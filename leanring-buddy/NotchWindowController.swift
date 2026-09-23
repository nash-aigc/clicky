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
//    · 展开 = 01 中心缩放 or 02 幕布垂落, the user's pick in 设置 → 交互样式 →
//      窗口样式 (中心缩放 is the default, chosen 2026-09-23). Either way the
//      frame is set ONCE (the sheet's final rect) and the animation is a Core
//      Animation on the content layer — a scale up from 8% pinned at the
//      top-centre edge, or a clip falling from that same edge. On the render
//      server, with no per-frame window resize and no per-frame SwiftUI
//      layout. 2026-09-23: this replaced a per-frame window resize along the
//      scale path, which was a category error — the reference animates
//      `transform`/`clip-path` on a fixed-size element precisely because
//      resizing re-wraps text and rebuilds the window's drawing surface every
//      frame. The rejected version was that mistake made literal; the scale is
//      now a `CALayer.transform` and the frame never moves.
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
        /// The SwiftUI surface inside the panel. Held because both expand
        /// reveals act on *this* view's layer (its `mask` for the curtain, its
        /// `transform` for the centre pop) — the panel's frame is set once and
        /// never animated, so the layer is the only moving part.
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

    /// 展开提交延后一个 run-loop tick（见 `beginExpansion` 里 2026-09-23 的
    /// 317ms 实测）：`isExpanded` 翻转前的这一小段窗口里，第二次点击会穿过
    /// `!panelModel.isExpanded` 的判断再走一次展开。这个标志在 `beginExpansion`
    /// 置位、在延后块里**无条件**先清掉（在 generation 判断之前），所以任何
    /// 情况下都不会卡死。
    private var isExpansionCommitPending = false

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

    /// 面板**最近一次**展开在哪块屏幕上。刻意不复用 `expandedScreen`：那个
    /// 属性在 `collapse` 里被清成 nil，而这里要的是一段记忆而不是一个状态
    /// —— Agent 页的「打开」先把面板收起来、选完文件夹再放回来，中间那一小段
    /// 里必须还记得原来开在哪儿。只写不清。
    private var lastSheetHostScreen: NSScreen?

    /// The key 边缘缩放's scale animation is added under, so `removeReveal` can
    /// take it off again. One constant rather than a literal in two places —
    /// a typo in the removal would leave the animation running.
    private static let scaleRevealAnimationKey = "scaleReveal"

    /// The key 中心缩放's mask + opacity animations are added under, same
    /// purpose as `scaleRevealAnimationKey`.
    private static let notchBloomAnimationKey = "notchBloomReveal"

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
            panel.level = NotchSupport.notchPanelWindowLevel
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
                hideSheetAction: { [weak self] in
                    self?.collapse(expandBackToPill: true)
                },
                revealSheetAction: { [weak self] in
                    self?.revealSheetAfterTemporaryHide()
                },
                companionManager: companionManager
            )
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.frame = NSRect(origin: .zero, size: panel.contentView!.bounds.size)
            hostingView.autoresizingMask = [.width, .height]
            // 展开的两种揭示都挂在这一层上（幕布用 `mask`、中心缩放用
            // `transform`），所以这一层必须真的存在——NSHostingView 通常自带
            // layer，显式置位不依赖这个巧合。
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

    /// Puts the sheet back after Agent 页的「打开」hid it for the folder picker
    /// (user's 2026-09-23 request: 「整个弹窗直接缩回去，就是隐藏一下」 — 「一下」
    /// meaning it comes back).
    ///
    /// 屏幕取 `lastSheetHostScreen` 而不是 `expandedScreen`：后者已经被
    /// `collapse` 清成 nil 了。面板已经在展开态时什么都不做——那条路径只在
    /// "刚让过位"的时候走到；没有可用的屏幕时也什么都不做，刘海还在，用户
    /// 点一下就能展开。
    func revealSheetAfterTemporaryHide() {
        guard !panelModel.isExpanded else { return }

        let targetPresence = screenPresences.first { $0.screen == lastSheetHostScreen }
            ?? screenPresences.first
        guard let targetPresence else { return }
        expand(on: targetPresence)
    }

    private func handleGlobalClick(at clickLocation: NSPoint) {
        if panelModel.isExpanded {
            // 再点一次刘海就是收起（用户 2026-09-23：「用户点击刘海屏的时候它
            // 展开，用户再点击刘海屏的时候它自动缩回去，增加这样一个动画效果」）。
            // 动画走的是既有的 winClose —— 缩放 1.0→0.92 + 整窗淡出，与 Esc /
            // 点面板外面完全同一条路径。
            //
            // 必须判在下面"点在面板外"之前：刘海命中区落在展开面板**之内**
            // （面板就是从那块刘海垂下来的），先判外面的分支会把这一下当成
            // "点在面板里"而什么都不做。
            //
            // 展开态的刘海那一条是页头的上留白（`sheetHeaderTopInset`），三列
            // 在那一带都没有可点的东西，所以这里不会抢掉任何控件的点击。
            if let expandedScreen,
               let restingFrame = NotchSupport.restingPillFrame(on: expandedScreen),
               restingFrame
                   .insetBy(dx: -NotchSupport.pillClickHitMargin, dy: -NotchSupport.pillClickHitMargin)
                   .contains(clickLocation) {
                collapse(expandBackToPill: true)
                return
            }

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
    /// reveal is a Core Animation on the content layer. No per-frame
    /// `setFrame`, no per-frame SwiftUI layout: the width is final from frame
    /// 0, so text cannot re-wrap mid-animation, and the main thread has nothing
    /// to do while the reveal plays.
    ///
    /// **The reveal is the user's choice** (设置 → 交互 → 窗口样式), and all
    /// three are the same structure differing only in which geometry moves:
    /// 中心缩放 (`startNotchBloomReveal`, the default) expands a mask out of the
    /// notch's own point — down, left and right at once; 边缘缩放
    /// (`startScaleReveal`) scales the content layer up from 8% about the
    /// panel's bottom edge; 幕布垂落 (`startCurtainReveal`) grows a mask down
    /// from the top edge. The one thing they share is the structure above — and
    /// the zero state installed *before* the frame commit, which is what keeps
    /// any of them from flashing a finished sheet for one frame (see
    /// `installRevealCover`).
    private func beginExpansion(on presence: ScreenPresence) {
        // The commit is deferred one tick (see below); a second click landing
        // inside that gap must not start a second expansion on top of it.
        guard !panelModel.isExpanded && !isExpansionCommitPending else { return }
        // 记住开在哪块屏幕上 —— 「打开」让位之后要放回同一块（见
        // `lastSheetHostScreen`）。
        lastSheetHostScreen = presence.screen
        let expandedFrame = NotchSupport.expandedSheetFrame(on: presence.screen)
        // Read the style ONCE here and carry it through the whole expansion:
        // saving in the settings window mid-animation must not turn one reveal
        // into two — the deadline below and the animation have to agree about
        // how long this expansion lasts.
        let expansionStyle = AppSettingsStore.snapshot().windowExpansionStyle
        let revealDuration = NotchSupport.expansionRevealDuration(for: expansionStyle)

        expansionGeneration += 1
        let expansionGenerationAtStart = expansionGeneration
        expandedScreen = presence.screen
        isExpansionCommitPending = true

        // Order matters. The cover (plus the temporary surface) goes on FIRST,
        // hiding the content entirely: `setFrame(display: true)` below forces a
        // synchronous draw, so installing it afterwards would paint the
        // finished sheet for one frame before the reveal hid it — a visible
        // flash.
        installRevealCover(on: presence)

        presence.panel.setFrame(expandedFrame, display: true)

        startReveal(on: presence, style: expansionStyle, expandedFrame: expandedFrame)

        // Back to the deadline the reveal was measured against; the sheet must
        // be fully revealed by then whether or not the animation ran.
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDuration + 0.05) { [weak self] in
            guard let self,
                  self.expansionGeneration == expansionGenerationAtStart,
                  self.panelModel.isExpanded else { return }
            self.removeReveal(on: presence)
        }

        presence.panel.ignoresMouseEvents = false

        // The content flip is DEFERRED one run-loop tick. Measured 2026-09-23
        // (「点击刘海之后没有马上开始展开，而是等了一段时间」): with the flip
        // inline, the sheet's SwiftUI build + draw ran inside the synchronous
        // draw above — 317 ms with a populated conversation (44 ms empty) — so
        // the reveal animation did not begin until click+350 ms. Deferring the
        // flip lets this tick's transaction commit with the reveal animations
        // already attached, and the render server (which plays them on its own
        // clock) starts the expansion the instant the click lands; the sheet
        // builds and draws mid-animation, over the temporary surface. The
        // generation guard stands a second expansion's stale flip down.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Cleared unconditionally: a stale deferred block (a generation
            // bump that should not happen while the flag gates new
            // expansions, but which must never wedge the flag on) must not
            // block every future expansion.
            self.isExpansionCommitPending = false
            guard self.expansionGeneration == expansionGenerationAtStart,
                  !self.panelModel.isExpanded else { return }
            self.panelModel.isExpanded = true
            self.finishExpansionCommit(on: presence)
        }

        // Expansion watchdog: a dropped layer animation cannot strand the
        // sheet half-revealed — past the reveal's deadline, force the expanded
        // state (frame, mask and layer transform) unless a newer
        // expand/collapse owns the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDuration + 0.25) { [weak self] in
            guard let self,
                  self.expansionGeneration == expansionGenerationAtStart,
                  self.panelModel.isExpanded else { return }
            self.convergeOnExpandedState(presence, targetFrame: expandedFrame)
        }
    }

    /// Hides the content before the final frame is committed, so the
    /// synchronous draw that `setFrame(display: true)` forces cannot paint a
    /// finished sheet for one frame before the reveal catches up.
    ///
    /// A zero-height mask is the tool because it works for **all three** styles
    /// and regardless of what the resize does to the layer: a mask hides its
    /// layer's content outright, whereas the two scale styles' own zero state is
    /// a `transform` on that same layer — and a layer transform is not something
    /// we can assume survives AppKit re-syncing the view's geometry during the
    /// resize. The pop therefore starts from this same cover and drops it in
    /// the same transaction that installs its scale (see
    /// `startScaleReveal`), which is a state we can guarantee rather than
    /// one we hope for.
    private func installRevealCover(on presence: ScreenPresence) {
        guard let hostingLayer = presence.contentHostingView.layer else { return }
        let coverLayer = CALayer()
        coverLayer.backgroundColor = NSColor.black.cgColor

        CATransaction.begin()
        // Implicit animations would animate the cover's own installation —
        // installing it must be instantaneous, the reveal is the animation.
        CATransaction.setDisableActions(true)
        hostingLayer.mask = coverLayer

        // The temporary surface (「空面板皮」): the content build is deferred
        // one run-loop tick so the reveal's transaction commits first, which
        // means the mask is growing over a layer whose SwiftUI content has
        // NOT drawn yet — without a surface the growing sheet would be a
        // growing TRANSPARENT hole onto the desktop. This paints the layer
        // with the sheet's own surface color and bottom corners so what grows
        // out of the notch reads as the sheet from the first frame; the real
        // content draws over it moments later. Top corners stay square
        // (the sheet's are 36 — a sliver the content corrects when it draws).
        hostingLayer.backgroundColor = NSColor(NotchExpandedSheetStyle.surfaceColor).cgColor
        hostingLayer.cornerRadius = NotchExpandedSheetStyle.sheetBottomCornerRadius
        // 「Bottom」 in the layer's own coordinate space depends on the view's
        // flippedness — the same dynamic read the mask styles use for topEdgeY.
        hostingLayer.maskedCorners = presence.contentHostingView.isFlipped
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        CATransaction.commit()
    }

    private func startReveal(
        on presence: ScreenPresence,
        style: WindowExpansionStyle,
        expandedFrame: CGRect
    ) {
        switch style {
        case .notchBloom:
            startNotchBloomReveal(on: presence, expandedFrame: expandedFrame)
        case .edgeScale:
            startScaleReveal(on: presence, expandedFrame: expandedFrame)
        case .curtain:
            startCurtainReveal(on: presence, expandedFrame: expandedFrame)
        }
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

    /// 中心缩放（2026-09-23 重设计）：the visible region grows out of the
    /// NOTCH's own point — the mask starts as a zero-size rect at the content's
    /// top-centre (the notch) and expands to the full frame, so the top-left
    /// corner moves left, the top-right corner moves right and the bottom edge
    /// moves down, all three at the same instant under the same timing
    /// function. The user's spec, verbatim: 「从刘海的位置向下、向左、向右同时展开」.
    ///
    /// This deliberately does NOT use a layer transform to place the anchor
    /// (that was the deleted `edgeAnchoredScaleTransform` top-edge variant):
    /// a transform's anchor depends on concat order and on which way the
    /// superlayer's y axis runs, and both failures are silent — which is why
    /// the old 中心缩放 kept coming out identical to 边缘缩放 no matter how the
    /// math was rearranged. A mask's geometry is written directly in the
    /// expanded frame, so there is no convention left to get wrong. The
    /// vertical start point reuses `startCurtainReveal`'s proven
    /// flippedness read; the horizontal start point is the frame's centre,
    /// which no flippedness can move.
    private func startNotchBloomReveal(on presence: ScreenPresence, expandedFrame: CGRect) {
        guard let hostingLayer = presence.contentHostingView.layer,
              let maskLayer = hostingLayer.mask else { return }
        let contentWidth = expandedFrame.width
        let contentHeight = expandedFrame.height

        // Same vertical convention as the curtain: the content's top edge is
        // y = 0 in a flipped view and y = height in an unflipped one.
        let topEdgeY: CGFloat = presence.contentHostingView.isFlipped ? 0 : contentHeight

        // Model values are the END state, like every reveal here: a dropped
        // animation leaves a fully open sheet, never a half-covered panel.
        let fullBounds = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let centrePosition = CGPoint(x: contentWidth / 2, y: contentHeight / 2)
        let pointBounds = CGRect(x: 0, y: 0, width: 0, height: 0)
        let notchPosition = CGPoint(x: contentWidth / 2, y: topEdgeY)

        let boundsAnimation = CABasicAnimation(keyPath: "bounds")
        boundsAnimation.fromValue = NSValue(rect: pointBounds)
        boundsAnimation.toValue = NSValue(rect: fullBounds)

        let positionAnimation = CABasicAnimation(keyPath: "position")
        positionAnimation.fromValue = NSValue(point: notchPosition)
        positionAnimation.toValue = NSValue(point: centrePosition)

        // A soft emergence on top of the geometric growth: the sheet fades in
        // while the mask expands, so the leading edges do not pop. Model value
        // stays 1 (the end state), fromValue 0 — same pattern as the scale
        // styles' opacity ramp.
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0
        opacityAnimation.toValue = 1

        let revealGroup = CAAnimationGroup()
        revealGroup.animations = [boundsAnimation, positionAnimation]
        revealGroup.duration = NotchSupport.expansionRevealDuration(for: .notchBloom)
        let controlPoints = NotchSupport.curtainRevealTimingControlPoints
        revealGroup.timingFunction = CAMediaTimingFunction(
            controlPoints: controlPoints.0,
            controlPoints.1,
            controlPoints.2,
            controlPoints.3
        )
        opacityAnimation.duration = revealGroup.duration
        opacityAnimation.timingFunction = revealGroup.timingFunction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.bounds = fullBounds
        maskLayer.position = centrePosition
        maskLayer.add(revealGroup, forKey: Self.notchBloomAnimationKey)
        hostingLayer.opacity = 1
        hostingLayer.add(opacityAnimation, forKey: Self.notchBloomAnimationKey)
        CATransaction.commit()
    }

    /// 边缘缩放's reveal: the whole content layer scales up from 8% about its
    /// BOTTOM edge, so the sheet grows upward off the bottom of where it will
    /// end up.
    ///
    /// (This transform machinery used to serve 中心缩放 too, via an
    /// `anchoredAtTopEdge` flag pinning the top edge instead. That variant is
    /// deleted: a transform's anchor depends on concat order and on which way
    /// the superlayer's y axis runs, both failures silent, and the top-edge pin
    /// never visibly differed from this bottom-edge one — the user saw 「中心缩放
    /// 跟边缘缩放效果是一样的」 twice. 中心缩放 is now `startNotchBloomReveal`, a
    /// mask expansion with no convention left to get wrong.)
    ///
    /// One Core Animation on the content layer: the render server plays it, the
    /// main thread does no per-frame work, and the window's frame never changes.
    ///
    /// The cover installed by `installRevealCover` comes off **in the same
    /// transaction** the scale goes on: mask off + model transform identity +
    /// the animation added, all with actions disabled, so the very first frame
    /// presented is the animation's `fromValue` (8%) and there is no
    /// intermediate paint at full size.
    private func startScaleReveal(
        on presence: ScreenPresence,
        expandedFrame: CGRect
    ) {
        guard let hostingLayer = presence.contentHostingView.layer else { return }

        let contentSize = expandedFrame.size
        let identityTransform = CATransform3DIdentity
        let startTransform = Self.edgeAnchoredScaleTransform(
            scale: NotchSupport.centerPopInitialScale,
            contentSize: contentSize,
            // The transform acts in the SUPERLAYER's coordinate space, so which
            // way is "up" is its view's flippedness — not the hosting view's own.
            superlayerIsFlipped: presence.contentHostingView.superview?.isFlipped ?? false
        )

        // Model value is the END state, exactly like the curtain's: if the
        // animation were ever dropped, the worst case is a fully open sheet,
        // never a permanently shrunken one.
        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = NSValue(caTransform3D: startTransform)
        scaleAnimation.toValue = NSValue(caTransform3D: identityTransform)

        // The reference's keyframe carries an opacity ramp alongside the scale
        // (`@keyframes winScale{ 0%{ transform:scale(.08); opacity:0 } … }`),
        // and it is load-bearing rather than decorative: at 8% the sheet is a
        // ~65 pt nub, so without the ramp that nub pops into existence at the
        // notch before it grows. Fading it in is what makes the sheet read as
        // emerging from the notch instead of appearing at it.
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0
        opacityAnimation.toValue = 1

        // Both properties ride ONE group under one timing function, so the
        // ramp and the scale share a clock and the compositor plays the pair
        // as a single animation.
        let revealGroup = CAAnimationGroup()
        revealGroup.animations = [scaleAnimation, opacityAnimation]
        revealGroup.duration = NotchSupport.centerPopRevealDuration
        let controlPoints = NotchSupport.centerPopTimingControlPoints
        revealGroup.timingFunction = CAMediaTimingFunction(
            controlPoints: controlPoints.0,
            controlPoints.1,
            controlPoints.2,
            controlPoints.3
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingLayer.mask = nil
        hostingLayer.transform = identityTransform
        hostingLayer.opacity = 1
        hostingLayer.add(revealGroup, forKey: Self.scaleRevealAnimationKey)
        CATransaction.commit()
    }

    /// A scale about the layer's BOTTOM horizontal edge, expressed as the one
    /// `CATransform3D` a layer can be handed — 边缘缩放's start transform.
    ///
    /// A layer's `transform` acts about its `anchorPoint`: a point `p` is placed
    /// at `position + T(p − c)` with `c` = the anchor point. Wanting the point
    /// `a` to stay put is `T(a − c) = a − c`, and with `T(v) = s·v + d` that
    /// solves to **`d = (1 − s)·(a − c)`** — a scale plus a compensation
    /// translation. Here `c` is the layer's centre (AppKit gives a view's
    /// backing layer an `anchorPoint` of `(0.5, 0.5)`, and the content hosting
    /// view fills its superview, so its centre is the superview's centre) and
    /// `a` is the pinned edge's midpoint. Both are on the vertical centre line,
    /// so `d.x` is always 0 and only the vertical term moves.
    ///
    /// **The one thing that has to be right is the sign of `d.y`, and getting
    /// it wrong is silent** — the sheet still opens, it just grows from the
    /// wrong edge. `(a − c)` is a vector in the SUPERLAYER's coordinate space,
    /// because that is the space the transform acts in; so which way is "up"
    /// is the *superview's* flippedness, NOT the hosting view's. The hosting
    /// view is an `NSHostingView` and reports `isFlipped == true`, while the
    /// panel's content view is an ordinary unflipped `NSView` whose y axis
    /// points up — reading the hosting view's own flip here inverts the sign
    /// and silently pins the wrong edge.
    /// (`startCurtainReveal` / `startNotchBloomReveal` may read the hosting
    /// view's flip directly only because there the layer being moved is the
    /// mask, whose superlayer *is* the hosting layer.)
    ///
    /// The compensation is written from the anchor point rather than by moving
    /// `anchorPoint` itself: changing `anchorPoint` moves the layer (position
    /// is expressed through it), so the layer would have to be re-placed to
    /// compensate, and the whole thing would be two coupled corrections instead
    /// of one.
    ///
    /// **The concat order is load-bearing, and getting it backwards is silent**
    /// (measured 2026-09-23: `Concat(translate, scale)` mapped the origin to
    /// (0, 200) for translate(0,100)∘scale(2,2) — the translation got scaled
    /// along with everything else). `CATransform3D` is a ROW-VECTOR convention:
    /// translation lives in `m41/m42/m43`, points map as `p' = p·M`, and
    /// `CATransform3DConcat(a, b)` applies **a first, then b**. So the scale
    /// must be the FIRST argument and the translation the second —
    /// `p' = s·p + d`, which is the shape the `d = (1 − s)·(a − c)` derivation
    /// assumed. Written the other way round, the effective offset is `s·d` and
    /// the pinned point drifts to `s·(2 − s)·a`: at the 8% start scale the
    /// pinned edge lands near the layer's CENTRE. That drift was the old
    /// 中心缩放's fatal flaw (both styles rendered as the same
    /// grow-outward-from-the-middle animation); the style no longer uses this
    /// machinery at all — see `startNotchBloomReveal` — and 边缘缩放 keeps it
    /// because its bottom-edge pin is the behaviour the user accepted.
    ///
    /// One property worth knowing, because it is what makes this exact rather
    /// than approximately right: `d` is proportional to `(1 − s)`, and Core
    /// Animation interpolates a transform by decomposing it into scale and
    /// translation and interpolating those linearly against the SAME eased
    /// progress. So at every instant `d(t) = (1 − s(t))·(a − c)` holds, and the
    /// pinned edge is fixed for the entire animation, not merely at the two
    /// endpoints.
    private static func edgeAnchoredScaleTransform(
        scale: CGFloat,
        contentSize: CGSize,
        superlayerIsFlipped: Bool
    ) -> CATransform3D {
        // The offset from the layer's centre to its top edge, in the
        // superlayer's coordinates: upward is +y in an unflipped superlayer and
        // −y in a flipped one. The PINNED edge is the BOTTOM one — its offset is
        // the negation, which is what makes the sheet grow upward.
        let topEdgeOffsetY = superlayerIsFlipped
            ? -(contentSize.height / 2)
            : (contentSize.height / 2)
        let bottomEdgeOffsetY = -topEdgeOffsetY
        let compensationY = (1 - scale) * bottomEdgeOffsetY
        // Scale FIRST (first argument acts first), translate SECOND — see the
        // concat-order note above.
        return CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(0, compensationY, 0)
        )
    }

    /// Takes the reveal off: the mask (all three styles cover with one), the
    /// layer transform and the layer opacity (the two 缩放 styles' own zero
    /// state). Idempotent, and called from every path that claims the panel is
    /// (or is becoming) fully open or fully closed — a mask left behind would
    /// clip the sheet forever, and a transform left behind would draw the whole
    /// sheet at 8% in a corner of its own window. All three also cost a
    /// compositing pass on every frame the panel draws.
    ///
    /// The animation is removed by key as well, not merely overridden by the
    /// model value: an explicit animation still attached to the layer keeps
    /// driving the presentation layer until it finishes on its own, so setting
    /// `transform` back to identity while one is in flight would visibly do
    /// nothing.
    private func removeReveal(on presence: ScreenPresence) {
        guard let hostingLayer = presence.contentHostingView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 中心缩放 rides TWO layers: the mask anim on the mask layer and the
        // opacity anim on the hosting layer. The mask's anim comes off BEFORE
        // the mask itself is dropped — removing a layer discards its
        // animations, but read order matters for clarity and for the nil'd mask.
        hostingLayer.mask?.removeAnimation(forKey: Self.notchBloomAnimationKey)
        if hostingLayer.mask != nil {
            hostingLayer.mask = nil
        }
        if !CATransform3DEqualToTransform(hostingLayer.transform, CATransform3DIdentity) || hostingLayer.opacity < 1 {
            hostingLayer.removeAnimation(forKey: Self.scaleRevealAnimationKey)
            hostingLayer.transform = CATransform3DIdentity
            hostingLayer.opacity = 1
        }
        hostingLayer.removeAnimation(forKey: Self.notchBloomAnimationKey)
        // The temporary surface goes with the reveal: the real content has
        // drawn (or the watchdog converged) by the time any removeReveal path
        // runs, and a leftover dark fill would halo the resting pill's
        // transparent flanks.
        hostingLayer.backgroundColor = NSColor.clear.cgColor
        hostingLayer.cornerRadius = 0
        hostingLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                      .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        CATransaction.commit()
    }

    /// Forces the panel into the fully-open state with no animation — the
    /// counterpart of `convergeOnRestingState`, covering both halves of what
    /// "open" means: the frame (which `beginExpansion` already put in place in
    /// one step, so this is normally a no-op) and the reveal (the cover, and
    /// the scale if the pop was the style). Idempotent at every normal
    /// completion.
    private func convergeOnExpandedState(_ presence: ScreenPresence, targetFrame: CGRect) {
        guard panelModel.isExpanded else { return }
        removeReveal(on: presence)
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
            removeReveal(on: collapsingPresence)
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
                removeReveal(on: collapsingPresence)
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
        removeReveal(on: presence)

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

    /// Keeps the last non-idle phase on screen instead of collapsing the moment
    /// the voice state goes quiet.
    ///
    /// The phase is a straight mapping from `CompanionVoiceState`, and the wings
    /// are drawn only while the phase is not `.idle` — so a single idle instant
    /// between `thinking` and `speaking` retracts them and slides them straight
    /// back out, which is what the user reported (2026-09-24: 「在 thinking
    /// 后面，动画自动缩回去了…缩回去之后 speaking 的时候又展开，这个时候其实没有
    /// 意义…不要一会儿开一会儿关」). The gap is not the end of the turn, and the
    /// panel should not read as flickering during it.
    private var activityPhaseHoldTask: Task<Void, Never>?
    private static let activityPhaseHoldSeconds: TimeInterval = 2.5

    /// Set by an explicit stop, consumed by the next `refreshActivityPhase`:
    /// the idle that follows is an ENDING, so the phase drops at once instead of
    /// being held. See the comment inside `refreshActivityPhase`.
    private var activityPhaseHoldIsSuppressed = false

    /// The way in for the stop path — `CompanionManager.interruptActiveResponse`
    /// is the one funnel every stop goes through, and this is the panel being
    /// told rather than having to infer it.
    func forceActivityPhaseIdle() {
        activityPhaseHoldIsSuppressed = true
        activityPhaseHoldTask?.cancel()
        activityPhaseHoldTask = nil
        refreshActivityPhase()
    }

    private func refreshActivityPhase() {
        let derivedPhase = panelModel.externalSessionOverride
            ?? (isDictationFinalizing
                ? .transcribing
                : NotchActivityPhase(from: latestVoiceState))

        guard derivedPhase == .idle else {
            activityPhaseHoldIsSuppressed = false
            activityPhaseHoldTask?.cancel()
            activityPhaseHoldTask = nil
            panelModel.activityPhase = derivedPhase
            return
        }

        // An explicit stop is an ENDING and takes effect at once; any other idle
        // instant is a GAP between two phases of the same turn and is held.
        //
        // Those two cannot be told apart from the signals available here — the
        // listening window arms on the first TTS audio, i.e. AFTER the gap it
        // would have to cover, and the brief idle of the gap looks exactly like
        // the idle of a stop. Two attempts to infer it (an unconditional hold,
        // then a hold keyed on the window) each broke the other case, which is
        // what the user saw. So the stop is now stated rather than inferred:
        // `forceActivityPhaseIdle()` is called from `interruptActiveResponse`,
        // the one funnel every stop goes through.
        if activityPhaseHoldIsSuppressed {
            activityPhaseHoldIsSuppressed = false
            activityPhaseHoldTask?.cancel()
            activityPhaseHoldTask = nil
            panelModel.activityPhase = .idle
            return
        }

        guard panelModel.activityPhase != .idle else { return }
        activityPhaseHoldTask?.cancel()
        activityPhaseHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.activityPhaseHoldSeconds))
            guard let self, !Task.isCancelled else { return }
            self.activityPhaseHoldTask = nil
            self.panelModel.activityPhase = self.panelModel.externalSessionOverride
                ?? (self.isDictationFinalizing
                    ? .transcribing
                    : NotchActivityPhase(from: self.latestVoiceState))
        }
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
