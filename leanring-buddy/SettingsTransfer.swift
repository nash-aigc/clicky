//
//  SettingsTransfer.swift
//  leanring-buddy
//
//  「导出设置 / 导入设置」：把设置页面上的参数整包写出一个 JSON 文件，也能把这个
//  文件读回来，覆盖当前设置。
//
//  范围是用户 2026-09-23 亲自划定的：「让用户可以把当前所有的对话和配置参数导出
//  到本地，也可以导入，自动加载出来……注意导入导出的是配置页面的参数，对话页面的
//  内容不需要管，因为它特别复杂。重点是这个设置页面的整个参数。而且要说明一下，
//  导入导出的其实是设置页面的参数，让用户知道导入的是什么。」
//
//  所以这里只有两样东西，正好是十个设置页背后的两个存储：
//
//    1. `AppSettings`          —— 通用 / 交互样式 / Agent / 对话与记忆 / 听 / 说 /
//                                 看与截图 / 操作 / 快捷键（九个页面，一份文件）
//    2. `ModelConfiguration`   —— 模型页（三个角色 + 每个服务商的 URL、Key、模型名）
//
//  **对话内容不在里面，是有意的**：`ConversationSessions.json` 带着每条会话的截图
//  与压缩摘要，体量和结构都不是"设置"该背的，用户也明说了不要它。写出去的 JSON 因
//  此可以放心当成"换台机器继续用"的凭据。
//
//  一个必须说清楚的取舍：**导出的文件里含模型服务商的 API Key**（模型页本来就存着
//  它们，不含就无法在另一台机器上直接用）。文件按 0600 写，界面上的说明文字也把
//  这件事写了出来——用户拿着这个文件知道自己在拿什么，比替他藏着更有用。
//

import AppKit
import Foundation
import SwiftUI
// `allowedContentTypes = [.json]` reads `UTType.json`, which is declared in
// UniformTypeIdentifiers — AppKit re-exports the type but not the module's
// members, so the module build refuses it without this line (the single-file
// `swiftc -typecheck` does not, which is why it only shows up here).
import UniformTypeIdentifiers

// MARK: - The document

/// What an exported file contains, and the only shape an import accepts.
///
/// `formatIdentifier` / `formatVersion` exist so importing the wrong file fails
/// with a sentence rather than with a partially-applied mess: a JSON file that
/// happens to decode into this shape but is not ours is rejected outright, and a
/// file from a newer build is rejected before anything is written.
nonisolated struct SettingsTransferDocument: Codable, Sendable {

    /// A value nothing else would plausibly produce. Checked on import.
    static let expectedFormatIdentifier = "com.yourcompany.leanring-buddy.settings-export"

    /// Bumped only when the payload's meaning changes. An import accepts
    /// anything at or below this and refuses anything above it — a file written
    /// by a build that knew more than this one must not be half-understood.
    static let currentFormatVersion = 1

    var formatIdentifier: String
    var formatVersion: Int
    var exportedAt: Date
    var appSettings: AppSettings
    var modelConfiguration: ModelConfiguration
}

/// What an import actually brought in, for the confirmation the user reads.
///
/// Counted from the document that was applied rather than described in the
/// abstract, so the sentence can state real numbers ("3 个服务商 / 3 个角色已配置")
/// instead of "导入成功" — which tells the user nothing about whether the file
/// they picked was the one they meant.
nonisolated struct SettingsTransferSummary: Sendable {
    let exportedAt: Date
    let providerCount: Int
    let configuredRoleCount: Int
}

nonisolated enum SettingsTransferError: LocalizedError {
    case notASettingsExport(underlyingError: Error?)
    case fromNewerFormatVersion(foundVersion: Int)
    case importedFileHasNoModelProviders

    var errorDescription: String? {
        switch self {
        case .notASettingsExport:
            return "这个文件不是 Clicky 导出的设置文件，没有改动任何设置。请在设置页里用「导出设置」生成文件，再拿它来导入。"
        case .fromNewerFormatVersion(let foundVersion):
            return "这个文件来自更新的 Clicky（格式版本 \(foundVersion)，本机只认到 \(SettingsTransferDocument.currentFormatVersion)），没有改动任何设置。请先升级 Clicky 再导入。"
        case .importedFileHasNoModelProviders:
            // 这一条拦的是一次**静默**的清空：`ModelConfiguration` 的解码是容错的
            // （见它自己的 `init(from:)`），一个模型条目形状不对的文件会解码成
            // 「零个服务商 + 三个角色都没分配」，然后照样覆盖掉用户当前能用的配置。
            // 应用之后就再也拿不回来了，所以宁可不导入。
            return "这个文件里的模型配置是空的，导入会让三个模型角色全部失效，所以没有改动任何设置。"
        }
    }
}

