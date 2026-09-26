//
//  CustomVoiceLibraryClient.swift
//  Wanna
//
//  用户自己**克隆**出来的音色（声音复刻）—— 列出来、以及后面要加的创建/删除。
//
//  WHY IT IS ITS OWN CLIENT. 这是官方四条「声音复刻」动作里最轻的一条，走的是
// 定制化接口，跟合成完全不是一条路：
//
//      POST https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization
//      { "model": "voice-enrollment", "input": { "action": "list_voice", … } }
//
//  另外三条动作是 `create_voice`（要先把参考音频传成 `oss://`）、`query_voice`
//  （轮询到 `status == OK`）、`delete_voice`。它们共用同一个 `_customization`
//  传输，所以都落在这个文件里，而不是散在视图里各拼一次 JSON。
//
//  **克隆音色是绑定模型的**（官方：3.1 克隆出来的音色只能 3.1 用）。所以
//  `targetModel` 必须跟着音色一起带回来 —— 界面上「使用」一个克隆音色时，如果
//  它的 `targetModel` 和当前合成模型不一致，那条路一定会失败（`Engine error
//  [411]`，一个不提音色也不提模型的报错），必须先拦住并说清楚。
//

import Foundation

/// 一个克隆音色。字段取自官方 `list_voice` 的返回。
nonisolated struct CustomVoice: Identifiable, Equatable {

    /// 填进 `voice` 参数的原值，也是云端唯一认的标识。
    let id: String

    /// 克隆时指定的合成模型。**音色与它绑定**，跨模型用一定失败。
    let targetModel: String

    /// 官方给的创建时间，原样字符串（例如 `2026-09-22 07:12:33`）。
    let createdAt: String

    /// 官方状态。只有 `OK` 的才能用。
    let status: String

    var isReady: Bool { status.caseInsensitiveCompare("OK") == .orderedSame }
}

struct CustomVoiceLibraryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum CustomVoiceLibraryClient {

    /// 官方声音复刻的定制化端点。**注意 host 不是业务空间域名** —— 这一族接口
    /// 只在这个全局端点上，用业务空间的地址会 404。
    private static let customizationEndpointURLString =
        "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization"

    /// 列出该账号下所有克隆音色。
    ///
    /// 分页：官方 `list_voice` 要 `page_index` / `page_size`。这里一次要 100 条 ——
    /// 个人账号远达不到，多要一次比做分页 UI 划算。
    static func listCustomVoices() async throws -> [CustomVoice] {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw CustomVoiceLibraryError(message: "还没有配置「说」这个角色（设置 → 模型），拿不到克隆音色列表。")
        }
        guard let endpointURL = URL(string: customizationEndpointURLString) else {
            throw CustomVoiceLibraryError(message: "克隆音色接口地址拼不出来。")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(resolvedSpeechRole.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "voice-enrollment",
            "input": [
                "action": "list_voice",
                "page_index": 0,
                "page_size": 100
            ]
        ])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomVoiceLibraryError(message: "克隆音色列表没有得到有效响应。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw CustomVoiceLibraryError(message: "拿克隆音色列表失败（HTTP \(httpResponse.statusCode)）：\(errorBody)")
        }

        guard let responseJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let output = responseJSON["output"] as? [String: Any]
        else {
            throw CustomVoiceLibraryError(message: "克隆音色列表的响应看不懂。")
        }

        let rawVoiceList = (output["voice_list"] as? [[String: Any]]) ?? []
        return rawVoiceList.compactMap { entry in
            guard let voiceID = entry["voice_id"] as? String, !voiceID.isEmpty else { return nil }
            return CustomVoice(
                id: voiceID,
                targetModel: (entry["target_model"] as? String) ?? "",
                createdAt: (entry["gmt_create"] as? String) ?? "",
                status: (entry["status"] as? String) ?? ""
            )
        }
        // 官方的顺序不可依赖，这里按创建时间倒序 —— 刚克隆完的排最前面。
        .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 克隆一个音色

