import AVFoundation
import AppKit

/// 从摄像头抓**一帧**。只为「停止录音那一刻的摄像头画面」这一件事存在。
///
/// 用户的要求：「录制摄像头，瞬间截屏一个摄像头屏幕……**揪一帧就可以**，就跟截屏是一样」。
///
/// 和录像无关 —— 不写文件、不保持会话，拿到一帧就把 session 停掉。所以它**不是**
/// `CameraPreviewService`（那个是给语音聊天用的持续预览），两者只在「都用
/// `AVCaptureSession`」这一点上重合。
///
/// 关键的一行是 `alwaysDiscardsLateVideoFrames`：默认是 `false`，缓冲会堆起来，
/// 拿到的是**队列里最旧**的那一帧；置成 `true` 之后拿到的才是**当下**这一帧。
/// 用户要的是「停止那一秒的画面」，差半秒可能就换了个样。
nonisolated final class RecordingCameraGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// 抓一帧。**超时就返回 nil** —— 摄像头被别的 App 占着、没设备、没权限时
    /// 都会走到这里，而那时候不该让整条录音链卡住：一张参考图没有了不起，
    /// 但用户说完了内容却因为摄像头没回话而拿不到结果，那是另一回事。
    static func grabOneFrameJPEG(timeoutSeconds: Double = 1.5) async -> Data? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return nil }
        guard let device = AVCaptureDevice.default(for: .video) else { return nil }

        let grabber = RecordingCameraGrabber()
        return await grabber.run(device: device, timeoutSeconds: timeoutSeconds)
    }

    private let session = AVCaptureSession()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var hasResumed = false

    private func run(device: AVCaptureDevice, timeoutSeconds: Double) async -> Data? {
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // 见类型注释：这一行决定了拿到的是「当下」还是「队列里最旧的」。
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "clicky.camera.grab"))
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        let frame: Data? = await withCheckedContinuation { continuation in
            self.continuation = continuation
            session.startRunning()
            // 超时兜底。
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finish(with: nil)
            }
        }
        session.stopRunning()
        return frame
    }

    /// 只兑现一次 —— delegate 回调可能比超时先到，两者会撞。
    private func finish(with data: Data?) {
        guard !hasResumed else { return }
        hasResumed = true
        session.stopRunning()
        continuation?.resume(returning: data)
        continuation = nil
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !hasResumed, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
            finish(with: nil); return
        }
        // 缩到 1280 长边：摄像头给的是 1920×1080，而这一帧只是「理解用的参考」，
        // 再大对模型没有帮助，只是把请求撑肥。
        let jpeg = Self.downscaledJPEG(from: cgImage, maximumDimension: 1280)
        finish(with: jpeg)
    }

    private static func downscaledJPEG(from image: CGImage, maximumDimension: CGFloat) -> Data? {
        let longestSide = CGFloat(max(image.width, image.height))
        let scale = min(1, maximumDimension / max(longestSide, 1))
        let targetWidth = Int(CGFloat(image.width) * scale)
        let targetHeight = Int(CGFloat(image.height) * scale)

        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
