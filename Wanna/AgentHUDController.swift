//
//  AgentHUDController.swift
//  Wanna
//
//  The desktop HUD for running agents: a small stack of round chips in each
//  screen's top-right corner, one chip per agent whose status is not idle,
//  hover-expanding into a preview strip.
//
//  One NSPanel per screen (grouped by `displayFrame` the way
//  `ScreenAnnotationManager` does it), cloned from
//  `CompanionResponseOverlay`'s panel parameters — borderless,
//  non-activating, `.statusBar` level, transparent, cross-Space — with one
//  deliberate difference: the HUD is INTERACTIVE (`ignoresMouseEvents =
//  false`), because the chips are buttons. The panel is only as big as the
//  chip stack, so the interactive surface never covers the user's screen.
//
//  The vision model never sees the HUD for free:
//  `CompanionScreenCaptureUtility` filters out every window owned by this
//  app's bundle identifier, and the HUD panels are owned by this app.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Controller

@MainActor
final class AgentHUDController {

    /// The agent the user tapped, delivered to `CompanionManager` — the sheet
    /// switches to the Agent page and expands. The HUD deliberately knows
    /// nothing about the notch subsystem.
    var onChipOpen: ((UUID) -> Void)?

    /// One panel per display, keyed by `CGDirectDisplayID` (the
    /// `ScreenAnnotationManager` grouping).
    private var panelsByDisplayID: [CGDirectDisplayID: NSPanel] = [:]

    /// The chip data every screen's stack view renders. Shared across panels
    /// (every screen shows the same stack), and updated IN PLACE on refresh —
    /// rebuilding the hosting view on every store mutation would drop the
    /// user's hover state mid-read, and a running agent mutates the store
    /// every few seconds.
    private let stackModel = AgentHUDStackModel()

    /// Chip close (×) dismissals for this app run only — in-memory, so a
    /// restart brings the chips back. Deliberately not persisted.
    private var dismissedAgentIDs = Set<UUID>()

    // Observers hold their own tokens for nothing — NotificationCenter keeps
    // block-based observers alive until removed, and these live for the whole
    // app run. Default `nil` values let init register them after self is fully
    // initialized (a closure capturing self cannot run in phase-1 init).
    private var changeObservers: (any NSObjectProtocol)? = nil
    private var settingsObservers: (any NSObjectProtocol)? = nil
    private var screenChangeObserver: (any NSObjectProtocol)? = nil
    private var terminateObserver: (any NSObjectProtocol)? = nil
    private var modelCancellable: AnyCancellable? = nil

