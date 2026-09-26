//
//  CardChatModeBar.swift
//  Wanna
//
//  右列页头最上面那一排：**角色 + 文本 / 图文 / 语音 / 视频**。
//
//  用户 2026-09-26 用它钉死了位置（截图红框圈着语音聊天页原本那排
//  `[视频聊天│语音聊天│音色]`）：「放在这里，右侧分割线上面，左侧对齐（四个模式）」。
//
//  ## 为什么是一个共用视图
//
//  三个内容列（主循环页 / Claude Code 页 / 语音视频页）都要在**同一个 y**
//  （`NotchSupport.contentColumnHeaderRuleY` 那条线之上）画出同一排东西。各画一份的话，
//  只要有一页改了个内边距，那页的线就会比别的页高一点 —— 而这正是那条线的注释里
//  反复强调过的不变量。
//
//  它自己**不认识**任何引擎：只读写「这张卡片选了哪个模式」，剩下的（换页、带不带截图、
//  用哪个角色）由各页自己按这个值决定。所以同一排按钮在三页上的行为不会分叉。
//

import SwiftUI

struct CardChatModeBar: View {

    /// 这一排属于哪张卡片 —— 卡片 id 与种类，与 `AppSettings.cardChatMode` 的键一致。
    let cardID: String
    let cardKind: CardKind

    /// 模式右边那一格（语音 / 视频页放「音色」；其余页留空）。
    var leadingAccessory: AnyView? = nil

    /// 靠右那一组（语音页的摄像头 / 屏幕 / 语速，对话页的复制全文…）。
    var trailingAccessory: AnyView? = nil

    /// **点模式之后**：调用方可能要顺手做点什么（语音页要把聊天类型跟着切过去）。
    /// 模式本身已经写进设置了，这个回调只报"变了"。
    var onModeSelected: ((CardChatMode) -> Void)? = nil

    @ObservedObject var preferences: CardChatPreferenceModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CardChatMode.allCases) { mode in
                modeChip(mode)
            }

            // 「角色」那颗按钮在模式**左边**（用户：「在语音聊天、视频聊天、图文聊天左侧
            // 添加『角色』按钮」）—— 它随阶段 5 一起进来，这里先留出位置。

            if let leadingAccessory {
                leadingAccessory
            }

            Spacer(minLength: 6)

            if let trailingAccessory {
                trailingAccessory
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .frame(height: NotchSupport.cardChatModeBandHeight, alignment: .center)
        // **与下面那行页头之间的细缝也归它**：三个页面都直接把它摞在自己那行页头上面，
        // 各自再补一次间距必然会漂 —— 而右列那条横线的 y 正是按"页头总高"算出来的
        //（`contentColumnHeaderRuleY`）。间距住在这里，三页就一定是同一个总高。
        .padding(.bottom, NotchSupport.cardChatModeBandBottomSpacing)
    }

    /// 一颗模式。观感与对话页那两颗「连续对话 / 临时对话」同一套
    ///（勾 + 绿色、7pt 圆角、1pt 边）—— 它们会出现在同一列的不同行上，样式不该是两族。
    private func modeChip(_ mode: CardChatMode) -> some View {
        let isSelected = preferences.mode(forCardID: cardID, kind: cardKind) == mode
        return Button {
            SoundEffectPlayer.shared.play(.sidebarButton)
            preferences.setMode(mode, forCardID: cardID)
            onModeSelected?(mode)
        } label: {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(mode.displayName)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(isSelected ? DS.Colors.success : .white.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected
                                  ? DS.Colors.success.opacity(0.55)
                                  : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(mode.helpText)
    }
}
