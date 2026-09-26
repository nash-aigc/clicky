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
    /// 这一排的**右边缘**在窗口坐标里的 x。挂载处算好传进来 —— 这个视图不认识屏幕。
    let trailingXInWindow: CGFloat

    /// 只在册子上最多的那几个：刘海左侧放不下更多（见 `maximumVisibleAgentButtons`）。
    private var visibleAgents: [EphemeralAgent] {
        Array(board.agents.prefix(NotchSupport.maximumVisibleAgentButtons))
    }

    var body: some View {
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
            // 卡片比按钮宽得多（190 vs 30），两张就会压在一起。
            ForEach(expandedAgents) { agent in
                banner(for: agent)
            }
        }
        .frame(width: NotchSupport.agentBannerWidth, alignment: .trailing)
        .offset(x: trailingXInWindow - NotchSupport.agentBannerWidth)
        // 整块不参与布局也不收点击：位置全靠 offset，点击走全局监听
        //（静止态的面板 `ignoresMouseEvents = true`，视图根本收不到点击）。
        .allowsHitTesting(false)
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
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(agent.status == .running ? DS.Colors.surface3 : DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(agent.status == .running
                                      ? DS.Colors.accent.opacity(0.65)
                                      : DS.Colors.borderSubtle,
                                      lineWidth: 1)
                )
            HStack(spacing: 3) {
                // 状态点：跑着的是呼吸的，完了的是静态的。**颜色是唯一的判据** ——
                // 按钮只有 30pt 宽，放不下字。
                Circle()
                    .fill(statusColor(for: agent))
                    .frame(width: 5, height: 5)
                Text(agent.id)
                    .font(.system(size: 9, weight: .semibold).monospaced())
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(width: NotchSupport.agentButtonWidth, height: NotchSupport.agentButtonHeight)
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
