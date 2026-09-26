//
//  ClaudeAgentProcess.swift
//  Wanna
//
//  The bridge between an `AgentSession` and the claude CLI — the project's
//  first `Foundation.Process` client. One live instance per running agent.
//
//  The CLI is used in its headless bidirectional mode, which is the direct
//  equivalent of a `codex` subprocess + JSON-RPC pipe
//  (claude's stream-json here — same protocol shape, a newline-delimited
//  bidirectional JSON stream):
//
//      claude -p --input-format stream-json --output-format stream-json \
//             --verbose --include-partial-messages --session-id <UUID> …
//
//  - a user turn is one JSON line written to stdin;
//  - the agent's output arrives on stdout as JSON lines (streaming deltas,
//    complete assistant messages, tool uses, and one `result` per turn);
//  - the process stays alive between turns, so a follow-up is just another
//    stdin line (a steer);
//  - the thread is identified by `--session-id`, so when a process dies the
//    next turn relaunches with `--resume <id>` and the conversation continues
//    (thread/resume).
//
//  Concurrency shape: the class is `nonisolated` (the target's default
//  MainActor isolation would make every pipe callback a compile error), all
//  mutable state is confined to one serial `parsingQueue`, and events are
//  handed back to `AgentSessionManager` on the main actor. `Foundation` only —
//  no SwiftUI — so the parser can be reasoned about (and tested) on its own.
//

import Foundation

/// What the process bridge reports back to `AgentSessionManager`, always on
/// the main actor.
nonisolated enum AgentProcessEvent: Sendable {
    /// A delta of the agent's in-flight answer text for the current turn.
    case streamDelta(agentID: UUID, appendedText: String)
    /// The agent invoked a tool — the visible progress of a working agent.
    case toolActivity(agentID: UUID, summaryLine: String)
    /// The current turn finished. `resultText` is the full answer (what the
    /// streamed deltas add up to); `costUSD` is the CLI's own cost estimate
    /// when it reports one.
    case turnFinished(agentID: UUID, resultText: String, costUSD: Double?)
    /// The subprocess exited. `exitCode` is nil when it never launched. The
    /// manager decides whether an exit means interrupted (it asked for it),
    /// failed, or just the end of a normal process lifetime.
    case processExited(agentID: UUID, exitCode: Int32?, stderrTail: String)
}

