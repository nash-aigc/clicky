//
//  ExternalToolchain.swift
//  Wanna
//
//  两个出口依赖的外部命令行工具，以及它们的查找与安装。
//
//  Wanna 自己不带 node，也不带 claude：图形讲解（第五出口）把 `.geom` 交给
//  geometry-dsl 的 Node 引擎编译，Agent 功能把任务交给 claude CLI。缺任何一个，
//  对应的那条出口就是坏的 —— 而**失败发生得很晚、而且指向错误的方向**：用户得真的
//  说一句「画个图」才会撞上，撞上时 `MacosUseController` 的两条 guard 报的都是
//  「找不到 python3」，而实际上 python3 在、缺的是 node（2026-09-26 实测）。
//
//  所以这里做两件事：启动时查一次并留下一条说明白了的日志，设置页里给出一张表和
//  安装按钮。查找方式与 `ClaudeAgentProcess` 一致 —— GUI app 继承到的 PATH 很短，
//  不能只信 `which`，候选路径按 Apple Silicon / Intel 两套 Homebrew 前缀列全。
//

import Combine
import Foundation

nonisolated enum ExternalToolchain {

    enum Tool: String, CaseIterable, Identifiable {
        case node
        case claudeCode

        var id: String { rawValue }

        /// 表里显示的名字 —— 就是用户在终端里敲的那个词。
        var displayName: String {
            switch self {
            case .node: return "node"
            case .claudeCode: return "claude"
            }
        }

        /// 哪个功能要它。缺了会坏在哪，必须写清楚 —— 否则用户没法判断要不要装。
        var purpose: String {
            switch self {
            case .node:
                return "图形讲解要用它。它把模型写出的 .geom 描述编译成 SVG —— 也就是你在屏幕上看到的那张图。没有它，说「画个图」不会有任何反应。"
            case .claudeCode:
                return "Agent 功能要用它。后台 Agent 是一整个 claude CLI 进程在你的项目文件夹里干活，它的每一轮输出都由 Wanna 读回来。没有它，新建的 Agent 跑不起来。"
            }
        }

        /// 找不到时给用户自己敲的那一条。
        var installCommandLine: String {
            switch self {
            case .node: return "brew install node"
            case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
            }
        }

        /// 候选位置。两套 Homebrew 前缀都列上，再算上 claude 自己的本地安装目录。
        var candidatePaths: [String] {
            switch self {
            case .node:
                return [
                    "/opt/homebrew/bin/node",
                    "/usr/local/bin/node"
                ]
            case .claudeCode:
                return [
                    "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude",
                    NSHomeDirectory() + "/.claude/local/claude"
                ]
            }
        }
    }

    /// GUI app 继承到的 PATH 很短，跑安装命令时补全 —— 与 `ClaudeAgentProcess`
    /// 给 Agent 进程补的是同一串，理由相同：brew / npm 都在这些目录里。
    static let guaranteedPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// 找到就返回绝对路径，找不到返回 nil。先看候选位置（可执行才算数），
    /// 再在补全后的 PATH 里找一遍 —— 用户可能装在 nvm / asdf 这类非标准位置。
    static func locate(_ tool: Tool) -> String? {
        let fileManager = FileManager.default
        for candidate in tool.candidatePaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        for directory in guaranteedPaths.split(separator: ":") {
            let path = "\(directory)/\(tool.displayName)"
            if fileManager.isExecutableFile(atPath: path) { return path }
        }

        // 用户的 PATH 里可能还有别的地方（nvm、asdf、mise）。GUI app 自己
        // 看不到它，但用户的登录 shell 看得到，所以问它一次。
        if let shellPath = loginShellWhich(tool.displayName), fileManager.isExecutableFile(atPath: shellPath) {
            return shellPath
        }

        return nil
    }

    /// 一次查全部。返回的字典里没有键 = 那个工具没找到。
    static func locateAll() -> [Tool: String] {
        var found: [Tool: String] = [:]
        for tool in Tool.allCases {
            if let path = locate(tool) { found[tool] = path }
        }
        return found
    }

    /// 登录 shell 里的 `which`。找不到就返回 nil，不抛错、不打印 ——
    /// 这只是一条兜底路径，没有它前面两轮已经答完了。
    private static func loginShellWhich(_ name: String) -> String? {
        let (status, output) = runLoginShell("/usr/bin/which \(name)", timeout: 10)
        guard status == 0 else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// 跑一条登录 shell 命令，返回 (退出码, 合并后的 stdout+stderr)。
    ///
    /// 走 `zsh -lc` 而不是直接 exec：brew 和 npm 都在用户的 shell 配置里，
    /// 用登录 shell 才拿得到它们；同时把 `guaranteedPaths` 补进 PATH，防止
    /// 用户的配置里根本没有（新机器、空 profile）。
    static func runLoginShell(_ command: String, timeout: TimeInterval = 900) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = guaranteedPaths + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "无法启动命令：\(error.localizedDescription)")
        }

        // 先读完再等退出：输出多的时候，先 wait 会在管道写满时死锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }
}

