//
//  DuplexVoiceEngine.swift
//  leanring-buddy
//
//  全双工语音：**一条 websocket 上边听边说**，没有分开的 ASR / LLM / TTS。
//
//  它和三段式的区别不是「更快」，是**结构性**的：三段式每一轮都要等用户说完、
//  等转写、等截图、等理解模型、再合成；这一条是把麦克风的音频持续推上去，模型
//  自己决定什么时候该回应，回应的音频也直接推回来播。所以这一条**没有「回合」的
//  概念**，`VoiceChatController` 那边也不会为它开持续监听 —— 两套 VAD 会互相打架，
//  服务端那套已经够了。
//
//  协议是**实测确认过的**（2026-09-24，探针跑在真实服务上，一整轮完整走通）：
//
//      session.created → session.updated                    session.update 被接受
//      input_audio_buffer.speech_started                    ← 服务端 VAD 听到人声
//      input_audio_buffer.speech_stopped / committed        ← 靠静音收尾
//      response.created / response.audio.delta ×9           ← 24 kHz PCM16，3.44 秒
//      conversation.item.input_audio_transcription.completed ← 用户说了什么
//      response.audio_transcript.delta ×9                    ← 助手说了什么
//      response.done
//
//  四条从实测里学到的、错了就静默失效的事：
//
//  1. **上行是 16 kHz、下行是 24 kHz**，两个数不一样，共用一个会有一边变速。
//  2. **不能发 `input_audio_buffer.commit`** —— 回合完全由服务端 VAD 决定，
//     客户端插手会打乱它。
//  3. **静音必须持续送。** 探针第一次两句都失败，就是因为片段结束后就停止发送：
//     `silence_duration_ms` 等不到安静尾巴，回合永远关不掉，模型**一句话都不说**。
//     这里靠麦克风 tap 天然满足（tap 一直在送，包括房间的静音），但这条注释必须
//     留着 —— 将来谁把 tap 挪走或加个「没人说话就停发」的优化，就会踩回去。
//  4. **音色必须是这个模型家族表里的**。填错不是少一个音色，是**整条
//     `session.update` 被拒**（实测 `Unsupported voice: 'Tina'`），连 instructions
//     一起失效。所以选音色前的校验在 `VoiceCatalog`，不在这里。
//

import Foundation
import AVFoundation

@MainActor
final class DuplexVoiceEngine {

    /// 上行音频的格式。实测：必须是 16 kHz 单声道 PCM16。
    /// 服务端判定「这一句说完了」所需的**静音时长**。
    ///
    /// 原来是 700 ms —— 用户 2026-09-25 实测：「我这句话还没说完，停顿时间不超过一秒，
    /// 它都给我当作一句话发送过去了」。700 比人的自然停顿还短（想词、换气常常 0.8~1.2s），
    /// 所以它会把半句话当成一整轮。
    ///
    /// 取 **1200 ms**：覆盖自然的句中停顿，又不会让"说完了"等太久。
    /// 这是**调节点** —— 觉得还是太紧就往上调，觉得反应慢就往下调。
    /// **官方快速上手的示例用的是 800。**
    ///
    /// 它决定「用户说完 → 服务端开始生成」要等多久，也就是用户感受到的那一段
    /// 无声延迟。我们原先写的是 1200，比官方多等 400ms —— 用户 2026-09-25 报
    /// 「声音回复的延迟明显非常大」，这是一处可以直接对上官方的差异。
    /// 来源：官方快速上手 `realtime_quickstart.py` 的 `session.update`
    /// （`"turn_detection": {"type": "server_vad", "threshold": 0.5, "silence_duration_ms": 800}`）。
    private static let turnEndSilenceMilliseconds = 800

    private static let uplinkSampleRate = 16_000.0
    /// 下行音频的格式。实测：服务端回的是 24 kHz 单声道 PCM16。
    private static let downlinkSampleRate = 24_000.0
    /// 上行分块大小：100 ms @16 kHz 单声道 16 bit = 3200 字节。和探针一致。
    private static let uplinkChunkByteCount = 3200

