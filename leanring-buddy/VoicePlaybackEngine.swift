//
//  VoicePlaybackEngine.swift
//  leanring-buddy
//
//  The shared audio engine for BOTH halves of the voice conversation: TTS
//  playback (AVAudioPlayerNode) and continuous-listening capture (the input
//  tap).
//
//  WHY THE TTS AND THE MICROPHONE SHARE ONE ENGINE — the AEC, and it is the
//  reason this class exists at all. Voice processing cancels "any of the audio
//  that is played from the device at a given time from the incoming audio"
//  (AVAudioIONode.h, setVoiceProcessingEnabled:error:), and it can only do that
//  for audio rendered through the SAME engine. Playing the answer through one
//  engine while listening on another leaves the answer in the microphone — for
//  the recognizer to transcribe as if the user had said it.
//
//  VOICE PROCESSING WAS REMOVED EARLIER ON 2026-09-23 AND IS BACK THE SAME DAY,
//  this time with the ducking turned down. The removal was never about the AEC
//  being wrong: enabling VPIO marks the app as a "communication" app and macOS
//  then DUCKS every other application's audio for as long as the engine runs
//  (the FaceTime behaviour; third-party utilities like Unduck-Pro exist purely
//  to fight it), and with 持续监听 holding the engine up for whole listening
//  windows every other app on the machine was attenuated to a whisper — the
//  user's 「任何一个软件的音量都被降到了非常低的程度」.
//
//  What the removal cost, measured 2026-09-23 and reported by the user the same
//  day: with no AEC the answer reaches the microphone raw while it plays (the
//  recording mute has to lift so the user can hear it), and the recognizer
//  transcribes OUR OWN ANSWER as perfectly real words. That one fact produced
//  BOTH reported failures, in opposite directions:
//
//    * heard correctly, our words matched the text-level echo filter
//      (BuddyDictationManager.continuousListeningTranscriptIsEchoOfSpokenAnswer)
//      and were correctly refused as a barge-in — so the answer kept playing
//      over the user's real speech, and interrupting seemed to need three or
//      four sentences;
//    * mis-heard by a single character, the same words failed that filter's
//      containment test, were taken for the user's, and the answer interrupted
//      itself — the self-interruption the user reported twice.
//
//  No text filter can win that: on a mixed signal the transcript is unreliable
//  in both directions. The fix is to un-mix the signal, and the ducking that
//  forced the removal is CONFIGURABLE on macOS 14 — which is what makes it
//  possible to have the AEC back without the volume complaint:
//
//      inputNode.voiceProcessingOtherAudioDuckingConfiguration =
//          AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
//              enableAdvancedDucking: false,   // never duck harder on voice activity
//              duckingLevel: .min)             // the mildest base ducking offered
//
//  Apple's own sample for this is `setVoiceProcessingEnabled(true)` followed by
//  a ducking configuration (WWDC23 session 10235, "What's new in voice
//  processing"), and the header documents the default as "disable advanced
//  ducking, with a ducking level set to
//  AVAudioVoiceProcessingOtherAudioDuckingLevelDefault" — the level that caused
//  the complaint was therefore the DEFAULT level, and `.min` is strictly below
//  it. 「回声消除」 (AppSettings.echoCancellationEnabled, default on) is the
//  user's way back out if their music dips.
//
//  TWO ORDERING RULES COME WITH IT, and both are measured rather than assumed.
//  Voice processing can only be toggled while the engine is stopped
//  (AVAudioIONode.h), so it is applied at every engine start — which is also
//  what makes a settings change land on the next reply instead of mid-answer,
//  since the engine is released whenever it goes idle. And the main mixer node
//  has to be touched BEFORE voice processing is enabled, or the engine will not
//  start at all: see `warmUpMainMixerNode` for the four-variant measurement and
//  for the -10875 that used to cost every reply its first spoken segment.
//
//  Voice processing is applied only when it is actually wanted
//  (`isEchoCancellationWantedProvider`): with 持续监听 off this engine never
//  carries a microphone tap, so there is nothing for an AEC to do and no reason
//  to pay its price. The engine is started on demand (first playback or first
//  listening tap) and stopped again when both go idle, so neither the
//  microphone route nor the ducking is held open permanently between replies.
//
//  THE DUCKING IS SCOPED TO PLAYBACK BY RUNNING TWO ENGINES, and that is the
//  other half of the same complaint. Applying the AEC only when it is *wanted*
//  was not enough: the listening window keeps an engine running for up to 30 s
//  after an answer with nothing playing, so the voice-processing IO ducked every
//  other application for that whole window — reported as 「按键之前和之后都压低了
//  电脑的系统音量… 正常情况下，用户没有使用这个软件… 的时候，不应该也压低音量」.
//
//  THE OBVIOUS FIX IS THE ONE THAT DOES NOT WORK, and the measurement is worth
//  keeping: turning voice processing OFF on the live engine while keeping the
//  tap. Measured 2026-09-23 with a probe that instruments FRAMES rather than
//  callbacks — the decisive number, because a tap whose callbacks fire with no
//  frames in them starves the recognizer just the same. With voice processing on,
//  the tap delivers 48000 frames/s (real time). After
//  `setVoiceProcessingEnabled(false)` plus a restart it delivers **0 callbacks
//  and 0 frames**, under every reinstall format tried (the old format,
//  `outputFormat(forBus: 0)`, `nil`, and `inputFormat(forBus: 0)`). Adding
//  `reset()` does not recover it either: it leaves `inputFormat(forBus: 0)` at
//  `48000 Hz / 0 ch` and the next `start()` fails -10875 with
//  `IsFormatSampleRateAndChannelCountValid`. A *fresh* engine, by contrast, pulls
//  a tap at 48000 frames/s with no voice processing and no downstream connection
//  at all. The toggle reconfigures the whole IO and this engine does not come
//  back from it — which is precisely the situation `AVAudioEngine.h:561`
//  documents a way out of: "For applications which may need to dynamically switch
//  between output-only and input-output modes, it may be advantageous to use two
//  engine instances."
//
//  So there are two engines, and the microphone MOVES between them. `engine` is
//  the playback engine: player node, time-pitch node, voice processing, and the
//  tap whenever there is audio to cancel. `captureOnlyEngine` has NO voice
//  processing and holds the tap whenever nothing is playing — the state that used
//  to duck the rest of the machine. Exactly one of them runs at a time, and the
//  tap lives on the one that runs: that is what keeps the AEC working (it only
//  cancels audio rendered through the same engine) while nothing is ducked for.
//  The hand-off happens at `releaseEngineWhenIdle` (playback ended, the window is
//  still listening) and at `ensureEngineStarted` (the next chunk), and the tap's
//  handler and buffer size are kept so it can be moved without the capture side
//  knowing — see `installInputTap`.
//

import AVFoundation
import Foundation

@MainActor
final class VoicePlaybackEngine {

