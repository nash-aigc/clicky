//
//  BailianRealtimeTranscriptionProvider.swift
//  Wanna
//
//  Streaming speech-to-text backed by Alibaba Bailian's realtime ASR
//  (`qwen3-asr-flash-realtime`). Audio is pushed over a websocket while the user
//  is still holding the push-to-talk key, so the transcript appears live instead
//  of only after they let go.
//
//  Replaces the AssemblyAI provider, which spoke a different websocket dialect.
//

import AVFoundation
import Foundation

struct BailianRealtimeTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class BailianRealtimeTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Bailian Realtime ASR"

    /// 角色独立配置的模型覆盖（nil = 跟随全局配置）。见工厂的说明。
    nonisolated(unsafe) var modelIDOverride: String?
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        BailianConfiguration.isConfigured
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }

        let transcriptionRoleStatus = ModelConfigurationStore.snapshot().status(of: .transcription)
        let unavailableReason = transcriptionRoleStatus.unavailableExplanation ?? "未配置"
        return "语音转文字不可用：\(unavailableReason)。请在菜单栏图标的齿轮里打开模型设置。"
    }

    /// Single long-lived URLSession shared across every streaming session.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes "Socket is not connected" errors after a few
    /// rapid reconnections to the same host. (Same reasoning as the AssemblyAI
    /// provider, which hit exactly that bug.)
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        try await startStreamingSession(
            keyterms: keyterms,
            resolvedTranscriptionRole: nil,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// - Parameter resolvedTranscriptionRole: Connect using this role instead of the
    ///   saved configuration. The settings window's connection test uses it to try a
    ///   provider the user has typed in but not yet saved; `nil` — what the
    ///   recording pipeline passes — means "use whatever is configured".
    ///
    ///   The role is resolved once and handed to the session as plain values. The
    ///   session deliberately never reads the configuration itself: a single
    ///   `startStreamingSession` would then resolve the host once for the URL and
    ///   once for the model name, and a save landing between those two reads would
    ///   open a socket whose address and model disagree. It also means a recording
    ///   already under way keeps the configuration it started with, which is
    ///   correct — switching providers mid-utterance would send the rest of the
    ///   audio to a host that never received the beginning of it.
    func startStreamingSession(
        keyterms: [String],
        resolvedTranscriptionRole: ResolvedModelRole?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let resolvedRole: ResolvedModelRole
        if let resolvedTranscriptionRole {
            resolvedRole = resolvedTranscriptionRole
        } else {
            let transcriptionRoleStatus = ModelConfigurationStore.snapshot().status(of: .transcription)
            guard let configuredRole = transcriptionRoleStatus.resolvedRole else {
                throw BailianRealtimeTranscriptionProviderError(
                    message: unavailableExplanation ?? "语音转文字不可用。"
                )
            }
            resolvedRole = configuredRole
        }

        // 角色独立配置的模型覆盖：模型名就在 URL 的 query 里，所以要在**这里**
        // 换掉，而不是等会话开口 —— 会话拿到的是一个拼好的 URL。
        let effectiveWebsocketURL: URL?
        if let modelIDOverride, !modelIDOverride.isEmpty,
           let baseWebsocketURL = resolvedRole.websocketURL,
           var components = URLComponents(url: baseWebsocketURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "model", value: modelIDOverride)]
            effectiveWebsocketURL = components.url
        } else {
            effectiveWebsocketURL = resolvedRole.websocketURL
        }

        guard let websocketURL = effectiveWebsocketURL else {
            throw BailianRealtimeTranscriptionProviderError(
                message: "语音转文字的 URL 拼不出来：\(resolvedRole.baseURL)\(resolvedRole.requestPath)（请检查 URL 里有没有空格或多余字符）"
            )
        }

        // Snapshot the recognition settings alongside the role, for the same
        // reason: one recording must speak one configuration, not half of the
        // old one and half of a save that landed mid-utterance.
        let appSettings = AppSettingsStore.snapshot()

        let streamingSession = BailianRealtimeTranscriptionSession(
            websocketURL: websocketURL,
            apiKey: resolvedRole.apiKey,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            transcriptionLanguageCode: appSettings.transcriptionLanguage.languageCodeForRequest,
            usesServerVAD: appSettings.usesAutomaticSpeechSegmentation,
            finalTranscriptGracePeriodSeconds: appSettings.finalTranscriptGracePeriodSeconds,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        // `open()` returns only once the server has confirmed the session is in
        // manual (push-to-talk) mode, so the caller can immediately start feeding
        // audio without racing the session setup.
        try await streamingSession.open()
        return streamingSession
    }
}

