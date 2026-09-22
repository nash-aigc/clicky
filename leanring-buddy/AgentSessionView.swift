//
//  AgentSessionView.swift
//  leanring-buddy
//
//  The agent transcript view — what the sheet's content column shows when the
//  sidebar's Agent section is active and an agent is selected.
//
//  Every visual here is cloned from `NotchHomeView`'s conversation styles (the
//  bubble geometry, the composer pill, the auto-scroll discipline) so the two
//  content columns read as one family; the differences are the agent's own:
//  a status + folder header, gray tool-activity lines instead of a progress
//  disclosure, and an interrupt button where voice had its pill.
//

import SwiftUI

struct AgentSessionView: View {

    @ObservedObject var agentSessionManager: AgentSessionManager

    @FocusState private var composerFieldIsFocused: Bool
    @State private var composerDraft: String = ""

    var body: some View {
        if let agent = agentSessionManager.selectedAgent {
            VStack(spacing: 0) {
                agentHeader(agent)
                transcriptFlow(agent)
                errorLine
                composerRow(agent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyRosterHint
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    /// Name + status capsule + the project folder the agent works in, plus the
    /// interrupt button while a turn is running.
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
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 6)
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
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .onChange(of: agent.transcript.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: streamingText) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private var streamingText: String {
        agentSessionManager.streamingTextByAgentID[agentSessionManager.selectedAgentID ?? UUID()] ?? ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("agent-streaming", anchor: .bottom)
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
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { agentSessionManager.dismissError() }
        }
    }

    // MARK: - Composer

    private func composerRow(_ agent: AgentSession) -> some View {
        HStack(alignment: .center, spacing: 10) {
            agentBadge(agent)

            composerField

            Button(action: submitComposerDraft(agent)) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(composerDraftIsEmpty
                        ? .white.opacity(0.2)
                        : Color(red: 0.30, green: 0.56, blue: 1.0))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(composerDraftIsEmpty)
            .help("发送给 Agent")
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// The composer's left badge — the agent's own status pill, playing the
    /// role the voice pill plays in the conversation composer.
    private func agentBadge(_ agent: AgentSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agent.status == .running
                    ? Color(red: 0.35, green: 0.85, blue: 0.55)
                    : Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
            Text("Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var composerField: some View {
        HStack(spacing: 6) {
            TextField("让 Agent 做什么…", text: $composerDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($composerFieldIsFocused)
                .onSubmit { submitComposerDraft(agentSessionManager.selectedAgent)() }

            if !composerDraftIsEmpty {
                Button(action: { composerDraft = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(
            Capsule().strokeBorder(
                composerFieldIsFocused ? Color.white.opacity(0.25) : Color.white.opacity(0.1),
                lineWidth: 0.5
            )
        )
    }

    private var composerDraftIsEmpty: Bool {
        composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

    private static let bubbleCornerRadius: CGFloat = 16
    private static let bubbleTailCornerRadius: CGFloat = 5

    private func outgoingBubble(_ text: String) -> some View {
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
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.53, green: 0.36, blue: 0.98),
                                    Color(red: 0.42, green: 0.24, blue: 0.90)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    bubbleShape(isOutgoing: true)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                )
        }
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    bubbleShape(isOutgoing: false)
                        .fill(Color.black.opacity(0.26))
                )
                .overlay(
                    bubbleShape(isOutgoing: false)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            Spacer(minLength: 56)
        }
    }
}