    struct Callbacks {
        /// 用户这句话的**最终**转写（服务端识别完才给）。
        ///
        /// 它比回答的文字 delta **来得晚**（实测：一整轮 9 个 `audio_transcript.delta`
        /// 全部到完，这条才到）—— 服务端是先听到用户说话就开始回答，转写是最后补的。
        /// 调用方据此把用户气泡插到回答气泡**前面**。
        var onUserUtterance: (String) -> Void
        /// **用户正在说的那句话（增量）** —— 服务端从开口那一刻就一直在下发。
        ///
        /// 与 `onUserUtterance` 的分工是**显示 vs 落盘**，两者都要：
        /// - 这一个 → 界面上的用户气泡，让用户的话**开口即现**；
        /// - `onUserUtterance`（`…transcription.completed`）→ 落盘与配对。
        ///
        /// 为什么不能只保留后者：`completed` 实测排在 `response.done` 之后，也就是
        /// **一整轮答完才到**，界面因此要等 AI 说完才知道用户说了什么
        /// （用户 2026-09-25：「用户的提示词在 AI 回复完成之后才突然出现」）。
        ///
        /// 为什么不能只保留前者：增量那份是"还在改"的文本（官方事件里它带一个
        /// `stash` 暂存尾巴），而且与回答不是同一个推理产物；记录必须用最终稿。
        var onUserTranscriptUpdate: (String) -> Void
        /// **用户说完了**（`input_audio_buffer.speech_stopped`），带上此刻那句的完整预览。
        ///
        /// 为什么需要它：Chatting 页要求"用户的提示词一次性展示、不要一个字一个字地显示"。
        /// 但"一次性"**不等于"等一整轮答完"** —— 官方时序图里 `speech_stopped` 紧跟在
        /// 增量之后、`response.created` 之前，所以在这一个点整段显示，既满足"一次性"，
        /// 又是在用户说完的那一刻，而不是等 AI 答完。
        var onUserSpeechStopped: (String) -> Void
        /// **第一段回答音频刚刚排进播放队列** —— 也就是「真的出声了」。
        ///
        /// 连接状态切换到「已连接」必须等它：在那之前对方是不是真的活着、
        /// 真的听得到，用户没有任何证据（2026-09-24 的原始抱怨就是这个）。
        var onFirstAudioScheduled: () -> Void
        /// 用户开口打断了当前回答（`speech_started`）。被掐断的那半截回答就地成为
        /// 完成的一段话，调用方要解掉「这轮回答」的绑定，好让下一句排在它后面。
        var onBargeIn: () -> Void
        /// **服务端听到用户开口了**（`input_audio_buffer.speech_started`）。
        ///
        /// 调用方靠它区分两种回答：**用户说话触发的**（该和用户那句话配成一对）
        /// 与**我们自己发起的**（开场白 —— 它不属于任何一轮提问，绝不能被配对）。
        var onUserSpeechStarted: () -> Void
        /// **助手这一轮开始了**（`response.created`）。
        ///
        /// 调用方据此**在这一刻就把条目排好位**：条目的顺序必须按"回合开始的先后"，
        /// 而不是"回合结束的先后" —— 后者会让上一轮的回答插到下一轮提问的后面
        /// （用户 2026-09-25 实测的顺序错乱）。
        var onAssistantTurnStarted: () -> Void
        /// 助手这一轮的累计文字，每次 delta 都回调一次。
        var onAssistantText: (String) -> Void
        /// 这一轮回答结束（`response.done`）。
        var onAssistantTurnFinished: () -> Void
        /// **会话配置被服务端接受了**（`session.updated`）—— 这一场已经建好，
        /// 可以开始说话。
        ///
        /// 它和 `onFirstAudioScheduled` 是两件事，**别混**：
        /// · 这个 = 「连通了」；
        /// · 那个 = 「对方真的出声了」（Chatting 用它来兑现"已连接"，因为那边
        ///   连上就会打招呼，出声是必然的）。
        /// Ask 语音电话**不打招呼**（用户要求：没说话之前什么都不发），所以那边
        /// 只能拿这一个当"接通"的判据 —— 否则界面会永远停在「连接中…」，
        /// 2026-09-25 用户报的正是这个。
        var onSessionConfigured: () -> Void

        /// 任何致命问题：连接失败、服务端报错。文字是可以直接显示给用户的中文。
        var onFailure: (String) -> Void
    }

