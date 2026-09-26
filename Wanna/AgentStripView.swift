import AppKit
import SwiftUI

/// 屏幕**右上角、菜单栏下面一行**那一排**临时 agent** 的按钮，以及按钮下面弹出的卡片。
///
/// ## 为什么在屏幕右上角
///
/// 用户 2026-09-26：「刘海左侧这个 agent 的小图标，就是状态图标，应该放在右侧，电脑屏幕的
/// 时间日期这个菜单栏的下面一行……在这个位置上从右到左依次显示各种各样的任务，用户点击之后
/// 可以展开。这样就不会影响整个窗口或者其他组件的位置」。
///
/// 它原来画在刘海面板里（刘海左侧），而刘海那一圈正是两翼动画、录音带、展开面板都要争的地方 ——
/// 所以那一排被展开的东西盖住过。搬到右上角之后它谁也不挡，而且**不再住在任何别人的窗口里**：
/// 它有自己的一块透明面板（`AgentStripPanelController`），面板怎么变都和它无关。
///
/// ## 位置上的硬要求
///
/// **绝对定位，不靠相对位置。** 用户明确要求过：相对位置会跟着容器内容的宽度跑，而那个宽度
/// 什么时候变是不可预测的。所以整块面板的矩形由 `NotchSupport.agentStripPanelFrame` 从**屏幕
/// 坐标**算出来，而这个视图在面板里**右对齐、顶对齐**铺满 —— 第 0 颗按钮因此正好落在
/// `NotchSupport.agentButtonFrame(indexFromTrailingEdge: 0)` 上，画的和点的只有一处算术。
struct AgentStripView: View {

    @ObservedObject var board: AgentActivityBoard
    /// 按钮高度（= 菜单栏高度），由挂载处按屏幕算好传进来。
    let buttonHeight: CGFloat

    /// 呼吸的相位。**整排共用一个** —— 每个按钮各起一条 `repeatForever` 动画会各自飘、
    /// 彼此不同步，看起来像坏了。
    @State private var isBreathing = false


    /// 只在册子上最多的那几个：那个角上放不下更多（见 `maximumVisibleAgentButtons`）。
    private var visibleAgents: [EphemeralAgent] {
        Array(board.agents.prefix(NotchSupport.maximumVisibleAgentButtons))
    }

    var body: some View {
        // **右对齐、顶对齐铺满整块面板。** 面板的右边缘就是第 0 颗按钮的右边缘
        //（见 `NotchSupport.agentStripPanelFrame`），所以这一列不需要任何 offset ——
        // 它画在哪儿由面板的位置决定，而面板的位置和命中矩形是同一处算术。
        //
        // 不接收点击：面板 `ignoresMouseEvents = true`，视图根本收不到点击；命中的那
        // 一侧由 `NotchWindowController.handleGlobalClick` 用 `NotchSupport` 的矩形接走。
        strip
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
            // 呼吸的起搏器：一次 `repeatForever`，之后只靠 `isBreathing` 这个 Bool 驱动
            // 每一个按钮的透明度插值。
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }

