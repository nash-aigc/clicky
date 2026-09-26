//
//  ModelConfiguration.swift
//  leanring-buddy
//
//  The user-editable model configuration: which provider serves each of the
//  three roles the app needs (👂 listen, 🧠 think, 👄 speak), and what each
//  provider's endpoint, key and model names are.
//
//  This file is pure data and resolution logic — no disk access. The loading
//  and saving live in `ModelConfigurationStore.swift`. Keeping them apart means
//  the resolution rules can be reasoned about without thinking about I/O.
//
//  Every type here is `nonisolated`, and that is load-bearing rather than
//  decorative. The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
//  so an unannotated type is main-actor-isolated; the store, which reads and
//  writes these values from a background-safe `nonisolated` context, could then
//  only reach them through an isolation hop. These are immutable value types with
//  no shared mutable state, so they are safe from any thread by construction, and
//  saying so lets the whole configuration layer stay off the main actor.
//

import Foundation

// MARK: - Roles

/// The three jobs the app asks a model to do.
///
/// The emoji are the user-facing shorthand used in the settings window and the
/// menu bar panel. They live here so the two views can't drift apart.
nonisolated enum ModelRole: String, Codable, CaseIterable, Sendable {
    /// 👂 Speech-to-text. Turns the user's push-to-talk audio into words.
    case transcription
    /// 🧠 Vision chat. Looks at the screenshots and answers the question.
    case vision
    /// 👄 Text-to-speech. Reads the answer aloud.
    case speech

    var emoji: String {
        switch self {
        case .transcription: return "👂"
        case .vision: return "🧠"
        case .speech: return "👄"
        }
    }

    var shortName: String {
        switch self {
        case .transcription: return "听"
        case .vision: return "想"
        case .speech: return "说"
        }
    }

    var displayName: String {
        switch self {
        case .transcription: return "听（语音转文字）"
        case .vision: return "想（看屏幕回答）"
        case .speech: return "说（朗读回答）"
        }
    }
}

// MARK: - Provider flavours

/// Which wire protocol a provider speaks.
///
/// This is what keeps the settings form down to three fields per provider. Each
/// flavour already knows its own request paths, so a non-technical user never has
/// to type an endpoint — and can't silently mistype one either.
nonisolated enum APIProviderFlavor: String, Codable, CaseIterable, Sendable {
    /// Alibaba Cloud Bailian (阿里云百炼). The only flavour here that serves all
    /// three roles: its workspace-scoped MaaS host carries an OpenAI-compatible
    /// chat route, a realtime websocket route and the Qwen-Audio-TTS route.
    case bailian
    /// DeepSeek. OpenAI-shaped, but its chat route has no `/v1` prefix, and the
    /// service offers no speech recognition or speech synthesis at all.
    case deepSeek
    /// A host the user supplies that speaks one of the protocols above — a
    /// different Bailian workspace, or an OpenAI-compatible proxy, for example.
    /// The user picks which protocol, so paths still never have to be typed.
    case custom

    var displayName: String {
        switch self {
        case .bailian: return "阿里云百炼"
        case .deepSeek: return "DeepSeek"
        case .custom: return "自定义"
        }
    }

    /// Filled into the URL field when a provider of this flavour is created.
    var defaultBaseURL: String {
        switch self {
        case .bailian: return ""
        case .deepSeek: return "https://api.deepseek.com"
        case .custom: return ""
        }
    }

    /// The request path for `role`, relative to the provider's base URL.
    ///
    /// `nil` means this flavour cannot serve the role at all. The settings window
    /// renders that as a read-only "不提供此能力" line instead of an input field,
    /// so the user can't type a model name into a role that can never work.
    func requestPath(for role: ModelRole) -> String? {
        switch (self, role) {
        case (.bailian, .vision):
            return "/compatible-mode/v1/chat/completions"
        case (.bailian, .transcription):
            // Rewritten from https:// to wss:// when the URL is built.
            return "/api-ws/v1/realtime"
        case (.bailian, .speech):
            return "/api/v1/services/audio/tts/SpeechSynthesizer"
        case (.deepSeek, .vision):
            // No `/v1` here — verified against the live DeepSeek endpoint.
            return "/chat/completions"
        case (.deepSeek, .transcription), (.deepSeek, .speech):
            return nil
        case (.custom, _):
            // Unreachable: `effectiveFlavor` never resolves to `.custom`.
            return nil
        }
    }

    /// Model IDs offered as suggestions for `role`. Empty when the flavour has no
    /// sensible guess — the user can still type anything into the field.
    func presetModelIDs(for role: ModelRole) -> [String] {
        switch (self, role) {
        case (.bailian, .vision):
            return ["qwen3-vl-plus", "qwen3-vl-flash"]
        case (.bailian, .transcription):
            // 非实时优先（默认），实时的留在列表里 —— 换模型就能换路。
            return ["qwen-audio-3.1-asr-flash", "qwen3-asr-flash-realtime"]
        case (.bailian, .speech):
            return ["qwen-audio-3.1-tts-flash"]
        case (.deepSeek, .vision):
            return ["deepseek-flash"]
        default:
            return []
        }
    }
}

