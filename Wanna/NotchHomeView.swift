//
//  NotchHomeView.swift
//  Wanna
//
//  The notch sheet's conversation home, drawn to the reference screenshot:
//  with nothing in the session yet, the hero is *centered* — the
//  big greeting and the hint line. Once the session has turns, the hero gives
//  way to the conversation flow.
//
//  The composer at the bottom is keyboard-only now — the glossy
//  「按住 ⌃⌥ 说话」 pill was deleted on 2026-09-23 at the user's request
//  (「右侧下方只有一个输入框」); talking is still push-to-talk, and the
//  shortcut is spelled out in the empty-session hero and on the 快捷键 page.
//  Return submits through `CompanionManager.submitTypedQuestion`, and the
//  field carries its own 展开 button (30% of the column). While a job runs, its
//  question shows as the outgoing bubble (`pendingQuestionText` — the history
//  entry is only written when the turn finishes) and its executed steps fold
//  into a 「N 条进度」 disclosure. A turn the
//  user stopped shows an 「已被用户打断」 chip; a finished turn shows a duration
//  + time footer beside its copy button. Every message carries a copy control
//  of its own and can be selected with the mouse.
//

import SwiftUI

struct NotchHomeView: View {

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var sessionsModel: ConversationSessionsModel
    /// Ask 页自己的全双工语音管线（页内的实时转录与状态芯片都读它）。

    /// Which finished turns have their progress disclosure expanded. Keyed by
    /// entry offset; live progress while a job runs is always expanded.
    @State private var expandedProgressOffsets: Set<Int> = []

    @State private var composerFieldIsFocused = false
    @State private var composerDraft: String = ""

    /// The composer's 展开 button (user's request): the field grows to 30% of
    /// the content column's height and collapses back to three lines.
    @State private var isComposerExpanded = false
    /// The content column's height, measured off the root view. The expansion
    /// is 30% of *this*, so it has to be a real measurement rather than a
    /// constant — the sheet's height is the user's own (they can drag its
    /// bottom edge), and a fixed expanded height would be a different fraction
    /// on every screen.
    @State private var contentColumnHeight: CGFloat = 0

    /// The reply-card theme (设置 → 交互样式). Snapshotted into state
    /// so a settings save (`.wannaAppSettingsChanged`) re-renders the flow's
    /// cards without waiting for some other published change to trigger it.
    @State private var answerCardStyle: AnswerCardStyle = AppSettingsStore.snapshot().answerCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmptySession {
                emptySessionHero
            } else {
                statusStrip
                conversationFlow
            }

            // **静音开关**（用户 2026-09-25：「把声音按钮移到用户输入框的右下角，
            // 减少空间占用。现在用户发送提示词后，声音按钮会挡住提示词……做成只有
            // 一个图标、没有文字的按钮，可以稍微大一点」）。
            //
            // 它曾经是输入框**上方独立的一行**，而那一行与输入框之间只有 10 pt ——
            // 提示词一长就从输入框里往上顶，正好钻到那一行底下被盖住。现在它作为
            // 输入框自己的右下角附加按钮渲染（`MessageComposerField.composerAccessory`），
            // 不再占任何额外高度，也不可能盖住文字。
            //
            // **两种情况**（用户 2026-09-25）：
            //   1. 提示词还没发送 / AI 还没开始说话 —— 点它就只是关设置，
            //      下一条回复的门禁在发送前读它，整条合成根本不会发生。
            //   2. 回复已经开始合成/播放 —— 点它除了关设置，还立刻停掉这一条
            //      的声音（已合成的收不回，但不再播，剩余段也不再合成），
            //      并且下一次自动静音。
            // 两条情况走同一个动作：先翻转设置，再让 manager 停这一条 ——
            // `silenceActiveReplyAudio` 的门禁是「这一条回复还在跑（或还在播）」，
            // 情况 1 下两者都不成立，它是 no-op。
            composerRow

