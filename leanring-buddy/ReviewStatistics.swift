import Foundation

/// 一条已经归好类的历史任务。
///
/// **分类不在这里做。** 方案 §08 §二 要的是「大类 → 小类」两级，而「换个说法做同一件
/// 事算同一类」是语义判断，代码做不了 —— 那是复盘 agent（模型）的活。这个类型假设
/// 分类**已经发生**，只承载结果，于是「数得对不对」这件事能被纯函数钉死，
/// 而不是和模型的不确定性搅在一起。
nonisolated struct ReviewTurnRecord: Sendable {
    /// 大类，如「系统控制」「内容生成」。
    let category: String
    /// 小类，如「调音量到指定值」「把选中的话翻成英文」。
    let subcategory: String
    /// 这一轮结束的时刻。**用它而不是开始时刻**：一轮跨过午夜时，
    /// 「哪一天做的」按做完算，和用户的记忆一致。
    let finishedAt: Date
}

/// 统计表里的一行。
nonisolated struct ReviewCountRow: Sendable, Equatable {
    let category: String
    let subcategory: String
    let count: Int
    let firstSeen: Date
    let lastSeen: Date
    /// 出现在几个**不同日期**上。
    let distinctDays: Int
    /// 够不够格进候选。见 `ReviewStatistics` 的三条。
    let isCandidate: Bool
    /// 够了或不够，**理由写出来** —— 「为什么它没被晋级」是复盘里最常被问的一句，
    /// 而只给一个布尔值的话，用户只能猜是自己的数据不够还是规则没生效。
    let promotionReason: String
}

/// 「哪些事以后可以更快」的统计。
///
/// **这是方案第 5 步里唯一能先跑在纸上的部分**（§09：「先让它跑在纸上（人工看统计表），
/// 确认判断对了再自动化」）。往提示词里写一行、待审区、批准这些都要先有正确的表，
/// 否则自动化的是一张错的表。
///
/// 三条晋级条件（§08 §三），**必须同时满足**：
///
/// | 规则 | 值 | 为什么 |
/// |---|---|---|
/// | 次数 | **> 5 次** | 用户定的 |
/// | 跨天数 | **≥ 3 个不同日期** | 防「一个下午连说五遍」被当成长期高频 |
/// | 新鲜度 | 最近 30 天内出现过 | 半年不用了的不该占位置 |
///
/// 不够的**什么都不做**，留在表里继续观察 —— 那是默认结果，不是失败。
nonisolated enum ReviewStatistics {

    static let minimumOccurrences = 5
    static let minimumDistinctDays = 3
    static let freshnessWindowDays = 30

    /// 按「大类 → 小类」两级统计，**高频的排在前面**。
    ///
    /// 排序是次数降序、同次数按小类名字典序 —— 后者只是为了**结果稳定**：
    /// 每次跑出来的顺序都一样，人工看表时才能一眼看出「这次比上次多了谁」。
    /// 少了这一层，同次数的行每次顺序不同，表就没法对比。
    static func table(from records: [ReviewTurnRecord],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [ReviewCountRow] {
        let grouped = Dictionary(grouping: records) { "\($0.category)\u{1}\($0.subcategory)" }

        return grouped.compactMap { _, turns -> ReviewCountRow? in
            guard let first = turns.first else { return nil }
            let dates = turns.map(\.finishedAt)
            let distinctDays = Set(dates.map { calendar.startOfDay(for: $0) }).count
            let lastSeen = dates.max() ?? first.finishedAt
            let freshnessCutoff = calendar.date(byAdding: .day,
                                                value: -freshnessWindowDays, to: now) ?? now

            let enoughOccurrences = turns.count > minimumOccurrences
            let enoughDays = distinctDays >= minimumDistinctDays
            let isFresh = lastSeen >= freshnessCutoff

            let reason: String
            if enoughOccurrences && enoughDays && isFresh {
                reason = "晋级候选：\(turns.count) 次，跨 \(distinctDays) 天"
            } else {
                var missing: [String] = []
                if !enoughOccurrences { missing.append("次数 \(turns.count) ≤ \(minimumOccurrences)") }
                if !enoughDays { missing.append("只跨了 \(distinctDays) 天，需要 ≥ \(minimumDistinctDays)") }
                if !isFresh { missing.append("最近 \(freshnessWindowDays) 天内没出现过" ) }
                reason = "留在观察表：" + missing.joined(separator: "；")
            }

            return ReviewCountRow(category: first.category,
                                  subcategory: first.subcategory,
                                  count: turns.count,
                                  firstSeen: dates.min() ?? first.finishedAt,
                                  lastSeen: lastSeen,
                                  distinctDays: distinctDays,
                                  isCandidate: enoughOccurrences && enoughDays && isFresh,
                                  promotionReason: reason)
        }
        .sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : ($0.category, $0.subcategory) < ($1.category, $1.subcategory)
        }
    }

    /// 只留够格的。**这是「候选」这个词的全部含义** —— 它还没有进任何提示词；
    /// 方案 §08 §5.2 要求用户批准才生效。
    static func candidates(from records: [ReviewTurnRecord],
                           now: Date = Date(),
                           calendar: Calendar = .current) -> [ReviewCountRow] {
        table(from: records, now: now, calendar: calendar).filter(\.isCandidate)
    }
}