    init() {
        // The handle's collapse toggle happens inside SwiftUI (it flips
        // `stackModel.isAccordionCollapsed`) — this is how the controller
        // learns to re-frame the panels (a collapsed stack is only the
        // handle's height, and a taller-than-needed transparent panel would
        // block clicks on whatever sits beneath it).
        modelCancellable = stackModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizePanelsForCurrentStack() }
        // Every agent mutation (status change, transcript append, preview
        // refresh) posts this — it is the refresh trigger.
        changeObservers = NotificationCenter.default.addObserver(
            forName: .wannaAgentSessionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // 「Agent 悬浮图标」 lives in AppSettings.json — its save posts this.
        settingsObservers = NotificationCenter.default.addObserver(
            forName: .wannaAppSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Displays plug in and out; rebuild the per-screen panels for the new
        // screen set.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanelsForCurrentScreens() }
        }
        // The panels never tear down during the run (same permanence as the
        // overlay windows) — only app exit orders them out.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderOutAllPanels() }
        }
        // First draw. Refresh is otherwise only driven by store-mutation
        // notifications, and a relaunch with NO turn activity yet posts none:
        // agents left failed/interrupted by the previous run stay non-idle in
        // the roster, the demotion pass finds nothing .running to demote (so
        // posts nothing), and the HUD sat invisible until the next turn's
        // first mutation (measured 2026-09-23). Reading the persisted roster
        // here is what puts those chips up at launch.
        refresh()
    }

    // MARK: Refresh

    /// Recomputes which agents deserve a chip and mirrors that into every
    /// screen's stack view. Cheap — the store snapshot is in memory.
    func refresh() {
        let visibleAgents = AgentHUDController.visibleAgents(dismissedAgentIDs: dismissedAgentIDs)

        if visibleAgents.isEmpty {
            orderOutAllPanels()
            return
        }

        stackModel.agents = visibleAgents

        let screens = NSScreen.screens

        // A screen that disappeared (or the first refresh) needs panels built.
        let missingScreens = screens.filter { screen in
            screen.displayID != 0 && panelsByDisplayID[screen.displayID] == nil
        }
        for screen in missingScreens {
            buildPanel(for: screen)
        }

        for (displayID, panel) in panelsByDisplayID {
            let isScreenConnected = screens.contains { $0.displayID == displayID }
            if !isScreenConnected {
                panel.orderOut(nil)
                continue
            }
            // NOTE: `panel.contentView == nil` is never true — AppKit
            // materialises a default empty view the first time contentView is
            // read, so that check silently skipped the install forever (the
            // panel sat on screen, correctly sized by `sizePanel`, rendering
            // nothing at all — every captured pixel at alpha 0, measured
            // 2026-09-23). Check for OUR view instead.
            if !(panel.contentView is NSHostingView<AgentHUDStackView>) {
                installStackView(in: panel, displayID: displayID)
            }
            sizePanel(panel, displayID: displayID, agentCount: visibleAgents.count, isCollapsed: stackModel.isAccordionCollapsed)
            panel.orderFrontRegardless()
        }
    }

    /// The chips shown: agents with something to report (not idle), not
    /// dismissed this run, when the setting is on. Nothing shows at launch
    /// until a turn actually does something, because an agent only leaves
    /// `.idle` (or gains a preview/cost) through turn activity.
    private static func visibleAgents(dismissedAgentIDs: Set<UUID>) -> [AgentSession] {
        guard AppSettingsStore.snapshot().allowsAgentDesktopHUD else { return [] }
        return AgentSessionStore.allAgents()
            .filter { agent in
                agent.status != .idle && !dismissedAgentIDs.contains(agent.id)
            }
    }

    func dismiss(agentID: UUID) {
        dismissedAgentIDs.insert(agentID)
        refresh()
    }

    // MARK: Panels

    private func buildPanel(for screen: NSScreen) {
        let displayID = screen.displayID
        guard displayID != 0 else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = false // the one difference from the response overlay — the chips are buttons
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // Key-ness: the panel must never become key or it would steal the
        // user's keyboard — clicking a chip is a mouse-only interaction. The
        // `.nonactivatingPanel` style mask plus a plain content view (no text
        // fields, nothing asking for first responder) is what prevents it.
        panelsByDisplayID[displayID] = panel
    }

    /// Places the panel for its display and installs the stack view ONCE —
    /// later refreshes only update `stackModel.agents`, so hover and
    /// collapse state survive every store mutation. The stack hangs from the
    /// screen's top-right corner (menu bar below it, a small inset past the
    /// notch's flank); the row heights are fixed (see `chipRowHeight`), so
    /// the frame computed here never has to move while chips show.
    private func installStackView(in panel: NSPanel, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }

        let stackView = AgentHUDStackView(
            stackModel: stackModel,
            onOpen: { [weak self] agentID in self?.onChipOpen?(agentID) },
            onDismiss: { [weak self] agentID in self?.dismiss(agentID: agentID) }
        )

        let hostingView = NSHostingView(rootView: stackView)
        // The panel is created with `contentRect: .zero`, so the content view
        // starts zero-sized — and it does NOT follow the later `setFrame`
        // without help. Measured 2026-09-23: without these two lines the
        // SwiftUI content rendered nothing at all (the window's capture came
        // back with every pixel at alpha 0, not even the accordion handle),
        // while the panel itself sat on screen at the correct 264×216.
        // `autoresizingMask` keeps the view tracking every later `sizePanel`
        // re-frame; the explicit frame covers this first placement. Same fix
        // `CompanionResponseOverlay` applies after its own `setFrame`.
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        let stackSize = hostingView.fittingSize
        let stackWidth = max(stackSize.width, AgentHUDStackView.minimumStackWidth)
        let marginFromRightEdge: CGFloat = 12
        // Hang the stack BELOW the menu bar band, not 4 pt below the screen's
        // top edge — `visibleFrame` already has the menu bar subtracted, and
        // at 4 pt the accordion handle sat inside the menu bar band, hidden
        // behind it (measured 2026-09-23).
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY + 4

        let panelFrame = NSRect(
            x: screen.frame.maxX - stackWidth - marginFromRightEdge,
            y: screen.frame.maxY - stackSize.height - topInset,
            width: stackWidth,
            height: stackSize.height
        )
        panel.setFrame(panelFrame, display: true)
        // Keep the content view in lockstep with this first real frame (the
        // autoresizing mask installed above covers later re-frames).
        hostingView.frame = NSRect(origin: .zero, size: panelFrame.size)
    }

    /// Re-frames the panel for the CURRENT agent count — chips come and go,
    /// and the frame set at install time only fitted that refresh's count.
    /// Top edge stays fixed; the stack grows downward (same rule as the notch
    /// sheet hanging from the notch).
    private func sizePanel(_ panel: NSPanel, displayID: CGDirectDisplayID, agentCount: Int, isCollapsed: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }

        let stackHeight = AgentHUDStackView.stackHeight(agentCount: agentCount, isCollapsed: isCollapsed)
        let stackWidth = AgentHUDStackView.minimumStackWidth
        let marginFromRightEdge: CGFloat = 12
        // Same rule as `installStackView` — below the menu bar band.
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY + 4

        panel.setFrame(
            NSRect(
                x: screen.frame.maxX - stackWidth - marginFromRightEdge,
                y: screen.frame.maxY - stackHeight - topInset,
                width: stackWidth,
                height: stackHeight
            ),
            display: true
        )
    }

    /// Display change (or first build): drop stale panels and rebuild for the
    /// current screen set, then refresh.
    private func rebuildPanelsForCurrentScreens() {
        panelsByDisplayID.removeAll()
        refresh()
    }

    /// Re-frames every connected panel for the stack's current shape — the
    /// collapse toggle's path (the refresh path re-frames on its own).
    private func resizePanelsForCurrentStack() {
        let isCollapsed = stackModel.isAccordionCollapsed
        for (displayID, panel) in panelsByDisplayID {
            guard NSScreen.screens.contains(where: { $0.displayID == displayID }) else { continue }
            sizePanel(
                panel,
                displayID: displayID,
                agentCount: stackModel.agents.count,
                isCollapsed: isCollapsed
            )
        }
    }

    private func orderOutAllPanels() {
        for panel in panelsByDisplayID.values {
            panel.orderOut(nil)
        }
    }
}

