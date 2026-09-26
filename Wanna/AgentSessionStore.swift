//
//  AgentSessionStore.swift
//  Wanna
//
//  Persists the agent roster to
//  `~/Library/Application Support/Wanna/AgentSessions.json` (0600).
//
//  The shape is a deliberate clone of `ConversationSessionsStore` (same file):
//  `nonisolated` + one `NSLock` over the cache, atomic write followed by a
//  0600 `setAttributes` (`.atomic` lands as 0644 after umask), one private
//  `mutate` funnel so the change notification and the file can never drift
//  apart, and a change notification (`wannaAgentSessionsDidChange`) so live
//  UI reloads without a restart.
//
//  Agent transcripts hold the user's instructions and the agent's answers, so
//  this file gets the same 0600 treatment and the same "unreadable file means
//  start empty, never crash" rule as the conversation stores.
//

import Foundation

/// What is stored on disk: the agent list. Unlike conversation sessions there
/// is no "active" pointer in the file — which agent the sheet is showing is UI
/// state, held by `AgentSessionManager`, not a fact about the data.
nonisolated struct StoredAgentSessions: Codable, Equatable {
    var agents: [AgentSession] = []
}

/// Posted after every agent mutation — create, delete, rename, status change,
/// transcript append — so the notch sheet's agent list and transcript reload.
nonisolated extension Notification.Name {
    static let wannaAgentSessionsDidChange = Notification.Name("wannaAgentSessionsDidChange")
}

