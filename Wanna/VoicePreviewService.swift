//
//  VoicePreviewService.swift
//  Wanna
//
//  「试听」—— 把一段固定的话用指定的音色合成出来，交给播放引擎。
//
//  WHY THERE ARE THREE PATHS AND NOT ONE. 三个模式的音色**各由不同的模型发声**，
//  没有任何一条合成链路能同时认这三套音色：
//
//   · 三段式   → 用户配的合成模型（本机是 `qwen-audio-3.1-tts-flash`），走
//                `/api/v1/services/audio/tts/SpeechSynthesizer`。
//   · 全模态   → `qwen3-tts-flash`。**不能用 3.1 那条路**：Qwen-TTS 与
//                Qwen-Audio-TTS 是两个端点家族，路径和请求体字段都不一样
//                （`language_type` 只属于 Qwen-TTS），配错只会得到一个
//                `InvalidParameter: url error` 这种指不到重点的报错。
//   · 全双工语音 → **必须让实时模型自己说**。官方那套龙安音色是实时模型的内部
//                音色，任何独立 TTS 都不认（VoiceWeb 实测 `qwen3-tts-flash` /
//                `qwen-audio-3.1-tts-flash` / `cosyvoice-v3` 全部 400
//                `Invalid voice`）。所以这一条是：开一个真·实时会话，用
//                `turn_detection: null` + `conversation.item.create` 发一句纯文字，
//                收 `response.audio.delta`。首次 3~5 秒，之后走缓存。
//
//  缓存落在 `~/Library/Application Support/Wanna/VoicePreviews/`。VoiceWeb 用
//  SHA1 做 key；这里用**可读的** key（音色/模型/参数拼起来再清洗），因为出问题时
//  能直接看出哪个文件对应哪次试听，比一串哈希值有用。
//

import Foundation

/// 试听用的固定文本。用一句普通话而不是「测试」两个字：音色好不好听得靠
/// 一句话的语调才判断得出来，一个词听不出音色。
private let voicePreviewSentence = "你好，我是你的语音助手，很高兴认识你。"

