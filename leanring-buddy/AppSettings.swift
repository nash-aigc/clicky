//
//  AppSettings.swift
//  leanring-buddy
//
//  The user-facing app settings — every switch and slider the settings window's
//  通用 / 对话与记忆 / 听 / 说 / 看与截图 / 快捷键 pages edit, as one value type.
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

    /// Free-form instructions appended verbatim to the system prompt.
    var extraSystemPromptInstructions: String = ""

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

    // MARK: - 快捷键

    /// Raw value of a `BuddyPushToTalkShortcut.ShortcutOption`. Stored as a
    /// string so an unknown value from a future/older build degrades to the
    /// default instead of failing the whole decode.
    var pushToTalkShortcutRawValue: String = BuddyPushToTalkShortcut.ShortcutOption.controlOption.rawValue

    /// Send the transcript the moment the key is released (current behavior).
    /// Off holds the transcript for confirmation — a quick tap of the shortcut
    /// sends it, holding the key again re-records over it.
    var sendsTranscriptImmediatelyOnRelease: Bool = true

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
        return settings
    }

    /// The push-to-talk shortcut option these settings name, falling back to the
    /// original hard-coded `controlOption` when the stored raw value is unknown.
    var pushToTalkShortcutOption: BuddyPushToTalkShortcut.ShortcutOption {
        BuddyPushToTalkShortcut.ShortcutOption(rawValue: pushToTalkShortcutRawValue) ?? .controlOption
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
        case extraSystemPromptInstructions
        case transcriptionLanguage
        case extraTranscriptionKeyterms
        case finalTranscriptGracePeriodSeconds
        case usesAutomaticSpeechSegmentation
        case speechPlaybackRate
        case speechPlaybackVolumePercent
        case interruptsPlaybackOnNewQuestion
        case maximumSpeechChunkCharacters
        case screenshotMaxDimension
        case screenshotCompressionQuality
        case capturesAllDisplays
        case pointsAtReferencedElements
        case pushToTalkShortcutRawValue
        case sendsTranscriptImmediatelyOnRelease
        case visionMaxCompletionTokens
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
        extraSystemPromptInstructions = try container.decodeIfPresent(String.self, forKey: .extraSystemPromptInstructions) ?? defaults.extraSystemPromptInstructions
        transcriptionLanguage = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .transcriptionLanguage) ?? defaults.transcriptionLanguage
        extraTranscriptionKeyterms = try container.decodeIfPresent(String.self, forKey: .extraTranscriptionKeyterms) ?? defaults.extraTranscriptionKeyterms
        finalTranscriptGracePeriodSeconds = try container.decodeIfPresent(Double.self, forKey: .finalTranscriptGracePeriodSeconds) ?? defaults.finalTranscriptGracePeriodSeconds
        usesAutomaticSpeechSegmentation = try container.decodeIfPresent(Bool.self, forKey: .usesAutomaticSpeechSegmentation) ?? defaults.usesAutomaticSpeechSegmentation
        speechPlaybackRate = try container.decodeIfPresent(Double.self, forKey: .speechPlaybackRate) ?? defaults.speechPlaybackRate
        speechPlaybackVolumePercent = try container.decodeIfPresent(Double.self, forKey: .speechPlaybackVolumePercent) ?? defaults.speechPlaybackVolumePercent
        interruptsPlaybackOnNewQuestion = try container.decodeIfPresent(Bool.self, forKey: .interruptsPlaybackOnNewQuestion) ?? defaults.interruptsPlaybackOnNewQuestion
        maximumSpeechChunkCharacters = try container.decodeIfPresent(Int.self, forKey: .maximumSpeechChunkCharacters) ?? defaults.maximumSpeechChunkCharacters
        screenshotMaxDimension = try container.decodeIfPresent(Int.self, forKey: .screenshotMaxDimension) ?? defaults.screenshotMaxDimension
        screenshotCompressionQuality = try container.decodeIfPresent(Double.self, forKey: .screenshotCompressionQuality) ?? defaults.screenshotCompressionQuality
        capturesAllDisplays = try container.decodeIfPresent(Bool.self, forKey: .capturesAllDisplays) ?? defaults.capturesAllDisplays
        pointsAtReferencedElements = try container.decodeIfPresent(Bool.self, forKey: .pointsAtReferencedElements) ?? defaults.pointsAtReferencedElements
        pushToTalkShortcutRawValue = try container.decodeIfPresent(String.self, forKey: .pushToTalkShortcutRawValue) ?? defaults.pushToTalkShortcutRawValue
        sendsTranscriptImmediatelyOnRelease = try container.decodeIfPresent(Bool.self, forKey: .sendsTranscriptImmediatelyOnRelease) ?? defaults.sendsTranscriptImmediatelyOnRelease
        visionMaxCompletionTokens = try container.decodeIfPresent(Int.self, forKey: .visionMaxCompletionTokens) ?? defaults.visionMaxCompletionTokens
    }
}
