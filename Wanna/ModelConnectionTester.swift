//
//  ModelConnectionTester.swift
//  Wanna
//
//  Sends one minimal request per role so the user can find out whether a provider
//  they just typed in actually works, before they rely on it.
//
//  Every failure is reported in the service's own words. Tempting as it is to
//  translate them into friendlier text, doing so is what hid an exhausted-quota
//  403 behind a generic "something went wrong" for a long time: the raw body
//  ("AllocationQuota.FreeTierOnly", "Model not exist", "InvalidApiKey") names the
//  fix, and a paraphrase does not.
//

import Foundation

/// What one role's connection test found.
struct ModelConnectionTestResult: Sendable, Equatable {
    let role: ModelRole
    let durationSeconds: TimeInterval
    /// HTTP status, for the roles the app talks to over HTTP.
    /// `nil` for 👂, which is a websocket: there, a completed handshake is the
    /// whole signal, and a failed one arrives as an error rather than a status.
    let httpStatusCode: Int?
    /// The service's own error text, or a configuration explanation when the role
    /// couldn't even be attempted. `nil` means the test passed.
    let errorText: String?

    var isSuccess: Bool {
        errorText == nil
    }
}

enum ModelConnectionTesterError: LocalizedError {
    case unusableURL(baseURL: String, requestPath: String)
    case noHTTPResponse
    case requestRejected(statusCode: Int, responseBody: String)

    var errorDescription: String? {
        switch self {
        case .unusableURL(let baseURL, let requestPath):
            return "URL 拼不出来：\(baseURL)\(requestPath)（请检查 URL 里有没有空格或多余字符）"
        case .noHTTPResponse:
            return "服务端没有返回 HTTP 响应"
        case .requestRejected(let statusCode, let responseBody):
            let trimmedResponseBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedResponseBody.isEmpty
                ? "HTTP \(statusCode)"
                : "HTTP \(statusCode) \(trimmedResponseBody)"
        }
    }
}

@MainActor
enum ModelConnectionTester {
    /// Sessions used only by the tests. Ephemeral so a test never reads or writes
    /// the app's real connection cache, and so nothing about the test is persisted.
    private static let testURLSession = URLSession(configuration: .ephemeral)

    /// One provider instance for the life of the process.
    ///
    /// The transcription provider owns a deliberately long-lived `URLSession` —
    /// creating and discarding one per connection corrupts the OS connection pool
    /// and produces "Socket is not connected" on later attempts — so the test
    /// reuses a single instance instead of building one per run.
    private static let transcriptionTestProvider = BailianRealtimeTranscriptionProvider()

    /// Tests every role, concurrently.
    ///
    /// Runs against `configuration` as passed rather than against what is saved, so
    /// the settings window can test a draft: the user gets to find out whether a
    /// provider works *before* committing it, which is the only order that makes
    /// "test" worth having.
    static func testAllRoles(in configuration: ModelConfiguration) async -> [ModelConnectionTestResult] {
        let results = await withTaskGroup(of: ModelConnectionTestResult.self) { taskGroup in
            for role in ModelRole.allCases {
                taskGroup.addTask { await test(role: role, in: configuration) }
            }

            var collectedResults: [ModelConnectionTestResult] = []
            for await result in taskGroup {
                collectedResults.append(result)
            }
            return collectedResults
        }

        // Reported in role order so the rows don't shuffle between runs.
        return results.sorted { firstResult, secondResult in
            let firstIndex = ModelRole.allCases.firstIndex(of: firstResult.role) ?? 0
            let secondIndex = ModelRole.allCases.firstIndex(of: secondResult.role) ?? 0
            return firstIndex < secondIndex
        }
    }

