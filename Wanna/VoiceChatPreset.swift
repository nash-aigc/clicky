//
//  VoiceChatPreset.swift
//  Wanna
//
//  **预设**：语音聊天里「用哪几个模型、用哪个音色、要不要开画面」的**唯一**单位。
//
//  为什么要有预设（用户 2026-09-24 的原话）：
//
//  > 「它们之间的组合关系特别多，而且每一个模型的协议又非常不一样，让你拼接组合的话，
//  > 可能会组合出七八十种协议，这样就很乱套了。所以最好的方法是极简化：把能够验证的、
//  > 已经验证出来的、完整的、能够使用的不同模型组合作为一个预设来使用，
//  > **不允许用户自定义**。」
//
//  也就是说预设不是「省事的模板」，而是**一条质量边界**：清单里的每一条都必须是
//  真的能连上、真的按它写的模型和音色发声的组合。用户能改的只有名字和备注
//  （以及全双工下换模型）；模型组合写死在这里，界面不提供入口。
//
//  三个维度：**聊天类型**（视频 / 语音）× **模式**（全双工 / 三段式）× 预设。
//  前两个是用户的选择，第三个是那一次选择的全部内容。
//

import Foundation

// MARK: - 聊天类型

/// 视频聊天 / 语音聊天。
///
/// 它是一条**分流**（用户 2026-09-24：「这两个按钮的功能是分流，它们的选择会影响
/// 其他所有按钮的样式」）：
///
///   · **语音聊天**：全双工只出全双工语音模型（全模态模型不进语音聊天 —— 用户原话
///     「一定要严格限制」）；摄像头/屏幕**永远置灰**，预设里的设备勾选一律无效。
///   · **视频聊天**：全双工的预设是全模态模型；摄像头/屏幕可开（还要看模型吃不吃图）。
///
/// **唯一不受它影响的是语速**（用户明确要求：语速是全局的，不受任何分流控制）。
enum VoiceChatChannel: String, CaseIterable, Identifiable, Sendable, Codable {
    case video
    case voice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video: return "视频聊天"
        case .voice: return "语音聊天"
        }
    }

    /// 这个聊天类型下，画面（屏幕 / 摄像头）能不能开。
    ///
    /// 语音聊天是**永远不能**（不是"看模型"，是这条路本身不要画面）。
    var allowsVideoInputAtAll: Bool {
        self == .video
    }
}

// MARK: - 预设

/// 一个预设：一组**已验证**的模型组合 + 音色 + 设备默认值。
nonisolated struct VoiceChatPreset: Identifiable, Equatable, Sendable {

    /// 稳定的代码 id（`channel.engine.名字`）。**用户改不了** —— 收藏、当前选中
    /// 都按它记，所以它必须跨版本稳定。
    let id: String
    let channel: VoiceChatChannel
    /// `.duplexVoice` = 全双工（一个模型包办）；`.threeStage` = 三段式。
    let engine: VoiceChatEngine

    /// 默认预设：永远排第一，不可编辑、不可删除、不可移动（用户明确要求）。
    /// 每个 (channel, engine) 组合**有且只有一个**。
    let isDefaultPreset: Bool

    /// 标题与备注 —— 这两项是用户唯一能编辑的内容。
    var title: String
    var note: String

    // 三段式的三个位置。全双工时都是 nil（那时看 `duplexModelID`）。
    let recognitionModelID: String?
    let understandingModelID: String?
    let expressionModelID: String?

    /// 全双工时那一个模型（识别/理解/表达都是它）。三段式时 nil。
    let duplexModelID: String?

    /// 预设自带的音色。nil = 用该模型族的兜底音色。
    let preferredVoiceID: String?

    /// 选中这个预设时，屏幕 / 摄像头要不要默认打开。
    ///
    /// 只有**视频聊天 + 全双工全模态**这一类预设才有意义（用户：「预设可以同时打开
    /// 屏幕和摄像头，用户可以在设置页面的预设里勾选」）。语音聊天下这两个值一律被
    /// 忽略 —— `VoiceChatChannel.allowsVideoInputAtAll` 是硬闸。
    let opensScreenByDefault: Bool
    let opensCameraByDefault: Bool

    /// 这条预设的两个"位"是否都点得动。`false` = 界面上置灰并给出 `note` 里的原因。
    let isReady: Bool
}

