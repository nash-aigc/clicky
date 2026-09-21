//
//  ModelConfigurationStore.swift
//  leanring-buddy
//
//  Reads and writes the user's model configuration
//  (`~/Library/Application Support/Clicky/ModelConfiguration.json`).
//
//  Deliberately `nonisolated`: the project builds with
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_VERSION = 5.0`, and in
//  Swift 5 mode the compiler emits no diagnostic when an unannotated
//  `DispatchQueue` closure touches MainActor-isolated state. A configuration
//  read that happens to run off the main thread therefore fails silently rather
//  than failing to compile. Opting the whole type out of actor isolation and
//  guarding the one piece of mutable state with an `NSLock` makes every read
//  safe from any thread by construction, instead of relying on the compiler to
//  catch a mistake it demonstrably will not catch.
//
//  Every read returns a copy of a value type, so callers never share mutable
//  state with each other or with this store.
//

import Foundation

nonisolated extension Notification.Name {
    /// Posted after a configuration is written to disk.
    ///
    /// The menu bar panel and the settings window both listen for it so they
    /// re-render against the new values — a save in the settings window is
    /// reflected in the panel without either one polling the other.
    static let clickyModelConfigurationChanged = Notification.Name("clickyModelConfigurationChanged")
}

enum ModelConfigurationStoreError: LocalizedError {
    case applicationSupportDirectoryUnavailable
    case couldNotEncodeConfiguration(underlyingError: Error)
    case couldNotWriteConfiguration(underlyingError: Error)
    case couldNotRestrictFilePermissions(underlyingError: Error)

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "找不到 ~/Library/Application Support 目录，配置无法保存。"
        case .couldNotEncodeConfiguration(let underlyingError):
            return "配置序列化失败：\(underlyingError.localizedDescription)"
        case .couldNotWriteConfiguration(let underlyingError):
            return "配置写入失败：\(underlyingError.localizedDescription)"
        case .couldNotRestrictFilePermissions(let underlyingError):
            return "配置已写入，但没能把文件权限收紧到 600：\(underlyingError.localizedDescription)"
        }
    }
}

nonisolated enum ModelConfigurationStore {

    // MARK: - Paths

    /// `~/Library/Application Support/Clicky/ModelConfiguration.json`.
    ///
    /// Next to `BailianSecrets.plist` — outside the repository, so the API keys
    /// the user types into the settings window never land in version control.
    static var configurationFileURL: URL? {
        guard let applicationSupportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("ModelConfiguration.json")
    }

    // MARK: - Cached state

    private static let configurationLock = NSLock()
    private static var cachedConfiguration: ModelConfiguration?

    // MARK: - Reading

    /// The configuration in effect right now.
    ///
    /// Cached after the first call because this is read on every request the app
    /// makes. The lock is held only while copying the cached value — all file I/O
    /// happens outside it, so a slow disk can never block a reader.
    static func snapshot() -> ModelConfiguration {
        configurationLock.lock()
        if let cachedConfiguration {
            configurationLock.unlock()
            return cachedConfiguration
        }
        configurationLock.unlock()

        let loadedConfiguration = loadConfigurationFromDiskOrSeed()

        configurationLock.lock()
        // Another thread may have finished loading while we were on disk. Keep
        // whichever value landed first so every caller sees the same one.
        if let cachedConfiguration {
            configurationLock.unlock()
            return cachedConfiguration
        }
        cachedConfiguration = loadedConfiguration
        configurationLock.unlock()

        return loadedConfiguration
    }

    /// Drops the cache so the next `snapshot()` re-reads from disk.
    static func invalidateCache() {
        configurationLock.lock()
        cachedConfiguration = nil
        configurationLock.unlock()
    }

    // MARK: - Writing

    /// Writes the configuration and swaps it into the cache.
    ///
    /// Only this call changes what the app uses — the settings window edits a
    /// draft and saves it here, so an abandoned edit never half-applies.
    static func save(_ configuration: ModelConfiguration) throws {
        guard let configurationFileURL else {
            throw ModelConfigurationStoreError.applicationSupportDirectoryUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encodedConfiguration: Data
        do {
            encodedConfiguration = try encoder.encode(configuration)
        } catch {
            throw ModelConfigurationStoreError.couldNotEncodeConfiguration(underlyingError: error)
        }

        let containingDirectoryURL = configurationFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: containingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encodedConfiguration.write(to: configurationFileURL, options: .atomic)
        } catch {
            throw ModelConfigurationStoreError.couldNotWriteConfiguration(underlyingError: error)
        }

        // `createDirectory` ignores `attributes` when the directory already
        // exists, and this directory also holds BailianSecrets.plist, so it
        // predates us. Applied separately, and tolerated failing, because a
        // directory permission is not worth refusing a save over.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: containingDirectoryURL.path
        )

        // `.atomic` writes to a temporary file and renames it into place, so the
        // finished file carries the temporary file's permissions (0644 after
        // umask) rather than anything requested at write time. The mode has to be
        // applied after the rename — and it matters here, because the file holds
        // API keys.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationFileURL.path
            )
        } catch {
            throw ModelConfigurationStoreError.couldNotRestrictFilePermissions(underlyingError: error)
        }

        configurationLock.lock()
        cachedConfiguration = configuration
        configurationLock.unlock()

        NotificationCenter.default.post(name: .clickyModelConfigurationChanged, object: nil)
    }

    // MARK: - Loading

    /// Reads the stored configuration, or builds the starting one when there is
    /// nothing readable on disk.
    ///
    /// Only an absent or undecodable file falls back to the seed. A file that
    /// decodes to zero providers is respected as-is: that is a configuration the
    /// user built deliberately, and resurrecting deleted providers on every
    /// launch would be worse than an app with nothing configured.
    private static func loadConfigurationFromDiskOrSeed() -> ModelConfiguration {
        guard let configurationFileURL,
              let storedConfigurationData = try? Data(contentsOf: configurationFileURL),
              let decodedConfiguration = try? JSONDecoder().decode(
                  ModelConfiguration.self,
                  from: storedConfigurationData
              )
        else {
            return makeSeedConfiguration()
        }

        return decodedConfiguration
    }

    /// The configuration a user gets before they have ever opened the settings
    /// window, so that upgrading changes nothing about how the app behaves.
    ///
    /// Built in memory only — nothing is written to disk until the user saves
    /// something. That keeps deleting `ModelConfiguration.json` a genuine reset
    /// back to "follow `BailianSecrets.plist`", and means this app never writes
    /// a secret anywhere as a side effect of launching.
    private static func makeSeedConfiguration() -> ModelConfiguration {
        var seededConfiguration = ModelConfiguration(providers: [])

        // A Bailian card is always offered, with its model names already filled
        // in, so a user whose secrets plist is missing only has to paste a URL
        // and a key rather than know which four models this app wants.
        var bailianProvider = ProviderProfile(
            id: UUID(),
            displayName: APIProviderFlavor.bailian.displayName,
            baseURL: BailianConfiguration.legacyWorkspaceBaseURL ?? "",
            apiKey: BailianConfiguration.legacyAPIKey ?? "",
            flavor: .bailian,
            customProtocol: nil
        )
        bailianProvider.visionModelID = legacySelectedVisionModelID()
        bailianProvider.transcriptionModelID = BailianConfiguration.Models.realtimeTranscription
        bailianProvider.speechModelID = BailianConfiguration.Models.textToSpeech
        bailianProvider.speechVoiceID = BailianConfiguration.textToSpeechVoice
        seededConfiguration.providers.append(bailianProvider)

        // A DeepSeek card is offered too, so "switch the brain to DeepSeek" is a
        // two-field edit instead of setting a provider up from scratch. Its API
        // key is deliberately left blank: this app only ever stores a secret the
        // user typed into the settings window themselves.
        var deepSeekProvider = ProviderProfile(
            id: UUID(),
            displayName: APIProviderFlavor.deepSeek.displayName,
            baseURL: APIProviderFlavor.deepSeek.defaultBaseURL,
            apiKey: "",
            flavor: .deepSeek,
            customProtocol: nil
        )
        deepSeekProvider.visionModelID = APIProviderFlavor.deepSeek.presetModelIDs(for: .vision).first
        seededConfiguration.providers.append(deepSeekProvider)

        // Roles are only assigned when the credentials to serve them actually
        // exist. Assigning a role to a provider with a blank URL would put the
        // app in its "configured, but every request fails" state on first launch.
        let bailianProviderIsUsable = !bailianProvider.baseURL.isEmpty && !bailianProvider.apiKey.isEmpty
        if bailianProviderIsUsable {
            seededConfiguration.visionProviderID = bailianProvider.id
            seededConfiguration.transcriptionProviderID = bailianProvider.id
            seededConfiguration.speechProviderID = bailianProvider.id
        }

        return seededConfiguration
    }

    /// Carries the vision model the user had picked in the menu bar panel's old
    /// Plus/Flash picker into the new configuration, so that upgrading does not
    /// silently move them back to the more expensive model.
    private static func legacySelectedVisionModelID() -> String {
        let storedModelID = UserDefaults.standard.string(forKey: "selectedClaudeModel")
        if let storedModelID,
           BailianConfiguration.Models.VisionChat.allModelIDs.contains(storedModelID) {
            return storedModelID
        }

        return BailianConfiguration.Models.VisionChat.defaultModelID
    }
}
