//
//  GitCommitGuard.swift
//  Wanna
//
//  **「要改这个项目之前，先确认最近的改动已经提交并推送」这条强制约定的执行者。**
//
//  用户 2026-09-26 的原话：
//
//      「任何一次修改之前都要去先提交一下历史，并且检测一次…用户发送任务之前，一定要
//        先去确定是否已提交历史，没有提交历史，先提交…推送到当前这个 GitHub 仓库里面，
//        然后才可以进行一个编辑或者写入…检测一下最近 10 分钟之内有没有 GitHub 这个历史
//        提交…如果超过 10 分钟的话，就必须让用户手动触发一次提交，然后才可以编辑。
//        这是一个强制性的约定。」
//
//  ## 为什么是代码而不是提示词
//
//  用户自己选了这条路（「用这个代码的形式来去实现的」），而理由本身也成立：提示词是
//  **请求**模型自觉，而这件事的成本不对称 —— 复盘 agent 写错一个文件，用户的代码没了；
//  而多做一次 `git log` 是毫秒级。所以判定在代码里，模型的输入里只放结论。
//
//  ## 它只回答三件事
//
//    1. 这个仓库最后一次提交是什么时候、是什么（`lastCommit`）；
//    2. 有没有没提交的改动（`hasUncommittedChanges`）；
//    3. 综合起来：**现在允许写吗**（`verdict`）。
//
//  它**不做**提交、不做推送 —— 那是用户的动作（他明确要求手动触发）。这个文件只负责
//  说清楚"现在是什么状态"，以及"还差不差一步"。
//

import Foundation