// MARK: - Provider profile

/// One provider the user has configured: where it lives, how to authenticate,
/// and which model this provider should use for each role it can serve.
///
/// The model names hang off the provider rather than off a single role-to-model
/// mapping so that switching a role between two providers remembers what each
/// one was using, instead of making the user retype it every time they switch
/// back.
nonisolated struct ProviderProfile: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var baseURL: String
    var apiKey: String
    var flavor: APIProviderFlavor
    /// Only meaningful when `flavor == .custom`: which protocol this host speaks.
    /// Kept optional so a hand-edited or older file still decodes.
    var customProtocol: APIProviderFlavor?

    var visionModelID: String?
    var transcriptionModelID: String?
    var speechModelID: String?
    /// TTS voice. Belongs to the speech model's family — a voice name from a
    /// different Qwen-TTS family is rejected with `Engine error [411]`.
    var speechVoiceID: String?

    /// Whether the vision model should think before it answers, as the user set it
    /// in the settings window.
    ///
    /// Optional so a file written before this setting existed still decodes: the
    /// synthesized `Codable` throws on a missing key, so a plain `Bool` added now
    /// would make every existing configuration file fail to load. `nil` also
    /// carries meaning — never set — which reads as off in the accessor below.
    var visionReasoningEnabled: Bool?

    /// What a vision request actually does with this provider's model.
    ///
    /// Never set reads as **off**, so thinking stays off for the users who never
    /// open the settings window. Measured 2026-09-21: `deepseek-flash` spends
    /// 664–868 reasoning tokens — 3.4 s of a 4.5 s request — before the first word
    /// of its answer, and Wanna's questions are perception questions answered out
    /// loud, so that is time the user spends watching a spinner and cannot hear.
    /// Off is the default rather than something the user has to discover.
    var allowsVisionReasoning: Bool { visionReasoningEnabled ?? false }

    /// The flavour that actually supplies request paths.
    ///
    /// A `.custom` provider defers to whichever of the two known protocols the
    /// user picked, so `.custom` never escapes this property and every path
    /// lookup lands on a real route.
    var effectiveFlavor: APIProviderFlavor {
        guard flavor == .custom else { return flavor }
        switch customProtocol {
        case .deepSeek: return .deepSeek
        default: return .bailian
        }
    }

    func modelID(for role: ModelRole) -> String? {
        let rawModelID: String?
        switch role {
        case .vision: rawModelID = visionModelID
        case .transcription: rawModelID = transcriptionModelID
        case .speech: rawModelID = speechModelID
        }

        let trimmedModelID = rawModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedModelID, !trimmedModelID.isEmpty else { return nil }
        return trimmedModelID
    }

    mutating func setModelID(_ modelID: String?, for role: ModelRole) {
        switch role {
        case .vision: visionModelID = modelID
        case .transcription: transcriptionModelID = modelID
        case .speech: speechModelID = modelID
        }
    }

    /// True when this provider can serve `role` at all, regardless of whether a
    /// model name has been filled in yet.
    func supports(_ role: ModelRole) -> Bool {
        effectiveFlavor.requestPath(for: role) != nil
    }
}

// MARK: - Configuration document

