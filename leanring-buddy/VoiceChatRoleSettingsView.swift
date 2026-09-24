import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// 「语音聊天 → 角色」的编辑界面。
///
/// 同一份视图有两个入口，用户 2026-09-24 两个都要：
/// 1. **语音聊天页右键角色卡片 → 编辑**：右侧的对话页面就地换成它（最直接的那个入口）；
/// 2. **设置 → 语音聊天 → 角色**：作为一个普通设置页。
///
/// 所以它自己不画窗口外框、不画底部按钮条，只负责两栏内容 —— 两个宿主各自提供
/// 标题与返回。这是本仓库里 `ModelSettingsView` 的同一种做法。
///
/// 每个角色可编辑的东西按用户列的那几项：**标题、备注、头像（本地上传或选图标）、
/// 提示词**，外加他另外要的**连续对话 / 全新对话**，以及「设为默认角色」。
struct VoiceChatRoleSettingsView: View {

    /// 编辑中的角色表 —— 直接读写存储，改一下存一下。
    ///
    /// 为什么不做「草稿 + 保存」：角色是**用户在会话中间会改**的东西（右键就能编辑），
    /// 而会话读的是存储里的当前值。这里如果做成草稿，用户改完提示词却忘了按保存，
    /// 下一次连接用的还是旧的 —— 那正是本仓库在设置页反复强调要避免的
    /// 「改了没反应」。字段少、且每个字段都是即时可见的，即时写入更不容易误解。
    @State private var roles: [VoiceChatRole] = []
    @State private var selectedRoleID: String?
    @State private var avatarErrorMessage: String?

    /// 草稿里有没有没保存的修改（用户 2026-09-24 的要求：改了参数**先点亮保存**，
    /// 用户点了才写盘 —— 不再改一下就自动落盘）。
    @State private var hasUnsavedChanges = false
    /// 刚被复制过的模型 id —— 复制按钮据此短暂打勾（用户要求「点击复制按钮就能自动复制」，
    /// 打勾是唯一的反馈）。
    @State private var copiedModelID: String?
    /// 设置页宿主把这个接进页头的保存按钮（那里也显示同一份脏标记）；
    /// 语音聊天页宿主不传（nil），视图自己在编辑栏底部画一颗保存。
    var hasUnsavedChangesBinding: Binding<Bool>? = nil
    /// 设置页宿主用：把「保存」这个动作注册上去，页头的保存按钮点它。
    var registerSaveAction: ((@escaping () -> Void) -> Void)? = nil

    /// 可选的图标。挑的都是「说话 / 人 / 职业」这一类，与语音对话对得上。
    /// 放在类型级而不是函数体里：ViewBuilder 里的局部 `let` 数组会让类型检查器
    /// 整个放弃（"failed to produce diagnostic"），提到这里就没有那个问题。
    private static let avatarSymbolChoices = [
        "person.wave.2", "person.fill", "bubble.left.and.bubble.right.fill",
        "globe.asia.australia.fill", "book.fill", "graduationcap.fill",
        "translate", "lightbulb.fill", "music.note", "airplane"
    ]

    var body: some View {
        HStack(spacing: 0) {
            roleListColumn
            Divider().overlay(DS.Colors.borderSubtle)
            editorColumn
        }
        .onAppear {
            reloadRoles()
            registerSaveAction? { saveRoleChanges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickyVoiceChatRolesDidChange)) { _ in
            reloadRoles()
        }
    }

    private func reloadRoles() {
        roles = VoiceChatRoleStore.allRoles()
        if selectedRoleID == nil || !roles.contains(where: { $0.id == selectedRoleID }) {
            selectedRoleID = roles.first?.id
        }
    }

    private var selectedRole: VoiceChatRole? {
        roles.first(where: { $0.id == selectedRoleID })
    }

    // MARK: - 左栏：角色列表

