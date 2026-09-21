//
//  MacosUseController.swift
//  leanring-buddy
//
//  Turns a parsed `CompanionAction` into a real thing happening on the user's
//  machine, and owns the one piece of arithmetic that makes it land in the right
//  place.
//
//  This is the only file that imports MacosUseSDK. Everything upstream of it —
//  the tags, the parser, the prompt — is ordinary Clicky code, so the dependency
//  has exactly one seam to move if it ever has to be replaced.
//
//  ## The coordinate question, which is the whole risk
//
//  Two coordinate systems meet here and they disagree about which way is up:
//
//  - The **model** reports positions on a 0–1000 grid over the screenshot it was
//    shown (`[POINT:860,50]`), because Qwen's vision models rescale images
//    internally before looking at them.
//  - **CGEvent and the Accessibility API** both take *Quartz global* coordinates:
//    origin at the top-left of the main display, y increasing downward, and each
//    additional display positioned relative to it — a screen above the main one
//    has a **negative** y.
//  - **AppKit** — which the existing pointing code converts into before handing a
//    position to the overlay — uses bottom-left origin, y increasing upward.
//
//  Handing an AppKit point to `clickMouse` mirrors the click vertically. It does
//  not throw, log, or crash; the pointer simply lands somewhere else, which is
//  the same silent-failure shape as the normalized-coordinate bug this project
//  already has a write-up for (`开发经验/10-踩过的坑.md` H3).
//
//  So the conversion runs one way only — the model's grid, to the display's own
//  top-left space, to that display's Quartz origin — and the AppKit flip happens
//  *only* on the overlay's side of the fence. `displayLocalPoint` below is shared
//  with the pointing path so that the cursor and the click cannot drift apart.
//

import AppKit
import ApplicationServices
import MacosUseSDK

/// What came of trying to perform an action.
nonisolated struct ActionExecutionOutcome: Sendable {
    /// One short line for the panel — what was done, or why nothing was.
    ///
    /// Actions have to be visible. The companion speaks an answer either way, so
    /// without this line a user cannot tell "it clicked the button" from "it told
    /// me where the button is".
    let description: String
    /// Text the model should see on its **next** turn, or nil when there is none.
    ///
    /// Only the accessibility read produces this. It is handed over as context
    /// rather than folded into the spoken answer because it is a list of your
    /// screen's contents, and reading it aloud would be absurd.
    let contextForNextTurn: String?
}

enum MacosUseController {

    // MARK: - Permission

    /// Whether the process may post synthetic events and read other apps' trees.
    ///
    /// Both halves of this feature need the same permission, so there is one check
    /// rather than one per action. `openApplication` is the exception — it goes
    /// through `NSWorkspace` and works without it.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Whether this launch has already sent the user off to grant Accessibility.
    ///
    /// Set the first time an action is refused for lack of permission; see the
    /// guard in `execute` for why it is not done on every refusal.
    private static var hasAskedForAccessibilityThisLaunch = false

    // MARK: - Coordinate conversion

    /// Where a reported coordinate lands **within its own display**, with the
    /// top-left corner of that display as the origin.
    ///
    /// This is the shared half of the conversion: the screenshot, Quartz and the
    /// model all agree that (0,0) is the top-left corner of the screen, and they
    /// only disagree about where on the desk that screen sits. Both the pointing
    /// path and the acting path call this, so "the cursor points accurately but
    /// the click lands somewhere else" is not a state this code can reach.
    ///
    /// The image-to-display scaling is not optional: the screenshot is captured at
    /// a capped size (1280px by default) while the display reports points, and
    /// skipping the ratio puts every click at the wrong fraction of the way across.
    nonisolated static func displayLocalPoint(
        fromNormalizedPoint normalizedPoint: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let pointInScreenshotPixels = CompanionManager.screenshotPixelCoordinate(
            fromNormalizedPoint: normalizedPoint,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        )

        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)

        // A model can report a coordinate a hair past the edge. Clamping keeps that
        // a click at the rim rather than a click on a display that isn't there.
        let clampedX = max(0, min(pointInScreenshotPixels.x, screenshotWidth))
        let clampedY = max(0, min(pointInScreenshotPixels.y, screenshotHeight))

