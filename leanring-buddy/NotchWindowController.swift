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
//  One panel does both roles: its frame moves between the resting pill rect
//  and the expanded sheet rect (a single window resizing — rebuilding or
//  swapping windows would flash and drop key status), while the SwiftUI
//  content inside switches between pill and sheet, keyed off
//  `expansionProgress` — which is DERIVED from the panel's live frame on
//  every `windowDidResize`, not animated on its own.
//
//  Expansion and collapse use two different mechanisms, both ported from
//  `刘海屏弹出窗口_12种动画对比.html`:
//
//    · 展开 = 02 幕布垂落. The frame is set ONCE (the sheet's final rect) and
//      the animation is a clip on the content layer falling from the top edge
//      — Core Animation, on the render server, with no per-frame window
//      resize and no per-frame SwiftUI layout. 2026-09-23: this replaced a
//      per-frame window resize along the 01 中心缩放 scale path, which was a
//      category error — the reference animates `transform`/`clip-path` on a
//      fixed-size element precisely because resizing re-wraps text and
//      rebuilds the window's drawing surface every frame.
//    · 收起 = the reference's winClose: scale .92 + the whole window fading
//      out over 160 ms ease-in, still driven frame-by-frame by
//      `driveCenterScaleFrames` (the window frame is its own animation source
//      there, and progress derives from it, so the silhouette cannot desync
//      or stall — the desync-stall class behind the 2026-09-23 「刘海缩不回去」
//      bug, see 开发经验/10 G12).
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
    /// 0–1, the sheet expansion. NOT independently animated — it is derived
    /// from the expanding panel's live frame on every `windowDidResize` (see
    /// `syncExpansionProgressWithPanelFrame`), so the window's single frame
    /// animation is the only animation source and the silhouette cannot
    /// desync from it, let alone stall behind it.
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
    /// The VoiceWeb external session's phase override (「连接中…」/「已连接」).
    /// nil = no override — the same nil-means-unset shape as
    /// `requestedSettingsPage`, and the same override precedent as
    /// `isDictationFinalizing`: `refreshActivityPhase` consults it first.
    /// Set through `NotchWindowController.setExternalSessionOverride`.
    @Published var externalSessionOverride: NotchActivityPhase?
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
        /// The SwiftUI surface inside the panel. Held because the expand
        /// animation masks *this* layer (02 幕布垂落) — the panel's frame is
        /// set once and never animated, so the clip is the only moving part.
        let contentHostingView: NSView
        /// Fires whenever this panel's frame changes — the per-frame hook
        /// that re-derives `expansionProgress` from the live frame while the
        /// morph animates. Removed with the presence in `teardown`.
        let resizeObserver: NSObjectProtocol?
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
    /// Bumped on every collapse so a pending convergence watchdog from an
    /// earlier collapse stands down instead of snapping a newer collapse's
    /// mid-flight animation to rest.
    private var collapseGeneration = 0

    /// Same guard for expansions: every beginExpansion bumps this, and its
    /// completion/watchdog callbacks stand down when a newer expand has taken
    /// over — without it, a watchdog firing after an expand→collapse→expand
    /// cycle would snap the OLD screen's panel to that OLD expanded frame.
    private var expansionGeneration = 0

    /// The screen whose sheet is currently expanded. At most one — expanding
    /// on a second screen collapses the first.
    private var expandedScreen: NSScreen?

    /// 中心缩放收起的逐帧驱动器（2026-09-23，参考
    /// `刘海屏弹出窗口_12种动画对比.html` 的 winClose）。**展开已经不用它了**
    /// ——展开是 02 幕布垂落，窗口一步到最终 frame、动的是内容层的遮罩（见
    /// `beginExpansion` / `startCurtainReveal`）。收起仍然是逐帧 setFrame：
    /// 它是一条以刘海顶边中点为锚的等比缩放路径，NSAnimationContext 只会做
    /// 两端 frame 的线性拉伸（「由小变大」而不是「等比缩小」），只能自己算。
    /// 每次新的收起先 invalidate 上一个，防两个驱动器抢同一个面板。
    private var centerScaleAnimationTimer: Timer?

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
            if let resizeObserver = presence.resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
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
            // 展开的幕布挂在宿主层的 `mask` 上（02 幕布垂落），所以这一层必须
            // 真的存在——NSHostingView 通常自带 layer，显式置位不依赖这个巧合。
            hostingView.wantsLayer = true
            panel.contentView?.addSubview(hostingView)

            panel.orderFrontRegardless()

            // Every real frame of the panel's morph re-derives the published
            // expansion progress from the live frame — the window animation
            // is the single animation source (see the model's doc comment).
            let resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.syncExpansionProgressWithPanelFrame(panel, on: screen)
            }

            rebuiltPresences.append(
                ScreenPresence(
                    displayID: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0,
                    screen: screen,
                    panel: panel,
                    contentHostingView: hostingView,
                    resizeObserver: resizeObserver
                )
            )
        }

        for presence in screenPresences where !rebuiltPresences.contains(where: { $0.panel == presence.panel }) {
            if let resizeObserver = presence.resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            presence.panel.orderOut(nil)
        }
        screenPresences = rebuiltPresences

        // The panel model outlives a rebuild (one shared model), so a rebuilt
        // presence re-syncs progress from its fresh panel's resting frame —
        // otherwise a value left high by a torn-down panel would draw the
        // mid-collapse outline on the new pill.
        for presence in screenPresences {
            syncExpansionProgressWithPanelFrame(presence.panel, on: presence.screen)
        }

        refreshFullscreenSuppression()
    }

    /// Derives `expansionProgress` from the panel's live frame — the inverse
    /// of the frame morph. `NSWindow` frame animation is a REAL per-frame
    /// resize (measured 2026-09-23: 18 intermediate frames over a 0.5 s
    /// morph, each a genuine `window.frame`), so this fires once per
    /// animation frame via `windowDidResize` and the published progress
    /// tracks the window exactly, with no second animation to desync or
    /// stall. Plain assignment — no `withAnimation`: the window is what
    /// animates; this only reports where it is.
    private func syncExpansionProgressWithPanelFrame(_ panel: NotchPanel, on screen: NSScreen) {
        guard let restingFrame = NotchSupport.restingWindowFrame(on: screen) else { return }
        let expandedFrame = NotchSupport.expandedSheetFrame(on: screen)
        let heightRange = expandedFrame.height - restingFrame.height
        guard heightRange > 1 else { return }
        let progress = (panel.frame.height - restingFrame.height) / heightRange
        panelModel.expansionProgress = min(max(progress, 0), 1)
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

        // 语音聊天进行中，右翼就是不展开刘海的那颗挂断按钮（用户 2026-09-23
        // 第 6 条：「如果用户已经点击连接或当前处于连接状态，菜单栏刘海屏右侧
        // 应显示一个挂断动画，或者保留菜单栏当前样式风格，把它做成挂断按钮，
        // 用户可以直接点击挂断，不必展开刘海屏再点击挂断」）。
        //
        // 判在 pill 之前：右翼在 pill 右侧、两者不重叠，顺序本身不影响结果，
        // 但写死了能保证以后有人把 pill 的命中区放大时，挂断不会被吃掉。
        // 命中的是收起态的窗口——它 `ignoresMouseEvents = true`，所以这一下
        // 既没有落到本 app 的窗口上，也不会被谁拦下，全局监听照常收到。
        if panelModel.externalSessionOverride == .externalChatting,
           screenPresences.contains(where: { presence in
               guard let wingFrame = NotchSupport.restingTrailingWingFrame(on: presence.screen) else { return false }
               return wingFrame.contains(clickLocation)
           }) {
            companionManager.voiceWebSessionController.disconnectCurrentSession()
            return
        }

        if let clickedPresence = screenPresences.first(where: { presence in
            guard let restingFrame = NotchSupport.restingPillFrame(on: presence.screen) else { return false }
            return restingFrame.insetBy(dx: -NotchSupport.pillClickHitMargin, dy: -NotchSupport.pillClickHitMargin).contains(clickLocation)
        }) {
            expand(on: clickedPresence)
        }
    }

    /// Starts the sheet opening on `presence` and commits it in the same
    /// breath — the window is put at its final frame in ONE step and the
    /// reveal is a curtain clip on the content layer (02 幕布垂落, see
    /// `NotchSupport.curtainRevealDuration`). No per-frame `setFrame`, no
    /// per-frame SwiftUI layout: the width is final from frame 0, so text
    /// cannot re-wrap mid-animation, and the main thread has nothing to do
    /// while the curtain falls.
    private func beginExpansion(on presence: ScreenPresence) {
        guard !panelModel.isExpanded else { return }
        let expandedFrame = NotchSupport.expandedSheetFrame(on: presence.screen)

        expansionGeneration += 1
        let expansionGenerationAtStart = expansionGeneration
        expandedScreen = presence.screen

        // Order matters. The curtain goes on FIRST, at zero visible height:
        // `setFrame(display: true)` below forces a synchronous draw, so
        // installing the mask afterwards would paint the finished sheet for
        // one frame before the curtain hid it — a visible flash.
        installCurtainMask(on: presence)

        panelModel.isExpanded = true
        presence.panel.setFrame(expandedFrame, display: true)

        startCurtainReveal(on: presence, expandedFrame: expandedFrame)

        // Back to the deadline the curtain was measured against; the sheet
        // must be fully revealed by then whether or not the animation ran.
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchSupport.curtainRevealDuration + 0.05) { [weak self] in
            guard let self,
                  self.expansionGeneration == expansionGenerationAtStart,
                  self.panelModel.isExpanded else { return }
            self.removeCurtainMask(on: presence)
        }

        presence.panel.ignoresMouseEvents = false
        finishExpansionCommit(on: presence)

        // Expansion watchdog: a dropped layer animation cannot strand the
        // sheet half-revealed — past the curtain's deadline, force the
        // expanded state (frame and mask) unless a newer expand/collapse
        // owns the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchSupport.curtainRevealDuration + 0.25) { [weak self] in
            guard let self,
                  self.expansionGeneration == expansionGenerationAtStart,
                  self.panelModel.isExpanded else { return }
            self.convergeOnExpandedState(presence, targetFrame: expandedFrame)
        }
    }

    /// Hangs the curtain on the content layer at zero visible height — the
    /// panel renders nothing until `startCurtainReveal` grows it.
    ///
    /// The mask's geometry is computed from the FINAL expanded frame, not
    /// from the hosting view's current bounds: the window has not been
    /// resized yet at this point, and a mask sized to the resting frame would
    /// stay that size (sublayers do not follow their superlayer's bounds) and
    /// reveal the sheet through a pill-sized hole.
    private func installCurtainMask(on presence: ScreenPresence) {
        guard let hostingLayer = presence.contentHostingView.layer else { return }
        let maskLayer = CALayer()
        maskLayer.backgroundColor = NSColor.black.cgColor

        CATransaction.begin()
        // Implicit animations would animate the mask's own installation —
        // installing it must be instantaneous, the reveal is the animation.
        CATransaction.setDisableActions(true)
        hostingLayer.mask = maskLayer
        CATransaction.commit()
    }

    /// 02 幕布垂落's reveal: one Core Animation group growing the mask's
    /// visible strip from the content's top edge down to its full height. The
    /// render server plays it — the main thread does no per-frame work, which
    /// is the whole point of doing this as a clip instead of a window resize.
    private func startCurtainReveal(on presence: ScreenPresence, expandedFrame: CGRect) {
        guard let maskLayer = presence.contentHostingView.layer?.mask else { return }
        let contentWidth = expandedFrame.width
        let contentHeight = expandedFrame.height

        // The strip is anchored at the content's TOP edge, and "top" is a
        // different y depending on the hosting view's flippedness: a flipped
        // (top-left origin) view's top edge is y = 0, an unflipped one's is
        // y = height. Handling both explicitly keeps the curtain falling
        // downward either way instead of silently rising from the bottom.
        let topEdgeY: CGFloat = presence.contentHostingView.isFlipped ? 0 : contentHeight

        // Model values are the END state: if the animation were ever dropped,
        // the worst case is a fully revealed sheet, never a permanently
        // half-covered panel.
        let fullBounds = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let centrePosition = CGPoint(x: contentWidth / 2, y: contentHeight / 2)
        let collapsedBounds = CGRect(x: 0, y: 0, width: contentWidth, height: 0)
        let topEdgePosition = CGPoint(x: contentWidth / 2, y: topEdgeY)

        // Both properties interpolate together under one timing function, so
        // the strip's top edge stays pinned exactly at the content's top edge
        // for the whole reveal — that pinning IS the curtain.
        let boundsAnimation = CABasicAnimation(keyPath: "bounds")
        boundsAnimation.fromValue = NSValue(rect: collapsedBounds)
        boundsAnimation.toValue = NSValue(rect: fullBounds)

        let positionAnimation = CABasicAnimation(keyPath: "position")
        positionAnimation.fromValue = NSValue(point: topEdgePosition)
        positionAnimation.toValue = NSValue(point: centrePosition)

        let revealGroup = CAAnimationGroup()
        revealGroup.animations = [boundsAnimation, positionAnimation]
        revealGroup.duration = NotchSupport.curtainRevealDuration
        let controlPoints = NotchSupport.curtainRevealTimingControlPoints
        revealGroup.timingFunction = CAMediaTimingFunction(
            controlPoints: controlPoints.0,
            controlPoints.1,
            controlPoints.2,
            controlPoints.3
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.bounds = fullBounds
        maskLayer.position = centrePosition
        maskLayer.add(revealGroup, forKey: "curtainReveal")
        CATransaction.commit()
    }

    /// Takes the curtain off. Idempotent, and called from every path that
    /// claims the panel is (or is becoming) fully open or fully closed — a
    /// mask left behind would clip the sheet forever, and it also costs a
    /// compositing pass on every frame the panel draws.
    private func removeCurtainMask(on presence: ScreenPresence) {
        guard let hostingLayer = presence.contentHostingView.layer, hostingLayer.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingLayer.mask = nil
        CATransaction.commit()
    }

    /// Forces the panel into the fully-open state with no animation — the
    /// counterpart of `convergeOnRestingState`, covering both halves of what
    /// "open" means: the frame (which `beginExpansion` already put in place in
    /// one step, so this is normally a no-op) and the curtain (which must come
    /// off). Idempotent at every normal completion.
    private func convergeOnExpandedState(_ presence: ScreenPresence, targetFrame: CGRect) {
        guard panelModel.isExpanded else { return }
        removeCurtainMask(on: presence)
        let frame = presence.panel.frame
        let isFrameAtTarget =
            abs(frame.minX - targetFrame.minX) < 0.5 &&
            abs(frame.minY - targetFrame.minY) < 0.5 &&
            abs(frame.width - targetFrame.width) < 0.5 &&
            abs(frame.height - targetFrame.height) < 0.5
        if !isFrameAtTarget {
            presence.panel.setFrame(targetFrame, display: true)
        }
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

        // The curtain belongs to the expansion. A collapse can start while it
        // is still falling (a click on the close button right after opening),
        // and the winClose fade must take the WHOLE sheet with it — leave the
        // mask on and the fade would play over a still-clipped panel.
        if let collapsingPresence {
            removeCurtainMask(on: collapsingPresence)
        }

        // Every collapse bumps the generation; a pending convergence callback
        // from an earlier collapse sees the bump and stands down instead of
        // snapping this collapse's mid-flight animation to rest.
        collapseGeneration += 1
        let collapseGenerationAtStart = collapseGeneration

        guard expandBackToPill,
              let collapsingPresence,
              let restingFrame = NotchSupport.restingWindowFrame(on: collapsingPresence.screen) else {
            // Teardown path: the panel is ordered out right after this, so
            // nobody sees an animation — stop any running scale driver and
            // leave the panel opaque at rest for the next install.
            centerScaleAnimationTimer?.invalidate()
            centerScaleAnimationTimer = nil
            if let collapsingPresence {
                removeCurtainMask(on: collapsingPresence)
                collapsingPresence.panel.alphaValue = 1
            }
            return
        }

        // winClose (reference page 01): scale .92 + fade the whole window
        // out over 160 ms ease-in — the sheet shrinks a touch and vanishes
        // rather than shrinking all the way back into the notch. alphaValue
        // multiplies the window's shadow too, so the silhouette and its
        // shadow fade together.
        driveCenterScaleFrames(
            panel: collapsingPresence.panel,
            targetFrame: NotchSupport.expandedSheetFrame(on: collapsingPresence.screen),
            startScale: 1.0,
            endScale: NotchSupport.centerScaleCollapseFinalScale,
            duration: NotchSupport.centerScaleCollapseDuration,
            controlPoints: NotchSupport.centerScaleCollapseTimingControlPoints,
            fadesToTransparent: true,
            completion: { [weak self] in
                guard let self, self.collapseGeneration == collapseGenerationAtStart else { return }
                // While fully transparent, drop the shadow and put the frame
                // back at the WIDE resting frame (restingWindowFrame, not the
                // pill rect): the window was created wide so the flanks have
                // a 150 pt canvas per side — shrinking to the pill rect here
                // clipped that canvas away permanently (measured 2026-09-23).
                collapsingPresence.panel.hasShadow = false
                collapsingPresence.panel.setFrame(restingFrame, display: false)
                collapsingPresence.panel.alphaValue = 1
                self.convergeOnRestingState(collapsingPresence)
            }
        )
        // Back to the inert resting state — see the panel creation comment.
        collapsingPresence.panel.ignoresMouseEvents = true

        // Convergence watchdog: the completion handler above can be skipped
        // when the frame animation is replaced or dropped. After the fade's
        // deadline, force the resting state unless a newer expand/collapse
        // owns it — the published progress follows the frame, so one snap
        // covers both.
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchSupport.centerScaleCollapseDuration + 0.25) { [weak self] in
            guard let self,
                  self.collapseGeneration == collapseGenerationAtStart,
                  !self.panelModel.isExpanded else { return }
            self.convergeOnRestingState(collapsingPresence)
        }
    }

    /// The winClose frame driver — the collapse's animation source. Each tick
    /// evaluates the reference page's CSS cubic-bezier timing function, scales
    /// `targetFrame` about its top-centre anchor (transform-origin: 50% 0),
    /// and setFrame's the result. `fadesToTransparent` additionally drives the
    /// window's alphaValue down with the same curve — winClose's opacity leg.
    /// (Expansion has no driver any more: 02 幕布垂落 sets the frame once and
    /// animates a layer mask instead.)
    private func driveCenterScaleFrames(
        panel: NSPanel,
        targetFrame: CGRect,
        startScale: CGFloat,
        endScale: CGFloat,
        duration: TimeInterval,
        controlPoints: (Float, Float, Float, Float),
        fadesToTransparent: Bool,
        completion: @escaping () -> Void
    ) {
        centerScaleAnimationTimer?.invalidate()
        let startDate = Date()
        let anchorMidX = targetFrame.midX
        let anchorTopY = targetFrame.maxY

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak panel] timer in
            guard let panel else {
                timer.invalidate()
                return
            }
            let linearProgress = min(Date().timeIntervalSince(startDate) / duration, 1)
            let eased = NotchSupport.timingCurveValue(atProgress: linearProgress, controlPoints: controlPoints)
            let scale = startScale + (endScale - startScale) * CGFloat(eased)
            panel.setFrame(
                CGRect(
                    x: anchorMidX - targetFrame.width * scale / 2,
                    y: anchorTopY - targetFrame.height * scale,
                    width: targetFrame.width * scale,
                    height: targetFrame.height * scale
                ),
                display: true
            )
            if fadesToTransparent {
                panel.alphaValue = 1 - CGFloat(eased)
            }
            if linearProgress >= 1 {
                timer.invalidate()
                self?.centerScaleAnimationTimer = nil
                completion()
            }
        }
        // 同时挂进 .common 模式：scheduledTimer 只挂 .default，展开恰好由一次
        // 点击发起，若点击的追踪循环还没退出，default 模式的定时器整段静默、
        // 进度靠下一次 tick 追平——表现为动画开头顿一下。common 模式下两种
        // 模式都会触发。
        RunLoop.main.add(timer, forMode: .common)
        centerScaleAnimationTimer = timer
    }

    /// Forces the panel's frame to the resting state with no animation — the
    /// winClose fade can still be skipped, and the published
    /// `expansionProgress` is derived from the frame, so snapping the frame
    /// converges that too. Idempotent: at every normal completion this is a
    /// no-op.
    private func convergeOnRestingState(_ presence: ScreenPresence) {
        guard !panelModel.isExpanded else { return }

        // The curtain is expansion state: whatever path got here, the resting
        // pill must not be clipped by a mask left over from an expansion that
        // never finished.
        removeCurtainMask(on: presence)

        // Defensive alpha restore: the winClose fade leaves the window fully
        // transparent until the frame snap brings it back. If the fade's
        // completion was skipped and only this watchdog ran, an unrestored
        // alpha would strand an invisible, unclickable pill.
        presence.panel.alphaValue = 1
        // Same defensive reasoning as the alpha: the resting pill must never
        // cast a shadow (it halos under the menu bar), and a skipped
        // completion would otherwise leave the expanded-state shadow on.
        presence.panel.hasShadow = false

        if let restingFrame = NotchSupport.restingWindowFrame(on: presence.screen) {
            let frame = presence.panel.frame
            let isFrameAtRest =
                abs(frame.minX - restingFrame.minX) < 0.5 &&
                abs(frame.minY - restingFrame.minY) < 0.5 &&
                abs(frame.width - restingFrame.width) < 0.5 &&
                abs(frame.height - restingFrame.height) < 0.5
            if !isFrameAtRest {
                presence.panel.setFrame(restingFrame, display: true)
            }
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
        panelModel.activityPhase = panelModel.externalSessionOverride
            ?? (isDictationFinalizing
                ? .transcribing
                : NotchActivityPhase(from: latestVoiceState))
    }

    /// The VoiceWeb session controller's way in — `panelModel` is private, and
    /// the override only means anything when the derived phase is recomputed
    /// with it in place.
    func setExternalSessionOverride(_ phase: NotchActivityPhase?) {
        panelModel.externalSessionOverride = phase
        refreshActivityPhase()
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
