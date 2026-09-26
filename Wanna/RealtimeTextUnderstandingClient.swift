//
//  RealtimeTextUnderstandingClient.swift
//  Wanna
//
//  **用实时模型做「理解」**：喂一条文字，流式收回一条文字回复。
//
//  为什么需要它（用户 2026-09-24）：
//
//  > 「如果用户选择这个预设，就应该调整管线，这也就是为什么一定要通过代码的方式才能
//  > 修改三段式的配置，因为**每一个预设背后都是不同的管线**。所以你应该按照官方的 API
//  > 文档重新调整管线，让它生成文本，它不是能输入文字吗？它能输入文字，你就能获得文字，
//  > 然后用这个文字来走音色克隆的路线。」
//
//  这正是三段式预设二（`voice.threeStage.fastText`）缺的那一环：**识别与理解都用
//  `qwen-audio-3.1-realtime-plus` 直接出文字**，再把文字交给 3.1 TTS 用任意音色合成。
//
//  协议形状**逐条来自官方文档**（不是猜的）：
//
//  · 《实时（Qwen-Omni-Realtime）》：「模型也支持纯文本输入：通过 `conversation.item.create`
//    发送 `input_text` 类型内容，无需音频，适用于非实时对话场景。」
//  · 同一篇：「`modalities` 支持设置为 `["text"]`（仅输出文本）或 `["text","audio"]`」。
//  · 同一篇：「`turn_detection` 设置为 `null` 表示**由客户端决定何时发起模型响应**」
//    —— 所以这一条路上没有服务端 VAD，回合由我们发 `response.create` 决定。
//  · 《服务端事件》：输出模态不含音频时，文本走 **`response.text.delta` / `response.text.done`**；
//    `response.audio_transcript.delta` 只在「输出模态包含音频」时才出现。
//
//  实测（2026-09-24，真连服务）：首个 `response.text.delta` **0.48 秒**，
//  整轮约 0.5 秒。记录在 `开发经验/09-实测数据.md` 第十节。
//
//  **它不吃图片**：`qwen-audio-3.x` 系列全双工语音模型不能理解图片（用户也是这么要求的），
//  所以这条路的入参里没有图像 —— 能力层会把画面开关一并置灰
//  （`VoiceCatalog.modelCanUnderstandImages` 对它返回 false）。
//

import Foundation

/// 用「说」那个角色（百炼业务空间）的地址与密钥，与 `DuplexVoiceEngine` 同一个来源 ——
/// 语音聊天里这些实时模型都属于同一个业务空间，没有第二个凭据可用。
nonisolated struct RealtimeTextUnderstandingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class RealtimeTextUnderstandingClient {

    /// 一轮文字往返的硬上限。实测 0.5 秒就回来了，20 秒是"它没在服务"的判据。
    private static let turnTimeoutSeconds: TimeInterval = 20

    private let urlSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    /// 开一条实时会话 → 喂一条文字 → 流式收回文字 → 关掉会话。
    ///
    /// - Parameters:
    ///   - modelID: 预设里写的理解模型（例如 `qwen-audio-3.1-realtime-plus`）。
    ///   - systemPrompt: 角色的系统提示词，放进 `session.instructions`。
    ///   - userPrompt: 用户这一轮说的话（识别阶段已经转成了文字）。
    ///   - onTextChunk: 每来一段就回调一次（调用方据此边收边朗读）。
    /// - Returns: 完整回复文本。
    func generateText(
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        guard let resolvedRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw RealtimeTextUnderstandingError(
                message: "还没有配置「说」这个角色（设置 → 模型），无法用实时模型做理解。"
            )
        }

        let websocketBaseURL = resolvedRole.baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let websocketURL = URL(string: "\(websocketBaseURL)/api-ws/v1/realtime?model=\(modelID)") else {
            throw RealtimeTextUnderstandingError(message: "实时理解会话的地址拼不出来：\(websocketBaseURL)")
        }

        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Bearer \(resolvedRole.apiKey)", forHTTPHeaderField: "Authorization")
        websocketRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = urlSession.webSocketTask(with: websocketRequest)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let deadline = Date().addingTimeInterval(Self.turnTimeoutSeconds)
        let startedAt = Date()
        var accumulatedText = ""
        var didSendSessionUpdate = false
        var didSendUserTurn = false
        var didLogFirstDelta = false

        // 事件循环。顺序**必须**是官方那套：created → session.update → updated →
        // item.create + response.create → 文本增量 → done。反过来配不上去。
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // 已经收到文本了就当正常结束（服务端可能先关连接再发 done 的变体）。
                if !accumulatedText.isEmpty { return accumulatedText }
                throw RealtimeTextUnderstandingError(
                    message: "实时理解会话中断了：\(error.localizedDescription)"
                )
            }

            let rawText: String
            switch message {
            case .string(let value): rawText = value
            case .data(let value): rawText = String(data: value, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            guard let data = rawText.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "session.created":
                guard !didSendSessionUpdate else { continue }
                didSendSessionUpdate = true
                try await send(task, [
                    "type": "session.update",
                    "session": [
                        // 只要文本：不要它出声（发声由 3.1 TTS 按用户选的音色来做）。
                        "modalities": ["text"],
                        // 回合由我们决定 —— 服务端 VAD 会和我们的回合逻辑抢方向盘。
                        "turn_detection": NSNull(),
                        "instructions": systemPrompt
                    ]
                ])

            case "session.updated":
                guard !didSendUserTurn else { continue }
                didSendUserTurn = true
                // 纯文本输入：官方文档明说这条路支持 `input_text`，无需音频。
                try await send(task, [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": userPrompt]]
                    ]
                ])
                try await send(task, ["type": "response.create"])

            case "response.text.delta":
                if let delta = event["delta"] as? String {
                    accumulatedText += delta
                    if !didLogFirstDelta {
                        didLogFirstDelta = true
                        // 这一行是「实时理解这条路真的被走了」的判据，也让 0.48 秒那个
                        // 实测数字在真机上随时可复核。
                        print("🧠 实时理解（\(modelID)）：首个文字增量 \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
                    }
                    onTextChunk(accumulatedText)
                }

            case "response.text.done":
                if accumulatedText.isEmpty, let text = event["text"] as? String {
                    accumulatedText = text
                    onTextChunk(accumulatedText)
                }

            case "response.done":
                // 有模型把整段文本放在 done 的 output 里而不是增量事件里，兜一下。
                if accumulatedText.isEmpty,
                   let response = event["response"] as? [String: Any],
                   let output = response["output"] as? [[String: Any]] {
                    for item in output {
                        guard let content = item["content"] as? [[String: Any]] else { continue }
                        for part in content where (part["type"] as? String) == "text" {
                            if let text = part["text"] as? String { accumulatedText += text }
                        }
                    }
                    if !accumulatedText.isEmpty { onTextChunk(accumulatedText) }
                }
                if accumulatedText.isEmpty {
                    throw RealtimeTextUnderstandingError(
                        message: "实时理解模型这一轮没有给出文字（模型 \(modelID)）。"
                    )
                }
                return accumulatedText

            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String
                    ?? String(rawText.prefix(200))
                throw RealtimeTextUnderstandingError(message: "实时理解报错：\(message)")

            default:
                continue
            }
        }

        if !accumulatedText.isEmpty { return accumulatedText }
        throw RealtimeTextUnderstandingError(
            message: "实时理解会话 \(Int(Self.turnTimeoutSeconds)) 秒没有回来，模型 \(modelID)。"
        )
    }

    private func send(_ task: URLSessionWebSocketTask, _ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }
}