    private var roleListColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(roles) { role in
                        roleListRow(role)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            Divider().overlay(DS.Colors.borderSubtle)

            Button {
                let newRole = VoiceChatRoleStore.createRole(named: "新角色")
                reloadRoles()
                selectedRoleID = newRole.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("新建角色")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
        .frame(width: 168)
        .background(DS.Colors.surface3)
    }

    private func roleListRow(_ role: VoiceChatRole) -> some View {
        let isSelected = role.id == selectedRoleID

        return Button {
            selectedRoleID = role.id
        } label: {
            HStack(spacing: 8) {
                RoleAvatarView(role: role, size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(role.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if role.isDefault {
                        Text("默认")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.Colors.success)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface4 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    // MARK: - 右栏：单个角色的编辑

    @ViewBuilder
    private var editorColumn: some View {
        if let role = selectedRole {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    avatarSection(role)
                    fieldSection(title: "标题") {
                        TextField("角色名称", text: binding(role, \.name))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(8)
                            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    fieldSection(title: "备注", hint: "给自己看的，不会发给模型") {
                        TextField("比如：翻译用、讲解用", text: binding(role, \.note))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(8)
                            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    memoryModeSection(role)
                    promptSection(role)
                    // 用户 2026-09-25：聊天类型/模式/预设是**角色的属性**，
                    // 所以放在提示词下面（换角色 = 连聊天方式一起换）。
                    chatSection(role)
                    footerActions(role)

                    if hasUnsavedChanges {
                        Button {
                            saveRoleChanges()
                        } label: {
                            Text("保存修改")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(DS.Colors.textOnAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(DS.Colors.accent)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("把改过的参数写进磁盘")
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("左侧还没有角色")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fieldSection<Content: View>(title: String,
                                             hint: String? = nil,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
            content()
        }
    }

    // MARK: 头像

    @ViewBuilder
    private func avatarSection(_ role: VoiceChatRole) -> some View {
        fieldSection(title: "头像", hint: "选一个图标，或上传本地图片") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RoleAvatarView(role: role, size: 44)

                    Button("上传图片…") { pickAvatarImage(for: role) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.accent)
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }

                    if role.avatarImagePath != nil {
                        Button("用回图标") { update(role) { $0.avatarImagePath = nil } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                    }
                }

                HStack(spacing: 6) {
                    ForEach(Self.avatarSymbolChoices, id: \.self) { symbolName in
                        Button {
                            update(role) {
                                $0.avatarSymbolName = symbolName
                                // 选图标就表示放弃上传的那张，否则用户点了半天图标却没变化。
                                $0.avatarImagePath = nil
                            }
                        } label: {
                            Image(systemName: symbolName)
                                .font(.system(size: 12))
                                .foregroundStyle(avatarSymbolIsChosen(symbolName, for: role)
                                                 ? DS.Colors.accent : DS.Colors.textSecondary)
                                .frame(width: 26, height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(avatarSymbolIsChosen(symbolName, for: role)
                                              ? DS.Colors.surface4 : DS.Colors.surface2)
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                    }
                }

                if let avatarErrorMessage {
                    Text(avatarErrorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.destructive)
                }
            }
        }
    }

    /// 某个图标现在是不是这个角色的头像（上传的图片优先，所以有图片时一个都不选中）。
    private func avatarSymbolIsChosen(_ symbolName: String, for role: VoiceChatRole) -> Bool {
        role.avatarImagePath == nil && role.avatarSymbolName == symbolName
    }

    /// 选一张本地图片当头像。
    ///
    /// **复制进 Clicky 自己的目录**，而不是记原路径：用户随时可能移动或删掉原文件，
    /// 记路径的话头像会某天突然变成空白，而且没人知道为什么。
    private func pickAvatarImage(for role: VoiceChatRole) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let pickedURL = panel.url else { return }

        do {
            let avatarsDirectory = VoiceChatRoleStore.avatarsDirectoryURL
            try FileManager.default.createDirectory(at: avatarsDirectory, withIntermediateDirectories: true)

            let fileExtension = pickedURL.pathExtension.isEmpty ? "png" : pickedURL.pathExtension
            let destinationURL = avatarsDirectory.appendingPathComponent("\(role.id).\(fileExtension)")
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: pickedURL, to: destinationURL)

            update(role) { $0.avatarImagePath = destinationURL.path }
            avatarErrorMessage = nil
        } catch {
            avatarErrorMessage = "图片没能保存：\(error.localizedDescription)"
        }
    }

    // MARK: 记忆方式

    @ViewBuilder
    private func memoryModeSection(_ role: VoiceChatRole) -> some View {
        fieldSection(title: "记忆", hint: "下次连接生效") {
            HStack(spacing: 6) {
                memoryModeButton(role, mode: "continue", title: "连续对话",
                                 detail: "接着上次聊，历史保留")
                memoryModeButton(role, mode: "fresh", title: "全新对话",
                                 detail: "每次从零开始，不读也不写历史")
            }
        }
    }

    private func memoryModeButton(_ role: VoiceChatRole,
                                  mode: String,
                                  title: String,
                                  detail: String) -> some View {
        let isChosen = (role.chatMode == mode) || (mode == "continue" && role.chatMode != "fresh")

        return Button {
            update(role) { $0.chatMode = mode }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isChosen ? DS.Colors.accent : DS.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isChosen ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderSubtle,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    // MARK: 提示词

    @ViewBuilder
    private func promptSection(_ role: VoiceChatRole) -> some View {
        fieldSection(title: "提示词", hint: "作为系统提示词发给 AI") {
            TextEditor(text: binding(role, \.systemPrompt))
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(6)
                .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }

    // MARK: 聊天（类型 / 模式 / 预设）—— 绑在角色上

    /// **聊天方式是角色的属性**（用户 2026-09-25）：
    ///
    /// > 「语音聊天和视频聊天其实是绑定角色的，所以应该放在设置页面的角色里……
    /// > 比如用户使用口语教练、手语教练，学的是手语，手语需要视频，那所有预设都好了，
    /// > 视频聊天也就打开了。如果用户想训练英语，只需要语音聊天就可以。」
    ///
    /// 所以这一节放在**提示词下面**：选一个角色，就把它的聊天方式一起带过来。
    /// 三条都写进角色的草稿（`chatChannel` / `chatEngine` / `presetID`），
    /// 「保存修改」一次落盘 —— 与这一页其它字段同一条规矩。
    @ViewBuilder
    private func chatSection(_ role: VoiceChatRole) -> some View {
        let channel = VoiceChatChannel(rawValue: role.chatChannel ?? "") ?? .voice
        fieldSection(title: "聊天", hint: "跟着角色走 —— 换角色就把这一整套换过去") {
            VStack(alignment: .leading, spacing: 10) {
                // **默认模式**（用户 2026-09-25：「可以在红色框上方加一个默认模式，下面选择
                // 语音聊天，即默认模式为语音聊天。这样用户在打开 chatting 界面选择某个角色时，
                // 会自动应用该默认设置」）—— 它就是"打开 Chatting 时自动套上的那一套"，
                // 默认是**语音聊天 + 全双工 3.0 Flash**。
                VStack(alignment: .leading, spacing: 5) {
                    Text("默认模式")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text("打开 Chatting 选中这个角色时，自动套用这一套（默认：语音聊天 + 全双工 3.0 Flash）")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                    HStack(spacing: 6) {
                        ForEach(VoiceChatChannel.allCases) { option in
                            chatChoiceCard(
                                title: option.displayName,
                                detail: option == .video
                                    ? "能开屏幕和摄像头（模型要能吃画面）"
                                    : "只用声音，屏幕和摄像头置灰",
                                isChosen: channel == option
                            ) {
                                chooseChannel(role, channel: option)
                            }
                        }
                    }
                }

                ForEach(VoiceChatEngine.pickerCases, id: \.self) { engine in
                    chatModeBlock(role, engine: engine, channel: channel)
                }
            }
        }
    }

    /// 一个模式（全双工 / 三段式）在设置页里的样子：选中卡片 + 预设下拉 + 可复制的模型清单。
    @ViewBuilder
    private func chatModeBlock(
        _ role: VoiceChatRole,
        engine: VoiceChatEngine,
        channel: VoiceChatChannel
    ) -> some View {
        let presets = VoiceChatPresetStore.resolvedPresets(for: channel, engine: engine)
        let activePresetID = role.presetID.flatMap { id in presets.first { $0.id == id }?.id }
            ?? presets.first(where: \.isDefaultPreset)?.id
        let isChosen = (VoiceChatEngine(rawValue: role.chatEngine) ?? .threeStage) == engine
            || (engine == .duplexVoice && role.chatEngine == VoiceChatEngine.omni.rawValue)
        let activePreset = presets.first { $0.id == activePresetID }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                chatChoiceCard(
                    title: engine.displayName,
                    detail: engine == .duplexVoice
                        ? "一个模型包办识别/理解/表达"
                        : "识别、理解、表达各自可调",
                    isChosen: isChosen
                ) {
                    chooseMode(role, engine: engine, channel: channel)
                }

                // 预设下拉：每条预设 = 一组已验证的模型组合。
                if let activePreset {
                    Menu {
                        ForEach(presets) { preset in
                            Button {
                                chooseMode(role, engine: engine, channel: channel, preset: preset)
                            } label: {
                                Text(preset.isDefaultPreset
                                     ? "\(preset.title)（默认）"
                                     : preset.title)
                            }
                            .disabled(!preset.isReady)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(activePreset.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(activePreset.note)
                }
            }

            if let activePreset, !activePreset.note.isEmpty {
                Text(activePreset.note)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }

            modelInventoryDisclosure(engine: engine, channel: channel)
        }
        .padding(.leading, isChosen ? 0 : 2)
    }

    /// 可折叠的**模型清单**：展开后每个模型一行，右侧一个复制按钮
    /// （用户：「可以通过折叠按钮展开，点击复制按钮就能自动复制」）。
    @ViewBuilder
    private func modelInventoryDisclosure(engine: VoiceChatEngine, channel: VoiceChatChannel) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(VoiceCatalog.modelInventory(for: engine, channel: channel), id: \.category) { group in
                    Text(group.category)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .tracking(0.5)
                        .padding(.top, 4)
                    ForEach(group.choices) { choice in
                        modelInventoryRow(choice)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("可用的模型（点右侧复制完整 id）")
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.leading, 2)
    }

    private func modelInventoryRow(_ choice: VoiceCatalog.ModelChoice) -> some View {
        HStack(spacing: 6) {
            Text(choice.displayName)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: 150, alignment: .leading)
            Text(choice.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(choice.priceNote)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
            Button {
                copyModelID(choice.id)
            } label: {
                Image(systemName: copiedModelID == choice.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copiedModelID == choice.id ? DS.Colors.success : DS.Colors.textSecondary)
                    .frame(width: 24, height: 20)
                    .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("复制 \(choice.id)")
        }
    }

    /// 复制模型 id（给 AI 用 —— 它只认完整 id，不认短名）。
    private func copyModelID(_ modelID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelID, forType: .string)
        copiedModelID = modelID
    }

    /// 这一页通用的小卡片（选中态描蓝）。与「记忆」那一节同一个样式。
    private func chatChoiceCard(
        title: String,
        detail: String,
        isChosen: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isChosen ? DS.Colors.accent : DS.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isChosen ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderSubtle,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    /// 换聊天类型：类型变了，预设要重新落一条（预设是按 (类型, 模式) 分的）。
    private func chooseChannel(_ role: VoiceChatRole, channel: VoiceChatChannel) {
        update(role) { draft in
            draft.chatChannel = channel.rawValue
            let engine = VoiceChatEngine(rawValue: draft.chatEngine) ?? .threeStage
            let resolvedEngine: VoiceChatEngine = (engine == .omni) ? .duplexVoice : engine
            let presets = VoiceChatPresetStore.resolvedPresets(for: channel, engine: resolvedEngine)
            guard let preset = presets.first(where: \.isDefaultPreset) ?? presets.first else { return }
            draft = preset.applied(to: draft, channel: channel)
            draft.presetID = preset.id
        }
    }

    /// 选模式（可同时指定预设）：把预设的模型组合、音色、设备默认值写进**草稿**。
    private func chooseMode(
        _ role: VoiceChatRole,
        engine: VoiceChatEngine,
        channel: VoiceChatChannel,
        preset explicitPreset: VoiceChatPreset? = nil
    ) {
        update(role) { draft in
            let presets = VoiceChatPresetStore.resolvedPresets(for: channel, engine: engine)
            let preset = explicitPreset
                ?? presets.first(where: \.isDefaultPreset)
                ?? presets.first
            guard let preset else { return }
            draft.chatEngine = engine.rawValue
            draft.presetID = preset.id
            draft = preset.applied(to: draft, channel: channel)
        }
    }

    // MARK: 底部动作

    @ViewBuilder
    private func footerActions(_ role: VoiceChatRole) -> some View {
        HStack(spacing: 10) {
            defaultRoleControl(role)
            Spacer(minLength: 0)
            deleteRoleControl(role)
        }
    }

    /// 「设为默认角色」/「已是默认」。
    @ViewBuilder
    private func defaultRoleControl(_ role: VoiceChatRole) -> some View {
        if role.isDefault {
            Label("默认角色（快捷键用它）", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.success)
        } else {
            Button("设为默认角色") {
                VoiceChatRoleStore.setDefaultRole(id: role.id)
                reloadRoles()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.Colors.accent)
            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }

    /// 删除。内置的「默认角色」不可删：快捷键总要有个目标。
    @ViewBuilder
    private func deleteRoleControl(_ role: VoiceChatRole) -> some View {
        if role.id != VoiceChatRole.defaultRoleID {
            Button("删除角色") {
                VoiceChatRoleStore.deleteRole(withID: role.id)
                selectedRoleID = nil
                reloadRoles()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(DS.Colors.destructive)
            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }

    // MARK: - 草稿

    /// 字段级编辑只改**内存里的草稿**，落盘交给「保存」。
    ///
    /// 为什么推翻当初「刻意不做草稿」的决定：写透式让页头的保存按钮**永远是灭的**
    /// —— 它亮不了，因为没有「未保存」这个状态存在。用户 2026-09-24 明确要回
    /// 「改了 → 保存亮 → 点保存」这个交互。结构性的动作（新建 / 删除 / 设为默认）
    /// 仍然即时写盘：它们要马上拿到持久化的 id，而且语义是「操作」而不是「改参数」。
    private func update(_ role: VoiceChatRole, _ change: (inout VoiceChatRole) -> Void) {
        guard let index = roles.firstIndex(where: { $0.id == role.id }) else { return }
        change(&roles[index])
        hasUnsavedChanges = true
        hasUnsavedChangesBinding?.wrappedValue = true
    }

    /// 把草稿写进存储。逐个 upsert（同 id 覆盖），比 diff 一遍划算。
    private func saveRoleChanges() {
        for role in roles {
            VoiceChatRoleStore.upsertRole(role)
        }
        hasUnsavedChanges = false
        hasUnsavedChangesBinding?.wrappedValue = false
    }

    private func binding(_ role: VoiceChatRole,
                         _ keyPath: WritableKeyPath<VoiceChatRole, String>) -> Binding<String> {
        Binding(
            get: { role[keyPath: keyPath] },
            set: { newValue in update(role) { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - 头像

/// 角色头像：有上传的图片就用图片，否则用 SF Symbol。
///
/// 单独抽出来是因为它有三个使用点（侧栏卡片、设置页的角色行、设置页的大预览），
/// 三处必须长得一样 —— 否则用户会以为「我设的头像没生效」。
struct RoleAvatarView: View {
    let role: VoiceChatRole
    let size: CGFloat

    var body: some View {
        Group {
            if let avatarImagePath = role.avatarImagePath,
               let avatarImage = NSImage(contentsOfFile: avatarImagePath) {
                Image(nsImage: avatarImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: role.avatarSymbolName.isEmpty ? "person.fill" : role.avatarSymbolName)
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(DS.Colors.surface2)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
    }
}
