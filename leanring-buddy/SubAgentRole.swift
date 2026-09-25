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
