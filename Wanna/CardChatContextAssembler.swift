//
//  CardChatContextAssembler.swift
//  Wanna
//
//  **语音 / 视频模式下的提示词组装。** 用户对这一段的原话：
//
//      「当用户点击语音聊天时，提取当前会话记录的文本，作为提示词的一部分，标记为
//       『请参考历史记录，请参考之前的对话』，并附加角色的 talks，即『请你作为什么样的
//        角色来回答用户的问题』。提示词共三部分：当前会话记录文本（含图片）、角色的 talks、
//        用户的全新内容。」
//
//  所以这里只做前两部分；**第三部分（用户的新内容）走用户消息**，不进系统提示词 ——
//  那两者在模型眼里是两种权威级别，混在一起就等于把用户的话降级成背景资料。
//
//  ## 为什么是「组装成一份系统提示词」而不是多轮消息
//
//  语音那两个引擎（全双工 / 三段式）本来就是**一轮一句**的形态，它们的系统提示词是角色
//  对象上的一个字符串（`VoiceChatRole.systemPrompt`）。所以这一层只产出**一个字符串**，
//  调用方把它塞进一份临时的角色副本里就行 —— 引擎一个字都不用改。
//
//  ## 三条分寸
//
//    1. **纯函数**：会话记录由调用方读好传进来，这里不碰任何 store，所以能脱离 App 验。
//    2. **上限只有这一处**（下面三个常量）。会话跑得越久提示词越长，而这段提示词每一轮
//       都要重发 —— 长了就是每句话都在为历史付钱。
//    3. **空的部分整段不出现**：没有历史就没有 `<history_reference>` 这一节。留一个空壳
//       等于告诉模型"这里本该有东西"，比没有更糟。
//

import Foundation

