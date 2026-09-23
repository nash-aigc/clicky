//
//  VoiceChatSessionView.swift
//  leanring-buddy
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
//    · the transcript mirrors the VoiceWeb session's own history, so what
//      the user SAYS lands here as outgoing bubbles too, not just typed text;
//    · the composer sends the typed line into the running session over the
//      external bridge (the page's official RTVI `sendText` path) — it only
//      sends while connected, and a draft typed before then is kept, not
//      swallowed.
//
//  The sheet's own top bar is not drawn on this page any more (the user asked
//  for one title instead of two, and for the ✕ to go) — this header takes its
//  slot, at `sheetHeaderTopInset`.
//

import AppKit
import SwiftUI

struct VoiceChatSessionView: View {

    @ObservedObject var controller: VoiceWebSessionController

    @State private var composerFieldIsFocused = false
    @State private var composerDraft: String = ""

    /// The composer's 展开 button (user's request): the field grows to 30% of
    /// the content column and collapses back to three lines.
    @State private var isComposerExpanded = false
    /// The content column's height, measured off the root view — the sheet's
    /// height is the user's own, so the 30% figure has to be measured.
    @State private var contentColumnHeight: CGFloat = 0

    /// 模式下拉是否展开。**自绘下拉没有原生菜单那套"点外面自动关"**，所以
    /// 这一页每一处"用户点了别的地方"都要顺手把它关掉：整列那颗
    /// `onTapGesture`（点正文、点输入框）就带这一句。
    @State private var isModeMenuOpen = false
    /// 下拉里鼠标悬停在哪一行 —— 自绘的行要自己画悬停态。
    @State private var hoveredMode: VoiceWebSessionController.VoiceWebMode?

