//
//  VoiceChatSessionView.swift
//  leanring-buddy
//
//  The 语音聊天 content column — what the sheet shows when the sidebar's
//  语音聊天 section is active. Every visual is cloned from AgentSessionView's
//  transcript styles (bubble geometry, composer field, auto-scroll), so the
//  content columns read as one family. The voice-chat-specific parts:
//
//    · the header carries this page's title and the three per-connection
//      choices — 模式 (三段式 / 全双工语音 / 全双工全模态), 屏幕, 摄像头;
//    · 「连接 / 挂断」 lives on the SIDEBAR's role row instead, at its right
//      edge. Clicking a role only selects it; the button beside it starts (or
//      ends) the session. Keeping the two apart is what fixed the bug where
//      connection state appeared to jump between role cards, and putting the
//      button on the row is the user's own 2026-09-23 request — the pointer
//      travel from "which role" to "connect" is a few pixels;
//    · the transcript mirrors the VoiceWeb session's own history, so what
//      the user SAYS lands here as outgoing bubbles too, not just typed text;
//    · the composer sends the typed line into the running session over the
//      external bridge (the page's official RTVI `sendText` path) — it only
//      sends while connected, and a draft typed before then is kept, not
//      swallowed.
//
//  The sheet's own top bar is not drawn on this page any more (the user asked
//  for one title instead of two, and for the ✕ to go) — this header takes its
//  slot, at `sheetHeaderTopInset`.
//

import SwiftUI

struct VoiceChatSessionView: View {

    @ObservedObject var controller: VoiceWebSessionController

    @FocusState private var composerFieldIsFocused: Bool
    @State private var composerDraft: String = ""

