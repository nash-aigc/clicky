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
    /// - **预览 12 帧/秒**：只做 `CVPixelBuffer → CGImage → NSImage`，**不编码 JPEG**。
    ///   编码再解码是这条路上最贵的一段，而预览根本不需要它。
    /// - **送模型 4 帧/秒**：才做 JPEG 编码、才进那个 24 帧的缓冲。
    ///
    /// 12 帧/秒对「转动摄像头看房间」是够跟手的，而 4 帧/秒 × 24 帧 = 覆盖 6 秒，
    /// token 也还在合理范围。
    /// 用户 2026-09-26 又调了一次，而且理由比数字本身重要：
    /// 「送给模型的是每秒 1 帧。不需要那么快，**因为人类的动作不会那么快，摄像头拍的就是人**」
    /// —— 模型那边要的是「这一段时间里镜头对着什么」，一秒一张足够；
    /// 而预览是**眼睛在看**，「要加就直接加 30 帧」，少了就知道卡。
    static let previewFramesPerSecond: Double = 30
    static let modelFramesPerSecond: Double = 1
    /// 最多留几帧。超过就丢最早的 —— 一段话说了几分钟时，前面那些帧跟最后的提问
    /// 已经没关系了，而每多一帧就多一份 token。
    ///
    /// 4 帧/秒 × 24 = **覆盖最近 6 秒**。之前 12 帧在 1 帧/秒时也是 12 秒，但换成
    /// 4 帧/秒之后不跟着放大就等于只覆盖 3 秒 —— 用户把镜头转一圈都录不全。
    static let maximumRetainedFrames = 24

    /// 预览帧（**不编码**，直接给 CGImage）。12 帧/秒。
    var onPreviewFrame: ((CGImage) -> Void)?
    /// 送模型的帧（JPEG）。4 帧/秒。
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
        // 把摄像头本身的帧率也压到 10 —— 我们 4 帧/秒够用，剩下的留给「某一帧迟到时
        // 还有后备」，再多就是白烧电和白占管线。
        //
        // **判据必须把区间夹住，不能只看上界。**
        // 原来写的是 `$0.maxFrameRate >= 10`，于是当某个格式的范围是 15–30 时它会
        // 放行，而设 10 越界 —— `setActiveVideoMinFrameDuration` 抛 **ObjC 异常**，
        // 而 `try?` 只接 Swift 错误，**接不住 ObjC 异常**，于是进程直接 SIGABRT。
        // 崩栈：[AVCaptureDALDevice setActiveVideoMinFrameDuration:] ← startOnQueue。
        //
        // 所以判据写成「区间包含目标帧率」，夹不住就**老老实实不设** ——
        // 帧率是优化，不是功能，为它崩一次不值。
        Self.applyFrameRateLimit(to: device, targetFramesPerSecond: 10)

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

        // **预览：12 帧/秒，不编码。** 这一步只做像素搬运，是「跟手」的来源。
        guard now.timeIntervalSince(lastPreviewAt) >= 1.0 / Self.previewFramesPerSecond else { return }
        lastPreviewAt = now

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let fullImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        // 预览缩到 480 长边 —— 那条小窗最宽 315pt、高 86pt，再清晰也是浪费，
        // 而缩放本身就发生在绘制路径上，不额外编码。
        if let previewImage = Self.downscaled(from: fullImage, maximumDimension: 480) {
            onPreviewFrame?(previewImage)
        }

        // **送模型：4 帧/秒，才做 JPEG。** 这一段贵，所以按自己的节奏走。
        guard now.timeIntervalSince(lastModelFrameAt) >= 1.0 / Self.modelFramesPerSecond else { return }
        lastModelFrameAt = now
        guard let jpeg = Self.downscaledJPEG(from: fullImage, maximumDimension: 768) else { return }
        capturedFrameCount += 1
        onModelFrame?(jpeg)
    }

    /// 小窗要的是「看得见」，模型要的是「看得清」—— 768 长边是两者的折中：
    /// 一帧约 40–60KB，12 帧也就 600KB 上下，比一张全屏截图还小。
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
