//
//  PushToTalkShortcutRecorder.swift
//  leanring-buddy
//
//  The 快捷键 page's shortcut recorder: a button that shows the shortcut
//  currently in effect and, when clicked, captures the next key combination
//  the user presses as the new push-to-talk shortcut — the same interaction
//  macOS game launchers and Raycast use.
//
//  Two things live here on purpose. The display half (key-code → readable
//  name) is pure data, so `BuddyPushToTalkShortcut.pushToTalkDisplayText` can
//  use it for any shortcut, preset or recorded. The capture half installs
//  NSEvent monitors only while armed, and posts
//  `.clickyShortcutRecorderStateChanged` so `CompanionManager` can suspend the
//  live global event tap meanwhile — without that, the keys pressed to record
//  would also start a real recording.
//

import AppKit
import SwiftUI

/// Posted when the recorder arms (object: `true`) or disarms (object:
/// `false`). `CompanionManager` stops the global push-to-talk event tap while
/// the recorder is armed and restarts it afterwards, so recording a shortcut
/// never triggers the shortcut.
extension Notification.Name {
    static let clickyShortcutRecorderStateChanged = Notification.Name("clickyShortcutRecorderStateChanged")
}

// MARK: - Display

extension RecordedKeyboardShortcut {

    /// The modifier keys in the order macOS writes them in shortcut displays,
    /// followed by the ordinary key. A modifier-only combo is just modifiers.
    var capsuleLabels: [String] {
        var labels: [String] = []
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { labels.append("Ctrl") }
        if flags.contains(.option) { labels.append("Option") }
        if flags.contains(.shift) { labels.append("Shift") }
        if flags.contains(.command) { labels.append("Cmd") }
        if flags.contains(.function) { labels.append("Fn") }
        if let keyCode {
            labels.append(Self.keyDisplayName(for: keyCode))
        }
        return labels
    }

    var displayText: String {
        capsuleLabels.joined(separator: " + ")
    }

    /// The modifiers a shortcut can meaningfully use. Everything else
    /// (capsLock, the Fen keys' own state…) is noise a stray keypress could
    /// otherwise smuggle into a recorded binding.
    static let recordableModifierFlags: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command, .function
    ]

    /// Readable name for the non-modifier half of a shortcut. A table rather
    /// than Carbon's `UCKeyboardTranslate` because the recorder only needs the
    /// ~40 physical keys anyone binds a shortcut to; anything unlisted falls
    /// back to its key code so the display is never empty.
    static func keyDisplayName(for keyCode: UInt16) -> String {
        if let letter = letterKeyName(for: keyCode) { return letter }

        let namedKeys: [UInt16: String] = [
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return namedKeys[keyCode] ?? "Key \(keyCode)"
    }

    /// The ANSI letter keys, whose key codes follow the alphabet's QWERTY
    /// ordering rather than ASCII: A=0 … in the classic hardware layout.
    private static func letterKeyName(for keyCode: UInt16) -> String? {
        let letterKeyCodes: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 43: ",", 45: "N",
            46: "M", 47: "."
        ]
        return letterKeyCodes[keyCode]
    }
}

// MARK: - Recorder button

/// Shows the effective shortcut as key capsules; clicking arms capture mode,
/// and the next key combination becomes the new shortcut. Esc alone cancels,
/// clicking anywhere cancels. A combination with no modifier key is ignored —
/// a bare letter would steal that key from every application.
struct ShortcutRecorderButton: View {
    /// The preset-derived shortcut shown and used when the user has not
    /// recorded one of their own.
    ///
    /// **可以是 nil** —— 「打开窗口」那四格就没有预设：没录就是没快捷键（预设按键会在
    /// 别人的应用里抢键）。nil 时按钮显示「点这里录制」而不是一串键帽。
    /// 传非可选值的老调用点不受影响（非可选赋给可选是合法的）。
    let fallbackBinding: RecordedKeyboardShortcut?

    @Binding var recordedShortcut: RecordedKeyboardShortcut?

    @State private var isRecording = false
    /// Whether a non-modifier key has been captured since arming. Modifier-only
    /// combos are recorded when the last modifier is released, and this flag is
    /// what stops that release from overwriting a combo already captured with
    /// a keyDown.
    @State private var didCaptureKeyDuringThisRecording = false
    /// Modifiers held as of the last flagsChanged, so releasing them all
    /// (with no ordinary key struck) can record a modifier-only combo.
    @State private var lastHeldModifiers = NSEvent.ModifierFlags()
    @State private var localEventMonitor: Any?
    @State private var globalEventMonitor: Any?

    private var effectiveShortcut: RecordedKeyboardShortcut? {
        recordedShortcut ?? fallbackBinding
    }

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 5) {
                if isRecording {
                    Image(systemName: "record.circle")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.accentText)
                    Text("请按下新的快捷键")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                } else if let effectiveShortcut {
                    ForEach(Array(effectiveShortcut.capsuleLabels.enumerated()), id: \.offset) { index, label in
                        if index > 0 {
                            Text("+")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                } else {
                    Text("点这里录制")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isRecording ? DS.Colors.accentSubtle : DS.Colors.surface3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isRecording ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: isRecording ? 1.2 : 0.8)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("点击后按下新的快捷键组合，Esc 取消")
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        didCaptureKeyDuringThisRecording = false
        lastHeldModifiers = []

        // Suspend the live shortcut first: without this, the keys pressed to
        // record would also start a real push-to-talk recording underneath.
        NotificationCenter.default.post(name: .clickyShortcutRecorderStateChanged, object: true)

        let monitoredEvents: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]

        // Global monitors see events aimed at other apps (the usual place a
        // shortcut will be pressed from); local monitors see the settings
        // window itself. Neither can consume events — recording is listen-only,
        // which is fine: the live tap is suspended, and one stray keystroke
        // reaching another app while recording is the same cost every such
        // recorder has.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: monitoredEvents) { event in
            handleRecordingEvent(event)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: monitoredEvents) { event in
            handleRecordingEvent(event)
            return event
        }
    }

    private func stopRecording() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        isRecording = false
        NotificationCenter.default.post(name: .clickyShortcutRecorderStateChanged, object: false)
    }

    private func record(_ shortcut: RecordedKeyboardShortcut) {
        recordedShortcut = shortcut
        stopRecording()
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click anywhere — including on the button itself — cancels.
            stopRecording()

        case .flagsChanged:
            let heldModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(RecordedKeyboardShortcut.recordableModifierFlags)

            if heldModifiers.isEmpty
                && !lastHeldModifiers.isEmpty
                && !didCaptureKeyDuringThisRecording {
                // All modifiers released and no ordinary key was struck while
                // they were down: a modifier-only combo like ctrl + option.
                record(RecordedKeyboardShortcut(
                    modifierFlagsRawValue: lastHeldModifiers.rawValue,
                    keyCode: nil
                ))
            }

            lastHeldModifiers = heldModifiers

        case .keyDown:
            if event.keyCode == 53 { // Esc
                if lastHeldModifiers.isEmpty {
                    stopRecording()
                }
                // Esc with modifiers held is just a combo containing Esc; let
                // the general path below record it.
            }

            let heldModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(RecordedKeyboardShortcut.recordableModifierFlags)

            // A bare key would steal that key from every application — refuse
            // it and stay armed so the user can add a modifier.
            guard !heldModifiers.isEmpty else { return }

            didCaptureKeyDuringThisRecording = true
            record(RecordedKeyboardShortcut(
                modifierFlagsRawValue: heldModifiers.rawValue,
                keyCode: event.keyCode
            ))

        default:
            break
        }
    }
}
