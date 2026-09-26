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
    /// The 语音聊天 subsystem, held by `CompanionManager` (one instance for
    /// the app) — observed because both the 语音聊天 sidebar list and the
    /// content column read its published presets / phase / transcript.
    @ObservedObject private var voiceChatController: VoiceChatController
    /// 每张卡片的聊天模式与角色。设置本身住在磁盘上（`AppSettings.json`），这个模型只是
    /// 把它读成视图要的形状 —— 观察它是为了让「切一下模式」立刻重绘右列。
    @ObservedObject private var cardChatPreferences = CardChatPreferenceModel.shared
    var collapseAction: () -> Void
    /// 收起 / 重新展开的两半，专给 Agent 页的「打开」用：选文件夹时面板必须
    /// 让开，选完再放回来（用户 2026-09-23 的第 7 条）。与 `collapseAction`
    /// 分开是因为语义不同——`collapseAction` 是"用户把面板收起来了"，
    /// 这两个是"面板暂时让个位，马上回来"。
    var hideSheetAction: () -> Void
    var revealSheetAction: () -> Void
    /// 顶栏那颗「展开 / 收缩」：全屏 ↔ 刘海下方小窗。动作住在
    /// `NotchWindowController`（只有它手里有面板与屏幕），这里只是转手。
    var toggleFullScreenAction: () -> Void
    var audioHistoryProvider: () -> [CGFloat]

    @StateObject private var sessionsModel = ConversationSessionsModel()
    @StateObject private var generalSettingsViewModel = GeneralSettingsViewModel()
    @StateObject private var modelSettingsViewModel = ModelSettingsViewModel()

    @State private var showsSettings = false
    @State private var selectedSettingsPage: SettingsPage = .general

    /// 侧栏是否收成一条图标栏（顶栏左右那两颗按钮管它）。
    ///
    /// **没放进 `AppSettings`，这是有意的取舍。** 它确实是一条该跨启动保留的用户
    /// 偏好，而 `AppSettingsStore.save` 那条路走不通：`.wannaAppSettingsChanged`
    /// 的观察者里有一句「关掉『重启后保留对话』就把已存的对话删掉」
    ///（`CompanionManager.appSettingsChangedObserver`），它调的是
    /// `ConversationSessionsStore.clearAllSessions()` —— 那个函数**连内存里的会话
    /// 一起清**（见 `ConversationHistoryStore.swift` 里它的实现）。也就是说，
    /// 点一下「收起侧栏」会把侧栏里的会话全清空。存 `UserDefaults` 拿到同样的
    /// 「重启后保持」，副作用为零 —— 展开态的面板高度
    ///（`NotchSupport.sheetHeightFractionKey`）本来就是这么存的。
    @State private var isSessionSidebarCollapsed =
        UserDefaults.standard.bool(forKey: NotchSheetRootView.sessionSidebarCollapsedDefaultsKey)

    private static let sessionSidebarCollapsedDefaultsKey = "wannaSessionSidebarCollapsed"

    /// 侧栏展开时的宽度。**值在 `NotchSupport` 里**（它要参与面板总宽的计算，
    /// 两处各存一份就一定会漂）。
    private static var expandedSidebarWidth: CGFloat {
        NotchSupport.expandedSidebarWidth
    }

    init(
        panelModel: NotchPanelModel,
        companionManager: CompanionManager,
        collapseAction: @escaping () -> Void,
        hideSheetAction: @escaping () -> Void,
        revealSheetAction: @escaping () -> Void,
        toggleFullScreenAction: @escaping () -> Void,
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
        self.toggleFullScreenAction = toggleFullScreenAction
        self.audioHistoryProvider = audioHistoryProvider
    }

    // MARK: - 当前卡片与它的聊天模式（2026-09-26）

    /// 右列现在属于哪一类卡片。
    ///
    /// 「分区决定哪张卡片」这条线是从旧结构继承下来的（`.conversations` = 主循环卡片，
    /// `.agents` = 选中的那个 agent 卡片），今天依然成立：卡片区点一下就会把分区一起切
    ///（`AgentCardModel.open`）。模式与角色都按这张卡片取。
    private var activeCardKind: CardKind {
        guard agentSessionManager.selectedSidebarSection == .agents else { return .mainLoop }
        // 复盘 agent 也是一个 `AgentSession`，但它的默认模式与 Claude Code 一样是文本，
        // 所以这个区分只影响"记的是哪张卡片的模式"，不影响默认值。
        return agentSessionManager.selectedAgent?.name == AgentCardModel.reviewAgentName
            ? .review
            : .claudeCode
    }

    /// 右列现在属于哪张卡片（= 背后那条会话 / 代理记录的 uuidString，与卡片区同一个键）。
    private var activeCardID: String? {
        switch agentSessionManager.selectedSidebarSection {
        case .conversations: return sessionsModel.activeSessionID?.uuidString
        case .agents: return agentSessionManager.selectedAgentID?.uuidString
        // 旧的「语音聊天」分区（侧栏那颗「角色」进的页）**不归任何卡片** ——
        // 所以它没有模式条。那条路在阶段 5 改成直进角色编辑页。
        case .voiceChat: return nil
        }
    }

    /// 右列此刻该按哪种模式显示。nil = 没有卡片（见上一条），模式条也就不画。
    private var activeCardChatMode: CardChatMode? {
        guard let cardID = activeCardID else { return nil }
        return cardChatPreferences.mode(forCardID: cardID, kind: activeCardKind)
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
                // 两列装在一个 ZStack 里，顶栏那排窗口按钮是它的第二个孩子 ——
                // 那排按钮是**窗口级的东西**（收起侧栏 / 收回刘海 / 全屏），不属于
                // 这两列中的任何一列，所以它不能参与那一层的布局：`HStack` 是
                //「左列定宽、右列吃掉剩下的」，多一个 177pt 宽的兄弟就会挤进
                // 最小宽度的账里。ZStack 的尺寸取两个孩子的较大者，而这一排永远
                // 比两列窄，所以它对布局是透明的。
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        // 收起／展开只换左列这一个视图，右边那一列（内容、页头、那条
                        // 贯穿的横线）完全不知道这件事 —— 宽度变了，`maxWidth: .infinity`
                        // 自己会跟上。
                        if isSessionSidebarCollapsed {
                            HomeSpaceSidebarRailView(
                                sessionsModel: sessionsModel,
                                agentSessionManager: agentSessionManager,
                                voiceChatController: voiceChatController,
                                showsSettings: $showsSettings,
                                toggleSidebarCollapseAction: {
                                    isSessionSidebarCollapsed.toggle()
                                    SoundEffectPlayer.shared.play(.sidebarButton)
                                }
                            )
                        } else {
                            HomeSpaceSidebarView(
                                sessionsModel: sessionsModel,
                                agentSessionManager: agentSessionManager,
                                voiceChatController: voiceChatController,
                                showsSettings: $showsSettings,
                                // 分阶段加载：第一拍只建侧栏的骨架（切换器、搜索、
                                // 底部按钮），列表留空 —— 列表是随会话数增长的那部分。
                                showsSectionList: panelModel.isSheetContentReady,
                                // 「历史归档」：归档页面住在设置里，侧栏这一行只是把设置
                                // 打开并落到那一页。（参数顺序跟着声明走，memberwise init。）
                                openArchiveAction: {
                                    selectedSettingsPage = .archive
                                    showsSettings = true
                                },
                                openRecordingSettingsAction: {
                                    // 先落页、再开门 —— 顺序不能反：`NotchSettingsArea` 是在
                                    // `showsSettings` 变真的那一刻被插进树的，它读的是当时的
                                    // `selectedSettingsPage`。
                                    selectedSettingsPage = .recording
                                    showsSettings = true
                                },
                                openRoleSettingsAction: {
                                    selectedSettingsPage = .voiceChatRoles
                                    showsSettings = true
                                },
                                toggleSidebarCollapseAction: {
                                    isSessionSidebarCollapsed.toggle()
                                    SoundEffectPlayer.shared.play(.sidebarButton)
                                },
                            )
                            .frame(width: Self.expandedSidebarWidth)
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1)

                        VStack(spacing: 0) {
                            // 对话页分割线之上那一行：**只有一排**（`topBar` 本身就是那一排
                            // 模式条 + 图文特有的音色）。
                            //
                            // 语音 / 视频模式下这整块让给语音页（它自带页头，也自带模式条），
                            // 所以这里只在文本 / 图文模式下画 —— 否则会画出两排模式按钮。
                            if agentSessionManager.selectedSidebarSection == .conversations,
                               let activeChatMode = activeCardChatMode,
                               !activeChatMode.isVoiceLike {
                                topBar
                                    .padding(.top, NotchSupport.sheetHeaderTopInset)
                                // 音色弹窗跟着页头走：它就开在右上那颗「音色」下面。
                                if isVoicePickerPresented {
                                    voicePickerPanel
                                }
                            }
                            // 侧栏顶部的「对话 / Agent」切换器决定右列显示哪一
                            // 个内容视图——两个视图共享同一个 sheet，不嵌套。
                            //
                            // **分阶段加载**：第一拍这一列是空的，面板先整块出现
                            //（地面上那块面板色由 `NotchExpandedSheetView` 画，与这里
                            // 无关），重内容在下一拍进来。见
                            // `NotchPanelModel.isSheetContentReady` —— 那里记着实测：
                            // 一次展开的主线程时间几乎全在 SwiftUI 对整棵树反复布局，
                            // 而树的主体就是这三页里的一页。
                            if panelModel.isSheetContentReady {
                                Group {
                                    // **语音 / 视频模式：右列整块换成语音页**（用户：这两个
                                    // 模式「分别使用对应的全双工三段式模式」）。它按卡片绑定 ——
                                    // 提示词里要带这段会话的记录，回话也要写回这条会话，
                                    // 所以卡片 id 一路传下去。
                                    if let cardID = activeCardID,
                                       let activeChatMode = activeCardChatMode,
                                       activeChatMode.isVoiceLike {
                                        VoiceChatSessionView(controller: voiceChatController,
                                                             cardID: cardID,
                                                             cardKind: activeCardKind)
                                    } else {
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
                                            // 旧的「语音聊天」分区：不归任何卡片，所以没有
                                            // 模式条、也没有卡片提示词（阶段 5 把这条路改成
                                            // 直进角色编辑页）。
                                            VoiceChatSessionView(controller: voiceChatController)
                                        }
                                    }
                                }
                                // TEMPORARY PROBE (2026-09-26)：分阶段加载的第二拍
                                // 何时到位。与 `[expand] 内容就位`（面板骨架那次）相减，
                                // 就是「面板已经看得见、内容还在建」的那段时长。
                                .onAppear {
                                    let elapsed = Date().timeIntervalSince1970 - NotchSupport.expansionStartedAt
                                    if NotchSupport.expansionStartedAt > 0 {
                                        print(String(format: "⏱️ [expand] 重内容就位 +%.0fms", elapsed * 1000))
                                    }
                                }
                            } else {
                                // 空占位：它必须**什么都不建**，否则第一拍就不便宜了。
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // **角色清单画在这一层**（2026-09-26）：它挂在模式条上的话，
                        // 那条只有 36pt 高，清单画得出、却**收不到点击**（实测点「管理角色…」
                        // 穿透到了下面那行预设按钮上）。这一层是整块右列，frame 够大，
                        // 而 `.overlay` 不参与布局 —— 清单浮在内容上，正文不会被推下去。
                        // **角色清单跟着那颗按钮走**：语音 / 视频页把「角色」放在**输入框那一行**，
                        // 所以清单从**下往上**弹；文本 / 图文页那颗还在页头，就仍然从上往下弹。
                        // 用户 2026-09-26 把语音页那颗挪到了下面（「放在类似语速按钮的位置上」），
                        // 清单不跟着走的话就会出现在离按钮很远的地方。
                        .overlay(alignment: activeCardChatMode?.isVoiceLike == true
                                 ? .bottomLeading : .topLeading) {
                            if let openCardID = cardChatPreferences.openRoleListCardID,
                               openCardID == activeCardID {
                                CardChatRoleListPanel(cardID: openCardID,
                                                      cardKind: activeCardKind,
                                                      preferences: cardChatPreferences)
                                    .padding(.leading, NotchSupport.contentColumnHorizontalMargin)
                                    .padding(.bottom, activeCardChatMode?.isVoiceLike == true
                                            ? Self.rolePanelBottomInset : 0)
                                    .padding(.top, activeCardChatMode?.isVoiceLike == true
                                            ? 0
                                            : NotchSupport.sheetHeaderTopInset
                                              + NotchSupport.cardChatModeBandHeight)
                            }
                        }
                    }
                    // **那条贯穿的横线画在这里 —— 横跨左右两列**（2026-09-26）。
                    //
                    // 用户：「分割线（贯穿左侧、右侧）」。原先它挂在右列那个 `VStack` 上，
                    // 所以只从两列之间那道竖线开始往右走；左列顶上那条是侧栏自己另一条、
                    // 另一个 y，两条接不上。挂在**装着两列的 `ZStack`** 上就只有一个来源，
                    // 从左边缘一直到右边缘是同一根线。两列的页头都按
                    // `contentColumnHeaderRuleY` 排版，所以内容仍然正好从线下开始。
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                            .offset(y: NotchSupport.contentColumnHeaderRuleY)
                    }

                    // 窗口顶栏那几颗按钮。压在两列**之上**：右边三颗（收起侧栏 /
                    // 收回刘海 / 全屏），左边一颗（收起侧栏）。用户 2026-09-26：
                    // 「窗口右上角加三个按钮……顶部左侧也要一个『隐藏侧边栏』入口，
                    // 用户在左边和右边都能点到」。
                    //
                    // **不放进任何一个内容页的页头。** 三个页头在右端各有一排自己的
                    // 按钮（复制全文 / 打开 / 摄像头·屏幕·语速），而这一排三颗要长在
                    // 三页都有的同一个位置上 —— 塞进页头就要改三个页头、还要让它们
                    // 各自记得留出这么宽的一条，只要有一页忘了，`复制全文` 就会被
                    // 这一排压住点不动，而且屏幕上完全看不出来是被谁压的。
                    //
                    // 纵向落在 `sheetHeaderTopInset`（40）那条留白里：面板顶边就是
                    // 屏幕顶边，0 会钻到菜单栏底下，而 40 往下就是各页页头——这一排
                    // 不进那条带子，所以它既不挤走页头，也不会和刘海那条状态带
                    //（32 高）打架。
                    // **左上角那颗「收起侧栏」已经删掉**（2026-09-26 晚）：用户把这颗按钮
                    // 排进了侧栏第 1 行（「最上面一行从左到右分别是：折叠按钮、设置按钮…」），
                    // 所以它由侧栏自己画，不再浮在面板角上。右侧窗口那一排里那颗还在
                    // —— 两颗的动作本来就是同一个。
                        // 一颗按钮在左边、右边各出现一次。两份都靠这个 frame 贴到
                        // ZStack 的对应边缘上（ZStack 是 `.topLeading` 对齐，所以
                        // 靠右那一份必须自己撑满再右对齐）。
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    HStack(spacing: 6) {
                        sidebarCollapseButton
                        hideSheetButton
                        // **最外那颗的右上角更圆**（用户：「因为咱们这个主窗口是有圆角的，所以
                        // 你这个对应的展开的按钮，它的右上角这个圆角应该更大一点…就是不要让他
                        // 这个按钮显示到外面」）—— 它落在面板 36pt 的顶角圆弧里，外角跟着圆一点
                        // 才像同一个轮廓的一部分，而不是一个方角戳在弧线上。
                        fullScreenToggleButton
                            .clipShape(
                                UnevenRoundedRectangle(topLeadingRadius: DS.CornerRadius.medium,
                                                       bottomLeadingRadius: DS.CornerRadius.medium,
                                                       bottomTrailingRadius: DS.CornerRadius.medium,
                                                       topTrailingRadius: 16,
                                                       style: .continuous)
                            )
                    }
                    .padding(.trailing, Self.cornerControlInset)
                    .padding(.top, Self.cornerControlTopInset)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
        }
        .onAppear {
            // 「管理角色…」（三页共用那条模式条上的入口）要打开设置里的角色页 ——
            // 只有这里知道怎么开，所以把动作装给那个模型一次。
            cardChatPreferences.openRoleSettingsAction = {
                selectedSettingsPage = .voiceChatRoles
                showsSettings = true
            }
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
        // **卡片绑定的会话要回到它那张卡片。** 语音 / 视频现在是卡片的两个模式，所以一场
        // 跑着的会话属于某张卡片 —— 把用户丢到旧的那个「语音聊天」分区（那一页不归任何
        // 卡片）等于让他在一个跟这场会话无关的页面里看着它跑。
        if let binding = voiceChatController.boundCardIdentity {
            agentSessionManager.selectedSidebarSection =
                binding.cardKind == .mainLoop ? .conversations : .agents
            return
        }
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

    // MARK: - 窗口顶栏那几颗按钮

    /// 这一排到面板左右边缘 / 上边缘的距离。
    ///
    /// 18 而不是内容列那 12：面板的 `HomeSpaceSheetShape` 顶角是 36pt 圆角，
    /// 而这一排 30pt 高的按钮落在最上面那条留白里 —— 贴到 12 的话，最外侧那颗的
    /// 上角正好落在圆角弧外面，会被裁掉一角（不报错，只是缺一块）。
    ///
    /// 5 是它们在那条 40pt 留白里的纵向位置：下方紧挨着各页页头（用户的要求是
    /// 「高度不要太矮也不要太高——它们下方紧挨着其它文字和按钮，不能把下面的内容
    /// 挤走」），所以这一排既不进页头带、也不去挤它。
    /// 值在 `NotchSupport` 里 —— **侧栏顶上那两行也读同一个数**（两处各存一份必然漂）。
    private static var cornerControlInset: CGFloat { NotchSupport.cornerControlInset }

    /// 语音页的角色清单离面板底边多远 —— 正好在**输入框那一行之上**。
    /// 那一行 + 输入框大约 130pt 高，再加一点缝。
    private static let rolePanelBottomInset: CGFloat = 160
    private static let cornerControlTopInset: CGFloat = 5

    /// 「收起侧栏」——纯图标，左右各一颗，动作完全相同。
    ///
    /// 用户 2026-09-26：右边那颗「只有图标，没有名称、没有文字」，左边那颗
    /// 「同样是纯图标」。一颗按钮一个定义、两处放，避免左右两颗哪天改得不一样。
    private var sidebarCollapseButton: some View {
        NotchBarActionButton(
            systemImage: "sidebar.left",
            isHighlighted: isSessionSidebarCollapsed,
            help: isSessionSidebarCollapsed ? "展开侧栏" : "收起侧栏（只留图标）"
        ) {
            setSessionSidebarCollapsed(!isSessionSidebarCollapsed)
        }
    }

    /// 「隐藏整个窗口」——把面板收回刘海。动作就是 `collapseAction`，与 Esc /
    /// 点面板外 / 设置页的「关闭」同一条路，不另开一条收起路径。
    private var hideSheetButton: some View {
        NotchBarActionButton(
            systemImage: "chevron.up",
            help: "把窗口收回刘海"
        ) {
            collapseAction()
        }
    }

    /// 「展开 / 收缩」——全屏与刘海下方小窗之间切。文案与图标都跟着状态走，
    /// 所以按下去之前就能看出下一次会变成哪一档。
    private var fullScreenToggleButton: some View {
        let isFullscreen = panelModel.isSheetFullscreen
        return NotchBarActionButton(
            title: isFullscreen ? "收缩" : "展开",
            systemImage: isFullscreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
            isHighlighted: isFullscreen,
            help: isFullscreen ? "收缩回刘海下方的小窗" : "展开到全屏"
        ) {
            toggleFullScreenAction()
        }
    }

    private func setSessionSidebarCollapsed(_ isCollapsed: Bool) {
        SoundEffectPlayer.shared.play(.sidebarButton)
        isSessionSidebarCollapsed = isCollapsed
        // 立刻落盘，不等退出：这是个「下次打开还是这样」的偏好，而面板随时会收起
        // （那时这个视图整棵被拆掉）。见属性上的注释 —— 这一条刻意没走 AppSettings。
        UserDefaults.standard.set(isCollapsed, forKey: Self.sessionSidebarCollapsedDefaultsKey)
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
    // MARK: - 音色（2026-09-26 从输入框那行搬到页头）
    //
    // 用户：「音色按钮放在复制原文按钮的左侧」—— 仓库里没有「复制原文」，
    // 页头右上角那颗是「复制全文」，所以音色就插在它左边。
    // 搬家的理由不是排版：音色是**播报**的属性，而播报属于整条会话，
    // 不属于某一次输入。
    /// 音色弹窗开着没有。
    @State private var isVoicePickerPresented = false
    /// 临时对话（阶段 4）：它自己的会话，**不碰主对话的任何状态**。
    @StateObject private var temporaryConversation = TemporaryConversationModel()
    /// 克隆音色（打开弹窗时拉一次；拉不到就只显示系统音色 + 一行说明）。
    @State private var customVoicesForPicker: [CustomVoice] = []
    @State private var voicePickerFailureText: String?
    /// 试听代次：换一个音色试听就作废上一段（与「音色查看」页同一个做法）。
    @State private var voicePreviewGeneration = 0

    /// 「音色」——点开选择这一条回复用哪个音色（用户：「点击后展开弹窗，根据当前
    /// 接入的语音合成服务展示支持的音色」；服务商就是百炼，音色表就是 `VoiceCatalog`）。
    /// 样式照着旁边那颗「复制全文」写（同一个 34pt 高、10pt 圆角、同样的底），
    /// 因为它现在就在它左边，两颗不一样高会很难看。
    private var voiceChip: some View {
        Button {
            isVoicePickerPresented.toggle()
            if isVoicePickerPresented { loadCustomVoicesForPickerIfNeeded() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                Text(currentVoiceDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isVoicePickerPresented ? DS.Colors.success : .white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isVoicePickerPresented ? 0.14 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isVoicePickerPresented
                                  ? DS.Colors.success.opacity(0.5) : Color.clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("选择回复用哪个音色（默认用设置里配的那个）")
    }

    /// 那一格显示什么字：选了就显示它的名字，没选就显示「音色」。
    private var currentVoiceDisplayName: String {
        guard let voiceID = companionManager.replyVoiceOverride else { return "音色" }
        if let systemVoice = VoiceCatalog.threeStageVoices.first(where: { $0.id == voiceID }) {
            return systemVoice.displayName
        }
        if let nickname = VoiceLibraryStore.nickname(forCustomVoiceID: voiceID) {
            return nickname
        }
        return "音色"
    }

    private func loadCustomVoicesForPickerIfNeeded() {
        guard customVoicesForPicker.isEmpty else { return }
        Task { @MainActor in
            do {
                customVoicesForPicker = try await CustomVoiceLibraryClient.listCustomVoices()
                voicePickerFailureText = nil
            } catch {
                voicePickerFailureText = "克隆音色没拉下来：\(error.localizedDescription)"
            }
        }
    }

    /// 音色弹窗。系统音色来自 `VoiceCatalog`（**当前合成模型支持的**那些），
    /// 克隆音色来自云端列表 —— 与「设置 → 音色查看」读的是同一批数据。
    private var voicePickerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("音色")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 4)
                Button(action: { isVoicePickerPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("收起音色列表")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    voicePickerSectionLabel("系统音色")
                    ForEach(VoiceCatalog.threeStageVoices) { voice in
                        voicePickerRow(voiceID: voice.id,
                                       model: currentSpeechModelID,
                                       displayName: voice.displayName)
                    }

                    voicePickerSectionLabel("克隆音色")
                    if let voicePickerFailureText {
                        Text(voicePickerFailureText)
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else if customVoicesForPicker.isEmpty {
                        Text("还没有克隆音色（「设置 → 音色查看 → 声音克隆」可以做一个）")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(customVoicesForPicker) { voice in
                            // `CustomVoice` 只有 id / targetModel / createdAt / status
                            // —— 官方那边**不存备注**，所以显示名只能取本地昵称，没有再退回 id
                            //（与「设置 → 音色查看」同一套三级回落）。
                            voicePickerRow(
                                voiceID: voice.id,
                                model: voice.targetModel.isEmpty ? currentSpeechModelID : voice.targetModel,
                                displayName: VoiceLibraryStore.nickname(forCustomVoiceID: voice.id) ?? voice.id
                            )
                        }
                    }

                    // 「用默认」——把覆盖清掉，回到设置里配的那个。
                    voicePickerRow(voiceID: nil, displayName: "默认（设置里那一个）")
                }
            }
            .frame(maxHeight: 220)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
    }

    private func voicePickerSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.40))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// 试听用的合成模型 = 「模型」页里 👄 那个（与「音色查看」页同一处取值，
    /// 包括那条 `?? BailianConfiguration.Models.textToSpeech` 回落）。
    private var currentSpeechModelID: String {
        ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole?.modelID
            ?? BailianConfiguration.Models.textToSpeech
    }

    private func voicePickerRow(voiceID: String?, model: String = "", displayName: String) -> some View {
        let isSelected = companionManager.replyVoiceOverride == voiceID
        return HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark" : "circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.success : .white.opacity(0.25))
                .frame(width: 12)

            Text(displayName)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let voiceID {
                Button(action: {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    previewVoice(voiceID, model: model)
                }) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("试听")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            SoundEffectPlayer.shared.play(.sidebarButton)
            companionManager.replyVoiceOverride = voiceID
        }
    }

    /// 试听：走「设置 → 音色查看」同一条链 —— `VoicePreviewService` 合成（结果进
    /// `VoicePreviews/` 缓存）+ `CompanionManager.playVoicePreview` 播放。
    ///
    /// 代次计数与那一页同义：**换一个音色试听 = 停掉上一段**，而不是两段叠在一起。
    /// （自己再写一条播放通路的话，两处会各自漂。）
    private func previewVoice(_ voiceID: String, model: String) {
        companionManager.stopVoicePreview()
        voicePreviewGeneration += 1
        let generation = voicePreviewGeneration
        Task { @MainActor in
            do {
                let appSettings = AppSettingsStore.snapshot()
                let audioData = try await VoicePreviewService.previewAudioData(
                    engine: .threeStage,
                    voice: voiceID,
                    model: model.isEmpty ? currentSpeechModelID : model,
                    speechRate: appSettings.speechPlaybackRate,
                    speechVolumePercent: appSettings.speechPlaybackVolumePercent,
                    styleInstruction: "")
                guard generation == voicePreviewGeneration else { return }
                try await companionManager.playVoicePreview(wavData: audioData)
            } catch {
                guard generation == voicePreviewGeneration else { return }
                voicePickerFailureText = "试听失败：\(error.localizedDescription)"
            }
        }
    }

    /// 对话页分割线之上那一行 —— **只剩模式条**（用户 2026-09-26）。
    ///
    /// 他这一条削掉了三件东西：标题（「图文模式下有一个标题，在分合线上面，把这个标题也
    /// 删掉，也就是右侧不需要显示标题」）、「复制全文」（「把『复制全文』按钮删掉」）、
    /// 以及那枚活动动画（它和刘海那条带子上的是同一个状态，重复）。
    ///
    /// 留下的只有：**共用的模式条**（角色 + 文本/图文/语音/视频），以及**图文模式特有的
    /// 音色** —— 他说「音色在语音跟视频下面，因为语音跟视频的音色其实显示在分割线下面；
    /// 但图文的音色显示在上面分割线上面这一行，因为它比较特殊，没有这么多模式」。
    /// 这一页就是图文 / 文本两种模式，所以音色恒在这一排的最右。
    private var topBar: some View {
        CardChatModeBar(cardID: activeCardID ?? "",
                        cardKind: activeCardKind,
                        trailingAccessory: AnyView(voiceChip),
                        preferences: cardChatPreferences)
    }
}

// MARK: - Settings area

/// The settings pages embedded in the sheet, drawn to the target
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
            // The large bold page title. 「‹ 返回」 used to sit above it; the
            // user moved that pill down to this column's bottom-left
            // (2026-09-23), so the title is now the first thing here.
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
