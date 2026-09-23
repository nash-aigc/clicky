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

    /// 收起 = 参考页的 winClose：scale(.92) + 整窗淡出，160ms ease-in。
    static let centerScaleCollapseDuration: TimeInterval = 0.16
    static let centerScaleCollapseFinalScale: CGFloat = 0.92
    /// CSS ease-in（0.42, 0, 1, 1）——参考页 winClose 的 animation-timing-function。
    static let centerScaleCollapseTimingControlPoints: (Float, Float, Float, Float) = (0.42, 0.0, 1.0, 1.0)

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
