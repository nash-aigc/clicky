//
//  NotchSheetRootView.swift
//  leanring-buddy
//
//  The expanded notch sheet's content: the session sidebar on the left, and
//  on the right either the conversation home or the settings pages.
//
//  Owns its own draft view models for the settings pages, exactly like the
//  titled settings window owns its pair — two drafts can exist at once (one
//  here, one in the titled window), and the rule is the same documented one:
//  last 保存 wins, because each save writes the whole configuration.
//

import SwiftUI

struct NotchSheetRootView: View {

    @ObservedObject var panelModel: NotchPanelModel
    @ObservedObject var companionManager: CompanionManager
    /// The agent subsystem, held by `CompanionManager` (one instance for the
    /// app) — observed here because the root view itself switches the content
    /// column and the top-bar chip on its state, so the switching view must
    /// be the one observing it, not only the subviews.
    @ObservedObject private var agentSessionManager: AgentSessionManager
    var collapseAction: () -> Void
    var audioHistoryProvider: () -> [CGFloat]

    @StateObject private var sessionsModel = ConversationSessionsModel()
    @StateObject private var generalSettingsViewModel = GeneralSettingsViewModel()
    @StateObject private var modelSettingsViewModel = ModelSettingsViewModel()

    @State private var showsSettings = false
    @State private var selectedSettingsPage: SettingsPage = .general

    init(
        panelModel: NotchPanelModel,
        companionManager: CompanionManager,
        collapseAction: @escaping () -> Void,
        audioHistoryProvider: @escaping () -> [CGFloat]
    ) {
        self.panelModel = panelModel
        self.companionManager = companionManager
        // `agentSessionManager` must come from `CompanionManager`, not a
        // @StateObject here — two instances would mean two rosters observing
        // the same store, and only the manager the app holds owns the
        // subprocesses.
        self.agentSessionManager = companionManager.agentSessionManager
        self.collapseAction = collapseAction
        self.audioHistoryProvider = audioHistoryProvider
    }

