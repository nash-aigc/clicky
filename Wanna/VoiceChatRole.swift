import Foundation

// MARK: - 角色模型

/// 一个语音聊天角色（用户口中的「助手」/「角色」）。
///
/// 字段取自一份 34 键的角色配置，**去掉了全部 `tools_*`** ——
/// 用户明确要求不移植「执行」，所以角色里没有工具开关，也没有任何文件访问权限。
///
/// **红线：角色里禁止存 API Key。** 配置文件和界面对 `roles` 这一段是**不脱敏**的
/// （只有顶层厂商字段脱敏），任何塞进角色的 Key 都会以明文落在磁盘上、并被回显，
/// 所以「角色不许带 Key」是硬规矩，
/// 免得将来有人图省事把某个角色的 Key 塞进来。
///
/// `chatEngine` 存在角色上而不是全局：每个角色可以自带模式、
/// 模型与音色，切角色等于切一整套说话方式。
nonisolated struct VoiceChatRole: Codable, Equatable, Identifiable {
    /// `"default"` 是内置角色，永远排第一、不可删；其余是 `"r" + 36 进制时间戳`。
    var id: String
    var name: String
    /// 用户给自己看的备注，不发给模型。
    var note: String
    /// 这个角色的系统提示词 —— 会话开始时发给模型的那一段。
    var systemPrompt: String

    /// 这个角色用哪个引擎对话，取值与 `VoiceChatController.VoiceChatMode.engineName` 一致。
    var chatEngine: String
    /// 三段式的合成音色（系统音色名或克隆 voice_id）。
    var ttsVoice: String

    /// **本角色独立**的识别模型（三段式的「听」）。nil = 跟随默认
    /// （`qwen-audio-3.0-realtime-flash`，流式）。每个角色一份，切角色即切配置。
    var recognitionModelID: String?

    /// **本角色独立**的理解模型（三段式的「想」）。nil = deepseek-flash。
    /// 语音模型当理解实测不成立（吐不出纯文字），所以可选项只有 deepseek 系。
    var understandingModelID: String?

    /// **本角色独立**的表达模型（三段式的「说」，即合成模型）。nil = 3.1-tts-flash。
    var expressionModelID: String?

    /// **本角色独立**的全双工语音模型（「全双工语音」类里二选一）。
    /// 它决定那一类的音色表（3.0 Flash 5 个 / 3.1 Plus 13 个）。nil = 3.0 Flash。
    var duplexModelID: String?
    /// **本角色独立**的全模态模型（「全双工全模态」模式用哪个）。nil = 3.8 Omni Flash。
    /// 全模态一个模型包办识别/理解/表达，所以角色上只需要这一个字段。
    var omniModelID: String?
    /// 聊天类型：`"video"` 视频聊天 / `"voice"` 语音聊天（nil 按语音聊天读）。
    ///
    /// 它是一条**分流**：决定全双工那一行给哪些预设、以及画面能不能开。语速不受它影响。
    var chatChannel: String?
    /// 当前选中的**预设** id（`VoiceChatPreset.id`）。nil = 该 (chatChannel, chatEngine)
    /// 下的默认预设。预设是唯一的真相：模型组合、音色、要不要开画面都从它来。
    var presetID: String?
    /// 全模态的内置音色（默认 `Tina`，见 `VoiceCatalog.omniVoices`）。
    /// **与全双工语音那套龙安音色是两张表，不能混填。**
    var omniVoice: String
    /// 全双工语音的内置音色（龙安系）。**与全模态是两套表，不能混填** ——
    /// 写错家族会让服务端把整条 `session.update` 拒掉。
    var duplexVoice: String

    /// 记忆方式：`"continue"` 接着上次聊 / `"fresh"` 每次全新。
    var chatMode: String

    /// 连接时自动开启什么。
    var autoMicEnabled: Bool
    var autoCameraEnabled: Bool
    var autoScreenEnabled: Bool

    /// 头像：默认用 SF Symbol 名（用户可以从一组内置图标里挑）。
    var avatarSymbolName: String
    /// 头像：用户自己上传的图片路径（沙盒外的绝对路径，复制进 Wanna 的目录）。
    /// **非空时优先于符号** —— 用户特意上传了一张，就该看到那一张。
    var avatarImagePath: String?

    /// 是不是「默认角色」。
    ///
    /// 用快捷键起语音对话时用的就是它（用户 2026-09-24：「用户使用快捷键触发语音对话时，
    /// 会自动触发这个默认选项」）。**全局只有一个**：设在 A 身上就把 B 身上的清掉，
    /// 由 `VoiceChatRoleStore.setDefaultRole` 保证，否则「默认」就没有意义了。
    var isDefault: Bool

    /// 内置默认角色 —— 磁盘上什么都没有时由它兜底，
    /// 保证角色列表永远不空。
    static let defaultRoleID = "default"

    static func makeDefaultRole() -> VoiceChatRole {
        VoiceChatRole(
            id: defaultRoleID,
            name: "默认角色",
            note: "",
            systemPrompt: VoiceChatRole.defaultSystemPrompt,
            // 用户 2026-09-25：「右侧默认应该选择的是语音聊天……默认应该是全双工 3.0 Flash」。
            // 预设回落也跟着这条走（见控制器 currentPreset 的回落链）。
            chatEngine: VoiceChatEngine.duplexVoice.rawValue,
            ttsVoice: "",
            // 新角色的默认全模态音色取 **`Tina`**：默认全模态模型是
            // `qwen3.8-omni-flash-realtime`，而它没有 `Ethan`（那是 3.5 的代际）。
            // 填 `Ethan` 不会崩（能力层会换成兜底并说明），但会平白多一次"你选的
            // 音色不可用"的提示 —— 默认值本来就该是这个模型真的接受的那个。
            omniVoice: "Tina",
            duplexVoice: "longanqian",
            chatMode: "continue",
            autoMicEnabled: true,
            autoCameraEnabled: false,
            autoScreenEnabled: false,
            avatarSymbolName: "person.wave.2",
            avatarImagePath: nil,
            isDefault: true
        )
    }

    /// 一个可以聊天的默认提示词。
    ///
    /// 与 Wanna 语音助手那份系统提示词是两件事：那份是「看着屏幕回答」的短问答
    /// 人格，这里是**长时间对话**的角色设定，所以它要求口语、简短、不要 emoji，
    /// 面向「听」而不是「读」。
    static let defaultSystemPrompt = """
    你是用户的语音对话助手。用口语回答，简短直接，不要用 emoji，不要罗列条目。
    用户是在听你说话，不是在读文档，所以一句话能说完就不要说三句。
    """

    /// 新角色的 id —— `"r"` + 36 进制毫秒时间戳，
    /// 保证时间上单调、肉眼可分，且不依赖 UUID 那种人念不出来的形状。
    static func makeRoleID() -> String {
        "r" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    }
}

