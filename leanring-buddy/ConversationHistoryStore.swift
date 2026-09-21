//
//  ConversationHistoryStore.swift
//  leanring-buddy
//
//  Persists the conversation so 对话与记忆 → 「重启后保留对话」 can mean what it
//  says, and holds the running summary that 「历史自动压缩」 produces.
//
//  Written to `~/Library/Application Support/Clicky/ConversationHistory.json`
//  (0600), outside the repo — same reasoning as `ModelConfiguration.json`: it
//  survives a clean checkout and never needs a `.gitignore` entry.
//
//  This file is the one place in the app where the user's own words are written
//  to disk, which is why the setting that turns it on defaults to off and why
//  turning it off deletes the file rather than merely stopping future writes.
//

import Foundation

/// One exchange: what the user asked and what the companion answered.
nonisolated struct ConversationHistoryEntry: Codable, Equatable {
    let userTranscript: String
    let assistantResponse: String

    /// The screenshots the model was looking at when it answered.
    ///
    /// Deliberately absent from `CodingKeys` below, so they live in memory and
    /// never reach the file. They are the largest thing this app produces — one
    /// JPEG per display per turn — and the setting's own description promises a
    /// restart drops them. Sending them again is only useful for as long as the
    /// follow-up question is still about the same screen.
    var userScreenshots: [ConversationHistoryScreenshot] = []

    private enum CodingKeys: String, CodingKey {
        case userTranscript
        case assistantResponse
    }
}

/// A screenshot kept alongside the exchange it was sent with.
nonisolated struct ConversationHistoryScreenshot: Equatable {
    let imageData: Data
    let label: String
}

/// What is stored on disk: the replayed exchanges plus the compressed summary of
/// everything older than them.
nonisolated struct StoredConversationHistory: Codable, Equatable {
    /// The running summary of exchanges that have aged out. Empty until
    /// 「历史自动压缩」 has had something to compress.
    var summary: String = ""

    var entries: [ConversationHistoryEntry] = []
}

/// Posted after `clear()` so the live copy in `CompanionManager` is dropped too.
///
/// The store cannot reach into the manager, and a cleared file with a live
/// in-memory history would mean the next answer still remembers a conversation
/// the user just deleted — and the next save would write it straight back.
nonisolated extension Notification.Name {
    static let clickyConversationHistoryCleared = Notification.Name("clickyConversationHistoryCleared")
}

nonisolated enum ConversationHistoryStore {

    /// `~/Library/Application Support/Clicky/ConversationHistory.json`.
    ///
    /// Computed rather than stored so it follows the real home directory; the
    /// directory is created on the way in by `save`.
    static var historyFileURL: URL? {
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
            .appendingPathComponent("ConversationHistory.json")
    }

    /// Guards `cachedHistory` only. File reads and writes happen outside it, so a
    /// slow disk never blocks a caller that just wants the current value.
    private static let historyLock = NSLock()
    private static var cachedHistory: StoredConversationHistory?

    /// The stored conversation, read from disk on first access.
    ///
    /// Deliberately `nonisolated` with an `NSLock`, copying the pattern from
    /// `ModelConfigurationStore`: the project builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and in Swift 5 mode the
    /// compiler gives no diagnostic for an unannotated `DispatchQueue` closure
    /// touching main-actor state — so isolation here has to be right by
    /// construction rather than by the compiler's say-so. Returning a value type
    /// means callers get a copy and there is no shared mutable state to race on.
    static func snapshot() -> StoredConversationHistory {
        historyLock.lock()
        if let cachedHistory {
            historyLock.unlock()
            return cachedHistory
        }
        historyLock.unlock()

        let loadedHistory = loadFromDisk()
        historyLock.lock()
        cachedHistory = loadedHistory
        historyLock.unlock()
        return loadedHistory
    }

    /// Writes the conversation and marks the cache current.
    static func save(_ history: StoredConversationHistory) throws {
        guard let historyFileURL else {
            throw ModelConfigurationStoreError.applicationSupportDirectoryUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encodedHistory: Data
        do {
            encodedHistory = try encoder.encode(history)
        } catch {
            throw ModelConfigurationStoreError.couldNotEncodeConfiguration(underlyingError: error)
        }

        let containingDirectoryURL = historyFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: containingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encodedHistory.write(to: historyFileURL, options: .atomic)
        } catch {
            throw ModelConfigurationStoreError.couldNotWriteConfiguration(underlyingError: error)
        }

        // `.atomic` writes to a temporary file and renames it into place, so the
        // finished file carries the temporary file's permissions (0644 after
        // umask) rather than anything requested at write time. The mode has to be
        // applied after the rename — and it matters here, because this file holds
        // the user's own words.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: historyFileURL.path
            )
        } catch {
            throw ModelConfigurationStoreError.couldNotRestrictFilePermissions(underlyingError: error)
        }

        historyLock.lock()
        cachedHistory = history
        historyLock.unlock()
    }

    /// Deletes the file and empties the cache.
    ///
    /// Used both by the 清空对话记忆 button and by turning 「重启后保留对话」 off —
    /// a user who switches that off is saying they do not want the conversation on
    /// disk, and leaving the file there would make the setting a lie for as long as
    /// they did not think to look for it.
    static func clear() {
        if let historyFileURL {
            try? FileManager.default.removeItem(at: historyFileURL)
        }

        historyLock.lock()
        cachedHistory = StoredConversationHistory()
        historyLock.unlock()

        NotificationCenter.default.post(name: .clickyConversationHistoryCleared, object: nil)
    }

    /// Forces the next `snapshot()` to re-read the file.
    static func invalidateCache() {
        historyLock.lock()
        cachedHistory = nil
        historyLock.unlock()
    }

    /// Reads the file, treating anything unreadable as an empty history.
    ///
    /// A corrupt or hand-edited file must not stop the app from answering — losing
    /// the memory of previous turns is a much smaller failure than being unable to
    /// hold a conversation at all.
    private static func loadFromDisk() -> StoredConversationHistory {
        guard let historyFileURL,
              let storedData = try? Data(contentsOf: historyFileURL) else {
            return StoredConversationHistory()
        }

        guard let decodedHistory = try? JSONDecoder().decode(
            StoredConversationHistory.self,
            from: storedData
        ) else {
            print("⚠️ Clicky: ConversationHistory.json could not be read — starting with an empty conversation.")
            return StoredConversationHistory()
        }

        return decodedHistory
    }
}
