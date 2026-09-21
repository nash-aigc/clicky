//
//  BailianConfiguration.swift
//  leanring-buddy
//
//  Single source of truth for every Alibaba Bailian (阿里云百炼) request the app
//  makes: the workspace endpoint, the API key, and the model IDs.
//

import Foundation

/// Central configuration for the app's Alibaba Bailian calls.
///
/// Why a workspace endpoint instead of the public DashScope one: this account is
/// provisioned on a workspace-scoped MaaS domain (`ws-<id>.<region>.maas.aliyuncs.com`)
/// rather than `dashscope.aliyuncs.com`. Every route — chat completions, TTS, and
/// the realtime websocket — hangs off that same host, so the base URL is read from
/// the gitignored secrets plist instead of being hardcoded per client.
enum BailianConfiguration {

    /// Workspace-scoped base URL, e.g. `https://ws-xxxx.cn-beijing.maas.aliyuncs.com`.
    /// Read from the gitignored `BailianSecrets.plist` so the account-specific host
    /// name never lands in version control.
    static var workspaceBaseURL: String? {
        AppBundleConfiguration.stringValue(forKey: "BailianWorkspaceBaseURL")
    }

    /// The Bailian API key. Lives in the gitignored `BailianSecrets.plist`.
    static var apiKey: String? {
        AppBundleConfiguration.stringValue(forKey: "BailianAPIKey")
    }

    /// True when both the endpoint and the key were found in the bundle.
    /// Used by the clients to report a clear configuration error instead of
    /// failing later with an opaque HTTP error.
    static var isConfigured: Bool {
        workspaceBaseURL != nil && apiKey != nil
    }

    /// Model IDs, kept here so the model picker in the panel and the clients that
    /// actually call the API can never drift out of sync.
    enum Models {
        /// Vision-language model used to answer questions about the user's screenshots.
        enum VisionChat {
            /// Higher quality — the default. Bigger context, better at reading UI detail.
            static let plus = "qwen3-vl-plus"
            /// Lower cost — roughly 1/6 the price per input token, slightly weaker.
            static let flash = "qwen3-vl-flash"

            static let allModelIDs = [plus, flash]
            static let defaultModelID = plus
        }

        /// Streaming speech-to-text. Chosen over the file-upload models so the
        /// transcript appears while the user is still talking.
        static let realtimeTranscription = "qwen3-asr-flash-realtime"

        /// Text-to-speech used to read answers aloud.
        ///
        /// Qwen-Audio-TTS is a different model family from Qwen-TTS
        /// (`qwen3-tts-flash`) and is served from a different endpoint — see
        /// `Paths.dashScopeSpeechSynthesizer`. Its voice names and request body
        /// are not interchangeable with Qwen-TTS.
        static let textToSpeech = "qwen-audio-3.1-tts-flash"
    }

    /// Voice used for spoken replies. `yuxiaoyun_v3.1` (于小云) is the
    /// Qwen-Audio-TTS 3.1 voice Alibaba describes as 元气、亲切、自然 — a warm,
    /// natural Mandarin female voice, and the closest match to the `Cherry` voice
    /// used before.
    ///
    /// Voice names are model-family specific: the Qwen-TTS names (`Cherry`,
    /// `Serena`, …) are rejected by this model with `Engine error [411]`. See the
    /// Qwen-Audio-TTS voice list for alternatives such as `yeqinghe_v3.1` or
    /// `yezhiqing_v3.1`.
    static let textToSpeechVoice = "yuxiaoyun_v3.1"

    /// Output format and sample rate for synthesized audio. These belong to the
    /// Qwen-Audio-TTS schema — Qwen-TTS has no equivalent fields, and rejects
    /// `format` as an unknown parameter. The response is a URL to a finished WAV
    /// in exactly this format.
    static let textToSpeechFormat = "wav"
    static let textToSpeechSampleRate = 24000

    /// Paths, relative to the workspace base URL.
    enum Paths {
        /// OpenAI-compatible chat completions. Standard SSE, so the response can be
        /// parsed with the same shape as any OpenAI streaming response.
        static let openAICompatibleChatCompletions = "/compatible-mode/v1/chat/completions"

        /// Qwen-Audio-TTS / CosyVoice speech synthesis.
        ///
        /// Alibaba documents these endpoints as non-interchangeable: a
        /// Qwen-Audio-TTS model posted to the multimodal-generation route fails
        /// with `InvalidParameter: url error, please check url`, and a Qwen-TTS
        /// model posted here fails the same way.
        static let dashScopeSpeechSynthesizer = "/api/v1/services/audio/tts/SpeechSynthesizer"

        /// Realtime websocket route, shared by streaming ASR and streaming TTS.
        /// Requests are dispatched by the `model` query parameter.
        static let realtimeWebSocket = "/api-ws/v1/realtime"
    }
}
