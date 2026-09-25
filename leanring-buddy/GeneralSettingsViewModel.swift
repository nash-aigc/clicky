//
//  GeneralSettingsViewModel.swift
//  leanring-buddy
//
//  State for the general pages of the settings window (everything except 模型,
//  which is owned by `ModelSettingsViewModel`): a draft `AppSettings` the user
//  edits, and the actions that save or reset it.
//
//  Mirrors `ModelSettingsViewModel`'s draft pattern on purpose: the window edits
//  a *draft* rather than the live settings, so nothing the user flips changes
//  what the app is doing until they press 保存, and an abandoned edit can't
//  leave the app in a half-changed state.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class GeneralSettingsViewModel: ObservableObject {

    /// The settings being edited. Controls bind directly to fields of this struct
    /// through `binding(_:)`.
    // MARK: - 复盘（设置页「复盘」）

    /// 跑复盘的结果。**放在这里而不是直接读 `ReviewRunner`** —— 这一页是
    /// `GeneralSettingsView` 的扩展，struct 的扩展加不了 `@ObservedObject`，
    /// 而 ViewModel 是它已经在观察的那个对象。转发一层，观察关系就现成了。
    @Published var reviewTable: [ReviewCountRow] = []
    @Published var reviewCandidates: [ReviewCountRow] = []
    @Published var reviewIsRunning = false
    @Published var reviewLastError: String?
    @Published var reviewHasRun = false

    /// 「这条候选走哪条路」的草稿，键是「大类/小类」。
    ///
    /// **不落盘**：用户打字打到一半，不该每敲一个字符就写一次设置文件。批准才写。
    @Published var reviewRoutes: [String: String] = [:]

    func runReview() async {
        guard !reviewIsRunning else { return }
        reviewIsRunning = true
        reviewLastError = nil
        await ReviewRunner.shared.run()
        let runner = ReviewRunner.shared
        reviewTable = runner.lastTable
        reviewCandidates = runner.candidates
        reviewLastError = runner.lastError
        reviewHasRun = true
        reviewIsRunning = false
    }

    @Published var draftSettings: AppSettings {
        didSet {
            guard draftSettings != oldValue else { return }
            // A saved-state message that describes settings the user has since
            // edited again would be stale — drop it the moment anything changes.
            saveErrorMessage = nil
            conversationMemoryStatusMessage = nil
        }
    }

    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var lastSavedAt: Date?

    /// The settings as last written to disk. Everything that differs from it is
    /// unsaved work, which is what `isDirty` reports.
    private var savedSettings: AppSettings

    init() {
        let currentSettings = AppSettingsStore.snapshot()
        self.savedSettings = currentSettings
        self.draftSettings = currentSettings
    }

    // MARK: - Dirty state

    var isDirty: Bool {
        draftSettings != savedSettings
    }

    /// Re-reads the saved settings when the window is reopened.
    ///
    /// Same semantics as `ModelSettingsViewModel.reloadDraftFromStoreIfUnchanged`:
    /// the window controller is created once and reused, so without this the
    /// window would come back showing whatever was in the draft when it was last
    /// closed. A draft with unsaved edits is left alone — someone who closed the
    /// window without meaning to should not lose their typing.
    func reloadFromStoreIfUnchanged() {
        guard !isDirty else { return }
        let currentSettings = AppSettingsStore.snapshot()
        savedSettings = currentSettings
        draftSettings = currentSettings
        saveErrorMessage = nil
        lastSavedAt = nil
    }

    // MARK: - Actions

    func save() {
        do {
            try AppSettingsStore.save(draftSettings)
            // The store clamps before caching, so the snapshot it kept may differ
            // from the draft in the clamped fields. Comparing dirty state against
            // the same clamped values the store now holds keeps `isDirty` honest
            // right after a save instead of immediately reporting a phantom edit.
            savedSettings = draftSettings.clamped()
            saveErrorMessage = nil
            lastSavedAt = Date()
            // The store posts `.clickyAppSettingsChanged`, which listeners read
            // back through `AppSettingsStore.snapshot()`.
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    /// Puts every setting back to its default **in the draft only**. Nothing is
    /// saved until the user presses 保存, so 恢复默认 followed by closing the
    /// window changes nothing on disk.
    func resetToDefaults() {
        draftSettings = AppSettings()
    }

    /// Commits **one** field straight to disk and leaves every other unsaved
    /// edit in the draft alone.
    ///
    /// Written for the 默认项目文件夹 row, and the reason is measured rather than
    /// theoretical: the user reported 「默认项目文件夹路径在设置页面，用户之前设置过，
    /// 但好像没有被保存，现在又变成空的了」 and the file agrees — the key was
    /// **absent entirely** from `AppSettings.json`. The picker only ever wrote
    /// the draft, so choosing a folder and not pressing 保存 lost it, while the
    /// row went on showing the path as if it had stuck. Every other row on these
    /// pages is a switch or a slider, where "the draft is not the setting until
    /// you save" is plain; a folder dialog is the opposite — the click IS the
    /// commitment gesture, and a path sitting in the row reads as done.
    ///
    /// Not simply `save()`: that writes the whole draft, so picking a folder
    /// would also commit whatever else the user happened to be mid-edit on.
    /// Here only the one field travels, from a copy of the settings as last
    /// written — so the other rows stay exactly as dirty as they were.
    func persistAgentDefaultProjectFolderImmediately(_ folderPath: String?) {
        draftSettings.agentDefaultProjectFolder = folderPath

        var settingsToSave = savedSettings
        settingsToSave.agentDefaultProjectFolder = folderPath
        do {
            try AppSettingsStore.save(settingsToSave)
            // Mirror `save()`: the store clamps before caching, so compare
            // against the clamped values or `isDirty` reports a phantom edit.
            savedSettings = settingsToSave.clamped()
            saveErrorMessage = nil
            lastSavedAt = Date()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Conversation memory

    /// What to show under the 清空对话记忆 button once it has run.
    ///
    /// Cleared whenever the draft changes, for the same reason `saveErrorMessage`
    /// is: a "已清空" left over from an earlier click reads as if the clear just
    /// happened again.
    @Published private(set) var conversationMemoryStatusMessage: String?

    /// How many exchanges are stored right now, across every session.
    ///
    /// Read live from the store rather than kept as state, because nothing here
    /// writes to it except the clear button — and after a clear the answer is
    /// simply zero, which needs no cache to be correct.
    ///
    /// Archived conversations are counted: the clear button deletes them too
    /// (`clearAllSessions` empties the whole file), so counting only the live
    /// sessions would let the row promise "there is nothing on disk" while
    /// conversations the user deleted are still there.
    var storedConversationExchangeCount: Int {
        ConversationSessionsStore.allSessionsIncludingArchived().reduce(0) { $0 + $1.entries.count }
    }

    /// Deletes every stored session and tells the running app to forget them.
    ///
    /// Deliberately *not* routed through the draft-and-save flow the rest of this
    /// page uses. Deleting files the user asked to delete should not depend on
    /// them also pressing 保存 afterwards — and the store posts
    /// `.clickyConversationHistoryCleared`, which is what makes the live copy in
    /// `CompanionManager` drop too rather than being written straight back on the
    /// next turn.
    func clearConversationMemory() {
        ConversationSessionsStore.clearAllSessions()
        conversationMemoryStatusMessage = "已清空，接下来它会从头开始记。"
    }

    // MARK: - Bindings

    /// A binding to one field of the draft settings.
    ///
    /// Most controls need `Binding<Double>` / `Binding<Bool>` / an enum binding
    /// while the draft is one struct — this resolves a `WritableKeyPath` against
    /// the draft on every read and write, so an edit lands exactly where the
    /// control says it does.
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { [weak self] in
                guard let self else { return AppSettings()[keyPath: keyPath] }
                return self.draftSettings[keyPath: keyPath]
            },
            set: { [weak self] newValue in
                guard let self else { return }
                self.draftSettings[keyPath: keyPath] = newValue
            }
        )
    }

    /// 「听」页那一栏当前选中的识别模型（来自**模型配置**，不是 AppSettings）。
    var currentRecognitionModelID: String {
        ModelConfigurationStore.snapshot().status(of: .transcription).resolvedRole?.modelID ?? ""
    }

    /// 换识别模型。写的是 `ModelConfiguration.json` 里那个 provider 的
    /// `transcriptionModelID` —— 也就是「模型」页同一条数据，只是从「听」页也能改。
    ///
    /// 为什么把它放在听写页而不是只在「模型」页：用户是在**听的效果**上做判断的，
    /// 让他为了换个识别模型跑去「模型」页找三个角色里的一个，是把判断和操作隔开了。
    func selectRecognitionModel(_ modelID: String) {
        var configuration = ModelConfigurationStore.snapshot()
        guard let providerIndex = configuration.providers.firstIndex(
            where: { $0.id == configuration.transcriptionProviderID }
        ) else { return }
        configuration.providers[providerIndex].transcriptionModelID = modelID
        do {
            try ModelConfigurationStore.save(configuration)
            print("🎙️ 识别模型已切换到 \(modelID)（在「听（识别）」页选的）")
        } catch {
            print("⚠️ 识别模型没写进磁盘：\(error.localizedDescription)")
        }
    }
}

// MARK: - Push-to-talk shortcut raw values

/// The persisted form of `BuddyPushToTalkShortcut.ShortcutOption`.
///
/// `AppSettings` stores the shortcut as a string (`pushToTalkShortcutRawValue`)
/// so an unknown value from a future or older build degrades to the default
/// instead of failing the whole decode — but the enum itself lives in
/// `BuddyDictationManager.swift` without a raw value, and that file is not
/// editable from this feature. A retroactive `RawRepresentable` conformance in
/// this module supplies the exact API `AppSettings` was written against. The
/// raw strings are the case names: they are stable identifiers written into
/// `AppSettings.json`, so they must never be renamed once shipped.
nonisolated extension BuddyPushToTalkShortcut.ShortcutOption: RawRepresentable {
    var rawValue: String {
        switch self {
        case .shiftFunction: return "shiftFunction"
        case .controlOption: return "controlOption"
        case .shiftControl: return "shiftControl"
        case .controlOptionSpace: return "controlOptionSpace"
        case .shiftControlSpace: return "shiftControlSpace"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "shiftFunction": self = .shiftFunction
        case "controlOption": self = .controlOption
        case "shiftControl": self = .shiftControl
        case "controlOptionSpace": self = .controlOptionSpace
        case "shiftControlSpace": self = .shiftControlSpace
        default: return nil
        }
    }
}
