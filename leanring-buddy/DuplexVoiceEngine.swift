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
    private static let turnEndSilenceMilliseconds = 1200

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
            print("🎧 [event] speech_started（服务端听到用户开口）")
        case "input_audio_buffer.speech_stopped":
            print("🎧 [event] speech_stopped（服务端判定用户说完）")
        case "input_audio_buffer.committed":
            print("🎧 [event] committed（用户音频已提交）")
        case "conversation.item.input_audio_transcription.completed":
            let userText = event["transcript"] as? String ?? ""
            let itemID = event["item_id"] as? String ?? "-"
            print("🎧 [user-transcript] item=\(itemID.prefix(12)) 「\(userText)」")
        case "response.created":
            let responseID = (event["response"] as? [String: Any])?["id"] as? String ?? "-"
            print("🎧 [response.created] id=\(responseID.prefix(16))")
        case "response.done":
            let responseID = (event["response"] as? [String: Any])?["id"] as? String ?? "-"
            print("🎧 [response.done] id=\(responseID.prefix(16))")
        case "response.audio_transcript.delta":
            let responseID = event["response_id"] as? String ?? "-"
            let delta = event["delta"] as? String ?? ""
            print("🧾 [ai-text +\(delta.count)字] resp=\(responseID.prefix(10)) 累计\((currentAssistantText + delta).count)字：「\(delta.prefix(24))」")
        case "response.audio.delta":
            let responseID = event["response_id"] as? String ?? "-"
            print("🔊 [ai-audio块] resp=\(responseID.prefix(10))")
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

        case "response.created":
            isResponseActive = true
            callbacks.onAssistantTurnStarted()
            // 新一轮开始：解开"丢弃助手音频"的闸，并允许下一次打断（每句只打断一次）。
            isDiscardingAssistantAudio = false
            didRequestLocalBargeIn = false
            speechAccumulatorSeconds = 0
            currentAssistantText = ""

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

        case "conversation.item.input_audio_transcription.completed":
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