/// 可编解码：用户新建的全双工预设要落盘（见 `VoiceChatPresetStore`）。
///
/// 写成 extension 而不是写在类型声明里 —— 后者会顶掉成员式 init，而这个文件的
/// 内置清单全靠它。（同 `VoiceChatRole` 的 `init(from:)` 那条注释里的规矩。）
extension VoiceChatPreset: Codable {}

// MARK: - 应用一条预设

extension VoiceChatPreset {

    /// 把这条预设写进角色：三个（或一个）模型 + 音色 + 设备默认值。
    ///
    /// **纯函数，故意放在这里**：控制器（用户点了预设）和设置页（角色编辑器里的草稿）
    /// 都要做这件事，而"应用一条预设"必须只有一处实现 —— 否则两边会漂成两套语义。
    /// 设置页那一侧尤其重要：它改的是**草稿**，所以这里只能返回值，不能自己落盘。
    ///
    /// 两条规则：
    /// · 设备默认值**只有视频聊天才写得进去**（`VoiceChatChannel.allowsVideoInputAtAll`
    ///   是硬闸）—— 语音聊天下写了也会被开关逻辑抹掉，不如不写。
    /// · 全双工只碰 `duplexModelID` 那一个字段；三段式只碰三个位置字段。互不越界。
    func applied(to role: VoiceChatRole, channel: VoiceChatChannel) -> VoiceChatRole {
        var updated = role

        switch engine {
        case .duplexVoice:
            if let duplexModelID {
                updated.duplexModelID = duplexModelID
            }
        case .threeStage, .omni:
            updated.recognitionModelID = recognitionModelID
            updated.understandingModelID = understandingModelID
            updated.expressionModelID = expressionModelID
        }

        if let preferredVoiceID, !preferredVoiceID.isEmpty {
            switch engine {
            case .duplexVoice:
                let effectiveModel = duplexModelID ?? VoiceCatalog.defaultDuplexModel
                if VoiceCatalog.isOmniRealtimeModel(effectiveModel) {
                    // **预设自带音色时也要校验，这一格是唯一的拦截点。**
                    //
                    // 2026-09-25：`video.duplex.omni38` 这一条预设写的是 `Ethan`，
                    // 而 3.8 那一代已经没有它 —— 原先这里是**无条件赋值**，于是
                    // `Ethan` 进了角色、进了 `session.update`，服务端回
                    // `<400> Voice 'Ethan' is not supported.`，`onFailure` 随即
                    // **挂断整场会话**，用户看到的是「连接之后会自动断开」。
                    updated.omniVoice = VoiceCatalog.isSelectable(
                        preferredVoiceID, for: .omni, model: effectiveModel
                    ) ? preferredVoiceID
                      : VoiceCatalog.fallbackVoice(for: .omni, model: effectiveModel)
                } else if VoiceCatalog.isSelectable(
                    preferredVoiceID, for: .duplexVoice, model: effectiveModel
                ) {
                    updated.duplexVoice = preferredVoiceID
                } else {
                    updated.duplexVoice = VoiceCatalog.fallbackVoice(
                        for: .duplexVoice, model: effectiveModel
                    )
                }
            case .threeStage, .omni:
                updated.ttsVoice = preferredVoiceID
            }
        } else if engine == .duplexVoice {
            // **预设不带音色时，沿用角色里那个之前，必须先看它对不对得上这一代的模型。**
            //
            // 这是 2026-09-25 那次「全双工连不上」的**上游写入者**：音色字段是全家族
            // **共用的一格**，而预设只在自己携带音色时才覆盖它。于是从「全双工 3.1 Plus」
            // （自带 `longanqian_v3.1`）切回「全双工 3.0 Flash」（不带音色）时，
            // `duplexModelID` 换了、**音色却留在 3.1 那一代**，整条 `session.update`
            // 随后被服务端拒绝，界面立刻挂断 —— 用户看到的是"刘海两侧什么都不显示"。
            //
            // 能力层现在会在握手时兜住（`isSelectable` 判到异代就换兜底 + 记说明），
            // 但那是**事后纠正**：这里把不该活下来的值直接换掉，那一格从一开始就是对的。
            //
            // **校验的是"这个模型真正在用的那一格"。** 全模态模型用的是 `omniVoice`、
            // 全双工语音用的是 `duplexVoice` —— 原先这里只查后者，于是全模态那一路
            // 实际上没有校验（默认模型 3.8 用的就是 `omniVoice`）。
            let effectiveModel = duplexModelID ?? VoiceCatalog.defaultDuplexModel
            if VoiceCatalog.isOmniRealtimeModel(effectiveModel) {
                if !VoiceCatalog.isSelectable(updated.omniVoice, for: .omni, model: effectiveModel) {
                    updated.omniVoice = VoiceCatalog.fallbackVoice(for: .omni, model: effectiveModel)
                }
            } else if !VoiceCatalog.isSelectable(
                updated.duplexVoice, for: .duplexVoice, model: effectiveModel
            ) {
                updated.duplexVoice = VoiceCatalog.fallbackVoice(
                    for: .duplexVoice, model: effectiveModel
                )
            }
        }

        let allowsVideo = channel.allowsVideoInputAtAll
        updated.autoScreenEnabled = allowsVideo && opensScreenByDefault
        updated.autoCameraEnabled = allowsVideo && opensCameraByDefault
        return updated
    }
}

