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

import AVFoundation
import Foundation

@MainActor
final class VoicePlaybackEngine {

    private let engine = AVAudioEngine()
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
    /// True while the continuous-listening tap is installed on the input —
    /// the engine must never be released underneath a live tap.
    private var isInputTapped = false

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
    }

    // MARK: - Capture surface (continuous listening)

    var engineInputNode: AVAudioInputNode {
        engine.inputNode
    }

    /// Starts the engine if it is not running. Called by the capture path when
    /// the listening tap is about to be installed on a possibly-stopped engine
    /// (the window can open just as the first TTS chunk begins).
    func ensureStartedForCapture() throws {
        try ensureEngineStarted()
    }

    /// Installs the continuous-listening mic tap on this engine's input.
    /// Replaces any previous tap first, matching the raw `installTap` call
    /// the own-engine path performs.
    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, handler: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: handler)
        isInputTapped = true
    }

    func removeInputTap() {
        guard isInputTapped else { return }
        engine.inputNode.removeTap(onBus: 0)
        isInputTapped = false
    }

    /// Stops the engine when nothing needs it, so the mic route is not held
    /// open between replies. Deliberately refuses while a chunk is playing or
    /// a tap is installed.
    func releaseEngineWhenIdle() {
        guard isEngineStarted, !isChunkPlaying, !isInputTapped else { return }
        engine.stop()
        isEngineStarted = false
        print("🔊 VoicePlaybackEngine: engine released (idle)")
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
        guard !isEngineStarted else { return }

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

        print("🔊 VoicePlaybackEngine: engine started (time-pitch node → mixer, echo cancellation \(isEchoCancellationActive ? "ON (voice processing, ducking .min)" : "off"), mixer \(Int(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)) Hz / input \(Int(inputNode.outputFormat(forBus: 0).sampleRate)) Hz \(inputNode.outputFormat(forBus: 0).channelCount) ch)")
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

        // The mildest ducking macOS offers, and never the activity-driven
        // extra: the ducking, not the AEC, is what took voice processing out
        // of this app earlier today (see the file header).
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        return inputNode.isVoiceProcessingEnabled
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
