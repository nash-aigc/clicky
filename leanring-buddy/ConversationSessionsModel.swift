//
//  ConversationSessionsModel.swift
//  leanring-buddy
//
//  SwiftUI-facing state for the notch sheet's sidebar: the session list, the
//  active session, and cross-session search.
//
//  Thin on purpose — every mutation goes straight to
//  `ConversationSessionsStore` (the source of truth) and this model reloads
//  from the `.clickySessionsDidChange` notification the store posts, which
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

    /// What the sidebar's search field holds. Empty means no filtering.
    @Published var searchQuery: String = ""

    private var sessionsChangeObserver: NSObjectProtocol?

    init() {
        reloadFromStore()
        sessionsChangeObserver = NotificationCenter.default.addObserver(
            forName: .clickySessionsDidChange,
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
    /// and assistant text, case-insensitively.
    var sidebarRows: [SessionRow] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return sessions.map { SessionRow(session: $0, searchPreview: nil) }
        }

        var rows: [SessionRow] = []
        for session in sessions {
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

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions (delegates to the store; the notification reloads)

    func selectSession(_ sessionID: UUID) {
        ConversationSessionsStore.setActiveSession(sessionID)
    }

    func createSession() {
        ConversationSessionsStore.createSession()
    }

    func deleteSession(_ sessionID: UUID) {
        ConversationSessionsStore.deleteSession(sessionID)
    }

    func renameSession(_ sessionID: UUID, to newTitle: String) {
        ConversationSessionsStore.renameSession(sessionID, to: newTitle)
    }
}