nonisolated final class ClaudeAgentProcess {

    // MARK: - Launch configuration

    /// The launch command for one agent process. Kept as a static function so
    /// the argument vocabulary is inspectable without a live process.
    ///
    /// `resumesThread` passes `--resume <id>` instead of `--session-id <id>`:
    /// both name the same thread, but a fresh launch names it and a resume
    /// continues it — and passing `--session-id` together with `--resume` is
    /// not a documented combination.
    static func launchArguments(
        sessionID: UUID,
        permissionArguments: [String],
        resumesThread: Bool,
        modelAlias: String? = nil
    ) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if resumesThread {
            arguments += ["--resume", sessionID.uuidString]
        } else {
            arguments += ["--session-id", sessionID.uuidString]
        }
        // A headless `-p` run has nobody to answer an approval prompt. `none`
        // makes anything that would prompt fail fast instead of hanging the
        // turn forever — the permission mode's own arguments decide what is
        // auto-approved (see `AgentPermissionMode.cliArguments`).
        arguments += ["--permission-prompts", "none"]
        // **这个 agent 自己选的模型**（卡片上那个「用哪个 AI」）。没选过就不传 ——
        // 传空串会让 CLI 直接报错，而"没选"的语义本来就是"用 CLI 的默认"。
        if let trimmedModelAlias = modelAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedModelAlias.isEmpty {
            arguments += ["--model", trimmedModelAlias]
        }
        arguments += permissionArguments
        return arguments
    }

    /// The claude executable: the user's explicit settings path when it is a
    /// usable file, otherwise `which claude`, otherwise the two Homebrew
    /// locations. Returns nil with a reason when nothing usable is found, so
    /// the failure can be shown instead of guessed at.
    static func resolveExecutablePath(explicitPath: String?) -> (path: String, searchedLocations: [String])? {
        var searchedLocations: [String] = []

        if let explicitPath, !explicitPath.isEmpty {
            searchedLocations.append(explicitPath)
            if FileManager.default.isExecutableFile(atPath: explicitPath) {
                return (explicitPath, searchedLocations)
            }
        }

        for candidatePath in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            searchedLocations.append(candidatePath)
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return (candidatePath, searchedLocations)
            }
        }

        return nil
    }

    /// Whether this agent's thread already exists in the CLI's own session
    /// store (`~/.claude/projects/<escaped-cwd>/<session-id>.jsonl`).
    ///
    /// This is the ground truth for the `--session-id` vs `--resume` decision,
    /// replacing a memory-only flag: the flag resets on every app relaunch,
    /// and the first turn afterwards then "created" a session the CLI already
    /// had on disk — the CLI refuses that with
    /// `Error: Session ID … is already in use.` (measured 2026-09-23 on the
    /// agent 「Wanna」). The session file surviving the app is exactly what
    /// the flag was trying to remember, so ask the filesystem instead.
    ///
    /// The directory name is the CLI's project slug for the agent's cwd: every
    /// character outside ASCII letters and digits becomes `-` — measured
    /// 2026-09-23, `<home>/Desktop/untitled folder` →
    /// `-Users-…-Desktop-untitled-folder`. Mirroring the rule (rather than
    /// listing the directory and matching) keeps the check one `FileManager`
    /// call.
    static func sessionExistsOnDisk(sessionID: UUID, projectFolderPath: String) -> Bool {
        let projectSlug = String(projectFolderPath.map { character in
            ("a"..."z").contains(character)
                || ("A"..."Z").contains(character)
                || ("0"..."9").contains(character)
                ? character : "-"
        })
        let sessionFilePath = NSHomeDirectory()
            + "/.claude/projects/\(projectSlug)/\(sessionID.uuidString).jsonl"
        return FileManager.default.fileExists(atPath: sessionFilePath)
    }

    // MARK: - State

    let agentID: UUID

    /// Called for every event, always on the main actor.
    private let eventHandler: @MainActor (AgentProcessEvent) -> Void

    /// Serial home for all mutable state: the live process handles, the stderr
    /// tail, the in-flight turn's streamed text, the interrupted flag.
    private let parsingQueue = DispatchQueue(label: "wanna.agent.process.parsing")

    private var process: Process?
    private var standardInputHandle: FileHandle?
    private var stderrTailLines: [String] = []
    private var accumulatedStreamText: String = ""
    private var isUserInterruptRequested = false
    /// Whether at least one launch has happened — the manager asks to decide
    /// between `--session-id` (first) and `--resume` (every launch after).
    private(set) var hasLaunchedOnce = false

    /// How many lines of stderr are kept for failure reporting.
    private static let maximumStderrTailLines = 12

    // MARK: - Lifecycle

    init(agentID: UUID, eventHandler: @MainActor @escaping (AgentProcessEvent) -> Void) {
        self.agentID = agentID
        self.eventHandler = eventHandler
    }

    /// Whether a live subprocess exists right now. The manager reads this to
    /// decide launch-vs-reuse for the next turn.
    var isProcessAlive: Bool {
        parsingQueue.sync {
            if let process, process.isRunning {
                return true
            }
            return false
        }
    }

    /// Spawns the claude subprocess. Fails with a reason (shown to the user)
    /// rather than leaving the manager to guess — an unresolvable executable
    /// or an unopenable project folder is a configuration problem, not a
    /// silent one.
    func launch(
        executablePath: String,
        projectFolderPath: String,
        permissionArguments: [String],
        modelAlias: String? = nil
    ) throws {
        try parsingQueue.sync { try launchSynchronously(
            executablePath: executablePath,
            projectFolderPath: projectFolderPath,
            permissionArguments: permissionArguments,
            modelAlias: modelAlias
        ) }
    }

    private func launchSynchronously(
        executablePath: String,
        projectFolderPath: String,
        permissionArguments: [String],
        modelAlias: String?
    ) throws {
        guard process == nil || process?.isRunning == false else {
            return // Already live — the manager asked to reuse.
        }

        guard FileManager.default.fileExists(atPath: projectFolderPath) else {
            throw AgentProcessError.projectFolderMissing(projectFolderPath)
        }

        let launchedProcess = Process()
        launchedProcess.executableURL = URL(fileURLWithPath: executablePath)
        // Resume when EITHER this process launched before OR the session file
        // is already on disk from an earlier app run — the in-memory flag
        // alone misses the cross-launch case (see sessionExistsOnDisk).
        let sessionAlreadyExists = hasLaunchedOnce
            || Self.sessionExistsOnDisk(sessionID: agentID, projectFolderPath: projectFolderPath)
        launchedProcess.arguments = Self.launchArguments(
            sessionID: agentID,
            permissionArguments: permissionArguments,
            resumesThread: sessionAlreadyExists,
            modelAlias: modelAlias
        )

        // The agent works inside the user's chosen project folder — the CLI's
        // cwd grant is what scopes its file access there.
        launchedProcess.currentDirectoryURL = URL(fileURLWithPath: projectFolderPath)

        // Inherit the user's environment but force a PATH that contains the
        // Homebrew and system locations: a GUI app's inherited PATH is minimal,
        // and the agent's Bash tool needs git, node, etc. to resolve.
        var environment = ProcessInfo.processInfo.environment
        let guaranteedPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = guaranteedPaths + ":" + (environment["PATH"] ?? "")

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        launchedProcess.standardInput = standardInputPipe
        launchedProcess.standardOutput = standardOutputPipe
        launchedProcess.standardError = standardErrorPipe
        launchedProcess.environment = environment

        try launchedProcess.run()

        process = launchedProcess
        standardInputHandle = standardInputPipe.fileHandleForWriting
        hasLaunchedOnce = true
        isUserInterruptRequested = false
        accumulatedStreamText = ""
        stderrTailLines = []

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            guard let chunk = String(data: availableData, encoding: .utf8) else { return }
            self.parsingQueue.async { self.consumeOutputChunk(chunk) }
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            guard let chunk = String(data: availableData, encoding: .utf8) else { return }
            self.parsingQueue.async { self.consumeErrorChunk(chunk) }
        }

        launchedProcess.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            self.parsingQueue.async { self.handleProcessTermination(exitCode: terminatedProcess.terminationStatus) }
        }
    }

    /// Writes one user turn to stdin. Returns false when there is no live
    /// process to receive it — the manager relaunches (with `--resume`) and
    /// re-sends; a turn written into a dead pipe would be lost silently.
    func sendUserTurn(_ turnText: String) -> Bool {
        parsingQueue.sync {
            guard let process, process.isRunning, let standardInputHandle else { return false }

            let turnPayload: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": turnText]],
                ],
            ]

            guard JSONSerialization.isValidJSONObject(turnPayload),
                  let payloadData = try? JSONSerialization.data(withJSONObject: turnPayload),
                  let payloadLine = String(data: payloadData, encoding: .utf8) else {
                return false
            }

            // The newline is the stream-json frame delimiter — no newline, no
            // message.
            standardInputHandle.write(Data((payloadLine + "\n").utf8))
            accumulatedStreamText = ""
            return true
        }
    }

    /// Stops the current turn: asks the CLI to interrupt (the SDK's
    /// control_request), then SIGTERMs if the turn has not ended shortly
    /// after. The thread history survives either way — the next turn resumes
    /// it with `--resume`.
    func requestInterrupt() {
        let interruptRequest: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ]
        let didSendControlRequest = parsingQueue.sync { () -> Bool in
            isUserInterruptRequested = true
            guard let process, process.isRunning, let standardInputHandle,
                  JSONSerialization.isValidJSONObject(interruptRequest),
                  let payloadData = try? JSONSerialization.data(withJSONObject: interruptRequest),
                  let payloadLine = String(data: payloadData, encoding: .utf8) else {
                return false
            }
            standardInputHandle.write(Data((payloadLine + "\n").utf8))
            return true
        }

        // If the control request was heard, the CLI ends the turn and emits a
        // `result` with subtype `error_during_execution` — no kill needed. If
        // it was not (or the process wedges), SIGTERM is the backstop.
        guard didSendControlRequest else {
            terminate(force: false)
            return
        }
        parsingQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let stillRunning = self.process?.isRunning ?? false
            if stillRunning, self.isUserInterruptRequested {
                self.terminateProcessDelivery(SIGTERM)
            }
        }
    }

    /// Kills the subprocess outright — agent deletion and app termination.
    func terminate(force: Bool) {
        parsingQueue.sync {
            isUserInterruptRequested = true
            terminateProcessDelivery(force ? SIGKILL : SIGTERM)
        }
    }

    private func terminateProcessDelivery(_ signal: Int32) {
        // kill(2) rather than Process.terminate(): terminate() raises SIGTERM
        // through the same path, but by this point the process handle may
        // already be mid-teardown and the direct signal is the more honest
        // way to reach a wedged child.
        if let process, process.isRunning {
            kill(process.processIdentifier, signal)
        }
        standardInputHandle?.closeFile()
        standardInputHandle = nil
    }

    // MARK: - Output parsing

    private func consumeOutputChunk(_ chunk: String) {
        // Chunks can split a JSON line across reads — buffer and split on
        // newlines, keeping the partial tail for the next chunk.
        outputLineBuffer += chunk
        var lines = outputLineBuffer.components(separatedBy: "\n")
        outputLineBuffer = lines.popLast() ?? ""
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            parseOutputLine(line)
        }
    }
    private var outputLineBuffer: String = ""

    private func parseOutputLine(_ line: String) {
        guard let lineData = line.data(using: .utf8),
              let eventObject = try? JSONSerialization.jsonObject(with: lineData),
              let event = eventObject as? [String: Any] else {
            return // Not JSON — the CLI's own stderr chatter arrives on stderr; ignore here.
        }

        switch event["type"] as? String {
        case "stream_event":
            parseStreamEvent(event["event"] as? [String: Any])
        case "assistant":
            parseAssistantMessage(event["message"] as? [String: Any])
        case "result":
            parseResultEvent(event)
        default:
            // `system` (init), `user` (tool results) and `control_response`
            // need no user-visible handling today.
            break
        }
    }

    private func parseStreamEvent(_ streamEvent: [String: Any]?) {
        guard streamEvent?["type"] as? String == "content_block_delta",
              let delta = streamEvent?["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let deltaText = delta["text"] as? String, !deltaText.isEmpty else {
            return
        }
        accumulatedStreamText += deltaText
        emit(.streamDelta(agentID: agentID, appendedText: deltaText))
    }

    private func parseAssistantMessage(_ message: [String: Any]?) {
        guard let contentBlocks = message?["content"] as? [[String: Any]] else { return }
        for block in contentBlocks where block["type"] as? String == "tool_use" {
            let toolName = block["name"] as? String ?? "工具"
            let summaryLine = Self.toolActivitySummaryLine(toolName: toolName, toolInput: block["input"] as? [String: Any])
            emit(.toolActivity(agentID: agentID, summaryLine: summaryLine))
        }
        // Text blocks are deliberately not emitted here: the streamed deltas
        // already delivered the same words, and emitting the complete message
        // too would paint the answer twice.
    }

    private func parseResultEvent(_ event: [String: Any]) {
        let subtype = event["subtype"] as? String
        let resultText = (event["result"] as? String) ?? accumulatedStreamText
        let costUSD = event["total_cost_usd"] as? Double
        accumulatedStreamText = ""

        if subtype == "success" {
            emit(.turnFinished(agentID: agentID, resultText: resultText, costUSD: costUSD))
        } else {
            // Interrupted turns and CLI-level errors also arrive as `result`
            // events with a non-success subtype; surface them through the
            // same channel so the manager can record one entry either way.
            let failureText = resultText.isEmpty ? "回合未正常完成（\(subtype ?? "未知原因")）" : resultText
            emit(.turnFinished(agentID: agentID, resultText: failureText, costUSD: costUSD))
        }
    }

    /// One human-readable line for a tool invocation — the tool's name plus the
    /// single argument that says what it is acting on, so the progress list
    /// reads as what the agent is doing.
    static func toolActivitySummaryLine(toolName: String, toolInput: [String: Any]?) -> String {
        let summarySourceKeys = ["command", "file_path", "pattern", "url", "query", "prompt", "description"]
        var detail: String?
        if let toolInput {
            for sourceKey in summarySourceKeys {
                if let candidate = toolInput[sourceKey] as? String, !candidate.isEmpty {
                    detail = candidate
                    break
                }
            }
            if detail == nil, let firstString = toolInput.values.compactMap({ $0 as? String }).first {
                detail = firstString
            }
        }
        let trimmedDetail = detail.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(60)) }
        return trimmedDetail.map { "⚙︎ \(toolName) · \($0)" } ?? "⚙︎ \(toolName)"
    }

    // MARK: - stderr and exit

    private func consumeErrorChunk(_ chunk: String) {
        let chunkLines = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        stderrTailLines.append(contentsOf: chunkLines)
        if stderrTailLines.count > Self.maximumStderrTailLines {
            stderrTailLines.removeFirst(stderrTailLines.count - Self.maximumStderrTailLines)
        }
    }

    private func handleProcessTermination(exitCode: Int32) {
        standardInputHandle?.closeFile()
        standardInputHandle = nil
        let wasUserInterrupted = isUserInterruptRequested
        let stderrTail = stderrTailLines.joined(separator: "\n")
        process = nil

        // A user interrupt that already produced its `result` event has no
        // extra story to tell; the exit event lets the manager settle the
        // status either way.
        _ = wasUserInterrupted
        emit(.processExited(agentID: agentID, exitCode: exitCode, stderrTail: stderrTail))
    }

    // MARK: - Plumbing

    private func emit(_ event: AgentProcessEvent) {
        let handler = eventHandler
        Task { @MainActor in
            handler(event)
        }
    }
}

nonisolated enum AgentProcessError: LocalizedError {
    case projectFolderMissing(String)
    case executableUnavailable(searchedLocations: [String])
    case turnDeliveryFailed

    var errorDescription: String? {
        switch self {
        case .projectFolderMissing(let path):
            return "项目文件夹不存在：\(path)"
        case .executableUnavailable(let searchedLocations):
            return "找不到 claude 命令行工具（找过：\(searchedLocations.joined(separator: "、"))）。可以在设置 → Agent 里手动指定路径。"
        case .turnDeliveryFailed:
            return "Agent 子进程没能接收这条指令（可能刚被中断）。请再试一次。"
        }
    }
}
