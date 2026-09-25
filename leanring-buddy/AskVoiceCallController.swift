//
//  AskVoiceCallController.swift
//  leanring-buddy
//
//  **Ask 页自己的全双工语音管线** —— 与 Chatting 那套是**两条不同的管线**。
//
//  用户 2026-09-25 的原话（这就是它的需求书）：
//
//  > 「我希望在 ask 页面里进行连续对话，只是更换了语音识别、语音理解、语音表达的模型，
//  > 仅此而已。相当于给 ask 页面增加一条全新的管线，**这条管线不截屏**。正常情况下，
//  > 我通过快捷键提问屏幕内容时会截屏……但用户点击全双工语音时，是针对当前某一个会话的
//  > 上下文来连续对话，**不截屏，只看上下文**。用户第一次发送时包含完整上下文，
//  > 第二次发送时只包含用户的提示词。」
//  >
//  > 「我不是让你照抄 Chatting 那套东西……你应该理解它搭建管线的逻辑，然后设计一条
//  > 全新的管线。」
//
//  两条管线的差别是设计意图上的，不是"少改了几行"：
//
//  | | Chatting（VoiceChatController） | Ask 语音电话（本文件） |
//  |---|---|---|
//  | 单位 | 角色 + 预设 | **Ask 的某一个会话** |
//  | 上下文 | 角色的系统提示词 | **该会话的聊天历史**（拼进 instructions） |
//  | 落点 | Chatting 页的转录流 | **Ask 页的会话本身**（`appendEntry`，与打字同一条存储路径） |
//  | 截图 | 三段式会截 | **从不截屏** |
//  | 问候语 | 连上就打招呼 | **没有** —— 用户没说话之前不发任何东西 |
//  | 侧栏 | 展开时会切到 Chatting 页 | **只管刘海状态带，绝不切换侧栏** |
//
//  协议层复用 `DuplexVoiceEngine`（一台 websocket 音频引擎）—— 那是**传输**，不是编排。
//  编排（何时发什么、结果落到哪里）全在本文件。
//

import Combine
import Foundation

