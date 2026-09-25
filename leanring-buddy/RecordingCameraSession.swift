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

    /// 每秒抓几帧。用户：「正常情况下按照一秒一帧」。
    static let framesPerSecond: Double = 1
    /// 最多留几帧。超过就丢最早的 —— 一段话说了几分钟时，前面那些帧跟最后的提问
    /// 已经没关系了，而每多一帧就多一份 token。
    static let maximumRetainedFrames = 12

    var onFrame: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "clicky.camera.session")
    private var lastCapturedAt = Date.distantPast
    private var startedAt = Date.distantPast
    private var arrivedFrameCount = 0
    private var isRunning = false

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
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent),
              let jpeg = Self.downscaledJPEG(from: cgImage, maximumDimension: 768) else { return }
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
