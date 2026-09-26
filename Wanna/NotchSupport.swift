//
//  NotchSupport.swift
//  Wanna
//
//  Geometry and environment facts for the notch presence subsystem — the
//  resting pill that lives inside the hardware notch and the floating sheet
//  it expands into.
//
//  Everything here is pure calculation: given a screen it answers where the
//  notch is, where the pill and the expanded sheet should sit (in AppKit
//  global coordinates, the space `NSPanel.setFrame` speaks), and whether a
//  fullscreen app is currently covering a display. No state, no windows.
//
//  The numeric sizes (pill growth, sheet dimensions, band height) are this
//  fork's own design: `HomeSpaceSheetShape` names the fields it needs —
//  menuBarBandHeight / stemWidth / cornerRadius / restingNotchSize /
//  expansionProgress / detachmentProgress / squish — but no values came with
//  those names, so the values here are chosen to look right.
//

import AppKit
import CoreGraphics

nonisolated enum NotchSupport {

    /// TEMPORARY PROBE (2026-09-25)：这次展开**动画开始**的那一刻。
    ///
    /// 用户报「点击刘海屏展开时，一开始什么字都看不见……相当于一个白板盖住了窗口里的
    /// 内容」——而代码注释里写着这个空白是有来历的：展开动画启动时 SwiftUI 的内容**还没
    /// 画出来**（内容构建被故意延后一个 tick，见 `beginExpansion`），所以先铺一层面板色
    /// 的「空面板皮」。仓库早先实测过那次构建：**空面板 44ms、有内容的对话 317ms**。
    ///
    /// 但那是个旧数字，而这套面板之后改了很多。这一对打点就是把它重新量准：
    /// `beginExpansion` 记起点，`NotchPanelRootSwitchingView` 的展开分支在 `onAppear`
    /// 里打差值 —— 那个差值就是"屏幕上只有那块白板"的时长。
    nonisolated(unsafe) static var expansionStartedAt: TimeInterval = 0
    // MARK: - 幕布垂落展开（参考：刘海屏弹出窗口_12种动画对比.html 02 幕布垂落）
    //
    // 展开和收起用的是两套完全不同的机制，各自有各自的常量，别混：
    //   展开 = 02 幕布垂落（下面三个 curtain*）——窗口 frame 一次性到位，
    //         动画在内容层的图层遮罩上，GPU 播放，主线程零逐帧工作。
    //   收起 = winClose（centerScaleCollapse*）——仍然是 60Hz 逐帧 setFrame。
    // 早先那两个「形变时长 / 过冲弹簧曲线」常量（0.62s + (0.22,1.28,.36,1)）
    // 是更早一版的展开实现，已被上面两套取代，无引用，2026-09-23 删除——
    // 留着会让这里对「展开到底怎么动」的描述自相矛盾。

    /// 展开 = 02 幕布垂落：窗口**一步**到最终 frame（宽度、x、顶边从第 0 帧
    /// 起就是最终值），展开的动感全部由内容层的裁剪揭示承担——可见区从
    /// 顶边往下长到整高。参考页的 winCurtain 就是这件东西：
    ///
    ///     @keyframes winCurtain{ 0%{ clip-path:inset(-44px -44px 100% -44px …) }
    ///                            100%{ clip-path:inset(-44px -44px 0 -44px …) } }
    ///     .win.winCurtain{ animation:winCurtain .43s ease-out both; }
    ///
    /// 为什么不再逐帧改窗口 frame（这一条换来的是「不卡」和「不重排」两件事）：
    /// 参考页 12 种窗口动画全是 `transform` / `clip-path`——**没有一种改元素
    /// 尺寸**，因为这两类都是合成器属性，GPU 每帧重画一下就完了。早先把它
    /// 移植成「逐帧 setFrame」是范畴错误：窗口每帧重建绘制表面、SwiftUI 每帧
    /// 对整张面板做变宽重排、文字每帧重算换行——用户看到的竖直卡顿和「同一行
    /// 十个字展开后变十一个字」都是这一个错误带来的（2026-09-23）。宽度恒定
    /// 之后换行从第一帧到最后一帧不可能变，这是结构性保证，不是调参调出来的。
    static let curtainRevealDuration: TimeInterval = 0.43
    /// CSS ease-out 的控制点，也就是 `CAMediaTimingFunction(name: .easeOut)`
    /// 的取值——参考页 winCurtain 写的 `ease-out`。
    static let curtainRevealTimingControlPoints: (Float, Float, Float, Float) = (0.0, 0.0, 0.58, 1.0)
    /// 内容入场比幕布晚多少起步。参考页把 02 幕布垂落和 `.unit.line` 配在一起
    /// 时给的 delay 就是 140ms（01 中心缩放配的是 230ms）。
    /// 内容入场比窗口动画晚多少起步。    ///
    /// **2026-09-25 两个值都归零 —— 用户要求「点击窗口之后马上就能看到窗口里的内容」。**
    ///
    /// 参考页里确实各配各的延迟（02 幕布垂落 140ms、01 中心缩放 230ms），理由写在
    /// 这里的老注释里：「配错的后果是内容在窗口还没长到能盖住它的时候就画出来」。
    /// **但那个理由在这里不成立** —— 因为这套面板的展开**本来就是一个遮罩在渐进揭示**
    /// （见 `NotchWindowController` 的三种揭示），内容是被遮罩一层层露出来的，不是
    /// 靠"晚一点画"来避免提前出现。延迟在这里只买到一件事：**用户在这段时间里看不到
    /// 任何内容。**
    ///
    /// 实测（`⏱️ [expand]` 那对打点，`wanna-展开空白测量-163853.log`）：展开动画
    /// 0.43 秒，而内容就位要 **161ms**（Screen 页、恢复了 10 轮对话）—— 这段时间屏幕上
    /// 只有 `installRevealCover` 铺的那块面板色「空面板皮」（因为内容构建被故意延后一个
    /// tick，见 `beginExpansion`）。再叠上这里的 230ms 延迟，**内容要接近四百毫秒才落到
    /// 屏幕上，几乎整段动画都在看那块白板**。用户的原话是「相当于一个白板盖住了窗口里的
    /// 内容，我根本看不到里面内容是什么」。
    ///
    /// 归零之后内容在它**存在的那一刻**就画出来（161ms），动画时长、曲线、遮罩
    /// 全部不动。
    static let curtainContentEntranceDelay: TimeInterval = 0

    // MARK: - 中心缩放展开（参考：同一份 HTML 的 01 中心缩放）
    //
    // 同一份参考页里的 01，2026-09-23 按用户要求补成可选项：
    // 「参考我提供的 HTML 页面，分析它的展开方式和动画效果。它的动画非常流畅，是从
    // 中心弹开的效果；当前项目是从上到下逐个展开显示。我希望增加一个弹开的效果。」
    //
    // 参考页 01 中心缩放的三个数（`.08` / `.34s` / `cubic-bezier(.22,.9,.3,1)` /
    // `transform-origin:50% 0`）在第一次移植时就量过并记在 AGENTS.md 里，这里沿用
    // 同一组；**没有**连带把透明度也做成动画——动画只有 scale 一个变量，纯 transform，
    // 多一个变量就多一处会和合成的倍率对不上的地方。
    //
    // **和 02 幕布垂落共用同一条铁律：窗口 frame 一次性到最终位置，动的是内容层
    // 的图层。** 这条不是风格偏好——第一版把中心缩放做成了逐帧 `NSWindow.setFrame`
    // （scale 沿「顶边中点固定」的路径每帧改 x/y/w/h），用户当场否掉：「你刚才的
    // 效果比之前还要卡顿…现在是从左到右展开，展开过程中非常卡顿」，还伴随着同一行
    // 文字十个字变十一个字的重排。参考页十二种窗口动画全是 `transform` /
    // `clip-path`，**没有一种改元素尺寸**，就是因为这两类属性在合成器上重画即可，
    // 而改窗口尺寸等于每帧重建绘制表面 + 整张面板重排 + 文字重算换行。
    //
    // 所以这里的 scale 是 `CALayer.transform`（一个 `CATransform3DMakeScale` 加一段
    // 补偿平移，见 `NotchWindowController.startScaleReveal`），窗口尺寸从第一帧
    // 起就是最终值，换行同样不可能变。

    /// 边缘缩放：内容层从 8% 弹到 100%。参考页 winScale 的起点。（中心缩放
    /// 2026-09-23 起改用遮罩扩张，不再用这套 transform 常量。）
    static let centerPopInitialScale: CGFloat = 0.08
    /// 参考页给的时长：`.34s`。
    static let centerPopRevealDuration: TimeInterval = 0.34
    /// 参考页 `cubic-bezier(.22,.9,.3,1)`——先快后缓、尾部几乎平掉，这就是那个
    /// 「弹开」的手感。
    static let centerPopTimingControlPoints: (Float, Float, Float, Float) = (0.22, 0.9, 0.3, 1.0)
    /// 内容入场比缩放晚多少起步。参考页 01 配的是 230ms（02 幕布垂落配 140ms），
    /// 两个数各自跟自己的窗口动画成对，不能混用。
    static let centerPopContentEntranceDelay: TimeInterval = 0

    /// 收起 = 参考页的 winClose：scale(.92) + 整窗淡出，160ms ease-in。
    static let centerScaleCollapseDuration: TimeInterval = 0.16
    static let centerScaleCollapseFinalScale: CGFloat = 0.92
    /// CSS ease-in（0.42, 0, 1, 1）——参考页 winClose 的 animation-timing-function。
    static let centerScaleCollapseTimingControlPoints: (Float, Float, Float, Float) = (0.42, 0.0, 1.0, 1.0)

    /// 展开动画要多长，按用户选的窗口样式取。    ///
    /// `NotchWindowController` 用它排那两个截止点（撤掉揭示的遮罩 / 收敛到展开态）
    /// 和看门狗。**两套时长必须从这一个函数出**：控制器里再写一个 switch，等于把
    /// 「动画多久」这件事说两遍，改一处就会留下一处永远等不到的定时器。
    static func expansionRevealDuration(for style: WindowExpansionStyle) -> TimeInterval {        switch style {
        // 中心缩放（notchBloom）是遮罩扩张，和幕布垂落同族（同一个 0.43s ease-out），
        // 时长同源；边缘缩放是参考页 winScale 的 0.34s。
        case .notchBloom, .curtain: return curtainRevealDuration
        case .edgeScale: return centerPopRevealDuration
        }
    }

    /// 内容入场（`.unit.line` 那三件套）比窗口动画晚多少起步。
    ///
    /// 参考页里两个窗口动画各配各的延迟：02 幕布垂落配 140ms、01 中心缩放配
    /// 230ms。配错的后果是内容在窗口还没长到能盖住它的时候就画出来——幕布/缩放
    /// 刚走三分之一，文字已经完整可见，两个动画看起来是两件事。
    static func expansionContentEntranceDelay(for style: WindowExpansionStyle) -> TimeInterval {
        switch style {
        case .notchBloom, .curtain: return curtainContentEntranceDelay
        case .edgeScale: return centerPopContentEntranceDelay
        }
    }

    /// CSS cubic-bezier(x1,y1,x2,y2) timing-function 的 Swift 求值。
    ///
    /// 参考页的曲线是 CSS 写法，而手驱动的逐帧 setFrame 没有
    /// CAMediaTimingFunction 可以交曲线过去，所以在这里自己解：先用
    /// Newton–Raphson 解 bezier-x(t) = progress 得参数 t（平坦段退化为
    /// 小步推进），再取 bezier-y(t)。端点直接透传，y 控制点 > 1（过冲
    /// 曲线）也能算。收起曲线（`centerScaleCollapseTimingControlPoints`）
    /// 走的就是这条求值。
    static func timingCurveValue(
        atProgress progress: Double,
        controlPoints: (Float, Float, Float, Float)
    ) -> Double {
        let clamped = min(max(progress, 0), 1)
        if clamped == 0 || clamped == 1 { return clamped }

        let x1 = Double(controlPoints.0), y1 = Double(controlPoints.1)
        let x2 = Double(controlPoints.2), y2 = Double(controlPoints.3)

        var parameter = clamped
        for _ in 0..<8 {
            let xError = cubicBezierValue(parameter, x1, x2) - clamped
            if abs(xError) < 1e-6 { break }
            let derivative = cubicBezierDerivative(parameter, x1, x2)
            if abs(derivative) < 1e-6 { parameter += 0.005; continue }
            parameter -= xError / derivative
        }
        let solvedParameter = min(max(parameter, 0), 1)
        return cubicBezierValue(solvedParameter, y1, y2)
    }

    private static func cubicBezierValue(_ t: Double, _ firstControl: Double, _ secondControl: Double) -> Double {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * t * firstControl
            + 3 * oneMinusT * t * t * secondControl
            + t * t * t
    }

    private static func cubicBezierDerivative(_ t: Double, _ firstControl: Double, _ secondControl: Double) -> Double {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * firstControl
            + 6 * oneMinusT * t * (secondControl - firstControl)
            + 3 * t * t * (1 - secondControl)
    }


    /// The resting pill is the hardware notch widened by this much on each
    /// side — enough that the pill's bottom rounded corners read as a
    /// deliberate shape rather than a rendering seam, while staying visually
    /// part of the notch at rest.
    static let restingPillExtraWidthPerSide: CGFloat = 2

    /// How much taller than the notch the *window* is at rest. The visible
    /// black pill is exactly the notch's height when idle; the extra window
    /// area is transparent and exists as the wings' canvas — the activity
    /// presentation extends the notch SIDEWAYS (the wings slide out of the
    /// notch's left and right edges), never downward.
    static let restingPillAnimationHeadroom: CGFloat = 22

    // MARK: - Window levels

    /// The notch panel's level: just above the menu bar, because the pill has to
    /// sit ON the menu bar band rather than under it.
    static let notchPanelWindowLevel: NSWindow.Level = .mainMenu + 1

    /// The level a modal file dialog has to take to be visible at all.
    ///
    /// `NSOpenPanel`'s own level is `.modalPanel` (8), and the notch panel sits
    /// at 25 — so with the sheet open, the folder picker opened BEHIND it and
    /// the user could not click anything in it. That is the 2026-09-23 report
    /// 「用户在 Agent 页面点击加号时，悬浮窗口会遮盖文件夹选择弹窗，导致用户无法
    /// 选择文件夹。需要调整窗口顺序：点击加号后，把文件夹选择放在前面」.
    ///
    /// Raising the picker rather than lowering the notch panel is deliberate:
    /// the panel's level is toggled in several places (`beginExpansion`,
    /// `collapse`, `convergeOnRestingState`) and there are one or more of them
    /// (one per notched screen), so "drop them all for the duration of a modal
    /// loop" would have to be undone on every exit path — including the
    /// cancellation one. The picker lives for exactly one `runModal()` call,
    /// so pushing it one step above the panel cannot be left behind.
    ///
    /// Written as `notchPanelWindowLevel + 1` rather than a literal 26 so the
    /// two can never drift into equality, which would silently put the picker
    /// back behind the sheet for however long it took someone to notice.
    static let modalFileDialogWindowLevel: NSWindow.Level = notchPanelWindowLevel + 1

    // MARK: - Content column geometry (对话 / Agent / 语音聊天)

    /// How far the content column's header sits below the sheet's top edge.
    ///
    /// The sheet's top edge IS the top of the screen (`expandedSheetFrame`), so
    /// anything at `0` would render under the menu bar / the hardware notch.
    /// `restingPillAnimationHeadroom + 8` is the inset the sheet's top bar has
    /// always used; it became a constant on 2026-09-23 when the Agent and
    /// 语音聊天 pages lost that bar — their own headers take the bar's slot
    /// now, and "the title moves up to where the chip was" only comes out right
    /// if both read the same number. The sheet root, the two content headers,
    /// the sidebar's account section and the settings sidebar all use it, so
    /// there is exactly one value to change if the top edge ever moves.
    /// 展开态内容顶端与屏幕顶端之间的距离 = **刘海高度 + 呼吸间距**。
    ///
    /// **原先它是 `restingPillAnimationHeadroom + 8` = 30，比刘海（32）还矮 2pt**，
    /// 这一个数字同时造成了两个被用户看到的问题（2026-09-25）：
    ///
    /// 1. **内容从刘海底下开始画** —— 用户：「要把整体的文字向下再移一点，因为现在
    ///    刘海把很多文字都压住了。比如在 chatting 这个界面，视频聊天和语音聊天的
    ///    文字就被刘海压住了……保留一定的间距，或者刚好不被压住」。
    /// 2. **展开态那条状态带也被它反压矮了** —— 带子的高度是
    ///    `min(notchBandHeight, sheetHeaderTopInset)`（见 `expandedWingBandHeight`），
    ///    被这里压到 30 就比刘海矮 2pt。用户：「渲染出来的左右两侧动画高度不对，
    ///    明显比刘海的高度要低……是不是应该调整到跟刘海高度一样」。
    ///
    /// 所以这一个值必须**不低于刘海**，两件事才会一起回到正确：内容让开刘海，
    /// 带子取 min 之后正好等于刘海高度。40 = 32（本机刘海）+ 8（呼吸间距）。
    static let sheetHeaderTopInset: CGFloat = 40

    /// The left and right breathing room of a content column. The user asked
    /// for the side margins to be as small as they can be, so all four regions
    /// of a content column — header, message flow, error line and composer —
    /// share this one number and stay flush with each other.
    static let contentColumnHorizontalMargin: CGFloat = 12

    // MARK: - The rule shared by the two columns

    /// 侧栏「对话 / Agent / 语音聊天」切换器那颗按钮的高度。
    ///
    /// 从 `HomeSpaceSidebarView` 提上来，因为右列那条线要跟它算出的分割线对齐 ——
    /// 同一条线由两列各自画，两处各存一份数字就一定会漂。
    static let sidebarSectionSwitcherButtonHeight: CGFloat = 30

    /// 切换器与它下面那条分割线之间的间距。
    ///
    /// 用户 2026-09-23 定的「跟分割线的间距小一点」：按钮从 25 长到 30 之后，这
    /// 5pt 正好把多出来的高度还回去，所以那条线一动不动。也就是说这个数字是**由那条
    /// 线的位置决定的**，不能单独改。
    static let sidebarSectionSwitcherBottomPadding: CGFloat = 5

    /// 左右两列共用的那条横线的 y（从面板顶边量起）。
    ///
    /// 左边是侧栏自己那条分割线所在的位置：让开刘海的 `sheetHeaderTopInset`，加上
    /// 切换器按钮的高度，加上按钮与线之间的间距。右边必须**在同一个 y 上**画一条
    /// 贯穿的线——用户 2026-09-23：「我觉得应该在每一个页面的右侧增加一条线。左侧边
    /// 最上面有一条线，就在对话 agent 的语音聊天下面。这条线应该从左到右贯穿，而且
    /// 必须是一条直线，所以应该适当调整左侧和右侧的按钮或文字位置，让它们对齐成一条
    /// 线。右侧的正文内容显示在这条线下面，线上面是相关的参数部分」。
    ///
    /// 写成三项之和而不是一个数字：这条线的全部意义就是两边对齐，任何一边的间距改
    /// 动都必须同时反映到另一边，而这个和是唯一能保证这件事的写法。
    ///
    /// **2026-09-26 加了一项**：右列页头之上多了「角色 + 文本/图文/语音/视频」那一排
    ///（用户要求「放在这里，右侧分割线上面，左侧对齐」）。它占一整格，所以这条线的 y
    /// 跟着下移 `cardChatModeBandHeight + cardChatModeBandBottomSpacing`。
    ///
    /// 左列**不受影响**：那条让两列对齐的「对话 / Agent / 语音聊天」切换器在
    /// 2026-09-26 的卡片化改造里已经删掉了，侧栏顶上现在是搜索框、下面直接是卡片区，
    /// y=75 那儿本来就没有线了。所以这个和今天只是右列自己的页头高度 —— 留成和式是
    /// 为了下一次有人往页头里加东西时，仍然只有一个地方要改。
    static let contentColumnHeaderRuleY: CGFloat =
        sheetHeaderTopInset
        + cardChatModeBandHeight
        + cardChatModeBandBottomSpacing
        + sidebarSectionSwitcherButtonHeight
        + sidebarSectionSwitcherBottomPadding

    // MARK: - 「角色 + 四个模式」那一排（2026-09-26）

    /// 模式行自己的高度。取 30 与侧栏那颗切换器同高（`sidebarSectionSwitcherButtonHeight`）
    /// —— 两处的按钮看起来才像同一套控件；四颗两字标签 + 一颗「角色」在这一格里放得下。
    static let cardChatModeBandHeight: CGFloat = 30

    /// 模式行与它下面那行页头之间的细缝。
    static let cardChatModeBandBottomSpacing: CGFloat = 6

    /// 右列页头**内容**能用的高度：从 `sheetHeaderTopInset` 的下沿到那条线。
    ///
    /// 三页的页头（对话页是顶栏，另两页是它们自己的标题行）都按这个高度排版，内容在
    /// 这条带子里垂直居中，于是每页的页头都恰好在那条线上结束、正文恰好从线下开始。
    ///
    /// **它不含模式行**（模式行有自己的 `cardChatModeBandHeight`）：这一格是"每页自己那行
    /// 页头"的高度，所以三个内容视图里那句 `frame(height:)` 一个字都不用改，
    /// 它们只是各自被套进一个 `VStack`，上面多一行模式条而已。
    static var contentColumnHeaderBandHeight: CGFloat {
        sidebarSectionSwitcherButtonHeight + sidebarSectionSwitcherBottomPadding
    }

    /// The expanded sheet's size — the expanded sheet is *large*, a real
    /// main-window-sized surface (roughly 810×940pt), not a popover. Clamped
    /// per screen so small displays still fit it below the menu bar.
    static func expandedSheetSize(on screen: NSScreen) -> CGSize {
        CGSize(
            width: min(810, screen.frame.width - 40),
            height: expandedSheetHeight(on: screen)
        )
    }

    // MARK: - Sheet height (user-resizable)

    /// The sheet carries a resize grip on its bottom edge and persists the
    /// chosen height (`sheetHeightFractionKey`): the height is a user
    /// preference, the width stays fixed.
    static let minimumSheetHeight: CGFloat = 520
    /// Keyed by screen height so a second display never inherits a height that
    /// does not fit it — the stored value is a fraction of screen height.
    private static let sheetHeightFractionKey = "wannaNotchSheetHeightFraction"

    /// 拖拽那一瞬间的临时高度，松手即清（nil = 没有正在进行的拖拽）。
    ///
    /// 为什么需要它：`expandedSheetHeight` 本来只认 `UserDefaults`，而一次拖拽会
    /// 产生上百个鼠标事件、每个都要改一次高度 —— 把「用户偏好的持久化」和「手指
    /// 底下这一帧」绑在一起，就是每个事件一次磁盘写入。拆开之后，拖动期间只动
    /// 这个内存值，落盘只发生在松手那一次。
    private static var liveDragSheetHeight: CGFloat?

    /// The sheet's height on this screen: the height under the user's finger
    /// while the resize grip is being dragged, otherwise the user's persisted
    /// fraction of the screen height, otherwise the default (~940pt on a
    /// 14″ MacBook's screen).
    static func expandedSheetHeight(on screen: NSScreen) -> CGFloat {
        let maximum = maximumSheetHeight(on: screen)
        if let liveDragSheetHeight {
            return min(maximum, max(minimumSheetHeight, liveDragSheetHeight))
        }
        let storedFraction = UserDefaults.standard.double(forKey: sheetHeightFractionKey)
        guard storedFraction > 0 else {
            return min(940, maximum)
        }
        return min(maximum, max(minimumSheetHeight, screen.frame.height * storedFraction))
    }

    static func maximumSheetHeight(on screen: NSScreen) -> CGFloat {
        screen.frame.height - 80
    }

    /// Called by the sheet's resize grip on every drag event: moves the live
    /// panel to the height under the finger without touching the stored
    /// preference. See `liveDragSheetHeight` for why the two are separate.
    static func setLiveDragSheetHeight(_ newHeight: CGFloat) {
        liveDragSheetHeight = newHeight
        NotificationCenter.default.post(name: NotchSupport.wannaNotchSheetSizeDidChange, object: nil)
    }

    /// Called once, when the user lets go of the resize grip: stores the
    /// height as a fraction of this screen's height so it scales sensibly
    /// across displays, drops the live drag value, and posts
    /// `.wannaNotchSheetSizeDidChange` so the live panel re-frames itself.
    static func commitExpandedSheetHeight(_ newHeight: CGFloat, on screen: NSScreen) {
        let clamped = min(maximumSheetHeight(on: screen), max(minimumSheetHeight, newHeight))
        // Clear first: the stored fraction and the live value agree at this
        // point, so the accessor keeps returning the same number either way.
        liveDragSheetHeight = nil
        UserDefaults.standard.set(clamped / screen.frame.height, forKey: sheetHeightFractionKey)
        NotificationCenter.default.post(name: NotchSupport.wannaNotchSheetSizeDidChange, object: nil)
    }

    /// How much wider than the pill the resting *window* is on each side —
    /// the canvas the flanking activity animation draws on while the
    /// companion is active (both sides of the notch animate). At rest the
    /// extra area is fully transparent, and the panel ignores mouse events
    /// while resting, so the menu bar items underneath stay clickable.
    static let activeFlankWidth: CGFloat = 150

    /// 点击展开的命中余量：pill 四周各放宽这么多，点击才算落在刘海上。
    /// 原来还有一个更窄的「离开」余量，配合悬停计时的迟滞带防止进度环
    /// 抖动；悬停触发已在 2026-09-22 整条移除（「鼠标滑动触发太影响体验」），
    /// 迟滞带随之失去意义，只剩这一个点扩大命中区。
    static let pillClickHitMargin: CGFloat = 4

    // MARK: - Notch detection

    /// Whether a screen carries the hardware notch this subsystem anchors to.
    ///
    /// `safeAreaInsets.top > 0` is the documented signal — only notched
    /// displays reserve top screen space for the camera housing.
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// The hardware notch's rectangle, in the screen's top-left display
    /// coordinates (the space `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`
    /// are reported in — note this is NOT `NSScreen.frame`'s bottom-left
    /// space).
    ///
    /// The notch's horizontal extent is the gap between the two menu-bar
    /// auxiliary areas: everything at the top band left of `auxiliaryTopRightArea`
    /// and right of `auxiliaryTopLeftArea` *is* the notch.
    static func notchRect(on screen: NSScreen) -> CGRect? {
        guard hasNotch(screen),
              let auxiliaryTopLeftArea = screen.auxiliaryTopLeftArea,
              let auxiliaryTopRightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        let notchMinX = auxiliaryTopLeftArea.maxX
        let notchMaxX = auxiliaryTopRightArea.minX
        let notchHeight = screen.safeAreaInsets.top
        guard notchMaxX > notchMinX, notchHeight > 0 else { return nil }

        return CGRect(x: notchMinX, y: 0, width: notchMaxX - notchMinX, height: notchHeight)
    }

    // MARK: - Frames in AppKit global coordinates (what NSPanel.setFrame wants)

    /// The resting pill's window frame: the notch widened slightly on each
    /// side and taller by the animation headroom (transparent when idle).
    /// This is the **drawn pill's** geometry — click-to-expand hit-tests
    /// against it. Nil on screens without a notch.
    static func restingPillFrame(on screen: NSScreen) -> CGRect? {
        guard let notchRect = notchRect(on: screen) else { return nil }

        let pillWidth = notchRect.width + restingPillExtraWidthPerSide * 2
        let windowWidth = pillWidth
        let windowHeight = notchRect.height + restingPillAnimationHeadroom

        // Display coordinates are top-left; AppKit global is bottom-left. The
        // pill hangs from the very top of the screen, so its window's top edge
        // is the screen's top edge: global y = screen.maxY - windowHeight.
        // x is relative to this screen's own origin (auxiliary areas are
        // reported per screen, so offset by the screen's frame origin).
        return CGRect(
            x: screen.frame.minX + notchRect.minX - restingPillExtraWidthPerSide,
            y: screen.frame.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
    }

    /// The resting **window's** frame: the pill frame widened on both sides
    /// by `activeFlankWidth`. The window is always this wide so the flanking
    /// animation never needs a live window resize — the extra area is
    /// transparent at rest. Nil on screens without a notch.
    static func restingWindowFrame(on screen: NSScreen) -> CGRect? {
        guard let pillFrame = restingPillFrame(on: screen) else { return nil }
        // **左侧比右侧宽**：右侧只要装两翼动画的画布，左侧还要装临时 agent 那一排按钮。
        //
        // 加宽是安全的，而且是这套设计里已有的性质：静止时那块区域**完全透明**，
        // 而面板在静止态 `ignoresMouseEvents = true` —— 所以多出来的地方既不显示
        // 任何东西，也挡不住下面菜单栏的点击（见 `activeFlankWidth` 的注释）。
        // **两侧必须等宽。** 内容是在窗口里居中的，所以窗口一旦左右不对称，
        // 胶囊就会被整体推离刘海中心 —— 2026-09-26 实测：左侧为 agent 那一排
        // 外扩 212pt、右侧只外扩 150pt，窗口中心比刘海中心偏左 31pt，胶囊跟着
        // 偏 31pt，露在硬件缺口左边。改成两边都用 `restingLeadingFlankWidth`
        // 之后窗口中心 = 胶囊中心，偏移消失；多出来的右侧在静止态是透明的，
        // 和左侧一样不显示、也挡不住菜单栏的点击。
        return CGRect(x: pillFrame.minX - restingLeadingFlankWidth,
                      y: pillFrame.minY,
                      width: pillFrame.width + restingLeadingFlankWidth * 2,
                      height: pillFrame.height)
    }

    /// 静止窗口**左侧**多出来的宽度。
    ///
    /// 取「两翼画布」和「agent 那一排需要的宽度」里大的那个 —— 少了这一条，
    /// 第 3 个按钮就会落到窗口外面，**画不出来也点不到**，而且不会有任何报错。
    static var restingLeadingFlankWidth: CGFloat {
        let agentStripWidth = leadingWingWidth + agentStripGapFromWing
            + CGFloat(maximumVisibleAgentButtons) * agentButtonWidth
            + CGFloat(maximumVisibleAgentButtons - 1) * agentButtonSpacing
            + agentStripOuterMargin
        return max(activeFlankWidth, agentStripWidth)
    }

    /// 刘海左侧最多同时显示几个 agent 按钮。
    ///
    /// **有上限是必须的。** 没有上限的话，用一天下来那一排会长到屏幕外面去，
    /// 而对面的按钮一个也点不到。超出的那些**不是丢了** —— 它们还在看板里，
    /// 点最左边那个「更多」能翻到（面板里列全部）。
    static let maximumVisibleAgentButtons = 3
    /// 那一排最左端还要留的边。
    static let agentStripOuterMargin: CGFloat = 14

    // MARK: - Wing geometry (shared by the drawing and the click target)

    /// 收起状态下两条翼的宽度，和 `NotchPillRootView` 画出来的一致。
    ///
    /// 放在 `NotchSupport` 而不是留在那个视图里，是为了让**画的**那一份和
    /// **点的**那一份（`restingTrailingWingFrame`）用的是同一个数字：两边各
    /// 写一遍的话，改了一个忘了另一个，命中区就会错位 —— 而且不报错、不崩，
    /// 只是点不准。
    static let leadingWingWidth: CGFloat = 86
    static let trailingWingWidth: CGFloat = 88

    // MARK: - 临时 agent 的那一排按钮（刘海左侧）

    /// 一个 agent 按钮的尺寸。
    ///
    /// **高度 = 菜单栏的高度**（用户 2026-09-26：「按钮的高度应该显示到整个菜单栏的
    /// 高度一样」）—— 在有刘海的机器上那就是 `safeAreaInsets.top`（本机实测 32），
    /// 也正是刘海那一条的高度。所以它跟屏幕有关，是个函数不是常量。
    ///
    /// **宽度从 30 加到 40**：30 的时候 id（4 个字符、9pt 等宽）在一行里放不下，
    /// 会折成两行 —— 屏幕上看着像「enc / 5」这种乱码（用户报过）。40×32 同时满足
    /// 用户要的「长方形」（宽 > 高）。
    static let agentButtonWidth: CGFloat = 40
    nonisolated static func agentButtonHeight(on screen: NSScreen) -> CGFloat {
        notchRect(on: screen)?.height ?? 32
    }
    /// 两个按钮之间。
    static let agentButtonSpacing: CGFloat = 6
    /// 这一排与**刘海左侧那些会展开的东西**之间留的空。
    ///
    /// **判据是"最宽的那一次左侧展开"，不是"翼宽"。** 刘海的左翼（86）在录音/思考/
    /// 播报时会滑出来，而**录音那条带比它还宽** —— 它还要往外压
    /// `recordingBandLeadingOverlap`（14pt 的圆角重叠），一共 100pt。用户 2026-09-26
    /// 的原话：「展开时，这个小按钮如果要显示，就必须在展开位置的左侧，否则一旦展开，
    /// 这个小按钮就看不见了。所以你要测量一下录音时、包括提问屏幕内容时，展开之后的
    /// 宽度是多少」。
    ///
    /// 实测（本机 1728×1117、刘海 185 宽）：录音展开时左侧占 100pt，所以这一排的右端
    /// 退到刘海左边缘以外 `86 + 14 + 10 = 110pt` 处。
    static let agentStripGapFromWing: CGFloat = 10

    /// 录音那条带在刘海左侧**多压出来的**宽度。
    ///
    /// 它同时被 `NotchRecordingOverlay` 用来画那条带（那边原来自己写了一个私有的
    /// 同名常量）—— 两处必须同一个数，否则"让位让够了没有"这件事就又变成两份算术。
    static let recordingBandLeadingOverlap: CGFloat = 14

    /// 这一排的**右端**在屏幕上的 x —— 也就是最靠近刘海的那个按钮的右边缘。
    ///
    /// **从屏幕坐标算，不从任何 SwiftUI 容器的相对位置算。** 用户明确要求
    ///（「用绝对路径来定位，就是说根据这个屏幕的左边缘来进行定位，而不是用相对…
    /// 因为相对的话可能这个刘海它左侧边那个内容，那你这个位置就又往后偏移了」）——
    /// 相对定位会跟着刘海内容的宽度跑，而刘海内容什么时候变宽是不可预测的。
    ///
    /// 从**刘海自己的左边缘**往回退：刘海宽 → 左翼宽 → 录音那条带多压的宽 → 那一段空。
    /// 退的是**最宽的那一次展开**（录音，见 `recordingBandLeadingOverlap`）。
    nonisolated static func agentStripTrailingX(on screen: NSScreen) -> CGFloat? {
        guard let notch = notchRect(on: screen) else { return nil }
        return screen.frame.minX + notch.minX
            - leadingWingWidth - recordingBandLeadingOverlap - agentStripGapFromWing
    }

    /// 那一排的右端**相对刘海中心**的偏移（屏幕坐标，负数 = 在刘海左边）——
    /// 视图就用这个量定位，而不是"窗口坐标里的绝对 x"。
    ///
    /// **为什么是相对中心：根视图只在启动时建一次**（`rebuildScreenPresences`），
    /// 所以传进去的窗口坐标会被烘死，而那一排要同时服务两个窗口 —— 静止时画在那块
    /// 673pt 的窗口里（原点 x=527），展开时画在 810pt 的面板里（原点 x=459）。
    /// 用"窗口坐标"定位，展开那一刻它就会跟着窗口原点整体平移 68pt（实测：
    /// 按钮被画到 x=566，而命中区在 622–662）。
    ///
    /// **两种窗口都居中在刘海中心上**（静止窗口 = 胶囊 ± 等宽外扩；展开面板 =
    /// 屏幕居中，而刘海本来就在屏幕中间），所以"中心 + 偏移"在两个窗口里得到的是
    /// 同一个屏幕位置 —— 画的和点的因此永远一致。
    nonisolated static func agentStripTrailingXFromNotchCenter(on screen: NSScreen) -> CGFloat? {
        guard let trailingX = agentStripTrailingX(on: screen),
              let notch = notchRect(on: screen) else { return nil }
        return trailingX - (screen.frame.minX + notch.midX)
    }

    /// 第 `indexFromNotch` 个按钮（0 = 最靠近刘海的那个）的屏幕矩形。
    ///
    /// **从右往左排**：最新的任务离刘海最近 —— 用户刚说完话，眼睛就在刘海上，
    /// 而旧任务让他去左边找是合理的。
    nonisolated static func agentButtonFrame(on screen: NSScreen,
                                             indexFromNotch: Int) -> CGRect? {
        guard let trailingX = agentStripTrailingX(on: screen) else { return nil }
        let right = trailingX - CGFloat(indexFromNotch) * (agentButtonWidth + agentButtonSpacing)
        let left = right - agentButtonWidth
        // 撞到屏幕左边缘就不放了 —— 一个跑到屏幕外面的按钮，点不到也看不见，
        // 而它会安静地占着一个位置让别的按钮也排不开。
        guard left >= screen.frame.minX + 8 else { return nil }
        // **顶对齐**：视图是挂在 `.overlay(alignment: .topLeading)` 上的，也就是从
        // 屏幕最上面那一行开始画。命中矩形必须贴同一条边 —— 原来是"竖直居中在刘海带里"，
        // 比画出来的位置低 5pt，点按钮上半部分会落空。
        let height = agentButtonHeight(on: screen)
        return CGRect(x: left,
                      y: screen.frame.maxY - height,
                      width: agentButtonWidth,
                      height: height)
    }

    /// 卡片**收起时**的高度 —— 也是它的命中高度。
    ///
    /// 命中判定只能用一个定值：卡片展开后高度随内容变，而"点的"那边拿不到视图的实测高度
    ///（这个仓库在"画的和点的各算一遍"上被打过三次）。取收起时的 74pt 是安全的：
    /// 展开态的前 74pt 里**一定**是标题行 + 前三行正文，点它收起也对。
    static let agentCardHitHeight: CGFloat = 74

    /// 第一张卡片的屏幕矩形（卡片就排在按钮那一排下面）。
    ///
    /// 用户 2026-09-26 要求卡片能点（「用户点击可以折叠或展开」），所以它必须和按钮一样
    /// **从屏幕坐标算出来**，不能只靠视图自己的摆放。
    nonisolated static func agentCardFrame(on screen: NSScreen) -> CGRect? {
        guard let trailingX = agentStripTrailingX(on: screen),
              let notch = notchRect(on: screen) else { return nil }
        let top = screen.frame.maxY - notch.height - agentButtonSpacing
        return CGRect(x: trailingX - agentBannerWidth,
                      y: top - agentCardHitHeight,
                      width: agentBannerWidth,
                      height: agentCardHitHeight)
    }

    /// 按钮下面那张卡片的宽度。**比按钮宽得多** —— 要放得下一行字。
    static let agentBannerWidth: CGFloat = 190
    static let agentBannerMaximumHeight: CGFloat = 46

    // MARK: - 摄像头小窗的摆放

    /// 摄像头小窗那块面板的窗口层级：**和录音那条带同层**。
    ///
    /// **不能沿用 `OverlayWindow` 的 `.screenSaver`（1000）。** 那个层级是给光标
    /// 伴随物准备的 —— 它要求自己盖在右键菜单之上；小窗没有这个需求，而「左中 /
    /// 右中」两个位置正好落在菜单弹出的区域里，一个 315pt 宽的黑块压住用户的右键
    /// 菜单是看得见的缺陷。26 层在小窗和菜单之间留出了正确的顺序。
    static let cameraStripWindowLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

    /// 小窗离屏幕可用区边缘留多少。
    static let cameraStripScreenMargin: CGFloat = 24

    /// 摄像头小窗在某块屏上的摆放参数。**纯几何，没有状态。**
    ///
    /// 四个位置共用一份，是因为「小窗有多宽」「刘海中心在哪」这些量对四个位置都是
    /// 同一个值 —— 各个位置自己算一遍，迟早会有一处用了不同的宽度。
    struct CameraStripPlacementGeometry: Equatable {
        /// 小窗的宽度。**横向摆放和命中矩形必须读同一个数。**
        let stripWidth: CGFloat
        /// `.belowNotch`：从屏幕顶边到小窗顶边（刘海高 + 字幕条高）。
        let topInset: CGFloat
        /// `.belowNotch`：刘海中心相对屏幕中心的横向偏移。
        let horizontalOffset: CGFloat
        /// `.belowNotch`：让小窗**对准刘海中心**时，从屏幕左边算起的距离。
        let notchCenteredLeadingInset: CGFloat
        let leadingInset: CGFloat
        let trailingInset: CGFloat
        let bottomInset: CGFloat
    }

    /// 算小窗在某块屏上的摆放参数。没有刘海的屏返回 nil（小窗只会出现在有刘海的屏上，
    /// 和录音那条带同一个门槛）。
    ///
    /// 三个横向/纵向边距都从 `visibleFrame` 推，所以**没隐藏的 Dock 会让开**；
    /// Dock 自动隐藏或隐藏时 `visibleFrame` 退化成 `frame`，结果同样正确。
    /// **但垂直居中不用 `visibleFrame`** —— 用户说的「中间」是屏幕中间，不是
    /// 「可用区的中间」，用可用区会让小窗在 Dock 存在时偏上。
    nonisolated static func cameraStripGeometry(on screen: NSScreen,
                                                stripWidth: CGFloat,
                                                topInset: CGFloat) -> CameraStripPlacementGeometry? {
        guard let notch = notchRect(on: screen) else { return nil }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        // 刘海在每一台在售 Mac 上都居中，所以这通常是 0 —— 但**必须留着**：
        // 小窗的新家是一块**全屏**面板，它的中心等于屏幕中心。哪天有人图省事按面板
        // 居中摆，`notchCenterX` 就被悄悄换成了 `screenCenterX`。
        let horizontalOffset = screenFrame.minX + notch.minX + notch.width / 2 - screenFrame.midX
        return CameraStripPlacementGeometry(
            stripWidth: stripWidth,
            topInset: topInset,
            horizontalOffset: horizontalOffset,
            notchCenteredLeadingInset: (screenFrame.width - stripWidth) / 2 + horizontalOffset,
            leadingInset: (visibleFrame.minX - screenFrame.minX) + cameraStripScreenMargin,
            trailingInset: (screenFrame.maxX - visibleFrame.maxX) + cameraStripScreenMargin,
            bottomInset: (visibleFrame.minY - screenFrame.minY) + cameraStripScreenMargin)
    }

    /// SwiftUI 的矩形（面板内、y 向下）→ AppKit 全局（屏幕坐标、y 向上）。
    ///
    /// **这一行的符号是整个小窗改动里风险最高的一处。** 写反了不会报错、不会崩、
    /// 屏幕上也不会有任何异常 —— 表现只是「按钮全都没反应」，然后你会去错的文件里找。
    /// 所以它和别的纯几何一样住在这里，能被探针直接测（见 `开发经验/03-…` 的离屏探针）。
    ///
    /// 面板是**全屏**的，所以 `panelFrame` 就是那块屏的 frame。
    nonisolated static func appKitGlobalRect(fromPanelLocal rect: CGRect,
                                             panelFrame: CGRect) -> CGRect {
        CGRect(x: panelFrame.minX + rect.minX,
               y: panelFrame.maxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// 摄像头小窗的宽度：**字幕条的宽，减掉它自己两个圆角的半径。**
    ///
    /// 用户 2026-09-26：「音频转写这一行是由圆角的。圆角的半径。就应该删掉左边的半径、
    /// 右边的圆角的半径删掉，然后中间那部分才是真正的摄像头的宽度」。
    /// 参照物是**字幕条**，不是刘海 —— 拿刘海算（185−20=165）用户当场说「太小了」。
    nonisolated static func cameraStripWidth(on screen: NSScreen,
                                             ribbonCornerRadius: CGFloat) -> CGFloat? {
        guard let notch = notchRect(on: screen) else { return nil }
        let bandWidth = leadingWingWidth + notch.width + trailingWingWidth
        return max(bandWidth - ribbonCornerRadius * 2, 120)
    }

    /// 收起状态下**右翼**的矩形（屏幕坐标）。
    ///
    /// 语音聊天进行中这块会被画成一颗挂断按钮，并且可以直接点（用户
    /// 2026-09-23 第 6 条：「如果用户已经点击连接或当前处于连接状态，菜单栏刘
    /// 海屏右侧应显示一个挂断动画，或者保留菜单栏当前样式风格，把它做成挂断
    /// 按钮，用户可以直接点击挂断，不必展开刘海屏再点击挂断」）。
    ///
    /// 几何不是估的，是从 `NotchPillRootView` 的布局反推的：`HStack(spacing: -2)`
    /// 的三段（左翼 / 中段 / 右翼）在窗口里居中，所以展开时
    ///
    ///     右翼左边界 = activeFlankWidth + leadingWingWidth/2 − trailingWingWidth/2 + pillWidth − 2
    ///
    /// （两个 −2 是那两处负间距）。竖直方向是窗口顶部那 `notchRect` 高的一条
    /// —— 翼的高度是窗口高减掉 `restingPillAnimationHeadroom`，也就是刘海本身
    /// 的高度。
    static func restingTrailingWingFrame(on screen: NSScreen) -> CGRect? {
        guard let windowFrame = restingWindowFrame(on: screen) else { return nil }

        let wingOriginX = trailingWingOriginX(inWindowOfWidth: windowFrame.width)
        let wingHeight = windowFrame.height - restingPillAnimationHeadroom

        return CGRect(
            x: windowFrame.minX + wingOriginX,
            y: windowFrame.maxY - wingHeight,
            width: trailingWingWidth,
            height: wingHeight
        )
    }

    /// 右翼在**那条带子里**的左边界 x（带子左端为 0）。
    ///
    /// 它就是带子的最后一段，所以左边界 = 带子总宽 − 右翼宽 —— 这一步是**定义**，
    /// 不是推导；写成一个函数是为了让「带子」这个坐标系有一个明确的名字。
    ///
    /// 参数是**带子**总宽（左翼 + 中段 + 右翼 − 两处 2pt 负间距）。它和收起**窗口**
    /// 的宽度差着两个 `activeFlankWidth`，而带子在窗口里是居中的 —— 这两个宽度
    /// 混用过一次（2026-09-24）：把带子宽当成窗口宽传进去，画出来的红色挂断图标
    /// 和点得到的矩形差了 71pt，而屏幕上完全看不出来（图标照画，只是点不准）。
    static func trailingWingOriginX(inBandOfWidth bandWidth: CGFloat) -> CGFloat {
        bandWidth - trailingWingWidth
    }

    /// 同一个值，但相对于**收起窗口**的左边界 —— 收起态的命中矩形用的是这个。
    ///
    /// 带子在窗口里居中，所以先把窗口坐标还原成带子坐标，再问上面那个函数：
    /// 「右翼是带子的最后一段」这句话全仓库只有一份。
    static func trailingWingOriginX(inWindowOfWidth windowWidth: CGFloat) -> CGFloat {
        let bandWidth = windowWidth - activeFlankWidth * 2
            + leadingWingWidth + trailingWingWidth - 4
        return (windowWidth - bandWidth) / 2
            + trailingWingOriginX(inBandOfWidth: bandWidth)
    }

    /// 刘海本身的高度 —— 收起态两条翼的高度。
    /// （`NotchPillRootView` 用的是窗口高减掉 `restingPillAnimationHeadroom`，
    /// 两者相等，因为收起窗口正是「刘海 + 那点动画余量」。）
    static func notchBandHeight(on screen: NSScreen) -> CGFloat {
        notchRect(on: screen)?.height ?? 0
    }

    /// 展开态那条状态带的高度。
    ///
    /// 展开态那条状态带的高度：**就是刘海的高度**。
    ///
    /// 取两者的较小值是为了防御 —— 早先 `sheetHeaderTopInset` 只有 30、比刘海还矮，
    /// 照刘海高度铺会压掉页头控件的上沿 2pt，所以那时它比刘海矮。现在那个值已经
    /// 抬到刘海之上（见它的说明），`min` 取到的就是刘海本身，用户 2026-09-25 要的
    /// 「跟刘海高度一样」由此成立；同时这个 min 仍然保留：将来若有人把 inset 调回
    /// 刘海以下，带子也不会重新长出那条压边。
    static func expandedWingBandHeight(on screen: NSScreen) -> CGFloat {
        min(notchBandHeight(on: screen), sheetHeaderTopInset)
    }

    /// 收起态那条带子的总宽（左翼 + 中段 + 右翼，含两处 −2 负间距）。
    ///
    /// 展开态的状态带按**同一个宽度**布局才能和收起态逐像素对齐：它把带子放回
    /// 一个同宽的虚拟窗口里居中，而不是在展开窗口里另推一套几何。两态切换时
    /// 带子因此不会横向跳一下。
    static func restingWingBandWidth(on screen: NSScreen) -> CGFloat {
        guard notchRect(on: screen) != nil else { return 0 }
        return leadingWingWidth + restingPillWidth(on: screen) + trailingWingWidth - 4
    }

    /// 收起态那条带子的「中段」宽度（就是那颗 pill）。
    static func restingPillWidth(on screen: NSScreen) -> CGFloat {
        guard let notchRect = notchRect(on: screen) else { return 0 }
        return notchRect.width + restingPillExtraWidthPerSide * 2
    }

    /// 展开态那条状态带里，刘海中心相对于**展开窗口**左上角的 x。
    ///
    /// 收起窗口和展开窗口都水平居中在屏幕上，看起来 `width / 2` 就够了 ——
    /// 但那是**屏幕**的中心，而刘海是「辅助顶栏之间的空隙」，不保证正好在屏幕
    /// 正中。所以这里拿两个真实矩形相减，而不是假设。
    static func notchBandCenterXInExpandedWindow(on screen: NSScreen) -> CGFloat? {
        guard let notchRect = notchRect(on: screen) else { return nil }
        let expandedFrame = expandedSheetFrame(on: screen)
        return screen.frame.minX + notchRect.midX - expandedFrame.minX
    }

    /// The expanded sheet's frame: `expandedSheetSize(on:)`, centered
    /// horizontally and hanging from the screen's top edge.
    static func expandedSheetFrame(on screen: NSScreen) -> CGRect {
        let size = expandedSheetSize(on: screen)
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 全屏态的面板 frame —— 就是整块屏幕。
    ///
    /// 用户 2026-09-26 要求面板顶栏那颗「展开」按钮「点一次展开成全屏，再点一次
    /// 收缩回原来的小窗状态」。全屏这一档**不另算一套几何**：面板要铺满的那块
    /// 屏幕就是 `screen.frame` 本身，而「小窗」那一档已经由 `expandedSheetFrame`
    /// 给全了（同样从屏幕顶边垂下、同样水平居中，只是尺寸小一号）。两档的差别因此
    /// 只有一个尺寸，来回切的时候不可能出现第二种坐标口径。
    ///
    /// 用 `frame` 而不是 `visibleFrame`：全屏就是全屏，菜单栏与 Dock 都该被盖住
    ///（面板本来就活在 `.mainMenu + 1` 这一层，盖得住）。和 `expandedSheetFrame`
    /// 一样，切过去之后 `expansionProgress` 由 `windowDidResize` 从 frame 反推，
    /// 所以三种揭示、状态带、三列内容都不需要知道面板换了档。
    static func fullScreenSheetFrame(on screen: NSScreen) -> CGRect {
        screen.frame
    }

    // MARK: - Fullscreen suppression

    /// Posted when the user drags the sheet's resize grip — the expanded
    /// panel listens and re-frames itself to the new height.
    nonisolated static let wannaNotchSheetSizeDidChange =
        Notification.Name("wannaNotchSheetSizeDidChange")

    /// One display's geometry, as the fullscreen heuristic needs it. Built by
    /// the caller from `NSScreen` because the menu-bar check reads
    /// `visibleFrame`, an AppKit value.
    struct DisplayGeometry {
        let displayID: CGDirectDisplayID
        /// The display's bounds in top-left global coordinates — the space
        /// `kCGWindowBounds` reports, and what `CGDisplayBounds` returns.
        let displayBounds: CGRect
        /// True when the menu bar is currently hidden on this display —
        /// `visibleFrame == frame`. A real fullscreen space hides the menu
        /// bar; ordinary desktops deduct it from `visibleFrame`.
        let isMenuBarHidden: Bool
    }

    /// The displays currently covered by another process's fullscreen window.
    ///
    /// A fullscreen space hides the menu bar, so a pill drawn at the screen
    /// top would float over the fullscreen app's content — the pill is hidden
    /// there. There is no public "which displays show a fullscreen space"
    /// API, so the heuristic reads the on-screen window list and
    /// requires BOTH signals, because either alone misfires:
    ///
    ///  * a layer-0 window from another process covering the whole display —
    ///    alone this misfires on this machine's `cua-driver`, a resident
    ///    computer-use driver that keeps an invisible full-screen overlay
    ///    window up at all times (measured 2026-09-22: it covers the display
    ///    at alpha 1.0 with the desktop clearly not fullscreen);
    ///  * the menu bar hidden on that display (`visibleFrame == frame`) —
    ///    alone this misfires on Dock auto-hide.
    ///
    /// Re-checked on every space change rather than cached — spaces change
    /// without the app being told which display.
    static func displaysCoveredByOtherProcessFullscreen(
        displayGeometries: [DisplayGeometry],
        ownProcessID: pid_t
    ) -> Set<CGDirectDisplayID> {
        var coveredDisplayIDs: Set<CGDirectDisplayID> = []

        guard let windowList = CGWindowListCopyWindowInfo(
            [ .optionOnScreenOnly, .excludeDesktopElements ],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return coveredDisplayIDs
        }

        for windowInfo in windowList {
            guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                  windowLayer == 0,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) != ownProcessID,
                  let windowBoundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let windowX = windowBoundsDictionary["X"] as? CGFloat,
                  let windowY = windowBoundsDictionary["Y"] as? CGFloat,
                  let windowWidth = windowBoundsDictionary["Width"] as? CGFloat,
                  let windowHeight = windowBoundsDictionary["Height"] as? CGFloat,
                  windowWidth > 0, windowHeight > 0 else {
                continue
            }

            let windowBounds = CGRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)

            for geometry in displayGeometries {
                if geometry.isMenuBarHidden,
                   windowBounds.contains(geometry.displayBounds) {
                    coveredDisplayIDs.insert(geometry.displayID)
                }
            }
        }

        return coveredDisplayIDs
    }
}
