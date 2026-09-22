//
//  NotchWindowController.swift
//  leanring-buddy
//
//  The notch presence subsystem: one panel per notched screen, resting as an
//  invisible black pill fused into the hardware notch, expanding on CLICK
//  into the app's main floating sheet. Hover does NOT expand it — the user
//  removed hover-dwell on 2026-09-22 because a mouse merely passing the menu
//  bar band kept yanking the sheet open (「鼠标滑动触发太影响体验」); click-only
//  also deleted the whole dwell/hover-growth machinery (30 Hz poll, growth
//  commit timer, dwell progress ring).
//
//  Structure mirrors HeyClicky's recovered `NotchScreenInstance` shape (one
//  instance per display holding its panel) and `NotchPanelViewState` (the
//  per-panel visible state). `NotchPanel` is borderless, nonactivating and
//  keyable, which is what lets the expanded sheet take keyboard focus without
//  stealing the frontmost app's activation.
//
//  One panel does both roles: its frame morphs between the resting pill rect
//  and the expanded sheet rect (a single window resizing — rebuilding or
//  swapping windows would flash and drop key status), while the SwiftUI
//  content inside switches between pill and sheet, keyed off the same
//  `expansionProgress` that drives `HomeSpaceSheetShape`. The frame morph
//  (`NSAnimationContext`, 0.62 s 过冲曲线) and the progress animation
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
    /// 0–1, the sheet expansion. Drives `HomeSpaceSheetShape` and the
    /// pill/sheet content switch.
    @Published var expansionProgress: CGFloat = 0
    @Published var isExpanded: Bool = false
    @Published var isFullscreenSuppressed: Bool = false
    /// An outside caller's request (the menu bar panel's 「更换…」) for the
    /// sheet to open straight into the settings pages. `NotchSheetRootView`
    /// consumes it — on appear and on change — by switching to settings and
    /// nilling it back. Optional because "no request pending" is the normal
    /// state, and the sheet must not re-enter settings on every unrelated
    /// panel-model publish.
    @Published var requestedSettingsPage: SettingsPage?
}

@MainActor
final class NotchWindowController {

    /// Borderless panel that can become key — the expanded sheet has text
    /// fields, and a window that cannot become key silently swallows every
    /// keystroke.
    final class NotchPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct ScreenPresence {
        let displayID: CGDirectDisplayID
        let screen: NSScreen
        let panel: NotchPanel
    }

    /// Strong on purpose — the manager owns this controller, so a strong back
    /// reference is a cycle, and a deliberate one: both objects live for the
    /// whole app run (the same reasoning the overlay windows use), so the
    /// cycle never has to break.
    private let companionManager: CompanionManager
    private let panelModel = NotchPanelModel()
    private let audioHistoryProvider: () -> [CGFloat]

    private var screenPresences: [ScreenPresence] = []
    private var cancellables: Set<AnyCancellable> = []
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
            // hit-test geometry for click-to-expand below.
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

    // MARK: - Expand / collapse

    /// Expands the sheet straight into the settings pages — the menu bar
    /// panel's 「更换…」 path, so the notch sheet's settings UI (the one the
    /// user kept) is what opens instead of the old titled window. Returns
    /// false when no screen can host the sheet right now (no notched screen,
    /// or every one is under another process's fullscreen window), and the
    /// caller falls back to the titled window — which is also what keeps
    /// settings reachable before onboarding installs the subsystem at all.
    @discardableResult
    func expandShowingSettings(initialPage: SettingsPage) -> Bool {
        guard !screenPresences.isEmpty, !panelModel.isFullscreenSuppressed else { return false }

        // Set the request BEFORE expanding: the sheet view is inserted by
        // expand() in this same call, so its onAppear is what consumes it —
        // ordering the flag first means the view can never appear, miss the
        // request, and sit on the conversation home.
        panelModel.requestedSettingsPage = initialPage

        if !panelModel.isExpanded {
            // Reuse whichever screen was expanded last (the user's mental
            // model of "the notch"), else the first notched screen.
            let targetPresence = screenPresences.first { $0.screen == expandedScreen }
                ?? screenPresences[0]
            expand(on: targetPresence)
        }
        // Already expanded: the running sheet consumes the request through
        // its onChange below — no collapse/re-expand flash.
        return true
    }