// MARK: - 磁盘格式与容错解码

/// 磁盘上的整体形状。`activeRoleID` 与 `roles` 一起落盘，
/// 这样「上次用的是哪个角色」能跨重启保留。
nonisolated struct StoredVoiceChatRoles: Codable, Equatable {
    var roles: [VoiceChatRole]
    var activeRoleID: String?
}

// MARK: - 容错解码（规则 E1）

extension VoiceChatRole {
    /// 手写解码，**每个键都用 `decodeIfPresent`**。
    ///
    /// 理由和 `AppSettings` / `AgentSession` / `ConversationSession` 完全一样：
    /// 合成的 `Codable` 遇到缺失的键会 **throw**，那样任何一份「在某个字段存在
    /// 之前」写下的文件都会让整个角色表加载失败。而现在这个模型只会往后加字段
    /// （例如阶段 3 要补的音色与压缩参数），所以这条规矩必须从一开始就立住。
    ///
    /// 写在 `extension` 里而不是结构体体内：结构体体内会顶掉成员式 init，
    /// 而 `makeDefaultRole()` 等调用点依赖它。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VoiceChatRole.makeDefaultRole()

        id = try container.decodeIfPresent(String.self, forKey: .id) ?? fallback.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? fallback.name
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? fallback.note
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? fallback.systemPrompt
        chatEngine = try container.decodeIfPresent(String.self, forKey: .chatEngine)
            ?? fallback.chatEngine
        ttsVoice = try container.decodeIfPresent(String.self, forKey: .ttsVoice) ?? fallback.ttsVoice
        omniVoice = try container.decodeIfPresent(String.self, forKey: .omniVoice) ?? fallback.omniVoice
        duplexVoice = try container.decodeIfPresent(String.self, forKey: .duplexVoice)
            ?? fallback.duplexVoice
        chatMode = try container.decodeIfPresent(String.self, forKey: .chatMode) ?? fallback.chatMode
        autoMicEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoMicEnabled)
            ?? fallback.autoMicEnabled
        autoCameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCameraEnabled)
            ?? fallback.autoCameraEnabled
        autoScreenEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoScreenEnabled)
            ?? fallback.autoScreenEnabled
        avatarSymbolName = try container.decodeIfPresent(String.self, forKey: .avatarSymbolName)
            ?? fallback.avatarSymbolName
        avatarImagePath = try container.decodeIfPresent(String.self, forKey: .avatarImagePath)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false

        // 五个模型字段都要**显式解码**。这一段曾经漏过：encode 是合成的（会把它们
        // 写进文件），decode 是这份手写的（当时没有这几行）—— 结果是选过的模型
        // 落了盘却在下次启动时全部回到默认，而且没有任何报错。
        recognitionModelID = try container.decodeIfPresent(String.self, forKey: .recognitionModelID)
        understandingModelID = try container.decodeIfPresent(String.self, forKey: .understandingModelID)
        expressionModelID = try container.decodeIfPresent(String.self, forKey: .expressionModelID)
        duplexModelID = try container.decodeIfPresent(String.self, forKey: .duplexModelID)
        omniModelID = try container.decodeIfPresent(String.self, forKey: .omniModelID)
        chatChannel = try container.decodeIfPresent(String.self, forKey: .chatChannel)
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
    }

    /// 名字为空时补一个能看的名字（空名 → 「未命名角色」）。
    /// 角色卡片上出现一行空白比出现「未命名角色」更让人困惑。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名角色" : trimmed
    }

    /// 这个角色要用的引擎。取值非法时回落到三段式 —— 三段式是三个里唯一不依赖
    /// 实时模型的，回落到它最不容易「连不上」。
    /// 模式收敛后的读取口（2026-09-24：只剩 全模态 / 三段式 两个模式）。
    /// 旧文件里的 `duplex` 一律按三段式读 —— 它的「听想说一体」由识别/理解/表达
    /// 三栏全选语音模型来达成，不再是一个独立模式。
    var resolvedChatEngine: VoiceChatEngine {
        // **「全双工」和旧的「全模态」都读成全双工。**
        //
        // 全模态不再是模式，而是全双工下面的一族模型（`qwen3.x-omni-*-realtime`）——
        // 由**预设**决定用哪一族，所以两者落到同一个模式上。
        //
        // 这里曾经写着「`duplex` 不再是独立模式，按三段式读」—— 那是上一轮
        // （全双工还藏在模式选择之外）的规则。本轮把全双工放回模式选择之后没跟着改，
        // 后果是：点「全双工」→ 写入 `chatEngine = "duplex"` → 角色变更通知把模式
        // 同步回来时读成三段式 → **勾立刻弹回去，看起来就是"这个按钮点不了"**。
        // （2026-09-24 用户报的正是这个。）
        switch VoiceChatEngine(rawValue: chatEngine) {
        case .duplexVoice, .omni: return .duplexVoice
        // 没写过 / 写坏了也按**全双工**读 —— 用户定的默认模式。
        // （"pipeline" 是历史值，只有显式存过它才走三段式。）
        case .threeStage: return .threeStage
        default: return .duplexVoice
        }
    }

    /// 记忆方式。非法值与缺失一样，按「接着上次聊」走：这既是默认值，
    /// 也是用户按「重启后保留对话」时的预期。
    var resolvesToContinuousMemory: Bool {
        chatMode != "fresh"
    }
}