@MainActor
final class AskVoiceCallController: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// 已发起，还没听到第一段音频（= AI 的第一次回答还没开口）。
        case connecting
        case live
    }

    @Published private(set) var phase: Phase = .idle
    /// 用户正在说的那句话（实时转写，Ask 页据此显示）。
    @Published private(set) var liveUserTranscript = ""
    /// AI 正在说的回复（增量文本，Ask 页据此显示；回合结束时落成一条正式条目）。
    ///
    /// **它是按帧合并后发布的那一份**，不是每收到一个字节就更新 —— 见
    /// `acceptAssistantText`。落盘用的是 `latestAssistantText`，两者刻意分开。
    @Published private(set) var liveAssistantText = ""

    /// 最新收到的累积文本，**不经过任何节奏控制**。落盘（`commitAssistantTurn`）读它。
    ///
    /// 为什么必须与界面上那份分开：界面那份是**按帧、按算出来的速率**逐字吐出来的，
    /// 落盘那一刻它多半还没吐完；读它就会把还没显示的字丢掉 —— 而"最后一句不完整"
    /// 正是最容易被注意到的缺陷。
    private var latestAssistantText = ""

    /// 界面上已经吐到第几个字（`latestAssistantText` 的前缀长度）。
    private var displayedCharacterCount = 0

    /// 本轮第一段文字到达的时刻 —— 短回复兜底要用它（见 `advanceDisplayedText`）。
    private var assistantTextBeganAt: Date?

    /// 本轮是否已经开始吐字。没开始之前，缓冲不攒够就什么都不显示 —— 这是
    /// 「前面两行一定是正常速度」的实现方式。见 `advanceDisplayedText`。
    private var hasStartedRevealing = false

    /// 不足一帧的推进量攒在这里，凑够一个字再吐。没有它，`max(1, …)` 会让实际
    /// 最低速度被抬到 30 字/秒（一帧一个字），"低速"就名不副实了。
    private var displayAdvanceAccumulator = 0.0

    // MARK: 吐字的四个数（全部由实测推出，见 `advanceDisplayedText` 的推导）

    /// 一帧的时长。33ms ≈ 30fps。
    private static let displayPacerTickMilliseconds = 33
    /// **正常速度：83 字/秒。**
    ///
    /// 这是**实测**出来的，不是拍的：Ask 页 DeepSeek 那条路 106 个字用 1.28 秒
    /// 出完（70 个 delta），也就是用户明确说过「我能接受」的那个速度。
    private static let displayNormalCharactersPerSecond = 83.0
    /// **全速所需的在手缓冲：60 字。**
    ///
    /// 一行约 27~33 字（实测：断行器在 459pt 宽下每行装 33 个 unit），所以 60 字
    /// 约等于两行 —— 正好是用户划的那条线：「前面这三行或者两行的时候，一定要
    /// 正常速度」。它同时是**启动阈值**：攒够两行才开始吐，于是开头那两行必然
    /// 是全速的。
    private static let displayFullSpeedBufferCharacters = 60
    /// **最低速度：10 字/秒。**
    ///
    /// 缓冲见底时用它兜着。它不是"停住"——只是慢；再低就会被读成卡住了。
    private static let displayMinimumCharactersPerSecond = 10.0
    /// 短回复兜底：首字到达这么久还没攒够两行，就先吐起来。
    ///
    /// 没有它，开场白那种二十来字的短句永远达不到 60 字的阈值，就一个字都不显示。
    /// 1.2 秒取得比 DeepSeek 那条路的首字延迟（实测约 0.8 秒）略长一点。
    private static let displayStartFallbackSeconds = 1.2

    private var displayPacerTask: Task<Void, Never>?

    /// 音色（跨启动保留）。nil = 兜底音色。
    @Published var voiceID: String? {
        didSet {
            if let voiceID {
                UserDefaults.standard.set(voiceID, forKey: Self.voiceIDDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.voiceIDDefaultsKey)
            }
        }
    }

    static let voiceIDDefaultsKey = "clickyAskVoiceCallVoiceID"

    /// 刘海状态带（本控制器不认识刘海窗口，由 `CompanionManager` 注入）。
    var setNotchPhase: ((NotchActivityPhase?) -> Void)?
    /// 报错往哪儿说（Ask 页底部那行）。
    var reportFailure: ((String) -> Void)?
    /// 共享播放引擎（全 app 唯一那台，从 `CompanionManager` 注入）。
    var playbackEngineProvider: (() -> VoicePlaybackEngine?)?
    /// **热引擎**（与 Chatting 的 `warmUpVoiceEngine` 同一个动作）。
    ///
    /// Chatting 在起会话前先热引擎（首次 VPIO 使能要 ~2 秒，还可能走一次失败回退），
    /// tap 装在**已经热好**的引擎上；Ask 原来没有这一步 —— tap 装在一次**冷 bring-up**
    /// 的返回值上，而那条冷启动路径可能落在"被拆过 voice processing 的引擎"上，
    /// 那种引擎的 tap 只送静音/0 帧且**不报错**（`VoicePlaybackEngine.swift` 的成文记录）。
    /// 2026-09-25 两路调查都点了这一条。
    var warmUpEngine: (() async -> Void)?

    private var engine: DuplexVoiceEngine?
    /// **等待配对**的那条 AI 回复在会话里的下标。
    ///
    /// 用户 2026-09-25 实测的第二类错位：转写比"下一轮"还晚到（长回复时必现），
    /// 用「最后一条」去找配对就配到**别人**的条目上了，甚至于是你的话被插到别处、
    /// 而那个位置的气泡不显示。所以这里记住**我自己刚写的那条**的下标，
    /// 配对时只认它。
    /// 这通电话服务**哪一个 Ask 会话**：点按钮那一刻定格 —— 通话中途切会话
    /// 不该把转录写进另一个会话。
    private var targetSessionID: UUID?
    /// 等待用户转写来配对的 AI 回复条目下标（nil = 没有待配对的）。
    private var pendingAssistantEntryIndex: Int?
    /// **这一轮回答应该落在哪个下标**（回合开始时定格）。
    ///
    /// 顺序必须按"回合开始的先后"排：回答是**在回合结束时**才写盘的，而用户下一句
    /// 往往已经先到了 —— 直接往后追加就会得到「上一轮的答案排在下一轮提问之后」
    /// （用户 2026-09-25 实测的顺序错乱）。回合一开始就把下标定下来，写盘时按它**插入**。
    private var pendingAssistantInsertIndex: Int?
    /// 已经在会话里、但还**没写进任何条目**的用户那句话（转写先于回答的 done 到达时）。
    private var pendingUserTranscript: String?
    /// 回答写了、用户转写还没补（常态：done 早于转写）—— 指向那条回答的下标。
    private var pendingPairIndex: Int?
    /// 当前这一轮回答是不是**用户说话触发的**（只有它才会写盘 / 配对）。
    private var isExpectingUserTranscriptForCurrentTurn = false
    /// 这一轮回答是否由用户说话触发（开场白是 false）—— 只有 true 才允许写盘。
    private var isCurrentTurnTriggeredByUserSpeech = false
    /// 开场白回合：不写盘、不配对、期间不武装本地打断（AEC 未收敛，麦克风会听到
    /// AI 自己的声音而误触发 —— 2026-09-25 日志实测）。
    private var isGreetingTurn = true

    init() {
        voiceID = UserDefaults.standard.string(forKey: Self.voiceIDDefaultsKey)
    }

    var isActive: Bool { phase != .idle }

    // MARK: - 起 / 停

    /// 起一通 Ask 语音电话。
    ///
    /// - Parameters:
    ///   - sessionID: 当前选中的 Ask 会话 —— 上下文与转录都落在它身上。
    ///   - contextPrompt: 该会话的聊天历史（见 `AskVoiceCallContext.prompt(entries:)`）。
    ///     它进 `session.instructions` —— **只发一次**，所以"第一次带完整上下文、
    ///     之后只送用户说的话"是协议层面的天然形状：instructions 只在 `session.update`
    ///     时上行，之后的回合只有用户的音频。
    func start(sessionID: UUID, contextPrompt: String, voiceID: String?) {
        guard phase == .idle, let playbackEngine = playbackEngineProvider?() else {
            reportFailure?("Ask 语音电话：共享播放引擎还没准备好。")
            return
        }
        targetSessionID = sessionID
        liveUserTranscript = ""
        resetAssistantTextBuffers()
        // 会话的状态属于会话：上一通电话残留的配对状态绝不带进来
        // （引擎侧在 start 里清自己的字段，这里清编排侧的）。
        pendingUserTranscript = nil
        pendingPairIndex = nil
        isCurrentTurnTriggeredByUserSpeech = false
        isExpectingUserTranscriptForCurrentTurn = false
        isGreetingTurn = true
        phase = .connecting
        setNotchPhase?(.externalConnecting)

        let effectiveVoiceID = voiceID
            ?? VoiceCatalog.fallbackVoice(for: .duplexVoice, model: VoiceCatalog.defaultDuplexModel)

        let engine = DuplexVoiceEngine(
            playbackEngine: playbackEngine,
            callbacks: DuplexVoiceEngine.Callbacks(
                onUserUtterance: { [weak self] transcript in
                    self?.handleUserUtterance(transcript)
                },
                onFirstAudioScheduled: { [weak self] in
                    // **接通判据 = AI 的第一段声音真的开始播**，与 Chatting 完全一致
                    // （用户 2026-09-25：「声音播放开始的那一秒，就把状态切换为已连接，
                    // 否则一直显示连接中……重点是先让 AI 说话，而不是让用户先说话」）。
                    // 开场白保证了这一段音频必然到来，所以这个判据不会永远等不到。
                    guard let self, self.phase == .connecting else { return }
                    self.phase = .live
                    self.setNotchPhase?(.externalChatting)
                    print("💬 Ask 语音电话：第一段音频已开始播 —— 状态切到「通话中」")
                },
                onBargeIn: { [weak self] in
                    self?.commitAssistantTurn()
                },
                onUserSpeechStarted: { [weak self] in
                    // 用户开口了：**这一轮之后的回答是"用户触发的"**，可以和用户那句话配对。
                    // 开场白那类"我方主动发起"的回合不会被标上，所以它绝不会被当成谁的答案。
                    self?.isExpectingUserTranscriptForCurrentTurn = true
                },
                onAssistantTurnStarted: { [weak self] in
                    self?.noteAssistantTurnStarted()
                },
                onAssistantText: { [weak self] cumulativeText in
                    self?.acceptAssistantText(cumulativeText)
                },
                onAssistantTurnFinished: { [weak self] in
                    self?.commitAssistantTurn()
                },
                // **接通 = 会话配置被接受**（不是"AI 开口"）—— 这条管线不打招呼，
                // 等 AI 出声才翻状态的话，用户说话之前界面会永远停在「连接中…」。
                onSessionConfigured: {
                    // 会话配置被服务端接受 —— 配置合法，但**还不算连上**：
                    // 真正的「已连接」等第一段音频（见下面那条），与 Chatting 一致。
                    print("💬 Ask 语音电话：会话配置已接受")
                },
                onFailure: { [weak self] message in
                    guard let self else { return }
                    // 引擎报错 = 这条会话已经死了：先收尾，别让界面挂在「通话中」。
                    if self.isActive { self.hangUp() }
                    self.reportFailure?("Ask 语音电话：\(message)")
                }
            )
        )
        self.engine = engine

        Task { [weak self] in
            guard let self else { return }
            do {
                // 与 Chatting 同一步：先把引擎热起来（首次 VPIO 使能 ~2 秒，还可能
                // 走一次失败回退），tap 因此装在热引擎上而不是冷启动的返回值上。
                await self.warmUpEngine?()
                try await engine.start(
                    role: VoiceChatRole.makeDefaultRole(),
                    model: VoiceCatalog.defaultDuplexModel,
                    voiceID: effectiveVoiceID,
                    systemPrompt: contextPrompt
                )
                print("💬 Ask 语音电话已接通（会话 \(sessionID)，模型 \(VoiceCatalog.defaultDuplexModel)，音色 \(effectiveVoiceID)）")
                // **先让 AI 说一句**（用户 2026-09-25：「点击之后要让 AI 先发送一条消息，
                // 比如"你好"，两个字就可以。然后检测语音什么时候开始播放，声音播放开始的
                // 那一秒，就把状态切换为已连接……重点是先让 AI 说话，而不是让用户先说话」）。
                //
                // 它同时解决了"连接中"没有判据的问题：有了这句话，"第一段音频"就必然到来，
                // 状态切换的时机与 Chatting 一模一样。
                try await engine.speakGreeting(Self.openingGreeting)
                scheduleConnectionFallbackIfNoAudio()
            } catch {
                engine.stop()
                self.engine = nil
                self.phase = .idle
                self.setNotchPhase?(nil)
                self.reportFailure?("Ask 语音电话起不来 —— \(error.localizedDescription)")
            }
        }
    }

    /// 打招呼的文字。用户给的例子就是两个字。
    static let openingGreeting = "你好"

    /// 等不到第一段音频的兜底：15 秒后如实说明并算连上 —— 不能把界面永远吊在
    /// 「连接中」（与 Chatting 的 `scheduleConnectionFallbackIfNoAudio` 同一条思路）。
    private var connectionFallbackTask: Task<Void, Never>?

    private func scheduleConnectionFallbackIfNoAudio() {
        connectionFallbackTask?.cancel()
        connectionFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.phase == .connecting else { return }
            self.phase = .live
            self.setNotchPhase?(.externalChatting)
            self.reportFailure?("Ask 语音电话：连上 15 秒还没听到它出声，它可能没真的在服务。")
        }
    }

    func hangUp() {
        guard phase != .idle else { return }
        connectionFallbackTask?.cancel()
        connectionFallbackTask = nil
        // 挂断音效（与 Chatting 一致）—— 它必须在这里、且只响一次：
        // 刘海右翼、页内挂断按钮、报错收尾三条路都走这个漏斗。
        SoundEffectPlayer.shared.play(.sessionHungUp)
        engine?.stop()
        engine = nil
        phase = .idle
        targetSessionID = nil
        liveUserTranscript = ""
        resetAssistantTextBuffers()
        pendingAssistantEntryIndex = nil
        setNotchPhase?(nil)
        print("💬 Ask 语音电话已挂断")
    }

    // MARK: - 转录落进 Ask 会话

    // **这一节是 Ask 管线的写盘状态机**，与 Chatting 的内存数组同构，但多了两条
    // 协议约束（都是事件流日志实测的，2026-09-25）：
    //
    //   1. 服务端顺序是「先回答、转写最后补」：response.done 早于
    //      input_audio_transcription.completed。所以回答先落盘（用户文本暂时为空）、
    //      转写到达时**按下标补配**进同一条 —— 配对目标记住的是**我自己刚写的下标**，
    //      绝不用"最后一条"去找（那会在下一轮开始后配错）。
    //   2. **开场白回合不落盘**：它是接通信号，不是对话内容；落了盘就会变成一条
    //      「问空答有」的记录，把用户第一问吸过去（问北京、答你好 就是这么来的）。
    //
    // 状态只有两个：`pendingUserTranscript`（用户说了、回答还没写）与
    // `pendingPairIndex`（回答写了、用户转写还没补）。任何时刻至多一个非空。

    /// 用户说了一句（引擎在 `transcription.completed` 给的是最终转写）。
    private func handleUserUtterance(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        liveUserTranscript = ""
        isGreetingTurn = false
        print("🗣️ [user-utterance] 「\(trimmed)」")

        // ① 有"刚写完、等着用户文本"的回答 → 补配进同一条（问在上、答在下）。
        if let session = currentTargetSession(),
           let pairIndex = pendingPairIndex,
           session.entries.indices.contains(pairIndex),
           session.entries[pairIndex].userTranscript.isEmpty,
           !session.entries[pairIndex].assistantResponse.isEmpty {
            let pendingReply = session.entries[pairIndex].assistantResponse
            var updatedEntries = session.entries
            updatedEntries[pairIndex] = ConversationHistoryEntry(
                userTranscript: trimmed,
                assistantResponse: pendingReply,
                recordedWithActionTags: true
            )
            ConversationSessionsStore.replaceEntriesAndSummary(
                entries: updatedEntries,
                summary: session.summary,
                sessionID: session.id
            )
            print("📝 [写盘] 补配 #\(pairIndex)：问「\(trimmed.prefix(20))」 答「\(pendingReply.prefix(20))」")
            pendingPairIndex = nil
            return
        }

        // ② 没有可配对的回答（回答要等它的 done）→ 攥住，等回合结束一起写。
        pendingUserTranscript = trimmed
    }

    /// 助手这一轮开始了（`response.created`）：记录"这一轮是不是用户说话触发的"。
    private func noteAssistantTurnStarted() {
        isCurrentTurnTriggeredByUserSpeech = isExpectingUserTranscriptForCurrentTurn
        isExpectingUserTranscriptForCurrentTurn = false
    }

    /// 这通电话服务的那个 Ask 会话（读一份最新快照）。
    private func currentTargetSession() -> ConversationSession? {
        guard let targetSessionID else { return nil }
        return ConversationSessionsStore.allSessions().first { $0.id == targetSessionID }
    }

    /// 回合结束 / 用户打断：把这一轮的回答写盘。
    ///
    /// 三种情况：
    ///   · 手里攥着用户的转写（转写比回答的 done 先到）→ 一条写全：问在上、答在下。
    ///   · 这一轮是**用户说话触发**的 → 先写「问空答有」，`pendingPairIndex` 指向它，
    ///     等转写到达补配。
    ///   · **开场白 / 不是用户触发的回合 → 一个字都不写**：它不属于任何一轮提问，
    ///     落了盘就会把用户的话吸过去（错位的根源）。
    /// 收到一段累积文本（引擎每个 delta 调一次）。
    ///
    /// **只负责收，不负责显示** —— 显示交给 `advanceDisplayedText` 按帧推进。
    ///
    /// 为什么必须解耦（用户 2026-09-25，两次反馈合起来才看清）：
    ///
    /// 1. 服务端的 delta **每个只有 1~3 个字**（日志里 `🧾 [ai-text +1字]` 是常态），
    ///    一段 150 字的回答发了 144 个 delta；但它是**成串**到达的 —— 一整句几乎同时
    ///    生成完，然后音频慢慢播。卡片每发布一次就重排一次整段，于是同样一段正文，
    ///    全双工要付高一两个数量级的排版次数 → 用户报的「卡顿」。
    /// 2. 按帧合并之后那些 delta 被压成 1~2 次发布 → **整句一下子贴上去**，然后
    ///    躺在那里等音频播完 —— 用户报的「突然间显示出所有文字、没有任何渲染效果，
    ///    然后卡在这个位置上等很长时间」。
    ///
    /// 两次是同一个原因的两面：**显示被绑在了到达节奏上**。到达是「一大阵 + 一段
    /// 静默」，而人想看到的是**匀速**。所以这里把两者彻底分开。
    private func acceptAssistantText(_ cumulativeText: String) {
        if latestAssistantText.isEmpty, !cumulativeText.isEmpty {
            assistantTextBeganAt = Date()
        }
        latestAssistantText = cumulativeText
        startDisplayPacerIfNeeded()
    }

    /// 把已经收到的文字，按帧、按计算出来的速率，**一帧一帧**地送到界面上。
    ///
    /// 速率不是一个常数，而是**看着积压算**的：
    ///
    ///     本帧推进的字符数 = 积压 × (一帧时长 / 追平时间)
    ///
    /// 积压小（服务端一字一字地来）时它自然退化成「每帧一个字」≈ 30 字/秒，读起来
    /// 是匀速的；积压大（一整句突然到齐）时它按比例加速，在 `catchUpSeconds` 内
    /// **平滑地追平**，而不是一次性贴上去。这就是用户要的：
    ///
    /// > 「前端渲染的时候一定要检测时间，让它能够很平滑地过渡这个效果……一定是渲染
    /// > 出来的，而不是突然间把这个东西粘贴在这个位置上」。
    /// 把已经收到的文字，按算出来的速率一帧一帧吐到界面上。
    ///
    /// ## 四个数是怎么算出来的
    ///
    /// 两个**实测**输入：
    /// - 用户能接受的速度 = Ask 页 DeepSeek 那条路：**106 字 / 1.28 秒 ≈ 83 字/秒**；
    /// - 全双工的交付：**约 4~10 字/秒**，而且是**成串**的 —— 一整句几乎同时生成完，
    ///   然后音频慢慢播，中间是静默。
    ///
    /// 由此可以定死两件事：
    ///
    /// 1. **平均吐字速度不可能超过交付速度。** 缓冲只能重新分配时间，不能造字。
    ///    所以任何"全程 83 字/秒"的打算都是空的 —— 能做的只是**把开头做快、
    ///    把降速做平滑**。
    /// 2. 要让开头那几行真的跑到 83 字/秒，就得**先攒够那几行**。一行约 27~33 字
    ///    （实测：断行器在 459pt 宽下每行 33 个 unit），用户要的是「前面两行一定
    ///    正常速度」→ **阈值 60 字**，它同时就是"全速所需的在手缓冲"：一开口就在
    ///    全速，然后随着缓冲变薄而**按比例**降速。
    ///
    /// 速率式（连续，所以不会有"突然减速"）：
    ///
    ///     速率 = 83 × clamp(缓冲 / 60, 10/83, 1)     字/秒
    ///
    /// - 缓冲 ≥ 60 → 83 字/秒（与 DeepSeek 观感一致）
    /// - 缓冲 = 30 → 41 字/秒
    /// - 缓冲 → 0  → 10 字/秒兜底（仍在前移，不是停住）
    ///
    /// 兜底那 1.2 秒是给短回复的：开场白只有二十来字，永远攒不到 60，
    /// 没有它就会一个字都不显示。
    private func startDisplayPacerIfNeeded() {
        guard displayPacerTask == nil else { return }
        displayPacerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.displayPacerTickMilliseconds))
                guard let self, !Task.isCancelled else { return }
                self.advanceDisplayedText()
            }
        }
    }

    private func advanceDisplayedText() {
        let targetText = latestAssistantText
        let targetCount = targetText.count

        // 目标比已显示的短 = 换了一轮 / 被清空 → 直接跟随，不要倒着"播放"。
        if targetCount < displayedCharacterCount {
            displayedCharacterCount = targetCount
        }
        guard targetCount > 0 else { return }

        // ① 开场闸：攒够两行才开始，于是开头那两行必然是**全速**的。
        //    短回复由 1.2 秒兜底放行。
        if !hasStartedRevealing {
            let waitedLongEnough = assistantTextBeganAt
                .map { Date().timeIntervalSince($0) >= Self.displayStartFallbackSeconds } ?? false
            guard targetCount >= Self.displayFullSpeedBufferCharacters || waitedLongEnough else { return }
            hasStartedRevealing = true
        }

        let backlog = targetCount - displayedCharacterCount
        guard backlog > 0 else { return }

        // ② 速率 = 正常速度 × 缓冲比例，两端各有一道夹。
        let bufferFraction = Double(backlog) / Double(Self.displayFullSpeedBufferCharacters)
        let charactersPerSecond = min(
            Self.displayNormalCharactersPerSecond,
            max(Self.displayMinimumCharactersPerSecond,
                Self.displayNormalCharactersPerSecond * bufferFraction)
        )

        // ③ 不足一帧的量攒起来，凑够整字再吐 —— 否则最低速度会被 `max(1,…)`
        //    抬到 30 字/秒（一帧一个字），"低速"就名不副实了。
        let tickSeconds = Double(Self.displayPacerTickMilliseconds) / 1000
        displayAdvanceAccumulator += charactersPerSecond * tickSeconds
        let advanceCount = Int(displayAdvanceAccumulator)
        guard advanceCount > 0 else { return }
        displayAdvanceAccumulator -= Double(advanceCount)
        displayedCharacterCount = min(targetCount, displayedCharacterCount + advanceCount)

        let shownText = String(targetText.prefix(displayedCharacterCount))
        if liveAssistantText != shownText {
            liveAssistantText = shownText
        }
    }

    /// 把两份文本、吐字进度与挂起的任务一起归零。
    ///
    /// 三处调用（起会话 / 挂断 / 回合落盘）都必须一起清：只清界面那份而留着
    /// 挂起的任务，它醒过来会把**上一轮**的文本重新贴到屏幕上；只清文本而不清
    /// `hasStartedRevealing`，下一轮就会跳过开场闸、第一行直接不是全速。
    private func resetAssistantTextBuffers() {
        displayPacerTask?.cancel()
        displayPacerTask = nil
        liveAssistantText = ""
        latestAssistantText = ""
        displayedCharacterCount = 0
        displayAdvanceAccumulator = 0
        hasStartedRevealing = false
        assistantTextBeganAt = nil
    }

    private func commitAssistantTurn() {
        // **落盘读 `latestAssistantText`，不读界面那份。** 界面那份是按帧发布的，
        // 最后一个 delta 与它被画出来之间隔着一帧；读界面那份就会把最后一两个字
        // 丢在条目外 —— 「最后一句不完整」正是最容易被注意到的缺陷。
        let spoken = latestAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        resetAssistantTextBuffers()
        guard !spoken.isEmpty, let sessionID = targetSessionID else { return }

        // ① 用户的话攥在手里 → 一条写全。
        if let userText = pendingUserTranscript {
            pendingUserTranscript = nil
            ConversationSessionsStore.appendEntry(
                ConversationHistoryEntry(
                    userTranscript: userText,
                    assistantResponse: spoken,
                    recordedWithActionTags: true
                ),
                targetSessionID: sessionID
            )
            print("📝 [写盘] 一条全写：问「\(userText.prefix(20))」 答「\(spoken.prefix(20))」")
            return
        }

        // ② 用户触发、但没有攥着的转写（常态：转写在 done 之后才到）→
        //    先写「问空答有」，等转写补配。
        if isCurrentTurnTriggeredByUserSpeech {
            let insertIndex = currentTargetSession()?.entries.count ?? 0
            ConversationSessionsStore.appendEntry(
                ConversationHistoryEntry(
                    userTranscript: "",
                    assistantResponse: spoken,
                    recordedWithActionTags: true
                ),
                targetSessionID: sessionID
            )
            pendingPairIndex = insertIndex
            print("📝 [写盘] #\(insertIndex) 等转写补配：答「\(spoken.prefix(20))」")
            return
        }

        // ③ 开场白 / 非用户触发的回合：**写盘，但不参与配对**。
        //
        // 用户 2026-09-25：「因为我强制要求 AI 先说话，所以 AI 说的话我其实看不到，
        // 它没有显示在对话里」。原先这条什么都不写，开场白只活在 `liveAssistantText`
        // 里，而它上面两行就被清空了 —— 于是开场白一闪而过，用户从来看不到它说了什么。
        //
        // 当初不写盘的顾虑是「它会变成一条『问空答有』的记录，把用户第一问吸过去」
        // （日志里出现过 问北京、答你好）。但那个风险来自**配对**，不来自写盘：
        // 补配的锚点是 `pendingPairIndex`，而它**只有 ② 那条路才设**。所以这里照写
        // 一条助手条目、不碰锚点，用户第一问就不可能认领到开场白。
        ConversationSessionsStore.appendEntry(
            ConversationHistoryEntry(
                userTranscript: "",
                assistantResponse: spoken,
                recordedWithActionTags: true
            ),
            targetSessionID: sessionID
        )
        print("📝 [写盘] 开场白（不参与配对）：答「\(spoken.prefix(20))」")
    }
}

