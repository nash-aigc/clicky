//
//  VoicePanelStyle.swift
//  Wanna
//
//  **语音聊天气泡面板那一套观感，抽出来给别的下拉用**（2026-09-26）。
//
//  用户的原话：「图文模式、文本模式下，音色按钮点击之后的效果，应该参考语音模式下的音色按钮，
//  看它的下拉菜单是怎么设计的。角色按钮的下拉菜单，整个 UI 风格也应该参考语音模式下音色按钮
//  的下拉菜单的风格，包括颜色、样式、卡片这些。」
//
//  所以他指的是**语音页那块音色面板**（`VoiceChatSessionView` 里的）：顶上一排分类标签
//  （选中 = accent 蓝底白字）、一行说明、下面是一格一格的卡片（卡面 + 名字 + id + 右侧几个
//  操作按钮）。那套观感是长在语音页里的（它按引擎分三路、还带收藏和试听），所以这里把**只有
//  形状**的那几件抽出来复用 —— 三个下拉长得一样，靠的是这几个小件，不是复制三份样式。
//
//  这里是纯样式：不认识音色、也不认识角色（`CardChatModeBar` 与 `NotchSheetRootView` 各自
//  往里塞自己的内容）。
//

import SwiftUI

/// 下拉面板的外壳：底色、圆角、边、阴影。三个下拉共用同一层皮。
struct PopupPanelSurface<Content: View>: View {

    /// 面板宽度。语音页那块是铺满右列的，卡片式下拉一般窄一些。
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}

/// 顶上那排分类标签（「系统音色 / 克隆音色」那一对）。
///
/// 选中态就是语音页那一套：**accent 蓝底 + 白字**；未选中是深底 + 次级字。
struct PopupPanelTabRow<Trailing: View>: View {

    struct Tab: Identifiable {
        let id: String
        let title: String
    }

    let tabs: [Tab]
    let selectedID: String
    let onSelect: (String) -> Void
    /// 最右边那一格（语音页放的是"这一行真正会用的音色"，绿色那串）。
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                let isSelected = tab.id == selectedID
                Button {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    onSelect(tab.id)
                } label: {
                    Text(tab.title)
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
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

/// 一行说明（语音页那行「左列男声，右列女声……」）。
struct PopupPanelHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(DS.Colors.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.top, 6)
    }
}

/// **一张卡片** —— 语音页那一格一格的音色卡。
///
/// 左边是名字（大、白）+ 一行小字（id 或说明），右边是调用方给的一排操作按钮。
struct PopupPanelCard<Trailing: View>: View {

    let title: String
    let subtitle: String
    /// 选中态（"正在用这个"）：卡面亮一档 + accent 描边，与语音页选中那张一致。
    let isSelected: Bool
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10)
                                 : (isHovering ? Color.white.opacity(0.07)
                                               : Color.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? DS.Colors.accent.opacity(0.85)
                                         : Color.white.opacity(0.08),
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

/// 卡片右边那种小按钮（语音页的 ★ / 使用 / ▶）。
struct PopupPanelCardButton: View {

    enum Kind {
        /// accent 实心（语音页的「使用」）。
        case primary
        /// 深底（语音页的 ▶、以及未收藏的 ★）。
        case secondary
    }

    let systemImage: String
    let kind: Kind
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(kind == .primary ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(kind == .primary ? DS.Colors.accent : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(helpText)
    }
}
