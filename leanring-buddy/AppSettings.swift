//
//  AppSettings.swift
//  leanring-buddy
//
//  The user-facing app settings — every switch and slider the settings window's
//  通用 / 对话与记忆 / 听 / 说 / 看与截图 / 操作 / 快捷键 pages edit, as one value type.
//
//  Pure data + clamping, no I/O: persistence lives in `AppSettingsStore`, which
//  mirrors `ModelConfigurationStore`. Every type here is `nonisolated` for the
//  same reason the types in `ModelConfiguration.swift` are — the target builds
//  with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated type
//  would silently become main-actor-isolated and a settings read from a
//  background-safe context would fail to compile.
//
//  Decoding is deliberately tolerant: every field falls back to its default when
//  missing, so a settings file written by an older build still loads after a new
//  field is added (the same `Bool?`-style reasoning that keeps
//  `ProviderProfile.visionReasoningEnabled` decodable).
//

import Foundation

/// How long the model is told its spoken answers should be.
///
/// This is prompt text, not a parameter: length is controlled by the sentence in
/// the system prompt, so the setting rewrites that sentence.
nonisolated enum AnswerLengthStyle: String, Codable, CaseIterable, Sendable {
    case oneOrTwoSentences
    case threeToFiveSentences
    case detailed

    var displayName: String {
        switch self {
        case .oneOrTwoSentences: return "一两句"
        case .threeToFiveSentences: return "三到五句"
        case .detailed: return "详细"
        }
    }

    /// The sentence spliced into the vision system prompt in place of the old
    /// hardcoded length instruction.
    var promptSentence: String {
        switch self {
        case .oneOrTwoSentences: return "请用一到两句话回答。"
        case .threeToFiveSentences: return "请用三到五句话回答。"
        case .detailed: return "请尽可能详细地回答，但不要空谈。"
        }
    }
}

/// The visual style of the card that renders the assistant's reply in the
/// conversation view. Values, borders and default follow the user-supplied
/// reference spec (「clip 卡片样式」): blue card #0B57D0 with a 30% white border,
/// black card #000 with a 16% white border, paper card #F7F2E7 with an 18%
/// black border and ink text — blue is the default.
nonisolated enum AnswerCardStyle: String, Codable, CaseIterable, Sendable {
    case blue
    case black
    case paper

    var displayName: String {
        switch self {
        case .blue: return "蓝色"
        case .black: return "黑色"
        case .paper: return "宣纸"
        }
    }
}

/// How the notch sheet opens.
///
/// 用户 2026-09-23：「参考我提供的 HTML 页面，分析它的展开方式和动画效果。它的动画
/// 非常流畅，是从中心弹开的效果；当前项目是从上到下逐个展开显示。我希望增加一个弹开
/// 的效果。」随后定了这一页的形状：「把设置页面的"卡片样式"页面调整为"交互样式"，
/// 里面包含两个选项：卡片样式 / 窗口样式……同时把我刚才提供的中心缩放样式也作为
/// 一个选项，并将中心缩放样式设为默认样式。」
///
/// 两个选项都是**同一套机制**（窗口一次 `setFrame` 到最终位置 + 内容层上一个 Core
/// Animation），所以加这一个不引入任何逐帧主线程工作 —— 第一版把中心缩放做成了逐帧
/// `NSWindow.setFrame`，用户当场否掉（「比之前还要卡顿…现在是从左到右展开」）。参考
/// 页面里十二个窗口动画没有一个改元素尺寸，全是 `transform` / `clip-path`，这就是原因。
nonisolated enum WindowExpansionStyle: String, Codable, CaseIterable, Sendable {
    /// 01 中心缩放（2026-09-23 重设计）：内容层被一个**从刘海那一个点向外长开的
    /// 遮罩**揭开——顶边中点全程钉在刘海底边，左上角向左、右上角向右、底边向下，
    /// 三个方向同一时刻同一节奏。旧的 transform 顶边锚定实现（`centerPop`）被整体
    /// 删除：它的锚点依赖拼接顺序和翻转坐标系两个都不报错的约定，修了两轮用户实测
    /// 仍与边缘缩放无异。rawValue 换成 `notchBloom`；老配置文件里的 `"centerPop"`
    /// 由解码处迁移到这个 case（见 `AppSettings.init(from:)`）。默认（用户指定）。
    case notchBloom
    /// 边缘缩放：内容层从 8% 缩放弹到 100%，锚在面板**底边**的中点，所以面板是
    /// 从下往上长开的。这是先前当作中心缩放实现时实际画出来的效果——补偿平移算在
    /// 了错的坐标系里。用户看到后觉得这个效果本身可以留，于是保留为独立选项。
    case edgeScale
    /// 02 幕布垂落：内容层被一个从顶边向下长开的遮罩揭开，宽度从第一帧就是最终值。
    case curtain

    var displayName: String {
        switch self {
        case .notchBloom: return "中心缩放"
        case .edgeScale: return "边缘缩放"
        case .curtain: return "幕布垂落"
        }
    }

    var explanation: String {
        switch self {
        case .notchBloom:
            return "面板从刘海那一个点同时向下、向左、向右展开。"
        case .edgeScale:
            return "面板从底部向上弹开、放大到整块。"
        case .curtain:
            return "面板宽度先到位，内容从上往下垂落展开。"
        }
    }
}

/// 输入框里哪个按键把写好的字发出去 —— 交互页的「发送方式」一行。
///
/// 用户 2026-09-23：「增加一个选项，即输入方式，或叫发送方法：1. 按 Enter 键发送，
/// 这是默认方法。2. 按 Command 加 Enter 发送。提供两种发送方法，供用户根据个人习惯
/// 选择」。
///
/// 两个值各自对应一种真实的键盘习惯：`.returnKey` 适合一行一句话的短提问，回车即发；
/// `.commandReturn` 适合经常要写好几段、写的时候还得空行的人 —— 回车留给换行，
/// 想发的时候顺手带一个 Command。两种都保留**另一个键仍然换行**（回车发送时
/// Shift+回车换行，Command+回车发送时回车换行），所以哪一种都能写出多行的输入。
nonisolated enum ComposerSendShortcut: String, Codable, CaseIterable, Sendable {
    /// 按 Enter 发送（默认）。换行是 Shift + Enter。
    case returnKey
    /// 按 Command + Enter 发送。换行就是裸的 Enter。
    case commandReturn

    var displayName: String {
        switch self {
        case .returnKey: return "按 Enter 发送"
        case .commandReturn: return "按 Command + Enter 发送"
        }
    }

    var explanation: String {
        switch self {
        case .returnKey:
            return "在输入框里按回车就把内容发出去，换行按 Shift + 回车。"
        case .commandReturn:
            return "回车用来换行，按 Command + 回车才发送 —— 适合经常要写好几段的人。"
        }
    }
}

/// Which language the streaming transcription is told to expect.
nonisolated enum TranscriptionLanguage: String, Codable, CaseIterable, Sendable {
    case chinese
    case english
    case mixed
    case followSystem

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        case .mixed: return "中英混合"
        case .followSystem: return "自动跟随系统"
        }
    }

    /// The value sent as `input_audio_transcription.language` in `session.update`.
    ///
    /// `mixed` returns `nil`, which means the field is omitted from the request
    /// and the service auto-detects. `followSystem` reads the user's preferred
    /// app language rather than asking the user to set the same thing twice.
    var languageCodeForRequest: String? {
        switch self {
        case .chinese: return "zh"
        case .english: return "en"
        case .mixed: return nil
        case .followSystem:
            let preferredLanguage = Locale.preferredLanguages.first ?? "zh"
            return preferredLanguage.hasPrefix("zh") ? "zh" : "en"
        }
    }
}

