//
//  VoiceChatPresetStore.swift
//  Wanna
//
//  预设里**用户能改的那一部分**的落盘：标题、备注、收藏，以及全双工预设换过的模型。
//
//  形状与 `VoiceChatRoleStore` / `AgentSessionStore` / `AppSettingsStore` 完全一致
//  （`nonisolated` + `NSLock` 缓存 + 单一 `mutate` 漏斗 + 原子写后补 0600 + 变更通知），
//  因为要解决的是同一批问题：跨线程读、写盘权限、文件与通知永不脱节。
//
//  **内核字段不可改**：`id` / `channel` / `engine` / 是否默认 / 三段式的三个模型 ——
//  这份文件里根本没有它们的字段，界面也不提供入口。用户定的规矩是
//  「预设只能放已验证的组合」，那么"模型组合"就不该是一个能被写进来的数据。
//  三段式因此**连新建都不可能**（没有可写的地方），而全双工只允许换 `duplexModelID`
//  —— 它本来就是"一个模型包办一切"，换模型等于换整条预设，且模型清单来自代码内置的
//  `VoiceCatalog.fullDuplexModelChoices`。
//

import Foundation

nonisolated extension Notification.Name {
    static let wannaVoiceChatPresetsDidChange =
        Notification.Name("wannaVoiceChatPresetsDidChange")
}

/// 一条预设的用户改动。缺省字段 = 跟随内置清单。
nonisolated struct VoiceChatPresetOverride: Codable, Equatable {
    var title: String?
    var note: String?
    /// 只有全双工预设会有值（换过的模型 id）。三段式的模型组合不可覆盖。
    var duplexModelID: String?
    /// 收藏 —— 收藏的排在默认预设之后、其余之前（稳定分区，不是排序）。
    var isFavourite: Bool?
    /// 用户自己新建的全双工预设（三段式不允许新建，所以这个字段对三段式永远为 nil）。
    ///
    /// 新建的预设必须自带完整的模型信息，否则它连"一条预设"都不成立。
    var customPreset: VoiceChatPreset?

    init(
        title: String? = nil,
        note: String? = nil,
        duplexModelID: String? = nil,
        isFavourite: Bool? = nil,
        customPreset: VoiceChatPreset? = nil
    ) {
        self.title = title
        self.note = note
        self.duplexModelID = duplexModelID
        self.isFavourite = isFavourite
        self.customPreset = customPreset
    }
}

/// 磁盘上的形状。
nonisolated struct StoredVoiceChatPresetOverrides: Codable {
    var overrides: [String: VoiceChatPresetOverride] = [:]
}

