import AppKit
import Foundation
// 工程开着 `MemberImportVisibility`，不显式 import 会被判成「成员不可见」。
import Combine

/// 用户配了哪些 MCP 服务器。
///
/// 落盘在 `~/Library/Application Support/Wanna/MCPServers.json`，**仓库外 + 0600**
/// —— 和 `AppSettings.json` / `ModelConfiguration.json` 同一层、同一个理由：
/// **这份文件里有密钥**（`env` 里的 API key），进仓库就是泄露。
///
/// 形状照抄另外几个 store：`nonisolated` + `NSLock` + 原子写后补 0600 + 变更通知。
/// 这几个 store 长得一样不是巧合 —— 项目的 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// 让一个隔离写错变得静默，所以凡是跨线程读写的存储都用同一种能一眼看懂的形状。
///
/// **和 `~/.claude.json` 里那份同构。** 两边说的是同一件事（起什么进程、给什么环境
/// 变量），形状一样，用户从一边抄到另一边不用做转换。
nonisolated final class MCPServersStore {

    static let shared = MCPServersStore()
    static let didChangeNotification = Notification.Name("wannaMCPServersDidChange")

    private let lock = NSLock()
    private var cache: [MCPServerConfig]?

    private var fileURL: URL {
        AppSupportDirectory.folderURLOrHome.appendingPathComponent("MCPServers.json")
    }

    func allServers() -> [MCPServerConfig] {
        lock.lock()
        if let cache { lock.unlock(); return cache }
        lock.unlock()

        let loaded = loadFromDisk()
        lock.lock(); cache = loaded; lock.unlock()
        return loaded
    }

    func server(named name: String) -> MCPServerConfig? {
        allServers().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func save(_ servers: [MCPServerConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(servers)
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // `.atomic` 落下来是 0644，而这份文件里有密钥 —— 补 0600。
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
        lock.lock(); cache = servers; lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 直接从磁盘读，**不走缓存** —— 只有这里需要看到别人刚写进去的东西。
    private func loadFromDisk() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: fileURL),
              let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return servers
    }
}

/// 活着的 MCP 连接。
///
/// **一个服务器一个客户端，按需起、闲置停。** 它是子进程，一直挂着会占内存；
/// 而 `[MCP:…]` 标签本来就不是每一轮都会出现 —— 用户问屏幕上的东西时，
/// 一个 MCP 进程都不该被拉起来。
///
/// 工具清单缓存在这里：`tools/list` 一次要几百毫秒，而同一次会话里同一个服务器
/// 会被问很多次。**缓存的是清单，不是 schema 的用法** —— schema 仍然只在真要调
/// 那个工具时才递进模型（方案 §08：工具 schema 不直接注入提示词）。
@MainActor
final class MCPRegistry {

    static let shared = MCPRegistry()
    private init() {
        // 进程退出时把子进程收掉 —— 否则每退一次 App 就留下一批孤儿 npx。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MCPRegistry.shared.shutdownAll() }
        }
        // 用户改了服务器清单就断开重来：配置变了而连接还是旧的，是最难查的一类
        // 「我改了它怎么没反应」。
        NotificationCenter.default.addObserver(
            forName: MCPServersStore.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MCPRegistry.shared.shutdownAll() }
        }
    }

    private var clients: [String: MCPClient] = [:]
    private var toolCache: [String: [MCPTool]] = [:]

    /// 用户配了名字的所有服务器。**不启动任何进程** —— 界面用它列清单。
    var configuredServerNames: [String] { MCPServersStore.shared.allServers().map(\.name) }

    func client(forServerNamed name: String) -> MCPClient? {
        guard let config = MCPServersStore.shared.server(named: name) else { return nil }
        if let existing = clients[config.name] { return existing }
        let client = MCPClient(config: config)
        clients[config.name] = client
        return client
    }

    /// 列某个服务器的工具。第一次会真的起进程。
    func tools(ofServerNamed name: String) async throws -> [MCPTool] {
        guard let config = MCPServersStore.shared.server(named: name) else {
            throw MCPClient.Failure.cannotLaunch("没有配过名为 `\(name)` 的 MCP 服务器")
        }
        if let cached = toolCache[config.name] { return cached }
        guard let client = client(forServerNamed: name) else {
            throw MCPClient.Failure.cannotLaunch("拿不到 `\(name)` 的客户端")
        }
        let tools = try await client.listTools()
        toolCache[config.name] = tools
        return tools
    }

    /// 调一次工具，返回给模型看的文字。
    func call(server: String, tool: String, arguments: [String: Any]) async throws -> String {
        guard let client = client(forServerNamed: server) else {
            throw MCPClient.Failure.cannotLaunch("没有配过名为 `\(server)` 的 MCP 服务器")
        }
        return try await client.callTool(name: tool, arguments: arguments)
    }

    func shutdownAll() {
        for (_, client) in clients { client.stop() }
        clients.removeAll()
        toolCache.removeAll()
    }

    /// 断掉一个（配置改了、或者用户手动断）。
    func shutdown(serverNamed name: String) {
        clients[name]?.stop()
        clients.removeValue(forKey: name)
        toolCache.removeValue(forKey: name)
    }
}