/// When the blue cursor companion is on screen.
///
/// The companion used to follow the mouse permanently with no way to hide it:
/// the only switch that could have stopped it (`isClickyCursorEnabled`) had its
/// UI commented out, so the "fade in on hotkey, fade out when idle" machinery
/// below it never ran even once. This is that switch, spelled out as three
/// honest choices instead of a hidden boolean.
nonisolated enum CursorPresenceMode: String, Codable, CaseIterable, Sendable {
    /// The companion is always on screen. This is what the app did before the
    /// setting existed, which is why it is the default — an upgrade changes
    /// nothing until the user asks for it.
    case alwaysVisible
    /// The companion fades in on the push-to-talk hotkey and fades out once the
    /// answer has been spoken, pointing is finished, and the bubble is gone.
    case duringConversation
    /// Only while the companion is actually flying to and pointing at something.
    /// Between questions the screen has no cursor at all; the answer bubble still
    /// appears next to the mouse, because a bubble does not need a cursor to be
    /// drawn under it.
    case onlyWhenPointing

    /// Kept to four characters or fewer: these are rendered as side-by-side
    /// segmented buttons, and a longer label wraps onto two lines and then
    /// overflows the settings card. The row's description carries the meaning.
    var displayName: String {
        switch self {
        case .alwaysVisible: return "一直显示"
        case .duringConversation: return "对话时"
        case .onlyWhenPointing: return "指位置时"
        }
    }

    /// Whether the companion stays on screen with nothing happening. Only the
    /// first mode does.
    var showsBuddyWhileIdle: Bool {
        self == .alwaysVisible
    }

    /// Whether the "fade in on the hotkey, schedule a fade-out when the
    /// interaction ends" machinery applies. It is the exact inverse of
    /// `showsBuddyWhileIdle`, but named separately because the schedule and the
    /// idle state are different questions at the two call sites that ask.
    var hidesWhenIdle: Bool {
        !showsBuddyWhileIdle
    }
}

/// What the blue cursor is drawn as.
nonisolated enum CursorShapeStyle: String, Codable, CaseIterable, Sendable {
    /// The original filled triangle, pointing up-right at the mouse.
    case triangle
    /// A macOS-style pointer outline, for users who want the companion to read
    /// as a cursor rather than as a separate character.
    case arrow

    var displayName: String {
        switch self {
        case .triangle: return "三角箭头"
        case .arrow: return "标准指针"
        }
    }

    /// The shape's frame. The pointer is drawn larger because its outline is
    /// thinner than the triangle's filled body, so it needs the extra size to
    /// carry the same visual weight.
    var frameSizeInPoints: CGFloat {
        switch self {
        case .triangle: return 16
        case .arrow: return 20
        }
    }
}

/// How far the companion sits from the mouse pointer.
///
/// The companion used to be pinned 35 points right and 25 below the mouse at
/// all times, which reads as a tail that never stops trailing you. This is that
/// offset, made adjustable.
nonisolated enum CursorFollowDistance: String, Codable, CaseIterable, Sendable {
    /// Directly on top of the mouse.
    case overlapping
    /// Nudged just clear of the mouse's own pointer.
    case closeBeside
    /// Down and to the right, the way the app has always drawn it.
    case farBehind

    /// Short for the same reason as `CursorPresenceMode.displayName` — the row's
    /// description spells out what each one does.
    var displayName: String {
        switch self {
        case .overlapping: return "重叠"
        case .closeBeside: return "紧贴"
        case .farBehind: return "稍远"
        }
    }

    /// Where the companion's frame centre sits relative to the mouse, in screen
    /// points. Added to the mouse position, so these are right-and-down offsets.
    var offsetFromMouse: CGSize {
        switch self {
        case .overlapping: return CGSize(width: 0, height: 0)
        case .closeBeside: return CGSize(width: 6, height: 6)
        case .farBehind: return CGSize(width: 35, height: 25)
        }
    }
}

/// How the companion delivers a `[TYPE:…]`'s text into whatever app has focus.
///
/// Typing posts every character as its own key event, which lands in any app but
/// cannot carry a line break — editors only answer a real Return press, so
/// multi-line text has to be split and joined with Return presses. Pasting puts
/// the whole text on the clipboard and presses cmd+v, which carries newlines in
/// one step and is much faster for long text — at the cost of borrowing the
/// user's clipboard for a moment. Typing stays the default because it never
/// touches anything outside the focused text field.
nonisolated enum TextEntryMethod: String, Codable, CaseIterable, Sendable {
    /// One key event per character, line breaks as real Return presses.
    case typeCharacters
    /// The whole text on the clipboard, delivered with one cmd+v.
    case pasteClipboard

    var displayName: String {
        switch self {
        case .typeCharacters: return "打字"
        case .pasteClipboard: return "粘贴"
        }
    }
}

/// A keyboard shortcut as the user actually pressed it: which modifier keys
/// were held, plus the one ordinary key that was struck (nil for a
/// modifier-only combo like ctrl + option).
///
/// `modifierFlagsRawValue` is an `NSEvent.ModifierFlags` raw value filtered
/// down to the five modifiers a shortcut can meaningfully use (control,
/// option, shift, command, function) — capsLock and the rest are noise a
/// stray keypress could otherwise smuggle in.
nonisolated struct RecordedKeyboardShortcut: Codable, Equatable, Sendable {
    var modifierFlagsRawValue: UInt
    var keyCode: UInt16?
}

/// How the push-to-talk shortcut behaves: hold-to-talk (press, speak, release
/// to send) or double-tap (press to start recording, press again to finalize
/// and send) — the latter for long utterances that are uncomfortable to hold
/// a key through.
nonisolated enum ShortcutTriggerMode: String, Codable, CaseIterable, Sendable {
    case holdToTalk
    case doubleTapToTalk

    var displayName: String {
        switch self {
        case .holdToTalk: return "按住说话"
        case .doubleTapToTalk: return "点两下说话"
        }
    }
}

/// How a reply is turned into speech — the 「播报方式」 row on the 说（播报） page.
///
/// Ported from the voice-web reference project's `tts_speak_mode` (sentence /
/// whole). The measured case for the default is written up in that project's
/// 实现方案/11 doc: synthesis runs ~20× faster than playback, so speaking the
/// first ~15-character segment while the rest is still being generated gets
/// the first word out at the floor of what the pipeline allows — waiting for
/// the whole reply first (whole) costs a 300-character answer about 17 extra
/// seconds of silence, in exchange for more连贯 intonation across the answer.
nonisolated enum SpeechSpeakMode: String, Codable, CaseIterable, Sendable {
    /// 逐句快答 (default): speak sentence-sized segments as the reply streams
    /// in, each merged to at least 15 characters and cut at 60 when the model
    /// writes none. The first segment is audible while the model is still
    /// writing the rest of the answer.
    case sentenceFastReply
    /// 整段合成: wait for the model to finish the whole reply, then synthesize
    /// and play it. Slower to first word, more even intonation.
    case wholeReply

    var displayName: String {
        switch self {
        case .sentenceFastReply: return "逐句快答"
        case .wholeReply: return "整段合成"
        }
    }

    var descriptionText: String {
        switch self {
        case .sentenceFastReply: return "边生成边合成边播，第一声最快。"
        case .wholeReply: return "等全文生成完再合成再播，语调更连贯，长回答等得久。"
        }
    }
}