    static func test(role: ModelRole, in configuration: ModelConfiguration) async -> ModelConnectionTestResult {
        let startTime = Date()

        let roleStatus = configuration.status(of: role)
        guard let resolvedRole = roleStatus.resolvedRole else {
            return ModelConnectionTestResult(
                role: role,
                durationSeconds: 0,
                httpStatusCode: nil,
                errorText: roleStatus.unavailableExplanation ?? "未配置"
            )
        }

        do {
            let httpStatusCode = try await sendMinimalRequest(for: role, resolvedRole: resolvedRole)
            return ModelConnectionTestResult(
                role: role,
                durationSeconds: Date().timeIntervalSince(startTime),
                httpStatusCode: httpStatusCode,
                errorText: nil
            )
        } catch {
            return ModelConnectionTestResult(
                role: role,
                durationSeconds: Date().timeIntervalSince(startTime),
                httpStatusCode: nil,
                errorText: error.localizedDescription
            )
        }
    }

    // MARK: - Per-role requests

    private static func sendMinimalRequest(
        for role: ModelRole,
        resolvedRole: ResolvedModelRole
    ) async throws -> Int? {
        switch role {
        case .transcription:
            return try await testTranscriptionHandshake(resolvedRole: resolvedRole)
        case .vision:
            return try await testChatRequest(resolvedRole: resolvedRole)
        case .speech:
            return try await testSpeechSynthesisRequest(resolvedRole: resolvedRole)
        }
    }

    /// A text-only chat request.
    ///
    /// Deliberately sends no image: this is checking that the host, the key and the
    /// model name are accepted, and attaching a screenshot would only make it slower
    /// and add failure modes that have nothing to do with the settings being tested.
    private static func testChatRequest(resolvedRole: ResolvedModelRole) async throws -> Int {
        var request = try makeJSONRequest(for: resolvedRole)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": resolvedRole.modelID,
            "max_tokens": 64,
            "messages": [
                ["role": "user", "content": "ping"]
            ]
        ])

        return try await send(request)
    }

    /// Synthesizes two characters and throws the audio away.
    ///
    /// Uses the same body shape the app sends, so a voice name from the wrong model
    /// family — whose only symptom in production is a reply that suddenly has no
    /// audio — fails here instead, while the user is looking at the settings.
    private static func testSpeechSynthesisRequest(resolvedRole: ResolvedModelRole) async throws -> Int {
        var request = try makeJSONRequest(for: resolvedRole)

        var speechInput: [String: Any] = [
            "text": "测试",
            "format": BailianConfiguration.textToSpeechFormat,
            "sample_rate": BailianConfiguration.textToSpeechSampleRate
        ]
        if let speechVoiceID = resolvedRole.speechVoiceID,
           !speechVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speechInput["voice"] = speechVoiceID
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": resolvedRole.modelID,
            "input": speechInput
        ])

        return try await send(request)
    }

    /// Opens the realtime websocket and closes it again immediately.
    ///
    /// Runs through the real transcription provider rather than a hand-rolled
    /// handshake, so the test covers exactly what a push-to-talk recording does —
    /// including the `session.update` / `session.updated` exchange, which is the
    /// step a bad key or an unavailable model actually fails at. An accepted
    /// connection is the whole result; there is no HTTP status to report.
    private static func testTranscriptionHandshake(resolvedRole: ResolvedModelRole) async throws -> Int? {
        let streamingSession = try await transcriptionTestProvider.startStreamingSession(
            keyterms: [],
            resolvedTranscriptionRole: resolvedRole,
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { _ in },
            onError: { _ in }
        )
        streamingSession.cancel()
        return nil
    }

    // MARK: - Transport

    private static func makeJSONRequest(for resolvedRole: ResolvedModelRole) throws -> URLRequest {
        guard let requestURL = resolvedRole.requestURL else {
            throw ModelConnectionTesterError.unusableURL(
                baseURL: resolvedRole.baseURL,
                requestPath: resolvedRole.requestPath
            )
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        // Short, because this runs while the user waits. The app's own requests use
        // a much longer timeout for full-size screenshots; a settings test has no
        // reason to hang that long before reporting a problem.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedRole.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Int {
        let (responseData, response) = try await testURLSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelConnectionTesterError.noHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ModelConnectionTesterError.requestRejected(
                statusCode: httpResponse.statusCode,
                responseBody: String(data: responseData, encoding: .utf8) ?? ""
            )
        }

        return httpResponse.statusCode
    }
}