// MARK: - Chip stack view

/// The chip data the stack renders, shared by every screen's panel. The
/// controller updates `agents` in place on refresh and flips
/// `isAccordionCollapsed` through the view's handle button, so panels and
/// their hover state are built once and never rebuilt.
@MainActor
final class AgentHUDStackModel: ObservableObject {
    @Published var agents: [AgentSession] = []
    /// 手柄: collapse the whole stack to just the handle. Shared across
    /// screens on purpose — every screen shows the same stack, so one
    /// collapse state keeps them consistent (and lets the controller shrink
    /// each panel's frame to match).
    @Published var isAccordionCollapsed = false
}

/// The SwiftUI content of every HUD panel: an accordion handle on top, then
/// one chip per visible agent, trailing-aligned so the stack hugs the screen
/// corner.
struct AgentHUDStackView: View {

    /// Narrower than this the expanded strip would truncate its preview
    /// pointlessly — this is also the panel width even when only collapsed
    /// tiles show, so the strip never has to resize the panel horizontally.
    static let minimumStackWidth: CGFloat = 264

    /// Panel height for a stack of `agentCount` chips (or the collapsed
    /// handle-only stack). Must stay in sync with the layout below: 6 pt
    /// outer padding top and bottom, 8 pt between rows, handle 20 pt, chip
    /// rows 56 pt each.
    static func stackHeight(agentCount: Int, isCollapsed: Bool = false) -> CGFloat {
        let handleHeight: CGFloat = 20
        guard agentCount > 0, !isCollapsed else { return handleHeight + 12 }
        // The VStack also puts its own 8 pt spacing between the handle and the
        // first chip row — the formula used to omit it, so `sizePanel` framed
        // the panel 8 pt shorter than the content `fittingSize` (measured
        // 2026-09-23: fitting 224 vs formula 216 for three agents).
        return handleHeight + 12 + 8 + CGFloat(agentCount) * 56 + CGFloat(max(agentCount - 1, 0)) * 8
    }

    @ObservedObject var stackModel: AgentHUDStackModel
    let onOpen: (UUID) -> Void
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            accordionHandlePill

