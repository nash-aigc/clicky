import Foundation

/// 一次文件操作的种类。
///
/// **只有读和写两种，而「写」不含删除。** 方案 §02 明写：写 = 创建/覆盖/追加，
/// 要删就单开一个工具和一个授权位。理由不是洁癖 —— 删除是这套体系里唯一不可逆的
/// 动作，把它藏在「写」里面，等于让用户开一个开关就悄悄拿到了它没打算给的能力。
/// **它实现 `CaseIterable` 是为了让「只有读和写」这条不变量可被断言**（方案 §六 P6）：
/// 哪天有人加进来一个 `.delete`，那条测试会当场变红，而不是等到某次误删之后才被发现。
nonisolated enum FileAccessOperation: String, CaseIterable, Sendable {
    case read
    case write
}

/// 白名单里的一条：一个路径，加它的两个开关。
///
/// **读和写互不蕴含** —— 只有写没有读是合法的（往一个目录里投文件，但不许看里面
/// 有什么），所以它们必须是两个独立的布尔，不能用一个枚举。
nonisolated struct FileAccessEntry: Codable, Hashable, Sendable {
    var path: String
    var allowsRead: Bool
    var allowsWrite: Bool

    init(path: String, allowsRead: Bool = false, allowsWrite: Bool = false) {
        self.path = path
        self.allowsRead = allowsRead
        self.allowsWrite = allowsWrite
    }
}

/// 放行还是拒绝，以及**为什么**。
///
/// 拒绝理由不是给人看的客套话：模型会读它。方案 §02「拒绝要说理由」那条的要求是
/// 理由里要有「哪条路径、当前允许什么」—— 少了这两样，模型只会对着同一个路径反复
/// 重试，而它每次拿到的都还是一句「不行」。
nonisolated struct FileAccessDecision: Sendable {
    let isAllowed: Bool
    let reason: String
    /// 命中的那一条（最长匹配）。拒绝时是 nil。
    let matchedEntry: FileAccessEntry?
}

