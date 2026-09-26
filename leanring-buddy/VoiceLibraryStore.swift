//
//  VoiceLibraryStore.swift
//  leanring-buddy
//
//  「音色查看」那一页自己的一份本地状态：**收藏**和**克隆音色的昵称**。
//
//  为什么这两样在本地、而不是云端 —— 两条都是被官方 API 的边界逼出来的：
//
//   · 收藏。VoiceWeb 把它存在浏览器 `localStorage` 里，**从不发到服务端**，而且
//     它是「稳定分区」而不是排序：收藏的提到最前面，**组内保持原顺序**
//     （`patch.js:4192` 是一个 `(isFav(b) - isFav(a)) || (a.i - b.i)` 的比较，
//     所以同组内相对次序不动）。既然服务端没有这个概念，原生就自己存一份，
//     没有任何东西需要同步。
//
//   · 昵称。官方声音复刻 API **不保存备注**（VoiceWeb 的注释原话：
//     「昵称是纯本地概念（阿里 API 不保存备注）」）。所以云端只认 `voice_id`，
//     用户给它起的名字只能落在这里。
//
//  存储形状照抄仓库里另外三个 store（`AppSettingsStore` / `ModelConfigurationStore`
//  / `ConversationHistoryStore`）：`nonisolated`、一把 `NSLock` 盖住缓存、
//  原子写之后补 0600、写完发通知。项目用 `SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor` 编译，所以这里的每一个 `nonisolated` 都是有意的。
//

import Foundation

nonisolated extension Notification.Name {
    /// 收藏或昵称变了。界面重读 `VoiceLibraryStore.snapshot()`。
    static let clickyVoiceLibraryChanged = Notification.Name("clickyVoiceLibraryChanged")
}

/// 「音色查看」的本地状态。两个字段都是纯 UI 概念，服务端一无所知。
nonisolated struct VoiceLibrary: Codable, Equatable {

    /// 收藏的音色，**最近收藏的在前**。
    ///
    /// key 带命名空间，因为三个模式的音色是互不相交的三套，同名不同源的音色
    /// 必须分开记 —— 这是 VoiceWeb 的做法（`patch.js` 的 `data-fav`）：
    ///   · 三段式系统音色 / 克隆音色 → 裸 `voice_id`（两共用一套命名空间）
    ///   · 全模态 → `omni:<音色名>`
    ///   · 全双工语音 → `duplex:<音色 id>`
    var favouriteVoiceKeys: [String] = []

    /// 克隆音色的昵称：`voice_id` → 用户起的名字。
    ///
    /// 云端列表只会回 `voice_id`，所以每次展示都要来这里查一次名字。
    var customVoiceNicknames: [String: String] = [:]

    /// 收藏在数组里的最大条数。纯粹是防止一个无限增长的文件；
    /// 用户真正会收藏的音色远不到这个数量。
    static let maximumFavouriteCount = 200

    /// 昵称长度上限 —— 官方复刻接口的 `name` 字段就是这个上限
    /// （VoiceWeb 在服务端 `server.py` 里做 `.strip()[:20]`），这里也照着卡。
    static let maximumNicknameLength = 20
}