/// How much authority a spawned agent subprocess carries, expressed as the
/// claude CLI permission arguments it is launched with.
///
/// The three levels mirror the reference design's approval policy (plan /
/// auto-edit / full). The vocabulary — which flags mean what on the CLI — is
/// held only here, so the process bridge never re-derives it.
nonisolated enum AgentPermissionMode: String, Codable, CaseIterable, Sendable {
    /// 只读规划: the agent may read and think but changes nothing. The safest
    /// level, for "what would you do" questions.
    case readOnlyPlan
    /// 自动改文件 (default): file edits inside the project folder are accepted
    /// automatically and the common working tools are pre-approved, so a
    /// headless agent (nobody to answer approval prompts) keeps working instead
    /// of stalling on every command.
    case autoEdit
    /// 完全授权: every tool auto-approved, including anything destructive. The
    /// settings row's description states the risk outright.
    case fullAccess

    var displayName: String {
        switch self {
        case .readOnlyPlan: return "只读规划"
        case .autoEdit: return "自动改文件"
        case .fullAccess: return "完全授权"
        }
    }

    var descriptionText: String {
        switch self {
        case .readOnlyPlan: return "Agent 只能看和想，不改任何文件。"
        case .autoEdit: return "自动接受项目内的文件修改，常用工具直接放行。"
        case .fullAccess: return "所有操作免确认，包括删除和覆盖——请只在可信任的文件夹上使用。"
        }
    }

    /// The permission arguments appended to the claude launch command.
    var cliArguments: [String] {
        switch self {
        case .readOnlyPlan:
            return ["--permission-mode", "plan"]
        case .autoEdit:
            // acceptEdits alone would still stall on tool approval prompts, and a
            // headless `-p` run has nobody to answer them — the pre-approved set
            // is what makes the default level actually usable unattended.
            return ["--permission-mode", "acceptEdits",
                    "--allowedTools", "Read Edit Write Glob Grep Bash WebSearch WebFetch Task NotebookEdit"]
        case .fullAccess:
            return ["--dangerously-skip-permissions"]
        }
    }
}

