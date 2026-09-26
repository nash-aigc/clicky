import AppKit
import SwiftUI

/// 设置页「复盘」。
///
/// 方案第 5 步最后那一跳：**引擎跑完给出候选，人点头才进提示词**
///（`开发经验/Agent施工/08-复盘与高速通道.md` §5.2）。
///
/// 这一页的每一处措辞都在回答同一个问题：「为什么它没进」。那张表被问得最多的
/// 就是这一句，所以候选行带着理由，空的时候也明说是三条门槛还没跨够，而不是留一片
/// 空白让人以为坏了。
///
/// ## 为什么批准要人补一句「做什么」
///
/// 复盘统计出来的是**需求类型**（「介绍某个城市」出现了 8 次），不是「这件事该怎么
/// 做」。方案 §08 §四 列了四种晋级形态，今天能自动生成的只有第一种的一半 ——
/// 触发词。往哪条路走（脚本？instant-agent 的哪个 id？）机器不知道，硬编一个
/// 等于让主 agent 每次遇到都照一个错的索引执行。
///
/// 所以这一页把两件事分开：**机器数出「这很常见」，人填「那就这么做」。**
/// 少了人填的那一步，写进提示词的就是一条每次都会走错的指令。
extension GeneralSettingsView {

    var reviewPage: some View {
        Group {
            SettingsPageHeader(
                title: "复盘",
                subtitle: "读你的历史，数出哪些需求反复出现，够格的变成高速通道的一条 —— 以后直接加载，不走 sub agent 那一圈。它**不会自己改任何东西**，候选要你点头。")

            SettingsGroupLabel("跑一次")
            SettingsCard {
                SettingsRow(
                    label: "统计",
                    description: "读全部历史（含归档），挑出值得复盘的那些轮，交给 🧠 归类，然后按「大类 → 小类」数。一次归类要等十几秒。"
                ) {
                    HStack(spacing: 10) {
                        if generalSettingsViewModel.reviewIsRunning
                            || generalSettingsViewModel.reviewHasRun {
                            Text(generalSettingsViewModel.reviewIsRunning
                                 ? "正在跑…"
                                 : "跑完了 —— 报告见下面")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Button(generalSettingsViewModel.reviewIsRunning ? "跑着…" : "跑一次") {
                            Task { await generalSettingsViewModel.runReview() }
                        }
                        .disabled(generalSettingsViewModel.reviewIsRunning)
                    }
                }
                if let error = generalSettingsViewModel.reviewLastError {
                    SettingsCardRowDivider()
                    SettingsRow(label: "上次没跑成", description: error)
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "报告文件",
                    description: "整张表（不只是候选）会写成一份 markdown，和录音放一起 —— `Application Support` 是隐藏目录，你去那儿找不着。"
                ) {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([ReviewRunner.reportFileURL])
                    }
                }
            }

            // MARK: 候选
            SettingsGroupLabel("候选（等批准）")
            SettingsCard {
                if generalSettingsViewModel.reviewCandidates.isEmpty {
                    SettingsRow(
                        label: "还没有候选",
                        description: "**这不是坏了。** 方案定的三条门槛是「> 5 次」且「跨 ≥ 3 个不同日期」且「30 天内出现过」——用得太集中（比如一个下午连说六遍）会被第二条挡住，而那是故意的：一天说了六遍是那一阵忙，不是长期习惯。"
                    )
                } else {
                    ForEach(Array(generalSettingsViewModel.reviewCandidates.enumerated()), id: \.offset) { index, row in
                        if index > 0 { SettingsCardRowDivider() }
                        candidateRow(row)
                    }
                }
            }

            // MARK: 已生效
            SettingsGroupLabel("已经进提示词的")
            SettingsCard {
                let entries = generalSettingsViewModel.draftSettings.fastPathEntries
                if entries.isEmpty {
                    SettingsRow(label: "一条都没有",
                                description: "高速通道是空的。**这时的提示词和没有这套东西时逐字节相同** —— 这正是方案要的性质：关掉它所有功能仍然正常，只是慢一点。")
                } else {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if index > 0 { SettingsCardRowDivider() }
                        SettingsRow(label: "「\(entry.trigger)」",
                                    description: "→ \(entry.action)　·　命中 \(entry.hitCount) 次"
                                        + (FastPathCatalog.isRetired(entry, now: Date()) ? "　·　**已到 60 天，下轮起不再加载**" : "")) {
                            Button("撤下") { removeFastPathEntry(entry) }
                        }
                    }
                }
            }
        }
    }

    /// 一条候选：理由 + 「走哪条路」+ 批准。
    private func candidateRow(_ row: ReviewCountRow) -> some View {
        SettingsRow(label: "\(row.category) / \(row.subcategory)",
                    description: row.promotionReason
                        + "　·　最近 \(Self.reviewStamp.string(from: row.lastSeen))") {
            HStack(spacing: 8) {
                TextField("走哪条路（脚本路径 / 工具 id）", text: binding(forRouteOf: row))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("批准") { approve(row) }
                    .disabled(binding(forRouteOf: row).wrappedValue
                        .trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - 动作

    /// 每条候选的「走哪条路」草稿。
    ///
    /// **存在 ViewModel 的草稿里，不直接落盘** —— 用户打字打到一半，不该每敲一个
    /// 字符就往设置文件写一次。批准才写。
    private func binding(forRouteOf row: ReviewCountRow) -> Binding<String> {
        let key = "\(row.category)/\(row.subcategory)"
        return Binding(
            get: { generalSettingsViewModel.reviewRoutes[key] ?? "" },
            set: { generalSettingsViewModel.reviewRoutes[key] = $0 }
        )
    }

    private func approve(_ row: ReviewCountRow) {
        let key = "\(row.category)/\(row.subcategory)"
        let route = (generalSettingsViewModel.reviewRoutes[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !route.isEmpty else { return }
        var settings = generalSettingsViewModel.draftSettings
        settings.fastPathEntries.append(FastPathEntry(
            trigger: row.subcategory,
            action: route,
            // **计数从 0 开始，不是从历史次数开始。** 历史上那几次是「这个需求出现过」，
            // 而 `hitCount` 数的是「这条高速通道被用中过几次」—— 两件事。
            // 拿历史次数当起点，等于一条刚加的捷径看起来已经用了 8 次，
            // 而它一次都没被走过；淘汰和撤出都会跟着算错。
            hitCount: 0,
            lastHitAt: nil,
            promotedAt: Date()))
        generalSettingsViewModel.draftSettings = settings
        try? AppSettingsStore.save(settings)
        SoundEffectPlayer.appendToDiagnosticLog(
            "复盘批准：\(key) → \(route)（进提示词，\(settings.fastPathEntries.count) 条）")
    }

    private func removeFastPathEntry(_ entry: FastPathEntry) {
        var settings = generalSettingsViewModel.draftSettings
        settings.fastPathEntries.removeAll { $0.trigger == entry.trigger && $0.action == entry.action }
        generalSettingsViewModel.draftSettings = settings
        try? AppSettingsStore.save(settings)
    }

    private static let reviewStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