    var body: some View {
        Group {
            // 设置独占整窗——会话侧栏是对话主页的一部分，进了设置就整块
            // 让位给设置内容（用户的要求：点设置就应该只显示设置内容）。
            if showsSettings {
                NotchSettingsArea(
                    generalSettingsViewModel: generalSettingsViewModel,
                    modelSettingsViewModel: modelSettingsViewModel,
                    selectedPage: $selectedSettingsPage,
                    backAction: { showsSettings = false },
                    closeAction: collapseAction
                )
            } else {
                HStack(spacing: 0) {
                    HomeSpaceSidebarView(
                        sessionsModel: sessionsModel,
                        agentSessionManager: agentSessionManager,
                        showsSettings: $showsSettings
                    )
                    .frame(width: 245)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)

                    VStack(spacing: 0) {
                        topBar
                        // 侧栏顶部的「对话 / Agent」切换器决定右列显示哪一
                        // 个内容视图——两个视图共享同一个 sheet，不嵌套。
                        switch agentSessionManager.selectedSidebarSection {
                        case .conversations:
                            NotchHomeView(
                                companionManager: companionManager,
                                sessionsModel: sessionsModel
                            )
                        case .agents:
                            AgentSessionView(agentSessionManager: agentSessionManager)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { consumeRequestedSettingsPageIfNeeded() }
        .onChange(of: panelModel.requestedSettingsPage) { _, _ in
            consumeRequestedSettingsPageIfNeeded()
        }
    }

    /// The menu bar panel's 「更换…」 asks for settings from outside the
    /// sheet: the request rides `panelModel.requestedSettingsPage`. It has to
    /// be consumed from both hooks — onAppear because the expand() that sets
    /// the flag is the same call that inserts this view (onChange never fires
    /// for a value the view did not exist to see change), onChange because the
    /// sheet may already be open when the panel asks.
    private func consumeRequestedSettingsPageIfNeeded() {
        guard let requestedPage = panelModel.requestedSettingsPage else { return }
        selectedSettingsPage = requestedPage
        showsSettings = true
        panelModel.requestedSettingsPage = nil
    }

    /// 仿 HeyClicky 的内容区顶栏：正中一颗当前会话的胶囊（角色头像 + 会话
    /// 名 + 下拉箭头），右上角是实时活动指示和关闭按钮。顶部留出茎带的
    /// 高度，不与刘海相接的那段重叠。
    private var topBar: some View {
        HStack(spacing: 14) {
            Spacer()

            // Agent 页顶栏只显示当前 Agent 的名字（会话切换 Menu 跟会话
            // 无关，不能混进 Agent 视图）。
            if agentSessionManager.selectedSidebarSection == .agents {
                agentChip
            } else {
                sessionChip
            }

            NotchActivityView(
                phase: panelModel.activityPhase,
                audioHistoryProvider: audioHistoryProvider
            )
            .frame(height: 14)

            Button(action: collapseAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .pointerCursor()
            }
            .buttonStyle(.plain)
            .help("收起（Esc）")
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchSupport.restingPillAnimationHeadroom + 8)
        .padding(.bottom, 2)
    }

    /// The active session's identity in the header — HeyClicky's centered
    /// chip, and a working switcher: clicking it drops the session list, and
    /// picking one moves the live conversation there (the sidebar's dot, the
    /// flow and the pipeline's write target all follow, since they read the
    /// same store).
    private var sessionChip: some View {
        Menu {
            ForEach(sessionsModel.sessions) { session in
                Button(action: { sessionsModel.selectSession(session.id) }) {
                    if session.id == sessionsModel.activeSessionID {
                        Label(session.title, systemImage: "checkmark")
                    } else {
                        Text(session.title)
                    }
                }
            }
            Divider()
            Button(action: { sessionsModel.createSession() }) {
                Label("新建会话", systemImage: "plus")
            }
        } label: {
            // 右侧不放小人（用户的要求：角色只在左侧会话列表出现）。
            // 这里也绝不能放 MascotAvatarDisc：macOS 的 Menu 对 label 提议
            // 不设上限，图会按素材原始 256pt 炸开、把整条顶栏撑高——
            // 实测 2026-09-22，任何 overlay/clipShape/frame 都压不住。
            HStack(spacing: 7) {
                Text(sessionsModel.activeSession?.title ?? "新对话")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }
    /// The Agent counterpart of `sessionChip` — a plain name capsule, not a
    /// Menu: switching agents happens in the sidebar list, so there is
    /// nothing to drop down here.
    private var agentChip: some View {
        HStack(spacing: 7) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            Text(agentSessionManager.selectedAgent?.name ?? "Agent")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)

            if let selectedAgent = agentSessionManager.selectedAgent {
                Text(selectedAgent.status.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .fixedSize()
    }
}

// MARK: - Settings area

/// The settings pages embedded in the sheet, drawn to HeyClicky's reference
/// screenshot: a ~245pt sidebar carrying the 「‹ 返回」 pill, a large bold
/// 「设置」 title, the account card, and the page list grouped under uppercase
/// section labels, with the app version pinned at its bottom; the content
/// column opens with the page's title and carries the close button at its
/// top right. The page views themselves are **reused unchanged** — embedding
/// copies no page.
struct NotchSettingsArea: View {

    @ObservedObject var generalSettingsViewModel: GeneralSettingsViewModel
    @ObservedObject var modelSettingsViewModel: ModelSettingsViewModel
    @Binding var selectedPage: SettingsPage
    /// 独占整窗后，会话侧栏（里面有「设置」入口）已经不在了——返回对话
    /// 的出口由这里自己的底部固定项承担。
    var backAction: () -> Void
    var closeAction: () -> Void

    /// The sidebar's grouped page list: (section label, pages). The untitled
    /// first block is HeyClicky's 「通用 / 模型」 pair, the same grouping the
    /// titled window's sidebar uses.
    private static let sidebarSections: [(label: String?, pages: [SettingsPage])] = [
        (label: nil, pages: [.general, .model, .agent]),
        (label: "对话", pages: [.memory, .listen, .speak, .shortcuts]),
        (label: "看与操作", pages: [.vision, .action]),
    ]

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                contentHeader

                switch selectedPage {
                case .model:
                    ModelSettingsView(modelSettingsViewModel: modelSettingsViewModel)
                default:
                    GeneralSettingsView(
                        generalSettingsViewModel: generalSettingsViewModel,
                        page: selectedPage
                    )
                    GeneralSettingsActionBar(generalSettingsViewModel: generalSettingsViewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 「‹ 返回」 pill + the large bold page title, like the
            // reference screenshot's settings entry.
            Button(action: backAction) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 2)
                }
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.horizontal, 16)
            .padding(.top, NotchSupport.restingPillAnimationHeadroom + 8)
            .padding(.bottom, 14)

            Text("设置")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            accountCard
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        Array(Self.sidebarSections.enumerated()),
                        id: \.offset
                    ) { sectionIndex, section in
                        if let sectionLabel = section.label {
                            Text(sectionLabel.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.35))
                                .tracking(1.2)
                                .padding(.horizontal, 18)
                                .padding(.top, sectionIndex == 1 ? 14 : 0)
                                .padding(.bottom, 6)
                        }
                        ForEach(section.pages) { page in
                            NotchSettingsSidebarItem(
                                page: page,
                                isSelected: page == selectedPage,
                                action: { selectedPage = page }
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)

            // 退出按钮 + 版本行，固定在侧栏底部。菜单栏面板曾是应用唯一的
            // 退出入口（NSApp.terminate），面板删掉后退出搬到这里。
            HStack(spacing: 10) {
                Button(action: { NSApp.terminate(nil) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .font(.system(size: 10, weight: .medium))
                        Text("退出 Clicky")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("退出 Clicky")

                Spacer(minLength: 2)

                // The app version, pinned at the sidebar's bottom — the
                // reference screenshot's footer line.
                Text(Self.versionFooterText)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 245)
        .background(Color.black.opacity(0.35))
    }

    /// The account card: initial disc + account name + the 「免费版」 badge.
    /// (The badge text mirrors the reference; there is no account service
    /// behind it locally, so it reads as the plan row it looks like.)
    private var accountCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                Text(Self.accountInitial)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: 36, height: 36)

            Text(Self.accountDisplayName)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("免费版")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: Content header

    private var contentHeader: some View {
        HStack(spacing: 12) {
            Text(selectedPage.sidebarTitle)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)

            Spacer(minLength: 8)

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .pointerCursor()
            }
            .buttonStyle(.plain)
            .help("收起（Esc）")
        }
        .padding(.horizontal, 24)
        .padding(.top, NotchSupport.restingPillAnimationHeadroom + 8)
        .padding(.bottom, 10)
    }

    // MARK: Formatting

    private static var accountDisplayName: String {
        let fullName = NSFullUserName()
        return fullName.isEmpty ? "用户" : fullName
    }

    private static var accountInitial: String {
        String(accountDisplayName.prefix(1)).uppercased()
    }

    /// "Clicky 1.4 (213)" — short version + build, the footer's shape.
    private static var versionFooterText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if shortVersion.isEmpty && buildVersion.isEmpty {
            return "Clicky"
        }
        return "Clicky \(shortVersion) (\(buildVersion))"
    }
}

private struct NotchSettingsSidebarItem: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.sidebarSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.55))
                    .frame(width: 16)

                Text(page.sidebarTitle)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.55))
                    .lineLimit(1)

                Spacer(minLength: 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            self.isHovering = isHovering
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.white.opacity(0.14) }
        if isHovering { return Color.white.opacity(0.06) }
        return .clear
    }
}
