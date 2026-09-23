//
//  NotchHomeView.swift
//  leanring-buddy
//
//  The notch sheet's conversation home, drawn to HeyClicky's reference
//  screenshot: with nothing in the session yet, the hero is *centered* — the
//  big greeting and the hint line. Once the session has turns, the hero gives
//  way to the conversation flow.
//
//  The composer at the bottom accepts BOTH input forms the original accepts:
//  voice (the glossy 「按住 ⌃⌥ 说话」 pill — talking is still push-to-talk)
//  and keyboard (the 「输入…」 field, Return submits through
//  `CompanionManager.submitTypedQuestion`). While a job runs, its question
//  shows as the outgoing bubble (`pendingQuestionText` — the history entry is
//  only written when the turn finishes) and its executed steps fold into a
//  「N 条进度」 disclosure (HeyClicky's progress messages). A turn the user
//  stopped shows an 「已被用户打断」 chip; a finished turn shows a duration +
//  time footer with a copy button.
//

import SwiftUI

struct NotchHomeView: View {

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var sessionsModel: ConversationSessionsModel

    /// Which finished turns have their progress disclosure expanded. Keyed by
    /// entry offset; live progress while a job runs is always expanded.
    @State private var expandedProgressOffsets: Set<Int> = []

    @FocusState private var composerFieldIsFocused: Bool
    @State private var composerDraft: String = ""

    /// The reply-card theme (对话与记忆 → 卡片样式). Snapshotted into state
    /// so a settings save (`.clickyAppSettingsChanged`) re-renders the flow's
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

            // 「松开发送」 — the original's caption while the talk key is held.
            // Recognition has not returned this press's final transcript yet,
            // so the only honest message is about the key, not the words.
            if companionManager.voiceState == .listening {
                Text("松开发送")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
            }
        }
    }

    private var isEmptySession: Bool {
        let entries = sessionsModel.activeSession?.entries ?? []
        return entries.isEmpty
            && companionManager.streamingAnswerText.isEmpty
            && companionManager.pendingQuestionText == nil
    }

    // MARK: - Empty-session hero

    /// 原版主页的居中构图：大字号问候和按住说话的提示。语音胶囊在底部
    /// 输入行里——原版主页也是这样，问候居中、输入行贴底。
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
    /// HeyClicky's "Afternoon, AA." pattern.
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
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
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
                        turnView(entryIndex, entry)
                            .id("entry-\(entryIndex)")
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
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .onChange(of: entries.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: companionManager.streamingAnswerText) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: companionManager.liveJobProgressSteps.count) { _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clickyAppSettingsChanged)) { _ in
                answerCardStyle = AppSettingsStore.snapshot().answerCardStyle
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("streaming", anchor: .bottom)
        }
    }

    /// One turn: the user's bubble, the assistant's reply, and what happened
    /// in between — the progress disclosure, the interrupted chip, and the
    /// duration footer.
    @ViewBuilder
    private func turnView(_ entryIndex: Int, _ entry: ConversationHistoryEntry) -> some View {
        outgoingBubble(entry.userTranscript)

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

    /// HeyClicky's progress messages: the executed steps of a multi-step job,
    /// folded behind a 「N 条进度」 toggle. Visual-only data — these are the
    /// same descriptions the panel's 上一次动手 row shows.
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
    /// 底角收到 5pt。用户气泡收右下、Clicky 气泡收左下，两种气泡的
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

    /// The user's words: the reference page's solid-accent bubble on the right
    /// (`#0A84FF`, white text) — 2026-09-23 UI 化改造 replaced the violet
    /// gradient.
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

    /// Clicky's reply: the card themed by 对话与记忆 → 卡片样式 (blue is the
    /// default; black and paper are the other two), replacing the old
    /// translucent dark bubble. The streaming reply renders with the card's
    /// blur-focus per-character animation; a finished reply renders as one
    /// plain Text inside the same card. See AnswerCardView.
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

    /// HeyClicky's turn footer: how long the job took and when it finished,
    /// with a copy button — or the interrupted chip when the user stopped it.
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
            } else if let durationSeconds = entry.turnDurationSeconds {
                Text(Self.footerDurationText(durationSeconds: durationSeconds, finishedAt: entry.turnFinishedAt))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }

            Button(action: { copyToPasteboard(entry.assistantResponse) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("复制回答")

            Spacer(minLength: 0)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// "23s · 21:59" — seconds when short, minutes when long; the finish time
    /// only when the turn carries one (older entries never will).
    private static func footerDurationText(durationSeconds: Int, finishedAt: Date?) -> String {
        let durationPart: String
        if durationSeconds < 60 {
            durationPart = "\(durationSeconds)s"
        } else {
            durationPart = "\(durationSeconds / 60)m\(durationSeconds % 60)s"
        }

        guard let finishedAt else { return durationPart }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(durationPart) · \(formatter.string(from: finishedAt))"
    }

    // MARK: - Composer (voice + keyboard)

    /// The bottom row the original always shows: the mascot sitting on the
    /// glossy 「按住 ⌃⌥ 说话」 pill (voice, push-to-talk) and, beside it, a
    /// separate text field pill (Return submits).
    private var composerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            voicePill

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
            .help("发送")
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var composerDraftIsEmpty: Bool {
        composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitComposerDraft() {
        guard !composerDraftIsEmpty else { return }
        companionManager.submitTypedQuestion(composerDraft)
        composerDraft = ""
        composerFieldIsFocused = false
    }

    /// The glossy 「按住 ⌃⌥ 说话」 pill (voice, push-to-talk). The mascot that
    /// used to sit on its left end is gone with the hero's — the user wants
    /// the characters only in the sidebar's session list, and the pill's
    /// waveform icon already says what it does.
    private var voicePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(red: 0.25, green: 0.45, blue: 0.90))
            Text("按住 ⌃⌥ 说话")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(red: 0.12, green: 0.15, blue: 0.25))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.98, blue: 1.0),
                        Color(red: 0.88, green: 0.91, blue: 0.97)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
    }

    private var composerField: some View {
        HStack(spacing: 6) {
            TextField("输入问题，回车发送…", text: $composerDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($composerFieldIsFocused)
                .onSubmit(submitComposerDraft)

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
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule().strokeBorder(
                composerFieldIsFocused ? Color.white.opacity(0.25) : Color.white.opacity(0.1),
                lineWidth: 0.5
            )
        )
    }

    /// The conversation view shows what the user hears, not the tags the
    /// executor reads — the same split the spoken answer makes. [POINT:…] and
    /// friends are stripped for display only; the stored entry keeps them.
    private func stripActionTagsForDisplay(_ text: String) -> String {
        // Tags look like [NAME:...] — drop everything from the opening
        // bracket to the closing one. Simple regex on a display copy only.
        return text.replacingOccurrences(
            of: "\\[[A-Z_]+:[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