    /// 从本地参考音频建一个克隆音色，返回云端给的 `voice_id`。
    ///
    /// **四步，缺一步都不行**（每一步都在 2026-09-24 实测跑通过一遍：
    /// `getPolicy` → multipart 上传 → `create_voice` → 轮询到 `OK`）：
    ///
    ///   1. 取上传凭证（`GET /api/v1/uploads?action=getPolicy&model=voice-enrollment`）。
    ///      注意这个端点在**全局域名** `dashscope.aliyuncs.com` 上，不在业务空间域名下。
    ///   2. 把文件 multipart 传到凭证给的 OSS 主机，拿到 `oss://…` 地址。
    ///      **这一步就是 VoiceWeb 要 shell 出去跑 `bl file upload` 的那一步** ——
    ///      官方文档把协议写全了，所以这里直接实现，App 不需要任何外部命令行依赖。
    ///   3. `create_voice`（**必须带 `X-DashScope-OssResourceResolve: enable` 头**，
    ///      否则服务端解析不了 `oss://` 地址）。
    ///   4. 轮询 `query_voice`：实测要 **8~10 秒**（`DEPLOYING` 四五次才变 `OK`），
    ///      所以界面上必须有进度或轮询，不能同步等。
    ///
    /// `targetModel` 是**音色绑定**的那个合成模型：克隆出来的音色只能用在它上面，
    /// 填错的话后面合成会失败。
    static func createVoice(
        referenceAudioFileURL: URL,
        targetModel: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw CustomVoiceLibraryError(message: "还没有配置「说」这个角色（设置 → 模型），无法克隆音色。")
        }
        let apiKey = resolvedSpeechRole.apiKey

        let audioFileData: Data
        do {
            audioFileData = try Data(contentsOf: referenceAudioFileURL)
        } catch {
            throw CustomVoiceLibraryError(message: "读不到参考音频：\(error.localizedDescription)")
        }
        // 官方上限 10 MB。本地先拦一次，比传上去再被拒要快得多。
        guard audioFileData.count <= 10 * 1024 * 1024 else {
            throw CustomVoiceLibraryError(
                message: "参考音频 \(audioFileData.count / 1024 / 1024) MB，超过官方 10 MB 上限。"
            )
        }

        onProgress?("正在上传参考音频…")
        let ossURLString = try await uploadReferenceAudio(
            audioFileData,
            fileName: referenceAudioFileURL.lastPathComponent,
            apiKey: apiKey
        )

        onProgress?("正在创建音色…")
        // prefix 只能是小写字母和数字、1~9 位（官方约束）。用时间戳保证不重复。
        let prefix = "ck" + String(format: "%07d", Int(Date().timeIntervalSince1970 * 10) % 10_000_000)
        let createResponse = try await postCustomization(
            apiKey: apiKey,
            input: [
                "action": "create_voice",
                "target_model": targetModel,
                "prefix": prefix,
                "url": ossURLString
            ],
            requiresOssResolveHeader: true
        )
        guard let output = createResponse["output"] as? [String: Any],
              let voiceID = output["voice_id"] as? String,
              !voiceID.isEmpty
        else {
            throw CustomVoiceLibraryError(message: "创建音色没有返回 voice_id：\(createResponse)")
        }

