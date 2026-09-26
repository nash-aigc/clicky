//
//  CardChatMode.swift
//  Wanna
//
//  **每张卡片的「用哪种方式跟它对话」**：文本 / 图文 / 语音 / 视频。
//
//  用户 2026-09-26 的设计（原话）：
//
//      「主 agent 默认图文，即截屏加文字提示词，用户也可选择文本，即不截屏。
//        Claude Code 默认文本模式，用户也可选择图文模式进行截屏。选择文本或图文模式时，
//        使用对应 agent 的上下文、工具等全部能力；只有点击语音或视频模式时，才只关注
//        历史记录文本部分，不具备 agent 能力，不执行用户任务，只知上下文，其他什么都不关心。」
//
//  所以四个模式分成两族，**这条分界线是整个功能的核心**：
//
//    * **文本 / 图文** —— 走该 Agent 原本的管线：工具、MCP、sub agent、系统提示词全都在。
//      图文与文本的唯一差别就是**这一轮带不带截图**（所以它们其实就是输入框上方那颗
//      「屏幕」开关升格成的显式模式）。
//    * **语音 / 视频** —— 走 `VoiceChatController`（全双工 / 三段式、预设、音色、语速
//      原样保留），但**只把会话记录 + 角色提示词组装进系统提示词**，不执行任务、不调工具。
//
//  模式的落点：右侧内容列**分割线上方**（代码里那一带本来就叫这个名字，见
//  `VoiceChatSessionView` 里「分割线**上方**」那段注释），左对齐。
//
//  ## 为什么模式按卡片存、而不是全局一个
//
//  用户明确要求两张卡片的**默认值不同**（主循环图文、Claude Code 文本），而且他会在两条线
//  之间来回切。全局一个模式会让「切到 Claude Code 就顺手把主循环也改成文本」——
//  这不是他说的任何一件事。
//

import Foundation
import Combine

/// 一张卡片的聊天模式。
nonisolated enum CardChatMode: String, CaseIterable, Sendable, Equatable, Identifiable {
    /// 纯文字：不截屏，走 Agent 原本的管线。
    case text
    /// 图文：截屏 + 文字，走 Agent 原本的管线（**主循环的默认**）。
    case imageText
    /// 语音聊天：`VoiceChatController`，聊天类型 = 语音聊天。
    case voice
    /// 视频聊天：`VoiceChatController`，聊天类型 = 视频聊天。
    case video

    /// 两字，因为这一排要跟「角色」「音色」挤在侧栏那么宽的地方（用户：「标签宽度可缩小」）。
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .imageText: return "图文"
        case .voice: return "语音"
        case .video: return "视频"
        }
    }

    /// `ForEach` 要的 id。用 rawValue 而不是 `self` —— 模式的 rawValue 就是它落到
    /// `AppSettings.json` 里的那个字符串，两处同一个来源。
    var id: String { rawValue }

    var helpText: String {
        switch self {
        case .text:
            return "只发文字，不截屏。用这个 Agent 的全部能力（工具、MCP、子 agent）"
        case .imageText:
            return "带上屏幕截图提问，用这个 Agent 的全部能力（工具、MCP、子 agent）"
        case .voice:
            return "语音对话：只把这段会话记录和一个角色当上下文，不执行任务"
        case .video:
            return "视频对话：同上，但会开摄像头，能看现场"
        }
    }

    /// **这条分界线就是「有没有 agent 能力」**（用户那句话的唯一实现处）。
    var isVoiceLike: Bool {
        self == .voice || self == .video
    }

    /// 文本 / 图文 —— 走 Agent 自己的管线，工具与系统提示词都在。
    var usesAgentCapability: Bool { !isVoiceLike }

    /// **这个模式的模型吃不吃图。** 只有图文（截图）与视频（摄像头 / 屏幕）吃。
    ///
    /// 用户 2026-09-26 把理由说得很清楚：「（文本、语音）都是只能（保留文字），因为
    /// 他们的模型，不支持视频或文件等等」。所以它不只是"要不要截屏"，而是**这一条路上
    /// 到底能不能有图** —— 两个出口：
    ///
    ///   * 主循环那条管线（图文以外的模式一律不截屏，见
    ///     `CompanionManager.sendTranscriptToVisionChatWithScreenshot`）；
    ///   * 语音 / 视频组装历史时带不带图（`CardChatContextAssembler` 的
    ///     `includesScreenshots`）—— 语音那条**只带文字**，视频才带画面。
    ///
    /// 语音聊天那条"永远不开画面"的闸门是另一层（按聊天类型判的），两者方向一致、互不依赖。
    var carriesImages: Bool {
        self == .imageText || self == .video
    }

    /// 这一轮要不要截图。只有图文要 —— 文本「即不截屏」是用户的原话。
    var sendsScreenshot: Bool { self == .imageText }

    /// 语音 / 视频分别对应该子系统里的哪种聊天类型。
    ///
    /// 这个映射不是装饰：语音聊天那条**永远不开画面**的闸门就是按聊天类型判的
    ///（`VoiceCatalog.capability`），所以「语音模式不会偷偷开摄像头」是结构上成立的。
    var voiceChatChannel: VoiceChatChannel? {
        switch self {
        case .voice: return .voice
        case .video: return .video
        case .text, .imageText: return nil
        }
    }

    /// **没存过模式时用哪个** —— 用户逐字指定过：主循环默认图文（= 今天的行为，他察觉不到
    /// 变化），Claude Code 默认文本。
    static func defaultMode(for cardKind: CardKind) -> CardChatMode {
        switch cardKind {
        case .mainLoop: return .imageText
        case .claudeCode, .review: return .text
        }
    }
}

/// 「角色」按钮那份清单里的一项。
///
/// 只有两种来源，而且它们在两个模式族里**互斥**（用户：「用户选择图文聊天时即使用此角色。
/// 用户选择语音聊天或视频聊天时，角色列表变化，不再包含图文聊天角色，而是用户独立设计的角色」）。
nonisolated struct CardChatRoleChoice: Identifiable, Equatable, Sendable {

    enum Source: Equatable, Sendable {
        /// 该 Agent 自己的预设系统提示词 —— **不可改、不可删、置顶**（用户明确要求）。
        /// 它编辑的地方一直是「设置 → 对话与记忆 → 系统提示词」，不在这个清单里。
        case agentPreset
        /// 用户自己设计的角色（`VoiceChatRoleStore`），本质是一段提示词。
        case userRole
        /// 用户一个自己的角色都还没建时，兜底用语音子系统里那条内置默认角色 ——
        /// 否则语音 / 视频模式会因为「没有角色可用」而根本跑不起来。
        case builtInVoiceRole
    }

    let id: String
    let displayName: String
    /// 角色的提示词正文（组装提示词的第二部分）。`agentPreset` 时是 Agent 的系统提示词。
    let promptText: String
    let source: Source

    /// 能不能在这个清单里改名 / 改提示词。只有用户自己的角色能。
    var isEditableHere: Bool { source == .userRole }
}
