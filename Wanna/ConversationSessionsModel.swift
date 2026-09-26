//
//  ConversationSessionsModel.swift
//  Wanna
//
//  SwiftUI-facing state for the notch sheet's sidebar: the session list, the
//  active session, and cross-session search.
//
//  Thin on purpose — every mutation goes straight to
//  `ConversationSessionsStore` (the source of truth) and this model reloads
//  from the `.wannaSessionsDidChange` notification the store posts, which
//  means the sidebar also follows switches made anywhere else in the app
//  (the pipeline appending a turn, another window clearing memory) with no
//  extra wiring.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ConversationSessionsModel: ObservableObject {

    @Published private(set) var sessions: [ConversationSession] = []
    @Published private(set) var activeSessionID: UUID?

    /// Deleted conversations, most recently archived first — the 归档 page's
    /// list. Held here rather than read on demand so the page follows a
    /// restore or a 彻底删除 made anywhere else without any extra wiring.
    @Published private(set) var archivedSessions: [ConversationSession] = []

    /// What the sidebar's search field holds. Empty means no filtering.
    @Published var searchQuery: String = ""

    private var sessionsChangeObserver: NSObjectProtocol?

    init() {
        reloadFromStore()
        sessionsChangeObserver = NotificationCenter.default.addObserver(
            forName: .wannaSessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadFromStore()
            }
        }
    }

    deinit {
        if let sessionsChangeObserver {
            NotificationCenter.default.removeObserver(sessionsChangeObserver)
        }
    }

    private func reloadFromStore() {
        sessions = ConversationSessionsStore.allSessions()
        activeSessionID = ConversationSessionsStore.activeSession().id

        // Newest deletion first: the conversation the user just got rid of is
        // the one they are most likely to want back.
        let archived = ConversationSessionsStore.allSessionsIncludingArchived()
            .filter { $0.archivedAt != nil }
        archivedSessions = archived.sorted { first, second in
            (first.archivedAt ?? .distantPast) > (second.archivedAt ?? .distantPast)
        }
    }

    // MARK: - Derived state

    /// The session currently being talked into, if any.
    var activeSession: ConversationSession? {
        sessions.first { $0.id == activeSessionID }
    }

    /// One sidebar row: the session, plus — when searching — a snippet of the
    /// entry text that matched, so the user can tell why the session hit.
    struct SessionRow {
        let session: ConversationSession
        let searchPreview: String?
    }

    /// The rows the sidebar shows: every session, or the search hits with
    /// their previews. Search covers session titles and every entry's user
    /// and assistant text, case-insensitively. The pinned-first order holds
    /// while searching too, so a pinned conversation is still at the top of the
    /// hits.
    var sidebarRows: [SessionRow] {
        let orderedSessions = orderedForDisplay(sessions)
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return orderedSessions.map { SessionRow(session: $0, searchPreview: nil) }
        }

        var rows: [SessionRow] = []
        for session in orderedSessions {
            if session.title.localizedCaseInsensitiveContains(trimmedQuery) {
                rows.append(SessionRow(session: session, searchPreview: nil))
                continue
            }

            // First entry whose text contains the query — its user line makes
            // the preview, that is what the user recognises the turn by.
            let matchingEntry = session.entries.first { entry in
                entry.userTranscript.localizedCaseInsensitiveContains(trimmedQuery)
                    || entry.assistantResponse.localizedCaseInsensitiveContains(trimmedQuery)
            }
            if let matchingEntry {
                let preview = "「\(matchingEntry.userTranscript)」"
                rows.append(SessionRow(session: session, searchPreview: preview))
            }
        }
        return rows
    }

    /// Pinned sessions first — earliest pin at the very top, so pinning
    /// another conversation never shuffles the ones already there — then
    /// everything else in the order the store gave them, which is the order
    /// they were created in. `filter` preserves that order, so only the pinned
    /// group is rearranged.
    private func orderedForDisplay(_ sessions: [ConversationSession]) -> [ConversationSession] {
        let pinnedSessions = sessions
            .filter { $0.pinnedAt != nil }
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
        let unpinnedSessions = sessions.filter { $0.pinnedAt == nil }
        return pinnedSessions + unpinnedSessions
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions (delegates to the store; the notification reloads)

    func selectSession(_ sessionID: UUID) {
        ConversationSessionsStore.setActiveSession(sessionID)
    }

    func createSession() {
        // The store returns the new session; this model only relays the
        // command — the caller that needs the id (the sidebar's 「＋」 does not)
        // can read `activeSessionID` after the reload the store posts.
        _ = ConversationSessionsStore.createSession()
    }

    /// Moves a session to 归档 — the sidebar's delete. Soft: the record stays on
    /// disk until `purgeSession`.
    func deleteSession(_ sessionID: UUID) {
        ConversationSessionsStore.deleteSession(sessionID)
    }

    func setPinned(_ isPinned: Bool, forSessionID sessionID: UUID) {
        ConversationSessionsStore.setPinned(isPinned, forSessionID: sessionID)
    }

    /// Brings an archived conversation back into the sidebar.
    func restoreSession(_ sessionID: UUID) {
        ConversationSessionsStore.restoreSession(sessionID)
    }

    /// Removes an archived conversation for good — the 归档 page's 彻底删除.
    func purgeSession(_ sessionID: UUID) {
        ConversationSessionsStore.purgeSession(sessionID)
    }

    func renameSession(_ sessionID: UUID, to newTitle: String) {
        ConversationSessionsStore.renameSession(sessionID, to: newTitle)
    }
}
