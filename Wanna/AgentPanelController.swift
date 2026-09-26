import AppKit
import Combine
import SwiftUI

/// 点屏幕右上角那一排 agent 按钮之后弹出来的**只读**面板。
///
/// （那一排 2026-09-26 从刘海左侧搬到了屏幕右上角、菜单栏下面一行；面板跟着它走，
/// 位置由 `NotchSupport.agentDetailPanelTopRightAnchor` 给。）
///
/// 用户 2026-09-26 的要求，逐条落在这里：
///
/// - 「可以点击查看：**具体做了什么？做到哪？做到什么程度？**」→ 步骤逐条列出来，
///   状态写在标题那一行
/// - 「**不可以输入**」→ 面板里没有任何 TextField；它是观察窗，不是控制台
/// - 「工具调用的部分**一定要折叠起来**，因为它会占用很多的空间」→ 默认收起，
///   点标题才展开
/// - 「把这个 ID 复制…让用户知道他是哪一个，然后方便跟 AI 交流」→ 标题旁边一个复制按钮
///
/// **它不并进 Agent 页。** 那一页装的是长期的 Claude Code 会话（有自己的历史和层级），
/// 而这里每一次都是一个临时任务 —— 用户的原话是「每一个 agent 都是临时的，所以你不能
/// 用一个对话来固定它」。
@MainActor
final class AgentPanelController {

    static let shared = AgentPanelController()

    /// 面板跟着看板的 `manualPanelID` 走 —— **一处状态，两处显示**。
    ///
    /// 不做成「按钮直接调 `show`」是因为那样就有了两个真相：按钮知道要开谁，
    /// 而看板不知道面板开着。用户再点一次按钮时，谁也说不清该收还是该开。
    /// 现在收/开都只是改那一个 id。
    private var panelSelectionObservation: AnyCancellable?

    private init() {
        panelSelectionObservation = AgentActivityBoard.shared.$manualPanelID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentID in
                guard let self else { return }
                if let agentID { self.show(agentID: agentID) } else { self.hide() }
            }
        // **面板开着的时候，里面的数据也要跟着走。**
        //
        // 原来只在 `manualPanelID` 变化时重建一次，于是"点开一个正在跑的任务、
        // 看着它跑"会永远停在点开那一刻的样子 —— 用户报的就是这个：
        // 「任务确实完成了，但是这个按钮跟任务的状态没有同步」。
        // 现在看板一变就按同一个 id 重新取一次、重建同一块视图。
        // 任务被退场（做完自动走）时 `show` 找不到它，会顺手把面板也收掉。
        panelContentObservation = AgentActivityBoard.shared.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let shownAgentID = self.shownAgentID else { return }
                self.show(agentID: shownAgentID)
            }
    }

    private var panelContentObservation: AnyCancellable?

    /// **「取消这个任务」的落点。** 面板不认识 `CompanionManager`，而"停止正在跑的活"
    /// 只有它做得到 —— 所以按这个仓库既有的做法注入一个闭包（同
    /// `LongFormAudioCapture.onSilentInputNeedsDeviceSwitch`）。
    ///
    /// 用户 2026-09-26 的要求：任务不该被"我下一次提问"打断，**只该被手动打断** ——
    /// 「要想打断它的话，只有用户点击这个左侧这个图标，然后点击这个取消任务」。
    /// 这就是那个入口。
    nonisolated(unsafe) static var cancelRunningJob: (() -> Void)?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AgentDetailView>?
    /// 面板正在展示哪一个 agent。看板那边关掉它时要用。
    private(set) var shownAgentID: String?

    private static let panelWidth: CGFloat = 320
    private static let panelMaximumHeight: CGFloat = 380

    func show(agentID: String) {
        guard let agent = AgentActivityBoard.shared.agents.first(where: { $0.id == agentID }) else {
            hide(); return
        }
        shownAgentID = agentID

        let root = AgentDetailView(agent: agent,
                                   board: AgentActivityBoard.shared,
                                   close: { [weak self] in
                                       AgentActivityBoard.shared.manualPanelID = nil
                                       self?.hide()
                                   })
        if let hostingView {
            hostingView.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []          // 窗口几何由我们自己说了算
            hostingView = view
        }
        guard let hostingView else { return }

        let size = NSSize(width: Self.panelWidth,
                          height: min(Self.panelMaximumHeight, hostingView.fittingSize.height))
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.hidesOnDeactivate = false
            // **比刘海面板高一层。** 同层的话它是**排在展开面板后面**的 —— 实测
            //（2026-09-26）：面板确实开了（窗口 320×277 在 341,38），但屏幕上看到的
            // 是展开面板的内容，任务面板被它整块盖住。高一层的代价只是它压在刘海里，
            // 而它本来就是从刘海那排按钮里点出来的。
            created.level = NotchSupport.notchPanelWindowLevel + 1
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            created.isReleasedWhenClosed = false
            created.animationBehavior = .none
            created.contentView = hostingView
            panel = created
        }
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel?.setFrame(frame(for: size), display: true)
        panel?.orderFrontRegardless()
    }

    /// 摆在那一排按钮**下面**，右边缘和那一排对齐。
    ///
    /// 贴不到就夹进屏幕里 —— 面板 320pt 宽、比一颗按钮（40pt）宽得多，直接右对齐到
    /// 屏幕右边缘会从右边伸出去，而用户看到的是「点了没反应」。
    ///
    /// 右侧的锚点由 `NotchSupport.agentDetailPanelTopRightAnchor` 给（那一排的右端、
    /// 按钮那一行的下沿），所以面板和按钮永远在同一个角上 —— 那一排 2026-09-26 从刘海
    /// 左侧搬到屏幕右上角时，这一处跟着换的只有这个锚点。
    private func frame(for size: NSSize) -> NSRect {
        guard let screen = NotchSupport.agentStripScreen else {
            return NSRect(origin: .zero, size: size)
        }
        let anchor = NotchSupport.agentDetailPanelTopRightAnchor(on: screen)
        let left = min(max(anchor.x - size.width, screen.frame.minX + 10),
                       screen.frame.maxX - size.width - 10)
        return NSRect(x: left, y: anchor.y - size.height, width: size.width, height: size.height)
    }

    /// 面板此刻在屏幕上的矩形 —— 给"点外面收起"用（判定在 `NotchWindowController`）。
    var panelScreenFrame: CGRect? {
        guard panel?.isVisible == true else { return nil }
        return panel?.frame
    }

    func hide() {
        panel?.orderOut(nil)
        shownAgentID = nil
    }
}