            if !stackModel.isAccordionCollapsed {
                ForEach(stackModel.agents) { agent in
                    AgentHUDChipView(
                        agent: agent,
                        onOpen: { onOpen(agent.id) },
                        onDismiss: { onDismiss(agent.id) }
                    )
                    .transition(.opacity)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The 顶部小胶囊: one click collapses or reopens the whole stack.
    private var accordionHandlePill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                stackModel.isAccordionCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: stackModel.isAccordionCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                if !stackModel.isAccordionCollapsed {
                    Text("\(stackModel.agents.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundColor(.white.opacity(0.55))
            .padding(.horizontal, 8)
            .frame(width: 30, height: 20)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(stackModel.isAccordionCollapsed ? "展开 Agent 图标" : "收起 Agent 图标")
    }
}

// MARK: - One chip

/// One agent's chip, two states. Collapsed: a 34×34 gradient circle tile with
/// the name's initial and an 8×8 status dot. Hovered: a strip with the name,
/// status word, last preview (2 lines), relative time, and a close ×.
struct AgentHUDChipView: View {

    let agent: AgentSession
    let onOpen: () -> Void
    let onDismiss: () -> Void

    /// Hover-expansion state. The strip is taller than the 34×34 tile, so
    /// every chip row is laid out at `chipRowHeight` up front — the height
    /// either state needs — and hover only swaps content, never changes the
    /// layout. That keeps the panel's frame fixed at install time (the
    /// controller sizes it from `fittingSize` once per refresh) and makes the
    /// hover animation a pure content cross-fade instead of a live re-frame.
    @State private var isHoverExpanded = false

    /// The height of an expanded strip (two-line preview + header line +
    /// padding). Every row is this tall; the 34×34 tile centres in it.
    private static let chipRowHeight: CGFloat = 56

    /// Collapse-back debounce: mouse jitter across the chip's edge must not
    /// flicker the strip. Mirror of the notch dwell hysteresis idea.
    @State private var collapseDelayTask: Task<Void, Never>?

    private static let collapsedTileSize: CGFloat = 34
    private static let statusDotSize: CGFloat = 8

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if isHoverExpanded {
                expandedContentStrip
                    .transition(.opacity)
            }

            collapsedTile
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: Self.chipRowHeight)
        .animation(.easeInOut(duration: 0.15), value: isHoverExpanded)
        .onHover { isHovering in
            if isHovering {
                collapseDelayTask?.cancel()
                collapseDelayTask = nil
                isHoverExpanded = true
            } else {
                scheduleCollapse()
            }
        }
    }

    /// 34×34 gradient circle tile — first letter of the agent name over a
    /// per-agent gradient (id-hashed palette, `MascotRoster`'s rule), with the
    /// status dot at the bottom-right.
    private var collapsedTile: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: AgentHUDPalette.gradientColors(for: agent),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(agent.name.prefix(1).uppercased())
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    // Deep navy like `MascotAvatarDisc`'s initial — the pastel
                    // tile is too light for white text to read (measured
                    // 2026-09-23: the letter was nearly invisible).
                    .foregroundColor(Color(red: 0.10, green: 0.24, blue: 0.60))
                Circle()
                    .fill(AgentHUDPalette.statusColor(for: agent.status))
                    .frame(width: Self.statusDotSize, height: Self.statusDotSize)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
            .frame(width: Self.collapsedTileSize, height: Self.collapsedTileSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("打开「\(agent.name)」的会话")
    }

    /// The hover strip: name + status word, the last thing that happened (2
    /// lines), how long ago, and a close ×. Nothing here is a second input
    /// box — follow-ups go through the notch sheet's composer (deliberate).
    private var expandedContentStrip: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(agent.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Text(agent.status.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(AgentHUDPalette.statusColor(for: agent.status))
                    Spacer(minLength: 0)
                    Text(relativeTimeText)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                Text(agent.lastPreview.isEmpty ? "…" : agent.lastPreview)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("从桌面隐藏（不影响 Agent 运行）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: AgentHUDStackView.minimumStackWidth - Self.collapsedTileSize - 20, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var relativeTimeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: agent.updatedAt, relativeTo: Date())
    }

    private func scheduleCollapse() {
        collapseDelayTask?.cancel()
        collapseDelayTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            isHoverExpanded = false
        }
    }
}

// MARK: - Palette

/// Chip colours. The gradient comes from the same id-hash rule
/// `MascotRoster` uses (top two bits of the agent id pick from the shared
/// pastel palette), so the desktop tile and the sidebar avatar for one agent
/// always agree.
enum AgentHUDPalette {

    static func gradientColors(for agent: AgentSession) -> [Color] {
        let pastel = MascotRoster.identity(forSessionID: agent.id).pastelBackground
        let base = Color(pastel)
        // The tile must read against any wallpaper, so the pastel gets a
        // deeper partner of itself rather than being shown alone.
        return [base.opacity(0.95), base.opacity(0.55)]
    }

    /// Status dot — running green / completed blue / failed red / interrupted
    /// orange / idle grey (idle never gets a chip, the colour is for safety).
    static func statusColor(for status: AgentSessionStatus) -> Color {
        switch status {
        case .idle: return Color(white: 0.6)
        case .running: return Color(red: 0.30, green: 0.88, blue: 0.50)
        case .completed: return Color(red: 0.30, green: 0.60, blue: 1.00)
        case .failed: return Color(red: 1.00, green: 0.36, blue: 0.34)
        case .interrupted: return Color(red: 1.00, green: 0.66, blue: 0.25)
        }
    }
}

// MARK: - Helpers


// `NSScreen.displayID` already exists as a project extension
// (`WindowPositionManager.swift`) — non-optional, falling back to 0. The HUD
// uses it directly and treats 0 as "no stable id", same as that extension's
// callers do.