nonisolated enum VoiceChatPresetStore {

    private static let fileName = "VoiceChatPresetOverrides.json"
    private static let lock = NSLock()
    private static var cached: StoredVoiceChatPresetOverrides?

    static var fileURL: URL {
        let appFolder = AppSupportDirectory.folderURLOrHome
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent(fileName)
    }

    // MARK: - 读

    static func snapshot() -> StoredVoiceChatPresetOverrides {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = loadFromDisk()
        cached = loaded
        return loaded
    }

    /// **最终清单**：内置 preset 叠上用户改动，再加上用户自己新建的全双工预设。
    ///
    /// 排序规则（用户 2026-09-24）：**默认预设永远第一**（不可编辑、不可移动），
    /// 收藏的紧随其后，其余保持代码里的顺序。这是**稳定分区**而不是排序 ——
    /// 收藏一个预设不该让它和别的收藏之间换位置。
    static func resolvedPresets(for channel: VoiceChatChannel, engine: VoiceChatEngine) -> [VoiceChatPreset] {
        let overrides = snapshot().overrides

        var presets = VoiceChatPreset.presets(for: channel, engine: engine).map { builtIn -> VoiceChatPreset in
            var preset = builtIn
            guard let override = overrides[builtIn.id] else { return preset }
            if let title = override.title, !title.isEmpty { preset.title = title }
            if let note = override.note { preset.note = note }
            if let duplexModelID = override.duplexModelID, !duplexModelID.isEmpty {
                preset = preset.replacingDuplexModel(withID: duplexModelID)
            }
            return preset
        }

        // 用户新建的预设（只有全双工会有）。
        let customPresets = overrides.values
            .compactMap(\.customPreset)
            .filter { $0.channel == channel && $0.engine == engine }
            .sorted { $0.title < $1.title }
        presets.append(contentsOf: customPresets)

        let defaultPreset = presets.filter(\.isDefaultPreset)
        let favourites = presets.filter { !$0.isDefaultPreset && isFavourite($0.id) }
        let rest = presets.filter { !$0.isDefaultPreset && !isFavourite($0.id) }
        return defaultPreset + favourites + rest
    }

    static func isFavourite(_ presetID: String) -> Bool {
        snapshot().overrides[presetID]?.isFavourite ?? false
    }

    // MARK: - 写

    /// 改标题（内置预设也允许 —— 用户说「只能编辑名称、编辑描述」）。
    static func setTitle(_ title: String, forPresetID presetID: String) {
        mutate { overrides in
            var override = overrides[presetID] ?? VoiceChatPresetOverride()
            override.title = title
            overrides[presetID] = override
        }
    }

    static func setNote(_ note: String, forPresetID presetID: String) {
        mutate { overrides in
            var override = overrides[presetID] ?? VoiceChatPresetOverride()
            override.note = note
            overrides[presetID] = override
        }
    }

    /// 收藏 / 取消收藏。默认预设不允许收藏（它本来就在第一位，收藏没有意义）。
    static func toggleFavourite(forPresetID presetID: String) {
        guard let preset = VoiceChatPreset.preset(withID: presetID), !preset.isDefaultPreset else { return }
        mutate { overrides in
            var override = overrides[presetID] ?? VoiceChatPresetOverride()
            override.isFavourite = !(override.isFavourite ?? false)
            overrides[presetID] = override
        }
    }

    /// 全双工预设换模型。
    ///
    /// **只对全双工生效**：三段式的三个位置是三条独立的模型，换哪一个都会改变
    /// "已验证的组合"，那不是用户能做的事。传三段式的 id 进来会静默不动 ——
    /// 界面本来也不提供这个入口。
    static func setDuplexModel(_ modelID: String, forPresetID presetID: String) {
        guard let preset = VoiceChatPreset.preset(withID: presetID),
              preset.engine == .duplexVoice else { return }
        mutate { overrides in
            var override = overrides[presetID] ?? VoiceChatPresetOverride()
            override.duplexModelID = modelID
            overrides[presetID] = override
        }
    }

    /// 新建一条全双工预设。**三段式没有这个入口**（用户明确禁止）。
    @discardableResult
    static func createDuplexPreset(
        channel: VoiceChatChannel,
        duplexModelID: String,
        title: String,
        note: String,
        preferredVoiceID: String? = nil,
        opensScreenByDefault: Bool = false,
        opensCameraByDefault: Bool = false
    ) -> VoiceChatPreset? {
        // 语音聊天不允许开画面 —— 与预设里怎么写无关，这是硬闸。
        let allowsVideo = channel.allowsVideoInputAtAll
        let preset = VoiceChatPreset(
            id: "user.\(channel.rawValue).duplex.\(UUID().uuidString.prefix(8))",
            channel: channel,
            engine: .duplexVoice,
            isDefaultPreset: false,
            title: title,
            note: note,
            recognitionModelID: nil,
            understandingModelID: nil,
            expressionModelID: nil,
            duplexModelID: duplexModelID,
            preferredVoiceID: preferredVoiceID,
            opensScreenByDefault: allowsVideo && opensScreenByDefault,
            opensCameraByDefault: allowsVideo && opensCameraByDefault,
            isReady: true
        )
        mutate { overrides in
            overrides[preset.id] = VoiceChatPresetOverride(customPreset: preset)
        }
        return preset
    }

    /// 删除一条**用户自己建的**全双工预设。内置的删不掉（用户：「预设不可以被删除」）。
    static func deleteCustomPreset(_ presetID: String) {
        guard snapshot().overrides[presetID]?.customPreset != nil else { return }
        mutate { overrides in overrides.removeValue(forKey: presetID) }
    }

    // MARK: - 内部

    private static func mutate(_ body: (inout [String: VoiceChatPresetOverride]) -> Void) {
        lock.lock()
        var store = cached ?? loadFromDisk()
        body(&store.overrides)
        cached = store
        lock.unlock()

        writeToDisk(store)
        NotificationCenter.default.post(name: .wannaVoiceChatPresetsDidChange, object: nil)
    }

    private static func loadFromDisk() -> StoredVoiceChatPresetOverrides {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoredVoiceChatPresetOverrides.self, from: data) else {
            return StoredVoiceChatPresetOverrides()
        }
        return decoded
    }

    private static func writeToDisk(_ store: StoredVoiceChatPresetOverrides) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        let url = fileURL
        try? data.write(to: url, options: .atomic)
        // `.atomic` 落盘是 0644，而这份文件里虽然只有名称和备注，但同一批存储
        // （角色表、对话、设置）都是 0600 —— 保持一致，不给以后往里加东西留坑。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension VoiceChatPreset {
    /// 换掉全双工那一个模型，其余字段照旧。
    func replacingDuplexModel(withID modelID: String) -> VoiceChatPreset {
        VoiceChatPreset(
            id: id,
            channel: channel,
            engine: engine,
            isDefaultPreset: isDefaultPreset,
            title: title,
            note: note,
            recognitionModelID: recognitionModelID,
            understandingModelID: understandingModelID,
            expressionModelID: expressionModelID,
            duplexModelID: modelID,
            preferredVoiceID: preferredVoiceID,
            opensScreenByDefault: opensScreenByDefault,
            opensCameraByDefault: opensCameraByDefault,
            isReady: isReady
        )
    }
}
