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

    /// 每秒抓几帧。
    ///
    /// 用户 2026-09-26 调整过这道题：一开始说「一秒一帧」，用过之后改口
    /// 「一秒一张太慢了……0.25 秒一张的话可能会好一点」。**预览要跟得上手的动作** ——
    /// 他移动摄像头看房间的时候，一秒才换一次画面是看不清自己转到哪了。
    static let framesPerSecond: Double = 4
    /// 最多留几帧。超过就丢最早的 —— 一段话说了几分钟时，前面那些帧跟最后的提问
    /// 已经没关系了，而每多一帧就多一份 token。
    ///
    /// 4 帧/秒 × 24 = **覆盖最近 6 秒**。之前 12 帧在 1 帧/秒时也是 12 秒，但换成
    /// 4 帧/秒之后不跟着放大就等于只覆盖 3 秒 —— 用户把镜头转一圈都录不全。
    static let maximumRetainedFrames = 24

    var onFrame: ((Data) -> Void)?
    /// 已经抓了多少帧。界面上的数字用它。
    private(set) var capturedFrameCount = 0
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "clicky.camera.session")
    private var lastCapturedAt = Date.distantPast
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
        }
        // 把摄像头本身的帧率也压到 10 —— 我们 4 帧/秒够用，剩下的 6 帧留给
        // 「某一帧迟到时还有后备」，再多就是白烧电和白占管线。
        if let format = device.activeFormat as AVCaptureDevice.Format? {
            let minimumDuration = CMTime(value: 1, timescale: 10)
            if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 10 }) {
                try? device.lockForConfiguration()
                device.activeVideoMinFrameDuration = minimumDuration
                device.activeVideoMaxFrameDuration = minimumDuration
                device.unlockForConfiguration()
            }
        }

        startedAt = Date()
        arrivedFrameCount = 0
        lastCapturedAt = .distantPast
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

        // 一秒一帧。摄像头本身可能给 30fps，这里按时间间隔丢。
        let now = Date()
        guard now.timeIntervalSince(lastCapturedAt) >= 1.0 / Self.framesPerSecond else { return }
        lastCapturedAt = now

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent),
              let jpeg = Self.downscaledJPEG(from: cgImage, maximumDimension: 768) else { return }
        capturedFrameCount += 1
        onFrame?(jpeg)
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
