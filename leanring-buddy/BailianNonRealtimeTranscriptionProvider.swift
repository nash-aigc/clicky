//
//  BailianNonRealtimeTranscriptionProvider.swift
//  leanring-buddy
//
//  **非实时**语音识别：把整句录音一次性交给模型，拿回一个完整的转写。
//
//  为什么换成这条路（用户 2026-09-24 的决定，原话）：
//
//  > 「最开始就不应该用流式……非流式既精准，又符合真正的使用场景，因为只有用户
//  > 把话说完了，才能理解他的意思，而不是一边说一边理解。」
//
//  三条实测原因，都指向同一个结论：
//
//  1. **流式的中间结果会不断改写**，屏幕上那句话一边说一边变 —— 用户看到的就是
//     「我说的话的文字总是在变化」。非流式只有一个结果，没有可变的中间态。
//  2. **准确率差得很远**。同一段 12 秒音频（`ref16k.wav`）：
//        `qwen3-asr-flash-realtime` → 「你好，我是你的语音助手，很高。」← **截断**
//        `qwen-audio-3.1-asr-flash`  → 「你好，我是你的语音助手，很高兴认识你。今天天气
//                                        不错，我们聊点什么吧？这是一段用来验证声音克隆
//                                        流程的参考音频。」← 一字不差
//  3. 整条实时的会话生命周期**本身就是一堆 bug 的来源**：每句之后重连、socket
//     在 commit 后掉线、2.4 秒宽限兜底把中间结果当最终结果交上去。这些在非流式
//     下**根本不存在** —— 一次 HTTP 请求，要么成功要么失败。
//
//  代价（明说，不藏）：
//  · 没有实时文字，所以「说话时实时显示识别文字」看不到中间态，话说完才出字。
//  · 「说到「屏幕」立即截屏」依赖中间结果，这条**失效**了。
//  · 每句话要等一次 HTTP 往返：实测 12 秒音频 1.27 秒返回。
//
//  端点与字段来自官方《非实时语音识别》的 HTTP API（不是 OpenAI 兼容那条路 ——
//  这个模型不在那条路上，填错只会得到一句 `url error, please check url`，
//  它完全不提「你走错端点了」）。
//

import AVFoundation
import Foundation

