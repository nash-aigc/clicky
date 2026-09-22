//
//  NotchWindowController.swift
//  leanring-buddy
//
//  The notch presence subsystem: one panel per notched screen, resting as an
//  invisible black pill fused into the hardware notch, expanding on hover
//  dwell (0.35 s + progress ring) or click into the app's main floating
//  sheet — the entry HeyClicky has and Clicky's menu bar panel backs up.
//
//  Structure mirrors HeyClicky's recovered `NotchScreenInstance` shape (one
//  instance per display holding its panel) and `NotchPanelViewState` (the
//  per-panel visible state), with the panel class copied from
//  `MenuBarPanelManager`'s `KeyablePanel` — borderless, nonactivating, keyable,
//  which is what lets the expanded sheet take keyboard focus without stealing
//  the frontmost app's activation.
//
//  One panel does both roles: its frame morphs between the resting pill rect
//  and the expanded sheet rect (a single window resizing — rebuilding or
//  swapping windows would flash and drop key status), while the SwiftUI
//  content inside switches between pill and sheet, keyed off the same
//  `expansionProgress` that drives `HomeSpaceSheetShape`. The frame morph
//  (`NSAnimationContext`, 0.38 s) and the progress animation
//  (SwiftUI `withAnimation`, matched duration) run simultaneously.
//
//  Collapse paths — all deliberate: Esc (local keyDown monitor, installed
//  only while expanded), a click outside the sheet, the app resigning active,
//  and the sheet's close button. A fullscreen app covering a display
//  suppresses that display's pill until the space changes back.
//

import AppKit
import SwiftUI
import Combine

/// The SwiftUI-visible state of the notch panels. One model drives every
/// screen's pill — activity is app-wide (the companion is answering or it
/// is not), so per-screen models would only be state to keep in sync.

final class NotchPanelModel: ObservableObject {
    @Published var activityPhase: NotchActivityPhase = .idle
    /// 0–1, how full the hover-dwell ring is drawn.
    @Published var dwellProgress: CGFloat = 0
    /// 0–1, the sheet expansion. Drives `HomeSpaceSheetShape` and the
    /// pill/sheet content switch.
    @Published var expansionProgress: CGFloat = 0
    @Published var isExpanded: Bool = false
    @Published var isFullscreenSuppressed: Bool = false
}

@MainActor
final class NotchWindowController {

    /// Borderless panel that can become key — copied from
    /// `KeyablePanel` (`MenuBarPanelManager.swift`), for the same reason:
    /// the expanded sheet has text fields, and a window that cannot become
    /// key silently swallows every keystroke.
    final class NotchPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct ScreenPresence {
        let displayID: CGDirectDisplayID
        let screen: NSScreen
        let panel: NotchPanel
    }

    private static let hoverDwellDuration: TimeInterval = 0.35
    private static let dwellPollingInterval: TimeInterval = 1.0 / 30.0

    /// Strong on purpose — the manager owns this controller, so a strong back
    /// reference is a cycle, and a deliberate one: both objects live for the
    /// whole app run (the same reasoning the overlay windows use), so the
    /// cycle never has to break.
    private let companionManager: CompanionManager
    private let panelModel = NotchPanelModel()
    private let audioHistoryProvider: () -> [CGFloat]

    private var screenPresences: [ScreenPresence] = []
    private var cancellables: Set<AnyCancellable> = []
    private var dwellTimer: Timer?
    private var dwellStartedAt: Date?
    private var keyDownMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultCenterObservers: [NSObjectProtocol] = []
    private var hasPlayedBootChime = false

    /// The screen whose sheet is currently expanded. At most one — expanding
    /// on a second screen collapses the first.
    private var expandedScreen: NSScreen?

    init(companionManager: CompanionManager, audioHistoryProvider: @escaping () -> [CGFloat]) {
        self.companionManager = companionManager
        self.audioHistoryProvider = audioHistoryProvider
    }

    // MARK: - Lifecycle

