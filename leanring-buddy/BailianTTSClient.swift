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
private struct SpeechPlaybackConfiguration {
    let rate: Float
    let volume: Float
}

@MainActor
final class BailianTTSClient {
    private let session: URLSession

    /// The player for the chunk currently being spoken. Kept as a property so the
    /// audio outlives the local scope of whichever method started it.
    private var audioPlayer: AVAudioPlayer?

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
    private func resolveSpeechRole() throws -> ResolvedModelRole {
        let speechRoleStatus = ModelConfigurationStore.snapshot().status(of: .speech)
        guard let resolvedSpeechRole = speechRoleStatus.resolvedRole else {
            let unavailableExplanation = speechRoleStatus.unavailableExplanation ?? "未配置"
            throw BailianTTSClientError(
                message: "朗读模型不可用：\(unavailableExplanation)。请在菜单栏图标的齿轮里打开模型设置。"
            )
        }
        return resolvedSpeechRole
    }

    /// Synthesizes `text` and begins playing it.
    ///
    /// Returns as soon as the *first* chunk of audio starts playing — the caller
    /// uses that moment to switch the companion into its "responding" state, so
    /// waiting for a long reply to finish synthesizing would keep the spinner up
    /// for the whole answer. Any remaining chunks play in the background.
    func speakText(_ text: String) async throws {
        stopPlayback()

        // Resolved once here and passed to every chunk below. Resolving per chunk
        // would let a save in the settings window land between chunk 1 and chunk 2,
        // so a single reply would be spoken half in one provider's voice and half
        // in another's — and `isPlaying` would be tracking two providers at once.
        let resolvedSpeechRole = try resolveSpeechRole()

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
        playAudioData(
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
    /// `isSpeakingChunkSequence` for why the gaps between chunks still count.
    var isPlaying: Bool {
        if audioPlayer?.isPlaying == true { return true }
        return isSpeakingChunkSequence
    }

    /// Stops playback immediately and abandons any chunks still queued.
    func stopPlayback() {
        remainingChunksPlaybackTask?.cancel()
        remainingChunksPlaybackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeakingChunkSequence = false
    }

    // MARK: - Synthesis

    /// Requests the finished WAV for one chunk and returns its bytes.
    ///
    /// Takes the resolved role rather than reading it here, so every chunk of one
    /// reply is synthesized by the same provider — see `speakText`.
    private func requestAudioData(
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

    private func playAudioData(
        _ audioData: Data,
        chunkIndex: Int,
        chunkCount: Int,
        playbackConfiguration: SpeechPlaybackConfiguration
    ) {
        do {
            let player = try AVAudioPlayer(data: audioData)
            // `enableRate` must be set before the player starts; `rate` below 1.0
            // or above 1.0 has no effect without it. Volume is independent.
            player.enableRate = true
            player.rate = playbackConfiguration.rate
            player.volume = playbackConfiguration.volume
            self.audioPlayer = player
            player.play()
            print("🔊 Bailian TTS: playing chunk \(chunkIndex)/\(chunkCount) (\(audioData.count / 1024)KB)")
        } catch {
            print("⚠️ Bailian TTS: could not play audio chunk \(chunkIndex)/\(chunkCount): \(error.localizedDescription)")
        }
    }

    private func playAndWaitUntilFinished(
        _ audioData: Data,
        chunkIndex: Int,
        chunkCount: Int,
        playbackConfiguration: SpeechPlaybackConfiguration
    ) async {
        playAudioData(
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
    /// MainActor class — playback state is checked a few times a second, which is
    /// far finer than the gap between chunks.
    private func waitUntilPlaybackFinishes() async {
        while audioPlayer?.isPlaying == true {
            try? await Task.sleep(nanoseconds: 200_000_000)
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
}
