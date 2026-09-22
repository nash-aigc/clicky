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
    var storedConversationExchangeCount: Int {
        ConversationSessionsStore.allSessions().reduce(0) { $0 + $1.entries.count }
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
