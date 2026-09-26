//
//  BailianVisionChatAPI.swift
//  leanring-buddy
//
//  Sends the user's screenshots plus their spoken question to Alibaba Bailian's
//  vision-language model (Qwen3-VL) and streams the answer back.
//
//  Replaces the old ClaudeAPI, which spoke Anthropic's Messages format. Bailian
//  exposes an OpenAI-compatible route, so the wire format here is the standard
//  OpenAI chat-completions shape.
//

import Foundation

class BailianVisionChatAPI {
    private static let tlsWarmupLock = NSLock()
    /// Hosts whose TLS connection has already been warmed in this process.
    ///
    /// Keyed by host rather than a single "already warmed up" flag: the TLS session
    /// ticket is host-scoped, so switching the vision model to a provider on a
    /// different host leaves that host cold — and the first request after a switch
    /// carries the largest payload the app ever sends (a full-screen screenshot),
    /// which is exactly when a cold handshake fails.
    private static var warmedUpHosts: Set<String> = []

    /// Ceiling on generated tokens, shared by the streaming and non-streaming
    /// paths. Read per request from the app settings (模型 → 回答长度上限) so a
    /// save takes effect on the next question without rebuilding anything.
    ///
    /// The stored value is clamped by `AppSettings.clamped()` to 32768, and that
    /// clamp is not arbitrary. One value serves every provider, so it has to be
    /// one they all accept — and their ceilings are far apart. Measured
    /// 2026-09-21: DeepSeek accepts up to 393216, while Bailian rejects anything
    /// above 32768 with `InternalError.Algo.InvalidParameter: Range of max_tokens
    /// should be [1, 32768]`. Bailian's ceiling is therefore what caps this, and
    /// raising it to DeepSeek's would break the vision role the moment the user
    /// switched the brain back to Bailian.
    ///
    /// Nowhere near what an answer needs, deliberately. Reasoning models bill
    /// their chain of thought against this budget, and an exhausted budget
    /// returns HTTP 200 with an empty answer rather than an error — so the
    /// ceiling is sized to leave thinking room, not to cap the reply.
    private static var maxCompletionTokens: Int {
        AppSettingsStore.snapshot().visionMaxCompletionTokens
    }

    /// Extra top-level body fields that keep a reasoning model from spending its
    /// budget on a chain of thought, sent whenever the user has left thinking off
    /// for this provider (which is the default — see
    /// `ProviderProfile.allowsVisionReasoning`).
    ///
    /// Measured 2026-09-21 with the app's real payload (a 1280x827 JPEG screenshot
    /// plus the 4923-character system prompt): `deepseek-flash` answers "屏幕右上角
    /// 有什么？" with 664-868 reasoning tokens before the first word of the answer,
    /// which is 3.4s of a 4.5s request — the answer itself is 0.3s. Wanna's
    /// questions are perception questions answered out loud, so that thinking is
    /// time the user spends watching a spinner and cannot hear.
    ///
    /// `thinking` is the field to use, and that was measured rather than assumed:
    /// of the plausible switches only this one and `reasoning_effort: "none"` turn
    /// thinking off, while `enable_thinking: false` (629 reasoning tokens still) and
    /// `chat_template_kwargs.thinking: false` (378 still) are accepted and silently
    /// do nothing. Bailian accepts this field too and ignores it — HTTP 200 with no
    /// change in output, on a model with no reasoning frames to suppress — which is
    /// what lets one user-facing setting cover whichever provider serves 🧠.
    private static func reasoningSuppressionBodyFields(
        for resolvedVisionRole: ResolvedModelRole
    ) -> [String: Any] {
        guard !resolvedVisionRole.allowsVisionReasoning else { return [:] }
        return ["thinking": ["type": "disabled"]]
    }

    private let session: URLSession

    /// The endpoint, key and model are resolved per request from the user's model
    /// configuration rather than captured here, so changing the vision provider in
    /// the settings window takes effect on the very next question instead of on
    /// the next launch.
    init() {
        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        // Done at construction so the handshake overlaps with app startup; requests
        // warm their own host again if the user switches providers later.
        if let resolvedVisionRole = BailianConfiguration.resolvedVision {
            warmUpTLSConnectionIfNeeded(for: resolvedVisionRole)
        }
    }

