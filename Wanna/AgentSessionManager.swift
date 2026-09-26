//
//  AgentSessionManager.swift
//  Wanna
//
//  Orchestration for the agent subsystem: the roster of agents, which one the
//  sheet is showing, and one `ClaudeAgentProcess` per running agent.
//
//  Deliberately NOT part of the voice pipeline. `CompanionManager`'s
//  `currentResponseTask` / `voiceState` are a single mutually-exclusive slot
//  that drive the cursor, TTS and the notch's activity band — an agent is a
//  long-running background job that must survive a new voice question, an
//  interrupt, and a session switch. This manager owns its own tasks and state,
//  the same way `historyCompressionTask` does.
//
//  Ownership: held by `CompanionManager` (lazy), so it lives for the app's
//  lifetime and its subprocesses are reachable from the will-terminate path.
//

import Combine
import Foundation
import SwiftUI

/// Which half of the notch sheet's sidebar list is showing — the conversation
/// sessions, the agent roster, or the voice-chat role presets. UI
/// state, held here because both the sidebar (which renders it) and the sheet
/// root (which switches the content column) read the same manager.
nonisolated enum SidebarSection: String, CaseIterable, Sendable {
    case conversations
    case agents
    case voiceChat

    var displayName: String {
        switch self {
        // 用户 2026-09-25：「把最左侧的对话按钮写成 ask」→ 随后更正为 **Ask**
        // （大写首字母）；同日晚些时候再改为 **Screen**：
        // 「把左侧边栏的 Ask 改成 Screen，因为它所有的对话都是参考屏幕的」。
        //
        // 这一列回答的确实是**屏幕上的东西** —— 每个回合都把截图连同问题一起送给
        // 视觉模型，回答里还能用 `[POINT:x,y:…]` 指到屏幕上的具体位置。所以
        // 「Screen」比「Ask」更贴近它实际在做的事；只改**显示名**，
        // `case conversations` 与磁盘上的存储值一律不动（那会影响已有会话与
        // 各处的持久化判断）。
        case .conversations: return "Screen"
        case .agents: return "Agent"
        case .voiceChat: return "Call"
        }
    }
}

@MainActor
final class AgentSessionManager: ObservableObject {

    // MARK: - Published state

    /// The agent roster, reloaded from `AgentSessionStore` whenever it changes.
    @Published private(set) var sessions: [AgentSession] = []

    /// Which agent the sheet's content column is showing. UI state — the
    /// store deliberately does not persist an "active agent".
    @Published var selectedAgentID: UUID?

    /// Which half of the sidebar's list is showing.
    @Published var selectedSidebarSection: SidebarSection = .conversations

    /// In-flight streamed answer text per agent, keyed by agent id. Held here
    /// rather than on `AgentSession` because deltas arrive dozens of times a
    /// second and the session structs live behind the store's lock and disk
    /// writes — only the finished turn goes through the store.
    @Published private(set) var streamingTextByAgentID: [UUID: String] = [:]

    /// The last failure worth showing in the agent view — an unresolvable
    /// executable, a dead subprocess, a refused turn. Cleared by the next
    /// successful send; shown as a dim line like `lastErrorMessage` is.
    @Published private(set) var lastAgentErrorMessage: String?

    // MARK: - Private state

    /// One live process bridge per agent that has ever run this app session.
    /// Kept after exit so `hasLaunchedOnce` (the resume-vs-new decision)
    /// survives the process itself.
    private var processesByAgentID: [UUID: ClaudeAgentProcess] = [:]

    private var settingsChangeObserver: NSObjectProtocol?
    private var sessionsChangeObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?

