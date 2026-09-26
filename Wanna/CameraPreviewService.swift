import Foundation
import AVFoundation
import AppKit
import Combine

/// 语音聊天用的摄像头。
///
/// Wanna 在此之前**完全没有摄像头代码**（全仓零 `AVCaptureSession`），所以这是一个
/// 全新的采集路径。两个用途、两种代价，故意分开：
///
/// - **给用户看**：`previewLayer` 交给界面。走 `AVCaptureVideoPreviewLayer` 是
///   零拷贝的（GPU 直接出画面），所以预览可以顺滑，而 CPU 几乎不动 —— 这正好对上
///   用户的要求「实时即可，不需要高画质」。
/// - **给模型看**：`latestFrameJPEG`，**节流到 1fps** 且压到小尺寸。视频帧上行是
///   按秒计的（全模态 `input_image_buffer.append` 官方要求间隔 ≥1 秒），
///   每帧都转一遍 JPEG 纯属浪费 CPU 和内存。
///
/// 采集本身在 `sessionQueue` 上跑 —— `AVCaptureSession.startRunning()` 是**阻塞**的，
/// 在主线程调它会卡住界面（本仓库在音频那边已经吃过同类的亏，见
/// `VoicePlaybackEngine` 把引擎启动挪出主线程的注释）。
@MainActor
final class CameraPreviewService: NSObject, ObservableObject {

    /// 摄像头当前是否真的在出画面。界面据此把它自己的空态换成预览。
    @Published private(set) var isRunning = false
    /// 拿不到摄像头时的原因（没设备 / 没授权），给用户看。
    @Published private(set) var unavailabilityReason: String?

    /// 给模型用的最新一帧（JPEG）。节流到 1fps。
    @Published private(set) var latestFrameJPEG: Data?

    /// 摄像头画面的宽高比（宽 ÷ 高）。界面拿它来**完整显示**画面而不是裁掉一半 ——
    /// 用户的原话：「不要把摄像头和屏幕做成左右对称，而是要把摄像头的完整比例显示出来
    /// ……比如摄像头能看到左边，但我在对话框里看不到实时画面，那就相当于我完全误解 AI 了」。
    /// 默认 4:3，真正值在设备就绪后由 `activeFormat` 读出来。
    @Published private(set) var frameAspectRatio: CGFloat = 4.0 / 3.0

    /// 预览层。界面把它装进一个 `NSView`，由它自己在 GPU 上出画面。
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// 采集的一切都在这个串行队列上，主线程只收结果。
    private let sessionQueue = DispatchQueue(label: "wanna.voicechat.camera")
    /// 给模型的那一路节流：上一次转 JPEG 的时刻。
    private var lastModelFrameAt = Date.distantPast

    /// 给模型的那一路的节流间隔。1 秒是官方对 `input_image_buffer.append` 的要求
    /// （间隔太密服务端会报错），所以这里不是性能取舍而是协议约束。
    private static let modelFrameMinimumIntervalSeconds: TimeInterval = 1.0

    // MARK: - 生命周期