    /// 「启动时自动打开面板」: expands the sheet on launch so the conversation
    /// is already open. Same screen choice as `expandShowingSettings` —
    /// whichever screen was expanded last, else the first notched screen.
    /// Returns false (and does nothing) when no screen can host the sheet
    /// right now.
    @discardableResult
    func expandForLaunch() -> Bool {
        guard !screenPresences.isEmpty, !panelModel.isFullscreenSuppressed else { return false }

        if !panelModel.isExpanded {
            let targetPresence = screenPresences.first { $0.screen == expandedScreen }
                ?? screenPresences[0]
            expand(on: targetPresence)
        }
        return true
    }

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
            return restingFrame.insetBy(dx: -NotchSupport.pillClickHitMargin, dy: -NotchSupport.pillClickHitMargin).contains(clickLocation)
        }) {
            expand(on: clickedPresence)
        }
    }

    /// Starts the sheet growing on `presence` and commits it in the same
    /// breath — the window morphs out, the silhouette reaches full size, and
    /// the sheet becomes real (content, activation, key status, shadow,
    /// chime). Hover no longer has a path here: expansion is click-only, so
    /// there is no slow creep to commit later.
    private func beginExpansion(on presence: ScreenPresence) {
        guard !panelModel.isExpanded else { return }
        let expandedFrame = NotchSupport.expandedSheetFrame(on: presence.screen)

        expandedScreen = presence.screen

        let timing = NotchSupport.morphTimingControlPoints
        let duration = NotchSupport.expansionAnimationDuration

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // 与 SwiftUI 侧的 timingCurve 同一组控制点，两边同步落地。
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: timing.0,
                timing.1,
                timing.2,
                timing.3
            )
            context.allowsImplicitAnimation = true
            presence.panel.setFrame(expandedFrame, display: true)
        }
        withAnimation(.timingCurve(
            CGFloat(timing.0),
            CGFloat(timing.1),
            CGFloat(timing.2),
            CGFloat(timing.3),
            duration: duration
        )) {
            panelModel.expansionProgress = 1
        }

        presence.panel.ignoresMouseEvents = false
        panelModel.isExpanded = true
        finishExpansionCommit(on: presence)
    }

    /// Everything "the sheet is now open" means: content, shadow, activation,
    /// key status, chime, Esc monitor. The overlay's bubble gate follows the
    /// content — it reads `companionManager.isNotchSheetExpanded`.
    private func finishExpansionCommit(on presence: ScreenPresence) {
        // The sheet's shadow comes on with the expansion: the resting pill
        // must never cast one (it would draw a halo under the menu bar), but
        // the expanded sheet is #161615 on whatever the user has behind it —
        // often near-black windows — and without a shadow its silhouette,
        // rounded bottom corners included, disappears into the background.
        presence.panel.hasShadow = true
        companionManager.isNotchSheetExpanded = true

        // The sheet has text fields (search, composer) — it cannot receive
        // keystrokes without the app being active and the panel being key,
        // the same trap the settings window documents.
        NSApp.activate(ignoringOtherApps: true)
        presence.panel.makeKeyAndOrderFront(nil)

        SoundEffectPlayer.shared.play(.notchRevealed)

        installEscapeMonitorIfNeeded()
    }

    /// Every expand path — the pill click, the settings entry, the launch
    /// entry — runs the same immediate morph.
    private func expand(on presence: ScreenPresence) {
        beginExpansion(on: presence)
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
        companionManager.isNotchSheetExpanded = false
        removeEscapeMonitor()

        // Morph back to the WIDE resting frame (restingWindowFrame), not the
        // pill rect: the window was created at the wide frame so the flanks
        // have a 150pt canvas per side, and shrinking to the pill rect here
        // clipped that canvas away permanently — after the first expand the
        // flank animations could never draw again. The pill rect remains the
        // hit-test geometry (click-to-expand above); only the window frame has
        // to come back wide.
        guard expandBackToPill,
              let collapsingPresence,
              let restingFrame = NotchSupport.restingWindowFrame(on: collapsingPresence.screen) else {
            withAnimation(.timingCurve(
                CGFloat(NotchSupport.collapseTimingControlPoints.0),
                CGFloat(NotchSupport.collapseTimingControlPoints.1),
                CGFloat(NotchSupport.collapseTimingControlPoints.2),
                CGFloat(NotchSupport.collapseTimingControlPoints.3),
                duration: NotchSupport.collapseAnimationDuration
            )) {
                panelModel.expansionProgress = 0
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NotchSupport.collapseAnimationDuration
            // 收起专用的先缓后快曲线（demo 定稿），退场不跟展开抢戏。
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: NotchSupport.collapseTimingControlPoints.0,
                NotchSupport.collapseTimingControlPoints.1,
                NotchSupport.collapseTimingControlPoints.2,
                NotchSupport.collapseTimingControlPoints.3
            )
            context.allowsImplicitAnimation = true
            collapsingPresence.panel.setFrame(restingFrame, display: true)
        }, completionHandler: {
            // Shadow off only once the morph lands — dropping it at the
            // start would make the sheet's silhouette pop mid-animation.
            collapsingPresence.panel.hasShadow = false
        })
        // Back to the inert resting state — see the panel creation comment.
        collapsingPresence.panel.ignoresMouseEvents = true

        withAnimation(.timingCurve(
            CGFloat(NotchSupport.collapseTimingControlPoints.0),
            CGFloat(NotchSupport.collapseTimingControlPoints.1),
            CGFloat(NotchSupport.collapseTimingControlPoints.2),
            CGFloat(NotchSupport.collapseTimingControlPoints.3),
            duration: NotchSupport.collapseAnimationDuration
        )) {
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
