//
//  MainLoopFailurePolicy.swift
//  Wanna
//
//  **兜底的唯一旋钮。** 主循环「做没做成」的判定，以及失败到什么时候把任务交给
//  Claude Code。
//
//  ## 为什么单独一个文件
//
//  用户 2026-09-26 说清了他为什么要这套东西：
//
//      「我准备自己设计全新的 Agent…因为考虑到我自己设计的能力问题，所以我才会去增加
//        一个兜底策略，兜底策略的话就是一个最强的 Agent 来做这件事情。然后在过程中间
//        我会去持续地升级我自己的主 Agent 的循环，然后在未来可能会持续地弱化这个
//        Claude Code。」
//
//  也就是说：**这个阈值会一直被往上推，直到不需要兜底。** 所以它必须只有一个地方 ——
//  散在 `CompanionManager` 各处的话，每次升级主循环都要去好几个地方找同一个数，
//  找漏一处就变成「有时候才兜底」，而这种不确定性正是他要消灭的东西。
//
//  这个文件**只做判定与文案，不做任何动作**：发不发、发给谁、卡片怎么迁移，都由调用方
//  （`CompanionManager`）照着 `Verdict` 去做。
//

import Foundation

nonisolated enum MainLoopFailurePolicy {

    // MARK: - 旋钮

    /// **同一个任务连续失败几次，就交给 Claude Code。**
    ///
    /// 初值 2：一次失败可能只是模型那一轮发挥不好，两次就没必要再让它试了 ——
    /// Claude Code 很重、token 很贵（用户：「Claude Code 又特别重，而且很多功能我
    /// 用不到」），所以它是最后手段，不是第二选择。
    ///
    /// **调这一个数就能改兜底的激进程度**，没有第二处。
    static let consecutiveFailuresBeforeHandoff = 2

    // MARK: - 判定

    /// 一轮主循环的结局。都在循环出口处**已经知道**，不需要额外埋点。
    struct TurnOutcome: Equatable {
        /// 这一轮跑了多少步。
        var stepCount: Int
        /// 撞到步数上限还没做完（`CompanionManager.maximumAutonomousActionSteps`）。
        var hitStepCap: Bool
        /// 这一轮报错了（`lastErrorMessage` 非空）。
        var threwError: Bool
        /// 这一轮有没有真的派过活 / 跑过一步 —— 纯问答不算「任务」，
        /// 不该进兜底统计（否则问两句话就会被判成"两次失败"）。
        var wasATask: Bool
        /// 卡在哪（报错原文或「撞到步数上限」）。
        var failureReason: String?

        var didSucceed: Bool { !hitStepCap && !threwError }
    }

    enum Verdict: Equatable {
        /// 做成了 —— 连续失败计数归零。
        case completed
        /// 没做成，但还没到兜底次数：留在主循环，下一轮自己再来。
        case unfinished(reason: String)
        /// 连续失败到阈值了：交给 Claude Code，并**把这个任务连卡片一起交出去**。
        case handOff(reason: String)
    }

    /// 判定。`consecutiveFailuresIncludingThisTurn` 是**含这一轮在内**的连续失败次数
    ///（由调用方维护；`completed` 时它会被归零）。
    static func verdict(for outcome: TurnOutcome,
                        consecutiveFailuresIncludingThisTurn: Int) -> Verdict {
        guard outcome.wasATask else { return .completed }
        if outcome.didSucceed { return .completed }

        let reason = outcome.failureReason ?? "主循环这一轮没有做完"
        if consecutiveFailuresIncludingThisTurn >= consecutiveFailuresBeforeHandoff {
            return .handOff(reason: reason)
        }
        return .unfinished(reason: reason)
    }

    // MARK: - 交接简报

    /// **交给 Claude Code 的那份简报。**
    ///
    /// 省 token 的关键就是它：不把用户的问题重问一遍（那等于让 Claude Code 从头把
    /// 我的 Agent 走过的路再走一遍），而是说清三件事 —— 原始请求是什么、我的 Agent
    /// 已经试过什么、卡在哪。
    ///
    /// 用户的原话：「我的目的是希望它实现，但是因为我的能力有限，所以在主循环任务失败的
    /// 时候，自动地去分配给 Claude Code 这个更强的 Agent」—— 目的是**把事做成**，
    /// 所以要给的是上下文，不是重来一遍。
    static func handoffBriefing(originalRequest: String,
                                steps: [String],
                                failureReason: String?) -> String {
        var lines: [String] = []
        lines.append("【兜底交接】这个任务由 Wanna 自己的主循环做了一轮，没做成，现在交给你。")
        lines.append("")
        lines.append("## 用户原本要的")
        lines.append(originalRequest.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")

        let meaningfulSteps = steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !meaningfulSteps.isEmpty {
            lines.append("## 我的主循环已经做过的（**不要重复做这些**）")
            for step in meaningfulSteps.suffix(12) {
                lines.append("- \(step)")
            }
            lines.append("")
        }

        if let failureReason, !failureReason.isEmpty {
            lines.append("## 卡在哪")
            lines.append(failureReason)
            lines.append("")
        }

        lines.append("## 请你做的")
        lines.append("把用户要的这件事做成。做完用一句话说明结果。")
        return lines.joined(separator: "\n")
    }

    /// 兜底那个 Claude Code 代理的名字。**固定一个**，不按任务起名 ——
    /// 用户要的是「默认分配的是咱们添加的这个工作目录下的 Claude Code」，
    /// 也就是每张工作目录对应一个代理，兜底的任务都挂在它下面；
    /// 按任务起名会让名册里堆出一串一次性代理，复盘时反而看不出"哪些是兜底"。
    static let fallbackAgentName = "兜底"
}
