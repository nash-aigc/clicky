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
    /// 已经在会话里、但还**没写进任何条目**的用户那句话。
    ///
    /// 用户的转写常常早于回答写盘（服务端先回答、转写最后补）。先攥在手里，
    /// 写回答时把"问在上、答在下"放进**同一条**；否则才单独落一条。
    private var pendingUserTranscript: String?
    /// 当前这一轮回答是不是**用户说话触发的**（只有它会去和用户那句话配对）。
    private var isExpectingUserTranscriptForCurrentTurn = false
    /// 这一轮回答是否由用户说话触发（开场白是 false）—— 只有 true 才允许配对。
    private var isCurrentTurnTriggeredByUserSpeech = false
    /// 排名：每个回合用自己的序号找配对，避免跨回合错配。
    private var currentTurnSequenceNumber = 0

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

    /// 用户说了一句（引擎给的是最终转写）→ 当成 Ask 会话里的一条用户消息落盘。
    ///
    /// 与打字发送走**同一条**存储路径，所以 Ask 页会照常把它渲染出来，
    /// 而且它自然成为下一轮的上下文。
    private func handleUserUtterance(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        liveUserTranscript = ""
        print("🗣️ [user-utterance 回调] 「\(trimmed)」")

        // **服务端是"先听到人说话就开始回答、转写最后才补"**（实测协议时序，与 Chatting
        // 那边 `insertDuplexUserEntry` 同一条理由）。所以用户这句话到达时，AI 那一轮
        // 的文本**往往已经落盘了** —— 直接往后追加就会出现「回复在提问上面」，
        // 而且一问一答会错位（用户截图：问赵金麦、答杨幂）。
        //
        // 规矩：**按邻接配对** —— 如果最后一条正是"还没有用户文本的 AI 回复"，
        // 就把这句话补进**那一条**的开头（一条记录 = 一个回合，问在上、答在下）。
        if let session = currentTargetSession(),
           let pairIndex = pendingAssistantEntryIndex,
           isCurrentTurnTriggeredByUserSpeech,
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
            pendingAssistantEntryIndex = nil
            return
        }

        // 还没有可配对的回答写盘（回答要等回合结束才写）→ **先攥住**，
        // 写回答时把"问在上、答在下"放进同一条；这样即使转写比回答早到，
        // 顺序也是对的。
        pendingAssistantEntryIndex = nil
        pendingUserTranscript = trimmed

        ConversationSessionsStore.appendEntry(
            ConversationHistoryEntry(
                userTranscript: trimmed,
                assistantResponse: "",
                recordedWithActionTags: true
            ),
            targetSessionID: targetSessionID
        )
    }

    /// 助手这一轮开始了：**在这一刻就把条目该落的位置定下来**。
    private func noteAssistantTurnStarted() {
        currentTurnSequenceNumber += 1
        let entryCount = currentTargetSession()?.entries.count ?? 0
        pendingAssistantInsertIndex = entryCount
        isCurrentTurnTriggeredByUserSpeech = isExpectingUserTranscriptForCurrentTurn
        isExpectingUserTranscriptForCurrentTurn = false
    }

    /// 这通电话服务的那个 Ask 会话（读一份最新快照）。
    private func currentTargetSession() -> ConversationSession? {
        guard let targetSessionID else { return nil }
        return ConversationSessionsStore.allSessions().first { $0.id == targetSessionID }
    }

    /// 把 AI 这一轮说的话补进**这一轮那条记录**。
    ///
    /// **一个回合只写一条记录**，与打字那条路同一个形状：用户说话时写一条
    /// （`assistantResponse` 先空着），AI 说完把回复补进**同一条**。
    ///
    /// 之前这里写成了两条（用户一条、AI 另一条），后果在 Ask 页上一眼可见
    /// （用户 2026-09-25 截图报的「总是发很多空白的区域给我」）：
    /// 用户那条的 `assistantResponse` 是空的 → 渲染出一张**空白回复卡**；
    /// AI 那条的 `userTranscript` 是空的 → 那一问一答看起来还被拆散了。
    private func commitAssistantTurn() {
        let spoken = liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        liveAssistantText = ""
        guard !spoken.isEmpty, let sessionID = targetSessionID else { return }

        // 这一轮的用户条目还在等回复（最后一条、用户有内容、回复还是空的）→ 补进去。
        //
        // `ConversationHistoryEntry` 的字段都是 `let`（它是一份不可变记录），所以这里是
        // **整条替换**：用同样的用户文本 + 新的回复文本造一条新的，放回同一个下标。
        if let session = currentTargetSession(),
           let lastIndex = session.entries.indices.last,
           !session.entries[lastIndex].userTranscript.isEmpty,
           session.entries[lastIndex].assistantResponse.isEmpty {
            let pendingEntry = session.entries[lastIndex]
            var updatedEntries = session.entries
            updatedEntries[lastIndex] = ConversationHistoryEntry(
                userTranscript: pendingEntry.userTranscript,
                assistantResponse: spoken,
                recordedWithActionTags: true
            )
            ConversationSessionsStore.replaceEntriesAndSummary(
                entries: updatedEntries,
                summary: session.summary,
                sessionID: sessionID
            )
            return
        }

        // 到这里说明这一轮**还没有条目**（用户那句话还没配对成功）→ 按定格的下标
        // **插入**一条：问在上（如果攥着）、答在下。顺序因此是"回合开始的先后"。
        guard let session = currentTargetSession() else { return }
        let pairedUserTranscript = isCurrentTurnTriggeredByUserSpeech
            ? (pendingUserTranscript ?? "")
            : ""
        if isCurrentTurnTriggeredByUserSpeech { pendingUserTranscript = nil }

        let insertIndex = min(max(pendingAssistantInsertIndex ?? session.entries.count, 0),
                              session.entries.count)
        pendingAssistantInsertIndex = nil

        var updatedEntries = session.entries
        updatedEntries.insert(
            ConversationHistoryEntry(
                userTranscript: pairedUserTranscript,
                assistantResponse: spoken,
                recordedWithActionTags: true
            ),
            at: insertIndex
        )
        ConversationSessionsStore.replaceEntriesAndSummary(
            entries: updatedEntries,
            summary: session.summary,
            sessionID: sessionID
        )
        print("📝 [写盘] 插到 #\(insertIndex)：问「\(pairedUserTranscript.prefix(20))」 答「\(spoken.prefix(20))」")
        // 这条回答后面若还收到用户转写，就该配到它身上。
        pendingAssistantEntryIndex = pairedUserTranscript.isEmpty ? insertIndex : nil
    }
}

// MARK: - 上下文提示词

/// 把 Ask 会话的历史拼成**带标签的提示词**（用户 2026-09-25 指定：
/// 「把 ask 这部分的聊天历史记录当做提示词的前半部分，可以打一个标签……
/// 然后在后面拼接"这是用户的问题"」）。
///
/// 它进的是全双工会话的 `session.instructions`，**只发一次** —— 这正是用户要的
/// 「第一次发送时包含完整上下文，第二次只包含用户说的话」：后续回合上行只有音频。
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