nonisolated struct AppSettings: Codable, Sendable, Equatable {

    // MARK: - 通用 · 启动

    /// Register/unregister the app as a macOS login item. The app used to force
    /// this on with no switch at all.
    var launchesAtLogin: Bool = true

    /// Open the menu bar panel every launch, not just when permissions are
    /// missing. Off keeps the old behavior (panel only when something needs fixing).
    var opensPanelOnLaunch: Bool = false

    // MARK: - 通用 · 回答的呈现

    /// Stream the answer's text into a bubble next to the cursor while it is
    /// being generated. The app previously never showed text at all.
    var showsResponseText: Bool = false

    /// Show the in-flight transcription while the user is still holding the key.
    var showsLiveTranscript: Bool = false

    /// How long the answer bubble stays up *after* the spoken answer finishes
    /// playing, before it is cleared.
    ///
    /// The reading time itself is not a duration the user picks — the text stays
    /// for as long as the voice is still going, however long that is. This is
    /// only the tail after the voice stops, so a short answer and a long one both
    /// leave the same amount of time to glance back.
    var answerBubbleLingerSeconds: Double = 3.0

    // MARK: - 通用 · 蓝色光标

    /// When the blue cursor companion is on screen.
    var cursorPresenceMode: CursorPresenceMode = .alwaysVisible

    /// What the companion is drawn as.
    var cursorShapeStyle: CursorShapeStyle = .triangle

    /// How far the companion sits from the mouse pointer.
    var cursorFollowDistance: CursorFollowDistance = .farBehind

    /// How long the companion lingers after the interaction ends before fading
    /// out. Only the two modes that hide when idle have anything to schedule, so
    /// the settings row is disabled under 「一直显示」. Was hardcoded to 1 second.
    var transientCursorHideDelaySeconds: Double = 1.0

    // MARK: - 对话与记忆

    /// How many recent question/answer rounds are sent with each request.
    /// Older rounds are dropped. Was hardcoded to 10.
    var rememberedConversationRounds: Int = 10

    /// Write conversation history to disk so it survives a relaunch. Off keeps
    /// history purely in memory. The history file is plaintext — the settings
    /// description must keep saying so.
    var persistsConversationHistory: Bool = false

    /// Before dropping the oldest rounds, summarize them into a compact note and
    /// keep that note in the prompt, so long conversations don't lose their start.
    var autoCompressesHistory: Bool = false

    /// Store each round's cursor-screen screenshot and send it back with the
    /// history, so "刚才那个按钮" can be answered. Substantially larger payloads.
    var includesScreenshotsInHistory: Bool = false

    /// Prompt-side answer length control.
    var answerLengthStyle: AnswerLengthStyle = .oneOrTwoSentences

    /// The card theme that renders the assistant's reply in the conversation
    /// view. 黑 is the default since 2026-09-23 — the user asked for the
    /// bubbles to be dark and to match the panel's ground (「气泡调成暗色…
    /// 主题应该跟背景颜色一致」), so the blue reference default became the
    /// option rather than the starting point. 蓝 and 宣纸 are still there for
    /// whoever wants them, in 设置 → 交互样式 (the page was called 卡片样式
    /// until 2026-09-23, when the window style joined it).
    var answerCardStyle: AnswerCardStyle = .black

    /// How the notch sheet opens — 中心缩放 (`notchBloom`, a mask expanding out
    /// of the notch's own point: down, left and right at once), 边缘缩放 (a
    /// scale about the bottom edge) or 幕布垂落 (the curtain reveal).
    /// `.notchBloom` is the default — the user asked for 中心缩放 as the default
    /// (「并将中心缩放样式设为默认样式」, 2026-09-23) and the 2026-09-23 redesign
    /// replaced that style's implementation, not its name or default status.
    ///
    /// Lives beside `answerCardStyle` rather than in its own section because
    /// the two are one settings page (交互) — see `WindowExpansionStyle`
    /// for what each value means and why none of them is a per-frame window
    /// resize.
    var windowExpansionStyle: WindowExpansionStyle = .notchBloom

    /// 输入框里哪个键发送 —— 交互页的「发送方式」。两个内容页的输入框
    /// （`MessageComposerField`）都读它，所以改完立刻生效，不用重启。
    var composerSendShortcut: ComposerSendShortcut = .returnKey

    /// Free-form instructions appended verbatim to the system prompt.
    var extraSystemPromptInstructions: String = ""

    /// The whole base system prompt, when the user has replaced it.
    ///
    /// `nil` means "follow the built-in", which is not the same as "empty": a build
    /// that improves the default prompt has to reach a user who never opened the
    /// editor. Storing the built-in text as this property's default value instead
    /// would freeze every existing install on whatever wording happened to ship the
    /// day it first ran, and the only way out would be to ask the user to rewrite it
    /// by hand. The length line and 补充指令 still append on top of this, so the
    /// editor stays about the base prompt and those two settings keep working.
    var customSystemPrompt: String?

    // MARK: - 听（语音识别）

    var transcriptionLanguage: TranscriptionLanguage = .chinese

    /// One term per line, appended to the built-in keyterm list as a
    /// recognition bias for proper nouns.
    var extraTranscriptionKeyterms: String = ""

    /// How long the transcription session waits for the server's final transcript
    /// after key-up before falling back to the best interim text. Was hardcoded
    /// to 1.4 seconds.
    var finalTranscriptGracePeriodSeconds: Double = 1.4

    /// Server-side VAD: the service auto-commits when the user pauses, so short
    /// utterances don't need the key held to the very end. Off keeps the manual
    /// commit mode the pipeline was built around.
    var usesAutomaticSpeechSegmentation: Bool = false

    /// 「回答时持续监听」: while the answer is being spoken (and for the window
    /// that follows it), keep the microphone listening so a follow-up question
    /// needs no shortcut at all — speaking up interrupts the TTS and the
    /// finished utterance is sent as a brand-new question.
    var continuousListeningEnabled: Bool = false

    /// 「持续监听时间」: how long, in seconds, the microphone stays open after the
    /// answer's playback starts, so a follow-up can be asked hands-free.
    ///
    /// `0` is a real value, not a floor (2026-09-24, the user's request): the
    /// microphone closes when the answer finishes and the only way in is the talk
    /// shortcut. That is a different thing from releasing the engine — the engine
    /// is held for `audioEngineIdleReleaseMinutes` either way, so a press after
    /// minutes of silence still gets a warm, fast reply. The two settings answer
    /// "is the microphone open?" and "is the engine warm?", and the user can mix
    /// them however they like.
    ///
    /// Clamped to 0...120.
    var continuousListeningWindowSeconds: Int = 30

    /// 「静音多久自动发送」: during the continuous-listening window, how long
    /// the microphone must stay quiet after the user stops speaking before the
    /// utterance is auto-sent as a new question. Human thinking pauses are
    /// unbounded (the user's framing, 2026-09-23), so the shortcut press is the
    /// reliable send marker and this wait is only the auto path — surfaced in
    /// the 听 page so it can be pushed out of the way of the user's own pauses.
    /// Clamped to 1...5.
    var continuousListeningSilenceSendSeconds: Double = 2.0

    /// 「引擎保持时间」: how long the shared audio engine stays up after the last
    /// activity before it is released.
    ///
    /// The engine's bring-up is not cheap — enabling voice processing
    /// reconfigures the whole IO (44.1 kHz / 1 ch → 48 kHz / 9 ch, measured in
    /// `VoicePlaybackEngine`) and takes ~2 s, of which the first `start()`
    /// usually fails and the rebuild succeeds in ~90 ms. That cost is meant to
    /// be paid ONCE; releasing the engine between replies made every new
    /// question pay it again, which the user measured as ~3 s from the reply
    /// card appearing to the first sound, against ~1.1 s on a follow-up inside
    /// an open listening window.
    ///
    /// The price of holding it is the one the second engine used to exist to
    /// avoid: while voice processing is enabled this app is in macOS's
    /// "communication app" class and every other application's audio is ducked,
    /// at the mildest level macOS offers. So the hold is a trade the user asked
    /// for explicitly (2026-09-24) and it is theirs to set:
    ///
    ///   · `1` / `3` / `5` minutes — release that long after the last activity;
    ///   · `0` — 「永久」: never release on a timer. Warm and instantly
    ///     responsive at all times; other audio stays ducked until the release
    ///     shortcut is pressed.
    ///
    /// Reset by any activity: a press, a recording, a barge-in, a transcript, a
    /// reply starting. Clamped to 0...60.
    /// 「弹出速度」: how fast the notch sheet's expansion plays, as a multiplier
    /// applied to every style's duration (and to the content entrance delays,
    /// which are fractions of the same window). `1.0` is the reference page's
    /// own timing; `2.0` — the default, the user's choice 2026-09-24 — is twice
    /// as fast. Clamped to 1...4: below 1 the panel would feel sluggish again,
    /// and above 4 the reveal stops reading as a bloom and starts reading as a
    /// flash.
    ///
    /// The constants in `NotchSupport` stay at the reference's original values;
    /// this divides at read time, so the reference numbers remain the documented
    /// baseline and a future style added to `NotchSupport` inherits the speed
    /// automatically.
    var notchExpansionSpeedMultiplier: Double = 2.0

    /// The expansion duration in force for `style`, with the user's speed
    /// multiplier applied. THE single entry point for "how long does the reveal
    /// take" — see the `expansionRevealDuration` comment for why there must be
    /// exactly one.
    var expansionRevealDurationInForce: (Double) -> (WindowExpansionStyle) -> TimeInterval {
        { multiplier in
            { style in
                NotchSupport.expansionRevealDuration(for: style) / multiplier
            }
        }
    }

    /// The content entrance delay in force, with the user's speed multiplier
    /// applied — the delay is paired to its window animation and must scale with
    /// it, or the content draws in full while the panel is still half-grown.
    var expansionContentEntranceDelayInForce: (Double) -> (WindowExpansionStyle) -> TimeInterval {
        { multiplier in
            { style in
                NotchSupport.expansionContentEntranceDelay(for: style) / multiplier
            }
        }
    }

    var audioEngineIdleReleaseMinutes: Int = 3

    /// 「释放引擎」: the shortcut that puts the machine's audio back to normal on
    /// demand — engine stopped, voice processing off, ducking lifted — for the
    /// times the user is doing something else while 「引擎保持时间」 is 永久.
    /// `nil` = not recorded, so nothing is bound until the user sets one.
    var releaseAudioEngineShortcut: RecordedKeyboardShortcut?

    /// 「回声消除」: whether Apple's voice processing (the system AEC) runs on
    /// the shared playback engine, cancelling the app's OWN spoken answer out
    /// of the microphone before the recognizer ever sees it.
    ///
    /// This is the structural half of the barge-in fix (2026-09-23). The
    /// text-level echo filter below it cannot hold on a mixed signal: with the
    /// answer audible in the microphone the recognizer transcribes our own
    /// words, and a filter then errs in BOTH directions — refusing a real
    /// interruption when it reads our words as echo (the answer talks over the
    /// user for sentences), and self-interrupting when it mis-hears one
    /// character (the AI cutting itself off). Un-mixing the signal is the only
    /// fix that holds, and AEC is what un-mixes it.
    ///
    /// Why it is a setting at all: while voice processing runs, macOS ducks
    /// every other application's audio (the FaceTime behaviour), which is what
    /// made this app remove AEC earlier on 2026-09-23. The ducking level is
    /// configurable from macOS 14 on — the app asks for the mildest one and
    /// never the activity-driven extra — and this switch is the user's way back
    /// out if their music still dips. Turning it off restores the old
    /// behaviour exactly: the text echo filter is still in place underneath.
    var echoCancellationEnabled: Bool = true

    /// 「录制期间自动静音系统扬声器，避免录入系统声音」: while the microphone
    /// is recording (push-to-talk or continuous listening) and no answer is
    /// being played back, the system's default output device is muted — music,
    /// video and every other application's audio stay out of the transcript —
    /// and un-muted again when the recording ends or playback starts. Never
    /// silences the app's own spoken replies. The echo defence while an answer
    /// IS playing is 「回声消除」 (echoCancellationEnabled, the shared engine's
    /// voice processing); this mute is what covers every other window.
    var mutesSystemSpeakersDuringRecording: Bool = true

    /// 「追问时自动截屏」: when a follow-up speaker is detected during the
    /// continuous-listening window, capture one screenshot of the screen at
    /// that instant (not continuously) and send it with the follow-up.
    var autoScreenshotOnFollowUpSpeech: Bool = true

    /// 「说到"屏幕"立即截屏」: whenever the recognized speech contains the
    /// word 屏幕 (or "screen"), capture one screenshot the moment the word is
    /// heard — before the sentence finishes — and use it for the question.
    /// Applies to every question, shortcut-triggered ones included.
    var autoScreenshotOnScreenKeyword: Bool = true

    // MARK: - 说（语音播报）

    /// AVAudioPlayer playback rate for the spoken answer. 1.0 = normal.
    var speechPlaybackRate: Double = 1.0

    /// AVAudioPlayer playback volume, 0–100 percent. Only affects this app's
    /// speech, not the system volume.
    var speechPlaybackVolumePercent: Double = 100

    /// When a new question starts while an answer is still being spoken, cut the
    /// speech off immediately (barge-in). Off lets the current answer finish.
    var interruptsPlaybackOnNewQuestion: Bool = true

    /// Characters per TTS synthesis request. The documented service cap is 600.
    var maximumSpeechChunkCharacters: Int = 500

    /// 「播报方式」: whether the reply is spoken as it streams in (逐句快答,
    /// the default) or held until the model has finished the whole answer
    /// (整段合成). See `SpeechSpeakMode` for the measured trade-off.
    var speechSpeakMode: SpeechSpeakMode = .sentenceFastReply

    // MARK: - 看与截图

    /// Longest edge of the captured screenshot in pixels. 0 means no rescaling
    /// (capture at the display's native size).
    var screenshotMaxDimension: Int = 1280

    /// JPEG compression factor for the screenshot.
    var screenshotCompressionQuality: Double = 0.8

    /// Send one screenshot per connected display (true) or only the display the
    /// cursor is on (false).
    var capturesAllDisplays: Bool = true

    /// When the answer embeds a `[POINT:…]` tag, fly the cursor to that element.
    var pointsAtReferencedElements: Bool = true

    /// 「圈选提问」: while holding the talk shortcut, the user can draw a circle
    /// around something on screen with the mouse, and that region rides along
    /// with the question as extra context — the same behaviour HeyClicky builds
    /// its precision on. Gated separately from 「回答里的位置自动飞过去指」
    /// because the two travel in opposite directions: this is the human
    /// marking the model's subject, not the model marking the user's screen.
    var allowsCircleToAsk: Bool = true

    /// 「刘海屏音效」: short one-shot chimes at conversation state transitions
    /// (recording started, transcript sent, answer arriving, an error) and when
    /// the notch sheet expands. Ported from HeyClicky's own chime set. Off means
    /// every sound effect is silent — spoken answers are unaffected either way.
    var playsNotchSoundEffects: Bool = true

    /// 连接成功之后，**先让 AI 说第一句话**（默认开）。
    ///
    /// 用户 2026-09-24 的观察很准：「刘海左右两侧显示的是连接成功，但我跟它说话它
    /// 没有反应，等了很长时间它才有反应」—— 原来的「已连接」只是**我们自己**把
    /// 状态标志翻了，它并不代表对方真的活着、真的听得到。让 AI 先出声，是把
    /// 「连接成功」这件事**变成一件用户能听见的事实**。
    ///
    /// 配合 `VoiceChatController` 里那条规则：刘海切到「Chatting」的时刻就是
    /// **第一段音频真的开始播**的时刻，而不是连接调用返回的时刻。
    var voiceChatGreetsOnConnect: Bool = true

    /// **静音回复**（用户 2026-09-25）：Ask 页右上角的静音开关 —— 开（默认）
    /// 时回复照常朗读；关时回复只显示文字、不合成不播放。它只作用于
    /// CompanionManager 的回复管线（按住说话 / Ask 打字）；Chatting 的会话
    /// 与它无关（那边有自己的音频流）。
    var voiceReplyMuted: Bool = false

    /// 第一句话说什么。留空就是用内置的那句。
    var voiceChatGreetingText: String = ""

    /// 内置打招呼语。写得短，因为它是「能不能听见」的探针，不是内容。
    static let defaultVoiceChatGreetingText = "你好，我在，能听到你说话。"

    /// 「刘海屏入口」: whether the notch-area pill is built at all on MacBooks
    /// with a hardware notch. The menu-bar panel is the permanent backup entry,
    /// so turning this off returns the app to a menu-bar-only life. On machines
    /// without a notch the subsystem idles regardless of this setting.
    var enablesNotchPresence: Bool = true

    // MARK: - 操作

    /// Master switch for acting on the machine — clicking, scrolling, typing,
    /// pressing keys, opening apps, reading the accessibility tree.
    ///
    /// On by default. Off means the tags are still parsed and then discarded, so
    /// the companion can point at things but cannot touch them.
    var allowsComputerControl: Bool = true

    /// Whether `[TYPE:…]` and `[PRESS:…]` are allowed, separately from everything
    /// else.
    ///
    /// Typing and key presses are the two that can reach any part of the system
    /// through whatever app happens to have focus, which is why they have their
    /// own gate rather than riding on the master switch. Clicking and scrolling
    /// are unaffected by it.
    var allowsKeyboardControl: Bool = true

    /// How `[TYPE:…]` gets its text into the focused app — one key event per
    /// character, or a clipboard paste (`cmd+v`). See `TextEntryMethod` for the
    /// trade-off; typing is the default so the clipboard is untouched unless the
    /// user asks for paste.
    var textEntryMethod: TextEntryMethod = .typeCharacters

    // MARK: - 快捷键

    /// Raw value of a `BuddyPushToTalkShortcut.ShortcutOption`. Stored as a
    /// string so an unknown value from a future/older build degrades to the
    /// default instead of failing the whole decode.
    var pushToTalkShortcutRawValue: String = BuddyPushToTalkShortcut.ShortcutOption.controlOption.rawValue

    /// The shortcut the user recorded by pressing keys in the settings window,
    /// or nil to follow the preset named by `pushToTalkShortcutRawValue`.
    /// A recorded shortcut always wins over the preset — the recorder is the
    /// more specific expression of the same one row.
    var customPushToTalkShortcut: RecordedKeyboardShortcut?

    /// How the shortcut is used: hold-to-talk (press, speak, release to send)
    /// or double-tap (press to start, press again to finalize and send) — the
    /// latter for long utterances that are uncomfortable to hold a key through.
    var pushToTalkTriggerModeRawValue: String = ShortcutTriggerMode.holdToTalk.rawValue

    var pushToTalkTriggerMode: ShortcutTriggerMode {
        get { ShortcutTriggerMode(rawValue: pushToTalkTriggerModeRawValue) ?? .holdToTalk }
        set { pushToTalkTriggerModeRawValue = newValue.rawValue }
    }

    /// The shortcut actually in effect: the user's recorded one when present,
    /// otherwise the chosen preset. Everything that matches events or displays
    /// the keys reads this, never the two stored halves directly, so a recorded
    /// shortcut and a preset can never disagree about which one is live.
    var pushToTalkShortcutBinding: RecordedKeyboardShortcut {
        if let customPushToTalkShortcut { return customPushToTalkShortcut }
        if let preset = BuddyPushToTalkShortcut.ShortcutOption(rawValue: pushToTalkShortcutRawValue) {
            return preset.defaultShortcutBinding
        }
        // Unknown preset string from a future/older build — same fallback the
        // `pushToTalkShortcutOption` accessor uses.
        return BuddyPushToTalkShortcut.ShortcutOption.controlOption.defaultShortcutBinding
    }

    /// Send the transcript the moment the key is released (current behavior).
    /// Off holds the transcript for confirmation — a quick tap of the shortcut
    /// sends it, holding the key again re-records over it.
    var sendsTranscriptImmediatelyOnRelease: Bool = true

    // MARK: - VoiceWeb 语音模式

    /// The three VoiceWeb mode shortcuts' factory defaults: ⌃⌥1 / ⌃⌥2 / ⌃⌥3
    /// (key codes 18/19/20 are the top number row's 1/2/3). The modifier raw
    /// value is control (0x40000) + option (0x80000) — the same two modifiers
    /// the talk shortcut's preset uses, so the whole family sits under one
    /// hand. Indexed by `VoiceWebMode`'s raw value.
    static let voiceWebDefaultShortcutBindings: [RecordedKeyboardShortcut] = [
        RecordedKeyboardShortcut(modifierFlagsRawValue: 786432, keyCode: 18),
        RecordedKeyboardShortcut(modifierFlagsRawValue: 786432, keyCode: 19),
        RecordedKeyboardShortcut(modifierFlagsRawValue: 786432, keyCode: 20),
    ]

    /// The factory default for 「释放引擎」: ⌃⌥4, the next key along from the
    /// three VoiceWeb mode shortcuts above (the only other ⌃⌥ bindings in the
    /// app), so the release shortcut works out of the box rather than needing to
    /// be recorded before it can be used.
    static let defaultReleaseAudioEngineShortcut = RecordedKeyboardShortcut(
        modifierFlagsRawValue: 786432,
        keyCode: 21
    )

    /// The release shortcut in force — the user's recorded one when present,
    /// otherwise the ⌃⌥4 preset. The same resolve-once shape as
    /// `pushToTalkShortcutBinding`, and for the same reason: what the settings
    /// page shows and what the event tap matches must be one value.
    var releaseAudioEngineShortcutBinding: RecordedKeyboardShortcut {
        releaseAudioEngineShortcut ?? Self.defaultReleaseAudioEngineShortcut
    }

    /// The shortcut that connects/disconnects the 三段式 (pipeline) voice mode.
    /// `nil` means the factory default ⌃⌥1 — same nil-means-preset shape as
    /// `customPushToTalkShortcut`.
    var voiceWebThreeStageShortcut: RecordedKeyboardShortcut?

    /// The shortcut for the 全双工语音 (duplex) voice mode. `nil` means ⌃⌥2.
    var voiceWebDuplexShortcut: RecordedKeyboardShortcut?

    /// The shortcut for the 全双工全模态 (omni) mode. `nil` means ⌃⌥3.
    var voiceWebOmniShortcut: RecordedKeyboardShortcut?

    /// Where the VoiceWeb project lives — the folder whose `.venv/bin/python
    /// server.py` is launched when the service is not reachable, and whose
    /// `cwd` that launch runs under. A stored default rather than a computed
    /// constant so a user who moved the project can fix it in settings without
    /// a rebuild.

    /// 三段式: send screen content along with the conversation (VoiceWeb's
    /// role-level screen recognition). Off = voice only. Written into the
    /// active role's `screen_vision_enabled` at connect time by the bridge.
    var voiceWebThreeStageSendsScreen: Bool = false

    /// 全双工全模态: whether voice participates. Voice is the point of the
    /// mode, so it defaults on; the two toggles below are the optional extras.
    var voiceWebOmniVoiceEnabled: Bool = true

    /// 全双工全模态: open the camera after connecting. Off by default — the
    /// camera light coming on uninvited would be the wrong default.
    var voiceWebOmniCameraEnabled: Bool = false

    /// 全双工全模态: ask for screen sharing after connecting. The macOS
    /// picker always needs one human click in the VoiceWeb window; the row's
    /// description says so.
    var voiceWebOmniScreenEnabled: Bool = false

    /// The shortcut actually in effect for VoiceWeb mode `modeIndex`
    /// (0 = 三段式, 1 = 全双工语音, 2 = 全双工全模态): the user's recorded
    /// one when present, otherwise the factory default — the same
    /// recorded-wins-over-preset rule as `pushToTalkShortcutBinding`.
    func voiceWebShortcutBinding(modeIndex: Int) -> RecordedKeyboardShortcut {
        let storedShortcuts = [voiceWebThreeStageShortcut, voiceWebDuplexShortcut, voiceWebOmniShortcut]
        let index = max(0, min(modeIndex, storedShortcuts.count - 1))
        return storedShortcuts[index] ?? Self.voiceWebDefaultShortcutBindings[index]
    }

    // MARK: - Agent

    /// Master switch for the agent subsystem — spawning claude subprocesses
    /// that work on a project folder in the background. Off means 「新建 Agent」
    /// and send are refused with an explanation rather than silently doing
    /// nothing (the same "don't act, but say so" rule as `allowsComputerControl`).
    var allowsAgentSubsystem: Bool = true

    /// Path to the claude CLI executable. `nil` means auto-detect (`which
    /// claude`, then the Homebrew locations) at spawn time, so a user who never
    /// opens settings still works; the settings row exists for installs where
    /// the CLI lives somewhere unusual.
    var agentClaudeExecutablePath: String?

    /// Folder pre-selected when a new agent is created. `nil` means the folder
    /// picker starts at the user's home directory.
    var agentDefaultProjectFolder: String?

    /// Raw value of `AgentPermissionMode`, stored as a string so an unknown
    /// value from a future/older build degrades to the default instead of
    /// failing the whole decode.
    var agentPermissionModeRawValue: String = AgentPermissionMode.autoEdit.rawValue

    var agentPermissionMode: AgentPermissionMode {
        get { AgentPermissionMode(rawValue: agentPermissionModeRawValue) ?? .autoEdit }
        set { agentPermissionModeRawValue = newValue.rawValue }
    }

    /// How many agent subprocesses may run at once. Each one is an independent
    /// claude process billing the user's own Claude login, so the ceiling is
    /// deliberately low.
    var maximumConcurrentAgents: Int = 3

    /// Whether agents with a non-idle status show up as floating chips in the
    /// screen's top-right corner (the HeyClicky HUD form). Off hides the
    /// controller's panels entirely — the roster in the notch sheet still works.
    var allowsAgentDesktopHUD: Bool = true

    /// Whether a finished agent turn is read aloud through the speech role.
    /// Announcements only fire while the voice companion is idle, so this can
    /// never cut into an answer the user is listening to.
    var announcesAgentCompletion: Bool = true

    // MARK: - 模型

    /// `max_completion_tokens` sent with every vision request. Shared by every
    /// provider, so the stored value is clamped to 32768 — Bailian's ceiling,
    /// which is an order of magnitude below DeepSeek's.
    var visionMaxCompletionTokens: Int = 32768

    // MARK: - Clamping

    /// A copy of these settings with every numeric value forced back inside the
    /// range its UI offers. Called on the way into the store so a hand-edited
    /// JSON file can't smuggle in an out-of-range value.
    func clamped() -> AppSettings {
        var settings = self
        settings.transientCursorHideDelaySeconds = min(max(settings.transientCursorHideDelaySeconds, 0.5), 5)
        settings.answerBubbleLingerSeconds = min(max(settings.answerBubbleLingerSeconds, 0), 15)
        settings.rememberedConversationRounds = min(max(settings.rememberedConversationRounds, 0), 30)
        settings.finalTranscriptGracePeriodSeconds = min(max(settings.finalTranscriptGracePeriodSeconds, 0.5), 3)
        settings.speechPlaybackRate = min(max(settings.speechPlaybackRate, 0.75), 1.5)
        settings.speechPlaybackVolumePercent = min(max(settings.speechPlaybackVolumePercent, 0), 100)
        settings.maximumSpeechChunkCharacters = min(max(settings.maximumSpeechChunkCharacters, 200), 600)
        settings.screenshotCompressionQuality = min(max(settings.screenshotCompressionQuality, 0.5), 0.95)
        settings.visionMaxCompletionTokens = min(max(settings.visionMaxCompletionTokens, 256), 32768)
        settings.maximumConcurrentAgents = min(max(settings.maximumConcurrentAgents, 1), 6)
        settings.continuousListeningWindowSeconds = min(max(settings.continuousListeningWindowSeconds, 0), 120)
        settings.continuousListeningSilenceSendSeconds = min(max(settings.continuousListeningSilenceSendSeconds, 1.0), 5.0)
        settings.audioEngineIdleReleaseMinutes = min(max(settings.audioEngineIdleReleaseMinutes, 0), 60)
        settings.notchExpansionSpeedMultiplier = min(max(settings.notchExpansionSpeedMultiplier, 1.0), 4.0)
        return settings
    }
}

