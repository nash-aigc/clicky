//
//  AgentSessionView.swift
//  leanring-buddy
//
//  The agent transcript view — what the sheet's content column shows when the
//  sidebar's Agent section is active and an agent is selected.
//
//  Every visual here is cloned from `NotchHomeView`'s conversation styles (the
//  bubble geometry, the composer field, the auto-scroll discipline) so the two
//  content columns read as one family; the differences are the agent's own:
//  a status + folder header that doubles as the page's only title (the sheet's
//  top bar is not drawn on this page — see `agentHeader`), gray tool-activity
//  lines instead of a progress disclosure, and an interrupt button at the
//  header's right.
//

import SwiftUI

struct AgentSessionView: View {

    @ObservedObject var agentSessionManager: AgentSessionManager

    @FocusState private var composerFieldIsFocused: Bool
    @State private var composerDraft: String = ""

    /// The composer's 展开 button (user's request): the field grows to 30% of
    /// the content column and collapses back to three lines.
    @State private var isComposerExpanded = false
    /// The content column's height, measured off the root view — the sheet's
    /// height is the user's own (they can drag its bottom edge), so the 30%
    /// figure has to be measured rather than assumed.
    @State private var contentColumnHeight: CGFloat = 0

    var body: some View {
        if let agent = agentSessionManager.selectedAgent {
            VStack(spacing: 0) {
                agentHeader(agent)
                transcriptFlow(agent)
                errorLine
                composerRow(agent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                GeometryReader { geometryProxy in
                    Color.clear
                        .onAppear { contentColumnHeight = geometryProxy.size.height }
                        .onChange(of: geometryProxy.size.height) { _, newHeight in
                            contentColumnHeight = newHeight
                        }
                }
            )
        } else {
            emptyRosterHint
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    /// Name + status capsule + the project folder the agent works in, plus the
    /// interrupt button while a turn is running.
    ///
    /// This header now opens the column: the sheet's own top bar (the name
    /// capsule, the activity indicator and the ✕) is not rendered on the Agent
    /// and 语音聊天 pages any more — the user asked for one title, not two, and
    /// for the ✕ to go, since clicking outside the sheet already puts it away.
    /// `sheetHeaderTopInset` is what the deleted bar used to occupy, so the
    /// title lands exactly where the capsule was instead of under the menu bar.
    private func agentHeader(_ agent: AgentSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(agent.status.displayName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(statusColor(agent.status))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(statusColor(agent.status).opacity(0.15))
                        )
                }

                Text(agent.projectFolderPath)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(agent.projectFolderPath)
            }

            Spacer(minLength: 8)

            if agent.status == .running {
                Button(action: { agentSessionManager.interrupt(agent.id) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("中断")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("停止当前任务（对话历史保留，下次任务接着进行）")
            }

            if let costUSD = agent.lastTurnCostUSD {
                Text(String(format: "≈$%.2f", costUSD))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            // 累计花费 only shows once it differs from the last turn's — a
            // first turn would read the same number twice.
            if let accumulatedCostUSD = agent.accumulatedCostUSD,
               accumulatedCostUSD != agent.lastTurnCostUSD {
                Text(String(format: "累计 ≈$%.2f", accumulatedCostUSD))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .padding(.bottom, 10)
    }

    private func statusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .idle: return .white.opacity(0.45)
        case .running: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .completed: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .failed: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .interrupted: return Color(red: 1.0, green: 0.75, blue: 0.35)
        }
    }

    // MARK: - Transcript flow

    private func transcriptFlow(_ agent: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if agent.transcript.isEmpty && streamingText.isEmpty {
                        emptyTranscriptHint(agent)
                    }

                    ForEach(agent.transcript) { entry in
                        switch entry.kind {
                        case .userMessage:
                            outgoingBubble(entry.text)
                                .id(entry.id)
                        case .assistantMessage:
                            assistantBubble(entry.text)
                                .id(entry.id)
                        case .toolActivity:
                            toolActivityLine(entry.text)
                                .id(entry.id)
                        }
                    }

                    if agent.status == .running {
                        if !streamingText.isEmpty {
                            assistantBubble(streamingText)
                                .id("agent-streaming")
                        } else {
                            workingIndicator
                                .id("agent-streaming")
                        }
                    }

                    // The scroll target AND the flow's bottom breathing room,
                    // as one resident view — the streaming ids above only exist
                    // while a turn is running, so scrolling to one of them did
                    // nothing when the user simply opened another agent.
                    Color.clear
                        .frame(height: 16)
                        .id(Self.transcriptBottomAnchorID)
                }
                .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
                .padding(.top, 4)
            }
            // Whole-flow selection: the user asked to be able to select part of
            // a message or drag across one, and this covers every Text below —
            // including the gray tool-activity lines.
            .textSelection(.enabled)
            .onChange(of: agent.transcript.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: streamingText) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: agentSessionManager.selectedAgentID) { _, _ in
                // One turn of the main loop later: the newly selected agent's
                // transcript is part of the same render pass, and scrolling
                // before that pass lays out measures the previous agent's rows.
                scheduleScrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private static let transcriptBottomAnchorID = "agent-transcript-bottom-anchor"

    private var streamingText: String {
        agentSessionManager.streamingTextByAgentID[agentSessionManager.selectedAgentID ?? UUID()] ?? ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
        }
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            scrollToBottom(proxy)
        }
    }

