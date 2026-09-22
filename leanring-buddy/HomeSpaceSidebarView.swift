//
//  HomeSpaceSidebarView.swift
//  leanring-buddy
//
//  The notch sheet's session sidebar: the account section at the very top
//  (initial-letter disc, account name, status line, gear into the settings —
//  moved up from the bottom on the user's request so it is always one click
//  away; the old top-left waveform logo was deleted with the move), then a
//  search field beside a round new-session button, then the session list
//  (pastel avatar, title + relative time, preview line, hairline separators,
//  a blue dot marking the active session).
//

import SwiftUI

struct HomeSpaceSidebarView: View {

    @ObservedObject var sessionsModel: ConversationSessionsModel
    @ObservedObject var agentSessionManager: AgentSessionManager
    @Binding var showsSettings: Bool

    @State private var hoveringSessionID: UUID?
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""

    /// Renaming targets an agent instead of a conversation session — the two
    /// lists share one inline-rename interaction, so one id pair serves both.
    @State private var renamingAgentID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 账户区在最顶部（用户的要求）：应用没有标题可显示，原左上角
            // 的波形 logo 已删——账户行自己带上茎带高度，就是侧栏第一行；
            // 设置齿轮在行右侧，同样在最顶部。
            accountSection
            sidebarSectionSwitcher

            switch agentSessionManager.selectedSidebarSection {
            case .conversations:
                searchRow
                sessionList
            case .agents:
                agentList
            }
            Spacer(minLength: 0)
        }
        .background(Color.black.opacity(0.35))
    }

    // MARK: - Section switcher

    /// 「对话 / Agent」二选一的小切换器——Agent 是独立于会话的一套列表
    /// （用户定的取舍：侧栏加 Agent 区，不走对话自动升级）。
    private var sidebarSectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(SidebarSection.allCases, id: \.self) { section in
                let isSelected = agentSessionManager.selectedSidebarSection == section
                Button(action: { agentSessionManager.selectedSidebarSection = section }) {
                    Text(section.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Pieces

    /// 搜索框占满剩余宽度，旁边是原版那颗独立的圆形「＋」。
    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))

                TextField("搜索对话", text: $sessionsModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .disableAutocorrection(true)

                if sessionsModel.isSearching {
                    Button(action: { sessionsModel.searchQuery = "" }) {
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

            Button(action: { sessionsModel.createSession() }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("新建会话")
        }
        .padding(.horizontal, 16)
        // 与账户区分隔线之间的间距——原来这里没有，分隔线贴着搜索框。
        .padding(.top, 8)
        .padding(.bottom, 10)
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
            .padding(.horizontal, 10)
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

                // 每个会话一只固定的角色脸——HeyClicky 会话网格的彩点头像
                MascotAvatarDisc(identity: MascotRoster.identity(forSessionID: row.session.id), diameter: 38)

                if row.session.id == renamingSessionID {
                    TextField("会话名", text: $renameDraft, onCommit: commitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(row.session.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if hoveringSessionID == row.session.id {
                                Button(action: { sessionsModel.deleteSession(row.session.id) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .help("删除这个会话")
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
            Button("重命名") {
                renamingSessionID = row.session.id
                renameDraft = row.session.title
            }
            Button("删除", role: .destructive) {
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

    private var agentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                newAgentRow

                ForEach(Array(agentSessionManager.sessions.enumerated()), id: \.element.id) { rowIndex, agent in
                    agentRow(agent)
                    if rowIndex < agentSessionManager.sessions.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
    }

    /// The 「＋ 新建 Agent」 row: opens the folder picker, and the picked
    /// folder becomes the new agent's working directory.
    private var newAgentRow: some View {
        Button(action: createAgentWithFolderPicker) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 5, height: 5)

                Image(systemName: "plus.circle")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 38, height: 38)

                Text("新建 Agent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("选一个项目文件夹，新建一个 Agent")
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
        if let defaultFolderPath = AppSettingsStore.snapshot().agentDefaultProjectFolder {
            folderPicker.directoryURL = URL(fileURLWithPath: defaultFolderPath)
        }

        guard folderPicker.runModal() == .OK, let pickedURL = folderPicker.url else { return }
        agentSessionManager.createAgent(
            name: pickedURL.lastPathComponent,
            projectFolderPath: pickedURL.path
        )
    }

    /// 顶部账户区：首字母头像 + 账户名 + 状态行，右侧一颗进设置的齿轮。
    /// （原版这里还有配额环和 info 图标——配额是账号服务的概念，本地
    /// 应用没有对应的真实数据，空着不画，免得展示一个假数字。）
    private var accountSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                    Text(Self.accountInitial)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.accountDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("本地模式")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer(minLength: 4)

                Button(action: { showsSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("设置")
            }
        .padding(.horizontal, 16)
        // 账户区行在顶上时自己让开茎带（与刘海相接的那段黑带）——原来这
        // 个高度由已删除的波形 logo 承担。
        .padding(.top, NotchSupport.restingPillAnimationHeadroom + 8)
        .padding(.bottom, 12)

        // 分隔线在账户区和搜索框之间，上下都留出间距（原来它与搜索框
        // 挤在一起，用户看着像重叠）。
        Divider()
            .overlay(Color.white.opacity(0.08))
        }
    }

    // MARK: - Formatting

    /// 会话的第二行预览：取最近一条对话的开头（用户的话优先，读起来才
    /// 像原版的「我会读完四家中国发射…」）。
    private static func previewText(_ session: ConversationSession) -> String {
        let lastEntry = session.entries.last
        let candidate = lastEntry?.userTranscript ?? lastEntry?.assistantResponse ?? ""
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 32 else { return trimmed.isEmpty ? "还没有对话" : trimmed }
        return String(trimmed.prefix(32)) + "…"
    }

    /// Relative time for a session's last update — the sidebar's second line.
    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 本机账户名，仿原版账户区的名字行。
    private static var accountDisplayName: String {
        let fullName = NSFullUserName()
        return fullName.isEmpty ? "用户" : fullName
    }

    private static var accountInitial: String {
        String(accountDisplayName.prefix(1)).uppercased()
    }
}
