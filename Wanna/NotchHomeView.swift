//
//  NotchHomeView.swift
//  Wanna
//
//  The notch sheet's conversation home.
//  With nothing in the session yet, the hero is *centered* — the
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

    // MARK: - 输入框上方那行（2026-09-26 新增）
    //
    // 用户的要求：「输入框上方显示按钮：左侧第一个：连续对话（默认状态，主对话）；
    // 第二个：临时对话；右侧：新建、屏幕、声音」「声音按钮移至输入框上方，其右侧增加
    // 『音色』按钮，点击后展开弹窗」。

    /// 这一行当前是哪种对话。**连续对话 = 今天的主对话**（唯一有完整链路的那个）；
    /// 临时对话的浮层在下一阶段接（`TempConversationOverlay`），这一阶段先把
    /// 选择与默认值立起来。
    enum ComposerConversationMode: String, CaseIterable, Identifiable {
        case continuous
        case temporary

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .continuous: return "连续对话"
            case .temporary: return "临时对话"
            }
        }
        var helpText: String {
            switch self {
            case .continuous: return "主对话：问题和回答都记进这条会话"
            case .temporary: return "临时对话：不记进任何会话，关掉就没了"
            }
        }
    }

    @State private var composerConversationMode: ComposerConversationMode = .continuous
    /// 音色弹窗开着没有。
    @State private var isVoicePickerPresented = false
    /// 克隆音色（打开弹窗时拉一次；拉不到就只显示系统音色 + 一行说明）。
    @State private var customVoicesForPicker: [CustomVoice] = []
    @State private var voicePickerFailureText: String?
    /// 试听代次：换一个音色试听就作废上一段（与「音色查看」页同一个做法）。
    @State private var voicePreviewGeneration = 0
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

    /// 内容列的宽度，与高度同一个测量点。**它唯一的用途是给回答卡片当身份证**
    /// （见 `assistantBubble` 里的 `.id(contentColumnWidth)`）。
    ///
    /// 为什么需要它：回答卡片把断好的行按当前宽度缓存在自己的 `@State` 里，而实时区
    /// 那两行是 `.fixedSize(horizontal: true)` 的（防流式期间被压缩换行，见
    /// `AnswerCardView.liveLineView`）。于是「卡片算出来的那几行有多宽」变成了这一列
    /// 的最小宽度 —— 而它又是从这一列量出来的，两者互相锁死：**列一变窄，卡片不肯跟着
    /// 变窄，宽度就永远停在旧值上**。2026-09-26 实测：810 的面板里收起再展开侧栏
    ///（内容列 747 → 564），两列一起被撑到 987 并居中，左列左边 89pt 被裁掉
    ///（连「Screen」按钮都看不见），右列右边 89pt 被裁掉。
    ///
    /// 外面几层拿不到这个数（列宽是 `HStack` 分给这一列的），所以只能在这里量；
    /// 量到了当 `.id` 用，宽度每变一次就把卡片重建一次 —— 新卡片的缓存是空的，
    /// 它会先按真实可用宽度重新断行，环就断开了。
    /// 内容列的**上次实测宽度** —— 展开时用它给 `contentColumnWidth` 当初值。
    ///
    /// 面板每次展开都会重建这一列的视图，`@State` 于是从 0 起步：卡片先按
    /// 「宽度未知」建一遍，紧接着 GeometryReader 量到真实宽度、`.id` 一变，
    /// **所有卡片整棵重建第二遍**。2026-09-26 实测
    ///（`开发经验/运行日志/wanna-展开采样-*.txt`）：8 张卡片一次展开排了 16 遍。
    /// 面板宽度在一次会话里不会变，记住上一次的值，第一遍就是对的、第二遍不会发生。
    /// 真正的宽度变化（收起侧栏、全屏切换）照样让 `.id` 变、照样重建 —— 那条语义
    /// 是上一段说明里那个「列变窄卡片不肯跟着窄」的修复，不能丢。
    @MainActor private static var rememberedContentColumnWidth: CGFloat = 0

    @State private var contentColumnWidth: CGFloat = NotchHomeView.rememberedContentColumnWidth

    /// 对话流一次渲染多少个回合 —— 窗口化的上限。
    ///
    /// 用户 2026-09-26：「我未来是要高频使用的，那么可能未来窗口就是几十个、几百个，
    /// 那这样的情况下，如果是每个都会越来越慢的话，那就体验就非常的差」。
    /// 而一次展开的主线程时间与**树的大小**成正比（见 `conversationFlow` 里
    /// `LazyVStack` 那段实测）。`LazyVStack` 只解决"视口外的卡片不建"，但
    /// **滚到底**那一下会把它上面的一整段都物化出来（实测：8 条里建了 7 条），
    /// 所以真正把成本关进常数的是这个窗口 —— 只渲染最后 `renderedTurnCount` 个回合，
    /// 更早的由流顶那个「载入更早的对话」一批一批补上来。
    ///
    /// 10 这个数来自视口：面板高 ~940pt、一回合约 120~150pt，视口里能看到五六条，
    /// 留一倍余量，滚一下不会立刻撞到边界。**它不影响短会话** —— 条数不到 10 时
    /// 这条窗口完全不存在（当前的会话都是 8~15 条）。
    @State private var renderedTurnCount = NotchHomeView.initialRenderedTurnCount
    private static let initialRenderedTurnCount = 10
    private static let renderedTurnExtendChunk = 20

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
            // 音色弹窗就在输入框正上方展开（用户：「点击后展开弹窗」）。
            // 放在 VStack 里而不是做成浮层：它一展开就把上面的流往上推一点，
            // 而浮层要自己算位置（`VoiceChatSessionView` 那套锚点测量）——
            // 一个音色列表不值得那套机械。
            if isVoicePickerPresented {
                voicePickerPanel
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
                    .onAppear {
                        contentColumnHeight = geometryProxy.size.height
                        contentColumnWidth = geometryProxy.size.width
                        Self.rememberedContentColumnWidth = geometryProxy.size.width
                    }
                    .onChange(of: geometryProxy.size.height) { _, newHeight in
                        contentColumnHeight = newHeight
                    }
                    // 列宽变化（收起／展开侧栏、全屏来回切）要重建回答卡片 ——
                    // 理由见 `contentColumnWidth` 的说明。
                    .onChange(of: geometryProxy.size.width) { _, newWidth in
                        contentColumnWidth = newWidth
                        Self.rememberedContentColumnWidth = newWidth
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

    /// 主页的居中构图：大字号问候和按住说话的提示。提示行是现在唯一
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
                // 静止时**什么都不占**。
                //
                // 这里原来画一个「同高透明胶囊」来固定这一条的高度，理由见上：免得
                // 语音状态一变、滚动区高度跟着变，整列消息上下抖一下。但它留下的
                // 是一条**看得见的空带** —— 分割线和第一条消息之间那块空白，用户
                // 2026-09-26 指着它说「这里应该渲染出文字，而不是保留一个空位」。
                // 占位是为了消除抖动，代价是永远有一块空白；用户要的是没有空白。
                EmptyView()
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
        // **窗口化的起点**：只渲染最后 `renderedTurnCount` 条，更早的等用户点
        // 流顶那个「载入更早的对话」。索引仍用**原始**的下标，所以 `id`、
        // 滚动目标、`renderedTurnCount` 的推进三者对得上。
        let firstRenderedEntryIndex = max(0, entries.count - renderedTurnCount)

        return ScrollViewReader { proxy in
            ScrollView {
                // **`LazyVStack` 而不是 `VStack`：会话越长，这一列越贵。**
                //
                // 2026-09-26 实测（`sample` 抓的栈）：一次展开的主线程时间几乎全在
                // SwiftUI 对整棵面板树反复布局，而这一列就是树的主体 —— 每一张回答
                // 卡片都要参与那一遍布局。`VStack` 会**把所有回合都建出来**，
                // 于是「用户以后有几十上百个回合」时，点开刘海要等的时间随回合数
                // 线性增长。`LazyVStack` 只建视口内的那几张（面板高 ~940pt，
                // 大概三四张），成本与会话长度脱钩。
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 流顶那一颗「载入更早的对话」。**它是显式的，不是靠哨兵视图的
                    // `onAppear`** —— 哨兵会被懒加载的预取顺手物化，那一下就补一批、
                    // 再物化再补，一路补到全部渲染出来，等于没窗口化；而这里点一下
                    // 补一批，补多少、什么时候补都由用户决定。
                    if firstRenderedEntryIndex > 0 {
                        loadEarlierTurnsButton(
                            olderEntryCount: firstRenderedEntryIndex,
                            proxy: proxy
                        )
                    }

                    // 回答还没写下来的那一条**整条不进列表** —— 早先这里是渲染
                    // 一个 `EmptyView()`，但它照样占掉 `VStack(spacing: 12)` 的一个
                    // 间隔：内容为空、位置却留着，读起来就是一个悬在那里的空框。
                    // 滤掉之后索引仍然用**原始**的 entryIndex，`id` 和滚动目标不变。
                    ForEach(
                        Array(entries.enumerated()).filter {
                            $0.offset >= firstRenderedEntryIndex
                                && !($0.offset == entries.count - 1 && $0.element.assistantResponse.isEmpty)
                        },
                        id: \.offset
                    ) { entryIndex, entry in
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
                // 换会话＝换一整列内容，窗口也跟着回到初始值 —— 上一条会话里
                // 用户往上补出来的那几十条不该算在下一个会话头上。
                renderedTurnCount = Self.initialRenderedTurnCount
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

    /// 流顶那颗「载入更早的对话」。见 `renderedTurnCount` —— 它把这一列的渲染量
    /// 关进一个常数，代价是更早的回合要用户点一下才出现；这个按钮就是那一下。
    @ViewBuilder
    private func loadEarlierTurnsButton(olderEntryCount: Int, proxy: ScrollViewProxy) -> some View {
        let loadingCount = min(olderEntryCount, Self.renderedTurnExtendChunk)
        HStack {
            Spacer(minLength: 0)
            Button(action: {
                loadEarlierTurns(
                    proxy: proxy,
                    keepingFirstRenderedEntryIndex: olderEntryCount
                )
            }) {
                Text("载入更早的 \(loadingCount) 条对话")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("这一列只渲染最近的对话；点一下往上补一批")
            Spacer(minLength: 0)
        }
    }

    /// 往上补一批回合。
    ///
    /// **补完必须把"原来最上面那一条"钉回视口顶部。** 不钉的话，新补的内容插在
    /// 它上面，而 `ScrollView` 的位置是按"距内容顶部多远"记的 —— 内容在头顶长高
    /// 多少，视口就往下跳多少，用户会觉得"我点了一下，正在读的东西被推走了"。
    /// 钉住之后，观感是"上面的历史展开了，我原来在读的那条还在原处"。
    ///
    /// 滚动排在 `Task { @MainActor }` 里：`renderedTurnCount` 刚改，新布局还没算出来，
    /// 当帧滚过去会落在旧的几何上（房子里其它滚动收口也是这么排的）。
    private func loadEarlierTurns(proxy: ScrollViewProxy, keepingFirstRenderedEntryIndex entryIndex: Int) {
        renderedTurnCount += Self.renderedTurnExtendChunk
        Task { @MainActor in
            proxy.scrollTo("entry-\(entryIndex)", anchor: .top)
        }
    }

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

        assistantBubble(entry.displayResponse ?? entry.assistantResponse, isStreaming: false)

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
    /// It replaced 参考页's solid-accent `#0A84FF` fill on
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
            // 列宽变了就重建这张卡：它的断行缓存按宽度存在 `@State` 里，而实时区
            // 那两行不允许被压缩（`.fixedSize(horizontal: true)`），两件事合起来会
            // 让「这一列的最小宽度」永远停在旧列宽上。重建一次缓存就空了，卡片会
            // 按新宽度重新断行。见 `contentColumnWidth` 的说明。
            .id(contentColumnWidth)
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
                text: stripActionTagsForDisplay(entry.displayResponse ?? entry.assistantResponse),
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
    /// 输入框上方那一行。左 = 两种对话模式；右 = 新建 · 声音 · 音色。
    ///
    /// 「屏幕」这一格**这一阶段先不放**：它要真的做到「不勾就不截图」，得给
    /// `sendTranscriptToVisionChatWithScreenshot` 加一条不带图的路径（那条函数
    /// 三百多行，中途插参数我不在这轮冒险）。放一个按了没反应的开关，比暂时不放更糟。
    private var composerControlsRow: some View {
        HStack(spacing: 6) {
            ForEach(ComposerConversationMode.allCases) { mode in
                conversationModeChip(mode)
            }

            Spacer(minLength: 6)

            composerRowButton(title: "新建", systemImage: "plus",
                              helpText: "新建主对话（当前这条会自动归档）") {
                sessionsModel.createSession()
                composerConversationMode = .continuous
            }
            soundChip
            voiceChip
        }
    }

    private func conversationModeChip(_ mode: ComposerConversationMode) -> some View {
        let isSelected = composerConversationMode == mode
        return Button(action: {
            SoundEffectPlayer.shared.play(.sidebarButton)
            composerConversationMode = mode
        }) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(mode.displayName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? DS.Colors.success : .white.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.success.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(mode.helpText)
    }

    private func composerRowButton(title: String,
                                   systemImage: String,
                                   isHighlighted: Bool = false,
                                   helpText: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10.5))
                Text(title).font(.system(size: 11.5))
            }
            .foregroundColor(isHighlighted ? DS.Colors.accent : .white.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHighlighted ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(helpText)
    }

    /// 「声音」——就是原来输入框右下角那个静音开关，搬到这一行（用户要求）。
    /// 状态仍然是同一个 `companionManager.voiceReplyMuted`，没有第二份真相。
    private var soundChip: some View {
        composerRowButton(title: "声音",
                          systemImage: companionManager.voiceReplyMuted
                              ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          isHighlighted: !companionManager.voiceReplyMuted,
                          helpText: companionManager.voiceReplyMuted
                              ? "已静音：回复只显示文字（点击恢复朗读）"
                              : "正在朗读回复（点击静音，只显示文字）") {
            companionManager.voiceReplyMuted.toggle()
            if companionManager.voiceReplyMuted {
                companionManager.silenceActiveReplyAudio()
            }
        }
    }

    /// 「音色」——点开选择这一条回复用哪个音色（用户：「点击后展开弹窗，根据当前
    /// 接入的语音合成服务展示支持的音色」；服务商就是百炼，音色表就是 `VoiceCatalog`）。
    private var voiceChip: some View {
        composerRowButton(title: currentVoiceDisplayName,
                          systemImage: "waveform",
                          isHighlighted: isVoicePickerPresented,
                          helpText: "选择回复用哪个音色（默认用设置里配的那个）") {
            isVoicePickerPresented.toggle()
            if isVoicePickerPresented { loadCustomVoicesForPickerIfNeeded() }
        }
    }

    /// 那一格显示什么字：选了就显示它的名字，没选就显示「音色」。
    private var currentVoiceDisplayName: String {
        guard let voiceID = companionManager.replyVoiceOverride else { return "音色" }
        if let systemVoice = VoiceCatalog.threeStageVoices.first(where: { $0.id == voiceID }) {
            return systemVoice.displayName
        }
        if let nickname = VoiceLibraryStore.nickname(forCustomVoiceID: voiceID) {
            return nickname
        }
        return "音色"
    }

    private func loadCustomVoicesForPickerIfNeeded() {
        guard customVoicesForPicker.isEmpty else { return }
        Task { @MainActor in
            do {
                customVoicesForPicker = try await CustomVoiceLibraryClient.listCustomVoices()
                voicePickerFailureText = nil
            } catch {
                voicePickerFailureText = "克隆音色没拉下来：\(error.localizedDescription)"
            }
        }
    }

    /// 音色弹窗。系统音色来自 `VoiceCatalog`（**当前合成模型支持的**那些），
    /// 克隆音色来自云端列表 —— 与「设置 → 音色查看」读的是同一批数据。
    private var voicePickerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("音色")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 4)
                Button(action: { isVoicePickerPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("收起音色列表")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    voicePickerSectionLabel("系统音色")
                    ForEach(VoiceCatalog.threeStageVoices) { voice in
                        voicePickerRow(voiceID: voice.id,
                                       model: currentSpeechModelID,
                                       displayName: voice.displayName)
                    }

                    voicePickerSectionLabel("克隆音色")
                    if let voicePickerFailureText {
                        Text(voicePickerFailureText)
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else if customVoicesForPicker.isEmpty {
                        Text("还没有克隆音色（「设置 → 音色查看 → 声音克隆」可以做一个）")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(customVoicesForPicker) { voice in
                            // `CustomVoice` 只有 id / targetModel / createdAt / status
                            // —— 官方那边**不存备注**，所以显示名只能取本地昵称，没有再退回 id
                            //（与「设置 → 音色查看」同一套三级回落）。
                            voicePickerRow(
                                voiceID: voice.id,
                                model: voice.targetModel.isEmpty ? currentSpeechModelID : voice.targetModel,
                                displayName: VoiceLibraryStore.nickname(forCustomVoiceID: voice.id) ?? voice.id
                            )
                        }
                    }

                    // 「用默认」——把覆盖清掉，回到设置里配的那个。
                    voicePickerRow(voiceID: nil, displayName: "默认（设置里那一个）")
                }
            }
            .frame(maxHeight: 220)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
    }

    private func voicePickerSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.40))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// 试听用的合成模型 = 「模型」页里 👄 那个（与「音色查看」页同一处取值，
    /// 包括那条 `?? BailianConfiguration.Models.textToSpeech` 回落）。
    private var currentSpeechModelID: String {
        ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole?.modelID
            ?? BailianConfiguration.Models.textToSpeech
    }

    private func voicePickerRow(voiceID: String?, model: String = "", displayName: String) -> some View {
        let isSelected = companionManager.replyVoiceOverride == voiceID
        return HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark" : "circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.success : .white.opacity(0.25))
                .frame(width: 12)

            Text(displayName)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let voiceID {
                Button(action: {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    previewVoice(voiceID, model: model)
                }) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("试听")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            SoundEffectPlayer.shared.play(.sidebarButton)
            companionManager.replyVoiceOverride = voiceID
        }
    }

    /// 试听：走「设置 → 音色查看」同一条链 —— `VoicePreviewService` 合成（结果进
    /// `VoicePreviews/` 缓存）+ `CompanionManager.playVoicePreview` 播放。
    ///
    /// 代次计数与那一页同义：**换一个音色试听 = 停掉上一段**，而不是两段叠在一起。
    /// （自己再写一条播放通路的话，两处会各自漂。）
    private func previewVoice(_ voiceID: String, model: String) {
        companionManager.stopVoicePreview()
        voicePreviewGeneration += 1
        let generation = voicePreviewGeneration
        Task { @MainActor in
            do {
                let appSettings = AppSettingsStore.snapshot()
                let audioData = try await VoicePreviewService.previewAudioData(
                    engine: .threeStage,
                    voice: voiceID,
                    model: model.isEmpty ? currentSpeechModelID : model,
                    speechRate: appSettings.speechPlaybackRate,
                    speechVolumePercent: appSettings.speechPlaybackVolumePercent,
                    styleInstruction: "")
                guard generation == voicePreviewGeneration else { return }
                try await companionManager.playVoicePreview(wavData: audioData)
            } catch {
                guard generation == voicePreviewGeneration else { return }
                voicePickerFailureText = "试听失败：\(error.localizedDescription)"
            }
        }
    }

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
            // **输入框上方那一行**（2026-09-26）：两种对话模式 + 新建 / 声音 / 音色。
            controlsRow: AnyView(composerControlsRow),
            // **静音开关搬走了**（2026-09-26）：用户要求「声音按钮移至输入框上方」——
            // 它现在是上面那行里的「声音」那一格（`soundChip`），状态还是同一个
            // `companionManager.voiceReplyMuted`。**不在这里留第二颗**：同一件事两个入口，
            // 迟早会有人只改一处。
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
