//
//  BailianRealtimeSpeechTranscriptionProvider.swift
//  Wanna
//
//  **把「全双工语音」那个语音模型当成纯识别器用** —— 用户 2026-09-24 的想法：
//
//  > 「全双工语音模型……能输出文本，也能输出文本加音频……我只用它来做语音识别和文本
//  > 输出，因为它识别得非常快，生成文本也非常快，然后再把它生成的文本发给大模型，
//  > 这样体验就会非常快。」
//
//  这个想法成立，而且是**实测**过的（2026-09-24，直连真服务）：
//
//      session.update: modalities=["text"], turn_detection=null
//      → 推 3 秒音频 → commit
//      → 0.27 秒后 conversation.item.input_audio_transcription.completed
//      → **模型没有生成任何回答**（事件里一个 response.* 都没有）
//
//  两条关键设计，缺一条这个用法就不成立：
//
//  1. **`turn_detection: null`**：回合由我们 commit 决定。带上服务端 VAD 的话，
//     它会自己判回合**并且自己开口回答** —— 那些回答我们既不要、又要花 token 和时间。
//  2. **永不发 `response.create`**：不发，模型就永远不生成。识别照常发生，因为它
//     是服务端对「用户说了什么」的转写，不依赖模型去回答。
//
//  为什么值得这么绕：三段式的三个步骤（听 / 想 / 说）是**拆开**的，所以「听」可以
//  单独挑一个又快又准的模型，而 3.x 这一代的语音模型识别明显强于 `qwen3-asr` 那一代
//  （同一段 12 秒音频：旧的实时识别截断成「…很高。」，这个一字不差）。
//  全双工没有这个自由 —— 它一个模型包办听想说，**音色也就不能自定义**了。
//

import AVFoundation
import Foundation