// MARK: - Read / write

nonisolated enum SettingsTransferService {

    /// Today's settings + model configuration, as the bytes of an exported file.
    ///
    /// Read through the two stores rather than through the settings view models:
    /// the stores are what every subsystem actually runs on, and — unlike a
    /// view model — they hold no unsaved draft, so an export can never write out
    /// something the app is not currently using.
    static func makeExportData() throws -> Data {
        let document = SettingsTransferDocument(
            formatIdentifier: SettingsTransferDocument.expectedFormatIdentifier,
            formatVersion: SettingsTransferDocument.currentFormatVersion,
            exportedAt: Date(),
            appSettings: AppSettingsStore.snapshot(),
            modelConfiguration: ModelConfigurationStore.snapshot()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ISO8601 rather than the default `timeIntervalSinceReferenceDate`: this
        // file is meant to be looked at and kept, and a date a human can read is
        // part of that. Both sides are this file's own, so nothing else breaks.
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// Applies an exported file, replacing both stores, and reports what landed.
    ///
    /// Order is deliberate: everything that can fail is checked **before** the
    /// first write. A doomed import must leave the current settings completely
    /// untouched — half-applied (new settings, old models, or the reverse) is
    /// the one outcome worse than refusing.
    @discardableResult
    static func applyImportedData(_ importedData: Data) throws -> SettingsTransferSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document: SettingsTransferDocument
        do {
            document = try decoder.decode(SettingsTransferDocument.self, from: importedData)
        } catch {
            throw SettingsTransferError.notASettingsExport(underlyingError: error)
        }

        guard document.formatIdentifier == SettingsTransferDocument.expectedFormatIdentifier else {
            throw SettingsTransferError.notASettingsExport(underlyingError: nil)
        }
        guard document.formatVersion <= SettingsTransferDocument.currentFormatVersion else {
            throw SettingsTransferError.fromNewerFormatVersion(foundVersion: document.formatVersion)
        }
        guard !document.modelConfiguration.providers.isEmpty else {
            throw SettingsTransferError.importedFileHasNoModelProviders
        }

        // Both saves clamp and post their own change notification, so the running
        // app (every client, the overlay, the notch) picks the imported values up
        // without a restart — 「导入，自动加载出来」.
        try AppSettingsStore.save(document.appSettings)
        try ModelConfigurationStore.save(document.modelConfiguration)

        let configuredRoleCount = [
            document.modelConfiguration.transcriptionProviderID,
            document.modelConfiguration.visionProviderID,
            document.modelConfiguration.speechProviderID,
        ].compactMap { $0 }.count

        return SettingsTransferSummary(
            exportedAt: document.exportedAt,
            providerCount: document.modelConfiguration.providers.count,
            configuredRoleCount: configuredRoleCount
        )
    }

    /// `Clicky设置-2026-09-23.json` — dated, so exporting twice does not silently
    /// overwrite yesterday's copy in the same folder.
    static func suggestedExportFileName(on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Clicky设置-\(formatter.string(from: date)).json"
    }

    /// Writes the bytes and tightens the file to 0600, because it carries the
    /// user's API keys.
    ///
    /// No `.atomic` here, unlike the two stores: this is a brand-new file the
    /// user just named, so there is nothing to replace atomically — and `Data`
    /// writes are atomic anyway for small payloads. What is *not* automatic is
    /// the permission, which would otherwise be 0644 and world-readable.
    static func writeExportData(_ exportData: Data, to destinationURL: URL) throws {
        try exportData.write(to: destinationURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }
}

// MARK: - The sidebar pages

/// 「导出设置」/「导入设置」各是一页。
///
/// 一开始这两个动作是**设置侧栏底部的一行按钮**，用户 2026-09-23 否掉了这个位置：
/// 「我让你做的导入导出设置，我还是觉得不应该放在设置页面左侧边栏的下面，应该类似于
/// 左侧边栏的通用……或者在通用的下面，比如说现在不是有"看与操作"吗？你可以在"看与操作"
/// 下面增加一个导入导出，然后把它作为两个选项的方式，不要放在这个下面，太不舒服了」。
/// 所以现在是侧栏里一个「导入导出」分组下的**两个页面**，和其余十页同一个形状——同样是
/// 标题 + 分组标签 + 卡片，同样是点一下侧栏就切过去，不再是钉在底部、跟页面列表抢位置的
/// 一行。这一改同时解决了另一半问题：那一行原来一直占着侧栏底部，用户滚动页面列表时
/// 它不动，看起来像"粘"在设置上的东西。
///
/// 说明文字仍然是用户明确要的（「要说明一下，导入导出的其实是设置页面的参数，让用户知道
/// 导入的是什么」），现在写进卡片里 —— 比原来那行 10.5pt 的小字有地方说话，也不必挤在
/// 按钮上面。
struct SettingsTransferPage: View {

    /// Which of the two pages this is. They share every piece of state and both
    /// helpers below; only the copy and which action the button runs differ, so
    /// one view with a mode beats two near-identical views.
    enum Mode {
        case exportSettings
        case importSettings

        var title: String {
            switch self {
            case .exportSettings: return "导出设置"
            case .importSettings: return "导入设置"
            }
        }

        var subtitle: String {
            switch self {
            case .exportSettings:
                return "把设置页面的全部参数写成一个 JSON 文件，换一台机器也能接着用。"
            case .importSettings:
                return "读回一个之前导出的设置文件，覆盖当前设置页面的全部参数。"
            }
        }
    }

    let mode: Mode

    /// Set when a file has been picked and read but not yet applied — the
    /// confirmation is between those two steps on purpose (applying replaces
    /// every setting, and there is no undo).
    @State private var pendingImport: PendingImport?
    @State private var resultAlert: ResultAlert?

    private struct PendingImport {
        let fileName: String
        let importedData: Data
    }

    private struct ResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        // 成功与失败都走这一条，靠标题和文案区分（「已导出设置」/「导出失败」）。
        // 不设 `role`：那只有确认框上的按钮才有意义，用在一次结果提示上会把"读到
        // 了坏文件"渲染成一次危险操作。
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: mode.title, subtitle: mode.subtitle)

            SettingsGroupLabel(mode == .exportSettings ? "会写出去的内容" : "导入会做什么")

            SettingsCard {
                if mode == .exportSettings {
                    SettingsRow(
                        label: "设置页面的参数",
                        description: "通用 / 交互样式 / 模型 / Agent / 对话与记忆 / 听 / 说 / 看与截图 / 操作 / 快捷键，这些页面上的全部设置。"
                    )
                    SettingsCardRowDivider(leadingInset: 14)
                    SettingsRow(
                        label: "模型服务商与 API Key",
                        description: "三个模型角色，以及每个服务商的 URL、Key 和模型名。文件按仅本机可读的权限写，但它确实带着你的 Key，别随手发到公开的地方。"
                    )
                    SettingsCardRowDivider(leadingInset: 14)
                    SettingsRow(
                        label: "不含对话内容",
                        description: "对话记录、每条对话里的截图和压缩摘要都不在里面。「对话与记忆」页上的设置本身是包含的。"
                    )
                    SettingsCardRowDivider(leadingInset: 14)
                    SettingsRow(
                        label: "写到哪里",
                        description: "自己选一个位置，文件名默认是 Clicky设置-日期.json。"
                    ) {
                        NotchBarActionButton(
                            title: "导出…",
                            systemImage: "square.and.arrow.up",
                            help: "把设置页面的全部参数写到一个 JSON 文件（含模型服务商的 API Key，不含对话内容）"
                        ) {
                            exportSettingsToFile()
                        }
                    }
                } else {
                    SettingsRow(
                        label: "会覆盖当前设置",
                        description: "设置页面的全部参数会被文件里的值覆盖。覆盖之后没有撤销，所以在动手之前会先问一次。对话内容不受影响。"
                    )
                    SettingsCardRowDivider(leadingInset: 14)
                    SettingsRow(
                        label: "导入后立刻生效",
                        description: "不用再按保存，也不用重启 —— 每个子系统都是从这两个文件里现读的。"
                    )
                    SettingsCardRowDivider(leadingInset: 14)
                    SettingsRow(
                        label: "读哪一个文件",
                        description: "选一个之前用「导出设置」生成的文件。格式不对、版本更新、或者模型配置是空的，都会被认出来并原样退回去，不会改掉任何设置。"
                    ) {
                        NotchBarActionButton(
                            title: "导入…",
                            systemImage: "square.and.arrow.down",
                            help: "读回一个之前导出的设置文件，覆盖当前设置页面的全部参数（不含对话内容）"
                        ) {
                            importSettingsFromFile()
                        }
                    }
                }
            }
        }
        // 与 `GeneralSettingsView` 里那十页同一套内边距：别的页面的边距在它的
        // body 上，而这一页不走那里，所以要自己带一份，否则标题和卡片会顶到边上。
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 覆盖当前设置是不可撤销的，所以先问一句，问的话里带上文件名与内容概要。
        .alert(
            "要用这个文件覆盖当前设置吗？",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { isPresented in if !isPresented { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { pendingImport in
            Button("取消", role: .cancel) { self.pendingImport = nil }
            Button("导入", role: .destructive) {
                applyPendingImport(pendingImport)
            }
        } message: { pendingImport in
            Text("文件：\(pendingImport.fileName)\n\n设置页面的全部参数会被这个文件里的值覆盖，对话内容不受影响。覆盖之后没有撤销。")
        }
        // 读到了坏文件 / 导入完成都走这一条。用 `isPresented` + `presenting` 而不是
        // 老的 `alert(item:)`：后者要返回一个 `Alert` 值，本仓库其余的地方（
        // `GeneralSettingsView` 的清空确认、`ModelSettingsView` 的删除确认）都是
        // 这一种，两处不同写法只会让人以为行为也不同。
        .alert(
            resultAlert?.title ?? "",
            isPresented: Binding(
                get: { resultAlert != nil },
                set: { isPresented in if !isPresented { resultAlert = nil } }
            ),
            presenting: resultAlert
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { resultAlert in
            Text(resultAlert.message)
        }
    }

    // MARK: Export

    private func exportSettingsToFile() {
        // An `LSUIElement` app is never the active application on its own, and a
        // modal panel that is not key swallows typing — the settings window has
        // the same rule. See `SettingsWindowController` and
        // `NotchSupport.modalFileDialogWindowLevel` for the level's own reason.
        NSApp.activate()

        let savePanel = NSSavePanel()
        savePanel.title = "导出 Clicky 设置"
        savePanel.message = "导出设置页面的全部参数（含模型服务商的 API Key，不含对话内容）"
        savePanel.prompt = "导出"
        savePanel.nameFieldStringValue = SettingsTransferService.suggestedExportFileName(on: Date())
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        // Without this the panel opens BEHIND the expanded notch sheet — the
        // notch panel sits at `.mainMenu + 1` and a modal panel's default level
        // is nine steps below it.
        savePanel.level = NotchSupport.modalFileDialogWindowLevel

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }

        do {
            let exportData = try SettingsTransferService.makeExportData()
            try SettingsTransferService.writeExportData(exportData, to: destinationURL)
            resultAlert = ResultAlert(
                title: "已导出设置",
                message: "写到了：\n\(destinationURL.path)\n\n这个文件里有你的模型 API Key，别随手发到公开的地方。"
            )
        } catch {
            resultAlert = ResultAlert(
                title: "导出失败",
                message: error.localizedDescription
            )
        }
    }

    // MARK: Import

    private func importSettingsFromFile() {
        NSApp.activate()

        let openPanel = NSOpenPanel()
        openPanel.title = "导入 Clicky 设置"
        openPanel.message = "选择一个之前用「导出设置」生成的文件"
        openPanel.prompt = "选择"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.json]
        openPanel.level = NotchSupport.modalFileDialogWindowLevel

        guard openPanel.runModal() == .OK, let sourceURL = openPanel.url else { return }

        // Read the file now, while it is still obviously "the file you picked",
        // rather than after the confirmation — a file that moved or was deleted
        // in between would otherwise surface as a failure at the worst moment.
        do {
            pendingImport = PendingImport(
                fileName: sourceURL.lastPathComponent,
                importedData: try Data(contentsOf: sourceURL)
            )
        } catch {
            resultAlert = ResultAlert(
                title: "读不到这个文件",
                message: error.localizedDescription
            )
        }
    }

    private func applyPendingImport(_ pendingImport: PendingImport) {
        self.pendingImport = nil

        do {
            let summary = try SettingsTransferService.applyImportedData(pendingImport.importedData)
            let exportDateLine = summary.exportedAt.formatted(date: .numeric, time: .shortened)
            resultAlert = ResultAlert(
                title: "已导入设置",
                message: """
                已经应用，不用再按保存。

                文件导出于：\(exportDateLine)
                服务商：\(summary.providerCount) 个
                已配置的模型角色：\(summary.configuredRoleCount) / 3
                """
            )
        } catch {
            resultAlert = ResultAlert(
                title: "导入失败",
                message: error.localizedDescription
            )
        }
    }
}
