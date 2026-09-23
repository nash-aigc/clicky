//
//  VoicePlaybackEngine.swift
//  leanring-buddy
//
//  The shared audio engine for BOTH halves of the voice conversation: TTS
//  playback (AVAudioPlayerNode) and continuous-listening capture (the input
//  tap), with the system's voice-processing unit (VPIO — echo cancellation)
//  enabled on its input node.
//
//  Why one engine: Apple's voice processing AEC only ever references audio
//  rendered through the same voice-processing chain (WWDC23 "What's new in
//  voice processing": everything else is "other audio" — ducked, never used
//  as the reference). VoiceWeb's own README records the same law for the
//  browser: capture and playback must both stay inside the WebRTC transport,
//  because the moment playback moves out (WebAudio/Python), AEC goes blind
//  and the AI starts interrupting itself. The first 持续监听 build failed for
//  exactly that reason: the mic ran on a VPIO-enabled engine while TTS played
//  through a separate `AVAudioPlayer`, so the AEC had no reference signal and
//  every reply triggered the VAD. Playing the TTS through THIS engine — the
//  one the listening tap is installed on — is the macOS equivalent of
//  VoiceWeb's "same page, same WebRTC transport" rule.
//
//  The engine is started on demand (first playback or first listening tap)
//  and stopped again when both go idle, so the microphone route is not held
//  open permanently between replies.
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

    /// True when the chunk currently scheduled on the player node is being
    /// played back. The analogue of `AVAudioPlayer.isPlaying` for the chunk
    /// level; the client's `isSpeakingChunkSequence` covers the gaps between
    /// chunks exactly as it did before.
    private(set) var isChunkPlaying = false

    /// Whether the input's voice processing (AEC) could be enabled at all.
    /// When false, continuous listening CANNOT cancel the app's own TTS out
    /// of the mic signal, so it must not ride this engine — the caller falls
    /// back and the feature stays off rather than self-interrupting.
    private(set) var isVoiceProcessingActive = false

    /// The engine-side format playback buffers are converted into. Read once
    /// when the graph is first connected; every chunk after that converts to
    /// it, so a provider returning a different sample rate never forces the
    /// stop-disconnect-reconnect dance.
    private var canonicalPlaybackFormat: AVAudioFormat?

    init() {
        // Voice processing is NOT enabled here. Measured 2026-09-23 on this
        // machine (macOS 27): enabling VPIO before the playback graph is
        // connected makes `engine.start()` fail with -10875
        // (PerformCommand(*outputNode, kAUInitialize) — a standalone probe
        // reproduced it in every "VPIO first, graph second" ordering, and
        // cleared it in every "graph first, VPIO second" ordering). The input
        // node is therefore touched in `ensureEngineStarted`, after the graph
        // is connected. No tap and no connection exist at init, so nothing
        // captures the microphone now.
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

        let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        canonicalPlaybackFormat = mixerOutputFormat

        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.connect(playerNode, to: timePitchNode, format: mixerOutputFormat)
        engine.connect(timePitchNode, to: engine.mainMixerNode, format: mixerOutputFormat)

        // Voice processing goes AFTER the playback graph is connected — the
        // ordering the -10875 probe settled on 2026-09-23 (see init's comment).
        // The engine is still stopped here, which is what the API requires.
        // A failure is not fatal to PLAYBACK: it only means no AEC, and the
        // listening path checks `isVoiceProcessingActive` before installing
        // its tap on this engine.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            isVoiceProcessingActive = true
            print("🔊 VoicePlaybackEngine: input voice processing (AEC) enabled")
        } catch {
            isVoiceProcessingActive = false
            print("⚠️ VoicePlaybackEngine: voice processing unavailable (\(error)) — playback continues without AEC")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Last-resort degradation: a failed VPIO start must never take
            // playback down with it (the silent-TTS failure mode). Drop AEC
            // and retry once; if that also throws, the caller sees the error.
            if isVoiceProcessingActive {
                print("⚠️ VoicePlaybackEngine: start failed (\(error.localizedDescription)) — retrying without AEC")
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                isVoiceProcessingActive = false
                try engine.start()
            } else {
                throw error
            }
        }
        isEngineStarted = true
        print("🔊 VoicePlaybackEngine: engine started (time-pitch node → mixer, AEC input)")
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