nonisolated enum VoiceLibraryStore {

    /// `~/Library/Application Support/Wanna/VoiceLibrary.json`。
    ///
    /// 和另外几个配置文件同一个目录。里面没有密钥，但「你收藏了哪些音色、
    /// 给你的克隆音色起了什么名字」是个人偏好，所以照样 0600。
    static var libraryFileURL: URL? {
        AppSupportDirectory.fileURL(named: "VoiceLibrary.json")
    }

    // MARK: - 缓存

    private static let libraryLock = NSLock()
    private static var cachedLibrary: VoiceLibrary?

    // MARK: - 读

    /// 当前生效的内容。第一次调用后进缓存；锁只覆盖拷贝，文件 I/O 不挡读的人。
    static func snapshot() -> VoiceLibrary {
        libraryLock.lock()
        if let cachedLibrary {
            libraryLock.unlock()
            return cachedLibrary
        }
        libraryLock.unlock()

        let loadedLibrary = loadFromDiskOrDefaults()

        libraryLock.lock()
        if let cachedLibrary {
            libraryLock.unlock()
            return cachedLibrary
        }
        cachedLibrary = loadedLibrary
        libraryLock.unlock()

        return loadedLibrary
    }

    /// 丢掉缓存，下一次 `snapshot()` 重新读盘。
    static func invalidateCache() {
        libraryLock.lock()
        cachedLibrary = nil
        libraryLock.unlock()
    }

    private static func loadFromDiskOrDefaults() -> VoiceLibrary {
        guard let libraryFileURL,
              let rawData = try? Data(contentsOf: libraryFileURL),
              !rawData.isEmpty
        else {
            // 文件不存在 = 什么都还没收藏过，不是错误。
            return VoiceLibrary()
        }

        // 解码失败同样退回空值：这一份是**偏好**，读坏了也不该让「音色查看」
        // 整页打不开。下一次保存会把它写回一个正常的文件。
        return (try? JSONDecoder().decode(VoiceLibrary.self, from: rawData)) ?? VoiceLibrary()
    }

    // MARK: - 收藏

    /// 收藏的 key。命名空间规则见 `VoiceLibrary.favouriteVoiceKeys`。
    ///
    /// 三段式和全模态/全双工的分界就是**音色从哪来**：内置表里的系统音色和
    /// 用户自己克隆的音色共用裸 id 这一套（VoiceWeb 也是如此），另外两个模式
    /// 各自加前缀。
    static func favouriteKey(for voiceID: String, engine: VoiceChatEngine) -> String {
        switch engine {
        case .threeStage: return voiceID
        case .omni: return "omni:\(voiceID)"
        case .duplexVoice: return "duplex:\(voiceID)"
        }
    }

    static func isFavourite(key: String) -> Bool {
        snapshot().favouriteVoiceKeys.contains(key)
    }

    /// 切换收藏。返回切换**之后**的状态，调用方据此提示「已收藏 / 已取消收藏」。
    @discardableResult
    static func toggleFavourite(key: String, displayName: String) throws -> Bool {
        var library = snapshot()
        let wasFavourite = library.favouriteVoiceKeys.contains(key)

        if wasFavourite {
            library.favouriteVoiceKeys.removeAll { $0 == key }
        } else {
            // 最近收藏的排最前 —— VoiceWeb 用的是 `unshift`。
            library.favouriteVoiceKeys.insert(key, at: 0)
            if library.favouriteVoiceKeys.count > VoiceLibrary.maximumFavouriteCount {
                library.favouriteVoiceKeys = Array(
                    library.favouriteVoiceKeys.prefix(VoiceLibrary.maximumFavouriteCount)
                )
            }
        }

        try save(library)
        return !wasFavourite
    }

    /// 按收藏把一串音色排成展示顺序：**收藏的在前，其余保持原顺序**。
    ///
    /// 这是**稳定分区**，不是排序 —— 组内相对次序必须原样保留，否则用户会发现
    /// 「收藏一个音色，别的音色跟着换了位置」。VoiceWeb 的注释同样强调这一点。
    static func orderedByFavourites(
        _ voices: [VoiceOption],
        engine: VoiceChatEngine
    ) -> [VoiceOption] {
        orderedByFavourites(voices, engine: engine) { $0.id }
    }

    /// 同一件事，但适用于任何带 id 的音色行 —— 克隆音色（`CustomVoice`）走的是
    /// 这里。抽成泛型是为了让「收藏优先、组内稳定」这条规则只有一份实现。
    static func orderedByFavourites<Element>(
        _ items: [Element],
        engine: VoiceChatEngine,
        voiceID: (Element) -> String
    ) -> [Element] {
        let favouriteKeys = Set(snapshot().favouriteVoiceKeys)
        guard !favouriteKeys.isEmpty else { return items }

        var favourites: [Element] = []
        var others: [Element] = []
        for item in items {
            if favouriteKeys.contains(favouriteKey(for: voiceID(item), engine: engine)) {
                favourites.append(item)
            } else {
                others.append(item)
            }
        }
        return favourites + others
    }

    // MARK: - 克隆音色的昵称

    /// 用户给这个克隆音色起的名字；没起过就是 nil。
    static func nickname(forCustomVoiceID voiceID: String) -> String? {
        guard let nickname = snapshot().customVoiceNicknames[voiceID],
              !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return nickname
    }

    /// 起名 / 改名。传空串等于删掉这个名字（回落到云端给的 id）。
    static func setNickname(_ nickname: String, forCustomVoiceID voiceID: String) throws {
        var library = snapshot()
        let trimmedNickname = String(
            nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(VoiceLibrary.maximumNicknameLength)
        )

        if trimmedNickname.isEmpty {
            library.customVoiceNicknames.removeValue(forKey: voiceID)
        } else {
            library.customVoiceNicknames[voiceID] = trimmedNickname
        }

        try save(library)
    }

    /// 展示用名字：用户起的 > 云端/预设给的 > 原 id。
    ///
    /// 三级回落的顺序和 VoiceWeb 一致（`server.py` 的
    /// `user_names.get(vid) or preset.get(vid, "")`）。
    static func displayName(forCustomVoiceID voiceID: String, cloudProvidedName: String) -> String {
        if let nickname = nickname(forCustomVoiceID: voiceID) { return nickname }
        let trimmedCloudName = cloudProvidedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCloudName.isEmpty ? voiceID : trimmedCloudName
    }

    // MARK: - 写

    private static func save(_ library: VoiceLibrary) throws {
        guard let libraryFileURL else {
            throw ModelConfigurationStoreError.applicationSupportDirectoryUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let encodedLibrary: Data
        do {
            encodedLibrary = try encoder.encode(library)
        } catch {
            throw ModelConfigurationStoreError.couldNotEncodeConfiguration(underlyingError: error)
        }

        let containingDirectoryURL = libraryFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: containingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encodedLibrary.write(to: libraryFileURL, options: .atomic)
        } catch {
            throw ModelConfigurationStoreError.couldNotWriteConfiguration(underlyingError: error)
        }

        // `.atomic` 是「写临时文件再改名」，落地的权限是 0644 —— 所以模式必须在
        // 改名**之后**补，和另外三个 store 同一个理由。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: libraryFileURL.path
        )

        libraryLock.lock()
        cachedLibrary = library
        libraryLock.unlock()

        NotificationCenter.default.post(name: .clickyVoiceLibraryChanged, object: nil)
    }
}
