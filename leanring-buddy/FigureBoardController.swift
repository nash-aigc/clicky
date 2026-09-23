//
//  FigureBoardController.swift
//  leanring-buddy
//
//  The on-screen whiteboard for [SVG_BOARD:元素名：任务] — the screen-anchored
//  sibling of the green [SHAPE:…] marks. When a reply asks for a figure "next
//  to the triangle on screen", CompanionManager resolves the named element's
//  real frame through Accessibility, runs the figure agent with --no-open (the
//  SVG is written to disk but no Preview window opens), and this controller
//  draw that SVG floating directly on the transparent window right beside the
//  element — no card, no surface, just the figure hovering over the screen
//  the way the green marks do (2026-09-24: an earlier white card was rejected
//  by the user as 格格不入; the figure itself is the board).
//
//  The window recipe is ScreenAnnotationManager's verbatim: one transparent,
//  click-through OverlayWindow per shown board, an NSHostingView, an
//  auto-dismiss with a fade, and a generation counter so a stale dismiss task
//  can never fade a newer board. Visual only: the board touches nothing, and
//  — like the marks — it is cleared before every fresh screenshot so the
//  model never sees its own drawing and decides to draw it again.
//

import AppKit
import SwiftUI

@MainActor
final class FigureBoardController {

    /// How long a board stays up before fading on its own. Longer than the
    /// marks' 10 s: a figure carries labelled geometry the user is meant to
    /// read against the problem beside it.
    private static let autoDismissDelaySeconds: TimeInterval = 20
    private static let fadeDurationSeconds: TimeInterval = 0.6

    /// The board's outer size. Generous enough for a labelled triangle or two
    /// intersecting circles; the SVG scales down to fit inside either way.
    private static let boardSize = CGSize(width: 340, height: 260)
    private static let boardCornerRadius: CGFloat = 14
    private static let boardMarginFromAnchor: CGFloat = 14
    private static let screenEdgeMargin: CGFloat = 8

    private var boardWindow: OverlayWindow?
    /// Bumped on every show and every removal. A scheduled auto-dismiss
    /// captures the generation it was scheduled for and refuses to act if the
    /// board it was meant to fade is no longer the one on screen.
    private var dismissGeneration = 0
    private var autoDismissTask: Task<Void, Never>?

