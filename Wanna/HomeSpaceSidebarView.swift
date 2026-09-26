//
//  HomeSpaceSidebarView.swift
//  Wanna
//
//  The notch sheet's session sidebar. Top to bottom: the 对话 / Agent / 语音聊天
//  switcher, a divider, one search field + round 「＋」 row shared by all three
//  sections, the section's list, and — pinned at the very bottom — the
//  「归档」 / 「设置」 pair.
//
//  Both ends of that order are the user's, and they were asked for in two steps
//  on 2026-09-23: first the account card and the bottom 归档 row were replaced
//  by one 归档/设置 row at the top, then that row was moved down here so the
//  top could carry the three section buttons above the divider ("分割线下面是
//  搜索和添加"). The sidebar therefore reads top-down as *which column am I in*
//  and bottom-up as *the whole app*.
//
//  The three sections read as one surface on purpose (the user's request):
//  same order from the top, same field, same rows, same margins.
//

import SwiftUI

struct HomeSpaceSidebarView: View {

    @ObservedObject var sessionsModel: ConversationSessionsModel
    @ObservedObject var agentSessionManager: AgentSessionManager
    /// The VoiceWeb subsystem — the 语音聊天 section's role-preset list reads
    /// its published presets and connection phase, and its rows select.
    @ObservedObject var voiceChatController: VoiceChatController
    @Binding var showsSettings: Bool

    /// 「录音」快捷入口：点一下直接跳到设置里的录音页。
    ///
    /// 用户 2026-09-25：「主页面设置按钮的右侧显示一个录音按钮，点击后自动跳转到
    /// 设置页面的录音位置，即设置一个快捷跳转按钮」。做成一��闭包而不是让侧栏
    /// 自己去改 `selectedSettingsPage` —— 那一页的状态住在上层，侧栏不该伸手进去。
    var openRecordingSettingsAction: () -> Void = {}
    /// 归档 takes the whole sheet over, the way 设置 does — see
    /// `NotchSheetRootView` — so this row only has to raise the flag.

    @State private var hoveringSessionID: UUID?
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""

    /// Renaming targets an agent instead of a conversation session — the two
    /// lists share one inline-rename interaction, so one id pair serves both.
    @State private var renamingAgentID: UUID?

    /// Search text for the two sections the store does not own a query for.
    /// The 对话 list's query lives on `ConversationSessionsModel` because its
    /// search also has to reach into entry text; these two are plain view state,
    /// which is all a name filter needs.
    @State private var agentSearchQuery: String = ""
    @State private var roleSearchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部是三个分区的切换器，紧跟一条分割线；分割线下面是搜索与
            // 「＋」，然后是列表，最底下才是「归档 / 设置」。
            //
            // 这个顺序是用户 2026-09-23 定的：「把对话、Agent、语音聊天这三个
            // 按钮放在左侧顶部这条分割线的上面，用按钮的形式显示。分割线下面
            // 是搜索和添加」「把左侧顶部的归档和设置按钮移动到左侧最下面」。
            // 读法因此从左到右、从上到下都成立 —— 上面选去哪一栏，下面管整个
            // 应用。
            sidebarSectionSwitcher

            Divider()
                .overlay(Color.white.opacity(0.08))

            // 三个分区共用同一行「搜索 + ＋」（用户要求三个页面顺序一致）。
            searchRow

            switch agentSessionManager.selectedSidebarSection {
            case .conversations:
                sessionList
            case .agents:
                agentList
            case .voiceChat:
                voiceChatRoleList
            }

            Spacer(minLength: 0)

