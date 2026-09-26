//
//  TableRowStyle.swift
//  Wanna
//
//  **「表格」那一套：无底色、无圆角，靠格线把一格一格分开**（2026-09-26 深夜）。
//
//  用户的原话：「左上角这个表格做得很好，但我觉得应该加一点边线，就是边框线，让用户知道这个
//  分界线在哪里……右侧顶部的文本、语音、视频、通话，以及右侧音色角色的收缩展开，也做成
//  这样一个效果吧。」
//
//  所以这一套就两件东西：
//
//  1. **一格**（`tableCellText`）：只有字。没有底色、没有描边、没有圆角 —— 那些东西一去掉，
//     字号就能提上去而高度不动（这正是他说的「不要在文字里面留很大的边距」）。
//  2. **格线**（`TableRule`）：1pt 的竖线（行内）与横线（行间），颜色只比地面亮一点点。
//     它是**唯一的**结构提示，所以不能少 —— 少了就成了一排浮着的字。
//
//  为什么不做成"每格一个带边框的小方块"：那还是按钮，只是边框细一点；而他要的是**表格**
//  —— 线在格与格**之间**，共用一条，格子本身不画边。少一半的线，也少一半的视觉噪音。
//

import SwiftUI

enum TableStyle {

    /// **一格左右的内边距**（表格里所有格共用）。
    ///
    /// 2026-09-26 深夜：通话那颗在两个模式下宽度差了 4pt（语音页自己写 12、图文页写 10），
    /// 于是它右边那条边在两个模式之间来回跳 —— 用户说的「产生飘逸」就是这个。
    /// 现在这个数只在这里有一份。
    static let cellHorizontalPadding: CGFloat = 12
    /// 表格里的字号（左列 14、右列 13 都用它当基准）。
    static let cellFontSize: CGFloat = 13
    /// 格线颜色。只比面板地面亮一档：表格要读得出结构，但不能抢内容。
    static let ruleColor = Color.white.opacity(0.14)
    static let ruleThickness: CGFloat = 1
    /// 格线比字高一点、又不到满格 —— 满格的线会把整块切成硬邦邦的网格。
    static let ruleVerticalInset: CGFloat = 5
}

/// 一行里的一条**竖**格线。
///
/// ⚠️ **必须显式给高度。** 一开始只写了 `width: 1`，而 `Rectangle` 在竖直方向是**弹性**的
/// —— 放进一行按钮里，它会把外面 VStack 剩下的高度全吃掉，两行按钮当场被撑开几百点
///（2026-09-26 实测：左列第一行从 y=4 掉到 y=92，第二行掉到 297）。表格的线不能参与
/// 分配空间，只能占住自己那一格的高度。
struct TableVerticalRule: View {
    /// 所在那一行的高度（左侧两行 28、页头那排 32）。
    var rowHeight: CGFloat = 28

    var body: some View {
        Rectangle()
            .fill(TableStyle.ruleColor)
            .frame(width: TableStyle.ruleThickness,
                   height: max(rowHeight - TableStyle.ruleVerticalInset * 2, 6))
    }
}

/// 两行之间的一条**横**格线（表格的内部分隔）。
struct TableHorizontalRule: View {
    var body: some View {
        Rectangle()
            .fill(TableStyle.ruleColor)
            .frame(height: TableStyle.ruleThickness)
    }
}

extension View {
    /// **表格里的一格**：去掉底色、描边与圆角，只留字与点击区。
    ///
    /// - Parameters:
    ///   - isOn: 选中态。表格里没有底色可用，所以**只剩颜色**（绿 = 选中）。
    ///   - fontSize: 字号。左列 14、右列 13 —— 两边都比他给这套样式之前大。
    func tableCellText(isOn: Bool = false, fontSize: CGFloat = 13) -> some View {
        self
            .font(.system(size: fontSize, weight: isOn ? .semibold : .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(isOn ? DS.Colors.success : .white.opacity(0.88))
    }
}

/// **「通话」那一格的标签** —— 一处实现，两个模式共用（2026-09-26 深夜）。
///
/// 用户的话：「为什么图文模式、图片文本模式跟语音视频模式右侧这个通话按钮不一样呢？
/// 正常情况下这个通话按钮都应该是白色的呀？不对，我想想想，应该是绿色的。那你就按照视频
/// 语音模式下这个通话按钮样式，修改一下文本跟图片的通话按钮样式，让它变成一个绿色图标跟
/// 绿色的文字。」
///
/// 所以两边**必须长得完全一样**：没通话时是绿的（图标 + 文字都绿），通话中是红的 + 「挂断」。
/// 之前两处各写一份（语音页在 `headerActionButton`、图文页在 `textCallChip`），
/// 颜色就是这么飘开的 —— 现在它只有这一个实现。
struct CallChipLabel: View {
    let isCalling: Bool

    /// 挂断用的红。与刘海那条带子上的挂断一个色。
    static let hangUpColor = Color(red: 0.95, green: 0.42, blue: 0.40)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isCalling ? "phone.down.fill" : "phone.fill")
                .font(.system(size: 12, weight: .medium))
            Text(isCalling ? "挂断" : "通话")
                .font(.system(size: 13, weight: isCalling ? .semibold : .regular))
                .lineLimit(1)
        }
        // **绿色**（他明确要的），通话中变红。
        .foregroundColor(isCalling ? Self.hangUpColor : DS.Colors.success)
    }
}
