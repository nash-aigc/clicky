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
    private var isEchoCancellationActive = false

    /// True when the chunk currently scheduled on the player node is being
    /// played back. The analogue of `AVAudioPlayer.isPlaying` for the chunk
    /// level; the client's `isSpeakingChunkSequence` covers the gaps between
    /// chunks exactly as it did before.
    private(set) var isChunkPlaying = false

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
        preparedCaptureHost = isEngineStarted ? .playbackEngine : .captureOnlyEngine
        let hostDescription = preparedCaptureHost == .playbackEngine
            ? "playback engine (an answer is playing — its echo cancellation covers it)"
            : "capture-only engine (nothing playing — no voice processing, so nothing else is ducked)"
        print("🎙️ VoicePlaybackEngine: the listening tap will go on the \(hostDescription)")
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
    func installInputTap(bufferSize: AVAudioFrameCount, handler: @escaping AVAudioNodeTapBlock) throws {
        installedInputTapHandler = handler
        installedInputTapBufferSize = bufferSize

        switch preparedCaptureHost {
        case .playbackEngine:
            installTapOnPlaybackEngine(handler: handler, bufferSize: bufferSize)
        case .captureOnlyEngine:
            try startCaptureOnlyEngineWithTap(handler: handler, bufferSize: bufferSize)
        case .none:
            // Nothing asked for a host, so treat it as the capture-only case —
            // the safe half: it is the one that cannot duck anything.
            try startCaptureOnlyEngineWithTap(handler: handler, bufferSize: bufferSize)
        }
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
    func releaseEngineWhenIdle() {
        guard isEngineStarted, !isChunkPlaying else { return }

        if inputTapHost == .playbackEngine {
            handCaptureToCaptureOnlyEngine()
            return
        }

        engine.stop()
        isEngineStarted = false
        // Stopping the engine is NOT what hands the input device back — voice
        // processing has to be switched off too, and this call is the one that
        // ends the ducking. See `releaseVoiceProcessingForCaptureOnlyRun`.
        do {
            try releaseVoiceProcessingForCaptureOnlyRun()
            print("🔊 VoicePlaybackEngine: engine released (idle) and voice processing is off, so nothing else is ducked")
        } catch {
            print("⚠️ VoicePlaybackEngine: engine released (idle), but voice processing would not switch off (\(error.localizedDescription)) — the rest of the machine stays ducked until the next reply")
        }
    }

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
            warmUpMainMixerNode()
            isEchoCancellationActive = enableEchoCancellationIfWanted(on: engine.inputNode)

            // Disconnected first, matching every other restart in this file:
            // `connectGraphAndStart` re-connects the same nodes.
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitchNode)
            try connectGraphAndStart()

            installTapOnPlaybackEngine(handler: handler, bufferSize: installedInputTapBufferSize)
        } catch {
            print("⚠️ VoicePlaybackEngine: the playback engine would not restart either (\(error.localizedDescription)) — the listening window is deaf until the next reply")
        }
    }

    // MARK: - Playback surface (TTS)

    /// Decodes `audioData` (a finished WAV from the synthesis endpoint) and
    /// plays it through the player node. Returns immediately; whether the
    /// chunk is audible is tracked in `isChunkPlaying`.
    func playWAVData(_ audioData: Data, rate: Float, volume: Float) throws {
        try ensureEngineStarted()
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
    }

    /// Stops the current chunk immediately (interruption path). The engine
    /// itself keeps running — a listening tap may live on it.
    func stopChunk() {
        guard isEngineStarted else {
            isChunkPlaying = false
            return
        }
        playerNode.stop()
        isChunkPlaying = false
    }

    // MARK: - Engine lifecycle

    private func ensureEngineStarted() throws {
        if isEngineStarted {
            // Already running: an answer is in progress, so the microphone is
            // already here (or there is no listening window open at all).
            return
        }

        // Attached exactly once, and outside the retry below: the header
        // documents `attachNode:` as taking ownership of a NEW node and gives
        // no meaning to attaching the same one twice.
        engine.attach(playerNode)
        engine.attach(timePitchNode)

        // LOAD-BEARING, and it has to happen BEFORE voice processing is turned
        // on — see `warmUpMainMixerNode`. Without it the engine cannot start at
        // all with voice processing on, which is what used to cost the first
        // TTS chunk of every reply.
        warmUpMainMixerNode()

        // Voice processing goes BEFORE the playback graph's format is read: it
        // can only be configured while the engine is stopped (AVAudioIONode.h),
        // and it reconfigures the IO — so the formats below have to be read from
        // the voice-processing hardware, not from whatever it was before.
        //
        // Enabling it on the input node is enough on its own: the header says
        // voice processing "requires both input and output nodes to be in the
        // voice processing mode", and then that "enabling this mode on either
        // of the IO nodes automatically enables it on the other IO node" — the
        // same line covers disabling.
        let inputNode = engine.inputNode
        isEchoCancellationActive = enableEchoCancellationIfWanted(on: inputNode)

        do {
            try connectGraphAndStart()
        } catch where isEchoCancellationActive {
            // The header also warns that "the output format of the input node
            // and the input format of the output node have to be the same" —
            // an input and output device pair that disagrees (a Bluetooth
            // headset in a call profile is the usual one) fails HERE rather
            // than at the setVoiceProcessingEnabled call above. Losing all
            // speech to save the echo canceller would be a far worse trade
            // than the echo, so voice processing is given up and the graph
            // rebuilt without it.
            print("⚠️ VoicePlaybackEngine: the engine would not start with voice processing on (\(error)) — retrying without echo cancellation")
            try? inputNode.setVoiceProcessingEnabled(false)
            isEchoCancellationActive = false
            // Turned off, voice processing hands the IO back its own formats,
            // so the connections made above are stale and have to be redone.
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitchNode)
            try connectGraphAndStart()
        }

        // Hand-off #2: the listening window may be open with its microphone on
        // the capture-only engine (see `releaseEngineWhenIdle`). Playback is the
        // one thing that needs voice processing — and voice processing only
        // cancels audio rendered through ITS OWN engine — so the microphone comes
        // back here for the duration of the answer, before the first chunk is
        // scheduled rather than during it.
        if inputTapHost == .captureOnlyEngine, let tapHandlerToMove = installedInputTapHandler {
            takeCaptureBackForPlayback(handler: tapHandlerToMove)
        }

        print("🔊 VoicePlaybackEngine: engine started (time-pitch node → mixer, echo cancellation \(isEchoCancellationActive ? "ON (voice processing, ducking .min)" : "off"), mixer \(Int(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)) Hz / input \(Int(inputNode.outputFormat(forBus: 0).sampleRate)) Hz \(inputNode.outputFormat(forBus: 0).channelCount) ch)")
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
    private func warmUpMainMixerNode() {
        _ = engine.mainMixerNode.outputFormat(forBus: 0)
    }

    /// Connects the playback graph and starts the engine — the half that has
    /// to be redone when a start with voice processing is retried without it,
    /// which is also why the formats are read here rather than earlier:
    /// toggling voice processing is exactly what changes them.
    private func connectGraphAndStart() throws {
        // Re-warmed here as well as in `ensureEngineStarted`, because the
        // fallback path has just toggled voice processing OFF — which
        // reconfigures the IO a second time, and leaves the mixer holding the
        // format of a configuration that no longer exists. See
        // `warmUpMainMixerNode` for the measurement.
        warmUpMainMixerNode()

        let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        canonicalPlaybackFormat = mixerOutputFormat

        engine.connect(playerNode, to: timePitchNode, format: mixerOutputFormat)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: mixerOutputFormat)

        engine.prepare()
        try engine.start()
        isEngineStarted = true
    }

    /// Turns the system AEC on for this engine run when the settings ask for
    /// it, and says so in the log either way.
    ///
    /// Deliberately never throws: a device that cannot do voice processing, or
    /// a microphone permission that has not been granted, must degrade to "no
    /// AEC" — the text-level echo filter in BuddyDictationManager is still
    /// there underneath — rather than take playback down with it.
    private func enableEchoCancellationIfWanted(on inputNode: AVAudioInputNode) -> Bool {
        guard isEchoCancellationWantedProvider?() ?? false else { return false }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("⚠️ VoicePlaybackEngine: voice processing could not be enabled (\(error.localizedDescription)) — continuing without echo cancellation")
            return false
        }

        applyMildestOtherAudioDuckingConfiguration(on: inputNode)
        return inputNode.isVoiceProcessingEnabled
    }

    /// The mildest ducking macOS offers, and never the activity-driven extra:
    /// the ducking, not the AEC, is what took voice processing out of this app
    /// earlier on 2026-09-23 (see the file header).
    private func applyMildestOtherAudioDuckingConfiguration(on inputNode: AVAudioInputNode) {
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
