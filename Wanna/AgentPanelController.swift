import AppKit
import Combine
import SwiftUI

/// 点刘海左侧那个 agent 按钮之后弹出来的**只读**面板。
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
            // 和刘海面板同层 —— 它属于刘海那一套，不该浮到菜单之上。
            created.level = NotchSupport.notchPanelWindowLevel
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

    /// 摆在按钮**下面**，左边缘和按钮那一排对齐。
    ///
    /// 贴不到就夹进屏幕里 —— 第 3 个按钮已经很靠左了，面板比按钮宽得多（320 vs 30），
    /// 不夹的话它会伸到屏幕外面，而用户看到的是「点了没反应」。
    private func frame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let notch = NotchSupport.notchRect(on: screen),
              let trailingX = NotchSupport.agentStripTrailingX(on: screen) else {
            return NSRect(origin: .zero, size: size)
        }
        let topEdge = screen.frame.maxY - notch.height - 6
        var left = trailingX - size.width
        left = max(screen.frame.minX + 10, min(left, screen.frame.maxX - size.width - 10))
        return NSRect(x: left, y: topEdge - size.height, width: size.width, height: size.height)
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
            .frame(maxHeight: 300)
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
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(agent.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Text(agent.status.displayName)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 6)
            // **复制 ID 是给用户跟 AI 说话用的** —— 用户的原话：「让用户知道他是哪一个，
            // 然后方便跟 AI 交流」。所以复制的是 id，不是标题（标题可能重复）。
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
                    Text(agent.id).font(.system(size: 10, weight: .medium).monospaced())
                }
                .foregroundColor(didCopyID ? DS.Colors.success : DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("复制这个 agent 的 ID")

            // **取消任务**：只在这条任务还没结束（还在跑）时出现。
            // 它是"手动打断"的唯一入口 —— 用户的模型是「任务只能被手动打断」。
            if agent.status == .running {
                Button {
                    AgentPanelController.cancelRunningJob?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.circle")
                        Text("取消任务").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.destructive)
                }
                .buttonStyle(.plain)
                .help("停掉这条正在跑的任务")
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    // MARK: - 三节

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("你说的是")
            // 完整原话 —— 标题是截断的，而用户回头核对时要知道自己当时到底说了什么。
            Text(agent.request)
                .font(.system(size: 11.5))
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
                            .font(.system(size: 11.5))
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
