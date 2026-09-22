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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmptySession {
                emptySessionHero
            } else {
                statusStrip
                conversationFlow
            }

            composerRow

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
    private var emptySessionHero: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)

            HomeHeroMascotPill()

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
                    // finished turn.
                    if !companionManager.streamingAnswerText.isEmpty {
                        assistantText(companionManager.streamingAnswerText)
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

        assistantText(entry.assistantResponse)

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
                    .fill(Color.white.opacity(0.05))
            )

            Spacer(minLength: 48)
        }
    }

    /// The user's words: a light-blue glossy bubble with a tail at its bottom
    /// right, dark navy text — the reference screenshot's outgoing shape.
    private func outgoingBubble(_ text: String) -> some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 56)

            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Color(red: 0.10, green: 0.16, blue: 0.32))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    OutgoingBubbleTailShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.82, green: 0.89, blue: 1.0),
                                    Color(red: 0.70, green: 0.81, blue: 0.99)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
    }

    /// The assistant speaks in plain text on the left — no bubble, matching
    /// the reference screenshot.
    private func assistantText(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(stripActionTagsForDisplay(text))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
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

    /// The mascot sitting on the glossy voice pill — the compact cousin of
    /// the empty-session hero's `HomeHeroMascotPill`.
    private var voicePill: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.25, green: 0.45, blue: 0.90))
                Text("按住 ⌃⌥ 说话")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.12, green: 0.15, blue: 0.25))
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)
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

            MascotAvatarDisc(identity: MascotRoster.homeHero, diameter: 26)
                .offset(x: -64, y: -8)
        }
        .padding(.top, 4)
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

/// The outgoing bubble's shape: a rounded rectangle whose bottom-right corner
/// carries a small tail — the speech-bubble silhouette of the reference
/// screenshot. Drawn as one shape so the fill and the tail are the same
/// material (a separate triangle would show a seam at the gradient).
struct OutgoingBubbleTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tailWidth: CGFloat = 10
        let tailHeight: CGFloat = 9
        let cornerRadius: CGFloat = 14

        var path = Path()
        let bodyRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(0, rect.height - tailHeight)
        )
        path.addRoundedRect(
            in: bodyRect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
            style: .continuous
        )

        // The tail: from the bubble's bottom edge near its right corner,
        // down to a point, then back up — flush with the body's bottom.
        let bodyBottom = bodyRect.maxY
        path.move(to: CGPoint(x: rect.maxX - tailWidth, y: bodyBottom))
        path.addLine(to: CGPoint(x: rect.maxX + 1, y: bodyBottom + tailHeight))
        path.addLine(to: CGPoint(x: rect.maxX + 1, y: bodyBottom))
        path.closeSubpath()
        return path
    }
}