/// Everything the user has configured, as stored on disk.
nonisolated struct ModelConfiguration: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var providers: [ProviderProfile]

    // Role ownership is stored explicitly rather than derived from the order of
    // `providers`. Deriving it would mean reordering cards to reassign a role,
    // and — worse — deleting a provider would silently hand the role to a
    // different company, sending the user's screenshots somewhere they did not
    // choose.
    var visionProviderID: UUID?
    var transcriptionProviderID: UUID?
    var speechProviderID: UUID?

    init(
        providers: [ProviderProfile],
        visionProviderID: UUID? = nil,
        transcriptionProviderID: UUID? = nil,
        speechProviderID: UUID? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.providers = providers
        self.visionProviderID = visionProviderID
        self.transcriptionProviderID = transcriptionProviderID
        self.speechProviderID = speechProviderID
    }

    /// Tolerant decoding.
    ///
    /// An unreadable configuration file is a hard failure for every feature in
    /// the app, so a file written by a newer build — or hand-edited into a bad
    /// shape — has to degrade to defaults rather than throw and take the whole
    /// app down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion))
            ?? Self.currentSchemaVersion
        self.providers = (try? container.decode([ProviderProfile].self, forKey: .providers))
            ?? []
        self.visionProviderID = try? container.decodeIfPresent(UUID.self, forKey: .visionProviderID)
        self.transcriptionProviderID = try? container.decodeIfPresent(UUID.self, forKey: .transcriptionProviderID)
        self.speechProviderID = try? container.decodeIfPresent(UUID.self, forKey: .speechProviderID)
    }

    // MARK: Role ownership

    func providerID(for role: ModelRole) -> UUID? {
        switch role {
        case .vision: return visionProviderID
        case .transcription: return transcriptionProviderID
        case .speech: return speechProviderID
        }
    }

    mutating func setProviderID(_ providerID: UUID?, for role: ModelRole) {
        switch role {
        case .vision: visionProviderID = providerID
        case .transcription: transcriptionProviderID = providerID
        case .speech: speechProviderID = providerID
        }
    }

    func provider(withID providerID: UUID?) -> ProviderProfile? {
        guard let providerID else { return nil }
        return providers.first { $0.id == providerID }
    }

    func provider(for role: ModelRole) -> ProviderProfile? {
        provider(withID: providerID(for: role))
    }

    /// The roles a provider is currently responsible for. Shown on each provider
    /// card as a read-back ("承担：👂 👄") so the assignment is never invisible.
    func rolesServed(by providerID: UUID) -> [ModelRole] {
        ModelRole.allCases.filter { self.providerID(for: $0) == providerID }
    }
}

// MARK: - Resolution

/// Everything one request needs, resolved from the configuration at the moment
/// the request is built.
///
/// A value type rebuilt per request, so a configuration change can never
/// half-apply to a request already in flight.
nonisolated struct ResolvedModelRole: Sendable, Equatable {
    let role: ModelRole
    let providerID: UUID
    let providerDisplayName: String
    /// Trimmed, with no trailing slash.
    let baseURL: String
    let apiKey: String
    let modelID: String
    let requestPath: String
    let speechVoiceID: String?
    /// Whether the model may think before answering. Carried here so the vision
    /// client can size its request body from what the user chose, without having
    /// to reach back into the store mid-request.
    let allowsVisionReasoning: Bool

    /// `nil` when the base URL and path cannot be turned into a URL at all.
    /// Callers report a clear configuration error instead of force-unwrapping —
    /// a stray space in a hand-typed URL would otherwise crash the app.
    var requestURL: URL? {
        URL(string: baseURL + requestPath)
    }

    /// 同一个角色、换一个**模型**。
    ///
    /// 三段式的「理解」按**预设**选模型（预设里写着 `understandingModelID`），而这里
    /// 解析出来的是全局配置里那份 —— 与音色那条完全同构的问题：不给覆盖，预设里写的
    /// 模型就只是个展示，引擎照样打全局那个。
    func withModelIDOverride(_ modelID: String?) -> ResolvedModelRole {
        guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self
        }
        return ResolvedModelRole(
            role: role,
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            requestPath: requestPath,
            speechVoiceID: speechVoiceID,
            allowsVisionReasoning: allowsVisionReasoning
        )
    }

    /// 同一个角色、换一个音色。
    ///
    /// 语音聊天是按**预设**选音色的（预设自己带 `preferredVoiceID`，否则用角色上存的），
    /// 而这里解析出来的是**全局配置**里那份（设置 → 模型 → 说）—— 两者本来是两个地方。
    /// 这个方法把预设的音色盖上去，其余字段一律不动，于是"选的那个音色"能真的进到
    /// 合成请求体里（`BailianTTSClient` 把 `speechVoiceID` 写进 `input.voice`）。
    func withSpeechVoiceOverride(_ voiceID: String?) -> ResolvedModelRole {
        guard let voiceID, !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self
        }
        return ResolvedModelRole(
            role: role,
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            requestPath: requestPath,
            speechVoiceID: voiceID,
            allowsVisionReasoning: allowsVisionReasoning
        )
    }

    /// The realtime websocket URL for speech recognition: same host and path with
    /// the scheme switched to `wss`, and the model carried as a query parameter
    /// because that route dispatches by model name.
    var websocketURL: URL? {
        guard role == .transcription else { return nil }

        let websocketBaseURL = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        guard var components = URLComponents(string: websocketBaseURL + requestPath) else { return nil }
        components.queryItems = [URLQueryItem(name: "model", value: modelID)]
        return components.url
    }
}

