import Foundation

/// 「用户说了什么」→「这属于哪一类需求」。
///
/// **这一步必须是模型，不能是代码。** 方案 §08 §二：「统计单位是**任务类型**，不是
/// 句子 —— 换个说法做同一件事算同一类」。我拿真实历史试过关键词表，它把
/// 「介绍一下北京」和「给我说一下北京」算成了两个小类，而它们显然是同一件事。
/// 那一次的表格就是「非得上模型」的证据，不是我的猜测。
///
/// **一次调用归一整批**，不是一轮一次：这些轮次之间没有依赖，而复盘是后台任务、
/// 不在用户的等待路径上 —— 省下的往返全部归它自己。方案 §08 §六 给复盘的定位是
/// 「按时间自己醒过来」，它不是交互式的。
///
/// 走 🧠 那个角色（今天是 DeepSeek + `deepseek-flash`），和播报总结同一条路：
/// 角色可以在「模型」页换，所以这里读的是**配置**，不写死模型名。
nonisolated enum ReviewClassifier {

    enum Failure: Error, CustomStringConvertible {
        case noModelConfigured
        case httpError(Int, String)
        case unreadableReply(String)

        var description: String {
            switch self {
            case .noModelConfigured:
                return "没有可用的 🧠 模型 —— 复盘需要它来归类。"
            case .httpError(let code, let body):
                return "归类调用失败 \(code)：\(body.prefix(200))"
            case .unreadableReply(let raw):
                return "归类结果读不出来：\(raw.prefix(200))"
            }
        }
    }

    /// 一次批量的上限。
    ///
    /// 不设上限的话，用了几个月之后这里会拼出一份几万行的清单，而模型对长清单的
    /// 归类质量是**下降**的（它会开始偷懒，把后半段全归成「其它」）。分批跑，
    /// 每批各自完整 —— 复盘本来就是后台慢慢做的事，多跑几次没有代价。
    static let maximumTurnsPerCall = 60

    /// 归一批。返回的长度与 `turns` 一致（归不出来的填「其它 / 未归类」，
    /// **不是丢掉** —— 丢掉会让统计表的总数对不上历史，而用户会以为是漏了）。
    static func classify(_ turns: [ReviewTurnInput],
                         settings: AppSettings) async throws -> [ReviewTurnRecord] {
        guard !turns.isEmpty else { return [] }
        let batch = Array(turns.prefix(maximumTurnsPerCall))
        let (url, apiKey, model) = try resolvedEndpoint()

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt(for: batch)]],
            "stream": false,
            // **关掉推理。** 和润色那条同一个理由（这个仓库量过那笔账：视觉那条路上
            // 4.5 秒的请求里 3.4 秒是思考）。归类是判断不是创作，那段思考用户看不到，
            // 而复盘是后台任务 —— 唯一的代价是它多烧钱多占时间。
            "thinking": ["type": "disabled"],
            "temperature": 0,
            // 输出是「编号 + 两个短标签」，比输入短得多；给足但不必奢侈。
            "max_tokens": 4096,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let labels = try parseLabels(from: data)
        return batch.enumerated().map { index, turn in
            let label = labels[index + 1]
            return ReviewTurnRecord(category: label?.0 ?? "其它",
                                    subcategory: label?.1 ?? "未归类",
                                    finishedAt: turn.finishedAt)
        }
    }

    // MARK: - 内部

    private static func prompt(for turns: [ReviewTurnInput]) -> String {
        let list = turns.enumerated()
            .map { "\($0.offset + 1). \($0.element.userText.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        return """
        下面是一批用户对同一个桌面助手说过的话。请把**每一句**归到一个「大类」和
        一个更具体的「小类」。

        规则：
        - **按需求归类，不按句子的说法。**「介绍一下北京」和「给我说一下北京」
          是同一类；换个说法做同一件事，算同一类。
        - 大类要少而稳（例如：屏幕问答 / 指位标注 / 电脑操作 / 内容生成 / 文件处理 /
          系统控制），小类要具体到「这件事是什么」（例如：介绍某个城市 / 调音量到指定值）。
        - 同一件事的说法要落到**同一个**小类名字上，不要每句造一个新名字。
        - 看不出类别的，大类填「其它」。

        **只输出 JSON，不要任何其他文字。** 形如：
        {"1": ["内容生成", "介绍某个城市"], "2": ["系统控制", "调音量到指定值"]}

        清单：
        \(list)
        """
    }

    private static func parseLabels(from data: Data) throws -> [Int: (String, String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure.unreadableReply(String(data: data, encoding: .utf8) ?? "")
        }
        // 模型偶尔会把 JSON 包在 ```json 里 —— 剥掉围栏再找第一个 `{` 到最后一个 `}`。
        let cleaned = content.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(
                  with: Data(cleaned[start...end].utf8)) as? [String: Any] else {
            throw Failure.unreadableReply(content)
        }
        var labels: [Int: (String, String)] = [:]
        for (key, value) in json {
            guard let index = Int(key), let pair = value as? [String], pair.count >= 2 else { continue }
            labels[index] = (pair[0], pair[1])
        }
        return labels
    }

    /// 地址、密钥、模型 —— **读配置，不写死**。
    ///
    /// 和播报总结走同一个角色（🧠）。写在两处的模型名迟早会漂，而用户换模型时
    /// 只会换一处。
    private static func resolvedEndpoint() throws -> (URL, String, String) {
        guard let resolved = ModelConfigurationStore.snapshot().status(of: .vision).resolvedRole,
              let url = resolved.requestURL else {
            throw Failure.noModelConfigured
        }
        return (url, resolved.apiKey, resolved.modelID)
    }
}