            // The last error's verbatim API text. The deleted menu bar panel
            // used to be the only place it showed; with the panel gone the
            // spoken apology must not be the only failure report. A tap
            // clears it — it would otherwise sit here until the next
            // model-configuration save.
            if let errorMessage = companionManager.lastErrorMessage {
                Button(action: { companionManager.clearLastErrorMessage() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(errorMessage)
                            .font(.system(size: 11.5))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.red.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("点击隐藏")
            }

            // 「松开发送」提示行已删（用户 2026-09-25：「右侧底部输入框下面总是
            // 多出一行文字，把输入框往上顶了一下」）。 listening 相位在刘海带子
            // 上本来就有动画，这里不需要重复一份还会顶布局的说明文字。
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A click anywhere in the column puts the caret in the composer — the
        // **点击右侧任意位置不再自动聚焦输入框**（用户 2026-09-25 放弃这条逻辑）。
        //
        // 它原先是个功能（2026-09-23 的「点右侧任意位置就能直接输入」），但反复
        // 引发同一个偶发故障：焦点被这条路径抢走之后打不进字、或刚打好的字被清掉，
        // 切到别的分区再回来点一下又会把字吸走。修了近十次都没真正解决，用户的判断
        // 是「放弃这个逻辑」——点内容区就是点内容区，要点输入框就点输入框。
        //
        // 注意这与「点输入框本身要能聚焦」是两条不同的路径：后者由
        // `MessageComposerField` 的 responder 桥负责（`becomeFirstResponder` /
        // `resignFirstResponder`），不要跟着一起删。
        .background(
            // Measures the column the composer expands against. Taken off the
            // column's own frame (which the parent bounds) rather than off a
            // scroll view's content, so growing the composer can never feed
            // its own measurement back in.
            GeometryReader { geometryProxy in
                Color.clear
                    .onAppear { contentColumnHeight = geometryProxy.size.height }
                    .onChange(of: geometryProxy.size.height) { _, newHeight in
                        contentColumnHeight = newHeight
                    }
            }
        )
    }

    private var isEmptySession: Bool {
        let entries = sessionsModel.activeSession?.entries ?? []
        return entries.isEmpty
            && companionManager.streamingAnswerText.isEmpty
            && companionManager.pendingQuestionText == nil
    }

    // MARK: - Empty-session hero

    /// 原版主页的居中构图：大字号问候和按住说话的提示。提示行是现在唯一
    /// 写着 ⌃⌥ 的地方——底部那颗「按住 ⌃⌥ 说话」胶囊 2026-09-23 按用户的
    /// 要求删掉了（右侧下方只留一个输入框）。
    /// 右侧不再放小人了（用户的要求：小人只在左侧会话列表里出现），
    /// 空会话主页就剩问候和提示两行。
    private var emptySessionHero: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)