        onProgress?("正在等待音色可用…（通常 8~10 秒）")
        try await waitUntilVoiceIsReady(voiceID: voiceID, apiKey: apiKey, onProgress: onProgress)
        return voiceID
    }

    /// 等 `query_voice` 变成 `OK`。
    ///
    /// 实测（2026-09-24）：一次克隆要 `DEPLOYING` 四五次、约 8~10 秒才 `OK`。
    /// 所以这里每 2 秒问一次、最多 20 次（≈40 秒）—— 超过就认为失败，而不是无限等。
    private static func waitUntilVoiceIsReady(
        voiceID: String,
        apiKey: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        for attempt in 1...20 {
            let queryResponse = try await postCustomization(
                apiKey: apiKey,
                input: ["action": "query_voice", "voice_id": voiceID]
            )
            let status = (queryResponse["output"] as? [String: Any])?["status"] as? String ?? ""
            if status.caseInsensitiveCompare("OK") == .orderedSame { return }
            onProgress?("正在等待音色可用…（\(status.isEmpty ? "排队中" : status)，第 \(attempt) 次）")
            try await Task.sleep(for: .seconds(2))
        }
        throw CustomVoiceLibraryError(
            message: "音色「\(voiceID)」一直在排队（超过 40 秒没有变成 OK）。去百炼控制台看看它的状态。"
        )
    }

    /// 删掉一个克隆音色 —— **云端也删**。
    ///
    /// 用户要的是「删掉、重新克隆一个全新的」，所以只从本地列表里藏起来不算数：
    /// 那个音色还占着账号里的一条记录、还能被合成用到。这一条走完才是真的没了。
    static func deleteVoice(voiceID: String) async throws {
        guard let resolvedSpeechRole = ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole else {
            throw CustomVoiceLibraryError(message: "还没有配置「说」这个角色（设置 → 模型），无法删除音色。")
        }
        let response = try await postCustomization(
            apiKey: resolvedSpeechRole.apiKey,
            input: ["action": "delete_voice", "voice_id": voiceID]
        )
        // 官方成功时 `output` 是空对象，失败会带 code/message，所以只查错误。
        if let code = response["code"] as? String, !code.isEmpty {
            throw CustomVoiceLibraryError(message: "云端删除失败（\(code)）：\(response["message"] ?? "")")
        }
    }

    // MARK: - 上传参考音频

    /// 取上传凭证 → multipart 上传 → 返回 `oss://…` 地址。
    ///
    /// 完全按官方文档的 Python 示例实现（`get-temporary-file-url.md`），
    /// 所以**不需要 `bl` 之类的命令行**。
    private static func uploadReferenceAudio(
        _ audioFileData: Data,
        fileName: String,
        apiKey: String
    ) async throws -> String {
        // ① 凭证。`model` 必须是**将来要用这个文件的模型** —— 声音复刻就是
        //    `voice-enrollment`，填别的会被拒。
        guard let policyURL = URL(string:
            "https://dashscope.aliyuncs.com/api/v1/uploads?action=getPolicy&model=voice-enrollment"
        ) else {
            throw CustomVoiceLibraryError(message: "上传凭证地址拼不出来。")
        }
        var policyRequest = URLRequest(url: policyURL)
        policyRequest.httpMethod = "GET"
        policyRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (policyData, policyResponse) = try await URLSession.shared.data(for: policyRequest)
        guard let policyHTTP = policyResponse as? HTTPURLResponse, (200...299).contains(policyHTTP.statusCode) else {
            let body = String(data: policyData, encoding: .utf8) ?? ""
            throw CustomVoiceLibraryError(
                message: "取上传凭证失败（HTTP \((policyResponse as? HTTPURLResponse)?.statusCode ?? -1)）：\(body)"
            )
        }
        guard let policyEnvelope = try? JSONSerialization.jsonObject(with: policyData) as? [String: Any],
              let policy = policyEnvelope["data"] as? [String: Any],
              let uploadHost = policy["upload_host"] as? String,
              let uploadDirectory = policy["upload_dir"] as? String,
              let objectKeyID = policy["oss_access_key_id"] as? String,
              let signature = policy["signature"] as? String,
              let encodedPolicy = policy["policy"] as? String,
              let objectACL = policy["x_oss_object_acl"] as? String,
              let forbidOverwrite = policy["x_oss_forbid_overwrite"] as? String,
              let uploadHostURL = URL(string: uploadHost)
        else {
            throw CustomVoiceLibraryError(message: "上传凭证的字段看不懂，无法上传。")
        }

        // ② multipart 上传。字段名是 OSS 的那一套，大小写和顺序都不能改。
        let objectKey = "\(uploadDirectory)/\(fileName)"
        let boundary = "----wanna\(UUID().uuidString)"
        var body = Data()
        func appendFormField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendFormField("OSSAccessKeyId", objectKeyID)
        appendFormField("Signature", signature)
        appendFormField("policy", encodedPolicy)
        appendFormField("x-oss-object-acl", objectACL)
        appendFormField("x-oss-forbid-overwrite", forbidOverwrite)
        appendFormField("key", objectKey)
        appendFormField("success_action_status", "200")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioFileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var uploadRequest = URLRequest(url: uploadHostURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = body

        let (uploadResponseData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse, uploadHTTP.statusCode == 200 else {
            let body = String(data: uploadResponseData, encoding: .utf8) ?? ""
            throw CustomVoiceLibraryError(
                message: "上传参考音频失败（HTTP \((uploadResponse as? HTTPURLResponse)?.statusCode ?? -1)）：\(body.prefix(200))"
            )
        }
        return "oss://\(objectKey)"
    }

    // MARK: - 定制化接口的传输

    /// 声音复刻四条动作共用的那一个 POST。
    ///
    /// `requiresOssResolveHeader` 只在**要服务端去解析 `oss://` 地址**的那一条上置位
    /// （`create_voice`）。缺了它服务端读不到刚上传的文件，报错也不指向这个头。
    private static func postCustomization(
        apiKey: String,
        input: [String: Any],
        requiresOssResolveHeader: Bool = false
    ) async throws -> [String: Any] {
        guard let endpointURL = URL(string: customizationEndpointURLString) else {
            throw CustomVoiceLibraryError(message: "声音复刻接口地址拼不出来。")
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if requiresOssResolveHeader {
            request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "voice-enrollment",
            "input": input
        ])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomVoiceLibraryError(message: "声音复刻接口没有得到有效响应。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            if errorBody.contains("AllocationQuota.FreeTierOnly") {
                throw CustomVoiceLibraryError(
                    message: "这个账号的免费额度用完了，而控制台里还开着「仅使用免费额度」。"
                        + "去百炼控制台充值、或关掉那个开关，就能克隆。"
                )
            }
            throw CustomVoiceLibraryError(
                message: "声音复刻接口失败（HTTP \(httpResponse.statusCode)）：\(errorBody.prefix(300))"
            )
        }
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }
}
