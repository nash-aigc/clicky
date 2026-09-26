//
//  CardChatPreferenceModel.swift
//  Wanna
//
//  「每张卡片的聊天模式与角色」的读写 + 「角色」那份清单的组装。
//  **一处实现，三个内容列共用**（主模型页 / Claude Code 页 / 语音视频页）。
//
//  纯数据（`CardChatMode` / `CardChatRoleChoice`）在 `CardChatMode.swift`，那边不碰任何
//  store —— 这样模式的默认值与映射可以脱离 App 编译、被探针直接验。
//
//  它是个 `shared` 单例，理由与 `AgentActivityBoard.shared` / `SoundEffectPlayer.shared`
//  一样：真相本来就在磁盘上的两个 store 里（`AppSettingsStore` / `VoiceChatRoleStore`），
//  这一层只是把它们读成视图要的形状；再往三个视图里各塞一份引用，只会多出三条可能分叉的路。
//

import Foundation
import Combine

@MainActor
final class CardChatPreferenceModel: ObservableObject {

    static let shared = CardChatPreferenceModel()

    /// 变更计数。设置本身住在磁盘上（不是 `@Published`），视图靠这个数重绘 ——
    /// 与 `VoiceChatSessionView` 里 `favouriteRevision` 同一个手法。
    @Published private(set) var revision: Int = 0

    /// 「管理角色…」要打开设置里的角色页 —— 而"怎么打开设置"只有 sheet 根知道
    ///（`showsSettings` / `selectedSettingsPage` 住在那里）。由 `NotchSheetRootView`
    /// 在出现时装进来：三个内容列共用同一条模式条，各自把这件事一路传下去只会多三处可能漏。
    var openRoleSettingsAction: (() -> Void)?

    /// 哪一个卡片的角色清单是展开的（nil = 都没开）。
    ///
    /// **展开状态放在这里而不是各页的 `@State`**：清单必须画在比那条页头带更大的范围里
    ///（不然它收不到点击 —— 实测：挂在模式条的 `.overlay` 上时，点击会**穿透**到下面
    /// 那一行预设按钮上，清单看着能点、其实点不动）。真正能接住的容器在 sheet 根那一层
    ///（右列那一整块），所以状态跟着上去了，清单也由那里画。
    @Published var openRoleListCardID: String?

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        // 设置变了（模式 / 角色选择）与角色表变了（新建 / 删除 / 改名）都要重绘：
        // 后者会让清单里的一项凭空出现或消失。
        for name in [Notification.Name.wannaAppSettingsChanged,
                     .wannaVoiceChatRolesDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.revision &+= 1 }
            })
        }
    }

    // MARK: - 模式

    func mode(forCardID cardID: String, kind: CardKind) -> CardChatMode {
        AppSettingsStore.snapshot().cardChatMode(forCardID: cardID, kind: kind)
    }

    func setMode(_ mode: CardChatMode, forCardID cardID: String) {
        // **一行日志，因为「模式改了没生效」唯一可核对的判据就是它**：哪张卡片、写成了
        // 什么、写完的表长什么样。2026-09-26 就是靠这一行抓到「写得进、读不出」那个
        // 解码 bug 的（只加 `CodingKeys` 忘了加 `init(from:)` 那两行）。
        print("🎛 [mode] card=\(cardID.prefix(8)) → \(mode.rawValue)")
        save(AppSettingsStore.snapshot().withCardChatMode(mode, forCardID: cardID),
             what: "聊天模式（\(mode.displayName)）")
    }

    // MARK: - 角色

    /// 这张卡片现在的角色清单。**清单随模式变**，这就是用户说的「角色列表变化」。
    func roleChoices(for mode: CardChatMode, kind: CardKind) -> [CardChatRoleChoice] {
        guard mode.isVoiceLike else {
            // 文本 / 图文：只有 Agent 自己那一个，置顶、不可改。
            return [Self.agentPresetChoice(for: kind)]
        }
        // **按 id 排除内置那条，不能只看 `isDefault`**：磁盘上那条内置角色的
        // `isDefault` 实测是 **false**（2026-09-26 的 `VoiceChatRoles.json`），所以只看那个
        // 标志会把它当成"用户自己设计的角色"列出来 —— 界面上就是一个叫「默认角色」、
        // 副标题却写着「你自己设计的角色」的行。id 才是它稳定的身份。
        let userRoles = VoiceChatRoleStore.allRoles().filter {
            $0.id != VoiceChatRole.defaultRoleID && !$0.isDefault
        }
        guard !userRoles.isEmpty else {
            // 一个都没建过 —— 用语音子系统那条内置默认角色兜底，否则这个模式没法跑
            //（没有角色 = 组装提示词的第二部分是空的，模型会被要求"作为某个角色"却
            // 不知道是哪个）。
            let builtIn = VoiceChatRoleStore.defaultRole()
            return [CardChatRoleChoice(id: builtIn.id,
                                       displayName: builtIn.displayName,
                                       promptText: builtIn.systemPrompt,
                                       source: .builtInVoiceRole)]
        }
        return userRoles.map {
            CardChatRoleChoice(id: $0.id,
                               displayName: $0.displayName,
                               promptText: $0.systemPrompt,
                               source: .userRole)
        }
    }

    /// 这张卡片当前选中的角色。**存的 id 失效时回落到清单第一个**（角色被删过）——
    /// 留一个指向已删角色的 id，这个模式就会拿着一份空提示词去说话。
    func resolvedRole(forCardID cardID: String, kind: CardKind, mode: CardChatMode) -> CardChatRoleChoice {
        let choices = roleChoices(for: mode, kind: kind)
        guard let storedID = AppSettingsStore.snapshot().cardVoiceRoleID(forCardID: cardID),
              let match = choices.first(where: { $0.id == storedID }) else {
            return choices[0]
        }
        return match
    }

    func setVoiceRoleID(_ roleID: String, forCardID cardID: String) {
        save(AppSettingsStore.snapshot().withCardVoiceRoleID(roleID, forCardID: cardID),
             what: "卡片角色")
    }

    /// Agent 自己那个「默认角色」。
    ///
    /// 主循环能读出真实正文（用户可在「对话与记忆 → 系统提示词」里改它，所以读的是
    /// **当下生效的那份**：改过就是改过的，没改过才是出厂那份）。Claude Code 的系统提示词
    /// 在它自己的 CLI 里、本 App 读不到 —— 那就如实留空，不假装有一段。
    private static func agentPresetChoice(for kind: CardKind) -> CardChatRoleChoice {
        switch kind {
        case .mainLoop:
            let settings = AppSettingsStore.snapshot()
            let editedPrompt = settings.customSystemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let promptText = (editedPrompt?.isEmpty == false ? editedPrompt : nil)
                ?? CompanionManager.defaultVoiceResponseSystemPrompt
            return CardChatRoleChoice(id: "agentPreset",
                                      displayName: "默认角色",
                                      promptText: promptText,
                                      source: .agentPreset)
        case .claudeCode, .review:
            return CardChatRoleChoice(id: "agentPreset",
                                      displayName: "默认角色",
                                      promptText: "",
                                      source: .agentPreset)
        }
    }

    // MARK: - 存

    /// 写失败（磁盘满 / 权限）只留一行日志、不让侧栏崩 —— 与 `AgentCardModel.setDefault`
    /// 同一条口径：这是用户刚点下的选择，写不进去要说出来，但不该把界面搞崩。
    private func save(_ settings: AppSettings, what: String) {
        do {
            try AppSettingsStore.save(settings)
        } catch {
            print("⚠️ Wanna: 记不住\(what) —— \(error)")
        }
    }
}
