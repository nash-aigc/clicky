//
//  VoiceChatSessionView.swift
//  Wanna
//
//  The 语音聊天 content column — what the sheet shows when the sidebar's
//  语音聊天 section is active. Every visual is cloned from AgentSessionView's
//  transcript styles (bubble geometry, composer field, auto-scroll), so the
//  content columns read as one family. The voice-chat-specific parts:
//
//    · the header carries this page's title and the three per-connection
//      choices — 模式 (三段式 / 全双工语音 / 全双工全模态), 屏幕, 摄像头;
//    · 「连接 / 挂断」 lives on the SIDEBAR's role row instead, at its right
//      edge. Clicking a role only selects it; the button beside it starts (or
//      ends) the session. Keeping the two apart is what fixed the bug where
//      connection state appeared to jump between role cards, and putting the
//      button on the row is the user's own 2026-09-23 request — the pointer
//      travel from "which role" to "connect" is a few pixels;
//    · the transcript carries everything the user SAYS as outgoing bubbles,
//      not just typed text;
//    · the composer sends the typed line into the running session as a normal
//      turn — it only sends while connected, and a draft typed before then is
//      kept, not swallowed.
//
//  The sheet's own top bar is not drawn on this page any more (the user asked
//  for one title instead of two, and for the ✕ to go) — this header takes its
//  slot, at `sheetHeaderTopInset`.
//

import AppKit
import SwiftUI

struct VoiceChatSessionView: View {

    @ObservedObject var controller: VoiceChatController

    /// **逐字变化的那份文字自己是一个可观察对象，所以这里要单独订阅它。**
    ///
    /// 订阅 `controller` 只会让这个视图响应控制器自己的 `@Published` —— 而文字已经
    /// 不住在那里了（见 `displayText(for:)` 与 `VoiceChatStreamingTextStore`）。
    /// 不显式订阅的话，卡片会在第一个 delta 之后就不再更新。
    ///
    /// 这一条订阅**只落在这个视图上**，所以逐字重算的范围是内容列，而不是整个面板。
    @ObservedObject private var streamingAnswerTextStore: VoiceChatController.VoiceChatStreamingTextStore

    init(controller: VoiceChatController,
         cardID: String? = nil,
         cardKind: CardKind = .mainLoop) {
        self.controller = controller
        self.cardID = cardID
        self.cardKind = cardKind
        self.streamingAnswerTextStore = controller.streamingAnswerTextStore
    }

    /// **这一页此刻属于哪张卡片**（2026-09-26）。
    ///
    /// nil = 不从卡片进来（旧的「语音聊天」分区，侧栏那颗「角色」走的路）—— 那一页脖子上
    /// 没有卡片，所以不画模式条，聊天类型仍然由页头那个分段控件决定。
    /// 有值时：模式条取代那个分段控件（`语音`/`视频` 两个模式就是那两种聊天类型），
    /// 而且阶段 3/4 会把「这段会话的记录 + 角色提示词」组装进系统提示词、把回话写回这条会话。
    let cardID: String?
    let cardKind: CardKind

    /// 每张卡片的模式与角色 —— 只读它来决定"现在是不是视频模式"这类事。
    @ObservedObject private var cardChatPreferences = CardChatPreferenceModel.shared

    @State private var composerFieldIsFocused = false
    @State private var composerDraft: String = ""
    /// 卡片主题（设置 → 交互）。快照进 @State，保存设置时靠
    /// `.wannaAppSettingsChanged` 重读，界面立刻换主题，不用重启。
    @State private var answerCardStyle: AnswerCardStyle = AppSettingsStore.snapshot().answerCardStyle

    /// The composer's 展开 button (user's request): the field grows to 30% of
    /// the content column and collapses back to three lines.
    @State private var isComposerExpanded = false
    /// The content column's height, measured off the root view — the sheet's
    /// height is the user's own, so the 30% figure has to be measured.
    @State private var contentColumnHeight: CGFloat = 0
    /// 整列的**宽度**，同样是量出来的。
    ///
    /// 所有浮层（模式、语速、音色）的宽度与落点都从这里算 —— 以前它们是写死的
    /// 像素偏移（`+ 240`、`110`），列一变宽就和触发它的按钮错位，右边还空出一条。
    /// 用户 2026-09-24 的原话：「右侧太窄了，不应该留空白……提前找到应该如何设计，
    /// 如何自适应窗口的宽度和高度」。
    @State private var contentColumnWidth: CGFloat = 0

    /// 哪一行的**预设下拉**开着（nil = 都没开）。两行各一个下拉，所以按行记。
    @State private var activePresetRow: VoiceChatEngine?
    /// 哪一行的**音色面板**开着（nil = 都没开）。音色按钮下移到两行行尾之后，
    /// 一个面板服务一行 —— 它显示的就是那一行模型的音色表。
    @State private var activeVoiceRow: VoiceChatEngine?

    /// 页头上**可以被浮层贴住**的那几颗控件，外加输入框那一行。
    ///
    /// 输入框不是"被贴住"的对象，它是浮层**不许越过的下边界**：音色面板的高度上限
    /// 要从"面板落点"到"输入框顶边"这段距离里算，所以它的位置也得量出来。
    /// 音色按钮现在有两个（全双工行、三段式行各一个），所以锚点也分成两个。
    private enum HeaderAnchor: String, Hashable {
        case speed, voiceDuplex, voiceThreeStage, presetDuplex, presetThreeStage, composer

        /// 某个模式那一行的音色按钮对应的锚点。
        static func voice(for engine: VoiceChatEngine) -> HeaderAnchor {
            engine == .duplexVoice ? .voiceDuplex : .voiceThreeStage
        }

        /// 某个模式那一行的预设按钮对应的锚点。
        static func preset(for engine: VoiceChatEngine) -> HeaderAnchor {
            engine == .duplexVoice ? .presetDuplex : .presetThreeStage
        }
    }

    /// 收集页头控件在**整列坐标系**里的 frame。每颗按钮用
    /// `.background(headerAnchorReporter(_:))` 报一次，`conversationColumn`
    /// 上挂 `onPreferenceChange` 收进 `headerControlFrames`。
    private struct HeaderAnchorPreferenceKey: PreferenceKey {
        static var defaultValue: [HeaderAnchor: CGRect] = [:]
        static func reduce(
            value: inout [HeaderAnchor: CGRect],
            nextValue: () -> [HeaderAnchor: CGRect]
        ) {
            value.merge(nextValue()) { _, reported in reported }
        }
    }

    /// 音色面板**内容**的自然高度。
    ///
    /// `ScrollView` 给内容的高度提议是"不限"，所以内容按自己的理想高度排 —— 在它
    /// 的 `.background` 里量到的就是这个数。面板高度 = min(它, 上限)，于是"内容少
    /// 面板就矮、内容多就封顶转滚动"是量出来的，不是猜的。
    private struct VoicePanelContentHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// 音色面板里**不滚动**的那部分（分类行 + 提示行）的高度。
    ///
    /// 也要量：面板的高度上限是"面板落点到输入框顶边"这段距离，而滚动区能占的是
    /// 这段距离**减去**这部分。写成一个常量会在有人改面板顶部那两行时悄悄漂掉。
    private struct VoicePanelChromeHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// `conversationColumn` 的坐标空间名。浮层的 `.offset` 与页头按钮上报的
    /// frame 都在这个空间里，两者相减才有意义。
    private static let columnCoordinateSpace = "voiceChatContentColumn"
    /// 模型折叠区里，三栏（识别/理解/表达）中哪一栏的模型菜单正开着。
    @State private var activeModelMenu: PipelineModelSlot?
    /// 模式下拉（分隔线上最右那颗）保持浮层。
    @State private var isModeMenuOpen = false
    /// 语速下拉（摄像头左侧那颗）。
    @State private var isSpeedMenuOpen = false
    /// 音色面板：该账号的克隆音色（打开面板时才加载）。
    @State private var customVoices: [CustomVoice] = []
    @State private var isLoadingCustomVoices = false
    @State private var previewingVoiceID: String?
    /// 音色面板顶部的两个分类。
    ///
    /// 用户 2026-09-24：「现在的弹窗其实已经完全符合我的需求，因为它已经分开了流式、
    /// 非流式、克隆音色，但**不应该这样分类，应该按照系统音色、克隆音色来分类**，
    /// 卡片的样式不用变。至于流式、非流式，这个不重要」—— 所以从三类收敛成两类，
    /// 「流式/非流式」那层（它描述的是识别模型，不是音色）整层去掉。
    private enum VoicePanelCategory: String, CaseIterable, Identifiable {
        case system = "系统音色"
        case cloned = "克隆音色"

        var id: String { rawValue }
    }
    @State private var voicePanelCategory: VoicePanelCategory = .system
    /// 收藏写入后**强制重画**：星星状态读的是 VoiceLibraryStore，SwiftUI 不会
    /// 因为一个非观察对象的变化重画 —— 没有这个代次，点★会「没有任何效果」
    /// （用户 2026-09-24 实测报的就是这个）。通知到达 +1，格子全部重算。
    @State private var favouriteRevision = 0
    /// 下拉里鼠标悬停在哪一行 —— 自绘的行要自己画悬停态。
    @State private var hoveredMode: VoiceChatEngine?
    @State private var hoveredMenuItemID: String?

    /// 页头那几颗控件量出来的位置（整列坐标系）。浮层贴着触发它的那颗按钮，
    /// 靠的就是这份数据。
    @State private var headerControlFrames: [HeaderAnchor: CGRect] = [:]
    /// 音色面板内容量出来的自然高度。初值给一个常见高度，免得第一帧塌成 0
    /// （量到真值后立刻改过来，见 `voicePanelMaximumScrollHeight`）。
    @State private var voicePanelContentHeight: CGFloat = 320
    /// 音色面板里不滚动的那部分量出来的高度（分类行 + 提示行）。
    @State private var voicePanelChromeHeight: CGFloat = 70

    var body: some View {
        // 右键角色卡片 → 编辑：**右侧这一列就地换成角色设置页**（用户的原话：
        // 「右侧的对话页面就变成一个设置页面」）。顶上给一条返回，否则进去就出不来。
        if controller.isShowingRoleEditor {
            roleEditorColumn
        } else {
            conversationColumn
        }
    }

