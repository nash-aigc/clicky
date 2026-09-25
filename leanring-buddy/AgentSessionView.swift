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

    /// 收起 / 重新展开整块面板。「打开」按钮的两半：选文件夹时面板必须让开，
    /// 选完再放回来（用户 2026-09-23 的第 7 条）。两个都是面板窗口控制器的
    /// 动作，由 `NotchSheetRootView` 一路传下来。
    var hideSheet: () -> Void = {}
    var revealSheet: () -> Void = {}

    @State private var composerFieldIsFocused = false
    @State private var composerDraft: String = ""

    /// The composer's 展开 button (user's request): the field grows to 30% of
    /// the content column and collapses back to three lines.
    @State private var isComposerExpanded = false
    /// The content column's height, measured off the root view — the sheet's
    /// height is the user's own (they can drag its bottom edge), so the 30%
    /// figure has to be measured rather than assumed.
    @State private var contentColumnHeight: CGFloat = 0

    /// 卡片主题（设置 → 交互）。与 Ask / Chatting 两页同一做法：快照进
    /// @State，保存设置时靠 `.clickyAppSettingsChanged` 重读。
    @State private var answerCardStyle: AnswerCardStyle = AppSettingsStore.snapshot().answerCardStyle

    var body: some View {
        if let agent = agentSessionManager.selectedAgent {
            VStack(spacing: 0) {
                agentHeader(agent)
                transcriptFlow(agent)
                errorLine
                composerRow(agent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 原先这里有一条「点右侧任意位置聚焦输入框」，已按用户的决定删除 ——
            // 与 Ask 页同一处收敛（见 `NotchHomeView` 里那段注释）。
            .onReceive(NotificationCenter.default.publisher(for: .clickyAppSettingsChanged)) { _ in
                answerCardStyle = AppSettingsStore.snapshot().answerCardStyle
            }
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

            // 「中断」在前、「打开」钉在最右（用户 2026-09-23：「把"打开"按钮放在
            // 最右侧」）。中断只在运行中出现，所以它出现/消失时挪动的是自己，
            // 打开始终在这一排的最右端，不会跟着左右跳。
            if agent.status == .running {
                Button(action: { agentSessionManager.interrupt(agent.id) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("中断")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, Self.headerButtonHorizontalPadding)
                    .frame(height: Self.headerButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Self.headerButtonCornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Self.headerButtonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("停止当前任务（对话历史保留，下次任务接着进行）")
            }

            // It opens a NEW agent rather than re-pointing this one, and the
            // help text says so, because that is not what "打开" alone implies
            // and the reason is real: the CLI files a thread under its cwd, so
            // moving an existing thread's folder would leave the model with no
            // memory of turns the panel still shows. See
            // `AgentSessionManager.openFolderAsNewAgent`.
            openFolderButton
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        // 页头整体占满 `contentColumnHeaderBandHeight`：这条栏的下边缘必须正好落在
        // 右列那条贯穿横线上，与对话页 / 语音聊天页同高（用户 2026-09-23：
        // 「每一个页面的右侧增加一条线…线上面是相关的参数部分」）。原来是内容底边距
        // 10，换成固定高度后由这条带自己决定内容的位置。
        .frame(height: NotchSupport.contentColumnHeaderBandHeight, alignment: .center)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
    }

    /// The header's 「打开」 control: pick a folder, then work in it.
    ///
    /// 「长方形加圆角，而不是胶囊」（用户 2026-09-23），与运行中出现的「中断」同一
    /// 套尺寸与圆角 —— 这一轮 UI 化改造本来就把按钮从胶囊换成了 10pt 圆角矩形
    /// （见 `DesignSystem`），这一排也跟上，两颗控件才会读成一组。
    private var openFolderButton: some View {
        Button(action: openFolderWithPicker) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text("打开")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, Self.headerButtonHorizontalPadding)
            .frame(height: Self.headerButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: Self.headerButtonCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.headerButtonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("选一个文件夹，为它新建一个 Agent 并切过去。已经跑过任务的 Agent 不能中途换文件夹——它的对话记忆是按目录存放的——所以这里是新开一个，原来那个连同历史都还在。")
    }

    /// 页头这两颗按钮共用的一把尺子：同样的高度、横向内边距、圆角。
    private static let headerButtonHeight: CGFloat = 26
    private static let headerButtonHorizontalPadding: CGFloat = 11
    private static let headerButtonCornerRadius: CGFloat = DS.CornerRadius.medium

    /// Folder picker for 「打开」 —— and why it hides the sheet first.
    ///
    /// 收起是用户点名的做法（2026-09-23：「用户点击"打开"按钮之后，整个弹窗直接
    /// 缩回去，就是隐藏一下，要不然用户没有办法去点击选择哪一个文件夹」）：展开的
    /// 面板是 810×821、从屏幕最上沿垂下来的一大块，系统选文件夹的对话框正好落在
    /// 它下面。
    ///
    /// **等收起动画走完再开对话框**，不能紧接着调用：`runModal()` 进去就一直占住
    /// 这一帧直到用户选完，紧挨着调用的话，用户看到的不是"面板缩回去、然后选文件
    /// 夹"，而是"面板还在原地、上面盖了个对话框"。收起用
    /// `centerScaleCollapseDuration`(0.16s)，这里多等 0.1s 让它真的收干净。选完
    /// （或取消）再把面板放回来 —— 说的是「隐藏**一下**」，取消也要还原，否则用户
    /// 点个取消、面板却没了。
    ///
    /// `NSApp.activate()` first and `modalFileDialogWindowLevel` on the panel
    /// are both load-bearing, and both for the same reason as the sidebar's ＋:
    /// this is an `LSUIElement` app whose only window is a panel floating above
    /// the menu bar, so a modal file dialog appears behind it and takes no
    /// clicks unless it is explicitly put in front. The user reported exactly
    /// that for the ＋ button (「悬浮窗口会遮盖文件夹选择弹窗，导致用户无法选择
    /// 文件夹」); this button would have had it too.
    private func openFolderWithPicker() {
        hideSheet()

        DispatchQueue.main.asyncAfter(deadline: .now() + NotchSupport.centerScaleCollapseDuration + 0.1) {
            NSApp.activate()

            let folderPicker = NSOpenPanel()
            folderPicker.canChooseDirectories = true
            folderPicker.canChooseFiles = false
            folderPicker.allowsMultipleSelection = false
            folderPicker.canCreateDirectories = true
            folderPicker.level = NotchSupport.modalFileDialogWindowLevel
            folderPicker.message = "选择一个文件夹，为它新建一个 Agent"
            folderPicker.prompt = "打开"
            if let defaultFolderPath = AppSettingsStore.snapshot().agentDefaultProjectFolder {
                folderPicker.directoryURL = URL(fileURLWithPath: defaultFolderPath)
            }

            let didConfirm = folderPicker.runModal() == .OK
            if didConfirm, let pickedURL = folderPicker.url {
                agentSessionManager.openFolderAsNewAgent(folderPath: pickedURL.path)
            }

            revealSheet()
        }
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

                    ForEach(transcriptRows(for: agent)) { row in
                        switch row {
                        case .message(let entry):
                            messageRow(for: entry)
                        case .toolRun(let groupID, let toolEntries):
                            ToolActivityGroupView(
                                entries: toolEntries,
                                isAgentRunning: agent.status == .running
                            )
                            .id(groupID)
                        }
                    }

                    if agent.status == .running {
                        if !streamingText.isEmpty {
                            assistantBubble(streamingText, isStreaming: true)
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
            // …点流里任意位置聚焦输入框那一条已删除（同 Ask 页）。
            .onChange(of: agent.transcript.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: streamingText) { _, _ in
                // 流式期间瞬时滚动（每 delta 一次 0.2s 动画 = 动画永不停止，
                // 每帧都带着正在变大的内容重新定位 —— 与 Ask 页同一处收敛）。
                scrollToBottomInstantly(proxy)
            }
            .onChange(of: agentSessionManager.selectedAgentID) { _, _ in
                // One turn of the main loop later: the newly selected agent's
                // transcript is part of the same render pass, and scrolling
                // before that pass lays out measures the previous agent's rows.
                scheduleScrollToBottom(proxy)
            }
            .thinWhiteScrollIndicator()
            .onAppear {
                // **展开面板时不许有滑动。**
                //
                // 用户 2026-09-25：「点击展开之后，为什么会向上移动、抖动一下，从下面
                // 向上移动到当前位置？它会有一个移动的过程。」——那一步原来是
                // `scrollToBottom`（**带动画 0.2 秒**），于是内容从下方滑上来；用户在
                // 视频里看到的正是它。
                //
                // 换成瞬时：位置一样落在最新，但**没有移动过程** —— 走的是 Screen 页
                // 一直用的那个（`NotchHomeView` 的 onAppear 本来就是 Instantly）。
                //
                // 为什么不能"保留用户上次的位置"：这棵树**每次展开都会被销毁重建**
                // （`NotchPanelRootSwitchingView` 里是 `if isExpanded`），滚动位置随树
                // 一起没了。要真保留位置，得让树常驻 —— 那条路戳出窗口画了个黑框，已回退。
                scrollToBottomInstantly(proxy)
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

    /// 流式期间用的瞬时滚动：带动画的版本 0.2s 长于 delta 间隔，动画在整段
    /// 流式期间永远处于「被改目标」状态，每一帧都带着正在变大的内容重新定位。
    private func scrollToBottomInstantly(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
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

    /// A user or assistant message. Tool activity never reaches here — see
    /// `transcriptRows(for:)`.
    @ViewBuilder
    private func messageRow(for entry: AgentTranscriptEntry) -> some View {
        switch entry.kind {
        case .userMessage:
            outgoingBubble(entry.text)
                .id(entry.id)
        case .assistantMessage:
            assistantBubble(entry.text)
                .id(entry.id)
        case .toolActivity:
            // Unreachable by construction: `transcriptRows(for:)` folds every
            // run of tool activity into a `.toolRun` row, so no `.message` row
            // can carry that kind. Spelled out rather than defaulted so a new
            // kind added later is a compile error, not a silently dropped line.
            EmptyView()
        }
    }

    /// The transcript as *display* rows: consecutive tool-activity entries
    /// collapsed into one `.toolRun`.
    ///
    /// The transcript itself is untouched — one entry per tool invocation is what
    /// the model's own record and `lastPreview` are built from — and this is a
    /// second, view-only reading of it. Grouping has to happen here rather than
    /// inside the row view, because "was the entry before this one also tool
    /// activity" is a question about the whole array, which a row cannot answer.
    private func transcriptRows(for agent: AgentSession) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var pendingToolEntries: [AgentTranscriptEntry] = []

        func flushPendingToolEntries() {
            guard let firstPendingEntry = pendingToolEntries.first else { return }
            // The group's id is its FIRST entry's id: the ids inside a group all
            // change as the run grows, so keying the view off the first one keeps
            // its identity (and the user's expansion of it) stable for the whole
            // run instead of rebuilding it on every new tool call.
            rows.append(.toolRun(id: firstPendingEntry.id, entries: pendingToolEntries))
            pendingToolEntries = []
        }

        for entry in agent.transcript {
            switch entry.kind {
            case .toolActivity:
                pendingToolEntries.append(entry)
            case .userMessage, .assistantMessage:
                flushPendingToolEntries()
                rows.append(.message(entry))
            }
        }
        flushPendingToolEntries()
        return rows
    }

    /// One display row of the transcript flow.
    private enum TranscriptRow: Identifiable {
        case message(AgentTranscriptEntry)
        case toolRun(id: UUID, entries: [AgentTranscriptEntry])

        var id: UUID {
            switch self {
            case .message(let entry): return entry.id
            case .toolRun(let groupID, _): return groupID
            }
        }
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
            onSubmit: submitComposerDraft(agent),
            // Red exactly while THIS agent's turn is in flight — the same test
            // `interrupt(_:)` guards on, so the button can never be live for a
            // turn there is nothing to stop.
            isResponding: agent.status == .running,
            onStop: { agentSessionManager.interrupt(agent.id) }
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

    /// Agent 回复用 Ask 页同一张卡（`AnswerCardView`，blur-focus 逐字动画）
    /// —— 用户 2026-09-25：「这个卡片的样式才是我真正需要的渲染效果」，要求
    /// 应用到 Agent 和 Chatting 两页。正在流式的那条拿 `isStreaming: true`，
    /// 历史条目整段显示。Agent 的文字来自 CLI、不带 `[POINT:]` 一类执行标签，
    /// 所以这里不需要 Ask 页那层 strip。
    private func assistantBubble(_ text: String, isStreaming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                AnswerCardView(
                    text: text,
                    isStreaming: isStreaming,
                    style: answerCardStyle
                )
                Spacer(minLength: 56)
            }

            MessageCopyButton(text: text, helpText: "复制 Agent 的回复")
        }
    }
}

/// One run of consecutive tool invocations, drawn as a single collapsible block.
///
/// The user's spec (2026-09-23) is three clauses in one breath: 「调用过程中可以显示，
/// 但最多显示两行，之前的调用内容自动隐藏；用户点击折叠按钮可以展开。正常情况下工
/// 作时最多显示两行，即最新的工具调用；所有工具调用完成后自动折叠成一行，以简化页
/// 面显示」. That is one rule about the *collapsed* shape plus the user's own right to
/// open the block up, so the two are kept apart here:
///
/// - How many lines a collapsed block shows is **derived from the agent's status**,
///   never stored: the two newest while tool calls are still arriving, none once the
///   run has landed — which is what makes a finished block exactly one line (its
///   header). A finished turn therefore leaves one row in the transcript where there
///   used to be one row per invocation.
/// - `isExpandedByUser` records only a deliberate expansion, and nothing ever clears
///   it. Auto-collapsing a block the user opened to read would take the text away
///   from them at the exact moment the turn ended; the status change is not evidence
///   they are done reading.
///
/// The header is both the label and the fold control, so the block is never a pile of
/// unlabeled grey text with a mystery chevron floating beside it.
private struct ToolActivityGroupView: View {

    let entries: [AgentTranscriptEntry]

    /// Whether the agent is still working — what decides the collapsed shape.
    let isAgentRunning: Bool

    @State private var isExpandedByUser = false

    /// The newest entries, and only while work is in flight. Zero once the run has
    /// finished, because "所有工具调用完成后自动折叠成一行" means the header is then
    /// the whole block.
    private var collapsedVisibleEntries: [AgentTranscriptEntry] {
        guard isAgentRunning else { return [] }
        return Array(entries.suffix(2))
    }

    private var visibleEntries: [AgentTranscriptEntry] {
        isExpandedByUser ? entries : collapsedVisibleEntries
    }

    private var headerText: String {
        isAgentRunning ? "工具调用中…" : "\(entries.count) 次工具调用"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            ForEach(visibleEntries) { entry in
                toolActivityLine(entry.text)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .animation(.easeInOut(duration: 0.18), value: isExpandedByUser)
    }

    private var header: some View {
        Button {
            isExpandedByUser.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpandedByUser ? 90 : 0))

                Image(systemName: "hammer")
                    .font(.system(size: 9, weight: .semibold))

                Text(headerText)
                    .font(.system(size: 11))

                Spacer(minLength: 0)
            }
            .foregroundColor(.white.opacity(0.42))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(
            isExpandedByUser
                ? "收起工具调用"
                : "展开全部 \(entries.count) 次工具调用。平时只显示最新两条，一轮跑完折成一行。"
        )
    }

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
        .padding(.leading, 14)
    }
}