// MARK: - Tolerant decoding

/// Hand-written so a settings file missing a field decodes with the field's
/// default instead of throwing. The synthesized `Codable` would refuse any file
/// written before a newly added field existed, which would silently reset every
/// setting on the first launch after an upgrade.
nonisolated extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case launchesAtLogin
        case opensPanelOnLaunch
        case showsResponseText
        case showsLiveTranscript
        case answerBubbleLingerSeconds
        case cursorPresenceMode
        case cursorShapeStyle
        case cursorFollowDistance
        case transientCursorHideDelaySeconds
        case rememberedConversationRounds
        case persistsConversationHistory
        case autoCompressesHistory
        case includesScreenshotsInHistory
        case answerLengthStyle
        case answerCardStyle
        case windowExpansionStyle
        case composerSendShortcut
        case extraSystemPromptInstructions
        case customSystemPrompt
        case transcriptionLanguage
        case extraTranscriptionKeyterms
        case finalTranscriptGracePeriodSeconds
        case usesAutomaticSpeechSegmentation
        case continuousListeningEnabled
        case continuousListeningWindowSeconds
        case continuousListeningSilenceSendSeconds
        case audioEngineIdleReleaseMinutes
        case releaseAudioEngineShortcut
        case notchExpansionSpeedMultiplier
        case echoCancellationEnabled
        case mutesSystemSpeakersDuringRecording
        case autoScreenshotOnFollowUpSpeech
        case autoScreenshotOnScreenKeyword
        case speechPlaybackRate
        case speechPlaybackVolumePercent
        case interruptsPlaybackOnNewQuestion
        case maximumSpeechChunkCharacters
        case speechSpeakMode
        case screenshotMaxDimension
        case screenshotCompressionQuality
        case capturesAllDisplays
        case pointsAtReferencedElements
        case allowsCircleToAsk
        case playsNotchSoundEffects
        case voiceChatGreetsOnConnect
        case voiceReplyMuted
        case voiceChatGreetingText
        case enablesNotchPresence
        case allowsComputerControl
        case allowsKeyboardControl
        case textEntryMethod
        case pushToTalkShortcutRawValue
        case customPushToTalkShortcut
        case pushToTalkTriggerModeRawValue
        case sendsTranscriptImmediatelyOnRelease
        case voiceWebThreeStageShortcut
        case voiceWebDuplexShortcut
        case voiceWebOmniShortcut
        case voiceWebThreeStageSendsScreen
        case voiceWebOmniVoiceEnabled
        case voiceWebOmniCameraEnabled
        case voiceWebOmniScreenEnabled
        case visionMaxCompletionTokens
        case allowsAgentSubsystem
        case agentClaudeExecutablePath
        case agentDefaultProjectFolder
        case agentPermissionModeRawValue
        case maximumConcurrentAgents
        case allowsAgentDesktopHUD
        case announcesAgentCompletion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()

        self.init()

        launchesAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchesAtLogin) ?? defaults.launchesAtLogin
        opensPanelOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .opensPanelOnLaunch) ?? defaults.opensPanelOnLaunch
        showsResponseText = try container.decodeIfPresent(Bool.self, forKey: .showsResponseText) ?? defaults.showsResponseText
        showsLiveTranscript = try container.decodeIfPresent(Bool.self, forKey: .showsLiveTranscript) ?? defaults.showsLiveTranscript
        answerBubbleLingerSeconds = try container.decodeIfPresent(Double.self, forKey: .answerBubbleLingerSeconds) ?? defaults.answerBubbleLingerSeconds
        cursorPresenceMode = try container.decodeIfPresent(CursorPresenceMode.self, forKey: .cursorPresenceMode) ?? defaults.cursorPresenceMode
        cursorShapeStyle = try container.decodeIfPresent(CursorShapeStyle.self, forKey: .cursorShapeStyle) ?? defaults.cursorShapeStyle
        cursorFollowDistance = try container.decodeIfPresent(CursorFollowDistance.self, forKey: .cursorFollowDistance) ?? defaults.cursorFollowDistance
        transientCursorHideDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .transientCursorHideDelaySeconds) ?? defaults.transientCursorHideDelaySeconds
        rememberedConversationRounds = try container.decodeIfPresent(Int.self, forKey: .rememberedConversationRounds) ?? defaults.rememberedConversationRounds
        persistsConversationHistory = try container.decodeIfPresent(Bool.self, forKey: .persistsConversationHistory) ?? defaults.persistsConversationHistory
        autoCompressesHistory = try container.decodeIfPresent(Bool.self, forKey: .autoCompressesHistory) ?? defaults.autoCompressesHistory
        includesScreenshotsInHistory = try container.decodeIfPresent(Bool.self, forKey: .includesScreenshotsInHistory) ?? defaults.includesScreenshotsInHistory
        answerLengthStyle = try container.decodeIfPresent(AnswerLengthStyle.self, forKey: .answerLengthStyle) ?? defaults.answerLengthStyle
        answerCardStyle = try container.decodeIfPresent(AnswerCardStyle.self, forKey: .answerCardStyle) ?? defaults.answerCardStyle
        // `decodeIfPresent` is what lets a file written before this setting
        // existed still load: `WindowExpansionStyle` is an enum, so a plain
        // `decode` would throw on a missing key and every older AppSettings.json
        // would fail to load. It is read as a STRING and matched by rawValue
        // rather than decoded as the enum directly, because the 2026-09-23
        // redesign renamed the 中心缩放 case `centerPop` → `notchBloom`: a file
        // holding the old value would make `decodeIfPresent(WindowExpansionStyle…)`
        // throw and take the whole AppSettings.json down with it. Unknown and
        // legacy values — `"centerPop"` included — read as the new 中心缩放.
        if let rawExpansionStyle = try container.decodeIfPresent(String.self, forKey: .windowExpansionStyle) {
            windowExpansionStyle = WindowExpansionStyle(rawValue: rawExpansionStyle) ?? .notchBloom
        } else {
            windowExpansionStyle = defaults.windowExpansionStyle
        }
        // 同一个理由：`ComposerSendShortcut` 也是枚举，普通 `decode` 会在缺键时
        // 抛错，把加这一项之前写下的每个 AppSettings.json 都变成读不进来。读不到
        // 就是默认的「按 Enter 发送」——那也是用户要的默认行为。
        composerSendShortcut = try container.decodeIfPresent(ComposerSendShortcut.self, forKey: .composerSendShortcut) ?? defaults.composerSendShortcut
        extraSystemPromptInstructions = try container.decodeIfPresent(String.self, forKey: .extraSystemPromptInstructions) ?? defaults.extraSystemPromptInstructions
        // Optional on purpose, and no `?? defaults` fallback: "no key" and "key set
        // to null" both have to land on nil, because nil is the value that means
        // "use the built-in prompt". A fallback here would turn every existing
        // settings file into one that ships a frozen copy of today's prompt.
        customSystemPrompt = try container.decodeIfPresent(String.self, forKey: .customSystemPrompt)
        transcriptionLanguage = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .transcriptionLanguage) ?? defaults.transcriptionLanguage
        extraTranscriptionKeyterms = try container.decodeIfPresent(String.self, forKey: .extraTranscriptionKeyterms) ?? defaults.extraTranscriptionKeyterms
        finalTranscriptGracePeriodSeconds = try container.decodeIfPresent(Double.self, forKey: .finalTranscriptGracePeriodSeconds) ?? defaults.finalTranscriptGracePeriodSeconds
        usesAutomaticSpeechSegmentation = try container.decodeIfPresent(Bool.self, forKey: .usesAutomaticSpeechSegmentation) ?? defaults.usesAutomaticSpeechSegmentation
        continuousListeningEnabled = try container.decodeIfPresent(Bool.self, forKey: .continuousListeningEnabled) ?? defaults.continuousListeningEnabled
        continuousListeningWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .continuousListeningWindowSeconds) ?? defaults.continuousListeningWindowSeconds
        continuousListeningSilenceSendSeconds = try container.decodeIfPresent(Double.self, forKey: .continuousListeningSilenceSendSeconds) ?? defaults.continuousListeningSilenceSendSeconds
        audioEngineIdleReleaseMinutes = try container.decodeIfPresent(Int.self, forKey: .audioEngineIdleReleaseMinutes) ?? defaults.audioEngineIdleReleaseMinutes
        releaseAudioEngineShortcut = try container.decodeIfPresent(RecordedKeyboardShortcut.self, forKey: .releaseAudioEngineShortcut)
        notchExpansionSpeedMultiplier = try container.decodeIfPresent(Double.self, forKey: .notchExpansionSpeedMultiplier) ?? defaults.notchExpansionSpeedMultiplier
        echoCancellationEnabled = try container.decodeIfPresent(Bool.self, forKey: .echoCancellationEnabled) ?? defaults.echoCancellationEnabled
        mutesSystemSpeakersDuringRecording = try container.decodeIfPresent(Bool.self, forKey: .mutesSystemSpeakersDuringRecording) ?? defaults.mutesSystemSpeakersDuringRecording
        autoScreenshotOnFollowUpSpeech = try container.decodeIfPresent(Bool.self, forKey: .autoScreenshotOnFollowUpSpeech) ?? defaults.autoScreenshotOnFollowUpSpeech
        autoScreenshotOnScreenKeyword = try container.decodeIfPresent(Bool.self, forKey: .autoScreenshotOnScreenKeyword) ?? defaults.autoScreenshotOnScreenKeyword
        speechPlaybackRate = try container.decodeIfPresent(Double.self, forKey: .speechPlaybackRate) ?? defaults.speechPlaybackRate
        speechPlaybackVolumePercent = try container.decodeIfPresent(Double.self, forKey: .speechPlaybackVolumePercent) ?? defaults.speechPlaybackVolumePercent
        interruptsPlaybackOnNewQuestion = try container.decodeIfPresent(Bool.self, forKey: .interruptsPlaybackOnNewQuestion) ?? defaults.interruptsPlaybackOnNewQuestion
        maximumSpeechChunkCharacters = try container.decodeIfPresent(Int.self, forKey: .maximumSpeechChunkCharacters) ?? defaults.maximumSpeechChunkCharacters
        speechSpeakMode = try container.decodeIfPresent(SpeechSpeakMode.self, forKey: .speechSpeakMode) ?? defaults.speechSpeakMode
        screenshotMaxDimension = try container.decodeIfPresent(Int.self, forKey: .screenshotMaxDimension) ?? defaults.screenshotMaxDimension
        screenshotCompressionQuality = try container.decodeIfPresent(Double.self, forKey: .screenshotCompressionQuality) ?? defaults.screenshotCompressionQuality
        capturesAllDisplays = try container.decodeIfPresent(Bool.self, forKey: .capturesAllDisplays) ?? defaults.capturesAllDisplays
        pointsAtReferencedElements = try container.decodeIfPresent(Bool.self, forKey: .pointsAtReferencedElements) ?? defaults.pointsAtReferencedElements
        allowsCircleToAsk = try container.decodeIfPresent(Bool.self, forKey: .allowsCircleToAsk) ?? defaults.allowsCircleToAsk
        playsNotchSoundEffects = try container.decodeIfPresent(Bool.self, forKey: .playsNotchSoundEffects) ?? defaults.playsNotchSoundEffects
        voiceChatGreetsOnConnect = try container.decodeIfPresent(Bool.self, forKey: .voiceChatGreetsOnConnect) ?? defaults.voiceChatGreetsOnConnect
        voiceReplyMuted = try container.decodeIfPresent(Bool.self, forKey: .voiceReplyMuted) ?? defaults.voiceReplyMuted
        voiceChatGreetingText = try container.decodeIfPresent(String.self, forKey: .voiceChatGreetingText) ?? defaults.voiceChatGreetingText
        enablesNotchPresence = try container.decodeIfPresent(Bool.self, forKey: .enablesNotchPresence) ?? defaults.enablesNotchPresence
        // `decodeIfPresent` is not optional politeness here: a synthesized `Codable`
        // throws on a missing key, so a plain `Bool` added today would make every
        // settings file written before today fail to load — and the store would
        // silently fall back to defaults for the user's entire configuration.
        allowsComputerControl = try container.decodeIfPresent(Bool.self, forKey: .allowsComputerControl) ?? defaults.allowsComputerControl
        allowsKeyboardControl = try container.decodeIfPresent(Bool.self, forKey: .allowsKeyboardControl) ?? defaults.allowsKeyboardControl
        textEntryMethod = try container.decodeIfPresent(TextEntryMethod.self, forKey: .textEntryMethod) ?? defaults.textEntryMethod
        pushToTalkShortcutRawValue = try container.decodeIfPresent(String.self, forKey: .pushToTalkShortcutRawValue) ?? defaults.pushToTalkShortcutRawValue
        customPushToTalkShortcut = try container.decodeIfPresent(RecordedKeyboardShortcut.self, forKey: .customPushToTalkShortcut) ?? defaults.customPushToTalkShortcut
        pushToTalkTriggerModeRawValue = try container.decodeIfPresent(String.self, forKey: .pushToTalkTriggerModeRawValue) ?? defaults.pushToTalkTriggerModeRawValue
        sendsTranscriptImmediatelyOnRelease = try container.decodeIfPresent(Bool.self, forKey: .sendsTranscriptImmediatelyOnRelease) ?? defaults.sendsTranscriptImmediatelyOnRelease
        voiceWebThreeStageShortcut = try container.decodeIfPresent(RecordedKeyboardShortcut.self, forKey: .voiceWebThreeStageShortcut) ?? defaults.voiceWebThreeStageShortcut
        voiceWebDuplexShortcut = try container.decodeIfPresent(RecordedKeyboardShortcut.self, forKey: .voiceWebDuplexShortcut) ?? defaults.voiceWebDuplexShortcut
        voiceWebOmniShortcut = try container.decodeIfPresent(RecordedKeyboardShortcut.self, forKey: .voiceWebOmniShortcut) ?? defaults.voiceWebOmniShortcut
        voiceWebThreeStageSendsScreen = try container.decodeIfPresent(Bool.self, forKey: .voiceWebThreeStageSendsScreen) ?? defaults.voiceWebThreeStageSendsScreen
        voiceWebOmniVoiceEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceWebOmniVoiceEnabled) ?? defaults.voiceWebOmniVoiceEnabled
        voiceWebOmniCameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceWebOmniCameraEnabled) ?? defaults.voiceWebOmniCameraEnabled
        voiceWebOmniScreenEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceWebOmniScreenEnabled) ?? defaults.voiceWebOmniScreenEnabled
        visionMaxCompletionTokens = try container.decodeIfPresent(Int.self, forKey: .visionMaxCompletionTokens) ?? defaults.visionMaxCompletionTokens
        allowsAgentSubsystem = try container.decodeIfPresent(Bool.self, forKey: .allowsAgentSubsystem) ?? defaults.allowsAgentSubsystem
        agentClaudeExecutablePath = try container.decodeIfPresent(String.self, forKey: .agentClaudeExecutablePath) ?? defaults.agentClaudeExecutablePath
        agentDefaultProjectFolder = try container.decodeIfPresent(String.self, forKey: .agentDefaultProjectFolder) ?? defaults.agentDefaultProjectFolder
        agentPermissionModeRawValue = try container.decodeIfPresent(String.self, forKey: .agentPermissionModeRawValue) ?? defaults.agentPermissionModeRawValue
        maximumConcurrentAgents = try container.decodeIfPresent(Int.self, forKey: .maximumConcurrentAgents) ?? defaults.maximumConcurrentAgents
        allowsAgentDesktopHUD = try container.decodeIfPresent(Bool.self, forKey: .allowsAgentDesktopHUD) ?? defaults.allowsAgentDesktopHUD
        announcesAgentCompletion = try container.decodeIfPresent(Bool.self, forKey: .announcesAgentCompletion) ?? defaults.announcesAgentCompletion
    }
}