    /// The composer's 展开 button (user's request): the field grows to 30% of
    /// the content column and collapses back to three lines.
    @State private var isComposerExpanded = false
    /// The content column's height, measured off the root view — the sheet's
    /// height is the user's own, so the 30% figure has to be measured.
    @State private var contentColumnHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            transcriptFlow
            composerRow
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
    }

    // MARK: - Header (role + 模式 / 屏幕 / 摄像头)

    /// 页头：左边是角色名与连接状态，右边是这一条连接的三个选择 —— 模式、
    /// 屏幕、摄像头。
    ///
    /// **连接/挂断按钮不在这里**，它在左下角角色卡片的右侧（用户 2026-09-23
    /// 的第 5 条：「把连接按钮放在左侧边角色卡片的右侧部分，做成大一点的长方形
    /// 圆角形式。这样用户点击角色就可以选择是否连接，鼠标移动距离会非常小。
    /// **不要放在右上角**」）。同一段话的末尾又提到「标题右侧是一个很长的连接
    /// 和挂断按钮」——两句冲突，编号那一条更明确，按编号做。
    ///
    /// 右边这三个控件都是"下一次连接生效"：桥只有一条 `connect` 命令，没有
    /// 运行时切换设备的接口，所以 `.help` 里逐条写明了。模式菜单改的是
    /// `selectedMode`（角色卡片的连接按钮会带上它），屏幕/摄像头改的是 快捷键
    /// 页里同一批设置键 —— 同一份存储，两处入口不会显示成不同的值。
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

            HStack(spacing: 6) {
                modeMenu

                deviceToggleButton(
                    title: "屏幕",
                    systemImage: "rectangle.on.rectangle",
                    isOn: controller.isScreenSharingEnabled,
                    isSupported: controller.selectedModeSupportsScreenSharing,
                    unsupportedHelp: "全双工语音模式没有屏幕共享",
                    help: "把屏幕内容发给 AI。下次连接时生效。"
                ) {
                    controller.setScreenSharingEnabled(!controller.isScreenSharingEnabled)
                }

                deviceToggleButton(
                    title: "摄像头",
                    systemImage: "video",
                    isOn: controller.isCameraEnabled,
                    isSupported: controller.selectedModeSupportsCamera,
                    unsupportedHelp: "只有全双工全模态模式有摄像头",
                    help: "把摄像头画面发给 AI。下次连接时生效。"
                ) {
                    controller.setCameraEnabled(!controller.isCameraEnabled)
                }
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .padding(.bottom, 10)
        .onAppear {
            // 设置页是整窗独占的，所以"改完设置回到这一页"一定走一次
            // onAppear —— 这里重读一次，两颗开关就不会拿着上一个模式的值。
            controller.reloadDeviceSwitches()
        }
    }

    /// 模式下拉菜单：三段式 / 全双工语音 / 全双工全模态。选中的那一项带勾。
    ///
    /// 下拉而不是三颗平铺的按钮：三个模式名字都不短（最长 6 个字），平铺会
    /// 把页头挤满，而且它改的是"下一次连接用什么引擎"，不是点击即生效的动作。
    private var modeMenu: some View {
        Menu {
            ForEach(VoiceWebSessionController.VoiceWebMode.allCases, id: \.self) { mode in
                Button {
                    controller.selectedMode = mode
                } label: {
                    if controller.selectedMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "switch.2")
                    .font(.system(size: 11, weight: .medium))
                Text(controller.selectedMode.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: Self.headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        // `.button` 而不是 `.borderlessButton`：后者在 macOS 14 已废弃。配
        // `.plain` 才不会让菜单给自己画一圈默认的按钮底。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help("选语音模式。下次连接时生效。")
    }

    /// 页头那颗设备开关：开启时是实底的绿，关闭时是描边。不支持的组合**禁用而
    /// 不隐藏** —— 隐藏的话换模式时页头会跳，而且用户分不清"这个模式没有这个
    /// 能力"和"这个功能没做"。
    private func deviceToggleButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        isSupported: Bool,
        unsupportedHelp: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let tint = isOn
            ? Color(red: 0.35, green: 0.85, blue: 0.55)
            : Color.white.opacity(0.85)

        let iconAndLabelColor: Color = isSupported ? tint : Color.white.opacity(0.3)
        let fillColor: Color = (isOn && isSupported) ? tint.opacity(0.16) : Color.white.opacity(0.08)
        let borderColor: Color = (isOn && isSupported) ? tint.opacity(0.5) : Color.clear

        return Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(iconAndLabelColor)
            .padding(.horizontal, 10)
            .frame(height: Self.headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isSupported)
        .pointerCursor(isEnabled: isSupported)
        .help(isSupported ? help : unsupportedHelp)
    }

    /// 页头三个控件同高，与侧栏的 `NotchBarActionButton`（30）取齐。
    private static let headerControlHeight: CGFloat = 30

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

                    // The scroll target AND the flow's bottom breathing room,
                    // as one resident view — the ids above only exist while the
                    // session is connecting, so scrolling to one of them did
                    // nothing when the user simply picked another role.
                    Color.clear
                        .frame(height: 16)
                        .id(Self.transcriptBottomAnchorID)
                }
                .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
                .padding(.top, 4)
            }
            // Whole-flow selection: the user asked to be able to select part of
            // a message or drag across one.
            .textSelection(.enabled)
            .onChange(of: controller.transcriptEntries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: controller.selectedRoleID) { _, _ in
                // One turn of the main loop later: the newly selected role's
                // transcript is part of the same render pass, and scrolling
                // before that pass lays out measures the previous role's rows.
                scheduleScrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private static let transcriptBottomAnchorID = "voicechat-transcript-bottom-anchor"

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
            // The wording follows the interaction: choosing a role in the
            // sidebar only selects it now — the connection is started by the
            // 连接 button on that role's own row.
            Text(emptyHintHeadline)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
            Text("连接后，这里实时显示聊天的每一句话；下面的输入框可以直接打字")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// 引导语跟着交互走：连接按钮现在在**角色卡片自己的右侧**（用户第 5 条），
    /// 所以这里不能再写「点右上角连接」。
    private var emptyHintHeadline: String {
        if let selectedRoleID = controller.selectedRoleID,
           let role = controller.rolePresets.first(where: { $0.id == selectedRoleID }) {
            return "已选中「\(role.name)」，点它右边的「连接」开始"
        }
        return "点左侧一个角色，再点它右边的「连接」"
    }

    // MARK: - Composer

    /// One text field, nothing else. The 「语音」 state badge that used to sit to
    /// the left is gone (the user's 「右侧下方只有一个输入框」) and so is the send
    /// button that used to sit to the right (「三个页面都删掉右侧底部的发送按
    /// 钮」). Return sends; while the session is down `submitComposerDraft`
    /// declines and the draft is kept, so nothing written before connecting is
    /// swallowed (the placeholder says why).
    private var composerRow: some View {
        MessageComposerField(
            placeholder: composerPlaceholder,
            draft: $composerDraft,
            isFocused: $composerFieldIsFocused,
            height: composerHeight,
            isExpanded: isComposerExpanded,
            canToggleExpansion: contentColumnHeight > 0,
            onToggleExpansion: { isComposerExpanded.toggle() },
            onSubmit: submitComposerDraft
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

    /// Connected: an input. Idle: the reason nothing can be typed yet.
    private var composerPlaceholder: String {
        controller.connectionPhase == .connected ? "输入文字，回车发送…" : "连接后可打字发送"
    }

    private var composerDraftIsEmpty: Bool {
        composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Typing is only worth sending while the session is up. The field stays
    /// enabled either way — a draft written before connecting is kept, not
    /// swallowed, which is what the old unconditional clear used to do.
    private var canSubmitComposerDraft: Bool {
        !composerDraftIsEmpty && controller.connectionPhase == .connected
    }

    private func submitComposerDraft() {
        guard canSubmitComposerDraft else { return }
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

    /// The user's line, with its copy control underneath — flush with the
    /// bubble's trailing edge. Both bubbles in this column carry one (the user
    /// asked for their own words and the assistant's replies to be copyable
    /// here).
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

            MessageCopyButton(text: text, helpText: "复制这条回复")
        }
    }
}