        return CGPoint(
            x: clampedX * (displayWidth / screenshotWidth),
            y: clampedY * (displayHeight / screenshotHeight)
        )
    }

    /// The Quartz global point — what `CGEvent` and the Accessibility API want —
    /// for a coordinate the model reported.
    nonisolated static func quartzGlobalPoint(
        fromNormalizedPoint normalizedPoint: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let pointWithinDisplay = displayLocalPoint(
            fromNormalizedPoint: normalizedPoint,
            in: screenCapture
        )
        let quartzOrigin = CGDisplayBounds(screenCapture.displayID).origin
        return CGPoint(
            x: pointWithinDisplay.x + quartzOrigin.x,
            y: pointWithinDisplay.y + quartzOrigin.y
        )
    }

    /// The reverse: a Quartz global point expressed back on the model's 0–1000
    /// grid, together with which screen it is on.
    ///
    /// Used to describe elements found through the Accessibility API. They have to
    /// be converted back, not passed through: the model has only ever been told
    /// about the normalized grid, so a raw Quartz coordinate in the prompt would
    /// come back as a normalized one and send the click to the far corner.
    ///
    /// Returns nil when the point is on a screen the model was not shown.
    nonisolated static func reportedCoordinate(
        fromQuartzGlobalPoint quartzPoint: CGPoint,
        among screenCaptures: [CompanionScreenCapture]
    ) -> ModelReportedCoordinate? {
        for (screenIndex, screenCapture) in screenCaptures.enumerated() {
            let quartzBounds = CGDisplayBounds(screenCapture.displayID)
            guard quartzBounds.contains(quartzPoint) else { continue }

            let pointWithinDisplay = CGPoint(
                x: quartzPoint.x - quartzBounds.origin.x,
                y: quartzPoint.y - quartzBounds.origin.y
            )

            return ModelReportedCoordinate(
                normalizedCoordinate: CGPoint(
                    x: pointWithinDisplay.x / quartzBounds.width * 1000,
                    y: pointWithinDisplay.y / quartzBounds.height * 1000
                ),
                elementLabel: nil,
                screenNumber: screenIndex + 1
            )
        }

        return nil
    }

    /// Picks the screen an action should happen on: the one the model named, or
    /// else the one the mouse is on.
    ///
    /// The model's screen numbers are positions in the list it was shown (its
    /// label reads "screen 2 of 3"), which is the same order `screenCaptures`
    /// arrives in — not the system's display ID.
    nonisolated static func screenCapture(
        for reportedCoordinate: ModelReportedCoordinate,
        among screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        if let screenNumber = reportedCoordinate.screenNumber,
           screenNumber >= 1,
           screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }
        return screenCaptures.first(where: { $0.isCursorScreen })
    }

    // MARK: - Executing

    /// Performs one action and reports what happened.
    ///
    /// Every switch the settings page offers is enforced **here**, at the moment
    /// of acting, rather than by filtering the tags earlier. That is deliberate: a
    /// setting that saves but does nothing is worse than no setting at all
    /// (`开发经验/10-踩过的坑.md` A1), so the check sits on the one path every
    /// action has to travel.
    static func execute(
        _ action: CompanionAction,
        among screenCaptures: [CompanionScreenCapture]
    ) async -> ActionExecutionOutcome {
        let appSettings = AppSettingsStore.snapshot()

        guard appSettings.allowsComputerControl else {
            return ActionExecutionOutcome(
                description: "「允许 Clicky 操作电脑」是关着的，这次只说了没动手。",
                contextForNextTurn: nil
            )
        }

        // Opening an app goes through NSWorkspace and needs no Accessibility
        // permission, so it is handled before the check below rather than being
        // blocked by a permission it does not use.
        if case .openApplication(let applicationName) = action {
            return await openApplication(named: applicationName)
        }

        guard isAccessibilityTrusted else {
            // Without this, the user is told to go press a button in a panel they
            // have no reason to connect with "it can't click" — which is exactly
            // how the first person to use this feature got stuck. Asking here
            // raises macOS's own alert (which also adds Clicky to the
            // Accessibility list) and, on a later attempt, opens that pane.
            //
            // Only once per launch: the second and later calls in
            // `requestAccessibilityPermission()` open System Settings, so asking
            // on every refusal would pull the user out of their work each time
            // the model tried to act.
            var description = "还没有辅助功能权限，动不了手 —— 授权之后再说一次就行。"
            if !hasAskedForAccessibilityThisLaunch {
                hasAskedForAccessibilityThisLaunch = true
                switch WindowPositionManager.requestAccessibilityPermission() {
                case .systemPrompt:
                    description = "还没有辅助功能权限，动不了手 —— 我把系统授权弹窗打开了，点「打开系统设置」把 Clicky 勾上，然后再说一次。"
                case .systemSettings:
                    description = "还没有辅助功能权限，动不了手 —— 我把「辅助功能」设置页打开了，把 Clicky 勾上，然后再说一次。"
                case .alreadyGranted:
                    description = "辅助功能权限刚授权好，再说一次就能动手了。"
                }
            }
            return ActionExecutionOutcome(description: description, contextForNextTurn: nil)
        }

        switch action {
        case .openApplication:
            // Handled above; the compiler still wants it covered.
            return ActionExecutionOutcome(description: "没有执行。", contextForNextTurn: nil)

        case .click(let reportedCoordinate):
            return await performClickAction(
                named: "点击",
                at: reportedCoordinate,
                among: screenCaptures,
                kind: .left
            )

        case .rightClick(let reportedCoordinate):
            return await performClickAction(
                named: "右键点击",
                at: reportedCoordinate,
                among: screenCaptures,
                kind: .right
            )

        case .doubleClick(let reportedCoordinate):
            return await performClickAction(
                named: "双击",
                at: reportedCoordinate,
                among: screenCaptures,
                kind: .double
            )

        case .scroll(let reportedCoordinate, let direction, let amountInSteps):
            return await performScrollAction(
                at: reportedCoordinate,
                direction: direction,
                amountInSteps: amountInSteps,
                among: screenCaptures
            )

        case .typeText(let textToType):
            guard appSettings.allowsKeyboardControl else {
                return ActionExecutionOutcome(
                    description: "「允许打字和按快捷键」是关着的，跳过了这次输入。",
                    contextForNextTurn: nil
                )
            }
            do {
                let typedLineCount = try typeMultilineText(
                    textToType,
                    textEntryMethod: appSettings.textEntryMethod
                )
                return ActionExecutionOutcome(
                    description: typedLineCount > 1
                        ? "输入了 \(textToType.count) 个字（\(typedLineCount) 行）。"
                        : "输入了 \(textToType.count) 个字。",
                    contextForNextTurn: nil
                )
            } catch {
                return ActionExecutionOutcome(
                    description: "输入失败：\(error.localizedDescription)",
                    contextForNextTurn: nil
                )
            }

        case .pressKey(let keyName, let modifierNames):
            guard appSettings.allowsKeyboardControl else {
                return ActionExecutionOutcome(
                    description: "「允许打字和按快捷键」是关着的，跳过了这次按键。",
                    contextForNextTurn: nil
                )
            }
            return performKeyPressAction(keyName: keyName, modifierNames: modifierNames)

        case .readAccessibilityTree:
            return await readAccessibilityTreeTask(among: screenCaptures)
        }
    }

    // MARK: - Mouse actions

    /// Which of the three mouse buttons-and-counts to deliver.
    private enum ClickKind {
        case left
        case right
        case double
    }

    private static func performClickAction(
        named actionName: String,
        at reportedCoordinate: ModelReportedCoordinate,
        among screenCaptures: [CompanionScreenCapture],
        kind: ClickKind
    ) async -> ActionExecutionOutcome {
        guard let clickPoint = await resolvedClickPoint(
            for: reportedCoordinate,
            among: screenCaptures
        ) else {
            return ActionExecutionOutcome(
                description: "找不到要操作的那块屏幕，\(actionName)没有执行。",
                contextForNextTurn: nil
            )
        }

        do {
            switch kind {
            case .left:
                try clickMouse(at: clickPoint)
            case .right:
                try rightClickMouse(at: clickPoint)
            case .double:
                try doubleClickMouse(at: clickPoint)
            }

            return ActionExecutionOutcome(
                description: "\(actionName)了\(describeTarget(reportedCoordinate, at: clickPoint))。",
                contextForNextTurn: nil
            )
        } catch {
            return ActionExecutionOutcome(
                description: "\(actionName)失败：\(error.localizedDescription)",
                contextForNextTurn: nil
            )
        }
    }

    private static func performScrollAction(
        at reportedCoordinate: ModelReportedCoordinate,
        direction: ScrollDirection,
        amountInSteps: Int,
        among screenCaptures: [CompanionScreenCapture]
    ) async -> ActionExecutionOutcome {
        guard let screenCapture = screenCapture(for: reportedCoordinate, among: screenCaptures) else {
            return ActionExecutionOutcome(
                description: "找不到要滚动的那块屏幕，滚动没有执行。",
                contextForNextTurn: nil
            )
        }

        let scrollPoint = quartzGlobalPoint(
            fromNormalizedPoint: reportedCoordinate.normalizedCoordinate,
            in: screenCapture
        )

        // The SDK takes signed line counts: positive scrolls down, negative up.
        let stepCount = max(1, min(amountInSteps, maximumScrollStepsPerAction))
        let signedSteps = Int32(direction == .down ? stepCount : -stepCount)

        do {
            try scrollWheel(at: scrollPoint, deltaY: signedSteps)
            let directionWord = direction == .down ? "向下" : "向上"
            return ActionExecutionOutcome(
                description: "\(directionWord)滚了 \(stepCount) 行。",
                contextForNextTurn: nil
            )
        } catch {
            return ActionExecutionOutcome(
                description: "滚动失败：\(error.localizedDescription)",
                contextForNextTurn: nil
            )
        }
    }

    // MARK: - Keyboard actions

    /// Types text, turning line breaks into **real Return key presses**, and
    /// returns how many lines were typed.
    ///
    /// The SDK's `writeText` posts every character — a line break included — as a
    /// virtualKey-0 event carrying a Unicode payload
    /// (`CGEventKeyboardSetUnicodeString`, see `MacosUseSDK/InputController.swift`
    /// `writeText`). Visible characters land fine, but editors ignore an
    /// *injected* U+000A: they insert text on a keypress and take a new line only
    /// from the Return key itself, so a multi-line `[TYPE:]` used to come out as
    /// one long line and a Markdown table arrived flattened. This is measured, not
    /// assumed — typing a two-row table through the raw path put the whole table on
    /// the document's first line.
    ///
    /// The fix stays on this side of the SDK seam deliberately: the SDK is an SPM
    /// dependency pinned to a revision, so patching its checkout would be undone by
    /// the next resolve. Text is split into lines, each written through the Unicode
    /// path (so Chinese and emoji still work), and the lines are joined with real
    /// Return presses via the SDK's own `pressKey` + key table — one table, not two.
    ///
    /// The prompt teaches the model to write `\n` inside the tag, because a literal
    /// newline inside `[TYPE:…]` is easy for a model to mangle; both spellings are
    /// accepted here.
    ///
    /// The user picks the delivery in the settings window
    /// (`AppSettings.textEntryMethod`). 粘贴 mode hands the whole text to
    /// `pasteText` — a single cmd+v carries line breaks natively, so no Return
    /// presses are needed — and falls back to the typing path if the "v" key is
    /// ever missing from the SDK's table, rather than failing.
    private static func typeMultilineText(
        _ textToType: String,
        textEntryMethod: TextEntryMethod
    ) throws -> Int {
        let normalizedText = textToType
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")

        if textEntryMethod == .pasteClipboard,
           let pasteKeyCode = mapKeyNameToKeyCode("v") {
            try pasteText(normalizedText, keyCode: pasteKeyCode)
            return lines.count
        }

        // "return" is in the SDK's own key table. If that ever changes, degrade to
        // the raw write rather than inventing a second table here (see A4 in
        // 开发经验/10-踩过的坑.md for what a second key table costs).
        guard let returnKeyCode = mapKeyNameToKeyCode("return") else {
            try writeText(normalizedText)
            return 1
        }

        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 {
                try pressKey(keyCode: returnKeyCode)
            }
            if !line.isEmpty {
                try writeText(line)
            }
        }

        return lines.count
    }

    /// Delivers text by putting it on the clipboard and pressing cmd+v.
    ///
    /// One paste carries line breaks natively and is far faster than one key
    /// event per character. The cost is borrowing the user's clipboard, so
    /// everything currently on it is snapshotted first and written back after a
    /// delay: the paste is processed by the target app some time after the event
    /// is posted, and restoring immediately could race it — the app would read
    /// the *old* clipboard contents back.
    private static func pasteText(_ textToPaste: String, keyCode pasteKeyCode: CGKeyCode) throws {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.pasteboardItems?.map { pasteboardItem in
            Dictionary(uniqueKeysWithValues: pasteboardItem.types.compactMap { pasteboardType in
                pasteboardItem.data(forType: pasteboardType).map { (pasteboardType, $0) }
            })
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(textToPaste, forType: .string)

        // "cmd" is in the parser's modifier table — see
        // `ActionTagParser.modifierFlag(named:)` for why there is only one table.
        try pressKey(keyCode: pasteKeyCode, flags: modifierFlag(named: "cmd") ?? [])

        // The half-second wait is the race guard, not polish: shorter and the
        // target app may not have read the pasteboard yet when it is restored.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            for contents in previousContents {
                let restoredItem = NSPasteboardItem()
                for (pasteboardType, itemData) in contents {
                    restoredItem.setData(itemData, forType: pasteboardType)
                }
                pasteboard.writeObjects([restoredItem])
            }
        }
    }

    private static func performKeyPressAction(
        keyName: String,
        modifierNames: [String]
    ) -> ActionExecutionOutcome {        // A model can invent a key name. The SDK's map covers the letters, digits,
        // arrows, function keys and the common named keys, and returns nil for
        // anything else — which is reported rather than silently ignored.
        if let numericKeyCode = CGKeyCode(keyName) {
            return postKeyPress(keyCode: numericKeyCode, keyName: keyName, modifierNames: modifierNames)
        }

        guard let keyCode = mapKeyNameToKeyCode(keyName) else {
            return ActionExecutionOutcome(
                description: "不认识「\(keyName)」这个键，没有按。",
                contextForNextTurn: nil
            )
        }

        return postKeyPress(keyCode: keyCode, keyName: keyName, modifierNames: modifierNames)
    }

    private static func postKeyPress(
        keyCode: CGKeyCode,
        keyName: String,
        modifierNames: [String]
    ) -> ActionExecutionOutcome {
        let unknownModifierNames = modifierNames.filter { modifierFlag(named: $0) == nil }
        guard unknownModifierNames.isEmpty else {
            return ActionExecutionOutcome(
                description: "不认识「\(unknownModifierNames.joined(separator: "+"))」这个修饰键，没有按。",
                contextForNextTurn: nil
            )
        }

        var modifierFlags: CGEventFlags = []
        for modifierName in modifierNames {
            if let flag = modifierFlag(named: modifierName) {
                modifierFlags.insert(flag)
            }
        }

        do {
            try pressKey(keyCode: keyCode, flags: modifierFlags)
            let describedKeys = (modifierNames + [keyName]).joined(separator: "+")
            return ActionExecutionOutcome(
                description: "按下了 \(describedKeys)。",
                contextForNextTurn: nil
            )
        } catch {
            return ActionExecutionOutcome(
                description: "按键失败：\(error.localizedDescription)",
                contextForNextTurn: nil
            )
        }
    }

    /// Maps the modifier words a model writes into the event flags they mean.
    ///
    /// The table itself lives with the tag parser — see
    /// `ActionTagParser.modifierFlag(named:)` for why this is not defined here.
    private static func modifierFlag(named modifierName: String) -> CGEventFlags? {
        ActionTagParser.modifierFlag(named: modifierName)
    }

    // MARK: - Aiming a click

    /// The point to actually click for a coordinate the model reported.
    ///
    /// A vision model reading a downscaled screenshot is off by a little, and a
    /// little is enough to miss a small button. The Accessibility tree knows where
    /// the element really is, so when hit-testing the estimated point lands on a
    /// **small** control, its centre is used instead — which turns "roughly there"
    /// into "exactly there".
    ///
    /// Only small elements are snapped to. Hit-testing a window, a scroll view or
    /// a list returns the container, and the centre of a window is not what anyone
    /// asked for — so a container is left alone and the model's own estimate is
    /// used, which is what the app did before any of this existed.
    private static func resolvedClickPoint(
        for reportedCoordinate: ModelReportedCoordinate,
        among screenCaptures: [CompanionScreenCapture]
    ) async -> CGPoint? {
        guard let screenCapture = screenCapture(for: reportedCoordinate, among: screenCaptures) else {
            return nil
        }

        let estimatedPoint = quartzGlobalPoint(
            fromNormalizedPoint: reportedCoordinate.normalizedCoordinate,
            in: screenCapture
        )

        // A target the model named is found by that name, and the estimate is never
        // consulted — see `accessibilityElementFrame(matchingLabel:nearestTo:)` for
        // the measurements that made this the first thing tried rather than the
        // fallback.
        if let elementLabel = reportedCoordinate.elementLabel, !elementLabel.isEmpty {
            let namedFrame = await accessibilityElementFrame(
                matchingLabel: elementLabel,
                nearestTo: estimatedPoint
            )
            if let namedFrame {
                return CGPoint(x: namedFrame.midX, y: namedFrame.midY)
            }
        }

        // Off the main actor: an accessibility call is a synchronous round trip to
        // another process, and a busy app can hold it for a while. Blocking there
        // would freeze the cursor mid-flight.
        let snappedFrame = await Task.detached(priority: .userInitiated) {
            accessibilityElementFrame(near: estimatedPoint)
        }.value

        guard let snappedFrame,
              snappedFrame.width <= maximumSnappableElementWidth,
              snappedFrame.height <= maximumSnappableElementHeight else {
            return estimatedPoint
        }

        return CGPoint(x: snappedFrame.midX, y: snappedFrame.midY)
    }

    // MARK: - Aiming the pointer

    /// Where the companion cursor should fly for a coordinate the model reported,
    /// in **AppKit global** coordinates — the space the overlay windows speak.
    ///
    /// Pointing was the last path still aiming with the model's own estimate, and
    /// this is the half of 定位不准 the user could still see. The two paths used
    /// to disagree about the same element: asked to click Calculator's "7" key,
    /// the click landed on the key's centre five times out of five while the
    /// cursor — pointed at that same key, from the same reply — flew to a spot a
    /// fifth of the screen away, and only because the click was the path that
    /// consulted the name. Both now resolve through `resolvedClickPoint`, so "the
    /// cursor pointed here and the click landed over there" is not a state this
    /// code can reach.
    ///
    /// The price is paid before the flight rather than during it: resolving by
    /// name is a synchronous walk of the frontmost app's accessibility tree
    /// (0.17–0.37 s measured), so the cursor is told where to go a beat later
    /// than it used to be. Aiming at the estimate first and correcting mid-flight
    /// would start sooner and read as a stumble.
    ///
    /// The flip is the same one the overlay has always needed — the display's
    /// height minus the point's distance from its top — but it is done against
    /// the display the point actually **landed on**, which is not always the one
    /// the model named: a label can match an element on another monitor, and
    /// flipping against the wrong screen's height puts the cursor on a screen
    /// that isn't there.
    static func resolvedPointerLocation(
        for reportedCoordinate: ModelReportedCoordinate,
        among screenCaptures: [CompanionScreenCapture]
    ) async -> (appKitLocation: CGPoint, displayFrame: CGRect)? {
        guard let namedScreenCapture = screenCapture(for: reportedCoordinate, among: screenCaptures),
              let quartzPoint = await resolvedClickPoint(
                  for: reportedCoordinate,
                  among: screenCaptures
              ) else {
            return nil
        }

        let displayContainingPoint = screenCaptures.first(where: {
            CGDisplayBounds($0.displayID).contains(quartzPoint)
        }) ?? namedScreenCapture

        let quartzOrigin = CGDisplayBounds(displayContainingPoint.displayID).origin
        let pointWithinDisplay = CGPoint(
            x: quartzPoint.x - quartzOrigin.x,
            y: quartzPoint.y - quartzOrigin.y
        )

        let displayFrame = displayContainingPoint.displayFrame

        return (
            appKitLocation: CGPoint(
                x: pointWithinDisplay.x + displayFrame.origin.x,
                y: (displayFrame.height - pointWithinDisplay.y) + displayFrame.origin.y
            ),
            displayFrame: displayFrame
        )
    }

    /// The frame of the element the model *named*, found by that name in the app in
    /// front.
    ///
    /// **This is what makes a click land, and it exists because measuring said the
    /// estimate cannot.** The model reads a screenshot that has been scaled down to
    /// fit one request, and its error is not small: asked twice, in the same words,
    /// to click Calculator's "7" key — whose centre sits at normalized (572, 668) —
    /// it answered (320, 599) once and (700, 700) the next time, misses of roughly a
    /// quarter of the screen's width in *opposite* directions. Hit-testing cannot
    /// repair that, because a hit test only reports the element *under* the estimate:
    /// the estimate has to land on the target before snapping to its centre helps it.
    /// It landed on a 1201x1436 container instead, and the click was left at the
    /// guessed point — beside the key rather than on it, with Calculator still
    /// reading 0.
    ///
    /// The label in the tag has no such problem. `[CLICK:700,700:7]` names the key,
    /// and the accessibility tree names it too — `AXButton "7"` at a precise
    /// rectangle — so the element is found by name and its centre clicked without
    /// consulting the estimate at all. That is why the estimate is now the second
    /// thing tried rather than the first.
    ///
    /// The estimate is still used, but only to break ties between equally good name
    /// matches: an app with two controls called "7" is a labelling problem, and the
    /// one nearest what the model pointed at is the one it meant.
    ///
    /// Returns nil when the tag carries no label, when the label names nothing in the
    /// app in front, or when that app will not talk — and the caller falls back to
    /// the estimate, which is what this did before any of it existed.
    private static func accessibilityElementFrame(
        matchingLabel elementLabel: String,
        nearestTo quartzPoint: CGPoint
    ) async -> CGRect? {
        let searchedLabel = elementLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !searchedLabel.isEmpty else { return nil }

        // Only the app in front is searched. A click at a coordinate works on any
        // window, because it is a click at a point — but a *name* is only meaningful
        // once you know whose names you are reading, and acting on a match in an app
        // the user is not looking at is how the wrong thing gets clicked.
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let processIdentifier = frontmostApplication.processIdentifier

        // Off the main actor: walking the tree is a synchronous round trip to the
        // other process, and the cursor animation is running.
        return await Task.detached(priority: .userInitiated) { () -> CGRect? in
            guard let responseData = try? traverseAccessibilityTree(
                pid: processIdentifier,
                onlyVisibleElements: true
            ) else {
                return nil
            }

            var bestFrame: CGRect?
            var bestRank = (
                nameRank: Int.max,
                sizeRank: Int.max,
                distance: CGFloat.greatestFiniteMagnitude
            )

            for element in responseData.elements {
                guard let elementText = element.text, !elementText.isEmpty,
                      let x = element.x, let y = element.y,
                      let width = element.width, let height = element.height,
                      width >= 1, height >= 1 else {
                    continue
                }

                let lowercasedElementText = elementText.lowercased()
                guard lowercasedElementText.contains(searchedLabel) else { continue }

                let frame = CGRect(x: x, y: y, width: width, height: height)
                let rank = (
                    // An element *called* "7" beats one that merely mentions it…
                    nameRank: lowercasedElementText == searchedLabel ? 0 : 1,
                    // …a control beats the window that contains it, because the
                    // centre of a window is not where anyone pointed…
                    sizeRank: frame.width <= maximumSnappableElementWidth
                        && frame.height <= maximumSnappableElementHeight ? 0 : 1,
                    // …and past that, the one nearest what the model pointed at.
                    distance: hypot(frame.midX - quartzPoint.x, frame.midY - quartzPoint.y)
                )

                if rank < bestRank {
                    bestRank = rank
                    bestFrame = frame
                }
            }

            return bestFrame
        }.value
    }

    /// The frame of whatever element sits under `quartzPoint` on any screen.
    ///
    /// Hit-tests through the **system-wide** element rather than an application's,
    /// because that is the only way to ask "what is at this position" without
    /// first knowing which app owns it. The frame comes back in the same Quartz
    /// space the point went in as, so the result is usable as a click target
    /// directly — no conversion, which is the reason this works at all.
    private nonisolated static func accessibilityElementFrame(near quartzPoint: CGPoint) -> CGRect? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitTestError = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &hitElement
        )

        guard hitTestError == .success, let hitElement else { return nil }
        return accessibilityFrame(of: hitElement)
    }

    /// Reads an element's screen-space frame (Quartz origin, top-left).
    private nonisolated static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              // Checked before the cast: an element that answers with something
              // other than an AXValue would trap, not throw.
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    // MARK: - Opening an application

    private static func openApplication(named applicationName: String) async -> ActionExecutionOutcome {
        // The SDK resolves a name by trying a fixed set of paths built from it, which
        // only works when the name is the bundle's file name. A question asked in
        // Chinese gets answered with the Chinese name — 「计算器」 — while the bundle
        // on disk is `Calculator.app`, so the match has to be made against the name
        // macOS itself shows, the way Spotlight and the Finder do it.
        let identifier = applicationBundleURL(matchingName: applicationName)?.path ?? applicationName

        do {
            // Module-qualified: this type has a method of the same name, and the
            // unqualified call resolves to that one instead of the SDK's function.
            let result = try await MacosUseSDK.openApplication(identifier: identifier)
            return ActionExecutionOutcome(
                description: "打开了 \(result.appName)。",
                contextForNextTurn: nil
            )
        } catch {
            return ActionExecutionOutcome(
                description: "打不开「\(applicationName)」：\(error.localizedDescription)",
                contextForNextTurn: nil
            )
        }
    }

    /// Finds an installed application whose name matches, in any of the spellings
    /// macOS considers the same app.
    ///
    /// Compared case-insensitively against the bundle's file name, the name the
    /// Finder displays, and the localized display and bundle names — the last two
    /// are what carry the translated name, and are why 「备忘录」 finds Notes.
    private static func applicationBundleURL(matchingName applicationName: String) -> URL? {
        let trimmedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        // A full path, or something that already ends in .app, is taken at face value.
        if trimmedName.hasSuffix(".app") {
            let candidatePath = trimmedName.hasPrefix("/")
                ? trimmedName
                : "/Applications/\(trimmedName)"
            if FileManager.default.fileExists(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath)
            }
        }

        let nameWithoutExtension = trimmedName.hasSuffix(".app")
            ? String(trimmedName.dropLast(".app".count))
            : trimmedName

        let searchDirectories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        for directory in searchDirectories {
            let directoryURL = URL(fileURLWithPath: directory)
            guard let bundleURLs = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for bundleURL in bundleURLs where bundleURL.pathExtension == "app" {
                if applicationBundle(bundleURL, isNamed: nameWithoutExtension) {
                    return bundleURL
                }
            }
        }

        return nil
    }

    private static func applicationBundle(_ bundleURL: URL, isNamed searchedName: String) -> Bool {
        func matches(_ candidateName: String?) -> Bool {
            guard let candidateName else { return false }
            return candidateName.compare(searchedName, options: .caseInsensitive) == .orderedSame
        }

        if matches(bundleURL.deletingPathExtension().lastPathComponent) {
            return true
        }

        // The Finder's name is the localized one, and is what a person would say.
        if matches(FileManager.default.displayName(atPath: bundleURL.path)) {
            return true
        }

        guard let bundle = Bundle(url: bundleURL) else { return false }
        return matches(bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            || matches(bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            || matches(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    // MARK: - Reading the accessibility tree

    /// Reads the frontmost app's interface and describes it for the model.
    ///
    /// This is what makes a second step possible: the model cannot see a button's
    /// exact position in a screenshot well enough to click it, but it can ask for
    /// the list and then click a named element at coordinates taken from it.
    private static func readAccessibilityTreeTask(
        among screenCaptures: [CompanionScreenCapture]
    ) async -> ActionExecutionOutcome {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return ActionExecutionOutcome(
                description: "没有别的应用在前台，没读到界面。",
                contextForNextTurn: nil
            )
        }

        let applicationName = frontmostApplication.localizedName ?? "这个应用"
        let processIdentifier = frontmostApplication.processIdentifier

        // Off the main actor on purpose: this walks up to a couple of thousand
        // elements synchronously, and the cursor animation is running.
        let responseData = await Task.detached(priority: .userInitiated) {
            try? traverseAccessibilityTree(pid: processIdentifier, onlyVisibleElements: true)
        }.value

        guard let responseData else {
            return ActionExecutionOutcome(
                description: "读不到「\(applicationName)」的界面，它可能没有开放辅助功能信息。",
                contextForNextTurn: nil
            )
        }

        let summaryText = accessibilitySummaryText(
            from: responseData,
            among: screenCaptures
        )

        return ActionExecutionOutcome(
            description: "读了「\(applicationName)」的界面，共 \(responseData.elements.count) 个元素。",
            contextForNextTurn: summaryText
        )
    }

    /// Renders the element list as prompt text.
    ///
    /// Coordinates are converted back onto the model's 0–1000 grid so the model can
    /// reuse them in a `[CLICK:x,y]` tag verbatim. Elements the model was never
    /// shown — on a screen that was not captured — are dropped rather than
    /// described, because it has no way to act on them.
    private nonisolated static func accessibilitySummaryText(
        from responseData: ResponseData,
        among screenCaptures: [CompanionScreenCapture]
    ) -> String {
        var elementLines: [String] = []

        for element in responseData.elements {
            guard elementLines.count < maximumAccessibilityElementsInSummary else { break }
            guard let elementText = element.text, !elementText.isEmpty else { continue }
            guard let x = element.x, let y = element.y,
                  let width = element.width, let height = element.height else { continue }

            let elementCentreInQuartz = CGPoint(x: x + width / 2, y: y + height / 2)
            guard let reportedCoordinate = reportedCoordinate(
                fromQuartzGlobalPoint: elementCentreInQuartz,
                among: screenCaptures
            ) else {
                continue
            }

            // Colons are stripped because a label containing one would break the
            // very tag the model is about to copy this text into.
            let safeElementText = elementText
                .replacingOccurrences(of: ":", with: " ")
                .replacingOccurrences(of: "\n", with: " ")

            elementLines.append(
                "- \(element.role) \"\(safeElementText)\" at "
                + "\(Int(reportedCoordinate.normalizedCoordinate.x)),"
                + "\(Int(reportedCoordinate.normalizedCoordinate.y)) "
                + "(screen \(reportedCoordinate.screenNumber ?? 1)), "
                + "size \(Int(width))x\(Int(height))"
            )
        }

        let header = """
        Interface of "\(responseData.app_name)", read through the accessibility API. \
        Coordinates are on the same 0-1000 grid as the screenshots, followed by the \
        screen number — use them directly in a tag such as [CLICK:x,y:label:screenN]. \
        Anything the user did not ask you to touch is listed here for information only.
        """

        guard !elementLines.isEmpty else {
            return header + "\n(no labelled elements were found)"
        }

        let truncationNote = responseData.stats.truncated
            ? "\n(list truncated — the app exposes more elements than were read)"
            : ""

        return header + "\n" + elementLines.joined(separator: "\n") + truncationNote
    }

    // MARK: - Describing

    /// Names the thing an action was aimed at, for the panel to show.
    private static func describeTarget(
        _ reportedCoordinate: ModelReportedCoordinate,
        at resolvedPoint: CGPoint
    ) -> String {
        if let elementLabel = reportedCoordinate.elementLabel, !elementLabel.isEmpty {
            return "「\(elementLabel)」"
        }
        return "(\(Int(resolvedPoint.x)), \(Int(resolvedPoint.y)))"
    }

    // MARK: - Limits

    /// How large an element may be before hit-testing stops being an improvement.
    ///
    /// Above this it is a window or a pane rather than a control, and its centre
    /// is not where anyone pointed.
    private static let maximumSnappableElementWidth: CGFloat = 400
    private static let maximumSnappableElementHeight: CGFloat = 120

    /// A ceiling on one scroll command, so a model that says "scroll 9999" nudges
    /// the page instead of throwing it to the bottom.
    private static let maximumScrollStepsPerAction = 30

    /// How many elements of an interface are described to the model. Every line
    /// is prompt text on every following turn, so this is a size limit, not a
    /// correctness one.
    private static let maximumAccessibilityElementsInSummary = 60
}
