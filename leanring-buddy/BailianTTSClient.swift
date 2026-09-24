//
//  BailianTTSClient.swift
//  leanring-buddy
//
//  Speaks the companion's replies aloud using Alibaba Bailian's text-to-speech
//  (`qwen-audio-3.1-tts-flash`). Replaces the ElevenLabs client.
//
//  Bailian has no OpenAI-compatible TTS route, so this talks to DashScope's
//  native speech-synthesis endpoint. That endpoint is request/response rather
//  than a stream: it answers with a URL to a finished WAV file, which is then
//  downloaded and played. There is no partial audio to start playing early.
//
//  Which endpoint is correct depends on the model family, and Alibaba documents
//  the two as non-interchangeable: Qwen-Audio-TTS / CosyVoice live on
//  `/api/v1/services/audio/tts/SpeechSynthesizer`, while Qwen-TTS
//  (`qwen3-tts-flash`) lives on `/api/v1/services/aigc/multimodal-generation/
//  generation`. Posting to the wrong one fails with `InvalidParameter: url
//  error`, so the model, the voice, the body fields and the path all move
//  together.
//

import AVFoundation
import Foundation

struct BailianTTSClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// One reply's playback parameters, snapshotted in `speakText` and handed to
/// every chunk, so a settings save landing mid-answer can't split one reply
/// across two speeds or volumes.
///
/// Internal rather than private: `StreamingSpeechSession` hands the same
/// snapshot to its own playback calls.
struct SpeechPlaybackConfiguration {
    let rate: Float
    let volume: Float
}

@MainActor
final class BailianTTSClient {
    private let session: URLSession

    /// The playback engine every chunk is spoken through. Shared with the
    /// continuous-listening capture path: the system AEC only cancels audio
    /// rendered through the same voice-processing chain as the mic, so the
    /// TTS MUST come out of this engine for 持续监听 not to hear its own
    /// voice (see VoicePlaybackEngine's header).
    let voicePlaybackEngine = VoicePlaybackEngine()

    /// Drives playback of chunks after the first one. The first chunk is spoken
    /// before `speakText` returns; the rest continue here in the background so a
    /// long answer isn't held back by synthesizing every chunk up front.
    private var remainingChunksPlaybackTask: Task<Void, Never>?

    /// True from the moment the first chunk's audio starts until the last chunk
    /// has finished. Between chunks the audio player is briefly idle while the
    /// next one is synthesized, but from the user's point of view the companion
    /// is still speaking — and the overlay polls this to decide when the
    /// interaction is over, so it must not flicker false mid-answer.
    ///
    /// **It must be cleared when the sequence ends naturally, not only when it is
    /// interrupted.** Callers wait on `isPlaying` becoming false; a flag that only
    /// `stopPlayback()` ever reset would read as "still speaking" from the end of
    /// the first reply until the start of the next one — see the clearing in
    /// `speakText`.
    private var isSpeakingChunkSequence = false

