import Foundation

/// 一条待归类的历史任务 —— 用户说了什么、什么时候做完的。
///
/// **只有这两样。** 分类不在这里（那是复盘 agent 的话，见 `ReviewTurnRecord`），
/// 执行细节也不在这里 —— 复盘统计的是**需求类型**，不是某一次怎么做的。
nonisolated struct ReviewTurnInput: Sendable, Equatable {
    let userText: String
    let finishedAt: Date
}

/// 从对话历史里挑出「值得复盘的那些轮」。
///
/// 方案 §08 §六 给了三条挑选规则，每一条挡掉一类会让统计变歪的记录：
///
/// | 规则 | 挡掉什么 |
/// |---|---|
/// | **没有结束时间的跳过** | 见下面那段 —— 这是实测踩到的一个坑 |
/// | **空话术跳过** | 只有语气词的轮次（「嗯」「呃」）不是一类需求 |
/// | **10 分钟内做完的跳过** | 「不看正在聊的」—— 一轮还没走完就统计它，等于统计半句话 |
///
/// **为什么收元组而不是直接收 `ConversationSession`**：那样这个类型就能脱离 App
/// 单独编译运行，上面三条规则各能被一个几行的测试钉死。取历史的适配写在调用处一行。
nonisolated enum ReviewHistoryReader {

    /// 做完多久之后才进复盘。方案 §08 §六：「turnFinishedAt < now − 10 分钟 才进」。
    static let quietMinutes = 10

    static func turns(from raw: [(text: String, finishedAt: Date?)],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [ReviewTurnInput] {
        let quietCutoff = now.addingTimeInterval(-Double(quietMinutes) * 60)

        return raw.compactMap { entry -> ReviewTurnInput? in
            // **没有结束时间的必须跳过。**
            //
            // 实测发现的坑：读历史文件时缺字段会落成 nil，而在别的语言里那容易默认成
            // 0，于是一条普通对话变成「1970 年 / 2001 年说的话」。后果不只是显示难看：
            // 它**永远不新鲜**（30 天前就过期），而且会把「跨了几个不同日期」算歪 ——
            // 一条假的古早记录能让一个只出现在今天的需求看起来跨了两年。
            guard let finishedAt = entry.finishedAt else { return nil }

            // 空话术不是一类需求。
            //
            // **判据是「内容字符有几个」，不是「字符串空不空」。** 第一次写的时候
            // 我在这条注释下面只写了一个 `!text.isEmpty` —— 注释说「只留语气词的
            // 轮次」不是需求，代码却放「嗯」「呃」过去。测试当场把它抓出来了
            //（`("嗯", …)` 没被挡）。阈值取 2：一个汉字的口头应声（「嗯」）挡掉，
            // 两个字的真需求（「静音」）留下 —— 和语音那条「≥4 个内容字符才算一句话」
            // 是同一种判据，只是复盘这边更宽。
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentCharacters = text.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0.value > 0x2E80   // 汉字与标点区
            }
            guard contentCharacters.count >= 2 else { return nil }

            // 还在聊的不看 —— 它可能还没做完，而复盘统计的是**已经发生**的事。
            guard finishedAt <= quietCutoff else { return nil }

            return ReviewTurnInput(userText: text, finishedAt: finishedAt)
        }
    }
}