nonisolated enum CardChatContextAssembler {

    // MARK: - 上限（本文件是唯一的旋钮）

    /// 最多带多少轮对话。
    static let maximumTurns = 20

    /// 历史正文的字数上限。**从最近的往回装**，装满就停 —— 越近的越相关。
    static let maximumHistoryCharacters = 4_000

    /// 最多附几张截图。它们只在内存里留得住（`userScreenshots` 不落盘），所以拿得到几张
    /// 是运气问题；有就带上，没有就只有文字。
    ///
    /// **只有 `includesScreenshots` 为真时才用得上** —— 语音那条路**只带文字**
    ///（用户：「语音聊天，去除对话历史里面的图片、文件等格式，只保留文本格式的历史内容」，
    /// 理由是模型不吃：「（文本、语音）都是只能保留文字，因为他们的模型不支持视频或文件等等」）。
    static let maximumScreenshots = 3

    // MARK: - 形状

    /// 一个回合：用户说的 + 这个 Agent 答的。
    ///
    /// 两种卡片各自折成它（主循环读 `ConversationHistoryEntry`，Claude Code 读
    /// `AgentTranscriptEntry`）—— 折完之后下面那段组装逻辑只有一份。
    struct Turn: Equatable {
        let question: String
        let answer: String
        /// 这一轮模型看着的那几屏（主循环才有）。
        let screenshots: [ConversationHistoryScreenshot]
    }

    struct AssembledContext: Equatable {
        /// 交给引擎的系统提示词（历史 + 角色两节）。
        let systemPrompt: String
        /// 该随请求一起发出去的截图。
        let screenshots: [ConversationHistoryScreenshot]
        /// 实际带进去了几轮（给日志用 —— 「它到底看到了多少」唯一可核对的数）。
        let includedTurnCount: Int
        /// 有没有因为上限被截掉更早的内容。
        let wasTruncated: Bool

        var logLine: String {
            "历史 \(includedTurnCount) 轮\(wasTruncated ? "（更早的被截断）" : "")、"
                + "截图 \(screenshots.count) 张、提示词 \(systemPrompt.count) 字"
        }
    }

    // MARK: - 组装

    static func assemble(role: CardChatRoleChoice,
                         turns: [Turn],
                         cardTitle: String,
                         includesScreenshots: Bool = false) -> AssembledContext {
        let kept = mostRecentTurnsWithinBudget(turns)
        var sections: [String] = []
        if !kept.isEmpty {
            sections.append(historySection(kept, cardTitle: cardTitle))
        }
        if let roleSection = roleSection(role) {
            sections.append(roleSection)
        }

        // 截图只从**带进去的那几轮**里取，而且要新的在前 —— 与历史同一个方向。
        // `includesScreenshots` 默认关：语音这条路只带文字（见 `maximumScreenshots` 上那段），
        // 只有视频那条才要画面。
        var screenshots: [ConversationHistoryScreenshot] = []
        if includesScreenshots {
            for turn in kept.reversed() {
                for screenshot in turn.screenshots {
                    guard screenshots.count < maximumScreenshots else { break }
                    screenshots.append(screenshot)
                }
                if screenshots.count >= maximumScreenshots { break }
            }
        }

        return AssembledContext(systemPrompt: sections.joined(separator: "\n\n"),
                                screenshots: screenshots,
                                includedTurnCount: kept.count,
                                wasTruncated: kept.count < turns.count)
    }

    /// 从最近的往回装，装到字数上限为止。**至少留一轮** —— 一轮都没有的话这段历史就是空的，
    /// 而那与"没有历史"看起来一样，反而把"上限太小"这件事藏起来了。
    private static func mostRecentTurnsWithinBudget(_ turns: [Turn]) -> [Turn] {
        var kept: [Turn] = []
        var characters = 0
        for turn in turns.suffix(maximumTurns).reversed() {
            let cost = turn.question.count + turn.answer.count
            if !kept.isEmpty && characters + cost > maximumHistoryCharacters { break }
            kept.append(turn)
            characters += cost
        }
        return kept.reversed()
    }

    /// 第一节：会话记录。用户指定的那句标记原样放在最前面。
    private static func historySection(_ turns: [Turn], cardTitle: String) -> String {
        var lines: [String] = []
        lines.append("<history_reference>")
        lines.append("请参考历史记录，请参考之前的对话。这是「\(cardTitle)」到今天为止的记录：")
        lines.append("")
        for turn in turns {
            lines.append("[用户] \(turn.question)")
            if !turn.answer.isEmpty {
                lines.append("[助手] \(turn.answer)")
            }
        }
        lines.append("</history_reference>")
        return lines.joined(separator: "\n")
    }

    /// 第二节：角色。
    ///
    /// 最后那句「只说话、不要输出标签、不要执行操作」是这一段的**固定**部分，不属于任何
    /// 角色：语音 / 视频两个模式本来就**没有 agent 能力**（用户：「不具备 agent 能力，
    /// 不执行用户任务，只知上下文，其他什么都不关心」），但用户自己写的角色提示词完全可能
    /// 要求它去点一下、去改个文件。语音这条路没有任何工具，所以那样写只会让模型把
    /// `[CLICK:…]` 当文字念出来 —— 与其指望每个角色都记得，不如在这里说一次。
    private static func roleSection(_ role: CardChatRoleChoice) -> String? {
        let prompt = role.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return """
        <role>
        请你作为「\(role.displayName)」来回答用户的问题。你只跟用户说话：不要执行任何操作，\
        也不要输出 [CLICK:]、[TYPE:] 这类标签。
        \(prompt)
        </role>
        """
    }

    // MARK: - 两种卡片各自的折法

    /// 主循环卡片：`ConversationHistoryEntry` → 回合。
    ///
    /// 答的那一侧取 `displayResponse ?? assistantResponse`，与界面上那张卡片读的是同一个
    /// 字段 —— **让语音模式看到的东西与用户看到的一样**。多步任务的原始回复是每一步拼起来
    /// 的（同一句话会出现两三次），拿它当上下文只会让模型以为事情做了好几遍。
    /// 原始回复里可能带 `[POINT:…]` 这类标签，所以再过一遍去标签那道（与「逐句快答」
    /// 同一个 helper）。
    static func turns(fromConversationEntries entries: [ConversationHistoryEntry]) -> [Turn] {
        entries.compactMap { entry in
            let question = entry.userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawAnswer = entry.displayResponse ?? entry.assistantResponse
            let answer = ActionTagParser.speakableTextFromStreamedReply(rawAnswer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 两边都空的条目不是一轮（空回复本来就不记账），丢掉比留一行空的强。
            guard !question.isEmpty || !answer.isEmpty else { return nil }
            return Turn(question: question.isEmpty ? "（这一轮没有文字）" : question,
                        answer: answer,
                        screenshots: entry.userScreenshots)
        }
    }

    /// Claude Code 卡片：`AgentTranscriptEntry` → 回合。
    ///
    /// 一个回合是「一条 userMessage + 它后面直到下一条 userMessage 之前的全部内容」——
    /// 也就是把 assistantMessage 与 toolActivity 都归到当轮里。工具行**照样带进去**：
    /// 用户要的就是「整个上下文」，而"它当时跑了哪些命令"正是他自己复盘时最想看的东西。
    /// 条数由上面的字数上限兜住。
    static func turns(fromAgentTranscript transcript: [AgentTranscriptEntry]) -> [Turn] {
        var turns: [Turn] = []
        var currentQuestion: String?
        var collected: [String] = []

        func flush() {
            guard let question = currentQuestion else { return }
            let answer = collected.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            turns.append(Turn(question: question, answer: answer, screenshots: []))
            collected = []
        }

        for entry in transcript {
            switch entry.kind {
            case .userMessage:
                flush()
                currentQuestion = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .assistantMessage:
                collected.append(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .toolActivity:
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                collected.append("[工具] \(text)")
            }
        }
        flush()
        return turns.filter { !$0.question.isEmpty }
    }
}
