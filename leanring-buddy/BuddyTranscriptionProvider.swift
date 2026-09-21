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
    func cancel()
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
            (.bailian, BailianRealtimeTranscriptionProvider()),
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
