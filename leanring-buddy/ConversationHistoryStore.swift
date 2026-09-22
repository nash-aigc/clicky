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

    /// Whether this reply was recorded by a build whose replies can carry action
    /// tags.
    ///
    /// `nil` — the key absent from the file — means the turn was written before the
    /// companion could act on the computer at all, so it cannot contain a
    /// `[CLICK:…]` or a `[TYPE:…]` even in principle. Replaying such a turn is not a
    /// neutral act: it shows the model a request answered with a past-tense sentence
    /// and nothing happening, which is exactly the shape the system prompt forbids —
    /// and an in-context example of the model's *own* past behaviour outweighs an
    /// instruction. Measured 2026-09-22: a single stale turn was enough to turn
    /// 「帮我点一下 7」 back into a reply that claimed the click and emitted no tag,
    /// with ten of them in the file.
    ///
    /// `BailianVisionChatAPI` reads this to decide whether the replayed turns need a
    /// note saying they predate the ability to act. The flag is optional, and so
    /// `decodeIfPresent`-shaped, for the usual reason: a non-optional `Bool` would
    /// make every file written before it existed fail to decode (`开发经验/10-踩过的坑.md` E1).
    var recordedWithActionTags: Bool?

    /// The agent loop's executed steps, one line each — what the conversation
    /// view's 「N 条进度」 disclosure expands to (HeyClicky's progress
    /// messages). `nil` on turns that ran no actions.
    var progressSteps: [String]?

    /// How long the turn took, in whole seconds, and when it finished — the
    /// finished turn's footer line (HeyClicky's `CoworkTurnFooter`).
    var turnDurationSeconds: Int?
    var turnFinishedAt: Date?

    /// True when the user stopped this turn mid-job. The conversation view
    /// renders an 「已被用户打断」 chip instead of a duration (HeyClicky's
    /// `CoworkInterruptedChip` / "INTERRUPTED BY USER").
    var wasInterrupted: Bool?

    // Every field above this comment that postdates the file format is
    // optional (`decodeIfPresent`-shaped) so files written before it existed
    // still decode — the same E1 rule `recordedWithActionTags` follows.

    private enum CodingKeys: String, CodingKey {
        case userTranscript
        case assistantResponse
        case recordedWithActionTags
        case progressSteps
        case turnDurationSeconds
        case turnFinishedAt
        case wasInterrupted
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

// MARK: - Multi-Session Storage

/// One named conversation — a session in the notch panel's sidebar.
///
/// `entries` and `summary` carry exactly what the single-conversation
/// `StoredConversationHistory` carried; a session is that shape plus an
/// identity, a title and timestamps, which is what lets the sidebar list many
/// of them and the pipeline keep addressing "the active one".
nonisolated struct ConversationSession: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    /// The running summary of this session's aged-out exchanges — the same
    /// 「历史自动压缩」 output the flat store kept, now per session.
    var summary: String

    var entries: [ConversationHistoryEntry]
}

/// What is stored on disk for sessions: the list plus which one is live.
nonisolated struct StoredConversationSessions: Codable, Equatable {
    var sessions: [ConversationSession] = []

    /// Optional on purpose: a hand-edited file without it still decodes, and
    /// resolution falls back to the most recently updated session.
    var activeSessionID: UUID?
}

/// Posted after every sessions mutation — create, delete, rename, switch,
/// append, trim, clear — so live UI (the notch sidebar) and the pipeline's
/// mirror in `CompanionManager` reload without a restart.
nonisolated extension Notification.Name {
    static let clickySessionsDidChange = Notification.Name("clickySessionsDidChange")
}

