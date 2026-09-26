import Foundation
// 工程开着 `MemberImportVisibility`，`@Published` 的 `init(wrappedValue:)` 定义在
// Combine 里，不显式 import 会被判成「成员不可见」而不是「少了个 import」。
import Combine

/// 复盘跑一次：读历史 → 挑轮次 → 归类 → 统计 → 出一张表 + 候选。
///
/// **方案 §09 给第 5 步定的施工原则是「先让它跑在纸上（人工看统计表），确认判断对了
/// 再自动化」。** 这个类就是那张纸：它把链子串起来、写出一份人看得懂的文件，
/// 而**不往提示词里写任何东西** —— 写进去要用户批准（§08 §5.2），那是下一步。
///
/// 顺序不能换。归类要花一次模型调用，所以**先**用 `ReviewHistoryReader` 把不值得
/// 复盘的轮次挡掉：语气词、还在聊的、没有结束时间的。拿几百条噪声去换一次调用，
/// 既浪费钱又拉低归类质量（模型对长清单会开始偷懒）。
@MainActor
final class ReviewRunner {

    static let shared = ReviewRunner()
    private init() {}

    /// 最近一次跑出来的整张表（不只是候选）。
    @Published private(set) var lastTable: [ReviewCountRow] = []
    /// 够格晋级、**但还没有进提示词**的那些 —— 方案 §08 §5.2 要求用户批准才生效。
    @Published private(set) var candidates: [ReviewCountRow] = []
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastError: String?

    /// 归类的进度，给界面用 —— 一次调用可能要在外头等十几秒，
    /// 而复盘是后台任务，用户点完「跑一次」之后不该对着一个不动的按钮猜。
    @Published private(set) var isRunning = false

    /// 报告落在哪。**放在 checkout 里**，和这套东西其余给人看的产物同一个地方 ——
    /// `Application Support` 是隐藏目录，用户找不到。
    static var reportFileURL: URL {
        WorkspaceDirectory.reviewsURL.appendingPathComponent("复盘报告.md")
    }

    /// 执行历史文件：复盘 agent 读的第一份材料。
    static var executionHistoryFileURL: URL {
        WorkspaceDirectory.reviewsURL.appendingPathComponent("执行历史.md")
    }

    /// **把执行历史写进复盘文件夹** —— 复盘 agent 的项目文件夹就是这里，所以写完它
    /// 的上下文里就有材料了，不需要靠提示词告诉它。
    ///
    /// 用户 2026-09-26 要的两个指标就是这个 + `复盘报告.md`（它自己上次的复盘结果）：
    /// 「你把这个整个的文件…把历史记录这部的内容当做一个参考，然后把他自己复盘的结果
    /// 当做一个复盘结果的依据，添加这两个指标，然后用户可以跟他聊」。
    ///
    /// 两份的差别是有意的：**执行历史是原料**（发生过什么、谁做的、卡在哪），
    /// **复盘报告是上一轮的结论**（他上次认为该改什么）。让 agent 同时看着这两份，
    /// 它才回答得了"这条为什么没做成、上次说该怎么改、改了没有"。
    @discardableResult
    static func writeExecutionHistoryFile(now: Date = Date()) -> URL? {
        var lines: [String] = []
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("# 执行历史")
        lines.append("")
        lines.append("这份是 Wanna 自己写出来的执行记录（生成于 \(stamp.string(from: now))），")
        lines.append("给复盘 agent 当原料用。它和同目录的「复盘报告.md」是两回事：")
        lines.append("这份记**发生过什么**，那份记**上一轮的结论**。")
        lines.append("")

        // ① 主对话与回合
        lines.append("## 一、主对话与回合")
        lines.append("")
        let sessions = ConversationSessionsStore.allSessionsIncludingArchived()
        if sessions.isEmpty {
            lines.append("（还没有任何对话。）")
        }
        for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let archivedMark = session.archivedAt == nil ? "" : "（已归档）"
            lines.append("### \(session.title)\(archivedMark) · \(session.entries.count) 轮")
            lines.append("")
            for entry in session.entries {
                let interrupted = entry.wasInterrupted == true ? " · **被用户打断**" : ""
                lines.append("- 问：\(entry.userTranscript.replacingOccurrences(of: "\n", with: " "))")
                let replyFirstLine = entry.assistantResponse
                    .components(separatedBy: .newlines)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                lines.append("  - 答：\(replyFirstLine)\(interrupted)")
            }
            lines.append("")
        }

        // ② 任务：谁发起的、谁执行的、卡在哪 —— 复盘最要紧的一段
        lines.append("## 二、任务（谁做的、成没成、卡在哪）")
        lines.append("")
        let tasks = FinishedTaskStore.shared.allTasks()
        if tasks.isEmpty {
            lines.append("（还没有任务记录。）")
        }
        for task in tasks {
            let executor = task.cardKind == .claudeCode ? "Claude Code（兜底）" : "自研主循环"
            lines.append("- **\(task.title)** · \(task.status.displayName) · 执行者：\(executor)")
            lines.append("  - 用户要的：\(task.request.replacingOccurrences(of: "\n", with: " "))")
            if let reason = task.handoffReason {
                lines.append("  - 为什么交给 Claude Code：\(reason)")
            }
            if let failure = task.failureReason {
                lines.append("  - 主循环为什么没做成：\(failure)")
            }
            if let attempts = task.attempts, attempts.count > 1 {
                lines.append("  - 试过 \(attempts.count) 次：")
                for attempt in attempts {
                    let note = attempt.note.map { "（\($0)）" } ?? ""
                    lines.append("    - \(attempt.executorDisplayName)：\(attempt.status.displayName)\(note)")
                }
            }
        }
        lines.append("")

