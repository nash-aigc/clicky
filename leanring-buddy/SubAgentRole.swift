import Foundation

/// 主 agent 可以派活的三个人。
///
/// 2026-09-26（`解决方案/Agent施工/` 第 2 步）：提示词从一份 22,649 字符拆成
/// 「主 agent 基础段」+ 三段技能正文。**主 agent 看不到技能正文** —— 它只看得到下面
/// 那份目录；正文由被派到的那个 agent 自己组装（基础段 + 它自己那一段）。
///
/// 这就是方案里「移走，但不是删掉」那一条：能力没有消失，只是不再由每一个问题分摊
/// 它的成本。拆之前，「屏幕上这句话什么意思」这种一句话就能答的问题，也要先读完
/// 11,958 字符的操作说明才轮到回答。
///
/// **这个类型刻意是 `nonisolated` 的**：`ActionParseResult` 是 `nonisolated Sendable`，
/// 而派活请求要作为它的一个字段穿过解析层传回来。所以这里只放**纯数据**（名字、
/// 目录行），技能正文留在 `CompanionManager` 上，由主线程那一侧按需取。
nonisolated enum SubAgentRole: String, CaseIterable, Sendable {
    case graphics
    case execution
    case text

    /// 提示词里用的名字，也是 `[AGENT:名字]` 里那个名字。
    var displayName: String {
        switch self {
        case .graphics: return "图形"
        case .execution: return "执行"
        case .text: return "文本"
        }
    }

    /// 从模型写的那三个字认出是谁。认不出返回 nil —— **宁可不派，也不猜**：
    /// 猜错就意味着把「帮我点登录」交给了只会画图的 agent。
    init?(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "图形", "graphics", "图形agent", "图形 agent": self = .graphics
        case "执行", "execution", "执行agent", "执行 agent": self = .execution
        case "文本", "text", "文本agent", "文本 agent": self = .text
        default: return nil
        }
    }

    /// 目录里那两行「什么时候叫它」。
    ///
    /// **只回答「什么时候叫谁」，不回答「怎么做」。** 怎么做的部分住在 `skillPrompt`
    /// 里，而主 agent 看不到它。
    ///
    /// 这个粗细是整套设计里**唯一需要实测调的地方**（方案 §09 的 E1）：太粗 → 主 agent
    /// 选错 agent；太细 → 又长回今天的胖提示词。今天的写法是方案 §02 给的原文。
    var directoryLine: String {
        switch self {
        case .graphics:
            return """
            图形 — 用户要在屏幕上看到指示或图形时（指位置、圈出某处、画流程图、画示意图）。
                   它负责画，你不需要描述怎么画。
            """
        case .execution:
            return """
            执行 — 用户要让电脑真的动起来时（点击、打字、开 App、调音量亮度、读写文件、跑脚本）。
                   你说做什么，它去做，做完会把结果给你。
            """
        case .text:
            return """
            文本 — 用户要一段长内容、或需要某个专业场景的写法时（文章、报告、翻译、
                   销售/法律/财务/建筑等场景的文案）。它没有任何工具，只产出文字。
            """
        }
    }
}

/// 一个 sub agent 的**能力面**。
///
/// **权限不只是安全边界，也是能力边界** —— 工具少的 agent 更不容易跑偏，所以
/// 「文本 agent 一个工具都不给」同时是质量控制手段，不是事后补的安全措施
///（方案 `06-权限模型.md` §一）。
///
/// 它是**独立于白名单**的一层：白名单管「这个路径允不允许」，能力面管「这个 agent
/// 有没有资格问这个问题」。两道都过才放行 —— 少了这一层，「文本 agent 写文件」
/// 就会因为路径恰好在白名单里而通过。
nonisolated struct SubAgentPermissionFace: Sendable {
    let canReadFiles: Bool
    let canWriteFiles: Bool
    /// 点击 / 打字 / 按键。
    let canActOnScreen: Bool
    /// 跑脚本 / 调 MCP。
    let canRunScripts: Bool
}