// MARK: - 内置清单

extension VoiceChatPreset {

    /// 代码内置的全部预设。**这是唯一的一份清单**：界面按 (channel, engine) 过滤，
    /// 用户不能增加、不能删除；能改的只有 `title` / `note`（存在
    /// `VoiceChatPresetStore`），全双工下还能换模型（同样是覆盖层）。
    static let builtIn: [VoiceChatPreset] = videoChatPresets + voiceChatPresets

    static func presets(for channel: VoiceChatChannel, engine: VoiceChatEngine) -> [VoiceChatPreset] {
        builtIn.filter { $0.channel == channel && $0.engine == engine }
    }

    static func preset(withID id: String) -> VoiceChatPreset? {
        builtIn.first { $0.id == id }
    }

    // MARK: 视频聊天

    private static let videoChatPresets: [VoiceChatPreset] = [
        // 全双工：三个全模态模型，每个一条预设（一个模型包办识别/理解/表达）。
        VoiceChatPreset(
            id: "video.duplex.omni38",
            channel: .video,
            engine: .duplexVoice,
            isDefaultPreset: true,
            title: "全模态 3.8 Flash",
            note: "全模态实时（识别、理解、表达一体），支持文字、图像、语音输入输出。默认开屏幕 + 摄像头。",
            recognitionModelID: nil,
            understandingModelID: nil,
            expressionModelID: nil,
            duplexModelID: "qwen3.8-omni-flash-realtime",
            // **官方 3.8 那一节的默认音色是 `Tina`，不是 `Ethan`** —— `Ethan` 属于
            // 3.5 那一代，服务端对 3.8 的回复原文是
            // `<400> InternalError.Algo.InvalidParameter: Voice 'Ethan' is not supported.`，
            // 而 `onFailure` 会**挂断整场会话**，用户看到的是「连接之后会自动断开」。
            preferredVoiceID: "Tina",
            opensScreenByDefault: true,
            opensCameraByDefault: true,
            isReady: true
        ),
        VoiceChatPreset(
            id: "video.duplex.omni35flash",
            channel: .video,
            engine: .duplexVoice,
            isDefaultPreset: false,
            title: "全模态 3.5 Flash",
            note: "上一代全模态实时，同样能理解画面。价格更贵（图文入 3.3 / 音频入 27 / 文本出 20 / 音频出 107，元每百万）。",
            recognitionModelID: nil,
            understandingModelID: nil,
            expressionModelID: nil,
            duplexModelID: "qwen3.5-omni-flash-realtime-2026-03-15",
            preferredVoiceID: nil,
            opensScreenByDefault: true,
            opensCameraByDefault: true,
            isReady: true
        ),
        VoiceChatPreset(
            id: "video.duplex.omni35plus",
            channel: .video,
            engine: .duplexVoice,
            isDefaultPreset: false,
            title: "全模态 3.5 Plus",
            note: "上一代全模态旗舰（图文入 10 / 音频入 80 / 文本出 60 / 音频出 300）。",
            recognitionModelID: nil,
            understandingModelID: nil,
            expressionModelID: nil,
            duplexModelID: "qwen3.5-omni-plus-realtime-2026-03-15",
            preferredVoiceID: nil,
            opensScreenByDefault: true,
            opensCameraByDefault: true,
            isReady: true
        ),

        // 三段式：**只有一条**（用户 2026-09-24：「视频聊天使用三段式模式时，
        // 就保留刚才那一个预设即可」）。
        VoiceChatPreset(
            id: "video.threeStage.standard",
            channel: .video,
            engine: .threeStage,
            isDefaultPreset: true,
            title: "标准三段式",
            note: "识别用 3.1 实时语音模型、理解用 DeepSeek Flash（能吃图文）、表达用 3.1 TTS。默认开屏幕 + 摄像头。",
            recognitionModelID: "qwen-audio-3.1-realtime-plus",
            understandingModelID: "deepseek-flash",
            expressionModelID: "qwen-audio-3.1-tts-flash",
            duplexModelID: nil,
            preferredVoiceID: nil,
            opensScreenByDefault: true,
            opensCameraByDefault: true,
            isReady: true
        ),
    ]

