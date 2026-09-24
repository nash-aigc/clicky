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
//  Two display modes. When the figure agent produced narration steps (its
//  sidecar .steps.json), the figure is revealed INCREMENTALLY — one step's
//  elements fade in, the narration for that step is spoken through the app's
//  own TTS, then the next — like a teacher drawing on a blackboard stroke by
//  stroke while explaining (2026-09-24, the user's 分步动画 request). Without
//  steps the whole figure appears at once, as before.
//
//  The window recipe is ScreenAnnotationManager's verbatim: one transparent,
//  click-through OverlayWindow per shown board, an NSHostingView, an
//  auto-dismiss with a fade, and a generation counter so a stale dismiss task
//  can never fade a newer board. Visual only: the board touches nothing, and
//  — like the marks — it is cleared before every fresh screenshot so the
//  model never sees its own drawing and decides to draw it again.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Narration steps (sidecar JSON written by the figure agent)

/// One planned step of the figure's incremental reveal: `n` is the 1-based
/// ordinal of the last SVG top-level element this step reveals (elements are
/// in the figure agent's object creation order), `text` is the sentence to
/// speak while those elements appear.
nonisolated struct FigureBoardStepPlan: Sendable, Codable {
    let n: Int
    let text: String

    /// Reads the sidecar `.steps.json` the figure agent writes next to the
    /// SVG (same path with the extension swapped). Any failure — no file,
    /// malformed JSON — reads as "no steps", and the board shows all at once.
    static func readSteps(fromSvgSidecarOf svgFilePath: String, maximumSteps: Int = 12) -> [FigureBoardStepPlan] {
        let sidecarPath = (svgFilePath as NSString).deletingPathExtension + ".steps.json"
        guard let data = FileManager.default.contents(atPath: sidecarPath),
              let plans = try? JSONDecoder().decode([FigureBoardStepPlan].self, from: data) else {
            return []
        }
        // The reveal is cumulative, so the steps must arrive in ascending
        // element order; duplicates would reveal nothing new.
        var lastN = 0
        var ordered: [FigureBoardStepPlan] = []
        for plan in plans.sorted(by: { $0.n < $1.n }) where plan.n > lastN {
            lastN = plan.n
            ordered.append(plan)
        }
        return Array(ordered.prefix(maximumSteps))
    }
}

@MainActor
final class FigureBoardController {

    /// How long a board stays up before fading on its own. Longer than the
    /// marks' 10 s: a figure carries labelled geometry the user is meant to
    /// read against the problem beside it.
    private static let autoDismissDelaySeconds: TimeInterval = 20
    private static let fadeDurationSeconds: TimeInterval = 0.6

    /// The board's outer size. Generous enough for a labelled triangle or two
    /// intersecting circles; the SVG scales down to fit inside either way.
    private static let boardSize = CGSize(width: 460, height: 360)
    private static let boardCornerRadius: CGFloat = 14
    private static let boardMarginFromAnchor: CGFloat = 14
    private static let screenEdgeMargin: CGFloat = 8

    private var boardWindow: OverlayWindow?
    private var boardModel: FigureBoardModel?
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

        guard let svgImage = NSImage(contentsOfFile: svgFilePath),
              let placement = Self.placement(anchoredToQuartzFrame: anchorFrame) else {
            return false
        }

