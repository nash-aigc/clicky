import SwiftUI
import AppKit
import AVFoundation

/// 语音聊天页顶部的两个预览框 —— **摄像头** 与 **屏幕**。
///
/// 交互按用户 2026-09-24 的原话重做：
/// - **常驻**：会话在跑，这条就一直在页头下面。上一版把「缩起来」做成整条消失，
///   用户点一下之后就再也叫不回来了 —— 那是个 bug，这里从结构上不会再发生：
///   折叠只是把那个框的高度收成一条，它自己还在，点一下就展开。
/// - 两个框并排：**左边摄像头，右边屏幕**。
/// - 每个框点一下折叠 / 再点一下展开；**设备关掉就自动折叠**（控制器里做的）。
/// - 还能全屏（用户之前提的），全屏时占满内容区、对话流让位。
///
/// 「实时、帧率低、画质低、内存小」是采集服务的参数取向，见
/// `ScreenPreviewCaptureService` / `CameraPreviewService` 的头注释。
struct VoiceChatPreviewStrip: View {

    @ObservedObject var controller: VoiceChatController

    /// 展开时的高度。矮一点是刻意的：它是预览，不是画布；真要看清楚就点全屏。
    private static let expandedPaneHeight: CGFloat = 104
    /// 折叠成一条之后的高度。
    private static let collapsedPaneHeight: CGFloat = 26

    var body: some View {
        // 只在会话连上时出现。没连上就没有画面可预览，占着高度只是从对话历史里
        // 白拿走一块 —— 这正是用户在意的那件事。
        if controller.connectionPhase == .idle {
            EmptyView()
        } else if let fullScreenPane = controller.fullScreenPreviewPane {
            fullScreenPanel(for: fullScreenPane)
        } else {
            panesRow
        }
    }

    // MARK: - 常规：两个框并排，各自可折叠

    /// 两个框**不是左右对称的**（用户 2026-09-24 明确要求）：
    /// 摄像头按它自己的比例占宽度（这样画面完整、不被裁掉），屏幕拿剩下的。
    /// 他的理由很实在：「摄像头能看到左边，但我在对话框里看不到实时画面，
    /// 那就相当于我完全误解 AI 了」—— 预览框的意义就是让用户看到**AI 看到的东西**，
    /// 裁掉一半等于骗自己。屏幕不是重点，所以它让位。
    private var panesRow: some View {
        let stripHeight = Self.expandedPaneHeight

        return HStack(alignment: .top, spacing: 8) {
            pane(for: .camera, width: cameraPaneWidth(forStripHeight: stripHeight))
            pane(for: .screen, width: nil)
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.bottom, 8)
    }

    /// 摄像头那块该多宽：展开时按画面比例算，折叠时和其他框一样是一条。
    /// 高度上限就是这一条的高度（再高会吃掉对话区）。
    private func cameraPaneWidth(forStripHeight stripHeight: CGFloat) -> CGFloat? {
        guard !controller.isCameraPreviewCollapsed else { return nil }
        // 只在摄像头真的出画面时才按比例排；没画面时两块平分，免得空框占掉半屏。
        guard controller.cameraPreview.isRunning else { return nil }

        let aspectRatio = max(0.4, min(3.0, controller.cameraPreview.frameAspectRatio))
        return stripHeight * aspectRatio
    }

