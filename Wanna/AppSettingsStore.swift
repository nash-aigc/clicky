//
//  AppSettingsStore.swift
//  Wanna
//
//  Reads and writes the user's app settings
//  (`~/Library/Application Support/Wanna/AppSettings.json`).
//
//  Mirrors `ModelConfigurationStore` exactly — `nonisolated`, one `NSLock` over
//  a cached value type, atomic write followed by a 0600 permission fix-up, and
//  a notification posted after every save. See the header comment there for why
//  the isolation is built this way rather than trusted to the compiler.
//
//  Unlike the model configuration there is no first-run seed: an absent file
//  simply means "every setting at its default", which is the app's historical
//  behavior. Nothing is written to disk until the user presses 保存.
//

import Foundation

nonisolated extension Notification.Name {
    /// Posted after app settings are written to disk. Listeners re-read
    /// `AppSettingsStore.snapshot()` to pick up the new values.
    static let wannaAppSettingsChanged = Notification.Name("wannaAppSettingsChanged")
}

nonisolated enum AppSettingsStore {

    /// `~/Library/Application Support/Wanna/AppSettings.json`.
    ///
    /// Same directory as the model configuration. There are no secrets in this
    /// file, but the 0600 treatment is kept anyway — the conversation history
    /// flag and the free-form prompt instructions are personal too.
    static var settingsFileURL: URL? {
        AppSupportDirectory.fileURL(named: "AppSettings.json")
    }

    // MARK: - Cached state

    private static let settingsLock = NSLock()
    private static var cachedSettings: AppSettings?

    // MARK: - Reading

    /// The settings in effect right now. Cached after the first call; the lock
    /// is held only while copying the value, so file I/O never blocks a reader.
    static func snapshot() -> AppSettings {
        settingsLock.lock()
        if let cachedSettings {
            settingsLock.unlock()
            return cachedSettings
        }
        settingsLock.unlock()

        let loadedSettings = loadSettingsFromDiskOrDefaults()

        settingsLock.lock()
        if let cachedSettings {
            settingsLock.unlock()
            return cachedSettings
        }
        cachedSettings = loadedSettings
        settingsLock.unlock()

        return loadedSettings
    }

    /// Drops the cache so the next `snapshot()` re-reads from disk.
    static func invalidateCache() {
        settingsLock.lock()
        cachedSettings = nil
        settingsLock.unlock()
    }

    // MARK: - Writing

    /// Writes the settings (clamped first) and swaps them into the cache.
    static func save(_ settings: AppSettings) throws {
        guard let settingsFileURL else {
            throw ModelConfigurationStoreError.applicationSupportDirectoryUnavailable
        }

        let clampedSettings = settings.clamped()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encodedSettings: Data
        do {
            encodedSettings = try encoder.encode(clampedSettings)
        } catch {
            throw ModelConfigurationStoreError.couldNotEncodeConfiguration(underlyingError: error)
        }

        let containingDirectoryURL = settingsFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: containingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encodedSettings.write(to: settingsFileURL, options: .atomic)
        } catch {
            throw ModelConfigurationStoreError.couldNotWriteConfiguration(underlyingError: error)
        }

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: containingDirectoryURL.path
        )

        // `.atomic` renames a temporary file into place carrying 0644 permissions,
        // so the mode is applied after the rename (same reason as in the model
        // configuration store).
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsFileURL.path
            )
        } catch {
            throw ModelConfigurationStoreError.couldNotRestrictFilePermissions(underlyingError: error)
        }

        settingsLock.lock()
        cachedSettings = clampedSettings
        settingsLock.unlock()

        NotificationCenter.default.post(name: .wannaAppSettingsChanged, object: nil)
    }

    // MARK: - Loading

    /// An absent or undecodable file reads as "all defaults" — that is the
    /// behavior every build of this app has had, so it is the honest default.
    private static func loadSettingsFromDiskOrDefaults() -> AppSettings {
        guard let settingsFileURL,
              let storedSettingsData = try? Data(contentsOf: settingsFileURL),
              let decodedSettings = try? JSONDecoder().decode(AppSettings.self, from: storedSettingsData)
        else {
            return AppSettings()
        }

        return decodedSettings.clamped()
    }
}