nonisolated final class BailianNonRealtimeTranscriptionProvider: BuddyTranscriptionProvider {

    let displayName = "Bailian Non-Realtime ASR"

    /// 走 HTTP，不需要系统的语音识别权限（那是 Apple 本地识别才要的）。
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
        try BailianNonRealtimeTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class BailianNonRealtimeTranscriptionSession: BuddyStreamingTranscriptionSession {

    /// 一句话的最终结果要等一次 HTTP 往返，所以宽限给足。
    ///
    /// 实测：12 秒音频 1.27 秒返回。取 12 秒是为了长录音（官方单文件上限 10MB）
    /// 也不会被宽限机制提前放弃 —— 原来那个 2.4 秒的常量是针对实时 websocket 的，
    /// 套在这里会把正常请求掐掉。
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 12

    private static let targetSampleRate = 16_000

    /// 结尾补的静音长度。
    ///
    /// VoiceWeb 的参考实现也是这么做的（pipecat 的 `SegmentedSTTService` 会补
    /// 0.5 秒尾静音）。句子常常结束在最后一个字上，没有任何静音空隙，补一小段能
    /// 让模型稳稳收尾，避免吃掉最后一个字。
    private static let trailingSilenceSeconds: Double = 0.5

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.bailian.nonrealtime.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        // 一句话的上传+识别是串行的，给足够宽的超时（长录音 + 排队）。
        urlSessionConfiguration.timeoutIntervalForRequest = 60
        urlSessionConfiguration.timeoutIntervalForResource = 120
        urlSessionConfiguration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    // MARK: - 采集

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        // 音频线程上只做转换，不发网络请求。
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            // 已经请求了最终结果就不再收 —— 这一句的音频到此为止。多收的会串到
            // 下一次识别里（那正是「上一句的尾巴接进新句子」的来源）。
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    // MARK: - 识别

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    /// 这一句交付完了，迎接下一句：清掉缓冲，标记复位（会话就是一次 HTTP 调用，
    /// 没有需要保活的东西）。
    func beginNextUtterance() {
        stateQueue.async {
            guard !self.isCancelled else { return }
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: true)
            self.hasRequestedFinalTranscript = false
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let isCancelledOrEmpty = stateQueue.sync { isCancelled || bufferedPCM16AudioData.isEmpty }
        if isCancelledOrEmpty {
            deliverFinalTranscript("")
            return
        }

        // 尾巴补静音：见 `trailingSilenceSeconds`。
        var audioWithTrailingSilence = bufferedPCM16AudioData
        let trailingSilenceByteCount = Int(Self.trailingSilenceSeconds * Double(Self.targetSampleRate)) * 2
        audioWithTrailingSilence.append(Data(repeating: 0, count: trailingSilenceByteCount))

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: audioWithTrailingSilence,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(forWAVData: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            if !transcriptText.isEmpty {
                // 非流式没有中间结果，所以这条只在「结果到了」这一刻调一次：
                // 界面上的实时气泡拿到的是已经定稿的完整句子，不会再变。
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Bailian Non-Realtime ASR] ❌ 识别失败（音频 \(wavAudioData.count) 字节）：\(error.localizedDescription)")
            onError(error)
        }
    }

    // MARK: - 一次 HTTP 调用

    private func requestTranscription(forWAVData wavAudioData: Data) async throws -> String {
        guard let resolvedRole = ModelConfigurationStore.snapshot().status(of: .transcription).resolvedRole else {
            throw BailianNonRealtimeTranscriptionError(
                message: "还没有配置「听」这个角色（设置 → 模型）。"
            )
        }

        // 官方端点：DashScope 的**同步多模态生成**。不是 OpenAI 兼容那条 chat/completions
        // —— 这个模型不在那条路上（实测会得到 `url error, please check url`）。
        guard let endpointURL = URL(
            string: "\(resolvedRole.baseURL)/api/v1/services/aigc/multimodal-generation/generation"
        ) else {
            throw BailianNonRealtimeTranscriptionError(
                message: "识别接口地址拼不出来：\(resolvedRole.baseURL)"
            )
        }

        var parameters: [String: Any] = [
            "format": "wav",
            "sample_rate": String(Self.targetSampleRate)
        ]
        // 语种提示：官方说能提前确定时给了更准（我们设置页里就有这一项）。
        let appSettings = AppSettingsStore.snapshot()
        if let languageCode = appSettings.transcriptionLanguage.languageCodeForRequest,
           !languageCode.isEmpty {
            parameters["language_hints"] = [languageCode]
        }
        // 即时热词：官方只对 `qwen-audio-3.x-asr-flash` 支持，键是词、值是权重
        // （1~5，越倾向输出该词；50 是超级热词但有 50 个上限）。这里用 4 ——
        // 明显加权，又不占用超级热词的额度。
        let trimmedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmedKeyterms.isEmpty {
            var vocabulary: [String: Int] = [:]
            for keyterm in trimmedKeyterms { vocabulary[keyterm] = 4 }
            parameters["vocabulary"] = vocabulary
        }

        let requestBody: [String: Any] = [
            "model": resolvedRole.modelID,
            "input": [
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "input_audio",
                                "input_audio": [
                                    "data": "data:audio/wav;base64," + wavAudioData.base64EncodedString()
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            "parameters": parameters
        ]

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedRole.apiKey)", forHTTPHeaderField: "Authorization")
        // 关掉 SSE：这条是同步调用，要一个完整的 JSON（官方示例同样带这个头）。
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BailianNonRealtimeTranscriptionError(message: "识别请求没有得到有效响应。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw BailianNonRealtimeTranscriptionError(
                message: "识别失败（HTTP \(httpResponse.statusCode)）：\(errorBody.prefix(300))"
            )
        }

        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw BailianNonRealtimeTranscriptionError(message: "识别的响应不是 JSON。")
        }

        // 实测（2026-09-24）：正文在 `output.sentence.text`，顶层也有一个 `text`
        // 兜底。两个都取一遍，免得某次结构微调就整条失效。
        if let output = responseJSON["output"] as? [String: Any] {
            if let sentence = output["sentence"] as? [String: Any],
               let text = sentence["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let text = output["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let text = responseJSON["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw BailianNonRealtimeTranscriptionError(
            message: "识别的响应里找不到文本：\(String(data: responseData, encoding: .utf8)?.prefix(200) ?? "")"
        )
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        stateQueue.async {
            guard !self.isCancelled else { return }
            self.onFinalTranscriptReady(transcriptText)
        }
    }
}

struct BailianNonRealtimeTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