    private func pane(for target: VoiceChatController.PreviewPane,
                      width: CGFloat?) -> some View {
        let isCollapsed = controller.isCollapsed(target)

        return VStack(spacing: 0) {
            // 顶部这条既是标题也是折叠开关 —— 用户说的「这个长方形的顶部点击一下
            // 可以折叠下来，变成一条」。
            paneHeader(for: target, isCollapsed: isCollapsed)

            if !isCollapsed {
                paneContent(for: target)
                    .frame(height: Self.expandedPaneHeight)
            }
        }
        .frame(width: width, alignment: .top)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .top)
        .background(DS.Colors.surface2, in: RoundedRectangle(
            cornerRadius: isCollapsed ? 6 : DS.CornerRadius.medium,
            style: .continuous
        ))
        .overlay(
            RoundedRectangle(
                cornerRadius: isCollapsed ? 6 : DS.CornerRadius.medium,
                style: .continuous
            )
            .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(
            cornerRadius: isCollapsed ? 6 : DS.CornerRadius.medium,
            style: .continuous
        ))
    }

    /// 那个框的顶栏：折叠箭头 + 名字 + 全屏按钮。**整条可点**（折叠），
    /// 全屏按钮自己吃自己的点击。
    private func paneHeader(for target: VoiceChatController.PreviewPane,
                            isCollapsed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 10)

            Image(systemName: target == .camera ? "video" : "display")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textSecondary)

            Text(target == .camera ? "摄像头" : "屏幕")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)

            // 折起来的时候顺手说明它现在是什么状态，不用展开就知道。
            if isCollapsed, let statusWord = collapsedStatusWord(for: target) {
                Text(statusWord)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            Spacer(minLength: 0)

            if !isCollapsed {
                Button {
                    controller.toggleFullScreen(target)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                .help("全屏")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.collapsedPaneHeight)
        .contentShape(Rectangle())
        .onTapGesture { controller.togglePreviewCollapsed(target) }
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        .help(isCollapsed ? "展开" : "折叠成一条")
    }

    /// 折起来那一行右侧的状态词 —— 「开着的」还是「关着的」，
    /// 让用户在折叠状态下也能一眼看出设备有没有在跑。
    private func collapsedStatusWord(for target: VoiceChatController.PreviewPane) -> String? {
        switch target {
        case .camera:
            if controller.cameraPreview.isRunning { return "开着" }
            return controller.isCameraEnabled ? "打不开" : "关着"
        case .screen:
            if controller.screenPreview.isRunning { return "开着" }
            return controller.isScreenSharingEnabled ? "打不开" : "关着"
        }
    }

    // MARK: - 展开时的画面

    @ViewBuilder
    private func paneContent(for target: VoiceChatController.PreviewPane) -> some View {
        ZStack {
            if isCaptureRunning(target) {
                switch target {
                case .camera:
                    CameraPreviewLayerView(previewLayer: controller.cameraPreview.previewLayer)
                case .screen:
                    screenFrameImage
                }
            } else {
                emptyState(for: target)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func isCaptureRunning(_ target: VoiceChatController.PreviewPane) -> Bool {
        switch target {
        case .camera: return controller.cameraPreview.isRunning
        case .screen: return controller.screenPreview.isRunning
        }
    }

    @ViewBuilder
    private var screenFrameImage: some View {
        if let frameImage = controller.screenPreview.latestFrameImage {
            Image(nsImage: frameImage)
                .resizable()
                // 填满而不是适应：小窗里要的是「看到屏幕大体在发生什么」，
                // 留黑边只会让本来就小的画面更小。
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            emptyState(for: .screen)
        }
    }

    /// 没画面时的空态：说清楚**为什么**，而不是留一块黑。
    private func emptyState(for target: VoiceChatController.PreviewPane) -> some View {
        VStack(spacing: 3) {
            Image(systemName: target == .camera ? "video.slash" : "display")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.textTertiary)
            Text(reasonText(for: target))
                .font(.system(size: 9))
                .foregroundStyle(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
    }

    private func reasonText(for target: VoiceChatController.PreviewPane) -> String {
        switch target {
        case .camera:
            return controller.cameraPreview.unavailabilityReason
                ?? (controller.isCameraEnabled ? "正在打开摄像头…" : "摄像头未开启")
        case .screen:
            return controller.screenPreview.unavailabilityReason
                ?? (controller.isScreenSharingEnabled ? "正在打开屏幕预览…" : "屏幕未开启")
        }
    }

    // MARK: - 全屏

    @ViewBuilder
    private func fullScreenPanel(for target: VoiceChatController.PreviewPane) -> some View {
        VStack(spacing: 0) {
            paneHeader(for: target, isCollapsed: false)
                .overlay(alignment: .trailing) {
                    Button {
                        controller.toggleFullScreen(target)
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                    .help("退出全屏")
                    .padding(.trailing, 6)
                }

            paneContent(for: target)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 200)
        .background(DS.Colors.surface2, in: RoundedRectangle(
            cornerRadius: DS.CornerRadius.medium,
            style: .continuous
        ))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.bottom, 8)
    }
}

// MARK: - 摄像头预览层

/// 把 `AVCaptureVideoPreviewLayer` 装进 SwiftUI 的桥。
///
/// **不用 `makeBackingLayer`**（上一版那么写，画面是黑的）：把一个 `CALayer` 当
/// backing layer 交给 AppKit，它的 frame 由 AppKit 管，而 SwiftUI 反复重建这个
/// NSView 时会把同一个 layer 在视图之间搬来搬去 —— 搬过之后就不出画面了。
/// 改成「普通 NSView + 手动把预览层作为 sublayer 装上去、在 `layout()` 里同步
/// frame」，这是更常见的做法，行为可预测：视图多大，预览层就多大。
///
/// 预览层本身是 GPU 直出（零拷贝），所以 CPU 基本不动 —— 这正是「实时但不追求
/// 高画质」能成立的原因。
struct CameraPreviewLayerView: NSViewRepresentable {

    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        CameraPreviewHostingView(previewLayer: previewLayer)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let hostingView = nsView as? CameraPreviewHostingView else { return }
        hostingView.reattachIfNeeded()
    }

    /// 宿主视图：自己负责把预览层铺满自己的 bounds。
    ///
    /// 关键在 `layout()` —— SwiftUI 调整这个视图的尺寸时 AppKit 会调它，所以展开、
    /// 折叠、全屏、面板整体缩放，预览层都会跟着变。靠 `updateNSView` 是不够的：
    /// 那只在 SwiftUI 状态变化时被调，纯尺寸变化不会触发，画面会停在旧尺寸上。
    final class CameraPreviewHostingView: NSView {

        private let previewLayer: AVCaptureVideoPreviewLayer

        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            reattachIfNeeded()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // 预览层的 frame 直接跟宿主 bounds；`resizeAspectFill` 自己处理留白/裁切。
            previewLayer.frame = bounds
        }

        /// 视图被重建时把预览层挪到当前这个宿主上 —— 一个 `CALayer` 只能挂在一处，
        /// 不重新挂就会出现「新视图里一片黑」（上一版用 `makeBackingLayer` 时
        /// 正是这个症状）。
        func reattachIfNeeded() {
            guard previewLayer.superlayer !== layer else { return }
            previewLayer.removeFromSuperlayer()
            layer?.addSublayer(previewLayer)
            previewLayer.frame = bounds
        }
    }
}
