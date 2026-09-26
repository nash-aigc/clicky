import Foundation

/// 「自定义风格」那一步的模型调用。
///
/// 转写结束之后，把**勾选中的风格提示词**和**转写原文**（以及可选的屏幕截图）拼成
/// 一次请求发出去，拿回来的文本就是最终内容。
///
/// 走的是 OpenAI 兼容的 `chat/completions` —— DeepSeek 和百炼的兼容模式都吃这套，
/// 所以用户填哪个地址都能用，不需要在这份代码里为服务商分叉。
///
/// 刻意**不复用** `BailianVisionChatAPI`：那个客户端读的是「模型」页里 🧠 角色的配置，
/// 而这一步是用户在这个页面**单独指定的**模型（用户：「模型可以在录音设置页面由用户
/// 添加 URL、API key 和大模型 ID」）。两者会在「用户在模型页换了模型」时互相牵连 ——
/// 那是两个不同的决定，不该共用一份配置。留空时才回落到 🧠，见 `resolvedEndpoint`。
nonisolated enum RecordingPolishClient {

    enum PolishError: Error, CustomStringConvertible {
        case noModelConfigured
        case badURL(String)
        case httpError(Int, String)
        case emptyReply

        var description: String {
            switch self {
            case .noModelConfigured: return "没有配置润色用的模型"
            case .badURL(let raw): return "地址不对：\(raw)"
            case .httpError(let code, let body): return "服务返回 \(code)：\(body.prefix(200))"
            case .emptyReply: return "模型没有返回任何内容"
            }
        }
    }

    /// 拼出要发给模型的提示词。
    ///
    /// 形状是用户指定的：**标签在上、内容在下**，并明确说明目的是「按上面的要求
    /// 重写下面这段转写」。用户的原话：「上面是标签内容，下面是用户提供的内容，
    /// 备注清楚，让 AI 知道它的目的是转写用户的提示词，并使用上面的要求」。
    static func buildPrompt(styles: [RecordingPolishStyle],
                            transcript: String,
                            hasScreenshot: Bool,
                            cameraFrameCount: Int) -> String {
        let ruleBlocks = styles.enumerated().map { index, style in
            """
            <style name="\(style.name)" order="\(index + 1)">
            \(style.prompt)
            </style>
            """
        }.joined(separator: "\n\n")

        var sections: [String] = []
        // **`<task>` 里必须提到随附材料。**
        //
        // 原来这一块只说「处理 <transcript>」，一个字没提截图 —— 模型被告知的
        // 「要处理的东西」里根本没有那张图，于是它有时用、有时当噪声忽略掉。
        // 这是「有时候能识别、有时候不能」的一半原因；另一半在下面 `<screenshot>`
        // 的措辞里（它当时写的是「不要描述这张图」，读起来像「别用它」）。
        let hasAttachments = hasScreenshot || cameraFrameCount > 0
        sections.append("""
        <task>
        下面 <rules> 里是你必须遵守的处理要求。请**严格按照这些要求**，处理 <transcript> 里的
        语音转写内容。你的输出就是成品本身：不要解释、不要前言、不要后缀、不要复述要求。
        \(hasAttachments ? """
        随本消息还附有参考材料（见 <screenshot> 块）。**当 <transcript> 里的内容需要它才能
        理解或校正时，必须使用它** —— 例如转写里出现的人名、标题、按钮、数字、报错文字，
        图上有的就以图为准。但它本身不是待处理的正文：不要复述、不要描述。
        """ : "")
        </task>

        <rules>
        \(ruleBlocks)
        </rules>
        """)

        if hasScreenshot {
            sections.append("""
            <screenshot>
            随本条消息附上了一张屏幕截图，拍摄于用户停止录音的那一刻 —— 也就是他说话时
            屏幕上正显示的内容。
            - **转录里提到「屏幕」「这个」「你看一下」，或者有靠屏幕才能确定的东西
              （标题、人名、按钮名、数字、报错文字）时，以这张图为准。**
            - **需要回答「屏幕上是什么」时，答案就来自这张图。**
            - **不要描述这张图本身**，也不要把图里的文字当成待处理的正文。
            </screenshot>
            """)
        }

        if cameraFrameCount > 0 {
            // 和 <screenshot> 同一个形状：说清它是什么、以及**不许拿它做什么**。
            //
            // **多帧这件事必须在提示词里说明白**，否则模型会把它们当成「同一时刻的几张图」
            // 而只挑一张看。它们是一段时间里的连续画面 —— 用户会移动摄像头去看房间的
            // 不同方向、或者把纸从左看到右，答案要靠这几帧合起来才成立。
            sections.append("""
            <camera>
            随本条消息附上了 \(cameraFrameCount) 张摄像头画面，**按时间先后顺序排列**，
            大约每秒一张 —— 它们不是同一时刻的重复，而是**一段时间里的连续画面**：
            用户可能在这段时间里移动了摄像头去看不同方向，或者把某个东西从左到右展示了一遍。

            - **提到「摄像头」「镜头」「这个东西」「你看一下」，或者有靠画面才能确定的东西
              （实物、人、纸上的字、房间里的布置）时，以这些画面为准。**
            - **需要看多个角度时，把这几帧合起来看**，不要只看第一张。
            - **不要描述这些画面本身**，也不要把画面里的文字当成待处理的正文。
            </camera>
            """)
        }

        sections.append("""
        <transcript>
        \(transcript)
        </transcript>
        """)

        return sections.joined(separator: "\n\n")
    }

    /// 发一次请求，返回整理好的文本。
    static func polish(prompt: String,
                       screenshotJPEG: Data?,
                       cameraFrames: [Data],
                       settings: AppSettings) async throws -> String {
        let endpoint = try resolvedEndpoint(settings: settings)
        return try await send(prompt: prompt, screenshotJPEG: screenshotJPEG,
                              cameraFrames: cameraFrames, endpoint: endpoint)
    }

    /// **「录音 → Notion 笔记」的整理**：同一套内核，但用**它自己那一套**地址 / Key / 模型。
    ///
    /// 用户的要求：「转写部分使用另一套提示词，独立使用 DeepSeek Flash 设计的提示词整理，
    /// 不使用录音润色提示词」。所以配置、提示词、温度都不共用 —— 只有"怎么发"共用。
    static func organizeNotionNote(prompt: String, settings: AppSettings) async throws -> String {
        let endpoint = try resolvedNotionEndpoint(settings: settings)
        return try await send(prompt: prompt, screenshotJPEG: nil, cameraFrames: [],
                              endpoint: endpoint)
    }

    /// Notion 整理那一步的服务商：用户填了就用自己的，没填**回落到录音润色那一套**
    ///（再没有就回落到 🧠）—— 因为"没配"时最合理的行为是照旧能用，而不是报错什么都不做。
    private static func resolvedNotionEndpoint(settings: AppSettings)
        throws -> (url: URL, apiKey: String, model: String) {
        let base = settings.notionNoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.notionNoteAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.notionNoteModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return (try chatCompletionsURL(fromBase: base), key, model)
        }
        return try resolvedEndpoint(settings: settings)
    }

    private static func send(prompt: String,
                             screenshotJPEG: Data?,
                             cameraFrames: [Data],
                             endpoint: (url: URL, apiKey: String, model: String)) async throws -> String {
        var messages: [[String: Any]] = []
        messages.append(["role": "user", "content": contentParts(
            prompt: prompt, screenshotJPEG: screenshotJPEG, cameraFrames: cameraFrames)])

        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": messages,
            "stream": false,
            // 这一步是**改写**不是创作，温度压低让结果稳定、可预期。
            "temperature": 0.2,
            // 输出不会比原文长多少，给一点余量就够 —— 不封顶时模型可能长篇发挥。
            "max_tokens": 8192,
            // **关掉推理。这就是那 8 秒的来源。**
            //
            // `deepseek-flash` 是推理模型：它会在给出答案**之前**先吐几百上千个推理
            // token。这个仓库自己量过 —— 视觉那条路上 4.5 秒的请求里有 **3.4 秒是思考**
            // （2026-09-21，见 CLAUDE.md 的「推理」一节），当时也是靠这个字段把首字从
            // 4298ms 压到 817ms 的。
            //
            // 润色这一步前面还压着用户那 3556 字的规则，模型要在这么长的规则上推理
            // 一遍 —— 实测一次 23 秒、一次 8 秒。而这是**改写**任务：要的只是「按规则
            // 把这段话整理一遍」，中间那段思考用户一个字都看不到，全是白等。
            //
            // 无条件发：百炼收到这个字段是**忽略**（实测 HTTP 200、输出不变），所以
            // 一个开关能同时覆盖两家的服务商，不用按 flavor 分叉。
            "thinking": ["type": "disabled"],
        ]

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 整篇转写可能几万字，读回来的成品也不会短，给足时间。
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PolishError.httpError(http.statusCode,
                                        String(data: data, encoding: .utf8) ?? "")
        }
        return try parseReply(data)
    }

    // MARK: - 内部

    /// 有图时 `content` 是一个「部件的数组」，没图时按纯文本发 —— 两种形状服务端都认，
    /// 但纯文本那一种几乎所有服务商都收，所以只在真有图时才用数组。
    private static func contentParts(prompt: String,
                                     screenshotJPEG: Data?,
                                     cameraFrames: [Data]) -> Any {
        // 一张图都没有 → 按纯文本发（那种形状所有服务商都收）。
        guard screenshotJPEG != nil || !cameraFrames.isEmpty else { return prompt }
        var parts: [[String: Any]] = [["type": "text", "text": prompt]]
        // **顺序和提示词里块的顺序一致**：先屏幕、后摄像头，摄像头内部按拍摄先后。
        // 模型按顺序对号入座，顺序反了它会把两张图认错 —— 而图本身没有可辨认的标记。
        for image in ([screenshotJPEG].compactMap { $0 } + cameraFrames) {
            parts.append(["type": "image_url",
                          "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]])
        }
        return parts
    }

    /// 地址、密钥、模型名。
    ///
    /// 用户在这个页面填了就用他填的；**留空则回落到「模型」页里 🧠 那个服务商** ——
    /// 用户已经在那边配过一次的东西，不该在这里再填一遍（用户的话：「默认使用当前的
    /// DeepSeek Flash，直接填进去即可」）。
    private static func resolvedEndpoint(settings: AppSettings)
        throws -> (url: URL, apiKey: String, model: String) {

        let model = settings.recordingPolishModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = settings.recordingPolishBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.recordingPolishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if !base.isEmpty {
            return (try chatCompletionsURL(fromBase: base), key, model)
        }

        // 回落：🧠 那个角色（用户已经在「模型」页配过一次的东西）。
        guard let resolved = BailianConfiguration.resolvedVision,
              let url = resolved.requestURL else {
            throw PolishError.noModelConfigured
        }
        return (url, resolved.apiKey, model.isEmpty ? resolved.modelID : model)
    }

    /// 把用户填的地址补成完整的 `chat/completions`。
    ///
    /// 用户可能填三种东西：根地址（`https://api.deepseek.com`）、带 `/v1` 的
    /// （`https://api.deepseek.com/v1`）、或者干脆把完整路径也贴进来。三种都要能用 ——
    /// 让人去记「该填到哪一层」是最容易出错的一种设计。
    private static func chatCompletionsURL(fromBase rawBase: String) throws -> URL {
        var base = rawBase
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            guard let url = URL(string: base) else { throw PolishError.badURL(rawBase) }
            return url
        }
        guard let url = URL(string: base + "/chat/completions") else {
            throw PolishError.badURL(rawBase)
        }
        return url
    }

    private static func parseReply(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw PolishError.emptyReply
        }
        // `content` 可能是字符串，也可能是部件数组（带图那一版服务端有时这么回）。
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PolishError.emptyReply }
            return trimmed
        }
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PolishError.emptyReply }
            return trimmed
        }
        throw PolishError.emptyReply
    }
}