extension SubAgentRole {
    var permissionFace: SubAgentPermissionFace {
        switch self {
        case .graphics:
            // 只碰图形相关文件；不点击、不打字、不跑脚本 —— 它产出图形**数据**，
            // 显示由 App 自己画（`ScreenAnnotationManager` / `FigureBoardController`）。
            return SubAgentPermissionFace(canReadFiles: true, canWriteFiles: true,
                                          canActOnScreen: false, canRunScripts: false)
        case .execution:
            // 工具最多的那一个：动作、脚本、文件都归它。
            return SubAgentPermissionFace(canReadFiles: true, canWriteFiles: true,
                                          canActOnScreen: true, canRunScripts: true)
        case .text:
            // **一个工具都不给。** 方案 §一：它只产出文字。
            return SubAgentPermissionFace(canReadFiles: true, canWriteFiles: false,
                                          canActOnScreen: false, canRunScripts: false)
        }
    }

    /// 图形 agent 写文件时，还要求路径落在图形目录里。
    ///
    /// 方案 §六 P5：「图形 agent 尝试写非图形文件 → 被拒」。这条不能用白名单表达 ——
    /// 白名单是用户配的，而这是**角色自带的**限制：一个被派去画图的 agent，没有任何
    /// 理由去写别的地方，哪怕用户把整个桌面加进了白名单。
    static let graphicsRootPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Desktop/Clicky图形")
}

/// 两道闸门都过才放行：**先看这个 agent 有没有资格，再看这个路径允不允许。**
///
/// 顺序不能反。反过来的话，被拒的理由会变成「路径不在白名单里」—— 而真正的原因是
/// 「这个 agent 根本不该写文件那一条，模型会去改路径重试。方案 §02 那句「拒绝要说
/// 理由」在这里的具体含义就是：**说清楚是哪一道闸门拦的**。
nonisolated func fileAccessDecision(for role: SubAgentRole,
                                    path: String,
                                    operation: FileAccessOperation,
                                    policy: FileAccessPolicy) -> FileAccessDecision {
    let face = role.permissionFace
    switch operation {
    case .read where !face.canReadFiles:
        return FileAccessDecision(isAllowed: false,
                                  reason: "\(role.displayName) agent 没有读文件的权限。", matchedEntry: nil)
    case .write where !face.canWriteFiles:
        return FileAccessDecision(isAllowed: false,
                                  reason: "\(role.displayName) agent 不写文件 —— 它只产出文字。", matchedEntry: nil)
    default:
        break
    }
    // 图形 agent 的写：**它自己的产出目录是角色自带的授权，不走用户白名单。**
    //
    // 方案 §一 给它的权限面写的就是「仅图形相关」—— 那是角色属性，不是用户配置。
    // 如果把它接进白名单，而白名单默认是空的，那么**画图这个功能会在任何人配过
    // 白名单之前直接坏掉**，用户看到的只是「画图不工作了」，而他没动过任何跟画图
    // 有关的开关。功能藏在一个跟它无关的开关后面，是最难查的一类故障。
    if operation == .write, role == .graphics {
        let graphicsRoot = URL(fileURLWithPath: SubAgentRole.graphicsRootPath).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == graphicsRoot || target.hasPrefix(graphicsRoot + "/") else {
            // 出了这个目录就**直接拒**，不再落到白名单 —— 方案 §六 P5 要的是
            // 「图形 agent 写非图形文件被拒」，而不是「除非用户放行」。
            return FileAccessDecision(
                isAllowed: false,
                reason: "图形 agent 只能写 \(graphicsRoot) 里面的文件，而这条路径在外面：\(target)",
                matchedEntry: nil)
        }
        return FileAccessDecision(isAllowed: true, reason: "图形 agent 自己的产出目录",
                                  matchedEntry: FileAccessEntry(path: graphicsRoot, allowsWrite: true))
    }
    return policy.decide(path: path, operation: operation)
}

/// 主 agent 提示词里那段**目录** —— 第 2 步给主 agent 加的全部新增内容就这么多。
///
/// 它取代了原来躺在提示词里的 19,134 字符技能正文（图形 7,176 + 执行 11,958）。
nonisolated enum SubAgentCatalog {
    static let prompt = """
    你手边有三个助手，需要时用 [AGENT:名字] 叫它们；能自己回答的就自己回答。

    \(SubAgentRole.allCases.map(\.directoryLine).joined(separator: "\n\n"))

    叫了谁，就把这件事整个交给它 —— 不要自己再写一遍它该产出的标签。
    说不清归谁的时候自己答：答错只是一句不好听的话，派错会动手。
    """
}
