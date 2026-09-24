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
        /// 助手这一轮的累计文字，每次 delta 都回调一次。
        var onAssistantText: (String) -> Void
        /// 这一轮回答结束（`response.done`）。
        var onAssistantTurnFinished: () -> Void
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
    /// 有没有收到 `session.created` —— `session.update` 的前置条件。
    private var didSeeSessionCreated = false
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

        // 麦克风上行。装在**共享播放引擎**上：voice processing 的回声消除只对它自己
        // 渲染的音频有效，所以话筒必须和「正在播的回答」在同一个引擎上，否则模型会
        // 听见自己刚说的话。
        try await playbackEngine.installInputTap(bufferSize: 1024) { [weak self] buffer, _ in
            self?.appendUplinkAudio(from: buffer)
        }
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
            "turn_detection": ["type": "server_vad", "threshold": 0.5, "silence_duration_ms": 700]
        ]
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            configuration["instructions"] = trimmedPrompt
        }
        return configuration
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
        isResponseActive = false
        hasScheduledFirstAudio = false
        pendingUplinkAudio.removeAll()
        currentAssistantText = ""

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
        guard let pcm16Data = pcm16Converter.convertToPCM16Data(from: buffer), !pcm16Data.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isStopped, self.webSocketTask != nil else { return }
            self.pendingUplinkAudio.append(pcm16Data)
            while self.pendingUplinkAudio.count >= Self.uplinkChunkByteCount {
                let chunk = self.pendingUplinkAudio.prefix(Self.uplinkChunkByteCount)
                self.pendingUplinkAudio.removeFirst(Self.uplinkChunkByteCount)
                Task { try? await self.sendJSON([
                    "type": "input_audio_buffer.append",
                    "audio": Data(chunk).base64EncodedString()
                ]) }
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

        switch type {
        case "session.created":
            didSeeSessionCreated = true

        case "input_audio_buffer.speech_started":
            // 用户开口 = 打断。服务端自己会处理回合，客户端要做的只是**别再出声**。
            cancelCurrentResponse()
            callbacks.onBargeIn()

        case "response.created":
            isResponseActive = true
            currentAssistantText = ""

        case "response.audio.delta":
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