    /// The 「正在工作…」 breathing row shown before the first text or tool
    /// line of a turn arrives — the agent's spinner.
    private var workingIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(dotsAreBright ? 0.6 : 0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .onAppear {
            // One autoreversing animation drives all three dots together —
            // per-dot stagger needs three timers for no visual gain.
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dotsAreBright = true
            }
        }
    }

    @State private var dotsAreBright: Bool = false

    /// A tool invocation, the gray monospace progress line — the same visual
    /// register as the conversation view's progress-disclosure rows.
    private func toolActivityLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
        }
        .padding(.leading, 4)
    }

    private func emptyTranscriptHint(_ agent: AgentSession) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer.circle")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.25))
            Text("让 Agent 在「\(URL(fileURLWithPath: agent.projectFolderPath).lastPathComponent)」里做什么")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
            Text("它会在这个文件夹里读文件、改代码、跑命令，每一步都显示在下面")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyRosterHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.circle")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.25))
            Text("还没有 Agent")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
            Text("在左侧 Agent 页点「＋」新建一个，选一个项目文件夹")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    // MARK: - Error line

    @ViewBuilder
    private var errorLine: some View {
        if let errorMessage = agentSessionManager.lastAgentErrorMessage {
            Text(errorMessage)
                .font(.system(size: 11.5))
                .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.45).opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { agentSessionManager.dismissError() }
        }
    }

    // MARK: - Composer

    /// One text field, nothing else. The Agent status badge that used to sit
    /// to the left is gone (the user's 「右侧下方只有一个输入框」) and so is the
    /// send button that used to sit to the right (「无论是对话、agent 还是语音
    /// 聊天，都删掉右侧底部的发送按钮」) — Return sends, and the field's own
    /// Return handling goes through the same `submitComposerDraft`.
    private func composerRow(_ agent: AgentSession) -> some View {
        MessageComposerField(
            placeholder: "让 Agent 做什么…",
            draft: $composerDraft,
            isFocused: $composerFieldIsFocused,
            height: composerHeight,
            isExpanded: isComposerExpanded,
            canToggleExpansion: contentColumnHeight > 0,
            onToggleExpansion: { isComposerExpanded.toggle() },
            onSubmit: submitComposerDraft(agent)
        )
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// Three lines at rest, 30% of the content column when expanded — the
    /// user's own figure for the 展开 button.
    private var composerHeight: CGFloat {
        guard isComposerExpanded, contentColumnHeight > 0 else {
            return MessageComposerField.threeLineHeight
        }
        return max(
            MessageComposerField.threeLineHeight,
            contentColumnHeight * Self.expandedComposerHeightFraction
        )
    }

    private static let expandedComposerHeightFraction: CGFloat = 0.30

    private var composerDraftIsEmpty: Bool {
        composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The submit closure reads the agent at call time rather than capturing it
    /// — the field's own Return handling and the send button both go through
    /// here, and the selected agent can change while a draft is being typed.
    private func submitComposerDraft(_ agent: AgentSession?) -> () -> Void {
        return {
            guard !composerDraftIsEmpty, let agent else { return }
            agentSessionManager.sendTurn(composerDraft, to: agent.id)
            composerDraft = ""
            composerFieldIsFocused = false
        }
    }

    // MARK: - Bubbles (cloned geometry from NotchHomeView)

    private func bubbleShape(isOutgoing: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Self.bubbleCornerRadius,
            bottomLeadingRadius: isOutgoing ? Self.bubbleCornerRadius : Self.bubbleTailCornerRadius,
            bottomTrailingRadius: isOutgoing ? Self.bubbleTailCornerRadius : Self.bubbleCornerRadius,
            topTrailingRadius: Self.bubbleCornerRadius,
            style: .continuous
        )
    }

    // 参考页 `.unit.user` 的气泡几何：圆角 14，尾巴角 4（与 NotchHomeView
    // 同一套，2026-09-23 UI 化改造）。
    private static let bubbleCornerRadius: CGFloat = 14
    private static let bubbleTailCornerRadius: CGFloat = 4

    /// The user's line, with its copy control underneath — flush with the
    /// bubble's trailing edge. Both bubbles in this column carry one (the user
    /// asked for their own words and the agent's replies to be copyable here).
    private func outgoingBubble(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .bottom) {
                Spacer(minLength: 56)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        bubbleShape(isOutgoing: true)
                            .fill(DS.Colors.userBubbleFill)
                    )
            }

            MessageCopyButton(text: text, helpText: "复制我说的话")
        }
    }

    private func assistantBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        bubbleShape(isOutgoing: false)
                            .fill(DS.Colors.assistantBubbleFill)
                    )
                    .overlay(
                        bubbleShape(isOutgoing: false)
                            .strokeBorder(DS.Colors.assistantBubbleBorder, lineWidth: 0.5)
                    )
                Spacer(minLength: 56)
            }

            MessageCopyButton(text: text, helpText: "复制 Agent 的回复")
        }
    }
}