// MARK: - 引擎枚举

/// 三个对话方案。放在这里而不是控制器里，因为角色要引用它、设置页也要引用它，
/// 放控制器里会让「角色 → 控制器」产生一条没必要的依赖。
nonisolated enum VoiceChatEngine: String, CaseIterable, Identifiable, Codable {
    case threeStage = "pipeline"
    case duplexVoice = "duplex"
    case omni = "omni"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .threeStage: return "三段式"
        // 用户 2026-09-24：「按钮名称始终叫全双工，无论用户选择哪个预设，
        // 显示出来的都叫全双工」—— 具体用哪个模型由预设那一行右侧显示。
        case .duplexVoice: return "全双工"
        case .omni: return "全模态"
        }
    }

    /// 这个引擎能不能送画面。
    ///
    /// 三段式能（它把一帧截图挂进请求），全模态能（`input_image_buffer.append`），
    /// **全双工语音不能** —— 服务端实测 `video_in_enabled=False`，画面帧发过去
    /// 会被忽略，所以界面上那两个开关必须置灰，而不是让用户打开了却什么都不发生。
    var supportsVideoInput: Bool {
        switch self {
        case .threeStage, .omni: return true
        case .duplexVoice: return false
        }
    }

    /// **模式选择器只出两个**（用户 2026-09-24：「真正的模式其实就两个」）。
    /// `duplexVoice` 保留在枚举里只为旧数据解码，不再出现在任何模式下拉。
    static var pickerCases: [VoiceChatEngine] {
        // 用户 2026-09-24 定的两个模式：**全双工 / 三段式**（不是「全模态」）。
        // 这一份同时喂给设置页的音色查看和三个模式快捷键，所以顺序即索引。
        [.duplexVoice, .threeStage]
    }
}