enum AskVoiceCallContext {

    /// 最近多少条进上下文。太多会把 instructions 撑大，而语音深聊通常只围绕最近一段。
    static let maximumEntryCount = 12

    static func prompt(entries: [ConversationHistoryEntry]) -> String {
        let recentEntries = entries.suffix(maximumEntryCount)
        var historyLines: [String] = []
        for entry in recentEntries {
            let userText = entry.userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userText.isEmpty {
                historyLines.append("用户：\(userText)")
            }
            // AI 侧剥掉动作标签 —— 那是给执行器看的，不是给人读的。
            let assistantText = ActionTagParser
                .speakableTextFromStreamedReply(entry.assistantResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !assistantText.isEmpty {
                historyLines.append("AI：\(assistantText)")
            }
        }

        guard !historyLines.isEmpty else {
            return """
            <chat_history>
            （这通语音之前没有文字记录，直接回答用户的问题。）
            </chat_history>
            """
        }

        return """
        <chat_history>
        以下是用户在文字对话里的聊天内容，作为这次语音交流的参考背景：

        \(historyLines.joined(separator: "\n\n"))
        </chat_history>

        接下来用户会用语音继续问这一话题。要求：
        - 用口语回答，简短直接，一次只说一两句关键内容；
        - 引用上文时不要复述大段原文，直接说结论；
        - 听不清或上下文不够时直接问，不要猜。
        """
    }
}