    private let engine = AVAudioEngine()
    /// The second engine, and it is the reason the listening window no longer
    /// ducks the rest of the machine: it NEVER has voice processing enabled, so
    /// while it is the one running, this app is not in macOS's "communication
    /// app" class. It carries the microphone whenever there is nothing to cancel
    /// — see the file header for the measurement that rules out doing this with
    /// one engine, and `AVAudioEngine.h:561` for Apple's own recommendation.
    private let captureOnlyEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Playback-rate unit for the TTS chunks — the AVAudioEngine equivalent of
    /// `AVAudioPlayer.enableRate` + `rate`, but pitch-preserving.
    ///
    /// Deliberately `AVAudioUnitTimePitch`, NOT `AVAudioUnitVarispeed`.
    /// Varispeed is a tape-speed unit: it resamples, so the pitch moves with
    /// the rate. Measured 2026-09-23 (probe: same WAV, same graph, each unit
    /// rendered offline at 1.0 and 1.4 — at 1.0 both pass through bit-identical
    /// at RMS 0.1501, and at 1.4 both compress to the same duration, 2.16 s →
    /// 1.62 s):
    ///
    ///     Varispeed 1.4x  F0 ≈ 321.9 Hz   (ratio vs TimePitch = 1.38 ≈ the rate)
    ///     TimePitch 1.4x  F0 ≈ 233.3 Hz   (ratio 1.0 — pitch untouched)
    ///
    /// The user's 语速 is 1.4 (AppSettings.speechPlaybackRate), so varispeed
    /// played the cloned 赵今麦 voice a perfect fourth high — reported as
    /// 「音色还是机器人的音色，不是赵今麦的音色」. TimePitch stretches time
    /// without moving the fundamental, so 语速 changes speed only.
    private let timePitchNode = AVAudioUnitTimePitch()

    private var isEngineStarted = false

    /// Whether `playerNode` and `timePitchNode` have been attached to `engine`.
    ///
    /// `AVAudioEngine.attach` takes ownership of a NEW node, so attaching the
    /// same one twice is meaningless — the graph is built once. This exists so
    /// `ensureEngineStarted` can be re-entered (which it now must be, whenever
    /// the engine stopped without telling `isEngineStarted`) without re-attaching.
    private var hasAttachedPlaybackNodes = false

    /// The bring-up currently in flight, so a second caller awaits it instead of
    /// starting another one. See the mutual-exclusion comment in
    /// `ensureEngineStarted` for the measurement that makes this necessary.
    private var engineBringUpTask: Task<EngineBringUpResult, Error>?

    /// The `AVAudioEngineConfigurationChange` registration — see `init`.
    private var configurationChangeObserver: NSObjectProtocol?

    /// Consecutive TTS chunks this engine could not play because it was not
    /// running. See the threshold's use in `playWAVData`.
    private var consecutiveUnplayableChunkCount = 0
    private static let consecutiveUnplayableChunkThreshold = 3
    /// True while the capture-only engine is running. It is started by
    /// `installInputTap` (with the tap already on it, the order the own-engine
    /// path uses) and stopped by whichever caller takes the tap away.
    private var isCaptureOnlyEngineStarted = false

    /// Which engine currently carries the listening tap. Exactly one engine runs
    /// at a time and the tap lives on THAT one, so this single value is the whole
    /// truth about where the microphone is — and therefore about whether voice
    /// processing (and its ducking) is running.
    private enum InputTapHost {
        case none
        /// The playback engine: voice processing on, so the answer being played
        /// is cancelled out of the microphone before the recognizer sees it.
        case playbackEngine
        /// The capture-only engine: no voice processing, so nothing is ducked.
        case captureOnlyEngine
    }
    private var inputTapHost: InputTapHost = .none

    /// True while a listening tap is installed — the engine carrying it must
    /// never be released underneath a live tap.
    private var isInputTapped: Bool { inputTapHost != .none }

    /// Where `installInputTap` will put the tap, decided by
    /// `prepareCaptureHost` just before the ASR session is opened. Kept rather
    /// than re-derived so the two calls cannot disagree if playback starts in
    /// between.
    private var preparedCaptureHost: InputTapHost = .none

    /// The handler and buffer size of the installed listening tap, kept so the
    /// tap can be MOVED between the two engines. The FORMAT is deliberately not
    /// kept: each engine hands out its own, and putting a tap on with the other
    /// engine's format is exactly the silent failure this avoids.
    private var installedInputTapHandler: AVAudioNodeTapBlock?
    private var installedInputTapBufferSize: AVAudioFrameCount = 1024

    /// Whether the system AEC should be enabled the next time the engine
    /// starts. Injected by CompanionManager, which reads it from the settings:
    /// it is wanted while 持续监听 is on (the only case in which this engine
    /// carries a microphone tap, and therefore the only case with an echo
    /// problem at all) and while the user has not switched 「回声消除」 off.
    ///
    /// Evaluated at every engine start rather than cached, and voice processing
    /// can only be toggled while the engine is STOPPED (AVAudioIONode.h), so a
    /// settings change takes effect at the next start — which is the next
    /// reply, since the engine is released whenever it goes idle.
    var isEchoCancellationWantedProvider: (() -> Bool)?

    /// True when the engine currently running has voice processing on. Not the
    /// same question as the setting: enabling it can fail (no microphone
    /// permission, a device that does not support it), and the log line has to
    /// say which of the two actually happened.
    ///
    /// Readable outside the class (internal getter) because the barge-in gate
    /// reads it: the mic-LEVEL path may interrupt a playing answer only while
    /// the AEC is genuinely up — see BuddyDictationManager's
    /// `markContinuousListeningUtteranceActive` for the measured reasoning.
    private(set) var isEchoCancellationActive = false

    /// True when the chunk currently scheduled on the player node is being
    /// played back. The analogue of `AVAudioPlayer.isPlaying` for the chunk
    /// level; the client's `isSpeakingChunkSequence` covers the gaps between
    /// chunks exactly as it did before.
    private(set) var isChunkPlaying = false

    /// TEMPORARY PROBE (2026-09-24) — see `installPlaybackRenderProbe`.
    private var playbackRenderProbeCounter = 0

    /// The engine-side format playback buffers are converted into. Read once
    /// when the graph is first connected; every chunk after that converts to
    /// it, so a provider returning a different sample rate never forces the
    /// stop-disconnect-reconnect dance.
    private var canonicalPlaybackFormat: AVAudioFormat?