/// 试听失败的原因。带一句人话，因为这一页的失败几乎都出在配置而不是代码。
struct VoicePreviewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 试听音频的合成。**只负责合成**：拿到了 WAV 之后由调用方交给
/// `BailianTTSClient.playPreviewWAVData` 播放 —— 试听要和朗读走同一个播放引擎，
/// 否则试听听起来是一个声音、选完朗读又是另一个。
nonisolated enum VoicePreviewService {

    // MARK: - 缓存

    private static var previewCacheDirectoryURL: URL? {
        AppSupportDirectory.fileURL(named: "VoicePreviews")
    }

    /// 缓存文件名。可读 + 有长度上限，并且把路径分隔符一类字符洗掉。
    private static func cacheFileName(
        engine: VoiceChatEngine,
        model: String,
        voice: String,
        speechRate: Double,
        speechVolumePercent: Double,
        styleInstruction: String
    ) -> String {
        // 三段式的语速/音量/风格都会改变声音本身，所以必须进 key；
        // 另外两个模式的音色由服务端模型决定，那些参数对它们没有意义。
        let rawKey: String
        switch engine {
        case .threeStage:
            rawKey = "\(engine.rawValue)-\(model)-\(voice)-\(speechRate)-\(speechVolumePercent)-\(styleInstruction)"
        case .omni, .duplexVoice:
            rawKey = "\(engine.rawValue)-\(model)-\(voice)"
        }
        // 文件名只留字母、数字和 `-_.`：音色 id 里有点号（`longanqian_v3.1`），
        // 模型 id 里有斜杠前的东西，都可能拼出意外的路径。
        let sanitizedKey = String(rawKey.map { character in
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        })
        return String(sanitizedKey.prefix(160)) + ".wav"
    }

    private static func cachedAudioData(forFileName fileName: String) -> Data? {
        guard let previewCacheDirectoryURL else { return nil }
        let fileURL = previewCacheDirectoryURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return data
    }

    private static func storeInCache(_ audioData: Data, fileName: String) {
        guard let previewCacheDirectoryURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: previewCacheDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try audioData.write(
                to: previewCacheDirectoryURL.appendingPathComponent(fileName),
                options: .atomic
            )
        } catch {
            // 写不进缓存不影响这次试听 —— 只是下次还要重新合成一遍。
            print("🔊 VoicePreview: could not cache \(fileName): \(error.localizedDescription)")
        }
    }

    /// 清掉试听缓存。设置里给的入口，也是「换了 Key 之后声音没变」时的解法。
    static func clearCache() {
        guard let previewCacheDirectoryURL else { return }
        try? FileManager.default.removeItem(at: previewCacheDirectoryURL)
    }

    // MARK: - 入口

    /// 合成一段试听音频。命中缓存就直接返回，不发任何请求。
    ///
    /// - Parameters:
    ///   - voice: 要试听的音色 id（`VoiceCatalog` 里的原值，区分大小写）。
    ///   - model: 该模式下当前选的模型 —— 全双工要按它决定用哪个实时模型、
    ///            全模态要按它决定音色是否可用，三段式就是合成模型。
    static func previewAudioData(
        engine: VoiceChatEngine,
        voice: String,
        model: String,
        speechRate: Double,
        speechVolumePercent: Double,
        styleInstruction: String
    ) async throws -> Data {
        let voiceID = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty else {
            throw VoicePreviewError(message: "这个音色还没有 id，无法试听。")
        }

        let fileName = cacheFileName(
            engine: engine,
            model: model,
            voice: voiceID,
            speechRate: speechRate,
            speechVolumePercent: speechVolumePercent,
            styleInstruction: styleInstruction
        )
        if let cached = cachedAudioData(forFileName: fileName) {
            return cached
        }

        let synthesizedAudioData: Data
        switch engine {
        case .threeStage:
            synthesizedAudioData = try await synthesizeWithConfiguredSpeechModel(
                voiceID: voiceID,
                speechRate: speechRate,
                speechVolumePercent: speechVolumePercent,
                styleInstruction: styleInstruction
            )
        case .omni:
            synthesizedAudioData = try await synthesizeWithQwenTTS(voiceID: voiceID)
        case .duplexVoice:
            synthesizedAudioData = try await synthesizeWithRealtimeModel(
                voiceID: voiceID,
                model: model
            )
        }

        storeInCache(synthesizedAudioData, fileName: fileName)
        return synthesizedAudioData
    }

    // MARK: - 三段式：用户配的合成模型

    /// Qwen-Audio-TTS 家族的合成。端点、鉴权、请求体字段全部跟朗读那条路一致
    /// （`BailianTTSClient.requestAudioData`），只把 `voice` 换成被试听的那个 ——
    /// 试听要听到的正是「选完之后朗读会发出什么声音」，所以除了音色以外的一切
    /// 都必须和真朗读相同。
    private static func synthesizeWithConfiguredSpeechModel(
        voiceID: String,
        speechRate: Double,
        speechVolumePercent: Double,
        styleInstruction: String
    ) async throws -> Data {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw VoicePreviewError(message: "还没有配置「说」这个角色（设置 → 模型），无法试听。")
        }
        guard let requestURL = URL(string: "\(resolvedSpeechRole.baseURL)\(resolvedSpeechRole.requestPath)") else {
            throw VoicePreviewError(
                message: "合成模型的 URL 拼不出来：\(resolvedSpeechRole.baseURL)\(resolvedSpeechRole.requestPath)"
            )
        }

        var speechInput: [String: Any] = [
            "text": voicePreviewSentence,
            "voice": voiceID,
            "format": BailianConfiguration.textToSpeechFormat,
            "sample_rate": BailianConfiguration.textToSpeechSampleRate,
            "rate": speechRate,
            "volume": Int(speechVolumePercent)
        ]
        let trimmedInstruction = styleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstruction.isEmpty {
            speechInput["instruction"] = trimmedInstruction
        }

        let responseJSON = try await postJSON(
            to: requestURL,
            apiKey: resolvedSpeechRole.apiKey,
            body: [
                "model": resolvedSpeechRole.modelID,
                "input": speechInput
            ]
        )
        return try await downloadSynthAudio(fromResponseJSON: responseJSON)
    }

    // MARK: - 全模态：Qwen-TTS

    /// Qwen-TTS 家族的合成。
    ///
    /// 路径与前一个家族**不同**，这不是笔误：`qwen3-tts-flash` 在多模态生成
    /// 那条路上，请求体用 `language_type` 而不是 `format`/`sample_rate`。
    /// 把两者混用只会得到 `InvalidParameter: url error, please check url` ——
    /// 一个完全不提「你走错端点了」的报错。
    ///
    /// `Tina` 在这里会失败，而且**是应该失败**：它不在 Qwen-TTS 的音色表里，
    /// 官方也只能用实时模型自己发声。调用方据此把这一行的 ▶ 置灰。
    private static func synthesizeWithQwenTTS(voiceID: String) async throws -> Data {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw VoicePreviewError(message: "还没有配置「说」这个角色（设置 → 模型），无法试听。")
        }
        guard let requestURL = URL(string: "\(resolvedSpeechRole.baseURL)/api/v1/services/aigc/multimodal-generation/generation") else {
            throw VoicePreviewError(message: "全模态试听的 URL 拼不出来，请检查「说」角色的服务地址。")
        }

        let responseJSON = try await postJSON(
            to: requestURL,
            apiKey: resolvedSpeechRole.apiKey,
            body: [
                "model": "qwen3-tts-flash",
                "input": [
                    "text": voicePreviewSentence,
                    "voice": voiceID,
                    "language_type": "Chinese"
                ]
            ]
        )
        return try await downloadSynthAudio(fromResponseJSON: responseJSON)
    }

    // MARK: - 全双工语音：让实时模型自己说

    /// 龙安那套音色只有实时模型认，所以这里开一个**真的**实时会话，发一句纯文字，
    /// 把它说出来的音频收下来。
    ///
    /// 三个关键点，缺一个就静默拿不到音频：
    ///  · `turn_detection: null` —— 不走服务端 VAD。这条会话没有麦克风，
    ///    服务端 VAD 永远等不到「有人说话」，会一直不出声。
    ///  · 必须先等 `session.created` 再发 `session.update`（官方事件顺序）。
    ///  · 音频在 `response.audio.delta` 里，是 **24 kHz 单声道 PCM16** base64，
    ///    不是 WAV —— 所以最后要自己加 WAV 头。
    private static func synthesizeWithRealtimeModel(voiceID: String, model: String) async throws -> Data {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw VoicePreviewError(message: "还没有配置「说」这个角色（设置 → 模型），无法试听。")
        }

        let realtimeModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "qwen-audio-3.0-realtime-flash"
            : model
        guard let websocketURL = URL(
            string: "\(resolvedSpeechRole.baseURL.replacingOccurrences(of: "https://", with: "wss://"))"
                + "/api-ws/v1/realtime?model=\(realtimeModel)"
        ) else {
            throw VoicePreviewError(message: "全双工试听的 websocket 地址拼不出来。")
        }

        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Bearer \(resolvedSpeechRole.apiKey)", forHTTPHeaderField: "Authorization")
        // 和识别用的那条实时链路同一个头 —— 这个端点族要求它，缺了握手被拒。
        websocketRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: websocketRequest)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let collectedPCM16 = try await RealtimePreviewTurn(
            task: task,
            voiceID: voiceID,
            previewSentence: voicePreviewSentence
        ).run()

        guard !collectedPCM16.isEmpty else {
            throw VoicePreviewError(
                message: "全双工模型没有返回音频（音色「\(voiceID)」可能不在 \(realtimeModel) 的音色表里）。"
            )
        }
        // 实时模型的输出固定 24 kHz 单声道 PCM16。
        return wavContainer(fromPCM16: collectedPCM16, sampleRate: 24_000)
    }

    // MARK: - 共用的 HTTP 小工具

    /// 把服务端的错误体翻译成一句人话。
    ///
    /// 现在只认一个，但它是真实撞到的那一个：`AllocationQuota.FreeTierOnly`
    /// —— 免费额度用完 + 控制台里还开着「仅使用免费额度」。这是**账号**问题，
    /// 不是这一页的代码问题（仓库里 TTS / 视觉那条路为它写过说明：一个 403 会让
    /// 用户以为模型坏了）。服务端只回一段英文 JSON，原样贴到界面上等于没说，
    /// 所以这里给出可执行的下一步。
    ///
    /// 实测于 2026-09-24，全模态试听用 `qwen3-tts-flash` 时必现。
    private static func friendlyMessage(forServerErrorBody body: String, statusCode: Int) -> String {
        if body.contains("AllocationQuota.FreeTierOnly") {
            return "这个音色的合成模型（qwen3-tts-flash）免费额度用完了，"
                + "而账号里还开着「仅使用免费额度」。去百炼控制台充值、或关掉那个开关，就能试听。"
        }
        return "试听合成失败（HTTP \(statusCode)）：\(body)"
    }

    private static func postJSON(
        to requestURL: URL,
        apiKey: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoicePreviewError(message: "试听请求没有得到有效响应。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw VoicePreviewError(
                message: Self.friendlyMessage(forServerErrorBody: errorBody, statusCode: httpResponse.statusCode)
            )
        }
        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw VoicePreviewError(message: "试听合成的响应不是 JSON。")
        }
        return responseJSON
    }

    /// 两个 TTS 家族都把音频放在 `output.audio.url`，所以取回来的方式共用。
    private static func downloadSynthAudio(fromResponseJSON responseJSON: [String: Any]) async throws -> Data {
        guard let output = responseJSON["output"] as? [String: Any],
              let audio = output["audio"] as? [String: Any],
              let audioURLString = audio["url"] as? String,
              !audioURLString.isEmpty
        else {
            throw VoicePreviewError(message: "试听合成没有返回音频地址。")
        }

        // 百炼回的是**明文 `http://` 的 OSS 链接**。macOS 的 App Transport Security
        // 直接拒发明文连接，报出来只有一句「the App Transport Security policy
        // requires the use of a secure connection」—— 指不到地址上。同一个桶在 TLS
        // 下的签名 URL 是同一个文件，所以升级协议而不是给这个域名开 ATS 例外
        // （`BailianTTSClient.downloadAudioFile` 踩过同一个坑，这是同一处修法）。
        let secureAudioURLString = audioURLString.hasPrefix("http://")
            ? "https://" + audioURLString.dropFirst("http://".count)
            : audioURLString

        guard let audioURL = URL(string: secureAudioURLString) else {
            throw VoicePreviewError(message: "试听音频地址无法解析：\(audioURLString)")
        }

        let (audioData, response) = try await URLSession.shared.data(from: audioURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw VoicePreviewError(message: "试听音频下载失败（HTTP \(statusCode)）。")
        }
        guard !audioData.isEmpty else {
            throw VoicePreviewError(message: "试听音频下载回来是空的。")
        }
        return audioData
    }

    // MARK: - WAV 封装

    /// 给裸 PCM16 加一个 44 字节的 WAV 头。
    ///
    /// 播放引擎读的是 `AVAudioFile`，它只认容器格式 —— 直接喂裸 PCM 会在解码那步
    /// 抛错，而错误信息听起来像是「音频坏了」。
    private static func wavContainer(fromPCM16 pcmData: Data, sampleRate: UInt32) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)

        var header = Data()
        func appendString(_ value: String) { header.append(contentsOf: Array(value.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        appendString("RIFF")
        appendUInt32(UInt32(36 + pcmData.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)                     // PCM
        appendUInt16(channelCount)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendString("data")
        appendUInt32(UInt32(pcmData.count))

        var wavData = header
        wavData.append(pcmData)
        return wavData
    }
}

/// 一次「让实时模型说一句话」的会话。
///
/// 单独抽成一个对象是为了让 `run()` 里的 await 顺序一目了然：连上 → 等
/// `session.created` → 发 `session.update` → 发文字 → 收音频 → 收 `response.done`。
/// 顺序错了不会崩，只会安静地收不到音频，所以顺序本身就是这段代码的重点。
private actor RealtimePreviewTurn {

    private let task: URLSessionWebSocketTask
    private let voiceID: String
    private let previewSentence: String

    private var collectedPCM16 = Data()
    private var didSeeSessionCreated = false
    private var isFinished = false

    init(task: URLSessionWebSocketTask, voiceID: String, previewSentence: String) {
        self.task = task
        self.voiceID = voiceID
        self.previewSentence = previewSentence
    }

    func run() async throws -> Data {
        // 先把接收循环挂起来，否则 `session.created` 可能在第一条 recv 之前就到，
        // 而 URLSessionWebSocketTask 只把消息投递给**已经开始等待**的那一次 recv。
        let receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        defer { receiveTask.cancel() }

        // 官方顺序：连接 → `session.created` → 客户端才发 `session.update`。
        try await waitForSessionCreated(timeoutSeconds: 8)

        try await sendJSON([
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": voiceID,
                "audio": [
                    "input": ["format": ["type": "pcm", "sample_rate": 16_000]],
                    "output": ["format": ["type": "pcm", "sample_rate": 24_000]]
                ],
                "instructions": "你正在试音，照读用户给的句子即可。",
                // 这条会话没有麦克风：留给服务端 VAD 就永远等不到「有人说话」，
                // 模型一句话都不会说。
                "turn_detection": NSNull()
            ]
        ])

        // 说完就要求发声：先放一条用户消息，再触发一次 response。
        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": previewSentence]]
            ]
        ])
        try await sendJSON(["type": "response.create"])

        try await waitForResponseDone(timeoutSeconds: 25)
        return collectedPCM16
    }

    private func sendJSON(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private func receiveLoop() async {
        while !Task.isCancelled, !isFinished {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleServerEvent(text)
                case .data:
                    break
                @unknown default:
                    break
                }
            } catch {
                // 连接断了就结束循环：`run()` 那边靠超时兜底，拿到多少算多少。
                return
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
        case "response.audio.delta":
            if let delta = event["delta"] as? String,
               let pcmData = Data(base64Encoded: delta) {
                collectedPCM16.append(pcmData)
            }
        case "response.done":
            isFinished = true
        case "error":
            print("🔊 VoicePreview: realtime error — \(text.prefix(300))")
            isFinished = true
        default:
            break
        }
    }

    private func waitForSessionCreated(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !didSeeSessionCreated, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard didSeeSessionCreated else {
            throw VoicePreviewError(message: "全双工试听：服务端没有回 session.created（等不到就发 session.update 会被拒）。")
        }
    }

    private func waitForResponseDone(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !isFinished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