    /// 角色编辑形态：一条返回 + 编辑页本身。
    private var roleEditorColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    controller.isShowingRoleEditor = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("返回对话")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(DS.Colors.success)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }

                Text("角色")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
            .padding(.top, NotchSupport.sheetHeaderTopInset)
            .padding(.bottom, 8)

            VoiceChatRoleSettingsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationColumn: some View {
        // 浮层是**同级**的第二个孩子，不是 `.overlay` 的内容。ZStack 后一个孩子画在
        // 前一个上面，所以浮层仍然盖在对话流之上；为什么不用 `.overlay` 见
        // `positionFloatingPanel` 的说明。
        ZStack(alignment: .topLeading) {
            columnBody
            floatingPanelLayer
        }
        // 浮层的落点都在这个坐标空间里算：页头按钮上报的 frame 与浮层的
        // 落点用同一套坐标。
        .coordinateSpace(name: Self.columnCoordinateSpace)
        .onPreferenceChange(HeaderAnchorPreferenceKey.self) { headerControlFrames = $0 }
    }

    /// 这一列的正文：页头 + 预览条 + 对话流 + 输入框。
    private var columnBody: some View {
        VStack(spacing: 0) {
            header
            // 摄像头 / 屏幕两个预览框就在页头下面、对话流上面 —— 用户定的位置：
            // 「顶部固定一条，对话从它下面开始」。
            //
            // 它自己决定占多高：常规形态是一条（每个框 108pt）；某个框全屏时它吃满
            // 剩余高度，下面的 `transcriptFlow` 就自动让位 —— 这正是用户要的
            // 「全屏时占据右侧部分的全部，只保留最下面的输入框」。
            VoiceChatPreviewStrip(controller: controller)
            // 全屏预览时对话流**整个让位**（用户：「只保留最下面的输入框」）。
            // 只是压扁的话，滚动区会缩到几行高，反而比藏起来更难用。
            if !controller.isAnyPreviewFullScreen {
                transcriptFlow
            }
            composerRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 点这一列任意位置只负责收起展开着的浮层。**不再聚焦输入框** —— 那一条
        // 按用户的决定删除了（与另外两页同一处收敛，见 `NotchHomeView` 的注释）。
        .contentShape(Rectangle())
        .onTapGesture {
            activeVoiceRow = nil
            activePresetRow = nil
            isSpeedMenuOpen = false
        }
        // 收藏写入后强制重画音色面板（星星状态不经过任何 @Published）。
        .onReceive(NotificationCenter.default.publisher(for: .wannaVoiceLibraryChanged)) { _ in
            favouriteRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .wannaAppSettingsChanged)) { _ in
            answerCardStyle = AppSettingsStore.snapshot().answerCardStyle
        }
        .background(
            GeometryReader { geometryProxy in
                Color.clear
                    .onAppear {
                        contentColumnHeight = geometryProxy.size.height
                        contentColumnWidth = geometryProxy.size.width
                    }
                    .onChange(of: geometryProxy.size) { _, newSize in
                        contentColumnHeight = newSize.height
                        contentColumnWidth = newSize.width
                    }
            }
        )
    }

    /// 三块浮层（预设 / 语速 / 音色）。它们互斥，所以竖直方向只会出现一块。
    @ViewBuilder
    private var floatingPanelLayer: some View {
        if let activePresetRow {
            positionFloatingPanel(
                presetDropdown(activePresetRow),
                anchor: .preset(for: activePresetRow),
                panelWidth: Self.presetDropdownWidth,
                keepsColumnMargins: false
            )
        }
        if isSpeedMenuOpen {
            positionFloatingPanel(
                speedMenuDropdown,
                anchor: .speed,
                panelWidth: Self.speedMenuDropdownWidth,
                keepsColumnMargins: false
            )
        }
        if let activeVoiceRow {
            positionFloatingPanel(
                voicePickerPanel(for: activeVoiceRow),
                anchor: .voice(for: activeVoiceRow),
                panelWidth: voicePanelWidth,
                keepsColumnMargins: true
            )
        }
    }

    /// 把一个浮层放到它锚定的那颗按钮下面，而且**不撑开、不遮挡任何东西**。
    ///
    /// · **落点是量出来的**（`floatingPanelTopOffset` / `floatingPanelLeftOffset`），
    ///   不是写死的像素偏移 —— 用户 2026-09-24：「如何自适应窗口的宽度和高度」。
    /// · **定位靠 `Spacer`，不靠 `.offset`**。`.offset` 是绘制期的位移、不产生布局，
    ///   而定位要的是真实几何。`Spacer` 只占位、**不参与命中测试**，所以浮层之外的
    ///   地方照旧点得到下面的对话流和输入框 —— 这也是它必须包在 `VStack`/`HStack`
    ///   里、而不是用 `.contentShape(Rectangle())` 铺满整列的原因。
    /// · 浮层是 `columnBody` 的 **ZStack 同级孩子**，不是它的 `.overlay` 内容。
    ///   这一条来自一次**没有解决问题**的试验，写在这里是为了下次别重复走：
    ///   语音面板里的 `ScrollView` 收不到滚轮事件（探针实测内容高 3075、滚动区
    ///   448，确实该能滚；而同一套滚轮事件在「对话」页的滚动区推得动内容）。
    ///   试过把它从 `.overlay` + `.offset` 换成 `.overlay` + `.padding`、换成
    ///   ZStack 同级、去掉面板上的 `contentShape`/`onTapGesture`、给内容加
    ///   `fixedSize` —— **四条路都还是滚不动**，所以这条限制的原因仍未定，见
    ///   `开发经验/10-踩过的坑.md`。ZStack 只是顺带消掉了 `.overlay` 布局下
    ///   分类行与滚动区之间那道 ~73pt 的空白，视觉上更对。
    private func positionFloatingPanel<PanelContent: View>(
        _ panel: PanelContent,
        anchor: HeaderAnchor,
        panelWidth: CGFloat,
        keepsColumnMargins: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: floatingPanelTopOffset(anchor: anchor))
            HStack(alignment: .top, spacing: 0) {
                Spacer().frame(width: floatingPanelLeftOffset(
                    anchor: anchor,
                    panelWidth: panelWidth,
                    keepsColumnMargins: keepsColumnMargins
                ))
                panel
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Header (role + 模式 / 屏幕 / 摄像头)

    /// 页头：左边是角色名与连接状态，右边是这一条连接的三个选择 —— 模式、
    /// 屏幕、摄像头。
    ///
    /// **连接/挂断按钮不在这里**，它在左下角角色卡片的右侧（用户 2026-09-23
    /// 的第 5 条：「把连接按钮放在左侧边角色卡片的右侧部分，做成大一点的长方形
    /// 圆角形式。这样用户点击角色就可以选择是否连接，鼠标移动距离会非常小。
    /// **不要放在右上角**」）。同一段话的末尾又提到「标题右侧是一个很长的连接
    /// 和挂断按钮」——两句冲突，编号那一条更明确，按编号做。
    ///
    /// 右边这三个控件都是"下一次连接生效"：桥只有一条 `connect` 命令，没有
    /// 运行时切换设备的接口，所以 `.help` 里逐条写明了。模式菜单改的是
    /// `selectedMode`（角色卡片的连接按钮会带上它），屏幕/摄像头改的是 快捷键
    /// 页里同一批设置键 —— 同一份存储，两处入口不会显示成不同的值。
    private var header: some View {
        VStack(spacing: 0) {

            // ── 模式行（2026-09-26）────────────────────────────────────────
            // 从卡片进来时，最上面这排是共用的 `[角色][文本][图文][语音][视频]` ——
            // 用户把它钉在了「右侧分割线上面，左侧对齐」，而这一带正是代码里叫
            // 「分割线**上方**」的那一格（见下面那段注释）。
            //
            // **它取代了原来那个 `[视频聊天 | 语音聊天]` 分段控件**：那两个按钮本来就是
            // 这条分流，现在「语音」「视频」两个模式就是它，多出来的是「文本」「图文」——
            // 点它们会换页（回到这一页时聊天类型又跟着回来）。
            if let cardID {
                CardChatModeBar(cardID: cardID,
                                cardKind: cardKind,
                                onModeSelected: { _ in syncChannelToCardChatMode() },
                                preferences: cardChatPreferences)
            }

            // ── 分割线**上方**（用户 2026-09-24 的第三次重排）──────────────
            //   左：`[视频聊天 | 语音聊天]` 分段控件 + 当前模式的绿色文字
            //       （从卡片进来时那一格已经搬到上面那排模式里，这里只剩音色）
            //   右：摄像头 · 屏幕 · 语速（靠右，依次）
            //
            // **语速不受分流影响**（用户明确要求：它是全局的，任何分流都不改它），
            // 所以它只是位置在这，行为与聊天类型无关。
            HStack(spacing: 8) {
                // 不从卡片进来时（旧的「语音聊天」分区）才需要它 —— 那条路上没有模式条。
                if cardID == nil {
                    channelSegmentedControl
                }

                // **连接放最左侧**（用户 2026-09-26：「（语音、视频）模式，连接通话的按钮，
                // 放最左侧，右侧是其他的」）。
                connectButton

                currentVoiceLabel

                Spacer(minLength: 8)

                // **语音模式自动隐藏摄像头 / 屏幕**（用户：「语音聊天，自动隐藏（屏幕、
                // 摄像头）的按钮」）：语音那一档永远没有画面，留两颗灰按钮只是占地方。
                // 判据用的是模式自己的能力位，不是再看一遍聊天类型 —— 一处定义。
                if showsDeviceToggles {
                    deviceToggleButton(
                        title: "摄像头",
                        systemImage: "video",
                        isOn: controller.isCameraEnabled,
                        isSupported: controller.selectedModeSupportsCamera,
                        unsupportedHelp: controller.videoInputDisabledReason ?? "当前设置用不了摄像头",
                        help: "摄像头（下次连接生效）"
                    ) {
                        controller.setCameraEnabled(!controller.isCameraEnabled)
                    }

                    deviceToggleButton(
                        title: "屏幕",
                        systemImage: "rectangle.on.rectangle",
                        isOn: controller.isScreenSharingEnabled,
                        isSupported: controller.selectedModeSupportsScreenSharing,
                        unsupportedHelp: controller.videoInputDisabledReason ?? "当前设置用不了屏幕",
                        help: "屏幕（下次连接生效）"
                    ) {
                        controller.setScreenSharingEnabled(!controller.isScreenSharingEnabled)
                    }
                }

                speedMenuButton
                    .background(headerAnchorReporter(.speed))
            }
            .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
            .frame(height: NotchSupport.contentColumnHeaderBandHeight, alignment: .center)

            // ── 分割线**下方**：两行，各是一整套选择 ──────────────────────
            //   全双工行：一个模型包办识别/理解/表达
            //   三段式行：识别 / 理解 / 表达 三个位置
            // 两行都常驻；**没被选中的那一行右侧留空**（用户：「如果用户选择的模式
            // 不是全双工，右侧就不要显示任何模型，保持留空状态」），音色按钮也置灰。
            VStack(spacing: 6) {
                modeRow(.duplexVoice)
                modeRow(.threeStage)
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .onAppear {
            // 设置页是整窗独占的，所以"改完设置回到这一页"一定走一次
            // onAppear —— 这里重读一次，两颗开关就不会拿着上一个模式的值。
            controller.reloadDeviceSwitches()
            syncChannelToCardChatMode()
            // 卡片页上这一页显示的就是**那张卡片的历史**（用户：「所有的模式，必须使用完全
            // 相同的对话历史，无缝切换不同的对话模式」）—— 还没按「连接」也该看得到。
            if let cardID {
                controller.showCardHistory(cardID: cardID, cardKind: cardKind)
            }
        }
        // 模式条上换了模式（语音 ↔ 视频）：聊天类型跟着走。**用 `onChange` 而不是
        // 只在点按钮时同步**，因为模式也可能在别处被改（另一页点的那一下），
        // 而这一页这时正挂在屏幕上。
        .onChange(of: currentCardChatMode) { _, _ in
            syncChannelToCardChatMode()
        }
    }

    /// 摄像头 / 屏幕两颗要不要画。
    ///
    /// 用户 2026-09-26：「语音聊天，自动隐藏（屏幕、摄像头）的按钮」。判据取模式的
    /// `carriesImages` —— 从卡片进来时这一页只可能是语音 / 视频，所以实际效果就是
    /// **视频才画、语音不画**；不从卡片进来时保持原样（那一页由聊天类型分段控件决定）。
    private var showsDeviceToggles: Bool {
        guard let mode = currentCardChatMode else { return true }
        return mode.carriesImages
    }

    /// 这张卡片此刻选的是哪种模式（不从卡片进来时是 nil）。
    private var currentCardChatMode: CardChatMode? {
        guard let cardID else { return nil }
        return cardChatPreferences.mode(forCardID: cardID, kind: cardKind)
    }

    /// 把「语音 / 视频」两个模式落到 `controller.selectedChannel` 上，**并把卡片选的角色
    /// 同步到控制器**。
    ///
    /// 用户：「语音聊天与视频聊天分别使用对应的全双工三段式模式」—— 所以两个模式就是
    /// 这条分流本身。**语音那一档永远不开画面**这条闸门住在聊天类型上
    ///（`VoiceCatalog.capability`），所以让模式驱动聊天类型，闸门才是自动生效的。
    ///
    /// 角色也要同步：页头的音色、两行预设、以及按「连接」时读的都是控制器的角色。不同步
    /// 的话，界面显示的是一张卡片选的角色、连上去用的却是上一次那个 —— 而这两件事在
    /// 用户眼里是同一件事。
    private func syncChannelToCardChatMode() {
        guard let cardID else { return }
        let roleID = roleIDForConnect
        if controller.selectedRoleID != roleID {
            controller.selectRole(roleID)
        }
        guard let channel = currentCardChatMode?.voiceChatChannel else { return }
        controller.alignChannelForCardMode(channel)
    }

    /// **连接 / 连接中 / 挂断** —— 这一页唯一能开始一场会话的入口。
    ///
    /// 它原先住在侧栏角色行的右端（用户第 5 条要的"鼠标移动距离小"）。2026-09-26 的
    /// 卡片化改造把侧栏那一列换成了卡片区，角色列表只剩收起态那条细栏 —— 于是整条路上
    /// **`connectToRole` 一个调用点都没有了**：语音聊天能打开、能选角色，但永远连不上。
    /// 而「语音 / 视频」两个模式必用这一步，所以它搬到这一页的页头（那一排的最右端），
    /// 一键三态，不再有第二个地方能连。
    private var connectButton: some View {
        switch controller.connectionPhase {
        case .connected:
            return AnyView(headerActionButton(
                title: "挂断",
                systemImage: "phone.down.fill",
                tint: Color(red: 0.95, green: 0.42, blue: 0.40),
                help: "断开这一场语音聊天（也可以点刘海右侧那颗红色电话）"
            ) {
                controller.disconnectCurrentSession()
            })
        case .connecting:
            return AnyView(headerActionButton(
                title: "连接中…",
                systemImage: "ellipsis",
                tint: Color(red: 0.98, green: 0.73, blue: 0.14),
                help: "正在建立连接",
                isEnabled: false,
                action: {}
            ))
        case .idle:
            return AnyView(headerActionButton(
                title: "连接",
                systemImage: "phone.fill",
                tint: DS.Colors.success,
                help: "开始这一场语音聊天"
            ) {
                controller.connectToRole(
                    roleIDForConnect,
                    // 从卡片进来才带绑定：它决定系统提示词里有没有这段会话的记录、
                    // 以及回话写回哪张卡片。
                    cardBinding: cardID.map {
                        VoiceChatController.CardVoiceBinding(cardID: $0, cardKind: cardKind)
                    }
                )
            })
        }
    }

    /// 连接用哪个角色：**卡片选了哪个就用哪个**（没有卡片时回落到侧栏那份选择）。
    ///
    /// 卡片侧的选择住在 `AppSettings`（每张卡片各记各的），而控制器只认一个
    /// `selectedRoleID` —— 所以连接这一下必须显式把它交给控制器，否则两个人各说各话。
    private var roleIDForConnect: String {
        guard let cardID, let mode = currentCardChatMode else {
            return controller.selectedRoleID ?? VoiceChatRoleStore.defaultRole().id
        }
        return cardChatPreferences.resolvedRole(forCardID: cardID, kind: cardKind, mode: mode).id
    }

    /// 页头那颗动作按钮（连接 / 连接中 / 挂断）。形状与 `deviceToggleButton` 同一套
    /// —— 它们并排站在一起，圆角与高度必须是同一个来源。
    private func headerActionButton(title: String,
                                    systemImage: String,
                                    tint: Color,
                                    help: String,
                                    isEnabled: Bool = true,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isEnabled ? tint : tint.opacity(0.55))
            .padding(.horizontal, Self.headerControlHorizontalPadding)
            .frame(height: Self.headerControlHeight)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isEnabled ? tint.opacity(0.18) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isEnabled ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor()
        .help(help)
    }

    // MARK: - 聊天类型分段控件 + 当前模式

    /// `[视频聊天 | 语音聊天]` —— 绿色滑块跟着选择移动。
    ///
    /// 它是一条**分流**（用户 2026-09-24：「这两个按钮的功能是分流，它们的选择会影响
    /// 其他所有按钮的样式，但不影响语速」）：切到语音聊天，全双工那一行只剩全双工语音
    /// 预设，画面两个按钮一起置灰。
    private var channelSegmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(VoiceChatChannel.allCases) { channel in
                channelSegment(channel)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// 分段控件里的一格。拆成独立函数是因为整段塞进 `ForEach` 的 ViewBuilder 里
    /// 会让类型检查器超时（实测：`unable to type-check this expression in reasonable time`）。
    private func channelSegment(_ channel: VoiceChatChannel) -> some View {
        let isSelected = controller.selectedChannel == channel
        return Button {
            controller.selectChannel(channel)
        } label: {
            Text(channel.displayName)
                .font(.system(size: Self.headerControlFontSize,
                              weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // 绿底上用深色字才有对比；未选中是白字。
                .foregroundStyle(isSelected ? Color.black.opacity(0.82) : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: Self.channelSegmentHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? DS.Colors.success : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// 分段控件右侧显示的**当前音色昵称**。
    ///
    /// 用户 2026-09-24 第二次调整：「在视频聊天、语音聊天按钮的右侧，**不要写模式了**，
    /// 因为现在模式被勾选出来已经能看得很清楚。右侧显示音色，把音色的昵称显示一下就好，
    /// 比如刘亦菲或者其他的人」—— 模式的选择态由下面两行的对勾表达，这里的位置让给音色。
    private var currentVoiceLabel: some View {
        HStack(spacing: 5) {
            // 用**声音的小符号**代替原来那道绿色竖线（用户 2026-09-24：「旁边不要用竖的
            // 绿线，应该增加一个音色的小符号，也就是声音的小符号」）。与「音色」按钮
            // 同一个 SF Symbol，读起来是一件事。
            Image(systemName: "waveform")
                .font(.system(size: Self.headerControlFontSize, weight: .medium))
            Text(currentVoiceNickname)
                .font(.system(size: Self.headerControlFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // **限宽**：克隆音色的 id 可能很长（用户实测 `qwen-aud…99220aa` 把「视频聊天」
        // 两个按钮挤成两行、把布局挤畸形）。给它一个上限，放不下就中部截断 ——
        // 右侧的摄像头/屏幕/语速三颗永远完整。
        .frame(maxWidth: 150)
        .foregroundStyle(DS.Colors.success)
    }

    /// 页头那个音色名 —— 就是**当前选中那一行**的昵称，走的同一份实现。
    private var currentVoiceNickname: String {
        voiceNickname(for: controller.selectedMode)
    }

    // MARK: - 模式两行（全双工 / 三段式）

    /// 一行模式：**选择按钮**（带对勾，不是下拉）+ **预设按钮** + 模型显示 + 行尾音色。
    private func modeRow(_ engine: VoiceChatEngine) -> some View {
        let isSelected = controller.selectedMode == engine
        let preset = controller.preset(for: engine)
        let capability = controller.capability(for: engine)

        return HStack(spacing: 6) {
            modeSelectButton(engine, isSelected: isSelected)
            presetMenuButton(engine, preset: preset, isSelected: isSelected)

            Spacer(minLength: 8)

            // **这一行选中的音色名**（用户 2026-09-26：「将任何模式中选中的音色，显示在对应
            // 的模式的音色按钮的左侧，比如：全双工、三段式，没有选中全双工，音色文字=暗色，
            // 选中后=绿色」）。
            //
            // 它取代了原来的「识别=理解=表达 / 识别｜理解｜表达」那两段说明文字 ——
            // 用户同一条要求里说「（识别、理解、表达）这个说明文字，全部删除，两行的说明
            // 文字，全部删除」。位置留给更有用的一件事实：**这一行接着会用哪个音色**。
            Text(voiceNickname(for: engine))
                .font(.system(size: Self.headerControlFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150)
                .foregroundStyle(isSelected ? DS.Colors.success : DS.Colors.textSecondary.opacity(0.5))

            voiceRowButton(engine, isSelected: isSelected, capability: capability)
                .background(headerAnchorReporter(
                    engine == .duplexVoice ? .voiceDuplex : .voiceThreeStage
                ))
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin + 4)
    }

    /// 模式选择按钮：点一下即选中，绿色 + 对勾（用户：「它是一个选择按钮，点击后立即
    /// 变绿，并显示对号或已选择符号」）。
    private func modeSelectButton(_ engine: VoiceChatEngine, isSelected: Bool) -> some View {
        Button {
            guard !isSelected else { return }
            controller.selectMode(engine)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(engine.displayName)
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DS.Colors.success : DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: Self.headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.success.opacity(0.16) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.success.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isSelected ? "当前就是\(engine.displayName)" : "切到\(engine.displayName)")
    }

    /// 预设按钮。名字之后跟着的模型由 `modeSummary` 显示。
    private func presetMenuButton(
        _ engine: VoiceChatEngine,
        preset: VoiceChatPreset,
        isSelected: Bool
    ) -> some View {
        let isOpen = activePresetRow == engine
        return Button {
            activePresetRow = isOpen ? nil : engine
            activeVoiceRow = nil
            isSpeedMenuOpen = false
        } label: {
            HStack(spacing: 5) {
                Text(preset.title)
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: Self.headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isOpen ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isOpen ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("这一行用哪个预设（每个预设 = 一组已验证的模型组合）")
        .background(headerAnchorReporter(.preset(for: engine)))
    }

    // MARK: - 预设下拉（每个预设 = 一组已验证的模型组合）

    /// 一行预设的清单。
    ///
    /// 排序由 `VoiceChatPresetStore` 定：**默认预设永远第一**，收藏的紧随其后，
    /// 其余按代码顺序（用户：「默认预设永远是第一个位置，这个不可以被改变」）。
    ///
    /// 每条预设是一张卡片：标题 + 备注 + 模型组合 + 价格/设备默认值。
    /// `isReady == false` 的（比如管线还没接的组合）灰掉并写明原因 —— 摆出来但点不动，
    /// 比藏起来更诚实：用户看得到"有哪些组合"，也知道哪一条还不能用。
    private func presetDropdown(_ engine: VoiceChatEngine) -> some View {
        VStack(spacing: 3) {
            ForEach(controller.presets(for: engine)) { preset in
                presetRow(preset, engine: engine)
            }
        }
        .padding(4)
        .frame(width: Self.presetDropdownWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .onTapGesture { }
    }

    private func presetRow(_ preset: VoiceChatPreset, engine: VoiceChatEngine) -> some View {
        let isActive = controller.selectedMode == engine && controller.currentPreset.id == preset.id
        let isHovered = hoveredMenuItemID == preset.id
        let isFavourite = VoiceChatPresetStore.isFavourite(preset.id)

        return Button {
            guard preset.isReady else { return }
            controller.selectPreset(preset)
            activePresetRow = nil
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isActive ? "checkmark" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? DS.Colors.accent : Color.white.opacity(0.25))
                    .frame(width: 12)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(preset.title)
                            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(preset.isReady ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                            .lineLimit(1)
                        if preset.isDefaultPreset {
                            Text("默认")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DS.Colors.textOnAccent)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(DS.Colors.accent.opacity(0.7)))
                        }
                        if isFavourite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.Colors.warning)
                        }
                    }
                    Text(preset.note)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 模型组合 —— 预设的全部内容就是它，所以直接列出来。
                    Text(presetModelSummary(preset))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(DS.Colors.success.opacity(preset.isReady ? 1 : 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)

                // 收藏（默认预设不给收藏 —— 它已经在第一位，收藏没有意义）。
                if !preset.isDefaultPreset {
                    Button {
                        VoiceChatPresetStore.toggleFavourite(forPresetID: preset.id)
                        favouriteRevision += 1
                    } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(isFavourite ? DS.Colors.warning : DS.Colors.textSecondary)
                            .frame(width: 26, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isFavourite ? "取消收藏" : "收藏（收藏的排在默认预设之后）")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered && preset.isReady ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!preset.isReady)
        .pointerCursor()
        .onHover { hovering in
            hoveredMenuItemID = hovering ? preset.id : nil
        }
    }

    /// 一条预设的模型组合（一行文字，够看和核对）。
    private func presetModelSummary(_ preset: VoiceChatPreset) -> String {
        if let duplexModelID = preset.duplexModelID {
            return duplexModelID
        }
        return [preset.recognitionModelID, preset.understandingModelID, preset.expressionModelID]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// 某一行的音色**昵称**（克隆音色显示用户起的名字，系统音色显示内置表里的中文名）。
    ///
    /// 两行各取各的：全双工那一行显示全双工会用哪个音色，三段式那一行显示三段式那个 ——
    /// 它们本来就是两套（`effectiveVoiceID(for:)` 走能力层）。
    private func voiceNickname(for engine: VoiceChatEngine) -> String {
        let voiceID = controller.effectiveVoiceID(for: engine)
        if let nickname = VoiceLibraryStore.nickname(forCustomVoiceID: voiceID), !nickname.isEmpty {
            return nickname
        }
        if let option = VoiceCatalog.systemVoices(for: engine, model: controller.voiceTableModelID(for: engine))
            .first(where: { $0.id == voiceID }) {
            return option.displayName
        }
        return voiceID
    }

    /// 行尾的音色按钮。
    ///
    /// **没选中这一行、或者这一行的模型族没有可用音色时，置灰不可点**
    /// （用户：「最右侧是音色，如果用户没有选择，这个音色按钮也不可以被点击，任何时候都这样」）。
    /// 判据是能力层的 `usableVoiceEngines` —— 与引擎读的是同一份。
    private func voiceRowButton(
        _ engine: VoiceChatEngine,
        isSelected: Bool,
        capability: VoiceCatalog.VoiceChatCapability
    ) -> some View {
        let isEnabled = isSelected && !capability.usableVoiceEngines.isEmpty
        let isOpen = activeVoiceRow == engine

        return Button {
            activeVoiceRow = isOpen ? nil : engine
            activePresetRow = nil
            isSpeedMenuOpen = false
            if isOpen == false { loadCustomVoicesForPanel() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                Text("音色")
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.85) : DS.Colors.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: Self.headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isOpen ? 0.16 : (isEnabled ? 0.08 : 0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isOpen ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!isEnabled)
        .help(voiceRowButtonHelp(isSelected: isSelected, capability: capability))
    }

    private func voiceRowButtonHelp(
        isSelected: Bool,
        capability: VoiceCatalog.VoiceChatCapability
    ) -> String {
        if !isSelected { return "先选中这一行才能改它的音色" }
        if capability.usableVoiceEngines.isEmpty {
            return capability.notes.first ?? "这一行的模型不支持自定义音色"
        }
        return "音色（跟着这一行的模型走）"
    }

    // MARK: - 浮层的自适应落点

    /// 一颗页头控件把自己的位置报上来。挂在 `.background` 上，所以**不参与布局**
    /// —— 加它不会让页头那一排的间距变一个点。
    private func headerAnchorReporter(_ anchor: HeaderAnchor) -> some View {
        GeometryReader { geometryProxy in
            Color.clear.preference(
                key: HeaderAnchorPreferenceKey.self,
                value: [anchor: geometryProxy.frame(in: .named(Self.columnCoordinateSpace))]
            )
        }
    }

    /// 浮层能用的宽度：整列宽度减去左右两条边距。
    private var floatingPanelAvailableWidth: CGFloat {
        max(0, contentColumnWidth - NotchSupport.contentColumnHorizontalMargin * 2)
    }

    /// 浮层的顶边：**触发它的那颗按钮的下边缘再往下 6pt**。
    ///
    /// 量到就用量到的；第一帧还没量到时退回几何算式 —— 两者相等（按钮在页头带子里
    /// 垂直居中），所以不会有跳一下。
    private func floatingPanelTopOffset(anchor: HeaderAnchor) -> CGFloat {
        guard let anchorFrame = headerControlFrames[anchor] else {
            return Self.modeMenuDropdownTopInset
        }
        return anchorFrame.maxY + 6
    }

    /// 浮层的左边缘：**右缘对齐触发它的那颗按钮的右缘**，再夹进整列之内。
    ///
    /// 夹取的**下界**分两种，因为两种浮层要跟的东西不一样：
    ///
    ///   · `keepsColumnMargins: true` —— 给吃满宽度的面板（音色）。它和页头、对话流
    ///     共用同一条页边距，所以夹到 `contentColumnHorizontalMargin`；取满宽度时
    ///     正好被夹到左边距上，右边也就不再留那条空白。
    ///   · `false` —— 给贴着按钮的窄下拉（模式 / 语速）。它只需要不出列，夹到 0 就够。
    ///     拿页边距当下界反而会把它从按钮底下推开：实测语速那颗按钮的右缘在列内
    ///     202pt 处，200pt 宽的下拉本该落在 2pt，被推到 12pt，和按钮错开 10pt。
    private func floatingPanelLeftOffset(
        anchor: HeaderAnchor,
        panelWidth: CGFloat,
        keepsColumnMargins: Bool
    ) -> CGFloat {
        let margin = NotchSupport.contentColumnHorizontalMargin
        let lowerBound: CGFloat = keepsColumnMargins ? margin : 0
        let upperBound = max(lowerBound, contentColumnWidth - margin - panelWidth)
        let anchorRightEdge = headerControlFrames[anchor]?.maxX ?? (contentColumnWidth - margin)
        return min(max(anchorRightEdge - panelWidth, lowerBound), upperBound)
    }

    /// 音色面板的宽度：**吃满整列的可用宽度**。
    ///
    /// 它内部是两列，每列都要放得下「名字 + ★ / 使用 / ▶ 三颗按钮」（约 230pt）。
    /// 贴着音色按钮右缘时面板只有 ~440pt，右边空出 ~120pt 而两列反而被挤到放不下。
    private var voicePanelWidth: CGFloat {
        floatingPanelAvailableWidth
    }

    /// 音色面板从落点往下**能用的**高度：到输入框那一行的顶边为止，再让开 8pt。
    ///
    /// 两个端点都是量出来的 —— 面板的落点（`floatingPanelTopOffset`）和输入框的顶边
    /// （页头锚点 `.composer`）。所以面板高度可调的窗口一变矮，这段高度跟着变，面板
    /// 自己就收窄，不会盖住输入框。写死一个数就会在某个窗口高度上盖住输入框。
    private var voicePanelAvailableHeight: CGFloat {
        // 还没量到输入框（第一帧）时按"整列都是可用的"算，量到之后立刻收紧。
        let composerTop = headerControlFrames[.composer]?.minY ?? contentColumnHeight
        return max(160, composerTop - floatingPanelTopOffset(anchor: .voice(for: activeVoiceRow ?? controller.selectedMode)) - 8)
    }

    /// 音色面板**滚动区**的高度上限，取两个约束里更紧的那个：
    ///
    ///   · 用户要求的 448（原 560 减 20%）；
    ///   · 上面那段可用高度减去不滚动的那部分（也是量出来的）。
    private var voicePanelMaximumScrollHeight: CGFloat {
        max(120, min(448, voicePanelAvailableHeight - voicePanelChromeHeight))
    }

    // MARK: - 表头下拉（识别 / 理解 / 表达 / 音色）

    /// 竖线分隔。用户 2026-09-24：「然后一条竖线分割」。
    private var headerSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 18)
    }

    /// 当前各栏的**生效值**（角色没单独配过 = 默认）。按钮上显示的是它。
    private var recognitionChoiceShortName: String {
        shortModelName(controller.currentRecognitionModelID)
    }
    private var understandingChoiceShortName: String {
        shortModelName(controller.currentUnderstandingModelID)
    }
    private var expressionChoiceShortName: String {
        shortModelName(controller.currentExpressionModelID)
    }
    private var currentVoiceShortName: String {
        controller.currentExpressionVoiceID
    }

    private func shortModelName(_ modelID: String) -> String {
        if modelID.contains("3.0-realtime") { return "流式3.0" }
        if modelID.contains("3.1-asr") { return "非流式3.1" }
        if modelID.contains("deepseek") { return "DeepSeek" }
        if modelID.contains("3.1-tts") { return "TTS 3.1" }
        // 全模态三个模型要能互相区分 —— 以前只有一个 omni，笼统的「全模态」
        // 就够了；现在三栏常驻、右侧是绿色短名，三个都显示「全模态」会分不清选的是谁。
        if modelID.contains("3.8-omni") { return "全模态3.8" }
        if modelID.contains("3.5-omni-plus") { return "全模态3.5+" }
        if modelID.contains("3.5-omni") { return "全模态3.5" }
        if modelID.contains("omni") { return "全模态" }
        return String(modelID.prefix(10))
    }

    /// 识别/理解/表达三个下拉共用的面板：一行一个模型，带**架构**与**价格**
    /// （用户 2026-09-24：「一定要标注模型的架构，这个事情极其重要」）。
    /// 全模态模式下三栏由同一个模型接管 —— 清单换成**全模态的三个模型**
    /// （用户 2026-09-24 指定补充），选中即写入角色的 `omniModelID`。
    // MARK: - 音色面板（双列）

    /// 音色下拉。**按行服务**：哪一行打开它，它显示的就是那一行模型的音色表
    /// （用户 2026-09-24：「每一个音色按钮都对应着相关模式的音色」）。收藏的排最前。
    private func voicePickerPanel(for engine: VoiceChatEngine) -> some View {
        VStack(alignment: .leading, spacing: Self.voicePanelRowSpacing) {
            // 面板里不滚动的那两行（分类行 + 提示行）成一组，量出它们的高度 ——
            // 面板的高度预算要扣掉这一组，见 `voicePanelMaximumScrollHeight`。
            VStack(alignment: .leading, spacing: Self.voicePanelRowSpacing) {
                voicePanelCategoryRow(for: engine)
                // 说明文字**只占一行**（用户 2026-09-24：「下面的说明文字，应该显示在一行
                // （禁止换行显示」）。放不下就尾部截断，不换行：换行会让这一行的高度跟着
                // 分类变（全双工那句最长），而它正属于面板「不滚动的那部分」——
                // `voicePanelChromeHeight` 量到几行，面板总高就跟着变，看上去就是高度在抖。
                Text(voicePanelHint(for: engine))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
            }
            .background(
                GeometryReader { chromeGeometryProxy in
                    Color.clear.preference(
                        key: VoicePanelChromeHeightPreferenceKey.self,
                        value: chromeGeometryProxy.size.height
                    )
                }
            )

            ScrollView {
                voiceCategoryContent(for: engine)
                    .id(favouriteRevision)
                    // 内容要**声明自己的理想高度**，别接受外面递进来的高度。
                    //
                    // 少了这一句，`ScrollView` 会把 frame 高度当作内容的高度：
                    // 卡片照旧铺满（它们的尺寸是固定的），但滚动区认为"内容正好
                    // 一屏"，于是**滚不动** —— 68 个音色里只有前 7 个够得着。
                    // 实测（2026-09-24）：同一套滚轮事件在「对话」页的滚动区能推
                    // 动内容，在这个面板上纹丝不动；加上这一句之后正常滚动。
                    .fixedSize(horizontal: false, vertical: true)
                    // 量内容自己的高度，量到的就是这个理想高度。
                    .background(
                        GeometryReader { contentGeometryProxy in
                            Color.clear.preference(
                                key: VoicePanelContentHeightPreferenceKey.self,
                                value: contentGeometryProxy.size.height
                            )
                        }
                    )
            }
            // **高度是量出来再封顶的，不是 `fixedSize`。**
            //
            // 这里原来写的是 `.fixedSize(horizontal: false, vertical: true)` 再加
            // `.frame(maxHeight: 448)`，那是个会糊满整个面板的写法：`fixedSize` 让
            // ScrollView 的**frame 等于内容的自然高度**（「流式」那一类 68 个音色、
            // 两列共 34 行 ≈ 1621pt），而后面那个 `frame(maxHeight:)` 只把**外框**
            // 定成 448 —— 它既不裁剪、也不改子视图的尺寸，于是内容以外框中心为准上下
            // 各溢出八百多点。
            //
            // 实测（2026-09-24，面板里点一下「流式」后读 AX 树）：音色格子的 y 一直
            // 排到 **−1179**，页头那一排按钮（y = 30）被整个盖住 —— 就是用户看到的
            // 「点击下拉菜单的其他按钮后，画面直接完全乱码，排版非常混乱」。
            //
            // 给 ScrollView 一个**确定的高度**（量到的内容高，封顶到
            // `voicePanelMaximumScrollHeight`），它自己就会滚动，也就没有溢出这回事。
            .frame(height: min(voicePanelContentHeight, voicePanelMaximumScrollHeight))

            if isLoadingCustomVoices {
                Text("正在读取克隆音色…")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
            }
        }
        .frame(width: voicePanelWidth)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        // 再上一道保险：面板内部无论怎么算错，都不许画到轮廓之外。悬停提示、
        // 阴影、内容全被这条裁掉，所以「乱码」在结构上不可能再发生。
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        // 面板自己的地盘要自己接住点击：不然点在面板的留白上会穿到下面那一列的
        // `onTapGesture`（那一下会顺手把面板收起来）。模式/语速两块下拉同理。
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .onTapGesture { }
        .onPreferenceChange(VoicePanelContentHeightPreferenceKey.self) { measuredContentHeight in
            // 0 是"还没量到"（内容被 `.id` 重建的那一帧），不能拿它把面板压成 0 高
            // —— 那会反过来让内容排不出来，永远停在 0。
            guard measuredContentHeight > 0 else { return }
            voicePanelContentHeight = measuredContentHeight
        }
        .onPreferenceChange(VoicePanelChromeHeightPreferenceKey.self) { measuredChromeHeight in
            guard measuredChromeHeight > 0 else { return }
            voicePanelChromeHeight = measuredChromeHeight
        }
    }

    /// 面板顶部那一行：两个分类（系统音色 / 克隆音色）+ 最右边"这一行真正会用的音色"。
    private func voicePanelCategoryRow(for engine: VoiceChatEngine) -> some View {
        HStack(spacing: 8) {
            ForEach(VoicePanelCategory.allCases) { category in
                let isSelected = voicePanelCategory == category
                Button {
                    voicePanelCategory = category
                } label: {
                    Text(category.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? DS.Colors.accent : DS.Colors.surface3)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer(minLength: 8)

            // **绿色标题显示的是能力层算出来的"真正会用的音色"**，不是角色里存的那个值。
            // 用户报的「选了没生效」在这里会立刻现形：显示的和引擎用的是同一个数。
            HStack(spacing: 4) {
                Rectangle()
                    .fill(DS.Colors.success)
                    .frame(width: 2, height: 12)
                Text(controller.effectiveVoiceID(for: engine))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.success)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    /// 面板顶部那行说明。**它同时是左右两列的"列头"**：那两个「男」「女」小标题已经
    /// 删掉了（用户 2026-09-24：「男女，删除，只保留注释就行，默认（左侧=男生，
    /// 右侧=女生）」），所以「左列男、右列女」这件事只剩这里能说。
    /// 整行只占一行（放不下就尾部截断，见调用处的 `.lineLimit(1)`）。
    private func voicePanelHint(for engine: VoiceChatEngine) -> String {
        switch engine {
        case .threeStage:
            return "左列男声，右列女声。系统音色 + 你自己的克隆音色（收藏的排最前）。"
        case .duplexVoice:
            return "全双工语音模型的系统音色，跟着这一行选的模型走。它没有克隆音色。"
        case .omni:
            return "全模态模型的内置音色，按模型代际分（3.5 系与 3.8 系各一组）。没有克隆音色。"
        }
    }

    @ViewBuilder
    private func voiceCategoryContent(for engine: VoiceChatEngine) -> some View {
        switch voicePanelCategory {
        case .system:
            systemVoiceContent(for: engine)
        case .cloned:
            clonedVoiceContent(for: engine)
        }
    }

    /// 「系统音色」：该行模型族自己的系统音色。
    ///
    /// 三段式是 3.1 TTS 的 68 个，按**男 / 女**分列（没有列头，靠上面那行说明）；
    /// 全双工 / 全模态是各自模型带的那几张表，直接铺网格。
    @ViewBuilder
    private func systemVoiceContent(for engine: VoiceChatEngine) -> some View {
        let voices = VoiceLibraryStore.orderedByFavourites(
            VoiceCatalog.systemVoices(for: engine, model: controller.voiceTableModelID(for: engine)),
            engine: engine
        )
        if engine == .threeStage {
            let maleVoices = voices.filter { $0.gender == "男" }
            let femaleVoices = voices.filter { $0.gender == "女" }
            HStack(alignment: .top, spacing: 6) {
                voiceGenderColumn(maleVoices, engine: engine)
                voiceGenderColumn(femaleVoices, engine: engine)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Self.voiceCardSpacing),
                    GridItem(.flexible(), spacing: Self.voiceCardSpacing)
                ],
                spacing: Self.voiceCardSpacing
            ) {
                ForEach(voices) { voice in
                    voiceCell(voice, engine: engine)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    /// 「克隆音色」：**只属于 3.1 TTS**。
    ///
    /// 用户 2026-09-24：「全双工语音模型或者全双工全模态……不能自定义音色，
    /// 或者说它们只有系统音色，不支持克隆音色」——所以在这一族里这一栏**明说为什么空**，
    /// 而不是显示一片空白让人以为加载失败。
    @ViewBuilder
    private func clonedVoiceContent(for engine: VoiceChatEngine) -> some View {
        if engine != .threeStage {
            Text("克隆音色只属于 3.1 TTS（三段式的「表达」）。全双工/全模态模型只能用它自带的系统音色。")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Self.voiceCardSpacing),
                    GridItem(.flexible(), spacing: Self.voiceCardSpacing)
                ],
                spacing: Self.voiceCardSpacing
            ) {
                ForEach(customVoices) { customVoice in
                    customVoiceCell(customVoice)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            if customVoices.isEmpty, !isLoadingCustomVoices {
                Text("这个账号下还没有克隆音色。去 设置 → 语音聊天 → 音色查看 → 声音克隆 里创建。")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
    }

    /// 一个性别列。**没有列头**（用户 2026-09-24 要求删掉），左列男、右列女由调用
    /// 顺序和上面那行说明决定。列内间距用 `voiceCardSpacing` —— 用户 2026-09-24：
    /// 「无论在哪个页面上，每个卡片的高度、宽度都固定，卡片与卡片之间的间距也固定」。
    private func voiceGenderColumn(_ voices: [VoiceOption], engine: VoiceChatEngine) -> some View {
        VStack(alignment: .leading, spacing: Self.voiceCardSpacing) {
            ForEach(voices) { voice in
                voiceCell(voice, engine: engine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func voiceCell(_ voice: VoiceOption, engine: VoiceChatEngine) -> some View {
        // 选中态取的是**能力层算出来的那个音色**（= 引擎真正会用的），不是角色里存的。
        let isSelected = controller.effectiveVoiceID(for: engine) == voice.id
        let isFavourite = VoiceLibraryStore.isFavourite(
            key: VoiceLibraryStore.favouriteKey(for: voice.id, engine: engine)
        )
        let isHovered = hoveredMenuItemID == voice.id

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(voice.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // ★ 和 ▶ 都做成**有边框的实体按钮**（用户 2026-09-24：
                // 「试听按钮和收藏按钮也太小了，都要同步增大」）。
                Button {
                    toggleVoiceFavourite(voice.id, engine: engine)
                } label: {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavourite ? DS.Colors.warning : DS.Colors.textSecondary)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    controller.setVoice(voice.id, for: engine)
                } label: {
                    Text("使用")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DS.Colors.accentText)
                        .frame(width: 34, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isSelected)
                Button {
                    auditionVoice(voice.id, engine: engine)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(previewingVoiceID != nil)
            }
            Text(voice.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        // **高度钉死**（用户 2026-09-24：「每个卡片的高度、宽度都固定」）：
        // 内容 = 上 9 + 按钮行 26 + 间距 4 + id 行 ~13 + 下 9 ≈ 61，取 62。
        // 所有分类的音色卡共用这一个数 —— 任何一行文字换行、字体微调都不会让
        // 某个分类的卡片悄悄变高，间距节奏在哪个页签里都一样。
        .frame(maxWidth: .infinity, minHeight: Self.voiceCardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected ? DS.Colors.accent.opacity(0.18)
                    : (isHovered ? Color.white.opacity(0.07) : DS.Colors.surface3)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { controller.setVoice(voice.id, for: engine) }
        .onHover { isHovered in
            hoveredMenuItemID = isHovered ? voice.id : nil
        }
        .help(isSelected ? "当前音色" : "点击选用 · ▶ 试听 · ★ 收藏")
    }

    private func customVoiceCell(_ customVoice: CustomVoice) -> some View {
        let isSelected = controller.currentExpressionVoiceID == customVoice.id
        let isFavourite = VoiceLibraryStore.isFavourite(
            key: VoiceLibraryStore.favouriteKey(for: customVoice.id, engine: .threeStage)
        )
        let displayName = VoiceLibraryStore.displayName(forCustomVoiceID: customVoice.id, cloudProvidedName: "")

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    toggleFavouriteForCustom(customVoice)
                } label: {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavourite ? DS.Colors.warning : DS.Colors.textSecondary)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    controller.setExpressionVoice(customVoice.id)
                } label: {
                    Text("使用")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DS.Colors.accentText)
                        .frame(width: 34, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isSelected)
                Button {
                    auditionVoice(customVoice.id, engine: .threeStage)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(previewingVoiceID != nil)
            }
            Text("克隆 · \(customVoice.targetModel)")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        // 与 `voiceCell` 同一个固定高度（用户 2026-09-24：「克隆音色卡片的间隙就
        // 比较大、比较长……每个卡片的高度、宽度都固定」）。
        .frame(maxWidth: .infinity, minHeight: Self.voiceCardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? DS.Colors.accent.opacity(0.18) : DS.Colors.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { controller.setExpressionVoice(customVoice.id) }
        .help("克隆音色 · 点击选用")
    }

    private func loadCustomVoicesForPanel() {
        guard controller.selectedMode != .omni, !isLoadingCustomVoices, customVoices.isEmpty else { return }
        isLoadingCustomVoices = true
        Task { @MainActor in
            defer { isLoadingCustomVoices = false }
            customVoices = (try? await CustomVoiceLibraryClient.listCustomVoices()) ?? []
        }
    }

    private func toggleVoiceFavourite(_ voiceID: String, engine: VoiceChatEngine) {
        _ = try? VoiceLibraryStore.toggleFavourite(
            key: VoiceLibraryStore.favouriteKey(for: voiceID, engine: engine),
            displayName: voiceID
        )
    }

    private func toggleFavouriteForCustom(_ customVoice: CustomVoice) {
        _ = try? VoiceLibraryStore.toggleFavourite(
            key: VoiceLibraryStore.favouriteKey(for: customVoice.id, engine: .threeStage),
            displayName: customVoice.id
        )
    }

    /// 试听。**用哪条合成路跟着那一行的族走**（三段式走用户配的合成模型、
    /// 全模态走 qwen3-tts-flash、全双工必须让实时模型自己说）—— 这与
    /// `VoicePreviewService` 里那张三路的表是同一件事，所以传 `engine` 而不是猜。
    private func auditionVoice(_ voiceID: String, engine: VoiceChatEngine) {
        guard previewingVoiceID == nil else { return }
        previewingVoiceID = voiceID
        Task { @MainActor in
            defer { previewingVoiceID = nil }
            if let audioData = try? await VoicePreviewService.previewAudioData(
                engine: engine,
                voice: voiceID,
                model: controller.voiceTableModelID(for: engine),
                speechRate: AppSettingsStore.snapshot().speechPlaybackRate,
                speechVolumePercent: AppSettingsStore.snapshot().speechPlaybackVolumePercent,
                styleInstruction: ""
            ) {
                try? await controller.speechSynthesizer.playPreviewWAVData(audioData)
            }
        }
    }

    // MARK: - 折叠区（2026-09-24 重排）

    /// 分隔线上的折叠开关。样式与其它页头按钮一致；激活时高亮。
    /// 音色按钮。原来是 `expanderButton(_:title:systemImage:)`，供四颗按钮共用；
    /// 模型三栏改成常驻、摄像头/屏幕改成开关之后，页头只剩这一颗"展开浮层"的
    /// 按钮，就着落成了现在这个样子（视觉与原来完全一致）。
    /// 分割线**下面常驻**的模型区：**三列固定宽度**（识别 | 理解 | 表达，中间分隔线）。
    /// 按钮宽度不随所选模型变化 —— 选中的模型名显示在**这一列的右侧**，
    /// 绿色标记（用户 2026-09-24：「按钮本身不会因为选中某个模型而改变大小」）。
    /// 点一列，下面就地展开这一列的模型清单（按 全双工语音/流式/非流式 分组）。
    /// **常驻**是用户 2026-09-24 的第二次重排：「把模型直接显示在分割线下面，
    /// 保持持续显示的状态」——不再有「模型」折叠开关。
    /// 三列中的一列。整列是一个按钮（点它开/关这一列的清单）；右侧是当前选中的
    /// 模型名 —— 绿色，且**不参与布局宽度**（超长就截断，列宽永远固定）。
    /// 全模态模式下三栏都是同一个模型（`currentOmniModelID`），点哪一栏展开的都是
    /// 全模态的清单。
    // MARK: - 语速（十档，全局 —— 直接写「说」页那一份设置）

    /// 十档语速。第 n 档对应的实际倍率在 0.75×~1.5× 之间线性分布 —— 与「说（播报）」
    /// 页的滑杆同一个范围（`AppSettings.speechPlaybackRate`，全局一份）。
    /// 用户 2026-09-24：「这个语速的选择直接影响设置页面的语速，它们之间是对应
    /// 关系，是全局的一个语速」。
    private static let speechSpeedLevels: [(level: Int, rate: Double)] = {
        (1...10).map { level in
            (level, 0.75 + Double(level - 1) * (1.5 - 0.75) / 9)
        }
    }()

    private var currentSpeedLevel: Int {
        let rate = AppSettingsStore.snapshot().speechPlaybackRate
        let level = Self.speechSpeedLevels.min(by: {
            abs($0.rate - rate) < abs($1.rate - rate)
        })?.level ?? 5
        return level
    }

    /// 语速按钮：样式与其它页头按钮一致，显示当前档位。
    private var speedMenuButton: some View {
        Button {
            isSpeedMenuOpen.toggle()
            activePresetRow = nil
            activeVoiceRow = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 11, weight: .medium))
                Text("语速 \(currentSpeedLevel)")
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isSpeedMenuOpen ? 180 : 0))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, Self.headerControlHorizontalPadding)
            .frame(height: Self.headerControlHeight)
            // **不许截断**（用户 2026-09-24：「语速按钮太小，导致按钮里的文字
            // 没有显示出来」）—— 宽度按内容来，不参与挤压。
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isSpeedMenuOpen ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isSpeedMenuOpen ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("十档语速，直接改全局「说（播报）」的语速")
    }

    /// 十档清单。选中的档位带勾；写入的是**全局** `speechPlaybackRate`，
    /// 「说」页的滑杆下一次打开就是同一个值 —— 两个入口、一份设置。
    private var speedMenuDropdown: some View {
        VStack(spacing: 2) {
            ForEach(Self.speechSpeedLevels, id: \.level) { entry in
                let isSelected = currentSpeedLevel == entry.level
                Button {
                    var settings = AppSettingsStore.snapshot()
                    settings.speechPlaybackRate = entry.rate
                    try? AppSettingsStore.save(settings)
                    isSpeedMenuOpen = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? DS.Colors.accent : Color.white.opacity(0.25))
                            .frame(width: 12)
                        Text("语速 \(entry.level)")
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Spacer(minLength: 0)
                        Text(String(format: "%.2f×", entry.rate))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hoveredMenuItemID == "speed\(entry.level)" ? Color.white.opacity(0.07) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .onHover { isHovered in
                    hoveredMenuItemID = isHovered ? "speed\(entry.level)" : nil
                }
            }
        }
        .padding(4)
        .frame(width: Self.speedMenuDropdownWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .onTapGesture { }
    }

    /// 模式选择：一颗自绘的按钮 + 一层自绘的下拉。
    ///
    /// 用户 2026-09-23：「在语音聊天页面三段式这个下拉菜单的按钮，你应该把每一个
    /// 下拉菜单的样式直接写好，不要让软件自动渲染……它应该跟按钮的样式差不多，就是
    /// 每一个按钮的高度应该再增大一点。你现在这个下拉菜单的样式特别丑。」原先用的是
    /// SwiftUI 的 `Menu`，它弹的是 AppKit 的 `NSMenu` —— 那一层的行高、圆角、悬停色、
    /// 内边距全部由系统画，SwiftUI 里没有任何一个修饰符能碰到它，所以要按用户的要求
    /// 把每一行"直接写好"，只能整颗换成自绘。
    ///
    /// 展开态持有在 `isModeMenuOpen`，浮层挂在**整列**上而不是挂在按钮上（见 `body`
    /// 的 `.overlay`）：VStack 里后画的兄弟盖在先画的上面，挂在页头里的浮层会被下面
    /// 的对话流整片盖住。
    /// 自绘的模式下拉：一行一个模式，行高比页头那三颗按钮**再高一点**
    /// （`modeMenuRowHeight`，用户要求「每一个按钮的高度应该再增大一点」），
    /// 行内是左勾 + 模式名。
    ///
    /// 面板底色用 `DS.Colors.surface2`：本仓库的立面层级是**反的**——卡片比地面更
    /// 深，这里照同一套来，再配一圈白描边与阴影，浮在对话流上时边界才清楚。
    /// 下拉里的一行。选中的那行带一颗 accent 勾并且文字加亮，悬停的那行有一层浅底
    /// —— 自绘的行没有系统给的任何状态，这三样都得自己画。
    /// 页头那颗设备开关：开启时是实底的绿，关闭时是描边。不支持的组合**禁用而
    /// 不隐藏** —— 隐藏的话换模式时页头会跳，而且用户分不清"这个模式没有这个
    /// 能力"和"这个功能没做"。
    private func deviceToggleButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        isSupported: Bool,
        unsupportedHelp: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let tint = isOn
            ? Color(red: 0.35, green: 0.85, blue: 0.55)
            : Color.white.opacity(0.85)

        let iconAndLabelColor: Color = isSupported ? tint : Color.white.opacity(0.3)
        let fillColor: Color = (isOn && isSupported) ? tint.opacity(0.16) : Color.white.opacity(0.08)
        let borderColor: Color = (isOn && isSupported) ? tint.opacity(0.5) : Color.clear

        return Button {
            // 用户 2026-09-25：「摄像头、屏幕声音（右上角的位置：点击时=23）」——
            // 苹果官方相机倒计时音。置灰时按钮本来就点不动，所以这里必然是有效切换。
            SoundEffectPlayer.shared.play(.deviceToggle)
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(iconAndLabelColor)
            .padding(.horizontal, Self.headerControlHorizontalPadding)
            .frame(height: Self.headerControlHeight)
            // 宽度按自己的文字来，不参与任何压缩：模式菜单已经固定尺寸了，这一句是
            // 第二道保险 —— 「屏幕」「摄像头」永远完整显示。
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isSupported)
        .pointerCursor(isEnabled: isSupported)
        .help(isSupported ? help : unsupportedHelp)
    }

    /// 页头三颗控件共用的一把尺子。高度从 30 抬到 34、横向内边距从 10 抬到 12，
    /// 是用户 2026-09-23 的「宽度和高度都应该大一点，方便用户点击」。原来那 30 是
    /// 跟侧栏的 `NotchBarActionButton` 取齐的，现在不齐了 —— 这一排的点击频率比
    /// 侧栏高得多，用户的判断优先。
    /// 页头按钮的高度 —— **唯一的定义在 `NotchSupport`**：模式条那排与这一页这几颗
    /// 必须完全相同（用户：「所有的模式按钮，高度增大，让它们完全相同，因为都是在分隔线
    /// 上面」），两处各存一个数字就一定会漂。
    private static var headerControlHeight: CGFloat {
        NotchSupport.contentHeaderControlHeight
    }
    private static let headerControlHorizontalPadding: CGFloat = 12
    private static let headerControlFontSize: CGFloat = 12

    /// 模式下拉里**文字那一格**的固定宽度，取最长的模式名。
    ///
    /// 量出来而不是写死一个数字：模式名可能在设置里被改成别的长度，写死会截断
    /// 以后会不会多一个更长的名字，写死等于把「挤掉旁边的按钮」这个 bug 留到下一次
    /// 改配置的时候。用 `NSFont` 而不是数字符个数：三个名字现在都是汉字（汉字在
    /// 12pt 下字宽正好是 12），但只要有一个英文字母或数字混进来，字数就不再等于宽度，
    /// 而 `NSFont.systemFont` 与 SwiftUI 的 `.system(size:weight:)` 是同一套字体，
    /// 量出来的就是实际排版宽度。
    /// **预设下拉**整块的宽度。每条预设是一张卡片（标题 + 备注 + 模型组合），
    /// 所以它比语速那种单行下拉宽得多 —— 460pt 能放下最长的备注与三个模型名。
    private static let presetDropdownWidth: CGFloat = 460

    /// 语速下拉整块的宽度。十行，每行是「语速 10」+ 右边的「1.50×」，200pt 够用。
    ///
    /// 提成常量是因为**浮层的落点要拿它算左边缘**（`floatingPanelLeftOffset`）：
    /// 以前它的位置是 `.padding(.trailing, contentColumnHorizontalMargin + 240)`，
    /// 那个 240 和语速按钮的真实位置没有任何关系 —— 实测浮层右缘落在 x=1017，
    /// 而语速按钮右缘在 907，错开 110pt。现在按量到的按钮位置贴。
    private static let speedMenuDropdownWidth: CGFloat = 200

    /// 音色面板里各段之间的间距（分类行 / 提示行 / 音色网格之间）。
    private static let voicePanelRowSpacing: CGFloat = 6

    /// 音色面板里**卡片之间**的间距。三类（全双工网格 / 男女两列 / 克隆网格）
    /// 共用这一个数 —— 用户 2026-09-24：「非流式卡片之间的高度间隙比较窄，
    /// 克隆音色卡片的间隙就比较大……卡片与卡片之间的间距也固定」。
    /// （原来两列是 4、全双工网格是 6、克隆网格是 8，三个页签三种节奏。）
    private static let voiceCardSpacing: CGFloat = 6

    /// 音色卡片的**固定高度**。`voiceCell` 与 `customVoiceCell` 都钉在这个数上，
    /// 见两处的 frame 注释。
    private static let voiceCardHeight: CGFloat = 62

    /// 聊天类型分段控件里那一格的高度。比分隔线上其它按钮（`headerControlHeight` = 34）
    /// 矮 4pt：它外面还套着 3pt 的内边距，加起来仍然落在同一条带上。
    private static let channelSegmentHeight: CGFloat = 30

    /// 自绘下拉挂在哪：触发它的那颗按钮**下边缘再往下 6pt**。
    ///
    /// 页头的实际高度是 `sheetHeaderTopInset + contentColumnHeaderBandHeight`（上边距
    /// 是 padding，加在 frame 之外），而那颗按钮在这一条里是垂直居中的，所以按钮底边
    /// 落在 `sheetHeaderTopInset + contentColumnHeaderBandHeight / 2 + headerControlHeight / 2`。
    /// 这个算式写在这里而不是把结果写死：页头带高或按钮高度一改，下拉还贴着按钮。
    private static let modeMenuDropdownTopInset: CGFloat =
        NotchSupport.sheetHeaderTopInset
        + NotchSupport.contentColumnHeaderBandHeight / 2
        + headerControlHeight / 2
        + 6

    private var headerRoleName: String {
        if let activeRoleID = controller.activeRoleID,
           let role = controller.rolePresets.first(where: { $0.id == activeRoleID }) {
            return role.name
        }
        if let selectedRoleID = controller.selectedRoleID,
           let role = controller.rolePresets.first(where: { $0.id == selectedRoleID }) {
            return role.name
        }
        return "语音聊天"
    }

    private var statusWord: String {
        switch controller.connectionPhase {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "聊天中"
        }
    }

    private var statusColor: Color {
        switch controller.connectionPhase {
        case .idle: return .white.opacity(0.45)
        case .connecting: return Color(red: 1.0, green: 0.75, blue: 0.35)
        case .connected: return Color(red: 0.35, green: 0.85, blue: 0.55)
        }
    }

    // MARK: - Transcript flow

    private var transcriptFlow: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.transcriptEntries.isEmpty && controller.connectionPhase == .idle {
                        emptyHint
                    }

                    // 空的助手条目**不画**：那一轮的回答气泡在回合一开始就占好了位置
                    // （这是为了让气泡顺序永远等于问答顺序），但第一个字可能还要几秒
                    // 才到 —— 那段时间画一个空卡片会显得像坏了。它在数组里的位置是对的，
                    // 所以文字一到就出现在正确的地方。
                    //
                    // 文字从这里取：**流式那份在 `streamingAnswerTextStore` 上，
                    // 定稿那份在条目里**。逐字的文字之所以不写进 `transcriptEntries`，
                    // 见 `VoiceChatStreamingTextStore` —— 那个数组一变，观察控制器的
                    // 四个视图（含左侧栏与整个面板根）全部重算。
                    ForEach(controller.transcriptEntries.filter { $0.isUser || !displayText(for: $0).isEmpty }) { entry in
                        if entry.isUser {
                            outgoingBubble(entry.text)
                                .id(entry.id)
                        } else {
                            // 先取出来再传：把 `displayText(for:)` 和那个 `||` 一起塞进
                            // 实参里，类型检查器会放弃（实测 "unable to type-check this
                            // expression in reasonable time"）。
                            let assistantText = displayText(for: entry)
                            let isStillGrowing = controller.streamingAnswerEntryID == entry.id
                                || controller.duplexAssistantEntryID == entry.id
                            assistantBubble(
                                assistantText,
                                // **「这张卡还在长吗」不能只看 `streamingAnswerEntryID`。**
                                //
                                // 那个槽是三段式与全双工**共用**的：全双工回复播放期间
                                // 用户往输入框打一句话并回车（`sendText` → `startTurn`）
                                // 会把它暂时指到那个新条目上。正在长的那张卡于是被当成
                                // "已定稿"折叠一次 —— 而折叠只增不减，那一行会被画两遍、
                                // 后面的字丢掉（实测探针：干净路径 55/55 字，被这一下
                                // 污染后剩 41/55）。`duplexAssistantEntryID` 只属于全双工，
                                // 抢不走，所以两个一起判。
                                isStreaming: isStillGrowing
                            )
                            .id(entry.id)
                        }
                    }

                    if controller.connectionPhase == .connecting {
                        workingIndicator
                            .id("voicechat-streaming")
                    }

                    // The scroll target AND the flow's bottom breathing room,
                    // as one resident view — the ids above only exist while the
                    // session is connecting, so scrolling to one of them did
                    // nothing when the user simply picked another role.
                    Color.clear
                        .frame(height: 16)
                        .id(Self.transcriptBottomAnchorID)
                }
                .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
                .padding(.top, 4)
            }
            // Whole-flow selection: the user asked to be able to select part of
            // a message or drag across one.
            .textSelection(.enabled)
            // …and a plain click in the flow puts the caret in the composer, so
            // a question can be typed before the session is up — the field keeps
            // its draft while disconnected and the placeholder is what says so.
            .contentShape(Rectangle())
            .onTapGesture {
                // 关掉展开着的浮层。**不再顺带聚焦输入框** —— 那一条按用户的
                // 决定删除了（偶发抢焦点导致打不进字，见 `NotchHomeView` 的注释）。
                activeVoiceRow = nil
                activePresetRow = nil
                isSpeedMenuOpen = false
            }
            .onChange(of: controller.transcriptEntries.count) { _, _ in
                scrollToBottom(proxy)
            }
            // **流式期间必须跟着文字走**（用户 2026-09-25）：「卡片在渲染过程中，
            // 永远都不可以显示到输入框的下面……就跟 ask 这个页面的卡片效果一样」。
            //
            // 上面那条只在**新增一条**时滚动，而全双工的回复是**往同一条里长**的
            // （`updateDuplexAssistantEntry` 按 id 更新），条目数不变 —— 于是整段
            // 流式期间一次都不滚，卡片一路往下长、长到输入框底下甚至屏幕外。
            // 判据取「最后一条的长度」，因为那正是逐字长出来的那个量。
            //
            // 与另外两页同一处收敛：Ask 用 `entries.count`（动画）+ 流式文字（瞬时），
            // Agent 用 `streamingText`（瞬时）。流式期间一律**瞬时**滚动 —— 带动画的
            // 0.2s 长于 delta 间隔，动画会永远处在「被改目标」的状态，每帧都在重新
            // 定位一个正在变大的内容。
            //
            // 判据从「最后一条的文字长度」换成 store 自己记的那个数：逐字的文字已经
            // 不住在 `transcriptEntries` 里了（见 `displayText(for:)`），而且对整段
            // 正文做 `String.count` 是 O(正文长度)、body 每次都会跑。
            .onChange(of: controller.streamingAnswerTextStore.latestTextCharacterCount) { _, _ in
                scrollToBottomInstantly(proxy)
            }
            .onChange(of: controller.selectedRoleID) { _, _ in
                // One turn of the main loop later: the newly selected role's
                // transcript is part of the same render pass, and scrolling
                // before that pass lays out measures the previous role's rows.
                scheduleScrollToBottom(proxy)
            }
            .thinWhiteScrollIndicator()
            .onAppear {
                // **展开面板时不许有滑动** —— 见 `AgentSessionView` 同名位置的说明。
                // 原来是 `scrollToBottom`（带动画 0.2 秒），用户看到的是内容从下方
                // 滑到当前位置；换成瞬时就没有移动过程了。
                scrollToBottomInstantly(proxy)
            }
        }
    }

    private static let transcriptBottomAnchorID = "voicechat-transcript-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
        }
    }

    /// 与上面同一个滚动，但**不带动画** —— 流式期间专用。
    ///
    /// 带动画的滚动时长（0.2s）长于 delta 的间隔，整个流式期间动画都处在「被改
    /// 目标」的状态，每一帧都在带着一个正在变大的内容重新定位。瞬时滚动没有这个
    /// 成本。Ask 与 Agent 两页早就分成这一对了（`NotchHomeView` /
    /// `AgentSessionView` 里的同名方法），这里是第三处。
    private func scrollToBottomInstantly(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            scrollToBottom(proxy)
        }
    }

    /// The 「正在连接…」 breathing row — the same spinner the agent view uses
    /// before a turn's first text arrives.
    private var workingIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(dotsAreBright ? 0.6 : 0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dotsAreBright = true
            }
        }
    }

    @State private var dotsAreBright: Bool = false

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.25))
            // 引导语跟着交互走：见 `emptyHintHeadline` —— 连接按钮现在在这一页的页头里。
            Text(emptyHintHeadline)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
            Text("连接后，这里实时显示聊天的每一句话；下面的输入框可以直接打字")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// 引导语要说清**这一页上**该点哪里。
    ///
    /// 它原本写的是「点它右边的「连接」」—— 那颗按钮住在侧栏的角色行上，而侧栏的角色列表
    /// 在 2026-09-26 的卡片化改造里被卡片区取代了，于是那句话指向了一个**不存在**的按钮
    ///（`connectToRole` 当时一个调用点都没有：语音聊天根本连不上）。连接按钮现在是这一页
    /// 页头里那颗（`connectButton`），所以两种情况的说法都跟着改。
    private var emptyHintHeadline: String {
        // 从卡片进来时，说的是**这张卡片选的那个角色**（按「连接」用的就是它）。
        if let cardID, let mode = currentCardChatMode, mode.isVoiceLike {
            let role = cardChatPreferences.resolvedRole(forCardID: cardID, kind: cardKind, mode: mode)
            return "已选中「\(role.displayName)」，点上面的「连接」开始"
        }
        if let selectedRoleID = controller.selectedRoleID,
           let role = controller.rolePresets.first(where: { $0.id == selectedRoleID }) {
            return "已选中「\(role.name)」，点上面的「连接」开始"
        }
        return "点上面的「连接」开始"
    }

    // MARK: - Composer

    /// One text field, nothing else. The 「语音」 state badge that used to sit to
    /// the left is gone (the user's 「右侧下方只有一个输入框」) and so is the send
    /// button that used to sit to the right (「三个页面都删掉右侧底部的发送按
    /// 钮」). Return sends; while the session is down `submitComposerDraft`
    /// declines and the draft is kept, so nothing written before connecting is
    /// swallowed (the placeholder says why).
    private var composerRow: some View {
        MessageComposerField(
            placeholder: composerPlaceholder,
            draft: $composerDraft,
            isFocused: $composerFieldIsFocused,
            height: composerHeight,
            isExpanded: isComposerExpanded,
            canToggleExpansion: contentColumnHeight > 0,
            onToggleExpansion: { isComposerExpanded.toggle() },
            onSubmit: submitComposerDraft,
            // 语音聊天的「正在运行」就是会话在跑：回复由会话自己合成播放，
            // Wanna 这边没有单条回复的中断指令，能停的
            // 只有整场会话 —— 所以这一颗按钮在这页上等于挂断。
            isResponding: controller.connectionPhase != .idle,
            onStop: { controller.disconnectCurrentSession() }
        )
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // 输入框顶边的位置要报上去：它是音色面板**不许越过的下边界**
        // （见 `voicePanelAvailableHeight`）。
        .background(headerAnchorReporter(.composer))
    }

    /// Three lines at rest, 30% of the content column when expanded — the
    /// user's own figure for the 展开 button.
    private var composerHeight: CGFloat {
        guard isComposerExpanded, contentColumnHeight > 0 else {
            return MessageComposerField.threeLineHeight
        }
        return max(
            MessageComposerField.threeLineHeight,
            contentColumnHeight * Self.expandedComposerHeightFraction
        )
    }

    private static let expandedComposerHeightFraction: CGFloat = 0.30

    /// Connected: an input. Idle: the reason nothing can be typed yet.
    private var composerPlaceholder: String {
        controller.connectionPhase == .connected ? "输入文字，回车发送…" : "连接后可打字发送"
    }

    private var composerDraftIsEmpty: Bool {
        composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Typing is only worth sending while the session is up. The field stays
    /// enabled either way — a draft written before connecting is kept, not
    /// swallowed, which is what the old unconditional clear used to do.
    private var canSubmitComposerDraft: Bool {
        !composerDraftIsEmpty && controller.connectionPhase == .connected
    }

    private func submitComposerDraft() {
        guard canSubmitComposerDraft else { return }
        controller.sendText(composerDraft)
        composerDraft = ""
        composerFieldIsFocused = false
        // 发送按钮是 `Button`，它那一下不会走到整列那颗 `onTapGesture` 上，
        // 所以下拉要在这里自己关一次。
        activeVoiceRow = nil
        activePresetRow = nil
        isSpeedMenuOpen = false
    }

    // MARK: - Bubbles (cloned geometry from AgentSessionView / NotchHomeView)

    private func bubbleShape(isOutgoing: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Self.bubbleCornerRadius,
            bottomLeadingRadius: isOutgoing ? Self.bubbleCornerRadius : Self.bubbleTailCornerRadius,
            bottomTrailingRadius: isOutgoing ? Self.bubbleTailCornerRadius : Self.bubbleCornerRadius,
            topTrailingRadius: Self.bubbleCornerRadius,
            style: .continuous
        )
    }

    // 参考页 `.unit.user` 的气泡几何：圆角 14，尾巴角 4（与 NotchHomeView
    // 同一套，2026-09-23 UI 化改造）。
    private static let bubbleCornerRadius: CGFloat = 14
    private static let bubbleTailCornerRadius: CGFloat = 4

    /// The user's line, with its copy control underneath — flush with the
    /// bubble's trailing edge. Both bubbles in this column carry one (the user
    /// asked for their own words and the assistant's replies to be copyable
    /// here).
    private func outgoingBubble(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .bottom) {
                Spacer(minLength: 56)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        bubbleShape(isOutgoing: true)
                            .fill(DS.Colors.userBubbleFill)
                    )
            }

            MessageCopyButton(text: text, helpText: "复制我说的话")
        }
    }

    /// 一条记录**当前该显示的文字**。
    ///
    /// 两级来源，顺序不能反：**流式中那一轮的文字住在
    /// `controller.streamingAnswerTextStore` 上，定稿的文字住在条目自己身上。**
    ///
    /// 为什么不干脆都放条目里：`transcriptEntries` 是控制器上的 `@Published`，而
    /// **四个**视图在观察这个控制器（Chatting 列、左侧角色栏、预览条、整个面板根）。
    /// 逐字去改那个数组，等于每来一个字就把整个展开面板重新求值一次。`sample` 实测
    /// （2026-09-25，全双工会话、面板展开）：主线程约 36% 的工作量花在
    /// `NSHostingView.layout()` 里，而那条栈是 `update → updateInheritedView → update
    /// → …` **逐层走完整棵树**（926 → 924 → 918 → 916 → 898 → 796 → 577 → 339 个样本）
    /// —— 特征就是"整棵面板在重算"。拆开之后，逐字变化的只有 store，
    /// 观察它的只有这一列。
    private func displayText(for entry: VoiceChatController.VoiceChatTranscriptEntry) -> String {
        streamingAnswerTextStore.text(forEntryID: entry.id) ?? entry.text
    }

    /// 助手回答用 Ask 页同一张卡（`AnswerCardView`， blur-focus 逐字动画），
    /// 而不是原来的纯色气泡 —— 用户 2026-09-25：「这个卡片的样式才是我真正
    /// 需要的渲染效果」，并要求把它应用到 Agent 和 Chatting 两页。
    /// 正在流式的那一条（`streamingAnswerEntryID`）拿 `isStreaming: true`，
    /// 其余历史条目直接整段显示。
    private func assistantBubble(_ text: String, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                AnswerCardView(
                    text: text,
                    isStreaming: isStreaming,
                    style: answerCardStyle,
                    // **全双工不做进场动画** —— 用户 2026-09-25：「（全双工语音模式）
                    // 最后 5 个字，不要动画，直接显示吧」。
                    //
                    // 判据走**这条会话本身**（`isDuplexSessionRunning`）而不是
                    // `activeMode`、也不是界面上高亮的那一行：前者只在用快捷键起会话时
                    // 才被赋值（点「连接」时恒为 nil，于是动画一直开着 —— 用户报的
                    // 「没修复」），后者可以在会话进行中被切走。详见那个属性的说明。
                    animatesIncomingCharacters: !controller.isDuplexSessionRunning
                )
                // 列宽变了就重建这张卡：它把断好的行按宽度缓存在自己的 `@State` 里，
                // 而实时区那两行不允许被压缩（`AnswerCardView.liveLineView` 的
                // `.fixedSize(horizontal: true)`）—— 于是「卡片算出来的行有多宽」
                // 变成了这一列的最小宽度，收起／展开侧栏（或全屏来回切）之后这一列
                // 就再也回不到窄的一档。重建一次缓存就空了，卡片按真实宽度重新断行。
                .id(contentColumnWidth)
                Spacer(minLength: 56)
            }

            MessageCopyButton(text: text, helpText: "复制这条回复")
        }
    }
}