    /// The endpoint, key, model and voice are resolved per `speakText` call from
    /// the user's model configuration rather than captured here, so changing the
    /// speech provider in the settings window takes effect on the next reply
    /// instead of on the next launch.
    init() {
        let configuration = URLSessionConfiguration.default
        // Synthesis of a full-length chunk plus the download of the resulting WAV
        // can take a while for long answers; give it room rather than failing
        // partway through a reply.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    /// The speech role as configured right now, or a thrown error naming exactly
    /// what is missing.
    ///
    /// `voiceOverride` 是**语音聊天按预设选的音色** —— 那个值以前根本没有进到这条
    /// 链路（这里只认全局配置），所以「我点了使用，但连接时播的不是那个音色」。
    /// 按住说话那条路不传它，仍旧走全局配置里那份。
    private func resolveSpeechRole(voiceOverride: String? = nil) throws -> ResolvedModelRole {
        let speechRoleStatus = ModelConfigurationStore.snapshot().status(of: .speech)
        guard let resolvedSpeechRole = speechRoleStatus.resolvedRole else {
            let unavailableExplanation = speechRoleStatus.unavailableExplanation ?? "未配置"
            throw BailianTTSClientError(
                message: "朗读模型不可用：\(unavailableExplanation)。请在菜单栏图标的齿轮里打开模型设置。"
            )
        }
        return resolvedSpeechRole.withSpeechVoiceOverride(voiceOverride)
    }

    /// Synthesizes `text` and begins playing it.
    ///
    /// Returns as soon as the *first* chunk of audio starts playing — the caller
    /// uses that moment to switch the companion into its "responding" state, so
    /// waiting for a long reply to finish synthesizing would keep the spinner up
    /// for the whole answer. Any remaining chunks play in the background.
    func speakText(_ text: String, voiceOverride: String? = nil) async throws {
        stopPlayback()

        // Resolved once here and passed to every chunk below. Resolving per chunk
        // would let a save in the settings window land between chunk 1 and chunk 2,
        // so a single reply would be spoken half in one provider's voice and half
        // in another's — and `isPlaying` would be tracking two providers at once.
        let resolvedSpeechRole = try resolveSpeechRole(voiceOverride: voiceOverride)

        // The playback settings are snapshotted alongside the role for the same
        // reason: every chunk of one reply should play at one speed and volume.
        let appSettings = AppSettingsStore.snapshot()
        let playbackConfiguration = SpeechPlaybackConfiguration(
            rate: Float(appSettings.speechPlaybackRate),
            volume: Float(appSettings.speechPlaybackVolumePercent) / 100
        )

        let speakableChunks = Self.splitIntoSpeakableChunks(
            text,
            maximumCharactersPerChunk: appSettings.maximumSpeechChunkCharacters
        )
        guard let firstChunk = speakableChunks.first else { return }

        let firstChunkAudioData = try await requestAudioData(
            for: firstChunk,
            resolvedSpeechRole: resolvedSpeechRole
        )
        try Task.checkCancellation()

        isSpeakingChunkSequence = true
        await playAudioData(
            firstChunkAudioData,
            chunkIndex: 1,
            chunkCount: speakableChunks.count,
            playbackConfiguration: playbackConfiguration
        )

        let remainingChunks = Array(speakableChunks.dropFirst())

        // The whole rest of the sequence runs in this task, so `speakText` can
        // still return the instant the first chunk is audible: it waits that
        // chunk out, synthesizes and plays the ones after it, and — the part that
        // matters — clears `isSpeakingChunkSequence` once the last one has ended.
        //
        // That last clear is the fix for a stuck answer bubble. `stopPlayback()`
        // used to be the only thing that reset the flag, and it runs at the
        // *start* of the next reply, so after the first answer of a session
        // `isPlaying` stayed true forever. Every caller that polls it to decide
        // the interaction is over — `CompanionManager.scheduleAnswerBubbleClear`
        // and `scheduleTransientHideIfNeeded` — was waiting on a condition that
        // could never come, so the answer text stayed on screen next to the
        // cursor and the 「回答文字多留一会儿」 setting was never even read.
        remainingChunksPlaybackTask = Task { [weak self] in
            guard let self else { return }

            // Waits out the chunk `speakText` already started. It is not replayed
            // here — only the chunks after it are.
            await self.waitUntilPlaybackFinishes()
            guard !Task.isCancelled else { return }

            for (offset, chunk) in remainingChunks.enumerated() {
                do {
                    let audioData = try await self.requestAudioData(
                        for: chunk,
                        resolvedSpeechRole: resolvedSpeechRole
                    )
                    guard !Task.isCancelled else { return }
                    await self.playAndWaitUntilFinished(
                        audioData,
                        chunkIndex: offset + 2,
                        chunkCount: speakableChunks.count,
                        playbackConfiguration: playbackConfiguration
                    )
                } catch {
                    // Partial audio already played is still useful; stop rather
                    // than leaving the companion stuck in a speaking state.
                    print("⚠️ Bailian TTS: stopped after chunk \(offset + 1) of \(remainingChunks.count): \(error.localizedDescription)")
                    self.isSpeakingChunkSequence = false
                    return
                }
            }

            // Not cleared when cancelled: a cancelled sequence means a newer one
            // has already claimed the flag, and clearing it here would report that
            // one as finished while its audio is still playing.
            guard !Task.isCancelled else { return }
            self.isSpeakingChunkSequence = false
        }
    }

    /// Whether audio is currently playing, or is about to be — see
    /// `isSpeakingChunkSequence` for why the gaps between chunks still count,
    /// and `StreamingSpeechSession.isSynthesizingBeforeFirstAudio` for why the
    /// synthesis window before the *first* audio counts too.
    var isPlaying: Bool {
        if voicePlaybackEngine.isChunkPlaying { return true }
        if isSpeakingChunkSequence { return true }
        return activeStreamingSession?.isSynthesizingBeforeFirstAudio ?? false
    }

    /// The live 逐句快答 session, if one is running. `stopPlayback` tears it
    /// down, so every existing interrupt path (the talk shortcut, the panel's
    /// 「停止」, a new question) silences it without knowing it exists.
    private var activeStreamingSession: StreamingSpeechSession?

    /// Begins a streaming speech session (逐句快答): the caller feeds the reply's
    /// tag-stripped text as it streams in, and the session speaks sentence-sized
    /// segments while the model is still writing the rest of the answer.
    ///
    /// - Throws: the same configuration error `speakText` would throw when the
    ///   👄 role is unusable — callers that catch it simply fall back to the
    ///   whole-reply path, which re-throws the identical error.
    /// Releases the shared audio engine now — see
    /// `VoicePlaybackEngine.releaseNow`.
    ///
    /// Called by `CompanionManager`'s idle-release timer and by the release
    /// shortcut. Deliberately not called when a reply ends: holding the engine
    /// is what keeps the next question's first sound fast.
    /// 打断：丢掉正在念的音频，但**这一轮继续有效**（后续文本还会被合成播放）。
    ///
    /// 语音聊天的 VAD 打断走这条，**不走 `stopPlayback()`** —— 那个是终止式的
    /// （它会把朗读会话标记成停止，之后 `feed()` 永远空转），用在一句自己播放声
    /// 引起的误触上，代价是整条回答哑掉。对话页面仍然走 `stopPlayback()`，行为不变。
    func bargeInWithoutEndingSession() {
        guard let activeStreamingSession else {
            // 没有逐句快答会话在跑（整段合成那条路），退回原来的终止式停止。
            stopPlayback()
            return
        }
        activeStreamingSession.dropQueuedAudio()
        voicePlaybackEngine.stopChunk()
        isSpeakingChunkSequence = false
        print("🔊 Streaming speech: barge-in — 丢掉剩下的音频，这一轮继续")
    }

    /// 预热共享音频引擎（语音聊天进分区时调）。
    func warmUpVoiceEngine() async {
        await voicePlaybackEngine.warmUpForVoiceChat()
    }

    func releaseAudioEngineNow() {
        voicePlaybackEngine.releaseNow()
    }

    func beginStreamingSpeech(voiceOverride: String? = nil) throws -> StreamingSpeechSession {
        stopPlayback()
        let resolvedSpeechRole = try resolveSpeechRole(voiceOverride: voiceOverride)
        let appSettings = AppSettingsStore.snapshot()
        let playbackConfiguration = SpeechPlaybackConfiguration(
            rate: Float(appSettings.speechPlaybackRate),
            volume: Float(appSettings.speechPlaybackVolumePercent) / 100
        )
        let session = StreamingSpeechSession(
            resolvedSpeechRole: resolvedSpeechRole,
            playbackConfiguration: playbackConfiguration,
            owner: self
        )
        activeStreamingSession = session
        return session
    }

    /// 试听：把一段**已经合成好**的 WAV 播出来。
    ///
    /// 和朗读共用同一个引擎、同一份语速与音量 —— 试听要让用户听到的正是「选完之后
    /// 朗读会发出的声音」。换一个播放器（哪怕是 `AVAudioPlayer`）就会因为不经过
    /// 同一条 voice-processing 链路而在两处听起来不一样，而用户是拿试听做决定的。
    ///
    /// 不复用 `speakText`：那条路自己还要去合成，而试听的音频已经在手上了。
    ///
    /// **必须重试，而且原因不是防御性编程**：试听是**一次性**的，而
    /// `playWAVData` 在引擎没起来时的兜底是「跳过这一块，等下一块来重建引擎」——
    /// 对朗读没问题（后面还有块），对试听就是彻底没声音、而且**不报错**。第一次
    /// 试听几乎必然撞上那个窗口：`ensureEngineStarted` 刚把引擎拉起来，开 voice
    /// processing 会重配整个 IO，引擎随即**自己停掉**。实测日志：
    ///
    ///     🔊 engine started (voiceProcessing=true, 3 ch)
    ///     ⚠️ skipping a TTS chunk — the engine is not running   ← 用户听到的就是这一行
    ///     🔊 the audio configuration changed and the engine stopped itself
    ///
    /// 所以这里把「跳过」变成「重建再放一次」。判据用 `isChunkPlaying`，它在这条
    /// 路上已经是现成的信号：被跳过时它被置回 false，真在放时是 true。
    func playPreviewWAVData(_ wavData: Data) async throws {
        let appSettings = AppSettingsStore.snapshot()
        let rate = Float(appSettings.speechPlaybackRate)
        let volume = Float(appSettings.speechPlaybackVolumePercent) / 100

        for attempt in 1...2 {
            try await voicePlaybackEngine.playWAVData(wavData, rate: rate, volume: volume)
            if voicePlaybackEngine.isChunkPlaying { return }

            if attempt == 1 {
                // 给「引擎自己停掉」那条通知一点时间落地；下一次调用就会走重建
                // 那条路（`ensureEngineStarted` 发现 `engine.isRunning == false`）。
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        throw BailianTTSClientError(
            message: "试听没放出来：播放引擎起不来（可能刚被释放，或音频设备正在切换）。再点一次通常就好。"
        )
    }

    /// 停掉正在试听的那一段。只停播放队列，不释放引擎 —— 用户往往会连着试好几个音色。
    func stopPreviewPlayback() {
        voicePlaybackEngine.stopChunk()
    }

    /// Stops playback immediately and abandons any chunks still queued.
    func stopPlayback() {
        // Reported BEFORE the storm of teardown below, because the interesting
        // question about a silent reply is whether there was ever anything to
        // hear: `isPlaying == true` with `isSpeakingChunkSequence == false`
        // means this stop landed in the synthesis gap BETWEEN two segments (the
        // first finished, the next had not started) — a reply that is being
        // killed while it is momentarily quiet. Every caller of this method is
        // an interrupt path, so the line also names how much was abandoned.
        if isPlaying {
            print("🔊 Streaming speech: stopPlayback() while \(isSpeakingChunkSequence ? "a segment was playing" : "between segments (synthesis gap)") — abandoning the rest of the reply")
        }
        activeStreamingSession?.stop()
        activeStreamingSession = nil
        remainingChunksPlaybackTask?.cancel()
        remainingChunksPlaybackTask = nil
        voicePlaybackEngine.stopChunk()
        isSpeakingChunkSequence = false

        // Releasing the engine here is what ends the ducking, and without it an
        // interrupt left every other application on the machine quiet until the
        // next reply — which may be minutes away. Stopping the chunk is not
        // enough: a stopped engine whose voice processing is still on keeps the
        // input device in its communication-app shape, so macOS goes on ducking
        // (this is the 「没用它的时候音量也是小的」 half of the report; see
        // `VoicePlaybackEngine.releaseVoiceProcessingForCaptureOnlyRun`).
        //
        // This is the one funnel every interrupt path reaches — the stop
        // shortcut, a new question replacing a running answer, the vision call
        // failing — and it always runs BEFORE any newer reply's audio is
        // requested, so releasing here cannot cut off a reply that is starting.
        // When a listening window is open the microphone moves to the engine
        // that has no voice processing at all, so the window keeps hearing.
    }

    // MARK: - Synthesis

    /// Requests the finished WAV for one chunk and returns its bytes.
    ///
    /// Takes the resolved role rather than reading it here, so every chunk of one
    /// reply is synthesized by the same provider — see `speakText`.
    ///
    /// Internal rather than private: `StreamingSpeechSession` below drives the
    /// same request path for the 逐句快答 mode.
    func requestAudioData(
        for textChunk: String,
        resolvedSpeechRole: ResolvedModelRole
    ) async throws -> Data {
        // A hand-typed URL with a stray space in it cannot be turned into a URL at
        // all. Reported as a configuration error rather than force-unwrapped: this
        // runs on the main actor, so a crash here takes the whole app down.
        guard let speechSynthesizerURL = resolvedSpeechRole.requestURL else {
            throw BailianTTSClientError(
                message: "朗读模型的 URL 拼不出来：\(resolvedSpeechRole.baseURL)\(resolvedSpeechRole.requestPath)，请检查设置里 \(resolvedSpeechRole.providerDisplayName) 的 URL。"
            )
        }

        var request = URLRequest(url: speechSynthesizerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedSpeechRole.apiKey)", forHTTPHeaderField: "Authorization")

        // Exactly the fields the official Qwen-Audio-TTS parameter table lists.
        // Notably there is no `language_type` here — that field belongs to
        // Qwen-TTS, and this model infers the language from the text.
        var speechInput: [String: Any] = [
            "text": textChunk,
            "format": BailianConfiguration.textToSpeechFormat,
            "sample_rate": BailianConfiguration.textToSpeechSampleRate
        ]
        // Voice names are model-family specific, so this is sent only when the user
        // has one configured for this provider. Omitting it lets the service report
        // a missing field, which is honest; substituting another provider's default
        // voice would instead surface as `Engine error [411]` naming nothing useful.
        if let speechVoiceID = resolvedSpeechRole.speechVoiceID,
           !speechVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechInput["voice"] = speechVoiceID
        }

        // 每次合成都把「用了哪个模型、哪个音色」打出来。用户报的症状是「我点了使用，
        // 但连接时播放的不是那个音色」—— 这一行是那条症状唯一能直接对照的判据：
        // 日志里的 voice 必须等于他刚点的那个 id。
        print("🔊 TTS 合成：model=\(resolvedSpeechRole.modelID) voice=\(resolvedSpeechRole.speechVoiceID ?? "(未指定，用服务端默认)") 文本 \(textChunk.count) 字")

        let body: [String: Any] = [
            "model": resolvedSpeechRole.modelID,
            "input": speechInput
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BailianTTSClientError(message: "Text-to-speech returned an invalid response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw BailianTTSClientError(
                message: "Text-to-speech API error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let output = responseJSON["output"] as? [String: Any],
              let audio = output["audio"] as? [String: Any],
              let audioURLString = audio["url"] as? String,
              !audioURLString.isEmpty else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw BailianTTSClientError(
                message: "Text-to-speech response had no audio URL: \(responseText)"
            )
        }

        return try await downloadAudioFile(fromURLString: audioURLString)
    }

    /// Downloads the synthesized WAV from the URL in the response.
    private func downloadAudioFile(fromURLString audioURLString: String) async throws -> Data {
        // Bailian hands back a plain `http://` OSS link. macOS App Transport
        // Security blocks cleartext HTTP, and the bucket serves the identical
        // file over TLS under the same signature, so upgrade the scheme instead
        // of adding a blanket ATS exception for this host.
        let secureAudioURLString = audioURLString.hasPrefix("http://")
            ? "https://" + audioURLString.dropFirst("http://".count)
            : audioURLString

        guard let audioFileURL = URL(string: secureAudioURLString) else {
            throw BailianTTSClientError(message: "Text-to-speech returned an unusable audio URL.")
        }

        let (audioFileData, response) = try await session.data(from: audioFileURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BailianTTSClientError(
                message: "Could not download synthesized audio (HTTP \(statusCode))."
            )
        }

        return audioFileData
    }

    // MARK: - Playback

    func playAudioData(
        _ audioData: Data,
        chunkIndex: Int,
        chunkCount: Int,
        playbackConfiguration: SpeechPlaybackConfiguration
    ) async {
        do {
            try await voicePlaybackEngine.playWAVData(
                audioData,
                rate: playbackConfiguration.rate,
                volume: playbackConfiguration.volume
            )
            // `speakText` knows the chunk count up front; a streaming session
            // does not (the reply is still being written), so it passes 0.
            let chunkDescription = chunkCount > 0 ? "chunk \(chunkIndex)/\(chunkCount)" : "segment \(chunkIndex)"
            // TEMPORARY PROBE (2026-09-24): the instant audio actually starts
            // rendering, which is what the level curve has to be read against —
            // `isPlaying` covers the whole streaming reply, synthesis gaps
            // included, so it cannot say whether sound was coming out.
            print("🔊 [aecprobe] t=\(String(format: "%.3f", Date().timeIntervalSince1970)) event=chunkStart \(chunkDescription)")
            print("🔊 Bailian TTS: playing \(chunkDescription) (\(audioData.count / 1024)KB)")
        } catch {
            print("⚠️ Bailian TTS: could not play audio chunk \(chunkIndex)/\(chunkCount): \(error.localizedDescription)")
        }
    }

    func playAndWaitUntilFinished(
        _ audioData: Data,
        chunkIndex: Int,
        chunkCount: Int,
        playbackConfiguration: SpeechPlaybackConfiguration
    ) async {
        await playAudioData(
            audioData,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            playbackConfiguration: playbackConfiguration
        )
        await waitUntilPlaybackFinishes()
    }

    /// Polls until the player has stopped.
    ///
    /// Separate from `playAndWaitUntilFinished` because the *first* chunk is
    /// started by `speakText` itself, before the playback task exists: for that
    /// one, starting and waiting are two different moments, and replaying it in
    /// order to reuse the combined method would restart it from the beginning.
    ///
    /// Polls rather than using `AVAudioPlayerDelegate` so this stays a plain
    /// MainActor class. The interval is the streaming mode's join gap: at
    /// every segment boundary, the next segment starts only after this loop
    /// notices the last one ended, so every millisecond here is millisecond
    /// of dead air the listener hears between sentences — 30 ms (down from
    /// 200 ms after the long-pauses-at-joins complaint) is silent to the ear
    /// and costs one boolean check.
    func waitUntilPlaybackFinishes() async {
        while voicePlaybackEngine.isChunkPlaying {
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    // MARK: - Chunking

    /// Splits reply text into chunks that each fit one synthesis request,
    /// preferring to break between sentences so playback doesn't pause mid-thought.
    ///
    /// - Parameter maximumCharactersPerChunk: The per-request character budget.
    ///   Comes from the app settings (说 → 长回答分段合成). The documented service
    ///   cap for `input.text` is 600 characters and the store clamps to that, so
    ///   an oversized value can never reach the request.
    static func splitIntoSpeakableChunks(
        _ text: String,
        maximumCharactersPerChunk: Int
    ) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }
        guard trimmedText.count > maximumCharactersPerChunk else { return [trimmedText] }

        var chunks: [String] = []
        var currentChunk = ""

        for sentence in splitIntoSentences(trimmedText) {
            // A single sentence longer than the limit can't be packed any further —
            // hard-split it so it still gets spoken.
            if sentence.count > maximumCharactersPerChunk {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                    currentChunk = ""
                }
                chunks.append(
                    contentsOf: splitLongSentence(
                        sentence,
                        maximumCharactersPerChunk: maximumCharactersPerChunk
                    )
                )
                continue
            }

            if currentChunk.isEmpty {
                currentChunk = sentence
            } else if currentChunk.count + sentence.count <= maximumCharactersPerChunk {
                currentChunk += sentence
            } else {
                chunks.append(currentChunk)
                currentChunk = sentence
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    /// Splits on sentence-ending punctuation, keeping the punctuation attached to
    /// the sentence it ends. Handles both full-width (Chinese) and ASCII marks.
    private static func splitIntoSentences(_ text: String) -> [String] {
        let sentenceTerminators: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "\n"]

        var sentences: [String] = []
        var currentSentence = ""

        for character in text {
            currentSentence.append(character)
            if sentenceTerminators.contains(character) {
                sentences.append(currentSentence)
                currentSentence = ""
            }
        }

        if !currentSentence.isEmpty {
            sentences.append(currentSentence)
        }

        return sentences
    }

    /// Breaks a single over-long sentence at natural pauses, falling back to a
    /// hard cut when there is no punctuation to break on.
    private static func splitLongSentence(
        _ sentence: String,
        maximumCharactersPerChunk: Int
    ) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        let softBreakCharacters: Set<Character> = ["，", "、", ",", " ", "：", ":"]

        for character in sentence {
            currentChunk.append(character)

            let hasReachedSoftBreakPoint = softBreakCharacters.contains(character)
                && currentChunk.count >= maximumCharactersPerChunk / 2
            let hasReachedHardLimit = currentChunk.count >= maximumCharactersPerChunk

            if hasReachedSoftBreakPoint || hasReachedHardLimit {
                chunks.append(currentChunk)
                currentChunk = ""
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    // MARK: - Streaming speech (逐句快答)

    /// What waiting for the stream's first audio resolved to. The response
    /// pipeline uses this to flip into its "responding" state at the moment the
    /// user actually hears the first segment — which in this mode can be while
    /// the model is still writing — and to speak the apology when synthesis
    /// failed before anything was heard.
    enum StreamingSpeechOutcome: Sendable {
        case firstAudioStarted
        case failed(Error)
        /// The reply ended with nothing speakable (empty, or all action tags),
        /// or the session was stopped — no audio will ever start.
        case nothingToSpeak
    }

    /// Speaks a reply while the model is still generating it.
    ///
    /// Ported from the voice-web reference project's three-part speech chain
    /// (实现方案/11): the reply's tag-stripped text is fed in as it streams, an
    /// aggregator turns the stream into segments that are synthesized the
    /// moment they exist — with up to two syntheses in flight, so while one
    /// segment is playing the next is already on its way. The measured physics
    /// behind the design: synthesis (~19 ms/char + ~450 ms fixed) runs far
    /// faster than playback (~5.8 chars/s), so once the first segment is
    /// audible every later segment is ready before the previous one finishes,
    /// and first audio lands roughly one synthesis after the model's first
    /// words instead of after the whole reply.
    ///
    /// The first sentence's shortness (~15 characters) is a two-sided contract
    /// (2026-09-22): the reference project's own numbers (merge to ≥15, cut at
    /// 60) made the first sound late, and a character-count force cut then made
    /// it sound torn — a sentence chopped mid-phrase. The fix splits the job:
    /// the SYSTEM PROMPT makes the model write its first sentence short (about
    /// 15 characters, ending in 。), while this cutter only ever cuts at
    /// punctuation the model actually wrote.
    ///
    /// The two halves of the reply run under different merge budgets, measured
    /// against the 2026-09-22 complaint that the reply played as many short
    /// segments with a long pause at every join (an eight-segment reply on one
    /// real reply). Later segments cost nothing to enlarge — synthesis is
    /// ~20 ms/char against ~170 ms/char of playback, so a 30-character segment
    /// plays for ~5 s while its successor synthesizes in ~1 s — and every join
    /// avoided is one less per-segment fixed cost (one synthesis request, one
    /// player start, the poll lag, the service's own trailing silence). Only
    /// the FIRST segment stays small, because it alone gates when the user
    /// first hears anything.
    @MainActor
    final class StreamingSpeechSession {

        /// Later segments: merged sentences shorter than this are held until
        /// they add up. This shapes evenness only, never latency — later
        /// segments are synthesized while earlier ones play. 30 (raised from
        /// the reference project's 15 after the too-many-joins complaint) is
        /// several sentences' worth, so joins land mostly at 。 rather than at
        /// every comma, and each segment plays long enough for the model to
        /// stream the next one well ahead of its turn.
        private let minimumSegmentCharacters = 30
        /// Later segments' only remaining character-count cut: a stretch this
        /// long with no punctuation whatsoever (no sentence mark, no comma, no
        /// space — pathologically run-on) still segments here. Kept well above
        /// `minimumSegmentCharacters` so a comma at ≤ 59 characters always
        /// wins over this backstop — the cut must land on punctuation the
        /// model wrote, and the backstop only exists so one unbroken stream
        /// can never stall the queue.
        private let unpunctuatedCutCharacters = 60
        /// The FIRST segment's no-punctuation backstop. Deliberately smaller
        /// than the later one: nothing has sounded yet, so a run-on first
        /// stretch must not be allowed to hold the first sound past 40
        /// characters.
        private let firstSegmentUnpunctuatedCutCharacters = 40
        /// How long a first sentence may be and still play whole rather than
        /// being comma-cut for speed. The system prompt asks the model for ~15
        /// characters; 22 gives that promise slack so a 17–20 character
        /// sentence is not needlessly split at its first comma.
        private let firstSegmentPreferredCeiling = 22
        /// Lookahead depth. Two in-flight syntheses cover ~10 s of playback
        /// against ~1 s of synthesis each at the 30-character merge — deep
        /// enough that the queue never runs dry at real speaking speeds.
        private let maximumSynthesesInFlight = 2

        private let resolvedSpeechRole: ResolvedModelRole
        private let playbackConfiguration: SpeechPlaybackConfiguration
        /// The client that owns this session. Weak because the ownership runs
        /// the other way; the client outlives the session either way.
        private weak var owner: BailianTTSClient?

        init(resolvedSpeechRole: ResolvedModelRole, playbackConfiguration: SpeechPlaybackConfiguration, owner: BailianTTSClient) {
            self.resolvedSpeechRole = resolvedSpeechRole
            self.playbackConfiguration = playbackConfiguration
            self.owner = owner
        }

        // Aggregation state. `consumedSpeakableText` is what has already been
        // diffed; feed() receives the cumulative stripped text, so a repeated
        // or partial update can never double-speak a sentence.
        private var consumedSpeakableText = ""
        private var unemittedBuffer = ""
        /// The first segment runs under a different (faster) rule than the
        /// rest — this flag is what switches between the two.
        private var hasEmittedAnySegment = false
        private var hasFinishedStreaming = false
        private var isStopped = false

        // Synthesis pipeline.
        private var pendingSegments: [String] = []
        private var inFlightSyntheses: [(segmentIndex: Int, task: Task<Data, Error>)] = []
        private var playbackLoopTask: Task<Void, Never>?
        private var queuedSegmentCount = 0
        private var pumpedSegmentCount = 0
        private var firstAudioStarted = false
        private var synthesisFailure: Error?

        /// Fired the moment the first segment's audio actually starts playing.
        var onFirstAudioStarted: (() -> Void)?

        /// True while the session still owes the user audio that has not begun:
        /// a segment is queued or synthesizing and none has sounded yet.
        ///
        /// `isPlaying` is false throughout this window — nothing is playing and
        /// `isSpeakingChunkSequence` only turns on at the first audio — so a
        /// caller that starts polling `isPlaying` right after the reply finished
        /// streaming (the bubble-clear scheduler, the transient hide) would pass
        /// immediately and take the text down while the first segment was still
        /// being synthesized. This is the missing half of that condition. False
        /// once the first audio starts (`isPlaying` covers the rest), and false
        /// when the session can never produce audio — stopped, failed, or ended
        /// with nothing speakable — so the waiter is never stuck.
        var isSynthesizingBeforeFirstAudio: Bool {
            !isStopped && synthesisFailure == nil && !firstAudioStarted
                && !(hasFinishedStreaming && pendingSegments.isEmpty && inFlightSyntheses.isEmpty)
        }

        // MARK: Feeding

        /// Receives the reply's cumulative tag-stripped text. Diffed against
        /// what was already consumed, so the caller can hand over the whole
        /// accumulated text on every update.
        func feed(cumulativeSpeakableText: String) {
            guard !isStopped, !hasFinishedStreaming else { return }
            guard cumulativeSpeakableText.hasPrefix(consumedSpeakableText) else {
                // Stripping only ever removes text, so a lost prefix means the
                // caller changed the text underneath us. Ignoring it is safer
                // than speaking a duplicate sentence.
                print("⚠️ Streaming speech: streamed text lost its prefix; ignoring this update")
                return
            }
            let delta = String(cumulativeSpeakableText.dropFirst(consumedSpeakableText.count))
            guard !delta.isEmpty else { return }
            consumedSpeakableText = cumulativeSpeakableText
            unemittedBuffer += delta
            emitReadySegments()
            // Pump here, not only in the playback loop: a segment that arrives
            // while the previous one is playing must start synthesizing now,
            // or it would only begin after playback ends — the exact gap this
            // mode exists to remove.
            pumpSynthesis()
            ensurePlaybackLoop()
        }

        /// The reply is complete: flush whatever the aggregator is still
        /// holding and let the loop play out the queue.
        func finishStreaming() {
            guard !isStopped, !hasFinishedStreaming else { return }
            hasFinishedStreaming = true
            if !unemittedBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enqueueSegment(unemittedBuffer)
            }
            unemittedBuffer = ""
            pumpSynthesis()
            ensurePlaybackLoop()
        }

        /// 丢掉**正在念的和已经排队的**音频，但**不结束这个会话** —— 打断专用。
        ///
        /// 与 `stop()` 的唯一区别就是它**不置 `isStopped`**，而这一点是全部意义所在：
        /// `stop()` 之后 `feed()` 会永远空转（`guard !isStopped`），所以一次误触
        /// 就让整条回答再也不会出声 —— 用户听到的就是「它自己把自己打断了」。
        /// 而这里丢掉旧的音频之后，后面新流进来的句子照样会合成、照样会播。
        ///
        /// **保留 `consumedSpeakableText` 与 `unemittedBuffer`**：
        /// 前者是对账基线，清掉会让下一次 `feed()` 的前缀校验失败、整段更新被忽略；
        /// 后者是还没成句的文本，清掉就是把字丢了。
        func dropQueuedAudio() {
            guard !isStopped else { return }
            playbackLoopTask?.cancel()
            playbackLoopTask = nil
            for (_, task) in inFlightSyntheses {
                task.cancel()
            }
            inFlightSyntheses = []
            pendingSegments = []
        }

        /// Stops everything and forgets all queued work. Called from the
        /// client's `stopPlayback`, so every existing interrupt path reaches it.
        func stop() {
            isStopped = true
            hasFinishedStreaming = true
            playbackLoopTask?.cancel()
            playbackLoopTask = nil
            for (_, task) in inFlightSyntheses {
                task.cancel()
            }
            inFlightSyntheses = []
            pendingSegments = []
            unemittedBuffer = ""
        }

        /// Waits until the stream's first segment is audible, synthesis fails,
        /// the stream ends with nothing speakable, or the session is stopped.
        func waitUntilFirstAudioOutcome() async -> StreamingSpeechOutcome {
            while true {
                if firstAudioStarted { return .firstAudioStarted }
                if let synthesisFailure { return .failed(synthesisFailure) }
                if isStopped { return .nothingToSpeak }
                if hasFinishedStreaming, pendingSegments.isEmpty, inFlightSyntheses.isEmpty {
                    // The stream ended before anything speakable arrived.
                    return .nothingToSpeak
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // MARK: Aggregation (cut at the model's own punctuation, never mid-sentence)

        /// Moves every segment the buffer already holds into the synthesis
        /// queue. The design rule above every number below: a cut lands where
        /// the model wrote punctuation, never between two characters it
        /// wrote as one phrase — an earlier character-count cut tore sentences
        /// in two and the user heard the tear. The FIRST sentence's shortness
        /// (~15 characters) is the system prompt's job now, not the cutter's.
        ///
        /// First segment, checked on every feed:
        /// ① the first sentence terminator at ≤ 22 characters — a short whole
        /// sentence, the shape the prompt asks for, plays whole rather than
        /// being split at its first comma into a 3-character crumb plus one
        /// extra join;
        /// ② the first comma-family pause — but only once the buffer has
        /// outgrown the 22-character ceiling, so a short first sentence gets
        /// its whole length to arrive before the comma cut fires. The comma
        /// is a cut the model itself wrote, so the first sound still stays
        /// fast whenever the first sentence really is long;
        /// ③ any longer terminator;
        /// ④ a stretch with no punctuation at all still hard-cuts at 40 so
        /// the first sound can never be stalled by one run-on stream.
        ///
        /// Later segments:
        /// ⑤ the smallest prefix ending at a sentence terminator carrying at
        /// least 30 characters — short sentences merge together, so joins land
        /// on 。 instead of on every comma;
        /// ⑥ no terminator — the first comma-family pause past 30 characters;
        /// ⑦ the 60-character no-punctuation backstop.
        private func emitReadySegments() {
            while true {
                if !hasEmittedAnySegment {
                    if let segmentLength = speakableSentenceSegmentLength(
                        in: unemittedBuffer,
                        minimumCharacters: 1,
                        maximumCharacters: firstSegmentPreferredCeiling) {
                        enqueueSegment(String(unemittedBuffer.prefix(segmentLength)))
                        unemittedBuffer.removeFirst(segmentLength)
                        continue
                    }
                    if unemittedBuffer.count > firstSegmentPreferredCeiling,
                       let cutLength = softBreakCutLength(in: unemittedBuffer, minimumCharacters: 1) {
                        enqueueSegment(String(unemittedBuffer.prefix(cutLength)))
                        unemittedBuffer.removeFirst(cutLength)
                        continue
                    }
                    if let segmentLength = speakableSentenceSegmentLength(
                        in: unemittedBuffer,
                        minimumCharacters: 1) {
                        enqueueSegment(String(unemittedBuffer.prefix(segmentLength)))
                        unemittedBuffer.removeFirst(segmentLength)
                        continue
                    }
                    if unemittedBuffer.count >= firstSegmentUnpunctuatedCutCharacters {
                        enqueueSegment(String(unemittedBuffer.prefix(firstSegmentUnpunctuatedCutCharacters)))
                        unemittedBuffer.removeFirst(firstSegmentUnpunctuatedCutCharacters)
                        continue
                    }
                    break
                }
                if let segmentLength = speakableSentenceSegmentLength(in: unemittedBuffer) {
                    enqueueSegment(String(unemittedBuffer.prefix(segmentLength)))
                    unemittedBuffer.removeFirst(segmentLength)
                    continue
                }
                if let cutLength = softBreakCutLength(
                    in: unemittedBuffer,
                    minimumCharacters: minimumSegmentCharacters) {
                    enqueueSegment(String(unemittedBuffer.prefix(cutLength)))
                    unemittedBuffer.removeFirst(cutLength)
                    continue
                }
                if unemittedBuffer.count >= unpunctuatedCutCharacters {
                    enqueueSegment(String(unemittedBuffer.prefix(unpunctuatedCutCharacters)))
                    unemittedBuffer.removeFirst(unpunctuatedCutCharacters)
                    continue
                }
                break
            }
        }

        /// The length of the smallest prefix ending in a sentence terminator
        /// with at least `minimumCharacters` characters, or nil. The first
        /// segment passes 1 (any terminator wins immediately); later segments
        /// pass `minimumSegmentCharacters`. `maximumCharacters` bounds the
        /// match from above — the first segment passes
        /// `firstSegmentPreferredCeiling` so a short whole sentence plays
        /// whole while a long one falls through to the comma rule. A
        /// terminator squeezed between two digits ("3.14") is part of the
        /// number, not a sentence boundary — and because the digits stream in
        /// one at a time, an ASCII "." sitting at the very end of the buffer
        /// is *not yet known* not to be a decimal point, so it is held until
        /// the next character arrives (a "。" is unambiguous and never held).
        private func speakableSentenceSegmentLength(
            in text: String,
            minimumCharacters: Int? = nil,
            maximumCharacters: Int? = nil
        ) -> Int? {
            let minimumLength = minimumCharacters ?? minimumSegmentCharacters
            let characters = Array(text)
            var previousCharacter: Character?
            for (index, character) in characters.enumerated() {
                let characterCount = index + 1
                if let maximumCharacters, characterCount > maximumCharacters {
                    return nil
                }
                let lookaheadCharacter = index + 1 < characters.count ? characters[index + 1] : nil
                if Self.sentenceTerminators.contains(character),
                   characterCount >= minimumLength,
                   !(character == "." && Self.isBetweenDigits(previousCharacter, lookaheadCharacter)),
                   !(character == "." && lookaheadCharacter == nil) {
                    return characterCount
                }
                previousCharacter = character
            }
            return nil
        }

        /// The length of the prefix ending at the first comma-family pause at
        /// or past `minimumCharacters`, or nil when the text has none. This is
        /// where a cut that must not wait for a sentence terminator lands —
        /// the model wrote this pause, so cutting here never tears a phrase.
        /// An ASCII "," at the very end of the buffer is held like the "."
        /// above: with no lookahead it may still turn out to be a thousands
        /// separator ("1,000"), and the next character settles it.
        private func softBreakCutLength(in text: String, minimumCharacters: Int) -> Int? {
            let characters = Array(text)
            var previousCharacter: Character?
            for (index, character) in characters.enumerated() {
                let characterCount = index + 1
                let lookaheadCharacter = index + 1 < characters.count ? characters[index + 1] : nil
                defer { previousCharacter = character }
                guard characterCount >= minimumCharacters,
                      Self.softBreakCharacters.contains(character),
                      !(character == "," && Self.isBetweenDigits(previousCharacter, lookaheadCharacter)),
                      !(character == "," && lookaheadCharacter == nil)
                else { continue }
                return characterCount
            }
            return nil
        }

        private static let digitCharacters: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

        /// Whether the breakpoint sits inside a number — "1,000", "3.14" are
        /// one token, and cutting there reads out half a number.
        private static func isBetweenDigits(
            _ previousCharacter: Character?,
            _ lookaheadCharacter: Character?
        ) -> Bool {
            guard let previousCharacter,
                  Self.digitCharacters.contains(previousCharacter),
                  let lookaheadCharacter,
                  Self.digitCharacters.contains(lookaheadCharacter)
            else { return false }
            return true
        }

        private static let sentenceTerminators: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";", "\n"]
        private static let softBreakCharacters: Set<Character> = ["，", "、", ",", " ", "：", ":"]

        // MARK: Synthesis and playback pipeline

        private func enqueueSegment(_ segment: String) {
            queuedSegmentCount += 1
            print("🗣️ Streaming speech: queued segment \(queuedSegmentCount) (\(segment.count) chars)")
            if queuedSegmentCount == 1 {
            }
            pendingSegments.append(segment)
            // From here on the later-segment rules (①②③ in emitReadySegments)
            // take over from the first-segment rule.
            hasEmittedAnySegment = true
        }

        private func pumpSynthesis() {
            guard let owner else { return }
            while inFlightSyntheses.count < maximumSynthesesInFlight, !pendingSegments.isEmpty {
                let segment = pendingSegments.removeFirst()
                pumpedSegmentCount += 1
                let segmentIndex = pumpedSegmentCount
                let resolvedSpeechRole = self.resolvedSpeechRole
                let synthesisTask = Task {
                    try await owner.requestAudioData(for: segment, resolvedSpeechRole: resolvedSpeechRole)
                }
                inFlightSyntheses.append((segmentIndex, synthesisTask))
            }
        }

        private func ensurePlaybackLoop() {
            guard playbackLoopTask == nil, !isStopped else { return }
            playbackLoopTask = Task { [weak self] in
                guard let self else { return }
                await self.runPlaybackLoop()
                // Detach from the owner only if it still points at *this*
                // session — a newer reply's session may already have replaced it.
                if self.owner?.activeStreamingSession === self {
                    self.owner?.activeStreamingSession = nil
                }
            }
        }

        /// One line per playback-loop exit, naming WHY it left and how much
        /// audio went unplayed.
        ///
        /// Dropping queued segments on a stop is correct — a stop must not keep
        /// talking — but it is silent, and a silent drop is indistinguishable
        /// in the log from a reply that never had any audio. That ambiguity is
        /// what made a level-triggered barge-in read as a synthesis failure and
        /// cost a whole round of diagnosis, so every exit now says which exit
        /// it was.
        private func reportPlaybackLoopExit(reason: String) {
            let unplayedSegmentCount = pendingSegments.count + inFlightSyntheses.count
            // TEMPORARY PROBE (2026-09-24): the end of the rendering window the
            // level curve is bracketed against.
            print("🔊 [aecprobe] t=\(String(format: "%.3f", Date().timeIntervalSince1970)) event=chunkEnd (\(reason))")
            print("🔊 Streaming speech: playback loop exited (\(reason)); \(unplayedSegmentCount) unplayed segment(s) dropped, first audio \(firstAudioStarted ? "had started" : "never started")")
        }

        private func runPlaybackLoop() async {
            guard let owner else { return }
            while !Task.isCancelled, !isStopped {
                pumpSynthesis()
                if let nextSynthesis = inFlightSyntheses.first {
                    do {
                        let audioData = try await nextSynthesis.task.value
                        guard !Task.isCancelled, !isStopped else {
                            reportPlaybackLoopExit(
                                reason: isStopped
                                    ? "stopPlayback() landed while the next segment's audio was in flight"
                                    : "playback task cancelled while the next segment's audio was in flight"
                            )
                            return
                        }
                        inFlightSyntheses.removeFirst()
                        if !firstAudioStarted {
                            firstAudioStarted = true
                            owner.isSpeakingChunkSequence = true
                            onFirstAudioStarted?()
                        }
                        await owner.playAndWaitUntilFinished(
                            audioData,
                            chunkIndex: nextSynthesis.segmentIndex,
                            chunkCount: 0,
                            playbackConfiguration: playbackConfiguration
                        )
                    } catch {
                        if isStopped || Task.isCancelled { return }
                        print("⚠️ Streaming speech: segment synthesis failed: \(error.localizedDescription)")
                        reportPlaybackLoopExit(reason: "segment synthesis failed")
                        synthesisFailure = error
                        // Partial audio already played is still useful; end the
                        // sequence rather than leaving the companion stuck in a
                        // speaking state (same rule as `speakText`'s chunk loop).
                        owner.isSpeakingChunkSequence = false
                        return
                    }
                } else if hasFinishedStreaming, pendingSegments.isEmpty {
                    reportPlaybackLoopExit(reason: "the whole reply played")
                    owner.isSpeakingChunkSequence = false
                    return
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // The loop also leaves here when the task was cancelled without a
            // stop, which is the one exit that used to print nothing at all.
            reportPlaybackLoopExit(
                reason: isStopped ? "stopPlayback()" : "playback task cancelled"
            )
            if isStopped {
                owner.isSpeakingChunkSequence = false
            }
        }
    }
}
