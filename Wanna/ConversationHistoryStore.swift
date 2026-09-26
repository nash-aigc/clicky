//
//  ConversationHistoryStore.swift
//  Wanna
//
//  Persists the conversation so 对话与记忆 → 「重启后保留对话」 can mean what it
//  says, and holds the running summary that 「历史自动压缩」 produces.
//
//  Written to `~/Library/Application Support/Wanna/ConversationHistory.json`
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
    /// view's 「N 条进度」 disclosure expands to. `nil` on turns that ran no
    /// actions.
    var progressSteps: [String]?

    /// How long the turn took, in whole seconds, and when it finished — the
    /// finished turn's footer line.
    var turnDurationSeconds: Int?
    var turnFinishedAt: Date?

    /// **回复的第一个字节到达的时刻** —— 用户在 2026-09-25 定的那条：
    /// 「只需要记录收到回复的那一秒，而不是完全回复完成的时间……这样卡片出现的
    /// 第一秒，下面的时间就确定了」。
    ///
    /// 它与 `turnFinishedAt` 是两个不同的时刻，用途也不同：`turnFinishedAt` 属于
    /// 「这一轮花了多久」这条统计，只有回合结束才知道；而这个在流式开始的第一秒
    /// 就有值，所以底部那一行**从卡片出现的第一秒就能画出来**，卡片底边不再等回合
    /// 结束才让位 —— 那一下正是用户报的「回复完成之后卡片会突然向上抖动／顶一下」。
    var replyReceivedAt: Date?

    /// True when the user stopped this turn mid-job. The conversation view
    /// renders an 「已被用户打断」 chip instead of a duration.
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
        case replyReceivedAt
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
    static let wannaConversationHistoryCleared = Notification.Name("wannaConversationHistoryCleared")
}

