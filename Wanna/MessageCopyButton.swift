//
//  MessageCopyButton.swift
//  Wanna
//
//  The copy control under a message bubble, shared by all three content
//  columns (对话 / Agent / 语音聊天) so the same gesture means the same thing
//  everywhere — the user asked for the Agent and 语音聊天 pages to be able to
//  copy both their own words and the assistant's reply, and for the three
//  pages to look like one app.
//
//  It copies the text the bubble SHOWS, not the raw stored reply. The stored
//  assistant response still carries its `[POINT:…]` / `[CLICK:…]` tags — the
//  executor's vocabulary — and those are never what someone wants to paste
//  somewhere. Callers pass the display string; see each call site's comment.
//

import AppKit
import SwiftUI

struct MessageCopyButton: View {

    /// The exact string this button puts on the pasteboard — the same one the
    /// bubble renders beside it.
    let text: String

    /// Shown to the right of the icon; 复制 for a question or a reply, and
    /// whatever else a call site wants. Kept a parameter rather than derived
    /// from the text so the label never guesses.
    var title: String = "复制"

    /// The accessibility / tooltip wording. The default names the copy act in
    /// full because the visible label is only two characters.
    var helpText: String = "复制这条消息"

    /// True for the 1.2 s after a successful copy, so the control can confirm
    /// it without a toast. Counted rather than a bare Bool: two fast clicks
    /// would otherwise let the first click's reset fire during the second
    /// click's confirmation, and the checkmark would vanish early.
    @State private var copyConfirmationGeneration = 0
    @State private var didCopyRecently = false
    @State private var isHovered = false

    private static let copyConfirmationDurationNanoseconds: UInt64 = 1_200_000_000

    private var textIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button(action: copyToPasteboard) {
            HStack(spacing: 4) {
                Image(systemName: didCopyRecently ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(didCopyRecently ? "已复制" : title)
                    .font(.system(size: 10.5))
            }
            .foregroundColor(
                didCopyRecently
                    ? Color(red: 0.42, green: 0.82, blue: 0.52)
                    : .white.opacity(isHovered ? 0.72 : 0.38)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.11 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: !textIsEmpty)
        .disabled(textIsEmpty)
        .opacity(textIsEmpty ? 0.4 : 1)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
    }

    private func copyToPasteboard() {
        guard !textIsEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        copyConfirmationGeneration += 1
        let generation = copyConfirmationGeneration
        didCopyRecently = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.copyConfirmationDurationNanoseconds)
            guard generation == copyConfirmationGeneration else { return }
            didCopyRecently = false
        }
    }
}
