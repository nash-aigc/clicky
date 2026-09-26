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
    /// The 语音聊天 subsystem — that section's role-preset list reads
    /// its published presets and connection phase, and its rows select.
    @ObservedObject var voiceChatController: VoiceChatController
    @Binding var showsSettings: Bool

    /// **分阶段加载：列表是否已经可以进场。**
    ///
    /// `false` 时这一列只画骨架（切换器、搜索行、底部按钮），三个列表一律不建。
    /// 列表是随会话数 / Agent 数增长的那部分，而一次展开的主线程时间几乎全在
    /// SwiftUI 对整个面板树反复布局上——把它挡在面板出现之后，面板就是秒开的。
    /// 见 `NotchPanelModel.isSheetContentReady`。
    var showsSectionList: Bool = true

    /// 任务区里展开了哪几个「文件夹」（一个目标派的多个 agent）。**纯界面的状态** ——
    /// 和看板无关：关掉侧栏就该忘掉。
    @State private var expandedTaskGroups: Set<String> = []
    /// 状态点呼吸的相位。**整区共用一个** —— 每颗点各起一条动画会各自飘，看起来像坏了。
    @State private var isTaskDotBreathing = false

    /// **卡片区**（2026-09-26 新设计）：卡片 = Agent 主体，任务按状态四栏。
    /// 它自己订阅四份数据源的通知并重算整棵树 —— 见 `AgentCardModel`。
    @StateObject private var cardModel = AgentCardModel()

    /// 哪些「卡片 # 栏」是展开的（纯界面状态，不进任何模型）。
    @State private var expandedTaskColumns: Set<String> = []

    /// 「历史归档」那一行：归档页面住在设置里（`SettingsPage.archive`），
    /// 所以这里只需要把设置打开并落到那一页 —— 与 `openRecordingSettingsAction`
    /// 同一个形状（闭包而不是让侧栏自己去改上层状态）。
    var openArchiveAction: () -> Void = {}

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
            // **顶部 = 卡片区**（2026-09-26 用户重新设计）。
            //
            // 原来的「对话 / Agent / 语音聊天」三按钮切换器没有了：用户要的是
            // 「顶部：卡片列表，显示当前正在使用的卡片（主循环卡片）」，而卡片
            // 底下按**任务状态**分四栏（进行中 / 任务完成 / 任务失败 / 历史任务）。
            // 卡片 = 一个 Agent 主体（见 `AgentCardModel` 与 `CardKind`），所以
            // 「对话」和「Agent」两个分区被它一并取代；「语音聊天」是角色列表、
            // 不是任务，所以它退成底部的「角色」那一行。
            cardArea

            Spacer(minLength: 0)

            // 分割线下方 = 「历史归档」与「角色」两条去别处的路。
            diversionRows

            bottomActionRow
        }
        // 完全不透明（用户 2026-09-23：「整个弹出窗口调整为完全不透明，现在
        // 是透明状态」）。原来这里是 `Color.black.opacity(0.35)` 叠在面板地面
        // 上，合成出来正好是 surface3 的 #101014 —— 换成不透明的同一个色，
        // 侧栏观感不变，透出来的壁纸没了。
        .background(DS.Colors.surface3)
    }

    // MARK: - 卡片区（2026-09-26）

    /// 搜索框 + 卡片列表。搜索接到 `cardModel.searchQuery`（卡片标题或它的任务命中）。
    private var cardArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardSearchRow

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(cardModel.cards) { card in
                        cardRow(card)
                        // 四栏固定序（`TaskColumn.allCases` = 进行中 → 完成 → 失败 → 历史），
                        // 空的栏不画 —— 用户要的是「按状态」，不是四行空标题。
                        ForEach(TaskColumn.allCases, id: \.self) { column in
                            let tasks = card.tasks(in: column)
                            if !tasks.isEmpty {
                                taskColumnSection(card: card, column: column, tasks: tasks)
                            }
                        }
                    }

                    if cardModel.cards.isEmpty {
                        Text(cardModel.searchQuery.isEmpty ? "还没有卡片" : "没有匹配的卡片")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// 卡片区的搜索 + 「＋」（＋ = 新建主对话；用户要求「点击新建时，之前的对话
    /// 自动归档，左侧列表保持干净」—— 归档那一步在 `createSession` 里）。
    private var cardSearchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                TextField("搜索卡片或任务", text: $cardModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )

            Button(action: {
                SoundEffectPlayer.shared.play(.sidebarButton)
                sessionsModel.createSession()
                agentSessionManager.selectedSidebarSection = .conversations
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("新建主对话（当前这条会自动归档）")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 一张卡片：标题 + 状态点 +（仅主循环卡片）「设为默认」。
    private func cardRow(_ card: AgentCardModel.Card) -> some View {
        let isCurrentCard = isCurrent(card)
        return HStack(spacing: 8) {
            Circle()
                .fill(card.kind == .mainLoop ? DS.Colors.accent : Color(red: 0.55, green: 0.78, blue: 0.55))
                .frame(width: 6, height: 6)
                .opacity(isCurrentCard ? 1 : 0.35)

            Text(card.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            if card.kind == .claudeCode {
                Text("Claude Code")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            Spacer(minLength: 4)

            // **「设为默认」只出现在主循环卡片上。** 用户明确要求「新建的 Claude Code
            // 类型卡片不可设为默认」—— 兜底那条线不是「我的主对话」。
            if card.kind == .mainLoop {
                Button(action: {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    cardModel.setDefault(cardID: card.entityID)
                }) {
                    Image(systemName: card.isDefault ? "star.fill" : "star")
                        .font(.system(size: 10.5))
                        .foregroundColor(card.isDefault
                                         ? DS.Colors.success
                                         : .white.opacity(0.40))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(card.isDefault ? 0.10 : 0.05)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(card.isDefault
                      ? "这条是默认主对话：屏幕快捷键发出去的问题进它"
                      : "设为默认：屏幕快捷键发出去的问题进这一条主对话")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            SoundEffectPlayer.shared.play(.notchRevealed)
            cardModel.open(card, sessionsModel: sessionsModel, agentSessionManager: agentSessionManager)
        }
    }

    /// 当前的卡片：主循环看「是不是当前活动会话」，Claude Code 看「是不是选中的代理」。
    private func isCurrent(_ card: AgentCardModel.Card) -> Bool {
        switch card.kind {
        case .mainLoop:
            return sessionsModel.activeSessionID?.uuidString == card.entityID
        case .claudeCode:
            return agentSessionManager.selectedAgentID?.uuidString == card.entityID
        }
    }

    /// 一栏任务：可折叠的标题（栏名 + 条数），展开后逐条列出。
    @ViewBuilder
    private func taskColumnSection(card: AgentCardModel.Card,
                                   column: TaskColumn,
                                   tasks: [AgentCardModel.CardTask]) -> some View {
        let expansionKey = "\(card.id)#\(column.rawValue)"
        let isExpanded = expandedTaskColumns.contains(expansionKey)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                SoundEffectPlayer.shared.play(.sidebarButton)
                if isExpanded { expandedTaskColumns.remove(expansionKey) }
                else { expandedTaskColumns.insert(expansionKey) }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: 10)
                    Text(column.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                    Text("\(tasks.count)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(.white.opacity(0.35))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                ForEach(tasks) { task in
                    cardTaskRow(task)
                }
            }
        }
    }

    /// 一条任务。**兜底过来的带一枚标记** —— 用户要靠它一眼看出「这条是我的 Agent
    /// 做不了、被交出去的」，而复盘看的正是这些。
    private func cardTaskRow(_ task: AgentCardModel.CardTask) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(task.status))
                .frame(width: 5, height: 5)

            Text(task.title)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(1)

            if task.wasHandedOff {
                Text("兜底 · Claude Code")
                    .font(.system(size: 9))
                    .foregroundColor(Color(red: 0.62, green: 0.80, blue: 0.62))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(red: 0.30, green: 0.55, blue: 0.36).opacity(0.25)))
            }

            Spacer(minLength: 4)

            Text(task.relativeTimeText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.white.opacity(0.30))
        }
        .padding(.leading, 34)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
    }

    private func statusColor(_ status: EphemeralAgent.Status) -> Color {
        switch status {
        case .running: return DS.Colors.accent
        case .doneVerified: return DS.Colors.success
        case .doneUnverified: return Color(red: 0.95, green: 0.78, blue: 0.35)
        case .failed: return Color(red: 0.95, green: 0.45, blue: 0.42)
        }
    }

    /// 分割线下方那两条：历史归档、角色。
    private var diversionRows: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.08))

            // **「历史归档」回到侧栏了。** 它 2026-09-24 曾被用户要求搬进设置
            //（「把窗口下面左侧边栏的『归档』按钮移动到设置页面」），2026-09-26 他又
            // 要求侧栏里「分割线下方为历史归档」。两者不冲突：入口在这儿，页面还是
            // 设置里的那一页（`SettingsPage.archive`）—— 所以这里只切设置页，
            // 不复活当年删掉的整窗接管那套。
            NotchBarActionButton(
                title: "历史归档",
                systemImage: "archivebox",
                isHighlighted: false,
                help: "以前的主对话与它们的任务"
            ) {
                SoundEffectPlayer.shared.play(.notchRevealed)
                openArchiveAction()
            }

            NotchBarActionButton(
                title: "角色",
                systemImage: "person.crop.circle",
                isHighlighted: false,
                help: "语音 / 视频聊天用的角色预设"
            ) {
                SoundEffectPlayer.shared.play(.notchRevealed)
                showsSettings = false
                agentSessionManager.selectedSidebarSection = .voiceChat
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: - Section switcher


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







    // MARK: - 任务（挂在主会话下面）

    /// 一个主会话下面的分组（用户画的图：主会话 → 分组 → 子任务，两级都能折叠）。
    ///
    /// 分组的键是 `groupID`（一轮派出去的活共用一个 ✓），所以"同一个目标派了三个 agent"
    /// 会折成一个文件夹 ✓；组行本身可以折叠，展开后才列子任务 ✓。
    /// 状态图标。**跑着的那一个会转**（参考图里是 ↻）—— 用一个 Bool 驱动
    /// `repeatForever` 的线性旋转，和状态点的呼吸同一套做法（整区共用一个相位）。
    @ViewBuilder
    private func taskStatusGlyph(_ status: EphemeralAgent.Status) -> some View {
        // **用户给的规格**（2026-09-26，逐字）：「最左边是任务状态…完成的话就是对勾的形式，
        // 没有完成的话就是一个转圈的形式」，而且「应该是个圆环，绿色圆环里边加一个对勾」
        // —— 是**空心圆环 + 对勾**，不是我原来那种实心圆点 ✗。
        switch status {
        case .doneVerified:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.success)
        case .doneUnverified:
            // 做完了但没人回读确认过 —— 同样是圆环+对勾，用琥珀色把差别说出来。
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
        case .failed:
            // **失败不是"没完成"里的转圈** —— 它已经停了，转圈会让人以为还在跑 ✗。
            // 红圆环 + 叉，而右侧的时间照常显示（用户：「主要是用在任务失败…让用户来看」）。
            Image(systemName: "xmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.destructive)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .rotationEffect(.degrees(isTaskDotBreathing ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false),
                           value: isTaskDotBreathing)
        }
    }

    /// 状态点。**跑着和失败会呼吸**（用户：「失败或者没有完成，应该有一个呼吸的效果，
    /// 或者通过颜色变化，让用户能够知道」）；做完的两种是静态的。
    @ViewBuilder
    private func taskStatusDot(_ status: EphemeralAgent.Status, size: CGFloat) -> some View {
        let isUnsettled = status == .running || status == .failed
        Circle()
            .fill(taskStatusColor(status))
            .frame(width: size, height: size)
            .opacity(isUnsettled && isTaskDotBreathing ? 0.45 : 1)
            .animation(isUnsettled ? .easeInOut(duration: 0.9) : .default, value: isTaskDotBreathing)
    }

    private func taskStatusColor(_ status: EphemeralAgent.Status) -> Color {
        switch status {
        case .running: return DS.Colors.accent
        case .doneVerified: return DS.Colors.success
        case .doneUnverified: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
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


    // MARK: - Voice chat role presets


    /// The role rows, filtered by the shared search field.
    private var filteredRolePresets: [VoiceChatController.VoiceChatRolePreset] {
        let trimmedQuery = roleSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return voiceChatController.rolePresets }
        return voiceChatController.rolePresets.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }



    /// 连接 / 挂断按钮的尺寸。原先是 28 高、横向 12 内边距（宽度跟着文字走，约
    /// 48pt）。用户 2026-09-23 连着两次要求做大：「把连接按钮放在左侧边角色卡片的
    /// 右侧部分，做成大一点的长方形圆角形式…鼠标移动距离会非常小」，第二天又说
    /// 「把连接按钮做大。这样用户挂断时也能点击挂断按钮…连接按钮应该做大一点，方便
    /// 用户点击」。66×34 是侧栏 245pt 宽度下能给出的最大舒适值：再宽就要从角色名的
    /// 那一列里拿。
    private static let roleConnectButtonWidth: CGFloat = 66
    private static let roleConnectButtonHeight: CGFloat = 34


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
    /// 像「我会读完四家中国发射…」这样的半句话）。internal 供归档页复用。
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

// MARK: - 折叠后的侧栏（一条只有图标的窄栏）

/// 侧栏收起之后的那一条：**从上到下是当前页标识 → 带圆环的头像列表 → 设置**，
/// 其余全部不画。用户 2026-09-26 定的顺序就是这三样：
/// 「点击后把整个左侧边栏收起来，只留一个圆形头像/图标，并且高亮当前激活的
/// 会话」「左侧边栏内容从上到下：当前页面标识（Screen / Agent / Call 三选一）→
/// 图标列表，每一项带圆环颜色的头像 → 最下方是「设置」，其余内容隐藏」。
///
/// **它和展开态的 `HomeSpaceSidebarView` 是两个视图，不是同一个视图的两档宽度。**
/// 245pt 里那套东西（三个分区按钮、搜索框、两行文字的行、录音按钮）在 62pt 里一个
/// 都放不下，硬压只会得到一堆被挤扁的控件。但**头像与选中语义仍然是同一套**：
/// 会话用 `MascotAvatarDisc`、角色用 `RoleAvatarView`、Agent 用它的状态色，
/// 圆环高亮的就是当前那一个 —— 所以折叠前后用户看到的是同一个头像、同一条会话。
struct HomeSpaceSidebarRailView: View {

    @ObservedObject var sessionsModel: ConversationSessionsModel
    @ObservedObject var agentSessionManager: AgentSessionManager
    @ObservedObject var voiceChatController: VoiceChatController
    @Binding var showsSettings: Bool

    /// 这一条的总宽。38 的圆环 + 两侧各 12 的呼吸位。
    static let width: CGFloat = 62
    /// 圆环的直径，以及环里那颗头像的直径 —— 环比头像大出来的那 3pt 就是圆环本身。
    private static let ringDiameter: CGFloat = 38
    private static let avatarDiameter: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            currentSectionBadge

            ScrollView {
                VStack(spacing: 6) {
                    switch agentSessionManager.selectedSidebarSection {
                    case .conversations:
                        sessionItems
                    case .agents:
                        agentItems
                    case .voiceChat:
                        roleItems
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            settingsButton
        }
        .frame(width: Self.width)
        .background(DS.Colors.surface3)
    }

    // MARK: 当前页标识

    /// 「我现在在哪一页」——Screen / Agent / Call 三选一，只显示当前那一个。
    ///
    /// 这一个是**标识，不是按钮**：收起之后切页要先把侧栏放出来（或者点开设置里的
    /// 内容），一条 62pt 的窄栏里放三颗按钮每颗只剩 20pt，谁也点不准。所以它只回答
    /// 「在哪」，不带动作，也就不会有「看着能点、点了没反应」那种控件。
    private var currentSectionBadge: some View {
        VStack(spacing: 3) {
            Image(systemName: Self.symbol(for: agentSessionManager.selectedSidebarSection))
                .font(.system(size: 13, weight: .medium))

            Text(agentSessionManager.selectedSidebarSection.displayName)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .padding(.horizontal, 10)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .padding(.bottom, 8)
    }

    /// 分区 → 那一页的脸。三个都挑和内容对得上的：Screen 是看屏幕的对话，
    /// Agent 是锤子（与 Agent 行里那颗同一个符号），Call 是声波
    ///（与角色列表空态那颗 `waveform.circle` 同一族）。
    private static func symbol(for section: SidebarSection) -> String {
        switch section {
        case .conversations: return "display"
        case .agents: return "hammer.fill"
        case .voiceChat: return "waveform"
        }
    }

    // MARK: 三个分区的头像列表

    private var sessionItems: some View {
        ForEach(sessionsModel.sidebarRows, id: \.session.id) { row in
            let identity = MascotRoster.identity(forSessionID: row.session.id)
            railItem(
                isActive: row.session.id == sessionsModel.activeSessionID && !showsSettings,
                tint: Color(identity.pastelBackground),
                help: row.session.title
            ) {
                MascotAvatarDisc(identity: identity, diameter: Self.avatarDiameter)
            } action: {
                SoundEffectPlayer.shared.play(.sidebarButton)
                sessionsModel.selectSession(row.session.id)
                showsSettings = false
            }
        }
    }

    private var agentItems: some View {
        ForEach(agentSessionManager.sessions) { agent in
            railItem(
                isActive: agent.id == agentSessionManager.selectedAgentID
                    && agentSessionManager.selectedSidebarSection == .agents
                    && !showsSettings,
                tint: agentStatusTint(for: agent.status),
                help: agent.name
            ) {
                // 和展开态那一行同一颗状态盘：Agent 的信息是「它在不在跑」。
                Circle()
                    .fill(agentStatusTint(for: agent.status))
                    .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
                    .overlay(
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.black.opacity(0.55))
                    )
            } action: {
                SoundEffectPlayer.shared.play(.sidebarButton)
                agentSessionManager.selectAgent(agent.id)
                agentSessionManager.selectedSidebarSection = .agents
                showsSettings = false
            }
        }
    }

    private var roleItems: some View {
        // 收起后没有搜索框，所以这一列是全部角色（展开态那一列按搜索词过滤）。
        ForEach(voiceChatController.rolePresets) { role in
            railItem(
                isActive: role.id == voiceChatController.selectedRoleID && !showsSettings,
                tint: DS.Colors.accent,
                help: role.name
            ) {
                RoleAvatarView(role: VoiceChatRoleStore.role(withID: role.id), size: Self.avatarDiameter)
            } action: {
                SoundEffectPlayer.shared.play(.sidebarButton)
                voiceChatController.selectRole(role.id)
                showsSettings = false
            }
        }
    }

    /// 一颗头像 + 一圈环。
    ///
    /// 环的颜色是**这一项自己的颜色**（会话是它那份粉彩、Agent 是状态色、角色是
    /// accent），亮到 1.0、粗一档的那一颗就是当前激活的会话 —— 用户要的「每一项带
    /// 圆环颜色的头像，并且高亮当前激活的会话」用同一圈环的两种状态说完，不用再加
    /// 一个小蓝点：38pt 的宽度里放不下第二套标记。
    ///
    /// 两档的差别**三个量一起变**（环的透明度 0.3 → 1.0、粗细 1.5 → 2.5、头像本身
    /// 0.65 → 1.0）。只拉开透明度是不够的：这几个粉彩本来就接近白（#D7E5FF 这一族），
    /// 0.45 的浅色环在深底上仍然是浅色环，第一版实测下来哪一个是当前会话根本看不出来。
    private func railItem<Avatar: View>(
        isActive: Bool,
        tint: Color,
        help: String,
        @ViewBuilder avatar: () -> Avatar,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(isActive ? 1.0 : 0.3),
                                  lineWidth: isActive ? 2.5 : 1.5)
                avatar()
                    .opacity(isActive ? 1 : 0.65)
            }
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    // MARK: 设置

    /// 最底下只有「设置」一颗 —— 收起态里没有归档、没有录音、没有搜索框，
    /// 用户要的就是「其余内容隐藏」。它和展开态那颗同形（`NotchBarActionButton`
    /// 的纯图标形态），所以两态之间来回点不会换一只手感。
    private var settingsButton: some View {
        NotchBarActionButton(
            systemImage: "gearshape",
            isHighlighted: showsSettings,
            help: "设置"
        ) {
            SoundEffectPlayer.shared.play(.sidebarButton)
            showsSettings = true
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Divider()
                .overlay(Color.white.opacity(0.08))
        }
    }
}

/// Agent 状态色。侧栏那一行和折叠后的图标栏共用这一份 —— 同一个 Agent 在两处
/// 必须是同一个颜色，各写一遍就会漂（而且不报错，只是看着像两个不同的状态）。
private func agentStatusTint(for status: AgentSessionStatus) -> Color {
    switch status {
    case .idle: return Color.white.opacity(0.25)
    case .running: return Color(red: 0.35, green: 0.85, blue: 0.55)
    case .completed: return Color(red: 0.35, green: 0.6, blue: 1.0)
    case .failed: return Color(red: 1.0, green: 0.45, blue: 0.4)
    case .interrupted: return Color(red: 1.0, green: 0.75, blue: 0.35)
    }
}