nonisolated enum ConversationHistoryStore {

    /// `~/Library/Application Support/Wanna/ConversationHistory.json`.
    ///
    /// Computed rather than stored so it follows the real home directory; the
    /// directory is created on the way in by `save`.
    static var historyFileURL: URL? {
        AppSupportDirectory.fileURL(named: "ConversationHistory.json")
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

        NotificationCenter.default.post(name: .wannaConversationHistoryCleared, object: nil)
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
            print("⚠️ Wanna: ConversationHistory.json could not be read — starting with an empty conversation.")
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

    /// When the user pinned this session to the top of the sidebar, or `nil`
    /// while it is not pinned. A date rather than a flag so the sidebar can
    /// order several pinned sessions by how recently each was pinned.
    var pinnedAt: Date?

    /// When the user deleted this session, or `nil` while it is still live.
    ///
    /// Deleting is a soft delete: the record stays in the file with this
    /// stamped, and the 归档 page is the only place that shows it. Two things
    /// follow from that, both deliberate — a turn that is in flight when the
    /// user deletes its session still lands in a real record instead of being
    /// dropped, and 彻底删除 (`purgeSession`) becomes the only path that
    /// actually shrinks the file.
    var archivedAt: Date?
}

/// Hand-written so a file written before `pinnedAt` / `archivedAt` existed
/// still decodes — the synthesized `Codable` throws on a missing key, which
/// would make every session in an existing file fail to load.
///
/// `CodingKeys` lists every stored property, because the still-synthesized
/// `encode(to:)` writes exactly the keys named here. A field missing from the
/// list is silently dropped on the next save, which only shows up after a
/// restart — so the list has to be re-checked whenever a property is added.
nonisolated extension ConversationSession {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case summary
        case entries
        case pinnedAt
        case archivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        summary = try container.decode(String.self, forKey: .summary)
        entries = try container.decode([ConversationHistoryEntry].self, forKey: .entries)
        // Both are optional and so `decodeIfPresent`-shaped: absent means "not
        // pinned" and "not archived", which is what every older file means.
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
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
    static let wannaSessionsDidChange = Notification.Name("wannaSessionsDidChange")
}

nonisolated enum ConversationSessionsStore {

    /// `~/Library/Application Support/Wanna/ConversationSessions.json`.
    static var sessionsFileURL: URL? {
        AppSupportDirectory.fileURL(named: "ConversationSessions.json")
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

    /// Sessions the user can still see, oldest created first — sidebar display
    /// order. Archived sessions are excluded; 归档 is the only view that shows
    /// them.
    static func allSessions() -> [ConversationSession] {
        snapshot().sessions.filter { $0.archivedAt == nil }
    }

    /// Every session in the file, archived ones included — what the 归档 page
    /// lists, and what 清空对话记忆 really deletes.
    static func allSessionsIncludingArchived() -> [ConversationSession] {
        snapshot().sessions
    }

    /// The session the pipeline is currently recording into. A live session
    /// always exists — one is made when there is none — so the pipeline never
    /// has to branch on "no active session".
    ///
    /// An archived session is never returned, in either the primary lookup or
    /// the fallback. Handing the pipeline a session the sidebar is not showing
    /// is a silent failure: the answer would be written into a conversation the
    /// user cannot see, with no row highlighted and no bubble appearing.
    static func activeSession() -> ConversationSession {
        let storedSessions = snapshot()
        if let activeSessionID = storedSessions.activeSessionID,
           let matchingSession = storedSessions.sessions.first(where: {
               $0.id == activeSessionID && $0.archivedAt == nil
           }) {
            return matchingSession
        }

        // Falls back to the most recently touched live session when the id is
        // absent or stale (a hand-edited file, an id whose session was
        // archived, or one that was just made). Deliberately never a freshly
        // invented session: `mutate` posts a notification on every write, so a
        // random id here would be a different one on every reload and no
        // sidebar row could ever match it.
        if let index = indexOfMostRecentlyUpdatedLiveSession(in: storedSessions) {
            return storedSessions.sessions[index]
        }

        // Nothing live at all — every conversation archived, or the file empty.
        // Make the pipeline somewhere to write and point the file at it, so
        // what `activeSession()` reports and what the sidebar lists agree.
        return createSession()
    }

    /// Points the pipeline at another session. No-ops when the id is unknown or
    /// archived, so a stale sidebar cannot blank the live conversation.
    static func setActiveSession(_ sessionID: UUID) {
        mutate { storedSessions in
            guard storedSessions.sessions.contains(where: {
                $0.id == sessionID && $0.archivedAt == nil
            }) else { return }
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

    /// Archives a session — what the sidebar's 删除 does. The record stays in
    /// the file with `archivedAt` stamped, so 归档 can offer it back; only
    /// `purgeSession` really removes a conversation.
    ///
    /// Archiving the active session moves activity to the most recently touched
    /// live survivor, and makes a new one when there is none: leaving
    /// `activeSessionID` pointing at an archived session (or nil) would have the
    /// pipeline write into a record no sidebar row is showing.
    static func deleteSession(_ sessionID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            guard storedSessions.sessions[index].archivedAt == nil else { return }
            storedSessions.sessions[index].archivedAt = Date()

            if storedSessions.activeSessionID == sessionID {
                let takeoverIndex = liveSessionIndexToTakeOver(in: &storedSessions)
                storedSessions.activeSessionID = storedSessions.sessions[takeoverIndex].id
            }
        }
    }

    /// Puts an archived session back in the sidebar, pinned state and all.
    static func restoreSession(_ sessionID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            storedSessions.sessions[index].archivedAt = nil
        }
    }

    /// Removes a session for good — 归档's 彻底删除, the only path that shrinks
    /// the file.
    static func purgeSession(_ sessionID: UUID) {
        mutate { storedSessions in
            let wasActive = storedSessions.activeSessionID == sessionID
            storedSessions.sessions.removeAll { $0.id == sessionID }
            if wasActive {
                let takeoverIndex = liveSessionIndexToTakeOver(in: &storedSessions)
                storedSessions.activeSessionID = storedSessions.sessions[takeoverIndex].id
            }
        }
    }

    /// Pins a session to the top of the sidebar, or releases it.
    static func setPinned(_ isPinned: Bool, forSessionID sessionID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            storedSessions.sessions[index].pinnedAt = isPinned ? Date() : nil
        }
    }

    /// Index of the live session whose turn happened most recently, or `nil`
    /// when every session in the file is archived.
    private static func indexOfMostRecentlyUpdatedLiveSession(
        in storedSessions: StoredConversationSessions
    ) -> Int? {
        storedSessions.sessions.indices
            .filter { storedSessions.sessions[$0].archivedAt == nil }
            .max { storedSessions.sessions[$0].updatedAt < storedSessions.sessions[$1].updatedAt }
    }

    /// Where the pipeline's activity goes when the session it was pointed at
    /// stops being live — the most recently touched live session, or a brand-new
    /// empty one appended when there is none. Never `nil`: the caller is about to
    /// point `activeSessionID` at the result, and the reasons it must not be nil
    /// are in `activeSession()`'s note about inventing ids.
    ///
    /// Callers make their session non-live *first* (stamp `archivedAt`, or
    /// remove it), so the filter below already excludes it.
    private static func liveSessionIndexToTakeOver(
        in storedSessions: inout StoredConversationSessions
    ) -> Int {
        indexOfMostRecentlyUpdatedLiveSession(in: storedSessions)
            ?? appendEmptySession(to: &storedSessions)
    }

    /// Appends an empty untitled session and returns its index.
    private static func appendEmptySession(to storedSessions: inout StoredConversationSessions) -> Int {
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
        return storedSessions.sessions.count - 1
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
    /// anything in it.
    ///
    /// A session archived mid-response is not lost: the record is still there
    /// (deleting is a soft delete), so the turn lands in the conversation the
    /// user just deleted, and 恢复 in 归档 brings it back. Only 彻底删除
    /// removes a conversation, and then the turn goes with it — which is what
    /// asking for it to be gone means.
    ///
    /// The explicit-session form is what the response pipeline uses: a turn
    /// belongs to the session that was active when it started, so a session
    /// switch made while the answer is still streaming must not land the
    /// finished turn in the conversation the user just left.
    static func appendEntry(_ entry: ConversationHistoryEntry, targetSessionID: UUID? = nil) {
        mutate { storedSessions in
            let targetIndex: Int
            if let targetSessionID,
               let index = storedSessions.sessions.firstIndex(where: { $0.id == targetSessionID }) {
                targetIndex = index
            } else if let activeSessionID = storedSessions.activeSessionID,
                      let index = storedSessions.sessions.firstIndex(where: {
                          $0.id == activeSessionID && $0.archivedAt == nil
                      }) {
                targetIndex = index
            } else if let mostRecentlyUpdatedLiveIndex = indexOfMostRecentlyUpdatedLiveSession(in: storedSessions) {
                targetIndex = mostRecentlyUpdatedLiveIndex
            } else {
                targetIndex = appendEmptySession(to: &storedSessions)
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
                // The session was purged (彻底删除) while the turn ran, so there
                // is nothing left to write back into — the appended entry went
                // with it, which is what deleting a conversation for good means.
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
            // Same two steps as `activeSession()`: the stored id when it still
            // names a live session, else the most recently touched live one.
            // An archived id here would rewrite a conversation the user cannot
            // see, so it is treated as absent.
            var activeID = storedSessions.activeSessionID
            if let candidateID = activeID,
               !storedSessions.sessions.contains(where: { $0.id == candidateID && $0.archivedAt == nil }) {
                activeID = nil
            }
            if activeID == nil,
               let mostRecentlyUpdatedLiveIndex = indexOfMostRecentlyUpdatedLiveSession(in: storedSessions) {
                activeID = storedSessions.sessions[mostRecentlyUpdatedLiveIndex].id
            }

            guard let activeID,
                  let index = storedSessions.sessions.firstIndex(where: { $0.id == activeID }) else { return }
            storedSessions.sessions[index].entries = newEntries
            storedSessions.sessions[index].summary = newSummary
            storedSessions.sessions[index].updatedAt = Date()
        }
    }

    /// Forgets every conversation, archived ones included, in memory and on
    /// disk — 清空对话记忆. This is the one path that skips 归档: the setting says
    /// it clears the conversation memory, and leaving archives behind would mean
    /// the user's own words were still on disk after they asked for them gone.
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
        NotificationCenter.default.post(name: .wannaSessionsDidChange, object: nil)
        NotificationCenter.default.post(name: .wannaConversationHistoryCleared, object: nil)
    }

    /// Deletes the file but keeps the in-memory sessions — what turning
    /// 「重启后保留对话」 off means: this run's conversation continues, the disk
    /// copy is gone.
    static func removeStoredFile() {
        if let sessionsFileURL {
            try? FileManager.default.removeItem(at: sessionsFileURL)
        }
        NotificationCenter.default.post(name: .wannaSessionsDidChange, object: nil)
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
        NotificationCenter.default.post(name: .wannaSessionsDidChange, object: nil)
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
            print("💬 Wanna: migrated \(legacyHistory.entries.count) exchanges into the session 「\(migratedSessionTitle)」")

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
