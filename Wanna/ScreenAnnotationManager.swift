//
//  ScreenAnnotationManager.swift
//  Wanna
//
//  Draws the [SHAPE:…] marks a model reply asks for — green rings, arrows,
//  lines, curves and outlines over the user's screen — the way a tutor would
//  draw on a whiteboard. One transparent, click-through window per display
//  that has marks on it (the same panel recipe the cursor overlay uses), a
//  SwiftUI Canvas tracing each stroke on, and an auto-dismiss so a drawing
//  never lingers past its usefulness.
//
//  Visual only: nothing here touches the machine, and nothing here is fed
//  back to the model. `CompanionManager` clears the marks before every fresh
//  screenshot, so a drawing the model made for the user never appears in the
//  screen the model looks at next — it would otherwise see its own circles
//  and re-draw or describe them.
//
//  Two details are deliberate. The auto-dismiss is generation-counted: a new
//  set of marks bumps the generation, so a stale dismiss task scheduled for
//  the previous set can never fade the new ones. And drawing needs no
//  accessibility lookup, unlike a click: a ring the model drew a little large
//  is still a ring around the thing, while a click one key away is a wrong
//  click — which is why marks land at the model's converted coordinates and
//  skip the element-name resolution the acting path runs.
//

import AppKit
import SwiftUI

/// One drawable annotation resolved into real screen coordinates.
nonisolated struct ScreenAnnotationMark: Sendable {
    let kind: AnnotationShapeKind
    /// The anchor label the shape resolved against — an element's own words.
    let label: String?
    /// The caption the capsule actually draws — what the user asked the label
    /// to say, when that differs from `label` (`anchor|display`). nil draws
    /// `label` unchanged.
    let displayLabel: String?
    /// The shape's points in **display-local points, y down from the display's
    /// top-left** — the coordinate space the annotation window's SwiftUI
    /// content uses directly, with no further conversion.
    let points: [CGPoint]
    /// The AppKit frame of the display the points are local to. Marks are
    /// grouped by this so one window covers one display.
    let displayFrame: CGRect
}

@MainActor
final class ScreenAnnotationManager {

    /// How long a full drawing stays visible before fading on its own. Long
    /// enough to actually read a labelled ring, short enough that the screen
    /// is clean by the time the user's next exchange starts.
    private static let autoDismissDelaySeconds: TimeInterval = 10
    private static let fadeDurationSeconds: TimeInterval = 0.6
    /// Handed to the canvas view, which traces each stroke over this long.
    private static let drawDurationSeconds: TimeInterval = 0.7

    private var annotationWindows: [OverlayWindow] = []
    /// Bumped on every show and every removal. An auto-dismiss task captures
    /// the generation it was scheduled for and refuses to act if the marks it
    /// was meant to fade are no longer the ones on screen.
    private var dismissGeneration = 0
    private var autoDismissTask: Task<Void, Never>?

    /// Replaces whatever is on screen with `marks`. An empty array clears.
    func show(_ marks: [ScreenAnnotationMark]) {
        removeAnnotationWindowsNow()
        guard !marks.isEmpty else { return }
        dismissGeneration += 1

        // One window per display that has marks on it — a shape reported for
        // screen 2 must never be drawn stretched across screen 1.
        let marksByDisplayFrame = Dictionary(grouping: marks, by: { $0.displayFrame })
        for (displayFrame, marksOnThisDisplay) in marksByDisplayFrame {
            guard let matchingScreen = NSScreen.screens.first(where: { $0.frame == displayFrame }) else {
                continue
            }
            let window = OverlayWindow(screen: matchingScreen)
            let canvasView = AnnotationCanvasView(
                marks: marksOnThisDisplay,
                viewSize: displayFrame.size,
                drawDuration: Self.drawDurationSeconds
            )
            let hostingView = NSHostingView(rootView: canvasView)
            hostingView.frame = NSRect(origin: .zero, size: displayFrame.size)
            window.contentView = hostingView
            window.orderFrontRegardless()
            annotationWindows.append(window)
        }

        let generationForThisSet = dismissGeneration
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.autoDismissDelaySeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.fadeOutAndRemoveAnnotationWindows(generation: generationForThisSet)
        }
    }

    /// Fades whatever marks are currently up. Called by `CompanionManager`
    /// before a fresh screenshot, on interrupt, and when a new press takes
    /// the stage — the marks belong to the reply they came with.
    func clear() {
        guard !annotationWindows.isEmpty else { return }
        fadeOutAndRemoveAnnotationWindows(generation: dismissGeneration)
    }

    private func removeAnnotationWindowsNow() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissGeneration += 1
        for window in annotationWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        annotationWindows.removeAll()
    }

    private func fadeOutAndRemoveAnnotationWindows(generation: Int) {
        guard generation == dismissGeneration else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissGeneration += 1

        let windowsToFade = annotationWindows
        annotationWindows.removeAll()
        guard !windowsToFade.isEmpty else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDurationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }
}

/// The SwiftUI content of one annotation window: strokes traced on by a
/// draw-progress fraction, each with its label capsule fading in once its
/// shape is complete.
private struct AnnotationCanvasView: View {
    let marks: [ScreenAnnotationMark]
    let viewSize: CGSize
    let drawDuration: TimeInterval

    /// Captured when the view is built, which is when its marks are shown —
    /// every timing below runs from this moment.
    private let startDate = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let drawProgress = min(1, max(0, elapsed / drawDuration))