            bottomActionRow
        }
        // 完全不透明（用户 2026-09-23：「整个弹出窗口调整为完全不透明，现在
        // 是透明状态」）。原来这里是 `Color.black.opacity(0.35)` 叠在面板地面
        // 上，合成出来正好是 surface3 的 #101014 —— 换成不透明的同一个色，
        // 侧栏观感不变，透出来的壁纸没了。
        .background(DS.Colors.surface3)
    }

    // MARK: - Section switcher

    /// 「对话 / Agent / 语音聊天」三选一——长方形圆角的按钮（用户定的样式），
    /// 三颗按钮平分整行。语音聊天是 VoiceWeb 的角色预设列表，与上面两个
    /// 列表一样是独立的半区。
    ///
    /// 2026-09-23 用户要求「把这三个按钮的高度调大一点，文字也大一点，让按钮
    /// 距离下边缘这条线的间距小一点……这样分割线位置不变，按钮也会变大」：
    /// 字号 12→13、按钮固定高 25→30，而下面那 5pt 的间距是从原来的 10pt 里
    /// **让出来的**——按钮长高的 5pt 正好等于间距少掉的 5pt，所以这一整块的总高
    /// 不变，底下那条分割线一动不动。按钮高度写死而不是靠 padding 撑，是因为
    /// 「总高不变」这件事必须由代码保证，不能靠每次调字号时心算。
    private var sidebarSectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(SidebarSection.allCases, id: \.self) { section in
                let isSelected = agentSessionManager.selectedSidebarSection == section
                // 用户 2026-09-25：「点击（左侧边栏的任何按钮）都发出声音：12」。
                Button(action: {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    agentSessionManager.selectedSidebarSection = section
                }) {
                    Text(section.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.sectionSwitcherButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        // 这一行现在顶在侧栏最上面，自己让开茎带（与刘海相接的那段黑带）。
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .padding(.bottom, Self.sectionSwitcherBottomPadding)
    }

    /// 30（原来 25）——用户要求的「按钮高度调大一点」。值本身在 `NotchSupport`
    /// 里：右列那条贯穿的横线要跟它算出来的分割线对齐，两处各存一份就一定会漂。
    private static var sectionSwitcherButtonHeight: CGFloat {
        NotchSupport.sidebarSectionSwitcherButtonHeight
    }
    /// 5（原来 10）——用户要求的「跟分割线的间距小一点」，正好把按钮长高的那
    /// 5pt 还回去，分割线因此不动。同样在 `NotchSupport` 里，理由同上。
    private static var sectionSwitcherBottomPadding: CGFloat {
        NotchSupport.sidebarSectionSwitcherBottomPadding
    }

    // MARK: - Pieces

    /// 搜索框占满剩余宽度，旁边是原版那颗独立的圆形「＋」。三个分区共用：
    /// 文案、过滤对象与「＋」的动作按当前分区取。
    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))

                TextField(searchFieldPlaceholder, text: searchQueryBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .disableAutocorrection(true)

                if !currentSearchQuery.isEmpty {
                    Button(action: { searchQueryBinding.wrappedValue = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )

            Button(action: primaryCreateAction) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(primaryCreateHelp)
        }
        .padding(.horizontal, 10)
        // 与上面那条分割线之间的间距——分割线不贴着输入框。
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// What the shared search field says. The placeholder names the thing being
    /// filtered, so one field reads correctly in all three sections.
    private var searchFieldPlaceholder: String {
        switch agentSessionManager.selectedSidebarSection {
        case .conversations: return "搜索对话"
        case .agents: return "搜索 Agent"
        case .voiceChat: return "搜索角色"
        }
    }

    /// The query the current section filters on. Read-only here; the writable
    /// form is `searchQueryBinding`.
    private var currentSearchQuery: String {
        switch agentSessionManager.selectedSidebarSection {
        case .conversations: return sessionsModel.searchQuery
        case .agents: return agentSearchQuery
        case .voiceChat: return roleSearchQuery
        }
    }

    /// The field's binding, routed to whichever query the current section uses.
    private var searchQueryBinding: Binding<String> {
        switch agentSessionManager.selectedSidebarSection {
        case .conversations: return $sessionsModel.searchQuery
        case .agents: return $agentSearchQuery
        case .voiceChat: return $roleSearchQuery
        }
    }

    /// What the 「＋」 does here. 对话 and Agent both make something new; the
    /// 语音聊天 roles come from VoiceWeb's own configuration and cannot be
    /// created by Wanna, so there the button re-reads the list instead — and
    /// its tooltip says so, rather than pretending to be a create button.
    private func primaryCreateAction() {
        switch agentSessionManager.selectedSidebarSection {
        case .conversations:
            sessionsModel.createSession()
        case .agents:
            createAgentWithFolderPicker()
        case .voiceChat:
            voiceChatController.refreshRolePresets()
        }
    }

    private var primaryCreateHelp: String {
        switch agentSessionManager.selectedSidebarSection {
        case .conversations: return "新建会话"
        case .agents: return "选一个项目文件夹，新建一个 Agent"
        case .voiceChat: return "角色由本地保存，可以新建和改提示词"
        }
    }

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sessionsModel.sidebarRows.enumerated()), id: \.element.session.id) { rowIndex, row in
                    sessionRow(row)
                    // 原版每行之间有一条发丝分隔线，与文字对齐、不压头像。
                    if rowIndex < sessionsModel.sidebarRows.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 66)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
    }

    private func sessionRow(_ row: ConversationSessionsModel.SessionRow) -> some View {
        let isSelected = row.session.id == sessionsModel.activeSessionID && !showsSettings

        return Button(action: {
            sessionsModel.selectSession(row.session.id)
            showsSettings = false
        }) {
            HStack(alignment: .center, spacing: 10) {
                // 原版用贴着侧栏左缘的小蓝点标记当前会话，选中行不再加底色。
                Circle()
                    .fill(Color(red: 0.25, green: 0.52, blue: 1.0))
                    .frame(width: 5, height: 5)
                    .opacity(isSelected ? 1 : 0)

                // 每个会话一只固定的角色脸——按 id 稳定领取的彩点头像
                MascotAvatarDisc(identity: MascotRoster.identity(forSessionID: row.session.id), diameter: 38)

                if row.session.id == renamingSessionID {
                    TextField("会话名", text: $renameDraft, onCommit: commitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            // 固定过的会话带一枚小图钉，否则用户看不出它是
                            // 因为什么排在最上面。
                            if row.session.pinnedAt != nil {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.35))
                            }

                            Text(row.session.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if hoveringSessionID == row.session.id {
                                Button(action: { sessionsModel.deleteSession(row.session.id) }) {
                                    Image(systemName: "archivebox")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .help("归档这个会话（可在「归档」里恢复）")
                            } else if row.searchPreview == nil && !row.session.entries.isEmpty {
                                Text(Self.relativeTime(row.session.updatedAt))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }

                        if let searchPreview = row.searchPreview {
                            Text(searchPreview)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        } else {
                            Text(row.session.entries.isEmpty
                                ? "还没有对话"
                                : Self.previewText(row.session))
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hoveringSessionID == row.session.id && row.session.id != renamingSessionID
                        ? Color.white.opacity(0.05)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            hoveringSessionID = hovering ? row.session.id : (hoveringSessionID == row.session.id ? nil : hoveringSessionID)
        }
        .contextMenu {
            Button(row.session.pinnedAt == nil ? "固定" : "取消固定") {
                sessionsModel.setPinned(row.session.pinnedAt == nil, forSessionID: row.session.id)
            }
            Button("重命名") {
                renamingSessionID = row.session.id
                renameDraft = row.session.title
            }
            // 删除是软删：这一条会移到「归档」，随时能恢复。
            Button("归档", role: .destructive) {
                sessionsModel.deleteSession(row.session.id)
            }
        }
    }

    private func commitRename() {
        if let renamingSessionID {
            sessionsModel.renameSession(renamingSessionID, to: renameDraft)
        }
        if let renamingAgentID {
            agentSessionManager.renameAgent(renamingAgentID, to: renameDraft)
        }
        renamingSessionID = nil
        renamingAgentID = nil
        renameDraft = ""
    }

    // MARK: - Agent list

    /// 三个分区共用的那一行「＋」负责新建 Agent（选文件夹），所以列表首行
    /// 不再重复放一颗。
    private var agentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filteredAgents.enumerated()), id: \.element.id) { rowIndex, agent in
                    agentRow(agent)
                    if rowIndex < filteredAgents.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
    }

    /// The Agent rows, filtered by the shared search field — name, project
    /// folder and last preview, so a folder name finds its agent too.
    private var filteredAgents: [AgentSession] {
        let trimmedQuery = agentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return agentSessionManager.sessions }
        return agentSessionManager.sessions.filter { agent in
            agent.name.localizedCaseInsensitiveContains(trimmedQuery)
                || agent.projectFolderPath.localizedCaseInsensitiveContains(trimmedQuery)
                || agent.lastPreview.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private func agentRow(_ agent: AgentSession) -> some View {
        let isSelected = agent.id == agentSessionManager.selectedAgentID
            && agentSessionManager.selectedSidebarSection == .agents
            && !showsSettings

        return Button(action: {
            agentSessionManager.selectAgent(agent.id)
            agentSessionManager.selectedSidebarSection = .agents
            showsSettings = false
        }) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(Color(red: 0.25, green: 0.52, blue: 1.0))
                    .frame(width: 5, height: 5)
                    .opacity(isSelected ? 1 : 0)

                // 状态点代替会话的角色头像——Agent 的信息是「它在不在跑」。
                Circle()
                    .fill(agentStatusColor(agent.status))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.black.opacity(0.55))
                    )

                if agent.id == renamingAgentID {
                    TextField("Agent 名", text: $renameDraft, onCommit: commitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(agent.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if hoveringSessionID == agent.id {
                                Button(action: { agentSessionManager.deleteAgent(agent.id) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .help("删除这个 Agent")
                            }
                        }

                        Text(agent.lastPreview.isEmpty
                            ? "还没有任务"
                            : agent.lastPreview)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hoveringSessionID == agent.id && agent.id != renamingAgentID
                        ? Color.white.opacity(0.05)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            hoveringSessionID = hovering ? agent.id : (hoveringSessionID == agent.id ? nil : hoveringSessionID)
        }
        .contextMenu {
            Button("重命名") {
                renamingAgentID = agent.id
                renameDraft = agent.name
            }
            Button("删除", role: .destructive) {
                agentSessionManager.deleteAgent(agent.id)
            }
        }
    }

    // MARK: - Voice chat role presets

    /// The 语音聊天 section's list: VoiceWeb's own role presets. Clicking a row
    /// only SELECTS it — the connection is started by the 连接 button in the
    /// content column, which is the single place a session can begin. That
    /// split is what stops the connection state from appearing to move between
    /// cards as the user clicks around (see the row's status line below).
    private var voiceChatRoleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if voiceChatController.rolePresets.isEmpty {
                    voiceChatEmptyHint
                } else if filteredRolePresets.isEmpty {
                    voiceChatNoMatchHint
                } else {
                    ForEach(Array(filteredRolePresets.enumerated()), id: \.element.id) { rowIndex, role in
                        voiceChatRoleRow(role)
                        if rowIndex < filteredRolePresets.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                                .padding(.leading, 46)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
        .onAppear {
            voiceChatController.refreshRolePresets()
            // 进入这个分区就开始预热（服务器 + Chrome + 页面），把用户选角色、
            // 把鼠标移到「连接」的那两三秒用掉 —— 等真正点连接时就没有可等的了。
            voiceChatController.prepareForConnect()
        }
    }

    /// The role rows, filtered by the shared search field.
    private var filteredRolePresets: [VoiceChatController.VoiceChatRolePreset] {
        let trimmedQuery = roleSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return voiceChatController.rolePresets }
        return voiceChatController.rolePresets.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private func voiceChatRoleRow(_ role: VoiceChatController.VoiceChatRolePreset) -> some View {
        let isSelected = role.id == voiceChatController.selectedRoleID
        let connectionPhase = voiceChatController.connectionPhase
        // 状态只属于真正在连/连上的那一个角色：`activeRoleID` 是 VoiceWeb
        // 真的在用的角色，`selectedRoleID` 只是用户点选的那一行。两者分开，
        // 连接状态就不可能跟着点击在卡片之间搬家。
        let isConnectedToThisRole = voiceChatController.activeRoleID == role.id
            && (connectionPhase == .connected || connectionPhase == .connecting)

        // 行分成两个**并列**的按钮，不是一个按钮套一个：左边整块只负责选中，
        // 右边那颗只负责连接/挂断。嵌套按钮在 SwiftUI 里点哪一颗都不确定，
        // 而这两件事必须互不干扰。
        return HStack(spacing: 6) {
            Button(action: {
                voiceChatController.selectRole(role.id)
                showsSettings = false
            }) {
                HStack(alignment: .center, spacing: 10) {
                    // 连上的角色亮绿点；只选中还没连的行亮蓝点——与
                    // 会话/Agent 列表同一个小点语言。
                    Circle()
                        .fill(isConnectedToThisRole
                            ? Color(red: 0.35, green: 0.85, blue: 0.55)
                            : Color(red: 0.25, green: 0.52, blue: 1.0))
                        .frame(width: 5, height: 5)
                        .opacity(isConnectedToThisRole || (!isConnectedToThisRole && isSelected) ? 1 : 0)

                    // 角色的头像（上传的图片优先，否则是它选的图标）。
                    RoleAvatarView(role: VoiceChatRoleStore.role(withID: role.id), size: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(roleStatusText(isConnectedToThisRole: isConnectedToThisRole, isSelected: isSelected))
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(isConnectedToThisRole ? 0.7 : 0.45))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            voiceChatRoleConnectButton(
                role,
                isConnectedToThisRole: isConnectedToThisRole,
                isConnecting: connectionPhase == .connecting
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.05) : Color.clear)
        )
        // 右键菜单 —— 用户 2026-09-24：「每一个左侧的卡片上都增加一个右键按钮，
        // 用来预设角色。右键卡片后有一个"编辑"按钮，点击编辑，右侧的对话页面就
        // 变成一个设置页面」。
        .contextMenu {
            Button("编辑") {
                voiceChatController.selectedRoleID = role.id
                voiceChatController.roleEditorInitialRoleID = role.id
                voiceChatController.isShowingRoleEditor = true
                showsSettings = false
            }

            let storedRole = VoiceChatRoleStore.role(withID: role.id)
            if storedRole.isDefault {
                Text("已是默认角色（快捷键用它）")
            } else {
                Button("设为默认角色") {
                    VoiceChatRoleStore.setDefaultRole(id: role.id)
                    voiceChatController.refreshRolePresets()
                }
            }

            Divider()

            Button("删除角色", role: .destructive) {
                VoiceChatRoleStore.deleteRole(withID: role.id)
                voiceChatController.refreshRolePresets()
            }
            .disabled(role.id == VoiceChatRole.defaultRoleID)
        }
    }

    /// The per-row 连接 / 挂断 button the user asked for on 2026-09-23:
    /// 「把连接按钮放在左侧边角色卡片的右侧部分，做成大一点的长方形圆角形式。
    /// 这样用户点击角色就可以选择是否连接，鼠标移动距离会非常小。不要放在右上角。」
    ///
    /// The mouse-travel argument is the whole point of it: the row is where the
    /// pointer already is when the user decides who to talk to, so the connect
    /// no longer needs a trip across the sheet to the content column's corner.
    /// Green before a session, red during one — the same two colours the notch
    /// wing's hang-up uses, so 「挂断」 looks the same wherever it is offered.
    private func voiceChatRoleConnectButton(
        _ role: VoiceChatController.VoiceChatRolePreset,
        isConnectedToThisRole: Bool,
        isConnecting: Bool
    ) -> some View {
        let tint: Color = isConnectedToThisRole
            ? Color(red: 1.0, green: 0.45, blue: 0.4)
            : Color(red: 0.35, green: 0.85, blue: 0.55)
        // 「取消」while the handshake is still running: the button tears down a
        // connection that has not finished being made, and calling that 挂断
        // would claim a conversation that never started.
        let title = isConnectedToThisRole ? (isConnecting ? "取消" : "挂断") : "连接"

        return Button {
            if isConnectedToThisRole {
                voiceChatController.disconnectCurrentSession()
            } else {
                voiceChatController.connectToRole(role.id)
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .lineLimit(1)
                // 固定尺寸，不是按文字撑开：三个文案（连接 / 挂断 / 取消）都是两个字，
                // 写死之后切换状态时按钮一动不动，左边的角色名也不会跟着抖。
                .frame(
                    width: Self.roleConnectButtonWidth,
                    height: Self.roleConnectButtonHeight
                )
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(tint.opacity(0.16))
                )
                // 一圈同色的边：这是整页里唯一一个"开始一件事"的按钮，纯色底在深色
                // 侧栏上还不够像可点的东西。
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .strokeBorder(tint.opacity(0.38), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isConnectedToThisRole
            ? "挂断「\(role.name)」"
            : "用「\(role.name)」开始语音聊天")
    }

    /// 连接 / 挂断按钮的尺寸。原先是 28 高、横向 12 内边距（宽度跟着文字走，约
    /// 48pt）。用户 2026-09-23 连着两次要求做大：「把连接按钮放在左侧边角色卡片的
    /// 右侧部分，做成大一点的长方形圆角形式…鼠标移动距离会非常小」，第二天又说
    /// 「把连接按钮做大。这样用户挂断时也能点击挂断按钮…连接按钮应该做大一点，方便
    /// 用户点击」。66×34 是侧栏 245pt 宽度下能给出的最大舒适值：再宽就要从角色名的
    /// 那一列里拿。
    private static let roleConnectButtonWidth: CGFloat = 66
    private static let roleConnectButtonHeight: CGFloat = 34

    /// What a role row says under its name. Four states, and only the first
    /// two mention a connection — the others describe selection, so a row the
    /// user has merely clicked never reads as connected or connecting.
    ///
    /// Short by design since 2026-09-23: the connect button moved into the row
    /// itself, so the status line no longer has to explain where that button
    /// is (it used to read 「已选中 · 点右上角连接」), and the row's name column
    /// lost the width that sentence needed.
    private func roleStatusText(isConnectedToThisRole: Bool, isSelected: Bool) -> String {
        guard isConnectedToThisRole else {
            return isSelected ? "已选中" : "点击选择"
        }
        return voiceChatController.connectionPhase == .connected ? "聊天中" : "连接中…"
    }

    /// Shown when the search field matches no role.
    private var voiceChatNoMatchHint: some View {
        Text("没有匹配的角色")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
    }

    /// Empty / unreachable states for the preset list — a hint, not a wall:
    /// the connect flow starts the server itself, so nothing here blocks.
    private var voiceChatEmptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.25))
            Text(voiceChatController.rolesErrorMessage ?? "正在读取角色…")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private func agentStatusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .idle: return Color.white.opacity(0.25)
        case .running: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .completed: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .failed: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .interrupted: return Color(red: 1.0, green: 0.75, blue: 0.35)
        }
    }

    /// Folder picker → `createAgent`. The app must activate first (an
    /// LSUIElement app's modal panels appear but never key otherwise — the
    /// same key-window trap the settings window has).
    private func createAgentWithFolderPicker() {
        NSApp.activate()

        let folderPicker = NSOpenPanel()
        folderPicker.canChooseDirectories = true
        folderPicker.canChooseFiles = false
        folderPicker.allowsMultipleSelection = false
        folderPicker.canCreateDirectories = true
        folderPicker.message = "选择 Agent 工作的项目文件夹"
        folderPicker.prompt = "新建 Agent"
        // Without this the picker opens BEHIND the expanded sheet: the notch
        // panel sits at `.mainMenu + 1` and an NSOpenPanel's default level is
        // `.modalPanel`, nine steps below it. See `modalFileDialogWindowLevel`.
        folderPicker.level = NotchSupport.modalFileDialogWindowLevel
        if let defaultFolderPath = AppSettingsStore.snapshot().agentDefaultProjectFolder {
            folderPicker.directoryURL = URL(fileURLWithPath: defaultFolderPath)
        }

        guard folderPicker.runModal() == .OK, let pickedURL = folderPicker.url else { return }
        agentSessionManager.createAgent(
            name: pickedURL.lastPathComponent,
            projectFolderPath: pickedURL.path
        )
    }

    /// 侧栏最底部一行：左「设置」右「归档」，两颗都是长方形按钮。2026-09-23
    /// 用户先要求「左侧顶部只显示归档和设置按钮：归档放左、设置放右、设置做
    /// 成长方形按钮，把用户名、本地模式、图标都删掉」——原本这里是一张账号卡
    /// （首字母圆盘 + 本机用户名 + 「本地模式」 + 一颗圆形齿轮），本机没有账号
    /// 服务支撑它；随后又要求「把左侧顶部的归档和设置按钮移动到左侧最下面」，
    /// 顶部让给了三个分区按钮。同一天稍后又要求两颗按钮对调位置
    /// （「把左侧边的设置按钮和归档按钮两个位置调换一下」），设置因此落在左边
    /// ——它正对着设置页里那颗同为长方形、同为 30pt 高的「返回」，两个入口在同一
    /// 条竖直线上，来回不跳。
    ///
    /// 顶上那条分隔线是随下移一起加的：这一行下面是 `Spacer`，列表短的时候
    /// 还好，长的时候最后一行会直接贴到按钮上，分不清哪是列表哪是操作。
    private var bottomActionRow: some View {
        HStack(spacing: 8) {
            NotchBarActionButton(
                title: "设置",
                systemImage: "gearshape",
                isHighlighted: showsSettings,
                help: "设置"
            ) {
                SoundEffectPlayer.shared.play(.sidebarButton)
                showsSettings = true
            }

            // 「录音」紧挨着设置右边 —— 一步跳到录音页，不用先进设置再找。
            NotchBarActionButton(
                title: "录音",
                systemImage: "record.circle",
                isHighlighted: showsSettings,
                help: "录音历史与设置"
            ) {
                SoundEffectPlayer.shared.play(.recordingEditorOpened)
                openRecordingSettingsAction()
            }

            Spacer(minLength: 8)

            // 「归档」**不在这里了**（用户 2026-09-24：「把窗口下面左侧边栏的
            // 「归档」按钮移动到设置页面，用户点击设置，在「导出导入」的下面添加
            // 一个按钮叫「归档」」）。它现在是 `SettingsPage.archive`，设置侧栏
            // 的「导入导出」组里那一行；整窗接管那条旧路连同 `showsArchive`
            // 一起删掉了 —— 侧栏这颗按钮是它唯一的入口，按钮没了它就成了死状态。
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Divider()
                .overlay(Color.white.opacity(0.08))
        }
    }

    // MARK: - Formatting

    /// 会话的第二行预览：取最近一条对话的开头（用户的话优先，读起来才
    /// 像原版的「我会读完四家中国发射…」）。internal 供归档页复用。
    static func previewText(_ session: ConversationSession) -> String {
        let lastEntry = session.entries.last
        let candidate = lastEntry?.userTranscript ?? lastEntry?.assistantResponse ?? ""
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 32 else { return trimmed.isEmpty ? "还没有对话" : trimmed }
        return String(trimmed.prefix(32)) + "…"
    }

    /// Relative time for a session's last update — the sidebar's second line.
    /// internal 供归档页复用。
    static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