    init() {
        // Voice processing is not enabled here — it is applied per engine run
        // in `ensureEngineStarted`, and only when the settings ask for it. See
        // the file header for why it exists, why it was removed earlier on
        // 2026-09-23, and why it is back with a ducking level of `.min`.
        //
        // What DOES have to happen here is the one ordering rule that must
        // precede every `setVoiceProcessingEnabled` in this process: the
        // capture-only engine's input node is instantiated NOW, while nothing
        // has touched voice processing yet.
        //
        // `AVAudioEngine.inputNode` is created lazily on first access, and the
        // node fixes its format from the hardware AT THAT MOMENT. Voice
        // processing reconfigures the whole IO into its communication-app shape
        // (48 kHz / 3 input channels on this machine, against 48 kHz / 1
        // channel before), so an input node first created while voice
        // processing is up — or in the instant it is being torn down — comes
        // out bound to a format that no longer exists, and its tap is then fed
        // **0 frames, forever**. Measured 2026-09-23 with the hand-off as it
        // stood then: 0 callbacks / 0 frames in 3 s, with the default input
        // device still reporting 3 channels. Touching the node here instead is
        // the same hand-off that then measured 46400 frames/s (real time) with
        // the device back at 1 channel — see `handCaptureToCaptureOnlyEngine`
        // for the other half of the requirement.
        //
        // The read is deliberately discarded: this is an ordered side effect
        // that brings the node into existence, not a format to keep. The tap
        // still reads its own format at install time, so an input device
        // swapped between replies is picked up as it always was.
        _ = captureOnlyEngine.inputNode.outputFormat(forBus: 0)

        // Apple's own requirement, and the trigger for everything above.
        // `AVAudioEngine.h:1036-1062`: "When the engine's I/O unit observes a
        // change to the audio input or output hardware's channel count or sample
        // rate, **the engine stops itself** … and issues this notification …
        // the app must reestablish connections." Nothing here observed it, and
        // this app GENERATES these notifications itself — enabling voice
        // processing reconfigures the whole IO (the file's own measurement,
        // 44.1 kHz / 1 ch → 48 kHz / 9 ch), which is exactly a channel-count and
        // sample-rate change. So every reply stopped the engine on purpose and
        // then never restarted it.
        //
        // Only the bookkeeping is cleared here; `ensureEngineStarted` rebuilds
        // lazily, immediately before the next chunk is scheduled. The header
        // warns against deallocating the engine inside the handler, and this
        // does not touch it.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEngineStarted, !self.engine.isRunning else { return }
                print("🔊 VoicePlaybackEngine: the audio configuration changed and the engine stopped itself (voice processing toggles do this on purpose) — it will be rebuilt before the next chunk")
                self.isEngineStarted = false
            }
        }
    }

    // MARK: - Capture surface (continuous listening)

    /// Chooses the engine that will carry the listening tap, and says so.
    ///
    /// Called by the capture path immediately before it opens the ASR session,
    /// so that the session's first buffer is fed rather than dropped.
    ///
    /// The choice follows the audio: if the playback engine is running then an
    /// answer is being spoken, and the tap belongs THERE — voice processing only
    /// cancels audio rendered through its own engine, so a tap anywhere else
    /// would hand the recognizer this app's own voice to transcribe as the
    /// user's. With nothing playing there is nothing to cancel, so the tap goes
    /// to the engine without voice processing and the rest of the machine is left
    /// alone.
    ///
    /// Deliberately starts nothing: the capture-only engine is started by
    /// `installInputTap` with the tap already installed, which is the order the
    /// own-engine fallback uses and the configuration that was measured pulling
    /// frames.
    func prepareCaptureHost() {
        // ONE engine, always. The capture-only engine is never used again, and
        // the measurement that retired it is the whole reason this app had no
        // sound (2026-09-24, from the app's own log):
        //
        //     ⚠️ skipping a TTS chunk — the engine is not running   (×6, whole reply)
        //
        // Between those two lines the only thing that runs is the hand-off back
        // from the capture-only engine — `takeCaptureBackForPlayback` removes its
        // tap and calls `stopCaptureOnlyEngine()`. Stopping the second engine
        // kills the FIRST one, because both are AVAudioEngines on the same input
        // device and voice processing has configured that device into its
        // communication shape; tearing one down takes the shared IO with it. The
        // reply is then mute, and the microphone is left un-cancelled — which is
        // where the mic peaks of 1.000 while the answer plays come from, and
        // those in turn are what made the reply interrupt itself and the silence
        // countdown never finish.
        //
        // One engine is also the reference's own rule, and it is the one it
        // records as ARCHITECTURAL rather than tunable: 「音频采集+播放必须都在
        // WebRTC 里 —— 挪出去会导致浏览器 AEC 失灵 → 自己打断自己」, 教训
        // 「浏览器回声消除依赖传输形态，架构级约束」 (实现方案/08-踩坑总表.md:11).
        // The cost is the one the second engine existed to avoid: while a
        // listening window is open this app is in macOS's communication-app
        // class, so other audio is ducked — at `.min`, and only while the
        // microphone is actually open. 「回声消除」 is the user's way out.
        preparedCaptureHost = .playbackEngine
        print("🎙️ VoicePlaybackEngine: the listening tap will go on the playback engine (one engine for capture and playback — the reference's rule, 坑 1)")
    }

    /// Installs the continuous-listening mic tap on whichever engine
    /// `prepareCaptureHost` chose, starting that engine if it is the
    /// capture-only one.
    ///
    /// The FORMAT is read here rather than passed in, because it belongs to the
    /// host engine: the two engines run at different formats (voice processing
    /// reconfigures the whole IO), and a tap installed with the other engine's
    /// format delivers silence rather than an error.
    ///
    /// The handler and buffer size are remembered so the tap can be moved when
    /// playback starts or ends — see `handCaptureToCaptureOnlyEngine` and
    /// `takeCaptureBackForPlayback`.
    func installInputTap(bufferSize: AVAudioFrameCount, handler: @escaping AVAudioNodeTapBlock) async throws {
        installedInputTapHandler = handler
        installedInputTapBufferSize = bufferSize

        // There is exactly one host now (see `prepareCaptureHost`), so the stale
        // snapshot that used to decide here — and the second engine it could
        // choose — are both gone. The tap always goes on the engine whose voice
        // processing can cancel the answer out of the microphone; with nothing
        // playing there is nothing to cancel, and the engine is simply left
        // running until the window closes.
        if !isEngineStarted {
            try await ensureEngineStarted()
        }
        installTapOnPlaybackEngine(handler: handler, bufferSize: bufferSize)
    }

    /// Puts the listening tap on the playback engine. The one way this is done,
    /// so the three paths that move the microphone here — the window opening
    /// while an answer plays, a new answer starting mid-window, and the
    /// capture-only fallback — cannot disagree about the format or the buffer
    /// size.
    ///
    /// The FORMAT is read from THIS engine's input node, never carried over
    /// from the other engine: the two run at different formats (voice
    /// processing reconfigures the whole IO), and a tap installed with the
    /// other engine's format delivers silence rather than an error.
    private func installTapOnPlaybackEngine(
        handler: @escaping AVAudioNodeTapBlock,
        bufferSize: AVAudioFrameCount
    ) {
        let playbackInputNode = engine.inputNode
        // TEMPORARY PROBE (2026-09-24). The engine's own log shows playback
        // starting and then nothing ever again — no `playback loop exited`, no
        // barge-in — which means `.dataPlayedBack` never fired and
        // `waitUntilPlaybackFinishes` is spinning. The tap below is installed
        // moments after `playerNode.play()`, on a RUNNING engine with voice
        // processing on, so these two lines say whether that is what kills the
        // render.
        playbackInputNode.removeTap(onBus: 0)
        playbackInputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: playbackInputNode.outputFormat(forBus: 0),
            block: handler
        )
        inputTapHost = .playbackEngine
    }

    func removeInputTap() {
        switch inputTapHost {
        case .none:
            // Falls through to the two lines below on purpose, and the `break`
            // is load-bearing: `.none` already means "no engine carries the
            // tap", but the REMEMBERED HANDLER still has to be cleared, and it
            // is the flag every deferred path reads before it places one. An
            // early `return` here would leave the handler behind, and the
            // hand-off in `handCaptureToCaptureOnlyEngine` — which finishes
            // inside a Task, i.e. after this window has closed — would then
            // install a tap on an engine nobody is listening to.
            break
        case .playbackEngine:
            engine.inputNode.removeTap(onBus: 0)
        case .captureOnlyEngine:
            captureOnlyEngine.inputNode.removeTap(onBus: 0)
            stopCaptureOnlyEngine()
        }
        inputTapHost = .none
        installedInputTapHandler = nil

        // Deliberately does NOT release the engine any more (2026-09-24).
        //
        // Releasing at the end of every listening window made each NEW question
        // pay the voice-processing IO reconfiguration again — measured as ~3 s
        // from the reply card to the first sound, against ~1.1 s on a follow-up
        // inside an open window. The engine is now held until
        // `AppSettings.audioEngineIdleReleaseMinutes` of inactivity have passed
        // (or the release shortcut is pressed), which pays that cost once.
        //
        // The price is real and the setting's own text says so: a held engine
        // keeps the app in macOS's communication-app class, so other audio stays
        // ducked, and it keeps the microphone route open.
    }

    /// Stops the engine and gives the machine's audio back, now.
    ///
    /// The idle timer's and the release shortcut's way in. The engine can only
    /// have voice processing switched off while it is stopped (AVAudioIONode.h),
    /// and switching it off — not stopping — is what ends the ducking, which is
    /// why both happen here together.
    func releaseNow() {
        guard isEngineStarted else {
            // Nothing running, but voice processing can still be on from a
            // previous run of this method's own failure path.
            try? releaseVoiceProcessingForCaptureOnlyRun()
            return
        }
        engine.stop()
        isEngineStarted = false
        do {
            try releaseVoiceProcessingForCaptureOnlyRun()
            print("🔊 VoicePlaybackEngine: engine released — voice processing off, nothing else is ducked")
        } catch {
            print("⚠️ VoicePlaybackEngine: engine released, but voice processing would not switch off (\(error.localizedDescription)) — the rest of the machine stays ducked until the next release")
        }
    }

    /// Puts the tap on the capture-only engine and starts it. The engine itself
    /// is prepared and started only after the tap is on, matching the own-engine
    /// fallback in `BuddyDictationManager` — the tested order.
    private func startCaptureOnlyEngineWithTap(
        handler: @escaping AVAudioNodeTapBlock,
        bufferSize: AVAudioFrameCount
    ) throws {
        let captureOnlyInputNode = captureOnlyEngine.inputNode
        captureOnlyInputNode.removeTap(onBus: 0)
        let captureOnlyTapFormat = captureOnlyInputNode.outputFormat(forBus: 0)
        // The format this tap is bound to is worth a log line of its own: a tap
        // installed against a format the hardware is not running delivers ZERO
        // frames and no error, which is indistinguishable from a dead
        // microphone everywhere else. Measured 2026-09-23 as the failure mode of
        // the whole hand-off until `init` and the voice-processing toggle above
        // were both in place.
        print("🎙️ VoicePlaybackEngine: capture-only engine starting — input node \(Int(captureOnlyTapFormat.sampleRate)) Hz / \(captureOnlyTapFormat.channelCount) ch, running=\(captureOnlyEngine.isRunning)")
        captureOnlyInputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: captureOnlyTapFormat,
            block: handler
        )
        captureOnlyEngine.prepare()
        try captureOnlyEngine.start()
        isCaptureOnlyEngineStarted = true
        inputTapHost = .captureOnlyEngine
    }

    private func stopCaptureOnlyEngine() {
        guard isCaptureOnlyEngineStarted else { return }
        captureOnlyEngine.stop()
        isCaptureOnlyEngineStarted = false
    }

    /// Stops the engine when nothing needs it, so the mic route is not held
    /// open between replies — and when the listening window is what is keeping
    /// playback alive, MOVES THE MICROPHONE to the engine that has no voice
    /// processing, so the rest of the window stops being a "communication app"
    /// call and macOS stops ducking every other app for it.
    ///
    /// Deliberately refuses while a chunk is playing. The two callers that
    /// matter (`BailianTTSClient`'s chunk loop and streaming session) clear
    /// `isSpeakingChunkSequence` and then call this synchronously in the same
    /// main-actor turn, so no newer playback can have started in between and
    /// `isChunkPlaying` is the whole truth about whether a stop is safe here.
    /// Switches voice processing off on the STOPPED playback engine, and it is
    /// the call that hands the input device back to its normal configuration —
    /// and therefore the one that ends the ducking of every other app.
    ///
    /// A stopped engine whose voice processing is still enabled keeps the input
    /// device in the communication-app shape, so "the engine is not running" is
    /// NOT the same thing as "nothing is being ducked" — which is exactly the
    /// failure the user reported: audio stayed quiet after the answer had
    /// finished and the app was doing nothing at all. Measured 2026-09-23 on
    /// the release path: engine stopped, default input device still reporting 3
    /// channels (the voice-processing configuration) against 1 channel before
    /// any of this ran.
    ///
    /// Only legal while the engine is stopped (AVAudioIONode.h), which is why
    /// every caller stops first. A no-op when it is already off, so the callers
    /// can call it unconditionally — including when the user has switched
    /// 「回声消除」 off in the settings.
    private func releaseVoiceProcessingForCaptureOnlyRun() throws {
        guard engine.inputNode.isVoiceProcessingEnabled else { return }
        try engine.inputNode.setVoiceProcessingEnabled(false)
        isEchoCancellationActive = false
    }

    /// Hand-off #1: playback has ended, the listening window is still open.
    ///
    /// The order is the whole point and it is deliberate. The playback engine
    /// stops FIRST, so there is never a moment with two live microphones feeding
    /// the recognizer; a doubled buffer duplicates a syllable, which corrupts the
    /// transcript, and the few milliseconds of missing audio this costs cannot.
    /// Voice processing is then switched OFF on the stopped engine, because
    /// stopping it is NOT enough to give the input device back — see below.
    ///
    /// The start of the capture-only engine is the one part that cannot happen
    /// in this same turn, and it is a measured race rather than caution: see
    /// `captureOnlyHandoffSettleNanoseconds`.
    ///
    /// A failure here is not allowed to leave the window deaf, so it puts the tap
    /// back where it was — ducking included. The ducking is the lesser problem,
    /// and the whole point of this method is that it is a problem at all rather
    /// than a broken microphone.
    private func handCaptureToCaptureOnlyEngine() {
        guard let tapHandlerToMove = installedInputTapHandler else {
            // No handler to move: the tap is not ours to relocate. Stop the
            // engine and release voice processing with it — stopping is NOT
            // what ends the ducking, so leaving this branch without the release
            // is precisely the "the machine is quiet while the app is doing
            // nothing" failure. See `releaseVoiceProcessingForCaptureOnlyRun`.
            engine.stop()
            isEngineStarted = false
            do {
                try releaseVoiceProcessingForCaptureOnlyRun()
            } catch {
                print("⚠️ VoicePlaybackEngine: voice processing would not switch off (\(error.localizedDescription)) — the rest of the machine stays ducked until the next reply")
            }
            return
        }
        let tapBufferSizeToMove = installedInputTapBufferSize

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isEngineStarted = false
        inputTapHost = .none

        do {
            // LOAD-BEARING, and it is the other half of the ordering rule in
            // `init`. It can only be toggled while the engine is stopped
            // (AVAudioIONode.h), which is why it sits after the stop above
            // rather than before it. See
            // `releaseVoiceProcessingForCaptureOnlyRun` for the measurement
            // that makes it a requirement rather than housekeeping.
            try releaseVoiceProcessingForCaptureOnlyRun()
        } catch {
            print("⚠️ VoicePlaybackEngine: voice processing would not switch off (\(error.localizedDescription)) — putting the microphone back on the playback engine")
            restorePlaybackEngineTap(handler: tapHandlerToMove)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.captureOnlyHandoffSettleNanoseconds)

            // The window may have closed while we waited (`removeInputTap`
            // clears the handler), in which case there is no tap left to place.
            guard self.installedInputTapHandler != nil else { return }

            // ...or a new answer may have started. Playback is the case that
            // needs voice processing, so the tap belongs on THAT engine, and
            // placing it here is what keeps this from being the one path that
            // leaves the window with no microphone at all.
            if self.isEngineStarted {
                self.installTapOnPlaybackEngine(handler: tapHandlerToMove, bufferSize: tapBufferSizeToMove)
                print("🎙️ VoicePlaybackEngine: a new answer started while the microphone was moving — it went to the playback engine instead")
                return
            }

            do {
                try self.startCaptureOnlyEngineWithTap(
                    handler: tapHandlerToMove,
                    bufferSize: tapBufferSizeToMove
                )
                print("🎙️ VoicePlaybackEngine: nothing playing — the microphone moved to the capture-only engine and voice processing is off, so no other app is ducked")
            } catch {
                print("⚠️ VoicePlaybackEngine: the capture-only engine would not start (\(error.localizedDescription)) — putting the microphone back on the playback engine")
                self.restorePlaybackEngineTap(handler: tapHandlerToMove)
            }
        }
    }

    /// How long to wait between switching voice processing off and starting the
    /// capture-only engine, and it is measured rather than guessed.
    ///
    /// Switching voice processing off reconfigures the input device, and that
    /// reconfiguration lands ASYNCHRONOUSLY: a capture-only engine started in
    /// the same turn comes up running, reports the right format, sits on a
    /// device that reports the right channel count — and receives **zero
    /// frames, zero callbacks, forever**. Measured 2026-09-23 (probe: repeat
    /// 「playback with voice processing → stop → voice processing off → start
    /// the capture-only engine」, four runs per delay, counting the frames the
    /// tap received over 1.5 s):
    ///
    ///     no wait      3 of 4 failed (0 frames)
    ///     0.05 s       0 of 4
    ///     0.10 s       0 of 4
    ///     0.20 s       0 of 4
    ///
    /// Re-running the same hand-off without any wait a second time always
    /// worked, which is what identifies this as a settling window rather than a
    /// permanent failure — and waiting is the fix rather than retrying, because
    /// detecting "no frames arrived" would cost the window a silence of its own.
    /// 120 ms is 2.4× the shortest delay that measured clean, and it is
    /// inaudible where it lands: this runs after the answer has finished
    /// playing, and a person needs longer than that to start speaking.
    private static let captureOnlyHandoffSettleNanoseconds: UInt64 = 120_000_000

    /// Puts the listening tap back on the playback engine and restarts it. Used
    /// only when the capture-only hand-off failed: a window that can hear is
    /// worth more than a window that does not duck.
    ///
    /// Voice processing is switched back ON here, and that is not incidental —
    /// the caller reached this point only after
    /// `releaseVoiceProcessingForCaptureOnlyRun` had switched it off. Leaving it
    /// off would mean an engine running with a microphone tap and no echo
    /// cancellation, so every answer from here on would be transcribed off its
    /// own playback and interrupt itself. The ducking that comes with it is the
    /// deliberate trade: it lasts until the answer ends, and the alternative is a
    /// listening window that cannot hear.
    ///
    /// The order is `ensureEngineStarted`'s, and it has to be: the mixer is
    /// warmed up BEFORE voice processing is enabled, because voice processing
    /// reconfigures the whole IO and a mixer instantiated afterwards comes up at
    /// the old rate and fails `kAUInitialize` (-10875). See
    /// `warmUpMainMixerNode`.
    private func restorePlaybackEngineTap(handler: @escaping AVAudioNodeTapBlock) {
        do {
            Self.warmUpMainMixerNode(on: engine)
            isEchoCancellationActive = Self.enableEchoCancellationIfWanted(
                on: engine.inputNode,
                wanted: isEchoCancellationWantedProvider?() ?? false
            )

            // Disconnected first, matching every other restart in this file:
            // `connectGraphAndStart` re-connects the same nodes.
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitchNode)
            canonicalPlaybackFormat = try Self.connectGraphAndStart(
                engine: engine,
                playerNode: playerNode,
                timePitchNode: timePitchNode
            )
            isEngineStarted = engine.isRunning

            installTapOnPlaybackEngine(handler: handler, bufferSize: installedInputTapBufferSize)
        } catch {
            print("⚠️ VoicePlaybackEngine: the playback engine would not restart either (\(error.localizedDescription)) — the listening window is deaf until the next reply")
        }
    }

    // MARK: - Playback surface (TTS)

    /// Decodes `audioData` (a finished WAV from the synthesis endpoint) and
    /// plays it through the player node. Returns immediately; whether the
    /// chunk is audible is tracked in `isChunkPlaying`.
    func playWAVData(_ audioData: Data, rate: Float, volume: Float) async throws {
        try await ensureEngineStarted()

        // A dead engine must not become an unending reply. With nothing being
        // rendered, `scheduleBuffer`'s `.dataPlayedBack` never fires, so
        // `isChunkPlaying` would stay true for ever and
        // `BailianTTSClient.waitUntilPlaybackFinishes` would poll it for ever —
        // which is what the user sees as the app freezing mid-answer with the
        // stop button up and no sound. A skipped chunk is a silent reply;
        // a hang is an app the user cannot get out of, and of the two the hang
        // is the worse one.
        guard engine.isRunning else {
            isChunkPlaying = false
            consecutiveUnplayableChunkCount += 1
            print("⚠️ VoicePlaybackEngine: skipping a TTS chunk — the engine is not running, so this chunk could never finish playing (\(consecutiveUnplayableChunkCount) in a row)")
            // pipecat counts the same thing — `max_consecutive_zero_audio_contexts`,
            // tts_service.py:170 — but its escalation is to write the TTS service
            // off (`is_usable = False`, tts_service.py:1851-1857), which mutes
            // EVERY later reply until a settings delta arrives. That is the
            // reference's own version of "once it stops speaking it keeps not
            // speaking", and the 三段式 picks `ProcessorUnusablePolicy.CONTINUE`
            // (server.py:3830), so it only logs. This app counts it and RECOVERS:
            // past the threshold the whole IO is torn down and rebuilt from
            // scratch, which is the one action that has actually cleared this
            // state in the measurements above.
            if consecutiveUnplayableChunkCount >= Self.consecutiveUnplayableChunkThreshold {
                print("⚠️ VoicePlaybackEngine: \(consecutiveUnplayableChunkCount) chunks in a row could not play — tearing the audio path down and rebuilding it")
                consecutiveUnplayableChunkCount = 0
                engine.stop()
                isEngineStarted = false
                try? await ensureEngineStarted()
            }
            return
        }
        consecutiveUnplayableChunkCount = 0

        guard let canonicalPlaybackFormat else {
            throw BailianTTSClientError(message: "播放引擎没有可用的输出格式。")
        }

        let chunkBuffer = try decodedPCMBuffer(fromWAVData: audioData, targetFormat: canonicalPlaybackFormat)

        // `rate` only — `pitch` stays at its default 0 cents, which is what
        // keeps the cloned voice sounding like itself at every 语速.
        timePitchNode.rate = rate
        playerNode.volume = volume

        isChunkPlaying = true
        // `.dataPlayedBack` fires when the audio has actually been heard, not
        // merely consumed — the same moment `AVAudioPlayer.isPlaying` flips.
        playerNode.scheduleBuffer(chunkBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isChunkPlaying = false
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        // TEMPORARY PROBE (2026-09-24): the reply reaches the speakers or it
        // does not, and the log has never answered that. See
        // `installPlaybackRenderProbe`.
        // TEMPORARY (2026-09-24): the first scheduled chunk IS the first sound,
        // so this mark is the far end of the gap the user measures by ear.
        // `markOnce` because it sits on a per-chunk path and only the first one
        // is the measurement.
    }

    /// Stops the current chunk immediately (interruption path). The engine
    /// itself keeps running — a listening tap may live on it.
    func stopChunk() {
        // `playerNode.stop()` runs UNCONDITIONALLY. Skipping it while the engine
        // is down leaves `isPlaying` stale-true, and `playWAVData` skips
        // `play()` whenever it reads true — so the next reply schedules its
        // buffer onto a node that never renders, and since the node is never
        // recreated the state never clears on its own. Stopping a stopped node
        // costs nothing; a stale `isPlaying` is permanent (found by the
        // adversarial audit, 2026-09-24).
        playerNode.stop()
        isChunkPlaying = false
    }

    // MARK: - Engine lifecycle

    private func ensureEngineStarted() async throws {
        if isEngineStarted, engine.isRunning {
            // Already running: an answer is in progress, so the microphone is
            // already here (or there is no listening window open at all).
            return
        }

        // TEMPORARY (2026-09-24) — the measurement this whole redesign turns on.
        // Everything below is synchronous and runs on the main actor, so if this
        // pair is 2-3 s apart then starting the engine at the beginning of
        // recording would freeze the UI while the user is still speaking, and
        // the engine's start has to move off the main thread before its timing
        // can move at all. If it is a few hundred ms, that step is unnecessary.
        let engineStartBeganAt = Date()

        // ONE bring-up at a time, and everyone else waits for the one in flight.
        //
        // This is not defensive: making the bring-up async removed the thing that
        // used to serialize it. While it was synchronous and main-actor-bound,
        // re-entering it was impossible; now the first caller SUSPENDS, and a
        // second caller — the listening tap arming, the next chunk — walks
        // straight in behind it. Measured 2026-09-24 from the log's own marks:
        // two bring-ups started 357 ms apart, both running at once, the first
        // finishing with `isRunning=false` because the second had stopped the
        // engine underneath it, and a THIRD bring-up taking 1555 ms to clean up.
        if let bringUpInFlight = engineBringUpTask {
            let result = try await bringUpInFlight.value
            applyBringUpResult(result, engineStartBeganAt: engineStartBeganAt)
            return
        }

        // `isEngineStarted` is NOT allowed to be the only word on this. It is
        // this class's own bookkeeping, and the engine can stop without telling
        // it — the audio configuration changing (a device appearing, a route
        // changing, the sample rate moving) stops an `AVAudioEngine` outright,
        // and nothing here observes `AVAudioEngineConfigurationChange`. Once the
        // flag outlives the engine, this method early-returns for ever, every
        // reply's chunks take the `guard engine.isRunning` early-return in
        // `playWAVData`, and the app shows the text while speaking nothing —
        // reply after reply, until it is relaunched. That is exactly the shape
        // the user reported (2026-09-24: "一旦第一次不朗读，后面连续两三次、
        // 五六次一直都不朗读"): a latch, not an intermittent fault.
        if isEngineStarted {
            print("⚠️ VoicePlaybackEngine: isEngineStarted was true but the engine is not running — rebuilding the IO instead of trusting the flag")
        }

        // Attached exactly once: the header documents `attachNode:` as taking
        // ownership of a NEW node and gives no meaning to attaching the same one
        // twice — so the flag guards it now that this method can be re-entered
        // with the graph already built.
        if !hasAttachedPlaybackNodes {
            engine.attach(playerNode)
            engine.attach(timePitchNode)
            hasAttachedPlaybackNodes = true
        }
        isEngineStarted = false

        // LOAD-BEARING, and it has to happen BEFORE voice processing is turned
        // on — see `warmUpMainMixerNode`. Without it the engine cannot start at
        // all with voice processing on, which is what used to cost the first
        // TTS chunk of every reply.
        //
        // Voice processing then goes BEFORE the playback graph's format is read:
        // it can only be configured while the engine is stopped (AVAudioIONode.h),
        // and it reconfigures the IO — so the formats below have to be read from
        // the voice-processing hardware, not from whatever it was before.
        // (Enabling it on the input node is enough on its own: the header says
        // voice processing "requires both input and output nodes to be in the
        // voice processing mode", and then that "enabling this mode on either of
        // the IO nodes automatically enables it on the other IO node" — the same
        // line covers disabling.)
        //
        // ALL OF IT RUNS OFF THE MAIN ACTOR. Measured 2026-09-24, first question
        // of a session, main thread inside the whole time:
        //
        //     +1778ms  engine start requested (main thread: true)
        //     +3792ms  engine start finished — isRunning=FALSE, took 2014ms
        //     +3881ms  engine start requested again
        //     +3976ms  engine start finished — isRunning=true, took 95ms
        //
        // The 2 s is enabling voice processing for the first time, which
        // reconfigures the whole IO (44.1 kHz/1 ch → 48 kHz/9 ch) and fails on
        // that first attempt; the engine's own start is 95 ms. And because it
        // ran on the main thread, those 2 s were a main-thread stall — the
        // stutter reported while the reply was streaming.
        //
        // `await` on a detached task SUSPENDS the main actor rather than
        // blocking it, so the run loop keeps turning and the card keeps
        // streaming while the device is reconfigured.
        // Read here, on the main actor, because the bring-up runs off it and the
        // provider reaches into this app's settings. Captured as locals so the
        // detached task holds the NODES, not this class.
        let echoCancellationWanted = isEchoCancellationWantedProvider?() ?? false
        let engineToBringUp = engine
        let playerNodeToBringUp = playerNode
        let timePitchNodeToBringUp = timePitchNode
        let bringUpTask = Task.detached(priority: .userInitiated) {
            try Self.performBringUp(
                engine: engineToBringUp,
                playerNode: playerNodeToBringUp,
                timePitchNode: timePitchNodeToBringUp,
                echoCancellationWanted: echoCancellationWanted
            )
        }
        engineBringUpTask = bringUpTask
        defer { engineBringUpTask = nil }

        let bringUpResult = try await bringUpTask.value
        applyBringUpResult(bringUpResult, engineStartBeganAt: engineStartBeganAt)
    }

    /// Puts a finished bring-up's result onto this class's state, on the main
    /// actor. Shared by the caller that ran the bring-up and by any caller that
    /// waited on one already in flight.
    private func applyBringUpResult(
        _ bringUpResult: EngineBringUpResult,
        engineStartBeganAt: Date
    ) {
        isEchoCancellationActive = bringUpResult.echoCancellationActive
        canonicalPlaybackFormat = bringUpResult.canonicalPlaybackFormat
        isEngineStarted = bringUpResult.isEngineRunning

        // Hand-off #2: the listening window may be open with its microphone on
        // the capture-only engine (see `releaseEngineWhenIdle`). Playback is the
        // one thing that needs voice processing — and voice processing only
        // cancels audio rendered through ITS OWN engine — so the microphone comes
        // back here for the duration of the answer, before the first chunk is
        // scheduled rather than during it.
        if inputTapHost == .captureOnlyEngine, let tapHandlerToMove = installedInputTapHandler {
            takeCaptureBackForPlayback(handler: tapHandlerToMove)
        }

        print("🔊 VoicePlaybackEngine: engine started (time-pitch node → mixer, echo cancellation \(isEchoCancellationActive ? "ON (voice processing, ducking .min, AGC off)" : "off"), mixer \(Int(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)) Hz / input \(Int(engine.inputNode.outputFormat(forBus: 0).sampleRate)) Hz \(engine.inputNode.outputFormat(forBus: 0).channelCount) ch)")
        // TEMPORARY (2026-09-24): the duration of the whole bring-up, and the
        // number the decision above depends on. This should now be off the main
        // thread — the mark reports which thread it lands on.
    }

    /// What the off-main-actor bring-up hands back to the main actor.
    ///
    /// `@unchecked Sendable` because `AVAudioFormat` is not `Sendable` and this
    /// crosses the `Task.detached` boundary. The value is a freshly read,
    /// immutable format object that nothing else mutates, and the alternative —
    /// applying it inside the task — would mean touching this class's state from
    /// two threads. This is the smaller hazard.
    private struct EngineBringUpResult: @unchecked Sendable {
        let isEngineRunning: Bool
        let echoCancellationActive: Bool
        let canonicalPlaybackFormat: AVAudioFormat?
    }

    /// The bring-up itself, on whatever executor the caller runs on.
    ///
    /// Every AVAudioEngine call it makes is a control call (attach/connect/
    /// prepare/start and the voice-processing toggle), which is the set that is
    /// safe to make away from the render thread. The rendering-side calls the
    /// main actor makes — `scheduleBuffer` and `play` on the player node — are
    /// never made concurrently with it: they only happen once this has returned
    /// and set `isEngineStarted`.
    nonisolated private static func performBringUp(
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode,
        timePitchNode: AVAudioUnitTimePitch,
        echoCancellationWanted: Bool
    ) throws -> EngineBringUpResult {
        // TEMPORARY (2026-09-24): measured HERE, inside the work, because a mark
        // taken after the `await` resumes on the main actor and would report the
        // main thread no matter where the bring-up actually ran.
        let bringUpBeganAt = Date()

        warmUpMainMixerNode(on: engine)

        let inputNode = engine.inputNode
        var echoCancellationActive = enableEchoCancellationIfWanted(
            on: inputNode,
            wanted: echoCancellationWanted
        )

        var canonicalFormat: AVAudioFormat?
        do {
            canonicalFormat = try connectGraphAndStart(
                engine: engine,
                playerNode: playerNode,
                timePitchNode: timePitchNode
            )
        } catch where echoCancellationActive {
            // The header also warns that "the output format of the input node
            // and the input format of the output node have to be the same" — an
            // input and output device pair that disagrees (a Bluetooth headset
            // in a call profile is the usual one) fails HERE rather than at the
            // setVoiceProcessingEnabled call above. Losing all speech to save
            // the echo canceller would be a far worse trade than the echo, so
            // voice processing is given up and the graph rebuilt without it.
            print("⚠️ VoicePlaybackEngine: the engine would not start with voice processing on (\(error)) — retrying without echo cancellation")
            try? inputNode.setVoiceProcessingEnabled(false)
            echoCancellationActive = false
            // Turned off, voice processing hands the IO back its own formats, so
            // the connections made above are stale and have to be redone.
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitchNode)
            canonicalFormat = try? connectGraphAndStart(
                engine: engine,
                playerNode: playerNode,
                timePitchNode: timePitchNode
            )
        }

        // TEMPORARY (2026-09-24): the duration the bring-up itself took, printed
        // from inside it so both the time and the thread are the work's own.

        return EngineBringUpResult(
            isEngineRunning: engine.isRunning,
            echoCancellationActive: echoCancellationActive,
            canonicalPlaybackFormat: canonicalFormat
        )
    }

    /// Hand-off #2, from the other side: playback is starting, so the
    /// microphone comes back to the engine that can cancel it.
    ///
    /// The capture-only engine stops FIRST, for the same reason as the other
    /// direction — two live microphones would feed the recognizer every buffer
    /// twice, and a doubled buffer duplicates a syllable.
    private func takeCaptureBackForPlayback(handler: @escaping AVAudioNodeTapBlock) {
        captureOnlyEngine.inputNode.removeTap(onBus: 0)
        stopCaptureOnlyEngine()
        inputTapHost = .none

        installTapOnPlaybackEngine(handler: handler, bufferSize: installedInputTapBufferSize)
        print("🎙️ VoicePlaybackEngine: the microphone came back for the answer (echo cancellation covers it while it plays)")
    }

    /// Forces the main mixer node into existence and connects it to the output
    /// node — and it is the whole difference between an engine that starts with
    /// voice processing on and one that dies with `-10875`.
    ///
    /// Measured 2026-09-23 on the built-in output device, four runs of one
    /// probe that differed ONLY in which node's format was read before
    /// `setVoiceProcessingEnabled(true)`:
    ///
    ///     nothing read        mixer after VPIO 44100 Hz   engine.start() -> -10875
    ///     input node read     mixer after VPIO 44100 Hz   engine.start() -> -10875
    ///     MAIN MIXER read     mixer after VPIO 48000 Hz   engine.start() -> OK
    ///     both read           mixer after VPIO 48000 Hz   engine.start() -> OK
    ///
    /// Reading the mixer's output format is what instantiates it and wires it to
    /// the output node, which is what creates the output audio unit. Turning
    /// voice processing on then reconfigures the WHOLE IO — input *and* output —
    /// to the voice-processing hardware format (48 kHz / 9 input channels on
    /// this machine, against 44.1 kHz / 1 channel before). With the mixer
    /// untouched, the output unit is instead created lazily *after* voice
    /// processing, comes up at the stale 44.1 kHz, and `kAUInitialize` fails
    /// against 48 kHz hardware:
    ///
    ///     Error Domain=com.apple.coreaudio.avfaudio Code=-10875
    ///     UserInfo={failed call=err = PerformCommand(*outputNode, kAUInitialize, NULL, 0)}
    ///
    /// That is the error the app's own log recorded on the first TTS chunk of
    /// every reply, and it is why the first segment used to be lost: the old
    /// recovery dropped voice processing, which reconfigures the IO a second
    /// time and fails the same way. The return value is deliberately discarded —
    /// this is an ordered side effect, not a format to keep.
    /// Forces the main mixer node into existence and connects it to the output
    /// node — and it is the whole difference between an engine that starts with
    /// voice processing on and one that dies with `-10875`.
    ///
    /// `nonisolated static` taking the engine, rather than an instance method,
    /// because it is called from `performBringUp`, which runs off the main actor.
    nonisolated private static func warmUpMainMixerNode(on engine: AVAudioEngine) {
        _ = engine.mainMixerNode.outputFormat(forBus: 0)
    }

    /// Connects the playback graph and starts the engine — the half that has
    /// to be redone when a start with voice processing is retried without it,
    /// which is also why the formats are read here rather than earlier:
    /// toggling voice processing is exactly what changes them.
    ///
    /// `nonisolated static` for the same reason as `warmUpMainMixerNode`: its
    /// caller, `performBringUp`, runs off the main actor.
    nonisolated private static func connectGraphAndStart(
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode,
        timePitchNode: AVAudioUnitTimePitch
    ) throws -> AVAudioFormat {
        // Re-warmed here as well as in `performBringUp`, because the fallback
        // path has just toggled voice processing OFF — which reconfigures the IO
        // a second time, and leaves the mixer holding the format of a
        // configuration that no longer exists. See `warmUpMainMixerNode` for the
        // measurement.
        warmUpMainMixerNode(on: engine)

        let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        engine.connect(playerNode, to: timePitchNode, format: mixerOutputFormat)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: mixerOutputFormat)

        engine.prepare()
        try engine.start()

        // `start()` returning without throwing is NOT proof the engine runs, and
        // the difference is invisible until the reply is silent AND never
        // finishes. Measured 2026-09-24 with the probe below: one run reported
        // `after engine.start(): isRunning=TRUE` and played (mixer peaks 0.05–0.84
        // over three segments, voice-processing input format 9 ch); another
        // reported the engine started and then `play(): engineRunning=FALSE`,
        // with the input format 3 ch — the raw device format, i.e. voice
        // processing had not engaged. In that state `playerNode.play()` does
        // nothing, `scheduleBuffer`'s `.dataPlayedBack` never fires, and
        // `BailianTTSClient.waitUntilPlaybackFinishes` spins forever, so the
        // reply is both mute and unending with not one line of log to say so.
        //
        // The retry is the fix for the two-engine instability rather than a
        // guess: the same call path yields a working IO on one run and a dead
        // one on the next, which is the signature of the IO being reconfigured
        // underneath (this class runs two `AVAudioEngine`s and moves the mic
        // between them, toggling voice processing each time — the opposite of the
        // reference's rule that capture and playback stay on ONE path, 坑 1 in
        // 实现方案/08-踩坑总表.md:11). Stopping, re-warming and starting again
        // rebuilds the IO from scratch, which is what a fresh launch does.
        if !engine.isRunning {
            print("⚠️ VoicePlaybackEngine: engine.start() returned but the engine is not running — rebuilding the IO and starting again")
            engine.stop()
            warmUpMainMixerNode(on: engine)
            engine.prepare()
            try engine.start()
        }

        // The caller owns every flag this used to set here (`isEngineStarted`,
        // `canonicalPlaybackFormat`) — this function runs off the main actor and
        // must not touch them.
        if !engine.isRunning {
            print("⚠️ VoicePlaybackEngine: the engine still is not running after a rebuild — playback will be silent for this reply. Input format \(engine.inputNode.outputFormat(forBus: 0).sampleRate)Hz/\(engine.inputNode.outputFormat(forBus: 0).channelCount)ch (3 ch is the raw device format, i.e. voice processing did not engage; 9 ch is the processed one)")
        }

        return mixerOutputFormat
    }

    /// TEMPORARY PROBE (2026-09-24) — remove once the silence is explained.
    ///
    /// Measures the one thing no log in this repo has ever measured: whether
    /// audio is actually being RENDERED. A tap on the main mixer observes every
    /// sample on its way to the output node, so a non-zero peak here means the
    /// app produced sound and the fault is downstream (device, routing, mute);
    /// a flat zero while `playerNode.isPlaying` is true means the player is not
    /// being pulled at all and the fault is the graph.
    ///
    /// Prints at most twice a second — a per-buffer print from the audio thread
    /// would bury the log it exists to explain.
    private func installPlaybackRenderProbe() {
        // REMOVED 2026-09-24, permanently — a diagnostic must never be part of
        // the thing it measures.
        //
        // What stood here installed a tap on the main mixer whose closure
        // created a `Task { @MainActor }` for EVERY buffer, i.e. ~12 hops onto
        // the main actor per second for the whole time audio played, plus a
        // 4096-sample scan on the audio thread. Its question — is audio actually
        // being RENDERED, or is the engine merely claiming to run — has been
        // answered, and the answer is now carried by things that cost nothing on
        // the audio path: every engine start is verified against
        // `engine.isRunning`, `playWAVData` refuses to schedule onto a dead
        // engine, and `consecutiveUnplayableChunkCount` counts the refusals.
        //
        // It is a suspect for the stutter the user reports as new (2026-09-24),
        // and it is the newest per-buffer work on the audio path, so it goes.
        // If the render question ever needs asking again, ask it with a tap that
        // does its work ON the audio thread and publishes a value, never with one
        // that hops actors.
        _ = playbackRenderProbeCounter
    }

    /// Turns the system AEC on for this engine run when the settings ask for
    /// it, and says so in the log either way.
    ///
    /// Deliberately never throws: a device that cannot do voice processing, or
    /// a microphone permission that has not been granted, must degrade to "no
    /// AEC" — the text-level echo filter in BuddyDictationManager is still
    /// there underneath — rather than take playback down with it.
    nonisolated private static func enableEchoCancellationIfWanted(
        on inputNode: AVAudioInputNode,
        wanted: Bool
    ) -> Bool {
        guard wanted else { return false }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("⚠️ VoicePlaybackEngine: voice processing could not be enabled (\(error.localizedDescription)) — continuing without echo cancellation")
            return false
        }

        applyMildestOtherAudioDuckingConfiguration(on: inputNode)
        disableAutomaticGainControlOnProcessedUplink(on: inputNode)
        return inputNode.isVoiceProcessingEnabled
    }

    /// Turns OFF the automatic gain control the voice processing unit applies to
    /// the microphone uplink. It is ON by default, and leaving it on is what
    /// made a working canceller look broken.
    ///
    /// `AVAudioIONode.h:228` documents the property as "Enable automatic gain
    /// control on the processed microphone uplink signal. Enabled by default."
    /// Sitting AFTER the canceller, that gain re-normalises whatever the
    /// canceller left behind: with an answer playing, the leftover echo is
    /// pumped back up towards speech level, so the microphone reads 0.876–1.000
    /// while the user is silent (four replies, 2026-09-24) even though the
    /// canceller measured BELOW the room's own noise floor on this same machine
    /// and route (peak 0.111 against a 0.167 floor, 2026-09-23). Two readings of
    /// one signal that differ by an order of magnitude and invert in sign are
    /// not a calibration problem — they are an amplifier sitting between the
    /// canceller and the meter, and no threshold survives it: the 0.25 that
    /// separates speech from a quiet room reports "someone is talking" for the
    /// whole of every reply.
    ///
    /// It is not only the meters that read it: the recognizer consumes the same
    /// re-gained signal, and a clipped one is exactly what this app's own ASR
    /// turned into 「嗯。」/「哎」/「那」 off its own answer.
    ///
    /// The reference project never meets this, because its VAD analyzer and its
    /// recognizer both read the browser AEC's own output — the same class of
    /// failure it records as 坑 1 (实现方案/08-踩坑总表.md:11), "capture and
    /// playback must both travel through the AEC for it to work".
    nonisolated private static func disableAutomaticGainControlOnProcessedUplink(on inputNode: AVAudioInputNode) {
        inputNode.isVoiceProcessingAGCEnabled = false
    }

    /// The mildest ducking macOS offers, and never the activity-driven extra:
    /// the ducking, not the AEC, is what took voice processing out of this app
    /// earlier on 2026-09-23 (see the file header).
    nonisolated private static func applyMildestOtherAudioDuckingConfiguration(on inputNode: AVAudioInputNode) {
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
    }

    // MARK: - WAV decoding

    /// Turns the downloaded WAV bytes into an `AVAudioPCMBuffer` in
    /// `targetFormat`. `AVAudioFile` cannot read from memory, so the bytes are
    /// written to a scratch file that is deleted on return; the file's own
    /// format is then converted to the engine's with `AVAudioConverter`, so
    /// any sample-rate/channel-count the provider returns just works.
    private func decodedPCMBuffer(
        fromWAVData audioData: Data,
        targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let scratchFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-tts-chunk-\(UUID().uuidString).wav")
        try audioData.write(to: scratchFileURL)
        defer { try? FileManager.default.removeItem(at: scratchFileURL) }

        let audioFile = try AVAudioFile(forReading: scratchFileURL)
        let fileFormat = audioFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)

        guard sourceFrameCount > 0 else {
            throw BailianTTSClientError(message: "朗读返回的音频是空的。")
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: sourceFrameCount) else {
            throw BailianTTSClientError(message: "朗读音频缓冲区创建失败。")
        }
        try audioFile.read(into: sourceBuffer)

        guard fileFormat != targetFormat else {
            return sourceBuffer
        }

        guard let formatConverter = AVAudioConverter(from: fileFormat, to: targetFormat) else {
            throw BailianTTSClientError(
                message: "朗读音频格式无法转换（\(fileFormat) → \(targetFormat)）。"
            )
        }

        let estimatedOutputFrameCount = AVAudioFrameCount(
            Double(sourceFrameCount) * (targetFormat.sampleRate / fileFormat.sampleRate)
        ) + 1024
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedOutputFrameCount
        ) else {
            throw BailianTTSClientError(message: "朗读音频转换缓冲区创建失败。")
        }

        var conversionError: NSError?
        var isSourceConsumed = false
        let conversionStatus = formatConverter.convert(
            to: convertedBuffer,
            error: &conversionError,
            withInputFrom: { _, inputStatus in
                if isSourceConsumed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                isSourceConsumed = true
                inputStatus.pointee = .haveData
                return sourceBuffer
            }
        )

        guard conversionStatus == .haveData, conversionError == nil else {
            throw BailianTTSClientError(
                message: "朗读音频格式转换失败（\(conversionStatus.rawValue)）：\(conversionError?.localizedDescription ?? "无错误信息")"
            )
        }

        return convertedBuffer
    }
}