nonisolated enum AgentSessionStore {

    /// `~/Library/Application Support/Wanna/AgentSessions.json`.
    static var agentsFileURL: URL? {
        AppSupportDirectory.fileURL(named: "AgentSessions.json")
    }

    /// Guards `cachedSessions` only. File reads and writes happen outside it.
    private static let sessionsLock = NSLock()
    private static var cachedSessions: StoredAgentSessions?

    /// Decoder paired with the encoder's `.iso8601` date strategy — the two
    /// halves of the round trip must agree or every reload silently fails.
    private static let dateIso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The whole agent document, read from disk on first access.
    ///
    /// Same `nonisolated` + `NSLock` shape as `ConversationSessionsStore`, for
    /// the same `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` reason: a value
    /// return means callers get a copy and there is no shared mutable state.
    static func snapshot() -> StoredAgentSessions {
        sessionsLock.lock()
        if let cachedSessions {
            sessionsLock.unlock()
            return cachedSessions
        }
        sessionsLock.unlock()

        let loadedSessions = loadFromDisk()
        sessionsLock.lock()
        cachedSessions = loadedSessions
        sessionsLock.unlock()
        return loadedSessions
    }

    /// All agents, oldest created first — sidebar display order.
    static func allAgents() -> [AgentSession] {
        snapshot().agents
    }

    /// Creates an agent and returns it. The manager owns spawn timing; the
    /// store only records that the agent exists.
    static func createAgent(name: String, projectFolderPath: String) -> AgentSession {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAgent = AgentSession(
            name: trimmedName.isEmpty ? URL(fileURLWithPath: projectFolderPath).lastPathComponent : trimmedName,
            projectFolderPath: projectFolderPath
        )
        mutate { storedSessions in
            storedSessions.agents.append(newAgent)
        }
        return newAgent
    }

    /// Deletes an agent. Its subprocess is the manager's responsibility — this
    /// only removes the record.
    static func deleteAgent(_ agentID: UUID) {
        mutate { storedSessions in
            storedSessions.agents.removeAll { $0.id == agentID }
        }
    }

    static func renameAgent(_ agentID: UUID, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == agentID }) else { return }
            guard !trimmedName.isEmpty else { return }
            storedSessions.agents[index].name = trimmedName
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    static func updateStatus(_ status: AgentSessionStatus, forAgentID agentID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == agentID }) else { return }
            storedSessions.agents[index].status = status
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    /// Appends one transcript entry and refreshes `lastPreview` from it — the
    /// two travel together because the sidebar row always shows the newest
    /// thing that happened. An agent deleted mid-turn is silently skipped:
    /// there is nothing left to write into.
    static func appendTranscriptEntry(_ entry: AgentTranscriptEntry, targetAgentID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == targetAgentID }) else { return }
            storedSessions.agents[index].transcript.append(entry)
            if storedSessions.agents[index].transcript.count > maximumPersistedTranscriptEntries {
                storedSessions.agents[index].transcript.removeFirst(
                    storedSessions.agents[index].transcript.count - maximumPersistedTranscriptEntries
                )
            }
            storedSessions.agents[index].lastPreview = previewText(for: entry)
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    /// Overwrites the sidebar preview with failure detail — the stderr tail of
    /// a dead subprocess does not arrive as a transcript entry, but it is
    /// exactly what the user needs to see on the row.
    static func updatePreview(_ preview: String, forAgentID agentID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == agentID }) else { return }
            storedSessions.agents[index].lastPreview = preview
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    static func updateLastTurnCost(_ costUSD: Double, forAgentID agentID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == agentID }) else { return }
            storedSessions.agents[index].lastTurnCostUSD = costUSD
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    /// Records one finished turn's cost and adds it to the agent's running
    /// total — the per-turn number answers "what did that job cost", the
    /// accumulated one answers "what is this agent costing me so far". An agent
    /// deleted mid-turn is silently skipped, like `appendTranscriptEntry`.
    static func addTurnCost(_ costUSD: Double, forAgentID agentID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == agentID }) else { return }
            storedSessions.agents[index].lastTurnCostUSD = costUSD
            storedSessions.agents[index].accumulatedCostUSD =
                (storedSessions.agents[index].accumulatedCostUSD ?? 0) + costUSD
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    /// Replaces an agent's whole transcript — reserved for future transcript
    /// management; today only the trim inside `appendTranscriptEntry` shrinks
    /// one.
    static func replaceTranscript(_ entries: [AgentTranscriptEntry], forAgentID agentID: UUID) {
        mutate { storedSessions in
            guard let index = storedSessions.agents.firstIndex(where: { $0.id == agentID }) else { return }
            storedSessions.agents[index].transcript = entries
            storedSessions.agents[index].updatedAt = Date()
        }
    }

    /// On launch, an agent persisted as `running` is not running — its process
    /// died with the previous app instance. Demote it to `interrupted` so the
    /// sidebar never shows a zombie state, and so the first turn resumes the
    /// thread via `--resume` (the process-bridge manager's job).
    static func demoteInterruptedAgentsOnLaunch() {
        let needsDemotion = snapshot().agents.contains { $0.status == .running }
        guard needsDemotion else { return }
        mutate { storedSessions in
            for index in storedSessions.agents.indices
            where storedSessions.agents[index].status == .running {
                storedSessions.agents[index].status = .interrupted
                storedSessions.agents[index].lastPreview = "上次会话结束时仍在运行，已被中断"
            }
        }
    }

    private static func previewText(for entry: AgentTranscriptEntry) -> String {
        let firstLine = entry.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? entry.text
        return String(firstLine.prefix(80))
    }

    /// The one mutation funnel: applies `mutation` to the cache, writes to
    /// disk, posts the change notification. Every public mutator goes through
    /// here — the same funnel discipline `ConversationSessionsStore.mutate`
    /// keeps, for the same reason.
    private static func mutate(_ mutation: (inout StoredAgentSessions) -> Void) {        sessionsLock.lock()
        var storedSessions = cachedSessions ?? loadFromDisk()
        mutation(&storedSessions)
        cachedSessions = storedSessions
        sessionsLock.unlock()

        try? writeSessionsToDisk(storedSessions)
        NotificationCenter.default.post(name: .wannaAgentSessionsDidChange, object: nil)
    }

    private static func loadFromDisk() -> StoredAgentSessions {
        guard let agentsFileURL,
              let storedData = try? Data(contentsOf: agentsFileURL) else {
            return StoredAgentSessions()
        }

        guard let decodedSessions = try? dateIso8601.decode(StoredAgentSessions.self, from: storedData) else {
            print("⚠️ Wanna: AgentSessions.json could not be read — starting with an empty agent roster.")
            return StoredAgentSessions()
        }

        return decodedSessions
    }

    private static func writeSessionsToDisk(_ storedSessions: StoredAgentSessions) throws {
        guard let agentsFileURL else {
            throw ModelConfigurationStoreError.applicationSupportDirectoryUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let encodedSessions: Data
        do {
            encodedSessions = try encoder.encode(storedSessions)
        } catch {
            throw ModelConfigurationStoreError.couldNotEncodeConfiguration(underlyingError: error)
        }

        let containingDirectoryURL = agentsFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: containingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encodedSessions.write(to: agentsFileURL, options: .atomic)
        } catch {
            throw ModelConfigurationStoreError.couldNotWriteConfiguration(underlyingError: error)
        }

        // Same post-rename permission fix as the conversation stores: `.atomic`
        // lands as 0644 and this file holds the user's own words to their agents.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: agentsFileURL.path
            )
        } catch {
            throw ModelConfigurationStoreError.couldNotRestrictFilePermissions(underlyingError: error)
        }
    }
}