            ZStack {
                Canvas { context, _ in
                    for mark in marks {
                        drawMark(mark, progress: drawProgress, in: &context)
                    }
                }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    if let label = mark.displayLabel ?? mark.label, drawProgress >= 1 {
                        annotationLabel(label)
                            .position(labelPosition(for: mark))
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    // MARK: - Drawing

    private static let strokeColor = Color(red: 0.13, green: 0.84, blue: 0.34)
    private static let lineWidth: CGFloat = 3.5

    private func drawMark(
        _ mark: ScreenAnnotationMark,
        progress: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard mark.points.count >= mark.kind.minimumPointCount else { return }

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: Self.strokeColor.opacity(0.55), radius: 5, x: 0, y: 0))
            layer.stroke(
                tracedPath(for: mark, progress: progress),
                with: .color(Self.strokeColor),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            )
            if mark.kind == .arrow {
                fillArrowheadIfComplete(mark, progress: progress, in: &layer)
            }
        }
    }

    /// The shape's path, cut to `progress` of its length so each mark appears
    /// to be drawn by hand. A circle becomes a partial arc sweeping clockwise
    /// from its top; everything else becomes a polyline (closed for a polygon)
    /// walked only as far as the progress reaches.
    private func tracedPath(for mark: ScreenAnnotationMark, progress: CGFloat) -> Path {
        var path = Path()

        switch mark.kind {
        case .circle:
            let centre = mark.points[0]
            let radius = hypot(mark.points[1].x - centre.x, mark.points[1].y - centre.y)
            let startAngle = Angle(degrees: -90)
            let endAngle = startAngle + Angle(degrees: 360 * progress)
            path.addArc(
                center: centre,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        case .line, .arrow, .curve:
            let traced = partialPolyline(mark.points, fraction: progress)
            guard let first = traced.first else { return path }
            path.move(to: first)
            for point in traced.dropFirst() {
                path.addLine(to: point)
            }
        case .polygon:
            // Trace the closed outline as one polyline: the walk ends back at
            // the first vertex when progress reaches 1.
            let closedPoints = mark.points + [mark.points[0]]
            let traced = partialPolyline(closedPoints, fraction: progress)
            guard let first = traced.first else { return path }
            path.move(to: first)
            for point in traced.dropFirst() {
                path.addLine(to: point)
            }
        }

        return path
    }

    /// The points of a polyline walked only `fraction` of its total length —
    /// the draw-on effect for every non-circle shape.
    private func partialPolyline(_ points: [CGPoint], fraction: CGFloat) -> [CGPoint] {
        guard points.count > 1, fraction > 0 else { return [] }
        if fraction >= 1 { return points }

        var segmentLengths: [CGFloat] = []
        var totalLength: CGFloat = 0
        for (current, next) in zip(points, points.dropFirst()) {
            let length = hypot(next.x - current.x, next.y - current.y)
            segmentLengths.append(length)
            totalLength += length
        }
        guard totalLength > 0 else { return [points[0]] }

        var remainingLength = totalLength * fraction
        var traced: [CGPoint] = [points[0]]
        for (index, segmentLength) in segmentLengths.enumerated() {
            if remainingLength >= segmentLength {
                traced.append(points[index + 1])
                remainingLength -= segmentLength
            } else {
                let current = points[index]
                let next = points[index + 1]
                let segmentFraction = segmentLength > 0 ? remainingLength / segmentLength : 0
                traced.append(CGPoint(
                    x: current.x + (next.x - current.x) * segmentFraction,
                    y: current.y + (next.y - current.y) * segmentFraction
                ))
                break
            }
        }
        return traced
    }

    /// The arrowhead is filled only once its shaft has been fully traced —
    /// a head floating in space before the line arrives looks broken.
    private func fillArrowheadIfComplete(
        _ mark: ScreenAnnotationMark,
        progress: CGFloat,
        in layer: inout GraphicsContext
    ) {
        guard progress >= 1, mark.points.count >= 2 else { return }

        let tip = mark.points[mark.points.count - 1]
        let previous = mark.points[mark.points.count - 2]
        let direction = CGPoint(x: tip.x - previous.x, y: tip.y - previous.y)
        let length = hypot(direction.x, direction.y)
        guard length > 0 else { return }
        let unit = CGPoint(x: direction.x / length, y: direction.y / length)
        let perpendicular = CGPoint(x: -unit.y, y: unit.x)

        let headLength: CGFloat = 14
        let headHalfWidth: CGFloat = 5.5
        let base = CGPoint(x: tip.x - unit.x * headLength, y: tip.y - unit.y * headLength)

        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x + perpendicular.x * headHalfWidth, y: base.y + perpendicular.y * headHalfWidth))
        head.addLine(to: CGPoint(x: base.x - perpendicular.x * headHalfWidth, y: base.y - perpendicular.y * headHalfWidth))
        head.closeSubpath()
        layer.fill(head, with: .color(Self.strokeColor))
    }

    // MARK: - Labels

    private func annotationLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Self.strokeColor)
                    .shadow(color: Self.strokeColor.opacity(0.45), radius: 4, y: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity)
    }

    /// Where a mark's label sits: above the top of what it describes, clamped
    /// inside the display so a label for something near the screen edge stays
    /// readable instead of hanging off-screen.
    private func labelPosition(for mark: ScreenAnnotationMark) -> CGPoint {
        let labelHalfWidth: CGFloat = 70
        let margin: CGFloat = 16

        let boundingBox = mark.points.reduce(CGRect(x: mark.points[0].x, y: mark.points[0].y, width: 0, height: 0)) { box, point in
            box.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }

        var position = CGPoint(
            x: boundingBox.midX,
            y: boundingBox.minY - 24
        )

        position.x = max(labelHalfWidth + margin, min(position.x, viewSize.width - labelHalfWidth - margin))
        position.y = max(margin, min(position.y, viewSize.height - margin))
        return position
    }
}
