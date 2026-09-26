//
//  AgentSession.swift
//  Wanna
//
//  The data model for the agent subsystem — one agent = one named claude CLI
//  subprocess working on one project folder.
//
//  Pure data, no I/O: persistence lives in `AgentSessionStore`, orchestration
//  in `AgentSessionManager`, the subprocess itself in `ClaudeAgentProcess`.
//  Everything here is `nonisolated` for the same reason the types in
//  `AppSettings.swift` are — the target builds with
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the process bridge's
//  background-queue callbacks must be able to carry these values without
//  hopping actors.
//

import Foundation

/// One agent in the sidebar's Agent section.
///
/// `id` is deliberately the same UUID passed to the claude CLI as
/// `--session-id`: the agent's thread history on the CLI side and its record
/// here are one and the same conversation, so `--resume <id>` picks up exactly
/// where an interrupted process left off.
nonisolated struct AgentSession: Identifiable, Codable, Equatable {
    let id: UUID

    /// What the sidebar shows. Defaults to the project folder's last path
    /// component; renameable like a conversation session.
    var name: String

    /// The folder the subprocess runs in (`cwd`) and is granted (`--add-dir`) —
    /// the custom-project-folder feature. The agent reads and edits files here.
    var projectFolderPath: String

    var status: AgentSessionStatus

    /// The transcript so far. Bounded: `AgentSessionStore` trims to the most
    /// recent `maximumPersistedTranscriptEntries` entries on every write, so a
    /// chatty agent cannot balloon `AgentSessions.json`.
    var transcript: [AgentTranscriptEntry]

    /// One line for the sidebar row — the last thing that happened. Either the
    /// tail of the latest assistant message, a tool activity line, or a
    /// failure's stderr tail.
    var lastPreview: String

    /// What the model is currently streaming. Deliberately NOT stored here:
    /// streaming deltas arrive dozens of times a second and this struct lives
    /// behind `AgentSessionStore`'s lock and disk writes — in-flight text is
    /// held by `AgentSessionManager` in a `@Published` dictionary instead, and
    /// only the turn's final text lands in `transcript`.

    /// Approximate USD cost of the latest completed turn, reported by the
    /// result event's `total_cost_usd`. Shown in the transcript footer.
    var lastTurnCostUSD: Double?

    /// Running total of every turn this agent has ever completed, across app
    /// restarts. The per-turn number answers "what did that last job cost";
    /// this one answers "what is this agent costing me so far".
    var accumulatedCostUSD: Double?

    var createdAt: Date
    var updatedAt: Date

    /// **这个 agent 用哪个模型**（用户 2026-09-26：「让用户……选择哪一个 AI」）。
    ///
    /// 值就是 claude CLI `--model` 认的那个写法（`fable` / `opus` / `sonnet`，
    /// 或者一个完整模型名）。nil = 不传这个参数 = CLI 自己的默认 —— 这也是绝大多数
    /// 已有记录的形态，所以它必须是 Optional 且 `decodeIfPresent`。
    var modelAlias: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case projectFolderPath
        case status
        case transcript
        case lastPreview
        case lastTurnCostUSD
        case accumulatedCostUSD
        case createdAt
        case updatedAt
        case modelAlias
    }

    init(id: UUID = UUID(), name: String, projectFolderPath: String) {
        self.id = id
        self.name = name
        self.projectFolderPath = projectFolderPath
        self.status = .idle
        self.transcript = []
        self.lastPreview = ""
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Hand-written decode so a file written before `lastTurnCostUSD` existed
    // still loads (开发经验/10-踩过的坑.md E1).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectFolderPath = try container.decode(String.self, forKey: .projectFolderPath)
        status = try container.decode(AgentSessionStatus.self, forKey: .status)
        transcript = try container.decode([AgentTranscriptEntry].self, forKey: .transcript)
        lastPreview = try container.decodeIfPresent(String.self, forKey: .lastPreview) ?? ""
        lastTurnCostUSD = try container.decodeIfPresent(Double.self, forKey: .lastTurnCostUSD)
        accumulatedCostUSD = try container.decodeIfPresent(Double.self, forKey: .accumulatedCostUSD)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        modelAlias = try container.decodeIfPresent(String.self, forKey: .modelAlias)
    }
}

/// The five states of the turn lifecycle.
nonisolated enum AgentSessionStatus: String, Codable, Sendable {
    /// Exists, never run, or its last turn finished.
    case idle
    /// A turn is in flight — the subprocess is generating or running tools.
    case running
    /// The last turn completed successfully.
    case completed
    /// The subprocess died on its own (crash, CLI error) rather than being
    /// stopped by the user.
    case failed
    /// The user stopped the current turn.
    case interrupted

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .completed: return "已完成"
        case .failed: return "出错"
        case .interrupted: return "已中断"
        }
    }
}

/// One line in an agent's transcript: what the user asked, what the agent
/// answered, or what tool it ran on the way.
nonisolated struct AgentTranscriptEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: AgentTranscriptEntryKind
    var text: String
    var createdAt: Date

    init(kind: AgentTranscriptEntryKind, text: String) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.createdAt = Date()
    }
}

nonisolated enum AgentTranscriptEntryKind: String, Codable, Sendable {
    /// The user's instruction for one turn.
    case userMessage
    /// The agent's final answer text for one turn (the result event's text).
    case assistantMessage
    /// A tool invocation observed mid-turn — 「⚙︎ Bash · git status」-shaped.
    /// These are the visible progress of a working agent.
    case toolActivity
}

/// How many transcript entries survive per agent in `AgentSessions.json`.
/// Older entries are dropped from the oldest end (nothing the user said is
/// preserved less faithfully than by keeping every one forever — but the claude
/// CLI itself retains the full thread under `--resume`, so trimming here costs
/// display history, not the agent's memory).
nonisolated let maximumPersistedTranscriptEntries = 60
