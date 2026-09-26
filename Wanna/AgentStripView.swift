import AppKit
import SwiftUI

/// 刘海左侧那一排**临时 agent** 的按钮，以及按钮下面弹出的卡片。
///
/// ## 为什么在刘海左侧
///
/// 用户 2026-09-26：「派活过程是一个非常大的问题。所以它应该显示在哪里？既要方便用户
/// 看见，又要能够点击查看：具体做了什么？做到哪？做到什么程度？」
///
/// 放刘海左侧是因为**眼睛本来就在那儿** —— 用户刚说完话、按的也是刘海那个位置。
/// 鼠标右下角那块留给主循环的播报（那是「结果」），左边这块留给「过程」。
///
/// ## 两个位置上的硬要求
///
/// **① 给两翼动画让位。** 刘海的左翼（86pt）在录音/思考/播报时会滑出来，
/// 按钮贴着刘海放就会被它盖住。所以整排从「刘海左边缘 − 翼宽 − 一段空」开始往左排。
///
/// **② 绝对定位，不靠相对位置。** 用户明确要求过：相对位置会跟着刘海内容的宽度跑，
/// 而那个宽度什么时候变是不可预测的。所以 x 由 `NotchSupport` 从**屏幕坐标**算出来
/// （和两翼、和摄像头小窗同一套办法）。
struct AgentStripView: View {

    @ObservedObject var board: AgentActivityBoard
    /// 那一排的**右端相对刘海中心**的偏移（屏幕坐标，负数 = 在刘海左边）。
    ///
    /// 不是"窗口坐标里的绝对 x"：根视图只在启动时建一次，而这一排要同时服务静止窗口
    ///（673pt）和展开面板（810pt）两个原点不同的窗口 —— 绝对 x 一烘死，展开那一刻
    /// 整排就平移 68pt（实测按钮画到 x=566，而命中区在 622–662，点不到）。
    /// 两种窗口都居中在刘海中心上，所以「容器中心 + 这个偏移」在两个窗口里是同一个
    /// 屏幕位置，和命中矩形永远一致。
    let trailingXFromNotchCenter: CGFloat
    /// 按钮高度（= 菜单栏高度），同样由挂载处按屏幕算好。
    let buttonHeight: CGFloat

    /// 呼吸的相位。**整排共用一个** —— 每个按钮各起一条 `repeatForever` 动画会各自飘、
    /// 彼此不同步，看起来像坏了。
    @State private var isBreathing = false

    /// 只在册子上最多的那几个：刘海左侧放不下更多（见 `maximumVisibleAgentButtons`）。
    private var visibleAgents: [EphemeralAgent] {
        Array(board.agents.prefix(NotchSupport.maximumVisibleAgentButtons))
    }

    var body: some View {
        // **「容器中心 + 相对刘海中心的偏移」** —— 容器就是当前那个窗口的内容
        //（静止 673pt / 展开 810pt），两种情况下它的中心都在刘海中心上，所以这个
        // 算法在两个窗口里得到同一个屏幕位置。见 `trailingXFromNotchCenter`。
        GeometryReader { proxy in
            strip
                .offset(x: proxy.size.width / 2 + trailingXFromNotchCenter
                            - NotchSupport.agentBannerWidth)
        }
        // 整块不参与布局也不收点击：位置全靠 offset，点击走全局监听
        //（静止态的面板 `ignoresMouseEvents = true`，视图根本收不到点击）。
        // 全局监听那一侧的命中矩形由 `NotchSupport.agentButtonFrame` 给出，
        // 和这里的摆放是同一套算术 —— 画在哪就点在哪。
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
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: NotchSupport.agentButtonSpacing) {
                // **从右往左**：最新的任务离刘海最近。用户刚说完话，眼睛就在刘海上，
                // 让他往屏幕左边去找刚刚那件事是反的。
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

    /// 卡片展开着的那些 —— **同时最多两张**。
    ///
    /// 三张一起弹会把刘海下面那块占满，而用户的注意力只有一处；最新的两张够表达
    /// 「刚才发生了什么」。
    private var expandedAgents: [EphemeralAgent] {
        Array(visibleAgents.filter { board.expandedIDs.contains($0.id) }.prefix(2))
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
        VStack(alignment: .leading, spacing: 1) {
            Text(agent.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Text(agent.bannerLine)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
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