/// 逐路径白名单。**三条铁律 + 四条逃逸防线。**
///
/// 三条铁律（方案 `06-权限模型.md` §二）：
/// 1. **空列表 = 文件能力全关。** 不是「默认给桌面」—— 一个没配过的 Clicky 不碰
///    用户的任何文件。
/// 2. **嵌套取最长匹配。** `/项目A` 只读 + `/项目A/notes.md` 可写 → 写 notes.md 通过。
/// 3. **读和写互不蕴含。**
///
/// 四条逃逸防线（同节）：
/// 1. **只接受绝对路径。** 相对路径的基准是什么？进程的工作目录 —— 那是 LaunchServices
///    决定的，用户看不到也控制不了。拿一个用户看不见的基准去判权限，等于没判。
/// 2. **符号链接要 realpath 之后才比对。** 否则 `/白名单/link` 指向 `/etc` 就绕过去了。
/// 3. **路径分量边界。** `/A` 不匹配 `/Ab` —— 纯前缀比较会把 `/Users/me/Documents2`
///    当成 `/Users/me/Documents` 的子目录放行。
/// 4. **`../` 越级。** 标准化的过程会折叠掉 `..`，所以 `/白名单/../../../etc/passwd`
///    化简之后根本落不进白名单，第三道防线自然接住它。
///
/// **这个类型是纯函数。** 没有文件系统之外的依赖、没有状态、没有并发 —— 所以它
/// 能脱离 App 单独编译运行，每一条防线都能被一个几行的测试钉死（见 `FileAccessPolicyTests`
/// 那段注释里的验证方式）。
nonisolated struct FileAccessPolicy: Sendable {
    let entries: [FileAccessEntry]

    init(entries: [FileAccessEntry]) {
        self.entries = entries
    }

    /// 没配过任何路径时的策略。
    static let closed = FileAccessPolicy(entries: [])

    func decide(path rawPath: String, operation: FileAccessOperation) -> FileAccessDecision {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 防线 ①：只接受绝对路径。
        guard trimmed.hasPrefix("/") else {
            return FileAccessDecision(
                isAllowed: false,
                reason: "路径必须是绝对路径（以 / 开头）：`\(trimmed)`。当前允许的路径：\(describeEntries())",
                matchedEntry: nil)
        }
        guard !trimmed.contains("\0") else {
            return FileAccessDecision(isAllowed: false,
                                      reason: "路径里有空字节。", matchedEntry: nil)
        }

        // 防线 ②：解析符号链接之后才比对。写一个新文件时它还不存在，所以从**最深的
        // 已存在祖先**开始解析 —— 不这么做的话，`/白名单/新文件.txt` 会因为 realpath
        // 失败而被当成非法路径，而它恰恰是最常见的合法用法。
        let resolved = Self.resolveSymlinksAsFarAsPossible(trimmed)

        // 防线 ③④：分量边界比较。`standardizedFileURL` 会折叠 `.` 和 `..`（防线 ④），
        // 而下面的比较按**分量**做，不是按字符串前缀（防线 ③）。
        let standardized = URL(fileURLWithPath: resolved).standardizedFileURL.path

        // **最长匹配优先。** 不是「先命中先赢」：`/项目A` 只读排在 `/项目A/notes.md`
        // 可写前面是完全正常的写法，先命中先赢会让那条更具体的授权永远不生效。
        let matches = entries.compactMap { entry -> (FileAccessEntry, String)? in
            let entryPath = URL(fileURLWithPath: Self.resolveSymlinksAsFarAsPossible(
                entry.path.trimmingCharacters(in: .whitespacesAndNewlines))).standardizedFileURL.path
            guard Self.isSameOrDescendant(standardized, of: entryPath) else { return nil }
            return (entry, entryPath)
        }
        .sorted { $0.1.count > $1.1.count }

        guard let (entry, _) = matches.first else {
            return FileAccessDecision(
                isAllowed: false,
                reason: "`\(standardized)` 不在允许的路径里。当前允许的路径：\(describeEntries())",
                matchedEntry: nil)
        }

        let allowed = operation == .read ? entry.allowsRead : entry.allowsWrite
        guard allowed else {
            return FileAccessDecision(
                isAllowed: false,
                reason: "`\(standardized)` 命中的是 `\(entry.path)`，"
                    + "它只允许\(entry.allowsRead ? "读" : "")\(entry.allowsRead && entry.allowsWrite ? "和" : "")\(entry.allowsWrite ? "写" : "")"
                    + "，不能\(operation == .read ? "读" : "写")。",
                matchedEntry: nil)
        }
        return FileAccessDecision(isAllowed: true, reason: "允许", matchedEntry: entry)
    }

    /// `candidate` 是不是 `base` 本身或它的后代。**按路径分量比，不按字符串前缀。**
    private static func isSameOrDescendant(_ candidate: String, of base: String) -> Bool {
        if candidate == base { return true }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return candidate.hasPrefix(prefix)
    }

    /// 从最深的已存在祖先开始 realpath，再把剩下的分量接回去。
    ///
    /// 写一个新文件时目标还不存在，`realpath` 会失败 —— 而「写一个还不存在的文件」
    /// 是写权限最常见的用法。所以逐级往上找到第一个存在的祖先解析它，剩下的原样接上：
    /// 中间那一层如果是个指向别处的符号链接，它必然已经存在，因而会被解析到。
    private static func resolveSymlinksAsFarAsPossible(_ path: String) -> String {
        var current = path
        var trailingComponents: [String] = []
        while true {
            let resolved = (current as NSString).resolvingSymlinksInPath
            // `resolvingSymlinksInPath` 对不存在的路径会原样返回，所以用「有没有解析掉
            // 分量」来判断是否到底：解析结果和输入相同时，说明这一级已经不存在了，
            // 该往上退一级再试。
            if resolved != current || current == "/" {
                guard !trailingComponents.isEmpty else { return resolved }
                return (resolved as NSString).appendingPathComponent(
                    trailingComponents.reversed().joined(separator: "/"))
            }
            trailingComponents.append((current as NSString).lastPathComponent)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return path }   // 到根了还是没解析出来
            current = parent
        }
    }

    private func describeEntries() -> String {
        guard !entries.isEmpty else { return "（空 —— 文件能力全关）" }
        return entries.map {
            "\($0.path)[\($0.allowsRead ? "读" : "")\($0.allowsWrite ? "写" : "")]"
        }.joined(separator: " ")
    }
}
