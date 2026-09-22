//
//  CircleToAskController.swift
//  leanring-buddy
//
//  「你圈我问」— the user holds the talk shortcut, draws a circle around
//  something on screen with the mouse cursor while speaking, and the marked
//  region rides along with the question. Reverse-engineered behaviour of the
//  closed-source HeyClicky ("hold the keys, circle something on your screen
//  with the cursor, and ask about it"): the human's own circle is what makes
//  the question's subject pixel-exact — no vision-model estimate involved.
//
//  Division of labour: this controller captures the drag and remembers the
//  region; the drawn lasso is handed to `ScreenAnnotationManager` as an
//  ordinary curve mark the moment the mouse comes up, so every clear
//  discipline that already exists for model-drawn marks (cleared before each
//  screenshot, on interrupt, on a new press) applies to the user's drawing
//  for free. `CompanionManager` consumes the pending region at the start of
//  the response pipeline and attaches it to the prompt as data.
//

import AppKit

/// A region the user circled on screen, resolved into every coordinate space
/// the pipeline needs.
struct MarkedScreenRegion {
    /// AppKit frame of the display the circle was drawn on.
    let displayFrame: CGRect
    let displayID: CGDirectDisplayID
    /// Which screen the circle is on, 1-based in the same order the captures
    /// are labeled — the same "screenN" language the model already knows.
    let screenNumber: Int
    /// The circle's bounding rect in display-local points, y down from the
    /// display's top-left.
    let localBounds: CGRect
    /// The circle on the model's normalized 0–1000 grid.
    let normalizedRect: CGRect
}

@MainActor
final class CircleToAskController {

    /// Drags shorter than this are clicks, not circles, and are ignored.
    private static let minimumLassoExtentInPoints: CGFloat = 24
    /// Breathing room added around the raw bounding box, so "around the
    /// button" includes the button's edges.
    private static let regionPaddingInPoints: CGFloat = 12

    private let annotationManager: ScreenAnnotationManager
    init(annotationManager: ScreenAnnotationManager) {
        self.annotationManager = annotationManager
    }

    /// The region waiting to ride along with the next question, or nil.
    private(set) var pendingMarkedRegion: MarkedScreenRegion?

    private var eventMonitors: [Any] = []
    private var lassoWindow: OverlayWindow?
    private var lassoView: LassoOverlayView?
    /// Drag points in AppKit global coordinates (bottom-left origin) — the
    /// space NSEvent reports.
    private var dragPointsInGlobalCoordinates: [CGPoint] = []
    private var screenTheDragStartedOn: NSScreen?

    // MARK: - Capture lifecycle