            Text(Self.timeBasedGreeting())
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)

            Text("按住 Control + Option，或直接在下面打字。")
                .font(.system(size: 13.5))
                .foregroundColor(.white.opacity(0.55))

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    /// A greeting for the time of day, with the local account's first name —
    /// the "Afternoon, AA." pattern.
    private static func timeBasedGreeting() -> String {
        let dayPart: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: dayPart = "早上好"
        case 11..<13: dayPart = "中午好"
        case 13..<18: dayPart = "下午好"
        default: dayPart = "晚上好"
        }

        let fullName = NSFullUserName()
        let firstName = fullName.split(separator: " ").first.map(String.init) ?? fullName
        return firstName.isEmpty ? "\(dayPart)。" : "\(dayPart)，\(firstName)。"
    }

    // MARK: - Status strip

    /// What the companion is doing right now, one line above the flow.
    /// Idle hides the strip — nothing happening is not a status.
    @ViewBuilder
    private var statusStrip: some View {
        // RESERVES ITS SPACE WHEN HIDDEN, and that is the fix for the
        // conversation jumping when the panel opens.
        //
        // This strip sits ABOVE the scroll view, and it used to return nothing
        // while the voice state was `.idle` — so the moment a reply ended (or
        // the panel opened on an idle state) the capsule vanished, the scroll
        // view's available height grew by the strip's ~30 pt, and EVERY message
        // shifted up by that much at once. The user reads it as
        // 「所有消息整体向上抖动一下，然后又下来」. Rendering an invisible
        // placeholder of the same height keeps the column's geometry constant
        // no matter what the voice state is doing.
        Group {
            if let statusText = Self.statusText(for: companionManager.voiceState) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            } else {
                // Same capsule shape, fully transparent — same height, no
                // content.
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 6, height: 6)
                    Text(" ")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var statusColor: Color {
        switch companionManager.voiceState {
        case .listening: return .green
        case .processing: return .orange
        case .responding: return .blue
        case .idle: return .gray
        }
    }

    private static func statusText(for voiceState: CompanionVoiceState) -> String? {
        switch voiceState {
        case .idle: return nil
        case .listening: return "在听…"
        case .processing: return "在想…"
        case .responding: return "在说…"
        }
    }

    // MARK: - Conversation flow

    private var conversationFlow: some View {
        let entries = sessionsModel.activeSession?.entries ?? []

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { entryIndex, entry in
                        // 回答还没写下来的那一条不渲染空卡：它的内容此刻在下面的流式
                        // 气泡里（`streamingAnswerText`），回合结束写盘后这里自然恢复渲染。
                        if entryIndex == entries.count - 1,
                           entry.assistantResponse.isEmpty {
                            EmptyView()
                        } else {
                            turnView(entryIndex, entry)
                                .id("entry-\(entryIndex)")
                        }
                    }

                    // The question currently being answered shows as the
                    // outgoing bubble the moment the pipeline starts — the
                    // history entry is only written when the turn finishes.
                    if let pendingQuestion = companionManager.pendingQuestionText {
                        outgoingBubble(pendingQuestion)
                            .id("pending-question")
                        liveProgressDisclosure
                    }

                    // The answer currently streaming in, live under the last
                    // finished turn. Gated on the question still being pending:
                    // once the turn is recorded the flow renders it from
                    // history, and the live text (kept up on purpose through
                    // the TTS reading for the overlay bubble's sake) would
                    // paint the same reply a second time until the post-linger
                    // clear — the 「回复先出现两条再变一条」 the user reported
                    // 2026-09-22.
                    if companionManager.pendingQuestionText != nil,
                       !companionManager.streamingAnswerText.isEmpty {
                        assistantBubble(companionManager.streamingAnswerText, isStreaming: true)
                            .id("streaming")
                        // **底部那一行从第一秒就在这里**（用户 2026-09-25）。
                        //
                        // 它原先只在回合结束时画（由 `turnFooter(entry)` 承担），
                        // 于是流式期间这条流少一行；回合一旦落成条目，内容突然变高，
                        // 而这里是钉在底部的 —— 多余的高度把上面所有内容整体顶上去，
                        // 用户看到的就是「回复完成之后卡片会突然向上抖动一下／向上顶
                        // 一下」。把同一行提前画出来，高度从第一帧起就不再变化。
                        liveTurnFooter
                    }

                    // The scroll target, and the flow's bottom breathing room
                    // in one view. It is a *resident* view on purpose: the
                    // streaming ids above only exist while a reply is arriving,
                    // so scrolling to one of those did nothing when the user
                    // opened an old session or switched conversations — the
                    // user's 「点击某一个对话，都要自动定位到最下面的聊天记录」.
                    Color.clear
                        .frame(height: 16)
                        .id(Self.conversationBottomAnchorID)
                }
                .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
                .padding(.top, 4)
            }
            // Selection is enabled for the whole flow at once — the user asked
            // to be able to select part of a message or drag across one, and
            // the environment modifier covers every Text beneath it, the
            // reply card's per-character units included.
            .textSelection(.enabled)
            // 同上：这里原先也有一条「点流里任意位置聚焦输入框」，同样已按用户的
            // 决定删除。拖选不受影响（拖拽不是点击）。
            .onChange(of: entries.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: sessionsModel.activeSessionID) { _ in
                // Switching conversations has to land at the newest message,
                // and the new session's rows are laid out in the same update —
                // waiting one turn of the main loop is what makes the scroll
                // land on the final layout instead of the previous session's.
                scheduleScrollToBottom(proxy)
            }
            .thinWhiteScrollIndicator()
            .onChange(of: companionManager.streamingAnswerText) { _ in
                // 同上：流式期间瞬时滚动（每 delta 一次 0.2s 动画 = 动画永不停止）。
                scrollToBottomInstantly(proxy)
            }
            // **用户刚发出的那条也要滚进来。**
            //
            // 用户 2026-09-25：「用户发送提示词之后，它没有自动显示在输入框上面，
            // 而是被输入框遮挡了。无论是 AI 的消息还是用户的消息，都自动显示在
            // 输入框上面」。
            //
            // `pendingQuestionText` 是发出后**立刻**画出来的那条用户气泡（历史条目要
            // 等回合结束才写），而它原先**不在任何滚动触发里** —— 气泡出现了，流却
            // 停在原地，那条就留在可视区底边被裁掉。这是唯一一个"用户主动发出东西"
            // 的触发点，缺了它，发出去的第一眼永远看不全。
            .onChange(of: companionManager.pendingQuestionText) { _ in
                scrollToBottomInstantly(proxy)
            }
            .onChange(of: companionManager.liveJobProgressSteps.count) { _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottomInstantly(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: .wannaAppSettingsChanged)) { _ in
                answerCardStyle = AppSettingsStore.snapshot().answerCardStyle
            }
        }
    }

    /// The resident view the flow scrolls to. Named rather than inlined so the
    /// scroll target cannot drift away from the view that carries it.
    private static let conversationBottomAnchorID = "conversation-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.conversationBottomAnchorID, anchor: .bottom)
        }
    }

    /// The same scroll, without animation — the panel-open landing.
    ///
    /// A fresh `ScrollView` starts at offset 0, and the old onAppear ran the
    /// ANIMATED scroll: the whole list slid up over 0.2 s while the panel was
    /// still revealing. Worse, that animated target then fought the other
    /// movers in the same window (the entrance slide, the cards' first-frame
    /// re-measure), and the scroll's 0.2 s hard stop against their longer runs
    /// read as a bounce. Landing instantly means the content is already at the
    /// bottom BEFORE the entrance makes any of it visible (~115 ms in at 2×),
    /// so nothing the eye can see moves except the entrance itself. Content
    /// changes keep the animated scroll — those are real new content arriving.
    private func scrollToBottomInstantly(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.conversationBottomAnchorID, anchor: .bottom)
    }

    /// One turn of the main loop later, then scroll. Used when the thing that
    /// changed is the *session* rather than its content: the new rows are part
    /// of the same render pass, and a scroll issued before that pass lays out
    /// measures the old content.
    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            scrollToBottom(proxy)
        }
    }

    /// One turn: the user's bubble, the assistant's reply, and what happened
    /// in between — the progress disclosure, the interrupted chip, and the
    /// duration footer.
    @ViewBuilder
    private func turnView(_ entryIndex: Int, _ entry: ConversationHistoryEntry) -> some View {
        // **没有用户那句话的回合不画用户气泡。**
        //
        // 有些回合只有回答、没有用户那句话（`userTranscript` 是空串）——无条件画就会
        // 在流里留一个空的蓝色气泡。
        if !entry.userTranscript.isEmpty {
            outgoingBubble(entry.userTranscript)
        }

        if let progressSteps = entry.progressSteps, !progressSteps.isEmpty {
            progressDisclosure(
                steps: progressSteps,
                stepCount: progressSteps.count,
                isExpanded: Binding(
                    get: { expandedProgressOffsets.contains(entryIndex) },
                    set: { expanded in
                        if expanded {
                            expandedProgressOffsets.insert(entryIndex)
                        } else {
                            expandedProgressOffsets.remove(entryIndex)
                        }
                    }
                )
            )
        }

        assistantBubble(entry.assistantResponse, isStreaming: false)

        turnFooter(entry)
    }

    /// The job's steps so far, live while it runs. Always expanded — a
    /// progress list that has to be opened while its job is still moving
    /// hides exactly the thing the user asked to see.
    @ViewBuilder
    private var liveProgressDisclosure: some View {
        if !companionManager.liveJobProgressSteps.isEmpty {
            progressDisclosure(
                steps: companionManager.liveJobProgressSteps,
                stepCount: companionManager.liveJobProgressSteps.count,
                isExpanded: .constant(true)
            )
        }
    }

    /// 流式期间画的那一行底部信息 —— 与 `turnFooter(_:)` 同一套几何，所以
    /// 回合落成条目、这一行换成正式那条时，位置与高度都不变。
    ///
    /// **只画复制与时间**（用户 2026-09-25：「同时出现的时候，只显示复制按钮和时间」）。
    /// 耗时此刻还算不出来 —— 那要等回合结束 —— 所以这里不画它；它出现时是加在
    /// 同一行里，行高不变，因此不会把卡片顶上去。
    ///
    /// 时间取 `currentReplyReceivedAt`（回复第一个字节到达的那一秒），不是完成时刻。
    @ViewBuilder
    private var liveTurnFooter: some View {
        if let replyReceivedAt = companionManager.currentReplyReceivedAt {
            // 与 `turnFooter(_:)` **同一个顺序**（复制 · 时间 · 耗时），只是流式期间
            // 还没有耗时 —— 它加在同一行尾，行高不变，所以不会把卡片顶上去。
            HStack(spacing: 8) {
                MessageCopyButton(
                    text: companionManager.streamingAnswerText,
                    helpText: "复制这条回答"
                )

                Text(Self.cachedTimeFormatter.string(from: replyReceivedAt))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))

                Spacer(minLength: 0)
            }
        }
    }

    /// The executed steps of a multi-step job, folded behind a 「N 条进度」
    /// toggle. Visual-only data — these are the same descriptions the panel's
    /// 上一次动手 row shows.
    private func progressDisclosure(
        steps: [String],
        stepCount: Int,
        isExpanded: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { stepIndex, step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(stepIndex + 1).")
                                .font(.system(size: 11.5))
                                .foregroundColor(.white.opacity(0.4))
                            Text(step)
                                .font(.system(size: 11.5))
                                .foregroundColor(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("\(stepCount) 条进度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.26))
            )

            Spacer(minLength: 48)
        }
    }

    /// 两种对话气泡共用的圆角几何：三个角 16pt 圆角，靠近说话人的那个
    /// 底角收到 5pt。用户气泡收右下、Wanna 气泡收左下，两种气泡的
    /// 圆角、内边距、字号完全一致，只有底色和贴边方向不同——一眼就能
    /// 分清谁在说，又读得像同一套东西。
    private func bubbleShape(isOutgoing: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Self.bubbleCornerRadius,
            bottomLeadingRadius: isOutgoing ? Self.bubbleCornerRadius : Self.bubbleTailCornerRadius,
            bottomTrailingRadius: isOutgoing ? Self.bubbleTailCornerRadius : Self.bubbleCornerRadius,
            topTrailingRadius: Self.bubbleCornerRadius,
            style: .continuous
        )
    }

    // 参考页 `.unit.user` 的气泡几何：圆角 14，右下（尾巴角）4。
    private static let bubbleCornerRadius: CGFloat = 14
    private static let bubbleTailCornerRadius: CGFloat = 4

    /// The user's words: a dark bubble on the right, brighter than Wanna's
    /// dark card so the two sides are told apart by shade as well as by side.
    /// It replaced the reference page's solid-accent `#0A84FF` fill on
    /// 2026-09-23 at the user's request (「气泡调成暗色，但区分用户和 AI，
    /// 三个页面全部暗色，主题跟背景一致」). See `DS.Colors.userBubbleFill`.
    /// The copy control sits under it, flush with the bubble's trailing edge —
    /// the same placement the Agent and 语音聊天 columns use.
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

    /// Wanna's reply: the card themed by 设置 → 交互样式. The default is
    /// 「黑」 since 2026-09-23 (the user's 「不需要蓝色，主题应该跟背景颜色一
    /// 致」 changed it from the blue reference default; 蓝 and 宣纸 remain
    /// available in that page), replacing the old translucent dark bubble.
    /// The streaming reply renders with the card's blur-focus per-character
    /// animation; a finished reply renders as one plain Text inside the same
    /// card. See AnswerCardView.
    private func assistantBubble(_ text: String, isStreaming: Bool) -> some View {
        HStack(alignment: .top) {
            AnswerCardView(
                text: stripActionTagsForDisplay(text),
                isStreaming: isStreaming,
                style: answerCardStyle
            )
            Spacer(minLength: 56)
        }
    }

    /// The turn footer, in the order the user asked for (2026-09-25):
    /// 「把复制按钮放在最左侧，也就是回复卡片的下面；右边是时间，最右边是耗时，
    /// 按照这个顺序排列」—— **复制 · 时间 · 耗时**，从左到右。
    ///
    /// 原先顺序是反的（时间在前、复制在后），且时间与耗时挤在一段字符串里
    /// （`"3s · 12:24"`），所以这里把它们拆成两个 `Text` —— 顺序是用户定的，
    /// 拼成一个字符串就没法再排。
    @ViewBuilder
    private func turnFooter(_ entry: ConversationHistoryEntry) -> some View {
        HStack(spacing: 8) {
            if entry.wasInterrupted == true {
                Text("已被用户打断")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.42))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color(red: 1.0, green: 0.72, blue: 0.42).opacity(0.14))
                    )
            }

            // 所见即所得：复制的是卡片里显示的那份文字，不是存储原文。
            // 存储的 `assistantResponse` 还带着 `[POINT:…]` / `[CLICK:…]`
            // 这些执行器标签，粘到别处只会是噪声。
            MessageCopyButton(
                text: stripActionTagsForDisplay(entry.assistantResponse),
                helpText: "复制这条回答"
            )

            // 时间：取**收到回复的那一秒**，与流式期间 `liveTurnFooter` 画的同一个值
            // —— 否则回合落成条目的一瞬间这一行会跳一下。
            if let receivedAt = entry.replyReceivedAt ?? entry.turnFinishedAt {
                Text(Self.cachedTimeFormatter.string(from: receivedAt))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }

            // 耗时：只有回合结束才知道，所以它在最右、也最后出现。
            if let durationSeconds = entry.turnDurationSeconds {
                Text(Self.footerDurationText(durationSeconds: durationSeconds))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer(minLength: 0)
        }
    }

    /// "23s · 21:59" — seconds when short, minutes when long; the finish time
    /// only when the turn carries one (older entries never will).
    /// `DateFormatter` 创建/配置很贵，而 footer 会对每个带时间戳的历史条目、
    /// 每次 body 求值（流式期间 = 每个文字 delta）调用一次 —— 缓存一个终身复用。
    private static let cachedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "23s" / "2m5s" — **只有耗时**，时钟由调用方单独画。
    ///
    /// 它原先返回 `"23s · 21:59"`，把两个量拼成一个字符串；用户 2026-09-25 定的
    /// 顺序是「复制 · 时间 · 耗时」，拼在一起就没法再排，所以拆开了。
    private static func footerDurationText(durationSeconds: Int) -> String {
        if durationSeconds < 60 {
            return "\(durationSeconds)s"
        }
        return "\(durationSeconds / 60)m\(durationSeconds % 60)s"
    }

    // MARK: - Composer (keyboard; talking is still push-to-talk)

    /// The bottom row: one text field, nothing else. The glossy
    /// 「按住 ⌃⌥ 说话」 pill that used to sit to the left is gone — the user
    /// asked for 「右侧下方只有一个输入框」, and the shortcut itself is what
    /// starts a recording, so a badge repeating it earned no space. The send
    /// button that used to sit to the right went the same way on 2026-09-23
    /// (「三个页面都删掉右侧底部的发送按钮」) — Return sends. The shortcut is
    /// still spelled out in the empty-session hero.
    private var composerRow: some View {
        MessageComposerField(
            placeholder: "输入问题，回车发送…",
            draft: $composerDraft,
            isFocused: $composerFieldIsFocused,
            height: composerHeight,
            isExpanded: isComposerExpanded,
            canToggleExpansion: contentColumnHeight > 0,
            onToggleExpansion: { isComposerExpanded.toggle() },
            onSubmit: submitComposerDraft,
            // 「正在回复」 is the same pair of states the cursor's spinner is
            // drawn for, so the stop button turns red exactly while the user is
            // watching it work.
            isResponding: companionManager.voiceState == .processing
                || companionManager.voiceState == .responding,
            onStop: { companionManager.interruptActiveResponse() },
            // 右下角常驻的静音开关 —— 它是输入框自己的一部分，不再是上面一行。
            composerAccessory: ComposerAccessoryButton(
                systemImageName: companionManager.voiceReplyMuted
                    ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tint: companionManager.voiceReplyMuted
                    ? Color(red: 1.0, green: 0.42, blue: 0.42) : .white,
                helpText: companionManager.voiceReplyMuted
                    ? "已静音：回复只显示文字（点击恢复朗读）"
                    : "正在朗读回复（点击静音，只显示文字）",
                action: {
                    companionManager.voiceReplyMuted.toggle()
                    if companionManager.voiceReplyMuted {
                        companionManager.silenceActiveReplyAudio()
                    }
                }
            )
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

    private func submitComposerDraft() {
        guard !composerDraftIsEmpty else { return }
        companionManager.submitTypedQuestion(composerDraft)
        composerDraft = ""
        composerFieldIsFocused = false
    }

    /// The conversation view shows what the user hears, not the tags the
    /// executor reads — the same split the spoken answer makes. [POINT:…] and
    /// friends are stripped for display only; the stored entry keeps them.
    ///
    /// **结果按输入文本缓存**（2026-09-25 性能修复）：这个函数在 Ask 页的 body 里
    /// 对**每条历史 entry** 调用（有的地方一帧两次），而 body 在流式回答期间
    /// **每个文字 delta 都重算一次** —— 原先每条历史每帧都做一次正则 + 全文替换。
    /// 历史条目的文本不可变，结果必然相同，用内存字典缓存后只有流式中的那条
    /// 真正计算。
    private static let actionTagStripCacheLock = NSLock()
    private static var actionTagStripCache: [String: String] = [:]

    private func stripActionTagsForDisplay(_ text: String) -> String {
        Self.actionTagStripCacheLock.lock()
        if let cached = Self.actionTagStripCache[text] {
            Self.actionTagStripCacheLock.unlock()
            return cached
        }
        Self.actionTagStripCacheLock.unlock()

        // Tags look like [NAME:...] — drop everything from the opening
        // bracket to the closing one. Simple regex on a display copy only.
        let stripped = text.replacingOccurrences(
            of: "\\[[A-Z_]+:[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        // 缓存上限保护：足够覆盖最长会话的全部条目，超了就清（历史不可变，
        // 重建的也只是重复计算一次）。
        Self.actionTagStripCacheLock.lock()
        if Self.actionTagStripCache.count > 512 { Self.actionTagStripCache.removeAll() }
        Self.actionTagStripCache[text] = stripped
        Self.actionTagStripCacheLock.unlock()
        return stripped
    }
}