    init() {
        // An agent persisted as `running` was killed with the last app
        // instance — the store demotes those so the roster never shows a
        // zombie.
        AgentSessionStore.demoteInterruptedAgentsOnLaunch()
        reloadSessionsFromStore()

        sessionsChangeObserver = NotificationCenter.default.addObserver(
            forName: .wannaAgentSessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSessionsFromStore()
            }
        }

        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminateAllProcessesForAppExit()
            }
        }
    }

    deinit {
        if let sessionsChangeObserver {
            NotificationCenter.default.removeObserver(sessionsChangeObserver)
        }
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
        }
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
    }

    // MARK: - Derived state

    var selectedAgent: AgentSession? {
        sessions.first(where: { $0.id == selectedAgentID })
    }

    private var runningAgentCount: Int {
        sessions.filter { $0.status == .running }.count
    }

    private var currentSettings: AppSettings {
        AppSettingsStore.snapshot()
    }

    // MARK: - Roster operations

    private func reloadSessionsFromStore() {
        sessions = AgentSessionStore.allAgents()
        if selectedAgentID == nil, let newestAgent = sessions.last {
            selectedAgentID = newestAgent.id
        }
        if let selectedAgentID, !sessions.contains(where: { $0.id == selectedAgentID }) {
            // The selected agent was deleted (possibly by a future multi-window
            // change) — fall to the newest survivor rather than showing nothing.
            self.selectedAgentID = sessions.last?.id
        }
    }

    @discardableResult
    func createAgent(name: String, projectFolderPath: String) -> AgentSession? {
        guard currentSettings.allowsAgentSubsystem else {
            lastAgentErrorMessage = "Agent 功能已在设置 → Agent 里关闭。"
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectFolderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lastAgentErrorMessage = "所选路径不是文件夹：\(projectFolderPath)"
            return nil
        }

        let newAgent = AgentSessionStore.createAgent(name: name, projectFolderPath: projectFolderPath)
        reloadSessionsFromStore()
        selectedAgentID = newAgent.id
        return newAgent
    }

    /// Opens a folder as a **new** agent's working directory and selects it —
    /// the Agent page's 「打开」 button.
    ///
    /// It creates an agent rather than re-pointing the current one, and that is
    /// a constraint of the CLI rather than a preference. `claude` files a
    /// thread under `~/.claude/projects/<slug of the cwd>/<session-id>.jsonl`
    /// (`ClaudeAgentProcess.sessionExistsOnDisk` mirrors that rule), so a cwd
    /// change moves the thread to a directory the CLI has never heard of: the
    /// process would come back up with an empty memory while Wanna's own
    /// transcript still showed the old turns — the panel claiming a history
    /// the model cannot see, and no error anywhere. A new agent per folder is
    /// the only shape in which the folder shown and the memory held agree.
    ///
    /// The name is the folder's own basename, disambiguated with a numeric
    /// suffix when an agent already has it: `[AGENT_SEND:]` resolves by name
    /// and *refuses* an ambiguous one («同时匹配到 N 个»), so letting a second
    /// WannaAgents exist would quietly break voice dispatch to both.
    @discardableResult
    func openFolderAsNewAgent(folderPath: String) -> AgentSession? {
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent

        var candidateName = folderName.isEmpty ? "未命名项目" : folderName
        var disambiguationSuffix = 2
        while sessions.contains(where: { $0.name.caseInsensitiveCompare(candidateName) == .orderedSame }) {
            candidateName = "\(folderName)-\(disambiguationSuffix)"
            disambiguationSuffix += 1
        }

        return createAgent(name: candidateName, projectFolderPath: folderPath)
    }

    func deleteAgent(_ agentID: UUID) {
        processesByAgentID[agentID]?.terminate(force: true)
        processesByAgentID[agentID] = nil
        streamingTextByAgentID[agentID] = nil
        AgentSessionStore.deleteAgent(agentID)
        // reloadSessionsFromStore fixes up the selection after the notification.
    }

    func renameAgent(_ agentID: UUID, to newName: String) {
        AgentSessionStore.renameAgent(agentID, to: newName)
    }

    func selectAgent(_ agentID: UUID) {
        selectedAgentID = agentID
    }

    /// Clears the error line — the dim red text's tap-to-dismiss.
    func dismissError() {
        lastAgentErrorMessage = nil
    }

    // MARK: - Voice-companion dispatch ([AGENT_SPAWN:] / [AGENT_SEND:])

    /// Injected by `CompanionManager` when it creates this manager — closures
    /// rather than a reference, so the agent subsystem stays one-way decoupled
    /// from the voice pipeline: it can *ask* whether the voice is idle and
    /// *request* a spoken announcement, without ever touching `voiceState`.
    var voiceIdleProvider: (() -> Bool)?
    var speakAnnouncement: ((String) async -> Void)?

    /// True while one completion announcement is being spoken. Two agents
    /// finishing in the same instant must not both call `speakText` — the
    /// second call's `stopPlayback()` would cut the first one off.
    private var isAnnouncingCompletion = false

    /// The `[AGENT_SPAWN:name:task]` path — the voice companion dispatching a
    /// background job. The agent's project folder is the default-folder setting
    /// when the user has one (that folder *is* their declared agent workspace);
    /// without one, a visible folder under `WannaAgents` is created,
    /// because an agent whose files nobody can find is worse than no agent.
    /// Returns the outcome line for the next turn's `<screen_contents>` data
    /// block either way — the model must see what happened to its request.
    func spawnAndSendFirstTurn(name: String, firstTurnText: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Agent dispatch failed: Agent 名字为空，没有创建。"
        }

        // An agent with this exact name already exists: spawning a duplicate
        // would fork its thread history. Hand the task to the existing one.
        if let existingAgent = sessions.first(where: {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            return deliverDispatchTurn(firstTurnText, to: existingAgent, verb: "已有同名 Agent「\(existingAgent.name)」，任务直接交给了它")
        }

        let settings = currentSettings
        guard runningAgentCount < settings.maximumConcurrentAgents else {
            return "Agent dispatch failed: 已有 \(runningAgentCount) 个 Agent 在同时运行（上限 \(settings.maximumConcurrentAgents)），「\(trimmedName)」没有创建。"
        }

        let projectFolderPath: String
        if let defaultProjectFolder = settings.agentDefaultProjectFolder {
            projectFolderPath = defaultProjectFolder
        } else {
            let agentsRoot = WorkspaceDirectory.agentsURL.path
            var candidateFolderPath = agentsRoot + "/" + trimmedName
            var disambiguationSuffix = 2
            while FileManager.default.fileExists(atPath: candidateFolderPath) {
                candidateFolderPath = "\(agentsRoot)/\(trimmedName)-\(disambiguationSuffix)"
                disambiguationSuffix += 1
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: candidateFolderPath,
                    withIntermediateDirectories: true
                )
            } catch {
                return "Agent dispatch failed: 无法创建项目文件夹 \(candidateFolderPath)（\(error.localizedDescription)）。"
            }
            projectFolderPath = candidateFolderPath
        }

        guard let newAgent = createAgent(name: trimmedName, projectFolderPath: projectFolderPath) else {
            return "Agent dispatch failed: \(lastAgentErrorMessage ?? "创建失败")。"
        }
        return deliverDispatchTurn(firstTurnText, to: newAgent, verb: "已派给新 Agent")
    }

    /// The `[AGENT_SEND:name:text]` path — a follow-up to an agent that already
    /// exists. The name is matched case-insensitively and exactly first, then
    /// by containment; ambiguity and absence both come back as outcome lines
    /// listing the roster, so the model can correct itself on the next step.
    func dispatchFollowUp(named agentName: String, turnText: String) -> String {
        let trimmedName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)

        let exactMatches = sessions.filter {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        let candidateAgents = exactMatches.isEmpty
            ? sessions.filter { $0.name.localizedCaseInsensitiveContains(trimmedName) }
            : exactMatches

        if candidateAgents.isEmpty {
            let rosterNames = sessions.map { "「\($0.name)」" }.joined(separator: "、")
            return "Agent dispatch failed: 没有叫「\(trimmedName)」的 Agent。现有：\(rosterNames.isEmpty ? "（一个都没有）" : rosterNames)。"
        }
        guard candidateAgents.count == 1 else {
            let candidateNames = candidateAgents.map { "「\($0.name)」" }.joined(separator: "、")
            return "Agent dispatch failed: 「\(trimmedName)」同时匹配到 \(candidateAgents.count) 个 Agent（\(candidateNames)），请指明用哪一个。"
        }

        return deliverDispatchTurn(turnText, to: candidateAgents[0], verb: "已转给")
    }

    /// The common tail of both dispatch paths: capacity-check, send, and
    /// phrase the outcome. The capacity guard is repeated here (rather than
    /// trusting `sendTurn`'s own) because the *outcome line* must tell the
    /// truth — `sendTurn` reports refusals on the roster's error line, which
    /// the model never reads.
    private func deliverDispatchTurn(_ turnText: String, to agent: AgentSession, verb: String) -> String {
        guard agent.status != .running else {
            return "Agent dispatch failed: 「\(agent.name)」正在执行上一条任务，这条指令没有送出。"
        }
        guard runningAgentCount < currentSettings.maximumConcurrentAgents else {
            let cap = currentSettings.maximumConcurrentAgents
            return "Agent dispatch failed: 已有 \(runningAgentCount) 个 Agent 在同时运行（上限 \(cap)），指令没有送出。"
        }
        sendTurn(turnText, to: agent.id)
        return "\(verb)「\(agent.name)」，任务：\(String(turnText.prefix(80)))"
    }

    // MARK: - Turns

    /// Sends one user instruction to an agent — the whole turn lifecycle in
    /// one call: gate checks, spawn-or-reuse the subprocess, write the turn to
    /// stdin, record it.
    func sendTurn(_ turnText: String, to agentID: UUID) {
        let trimmedText = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        guard currentSettings.allowsAgentSubsystem else {
            lastAgentErrorMessage = "Agent 功能已在设置 → Agent 里关闭，这条指令没有执行。"
            return
        }

        guard let agent = sessions.first(where: { $0.id == agentID }) else { return }

        guard agent.status != .running else {
            lastAgentErrorMessage = "「\(agent.name)」正在执行上一条任务，先点中断或等它完成。"
            return
        }

        let maximumConcurrentAgents = currentSettings.maximumConcurrentAgents
        guard runningAgentCount < maximumConcurrentAgents else {
            lastAgentErrorMessage = "最多同时运行 \(maximumConcurrentAgents) 个 Agent（设置 → Agent 可调整）。"
            return
        }

        // Record the user's instruction before anything can fail — what the
        // user asked is part of the transcript whatever happens next.
        AgentSessionStore.appendTranscriptEntry(
            AgentTranscriptEntry(kind: .userMessage, text: trimmedText),
            targetAgentID: agentID
        )
        AgentSessionStore.updateStatus(.running, forAgentID: agentID)
        streamingTextByAgentID[agentID] = ""
        lastAgentErrorMessage = nil

        Task {
            await self.deliverTurn(trimmedText, toAgent: agent)
        }
    }

    /// Spawn-or-reuse and write. Split out of `sendTurn` so the recording
    /// above happens synchronously and this part can await the (blocking)
    /// executable resolution.
    private func deliverTurn(_ turnText: String, toAgent agent: AgentSession) async {
        do {
            let processBridge = try await ensureProcess(for: agent)
            let wasWritten = processBridge.sendUserTurn(turnText)
            if !wasWritten {
                // The process died between the alive-check and the write —
                // relaunch once (with --resume) and try again rather than
                // reporting a failure the user did not cause.
                processesByAgentID[agent.id] = nil
                let relaunchedBridge = try await ensureProcess(for: agent)
                guard relaunchedBridge.sendUserTurn(turnText) else {
                    throw AgentProcessError.turnDeliveryFailed
                }
            }
        } catch {
            AgentSessionStore.updateStatus(.failed, forAgentID: agent.id)
            AgentSessionStore.updatePreview(error.localizedDescription, forAgentID: agent.id)
            lastAgentErrorMessage = error.localizedDescription
            streamingTextByAgentID[agent.id] = nil
            SoundEffectPlayer.shared.play(.attentionNeeded)
        }
    }

    /// Returns a live process bridge for the agent, launching (first turn) or
    /// relaunching with `--resume` (every launch after) as needed.
    private func ensureProcess(for agent: AgentSession) async throws -> ClaudeAgentProcess {
        if let existingBridge = processesByAgentID[agent.id], existingBridge.isProcessAlive {
            return existingBridge
        }

        let settings = currentSettings
        let resolution = await Task.detached(priority: .userInitiated) {
            ClaudeAgentProcess.resolveExecutablePath(explicitPath: settings.agentClaudeExecutablePath)
        }.value

        guard let resolution else {
            throw AgentProcessError.executableUnavailable(searchedLocations: [])
        }

        let processBridge = ClaudeAgentProcess(agentID: agent.id) { [weak self] event in
            self?.handleAgentProcessEvent(event)
        }

        let permissionArguments = currentSettings.agentPermissionMode.cliArguments
        try processBridge.launch(
            executablePath: resolution.path,
            projectFolderPath: agent.projectFolderPath,
            permissionArguments: permissionArguments
        )

        processesByAgentID[agent.id] = processBridge
        return processBridge
    }

    /// Stops the agent's current turn. The thread history stays on the CLI
    /// side — the next turn resumes it.
    func interrupt(_ agentID: UUID) {
        guard let agent = sessions.first(where: { $0.id == agentID }),
              agent.status == .running else { return }

        processesByAgentID[agentID]?.requestInterrupt()
        AgentSessionStore.updateStatus(.interrupted, forAgentID: agentID)
        streamingTextByAgentID[agentID] = nil
    }

    private func terminateAllProcessesForAppExit() {
        for (_, processBridge) in processesByAgentID {
            processBridge.terminate(force: false)
        }
    }

    // MARK: - Completion announcement (TTS)

    /// Reads a finished turn aloud — the "agent reports back in voice"
    /// behavior. Three gates, each load-bearing: the setting, the voice being
    /// idle (a `speakText` call begins with `stopPlayback()`, so announcing
    /// during an answer would cut the answer off mid-sentence), and the
    /// one-at-a-time flag (two agents finishing together must queue, not
    /// clobber). A busy voice falls back to the `answerFinished` chime that
    /// already played — the user still hears *something* happened.
    private func maybeAnnounceCompletion(agentID: UUID, resultText: String) {
        guard AppSettingsStore.snapshot().announcesAgentCompletion else { return }
        guard voiceIdleProvider?() == true else { return }
        guard !isAnnouncingCompletion, let speakAnnouncement else { return }

        let agentName = sessions.first(where: { $0.id == agentID })?.name ?? "后台 Agent"
        // One sentence is the announcement; the full answer is on the chip and
        // in the roster. Sentence terminators cut, newlines too, and the 60-
        // character cap keeps a run-on first line from becoming a lecture.
        let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = trimmedResult
            .components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .first ?? trimmedResult
        let announcementBody = String(firstSentence.prefix(60))

        isAnnouncingCompletion = true
        Task {
            await speakAnnouncement("「\(agentName)」完成了：\(announcementBody)")
            isAnnouncingCompletion = false
        }
    }

    // MARK: - Process event handling

    private func handleAgentProcessEvent(_ event: AgentProcessEvent) {
        switch event {
        case .streamDelta(let agentID, let appendedText):
            var currentText = streamingTextByAgentID[agentID] ?? ""
            currentText += appendedText
            streamingTextByAgentID[agentID] = currentText

        case .toolActivity(let agentID, let summaryLine):
            AgentSessionStore.appendTranscriptEntry(
                AgentTranscriptEntry(kind: .toolActivity, text: summaryLine),
                targetAgentID: agentID
            )

        case .turnFinished(let agentID, let resultText, let costUSD):
            let finishedStatus: AgentSessionStatus = sessions.first(where: { $0.id == agentID })?.status == .interrupted
                ? .interrupted
                : .completed
            // An interrupted turn still gets its partial result recorded —
            // what the agent did say is part of what happened.
            AgentSessionStore.appendTranscriptEntry(
                AgentTranscriptEntry(kind: .assistantMessage, text: resultText),
                targetAgentID: agentID
            )
            AgentSessionStore.updateStatus(finishedStatus, forAgentID: agentID)
            if let costUSD {
                // One write covers both the per-turn figure and the running
                // total — the accumulated number is what the transcript header
                // shows as 「累计 ≈$x.xx」.
                AgentSessionStore.addTurnCost(costUSD, forAgentID: agentID)
            }
            streamingTextByAgentID[agentID] = nil
            if finishedStatus == .completed {
                SoundEffectPlayer.shared.play(.answerFinished)
                maybeAnnounceCompletion(agentID: agentID, resultText: resultText)
            }

        case .processExited(let agentID, _, let stderrTail):            let agent = sessions.first(where: { $0.id == agentID })
            switch agent?.status {
            case .running:
                // Died mid-turn without being asked to — a crash or a CLI
                // error. The stderr tail is the actual cause; show it.
                let failurePreview = stderrTail.isEmpty
                    ? "子进程意外退出"
                    : String(stderrTail.suffix(200))
                AgentSessionStore.updateStatus(.failed, forAgentID: agentID)
                AgentSessionStore.updatePreview(failurePreview, forAgentID: agentID)
                lastAgentErrorMessage = stderrTail.isEmpty ? "Agent 子进程意外退出。" : failurePreview
                streamingTextByAgentID[agentID] = nil
                SoundEffectPlayer.shared.play(.attentionNeeded)
            default:
                // Interrupted, completed or idle exits need no alarm — the
                // next turn simply resumes the thread.
                break
            }
        }
    }
}
