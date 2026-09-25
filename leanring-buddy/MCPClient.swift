import Foundation

// 帧规则来自官方 SDK 的源码（`@modelcontextprotocol/sdk/dist/esm/shared/stdio.js`），
// 不是猜的：
//
//     readMessage() { const index = this._buffer.indexOf("\n"); … }
//     serializeMessage(message) { return JSON.stringify(message) + "\n" }
//
// 也就是**换行分隔的 JSON-RPC**，没有 `Content-Length` 头（那是 LSP 的写法，MCP
// 不用）。每一条消息一行，读的时候按 `\n` 切、去掉行尾的 `\r`。

/// 一个 MCP 服务器的启动方式。**和 `~/.claude.json` 里那一份同构** —— 两边说同一
/// 件事（起什么进程、给什么环境变量），形状一样才不用记两套。
nonisolated struct MCPServerConfig: Codable, Sendable, Equatable {
    var name: String
    var command: String
    var args: [String]
    /// 环境变量。**密钥就住在这里** —— 而这份文件在仓库外面、0600。
    var env: [String: String]?

    init(name: String, command: String, args: [String] = [], env: [String: String]? = nil) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

/// 服务器报上来的一个工具。
///
/// **它的 `description` 和 `inputSchema` 是运行时问出来的**，不是写在配置里的 ——
/// 服务器换了工具，客户端一个字都不用改。这就是 MCP 和「技能」最大的区别：
/// 技能的功能写在 `SKILL.md` 的 description 里，MCP 的功能靠 `tools/list` 现问。
nonisolated struct MCPTool: Sendable, Equatable {
    let name: String
    let description: String
    /// 原始 JSON 字符串。**只在真的要调这个工具时才递进模型**，
    /// 不是把所有 schema 都塞进提示词（方案 §08 组装机制明写这一条）。
    let inputSchemaJSON: String
}

/// 一个 MCP 服务器的连接：起进程、握手、列工具、调工具。
///
/// 生命周期是「按需起、闲置停」：它是子进程，一直挂着会占内存；而 `[MCP:…]` 标签
/// 本来就不是每一轮都会出现。第一次用到某个服务器时才 `start()`。
///
/// **所有可变状态都关在 `queue` 上**，对外只暴露 async 方法 —— 和
/// `VolcengineRealtimeASRClient` 同一个形状。
nonisolated final class MCPClient {

    enum Failure: Error, CustomStringConvertible {
        case cannotLaunch(String)
        case handshakeFailed(String)
        case serverError(String)
        case timedOut(String)

        var description: String {
            switch self {
            case .cannotLaunch(let why): return "MCP 服务器起不来：\(why)"
            case .handshakeFailed(let why): return "MCP 握手失败：\(why)"
            case .serverError(let why): return "MCP 服务器报错：\(why)"
            case .timedOut(let what): return "MCP 等了太久没回应：\(what)"
            }
        }
    }

    let config: MCPServerConfig

    private let queue = DispatchQueue(label: "clicky.mcp")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var buffer = Data()
    private var nextRequestID = 1
    /// 每个请求一个 continuation，按 id 找回。
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var isStarted = false
    /// 服务器报错时留下的最后一行 —— 出问题时它是唯一能看的东西。
    private(set) var lastStderrLine: String?

    init(config: MCPServerConfig) {
        self.config = config
    }

    deinit {
        // **只直接关文件，不走 `stop()`。** `stop()` 会 `queue.async { self… }`，
        // 那等于在引用计数已经归零之后又留了一个对 self 的引用 —— 释放那一刻
        // 会多一次 release，进程就死在 `_Block_release` 里。
        // 这个坑这个仓库已经踩过一次（见 `BailianRealtimeTranscriptionSession`）。
        try? stdinHandle?.close()
        process?.terminate()
    }

    // MARK: - 起进程与握手

    /// 起来并握手。已经起来就什么都不做。
    func start() async throws {
        if isStarted { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.launchOnQueue() } catch {
                    continuation.resume(throwing: error); return
                }
                continuation.resume()
            }
        }
        // 握手：`initialize` → 通知 `initialized` → 完事。
        //
        // **三条缺一不可。** 只发 `initialize` 不补那条通知的话，官方 SDK 会一直
        // 认为客户端没准备好，后面 `tools/list` 直接不响应 —— 表现是「等超时」，
        // 而不是任何一句能看懂的报错。
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Clicky", "version": "1.0"],
        ])
        notify(method: "notifications/initialized")
        isStarted = true
    }

    private func launchOnQueue() throws {
        guard let executable = Self.resolveExecutable(config.command) else {
            throw Failure.cannotLaunch("找不到可执行文件 `\(config.command)`")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = config.args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.env ?? [:] { environment[key] = value }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.ingestOnQueue(chunk) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let line = String(data: chunk, encoding: .utf8) else { return }
            self?.queue.async { self?.lastStderrLine = line.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        do {
            try process.run()
        } catch {
            throw Failure.cannotLaunch(error.localizedDescription)
        }
        self.process = process
        self.stdinHandle = input.fileHandleForWriting
        self.stdoutHandle = output.fileHandleForReading
    }

    /// 把 `npx` 这类名字解析成绝对路径。
    ///
    /// GUI App 的 PATH 和终端不一样（launchd 给的是一份很窄的），所以直接用
    /// `Process` 起 `npx` 往往会「找不到文件」—— 而那句话完全不会提到 PATH。
    private static func resolveExecutable(_ command: String) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in searchPaths {
            let candidate = directory + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 收发

    private func ingestOnQueue(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line.removeLast() }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else {
                continue   // 通知，或我们不认识的 id
            }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: Failure.serverError(
                    (error["message"] as? String) ?? "\(error)"))
            } else {
                continuation.resume(returning: (object["result"] as? [String: Any]) ?? [:])
            }
        }
    }

    private func request(method: String, params: [String: Any]? = nil) async throws
        -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let stdinHandle = self.stdinHandle else {
                    continuation.resume(throwing: Failure.cannotLaunch("进程没起来"))
                    return
                }
                let id = self.nextRequestID
                self.nextRequestID += 1
                var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
                if let params { message["params"] = params }
                guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                    continuation.resume(throwing: Failure.handshakeFailed("请求编码失败"))
                    return
                }
                self.pending[id] = continuation
                stdinHandle.write(data)
                stdinHandle.write(Data([0x0A]))   // 一条一行
            }
        }
    }

    private func notify(method: String) {
        queue.async {
            guard let stdinHandle = self.stdinHandle,
                  let data = try? JSONSerialization.data(
                      withJSONObject: ["jsonrpc": "2.0", "method": method]) else { return }
            stdinHandle.write(data)
            stdinHandle.write(Data([0x0A]))
        }
    }

    // MARK: - 工具

    func listTools() async throws -> [MCPTool] {
        try await start()
        let result = try await request(method: "tools/list")
        let rawTools = (result["tools"] as? [[String: Any]]) ?? []
        return rawTools.compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            let schema = (raw["inputSchema"] as? [String: Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return MCPTool(name: name,
                           description: (raw["description"] as? String) ?? "",
                           inputSchemaJSON: schema)
        }
    }

    /// 调一个工具，返回**给模型看的那段文字**。
    ///
    /// MCP 的回包是 `content` 数组（text / image / audio / resource）。今天只取 text：
    /// 图片要变成 `image_url` 部件递进请求体，那是另一条路；而把它当字符串塞进去
    /// 只会让模型看到一坨 base64。
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        try await start()
        let result = try await request(method: "tools/call",
                                       params: ["name": name, "arguments": arguments])
        if (result["isError"] as? Bool) == true {
            throw Failure.serverError(Self.text(from: result) ?? "工具返回了错误")
        }
        return Self.text(from: result) ?? "（工具没有返回文字）"
    }

    private static func text(from result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    func stop() {
        queue.async {
            self.stdoutHandle?.readabilityHandler = nil
            try? self.stdinHandle?.close()
            self.process?.terminate()
            self.process = nil
            self.stdinHandle = nil
            self.stdoutHandle = nil
            self.isStarted = false
            for (_, continuation) in self.pending {
                continuation.resume(throwing: Failure.cannotLaunch("服务器已停"))
            }
            self.pending.removeAll()
        }
    }
}