    var body: some View {
        VStack(spacing: 0) {
            header
            transcriptFlow
            composerRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A click anywhere in the column puts the caret in the composer (the
        // user's 2026-09-23 ask, same as the other two columns). Controls — the
        // header's three, the copy buttons — still win their own taps.
        .contentShape(Rectangle())
        .onTapGesture {
            isModeMenuOpen = false
            composerFieldIsFocused = true
        }
        // 模式下拉挂在**整列**上，不是页头上。VStack 里后一个兄弟画在前一个
        // 上面，挂在页头上的浮层会被下面的对话流盖住；`.overlay` 画在它所附
        // 着的那个视图的全部内容之上，所以挂在这里才是"浮在最上面"。
        .overlay(alignment: .topTrailing) {
            if isModeMenuOpen {
                modeMenuDropdown
                    .padding(.trailing, NotchSupport.contentColumnHorizontalMargin)
                    .padding(.top, Self.modeMenuDropdownTopInset)
            }
        }
        .background(
            GeometryReader { geometryProxy in
                Color.clear
                    .onAppear { contentColumnHeight = geometryProxy.size.height }
                    .onChange(of: geometryProxy.size.height) { _, newHeight in
                        contentColumnHeight = newHeight
                    }
            }
        )
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(headerRoleName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(statusWord)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusColor.opacity(0.15)))
                }

                Text("VoiceWeb 语音聊天")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer(minLength: 8)

            // 顺序是用户定的（2026-09-23）：「把模式选择按钮放在最右边，左侧分别是
            // 摄像头、屏幕这些按钮」。三颗按钮的总宽是固定的（模式菜单的文字格按最长
            // 的模式名量出来，见 `modeMenuLabelWidth`），所以不论当前选的是哪一个模式，
            // 这一排都不会变宽变窄，也就不会再挤掉旁边两颗的文字。
            HStack(spacing: 6) {
                deviceToggleButton(
                    title: "摄像头",
                    systemImage: "video",
                    isOn: controller.isCameraEnabled,
                    isSupported: controller.selectedModeSupportsCamera,
                    unsupportedHelp: "只有全双工全模态模式有摄像头",
                    help: "把摄像头画面发给 AI。下次连接时生效。"
                ) {
                    controller.setCameraEnabled(!controller.isCameraEnabled)
                }

                deviceToggleButton(
                    title: "屏幕",
                    systemImage: "rectangle.on.rectangle",
                    isOn: controller.isScreenSharingEnabled,
                    isSupported: controller.selectedModeSupportsScreenSharing,
                    unsupportedHelp: "全双工语音模式没有屏幕共享",
                    help: "把屏幕内容发给 AI。下次连接时生效。"
                ) {
                    controller.setScreenSharingEnabled(!controller.isScreenSharingEnabled)
                }

                modeMenu
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        // 页头整体占满 `contentColumnHeaderBandHeight`：这条栏的下边缘必须正好落在
        // 右列那条贯穿横线上，与对话页 / Agent 页同高（用户 2026-09-23：
        // 「每一个页面的右侧增加一条线…线上面是相关的参数部分」）。这一页的参数
        // 最多——模式菜单 + 两颗设备开关——所以带高取的是三页里最高的那个需求。
        .frame(height: NotchSupport.contentColumnHeaderBandHeight, alignment: .center)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .onAppear {
            // 设置页是整窗独占的，所以"改完设置回到这一页"一定走一次
            // onAppear —— 这里重读一次，两颗开关就不会拿着上一个模式的值。
            controller.reloadDeviceSwitches()
        }
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
    private var modeMenu: some View {
        Button {
            isModeMenuOpen.toggle()
            hoveredMode = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "switch.2")
                    .font(.system(size: 11, weight: .medium))
                Text(controller.selectedMode.displayName)
                    .font(.system(size: Self.headerControlFontSize, weight: .medium))
                    .lineLimit(1)
                    // 固定宽度，量的是**最长的那个模式名**而不是当前这个。用户的原话
                    // （2026-09-23）：「下拉菜单按钮的整个宽度必须按照全双工全模态这个
                    // 菜单能够完整显示的固定宽度来设置，让左侧的摄像头和屏幕这两个按钮
                    // 也能完整显示…现在如果是三段式，屏幕和摄像头的文字能正常显示，但
                    // 如果选择全双工全模态，文字数量变多，按钮就会变大，把其他两个按钮
                    // 的文字挤掉」。之前这颗菜单带 `.fixedSize()`，宽度跟着当前模式名走，
                    // 它一变宽，右边是页面边缘、左边就是那两颗设备按钮 —— 被挤掉的正是
                    // 它们的文字。
                    .frame(width: Self.modeMenuLabelWidth, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    // 展开时箭头翻过来，用户一眼能看出"现在这是开着的、再点一下会关"。
                    .rotationEffect(.degrees(isModeMenuOpen ? 180 : 0))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, Self.headerControlHorizontalPadding)
            .frame(height: Self.headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isModeMenuOpen ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(
                        isModeMenuOpen ? Color.white.opacity(0.22) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("选语音模式。下次连接时生效。")
    }

    /// 自绘的模式下拉：一行一个模式，行高比页头那三颗按钮**再高一点**
    /// （`modeMenuRowHeight`，用户要求「每一个按钮的高度应该再增大一点」），
    /// 行内是左勾 + 模式名。
    ///
    /// 面板底色用 `DS.Colors.surface2`：本仓库的立面层级是**反的**——卡片比地面更
    /// 深，这里照同一套来，再配一圈白描边与阴影，浮在对话流上时边界才清楚。
    private var modeMenuDropdown: some View {
        VStack(spacing: 2) {
            ForEach(VoiceWebSessionController.VoiceWebMode.allCases, id: \.self) { mode in
                modeMenuRow(mode)
            }
        }
        .padding(4)
        .frame(width: Self.modeMenuDropdownWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        // 空白处（行与行之间那 2pt、四周那 4pt 内边距）也要吃掉点击：整列有一颗
        // `onTapGesture`（点哪儿都把光标放进输入框），漏下去的话点下拉的缝会连带
        // 跳去输入框。行本身是 `Button`，自己那颗点击不受影响。
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .onTapGesture { }
    }

    /// 下拉里的一行。选中的那行带一颗 accent 勾并且文字加亮，悬停的那行有一层浅底
    /// —— 自绘的行没有系统给的任何状态，这三样都得自己画。
    private func modeMenuRow(_ mode: VoiceWebSessionController.VoiceWebMode) -> some View {
        let isSelected = controller.selectedMode == mode
        let isHovered = hoveredMode == mode

        return Button {
            controller.selectedMode = mode
            isModeMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.accent)
                    // 不选中的行留同样宽的空位（`.opacity(0)` 而不是不画），否则
                    // 三个模式名会各自左右错开，读起来像三份不同的层级。
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)

                Text(mode.displayName)
                    .font(.system(
                        size: Self.headerControlFontSize + 0.5,
                        weight: isSelected ? .semibold : .medium
                    ))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.8))
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .frame(height: Self.modeMenuRowHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            // 只清自己这一格：鼠标从 A 滑到 B 时先来 B 的 true 再来 A 的 false，
            // 无条件写 nil 会把 B 刚点亮的悬停又擦掉。
            if isHovering {
                hoveredMode = mode
            } else if hoveredMode == mode {
                hoveredMode = nil
            }
        }
    }

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
    private static let headerControlHeight: CGFloat = 34
    private static let headerControlHorizontalPadding: CGFloat = 12
    private static let headerControlFontSize: CGFloat = 12

    /// 模式下拉里**文字那一格**的固定宽度，取最长的模式名。
    ///
    /// 量出来而不是写死一个数字：模式名由 VoiceWeb 的配置决定，Clicky 这一侧不知道
    /// 以后会不会多一个更长的名字，写死等于把「挤掉旁边的按钮」这个 bug 留到下一次
    /// 改配置的时候。用 `NSFont` 而不是数字符个数：三个名字现在都是汉字（汉字在
    /// 12pt 下字宽正好是 12），但只要有一个英文字母或数字混进来，字数就不再等于宽度，
    /// 而 `NSFont.systemFont` 与 SwiftUI 的 `.system(size:weight:)` 是同一套字体，
    /// 量出来的就是实际排版宽度。
    private static let modeMenuLabelWidth: CGFloat = {
        let modeNameFont = NSFont.systemFont(ofSize: headerControlFontSize, weight: .medium)
        return VoiceWebSessionController.VoiceWebMode.allCases
            .map { ($0.displayName as NSString).size(withAttributes: [.font: modeNameFont]).width }
            .max() ?? 0
    }()

    /// 自绘下拉里每一行的高度。比页头那三颗按钮（`headerControlHeight` = 34）再高
    /// 4pt —— 用户 2026-09-23 的原话是「每一个按钮的高度应该再增大一点」。
    private static let modeMenuRowHeight: CGFloat = 38

    /// 自绘下拉整块的宽度。文字那一格按最长的模式名量（`modeMenuLabelWidth`），
    /// 剩下的 70pt 是勾（12）+ 间距（8）+ 行内边距（18）+ 容器内边距（8）+ 一点余量，
    /// 也就是把下拉做成**不比触发它的那颗按钮窄**：比按钮窄的下拉看着像没对齐。
    private static let modeMenuDropdownWidth: CGFloat = modeMenuLabelWidth + 70

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

                    ForEach(controller.transcriptEntries) { entry in
                        if entry.isUser {
                            outgoingBubble(entry.text)
                                .id(entry.id)
                        } else {
                            assistantBubble(entry.text)
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
                isModeMenuOpen = false
                composerFieldIsFocused = true
            }
            .onChange(of: controller.transcriptEntries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: controller.selectedRoleID) { _, _ in
                // One turn of the main loop later: the newly selected role's
                // transcript is part of the same render pass, and scrolling
                // before that pass lays out measures the previous role's rows.
                scheduleScrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private static let transcriptBottomAnchorID = "voicechat-transcript-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.transcriptBottomAnchorID, anchor: .bottom)
        }
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
            // The wording follows the interaction: choosing a role in the
            // sidebar only selects it now — the connection is started by the
            // 连接 button on that role's own row.
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

    /// 引导语跟着交互走：连接按钮现在在**角色卡片自己的右侧**（用户第 5 条），
    /// 所以这里不能再写「点右上角连接」。
    private var emptyHintHeadline: String {
        if let selectedRoleID = controller.selectedRoleID,
           let role = controller.rolePresets.first(where: { $0.id == selectedRoleID }) {
            return "已选中「\(role.name)」，点它右边的「连接」开始"
        }
        return "点左侧一个角色，再点它右边的「连接」"
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
            // 语音聊天的「正在运行」就是会话在跑：VoiceWeb 的回复由它自己的
            // Chrome 页面合成播放，Clicky 这边没有单条回复的中断指令，能停的
            // 只有整场会话 —— 所以这一颗按钮在这页上等于挂断。
            isResponding: controller.connectionPhase != .idle,
            onStop: { controller.disconnectCurrentSession() }
        )
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, 10)
        .padding(.bottom, 12)
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
        isModeMenuOpen = false
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

    private func assistantBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        bubbleShape(isOutgoing: false)
                            .fill(DS.Colors.assistantBubbleFill)
                    )
                    .overlay(
                        bubbleShape(isOutgoing: false)
                            .strokeBorder(DS.Colors.assistantBubbleBorder, lineWidth: 0.5)
                    )
                Spacer(minLength: 56)
            }

            MessageCopyButton(text: text, helpText: "复制这条回复")
        }
    }
}
