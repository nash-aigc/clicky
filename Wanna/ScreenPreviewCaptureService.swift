import Foundation
import ScreenCaptureKit
import AppKit
import Combine

/// 语音聊天用的屏幕预览流。
///
/// 在此之前全仓**没有 `SCStream`** —— 只有 `CompanionScreenCaptureUtility` 的一发式
/// 截图（`SCScreenshotManager`）。这里新建一条低帧率的连续流，同时供两个用途：
///
/// - **给用户看**：`latestFrameImage`，让「屏幕」那个预览框真的有画面。
/// - **给模型看**：`latestFrameJPEG`，缩得更小，供三段式/全模态按需取用。
///
/// 用户对这条流的三个要求是「实时、帧率可以低、画质可以低、内存占用尽量小」，
/// 所以参数是按这三条写死的，不是随手取的默认值：
/// - `minimumFrameInterval` = 0.5 秒（2fps）—— 「实时」在这里指**不要延迟**，
///   而不是高帧率；2fps 的预览看起来就是连续的画面，而编码开销只有 30fps 的十五分之一。
/// - `queueDepth` = 1 —— **要的就是丢帧**：屏幕预览的价值在「最新的一张」，
///   排队积压只会让画面越播越晚（延迟恰恰是用户明确不要的）。
/// - 画面缩到 640 宽 —— 2K 屏全量送过来在小窗里也看不清，纯属浪费内存。
@MainActor
final class ScreenPreviewCaptureService: NSObject, ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var unavailabilityReason: String?
    /// 给预览框显示的当前帧。
    @Published private(set) var latestFrameImage: NSImage?
    /// 给模型用的当前帧（更小）。
    @Published private(set) var latestFrameJPEG: Data?

    private var stream: SCStream?
    /// 采集回调所在的队列 —— `SCStreamOutput` 的回调不在主线程。
    private let captureQueue = DispatchQueue(label: "wanna.voicechat.screen")

    /// 预览与送模型共用的目标宽度。取一个就够，因为「看清内容」这个标准两边一样。
    private static let targetWidthPixels = 640
    /// 预览框帧率：2fps。
    private static let frameIntervalSeconds: TimeInterval = 0.5

    // MARK: - 生命周期

    func start() async {
        guard !isRunning else { return }

        do {
            // 自己 App 的窗口要排除掉 —— 否则刘海面板会出现在「我的屏幕」预览里，
            // 也会被送给模型（模型会看到自己的界面）。与一发式截图同一套取向。
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let captureDisplay = shareableContent.displays.first else {
                unavailabilityReason = "没有找到可采集的显示器。"
                return
            }
            let ownApplicationWindows = shareableContent.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let contentFilter = SCContentFilter(
                display: captureDisplay,
                excludingWindows: ownApplicationWindows
            )

            let configuration = SCStreamConfiguration()
            // ⚠️ `SCDisplay.width` 是**点**不是像素。2K 屏上直接用会把采集分辨率
            // 设成实际的一半（笔记本上则是两倍）—— 本仓库的一发式截图里记着同一个坑。
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2
            let nativeWidthPixels = Int(captureDisplay.width) * Int(scaleFactor)
            let outputWidth = min(Self.targetWidthPixels, max(160, nativeWidthPixels))
            let aspectRatio = captureDisplay.height > 0
                ? Double(captureDisplay.height) / Double(captureDisplay.width)
                : 0.5625
            configuration.width = outputWidth
            configuration.height = max(90, Int(Double(outputWidth) * aspectRatio))

            configuration.minimumFrameInterval = CMTime(
                seconds: Self.frameIntervalSeconds,
                preferredTimescale: 600
            )
            // 丢帧是有意的：积压的帧只会让预览越来越晚。
            configuration.queueDepth = 1
            // 光标不画进画面：预览里那个箭头会让人以为屏幕上有两个鼠标。
            configuration.showsCursor = false

            let newStream = SCStream(
                filter: contentFilter,
                configuration: configuration,
                delegate: self
            )
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )

            try await newStream.startCapture()
            stream = newStream
            isRunning = true
            unavailabilityReason = nil
            print("🖥️ 语音聊天：屏幕预览流已开启（\(configuration.width)×\(configuration.height) @ \(Int(1 / Self.frameIntervalSeconds))fps）")
        } catch {
            // 最常见的原因是「屏幕录制」权限没给。这里如实报出来，而不是静默黑屏。
            unavailabilityReason = "屏幕预览打不开（多半是「屏幕录制」权限）：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard let stream else {
            isRunning = false
            return
        }
        self.stream = nil
        isRunning = false
        latestFrameImage = nil
        latestFrameJPEG = nil
        Task {
            try? await stream.stopCapture()
        }
        print("🖥️ 语音聊天：屏幕预览流已关闭")
    }
}

// MARK: - 帧回调

extension ScreenPreviewCaptureService: SCStreamOutput {

    /// 采集队列上的回调（**不是主线程**）。这里只做像素格式转换，状态更新跳主线程。
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = sourceImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        // 用同一个 CIImage 出两份：一份给预览（画质稍好），一份给模型（更小）。
        guard let previewImage = makeNSImage(from: sourceImage, longestEdge: 640) else { return }
        let modelJPEG = makeJPEG(from: sourceImage, longestEdge: 512)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestFrameImage = previewImage
            if let modelJPEG { self.latestFrameJPEG = modelJPEG }
        }
    }

    private nonisolated func makeNSImage(from sourceImage: CIImage, longestEdge: CGFloat) -> NSImage? {
        guard let cgImage = makeCGImage(from: sourceImage, longestEdge: longestEdge) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private nonisolated func makeJPEG(from sourceImage: CIImage, longestEdge: CGFloat) -> Data? {
        guard let cgImage = makeCGImage(from: sourceImage, longestEdge: longestEdge) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.55])
    }

    private nonisolated func makeCGImage(from sourceImage: CIImage, longestEdge: CGFloat) -> CGImage? {
        let extent = sourceImage.extent
        let currentLongestEdge = max(extent.width, extent.height)
        guard currentLongestEdge > 0 else { return nil }

        // 只缩不放：源比目标小的时候放大没有意义，只是白白多花内存。
        let scale = min(1, longestEdge / currentLongestEdge)
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return sharedScreenCIContext.createCGImage(scaledImage, from: scaledImage.extent)
    }
}

private nonisolated let sharedScreenCIContext = CIContext(options: [.useSoftwareRenderer: false])

// MARK: - SCStreamDelegate

extension ScreenPreviewCaptureService: SCStreamDelegate {

    /// 流被系统停掉（例如权限被撤销、显示器被拔）时，如实回到「没在跑」，
    /// 而不是让界面继续显示一张定格不动的旧图。
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.stream = nil
            self.latestFrameImage = nil
            self.latestFrameJPEG = nil
            self.unavailabilityReason = "屏幕预览中断了：\(error.localizedDescription)"
        }
    }
}