    private let playbackEngine: VoicePlaybackEngine
    private let callbacks: Callbacks

    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)
    private let pcm16Converter = BuddyPCM16AudioConverter(targetSampleRate: uplinkSampleRate)

    /// 未凑满一个 100 ms 块的字节。和识别那边同一套攒块逻辑。
    private var pendingUplinkAudio = Data()
    /// 服务端是否正在产出一轮回答。`response.cancel` 只有在这个为真时才允许发
    /// （实测：没有活跃回答时发它，服务端回 `Conversation has none active response`）。
    private var isResponseActive = false

    // MARK: - 本地打断（VAD）

    /// 上行电平（由音频线程投递到主线程，与 `BuddyDictationManager` 同一套算法）。
    private var latestUplinkLevel: Double = 0
    private var smoothedUplinkLevel: Double = 0

    /// **打断不再等服务端。**
    ///
    /// 三段式的打断是「瞬间」的，靠的是**本地能量 VAD**：电平过阈值就地停播放，
    /// 整个判定在同一进程里（见 `BuddyDictationManager.runContinuousListeningVADLoop`）。
    /// 全双工原先只用服务端 `server_vad` —— 打断要等「100ms 攒块 + 上行 + 服务端判定 +
    /// 下行事件」，结构上不可能瞬间（用户 2026-09-25：「三段式瞬间打断，全双工没有打断」）。
    ///
    /// 这里把同一套判据搬过来（**同一个阈值 0.25、同一个 0.20 秒累计**，理由见
    /// `BuddyDictationManager` 里那两处校准注释：安静房间的底噪峰值实测 0.167，
    /// 说话 0.3~1.0），于是"用户开口那一瞬间就停"对两种模式是同一件事。
    private var speechAccumulatorSeconds: Double = 0
    private var didRequestLocalBargeIn = false
    private var localBargeInTask: Task<Void, Never>?

    /// 打断之后、下一轮开始之前，到达的助手音频要**丢掉**。
    ///
    /// 否则 `stopStreamingPlayback()` 只清空一次队列，随后到达的 delta 会把声音
    /// **重新排回去**（实测报告里指出的第二条独立缺陷：回答文字已结束、声音还在播
    /// 的那段插话"一个字节都不停"）。它在下一次 `response.created` 时清掉。
    private var isDiscardingAssistantAudio = false

    /// 上行首块日志只打一次（`appendUplinkAudio` 在音频线程上，所以走 MainActor 写）。
    nonisolated(unsafe) private var hasLoggedFirstUplinkChunk = false
    /// 按序上行的泵（nil = 没在跑）。
    private var uplinkPumpTask: Task<Void, Never>?
    /// 已发出的上行块序号（日志用）。
    private var uplinkSequenceNumber = 0

    /// 本地 VAD 的判据（与三段式同一套数）。
    private static let bargeInLevelThreshold: Double = 0.25
    private static let bargeInAccumulatedSeconds: Double = 0.20
    private static let bargeInPollIntervalSeconds: Double = 0.05
    /// 有没有收到 `session.created` —— `session.update` 的前置条件。
    private var didSeeSessionCreated = false
    /// 有没有收到 `session.updated` —— `session.update` 已被服务端应用的确认。
    private var didSeeSessionUpdated = false
    /// 这一场会话里有没有出声过（见 `Callbacks.onFirstAudioScheduled`）。
    private var hasScheduledFirstAudio = false
    /// 这一轮助手文字的累计值。
    private var currentAssistantText = ""

    /// 增量用户转写事件到达的计数（探针）—— 见诊断分支里的说明。
    private var inputTranscriptionDeltaCount = 0

    /// 本轮第一块助手音频到达的时刻（探针用）。
    private var firstAssistantAudioChunkAt: Date?

    /// 事件流打点用的时间戳（秒，带毫秒）。延迟只能量，不能猜。
    private static func eventLogTimestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }

    // MARK: 用户转写的累积（官方的 `text` 是按句的，跨句要自己攒）
    //
    // 三个量对应官方 `conversation.item.input_audio_transcription.delta` 的语义：
    //   confirmedUserTranscript —— 前面几句已经定稿的（官方那里 `text` 会按句重置，
    //                              重置前必须先并进来，否则前面说的话会消失）
    //   currentUserSettledText  —— 当前这一句已确认的前缀（官方 `text`）
    //   currentUserStashedText  —— 当前这一句还在改的尾巴（官方 `stash`）
    // 显示 = 三者拼接。
    private var confirmedUserTranscript = ""
    private var currentUserSettledText = ""
    private var currentUserStashedText = ""

    /// 此刻用户那句话的完整预览（官方定义的 `text + stash`，加上我们自己攒的前几句）。
    var currentUserTranscriptPreview: String {
        (confirmedUserTranscript + currentUserSettledText + currentUserStashedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一次用户发言结束 —— 把三个量清空，下一句从零开始。
    ///
    /// 在 `speech_started` 里调（**不是** `speech_stopped`）：官方时序图里
    /// `speech_started` 是"这一轮开口"的起点，而 `.delta` 紧跟着它开始下发。
    private func resetUserTranscriptAccumulators() {
        confirmedUserTranscript = ""
        currentUserSettledText = ""
        currentUserStashedText = ""
    }
    private var isStopped = false

    init(playbackEngine: VoicePlaybackEngine, callbacks: Callbacks) {
        self.playbackEngine = playbackEngine
        self.callbacks = callbacks
    }

    // MARK: - 开 / 关

    /// 起一条会话。
    ///
    /// - Parameters:
    ///   - role: 角色 —— 系统提示词从它读。
    ///   - model: 这一场用哪个实时模型（来自**预设**）。
    ///   - voiceID: 这一场用哪个音色。**必须是能力层校验过的那个**
    ///     （`VoiceCatalog.capability(...).effectiveVoiceID`）：跨族音色会让整条
    ///     `session.update` 被拒，而那句错误完全不提音色（见下面的错误分支）。
    func start(role: VoiceChatRole, model: String, voiceID: String, systemPrompt: String) async throws {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw BailianTTSClientError(message: "还没有配置「说」这个角色（设置 → 模型），无法开始全双工语音。")
        }

        let websocketBaseURL = resolvedSpeechRole.baseURL.replacingOccurrences(of: "https://", with: "wss://")
        guard let websocketURL = URL(string: "\(websocketBaseURL)/api-ws/v1/realtime?model=\(model)") else {
            throw BailianTTSClientError(message: "全双工语音的 websocket 地址拼不出来：\(websocketBaseURL)")
        }

        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Bearer \(resolvedSpeechRole.apiKey)", forHTTPHeaderField: "Authorization")
        // 这个端点族要求它，缺了握手会被拒（识别那条实时链路用的是同一个头）。
        websocketRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        isStopped = false

        // **会话级状态必须在"会话开始"这一刻清干净。**
        //
        // 引擎实例是**跨会话复用**的（Chatting 那台是 lazy 常驻，Ask 语音电话每次新建），
        // 而这三个字段原先只在 `stop()` 里清 —— 于是任何一条**没走 stop 的结束路径**
        // （socket 自己断了、错误分支、上一场还在回答时就换了会话）都会把脏状态带进下一场：
        //
        //   · `hasScheduledFirstAudio` 残留 true → 下一场的 `onFirstAudioScheduled`
        //     **永不触发**。而它正是"接通"的判据（Chatting 的「已连接」、Ask 语音电话的
        //     「通话中」都等它）→ 界面永远停在「连接中」（用户 2026-09-25 报的）
        //   · `isResponseActive` 残留 true → 打断时会发 `response.cancel`，而那一场
        //     并没有活跃回答 → 服务端回 **`Conversation has no active response.`**
        //     （用户截图里那条报错的原文），同时打断逻辑也会被这个脏标志带偏
        //   · `currentAssistantText` 残留 → 下一场的助手文本会从上一场**接着累加**
        //
        // 写成"start 重置"而不是"再多加几个 stop 调用点"：**会话的状态属于会话**，
        // 清它的地方就该是开始的地方 —— 补 stop 的调用点是在追着症状跑。
        isResponseActive = false
        hasScheduledFirstAudio = false
        // **会话的状态属于会话**：这个引擎实例在 Chatting 页是 lazy 复用、跨会话
        // 不重建的，所以用户转写的三个累加器必须在这里清 —— 只靠 `speech_started`
        // 清，会让一条说到一半就断掉的会话把文字留在下一次通话里。
        resetUserTranscriptAccumulators()
        currentAssistantText = ""
        isDiscardingAssistantAudio = false
        didRequestLocalBargeIn = false
        speechAccumulatorSeconds = 0
        smoothedUplinkLevel = 0
        uplinkSequenceNumber = 0
        pendingUplinkAudio.removeAll()
        didSeeSessionCreated = false
        didSeeSessionUpdated = false
        startLocalBargeInWatch()
        let task = urlSession.webSocketTask(with: websocketRequest)
        webSocketTask = task
        task.resume()
        receiveNextMessage()

        // 先等 `session.created` 再发 `session.update` —— 官方事件顺序，反过来配不上去。
        try await waitForSessionCreated(timeoutSeconds: 8)

        try await sendJSON([
            "type": "session.update",
            "session": sessionConfiguration(
                voice: voiceID,
                model: model,
                systemPrompt: systemPrompt
            )
        ])
        // 这一行是「音色到底有没有生效」的判据：它必须等于用户在音色面板里点的那个。
        print("💬 全双工会话：model=\(model) voice=\(voiceID)")

        // **等配置确认再继续**：装 tap、返回调用方（随后就是问候语）都必须发生在
        // 服务端应用完配置**之后** —— 否则问候语的 response.create 会被静默丢弃，
        // 界面永远停在「连接中」（2026-09-25 实测）。
        try await waitForSessionUpdated(timeoutSeconds: 8)

        // 麦克风上行。装在**共享播放引擎**上：voice processing 的回声消除只对它自己
        // 渲染的音频有效，所以话筒必须和「正在播的回答」在同一个引擎上，否则模型会
        // 听见自己刚说的话。
        try await playbackEngine.installInputTap(bufferSize: 1024) { [weak self] buffer, _ in
            self?.appendUplinkAudio(from: buffer)
        }
        // **上行可见性**：这条链原先一行日志都没有，于是"麦克风有没有在送"完全不可查
        // （2026-09-25 两路调查都点了这件事）。首块音频到达时打一行就够定位。
        print("🎙️ 全双工会话：麦克风 tap 已装好（共享播放引擎）")
        isRunning = true
    }

    /// `session.update` 的内容。抽出来是因为**每一个字段都踩过坑**，散在调用处
    /// 会被改坏：
    ///
    /// · `turn_detection` 用**服务端的 VAD**（`server_vad`）。客户端自己判回合会和
    ///   它抢；而且实测这一族只认 `server_vad` / `smart_turn` / `smart_turn_v2` / null。
    /// · `silence_duration_ms` 给它足够长，让用户思考时的停顿不会被当成说完 ——
    ///   这是实测第一句失败的直接原因（片段结束在语音上，没有安静尾巴）。
    /// · `max_history_turns` 只属于这一族（全模态没有这个参数），所以放在这里而不是
    ///   当成通用字段。
    private func sessionConfiguration(voice: String, model: String, systemPrompt: String) -> [String: Any] {
        var configuration: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": voice,
            "audio": [
                "input": ["format": ["type": "pcm", "sample_rate": Int(Self.uplinkSampleRate)]],
                "output": ["format": ["type": "pcm", "sample_rate": Int(Self.downlinkSampleRate)]]
            ],
            "turn_detection": ["type": "server_vad", "threshold": 0.5, "silence_duration_ms": Self.turnEndSilenceMilliseconds]
        ]
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            configuration["instructions"] = trimmedPrompt
        }
        return configuration
    }

    /// 本地 VAD 轮询：每 50 ms 看一次平滑后的电平（与三段式同一个节拍）。
    private func startLocalBargeInWatch() {
        localBargeInTask?.cancel()
        localBargeInTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(Self.bargeInPollIntervalSeconds * 1000)))
                guard let self, !self.isStopped else { return }
                self.smoothedUplinkLevel = max(self.latestUplinkLevel, self.smoothedUplinkLevel * 0.72)
                if self.smoothedUplinkLevel >= Self.bargeInLevelThreshold {
                    self.speechAccumulatorSeconds += Self.bargeInPollIntervalSeconds
                    if self.speechAccumulatorSeconds >= Self.bargeInAccumulatedSeconds,
                       !self.didRequestLocalBargeIn {
                        self.didRequestLocalBargeIn = true
                        self.performLocalBargeIn()
                    }
                } else {
                    self.speechAccumulatorSeconds = 0
                }
            }
        }
    }

    /// 用户开口了（本地判定）→ **就地停声**，不等服务端。
    private func performLocalBargeIn() {
        playbackEngine.stopStreamingPlayback()
        isDiscardingAssistantAudio = true
        print("🎙️ 全双工会话：本地判定用户开口 —— 就地停声")
        callbacks.onBargeIn()
        // 服务端那一轮只有真的还在进行时才需要撤销；不是就不发（发了会得到一个
        // 冗余的请求级错误，而那个错误曾经把整场会话收掉）。
        if isResponseActive {
            Task { try? await self.sendJSON(["type": "response.cancel"]) }
        }
    }

    /// 有没有真的起过一次会话。
    ///
    /// **它保护的不是自己，是别的模式。** `stop()` 会去拆共享播放引擎上的麦克风
    /// tap —— 而三段式的持续监听**用的是同一根 tap**。挂断那条路（`disconnectCurrentSession`）
    /// 是三种模式共用的，所以在三段式里调一次 `stop()` 就会把三段式自己的麦克风拆掉：
    /// 用户说话，谁也听不到（2026-09-24 实测到的就是这个）。
    private(set) var isRunning = false

    func stop() {
        // 没起过就什么都不做：连 tap 都不该碰。`duplexVoiceEngine` 是 lazy 的，
        // 所以这条 guard 同时挡住了「三段式里凭空构造一个全双工引擎」。
        let wasRunning = isRunning
        isRunning = false

        isStopped = true
        didSeeSessionUpdated = false
        isResponseActive = false
        hasScheduledFirstAudio = false
        pendingUplinkAudio.removeAll()
        currentAssistantText = ""

        localBargeInTask?.cancel()
        localBargeInTask = nil
        uplinkPumpTask?.cancel()
        uplinkPumpTask = nil
        if wasRunning {
            playbackEngine.removeInputTap()
            playbackEngine.stopStreamingPlayback()
        }
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    /// 让 AI 先开口说一句 —— 既是打招呼，也是「连接真的通了」的可听证据。
    ///
    /// 协议形状与试听那条路完全一致（`VoicePreviewService` 的实时分支，已实测）：
    /// 放一条**文字**用户消息，再触发一次 response。文字消息**不会**变成用户气泡
    /// —— 界面上的用户气泡来自 `conversation.item.input_audio_transcription.completed`
    /// （语音转写事件），文字消息不产生那个事件。
    func speakGreeting(_ greetingText: String) async throws {
        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": greetingText]]
            ]
        ])
        try await sendJSON(["type": "response.create"])
    }

    /// 用户主动打断当前回答（页面的「挂断」以外的打断入口）。
    ///
    /// **只有服务端正在产出回答时才发 cancel**（实测：没有活跃回答时发它，服务端
    /// 回 `Conversation has none active response`）。
    func cancelCurrentResponse() {
        guard isResponseActive else { return }
        playbackEngine.stopStreamingPlayback()
        Task { try? await sendJSON(["type": "response.cancel"]) }
    }

    // MARK: - 上行

    /// 麦克风来的音频 → 16 kHz PCM16 → 攒够 100 ms 发一块。
    ///
    /// 这个方法在音频线程上被调，所以**不发网络请求**：只做转换和攒块。
    nonisolated private func appendUplinkAudio(from buffer: AVAudioPCMBuffer) {
        // 电平在音频线程上算（与 `BuddyDictationManager` 的 tap 同一个公式），
        // 只把**一个数**投到主线程 —— 音频线程上不做任何别的事。
        if let channelData = buffer.floatChannelData?[0] {
            let frameCount = Int(buffer.frameLength)
            if frameCount > 0 {
                var sumOfSquares: Double = 0
                for index in 0..<frameCount {
                    let sample = Double(channelData[index])
                    sumOfSquares += sample * sample
                }
                let rootMeanSquare = (sumOfSquares / Double(frameCount)).squareRoot()
                let level = rootMeanSquare * 10.2
                Task { @MainActor [weak self] in self?.latestUplinkLevel = level }
            }
        }

        guard let pcm16Data = pcm16Converter.convertToPCM16Data(from: buffer), !pcm16Data.isEmpty else { return }
        // 只在音频线程上读写这一个 Bool（tap 的回调是串行的），打印丢给主线程。
        if !hasLoggedFirstUplinkChunk {
            hasLoggedFirstUplinkChunk = true
            let chunkByteCount = pcm16Data.count
            Task { @MainActor in
                print("🎙️ 全双工会话：第一块上行音频已就绪（\(chunkByteCount) 字节）")
            }
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isStopped, self.webSocketTask != nil else { return }
            self.pendingUplinkAudio.append(pcm16Data)
            self.pumpUplinkChunksInOrder()
        }
    }

    /// **按序上行的泵。**
    ///
    /// 原来每块音频一个独立 `Task` 发送 —— Swift 的 Task **不保证按创建顺序执行**，
    /// 于是 websocket 上的字节序 = 实际执行序，音频可能乱序到达服务端。模型听到的
    /// 就是被打乱的语音：**转写不是用户说的话、回答答非所问、还慢一拍**（用户
    /// 2026-09-25 报的三个症状，一个原因）。
    ///
    /// 现在改成单一消费者：按切分顺序逐块 `await` 发送，前一块没发完就不取下一块。
    /// `await` 会挂起泵、让出 MainActor，所以不会卡界面；顺序由此得到保证。
    private func pumpUplinkChunksInOrder() {
        guard uplinkPumpTask == nil else { return }   // 已有泵在跑，它会把队列抽干
        uplinkPumpTask = Task { [weak self] in
            guard let self else { return }
            defer { self.uplinkPumpTask = nil }
            while !self.isStopped, self.webSocketTask != nil {
                // **必须在同一个同步段里"看一眼 + 取走"**：`stop()` 会在泵挂起期间
                // `removeAll()` 这个队列（2026-09-25 崩溃：`Can't remove more items
                // from a collection than it contains` —— 泵恢复后拿着过期的余量去
                // remove）。取块数量按**当下**的余量算，永不多取。
                let chunkByteCount = min(Self.uplinkChunkByteCount, self.pendingUplinkAudio.count)
                guard chunkByteCount > 0 else { return }
                let chunk = Data(self.pendingUplinkAudio.prefix(chunkByteCount))
                self.pendingUplinkAudio.removeFirst(chunkByteCount)
                self.uplinkSequenceNumber += 1
                let sequenceNumber = self.uplinkSequenceNumber
                // 串行 await：这一块发完（成功或失败）才发下一块。
                try? await self.sendJSON([
                    "type": "input_audio_buffer.append",
                    "audio": chunk.base64EncodedString()
                ])
                if sequenceNumber <= 3 || sequenceNumber % 50 == 0 {
                    print("🎙️ 上行块 #\(sequenceNumber)（\(chunkByteCount)B）已发出")
                }
            }
        }
    }

    // MARK: - 收发

    private func receiveNextMessage() {
        guard let webSocketTask else { return }
        webSocketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleServerEvent(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleServerEvent(text) }
                    @unknown default: break
                    }
                    self.receiveNextMessage()
                case .failure(let error):
                    // 连接断了就结束会话，并把原因交给界面 —— 沉默地停掉是最糟的：
                    // 用户会以为「它在听」，其实早就没了。
                    let description = error.localizedDescription
                    self.stop()
                    self.callbacks.onFailure("全双工语音的连接断了：\(description)")
                }
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        // **全事件流仪器**（2026-09-25）：顺序问题已经改了五次没修好，从这一次起
        // 先看数据再下结论。每个关键事件都带 response_id / item_id / 文本前缀，
        // 复现一次之后，"谁先谁后、哪条回答属于哪个回合、转写到底说了什么"
        // 全部可以从日志直接读出来 —— 不再需要任何推测。
        switch type {
        case "input_audio_buffer.speech_started":
            print("🎧 [event t=\(Self.eventLogTimestamp())] speech_started（服务端听到用户开口）")
        case "input_audio_buffer.speech_stopped":
            print("🎧 [event] speech_stopped（服务端判定用户说完）")
        case "input_audio_buffer.committed":
            print("🎧 [event] committed（用户音频已提交）")
        case "conversation.item.input_audio_transcription.completed":
            let userText = event["transcript"] as? String ?? ""
            let itemID = event["item_id"] as? String ?? "-"
            print("🎧 [user-transcript] item=\(itemID.prefix(12)) 「\(userText)」")
        case "conversation.item.input_audio_transcription.delta":
            // 增量转写存在与否，只能靠日志回答：官方文档说服务端从 `speech_started`
            // 起就增量下发，但**我们的 `session.update` 是否足以让它真的下发**、
            // 以及用的是哪个转写模型（官方示例是 `fun-asr`），文档没有对照实验。
            // 所以这里打一行 —— 有它，用户的话就能开口即现；没有它，就只能等
            // `completed`（实测排在 `response.done` 之后）。
            let settledText = event["text"] as? String ?? ""
            let stashedText = event["stash"] as? String ?? ""
            if inputTranscriptionDeltaCount == 0 {
                print("🎧 [user-transcript-delta] 首个增量事件已到达 —— text「\(settledText.prefix(20))」 stash「\(stashedText.prefix(20))」")
            }
            inputTranscriptionDeltaCount += 1
        case "response.created":
            let responseID = (event["response"] as? [String: Any])?["id"] as? String ?? "-"
            print("🎧 [response.created t=\(Self.eventLogTimestamp())] id=\(responseID.prefix(16))")
        case "response.done":
            let responseID = (event["response"] as? [String: Any])?["id"] as? String ?? "-"
            print("🎧 [response.done] id=\(responseID.prefix(16))")
        case "response.audio_transcript.delta":
            let responseID = event["response_id"] as? String ?? "-"
            let delta = event["delta"] as? String ?? ""
            print("🧾 [ai-text +\(delta.count)字] resp=\(responseID.prefix(10)) 累计\((currentAssistantText + delta).count)字：「\(delta.prefix(24))」")
        case "response.audio_transcript.done":
            // 官方权威全文到达 —— 与累积值一对比就知道增量有没有丢过片。
            let responseID = event["response_id"] as? String ?? "-"
            let transcript = event["transcript"] as? String ?? ""
            print("🧾 [ai-text-done] resp=\(responseID.prefix(10)) 官方全文 \(transcript.count) 字（累积值 \(currentAssistantText.count) 字）")
        case "response.audio.delta":
            // 只在**第一块**打时间戳：延迟是「什么时候出声」，不是"有多少块"。
            let responseID = event["response_id"] as? String ?? "-"
            if firstAssistantAudioChunkAt == nil {
                firstAssistantAudioChunkAt = Date()
                print("🔊 [ai-audio首块 t=\(Self.eventLogTimestamp())] resp=\(responseID.prefix(10))")
            }
        case "session.updated":
            print("🎧 [event] session.updated（配置被接受）")
        case "session.created":
            print("🎧 [event] session.created")
        case "error":
            break   // 下面原有分支已打印完整错误
        default:
            break
        }

        switch type {
        case "session.updated":
            didSeeSessionUpdated = true
            callbacks.onSessionConfigured()

        case "session.created":
            didSeeSessionCreated = true

        case "input_audio_buffer.speech_started":
            callbacks.onUserSpeechStarted()
            // 用户开口 = 打断。服务端自己会处理回合，客户端要做的只是**别再出声**。
            cancelCurrentResponse()
            callbacks.onBargeIn()
            // **一次用户发言 = 一次回答的边界**，助手文字的累加器在这里清零。
            //
            // 原先它在 `response.created` 里清零，那是个**错误的边界**：实测
            // （2026-09-25，日志 `🧾 [ai-text …]` 的 resp id）服务端把**一条**回答
            // 拆成多次 `response.created`/`response.done`（一次实测拿到 3 段），
            // 于是每条回答都被切成几截，屏幕上表现为一堆只装几个字的碎卡片
            // ——用户报的「全双工回复乱码／只显示一部分」正是这个。
            currentAssistantText = ""
            resetUserTranscriptAccumulators()

        case "input_audio_buffer.speech_stopped":
            // **用户说完的那一刻。** 官方时序图：它紧跟在增量转写之后、`response.created`
            // 之前。Chatting 页要的"一次性展示"就落在这里 —— 既不是一个字一个字地长，
            // 也不用等 AI 答完。见 `Callbacks.onUserSpeechStopped`。
            let preview = currentUserTranscriptPreview
            if !preview.isEmpty { callbacks.onUserSpeechStopped(preview) }

        case "response.created":
            isResponseActive = true
            callbacks.onAssistantTurnStarted()
            // 新一轮开始：解开"丢弃助手音频"的闸，并允许下一次打断（每句只打断一次）。
            isDiscardingAssistantAudio = false
            didRequestLocalBargeIn = false
            speechAccumulatorSeconds = 0
            // **这里不清 `currentAssistantText`** —— 服务端会在同一条回答中途再发
            // `response.created`，那只是一个"继续生成"的分段信号，不是新回答。
            // 边界见上面的 `speech_started`。

        case "response.audio.delta":
            // **打断之后到达的音频要丢掉**：`stopStreamingPlayback()` 只清空一次队列，
            // 不清这个闸的话，随后的 delta 会把声音重新排回去（用户听到的就是"打断了还在说"）。
            guard !isDiscardingAssistantAudio else { return }
            guard let delta = event["delta"] as? String,
                  let pcmData = Data(base64Encoded: delta) else { return }
            try? playbackEngine.playStreamingPCM16(pcmData, sampleRate: Self.downlinkSampleRate)
            if !hasScheduledFirstAudio {
                hasScheduledFirstAudio = true
                callbacks.onFirstAudioScheduled()
            }

        case "response.audio_transcript.delta":
            // 助手的文字。**实测确认是这个名字**（官方某一页写的是
            // `response.output_audio_transcript`，代码里这个才是真的）。
            guard let delta = event["delta"] as? String else { return }
            currentAssistantText += delta
            callbacks.onAssistantText(currentAssistantText)

        case "response.audio_transcript.done":
            // **官方给的"完整字幕文本"，我们原先完全没接。**
            //
            // 官方服务端事件页：`response.audio_transcript.done` —— 「音频模式下的字幕
            // 输出完成事件」，字段 `transcript` = 「完整的字幕文本」。**两份官方快速
            // 上手的接收循环都只读这一个事件、从不拼增量**
            // （`elif t == "response.audio_transcript.done": print(f"[AI] {event['transcript']}")`）。
            //
            // 而我们只接了 `response.audio_transcript.delta`，靠 `+=` 累积 —— 而那个
            // "增量只增不重"的前提**官方没有写**：同一页对
            // `conversation.item.input_audio_transcription.delta` 明确写了
            // 「实时预览句子 = text + stash」，对 `response.function_call_arguments.delta`
            // 也写了要按接收顺序拼接，**唯独助手文字这一条什么规则都没给**。
            //
            // 所以把服务端给的完整文本作为**权威值**落下来：增量若丢过一片、或与音频
            // 不同步，累积值会静默偏短，而这一步能自愈 —— 不靠任何未成文的假设。
            //
            // 只在它**不比累积值短**时才采用：多段回答（官方说只有 Function Calling
            // 会产生，本 App 没开 tools）里后一段的 done 更短，直接替换会把前一段吃掉，
            // 那就从"补齐"变成了"丢字"。
            guard let transcript = event["transcript"] as? String,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if transcript.count >= currentAssistantText.count {
                currentAssistantText = transcript
            }
            callbacks.onAssistantText(currentAssistantText)

        case "conversation.item.input_audio_transcription.delta":
            // **用户正在说的话，服务端从开口那一刻就在增量下发。**
            //
            // 官方服务端事件参考（阿里云 `qwen-audio-realtime-server-events`）写着：
            //   「服务端检测到语音开始，返回 `input_audio_buffer.speech_started`，
            //     同时流式返回 ASR 转写增量 `conversation.item.input_audio_transcription.delta`」
            // 事件体带两个字段（官方示例）：
            //   { "text": "你好", "stash": "世界" }
            // `text` 是已确定的部分，`stash` 是还没定稿的暂存尾巴 —— 两个拼起来才是
            // 此刻完整的一句话。
            //
            // **原先这里只有 `completed` 一个分支**，所以界面要等很久才知道用户说了
            // 什么 ——复核用项目自己的日志定的实：`speech_started → speech_stopped →
            // committed → response.created → 十条 ai-text → [user-transcript] → …
            // → response.done`，也就是 `completed` 排在**回答的文字全部流完之后**。
            // （这里原先写的是"排在 response.done 之后"，与文件头 `:19` 记录的实测
            // 序列互相矛盾，已按日志改正。）用户 2026-09-25 报的「用户的提示词在 AI
            // 回复完成之后才突然出现」就是这个，而不是协议做不到。
            // 这一条只补了"没接的那个事件"，没有第二条识别、没有第二个 websocket。
            let settledText = event["text"] as? String ?? ""
            let stashedText = event["stash"] as? String ?? ""

            // ## `text` 是**按句**的，跨句必须自己攒
            //
            // 这一条不看官方会写错：阿里云的姊妹页（Qwen-ASR-Realtime / Omni-Realtime
            // 服务端事件）对这两个字段有完整定义，还配了 T1~T7 的对照表：
            //
            //   text  —— 已确认的文本前缀：当前句子中模型已确认不会再变更的部分
            //   stash —— 预识别的文本后缀：仍在处理、可能会被修正的临时草稿
            //   **实时预览句子 = text + stash**
            //
            // 而那张表同时暴露一个细节：**一句话内 `text` 只增不减，换句会重置**
            // （T4 停顿后 `text` 是整句、`stash` 为空；下一句来时又从空开始）。
            // 所以直接显示 `text + stash` 会**把前面说过的话丢掉** —— 用户说三句，
            // 屏幕上只剩最后一句。
            //
            // 判据：新来的 `text` 不再是上一个 `text` 的延长（`hasPrefix` 不成立）
            // = 换句了 → 把上一句并进已定稿的前缀。
            // 判据分三种，**不能用一条 `hasPrefix` 了事** —— 复核指出那样分不清
            // "换句"和"服务端回改"，后者会把同一句显示两遍（「今天天气」被改成
            // 「天气」时会变成「今天天气天气」）。
            if settledText.hasPrefix(currentUserSettledText) {
                // ① 变长（或没变）：正常推进。
                currentUserSettledText = settledText
            } else if currentUserSettledText.hasPrefix(settledText) {
                // ② **变短 = 服务端回改。** 官方说 `text` 是「已确认、不会再变更」的，
                //    那是**意图描述，不是协议约束**。保留更长的那份：已经给用户看过
                //    的字不该凭空消失。
                //    （什么都不做。）
            } else {
                // ③ 既不是延长也不是回改 → 真的换句了：把上一句并进已定稿前缀。
                //
                //    注意这里**是推断，不是实测**：官方 T1~T7 那张表只演示了一句话，
                //    中间那次停顿（T4）`text` 并没有重置，所以"按句重置"官方**没有写**。
                //    留这个分支是因为姊妹页把 `text` 定义成"当前句子中"的已确认部分 ——
                //    若真有重置，不攒就会丢掉前面说的话。
                confirmedUserTranscript += currentUserSettledText
                // 句间补一个分隔：不补的话英文会连成 "Helloworld"（Ask 页有英文对话）。
                if let lastCharacter = currentUserSettledText.last, lastCharacter.isLetter || lastCharacter.isNumber {
                    confirmedUserTranscript += " "
                }
                currentUserSettledText = settledText
            }
            currentUserStashedText = stashedText
            let preview = (confirmedUserTranscript + settledText + stashedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty { callbacks.onUserTranscriptUpdate(preview) }

        case "conversation.item.input_audio_transcription.completed":
            // 整段的最终稿（官方：`transcript` 是「完整的转写文本」，并会写进 item）。
            // 它才是落盘与配对的依据；增量那份只用于显示。
            guard let transcript = event["transcript"] as? String else { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { callbacks.onUserUtterance(trimmed) }

        case "response.done":
            isResponseActive = false
            callbacks.onAssistantTurnFinished()

        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
                ?? String(text.prefix(200))
            let errorParam = (event["error"] as? [String: Any])?["param"] as? String ?? ""
            // **「撤销一个不存在的回答」不是致命错误，是打断的副产品。**
            //
            // 服务端收到我们的 `response.cancel` 时，它那一轮可能刚好自己结束了
            // （`response.done` 早于音频播完就到达），于是回一个请求级错误。
            // 实测（2026-09-25，三份日志）：每一次打断后面都紧跟这一条，
            // 而它曾经被当成致命错误 → 整场会话被挂断 —— 用户看到的「我一说话它就没了」
            // 就是这个。这里只记一行，绝不收尾。
            if errorParam == "response.cancel" || message.lowercased().contains("no active response") {
                print("⚠️ 全双工会话：打断时的 cancel 冗余（服务端那一轮已结束）—— 忽略")
                return
            }
            // **原文照打**：这句是排查"连上就断"唯一的线索（实测 2026-09-25：
            // Ask 语音电话每次接通后立刻被 onFailure 收尾，而日志里只有"已挂断"，
            // 因为错误原文只去了 UI）。code / param / type 一起打，服务端有时把
            // 真正的原因放在它们里面，message 反而很泛。
            let errorObject = event["error"] as? [String: Any] ?? [:]
            print("❌ 全双工会话服务端报错：message=\(message) code=\(errorObject["code"] ?? "-") type=\(errorObject["type"] ?? "-") param=\(errorObject["param"] ?? "-")")
            // 音色不合法会让整条 session.update 被拒 —— 那句话完全不提音色，所以这里
            // 主动把它翻出来，否则用户只会看到「连上了但一句话都不说」。
            if message.contains("Unsupported voice") {
                callbacks.onFailure("这个音色不被全双工语音支持，整条会话配置都被拒了。"
                                    + "回设置 → 音色查看 → 全双工语音，换一个家族内的音色。")
            } else {
                callbacks.onFailure("全双工语音报错：\(message)")
            }

        default:
            break
        }
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let webSocketTask else { return }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocketTask.send(.string(text))
    }

    /// **等 `session.updated` 确认** —— 服务端应用完 `session.update` 才会发它。
    ///
    /// 不等它的后果（2026-09-25 实测，Ask 语音电话）：问候语的 `response.create`
    /// 与服务端应用配置**赛跑**，配置还没应用完，`response.create` 被服务端**静默丢弃**
    /// （没有任何报错、没有任何 response 事件）—— 界面永远停在「连接中」，15 秒兜底
    /// 都等不到一声「你好」。日志证据：`session.updated` 排在问候语发出之后，且全程
    /// 零个 `response.created`。
    ///
    /// 协议的事件顺序本身就是 `session.created → session.updated`（应用完的确认），
    /// 所以"等它"是官方语义的一部分，不是 workaround。
    private func waitForSessionUpdated(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while didSeeSessionUpdated == false, Date() < deadline, !isStopped {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard didSeeSessionUpdated else {
            throw BailianTTSClientError(
                message: "全双工会话配置没有在 \(Int(timeoutSeconds)) 秒内被确认（session.updated 未到达）。"
            )
        }
    }

    private func waitForSessionCreated(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while didSeeSessionCreated == false, Date() < deadline, !isStopped {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard didSeeSessionCreated else {
            stop()
            throw BailianTTSClientError(
                message: "全双工语音：服务端没有回 session.created（等不到就配不上去）。检查「说」角色里的服务地址和 Key。"
            )
        }
    }

}
