import AppKit
import SwiftUI

/// 屏幕**右上角那一排临时 agent** 住的窗口。
///
/// ## 为什么它自己一块面板
///
/// 用户 2026-09-26 要求把那一排从刘海左侧搬到「电脑屏幕右上角时间日期菜单栏的下面一行」，
/// 理由是「这样就不会影响整个窗口或者其他组件的位置」。它原来是画在刘海面板里的，而那块
/// 面板的窗口是为刘海量身的 —— 静止时只有 54pt 高、宽度也只到刘海两侧 150pt，所以那一排
/// 既被展开的东西盖住过，自己也放不下下面那两张卡片（画出来的部分落到窗口外，被静静裁掉）。
///
/// **这块面板是那个角落唯一的住户**，配方照抄这个仓库既有的做法（`AgentPanelController` /
/// `ScreenAnnotationManager` / `CameraStripPanelController`）：
///
/// - **透明、无边框、非激活**：`isOpaque = false` + `backgroundColor = .clear`，
///   `.nonactivatingPanel` 所以它永远不抢焦点，也不改变任何别的窗口的 frame；
/// - **`ignoresMouseEvents = true`** —— 点击穿透：菜单栏、`NSScreen` 上任何一个 App 的
///   窗口、右键菜单全都照常可点。命中的那一侧由 `NotchWindowController.handleGlobalClick`
///   用**同一批矩形**接走（`NotchSupport.agentButtonFrame` / `agentCardFrame`），
///   所以"画在哪"和"点在哪"只有一处算术；
/// - **`hidesOnDeactivate = false`** —— `NSPanel` 默认在 App 失去激活时躲起来，而这一排
///   是常驻的状态指示：用户去别的 App 干活时它必须还在（`AgentPanelController` 同一个理由）；
/// - **`.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.stationary`** —— 切空间、进全屏都跟着，
///   而且不会被"用户换了个桌面"挪走；
/// - **层级 `NotchSupport.agentStripWindowLevel`** —— 在普通窗口之上、在我们自己的面板之下。
///
/// **窗口建好一次、之后只挪 frame。** 这是这个仓库在透明窗口上踩过的坑：几何在 CA 提交
/// **之前**就改了，中间那一瞬新露出来的区域是空的、桌面会透出来（录音那条带报过「背景穿透」）。
/// 所以 `install()` 幂等，只重算 frame 和内容，不重建窗口。
@MainActor
final class AgentStripPanelController {

    static let shared = AgentStripPanelController()
    private init() {}

    private var panel: NSPanel?
    /// 视图要在屏幕参数变化时按新屏幕重算按钮高度，所以这一份得留着。
    private var hostingView: NSHostingView<AgentStripView>?

    /// 把那一排装上，或者按**当前**的屏幕重算它的位置。幂等 —— 启动、屏幕参数变化、
    /// （`rebuildScreenPresences` 的每一条调用路径）都走这里。
    func install() {
        // 挑屏：有菜单栏的那一块（主屏）。见 `NotchSupport.agentStripScreen`。
        guard let screen = NotchSupport.agentStripScreen else { return }
        let panelFrame = NotchSupport.agentStripPanelFrame(on: screen)
        let buttonHeight = NotchSupport.agentButtonHeight(on: screen)

        guard let panel else {
            let created = NSPanel(
                contentRect: panelFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isOpaque = false
            created.backgroundColor = .clear
            // 不要阴影：这一排是贴在菜单栏下面的一层状态指示，投影会在浅色壁纸上糊出一圈边。
            created.hasShadow = false
            created.level = NotchSupport.agentStripWindowLevel
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            created.isReleasedWhenClosed = false
            created.hidesOnDeactivate = false
            created.animationBehavior = .none
            // 点击穿透 —— 这是它"不影响任何别的窗口的命中判定"的唯一机制。
            // 面板自己永远收不到点击，所以 `AgentStripView` 里那句
            // `allowsHitTesting(false)` 是同一个事实的另一半。
            created.ignoresMouseEvents = true

            let hosting = NSHostingView(
                rootView: AgentStripView(board: .shared, buttonHeight: buttonHeight)
            )
            hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
            hosting.autoresizingMask = [.width, .height]
            created.contentView = hosting

            self.hostingView = hosting
            self.panel = created
            created.orderFrontRegardless()
            return
        }

        // 已经有了：屏幕参数可能变了（分辨率、主屏换了一块），重算 frame 与内容。
        // 先换内容再挪窗口 —— 顺序反过来的话，新区域会先空一帧。
        hostingView?.rootView = AgentStripView(board: .shared, buttonHeight: buttonHeight)
        hostingView?.frame = NSRect(origin: .zero, size: panelFrame.size)
        if panel.frame != panelFrame {
            panel.setFrame(panelFrame, display: false)
        }
    }

    /// 「刘海屏入口」关掉、或者 App 退出：整块撤掉。
    ///
    /// 窗口是**关掉**而不是留着 —— 这条路上没有"还会再用一次"的场景（`teardown` 只在
    /// 关入口和退出时走到），而留一块透明面板在屏幕上没有任何好处。
    func teardown() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}