/// 面板里画的东西。
private struct AgentDetailView: View {

    let agent: EphemeralAgent
    @ObservedObject var board: AgentActivityBoard
    let close: () -> Void

    /// 工具调用默认**收起** —— 用户明确要求过，它们太长。
    @State private var showsToolCalls = false
    @State private var didCopyID = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    requestSection
                    stepsSection
                    toolCallsSection
                }
                .padding(11)
            }
            // **必须是定高，不能是 `maxHeight`。** `ScrollView` 的 fittingSize 高度是 0，
            // 于是 `show()` 里那个 `min(380, hostingView.fittingSize.height)` 把整块面板
            // 压成 37pt —— 屏幕上只剩一条表头（2026-09-26 实测：窗口 320×37，
            // 正文一个字都看不见）。定高之后内容真的在窗口里。
            .frame(height: 240)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }

    // MARK: - 头

    private var header: some View {
        // **标题行 = 时间**（用户 2026-09-26：「标题还是没有修改成时间」—— 面板这一行
        // 原来还是被截断的标题）。右边那颗 ✅ / ⏳ / ❌ 是任务结果；**完成时整行底色变绿**
        //（「✅表示任务完成，标题背景=绿色（如果完成的话），没完成=正常颜色」）。
        HStack(spacing: 8) {
            Image(systemName: agent.status == .running ? "hourglass" : (agent.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(statusColor)
            Text(agent.startTimeText)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundColor(DS.Colors.textPrimary)
            Text("任务内容")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 6)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.id, forType: .string)
                didCopyID = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    didCopyID = false
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: didCopyID ? "checkmark" : "doc.on.doc")
                    Text(agent.id).font(.system(size: 12, weight: .medium).monospaced())
                }
                .foregroundColor(didCopyID ? DS.Colors.success : DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("复制这个 agent 的 ID")

            // 「取消任务」只在这条还在跑时出现。
            if agent.status == .running {
                Button {
                    AgentPanelController.cancelRunningJob?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.circle")
                        Text("取消任务").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.destructive)
                }
                .buttonStyle(.plain)
                .help("停掉这条正在跑的任务")
            }
            // **右上角的 ✕ 删掉了**（用户 2026-09-26：「卡片右上角X删除，通过点击外部隐藏
            // 卡片即可」）—— 收起改由「点面板外面」负责，见 `NotchWindowController`。
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(agent.status == .doneVerified ? DS.Colors.success.opacity(0.22) : Color.clear)
    }

    // MARK: - 三节

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("你说的是")
            // 完整原话 —— 标题是截断的，而用户回头核对时要知道自己当时到底说了什么。
            Text(agent.request)
                .font(.system(size: 14.5))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("做了什么（\(agent.steps.count) 步）")
            if agent.steps.isEmpty {
                Text(agent.status == .running ? "还没开始…" : "没有记录到步骤")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                ForEach(Array(agent.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 14, alignment: .trailing)
                        Text(step)
                            .font(.system(size: 13.5))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// 工具调用 —— **默认收着**。
    private var toolCallsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsToolCalls.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsToolCalls ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    sectionLabel("工具调用（\(agent.toolCalls.count)）")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsToolCalls {
                if agent.toolCalls.isEmpty {
                    Text("一次都没有")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ForEach(Array(agent.toolCalls.enumerated()), id: \.offset) { _, call in
                        Text(call)
                            .font(.system(size: 10.5).monospaced())
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // **最后一行：任务结果。** 用户 2026-09-26：「只写了工具调用，下面没有说明
            //（任务是否完成或失败）…用代码的方式，在最后一行显示下状态」。状态本来就有
            //（`agent.status`），这里只是把它说出来 —— 三种做完的结果分别对应
            // 「成功 / 没做成 / 还在跑」，用户不用去猜。
            HStack(spacing: 5) {
                Text("任务结果")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.textTertiary)
                Text(resultText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(statusColor)
            }
            .padding(.top, 2)
        }
    }

    /// 结果那一行说什么。**「完成（未核验）」是刻意保留的**：它表示"做完了，但我没有
    /// 回读确认" —— 用户可能需要自己看一眼，而"成功"会让他放心地不看。
    private var resultText: String {
        switch agent.status {
        case .running: return "⏳ 还在跑"
        case .doneVerified: return "✅ 成功（已核验）"
        case .doneUnverified: return "✅ 已执行（未核验）"
        case .failed: return "❌ 没做成"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private var statusColor: Color {
        switch agent.status {
        case .running: return DS.Colors.accent
        case .doneVerified: return DS.Colors.success
        case .doneUnverified: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        }
    }
}

/// **鼠标左下角那块任务清单**（用户按快捷键弹出来的那一个）。
///
/// 用户 2026-09-26 的原话与理由：「增加一个快捷键…在鼠标左下角显示这个窗口。点这个快捷键
/// 之后，**它就不变了**，但是任务的卡片是可以变化的，可以展开的，也可以停止什么的」；
/// 「为什么推荐呢？因为鼠标移动到左侧是左上角，它其实需要时间和距离的，而且体验下来不是
/// 很好」。所以：
///
/// - **位置在弹出那一刻定死**（锚在鼠标的左下角），之后**不跟随鼠标** —— 会跟随的东西
///   点不准，而这里的每一行都要能点（看详情 / 取消）。
/// - 内容跟着看板走（`@ObservedObject`），所以卡片该变的时候它自己变 ✓。
@MainActor
final class TaskListPanelController {

    static let shared = TaskListPanelController()
    private init() {}

    private var panel: NSPanel?
    private var hosting: NSHostingView<TaskListView>?

    private static let panelWidth: CGFloat = 320
    private static let panelMaximumHeight: CGFloat = 420

    var isShown: Bool { panel?.isVisible == true }

    /// 面板此刻在屏幕上的矩形 —— 给"点外面收起"用（判定在 `NotchWindowController`）。
    var panelScreenFrame: CGRect? {
        guard panel?.isVisible == true else { return nil }
        return panel?.frame
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let root = TaskListView()
        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            hosting = view
        }
        guard let hosting else { return }

        let height = min(Self.panelMaximumHeight, max(80, hosting.fittingSize.height))
        let size = NSSize(width: Self.panelWidth, height: height)
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.hidesOnDeactivate = false
            // 和任务详情面板同层：它也是从刘海那套里出来的。
            created.level = NotchSupport.notchPanelWindowLevel + 1
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            created.isReleasedWhenClosed = false
            created.animationBehavior = .none
            created.contentView = hosting
            panel = created
        }
        hosting.frame = NSRect(origin: .zero, size: size)

        // **锚点：此刻鼠标的左下角。** AppKit 全局坐标是左下原点，所以"面板的右上角
        // 落在光标上"就是它挂在光标的左下 ✓。夹进屏幕里 —— 光标贴着边时面板不能跑出去。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width, y: mouse.y - size.height)
        if let frame = screen?.frame {
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

/// 清单里画的东西。**只读 + 三个动作**：看状态、去详情、取消在跑的那条。
private struct TaskListView: View {

    @ObservedObject private var board = AgentActivityBoard.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("任务")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("\(board.agents.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().overlay(DS.Colors.borderSubtle)

            if board.agents.isEmpty {
                Text("现在没有任务")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(board.agents) { agent in
                            row(agent)
                        }
                    }
                }
                .frame(height: 300)
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }

    private func row(_ agent: EphemeralAgent) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(agent.status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(agent.startTimeText)  \(agent.title)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(agent.status.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(color(agent.status))
            }
            Spacer(minLength: 4)
            if agent.status == .running {
                Button {
                    AgentPanelController.cancelRunningJob?()
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.destructive)
                }
                .buttonStyle(.plain)
                .help("停掉这条正在跑的任务")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private func color(_ status: EphemeralAgent.Status) -> Color {
        switch status {
        case .running: return DS.Colors.accent
        case .doneVerified: return DS.Colors.success
        case .doneUnverified: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        }
    }
}
