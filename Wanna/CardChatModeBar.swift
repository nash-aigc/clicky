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

    /// 靠右那一组（语音页的摄像头 / 屏幕 / 模式下拉 / 通话，对话页的音色）。
    var trailingAccessory: AnyView? = nil

    /// 「角色」那颗要不要画。**语音页不画** —— 它把角色挪到输入框那一行去了
    ///（用户 2026-09-26：「把角色按钮放在右侧，放在类似语速按钮的位置上，最右侧」）。
    var showsRoleChip: Bool = true

    /// **点模式之后**：调用方可能要顺手做点什么（语音页要把聊天类型跟着切过去）。
    /// 模式本身已经写进设置了，这个回调只报"变了"。
    var onModeSelected: ((CardChatMode) -> Void)? = nil

    @ObservedObject var preferences: CardChatPreferenceModel

    var body: some View {
        baseRow
    }

    private var baseRow: some View {
        // **和左边那张表同一套**（用户 2026-09-26 深夜：「右侧顶部的文本、语音、视频、通话，
        // 以及右侧音色角色的收缩展开，也做成这样一个效果吧」）：无底色、无圆角、格与格之间
        // 一条 1pt 竖线。
        HStack(spacing: 0) {
            ForEach(CardChatMode.allCases) { mode in
                modeChip(mode)
                TableVerticalRule(rowHeight: NotchSupport.contentHeaderControlHeight)
            }

            if let leadingAccessory {
                leadingAccessory
                TableVerticalRule(rowHeight: NotchSupport.contentHeaderControlHeight)
            }

            Spacer(minLength: 0)

            if let trailingAccessory {
                trailingAccessory
            }

            // **「角色」在最右**（用户 2026-09-26：「把角色按钮放在右侧…最右侧」）——
            // 它曾经在最左，那是"先选角色再选模式"的读法；他现在要的是**靠右那一组**，
            // 与摄像头 / 模式 / 通话并排。
            if showsRoleChip {
                CardChatRoleChip(cardID: cardID, cardKind: cardKind, preferences: preferences)
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .frame(height: NotchSupport.cardChatModeBandHeight, alignment: .center)
        // **与下面那行页头之间的细缝也归它**：三个页面都直接把它摞在自己那行页头上面，
        // 各自再补一次间距必然会漂 —— 而右列那条横线的 y 正是按"页头总高"算出来的
        //（`contentColumnHeaderRuleY`）。间距住在这里，三页就一定是同一个总高。
        .padding(.bottom, NotchSupport.cardChatModeBandBottomSpacing)
    }

    // MARK: - 角色

    private var currentMode: CardChatMode {
        preferences.mode(forCardID: cardID, kind: cardKind)
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
            // **不再用对号表示选中**（用户 2026-09-26：「用户选中时不要在前面加对号，
            // 而是通过边缘高亮以及按钮高亮的方式来显示」）。选中 = 底色更亮 + 绿色描边 +
            // 绿字；未选中 = 几乎透明的底 + 极淡的边。对号还会让被选中的那颗**变宽**，
            // 于是它右边那几颗的位置会跟着挪 —— 现在四颗宽度恒定，点起来不跳。
            // **一格 = 只有字**（共用的 `tableCellText`）—— 底色与描边都去掉了，
            // 所以"选中"只能靠颜色（绿字），格线负责说清"这一格到哪为止"。
            Text(mode.displayName)
                .tableCellText(isOn: isSelected, fontSize: 13)
                .padding(.horizontal, TableStyle.cellHorizontalPadding)
                .frame(height: NotchSupport.contentHeaderControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(mode.helpText)
    }
}

/// 点开「角色」之后那块清单。
///
/// **它必须是独立的一个视图，而且由 sheet 根来画**（不是模式条自己的 `.overlay`）。
/// 原因只有一个但很硬：模式条只有 36pt 高，清单挂在它的 `.overlay` 上时画得出、**收不到
/// 点击** —— 实测点「管理角色…」会穿透到下面那一行预设按钮上（把预设菜单点开了），
/// 也就是说那块清单看着能点、其实点不动。真正接得住的是右列那一整块（sheet 根的
/// `overlay`），那里的 frame 足够大。
///
/// 展开状态因此住在 `CardChatPreferenceModel.openRoleListCardID` 上 —— 一条模式条和三页
/// 共用的东西，状态放谁那儿都会漂，放模型上只有一个来源。
struct CardChatRoleListPanel: View {

    let cardID: String
    let cardKind: CardKind
    @ObservedObject var preferences: CardChatPreferenceModel

    /// 清单里的行：**内容随模式变**（用户：「用户选择图文聊天时即使用此角色。用户选择
    /// 语音聊天或视频聊天时，角色列表变化，不再包含图文聊天角色，而是用户独立设计的角色」）。
    private var mode: CardChatMode {
        preferences.mode(forCardID: cardID, kind: cardKind)
    }

    var body: some View {
        let choices = preferences.roleChoices(for: mode, kind: cardKind)
        let selectedID = preferences.resolvedRole(forCardID: cardID, kind: cardKind, mode: mode).id
        // **观感照语音页那块音色面板**（用户 2026-09-26：「角色按钮的下拉菜单，整个 UI 风格
        // 也应该参考语音模式下音色按钮的下拉菜单的风格，包括颜色、样式、卡片这些」）：
        // 同一层皮（`PopupPanelSurface`）、同一种卡片（`PopupPanelCard`）、同一套右边的小按钮。
        PopupPanelSurface(width: 320) {
            HStack(spacing: 6) {
                Text("角色")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer(minLength: 4)
                Button { preferences.openRoleListCardID = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("收起角色列表")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            PopupPanelHint(text: mode.isVoiceLike
                           ? "这一段对话里它扮演的角色。语音 / 视频只把这段会话记录和这个角色当上下文。"
                           : "这一页用它自己的系统提示词 —— 文本 / 图文模式下 Agent 的全部能力都在。")

            VStack(spacing: 6) {
                ForEach(choices) { choice in
                    row(choice, isSelected: choice.id == selectedID, choiceCount: choices.count)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.08))

            Button {
                preferences.openRoleListCardID = nil
                preferences.openRoleSettingsAction?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text("管理角色…")
                        .font(.system(size: 12.5))
                    Spacer(minLength: 4)
                }
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("打开设置里的角色页：新建、改名、写提示词")
        }
    }

    /// 清单里的一行 —— 用的就是语音面板那张卡片。
    ///
    /// 「默认角色」（= 这个 Agent 自己的系统提示词）**不可改、不可删、置顶**，这是用户
    /// 明确要求的；这一行显示的是**当下生效的那份提示词**有多少字，而不是内容 —— 那几千字
    /// 放在一个下拉里没人读，要看它去「设置 → 对话与记忆 → 系统提示词」。
    private func row(_ choice: CardChatRoleChoice,
                     isSelected: Bool,
                     choiceCount: Int) -> some View {
        // 文本 / 图文模式只有「默认角色」这一个，点它没有意义，所以那一行不是按钮而是说明。
        let isSelectable = !(choice.source == .agentPreset && choiceCount == 1)
        return PopupPanelCard(title: choice.displayName,
                              subtitle: subtitle(for: choice),
                              isSelected: isSelected) {
            if isSelected {
                PopupPanelCardButton(systemImage: "checkmark",
                                     kind: .primary,
                                     helpText: "这一段正在用它",
                                     action: {})
            } else if isSelectable {
                PopupPanelCardButton(systemImage: "checkmark.circle",
                                     kind: .secondary,
                                     helpText: "用这个角色") {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    preferences.setVoiceRoleID(choice.id, forCardID: cardID)
                    preferences.openRoleListCardID = nil
                }
            }
        }
        .opacity(isSelectable || isSelected ? 1 : 0.9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelectable else { return }
            SoundEffectPlayer.shared.play(.sidebarButton)
            preferences.setVoiceRoleID(choice.id, forCardID: cardID)
            preferences.openRoleListCardID = nil
        }
    }

    private func subtitle(for choice: CardChatRoleChoice) -> String {
        switch choice.source {
        case .agentPreset:
            return mode.isVoiceLike
                ? "这个 Agent 自己的提示词"
                : "这个 Agent 自己的系统提示词（不可改）"
        case .userRole:
            return "你自己设计的角色 · \(choice.promptText.count) 字"
        case .builtInVoiceRole:
            return "还没有自己的角色，先用内置这条 · \(choice.promptText.count) 字"
        }
    }

}

/// 「角色」那颗 —— **一处实现，两处用**（模式条的最右、语音页输入框那一行的最右）。
///
/// 抽出来是因为它现在出现在两个地方（用户 2026-09-26 把语音页那颗挪到了输入框上方），
/// 而两处各写一份就一定会漂：一边高亮了一边没有、一边能展开一边不能。
struct CardChatRoleChip: View {

    let cardID: String
    let cardKind: CardKind
    @ObservedObject var preferences: CardChatPreferenceModel

    var body: some View {
        let isRoleListOpen = preferences.openRoleListCardID == cardID
        return Button {
            SoundEffectPlayer.shared.play(.sidebarButton)
            preferences.openRoleListCardID = isRoleListOpen ? nil : cardID
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 12))
                Text("角色")
                    .tableCellText(fontSize: 13)
                Image(systemName: isRoleListOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, TableStyle.cellHorizontalPadding)
            .frame(height: NotchSupport.contentHeaderControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("换一个角色（它就是一段提示词）")
    }
}
