//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
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

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// 百炼有**两条**识别路，由**模型名**决定走哪条：
    ///
    ///  · 名字里带 `-realtime`（如 `qwen3-asr-flash-realtime`）→ 实时 websocket，
    ///    说话时就有中间结果。
    ///  · 其余（如 `qwen-audio-3.1-asr-flash`）→ 非实时 HTTP，整句一次认，更准。
    ///
    /// 分流放在这里而不是让用户在设置里选「协议」，因为模型名本身就说明了协议 ——
    /// 多一个开关就多一个能和模型名矛盾的状态。
    private static func bailianProviderForConfiguredModel() -> any BuddyTranscriptionProvider {
        let modelID = ModelConfigurationStore.snapshot()
            .status(of: .transcription).resolvedRole?.modelID ?? ""
        if modelID.contains("realtime") {
            return BailianRealtimeTranscriptionProvider()
        }
        return BailianNonRealtimeTranscriptionProvider()
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))
            ?? defaultProvider

        // Apple Speech is the local, always-available fallback. It is deliberately
        // kept out of this list so it is only ever reached after every cloud
        // provider has been ruled out.
        let cloudProviderCandidates: [(provider: PreferredProvider, instance: any BuddyTranscriptionProvider)] = [
            (.bailian, bailianProviderForConfiguredModel()),
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