nonisolated final class BailianRealtimeSpeechTranscriptionProvider: BuddyTranscriptionProvider {

    let displayName = "Bailian 语音模型（当识别器）"

    /// 角色独立配置的模型覆盖（nil = 跟随全局配置）。工厂按它分流，
    /// 会话开口时用它 —— 见 `BuddyTranscriptionProviderFactory`。
    nonisolated(unsafe) var modelIDOverride: String?

    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        ModelConfigurationStore.snapshot().status(of: .transcription).resolvedRole != nil
    }

    var unavailableExplanation: String? {
        ModelConfigurationStore.snapshot().status(of: .transcription).unavailableExplanation
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        try BailianRealtimeSpeechTranscriptionSession(
            modelIDOverride: modelIDOverride,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class BailianRealtimeSpeechTranscriptionSession: BuddyStreamingTranscriptionSession {

    /// 实测 commit 之后 0.27 秒就出转写，所以宽限给 5 秒已经很宽裕 ——
    /// 它只是「等不到就认输」的上限，不是预期耗时。
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 5

    private static let targetSampleRate = 16_000.0
    /// 上行分块：100 ms @16 kHz 单声道 16 bit。
    private static let uplinkChunkByteCount = 3200

    /// 角色独立配置的模型覆盖（nil = 全局配置）。URL 在 init 里就要拼，所以
    /// 它必须是 init 参数。
    private let modelIDOverride: String?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.bailian.speechtranscriber")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var pendingUplinkAudio = Data()
    private var hasSentSessionUpdate = false
    private var isCancelled = false
    private var hasDeliveredFinalTranscript = false
    private var didSeeSessionCreated = false
    private var latestTranscriptText = ""

    init(
        modelIDOverride: String?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.modelIDOverride = modelIDOverride
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        guard let resolvedRole = ModelConfigurationStore.snapshot().status(of: .transcription).resolvedRole else {
            throw BailianNonRealtimeTranscriptionError(
                message: "还没有配置「听」这个角色（设置 → 模型）。"
            )
        }

        let websocketBaseURL = resolvedRole.baseURL.replacingOccurrences(of: "https://", with: "wss://")
        let effectiveModelID = modelIDOverride ?? resolvedRole.modelID
        guard let websocketURL = URL(
            string: "\(websocketBaseURL)/api-ws/v1/realtime?model=\(effectiveModelID)"
        ) else {
            throw BailianNonRealtimeTranscriptionError(
                message: "识别用的 websocket 地址拼不出来：\(websocketBaseURL)"
            )
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)

        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Bearer \(resolvedRole.apiKey)", forHTTPHeaderField: "Authorization")
        websocketRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = task
        task.resume()
        receiveNextMessage()
    }

    // MARK: - 采集

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let pcm16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer), !pcm16Data.isEmpty else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isCancelled else { return }
            self.pendingUplinkAudio.append(pcm16Data)
            while self.pendingUplinkAudio.count >= Self.uplinkChunkByteCount {
                let chunk = self.pendingUplinkAudio.prefix(Self.uplinkChunkByteCount)
                self.pendingUplinkAudio.removeFirst(Self.uplinkChunkByteCount)
                Task { try? await self.sendAudioChunk(Data(chunk)) }
            }
        }
    }

    // MARK: - 会话配置

    /// `session.update` 只发一次，而且**每一格都是必须的**：
    ///
    /// · `modalities: ["text"]` —— 不要它出音频。这一场我们只要文字。
    /// · `turn_detection: null` —— **不要服务端 VAD**。带上它，服务端会自己判回合
    ///   并自己回答，那些回答既不要又费 token。
    /// · `input_audio_transcription` —— 只有这样它才会把「用户说了什么」转写出来。
    private func sendSessionUpdateIfNeeded() async throws {
        guard !hasSentSessionUpdate else { return }
        hasSentSessionUpdate = true

        let appSettings = AppSettingsStore.snapshot()
        var transcriptionConfiguration: [String: Any] = [:]
        if let languageCode = appSettings.transcriptionLanguage.languageCodeForRequest, !languageCode.isEmpty {
            transcriptionConfiguration["language"] = languageCode
        }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "audio": [
                    "input": ["format": ["type": "pcm", "sample_rate": Int(Self.targetSampleRate)]],
                    "output": ["format": ["type": "pcm", "sample_rate": 24_000]]
                ],
                "input_audio_transcription": transcriptionConfiguration,
                "turn_detection": NSNull()
            ]
        ])
    }

    // MARK: - 收尾

    func requestFinalTranscript() {
        Task { @MainActor [weak self] in
            guard let self, !self.isCancelled else { return }
            // 先等 `session.created`（服务端没确认之前 commit 可能被忽略）。
            let deadline = Date().addingTimeInterval(5)
            while !self.didSeeSessionCreated, Date() < deadline, !self.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await self.flushAndCommit()
        }
    }

    private func flushAndCommit() async {
        // 不满一块的尾巴也要发上去，否则最后几个字会被丢掉。
        let leftover = pendingUplinkAudio
        pendingUplinkAudio.removeAll(keepingCapacity: false)
        if !leftover.isEmpty {
            try? await sendAudioChunk(leftover)
        }
        try? await sendJSON([
            "type": "input_audio_buffer.commit"
        ])
    }

    func beginNextUtterance() {
        pendingUplinkAudio.removeAll(keepingCapacity: false)
        hasDeliveredFinalTranscript = false
        latestTranscriptText = ""
    }

    func cancel() {
        isCancelled = true
        pendingUplinkAudio.removeAll(keepingCapacity: false)
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession.invalidateAndCancel()
    }

    // MARK: - 收发

    private func receiveNextMessage() {
        guard let webSocketTask else { return }
        webSocketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
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
                    guard !self.hasDeliveredFinalTranscript else { return }
                    self.onError(error)
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
            // 连上就把配置发出去，别等第一句音频 —— 那会白白多一次往返。
            Task { try? await sendSessionUpdateIfNeeded() }

        case "conversation.item.input_audio_transcription.delta":
            // 这个是**这一句**的实时片段（服务端会累计着给），拿它当「正在说什么」
            // 已经足够，而且它已经不是那种反复改写的猜测了。
            if let delta = event["delta"] as? String {
                latestTranscriptText += delta
                onTranscriptUpdate(latestTranscriptText)
            }

        case "conversation.item.input_audio_transcription.completed":
            guard !hasDeliveredFinalTranscript else { return }
            hasDeliveredFinalTranscript = true
            let transcript = (event["transcript"] as? String ?? latestTranscriptText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onFinalTranscriptReady(transcript)

        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
                ?? String(text.prefix(200))
            onError(BailianNonRealtimeTranscriptionError(message: "识别报错：\(message)"))

        default:
            break
        }
    }

    private func sendAudioChunk(_ pcm16Data: Data) async throws {
        try await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": pcm16Data.base64EncodedString()
        ])
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let webSocketTask else { return }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocketTask.send(.string(text))
    }
}