// MARK: - 存储

nonisolated extension Notification.Name {
    static let wannaVoiceChatRolesDidChange = Notification.Name("wannaVoiceChatRolesDidChange")
}

/// 角色表的持久化 —— `VoiceChatRoles.json`。
///
/// 形状与 `AgentSessionStore` / `ConversationSessionsStore` / `AppSettingsStore` 完全一致
/// （`nonisolated` + `NSLock` 缓存 + 单一 `mutate` 漏斗 + 原子写后补 0600 + 变更通知），
/// 因为这几个存储要解决的是同一批问题：跨线程读、写盘权限、以及「文件与通知永不脱节」。
nonisolated enum VoiceChatRoleStore {

    private static let rolesFileName = "VoiceChatRoles.json"
    private static let rolesLock = NSLock()
    private static var cachedRoles: StoredVoiceChatRoles?

    static var rolesFileURL: URL {
        let appFolder = AppSupportDirectory.folderURLOrHome
        try? FileManager.default.createDirectory(
            at: appFolder,
            withIntermediateDirectories: true
        )
        return appFolder.appendingPathComponent(rolesFileName)
    }

    /// 上传头像的存放目录 —— 在 Wanna 自己的目录里，而不是记原路径（见编辑页的注释）。
    static var avatarsDirectoryURL: URL {
        rolesFileURL.deletingLastPathComponent().appendingPathComponent("VoiceChatAvatars", isDirectory: true)
    }

    /// 当前角色表。**永远至少有一个角色**（缺失时补内置默认角色），
    /// 否则语音聊天页会是一张空列表，用户会以为是坏了。
    static func snapshot() -> StoredVoiceChatRoles {
        rolesLock.lock()
        defer { rolesLock.unlock() }

        if let cachedRoles { return cachedRoles }

        let loaded = loadFromDisk()
        cachedRoles = loaded
        return loaded
    }

    /// 全部角色，**默认角色永远排第一** —— 用户要求它「在左侧边栏的卡片上显示在第一个位置」。
    /// 排序放在存储层而不是视图里：三个地方（侧栏、设置页、快捷键）都要同一个顺序，
    /// 各排各的迟早会分叉。
    static func allRoles() -> [VoiceChatRole] {
        snapshot().roles.sorted { left, right in
            if left.isDefault != right.isDefault { return left.isDefault }
            return false
        }
    }

    /// 按 id 取一个角色。取不到时返回一个「空白角色」而不是内置默认角色 ——
    /// 调用方（侧栏卡片）要的是「这张卡片对应的角色」，回落到默认角色会让卡片
    /// 显示成另一个角色的头像，那比显示空头像更难查。
    static func role(withID roleID: String) -> VoiceChatRole {
        if let match = snapshot().roles.first(where: { $0.id == roleID }) { return match }
        var placeholder = VoiceChatRole.makeDefaultRole()
        placeholder.id = roleID
        return placeholder
    }

    /// 快捷键该用哪个角色 —— 就是被标了默认的那个；一个都没有时用第一个，
    /// 保证「按快捷键一定有反应」。
    static func defaultRole() -> VoiceChatRole {
        let roles = allRoles()
        return roles.first(where: { $0.isDefault }) ?? roles.first ?? VoiceChatRole.makeDefaultRole()
    }

    /// 设为默认（全局唯一）。
    static func setDefaultRole(id roleID: String) {
        mutate { stored in
            for index in stored.roles.indices {
                stored.roles[index].isDefault = (stored.roles[index].id == roleID)
            }
        }
    }

    static func activeRole() -> VoiceChatRole {
        let stored = snapshot()
        if let activeRoleID = stored.activeRoleID,
           let match = stored.roles.first(where: { $0.id == activeRoleID }) {
            return match
        }
        return stored.roles.first ?? VoiceChatRole.makeDefaultRole()
    }

    static func invalidateCache() {
        rolesLock.lock()
        cachedRoles = nil
        rolesLock.unlock()
    }

    static func setActiveRoleID(_ roleID: String) {
        mutate { stored in
            guard stored.roles.contains(where: { $0.id == roleID }) else { return }
            stored.activeRoleID = roleID
        }
    }

    static func upsertRole(_ role: VoiceChatRole) {
        mutate { stored in
            if let index = stored.roles.firstIndex(where: { $0.id == role.id }) {
                stored.roles[index] = role
            } else {
                stored.roles.append(role)
            }
        }
    }

    /// 新建一个角色，返回它 —— 上面 `upsertRole` 只管写，调用方还需要拿到
    /// 刚生成的 id 去选中它，所以这里直接返回成品。
    static func createRole(named name: String) -> VoiceChatRole {
        var role = VoiceChatRole.makeDefaultRole()
        role.id = VoiceChatRole.makeRoleID()
        role.name = name
        upsertRole(role)
        return role
    }

    /// 删除角色。**内置默认角色不可删**；删掉的如果是当前激活角色，
    /// 激活位回落到剩下的第一个 —— 留一个指向已删角色的 activeRoleID 会让
    /// 「当前角色」在界面上空白。
    static func deleteRole(withID roleID: String) {
        guard roleID != VoiceChatRole.defaultRoleID else { return }
        mutate { stored in
            let removedWasDefault = stored.roles.first(where: { $0.id == roleID })?.isDefault ?? false
            stored.roles.removeAll { $0.id == roleID }
            if stored.activeRoleID == roleID {
                stored.activeRoleID = stored.roles.first?.id
            }
            // 删掉的是默认角色：把默认位让给剩下的第一个，否则快捷键会没有目标。
            if removedWasDefault, let firstRemaining = stored.roles.first?.id {
                for index in stored.roles.indices {
                    stored.roles[index].isDefault = (stored.roles[index].id == firstRemaining)
                }
            }
        }
    }

    /// 唯一的写入漏斗：锁 → 改缓存 → 落盘 → 发通知。
    /// 把它做成唯一入口，文件和通知就不可能脱节（照 `AgentSessionStore.mutate`）。
    private static func mutate(_ change: (inout StoredVoiceChatRoles) -> Void) {
        rolesLock.lock()
        var stored = cachedRoles ?? loadFromDisk()
        change(&stored)
        cachedRoles = stored
        rolesLock.unlock()

        writeToDisk(stored)
        NotificationCenter.default.post(name: .wannaVoiceChatRolesDidChange, object: nil)
    }

    private static func loadFromDisk() -> StoredVoiceChatRoles {
        let fileURL = rolesFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoredVoiceChatRoles.self, from: data),
              !decoded.roles.isEmpty else {
            // 读不出来（首次运行 / 文件损坏）就回到默认角色，**绝不崩**。
            // 与 `AgentSessionStore.loadFromDisk` 同一条规矩。
            return StoredVoiceChatRoles(
                roles: [VoiceChatRole.makeDefaultRole()],
                activeRoleID: VoiceChatRole.defaultRoleID
            )
        }

        // 迁移：老文件里可能缺默认角色，或 activeRoleID 指向已经不存在的角色。
        var migrated = decoded
        if !migrated.roles.contains(where: { $0.id == VoiceChatRole.defaultRoleID }) {
            migrated.roles.insert(VoiceChatRole.makeDefaultRole(), at: 0)
        }
        if migrated.activeRoleID == nil
            || !migrated.roles.contains(where: { $0.id == migrated.activeRoleID }) {
            migrated.activeRoleID = migrated.roles.first?.id
        }
        return migrated
    }

    private static func writeToDisk(_ stored: StoredVoiceChatRoles) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let fileURL = rolesFileURL
        do {
            try data.write(to: fileURL, options: .atomic)
            // `.atomic` 落盘是 0644，而这份文件里有用户写给模型的角色设定，
            // 补一次 0600，与其它几个存储保持一致。
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            print("⚠️ VoiceChatRoleStore: 写入角色表失败 — \(error.localizedDescription)")
        }
    }
}