/// 设置页那张表的状态。装完之后要能立刻变绿，所以状态归它管，不归视图。
@MainActor
final class ExternalToolchainModel: ObservableObject {

    /// 找到的工具 → 它的绝对路径。没有键 = 没找到。
    @Published private(set) var located: [ExternalToolchain.Tool: String] = [:]

    /// 正在装的工具。装的时候按钮变「安装中…」并禁用。
    @Published private(set) var installing: Set<ExternalToolchain.Tool> = []

    /// 安装失败的原因，按工具存。失败必须说出来 —— 静默的安装按钮等于没装。
    @Published private(set) var failures: [ExternalToolchain.Tool: String] = [:]

    init() {
        refresh()
    }

    func refresh() {
        located = ExternalToolchain.locateAll()
    }

    func isInstalled(_ tool: ExternalToolchain.Tool) -> Bool {
        located[tool] != nil
    }

    func isInstalling(_ tool: ExternalToolchain.Tool) -> Bool {
        installing.contains(tool)
    }

    func failure(for tool: ExternalToolchain.Tool) -> String? {
        failures[tool]
    }

    /// 跑安装命令，完了重新查一遍。
    func install(_ tool: ExternalToolchain.Tool) async {
        guard !installing.contains(tool) else { return }
        installing.insert(tool)
        failures[tool] = nil

        let command = tool.installCommandLine
        ExternalToolchain.appendToDiagnosticLog("开始安装 \(tool.displayName)：\(command)")

        let result = await Task.detached { ExternalToolchain.runLoginShell(command) }.value

        installing.remove(tool)
        refresh()

        if isInstalled(tool) {
            ExternalToolchain.appendToDiagnosticLog("安装成功：\(tool.displayName) → \(located[tool] ?? "?")")
        } else {
            // 命令退出 0 也可能装到 PATH 之外，所以判断标准是「重新查到了没有」，
            // 而不是退出码 —— 否则会给用户一个「成功」但其实仍然不可用的结果。
            let tail = result.output.suffix(600)
            failures[tool] = "命令退出码 \(result.status)，但重新查找仍然没找到 \(tool.displayName)。\n\(tail)"
            ExternalToolchain.appendToDiagnosticLog("安装失败：\(tool.displayName)，退出码 \(result.status)")
        }
    }
}

extension ExternalToolchain {
    /// 往录音诊断日志追加一行。和 `SoundEffectPlayer.appendToDiagnosticLog` 写同一个
    /// 文件 —— 外部工具的问题和录音的时间线放在同一张纸上，排查时不用对齐时间戳。
    nonisolated static func appendToDiagnosticLog(_ line: String) {
        let url = AppSupportDirectory.folderURLOrHome.appendingPathComponent("录音诊断.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