    /// 起摄像头。拿不到设备或没授权时**不抛错**，而是把原因写进
    /// `unavailabilityReason` —— 摄像头打不开不该让整个语音会话失败。
    func start() async {
        guard !isRunning else { return }

        // 量一下每一步花了多久。用户报的「摄像头要等将近 20 秒」不能靠猜 ——
        // 是设备选错了（选到 Continuity Camera 之类的网络设备）、还是硬件本身慢，
        // 这两句日志会直接给出答案。
        let startedAt = Date()

        guard await requestCameraAccessIfNeeded() else {
            unavailabilityReason = "没有摄像头权限。到「系统设置 → 隐私与安全性 → 摄像头」里允许 Wanna。"
            return
        }
        print(String(format: "📷 [camera] 授权 %dms", Int(Date().timeIntervalSince(startedAt) * 1000)))

        guard let cameraDevice = selectCameraDevice() else {
            unavailabilityReason = "这台 Mac 上没有找到摄像头。"
            return
        }
        print("📷 [camera] 选中设备「\(cameraDevice.localizedName)」 type=\(cameraDevice.deviceType.rawValue)")

        do {
            let deviceInput = try AVCaptureDeviceInput(device: cameraDevice)

            session.beginConfiguration()
            // `.medium` 而不是 `.high`：用户要的是「实时看得到」，不是清晰。
            // 低一档的分辨率让 CPU/内存明显更省，对预览和 1fps 送模型都够用。
            if session.canSetSessionPreset(.medium) {
                session.sessionPreset = .medium
            }
            guard session.canAddInput(deviceInput) else {
                session.commitConfiguration()
                unavailabilityReason = "摄像头被别的程序占用了。"
                return
            }
            session.addInput(deviceInput)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            session.commitConfiguration()

            // 画面比例从**设备的活动格式**读，而不是假设 4:3 —— 外接摄像头和
            // 笔记本内置头的比例不一样，写死会把画面拉变形。
            updateFrameAspectRatio(from: cameraDevice)

            previewLayer.session = session
            // `.resizeAspect`（完整显示）而不是 `.resizeAspectFill`（裁掉一部分）：
            // 用户要的是「看到摄像头能看到的完整内容」，裁切正是他报的那个误解来源。
            previewLayer.videoGravity = .resizeAspect

            // `startRunning()` 是阻塞调用（打开硬件、协商格式，这一步最慢），
            // 放到采集队列上，主线程 await 挂起。
            let startRunningBeganAt = Date()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sessionQueue.async { [session] in
                    session.startRunning()
                    continuation.resume()
                }
            }
            print(String(format: "📷 [camera] startRunning %dms（总 %dms）",
                         Int(Date().timeIntervalSince(startRunningBeganAt) * 1000),
                         Int(Date().timeIntervalSince(startedAt) * 1000)))

            isRunning = true
            unavailabilityReason = nil
            print("📷 语音聊天：摄像头已开启（\(cameraDevice.localizedName)，比例 \(String(format: "%.2f", frameAspectRatio))）")
        } catch {
            unavailabilityReason = "摄像头打不开：\(error.localizedDescription)"
        }
    }

    /// 挑摄像头。
    ///
    /// **默认只问内置摄像头** —— 这是速度的关键，不是"优先选内置"那么简单。
    /// 上一版我把 `.continuityCamera` 也写进了 `deviceTypes`，以为「列出了再挑内置的」
    /// 就够了；实际上**只要把它列进枚举，系统就会去探那台 iPhone**，这一探本身就是
    /// 十几秒的停顿 —— 于是「选了内置的」也照样慢。
    ///
    /// 所以默认这一次枚举里**完全不提 Continuity**，只问 `.builtInWideAngleCamera`，
    /// 走的是纯本地设备表，毫秒级。iPhone 摄像头要用户显式打开才会去探
    /// （`prefersContinuityCamera`），与用户的要求一致：
    /// 「你要写死，默认使用 Mac 的摄像头，不需要选……除非用户手动勾选使用 iPhone 的摄像头」。
    var prefersContinuityCamera = false

    private func selectCameraDevice() -> AVCaptureDevice? {
        if prefersContinuityCamera {
            let continuitySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.continuityCamera],
                mediaType: .video,
                position: .unspecified
            )
            if let continuityCamera = continuitySession.devices.first {
                return continuityCamera
            }
            // 用户勾了但眼下没有 iPhone，退回内置而不是报错 —— 摄像头突然不可用
            // 比「用回了 Mac 摄像头」更让人困惑。
            print("📷 [camera] 勾了 iPhone 摄像头但没找到，回退到内置")
        }

        let builtInSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        if let builtInCamera = builtInSession.devices.first {
            return builtInCamera
        }
        // 没有内置头（外接摄像头 / Mac mini 之类）时才做一次全量枚举。
        return AVCaptureDevice.default(for: .video)
    }

    /// 从设备的活动格式读出画面比例。
    private func updateFrameAspectRatio(from device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return }
        frameAspectRatio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }

    func stop() {
        guard isRunning || session.isRunning else { return }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        isRunning = false
        latestFrameJPEG = nil
        print("📷 语音聊天：摄像头已关闭")
    }

    /// 授权。已经在别的入口授过就直接返回真，不重复弹窗。
    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - 帧回调

extension CameraPreviewService: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// 采集队列上的回调 —— **不是主线程**，所以这里只做「要不要留这一帧」的判断，
    /// 真正的状态更新跳回主线程。
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // 每一帧都转 JPEG 是纯浪费：模型那一路 1 秒才要一帧。
        // 节流判断放在这里、转换之前，省掉大多数帧的编码开销。
        let now = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard now.timeIntervalSince(self.lastModelFrameAt) >= Self.modelFrameMinimumIntervalSeconds else {
                return
            }
            self.lastModelFrameAt = now

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            // 送模型的那一路再压小一档：画面小一点，上行省一大截，模型看内容够用。
            if let jpegData = Self.makeDownscaledJPEG(from: pixelBuffer) {
                self.latestFrameJPEG = jpegData
            }
        }
    }

    /// `CVPixelBuffer` → 缩小后的 JPEG。
    ///
    /// 走 `CIContext` 而不是 `NSBitmapImageRep`：这里拿到的是 BGRA 的像素缓冲，
    /// 用 Core Image 缩放 + 出 CGImage 是一条直路，不必先拷成 `NSImage` 再编码。
    private nonisolated static func makeDownscaledJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

        // 最长边压到 640 —— 与语音聊天送屏幕帧的取向一致：看得出是什么，不追求细节。
        let longestEdge = max(sourceImage.extent.width, sourceImage.extent.height)
        guard longestEdge > 0 else { return nil }
        let scale = min(1, 640 / longestEdge)
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = sharedCIContext
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}

/// 一个共用的 `CIContext`。
///
/// `CIContext` 的创建不便宜（要建 GPU 管线），而每秒都要用一次，所以建一次存着。
/// `nonisolated` 是因为它只在采集队列上被读。
private nonisolated let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