/// One push-to-talk recording, from websocket handshake to final transcript.
///
/// The server speaks an OpenAI-Realtime-shaped protocol. The exact event
/// sequence below was verified end to end against the live workspace endpoint
/// before this file was written:
///
///   -> session.update (turn_detection: null)
///   <- session.updated
///   -> input_audio_buffer.append   (xN, base64 PCM16 @ 16kHz mono)
///   -> input_audio_buffer.commit
///   <- conversation.item.input_audio_transcription.text      (interim, xN)
///   <- conversation.item.input_audio_transcription.completed (final)
///
/// Two behaviours worth knowing, both observed live:
///   * The interim event carries `text` + `stash`; concatenating them gives the
///     whole transcript so far (it is NOT an incremental delta).
///   * The final event carries `transcript` (not `text`), and the server leaves
///     the socket open afterwards — it never closes it for us, so we must.
private final class BailianRealtimeTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {

    // MARK: - Server message shapes

    private struct MessageEnvelope: Decodable {
        let type: String
    }

    /// Interim transcription. `text` is the settled prefix, `stash` the part the
    /// model may still revise. Displayed joined together.
    private struct InterimTranscriptionMessage: Decodable {
        let text: String?
        let stash: String?
    }

    /// Final transcription for the committed audio. The field is `transcript`,
    /// not `text` — reading the wrong one silently yields an empty result.
    private struct CompletedTranscriptionMessage: Decodable {
        let transcript: String?
    }

    private struct ErrorMessage: Decodable {
        let message: String?
        let error: NestedError?

        struct NestedError: Decodable {
            let message: String?
            let code: String?
        }
    }

    // MARK: - Constants

    private static let targetSampleRate = 16_000.0

    /// 100ms of 16kHz PCM16 mono. The audio tap hands us ~21ms buffers, which is
    /// far too chatty to put on the wire one message at a time, so buffers are
    /// accumulated up to this size before being sent.
    private static let audioChunkByteCount = 3200

    /// How long `open()` waits for `session.updated` before giving up on the
    /// confirmation and starting anyway. Without this a server-side hiccup would
    /// hang the push-to-talk session forever with no audio ever being sent.
    private static let sessionUpdateConfirmationTimeoutSeconds = 3.0

    /// How long to wait for the final transcript after the turn ends before
    /// falling back to the best interim text. Set from the app settings
    /// (听 → 松键后等最终结果); was hardcoded to 1.4 seconds.
    let finalTranscriptGracePeriodSeconds: TimeInterval

    /// The dictation manager waits this much longer than the session's own grace
    /// period before giving up entirely, so the two stay a fixed margin apart
    /// however the user tunes the grace period.
    var finalTranscriptFallbackDelaySeconds: TimeInterval {
        finalTranscriptGracePeriodSeconds + 1.4
    }

    /// Language hint sent in `session.update`, or `nil` to omit the field and let
    /// the service auto-detect. Officially optional ("语种标识，可选").
    private let transcriptionLanguageCode: String?

    /// Server-side voice activity detection. Off (the default) is the manual
    /// commit mode this pipeline was built around.
    private let usesServerVAD: Bool

    // MARK: - Dependencies

    private let apiKey: String
    private let websocketURL: URL
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    /// Serializes all mutable session state. Deliberately a DispatchQueue rather
    /// than an actor: `appendAudioBuffer` is called from AVAudioEngine's internal
    /// render thread, and the rest of this file uses the same pattern as the
    /// other transcription providers.
    private let stateQueue = DispatchQueue(label: "com.learningbuddy.bailian.asr.state")

    /// Serializes outgoing websocket frames so they reach the server in the order
    /// they were produced — audio must land before the commit that closes it.
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.bailian.asr.send")

    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    // MARK: - Mutable state (stateQueue only)

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var hasSentSessionUpdate = false