/// Why a role is or isn't usable, spelled out.
///
/// The settings window renders each case differently, so the user can see *which*
/// piece is missing instead of a generic "not configured". This is also what the
/// connection test reports against.
nonisolated enum RoleConfigurationStatus: Sendable, Equatable {
    /// Ready to send requests.
    case ready(ResolvedModelRole)
    /// No provider has been assigned to this role.
    case noProviderAssigned
    /// A provider was assigned, then deleted.
    case assignedProviderMissing
    /// A provider is assigned but has no model name for this role yet.
    case modelNameMissing(providerName: String)
    /// The assigned provider cannot serve this role at all.
    case providerDoesNotSupportRole(providerName: String)
    /// URL or API key is still blank.
    case credentialsMissing(providerName: String)
    /// The URL field has something in it that isn't a usable URL.
    case invalidURL(providerName: String)

    var resolvedRole: ResolvedModelRole? {
        if case .ready(let resolvedRole) = self { return resolvedRole }
        return nil
    }

    /// One-line explanation for the settings window, or `nil` when ready.
    var unavailableExplanation: String? {
        switch self {
        case .ready:
            return nil
        case .noProviderAssigned:
            return "未指定服务商"
        case .assignedProviderMissing:
            return "指定的服务商已被删除"
        case .modelNameMissing(let providerName):
            return "\(providerName) 还没填这个角色的模型名"
        case .providerDoesNotSupportRole(let providerName):
            return "\(providerName) 不提供此能力"
        case .credentialsMissing(let providerName):
            return "\(providerName) 的 URL 或 API Key 还没填"
        case .invalidURL(let providerName):
            return "\(providerName) 的 URL 填得不对"
        }
    }
}

nonisolated extension ModelConfiguration {
    /// Full status of one role, including the exact reason it can't be used.
    func status(of role: ModelRole) -> RoleConfigurationStatus {
        guard let assignedProviderID = providerID(for: role) else {
            return .noProviderAssigned
        }
        guard let provider = providers.first(where: { $0.id == assignedProviderID }) else {
            return .assignedProviderMissing
        }
        guard provider.supports(role) else {
            return .providerDoesNotSupportRole(providerName: provider.displayName)
        }
        guard let modelID = provider.modelID(for: role) else {
            return .modelNameMissing(providerName: provider.displayName)
        }

        let normalizedBaseURL = Self.normalizedBaseURL(provider.baseURL)
        let trimmedAPIKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBaseURL.isEmpty, !trimmedAPIKey.isEmpty else {
            return .credentialsMissing(providerName: provider.displayName)
        }

        guard let requestPath = provider.effectiveFlavor.requestPath(for: role) else {
            return .providerDoesNotSupportRole(providerName: provider.displayName)
        }

        let resolvedRole = ResolvedModelRole(
            role: role,
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            baseURL: normalizedBaseURL,
            apiKey: trimmedAPIKey,
            modelID: modelID,
            requestPath: requestPath,
            speechVoiceID: provider.speechVoiceID,
            allowsVisionReasoning: provider.allowsVisionReasoning
        )

        guard resolvedRole.requestURL != nil else {
            return .invalidURL(providerName: provider.displayName)
        }

        return .ready(resolvedRole)
    }

    func resolvedRole(_ role: ModelRole) -> ResolvedModelRole? {
        status(of: role).resolvedRole
    }

    /// Trims whitespace and strips trailing slashes.
    ///
    /// Deliberately does *not* add or remove a `/v1`, and does not try to
    /// recognise a full endpoint URL pasted into the field — guessing wrong
    /// there sends requests to a path that silently 404s.
    static func normalizedBaseURL(_ rawBaseURL: String) -> String {
        var normalizedBaseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedBaseURL.hasSuffix("/") {
            normalizedBaseURL.removeLast()
        }
        return normalizedBaseURL
    }
}