    // MARK: 语音聊天

    private static let voiceChatPresets: [VoiceChatPreset] = [
        // 全双工：**只有全双工语音模型**（用户 2026-09-24 确认：「只显示全双工语音模型
        // （严格限制）」—— 全模态模型不进语音聊天）。
        VoiceChatPreset(
            id: "voice.duplex.3_0flash",
            channel: .voice,
            engine: .duplexVoice,
            isDefaultPreset: true,
            title: "全双工 3.0 Flash",
            note: "全双工语音模型（识别、理解、表达一体），只能语音与文字输入输出。最便宜、最流畅。",
            recognitionModelID: nil,
            understandingModelID: nil,
            expressionModelID: nil,
            duplexModelID: "qwen-audio-3.0-realtime-flash",
            preferredVoiceID: nil,
            opensScreenByDefault: false,
            opensCameraByDefault: false,
            isReady: true
        ),
        VoiceChatPreset(
            id: "voice.duplex.3_1plus",
            channel: .voice,
            engine: .duplexVoice,
            isDefaultPreset: false,
            title: "全双工 3.1 Plus",
            note: "更强一代的全双工语音模型，音色表更大（13 个）。价格也更高（音频入 40 / 文本出 40 / 音频出 150）。",
            recognitionModelID: nil,
            understandingModelID: nil,
            expressionModelID: nil,
            duplexModelID: "qwen-audio-3.1-realtime-plus",
            preferredVoiceID: "longanqian_v3.1",
            opensScreenByDefault: false,
            opensCameraByDefault: false,
            isReady: true
        ),

        // 三段式预设一：与视频那条**同一组模型**，区别是设备关、且不可勾
        // （用户：「预设保留，但不会自动勾选屏幕和摄像头，也不可以被勾选」）。
        VoiceChatPreset(
            id: "voice.threeStage.standard",
            channel: .voice,
            engine: .threeStage,
            isDefaultPreset: true,
            title: "标准三段式",
            note: "识别 3.1 实时语音、理解 DeepSeek Flash、表达 3.1 TTS。语音聊天下不开画面。",
            recognitionModelID: "qwen-audio-3.1-realtime-plus",
            understandingModelID: "deepseek-flash",
            expressionModelID: "qwen-audio-3.1-tts-flash",
            duplexModelID: nil,
            preferredVoiceID: nil,
            opensScreenByDefault: false,
            opensCameraByDefault: false,
            isReady: true
        ),

        // **管线已接**（2026-09-24）：三段式的「理解」现在按预设分派 ——
        // 实时模型走 `RealtimeTextUnderstandingClient`（WebSocket：喂 `input_text`、
        // 收 `response.text.delta`），其余走 HTTP 图文。协议逐条照官方文档，
        // 模型能力实测首字 **0.48 秒**（`开发经验/09-实测数据.md` 第十节）。
        VoiceChatPreset(
            id: "voice.threeStage.fastText",
            channel: .voice,
            engine: .threeStage,
            isDefaultPreset: false,
            title: "快问快答（实时模型出文字）",
            note: "识别与理解都用 3.1 实时语音模型直接出文字（实测首字 0.48 秒），表达用 3.1 TTS，音色可任选（含克隆）。",
            recognitionModelID: "qwen-audio-3.1-realtime-plus",
            understandingModelID: "qwen-audio-3.1-realtime-plus",
            expressionModelID: "qwen-audio-3.1-tts-flash",
            duplexModelID: nil,
            preferredVoiceID: nil,
            opensScreenByDefault: false,
            opensCameraByDefault: false,
            isReady: true
        ),
    ]
}