    private var pendingPCM16AudioData = Data()
    private var latestTranscriptText = ""
    private var sessionUpdateTimeoutWorkItem: DispatchWorkItem?
    private var finalTranscriptDeadlineWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - websocketURL: Fully formed `wss://` URL, including the `model` query
    ///     parameter. Built by the provider from the current configuration so this
    ///     session never has to consult global state — see `startStreamingSession`.
    ///   - apiKey: Bearer token for the handshake.
    init(
        websocketURL: URL,
        apiKey: String,
        urlSession: URLSession,
        keyterms: [String],
        transcriptionLanguageCode: String?,
        usesServerVAD: Bool,
        finalTranscriptGracePeriodSeconds: TimeInterval,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.websocketURL = websocketURL
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.transcriptionLanguageCode = transcriptionLanguageCode
        self.usesServerVAD = usesServerVAD
        self.finalTranscriptGracePeriodSeconds = finalTranscriptGracePeriodSeconds
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    // MARK: - Opening

    /// Connects and waits for the server to confirm the session configuration.
    func open() async throws {
        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Required by the realtime endpoint — without it the handshake is rejected.
        websocketRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        // URLSessionWebSocketTask only ever speaks HTTP/1.1, which is exactly what
        // this endpoint requires (it rejects HTTP/2 with a 400).
        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    // MARK: - Audio input

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        // Called on AVAudioEngine's render thread — convert first (the converter is
        // only touched here), then hand the bytes to stateQueue.
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.isCancelled, !self.hasRequestedFinalTranscript else { return }

            self.pendingPCM16AudioData.append(audioPCM16Data)

            while self.pendingPCM16AudioData.count >= Self.audioChunkByteCount {
                let chunk = self.pendingPCM16AudioData.prefix(Self.audioChunkByteCount)
                self.pendingPCM16AudioData.removeFirst(Self.audioChunkByteCount)
                self.sendAudioChunk(Data(chunk))
            }
        }
    }

    /// 这一句结束了，但**会话继续用**。
    ///
    /// 官方实测（2026-09-24，直连真服务）：同一个 websocket 上连着 commit 两次，
    /// 两次都拿到各自的最终结果；而且 commit 之后服务端**不会**关连接（commit 后
    /// 0.21 秒给结果，连接一直开着）。所以「每句重开会话」是我们自己加的限制，
    /// 不是协议要求。
    ///
    /// 原来每句都 `cancel()` 旧 task 再在**同一个共享 URLSession** 上建新 task ——
    /// 新连接撞上正在拆掉的旧连接就报 `Socket is not connected`（POSIX 57），
    /// 于是每一轮都：报错 → 重试建连（最多 5×1s）→ 而最终结果还得先等 2.4 秒宽限。
    /// 这就是用户报的「三段式特别慢、卡顿」。
    ///
    /// 这个方法只把**每一句**的标记清掉（已请求/已交付/累积文本/那句的截止计时器），
    /// 会话级的东西（socket、`session.update`、`isCancelled`）一概不动。
    func beginNextUtterance() {
        stateQueue.async {
            guard !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = false
            self.hasDeliveredFinalTranscript = false
            self.pendingPCM16AudioData.removeAll(keepingCapacity: true)
            self.latestTranscriptText = ""
            self.finalTranscriptDeadlineWorkItem?.cancel()
            self.finalTranscriptDeadlineWorkItem = nil
        }
    }

    /// Sends whatever audio is too short to have formed a full chunk yet.
    /// Must be called on `stateQueue` so the audio precedes the commit on `sendQueue`.
    private func flushPendingAudio() {
        guard !pendingPCM16AudioData.isEmpty else { return }
        let remainingAudioData = pendingPCM16AudioData
        pendingPCM16AudioData.removeAll(keepingCapacity: false)
        sendAudioChunk(remainingAudioData)
    }

    private func sendAudioChunk(_ pcm16AudioChunk: Data) {
        sendJSONMessage([
            "event_id": Self.makeEventIdentifier(),
            "type": "input_audio_buffer.append",
            "audio": pcm16AudioChunk.base64EncodedString()
        ])
    }

    // MARK: - Finishing

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            // Flush and commit from inside the same stateQueue block so both land
            // on sendQueue in order: all audio first, then the commit that ends it.
            // In server-VAD mode the commit is never sent — the service commits
            // turns itself, and the official sample only commits when VAD is off.
            self.flushPendingAudio()
            if !self.usesServerVAD {
                self.sendJSONMessage([
                    "event_id": Self.makeEventIdentifier(),
                    "type": "input_audio_buffer.commit"
                ])
            }