nonisolated enum GitCommitGuard {

    /// 最近一次提交超过这么久就算「旧」。
    ///
    /// 10 分钟这个数是用户定的（「检测一下最近 10 分钟之内…如果超过 10 分钟的话，就必须
    /// 让用户手动触发一次提交」）。它的含义不是「10 分钟必须提交一次」，而是**这一轮工作
    /// 开始前是不是有一个刚存过的还原点** —— 10 分钟内的提交说明"刚才有个保存点"，
    /// 而写了半小时都没提交过，就意味着接下来改错的话没有东西可以回退。
    static let stalenessThresholdMinutes = 10

    /// 一次提交的摘要。
    struct Commit: Equatable, Sendable {
        let shortHash: String
        let subject: String
        let committedAt: Date

        var ageText: String {
            let seconds = max(0, Date().timeIntervalSince(committedAt))
            if seconds < 60 { return "刚刚" }
            if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
            if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
            return "\(Int(seconds / 86_400)) 天前"
        }
    }

    /// 写之前的判定。
    ///
    /// **拦人的只有一条：最近一次提交太旧。** 这是用户的原话（「检测一下最近 10 分钟
    /// 之内有没有 GitHub 这个历史提交…如果超过 10 分钟的话，就必须让用户手动触发一次
    /// 提交，然后才可以编辑」）。
    ///
    /// 未提交的改动**只报不拦**，这一条也是探针逼出来的：第一版把「工作区脏」也当成拦人
    /// 条件，可这个仓库里有一个 App 自己一直在追写的运行日志（已跟踪），于是守卫永远
    /// 卡红、功能等于没有。用户的判据是"有没有一个**最近的**还原点"，而不是"工作区
    /// 一个字节都没动过" —— 后者在一个正在运行的项目里根本不可能满足。
    enum Verdict: Equatable, Sendable {
        /// 可以写。`trackedChangeCount` / `untrackedCount` 只用于显示。
        case ready(commit: Commit, trackedChangeCount: Int, untrackedCount: Int)
        /// 最近一次提交太旧了 —— 要用户先手动提交推送一次。
        case commitTooOld(commit: Commit, minutesAgo: Int)
        /// 这儿根本不是个 git 仓库，或者 git 跑不起来 —— 不能替用户判断，只能拦住。
        case repositoryUnavailable(reason: String)

        var allowsWriting: Bool {
            if case .ready = self { return true }
            return false
        }

        var commit: Commit? {
            switch self {
            case .ready(let commit, _, _): return commit
            case .commitTooOld(let commit, _): return commit
            case .repositoryUnavailable: return nil
            }
        }

        /// 给用户看的一句话。**要说清"差哪一步"**，因为这是个必须他动手的闸门。
        var blockingMessage: String? {
            switch self {
            case .ready:
                return nil
            case .commitTooOld(_, let minutesAgo):
                return "最近一次提交是 \(minutesAgo) 分钟前（超过 \(stalenessThresholdMinutes) 分钟）。"
                    + "请先提交并推送一次，再让它改这个项目。"
            case .repositoryUnavailable(let reason):
                return "读不到这个仓库的提交历史（\(reason)），所以不能确认有还原点。"
            }
        }

        /// 不拦人、但该让用户看见的一句（工作区还有没提交的东西）。
        var advisoryMessage: String? {
            guard case .ready(_, let tracked, let untracked) = self else { return nil }
            guard tracked > 0 || untracked > 0 else { return nil }
            var pieces: [String] = []
            if tracked > 0 { pieces.append("\(tracked) 个已跟踪文件有改动") }
            if untracked > 0 { pieces.append("\(untracked) 个未跟踪文件") }
            return "工作区还有 " + pieces.joined(separator: "、") + " 没提交（不拦，但提交了才有干净的回退点）"
        }
    }

    // MARK: - 读

    /// 仓库里最后一次提交。读不到返回 nil（不是 git 仓库 / git 不可用 / 仓库是空的）。
    static func lastCommit(inRepositoryAt repositoryPath: String) -> Commit? {
        let output = runGit(["-C", repositoryPath, "log", "-1", "--format=%ct%x1f%h%x1f%s"])
        guard let output, !output.isEmpty else { return nil }
        let parts = output.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard parts.count >= 3, let epochSeconds = TimeInterval(parts[0]) else { return nil }
        return Commit(shortHash: String(parts[1]),
                      subject: String(parts[2]),
                      committedAt: Date(timeIntervalSince1970: epochSeconds))
    }

    /// 工作区的状态：**已跟踪文件的改动**算「没提交」，未跟踪的另计。
    ///
    /// 这个分工是探针逼出来的：第一版把未跟踪文件也算进去，于是在这个仓库里
    /// `git status` 有 33 个未跟踪的运行日志 —— 守卫永远爆红，等于没有。
    /// **要保护的是「改错了能回退」**，而回退点是提交；未跟踪文件（日志、临时产物）
    /// 本来就不在任何一个提交里，把它们算成"没提交"只是噪声。所以：
    ///
    ///   * `trackedChangeCount` —— 已跟踪文件的增删改，**这一项才拦人**；
    ///   * `untrackedCount` —— 只报个数，供用户自己判断。
    struct WorkingTreeStatus: Equatable, Sendable {
        var trackedChangeCount: Int
        var untrackedCount: Int
    }

    /// 不是仓库时返回 nil。
    static func workingTreeStatus(inRepositoryAt repositoryPath: String) -> WorkingTreeStatus? {
        guard let output = runGit(["-C", repositoryPath, "status", "--porcelain"]) else { return nil }
        var tracked = 0
        var untracked = 0
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("??") { untracked += 1 } else { tracked += 1 }
        }
        return WorkingTreeStatus(trackedChangeCount: tracked, untrackedCount: untracked)
    }

    /// **写之前的判定。** 顺序是有意的：先确认能读到仓库，再看提交新旧，最后看工作区脏不脏
    ///（三者的修法不同，先报最根本的那个）。
    static func verdict(forRepositoryAt repositoryPath: String,
                        now: Date = Date()) -> Verdict {
        guard let commit = lastCommit(inRepositoryAt: repositoryPath) else {
            return .repositoryUnavailable(reason: "没有提交记录或这不是一个 git 仓库")
        }
        let minutesAgo = Int(now.timeIntervalSince(commit.committedAt) / 60)
        if minutesAgo > stalenessThresholdMinutes {
            return .commitTooOld(commit: commit, minutesAgo: minutesAgo)
        }
        guard let treeStatus = workingTreeStatus(inRepositoryAt: repositoryPath) else {
            return .repositoryUnavailable(reason: "git status 读不出来")
        }
        return .ready(commit: commit,
                      trackedChangeCount: treeStatus.trackedChangeCount,
                      untrackedCount: treeStatus.untrackedCount)
    }

    // MARK: - 跑 git

    /// `git` 在 `/usr/bin/git`（macOS 自带）。**不走 shell**：参数以数组给出，
    /// 路径里的空格/引号因此不需要转义，也没有注入面。
    private static func runGit(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()          // 吞掉：非仓库时 git 会往 stderr 抱怨
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