    private var strip: some View {
        VStack(alignment: .trailing, spacing: NotchSupport.agentStripRowSpacing) {
            HStack(spacing: NotchSupport.agentButtonSpacing) {
                // **从右往左**：最新的任务离右上角最近（用户 2026-09-26：「在这个位置上
                // 从右到左依次显示各种各样的任务」）。
                ForEach(visibleAgents.reversed()) { agent in
                    button(for: agent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 卡片**叠着往下排**，右对齐到同一列。
            //
            // 用户的要求是「它就把这个卡片也显示，可以显示在下面，让它们别重叠」——
            // 竖着排是唯一同时满足「在按钮下面」和「不重叠」的排法：横着排的话，
            // 卡片比按钮宽得多（190 vs 40），两张就会压在一起。
            ForEach(expandedAgents) { agent in
                banner(for: agent)
            }
        }
        .frame(width: NotchSupport.agentBannerWidth, alignment: .trailing)
    }

    /// 卡片展开着的那些 —— **同时最多两张**（和 `agentCardFrame` 的命中高度同一套假设）。
    ///
    /// 三张一起弹会把那个角占满，而用户的注意力只有一处；最新的两张够表达
    /// 「刚才发生了什么」。
    /// **面板展开时，卡片让位。**
    ///
    /// 2026-09-26 自查截图发现：卡片改成"任务在它就在"之后，展开面板时它们**盖住了侧栏** ✗
    ///（会话列表整个被遮住，用户找不到自己那条对话 ✗）。这和这个仓库既有的规矩是同一条：
    /// 回答气泡在面板展开时也让位（"the sheet's conversation flow is showing the same text"✓），
    /// 而面板里的侧栏本来就把这些任务列出来了 ✓。
    /// **芯片（右上角那几个小方块）不动** —— 它们是常驻的状态指示 ✓。
    private var expandedAgents: [EphemeralAgent] {
        // **任务在，卡片就在。**
        //
        // 原来这里筛的是 `expandedIDs` —— 那是「刚做完、给你看一眼结果」的两秒提示，
        // 所以**任务在跑的时候根本没有卡片**（用户 2026-09-26：「内容现在看不到，
        // 修复一下」就是这个）。而卡片是他要看任务内容的地方（时间 + 正文 + 可展开），
        // 所以它跟着任务活着：任务在 = 卡片在，任务退场 = 卡片一起走。
        board.showsNotchCards
            ? Array(visibleAgents.prefix(NotchSupport.maximumVisibleAgentCards))
            : []
    }

    // MARK: - 按钮

    private func button(for agent: EphemeralAgent) -> some View {
        // **形状：上边两个直角、下面两个圆角。** 用户 2026-09-26：「按钮的样式应该是
        // 一个长方形，但左下角、右下角有圆角」。复用刘海那条带自己的 `PillShape` ——
        // 同一个语汇，不另写一份路径。
        //
        // **高度 = 菜单栏高度**（用户：「按钮的高度应该显示到整个菜单栏的高度一样」），
        // 由控制器按屏幕算好传进来。
        let isUnsettled = agent.status == .running || agent.status == .failed
        let cornerRadius = Self.buttonCornerRadius
        let background: some View = PillShape(bottomCornerRadius: cornerRadius)
            .fill(fillColor(for: agent))
        // `PillShape` 是 `Shape` 不是 `InsettableShape`，所以这里只能用 `stroke`
        //（边框压在中线上，1pt 的线看不出差别），不能用 `strokeBorder`。
        let border: some View = PillShape(bottomCornerRadius: cornerRadius)
            .stroke(strokeColor(for: agent), lineWidth: 1)
        let content: some View = HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: agent))
                .frame(width: 6, height: 6)
            // **一行放下** —— 40pt 宽装得下 4 个字符；原来 30pt 宽时它会折成两行，
            // 屏幕上看着像「enc / 5」那种乱码（用户报过）。
            Text(agent.id)
                .font(.system(size: 9, weight: .semibold).monospaced())
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        // **拆成几段写是有原因的**：一整条链子（ZStack + 三元 + overlay + frame +
        // opacity + animation）会让编译器的类型推断超时，报「failed to produce
        // diagnostic for expression」。分段 + 显式类型之后它才编得过。
        //
        // **呼吸只给「还在跑」和「没做成」。** 用户 2026-09-26：「如果任务失败或者任务
        // 没有完成，它应该有一个呼吸的效果，或者通过颜色变化，让用户能够知道」。
        // 做完的两种不呼吸 —— 它们马上会自己退场（见 `AgentActivityBoard.finishTask`），
        // 而会呼吸的东西是在喊「看我」，对已经结束的事那是假的。
        //
        // 相位是**整排共用一个** `@State`：每个按钮各起一条 `repeatForever` 会各自飘、
        // 彼此不同步，看起来像坏了。
        return ZStack {
            background
            border
            content
        }
        .frame(width: NotchSupport.agentButtonWidth, height: buttonHeight)
        .opacity(isUnsettled && isBreathing ? 0.55 : 1.0)
        .animation(isUnsettled ? .easeInOut(duration: 0.9) : .default, value: isBreathing)
    }

    private func fillColor(for agent: EphemeralAgent) -> Color {
        agent.status == .running ? DS.Colors.surface3 : DS.Colors.surface2
    }

    /// 按钮下面那条边的圆角。刘海那条带是 6，卡片是 9 —— 按钮取中间，看起来才像
    /// 同一套东西里的一员。
    private static let buttonCornerRadius: CGFloat = 7

    private func strokeColor(for agent: EphemeralAgent) -> Color {
        switch agent.status {
        case .running: return DS.Colors.accent.opacity(0.65)
        // 没做成的要**看得出来** —— 颜色是唯一的判据（按钮里只有 6pt 的圆点 + 4 个字符）。
        case .failed: return DS.Colors.destructive.opacity(0.7)
        case .doneVerified, .doneUnverified: return DS.Colors.borderSubtle
        }
    }

    private func statusColor(for agent: EphemeralAgent) -> Color {
        switch agent.status {
        case .running: return DS.Colors.accent
        case .doneVerified: return DS.Colors.success
        case .doneUnverified: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        }
    }

    // MARK: - 卡片

    /// 按钮下面弹出来的那一块。
    ///
    /// 形状照用户说的：「类似于录音按钮下面刘海边一块一行的小文字…这个卡片的下面有
    /// 圆角，左边有圆角，右边有圆角」—— 四角都圆，和刘海那条带同一个语汇。
    private func banner(for agent: EphemeralAgent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // **标题行 = 时间。** 用户 2026-09-26：「把标题上写时间」—— 标题在这里只有
            // 190pt，永远被截断（「帮我在桌面上新建一个文件…」），时间定长、一眼对得上。
            HStack(spacing: 5) {
                Text(agent.startTimeText)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(DS.Colors.textSecondary)
                Text("任务内容")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 4)
                Image(systemName: agent.isCardExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            // **正文 = 任务内容本身。** 默认三行，点一下展开/收起
            //（用户：「如果任务内容非常多，就显示三行，用户点击可以折叠或展开」）。
            Text(agent.request)
                .font(.system(size: 14.5))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(agent.isCardExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            if agent.isCardExpanded {
                Text(agent.bannerLine)
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: NotchSupport.agentBannerWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
