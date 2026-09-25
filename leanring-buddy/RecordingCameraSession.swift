import AVFoundation
import AppKit

/// 录音期间持续抓摄像头帧（默认一秒一帧）。
///
/// ## 为什么要持续抓，而不是「停止时抓一张」
///
/// 用户 2026-09-26：「屏幕是固定的，人是动的……人眼有细节需求，我让它仔细看，
/// 这种情况下只截一张图很难实现，所以需要**截多张图**」。他会移动摄像头去看房间的
/// 左边、右边、上面、下面，或者把一张纸凑到镜头前从左看到右 —— 一张图只能看到其中
/// 一个角度。
///
/// ## 为什么必须有预热
///
/// 摄像头冷启动时自动曝光还没稳定，**第一帧是全黑的**。实测：第一帧 33,665 字节
/// （全黑压缩后几乎为零），丢掉前 5 帧 + 等 0.35 秒之后是 429,468 字节、平均亮度
/// 119/255。所以这里**整段会话共用一次预热**：会话开始时等一次，之后每秒那一帧都是
/// 曝光稳定的。
nonisolated final class RecordingCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// **预览和送模型是两条不同步率的路径。**
    ///
    /// 用户 2026-09-26：「如果现在是一秒 4 帧的话，我觉得应该到一秒 12 帧……现在太卡了，
    /// 体验没法忍」，同时又说「是不是你采集的时候是一秒一张，但是显示的时候你可以很同步？」
    /// —— 他两次都指向同一件事：**看的要跟得上手，发出去的不用那么多**。
    ///
    /// - **预览**：只做 `CVPixelBuffer → CGImage → NSImage`，**不编码 JPEG**。
    ///   编码再解码是这条路上最贵的一段，而预览根本不需要它。
    /// - **送模型**：才做 JPEG 编码、才进那个帧缓冲。
    ///
    /// 2026-09-26 起这两个数**不再是常量**：用户在「录音」设置页里自己选
    /// （`recordingCameraPreviewFramesPerSecond` / `recordingCameraModelFramesPerSecond`），
    /// 由 `LongFormRecorderController` 在起采前写进来。
    ///
    /// **写入时机是一个约定：起采之前写好，起采之后只读。**
    /// 它们从主线程写、从 `queue` 上读，而 `start()` 里的 `queue.async` 正好是那道
    /// 屏障 —— 只要不在一段会话跑着的时候改，就不存在竞争。
    var previewFramesPerSecond: Double = 30
    var modelFramesPerSecond: Double = 1

    /// 预览帧（**不编码**，直接给 CGImage）。
    var onPreviewFrame: ((CGImage) -> Void)?
    /// 送模型的帧（JPEG）。
    var onModelFrame: ((Data) -> Void)?
    /// 已经抓了多少帧。界面上的数字用它。
    private(set) var capturedFrameCount = 0
    /// 缩放到指定长边，**不编码**。预览走这条。
    private static func downscaled(from image: CGImage, maximumDimension: CGFloat) -> CGImage? {
        let longestSide = CGFloat(max(image.width, image.height))
        let scale = min(1, maximumDimension / max(longestSide, 1))
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 当前用的采集分辨率。展开小窗时切成 1080p。
    private var currentPreset: AVCaptureSession.Preset = .hd1280x720

    /// 展开小窗时把分辨率换成 1080p；收起换回 720p。
    ///
    /// 用户 2026-09-26：「720P 吧，可以低清，但是点击右上角展开之后，换成 1080」——
    /// 收起时那一条只有 86pt 高，720p 完全够；展开成 200pt 时他是在**仔细看**，
    /// 那才值得花那份像素。
    func setHighResolution(_ wantsHighResolution: Bool) {
        let target: AVCaptureSession.Preset = wantsHighResolution ? .hd1920x1080 : .hd1280x720
        queue.async { [weak self] in
            guard let self, self.isRunning, self.currentPreset != target,
                  self.session.canSetSessionPreset(target) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = target
            self.session.commitConfiguration()
            self.currentPreset = target
        }
    }

    /// 把设备的帧率限制到目标值。**夹不住就不设** —— 见调用处的注释。
    private static func applyFrameRateLimit(to device: AVCaptureDevice,
                                            targetFramesPerSecond: Double) {
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= targetFramesPerSecond && targetFramesPerSecond <= $0.maxFrameRate
        }
        guard supported else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let duration = CMTime(value: 1, timescale: CMTimeScale(targetFramesPerSecond))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "clicky.camera.session")
    private var lastPreviewAt = Date.distantPast
    private var lastModelFrameAt = Date.distantPast
    private var startedAt = Date.distantPast
    private var arrivedFrameCount = 0
    private var isRunning = false

    /// **提到成员上，不要每帧新建。** `CIContext()` 每次构造都会分配 GPU/Metal 资源，
    /// 一秒一个虽然不算致命，但那是白扔的开销 —— 它是无状态的，建一次就够。
    private let ciContext = CIContext()

    private static let settleSeconds: TimeInterval = 0.35
    private static let minimumFramesToDiscard = 5

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.session.stopRunning()
        }
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            onFailure?("没有摄像头权限"); return
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onFailure?("打不开摄像头"); return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { onFailure?("加不了输出"); return }
        session.addOutput(output)

        // **这两行是「卡顿」的正面修复。**
        //
        // 从来没有人设过它们，所以摄像头一直按默认跑 —— 那是 **1080p30**，一条
        // **持续**占 CPU/GPU 的取景管线，和我们一秒要几帧毫无关系。用户报「非常卡顿」
        // 的时候，卡的就是这 30 帧里我们用不到的那 29 帧。
        //
        // `.hd1280x720`：像素量是 1080p 的 44%，而送模型的帧本来就是缩到 768 的，
        // 再高也白给。
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
            currentPreset = .hd1280x720
        }
        // 把摄像头本身的帧率压到**预览那个数**，不能再低。
        //
        // 原来是写死的 10（那是「送模型 4 帧/秒」时代的余量），而预览早就改成 30 了
        // —— 设备设了 `min/maxFrameDuration = 1/10` 之后硬件就只给 10 帧，上面那道
        // 30 帧的门限永远拿不到第 11 帧。**用户看到的「30 帧」其实一直是 10 帧。**
        // 所以这个上限必须跟着预览走：预览是眼睛在看的东西，它要多少就得给多少。
        //
        // **判据必须把区间夹住，不能只看上界。**
        // 原来写的是 `$0.maxFrameRate >= 10`，于是当某个格式的范围是 15–30 时它会
        // 放行，而设 10 越界 —— `setActiveVideoMinFrameDuration` 抛 **ObjC 异常**，
        // 而 `try?` 只接 Swift 错误，**接不住 ObjC 异常**，于是进程直接 SIGABRT。
        // 崩栈：[AVCaptureDALDevice setActiveVideoMinFrameDuration:] ← startOnQueue。
        //
        // 所以判据写成「区间包含目标帧率」，夹不住就**老老实实不设** ——
        // 帧率是优化，不是功能，为它崩一次不值。
        Self.applyFrameRateLimit(to: device, targetFramesPerSecond: previewFramesPerSecond)

        startedAt = Date()
        arrivedFrameCount = 0
        lastPreviewAt = .distantPast
        lastModelFrameAt = .distantPast
        isRunning = true
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 预热：先丢掉最初那几帧。见类型注释里的实测数字。
        arrivedFrameCount += 1
        guard arrivedFrameCount > Self.minimumFramesToDiscard,
              Date().timeIntervalSince(startedAt) >= Self.settleSeconds else { return }

        let now = Date()

        // **预览：不编码。** 这一步只做像素搬运，是「跟手」的来源。
        guard now.timeIntervalSince(lastPreviewAt) >= 1.0 / previewFramesPerSecond else { return }
        lastPreviewAt = now

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let fullImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        // 预览缩到 480 长边 —— 那条小窗最宽 315pt、高 86pt，再清晰也是浪费，
        // 而缩放本身就发生在绘制路径上，不额外编码。
        if let previewImage = Self.downscaled(from: fullImage, maximumDimension: 480) {
            onPreviewFrame?(previewImage)
        }

        // **送模型：才做 JPEG。** 这一段贵，所以按自己的节奏走。
        guard now.timeIntervalSince(lastModelFrameAt) >= 1.0 / modelFramesPerSecond else { return }
        lastModelFrameAt = now
        guard let jpeg = Self.downscaledJPEG(from: fullImage, maximumDimension: 768) else { return }
        capturedFrameCount += 1
        onModelFrame?(jpeg)
    }

    /// 小窗要的是「看得见」，模型要的是「看得清」—— 768 长边是两者的折中：
    /// 一帧约 40–60KB，24 帧也就 1MB 上下，比一张全屏截图还小。
    private static func downscaledJPEG(from image: CGImage, maximumDimension: CGFloat) -> Data? {
        let longestSide = CGFloat(max(image.width, image.height))
        let scale = min(1, maximumDimension / max(longestSide, 1))
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}