nonisolated enum ConversationSessionsStore {

    /// `~/Library/Application Support/Clicky/ConversationSessions.json`.
    static var sessionsFileURL: URL? {
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
            .appendingPathComponent("ConversationSessions.json")
    }

    private static let sessionsLock = NSLock()
    private static var cachedSessions: StoredConversationSessions?

    /// Title given to a brand-new session until its first user message arrives,
    /// and to the session the flat pre-sessions history migrates into.
    static let defaultSessionTitle = "新会话"
    static let migratedSessionTitle = "默认会话"

    /// The whole sessions document, read from disk on first access.
    ///
    /// Same `nonisolated` + `NSLock` shape as `ConversationHistoryStore`, for the
    /// same `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` reason: isolation here
    /// has to be right by construction.
    static func snapshot() -> StoredConversationSessions {
        sessionsLock.lock()
        if let cachedSessions {
            sessionsLock.unlock()
            return cachedSessions
        }
        sessionsLock.unlock()

        let loadedSessions = loadFromDiskWithMigration()
        sessionsLock.lock()
        cachedSessions = loadedSessions
        sessionsLock.unlock()
        return loadedSessions
    }

    /// All sessions, oldest created first — sidebar display order.
    static func allSessions() -> [ConversationSession] {
        snapshot().sessions
    }

    /// The session the pipeline is currently recording into. A session always
    /// exists — a store with none gets an empty default one — so the pipeline
    /// never has to branch on "no active session".
    static func activeSession() -> ConversationSession {
        let storedSessions = snapshot()
        if let activeSessionID = storedSessions.activeSessionID,
           let matchingSession = storedSessions.sessions.first(where: { $0.id == activeSessionID }) {
            return matchingSession
        }
        // Falls back to the most recently touched session when the id is absent
        // or stale (a hand-edited file, or an id whose session was deleted).
        let mostRecentSession = storedSessions.sessions.max { $0.updatedAt < $1.updatedAt }
            ?? ConversationSession(id: UUID(), title: defaultSessionTitle, createdAt: Date(), updatedAt: Date(), summary: "", entries: [])
        return mostRecentSession
    }

    /// Points the pipeline at another session. No-ops when the id is unknown,
    /// so a stale sidebar cannot blank the live conversation.
    static func setActiveSession(_ sessionID: UUID) {
        mutate { storedSessions in
            guard storedSessions.sessions.contains(where: { $0.id == sessionID }) else { return }
            storedSessions.activeSessionID = sessionID
        }
    }

    /// Creates an empty session and makes it active — what 「+ 新会话」 does.
    static func createSession(title: String = defaultSessionTitle) -> ConversationSession {
        let now = Date()
        let newSession = ConversationSession(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now,
            summary: "",
            entries: []
        )
        mutate { storedSessions in
            storedSessions.sessions.append(newSession)
            storedSessions.activeSessionID = newSession.id
        }
        return newSession
    }

    /// Deletes a session. Deleting the active one moves activity to the most
    /// recently touched survivor, so the pipeline always has somewhere to write.
    static func deleteSession(_ sessionID: UUID) {
        mutate { storedSessions in
            storedSessions.sessions.removeAll { $0.id == sessionID }
            if storedSessions.activeSessionID == sessionID {
                storedSessions.activeSessionID = nil
            }
        }
    }

    static func renameSession(_ sessionID: UUID, to newTitle: String) {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { storedSessions in
            guard let index = storedSessions.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            guard !trimmedTitle.isEmpty else { return }
            storedSessions.sessions[index].title = trimmedTitle
            storedSessions.sessions[index].updatedAt = Date()
        }
    }

    /// Appends one exchange to the active session (or, when `targetSessionID`
    /// is given, to that explicit session) and auto-titles a session that has
    /// never been titled: the first user message, truncated, is the name a
    /// sidebar can recognise — nobody names a conversation before saying
    /// anything in it. A session deleted mid-response is recreated rather
    /// than losing the turn.
    ///
    /// The explicit-session form is what the response pipeline uses: a turn
    /// belongs to the session that was active when it started, so a session
    /// switch made while the answer is still streaming must not land the
    /// finished turn in the conversation the user just left.
    static func appendEntry(_ entry: ConversationHistoryEntry, targetSessionID: UUID? = nil) {
        mutate { storedSessions in
            if storedSessions.sessions.isEmpty {
                let now = Date()
                storedSessions.sessions.append(
                    ConversationSession(
                        id: UUID(),
                        title: defaultSessionTitle,
                        createdAt: now,
                        updatedAt: now,
                        summary: "",
                        entries: []
                    )
                )
            }

            let targetIndex: Int
            if let targetSessionID,
               let index = storedSessions.sessions.firstIndex(where: { $0.id == targetSessionID }) {
                targetIndex = index
            } else if let activeSessionID = storedSessions.activeSessionID,
               let index = storedSessions.sessions.firstIndex(where: { $0.id == activeSessionID }) {
                targetIndex = index
            } else {
                targetIndex = storedSessions.sessions.count - 1
            }

            if storedSessions.sessions[targetIndex].entries.isEmpty
                && storedSessions.sessions[targetIndex].title == defaultSessionTitle {
                storedSessions.sessions[targetIndex].title = String(entry.userTranscript.prefix(20))
            }
            storedSessions.sessions[targetIndex].entries.append(entry)
            storedSessions.sessions[targetIndex].updatedAt = Date()
        }
    }

    /// Replaces one session's entries and summary in one write — what
    /// trimming and compression do together after each answer. The
    /// explicit-session form pairs with `appendEntry(_:targetSessionID:)` so
    /// a turn's whole write path stays inside the session it started in,
    /// whatever the sidebar switched to mid-response.
    static func replaceEntriesAndSummary(
        entries newEntries: [ConversationHistoryEntry],
        summary newSummary: String,
        sessionID targetSessionID: UUID
    ) {
        mutate { storedSessions in
            guard let index = storedSessions.sessions.firstIndex(where: { $0.id == targetSessionID }) else {
                // The session was deleted while the turn ran — nothing sane
                // to write back into; the appended entry was recreated by
                // appendEntry, so re-sync from there instead of dropping.
                return
            }
            storedSessions.sessions[index].entries = newEntries
            storedSessions.sessions[index].summary = newSummary
            storedSessions.sessions[index].updatedAt = Date()
        }
    }

    /// Replaces the active session's entries and summary in one write — what
    /// trimming and compression do together after each answer.
    static func replaceActiveEntriesAndSummary(
        entries newEntries: [ConversationHistoryEntry],
        summary newSummary: String
    ) {
        mutate { storedSessions in
            let activeID = storedSessions.activeSessionID
                ?? storedSessions.sessions.max { $0.updatedAt < $1.updatedAt }?.id
            guard let activeID,
                  let index = storedSessions.sessions.firstIndex(where: { $0.id == activeID }) else { return }
            storedSessions.sessions[index].entries = newEntries
            storedSessions.sessions[index].summary = newSummary
            storedSessions.sessions[index].updatedAt = Date()
        }
    }

    /// Forgets every conversation, in memory and on disk — 清空对话记忆.
    /// Also removes the legacy flat file if a migration left it behind.
    static func clearAllSessions() {
        sessionsLock.lock()
        let freshSessions = StoredConversationSessions()
        cachedSessions = freshSessions
        sessionsLock.unlock()

        if let sessionsFileURL {
            try? FileManager.default.removeItem(at: sessionsFileURL)
        }
        if let historyFileURL = ConversationHistoryStore.historyFileURL {
            try? FileManager.default.removeItem(at: historyFileURL)
        }
        NotificationCenter.default.post(name: .clickySessionsDidChange, object: nil)
        NotificationCenter.default.post(name: .clickyConversationHistoryCleared, object: nil)
    }

    /// Deletes the file but keeps the in-memory sessions — what turning
    /// 「重启后保留对话」 off means: this run's conversation continues, the disk
    /// copy is gone.
    static func removeStoredFile() {
        if let sessionsFileURL {
            try? FileManager.default.removeItem(at: sessionsFileURL)
        }
        NotificationCenter.default.post(name: .clickySessionsDidChange, object: nil)
    }

    /// The one mutation funnel: applies `mutation` to the cache, writes to disk
    /// when persistence is on, posts the change notification. Every public
    /// mutator goes through here, which is what keeps the notification and the
    /// file from drifting apart.
    private static func mutate(_ mutation: (inout StoredConversationSessions) -> Void) {
        sessionsLock.lock()
        var storedSessions = cachedSessions ?? loadFromDiskWithMigration()
        mutation(&storedSessions)
        cachedSessions = storedSessions
        sessionsLock.unlock()

        if AppSettingsStore.snapshot().persistsConversationHistory {
            try? writeSessionsToDisk(storedSessions)
        }
        NotificationCenter.default.post(name: .clickySessionsDidChange, object: nil)
    }

    /// First load: read the sessions file; if there is none but the old flat
    /// history file exists, migrate — wrap it as 「默认会话」, write the new file,
    /// rename the old one to `.migrated` rather than deleting it. A migration is
    /// a data move, not a data delete: nothing the user said is ever discarded
    /// to make room for a new format.
    private static func loadFromDiskWithMigration() -> StoredConversationSessions {
        guard let sessionsFileURL else {
            return StoredConversationSessions()
        }

        if let storedData = try? Data(contentsOf: sessionsFileURL),
           let decodedSessions = try? JSONDecoder().decode(StoredConversationSessions.self, from: storedData) {
            return decodedSessions
        }

        // Sessions file absent or unreadable — check for a legacy flat history
        // worth wrapping before starting from empty.
        var migratedSessions = StoredConversationSessions()
        if let historyFileURL = ConversationHistoryStore.historyFileURL,
           let legacyData = try? Data(contentsOf: historyFileURL),
           let legacyHistory = try? JSONDecoder().decode(StoredConversationHistory.self, from: legacyData) {
            let now = Date()
            let migratedSession = ConversationSession(
                id: UUID(),
                title: migratedSessionTitle,
                createdAt: now,
                updatedAt: now,
                summary: legacyHistory.summary,
                entries: legacyHistory.entries
            )
            migratedSessions.sessions = [migratedSession]
            migratedSessions.activeSessionID = migratedSession.id
            print("💬 Clicky: migrated \(legacyHistory.entries.count) exchanges into the session 「\(migratedSessionTitle)」")

            try? writeSessionsToDisk(migratedSessions)
            let migratedFileURL = historyFileURL.deletingLastPathComponent()
                .appendingPathComponent("ConversationHistory.json.migrated")
            try? FileManager.default.removeItem(at: migratedFileURL)
            try? FileManager.default.moveItem(at: historyFileURL, to: migratedFileURL)
        }

        return migratedSessions
    }

    private static func writeSessionsToDisk(_ storedSessions: StoredConversationSessions) throws {
        guard let sessionsFileURL else {
            throw ModelConfigurationStoreError.applicationSupportDirectoryUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encodedSessions: Data
        do {
            encodedSessions = try encoder.encode(storedSessions)
        } catch {
            throw ModelConfigurationStoreError.couldNotEncodeConfiguration(underlyingError: error)
        }

        let containingDirectoryURL = sessionsFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: containingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encodedSessions.write(to: sessionsFileURL, options: .atomic)
        } catch {
            throw ModelConfigurationStoreError.couldNotWriteConfiguration(underlyingError: error)
        }

        // Same post-rename permission fix as `ConversationHistoryStore.save`:
        // `.atomic` lands as 0644 and this file holds the user's own words.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sessionsFileURL.path
            )
        } catch {
            throw ModelConfigurationStoreError.couldNotRestrictFilePermissions(underlyingError: error)
        }
    }
}