    /// The vision role as configured right now, or a thrown error naming exactly
    /// what is missing.
    ///
    /// The reason is carried through verbatim from the configuration status rather
    /// than collapsed into "not configured", so the user is told whether to fill in
    /// a model name, an API key or a URL.
    private func resolveVisionRole(modelIDOverride: String? = nil) throws -> ResolvedModelRole {
        let visionRoleStatus = ModelConfigurationStore.snapshot().status(of: .vision)
        guard let resolvedVisionRole = visionRoleStatus.resolvedRole else {
            let unavailableExplanation = visionRoleStatus.unavailableExplanation ?? "未配置"
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "视觉模型不可用：\(unavailableExplanation)。请在菜单栏图标的齿轮里打开模型设置。"]
            )
        }
        return resolvedVisionRole.withModelIDOverride(modelIDOverride)
    }

    private func makeAPIRequest(for resolvedVisionRole: ResolvedModelRole) throws -> URLRequest {
        // A hand-typed URL with a stray space in it cannot be turned into a URL at
        // all. Reported as a configuration error rather than force-unwrapped: this
        // runs on the main actor, so a crash here takes the whole app down.
        guard let chatCompletionsURL = resolvedVisionRole.requestURL else {
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "视觉模型的 URL 拼不出来：\(resolvedVisionRole.baseURL)\(resolvedVisionRole.requestPath)，请检查设置里 \(resolvedVisionRole.providerDisplayName) 的 URL。"]
            )
        }

        warmUpTLSConnectionIfNeeded(for: resolvedVisionRole)

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedVisionRole.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. Declaring the wrong type makes the model misread the image.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the provider's host to establish and cache a
    /// TLS session, at most once per host per process.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded(for resolvedVisionRole: ResolvedModelRole) {
        guard let requestURL = resolvedVisionRole.requestURL,
              let requestHost = requestURL.host else {
            return
        }

        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.warmedUpHosts.contains(requestHost)
        if shouldStartTLSWarmup {
            Self.warmedUpHosts.insert(requestHost)
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(
            url: requestURL,
            resolvingAgainstBaseURL: false
        ) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Builds the OpenAI-compatible `messages` array.
    ///
    /// Bailian has no top-level `system` field the way Anthropic does, so the system
    /// prompt becomes the first message. Each screenshot is sent as an `image_url`
    /// data URI followed by a text block carrying its label — the label is what tells
    /// the model which screen is the cursor's ("primary focus") when several are sent.
    ///
    /// `conversationSummary` rides as a second system message rather than being
    /// appended to the first. It describes older turns, not instructions, and a
    /// summary that has drifted into the instruction prompt would be read as
    /// something the user asked for.
    private func buildMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [ConversationHistoryEntry],
        conversationSummary: String,
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        if !conversationSummary.isEmpty {
            messages.append([
                "role": "system",
                "content": "summary of earlier turns in this conversation that are no longer shown in full:\n\(conversationSummary)"
            ])
        }

        for entry in conversationHistory {
            // A past turn is replayed with its own screenshots when 「历史里带截图」
            // is on, and as plain text when it is off — which is also what a turn
            // restored from disk looks like, since screenshots are never persisted.
            if entry.userScreenshots.isEmpty {
                messages.append(["role": "user", "content": entry.userTranscript])
            } else {
                messages.append([
                    "role": "user",
                    "content": imageAndTextBlocks(
                        images: entry.userScreenshots.map { (data: $0.imageData, label: $0.label) },
                        userPrompt: entry.userTranscript
                    )
                ])
            }
            messages.append(["role": "assistant", "content": entry.assistantResponse])
        }

        // Entries recorded before the companion could act never reach here — the
        // caller filters them out, see `ConversationHistoryEntry.recordedWithActionTags`.

        messages.append([
            "role": "user",
            "content": imageAndTextBlocks(images: images, userPrompt: userPrompt)
        ])

        return messages
    }

    /// The content blocks for one user turn: every screenshot as an `image_url`
    /// data URI with its label, then the text of what the user said.
    ///
    /// Shared by the current turn and by replayed history turns so a screenshot in
    /// the history is sent in exactly the same shape as the one taken now — the
    /// model sees no difference between the picture it was asked about and the
    /// picture it answered about.
    private func imageAndTextBlocks(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var contentBlocks: [[String: Any]] = []
        for image in images {
            let mediaType = detectImageMediaType(for: image.data)
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(mediaType);base64,\(image.data.base64EncodedString())"
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        return contentBlocks
    }

    /// Send a vision request with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [ConversationHistoryEntry] = [],
        conversationSummary: String = "",
        userPrompt: String,
        modelIDOverride: String? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let resolvedVisionRole = try resolveVisionRole(modelIDOverride: modelIDOverride)
        var request = try makeAPIRequest(for: resolvedVisionRole)

        var body: [String: Any] = [
            "model": resolvedVisionRole.modelID,
            // See `maxCompletionTokens`: too low a ceiling returns HTTP 200 with an
            // empty answer rather than an error, so an empty answer is treated as a
            // failure below instead of passing silently.
            "max_tokens": Self.maxCompletionTokens,
            "stream": true,
            "messages": buildMessages(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                conversationSummary: conversationSummary,
                userPrompt: userPrompt
            )
        ]
        body.merge(Self.reasoningSuppressionBodyFields(for: resolvedVisionRole)) { _, newValue in newValue }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Bailian streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(resolvedVisionRole.modelID) @ \(resolvedVisionRole.providerDisplayName)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse the SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // **取消必须在这里判 —— 这个循环是唯一能做这件事的地方。**
            //
            // `URLSession.bytes(for:)` 给回来的 `AsyncBytes`，**在 Swift 任务被取消时
            // 不会立即结束**：底层的 `URLSessionTask` 要等这个流被释放才跟着取消，
            // 在那之前 `for try await` 会继续把已经缓冲的行吐出来。而 `await
            // onTextChunk(...)` 每吐一行就把全文交给上层重画一次。
            //
            // 实测（2026-09-25，`clicky-挂断取消探针-160840.log`）：用户挂断之后
            // —— 任务**已经**是取消态（探针打出 `本任务已取消=true`）—— 文字仍然
            // 从 1000 字继续长到 1200、1400 字，屏幕上继续显示、主线程被一串
            // 140~572ms 的重排打断。用户的原话是「挂断之后内容还在继续生成，
            // 比如一千字，它还在后面继续生成、继续显示」。
            //
            // 抛 `CancellationError` 而不是 `break`：`break` 会让这次调用**正常返回**
            // 一段截断的文本，上层会当成"这一轮正常答完了"记进历史；抛出则走
            // `CascadeVoiceEngine` 已有的取消分支（那条路本来就是为打断准备的）。
            if Task.isCancelled { throw CancellationError() }

            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Bailian sends a final usage-only frame whose `choices` array is empty.
            // Guard against that instead of assuming there is always a first choice.
            guard let choices = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first else {
                continue
            }

            // Answer text lives at choices[0].delta.content. The model's optional
            // chain-of-thought arrives separately in delta.reasoning_content and is
            // deliberately skipped — this response gets spoken aloud.
            guard let delta = firstChoice["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String,
                  !textChunk.isEmpty else {
                continue
            }

            accumulatedResponseText += textChunk
            // Send the accumulated text so far to the UI for progressive rendering
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        // An empty answer arrives as a perfectly successful HTTP 200, and the only
        // thing the user would see is the cursor flashing with nothing spoken — the
        // hardest kind of failure to diagnose. Reported as an error instead.
        guard !accumulatedResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "模型（\(resolvedVisionRole.modelID)）返回了空回答。常见原因：推理内容吃光了 max_tokens，或这个模型不支持图片输入。"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming variant, used by the onboarding demo where the answer is short
    /// and progressive rendering isn't needed.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [ConversationHistoryEntry] = [],
        conversationSummary: String = "",
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let resolvedVisionRole = try resolveVisionRole()
        var request = try makeAPIRequest(for: resolvedVisionRole)

        var body: [String: Any] = [
            "model": resolvedVisionRole.modelID,
            // Same constant and same reasoning as the streaming path above.
            "max_tokens": Self.maxCompletionTokens,
            "messages": buildMessages(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                conversationSummary: conversationSummary,
                userPrompt: userPrompt
            )
        ]
        body.merge(Self.reasoningSuppressionBodyFields(for: resolvedVisionRole)) { _, newValue in newValue }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Bailian request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model=\(resolvedVisionRole.modelID) @ \(resolvedVisionRole.providerDisplayName)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format: \(responseString)"]
            )
        }

        // Same empty-answer guard as the streaming path: an exhausted token budget
        // and an unsupported image input both come back as a 200 with no text, and
        // silently showing nothing looks identical to the app being broken.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "BailianVisionChatAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "模型（\(resolvedVisionRole.modelID)）返回了空回答。常见原因：推理内容吃光了 max_tokens，或这个模型不支持图片输入。"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
