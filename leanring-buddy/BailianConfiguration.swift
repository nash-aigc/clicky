//
//  BailianConfiguration.swift
//  leanring-buddy
//
//  Where the app finds the models it uses, and what the Alibaba Bailian
//  (阿里云百炼) defaults are.
//
//  The user's live configuration lives in `ModelConfiguration.json` and is read
//  through `ModelConfigurationStore` — the three `resolved…` properties below are
//  the only way the rest of the app should reach it. Nothing here caches: each
//  access resolves against the current configuration, so a change saved in the
//  settings window takes effect on the next request rather than the next launch.
//
//  What remains of the Bailian-specific constants is the *seed* — the values used
//  to build a starting configuration for a user who has never opened the
//  settings window, plus the shared model IDs that seed refers to.
//

import Foundation

/// Resolved, ready-to-use settings for one role, and the Bailian defaults the
/// app ships with.
///
/// Nonisolated so that everything built on it — the store, the connection tester,
/// the three clients — can reach it from whatever context it already runs in,
/// instead of being dragged onto the main actor to read a constant.
nonisolated enum BailianConfiguration {

    // MARK: - Roles

    /// 👂 Speech-to-text.
    static var resolvedTranscription: ResolvedModelRole? {
        ModelConfigurationStore.snapshot().resolvedRole(.transcription)
    }

    /// 🧠 Vision chat.
    static var resolvedVision: ResolvedModelRole? {
        ModelConfigurationStore.snapshot().resolvedRole(.vision)
    }

    /// 👄 Text-to-speech.
    static var resolvedSpeech: ResolvedModelRole? {
        ModelConfigurationStore.snapshot().resolvedRole(.speech)
    }

    /// True when speech recognition has a usable provider.
    ///
    /// Used by the transcription provider to report a clear configuration error
    /// instead of failing later with an opaque websocket failure. Vision and
    /// speech report their own status through `snapshot().status(of:)`, which
    /// carries the reason something isn't usable rather than just a flag.
    static var isConfigured: Bool {
        resolvedTranscription != nil
    }

    // MARK: - Legacy secrets (seed only)

    /// Workspace-scoped base URL, e.g. `https://ws-xxxx.cn-beijing.maas.aliyuncs.com`.
    ///
    /// Read from the gitignored `BailianSecrets.plist`. Only consulted when
    /// building the starting configuration — once the user has saved a
    /// configuration, the settings window is the source of truth and this plist
    /// is no longer in the request path at all.
    static var legacyWorkspaceBaseURL: String? {
        AppBundleConfiguration.stringValue(forKey: "BailianWorkspaceBaseURL")
    }

    /// The Bailian API key, from the gitignored `BailianSecrets.plist`.
    /// Consulted only when seeding, same as `legacyWorkspaceBaseURL`.
    static var legacyAPIKey: String? {
        AppBundleConfiguration.stringValue(forKey: "BailianAPIKey")
    }

    // MARK: - Default model IDs

    /// Model IDs this app ships with, used to seed a new configuration and to
    /// offer suggestions in the settings window. They are defaults, not
    /// restrictions — the settings window accepts any model name the user types.
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

        /// 非实时语音识别 —— **整句交给模型，一次拿回完整转写**。
        ///
        /// 2026-09-24 从 `qwen3-asr-flash-realtime` 换到它，理由见
        /// `BailianNonRealtimeTranscriptionProvider` 的文件头：流式的中间结果会
        /// 一边说一边改写（用户看到「文字总是在变」），而且准确率差得远（同一段
        /// 12 秒音频，实时的把句子截断成「…很高。」，这个一字不差）。
        /// 实时那条路仍然可用 —— 模型名里带 `-realtime` 就会走它。
        static let realtimeTranscription = "qwen-audio-3.0-realtime-flash"

        /// Text-to-speech used to read answers aloud.
        ///
        /// Qwen-Audio-TTS is a different model family from Qwen-TTS
        /// (`qwen3-tts-flash`) and is served from a different endpoint — see
        /// `APIProviderFlavor.requestPath(for:)`. Its voice names and request body
        /// are not interchangeable with Qwen-TTS.
        static let textToSpeech = "qwen-audio-3.1-tts-flash"
    }

    /// Default voice for spoken replies.
    ///
    /// This is a **cloned** voice from the Bailian voice-enrollment service
    /// (赵今麦's cloned voice). Cloned voice IDs carry the driving model's name
    /// as their prefix (`qwen-audio-3.1-tts-flash-…`), so this ID only works
    /// with the matching TTS model — swap the model and the voice must move
    /// with it.
    ///
    /// To use a stock voice instead, pick from the Qwen-Audio-TTS 3.1 voice
    /// list, e.g. `yuxiaoyun_v3.1` (于小云, 元气亲切女声) or `yeqinghe_v3.1`
    /// (叶清禾, 亲切温柔). Stock names are model-family specific too: the
    /// Qwen-TTS names (`Cherry`, `Serena`, …) are rejected by this model with
    /// `Engine error [411]`.
    ///
    /// Editable per provider in the settings window.
    static let textToSpeechVoice = "qwen-audio-3.1-tts-flash-zjm-7f08616cacf844bbbb165213d739f060"

    /// Output format and sample rate for synthesized audio. These belong to the
    /// Qwen-Audio-TTS schema — Qwen-TTS has no equivalent fields, and rejects
    /// `format` as an unknown parameter. The response is a URL to a finished WAV
    /// in exactly this format.
    static let textToSpeechFormat = "wav"
    static let textToSpeechSampleRate = 24000
}
