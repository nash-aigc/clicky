import Foundation

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

    /// 报告落在哪。**放在录音目录旁边**，和这套东西其余给人看的产物同一个地方 ——
    /// `Application Support` 是隐藏目录，用户找不到。
    static var reportFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Clicky复盘/复盘报告.md")
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
        lines.append("# Clicky 复盘报告")
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
