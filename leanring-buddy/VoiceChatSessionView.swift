//
//  VoiceChatSessionView.swift
//  leanring-buddy
//
//  The 语音聊天 content column — what the sheet shows when the sidebar's
//  语音聊天 section is active. Every visual is cloned from AgentSessionView's
//  transcript styles (bubble geometry, composer pill, auto-scroll), so the
//  content columns read as one family. The voice-chat-specific parts:
//
//    · the header carries the 「挂断 / 连接」 button the user asked for at
//      the top right — hang up while a session runs, connect (the selected
//      preset) while idle;
//    · the transcript mirrors the VoiceWeb session's own history, so what
//      the user SAYS lands here as outgoing bubbles too, not just typed text;
//    · the composer sends the typed line into the running session over the
//      external bridge (the page's official RTVI `sendText` path) — it only
//      enables while connected.
//

import SwiftUI

struct VoiceChatSessionView: View {

    @ObservedObject var controller: VoiceWebSessionController

    @FocusState private var composerFieldIsFocused: Bool
    @State private var composerDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            transcriptFlow
            composerRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header (role + 挂断/连接)

    /// The role name + connection-status capsule on the left, the
    /// 「挂断 / 连接」 button on the right — the user's requirement: the
    /// quick control sits at the content column's top, not buried in a menu.
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(headerRoleName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(statusWord)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusColor.opacity(0.15)))
                }

                Text("VoiceWeb 语音聊天")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer(minLength: 8)

            // 顶部右侧的「挂断 / 连接」按钮：会话进行中（连接中或聊天中）
            // 显示红色挂断；未连接时显示绿色连接（连当前选中的预设角色）。
            if controller.connectionPhase == .idle {
                Button {
                    if let roleID = controller.selectedRoleID ?? controller.rolePresets.first?.id {
                        controller.connectToRole(roleID)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("连接")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.35, green: 0.85, blue: 0.55))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(controller.rolePresets.isEmpty && controller.selectedRoleID == nil)
                .help("连接选中的语音角色")
            } else {
                Button {
                    controller.disconnectCurrentSession()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("挂断")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("挂断当前语音聊天")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var headerRoleName: String {
        if let activeRoleID = controller.activeRoleID,
           let role = controller.rolePresets.first(where: { $0.id == activeRoleID }) {
            return role.name
        }
        if let selectedRoleID = controller.selectedRoleID,
           let role = controller.rolePresets.first(where: { $0.id == selectedRoleID }) {
            return role.name
        }
        return "语音聊天"
    }

    private var statusWord: String {
        switch controller.connectionPhase {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "聊天中"
        }
    }

    private var statusColor: Color {
        switch controller.connectionPhase {
        case .idle: return .white.opacity(0.45)
        case .connecting: return Color(red: 1.0, green: 0.75, blue: 0.35)
        case .connected: return Color(red: 0.35, green: 0.85, blue: 0.55)
        }
    }

    // MARK: - Transcript flow

    private var transcriptFlow: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.transcriptEntries.isEmpty && controller.connectionPhase == .idle {
                        emptyHint
                    }

                    ForEach(controller.transcriptEntries) { entry in
                        if entry.isUser {
                            outgoingBubble(entry.text)
                                .id(entry.id)
                        } else {
                            assistantBubble(entry.text)
                                .id(entry.id)
                        }
                    }

                    if controller.connectionPhase == .connecting {
                        workingIndicator
                            .id("voicechat-streaming")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .onChange(of: controller.transcriptEntries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("voicechat-streaming", anchor: .bottom)
        }
    }

    /// The 「正在连接…」 breathing row — the same spinner the agent view uses
    /// before a turn's first text arrives.
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
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dotsAreBright = true
            }
        }
    }

    @State private var dotsAreBright: Bool = false

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.25))
            Text("点击左侧一个角色，连接语音聊天")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
            Text("连接后，这里实时显示聊天的每一句话；下面的输入框可以直接打字")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Composer

    private var composerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            stateBadge

            composerField

            Button(action: submitComposerDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(composerDraftIsEmpty
                        ? .white.opacity(0.2)
                        : Color(red: 0.30, green: 0.56, blue: 1.0))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(composerDraftIsEmpty)
            .help("发送文字到语音聊天")
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// The composer's left badge — the connection-state dot, playing the role
    /// the voice pill plays in the conversation composer.
    private var stateBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.connectionPhase == .connected
                    ? Color(red: 0.35, green: 0.85, blue: 0.55)
                    : Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
            Text("语音")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var composerField: some View {
        HStack(spacing: 6) {
            TextField(composerPlaceholder, text: $composerDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($composerFieldIsFocused)
                .onSubmit { submitComposerDraft() }

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

    /// Connected: an input. Idle: the reason nothing can be typed yet.
    private var composerPlaceholder: String {
        controller.connectionPhase == .connected ? "输入文字，回车发送…" : "连接后可打字发送"
    }

    private var composerDraftIsEmpty: Bool {
        composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitComposerDraft() {
        guard !composerDraftIsEmpty else { return }
        controller.sendText(composerDraft)
        composerDraft = ""
        composerFieldIsFocused = false
    }

    // MARK: - Bubbles (cloned geometry from AgentSessionView / NotchHomeView)

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
                        .fill(DS.Colors.accent)
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
