//
//  CompanionScreenCaptureUtility.swift
//  Wanna
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    /// The display's AppKit frame (bottom-left origin) — the space
    /// `NSEvent.mouseLocation` and the overlay windows already use.
    let displayFrame: CGRect
    /// The screen's real display ID.
    ///
    /// Carried so a Quartz coordinate can be built without assuming where a
    /// screen sits in Quartz space: `CGDisplayBounds(displayID).origin` is the
    /// answer, and it differs per screen. Deriving the Quartz origin from the
    /// main screen's height instead is the classic mistake here — it is right on
    /// a single display and silently wrong on every other one.
    let displayID: CGDirectDisplayID
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures displays as JPEG data, labeling each with whether the user's
    /// cursor is on that screen. By default every connected display is captured
    /// so the AI has full context across multiple monitors.
    ///
    /// - Parameters:
    ///   - maximumDimension: Longest edge of the captured image in pixels, or
    ///     `nil` to capture at each display's native size.
    ///   - compressionQuality: JPEG compression factor (0–1).
    ///   - capturesAllDisplays: When false, only the display the cursor is on is
    ///     captured — a multi-monitor setup then sends one image instead of one
    ///     per screen.
    static func captureAllScreensAsJPEG(
        maximumDimension: Int? = 1280,
        compressionQuality: Double = 0.8,
        capturesAllDisplays: Bool = true
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        var sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        // 仅光标所在屏 mode: the cursor screen is guaranteed first after the sort,
        // so keeping just it is a filter, not a search.
        if !capturesAllDisplays {
            sortedDisplays = sortedDisplays.prefix(1).map { $0 }
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            if let maximumDimension {
                let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
                if display.width >= display.height {
                    configuration.width = maximumDimension
                    configuration.height = Int(CGFloat(maximumDimension) / aspectRatio)
                } else {
                    configuration.height = maximumDimension
                    configuration.width = Int(CGFloat(maximumDimension) * aspectRatio)
                }
            } else {
                // 原图 mode: the display's own **pixel** size. SCDisplay.width is in
                // points — 1728 on this machine's screen — so passing it through gave
                // a 1x image while the panel's real backing store is 2x, and the
                // option did not do what its name said. Measured 2026-09-22:
                // CGDisplayPixelsWide also reports the point size (1728, not 3456),
                // so the scale has to come from the matched NSScreen's
                // backingScaleFactor instead. A display with no matching NSScreen
                // keeps the old behaviour (scale 1) rather than guessing a factor.
                let backingScale = nsScreenByDisplayID[display.displayID]?.backingScaleFactor ?? 1
                configuration.width = Int(CGFloat(display.width) * backingScale)
                configuration.height = Int(CGFloat(display.height) * backingScale)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(
                        using: .jpeg,
                        properties: [.compressionFactor: compressionQuality]
                    ) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                displayID: display.displayID,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
