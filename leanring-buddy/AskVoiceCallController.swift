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
    @Published private(set) var liveAssistantText = ""

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
        liveAssistantText = ""
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
                    self?.liveAssistantText = cumulativeText
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
        liveAssistantText = ""
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
    private func commitAssistantTurn() {
        let spoken = liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        liveAssistantText = ""
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

        // ③ 开场白 / 非用户触发的回合：不写盘。文本只在 Ask 页的实时气泡里出现过。
        print("📝 [写盘] 跳过（非用户触发的回合，如开场白）：「\(spoken.prefix(20))」")
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