        let model = FigureBoardModel(image: svgImage)
        presentWindow(model: model, placement: placement)
        scheduleAutoDismiss()
        return true
    }

    /// Reveals the figure STEP BY STEP: `steps` (from the figure agent's
    /// sidecar) map each narration sentence to a prefix of the SVG's top-level
    /// elements; every step fades its new elements in and then awaits
    /// `speakStep`, which the caller supplies so the app's own TTS reads the
    /// narration and the loop naturally paces to the speech. Returns false —
    /// before anything is shown — when the SVG cannot be parsed or there are
    /// fewer than two usable steps, so the caller falls back to `show`.
    func showAnimated(
        svgFilePath: String,
        anchoredToQuartzFrame anchorFrame: CGRect,
        steps: [FigureBoardStepPlan],
        speakStep: (String) async -> Void
    ) async -> Bool {
        removeAllNow()

        guard let svgText = try? String(contentsOfFile: svgFilePath, encoding: .utf8),
              let (header, elements, footer) = Self.splitSvgTopLevelElements(svgText),
              !elements.isEmpty,
              let placement = Self.placement(anchoredToQuartzFrame: anchorFrame) else {
            return false
        }

        // Turn the plans into cumulative element counts (steps arrive sorted
        // and strictly increasing already). If the last step stops short of
        // the whole figure, append a silent final step that reveals the rest.
        var stepElementCounts: [Int] = []
        var stepNarrations: [String] = []
        for step in steps {
            let elementCount = min(max(step.n, 1), elements.count)
            if let lastCount = stepElementCounts.last, elementCount <= lastCount { continue }
            stepElementCounts.append(elementCount)
            stepNarrations.append(step.text)
        }
        if stepElementCounts.last != elements.count {
            stepElementCounts.append(elements.count)
            stepNarrations.append("")
        }
        guard stepElementCounts.count >= 2, stepElementCounts.count == stepNarrations.count else {
            return false
        }

        // Rasterize one cumulative SVG per step, off the main actor — an SVG
        // parse-and-render per step is real work and this method runs inside
        // the response pipeline.
        let cumulativeImages = await Self.rasterizeCumulativeImages(
            header: header, elements: elements, footer: footer,
            elementCounts: stepElementCounts
        )
        guard cumulativeImages.count == stepElementCounts.count, let firstImage = cumulativeImages.first else {
            return false
        }

        let model = FigureBoardModel(image: firstImage)
        presentWindow(model: model, placement: placement)

        for (stepIndex, narration) in stepNarrations.enumerated() {
            guard !Task.isCancelled else { break }
            if stepIndex > 0 {
                withAnimation(.easeInOut(duration: 0.45)) {
                    model.advance(to: cumulativeImages[stepIndex])
                }
            }
            scheduleAutoDismiss()
            if !narration.isEmpty {
                await speakStep(narration)
            } else {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
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

    // MARK: - Shared placement machinery

    private struct Placement {
        let screen: NSScreen
        let boardOrigin: CGPoint
    }

    /// Where a board anchored to `anchorFrame` (Quartz global) goes: beside
    /// the anchor on the display that contains it. Prefer the right of the
    /// anchor; flip to the left when that runs off the display; clamp so a
    /// board beside something at either edge stays readable instead of
    /// hanging off-screen.
    private static func placement(anchoredToQuartzFrame anchorFrame: CGRect) -> Placement? {
        let anchorCentre = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let (hostScreen, hostDisplayBounds) = screen(containing: anchorCentre) else {
            return nil
        }
        let anchorLocalFrame = CGRect(
            x: anchorFrame.minX - hostDisplayBounds.origin.x,
            y: anchorFrame.minY - hostDisplayBounds.origin.y,
            width: anchorFrame.width,
            height: anchorFrame.height
        )

        let boardOriginCandidates: [CGPoint] = [
            CGPoint(x: anchorLocalFrame.maxX + boardMarginFromAnchor,
                    y: anchorLocalFrame.midY - boardSize.height / 2),
            CGPoint(x: anchorLocalFrame.minX - boardSize.width - boardMarginFromAnchor,
                    y: anchorLocalFrame.midY - boardSize.height / 2)
        ]
        var boardOrigin = boardOriginCandidates[0]
        if boardOrigin.x + boardSize.width > hostDisplayBounds.width - screenEdgeMargin {
            boardOrigin = boardOriginCandidates[1]
        }
        boardOrigin.x = max(screenEdgeMargin,
                            min(boardOrigin.x, hostDisplayBounds.width - boardSize.width - screenEdgeMargin))
        boardOrigin.y = max(screenEdgeMargin,
                            min(boardOrigin.y, hostDisplayBounds.height - boardSize.height - screenEdgeMargin))
        return Placement(screen: hostScreen, boardOrigin: boardOrigin)
    }

    private func presentWindow(model: FigureBoardModel, placement: Placement) {
        let window = OverlayWindow(screen: placement.screen)
        let boardView = FigureBoardView(
            boardFrame: CGRect(origin: placement.boardOrigin, size: Self.boardSize),
            model: model
        )
        let hostingView = NSHostingView(rootView: boardView)
        let hostDisplayBounds = placement.screen.frame
        hostingView.frame = NSRect(origin: .zero, size: hostDisplayBounds.size)
        window.contentView = hostingView
        window.orderFrontRegardless()
        boardWindow = window
        boardModel = model
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        dismissGeneration += 1
        let generationForThisBoard = dismissGeneration
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.autoDismissDelaySeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.fadeOut(generation: generationForThisBoard)
        }
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
        boardModel = nil
    }

    private func fadeOut(generation: Int) {
        guard generation == dismissGeneration else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissGeneration += 1

        guard let windowToFade = boardWindow else { return }
        boardWindow = nil
        boardModel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDurationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            windowToFade.animator().alphaValue = 0
        }, completionHandler: {
            windowToFade.orderOut(nil)
            windowToFade.contentView = nil
        })
    }

    // MARK: - SVG splitting and per-step rasterization

    /// Splits the SVG into its opening tag (plus everything before the first
    /// top-level element, e.g. `<defs>`), the top-level elements themselves,
    /// and the closing tail. A cumulative image for step k is header +
    /// elements[0...k] + footer, so each step's image contains everything
    /// drawn before it and the reveal is strictly additive.
    private static func splitSvgTopLevelElements(_ svgText: String) -> (header: String, elements: [String], footer: String)? {
        let nsText = svgText as NSString
        let contentLength = nsText.length

        guard let openTagEnd = svgText.range(of: ">")?.upperBound.utf16Offset(in: svgText),
              openTagEnd < contentLength else {
            return nil
        }
        let closeTagStart = nsText.range(of: "</svg>").location
        guard closeTagStart != NSNotFound, closeTagStart > openTagEnd else {
            return nil
        }

        var elements: [String] = []
        var cursor = openTagEnd
        while cursor < closeTagStart {
            // Skip inter-element whitespace.
            while cursor < closeTagStart, nsText.character(at: cursor) <= 32 { cursor += 1 }
            guard cursor < closeTagStart, nsText.character(at: cursor) == UInt16(UInt8(ascii: "<")) else { break }

            // Walk tags until this top-level element's matching close.
            let elementStart = cursor
            var depth = 0
            var elementEnd = -1
            var tagCursor = cursor
            while tagCursor < closeTagStart {
                guard nsText.character(at: tagCursor) == UInt16(UInt8(ascii: "<")) else {
                    tagCursor += 1
                    continue
                }
                var tagEnd = tagCursor + 1
                while tagEnd < closeTagStart, nsText.character(at: tagEnd) != UInt16(UInt8(ascii: ">")) {
                    tagEnd += 1
                }
                guard tagEnd < closeTagStart else { break }
                let tag = nsText.substring(with: NSRange(location: tagCursor, length: tagEnd - tagCursor + 1))
                if tag.hasPrefix("</") {
                    depth -= 1
                    if depth == 0 {
                        elementEnd = tagEnd + 1
                        break
                    }
                } else if !tag.hasSuffix("/>"), !tag.hasPrefix("<!"), !tag.hasPrefix("<?") {
                    depth += 1
                }
                tagCursor = tagEnd + 1
            }
            guard elementEnd > elementStart else { break }
            elements.append(nsText.substring(with: NSRange(location: elementStart, length: elementEnd - elementStart)))
            cursor = elementEnd
        }
        guard !elements.isEmpty else { return nil }

        let header = nsText.substring(with: NSRange(location: 0, length: openTagEnd))
        let footer = nsText.substring(with: NSRange(location: closeTagStart, length: contentLength - closeTagStart))
        return (header, elements, footer)
    }

    /// Renders one cumulative SVG per step and loads it as an NSImage. The
    /// temp files only shuttle bytes into the images' in-memory data — each
    /// NSImage is loaded before its file is deleted. Runs off the main actor.
    private static func rasterizeCumulativeImages(
        header: String,
        elements: [String],
        footer: String,
        elementCounts: [Int]
    ) async -> [NSImage] {
        await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("clicky-figure-board-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            var images: [NSImage] = []
            for (stepIndex, elementCount) in elementCounts.enumerated() {
                let svg = header + elements[0..<elementCount].joined() + footer
                let fileURL = directory.appendingPathComponent("step-\(stepIndex).svg")
                guard (try? svg.write(to: fileURL, atomically: true, encoding: .utf8)) != nil,
                      let image = NSImage(contentsOf: fileURL) else {
                    break
                }
                images.append(image)
            }
            return images
        }.value
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

/// Holds the image currently on the board. The animated reveal swaps it per
/// step through this observable model, so the hosting view is built once and
/// each step is just a published change (an image rebuild per step would drop
/// the window's drawing state mid-reveal).
@MainActor
private final class FigureBoardModel: ObservableObject {
    @Published var image: NSImage
    /// Forces a fresh view identity per step so the cumulative change
    /// crossfades instead of snapping.
    @Published var stepIndex = 0

    init(image: NSImage) {
        self.image = image
    }

    func advance(to image: NSImage) {
        self.image = image
        stepIndex += 1
    }
}

/// The figure itself: the SVG scaled to fit, floating directly on the
/// transparent window (no card, no surface, no shadow) at `boardFrame` in
/// display-local points — the coordinate space the hosting view's content
/// draws in. Crisp strokes, the same look as the system's green marks.
private struct FigureBoardView: View {
    let boardFrame: CGRect
    @ObservedObject var model: FigureBoardModel

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
        Image(nsImage: model.image)
            .resizable()
            .scaledToFit()
            .padding(12)
            .id(model.stepIndex)
            .transition(.opacity)
    }
}
