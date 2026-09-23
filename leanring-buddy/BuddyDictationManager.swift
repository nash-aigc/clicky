//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

/// `RecordedKeyboardShortcut` is pure data (a raw-value struct in
/// `AppSettings.swift`, which deliberately imports no AppKit), so the
/// `NSEvent.ModifierFlags` view of its stored raw value lives here with the
/// event-matching code that needs it.
extension RecordedKeyboardShortcut {
    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }
}

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        /// The preset expressed in the same shape as a shortcut the user
        /// recorded, so the event matcher below has one path for both. Every
        /// modifier-only preset binds no key; the two space presets bind
        /// space (key code 49).
        var defaultShortcutBinding: RecordedKeyboardShortcut {
            switch self {
            case .shiftFunction:
                return RecordedKeyboardShortcut(
                    modifierFlagsRawValue: NSEvent.ModifierFlags([.shift, .function]).rawValue,
                    keyCode: nil
                )
            case .controlOption:
                return RecordedKeyboardShortcut(
                    modifierFlagsRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
                    keyCode: nil
                )
            case .shiftControl:
                return RecordedKeyboardShortcut(
                    modifierFlagsRawValue: NSEvent.ModifierFlags([.shift, .control]).rawValue,
                    keyCode: nil
                )
            case .controlOptionSpace:
                return RecordedKeyboardShortcut(
                    modifierFlagsRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
                    keyCode: pushToTalkKeyCode
                )
            case .shiftControlSpace:
                return RecordedKeyboardShortcut(
                    modifierFlagsRawValue: NSEvent.ModifierFlags([.shift, .control]).rawValue,
                    keyCode: pushToTalkKeyCode
                )
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    /// The push-to-talk keybinding in effect. Read from the app settings on
    /// every access rather than cached: the settings window can change it while
    /// the app runs, and the event-tap matching and the panel's tooltip must
    /// never disagree about which keys start and end a recording. A shortcut
    /// the user recorded in the settings window wins over the preset.
    static var currentShortcutBinding: RecordedKeyboardShortcut {
        AppSettingsStore.snapshot().pushToTalkShortcutBinding
    }
    /// Space, the key the two built-in presets bind. Kept as a named constant
    /// because the preset bindings and any recorder hint text both want it.
    static let pushToTalkKeyCode: UInt16 = 49
    static var pushToTalkDisplayText: String { currentShortcutBinding.displayText }
    static var pushToTalkTooltipText: String { "push to talk (\(pushToTalkDisplayText))" }

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        // One matching path for presets and recorded shortcuts alike — they are
        // the same shape by the time they get here (`pushToTalkShortcutBinding`
        // resolves which one is live). Modifier-only bindings press and release
        // on flagsChanged; bindings with a key press and release on that key.
        let binding = currentShortcutBinding
        let requiredModifierFlags = binding.modifierFlags
            .intersection(.deviceIndependentFlagsMask)

        if let boundKeyCode = binding.keyCode {
            if shortcutEventType == .keyDown
                && keyCode == boundKeyCode
                && modifierFlags.isSuperset(of: requiredModifierFlags)
                && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if shortcutEventType == .keyUp
                && keyCode == boundKeyCode
                && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard shortcutEventType == .flagsChanged, !requiredModifierFlags.isEmpty else { return .none }

        let isShortcutCurrentlyPressed = modifierFlags.isSuperset(of: requiredModifierFlags)

        if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

/// Callbacks the continuous-listening window (回答时持续监听) installs so
/// CompanionManager can react to what the microphone hears while the answer
/// is still being spoken. Deliberately a separate shape from
/// `BuddyDictationDraftCallbacks`: a listening session never writes into the
/// composer draft — its transcripts are whole new questions.
struct BuddyContinuousListeningCallbacks {
    /// The user really is speaking over the answer (the barge-in moment: the
    /// caller stops TTS playback and takes the follow-up screenshot here).
    ///
    /// Fires at most ONCE per utterance, and — while the answer is being read
    /// aloud — only once the recognizer has produced real words. A rise in the
    /// microphone level is not enough on its own: see
    /// `markContinuousListeningUtteranceActive` for the measurement that made
    /// the level path non-authoritative while the bot is speaking.
    let onSpeechDetected: () -> Void
    /// Cumulative interim transcript of the utterance currently being spoken.
    let onTranscriptUpdate: (String) -> Void
    /// The utterance ended (silence long enough) and the recognizer delivered
    /// its final transcript. Empty/echo-short transcripts are filtered before
    /// this fires.
    let onUtteranceFinalized: (String) -> Void
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    // Continuous listening (回答时持续监听) tuning. The layering mirrors what
    // the VoiceWeb reference measured (浏览器 AEC 承重 + VAD 阈值/时长防误触发),
    // and since 2026-09-23 it matches it again — the load-bearing layer is a
    // real AEC once more.
    // ① the system AEC (Apple voice processing, on the shared playback engine
    //    — see VoicePlaybackEngine's header) removes the app's own answer from
    //    the microphone BEFORE the recognizer sees it. This is the layer that
    //    matters: without it the answer arrives as perfectly real words and no
    //    later layer can tell them apart from the user's.
    // ② the recording mute (SystemSpeakerMuteCoordinator) keeps system audio
    //    out of the mic while nothing is playing — it is what covers the
    //    windows in which ① is not running, and it is why AEC is only needed
    //    while an answer is actually being read aloud.
    // ③ a smoothed-RMS threshold rejects background hiss,
    // ④ a sustained-speech debounce rejects clicks and door slams,
    // ⑤ a minimum transcript length keeps a short artefact from being sent
    //    as a question even if ①-④ all let something through.
    //
    // The threshold is on the waveform's boosted scale (RMS × 10.2), and it
    // was calibrated 2026-09-23 against this machine's built-in mic with a
    // 15 s quiet-room probe: the ambient floor peaked at 0.167 (typical
    // 0.09–0.11), so the original 0.06 sat BELOW the noise floor and the VAD
    // fired constantly in silence — every answer triggered a garbage follow-up
    // (「嗯。」) and the whole runaway-loop failure. Normal speech measures
    // 0.3–1.0 on the same scale, so 0.25 clears the floor with margin while
    // staying under quiet speech.
    private static let continuousListeningSpeechLevelThreshold: CGFloat = 0.25
    // Speech is confirmed by ACCUMULATED above-threshold time with a slow
    // release, NOT by an unbroken run of it.
    //
    // Why (measured 2026-09-23, probe: a real Chinese voice played through the
    // system speakers into this same tap topology, while VPIO was still in
    // place): the smoothed level
    // during continuous speech reads peak 0.772 / p95 0.556 but p50 0.159 —
    // natural articulation dips below 0.25 roughly half the time, and the
    // smoothing decays at 0.72 per tap buffer, so the level is already down
    // between syllables. The previous rule asked for 0.35 s of CONTINUOUS
    // above-threshold time, which normal speech never delivers, so
    // `continuousListeningUtteranceActive` never became true: nothing to send
    // after 2–3 s of silence (「等待了两秒、三秒，它还是没有发送」) and a
    // shortcut press found nothing pending, fell through to the stop branch
    // and exited listening (「我按住快捷键的话，它还是自动退出」).
    //
    // A leaky accumulator tolerates those dips the way pipecat's neural VAD
    // tolerates them, while still demanding real speech rather than one loud
    // click. Rising costs the full poll interval, falling returns only a
    // quarter of it, so ~0.2 s of net speech confirms the utterance and a
    // brief pause cannot undo it.
    private static let continuousListeningSpeechAccumulationSeconds: TimeInterval = 0.20
    private static let continuousListeningSpeechAccumulatorReleaseRatio: Double = 0.25
    // The silence that ends an utterance is now a USER SETTING
    // (「静音多久自动发送」, AppSettings.continuousListeningSilenceSendSeconds,
    // default 2.0 s, clamped 1–5) — human thinking pauses are unbounded (the
    // user's framing, 2026-09-23), so no single silence value can be the
    // "finished speaking" verdict; the talk shortcut is the reliable send
    // marker and this wait is only the auto path. Held as an instance
    // property fed in at window start, not read from the store mid-window,
    // so changing the setting only affects the NEXT window (the live VAD loop
    // must not have its threshold move under it).
    private var continuousListeningUtteranceEndSilenceSeconds: TimeInterval = 2.0
    private static let continuousListeningMaximumUtteranceSeconds: TimeInterval = 15
    /// The VAD loop's tick. Held in seconds and derived into a `Duration` so
    /// the accumulator maths and the sleep can never disagree about it.
    private static let continuousListeningVADPollSeconds: TimeInterval = 0.05
    private static var continuousListeningVADPollInterval: Duration { .seconds(continuousListeningVADPollSeconds) }
    /// How far back the microphone-level corroboration looks, and how many VAD
    /// ticks that is.
    ///
    /// Half a second, because the level is SPIKY, not because half a second is
    /// a round number: continuous speech on this machine reads peak 0.772 /
    /// p95 0.556 but only p50 0.159 (measured 2026-09-23), so at any single
    /// 50 ms tick the level is as likely as not to be sitting under the 0.25
    /// threshold. Asking "is the level high right now" would answer no about
    /// half the time and lose the corroboration for no reason; asking "has the
    /// microphone been loud recently" is the question that matches what a
    /// person speaking into it actually produces.
    private static let continuousListeningRecentLevelWindowSeconds: TimeInterval = 0.5
    private static var continuousListeningRecentLevelSampleCount: Int {
        max(1, Int((continuousListeningRecentLevelWindowSeconds / continuousListeningVADPollSeconds).rounded()))
    }
    // 4 characters of REAL content (up from 2, 2026-09-23): an interjection the
    // user hums while listening to an answer (「嗯。」) transcribes to 1–3
    // characters and must not be submitted as a brand-new question — that was
    // the "循环一个全新的东西" loop's fuel. A real follow-up question is a
    // sentence. Counted through `continuousListeningContentCharacterCount`, so
    // punctuation can never add up to a sentence (「。。。。」 is 0, not 4).
    private static let continuousListeningMinimumTranscriptCharacters = 4
    /// How much real content a transcript must carry to be allowed to INTERRUPT
    /// an answer that is being read aloud.
    ///
    /// This is pipecat's official `MinWordsUserTurnStartStrategy`, adopted
    /// rather than reinvented — it is the framework's answer to exactly this
    /// failure. Its rule (user_start/min_words_user_turn_start_strategy.py:118)
    /// is `word_count >= (min_words if bot_speaking else 1)`: a single word may
    /// start a turn while the bot is SILENT, but while the bot is SPEAKING a
    /// transcription must clear a higher bar before it may interrupt it.
    /// VoiceWeb runs the same transcription-driven turn start — its 三段式
    /// passes `TranscriptionUserTurnStartStrategy` verbatim (server.py:3725) —
    /// so this is the shipping framework design, not a local heuristic.
    ///
    /// Why the guard is not optional, measured 2026-09-23: the Bailian realtime
    /// recognizer, fed the microphone audio recorded while this app was reading
    /// an answer aloud (VPIO's AEC was still active then and working — the
    /// echo measured BELOW the
    /// room's own noise floor, peak 0.111 against a 0.167 floor), returned a
    /// FINAL transcript of 「。」. `String.split()` scores that one "word", so
    /// pipecat's rule at min_words=1 accepts it — and an unguarded trigger would
    /// stop the answer mid-sentence. Counting content characters scores it 0.
    private static let continuousListeningMinimumInterruptContentCharacters = 4
    /// How much real content a transcript must carry to interrupt an answer
    /// when the microphone LEVEL independently confirms the user is speaking.
    ///
    /// 2, against the no-evidence bar's 4, because that bar IS the latency the
    /// user reported. Measured 2026-09-23 against the live recognizer with the
    /// app's own model (`qwen3-asr-flash-realtime`), streaming a 14-character
    /// Chinese question in the app's own 100 ms cadence: the FIRST interim
    /// lands at t=0.52 s already carrying 2 content characters (「帮我」), the
    /// next at t=0.74 s carries 3, and the first one to clear 4 arrives at
    /// t=1.44 s (「帮我看一下」) — by which time the user has spoken about 7
    /// characters, which is precisely the 「说到第 7～8 个字的时候，它才会自动
    /// 停止」 they reported. The recognizer was never the bottleneck; the bar
    /// was.
    ///
    /// What the bar exists to reject is the recognizer's OWN noise, and that
    /// noise is quiet. Measured the same day: fed a silent room, the
    /// recognizer volunteered 「嗯。」 — 1 content character — at a microphone
    /// level of 0.046, and 0.078 on another run. The app's speech threshold is
    /// 0.25 on the same boosted scale and real speech measures 0.3–1.0, so 1–2
    /// characters arriving with a corroborating level is the user, and 1–2
    /// characters arriving quietly is the recognizer inventing something.
    ///
    /// The two bars cover each other's blind spot, which is why BOTH stay: 2
    /// characters + level is the fast path, and 4 characters with no level
    /// evidence remains the fallback, so a quiet speaker degrades to exactly
    /// today's behaviour rather than to nothing.
    private static let continuousListeningMinimumCorroboratedInterruptContentCharacters = 2
    /// Characters that are actual linguistic content — letters (CJK included)
    /// and digits — with punctuation, whitespace, symbols and emoji excluded.
    ///
    /// Chinese has no spaces, so pipecat's `len(text.split())` cannot be ported
    /// literally. This counts the same thing that test counts in English: how
    /// many words the recognizer really heard, rather than how many marks it
    /// emitted into a silent room.
    private static func continuousListeningContentCharacterCount(in transcriptText: String) -> Int {
        transcriptText.reduce(into: 0) { contentCharacterCount, character in
            if character.isLetter || character.isNumber { contentCharacterCount += 1 }
        }
    }
    /// Whether a listening transcript is the app's OWN answer coming back
    /// through the microphone, not the user speaking.
    ///
    /// This is a BACKSTOP, not the defence. The defence is the system AEC on
    /// the shared playback engine (VoicePlaybackEngine's header): it removes
    /// the answer from the microphone before the recognizer ever sees it, and
    /// the 「回声消除」 setting is what turns it off. This filter covers the
    /// cases where the AEC is off, could not be enabled, or did not fully
    /// converge — a Bluetooth route with no usable reference signal, a device
    /// that refuses voice processing.
    ///
    /// Why a backstop is worth keeping, measured 2026-09-23: while an answer
    /// plays the recording mute lifts (so the user can hear it), and without
    /// AEC the answer's own audio reaches the microphone raw — the recognizer
    /// transcribes it as perfectly real words. Those words clear the
    /// ≥4-character content bar, and pipecat's `MinWordsUserTurnStartStrategy`
    /// rule cannot help, because echo of speech IS words — so the ASR
    /// barge-in path (the only path allowed to interrupt while the bot speaks)
    /// fires on them. What the framework's rule cannot know, this filter does:
    /// the app knows exactly what it is reading aloud. A transcript contained
    /// in that text is our own voice.
    ///
    /// **It cannot be the only defence, and that is the point.** The recognizer
    /// hears a MIX of our answer and the user's voice, and the transcript of a
    /// mix is unreliable in both directions: heard cleanly, our words match and
    /// are refused — which the user experiences as "it took three or four
    /// sentences to stop"; mis-heard by one character, the same words fail the
    /// containment test, are taken for the user's, and the answer interrupts
    /// itself. Both were reported on 2026-09-23, from this one filter. Un-mix
    /// the signal and neither happens.
    ///
    /// Containment, not equality: the recognizer delivers the CUMULATIVE
    /// utterance, and an echo utterance is a run of the spoken answer's own
    /// text. Both sides are reduced to letters and digits first — the
    /// recognizer's punctuation of our own voice never matches the text that
    /// was spoken mark for mark.
    static func continuousListeningTranscriptIsEchoOfSpokenAnswer(
        _ transcriptText: String,
        spokenAnswerText: String
    ) -> Bool {
        let normalizedTranscriptText = transcriptText.filter { $0.isLetter || $0.isNumber }
        // Below the interrupt bar the transcript cannot barge in on its own,
        // so there is nothing for the filter to protect against.
        guard normalizedTranscriptText.count >= continuousListeningMinimumInterruptContentCharacters else {
            return false
        }
        let normalizedSpokenAnswerText = spokenAnswerText.filter { $0.isLetter || $0.isNumber }
        guard !normalizedSpokenAnswerText.isEmpty else { return false }
        return normalizedSpokenAnswerText.contains(normalizedTranscriptText)
    }
    private static let continuousListeningSessionRetryCount = 5
    // How long the final-fallback waits after requestFinalTranscript before
    // deciding the session is dead. Measured 2026-09-23: a failing Bailian
    // websocket dies with "Socket is not connected" WITHOUT the error handler
    // firing on the listening path every time — the final simply never
    // arrives, and the window sits deaf forever (the 「说完它也不回复」
    // complaint). When the deadline passes, the latest interim transcript is
    // submitted as the final instead. Same grace figure as the push-to-talk
    // fallback above.
    // `nonisolated` because it is used as a DEFAULT ARGUMENT value, and default
    // arguments are evaluated outside the actor — a main-actor-isolated static
    // here is a warning today and an error under Swift 6.
    nonisolated private static let continuousListeningFinalGraceSeconds: TimeInterval = 2.4
    // The same fallback, for the EXPLICIT send (the talk shortcut pressed while
    // an utterance is pending). Shorter because here the user is standing by
    // waiting for the answer, and because the wait is known to be unnecessary
    // in the healthy case: measured 2026-09-23 against the live service, the
    // final lands 0.27 s after `input_audio_buffer.commit`. 2.4 s of silence
    // after an explicit "send it" reads as the feature being broken again.
    private static let continuousListeningShortcutSendGraceSeconds: TimeInterval = 0.8

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    /// The 回答时持续监听 window is open: the engine and a streaming ASR
    /// session run while the answer plays, watching for the user to speak.
    /// Deliberately NOT part of `isDictationInProgress` — the shortcut guard
    /// and the derived voice-state observation must not treat passive
    /// listening as a real recording.
    @Published private(set) var isContinuousListening = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// The transcription backend in use.
    ///
    /// Not `let`: the provider is chosen once at init from whichever backend was
    /// configured *at that moment*, so a user who had no speech-recognition
    /// credentials at launch falls back to Apple Speech — and would then stay on
    /// Apple Speech forever, no matter what they typed into the model settings
    /// window, until the app was restarted. `startRecognitionSession` re-resolves
    /// it when the current one is unusable.
    private var transcriptionProvider: any BuddyTranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    // Continuous-listening state (see the constants block above for the design).
    private var continuousListeningCallbacks: BuddyContinuousListeningCallbacks?
    private var continuousListeningVADTask: Task<Void, Never>?
    /// Provides the shared TTS playback engine (injected by CompanionManager,
    /// which owns the lazy TTS client). The listening tap installs on IT —
    /// one engine serves both halves of the voice conversation (the same-engine
    /// rule; see VoicePlaybackEngine's header). nil → the own-engine fallback
    /// below runs instead.
    var sharedVoicePlaybackEngineProvider: (() -> VoicePlaybackEngine?)?
    /// Whether the app is reading an answer aloud right now (injected by
    /// CompanionManager, which owns the lazy TTS client). `isPlaying` is true
    /// for a whole spoken reply, segment gaps included, so it is the faithful
    /// macOS equivalent of pipecat's `BotStartedSpeakingFrame` /
    /// `BotStoppedSpeakingFrame` pair — and it is what raises the bar for
    /// accepting a transcript as the user speaking. See
    /// `continuousListeningMinimumInterruptContentCharacters`.
    var isBotSpeakingProvider: (() -> Bool)?
    /// The tag-stripped text of the answer currently being read aloud — or the
    /// most recent one, because an echo transcript can arrive after the
    /// barge-in has already stopped playback. Injected by CompanionManager,
    /// which holds the exact text every TTS path feeds. The echo filter
    /// (`continuousListeningTranscriptIsEchoOfSpokenAnswer`) compares what the
    /// microphone heard against this text. The real defence is the shared
    /// engine's AEC (VoicePlaybackEngine's header); this is the backstop for
    /// when it is off or did not fully converge — on those paths the answer's
    /// own audio reaches the input while it plays (the mute lifts so the user
    /// can hear it), and the recognizer transcribes it as real words.
    var spokenAnswerTextProvider: (() -> String)?
    /// Whether the current listening window's tap lives on the shared engine
    /// (endContinuousListening must then NOT stop that engine — playback and
    /// later windows still need it, and its voice processing can only be
    /// reconfigured while it is stopped).
    private var isContinuousListeningOnSharedEngine = false
    /// Leaky accumulator of above-threshold mic level for the current
    /// window-with-no-utterance state, in seconds. Replaces a "how long has it
    /// been continuously loud" timestamp: it fills at the full poll interval
    /// while the level is up and drains at a quarter of it while the level is
    /// down, so the inter-syllable dips of ordinary speech do not reset the
    /// count (see `continuousListeningSpeechAccumulationSeconds`).
    private var continuousListeningSpeechAccumulatorSeconds: TimeInterval = 0
    /// An utterance is in progress (speech was detected, interim transcripts
    /// are accumulating); the VAD loop is now watching for it to end.
    private var continuousListeningUtteranceActive = false
    /// The barge-in callback has already fired for the utterance in progress.
    ///
    /// Separate from `continuousListeningUtteranceActive` because the two are
    /// decided by DIFFERENT evidence (see
    /// `markContinuousListeningUtteranceActive`): the level path may open an
    /// utterance without being allowed to interrupt, and the transcript path
    /// must still be able to interrupt that same utterance afterwards. One
    /// flag for both would make whichever path fired first veto the other.
    private var continuousListeningDidRequestBargeIn = false
    /// The microphone levels of the last
    /// `continuousListeningRecentLevelWindowSeconds`, refreshed by the VAD loop
    /// on its own 50 ms cadence. Read only to corroborate a SHORT transcript
    /// while an answer is being read aloud — see
    /// `continuousListeningMinimumCorroboratedInterruptContentCharacters`.
    ///
    /// Deliberately NOT cleared per utterance: the window is self-refreshing by
    /// construction, and emptying it would blind the corroboration for the half
    /// second it takes to refill, which is exactly the half second a barge-in
    /// has to fire in. It is cleared when the listening WINDOW opens and closes.
    private var continuousListeningRecentAudioLevels: [CGFloat] = []
    /// The loudest the microphone has been inside that window — the
    /// corroborating evidence a short interrupt transcript is judged against.
    private var continuousListeningRecentPeakAudioLevel: CGFloat {
        continuousListeningRecentAudioLevels.max() ?? 0
    }
    private var continuousListeningUtteranceStartedAt: Date?
    private var continuousListeningSilenceStartedAt: Date?
    /// The latest interim transcript of the current utterance. The fallback
    /// for a dead session: if `requestFinalTranscript` produces no final
    /// within the grace window, THIS text is submitted as the question
    /// instead (measured failure: the websocket dies with "Socket is not
    /// connected" and delivers neither a final nor an error event).
    private var continuousListeningLatestInterimTranscript = ""
    /// True between requestFinalTranscript and the final's arrival (or the
    /// grace fallback firing). The shortcut-send branch must not treat a
    /// "finalizing" utterance as speech-in-progress, and the fallback must
    /// not fire once a real final has landed — this flag is both gates.
    private var isContinuousListeningAwaitingFinal = false
    /// Bumped on every requestContinuousListeningFinalTranscript and captured
    /// by the grace task, so a STALE grace task (from an earlier request)
    /// can never cancel a newer request's session or submit an older
    /// interim — only the generation it was created for.
    private var continuousListeningFinalRequestGeneration = 0

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        super.init()
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    // MARK: - Continuous listening (回答时持续监听)

    /// Opens the continuous-listening window: starts the audio engine (whose
    /// voice processing is managed by the engine itself — see
    /// VoicePlaybackEngine's header), opens one streaming ASR session, and
    /// runs a local VAD loop that watches the mic level.
    ///
    /// Unlike push-to-talk, the engine KEEPS RUNNING across utterances: the
    /// tap feeds whatever `activeTranscriptionSession` currently points at, so
    /// swapping that reference after each final transcript moves the next
    /// utterance onto a fresh websocket without touching the engine (one
    /// Bailian connection carries exactly one final transcript).
    func startContinuousListening(
        utteranceEndSilenceSeconds: TimeInterval,
        onSpeechDetected: @escaping () -> Void,
        onTranscriptUpdate: @escaping (String) -> Void,
        onUtteranceFinalized: @escaping (String) -> Void
    ) async {
        guard !isContinuousListening else { return }
        guard !isDictationInProgress else { return }

        print("🎙️ BuddyDictationManager: continuous listening requested")

        // Snapshot the 「静音多久自动发送」 setting for THIS window — a change
        // mid-window must not move the VAD loop's threshold under it.
        continuousListeningUtteranceEndSilenceSeconds = utteranceEndSilenceSeconds

        if needsInitialPermissionPrompt {
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // Same reasoning as the push-to-talk start: continue into the
                // permission check even if this wait was cut short.
            }
        }

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: continuous listening blocked (permissions missing)")
            return
        }

        isContinuousListening = true
        continuousListeningCallbacks = BuddyContinuousListeningCallbacks(
            onSpeechDetected: onSpeechDetected,
            onTranscriptUpdate: onTranscriptUpdate,
            onUtteranceFinalized: onUtteranceFinalized
        )
        resetContinuousListeningUtteranceState()
        continuousListeningRecentAudioLevels.removeAll()
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        lastRecordedAudioPowerSampleDate = .distantPast

        do {
            try await openContinuousListeningEngineAndSession()
            continuousListeningVADTask = Task { [weak self] in
                await self?.runContinuousListeningVADLoop()
            }
            print("🎙️ BuddyDictationManager: continuous listening started")
        } catch {
            print("❌ BuddyDictationManager: failed to start continuous listening: \(error)")
            endContinuousListening()
        }
    }

    /// Closes the listening window: stops the VAD loop, the engine, and the
    /// ASR session. Safe to call when no window is open.
    ///
    /// On the shared TTS engine the engine is only RELEASED if idle (never
    /// stopped unconditionally — a follow-up reply may need it a moment later).
    func endContinuousListening() {
        guard isContinuousListening else { return }

        isContinuousListening = false
        continuousListeningVADTask?.cancel()
        continuousListeningVADTask = nil
        continuousListeningCallbacks = nil
        resetContinuousListeningUtteranceState()
        continuousListeningRecentAudioLevels.removeAll()

        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        if isContinuousListeningOnSharedEngine {
            isContinuousListeningOnSharedEngine = false
            sharedVoicePlaybackEngineProvider?()?.removeInputTap()
            sharedVoicePlaybackEngineProvider?()?.releaseEngineWhenIdle()
        } else {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        lastRecordedAudioPowerSampleDate = .distantPast

        print("🎙️ BuddyDictationManager: continuous listening ended")
    }

    /// Opens the first ASR session of the window and installs the tap.
    ///
    /// Voice processing is NOT enabled here: it belongs to the engine and is
    /// applied by the engine at start-up, gated on the settings
    /// (VoicePlaybackEngine's header). The tap's HOME is the shared TTS
    /// playback engine whenever that engine is available — which is exactly
    /// what makes its AEC able to cancel the answer out of the mic, since AEC
    /// only works on audio rendered through the same engine. Only when the
    /// shared engine is missing does the window fall back to this manager's
    /// own engine, and that fallback runs without AEC; the echo filter in
    /// `continuousListeningTranscriptIsEchoOfSpokenAnswer` is the backstop
    /// there.
    private func openContinuousListeningEngineAndSession() async throws {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        if !transcriptionProvider.isConfigured {
            let reResolvedProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
            if reResolvedProvider.isConfigured {
                print("🎙️ BuddyDictationManager: switching transcription provider \(transcriptionProvider.displayName) → \(reResolvedProvider.displayName)")
                transcriptionProvider = reResolvedProvider
                transcriptionProviderDisplayName = reResolvedProvider.displayName
            }
        }

        if let sharedEngine = sharedVoicePlaybackEngineProvider?() {
            do {
                // The window can open right as the first TTS chunk starts
                // (the arm happens on the first-audio hook), so the engine may
                // already be running — ensureStarted is a no-op then.
                try sharedEngine.ensureStartedForCapture()

                activeTranscriptionSession = try await openContinuousListeningTranscriptionSession()

                let sharedInputNode = sharedEngine.engineInputNode
                let inputFormat = sharedInputNode.outputFormat(forBus: 0)
                sharedEngine.installInputTap(bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                    self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
                    self?.updateAudioPowerLevel(from: buffer)
                }
                isContinuousListeningOnSharedEngine = true
                print("🎙️ BuddyDictationManager: listening tap installed on the shared TTS engine")
                return
            } catch {
                // Falling back must not leave the shared engine half-configured.
                sharedEngine.removeInputTap()
                isContinuousListeningOnSharedEngine = false
                print("⚠️ BuddyDictationManager: shared-engine listening failed (\(error)); falling back to the own engine")
            }
        }

        isContinuousListeningOnSharedEngine = false
        let inputNode = audioEngine.inputNode

        activeTranscriptionSession = try await openContinuousListeningTranscriptionSession()

        // BuddyPCM16AudioConverter rebuilds itself whenever the incoming
        // format description changes, so no extra work is needed downstream.
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func openContinuousListeningTranscriptionSession() async throws -> any BuddyStreamingTranscriptionSession {
        try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self, self.isContinuousListening else { return }
                    // Keep the cumulative interim — the dead-session fallback
                    // submits it as the final if the real final never lands.
                    // Every utterance resets the state that clears this, so a
                    // new utterance never inherits the old text.
                    let didTranscriptChange = transcriptText
                        != self.continuousListeningLatestInterimTranscript
                    self.continuousListeningLatestInterimTranscript = transcriptText
                    // Text means the user was speaking, whether or not the
                    // energy VAD agreed (see markContinuousListeningUtteranceActive)
                    // — but only once it carries real content, and while an
                    // answer is being read aloud it must carry enough of it.
                    // pipecat's rule, not a local one: a single word may open a
                    // turn when the bot is silent, a higher bar applies while
                    // the bot is speaking (MinWordsUserTurnStartStrategy). The
                    // `else` branch is not a nicety — the recognizer emits
                    // 「。」 into silence, and without this an answer would cut
                    // itself off the moment that landed.
                    let isBotSpeaking = self.isBotSpeakingProvider?() ?? false
                    // Echo of our own answer, checked BEFORE the content bar:
                    // while the answer plays (mute lifted) the recognizer can
                    // still transcribe it as real words — the AEC is what stops
                    // that, and this covers the paths where it is off or did not
                    // fully converge. Words are exactly what the content bar
                    // accepts. A transcript contained in the text being read is
                    // our own voice — it may neither interrupt nor keep an
                    // utterance's silence countdown open. See
                    // `continuousListeningTranscriptIsEchoOfSpokenAnswer`.
                    let transcriptIsOwnAnswerEcho = isBotSpeaking && Self.continuousListeningTranscriptIsEchoOfSpokenAnswer(
                        transcriptText,
                        spokenAnswerText: self.spokenAnswerTextProvider?() ?? ""
                    )
                    if transcriptIsOwnAnswerEcho {
                        if didTranscriptChange {
                            print("🎙️ BuddyDictationManager: listening transcript is our own answer's echo — not treating it as the user (transcript: \"\(transcriptText)\")")
                        }
                    } else {
                        // While the bot is speaking a SHORT transcript is
                        // trusted when the microphone independently agrees the
                        // room was loud — that is the fast path, and it fires on
                        // the recognizer's very FIRST interim (~0.5 s in, ~2
                        // characters spoken) instead of the ~1.4 s the
                        // no-evidence bar used to cost. Without the level the
                        // long bar still applies, so a quiet speaker keeps
                        // exactly the old behaviour. Both constants carry their
                        // measurements.
                        let isCorroboratedByVoiceLevel =
                            self.continuousListeningRecentPeakAudioLevel
                                >= Self.continuousListeningSpeechLevelThreshold
                        let minimumContentCharacters: Int
                        if isBotSpeaking {
                            minimumContentCharacters = isCorroboratedByVoiceLevel
                                ? Self.continuousListeningMinimumCorroboratedInterruptContentCharacters
                                : Self.continuousListeningMinimumInterruptContentCharacters
                        } else {
                            minimumContentCharacters = 1
                        }
                        if Self.continuousListeningContentCharacterCount(in: transcriptText)
                            >= minimumContentCharacters {
                            self.markContinuousListeningUtteranceActive(trigger: "ASR transcript")
                            // New words are still arriving, so the user is still
                            // talking — restart the silence countdown. This is the
                            // reference's 「有文本」 turn-end rule (pipecat's
                            // SpeechTimeoutUserTurnStopStrategy only ends a turn
                            // once text has stopped coming AND silence has
                            // sustained), and it is what keeps a voice below
                            // the energy threshold from being cut off mid-sentence
                            // by the backstop that exists to catch exactly that
                            // voice. Keyed on a CHANGE, not on every callback: a
                            // repeated identical transcript is not evidence of
                            // speech.
                            if didTranscriptChange, self.continuousListeningUtteranceActive {
                                self.continuousListeningSilenceStartedAt = nil
                            }
                        }
                    }
                    self.continuousListeningCallbacks?.onTranscriptUpdate(transcriptText)
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self, self.isContinuousListening else { return }
                    self.handleContinuousListeningFinalTranscript(transcriptText)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isContinuousListening else { return }
                    print("❌ BuddyDictationManager: continuous listening session error: \(error)")
                    Task {
                        await self.restartListeningTranscriptionSession()
                    }
                }
            }
        )
    }

    /// One final transcript has landed for the current utterance. Short/empty
    /// results (echo artefacts, a cough, nothing recognizable) are dropped;
    /// real ones are handed to the caller as a new question. Either way the
    /// next utterance needs a fresh websocket, so the session is replaced.
    private func handleContinuousListeningFinalTranscript(_ transcriptText: String) {
        // A final is only expected while a request is outstanding
        // (isContinuousListeningAwaitingFinal). Without a request, this is a
        // LATE final from a session the grace fallback already cancelled and
        // replaced — its utterance was already submitted from the interim, so
        // delivering it here would send the question twice.
        guard isContinuousListeningAwaitingFinal else {
            print("🎙️ BuddyDictationManager: ignoring a late final with no pending request (already handled by the fallback)")
            Task {
                await self.restartListeningTranscriptionSession()
            }
            return
        }

        let trimmedTranscriptText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        resetContinuousListeningUtteranceState()

        let contentCharacterCount = Self.continuousListeningContentCharacterCount(in: trimmedTranscriptText)
        if contentCharacterCount < Self.continuousListeningMinimumTranscriptCharacters {
            print("🎙️ BuddyDictationManager: listening transcript too short to send (\(contentCharacterCount) content chars: \"\(trimmedTranscriptText)\")")
        } else if Self.continuousListeningTranscriptIsEchoOfSpokenAnswer(
            trimmedTranscriptText,
            spokenAnswerText: spokenAnswerTextProvider?() ?? "") {
            // The echo check is NOT gated on the bot still speaking, on
            // purpose: an utterance opened on echo can outlive the answer (the
            // answer finishes, the level drops, the silence-send fires) and its
            // final then lands after playback stopped — by then
            // `isBotSpeakingProvider` is false and the content bar alone would
            // submit our own sentence as the user's next question.
            print("🎙️ BuddyDictationManager: listening final transcript is our own answer's echo — dropped (\"\(trimmedTranscriptText)\")")
        } else {
            continuousListeningCallbacks?.onUtteranceFinalized(trimmedTranscriptText)
        }

        Task {
            await self.restartListeningTranscriptionSession()
        }
    }

    /// Replaces the ASR session after a final transcript was delivered (the
    /// provider closes its websocket and stops accepting audio then). The
    /// engine and tap keep running; only the session reference changes.
    private func restartListeningTranscriptionSession() async {
        guard isContinuousListening else { return }

        resetContinuousListeningUtteranceState()
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        for attemptIndex in 1...Self.continuousListeningSessionRetryCount {
            do {
                let replacementSession = try await openContinuousListeningTranscriptionSession()
                guard isContinuousListening else {
                    replacementSession.cancel()
                    return
                }
                activeTranscriptionSession = replacementSession
                return
            } catch {
                print("❌ BuddyDictationManager: listening session restart failed (attempt \(attemptIndex)): \(error)")
                guard attemptIndex < Self.continuousListeningSessionRetryCount else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard isContinuousListening else { return }
            }
        }
    }

    /// The idle→utterance transition, in ONE place because there are two
    /// independent ways to discover that the user is speaking.
    ///
    /// 1. `trigger == "mic level"` — the local energy VAD's accumulator
    ///    reached its threshold. Fast.
    /// 2. `trigger == "ASR transcript"` — the speech service produced text.
    ///    This is pipecat's `TranscriptionUserTurnStartStrategy` doing the same
    ///    job in the reference: a VAD will always miss a quiet or unusual
    ///    voice, but if the recognizer heard words then the user was
    ///    unambiguously speaking. Slower to fire, and the safety net when
    ///    path 1 does not.
    ///
    /// Opening an utterance and INTERRUPTING the answer are two decisions with
    /// two different bars, and this function is where the difference lives.
    ///
    /// While an answer is being read aloud, a microphone-level rise is not
    /// evidence that the USER spoke — and treating it as evidence is what made
    /// the companion cut itself off. Measured 2026-09-23 on this machine's
    /// built-in mic + speakers, from the app's own log across 13 replies:
    /// **all 11 level-triggered barge-ins carried an EMPTY transcript**, and 6
    /// of the 13 replies were silenced by one (46%, against the 40% the user
    /// reported). The mechanism is that a level rise while the answer plays is
    /// our own audio — either the AEC's adaptive filter converging from zero
    /// at the start of a reply, or (with AEC off, or defeated by a device with
    /// no usable reference signal) the raw playback itself. In every one of
    /// those worlds a fixed threshold cannot separate "our own voice" from
    /// "the user's voice" — content is the only discriminator that survives:
    /// words mean a person spoke.
    ///
    /// This is the framework's own rule, not a local invention. pipecat's
    /// `MinWordsUserTurnStartStrategy` (user_start/min_words_user_turn_start_
    /// strategy.py:108) is `min_words if bot_speaking else 1` — a low bar while
    /// the bot is silent, a higher one while it is speaking — and the
    /// transcription path in `openContinuousListeningTranscriptionSession`
    /// already applies it. What was missing is that the LEVEL path bypassed it
    /// entirely, because both paths used to share one `onSpeechDetected`.
    ///
    /// The truth table this produces:
    ///
    ///     bot speaking?  trigger            utterance   barge-in
    ///     no             mic level          opened      yes
    ///     no             ASR transcript     opened      yes
    ///     yes            mic level          opened      no   ← echo, wait for words
    ///     yes            ASR transcript     opened      yes  ← real speech
    ///
    /// Silence is the right trade for the third row: if the recognizer cannot
    /// produce words, then stopping the answer buys nothing, because there is
    /// no follow-up question to answer — the feature's whole point is the
    /// question that comes after the interruption.
    private func markContinuousListeningUtteranceActive(trigger: String) {
        guard isContinuousListening, !isContinuousListeningAwaitingFinal else { return }

        // Decision 1: may this interrupt? Judged BEFORE the utterance-active
        // guard below, because the level path usually opens the utterance
        // first and the transcript path must still be able to interrupt it.
        let isBotSpeaking = isBotSpeakingProvider?() ?? false
        let isCorroboratedByTranscript = trigger == "ASR transcript"
        if isBotSpeaking && !isCorroboratedByTranscript {
            print("🎙️ BuddyDictationManager: continuous listening heard a level rise while speaking — waiting for words before interrupting (transcript: \"\(continuousListeningLatestInterimTranscript)\")")
        } else {
            requestContinuousListeningBargeIn(trigger: trigger)
        }

        // Decision 2: open the utterance, once. The silence countdown and the
        // maximum-utterance cap hang off this, and they apply to an
        // echo-triggered utterance harmlessly: if the user never speaks, the
        // final comes back empty and is dropped.
        guard !continuousListeningUtteranceActive else { return }
        continuousListeningUtteranceActive = true
        continuousListeningSpeechAccumulatorSeconds = 0
        continuousListeningUtteranceStartedAt = Date()
        continuousListeningSilenceStartedAt = nil
    }

    /// Tells the caller to stop the answer and take the follow-up screenshot,
    /// at most once per utterance.
    ///
    /// The transcript is logged WITH the trigger because the two paths fail
    /// differently and the text is what tells them apart: an energy fire with
    /// empty text means our own audio leaked back into the mic (echo), while
    /// an ASR fire carrying a lone 「。」 or a
    /// couple of echoed characters is the recognizer's own noise.
    private func requestContinuousListeningBargeIn(trigger: String) {
        guard isContinuousListening,
              !isContinuousListeningAwaitingFinal,
              !continuousListeningDidRequestBargeIn else { return }

        continuousListeningDidRequestBargeIn = true
        print("🎙️ BuddyDictationManager: continuous listening detected speech (\(trigger), recent mic peak \(String(format: "%.3f", continuousListeningRecentPeakAudioLevel)), transcript: \"\(continuousListeningLatestInterimTranscript)\")")
        continuousListeningCallbacks?.onSpeechDetected()
    }

    /// The local VAD loop. 50 ms polling of the existing smoothed RMS level,
    /// three states: idle (watching for speech to sustain long enough),
    /// utterance active (watching for silence to sustain long enough, or the
    /// maximum-utterance cap), and finalizing (handed to the session's
    /// requestFinalTranscript). The engine is NEVER stopped here — that is the
    /// one behavioural difference from the push-to-talk stop path.
    private func runContinuousListeningVADLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.continuousListeningVADPollInterval)
            guard isContinuousListening else { return }

            let now = Date()
            let audioLevel = currentAudioPowerLevel

            // Refresh the rolling level window the short-transcript
            // corroboration reads. Sampled here rather than in the tap so the
            // window means wall-clock time — "the last half second" — instead
            // of "however many tap buffers happened to arrive".
            continuousListeningRecentAudioLevels.append(audioLevel)
            let recentLevelSampleCount = Self.continuousListeningRecentLevelSampleCount
            if continuousListeningRecentAudioLevels.count > recentLevelSampleCount {
                continuousListeningRecentAudioLevels.removeFirst(
                    continuousListeningRecentAudioLevels.count - recentLevelSampleCount)
            }

            if continuousListeningUtteranceActive {
                let utteranceDuration = now.timeIntervalSince(continuousListeningUtteranceStartedAt ?? now)

                if utteranceDuration >= Self.continuousListeningMaximumUtteranceSeconds {
                    requestContinuousListeningFinalTranscript()
                    continue
                }

                if audioLevel < Self.continuousListeningSpeechLevelThreshold {
                    if let silenceStartedAt = continuousListeningSilenceStartedAt,
                       now.timeIntervalSince(silenceStartedAt) >= continuousListeningUtteranceEndSilenceSeconds {
                        requestContinuousListeningFinalTranscript()
                    } else if continuousListeningSilenceStartedAt == nil {
                        continuousListeningSilenceStartedAt = now
                    }
                } else {
                    continuousListeningSilenceStartedAt = nil
                }
            } else {
                // Idle: accumulate above-threshold time rather than requiring
                // an unbroken run of it (see the accumulator's declaration).
                let pollSeconds = Self.continuousListeningVADPollSeconds
                if audioLevel >= Self.continuousListeningSpeechLevelThreshold {
                    continuousListeningSpeechAccumulatorSeconds += pollSeconds
                } else {
                    continuousListeningSpeechAccumulatorSeconds = max(
                        0,
                        continuousListeningSpeechAccumulatorSeconds
                            - pollSeconds * Self.continuousListeningSpeechAccumulatorReleaseRatio
                    )
                }
                if continuousListeningSpeechAccumulatorSeconds >= Self.continuousListeningSpeechAccumulationSeconds {
                    markContinuousListeningUtteranceActive(trigger: "mic level")
                }
            }
        }
    }

    /// Whether the press has something to send. True ONLY while the listening
    /// window is open — it is the shortcut-send branch's gate: a press while
    /// this is true means "I'm done, send it", a press while it is false means
    /// "stop".
    ///
    /// The bar is the SEND path's own bar
    /// (`continuousListeningMinimumTranscriptCharacters`), deliberately: a press
    /// may only mean "send" when the send could accept the result, or the press
    /// is spent on a delivery `handleContinuousListeningFinalTranscript` drops
    /// one line later. That mismatch is the 「按两次快捷键才能停止播放」 defect
    /// (measured 2026-09-23): the recognizer emits 「啊。」/「嗯。」/「中间。」 off the
    /// assistant's own leaked audio — one or two content characters each — and
    /// every one of them cleared the old `> 0` test, so the first press went
    /// into a send that could never happen and the user had to press again to
    /// get playback stopped.
    ///
    /// Content is the ONLY evidence counted here; a confirmed utterance is
    /// deliberately not enough on its own. The energy VAD reads raw mic level,
    /// so the assistant's own residual echo trips it as readily as the user's
    /// voice — the same run logged "detected speech (mic level, transcript:
    /// \"\")" with nobody speaking. So a triggered-but-empty utterance says
    /// nothing about the user, while real speech is never empty by the time
    /// they press: the recognizer streams partial results throughout the
    /// utterance, and the press comes after the user has finished talking. Real
    /// speech below the bar is the cheaper mistake of the two — the press still
    /// does something the user can see, and they can say it again, whereas a
    /// press that does nothing at all is what they reported.
    var isContinuousListeningUtterancePending: Bool {
        guard isContinuousListening else { return false }
        // A final is already in flight (the silence window expired, or an
        // earlier press asked for one): the press means "send it now".
        if isContinuousListeningAwaitingFinal { return true }
        // Echo of our own answer must not count as pending, or the press goes
        // into a send the final handler drops one line later while playback
        // keeps running — the 「按两次快捷键才能停止播放」 shape again, this time
        // fed by the recognizer transcribing our own voice.
        if Self.continuousListeningTranscriptIsEchoOfSpokenAnswer(
            continuousListeningLatestInterimTranscript,
            spokenAnswerText: spokenAnswerTextProvider?() ?? "") {
            return false
        }
        return Self.continuousListeningContentCharacterCount(
            in: continuousListeningLatestInterimTranscript
        ) >= Self.continuousListeningMinimumTranscriptCharacters
    }

    /// The talk shortcut pressed mid-utterance is the explicit "I'm done —
    /// send it" marker (the user's design, 2026-09-23): human thinking pauses
    /// are unbounded, so no silence threshold can be the finished-speaking
    /// verdict. The shortcut bypasses the silence wait entirely and requests
    /// the final immediately.
    func finishContinuousListeningUtteranceByShortcutSend() {
        guard isContinuousListening, isContinuousListeningUtterancePending else { return }
        print("🎙️ BuddyDictationManager: talk shortcut pressed mid-utterance — sending it now")

        // Interim text with no confirmed utterance: promote it to a live
        // utterance so the shared request path (final + grace fallback) runs.
        if !continuousListeningUtteranceActive && !isContinuousListeningAwaitingFinal {
            continuousListeningUtteranceActive = true
            continuousListeningUtteranceStartedAt = Date()
        }

        // The shorter grace: the user is waiting on this send, and a healthy
        // session answers a commit in ~0.27 s (see the constant).
        requestContinuousListeningFinalTranscript(
            graceSeconds: Self.continuousListeningShortcutSendGraceSeconds
        )
    }

    /// Ends the current utterance and turns whatever audio is already in the
    /// session into a final transcript.
    ///
    /// The grace fallback is load-bearing: a Bailian websocket can die with
    /// "Socket is not connected" and deliver NEITHER a final NOR an error
    /// event (measured 2026-09-23), and without a final the utterance is
    /// never submitted and the window sits deaf — the 「说完它也不回复」
    /// failure. If the final has not landed within
    /// `continuousListeningFinalGraceSeconds`, the latest interim transcript
    /// is submitted as the final instead.
    private func requestContinuousListeningFinalTranscript(
        graceSeconds: TimeInterval = BuddyDictationManager.continuousListeningFinalGraceSeconds
    ) {
        // Capture BEFORE the reset — resetContinuousListeningUtteranceState
        // clears the interim, and the fallback may still need it.
        let fallbackTranscriptText = continuousListeningLatestInterimTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        resetContinuousListeningUtteranceState()
        isContinuousListeningAwaitingFinal = true
        continuousListeningFinalRequestGeneration += 1
        let requestGeneration = continuousListeningFinalRequestGeneration

        // The engine and tap stay up; the provider turns the audio it has
        // already received into a final transcript, whose delivery handler
        // swaps in a fresh session.
        activeTranscriptionSession?.requestFinalTranscript()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(graceSeconds))
            guard let self, self.isContinuousListening, self.isContinuousListeningAwaitingFinal else { return }
            // A newer request superseded this one (or a final landed and a new
            // request began) — this task's session is no longer the live one.
            guard self.continuousListeningFinalRequestGeneration == requestGeneration else { return }

            print("⚠️ BuddyDictationManager: no final transcript arrived in \(graceSeconds)s — submitting the interim transcript instead")
            self.isContinuousListeningAwaitingFinal = false

            // Cancel BEFORE submitting: a dead session delivering a late
            // final would double-submit the utterance. The replacement
            // session below is what the next utterance speaks into.
            self.activeTranscriptionSession?.cancel()
            self.activeTranscriptionSession = nil

            if fallbackTranscriptText.count >= Self.continuousListeningMinimumTranscriptCharacters,
               !Self.continuousListeningTranscriptIsEchoOfSpokenAnswer(
                    fallbackTranscriptText,
                    spokenAnswerText: self.spokenAnswerTextProvider?() ?? "") {
                self.continuousListeningCallbacks?.onUtteranceFinalized(fallbackTranscriptText)
            } else if fallbackTranscriptText.count >= Self.continuousListeningMinimumTranscriptCharacters {
                print("🎙️ BuddyDictationManager: fallback interim transcript is our own answer's echo — dropped (\"\(fallbackTranscriptText)\")")
            } else {
                print("🎙️ BuddyDictationManager: fallback interim transcript too short to send (\(fallbackTranscriptText.count) chars)")
            }

            await self.restartListeningTranscriptionSession()
        }
    }

    private func resetContinuousListeningUtteranceState() {
        continuousListeningSpeechAccumulatorSeconds = 0
        continuousListeningUtteranceActive = false
        continuousListeningDidRequestBargeIn = false
        continuousListeningUtteranceStartedAt = nil
        continuousListeningSilenceStartedAt = nil
        continuousListeningLatestInterimTranscript = ""
        isContinuousListeningAwaitingFinal = false
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()

        resetSessionState()
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // If the task is cancelled while we are waiting for macOS to bring
            // the app forward, we can safely continue into the permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        // Double insurance: CompanionManager ends the listening window before it
        // starts a real recording, but a stray start arriving mid-window must
        // not silently fight the listening session over the single engine.
        guard !isContinuousListening else { return }
        guard !isDictationInProgress else { return }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        do {
            try await startRecognitionSession()
            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                activeTranscriptionSession?.cancel()
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private func startRecognitionSession() async throws {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        // The provider was picked at init from what was configured then. If it is
        // still unusable, re-resolve now — this is the path that makes a model
        // configured in the settings window take effect on the next push-to-talk
        // instead of on the next launch.
        if !transcriptionProvider.isConfigured {
            let reResolvedProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
            if reResolvedProvider.isConfigured {
                print("🎙️ BuddyDictationManager: switching transcription provider \(transcriptionProvider.displayName) → \(reResolvedProvider.displayName)")
                transcriptionProvider = reResolvedProvider
                transcriptionProviderDisplayName = reResolvedProvider.displayName
            }
        }

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")

        let activeTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.latestRecognizedText = transcriptText
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        self.activeTranscriptionSession = activeTranscriptionSession
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't transcribe that. try again."
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
        let finalTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else { return }

        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    private func buildTranscriptionKeyterms() -> [String] {
        // Vocabulary the speech recognizer is likely to meet in this app's
        // conversations. Kept in sync with the models the app actually calls —
        // naming a provider the app no longer uses only biases the recognizer
        // toward words the user is unlikely to say.
        let baseKeyterms = [
            "Clicky",
            "Bailian",
            "Qwen",
            "DashScope",
            "SwiftUI",
            "Xcode",
            "Vercel",
            "Next.js",
            "localhost"
        ]

        // Keyterms the user added in the settings window (听 → 热词), one per
        // line. They join the built-in list rather than replacing it: the base
        // terms describe the app itself, which the user did not opt out of.
        let extraKeyterms = AppSettingsStore.snapshot()
            .extraTranscriptionKeyterms
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        let combinedKeyterms = baseKeyterms + extraKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}