            self.scheduleFinalTranscriptDeadline()
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.pendingPCM16AudioData.removeAll(keepingCapacity: false)
            self.sessionUpdateTimeoutWorkItem?.cancel()
            self.sessionUpdateTimeoutWorkItem = nil
            self.finalTranscriptDeadlineWorkItem?.cancel()
            self.finalTranscriptDeadlineWorkItem = nil
        }

        closeWebSocket()
    }

    /// Closes the connection. The server does not hang up after sending the final
    /// transcript, so if we don't close it ourselves the socket leaks and the
    /// shared URLSession accumulates dead connections.
    private func closeWebSocket() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Receiving

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                // A close we initiated is not a failure worth surfacing.
                let wasCancelled = self.stateQueue.sync { self.isCancelled }
                guard !wasCancelled else { return }
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        guard let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: messageData) else {
            return
        }

        switch envelope.type {
        case "session.created":
            // Configure manual turn detection now that the server is ready to
            // accept it. Push-to-talk decides when a turn ends, not server VAD.
            sendSessionUpdateIfNeeded()

        case "session.updated":
            resolveReadyContinuationIfNeeded(with: .success(()))

        case "conversation.item.input_audio_transcription.text":
            handleInterimTranscription(messageData)

        case "conversation.item.input_audio_transcription.completed":
            handleCompletedTranscription(messageData)

        case "session.finished":
            resolveReadyContinuationIfNeeded(with: .success(()))
            stateQueue.async {
                guard self.hasRequestedFinalTranscript, !self.hasDeliveredFinalTranscript else { return }
                self.deliverFinalTranscript(self.latestTranscriptText)
            }

        case "error":
            let errorMessage = try? JSONDecoder().decode(ErrorMessage.self, from: messageData)
            let messageText = errorMessage?.error?.message
                ?? errorMessage?.message
                ?? text
            failSession(with: BailianRealtimeTranscriptionProviderError(message: messageText))

        default:
            // Plenty of event types are informational (speech_started,
            // input_audio_buffer.committed, conversation.item.created, …).
            break
        }
    }

    private func handleInterimTranscription(_ messageData: Data) {
        guard let interimMessage = try? JSONDecoder().decode(
            InterimTranscriptionMessage.self,
            from: messageData
        ) else {
            return
        }

        // `text` and `stash` together form the transcript so far — this event
        // replaces the previous one rather than appending to it.
        let transcriptSoFar = (interimMessage.text ?? "") + (interimMessage.stash ?? "")
        let trimmedTranscriptSoFar = transcriptSoFar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscriptSoFar.isEmpty else { return }

        stateQueue.async {
            guard !self.isCancelled, !self.hasDeliveredFinalTranscript else { return }
            self.latestTranscriptText = transcriptSoFar
            self.onTranscriptUpdate(transcriptSoFar)
        }
    }

    private func handleCompletedTranscription(_ messageData: Data) {
        guard let completedMessage = try? JSONDecoder().decode(
            CompletedTranscriptionMessage.self,
            from: messageData
        ) else {
            return
        }

        let finalTranscriptText = (completedMessage.transcript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }

            if !finalTranscriptText.isEmpty {
                self.latestTranscriptText = finalTranscriptText
            }

            // Manual mode: `completed` only arrives after the explicit commit, so
            // it always marks the end of the turn — deliver straight away rather
            // than waiting out the fallback deadline. Server-VAD mode: the service
            // commits whenever the user pauses, so `completed` can arrive while
            // the key is still held mid-utterance — there it only refreshes the
            // running transcript, and delivery waits for key-up.
            if !self.usesServerVAD || self.hasRequestedFinalTranscript {
                let transcriptToDeliver = finalTranscriptText.isEmpty
                    ? self.bestAvailableTranscriptText()
                    : finalTranscriptText

                if !transcriptToDeliver.isEmpty {
                    self.onTranscriptUpdate(transcriptToDeliver)
                }

                self.deliverFinalTranscript(transcriptToDeliver)
            }
        }
    }

    // MARK: - Session configuration

    private func sendSessionUpdateIfNeeded() {
        stateQueue.async {
            guard !self.hasSentSessionUpdate, !self.isCancelled else { return }
            self.hasSentSessionUpdate = true

            // Officially optional ("语种标识，可选"): naming a language gives
            // noticeably better accuracy than auto-detection, and omitting it is
            // the documented way to ask for auto-detection (中英混合).
            var transcriptionConfiguration: [String: Any] = [:]
            if let transcriptionLanguageCode = self.transcriptionLanguageCode {
                transcriptionConfiguration["language"] = transcriptionLanguageCode
            }

            // Turn detection has exactly two documented shapes. Manual (the
            // default): `turn_detection: null`, key-up sends the commit. Server
            // VAD: the official sample sends
            // `{"type":"server_vad","threshold":0.2,"silence_duration_ms":800}`
            // and never sends a commit — the service ends the turn on silence.
            let turnDetectionConfiguration: Any = self.usesServerVAD
                ? ["type": "server_vad", "threshold": 0.2, "silence_duration_ms": 800]
                : NSNull()

            self.sendJSONMessage([
                "event_id": Self.makeEventIdentifier(),
                "type": "session.update",
                "session": [
                    "modalities": ["text"],
                    "input_audio_format": "pcm",
                    "sample_rate": Int(Self.targetSampleRate),
                    "input_audio_transcription": transcriptionConfiguration,
                    "turn_detection": turnDetectionConfiguration
                ]
            ])

            self.scheduleSessionUpdateConfirmationTimeout()
        }
    }

    /// If `session.updated` never arrives, stop waiting and let audio flow anyway.
    /// A missing confirmation frame must not be allowed to stall the whole
    /// recording — the worst case is that the server is still in its default
    /// configuration, which still transcribes.
    private func scheduleSessionUpdateConfirmationTimeout() {
        sessionUpdateTimeoutWorkItem?.cancel()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("[Bailian ASR] ⚠️ No session.updated within \(Self.sessionUpdateConfirmationTimeoutSeconds)s — starting audio anyway")
            self.resolveReadyContinuationIfNeeded(with: .success(()))
        }

        sessionUpdateTimeoutWorkItem = timeoutWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionUpdateConfirmationTimeoutSeconds,
            execute: timeoutWorkItem
        )
    }

    // MARK: - Final transcript delivery

    private func scheduleFinalTranscriptDeadline() {
        finalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.hasDeliveredFinalTranscript else { return }
                self.deliverFinalTranscript(self.bestAvailableTranscriptText())
            }
        }

        finalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    /// Must be called on `stateQueue`.
    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true

        sessionUpdateTimeoutWorkItem?.cancel()
        sessionUpdateTimeoutWorkItem = nil
        finalTranscriptDeadlineWorkItem?.cancel()
        finalTranscriptDeadlineWorkItem = nil

        onFinalTranscriptReady(transcriptText)

        // Nothing more will be sent on this connection, and the server won't
        // close it for us.
        closeWebSocket()
    }

    /// Must be called on `stateQueue`.
    private func bestAvailableTranscriptText() -> String {
        latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plumbing

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))

        stateQueue.async {
            let wasCancelled = self.isCancelled
            let hasPartialTranscript = !self.bestAvailableTranscriptText().isEmpty

            // A dropped connection mid-recording still leaves usable text on screen.
            // Hand that back instead of throwing the user's words away.
            if !wasCancelled, !self.hasDeliveredFinalTranscript, hasPartialTranscript {
                print("[Bailian ASR] ⚠️ Connection failed with a partial transcript, delivering it: \(error.localizedDescription)")
                self.deliverFinalTranscript(self.bestAvailableTranscriptText())
                return
            }

            guard !wasCancelled else { return }
            print("[Bailian ASR] ❌ Session failed: \(error.localizedDescription)")
            self.closeWebSocket()
            self.onError(error)
        }
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            // The wait is over whichever way it ended, so the confirmation
            // timer must not stay scheduled: when `session.updated` DID arrive
            // promptly, the leftover work item still fired three seconds later
            // and printed "⚠️ No session.updated within 3.0s" over a handshake
            // that had in fact succeeded — 20 such false alarms in one 47000-byte
            // log, and they read exactly like a real service problem while
            // diagnosing the barge-in defect of 2026-09-23. (Cancelling from
            // inside the work item itself is a no-op; it is already running.)
            self.sessionUpdateTimeoutWorkItem?.cancel()
            self.sessionUpdateTimeoutWorkItem = nil

            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    private static func makeEventIdentifier() -> String {
        "event_\(UUID().uuidString)"
    }

    /// Safety net for the case where the owner drops this session without calling
    /// `cancel()` first — the socket is what would otherwise leak.
    ///
    /// Deliberately does NOT call `cancel()`. That method enqueues a block that
    /// strongly captures `self` onto `stateQueue`, and `deinit` only runs once the
    /// reference count is already zero: the extra retain lands on an object that is
    /// being deallocated, so when the block is later released it over-releases
    /// `self` and crashes inside `_Block_release`. Messaging the socket directly
    /// touches no captured `self`, so the safety net is kept without the crash.
    deinit {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
    }
}
