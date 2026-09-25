import Foundation

/// 高速通道里的一条：一句「用户怎么说」加一条「走哪条路」。
///
/// **它只写入口，不写怎么做**（方案 §08 §5.3）。`action` 是一个**索引** ——
/// 脚本路径、或 instant-agent 里那个 id —— 不是步骤。写成步骤就是用另一种方式把
/// 提示词重新吹胖，而那正是这套重构要拆掉的东西。
nonisolated struct FastPathEntry: Codable, Sendable, Equatable {
    /// 用户会怎么说。给人看的、也是主 agent 认的。
    var trigger: String
    /// 走哪条路。**不是步骤**。
    var action: String
    /// 命中过几次。淘汰按它排序。
    var hitCount: Int
    /// 最后一次命中。60 天没动过就撤出。
    var lastHitAt: Date?
    /// 什么时候晋级的。「重新晋级」要靠它区分「新条目」和「撤出又回来的」。
    var promotedAt: Date
}

/// 提示词里那一段高速通道。
///
/// **它是复盘唯一的产出，也是唯一往提示词里加东西的地方**（方案 §08 §一）。
/// 三条防退化规则全在这里：
///
/// | 规则 | 值 | 为什么 |
/// |---|---|---|
/// | 预算 | **≤ 20 行 / 约 800 字符** | 刚把 12,096 字符搬出提示词，不设上限半年后会重新长胖 |
/// | 超了怎么办 | **按频率淘汰最低的**（只撤提示词那一行，脚本不删） | 撤的是入口，不是能力 |
/// | 长期不用 | **60 天没命中 → 自动撤出** | 回到观察表，不是删除 |
///
/// 外加一条方向性：**撤出之后再用起来，要能重新晋级**（§08 H10）——
/// 它是「观察 → 晋级 → 撤出 → 再晋级」的环，不是单行道。少了这一条，
/// 一次误撤就等于永久失去那条捷径。
nonisolated enum FastPathCatalog {

    static let maximumLines = 20
    static let maximumCharacters = 800
    static let retirementDays = 60

    /// 撤出：太久没命中。
    ///
    /// **只从提示词里撤，条目本身留着** —— 「撤出」和「删除」是两件事，
    /// 方案 §08 §5.1 明写「只撤提示词那一行，脚本不删」。
    static func isRetired(_ entry: FastPathEntry, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastHitAt = entry.lastHitAt else {
            // 从没命中过：拿晋级时间当基准，否则一条刚加进来还没用过的条目
            // 会立刻被当成「60 天没动过」撤掉。
            return daysBetween(entry.promotedAt, and: now, calendar: calendar) > retirementDays
        }
        return daysBetween(lastHitAt, and: now, calendar: calendar) > retirementDays
    }

    /// 还在服役的那些，**热的排前面**。
    ///
    /// 排序和统计表同一个理由：两次跑出来顺序一样，人才能对比。
    static func activeEntries(from entries: [FastPathEntry],
                              now: Date = Date(),
                              calendar: Calendar = .current) -> [FastPathEntry] {
        entries
            .filter { !isRetired($0, now: now, calendar: calendar) }
            .sorted { $0.hitCount != $1.hitCount ? $0.hitCount > $1.hitCount : $0.trigger < $1.trigger }
    }

    /// 渲染成提示词里那一段。空的时候返回空串 —— **不要写一段「（暂无）」**，
    /// 那只是白占字符，而这一段的预算只有 800。
    ///
    /// 两条预算**同时**执行：行数和字符数谁先到算谁。只盯行数的话，一行长描述
    /// 就能把这 800 字符吃光；只盯字符数的话，20 行超短条目又会把结构撑散。
    static func promptSection(from entries: [FastPathEntry],
                              now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        let active = activeEntries(from: entries, now: now, calendar: calendar)
        guard !active.isEmpty else { return "" }

        var lines: [String] = []
        var used = 0
        let header = "以下这些说法你已经很熟了，直接做，不必再想一遍："
        used = header.count

        for entry in active {
            guard lines.count < maximumLines else { break }
            let line = "「\(entry.trigger)」→ \(entry.action)"
            // +1 是换行
            guard used + line.count + 1 <= maximumCharacters else { break }
            lines.append(line)
            used += line.count + 1
        }

        guard !lines.isEmpty else { return "" }
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// 被预算挤掉的、和被 60 天规则撤掉的，**都报出来**。
    ///
    /// 方案 §08 H8 要求「超预算 → 留记录」。没有记录的话，用户只会发现某条捷径
    /// 突然不灵了，而没有任何地方告诉他为什么 —— 那和丢了不一样，那叫「悄悄坏了」。
    static func evicted(from entries: [FastPathEntry],
                        now: Date = Date(),
                        calendar: Calendar = .current) -> [FastPathEntry] {
        let active = activeEntries(from: entries, now: now, calendar: calendar)
        let section = promptSection(from: entries, now: now, calendar: calendar)
        guard !section.isEmpty else { return active }
        // 渲染时被留下的是前 N 条（active 已按热度排好），所以挤掉的就是剩下的。
        let keptCount = section.split(separator: "\n").count - 1
        return Array(active.dropFirst(max(0, keptCount)))
    }

    private static func daysBetween(_ from: Date, and to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day],
                                from: calendar.startOfDay(for: from),
                                to: calendar.startOfDay(for: to)).day ?? 0
    }
}