    /// Builds the resting pills on every screen that has a notch. Called
    /// repeatedly (launch, permission completion, screen changes, settings
    /// changes) — rebuilding is idempotent: existing panels whose screen is
    /// unchanged are kept, not torn down, because tearing down and recreating
    /// a panel flashes.
    func installIfScreensSupportIt() {
        guard AppSettingsStore.snapshot().enablesNotchPresence else { return }

        rebuildScreenPresences()
        installMonitorsIfNeeded()
        // The dwell poll runs for the controller's whole life and gates itself
        // per tick (idle + not expanded + not suppressed). Starting it only on
        // a non-idle state change — as an earlier version did — left it dead
        // while idle, which is the one state dwell is supposed to serve.
        startDwellTimer()

        if !screenPresences.isEmpty && !hasPlayedBootChime {
            hasPlayedBootChime = true
            SoundEffectPlayer.shared.play(.notchBoot)
        }
    }

    /// Tears everything down — 「刘海屏入口」 off, or the app quitting. The
    /// menu bar panel is the permanent backup entry, so disabling this never
    /// strands the user.
    func teardown() {
        collapse(expandBackToPill: false)
        for presence in screenPresences {
            presence.panel.orderOut(nil)
        }
        screenPresences = []
        stopDwellTimer()
        removeMonitors()
        hasPlayedBootChime = false
    }

