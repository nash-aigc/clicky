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

    /// 一张卡片的高度。用户 2026-09-26 先要「增加两倍」（40 → 80），看过之后说
    /// 「这个高度有点大了，我觉得再缩小个 30%」→ 80 × 0.7 = **56**。
    private static let cardRowHeight: CGFloat = 56

    /// 卡片右侧那颗通话按钮的边长 —— 卡片 80 减去上下各 4 的边距，所以它**贴着**
    /// 卡片的上/下边缘（用户要求"上边缘、下边缘和右边缘尽可能小"）。
    private static let callButtonSize: CGFloat = 48

    /// 每张卡片的聊天模式 —— 卡片右侧那颗「通话」读它（高亮与否），点它写它。
    @ObservedObject private var cardChatPreferences = CardChatPreferenceModel.shared

    /// 鼠标停在哪张卡片上（纯界面状态）。**卡片的"亮"表达的是"可以点"**，
    /// 不是"这一张是当前的" —— 见 `cardRow` 里那段。
    @State private var hoveredCardID: String?

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

    /// 「角色」那一行：点一下直接跳到设置里的**角色编辑页**（新建 / 改名 / 写提示词）。
    ///
    /// 用户 2026-09-26 晚上点名要它回来（白天他删过一次）：「第 2 行再最左侧增加一个按钮，
    /// 叫角色，对应的关系就是在设置页面里面这个角色」。所以它只做一件事：**去设计角色**；
    /// 语音 / 视频模式下**选用**哪个角色在卡片页头上（`CardChatModeBar`）。
    var openRoleSettingsAction: () -> Void = {}

    /// 第 1 行那颗「折叠」（收起侧栏）。动作住在窗口控制器里 —— 侧栏只负责把点击报上去。
    var toggleSidebarCollapseAction: () -> Void = {}
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
            // **分割线之上有两行按钮**（用户 2026-09-26 的最后一轮）：
            //
            //   第 1 行：设置 · 折叠 · 历史 · 添加
            //   第 2 行：角色 · 复盘 · 录音
            //   ──────────────────────────────  ← 那条横线（横跨两列）
            //
            // 他把原来钉在左下角那三颗（设置 / 历史 / 复盘）**全搬上来了**，理由是
            // 「其实分割线上面有两行」—— 下面那一整块因此空出来给卡片列表。
            // 四颗 / 三颗我都让它们**等宽**：并排读起来才是一排按钮，而不是几个长短不一的字。
            sidebarTopButtonRows

            // **卡片从那根线下面 10pt 开始**（用户 2026-09-26：「左侧卡片跟上面的风格线
            // 重叠了，再往下来一点」）。
            //
            // 写成"从线的 y 倒推"而不是一个写死的数：两行按钮只占 4 + 30 + 8 + 30 = 72，
            // 而线在 80 —— 差额就是这里要补的高度。将来谁动了按钮高度或线的位置，卡片都还在
            // 同一个相对位置上。
            Color.clear
                .frame(height: max(0, NotchSupport.contentColumnHeaderRuleY + 10
                                   - Self.topButtonRowsHeight - 4))

            cardArea

            Spacer(minLength: 0)
        }
        // 完全不透明（用户 2026-09-23：「整个弹出窗口调整为完全不透明，现在
        // 是透明状态」）。原来这里是 `Color.black.opacity(0.35)` 叠在面板地面
        // 上，合成出来正好是 surface3 的 #101014 —— 换成不透明的同一个色，
        // 侧栏观感不变，透出来的壁纸没了。
        .background(DS.Colors.surface3)
    }

    // MARK: - 分割线之上的两行按钮

    /// 两行按钮的总高度（第 1 行 + 间距 + 第 2 行）—— 卡片区从那之后开始。
    /// **30，不是 34**：用户给的参照是「右侧这个展开的按钮」—— 窗口右上角那颗
    /// 「展开到全屏」，它是 30 高（`NotchBarActionButton` 的那一档）。两行合起来
    /// 4（上边距）+ 30 + 8 + 30 = 72，正好在那条线（80）之上留出 8pt。
    private static let topButtonHeight: CGFloat = 30

    private static var topButtonRowsHeight: CGFloat {
        topButtonHeight * 2 + topButtonRowSpacing
    }
    private static let topButtonRowSpacing: CGFloat = 8

    private var sidebarTopButtonRows: some View {
        VStack(spacing: Self.topButtonRowSpacing) {
            // 第 1 行：**设置 · 折叠 · 历史 · 添加**。
            //
            // 「设置按钮要放在上面这一行，放在折叠的左侧」（他的补充）—— 所以设置在最左，
            // 折叠第 2。折叠那颗以前是**窗口级**画在面板左上角的，现在搬进这一行：
            // 它就该和这些按钮排在一起，而不是浮在它们上面（浮着的那颗已经删掉，
            // 右侧那颗窗口级的「收起侧栏」还在，两颗动作本来相同）。
            HStack(spacing: 6) {
                // **折叠在最左，设置第 2**（用户 2026-09-26：「左侧顶部第一行最左侧应为折叠
                // 按钮（当前写错了），第二个是设置」—— 上一轮他说"设置放在折叠的左侧"，
                // 这一轮更正回来了）。
                sidebarTopButton(title: "折叠", isOn: false) {
                    SoundEffectPlayer.shared.play(.notchRevealed)
                    toggleSidebarCollapseAction()
                }
                sidebarTopButton(title: "设置", isOn: showsSettings) {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    showsSettings = true
                }
                sidebarTopButton(title: "历史", isOn: false) {
                    SoundEffectPlayer.shared.play(.notchRevealed)
                    openArchiveAction()
                }
                sidebarTopButton(title: "添加", isOn: false) {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    sessionsModel.createSession()
                    agentSessionManager.selectedSidebarSection = .conversations
                }
            }

            // 第 2 行：**角色 · 复盘 · 录音**。
            //
            // 「角色」是他这一轮点名要回来的（上一轮他删过一次）：它对应**设置里的角色页**
            //（「对应的关系就是在设置页面里面这个角色」）—— 也就是设计角色的地方；
            // 语音 / 视频模式下**选用**哪个角色在卡片页头上，两条路各管一件事。
            HStack(spacing: 6) {
                sidebarTopButton(title: "角色", isOn: false) {
                    SoundEffectPlayer.shared.play(.notchRevealed)
                    showsSettings = false
                    openRoleSettingsAction()
                }
                sidebarTopButton(title: "复盘", isOn: false) {
                    SoundEffectPlayer.shared.play(.notchRevealed)
                    showsSettings = false
                    cardModel.openReviewAgent(agentSessionManager: agentSessionManager)
                }
                sidebarTopButton(title: "录音", isOn: false) {
                    SoundEffectPlayer.shared.play(.recordingEditorOpened)
                    openRecordingSettingsAction()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    /// 上面那两行里的一颗：**等宽、等高**（`.frame(maxWidth: .infinity)` 让同一行的几颗
    /// 平分宽度），高度取 `contentHeaderControlHeight` —— 与右列那一排完全相同（用户：
    /// 「这三个按钮的高度都要再增大一点，跟右侧这个展开的按钮相同就可以了」）。
    private func sidebarTopButton(title: String,
                                  isOn: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // **只有名称、没有图标**（用户 2026-09-26：「左侧边栏的按钮全部显示为名称，
            // 不使用图标，以便压缩宽度」）—— 两个字的标签比"图标 + 间距 + 文字"窄一截，
            // 侧栏缩到 240 之后靠它才放得下四颗。
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundColor(isOn ? DS.Colors.success : .white.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: Self.topButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isOn ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isOn ? DS.Colors.success.opacity(0.5) : Color.white.opacity(0.12),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(title == "折叠" ? "收起侧栏（只留一条图标栏）" : title)
    }

    // MARK: - 卡片区（2026-09-26）

    /// 卡片列表。搜索接到 `cardModel.searchQuery`（卡片标题或它的任务命中）。
    private var cardArea: some View {
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
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                }
            }
        }
    }

    /// 一张卡片：标题 + 状态点 +（仅主循环卡片）「设为默认」。
    private func cardRow(_ card: AgentCardModel.Card) -> some View {
        // **三档**：选中（右列正在显示它）> 悬停（可以点）> 普通。
        //
        // 用户 2026-09-26 的两句话合起来才是完整需求：先是「我点击的时候它才需要高亮…
        // 但现在是持续高亮，这是错误的」，随后是「点击时没有高亮选中效果」—— 所以他要的是
        // **点出来的那张要明显亮着**（选中态），而不是"两张都淡淡地亮"。
        let isSelectedCard = isCurrent(card)
        let isHoveredCard = hoveredCardID == card.id
        return HStack(spacing: 8) {
            Circle()
                .fill(card.kind == .mainLoop ? DS.Colors.accent : Color(red: 0.55, green: 0.78, blue: 0.55))
                .frame(width: 6, height: 6)
                .opacity(1)

            Text(card.title)
                .font(.system(size: 13.5, weight: .semibold))
                // 标题也跟着亮 / 暗（见下面那段"选中的那张要明显不同"）：
                // 只高亮底和边、字还是同一个亮度，两张卡片看着仍然是一对。
                .foregroundColor(.white)
                .lineLimit(1)

            if card.kind == .claudeCode {
                Text("Claude Code")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            Spacer(minLength: 4)

            // **「设为默认」在左，「通话」在最右**（用户 2026-09-26：「把右侧的收藏按钮放在
            // 通话按钮的左侧，把通话按钮放在右侧」）。只出现在主循环卡片上 —— 用户明确
            // 要求「新建的 Claude Code 类型卡片不可设为默认」，兜底那条线不是「我的主对话」。
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
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(card.isDefault ? 0.10 : 0.05)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(card.isDefault
                      ? "这条是默认主对话：屏幕快捷键发出去的问题进它"
                      : "设为默认：屏幕快捷键发出去的问题进这一条主对话")
            }

            // **「通话」**（用户 2026-09-26：「左侧卡片的右侧，分别添加（通话的图标按钮），
            // 点击后=自动切换成（语音：全双工语音模式），也能在设置页面设置（全双工、
            // 三段式，等音色设置）」）。
            //
            // 它做的三件事：把这张卡片的模式切到**语音**、把引擎备成**全双工语音**、
            // 然后切到这张卡片（右列随之显示语音页）。**不自动连接** —— 他说的那一下是
            // 「切换成」，开麦留给他按页头那颗「连接」。引擎与音色都能在「设置 → 角色」
            // 里改（那一页的聊天节就是干这个的）。
            callButton(card)
        }
        // **一张卡片就该长得像卡片**（用户 2026-09-26：「应该设计成一个卡片的样式吧？
        // 或者是你把它这个单行的样式高度大一点，现在都是不太方便点击」）。
        // 加高到 40pt 并给它一层底：单行 22pt 的行高在侧栏里既难点中，也读不出
        //「这一块是同一张卡片」—— 下面那四栏是它的内容。
        // **卡片高度翻倍**（用户 2026-09-26：「左侧边栏的两个卡片高度再增加，高度增加两倍，
        // 方便用户点击」）：40 → 80。左右内边距分开写 —— 右侧只留 4，因为通话按钮要
        // **尽可能大、贴着卡片的上/下/右边缘**（下一条要求）。
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(height: Self.cardRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // **选中的那张要与另一张明显不同**（用户 2026-09-26：「现在这两个卡片样式一样，
        // 应该让它们不一样：用户选中哪张卡片，哪张卡片背景跟边缘高亮，另一张卡片就是暗色，
        // 用来区分」）。原来是 0.10 / 0.05 两档白 —— 在深色底上几乎看不出差别（截图里两张
        // 卡片确实长得一样）。现在拉开成**亮面 + accent 边**对**暗面 + 几乎无边**，
        // 标题与状态点也跟着亮 / 暗。
        // **一张卡片要看得清、也要看得出"我点了哪张"**（用户 2026-09-26：「当前颜色太浅，
        // 看不清」「点击时没有高亮选中效果」「样式偏丑」）。
        //
        // 三档的取值都拉开：普通用一块**比侧栏地面亮的卡面**（`surface1`，不是压暗的黑），
        // 悬停再亮一档，**选中用 accent 底 + accent 边** —— 一眼能分出"我点的是这张"。
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelectedCard
                      ? DS.Colors.accent.opacity(0.22)
                      : (isHoveredCard ? DS.Colors.surface2
                                       : DS.Colors.surface1.opacity(0.85)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelectedCard
                              ? DS.Colors.accent.opacity(0.85)
                              : (isHoveredCard ? Color.white.opacity(0.16)
                                               : Color.white.opacity(0.07)),
                              lineWidth: isSelectedCard ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(isSelectedCard ? 0.35 : 0), radius: 8, y: 2)
        .onHover { hovering in
            hoveredCardID = hovering ? card.id : (hoveredCardID == card.id ? nil : hoveredCardID)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            SoundEffectPlayer.shared.play(.notchRevealed)
            cardModel.open(card, sessionsModel: sessionsModel, agentSessionManager: agentSessionManager)
        }
    }

    /// 这张卡片是不是**右列正在显示的那张** —— 选中态由它决定。
    ///
    /// 上一轮我把这个判定连同它的高亮一起删了（当时把"常亮"理解成多余的），而用户这一轮
    /// 说「点击时没有高亮选中效果」—— 所以它回来了：**点出来的那张就该一直亮着**，
    /// 这既是"我点了哪张"的回执，也是"右列在显示谁"的指示。
    private func isCurrent(_ card: AgentCardModel.Card) -> Bool {
        switch card.kind {
        case .mainLoop:
            return sessionsModel.activeSessionID?.uuidString == card.entityID
        case .claudeCode, .review:
            return agentSessionManager.selectedAgentID?.uuidString == card.entityID
        }
    }

    /// 卡片右侧那颗「通话」。
    ///
    /// 它自己不认识引擎：模式写进设置、引擎由 `VoiceChatController.prepareCallForCard`
    /// 备好（那一步里顺序很讲究，见那里的注释），最后切到这张卡片。
    private func callButton(_ card: AgentCardModel.Card) -> some View {
        let isCalling = cardChatPreferences.mode(forCardID: card.entityID, kind: card.kind) == .voice
        return Button {
            SoundEffectPlayer.shared.play(.sidebarButton)
            cardChatPreferences.setMode(.voice, forCardID: card.entityID)
            voiceChatController.prepareCallForCard(cardID: card.entityID, cardKind: card.kind)
            cardModel.open(card, sessionsModel: sessionsModel, agentSessionManager: agentSessionManager)
        } label: {
            // **正方形 + 圆角、图形更大、贴着上/下/右边缘**（用户 2026-09-26：「卡片里的
            // 通话按钮改成正方形加圆角的形式，里面的按钮图形要变大。按钮的上边缘、下边缘和
            // 右边缘尽可能小，让按钮在卡片里尽可能大，方便用户点击」）。
            // 所以它按卡片高度撑满，不再是 20pt 的小圆圈。
            Image(systemName: "phone.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(isCalling ? DS.Colors.success : .white.opacity(0.5))
                .frame(width: Self.callButtonSize, height: Self.callButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(isCalling ? 0.14 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isCalling
                                      ? DS.Colors.success.opacity(0.5)
                                      : Color.white.opacity(0.10),
                                      lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("跟它通话：切到语音模式（全双工语音）。引擎与音色在「设置 → 角色」里改")
    }

    // 这里曾经有一个 `isCurrent(_:)`（判断"这张卡片是不是当前正在显示的那张"）——
    // 2026-09-26 用户要求卡片的亮色表达**点击**而不是"当前"，它就随那个判断一起删了。
    // 哪张卡片是当前的由右列的内容本身回答，不需要侧栏再标一遍。

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
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 10)
                    Text(column.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                    Text("\(tasks.count)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(.white.opacity(0.55))
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

    /// **左下角一行三颗：设置 · 历史 · 复盘**（用户 2026-09-26：「左侧底部分别是
    /// （设置、历史、复盘，显示在同一行）」）。
    ///
    /// 这一行换过好几次：账号卡 → 「设置/归档」并排 → 竖着三行（设置/历史/录音）。
    /// 现在回到**并排**，但要读成"一条清单"的那三件事仍然在：设置（去设置）、
    /// 历史（去归档页）、复盘（去复盘 agent）。**「录音」挪到顶上那条带子的右端**了
    /// （用户：「录音按钮放在左侧边栏，顶部的右侧，靠右对齐」），**「角色」删掉了**
    /// （用户：「左侧的角色按钮删除，这是之前的设计思路，现在不需要了」）。
    ///
    /// 三颗等宽（`HStack` + `maxWidth: .infinity`）：等宽才读得出"并排"，
    /// 否则文字长短不同、右缘参差，又变回三个各自为政的按钮。
    private var bottomActionRow: some View {
        HStack(spacing: 4) {
            NotchBarActionButton(
                title: "设置",
                systemImage: "gearshape",
                isHighlighted: showsSettings,
                help: "设置"
            ) {
                SoundEffectPlayer.shared.play(.sidebarButton)
                showsSettings = true
            }

            NotchBarActionButton(
                title: "历史",
                systemImage: "archivebox",
                isHighlighted: false,
                help: "以前的主对话与它们的任务"
            ) {
                SoundEffectPlayer.shared.play(.notchRevealed)
                openArchiveAction()
            }

            NotchBarActionButton(
                title: "复盘",
                systemImage: "chart.line.uptrend.xyaxis",
                isHighlighted: false,
                help: "跟复盘 agent 聊：它读的是复盘文件夹里的材料"
            ) {
                SoundEffectPlayer.shared.play(.notchRevealed)
                showsSettings = false
                cardModel.openReviewAgent(agentSessionManager: agentSessionManager)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
