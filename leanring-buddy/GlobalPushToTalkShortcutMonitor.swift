//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// The VoiceWeb mode shortcuts (三段式 / 全双工语音 / 全双工全模态), matched
    /// by the same tap BEFORE the talk shortcut — an event that fires one of
    /// these never also feeds the talk matcher. The tap receives every keyboard
    /// event already; generalizing to a second consumer costs no new machinery.
    /// `CompanionManager` refreshes this snapshot when the settings change
    /// (same read-fresh rule as `BuddyPushToTalkShortcut.currentShortcutBinding`).
    /// Mutated only on the main thread, which is where the tap callback runs.
    var externalShortcutBindings: [RecordedKeyboardShortcut] = []
    let externalShortcutTransitionsPublisher = PassthroughSubject<(index: Int, pressed: Bool), Never>()

    /// Per-index pressed state, the multi-binding analogue of
    /// `isShortcutCurrentlyPressed`. Written only from the tap callback.
    private var externalShortcutPressedStates: [Int: Bool] = [:]

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if matchExternalShortcuts(
            eventType: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue
        ) {
            return Unmanaged.passUnretained(event)
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Matches the external VoiceWeb bindings against one tap event. Returns
    /// whether any binding transitioned — the caller then stops, so an external
    /// hit can never also be read as a talk-shortcut press. The matching
    /// semantics are deliberately a per-index copy of
    /// `BuddyPushToTalkShortcut.shortcutTransition`: a binding with a key
    /// presses/releases on that key's down/up, a modifier-only binding on
    /// flagsChanged.
    private func matchExternalShortcuts(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64
    ) -> Bool {
        guard !externalShortcutBindings.isEmpty else { return false }
        guard eventType == .flagsChanged || eventType == .keyDown || eventType == .keyUp else {
            return false
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)

        var anyTransitioned = false
        for (index, binding) in externalShortcutBindings.enumerated() {
            let wasPressed = externalShortcutPressedStates[index] ?? false
            let requiredModifierFlags = binding.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            var pressedNow: Bool?

            if let boundKeyCode = binding.keyCode {
                if eventType == .keyDown
                    && keyCode == boundKeyCode
                    && modifierFlags.isSuperset(of: requiredModifierFlags)
                    && !wasPressed {
                    pressedNow = true
                }
                if eventType == .keyUp
                    && keyCode == boundKeyCode
                    && wasPressed {
                    pressedNow = false
                }
            } else if eventType == .flagsChanged, !requiredModifierFlags.isEmpty {
                let isHeldNow = modifierFlags.isSuperset(of: requiredModifierFlags)
                if isHeldNow && !wasPressed {
                    pressedNow = true
                }
                if !isHeldNow && wasPressed {
                    pressedNow = false
                }
            }

            if let pressedNow {
                externalShortcutPressedStates[index] = pressedNow
                externalShortcutTransitionsPublisher.send((index: index, pressed: pressedNow))
                anyTransitioned = true
            }
        }
        return anyTransitioned
    }
}
