//
//  BuddyTranscriptionProvider.swift
//  Wanna
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    /// 这一句交付完了，**保住会话**准备下一句。
    ///
    /// 默认空实现：只有实时流式的那条路（百炼）需要它 —— 它的会话可以连着用，
    /// 而另外两个 provider（上传式 / Apple 本地）本来就是一句话一个会话。
    func beginNextUtterance()
    func cancel()
}

extension BuddyStreamingTranscriptionSession {
    func beginNextUtterance() {}
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case bailian = "bailian"
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case appleSpeech = "apple"
    }

    /// Used when `VoiceTranscriptionProvider` is missing from the bundle config.
    private static let defaultProvider: PreferredProvider = .bailian

    /// `transcriptionModelIDOverride`：语音聊天的**角色独立配置**。对话页不传，
    /// 走「听」页的全局选择；传了就以它为准（工厂按模型名分流，见下面那三行）。
    static func makeDefaultProvider(
        transcriptionModelIDOverride: String? = nil
    ) -> any BuddyTranscriptionProvider {
        let provider = resolveProvider(override: transcriptionModelIDOverride)
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// 百炼有**三条**识别路，由**模型名**决定走哪条：
    ///
    ///  · `qwen-audio-3.x-realtime-*`（全双工语音那个**语音模型**）→ 拿它当纯识别器：
    ///    它识别又快又准，而且可以不生成回答（实测：commit 后 0.27 秒出转写、
    ///    一个 `response.*` 事件都没有）。
    ///  · 其它带 `realtime` 的（`qwen3-asr-flash-realtime`）→ 专用的实时识别模型。
    ///  · 其余（`qwen-audio-3.1-asr-flash`）→ 非实时 HTTP，整句一次认。
    ///
    /// 分流放在这里而不是让用户在设置里选「协议」，因为模型名本身就说明了协议 ——
    /// 多一个开关就多一个能和模型名矛盾的状态。设置页那一栏选的是**模型**，路由
    /// 从这里推出来。
    private static func bailianProviderForConfiguredModel(override: String?) -> any BuddyTranscriptionProvider {
        let configuredModelID = ModelConfigurationStore.snapshot()
            .status(of: .transcription).resolvedRole?.modelID ?? ""
        // 角色覆盖优先；没有覆盖才看全局配置。
        let modelID = override ?? configuredModelID

        // 语音模型当识别器：名字形如 `qwen-audio-3.0-realtime-flash`。
        // 判据是 `qwen-audio-` + `-realtime`，因为这一族里还有 `qwen-audio-3.1-realtime-plus`。
        if modelID.hasPrefix("qwen-audio-") && modelID.contains("realtime") {
            let speechProvider = BailianRealtimeSpeechTranscriptionProvider()
            speechProvider.modelIDOverride = override
            return speechProvider
        }
        if modelID.contains("realtime") {
            let realtimeProvider = BailianRealtimeTranscriptionProvider()
            realtimeProvider.modelIDOverride = override
            return realtimeProvider
        }
        let nonRealtimeProvider = BailianNonRealtimeTranscriptionProvider()
        nonRealtimeProvider.modelIDOverride = override
        return nonRealtimeProvider
    }

    private static func resolveProvider(override: String?) -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))
            ?? defaultProvider

        // Apple Speech is the local, always-available fallback. It is deliberately
        // kept out of this list so it is only ever reached after every cloud
        // provider has been ruled out.
        let cloudProviderCandidates: [(provider: PreferredProvider, instance: any BuddyTranscriptionProvider)] = [
            (.bailian, bailianProviderForConfiguredModel(override: override)),
            (.assemblyAI, AssemblyAIStreamingTranscriptionProvider()),
            (.openAI, OpenAIAudioTranscriptionProvider())
        ]

        // Try the preferred provider first, then the others in their listed order.
        var orderedCandidates = cloudProviderCandidates
        if let preferredCandidateIndex = orderedCandidates.firstIndex(where: { $0.provider == preferredProvider }) {
            let preferredCandidate = orderedCandidates.remove(at: preferredCandidateIndex)
            orderedCandidates.insert(preferredCandidate, at: 0)
        }

        for candidate in orderedCandidates where candidate.instance.isConfigured {
            if candidate.provider != preferredProvider {
                print("⚠️ Transcription: \(preferredProvider.rawValue) preferred but not configured, falling back to \(candidate.instance.displayName)")
            }
            return candidate.instance
        }

        print("⚠️ Transcription: no cloud provider is configured, falling back to Apple Speech")
        return AppleSpeechTranscriptionProvider()
    }
}