    /// Arms the mouse-drag monitors for one dictation session.
    ///
    /// Deliberately does NOT drop a pending region here: in confirmation mode
    /// the tap that sends the held question starts a recording first, and
    /// dropping on arm would destroy the region before its question ever went
    /// out. Stale regions are dropped by the press path instead, which knows
    /// whether a send is about to happen.
    func beginCaptureIfEnabled() {
        endCapture()
        guard AppSettingsStore.snapshot().allowsCircleToAsk else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        // Global monitors catch the drag over other apps' windows; the local
        // one catches drags over Clicky's own panel. Neither needs a fresh
        // permission — mouse monitoring is not TCC-gated the way keyboard
        // monitoring is.
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseEvent(event)
        })
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        })
        eventMonitors = [globalMonitor, localMonitor].compactMap { $0 }
    }

    /// Disarms the monitors. Called when the dictation session ends; a lasso
    /// already drawn stays pending until consumed or discarded.
    func endCapture() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        closeLassoWindow()
    }

    /// Hands the pending region to the pipeline and forgets it.
    func consumePendingRegion() -> MarkedScreenRegion? {
        let region = pendingMarkedRegion
        pendingMarkedRegion = nil
        return region
    }

    /// Forgets the pending region without consuming it — interrupt and
    /// new-question paths.
    func discardPendingRegion() {
        pendingMarkedRegion = nil
    }

    // MARK: - Mouse handling

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A fresh press starts a new lasso; the previous one, if never
            // consumed, is replaced.
            dragPointsInGlobalCoordinates = [event.locationInWindow]
            screenTheDragStartedOn = screen(containingGlobalPoint: event.locationInWindow)
            openLassoWindow(on: screenTheDragStartedOn)

        case .leftMouseDragged:
            guard lassoWindow != nil else { return }
            dragPointsInGlobalCoordinates.append(event.locationInWindow)
            lassoView?.points = displayLocalPoints()
            lassoView?.needsDisplay = true

        case .leftMouseUp:
            guard lassoWindow != nil else { return }
            finishLasso()
            closeLassoWindow()

        default:
            break
        }
    }

    private func finishLasso() {
        let localPoints = displayLocalPoints()
        guard let dragScreen = screenTheDragStartedOn else { return }
        guard localPoints.count >= 2 else { return }

        var boundingBox = CGRect(
            x: localPoints[0].x, y: localPoints[0].y, width: 0, height: 0
        )
        for point in localPoints.dropFirst() {
            boundingBox = boundingBox.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard boundingBox.width >= Self.minimumLassoExtentInPoints
                || boundingBox.height >= Self.minimumLassoExtentInPoints else {
            return
        }

        let paddedBounds = boundingBox.insetBy(
            dx: -Self.regionPaddingInPoints, dy: -Self.regionPaddingInPoints
        )

        // The drawn circle itself is shown through the ordinary annotation
        // path — the user sees their own stroke stay up while they keep
        // talking, and the screenshot-capture clear takes it away later.
        annotationManager.show([
            ScreenAnnotationMark(
                kind: .curve,
                label: nil,
                points: localPoints,
                displayFrame: dragScreen.frame
            )
        ])

        let screenFrame = dragScreen.frame
        let paddedForGrid = paddedBounds
        pendingMarkedRegion = MarkedScreenRegion(
            displayFrame: screenFrame,
            displayID: displayID(of: dragScreen),
            screenNumber: (NSScreen.screens.firstIndex(where: { $0 == dragScreen }) ?? 0) + 1,
            localBounds: paddedForGrid,
            normalizedRect: CGRect(
                x: paddedForGrid.minX / screenFrame.width * 1000,
                y: paddedForGrid.minY / screenFrame.height * 1000,
                width: paddedForGrid.width / screenFrame.width * 1000,
                height: paddedForGrid.height / screenFrame.height * 1000
            )
        )
    }

    // MARK: - Coordinate conversion

    private func screen(containingGlobalPoint globalPoint: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(globalPoint) })
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The recorded drag points converted to display-local points, y down from
    /// the display's top-left — the space the annotation canvas draws in.
    private func displayLocalPoints() -> [CGPoint] {
        guard let dragScreen = screenTheDragStartedOn else { return [] }
        let screenFrame = dragScreen.frame
        return dragPointsInGlobalCoordinates.map { globalPoint in
            CGPoint(
                x: globalPoint.x - screenFrame.origin.x,
                y: screenFrame.height - (globalPoint.y - screenFrame.origin.y)
            )
        }
    }

    // MARK: - Live lasso window

    private func openLassoWindow(on screen: NSScreen?) {
        guard let screen else { return }
        closeLassoWindow()
        let window = OverlayWindow(screen: screen)
        let view = LassoOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: screen.frame.size)
        window.contentView = view
        window.orderFrontRegardless()
        lassoWindow = window
        lassoView = view
    }

    private func closeLassoWindow() {
        lassoWindow?.orderOut(nil)
        lassoWindow?.contentView = nil
        lassoWindow = nil
        lassoView = nil
    }
}

/// The live stroke the user is dragging right now. An AppKit view rather than
/// SwiftUI because the points update on every mouse-dragged event — tens per
/// second — and a redraw of one polyline needs no view diffing on top.
private final class LassoOverlayView: NSView {

    /// Display-local points, y down (`isFlipped` makes the view's coordinates
    /// match, so no second y flip lives here).
    var points: [CGPoint] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }

        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = 3.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        NSColor(red: 0.13, green: 0.84, blue: 0.34, alpha: 1).setStroke()
        let glow = NSShadow()
        glow.shadowColor = NSColor(red: 0.13, green: 0.84, blue: 0.34, alpha: 0.55)
        glow.shadowBlurRadius = 5
        glow.set()
        path.stroke()
    }
}
