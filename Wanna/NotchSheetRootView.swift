//
//  NotchSheetRootView.swift
//  Wanna
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
    /// The VoiceWeb subsystem, held by `CompanionManager` (one instance for
    /// the app) — observed because both the 语音聊天 sidebar list and the
    /// content column read its published presets / phase / transcript.
    @ObservedObject private var voiceChatController: VoiceChatController
    /// 「复制全文」按下后的对勾态，1.4 秒后自己回去。
    @State private var copyFullConversationDidSucceed = false
    @State private var copyFullConversationResetTask: Task<Void, Never>?
    var collapseAction: () -> Void
    /// 收起 / 重新展开的两半，专给 Agent 页的「打开」用：选文件夹时面板必须
    /// 让开，选完再放回来（用户 2026-09-23 的第 7 条）。与 `collapseAction`
    /// 分开是因为语义不同——`collapseAction` 是"用户把面板收起来了"，
    /// 这两个是"面板暂时让个位，马上回来"。
    var hideSheetAction: () -> Void
    var revealSheetAction: () -> Void
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
        hideSheetAction: @escaping () -> Void,
        revealSheetAction: @escaping () -> Void,
        audioHistoryProvider: @escaping () -> [CGFloat]
    ) {
        self.panelModel = panelModel
        self.companionManager = companionManager
        // `agentSessionManager` must come from `CompanionManager`, not a
        // @StateObject here — two instances would mean two rosters observing
        // the same store, and only the manager the app holds owns the
        // subprocesses.
        self.agentSessionManager = companionManager.agentSessionManager
        self.voiceChatController = companionManager.voiceChatController
        self.collapseAction = collapseAction
        self.hideSheetAction = hideSheetAction
        self.revealSheetAction = revealSheetAction
        self.audioHistoryProvider = audioHistoryProvider
    }

    var body: some View {
        Group {
            // 设置独占整窗——会话侧栏是对话主页的一部分，进了设置就整块
            // 让位给设置内容（用户的要求：点设置就应该只显示设置内容）。
            // 「归档」照同一套整窗接管：它自带左列，所以侧栏里那些
            // showsSettings 的互斥判断一处都不用动。设置优先于归档。
            if showsSettings {
                NotchSettingsArea(
                    sessionsModel: sessionsModel,
                    companionManager: companionManager,
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
                        voiceChatController: voiceChatController,
                        showsSettings: $showsSettings,
                        openRecordingSettingsAction: {
                            // 先落页、再开门 —— 顺序不能反：`NotchSettingsArea` 是在
                            // `showsSettings` 变真的那一刻被插进树的，它读的是当时的
                            // `selectedSettingsPage`。
                            selectedSettingsPage = .recording
                            showsSettings = true
                        }
                    )
                    .frame(width: 245)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)

                    VStack(spacing: 0) {
                        // 顶栏只剩对话页有：Agent 与语音聊天页的内容视图
                        // 自带标题，用户要求「两个标题保留一个」，并且那条
                        // 栏上的 ✕ 也不要（点窗口外 / Esc 都能收起）。
                        if agentSessionManager.selectedSidebarSection == .conversations {
                            topBar
                        }
                        // 侧栏顶部的「对话 / Agent」切换器决定右列显示哪一
                        // 个内容视图——两个视图共享同一个 sheet，不嵌套。
                        switch agentSessionManager.selectedSidebarSection {
                        case .conversations:
                            NotchHomeView(
                                companionManager: companionManager,
                                sessionsModel: sessionsModel
                            )
                        case .agents:
                            AgentSessionView(
                                agentSessionManager: agentSessionManager,
                                hideSheet: hideSheetAction,
                                revealSheet: revealSheetAction
                            )
                        case .voiceChat:
                            VoiceChatSessionView(controller: voiceChatController)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 右列那条贯穿的横线，与侧栏切换器下面那条分割线**同一个 y**
                    // ——用户 2026-09-23：「每一个页面的右侧增加一条线…这条线应该
                    // 从左到右贯穿，而且必须是一条直线…右侧的正文内容显示在这条线
                    // 下面，线上面是相关的参数部分」。横向完全贯穿（不留边），所以
                    // 它与侧栏自己那条线拼起来是一整条，而不是两截。
                    //
                    // 画在这里而不是画进三个内容视图：三页的页头高度不同，但这条线
                    // 必须落在同一个 y 上，只有一列一个 overlay 才能保证这件事。
                    // 页头各自按 `contentColumnHeaderBandHeight` 排到线下为止。
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                            .offset(y: NotchSupport.contentColumnHeaderRuleY)
                    }
                }
            }
        }
        .onAppear {
            consumeRequestedSettingsPageIfNeeded()
            openVoiceChatSectionIfASessionIsLive()
        }
        .onChange(of: panelModel.requestedSettingsPage) { _, _ in
            consumeRequestedSettingsPageIfNeeded()
        }
    }

    /// 用户 2026-09-23：「如果用户当前处于聊天状态，点击刘海屏后应首先自动切换
    /// 到语音聊天界面，而不是对话界面」。
    ///
    /// 只在**展开这一下**切一次，靠的是 `onAppear` 的语义：面板每次展开都会重新
    /// 插入这张视图，而展开之后用户自己点回「对话」不会再触发它 —— 所以人不会被
    /// 反复拽回语音聊天页。会话不在跑就什么都不做，默认停在对话页仍然是对的。
    ///
    /// 放在 `consumeRequestedSettingsPageIfNeeded()` 之后：外部的设置请求优先，
    /// 它刚把整窗让给设置页的时候不该被这一句抢回列表页。
    private func openVoiceChatSectionIfASessionIsLive() {
        guard !showsSettings else { return }
        guard voiceChatController.connectionPhase != .idle else { return }
        agentSessionManager.selectedSidebarSection = .voiceChat
    }

    /// The menu bar panel's 「更换…」 asks for settings from outside the
    /// sheet: the request rides `panelModel.requestedSettingsPage`. It has to
    /// be consumed from both hooks — onAppear because the expand() that sets
    /// the flag is the same call that inserts this view (onChange never fires
    /// for a value the view did not exist to see change), onChange because the
    /// sheet may already be open when the panel asks.（归档页以前也要在这里一起
    /// 退出，自从它搬进设置、成为 `SettingsPage.archive` 之后就不需要了 ——
    /// 它现在就在设置里。）
    private func consumeRequestedSettingsPageIfNeeded() {
        guard let requestedPage = panelModel.requestedSettingsPage else { return }
        selectedSettingsPage = requestedPage
        showsSettings = true
        panelModel.requestedSettingsPage = nil
    }

    /// 内容区顶栏：左边是当前会话的标题，右边只剩实时活动指示。顶部留出茎
    /// 带的高度，不与刘海相接的那段重叠——这个数字是 `NotchSupport.sheetHeader
    /// TopInset`，Agent / 语音聊天页的标题读同一个常量，所以三页的标题落在
    /// 同一条基线上（面板顶边就是屏幕最上沿，写 0 会钻到菜单栏底下）。
    ///
    /// 2026-09-23 用户要求「右侧那个下拉菜单按钮改成标题，叉删掉」：这里原本
    /// 是一颗可展开的会话胶囊 + 一颗 ✕。胶囊换成纯标题后，换会话只剩下侧栏
    /// 一条路——那本来就是主路径，而且侧栏的列表能显示预览与时间，比这颗只
    /// 放得下标题的胶囊好用。✕ 去掉不影响收起：Esc、点面板外、失活三条路都
    /// 还在。
    private var topBar: some View {
        HStack(spacing: 14) {
            Text(sessionsModel.activeSession?.title ?? "新对话")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            // 通话中：状态字（连接中琥珀 / 通话中绿）+ 挂断；活动动画让位 ——
            // 两个状态源会互相打架。
            NotchActivityView(
                phase: panelModel.activityPhase,
                audioHistoryProvider: audioHistoryProvider
            )
            .frame(height: 14)

            copyFullConversationButton
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        // 页头整体占满 `contentColumnHeaderBandHeight`：这条栏的下边缘必须正好落在
        // 右列那条贯穿横线上（`NotchSupport.contentColumnHeaderRuleY`），否则三个
        // 内容页各按自己的内容高度收尾，线就成了三页各一条、高度不一的短线。
        // 原来的 `.padding(.bottom, 2)` 是内容底边距，换成固定高度后由这 35pt
        // 自己决定内容在中线上方的位置。
        .frame(height: NotchSupport.contentColumnHeaderBandHeight, alignment: .center)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
    }

    // MARK: - 复制全文

    /// 「复制全文」—— 把当前会话的**整段上下文**复制到剪贴板。
    ///
    /// 它取代的是原来那两个按钮（Ask 页的「全双工语音」与它的音色）。用户 2026-09-25：
    /// 「把 ASK 页面右上角的『全双工语音』和『全双工语音音色』删掉，这个模式也删掉，
    /// 完全放弃这个接线和这个模式……把全双工语音这个位置的按钮改成复制全文按钮，
    /// 用户可以复制所有的上下文」。
    ///
    /// 复制的是**整段对话**：每一轮的问与答，按时间顺序拼接。执行器的标签会被剥掉
    /// （存储的原稿带着 `[POINT:…]` / `[CLICK:…]` 这类标签，粘到别处只是噪声），
    /// 与页面里那个「复制」按钮同一条口径 —— 所见即所得。
    private var copyFullConversationButton: some View {
        Button {
            copyFullConversationToPasteboard()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copyFullConversationDidSucceed ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text("复制全文")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("把当前会话的整段上下文（每一轮的问与答）复制到剪贴板")
    }

    private func copyFullConversationToPasteboard() {
        let entries = sessionsModel.activeSession?.entries ?? []
        let conversationText = entries.compactMap { entry -> String? in
            var lines: [String] = []
            let question = entry.userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { lines.append("我：" + question) }
            // 剥标签，与页面上那个「复制」按钮同一条口径。
            let answer = ActionTagParser.speakableTextFromStreamedReply(entry.assistantResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { lines.append("Wanna：" + answer) }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")

        guard !conversationText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conversationText, forType: .string)

        copyFullConversationDidSucceed = true
        copyFullConversationResetTask?.cancel()
        copyFullConversationResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            copyFullConversationDidSucceed = false
        }
    }

}

// MARK: - Settings area

/// The settings pages embedded in the sheet, drawn to the reference
/// screenshot: a ~245pt sidebar carrying a large bold 「设置」 title and the page
/// list grouped under uppercase section labels, with 「返回」 (green) at its
/// bottom-left, 「退出 Wanna」 at its bottom-right and a divider above the pair;
/// the content column opens with the page's title and carries 恢复默认 / 保存 /
/// 关闭 at that row's right — and **no ✕**, which the user removed on 2026-09-23.
/// The page views themselves are **reused unchanged** — embedding copies no page.
///
/// 侧栏里原本还有一张账号卡（首字母圆盘 + 用户名 + 「免费版」），2026-09-23
/// 用户要求「设置页面也把用户名删掉，第一个直接是通用」——本机没有账号服务
/// 支撑那张卡，删掉后侧栏第一行就是 通用，第二行是 交互样式。同一天稍后
/// 顶部那颗「‹ 返回」胶囊和底部的版本行也按用户要求动了位置：「返回按钮放在
/// 设置页面的左下角，退出按钮放在返回按钮的右侧。去掉版本号」。
struct NotchSettingsArea: View {

    /// 角色页的草稿脏标记与保存动作（由 `VoiceChatRoleSettingsView` 反填）。
    /// 放在宿主而不是视图里，因为页头的保存按钮也在读它。
    @State private var roleEditorHasUnsavedChanges = false
    @State private var roleEditorSaveAction: (() -> Void)?

    /// 「归档」页要它 —— 那一页复用 `NotchArchiveArea`，而归档的列表与选中态
    /// 都来自这个模型。
    @ObservedObject var sessionsModel: ConversationSessionsModel

    /// 音色查看那一页要它 —— 试听必须走全 app 唯一的播放引擎（见
    /// `CompanionManager.playVoicePreview`），而设置页拿不到那个客户端。
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var generalSettingsViewModel: GeneralSettingsViewModel
    @ObservedObject var modelSettingsViewModel: ModelSettingsViewModel
    @Binding var selectedPage: SettingsPage
    /// 独占整窗后，会话侧栏（里面有「设置」入口）已经不在了——返回对话
    /// 的出口由这里自己的底部固定项承担。
    var backAction: () -> Void
    var closeAction: () -> Void

    /// The sidebar's grouped page list: (section label, pages). The untitled
    /// first block is the 「通用 / 模型」 pair, the same grouping the titled
    /// window's sidebar uses.
    private static let sidebarSections: [(label: String?, pages: [SettingsPage])] = [
        (label: nil, pages: [.general, .interactionStyle, .model, .agent]),
        (label: "对话", pages: [.memory, .listen, .speak, .shortcuts, .recording, .review]),
        (label: "看与操作", pages: [.vision, .action]),
        // 「语音聊天」分组（用户 2026-09-24 要求）。角色页与语音聊天页右键
        // 「编辑」共用同一份视图，所以两处入口改的是同一份数据。
        (label: "语音聊天", pages: [.voiceChatRoles, .voiceCatalog, .voiceChatConnection]),
        // 「归档」按用户 2026-09-24 的要求从对话侧栏移到这里：
        // 「在「导出导入」的下面添加一个按钮叫「归档」」。
        (label: "导入导出", pages: [.exportSettings, .importSettings, .archive]),
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
                case .voiceChatRoles:
                    VoiceChatRoleSettingsView(
                        hasUnsavedChangesBinding: $roleEditorHasUnsavedChanges,
                        registerSaveAction: { roleEditorSaveAction = $0 }
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .voiceCatalog:
                    VoiceCatalogSettingsView(companionManager: companionManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .archive:
                    // 复用归档那两栏，但**不要它自己的返回键** —— 设置侧栏就是
                    // 导航，页面里再来一个返回会变成两个出口。
                    NotchArchiveArea(
                        sessionsModel: sessionsModel,
                        backAction: nil,
                        closeAction: nil
                    )
                case .model:
                    ModelSettingsView(modelSettingsViewModel: modelSettingsViewModel)
                case .exportSettings:
                    SettingsTransferPage(mode: .exportSettings)
                case .importSettings:
                    SettingsTransferPage(mode: .importSettings)
                default:
                    GeneralSettingsView(
                        generalSettingsViewModel: generalSettingsViewModel,
                        page: selectedPage
                    )
                    // 底部那条动作栏没有了——「恢复默认 / 保存 / 关闭」搬到
                    // `contentHeader` 的右侧（用户 2026-09-23：「把右侧最下面
                    // 这一行的恢复默认/保存/关闭这些按钮放到右侧顶部标题的
                    // 右侧，也就是标题这一行的靠右部分，这样能减少一些右侧空间
                    // 的占用」）。模型页不受影响：`ModelSettingsView` 自带
                    // 保存栏，它的按钮本来就不在这条里。
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The large bold page title, like the reference screenshot's
            // settings entry. 「‹ 返回」 used to sit above it; the user moved
            // that pill down to this column's bottom-left (2026-09-23), so the
            // title is now the first thing here.
            Text("设置")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.top, NotchSupport.sheetHeaderTopInset)
                .padding(.bottom, 14)

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
                                action: {
                                    SoundEffectPlayer.shared.play(.sidebarButton)
                                    selectedPage = page
                                }
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)

            // 底部一行：顶上一条分隔线，左「返回」右「退出 Wanna」。用户
            // 2026-09-23 先定「返回按钮放在设置页面的左下角，退出按钮放在返回
            // 按钮的右侧。去掉版本号」，随后又补了三条：「设置页面左下角也应该
            // 有一条线」「返回按钮跟设置按钮必须样式完全相同，但返回按钮改成绿色，
            // 让用户知道可以通过这个渠道返回」「退出按钮靠右对齐，返回按钮靠左
            // 对齐」。
            //
            // 所以这一行不再是原来那种并排挤在左下角的小胶囊：分隔线与侧栏底部
            // 那条同形，两颗按钮改用 `NotchBarActionButton`——和侧栏的「设置」
            // 同一个结构体，样式不可能漂，返回只是把 tint 换成绿色。绿色的理由
            // 是「返回」在这块深色面板里只有一个图标能提示它，染绿之后它和
            // 「设置」在竖直方向正对、颜色又不同，来回一眼就找到。
            //
            // 版本行（原来是 "Wanna 1.4 (213)"）按同一句要求删掉了；退出按钮
            // 留着 —— 菜单栏面板曾是这个应用唯一的退出入口（NSApp.terminate），
            // 面板删掉后它是唯一还露在外面的那个。
            HStack(spacing: 8) {
                NotchBarActionButton(
                    title: "返回",
                    systemImage: "chevron.left",
                    tint: DS.Colors.success,
                    help: "返回对话"
                ) {
                    backAction()
                }

                Spacer(minLength: 8)

                // 「重启」放在「退出」左边（用户 2026-09-26：「把这个退出按钮左侧添加
                // 一个重启……你就写退出、重启两个按钮就可以了」）。
                //
                // **必须先起新实例再退旧的**，顺序反了就没有第二次机会 —— `terminate`
                // 之后这个进程里不会再有任何一行代码执行。
                //
                // `createsNewApplicationInstance`：这是个 `LSUIElement` 的单实例应用，
                // 不带这个开关时 `openApplication` 只会把请求交给**正在退出的自己**，
                // 结果就是退出去、没回来（用户按了重启，应用却消失了）。
                NotchBarActionButton(
                    title: "重启",
                    systemImage: "arrow.clockwise",
                    help: "重启 Wanna"
                ) {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(
                        at: Bundle.main.bundleURL,
                        configuration: configuration
                    ) { _, _ in
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }

                NotchBarActionButton(
                    title: "退出",
                    systemImage: "power",
                    help: "退出 Wanna"
                ) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Divider()
                    .overlay(Color.white.opacity(0.08))
            }
        }
        .frame(width: 245)
        // 不透明（用户 2026-09-23：「整个弹出窗口调整为完全不透明」）。原来
        // 是 `Color.black.opacity(0.35)` 叠在面板地面上，合成即 surface3 的
        // #101014，换成同一个色的不透明版，观感不变。
        .background(DS.Colors.surface3)
    }

    // MARK: Content header

    /// 内容页标题行：左边是这一页的名字，右边是这一页的动作按钮。
    ///
    /// 2026-09-23 这一行动了两处。**右上角那颗 ✕ 删掉了**（用户：「把设置页面
    /// 右上角的叉号去掉」「另外，把标题右侧的叉X删掉」）——它不是唯一出口：Esc、
    /// 点面板外、失活三条路都还在，侧栏底部的「返回」也刚补上。**「恢复默认 /
    /// 保存 / 关闭」从页面底部搬到了这里**（用户：「把右侧最下面这一行的恢复
    /// 默认/保存/关闭这些按钮放到右侧顶部标题的右侧……这样能减少一些右侧空间
    /// 的占用」）——搬走之后右侧少了一整条 ~60pt 的固定栏，标题行本身长高
    /// ~30pt，净省下一截。
    ///
    /// 模型页没有这一组：`ModelSettingsView` 的保存栏是它自己的一部分。
    private var contentHeader: some View {
        HStack(spacing: 12) {
            Text(selectedPage.sidebarTitle)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            if selectedPage == .voiceChatRoles {
                // 角色页的保存是**这一页自己的草稿**（不是 AppSettings），所以
                // 页头这里单独画：灭了 = 没有未保存的修改，亮了 = 点一下落盘。
                HStack(spacing: 8) {
                    Button {
                        roleEditorSaveAction?()
                    } label: {
                        Text("保存")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(roleEditorHasUnsavedChanges
                                             ? DS.Colors.textOnAccent
                                             : DS.Colors.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(roleEditorHasUnsavedChanges
                                          ? DS.Colors.accent
                                          : DS.Colors.surface3)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!roleEditorHasUnsavedChanges)

                    Button("关闭") { closeAction() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .pointerCursor()
                }
            } else if selectedPage != .model && selectedPage.drawsSettingsActionBar {
                // 关闭的动作必须走 `closeAction`（收起面板），**不能**是
                // `GeneralSettingsActionBar` 默认的 `NSApp.keyWindow?.close()`：
                // 展开的刘海面板就是 key window，`.close()` 会把它直接 orderOut，
                // 而 `NotchWindowController.isExpanded` 还停在 true、`expansionProgress`
                // 还停在高位 —— 刘海会卡成一个既收不回去、也点不开的状态。
                GeneralSettingsActionBar(
                    generalSettingsViewModel: generalSettingsViewModel,
                    style: .headerInline,
                    closeAction: closeAction
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .padding(.bottom, 10)
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