        let body = lines.joined(separator: "\n")
        let fileURL = executionHistoryFileURL
        do {
            try FileManager.default.createDirectory(
                at: WorkspaceDirectory.reviewsURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            // 这里装着用户的对话原文，所以和别的数据文件一样补 0600
            //（`.atomic` 落盘是 0644）。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
            return fileURL
        } catch {
            // 静态写法里没有实例的 `lastError` 可写；这里用一行日志 —— 写不进去的原因
            // 只可能是目录权限或磁盘，用户看到的效果是"复盘 agent 的文件夹里没有新材料"。
            print("⚠️ Wanna: 写执行历史失败 \(fileURL.path)：\(error.localizedDescription)")
            return nil
        }
    }

    func run(now: Date = Date()) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        defer { isRunning = false }

        // ① 读历史。归档的也算 —— 归档只表示「不在侧栏里了」，不代表那件事没发生过。
        let raw: [(text: String, finishedAt: Date?)] = ConversationSessionsStore
            .allSessionsIncludingArchived()
            .flatMap(\.entries)
            .map { ($0.userTranscript, $0.turnFinishedAt) }
        let turns = ReviewHistoryReader.turns(from: raw, now: now)

        guard !turns.isEmpty else {
            lastTable = []
            candidates = []
            lastRunAt = now
            writeReport(turns: 0, records: [], now: now)
            return
        }

        // ② 归类。分批 —— 见 `ReviewClassifier.maximumTurnsPerCall`。
        var records: [ReviewTurnRecord] = []
        do {
            var index = 0
            while index < turns.count {
                let batch = Array(turns[index..<min(index + ReviewClassifier.maximumTurnsPerCall,
                                                   turns.count)])
                records += try await ReviewClassifier.classify(batch,
                                                               settings: AppSettingsStore.snapshot())
                index += batch.count
            }
        } catch {
            // 归类失败就**什么都不改**：一张用半批数据算出来的表比没有表更糟，
            // 因为它看起来像结论。
            lastError = (error as? ReviewClassifier.Failure)?.description ?? error.localizedDescription
            SoundEffectPlayer.appendToDiagnosticLog("复盘失败：\(lastError ?? "")")
            return
        }

        // ③ 统计
        lastTable = ReviewStatistics.table(from: records, now: now)
        candidates = lastTable.filter(\.isCandidate)
        lastRunAt = now
        writeReport(turns: turns.count, records: records, now: now)
        SoundEffectPlayer.appendToDiagnosticLog(
            "复盘跑完：\(turns.count) 轮 → \(lastTable.count) 类，候选 \(candidates.count) 条")
    }

    /// 把表写成人看得懂的一份文件。
    ///
    /// **它同时是「为什么这条没晋级」的答案。** 每行都带 `promotionReason`，
    /// 而那张表被问得最多的一句就是「为什么它没进」。
    private func writeReport(turns: Int, records: [ReviewTurnRecord], now: Date) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let day = DateFormatter()
        day.dateFormat = "MM-dd"

        var lines: [String] = []
        lines.append("# Wanna 复盘报告")
        lines.append("")
        lines.append("生成于 \(stamp.string(from: now))　·　采样 \(turns) 轮历史")
        lines.append("")
        lines.append("> 这张表**还没有改动任何东西**。够格的那些只是候选，")
        lines.append("> 要你点头才会进系统提示词（方案 08 §5.2：一条统计错的条目不是「没用」，")
        lines.append("> 而是每次遇到都会被错误地执行）。")
        lines.append("")
        lines.append("## 分类统计")
        lines.append("")
        lines.append("| 大类 | 小类 | 次数 | 首次 | 末次 | 跨天数 | 处置 |")
        lines.append("|---|---|---|---|---|---|---|")

        for row in lastTable {
            lines.append("| \(row.category) | \(row.subcategory) | \(row.count) "
                         + "| \(day.string(from: row.firstSeen)) | \(day.string(from: row.lastSeen)) "
                         + "| \(row.distinctDays) | \(row.promotionReason) |")
        }
        if lastTable.isEmpty {
            lines.append("| — | — | — | — | — | — | 还没有够长的历史可以统计 |")
        }

        lines.append("")
        lines.append("## 候选（够格晋级，等批准）")
        lines.append("")
        if candidates.isEmpty {
            lines.append("暂无。**这不是坏了** —— 方案定的三条门槛是「> 5 次」**且**")
            lines.append("「跨 ≥ 3 个不同日期」**且**「30 天内出现过」。用得太集中")
            lines.append("（比如一个下午连说六遍）会被第二条挡住，而那是故意的。")
        } else {
            for row in candidates {
                lines.append("- **\(row.category) / \(row.subcategory)** —— \(row.promotionReason)")
            }
        }
        lines.append("")

        let url = Self.reportFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