    /// Shows `svgFilePath` floating on the transparent window next to the
    /// element whose Quartz-global frame is `anchorFrame`. Replaces any board
    /// already up. Returns false when the SVG cannot be loaded (the caller
    /// reports that).
    @discardableResult
    func show(svgFilePath: String, anchoredToQuartzFrame anchorFrame: CGRect) -> Bool {
        removeAllNow()

        guard let svgImage = NSImage(contentsOfFile: svgFilePath) else {
            return false
        }

        // Which display the anchor lives on: the one whose Quartz-global
        // bounds contain the frame's centre. The frame came back in Quartz
        // space (top-left origin of the main display), so the conversion to
        // display-local points is a subtraction of that display's origin.
        let anchorCentre = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let (hostScreen, hostDisplayBounds) = Self.screen(containing: anchorCentre) else {
            return false
        }
        let anchorLocalFrame = CGRect(
            x: anchorFrame.minX - hostDisplayBounds.origin.x,
            y: anchorFrame.minY - hostDisplayBounds.origin.y,
            width: anchorFrame.width,
            height: anchorFrame.height
        )

        // Prefer the right of the anchor; flip to the left when that runs off
        // the display; clamp so a board beside something at either edge stays
        // readable instead of hanging off-screen.
        let boardOriginCandidates: [CGPoint] = [
            CGPoint(x: anchorLocalFrame.maxX + Self.boardMarginFromAnchor,
                    y: anchorLocalFrame.midY - Self.boardSize.height / 2),
            CGPoint(x: anchorLocalFrame.minX - Self.boardSize.width - Self.boardMarginFromAnchor,
                    y: anchorLocalFrame.midY - Self.boardSize.height / 2)
        ]
        var boardOrigin = boardOriginCandidates[0]
        if boardOrigin.x + Self.boardSize.width > hostDisplayBounds.width - Self.screenEdgeMargin {
            boardOrigin = boardOriginCandidates[1]
        }
        boardOrigin.x = max(Self.screenEdgeMargin,
                            min(boardOrigin.x, hostDisplayBounds.width - Self.boardSize.width - Self.screenEdgeMargin))
        boardOrigin.y = max(Self.screenEdgeMargin,
                            min(boardOrigin.y, hostDisplayBounds.height - Self.boardSize.height - Self.screenEdgeMargin))

        let window = OverlayWindow(screen: hostScreen)
        let boardView = FigureBoardView(
            boardFrame: CGRect(origin: boardOrigin, size: Self.boardSize),
            svgImage: svgImage
        )
        let hostingView = NSHostingView(rootView: boardView)
        hostingView.frame = NSRect(origin: .zero, size: hostDisplayBounds.size)
        window.contentView = hostingView
        window.orderFrontRegardless()
        boardWindow = window

        dismissGeneration += 1
        let generationForThisBoard = dismissGeneration
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.autoDismissDelaySeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.fadeOut(generation: generationForThisBoard)
        }
        return true
    }

    /// Fades whatever board is up. CompanionManager clears the board wherever
    /// it clears the green marks — before every fresh screenshot, on
    /// interrupt, and on a new press — so a figure never outlives its reply.
    func clear() {
        guard boardWindow != nil else { return }
        fadeOut(generation: dismissGeneration)
    }

    private func removeAllNow() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissGeneration += 1
        if let window = boardWindow {
            window.orderOut(nil)
            window.contentView = nil
        }
        boardWindow = nil
    }

    private func fadeOut(generation: Int) {
        guard generation == dismissGeneration else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissGeneration += 1

        guard let windowToFade = boardWindow else { return }
        boardWindow = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDurationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            windowToFade.animator().alphaValue = 0
        }, completionHandler: {
            windowToFade.orderOut(nil)
            windowToFade.contentView = nil
        })
    }

    /// The screen whose Quartz-global bounds contain `quartzPoint`, together
    /// with those bounds. Quartz global space and CGDisplayBounds share the
    /// same top-left origin convention, so containment is a plain `contains`.
    private static func screen(containing quartzPoint: CGPoint) -> (NSScreen, CGRect)? {
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            let displayBounds = CGDisplayBounds(displayID)
            if displayBounds.contains(quartzPoint) {
                return (screen, displayBounds)
            }
        }
        // A point just off every display (an anchor at the rim) still deserves
        // the board on the nearest screen rather than nowhere.
        return NSScreen.screens.first.flatMap { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (screen, CGDisplayBounds(displayID))
        }
    }
}

/// The figure itself: the SVG scaled to fit, floating directly on the
/// transparent window (no card, no surface, no shadow) at `boardFrame` in
/// display-local points — the coordinate space the hosting view's content
/// draws in. Crisp strokes, the same look as the system's green marks.
private struct FigureBoardView: View {
    let boardFrame: CGRect
    let svgImage: NSImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            board
                .frame(width: boardFrame.width, height: boardFrame.height)
                .position(x: boardFrame.midX, y: boardFrame.midY)
        }
        .allowsHitTesting(false)
    }

    // The board is deliberately TRANSPARENT (2026-09-24, the user's 「我要的是
    // 一个透明的，然后在透明的位置上去显示，这样可能会更加原生一点，你这样的话就
    // 太格格不入了」 — the white card was rejected outright) and the strokes
    // are drawn CRISP, with no halo: an earlier white shadow halo was rejected
    // as 发虚 (2026-09-24, 「非常高亮的绿色线，边线或文字字母等没有周围的阴影」) —
    // the system's green marks are clean bright strokes and so is the figure.
    private var board: some View {
        Image(nsImage: svgImage)
            .resizable()
            .scaledToFit()
            .padding(12)
    }
}
