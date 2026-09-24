//
//  NotchSupport.swift
//  leanring-buddy
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
//  fork's own design: HeyClicky's reversed docs recovered the *shape names*
//  (`HomeSpaceSheetShape` with menuBarBandHeight / stemWidth / cornerRadius /
//  restingNotchSize / expansionProgress / detachmentProgress / squish) but no
//  values, so the values here are chosen to look right against the reference
//  screenshots.
//

import AppKit
import CoreGraphics

nonisolated enum NotchSupport {
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
    static let curtainContentEntranceDelay: TimeInterval = 0.14

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
    static let centerPopContentEntranceDelay: TimeInterval = 0.23

    /// 收起 = 参考页的 winClose：scale(.92) + 整窗淡出，160ms ease-in。
    static let centerScaleCollapseDuration: TimeInterval = 0.16
    static let centerScaleCollapseFinalScale: CGFloat = 0.92
    /// CSS ease-in（0.42, 0, 1, 1）——参考页 winClose 的 animation-timing-function。
    static let centerScaleCollapseTimingControlPoints: (Float, Float, Float, Float) = (0.42, 0.0, 1.0, 1.0)

    /// 展开动画要多长，按用户选的窗口样式取。
    ///
    /// `NotchWindowController` 用它排那两个截止点（撤掉揭示的遮罩 / 收敛到展开态）
    /// 和看门狗。**两套时长必须从这一个函数出**：控制器里再写一个 switch，等于把
    /// 「动画多久」这件事说两遍，改一处就会留下一处永远等不到的定时器。
    static func expansionRevealDuration(for style: WindowExpansionStyle) -> TimeInterval {
        switch style {
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
    static let sheetHeaderTopInset: CGFloat = restingPillAnimationHeadroom + 8

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
    static let contentColumnHeaderRuleY: CGFloat =
        sheetHeaderTopInset + sidebarSectionSwitcherButtonHeight + sidebarSectionSwitcherBottomPadding

    /// 右列页头**内容**能用的高度：从 `sheetHeaderTopInset` 的下沿到那条线。
    ///
    /// 三页的页头（对话页是顶栏，另两页是它们自己的标题行）都按这个高度排版，内容在
    /// 这条带子里垂直居中，于是每页的页头都恰好在那条线上结束、正文恰好从线下开始。
    static var contentColumnHeaderBandHeight: CGFloat {
        contentColumnHeaderRuleY - sheetHeaderTopInset
    }

    /// The expanded sheet's size — HeyClicky's expanded sheet is *large*, a
    /// real main-window-sized surface (measured off the reference screenshot:
    /// roughly 810×940pt), not a popover. Clamped per screen so small
    /// displays still fit it below the menu bar.
    static func expandedSheetSize(on screen: NSScreen) -> CGSize {
        CGSize(
            width: min(810, screen.frame.width - 40),
            height: expandedSheetHeight(on: screen)
        )
    }

    // MARK: - Sheet height (user-resizable)

    /// HeyClicky's sheet carries a resize grip (`attachedSheetResizeGrip`) and
    /// persists the chosen height (`clicky.homeSpace.attachedSheetSize.v1`).
    /// Same idea here: the height is a user preference, the width stays fixed.
    static let minimumSheetHeight: CGFloat = 520
    /// Keyed by screen height so a second display never inherits a height that
    /// does not fit it — the stored value is a fraction of screen height.
    private static let sheetHeightFractionKey = "clickyNotchSheetHeightFraction"

    /// The sheet's height on this screen: the user's persisted fraction of the
    /// screen height when one was set, otherwise the default (~940pt on a
    /// 14″ MacBook's screen, like the reference screenshot).
    static func expandedSheetHeight(on screen: NSScreen) -> CGFloat {
        let maximum = maximumSheetHeight(on: screen)
        let storedFraction = UserDefaults.standard.double(forKey: sheetHeightFractionKey)
        guard storedFraction > 0 else {
            return min(940, maximum)
        }
        return min(maximum, max(minimumSheetHeight, screen.frame.height * storedFraction))
    }

    static func maximumSheetHeight(on screen: NSScreen) -> CGFloat {
        screen.frame.height - 80
    }

    /// Called by the sheet's resize grip. Stores the height as a fraction of
    /// this screen's height so it scales sensibly across displays, and posts
    /// `.clickyNotchSheetSizeDidChange` so the live panel re-frames itself.
    static func setExpandedSheetHeight(_ newHeight: CGFloat, on screen: NSScreen) {
        let clamped = min(maximumSheetHeight(on: screen), max(minimumSheetHeight, newHeight))
        UserDefaults.standard.set(clamped / screen.frame.height, forKey: sheetHeightFractionKey)
        NotificationCenter.default.post(name: NotchSupport.clickyNotchSheetSizeDidChange, object: nil)
    }

    /// How much wider than the pill the resting *window* is on each side —
    /// the canvas the flanking activity animation draws on while the
    /// companion is active (HeyClicky animates both sides of the notch). At
    /// rest the extra area is fully transparent, and the panel ignores mouse
    /// events while resting, so the menu bar items underneath stay clickable.
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
        return pillFrame.insetBy(dx: -activeFlankWidth, dy: 0)
    }

    // MARK: - Wing geometry (shared by the drawing and the click target)

    /// 收起状态下两条翼的宽度，和 `NotchPillRootView` 画出来的一致。
    ///
    /// 放在 `NotchSupport` 而不是留在那个视图里，是为了让**画的**那一份和
    /// **点的**那一份（`restingTrailingWingFrame`）用的是同一个数字：两边各
    /// 写一遍的话，改了一个忘了另一个，命中区就会错位 —— 而且不报错、不崩，
    /// 只是点不准。
    static let leadingWingWidth: CGFloat = 86
    static let trailingWingWidth: CGFloat = 88

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
    /// **比刘海矮一点是有意的**：面板内容从 `sheetHeaderTopInset`（= 22 + 8 = 30）
    /// 那一条开始画，而刘海是 32 高 —— 直接照刘海的高度铺，这条带子就会压掉页头
    /// 控件的上沿 2pt。右翼横跨刘海右侧 ~88pt，那一段正落在内容列页头那一排按钮
    /// （摄像头 / 屏幕 / 三段式）的左端，所以这 2pt 是真的会露出来的。
    ///
    /// 取两者的较小值，两个数各自改动时都不会重新长出这条压边；代价是展开态的翼
    /// 比收起态矮 2pt，肉眼不可见，而且收起/展开之间横向本来就对齐。
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

    // MARK: - Fullscreen suppression

    /// Posted when the user drags the sheet's resize grip — the expanded
    /// panel listens and re-frames itself to the new height.
    nonisolated static let clickyNotchSheetSizeDidChange =
        Notification.Name("clickyNotchSheetSizeDidChange")

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
    /// top would float over the fullscreen app's content — HeyClicky hides
    /// its pill there (`NotchPanelViewState._isSuppressedForFullscreen`) and
    /// so does this. There is no public "which displays show a fullscreen
    /// space" API, so the heuristic reads the on-screen window list and
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