    private func rebuildScreenPresences() {
        let notchedScreens = NSScreen.screens.filter { NotchSupport.hasNotch($0) }

        // Keep existing panels for screens that still qualify; remove panels
        // for screens that went away or lost their notch; add panels for new
        // ones.
        var rebuiltPresences: [ScreenPresence] = []
        for screen in notchedScreens {
            if let existing = screenPresences.first(where: { $0.screen == screen }) {
                rebuiltPresences.append(existing)
                continue
            }
            // The window is the pill widened by the flank-animation canvas on
            // both sides; the *pill* rect (restingPillFrame) stays the
            // hit-test geometry for dwell and click-to-expand below.
            guard let restingFrame = NotchSupport.restingWindowFrame(on: screen) else { continue }

            let panel = NotchPanel(
                contentRect: restingFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .mainMenu + 1
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            // The resting window is 300pt wider than the visible pill and its
            // flanks are transparent — ignoring mouse events while resting
            // keeps the menu bar items underneath clickable. Click-to-expand
            // still works: the click falls through to whatever is beneath,
            // and the *global* monitor sees it. The sheet needs real events,
            // so expand() flips this back before making the panel key.
            panel.ignoresMouseEvents = true

            let rootView = NotchPanelRootSwitchingView(
                panelModel: panelModel,
                audioHistoryProvider: audioHistoryProvider,
                collapseAction: { [weak self] in
                    self?.collapse(expandBackToPill: true)
                },
                companionManager: companionManager
            )
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.frame = NSRect(origin: .zero, size: panel.contentView!.bounds.size)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(hostingView)

            panel.orderFrontRegardless()
            rebuiltPresences.append(
                ScreenPresence(
                    displayID: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0,
                    screen: screen,
                    panel: panel
                )
            )
        }

        for presence in screenPresences where !rebuiltPresences.contains(where: { $0.panel == presence.panel }) {
            presence.panel.orderOut(nil)
        }
        screenPresences = rebuiltPresences

        refreshFullscreenSuppression()
    }

    // MARK: - Monitors

    private func installMonitorsIfNeeded() {
        guard globalClickMonitor == nil else { return }

        // One global click monitor covers outside clicks in both directions:
        // a click on some other app's window while the sheet is expanded
        // collapses it, and a click elsewhere never expands. Global monitors
        // observe without consuming, so the click still reaches its window.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleGlobalClick(at: NSEvent.mouseLocation)
        }

        // A global monitor explicitly does NOT see events destined for this
        // app's own windows — and the pill IS this app's window, so a click
        // on it only ever surfaces here, on the local monitor. The event is
        // returned untouched; the handler only reads the location.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleGlobalClick(at: NSEvent.mouseLocation)
            return event
        }

        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFullscreenSuppression()
        })
        workspaceObservers.append(workspaceNotificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildScreenPresences()
        })

        // The app activating is what lets the sheet take keystrokes; the app
        // resigning active means the user went elsewhere — collapse rather
        // than leave a sheet floating over another app's work.
        defaultCenterObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.collapse(expandBackToPill: true)
        })

        // The sheet's resize grip changed the persisted height: re-frame the
        // expanded panel live (no animation — the drag is the animation).
        defaultCenterObservers.append(NotificationCenter.default.addObserver(
            forName: NotchSupport.clickyNotchSheetSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panelModel.isExpanded,
                  let presence = self.screenPresences.first(where: { $0.screen == self.expandedScreen }) else { return }
            presence.panel.setFrame(
                NotchSupport.expandedSheetFrame(on: presence.screen),
                display: true,
                animate: false
            )
        })
    }

    private func removeMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        defaultCenterObservers = []
    }

    // MARK: - Dwell detection

    /// Starts the 30 Hz poll that drives hover-dwell. Polling rather than a
    /// mouseMoved monitor: the pill sits inside the menu-bar band where mouse
    /// events arrive from whichever app is frontmost, and a poll reads
    /// `NSEvent.mouseLocation` no matter who owns the event stream.
    private func startDwellTimer() {
        guard dwellTimer == nil else { return }
        let timer = Timer(timeInterval: Self.dwellPollingInterval, repeats: true) { [weak self] _ in
            self?.pollHoverDwell()
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func stopDwellTimer() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellStartedAt = nil
        panelModel.dwellProgress = 0
    }

    private func pollHoverDwell() {
        guard !panelModel.isExpanded else { return }

        let cursorLocation = NSEvent.mouseLocation

        // Which pill is the cursor over? Entered with the wide (enter)
        // margin, exited with the narrow one — the hysteresis band keeps the
        // ring from flickering on a jittering cursor.
        let hoveredPresence = screenPresences.first { presence in
            guard let restingFrame = NotchSupport.restingPillFrame(on: presence.screen) else { return false }
            let enterFrame = restingFrame.insetBy(dx: -NotchSupport.hoverEnterMargin, dy: -NotchSupport.hoverEnterMargin)
            let exitFrame = restingFrame.insetBy(dx: -NotchSupport.hoverExitMargin, dy: -NotchSupport.hoverExitMargin)

            if dwellStartedAt != nil {
                return exitFrame.contains(cursorLocation)
            }
            return enterFrame.contains(cursorLocation)
        }

        // Active or suppressed — dwell is meaningless, but the timer keeps
        // polling: it is the only thing that can start a dwell, so stopping
        // it here would strand the pill until the next voice-state change.
        guard panelModel.activityPhase == .idle, !panelModel.isFullscreenSuppressed else {
            dwellStartedAt = nil
            panelModel.dwellProgress = 0
            return
        }

        // Cursor not over any pill — drop an in-flight dwell (leaving the
        // exit frame cancels the ring) and keep polling.
        guard let hoveredPresence else {
            dwellStartedAt = nil
            panelModel.dwellProgress = 0
            return
        }

        if dwellStartedAt == nil {
            dwellStartedAt = Date()
        }
        let elapsed = Date().timeIntervalSince(dwellStartedAt ?? Date())
        panelModel.dwellProgress = CGFloat(elapsed / Self.hoverDwellDuration)

        if elapsed >= Self.hoverDwellDuration {
            // Reset the dwell state but do NOT stop the timer — the poll
            // early-returns while expanded, and a stopped timer would leave
            // the pill permanently unable to dwell again after collapse
            // (nothing restarts it except teardown).
            dwellStartedAt = nil
            panelModel.dwellProgress = 0
            expand(on: hoveredPresence)
        }
    }

    // MARK: - Expand / collapse

    private func handleGlobalClick(at clickLocation: NSPoint) {
        if panelModel.isExpanded {
            if let expandedScreen,
               !NotchSupport.expandedSheetFrame(on: expandedScreen).contains(clickLocation) {
                collapse(expandBackToPill: true)
            }
            return
        }

        if panelModel.isFullscreenSuppressed { return }

        if let clickedPresence = screenPresences.first(where: { presence in
            guard let restingFrame = NotchSupport.restingPillFrame(on: presence.screen) else { return false }
            return restingFrame.insetBy(dx: -NotchSupport.hoverEnterMargin, dy: -NotchSupport.hoverEnterMargin).contains(clickLocation)
        }) {
            expand(on: clickedPresence)
        }
    }

    private func expand(on presence: ScreenPresence) {
        guard !panelModel.isExpanded else { return }
        let expandedFrame = NotchSupport.expandedSheetFrame(on: presence.screen)

        expandedScreen = presence.screen
        panelModel.isExpanded = true
        // A click-expand can arrive mid-dwell; a stale dwellStartedAt would
        // make the very next hover after collapse skip the ring and expand
        // instantly.
        dwellStartedAt = nil
        panelModel.dwellProgress = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NotchSupport.expansionAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            presence.panel.setFrame(expandedFrame, display: true)
        }
        // The sheet's shadow comes on with the expansion: the resting pill
        // must never cast one (it would draw a halo under the menu bar), but
        // the expanded sheet is #161615 on whatever the user has behind it —
        // often near-black windows — and without a shadow its silhouette,
        // rounded bottom corners included, disappears into the background.
        presence.panel.hasShadow = true

        withAnimation(.easeInOut(duration: NotchSupport.expansionAnimationDuration)) {
            panelModel.expansionProgress = 1
        }

        // The sheet has text fields (search, composer) — it cannot receive
        // keystrokes without the app being active and the panel being key,
        // the same trap the settings window documents.
        presence.panel.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        presence.panel.makeKeyAndOrderFront(nil)

        SoundEffectPlayer.shared.play(.notchRevealed)

        installEscapeMonitorIfNeeded()
    }

    /// Every collapse path funnels here. `expandBackToPill` false (teardown)
    /// leaves the panel off-screen entirely.
    func collapse(expandBackToPill: Bool) {
        guard panelModel.isExpanded else { return }

        // The panel that is expanded is resolved BEFORE the expanded-screen
        // bookkeeping clears — after that, no presence matches "expanded"
        // and the morph-back would silently pick a wrong screen.
        let collapsingPresence = screenPresences.first { $0.screen == expandedScreen }
        panelModel.isExpanded = false
        expandedScreen = nil
        removeEscapeMonitor()

        // Morph back to the WIDE resting frame (restingWindowFrame), not the
        // pill rect: the window was created at the wide frame so the flanks
        // have a 150pt canvas per side, and shrinking to the pill rect here
        // clipped that canvas away permanently — after the first expand the
        // flank animations could never draw again. The pill rect remains the
        // hit-test geometry (dwell / click-to-expand above); only the window
        // frame has to come back wide.
        guard expandBackToPill,
              let collapsingPresence,
              let restingFrame = NotchSupport.restingWindowFrame(on: collapsingPresence.screen) else {
            withAnimation(.easeInOut(duration: NotchSupport.expansionAnimationDuration)) {
                panelModel.expansionProgress = 0
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NotchSupport.expansionAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            collapsingPresence.panel.setFrame(restingFrame, display: true)
        }, completionHandler: {
            // Shadow off only once the morph lands — dropping it at the
            // start would make the sheet's silhouette pop mid-animation.
            collapsingPresence.panel.hasShadow = false
        })
        // Back to the inert resting state — see the panel creation comment.
        collapsingPresence.panel.ignoresMouseEvents = true

        withAnimation(.easeInOut(duration: NotchSupport.expansionAnimationDuration)) {
            panelModel.expansionProgress = 0
        }
    }

    private func installEscapeMonitorIfNeeded() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc while the sheet is expanded collapses it and swallows the
            // key — the sheet is key, so the monitor is local and cannot
            // steal anyone else's Esc.
            if event.keyCode == 53 {
                self?.collapse(expandBackToPill: true)
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

    // MARK: - Fullscreen suppression

    private func refreshFullscreenSuppression() {
        // Build the per-display geometry the heuristic needs: the display's
        // bounds in the window list's top-left space, and whether the menu
        // bar is currently hidden there (`visibleFrame == frame`) — the
        // second signal that separates a real fullscreen space from this
        // machine's resident full-screen driver overlays.
        let displayGeometries = screenPresences.map { presence -> NotchSupport.DisplayGeometry in
            let screen = presence.screen
            return NotchSupport.DisplayGeometry(
                displayID: presence.displayID,
                displayBounds: CGDisplayBounds(presence.displayID),
                isMenuBarHidden: abs(screen.visibleFrame.height - screen.frame.height) < 0.5
                    && abs(screen.visibleFrame.width - screen.frame.width) < 0.5
            )
        }

        let coveredDisplayIDs = NotchSupport.displaysCoveredByOtherProcessFullscreen(
            displayGeometries: displayGeometries,
            ownProcessID: getpid()
        )
        let isAnyDisplaySuppressed = screenPresences.contains { coveredDisplayIDs.contains($0.displayID) }

        panelModel.isFullscreenSuppressed = isAnyDisplaySuppressed

        for presence in screenPresences {
            if coveredDisplayIDs.contains(presence.displayID) && !panelModel.isExpanded {
                presence.panel.orderOut(nil)
            } else {
                presence.panel.orderFrontRegardless()
            }
        }

        if isAnyDisplaySuppressed, dwellStartedAt != nil {
            // Reset an in-flight dwell but keep the timer — same reason the
            // poll never stops itself: the timer must survive to see the
            // suppression lift.
            dwellStartedAt = nil
            panelModel.dwellProgress = 0
        }
    }

    // MARK: - Companion state binding

    /// Mirrors the companion's voice state into the notch's activity phase,
    /// and re-checks suppression on every change (a fullscreen space change
    /// sometimes lands without a workspace notification).
    func bindCompanionState(voiceStatePublisher: AnyPublisher<CompanionVoiceState, Never>) {
        voiceStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState in
                guard let self else { return }
                self.latestVoiceState = voiceState
                self.refreshActivityPhase()
                self.refreshFullscreenSuppression()
                // Idempotent — the timer is already running from install; this
                // only matters if it was torn down and the subsystem came back.
                self.startDwellTimer()
            }
            .store(in: &cancellables)
    }

    /// 「松键后等最终结果」的间隙——语音已停、识别服务还没给出最终文本——
    /// 是原版 `legacyDictationTypingDashes` 的时刻：右翼打字点线，左翼
    /// Typing…。识别收尾映射成独立的 `.transcribing` 相位，盖过 thinking，
    /// 收尾一结束就回落到语音状态映射的相位。
    func bindDictationFinalizing(_ publisher: AnyPublisher<Bool, Never>) {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isFinalizing in
                guard let self else { return }
                self.isDictationFinalizing = isFinalizing
                self.refreshActivityPhase()
            }
            .store(in: &cancellables)
    }

    private var latestVoiceState: CompanionVoiceState = .idle
    private var isDictationFinalizing = false

    private func refreshActivityPhase() {
        panelModel.activityPhase = isDictationFinalizing
            ? .transcribing
            : NotchActivityPhase(from: latestVoiceState)
    }
}

extension NotchActivityPhase {
    init(from voiceState: CompanionVoiceState) {
        switch voiceState {
        case .idle: self = .idle
        case .listening: self = .listening
        case .processing: self = .thinking
        case .responding: self = .speaking
        }
    }
}
