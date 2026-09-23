//
//  MessageComposerField.swift
//  leanring-buddy
//
//  The text field at the bottom of all three content columns (对话 / Agent /
//  语音聊天). Shared rather than cloned three times because the behaviour the
//  user asked for is fiddly and identical everywhere:
//
//    · it is the ONLY control on its row — the 语音 / Agent state badges that
//      used to sit to its left are gone (the user's 「右侧下方只有一个输入框」);
//    · it is a three-line rounded rectangle, not a 34pt capsule — a single-line
//      box made a long typed question unreadable;
//    · it carries a 展开 button in its own top-right corner (the user's
//      「点击这个展开按钮后，输入框的高度占据右侧高度的 30%」) and a clear ✕ in
//      its bottom-right, so the two never fight for one spot;
//    · Return sends; Shift+Return is swallowed rather than sending, because
//      this field cannot take a newline from the keyboard at all (the
//      measurements are on the handler below).
//
//  The height is the caller's: it measures the content column and passes
//  `threeLineHeight` when collapsed and 30% of that column when expanded. The
//  line limit follows the height, so an expanded box can actually be filled
//  with text instead of showing three lines above a field of blank.
//

import SwiftUI

struct MessageComposerField: View {

    let placeholder: String
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding

    /// The box's height right now — `threeLineHeight` collapsed, the caller's
    /// 30%-of-column figure expanded.
    let height: CGFloat

    let isExpanded: Bool
    let canToggleExpansion: Bool
    let onToggleExpansion: () -> Void

    /// Return, or the send button. Callers own what sending means.
    let onSubmit: () -> Void

    /// Room for the text: text is inset this far from the top and bottom, so
    /// the first line never touches the border.
    static let verticalTextInset: CGFloat = 8
    /// One line of the 13pt field. Deliberately a round number rather than a
    /// measured text line height: it only ever decides how many lines fit, and
    /// being slightly generous leaves a hair of slack at the bottom.
    static let lineHeight: CGFloat = 17
    /// The user's floor: 「至少要能让用户看到三行」.
    static let minimumVisibleLineCount = 3
    /// A three-line box with a single line typed in it — the resting height.
    static let threeLineHeight: CGFloat =
        verticalTextInset * 2 + lineHeight * CGFloat(minimumVisibleLineCount)
    /// 「长方形加圆角」 — the reference's chat-card radius, not a capsule.
    static let cornerRadius: CGFloat = DS.CornerRadius.large
    /// The trailing inset that keeps text out from under the two corner
    /// buttons (they are 20pt wide and sit 4pt from the edge).
    static let trailingButtonInset: CGFloat = 26

    @State private var isExpandButtonHovered = false
    @State private var isClearButtonHovered = false

    var body: some View {
        TextField(placeholder, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .lineLimit(Self.minimumVisibleLineCount...maximumVisibleLineCount)
            .focused(isFocused)
            // Return sends, and `.onSubmit` is the whole of it — no key handler
            // is needed for the plain case, because SwiftUI already routes
            // Return here: measured 2026-09-23 with this handler removed
            // entirely, a Return on the 语音聊天 composer still produced
            // `onSubmit`. The handler below exists for the OTHER Return.
            //
            // Shift+Return is consumed and deliberately does nothing, and this
            // is the least-bad of the three behaviours that were measured
            // against the live field on 2026-09-23. It CANNOT insert a line
            // break: a `TextField(axis: .vertical)` takes no newline from the
            // keyboard at all — with the whole key handler removed, Shift+Return
            // produced `onSubmit` and no change to the bound text; appending
            // "\n" to `draft` from a handler is swallowed by the focused field
            // editor (the handler ran, the log proved the shift was seen, the
            // text was unchanged); and writing "\n" into the field editor
            // itself (`NSTextView.insertText`) ran without error and left the
            // value byte-exactly as it was. Only an accessibility-level write of
            // the whole string holds a "\n", which is not a path a keyboard can
            // take. So the choice is between doing nothing and sending: letting
            // the event continue (`.ignored`) falls through to the field's own
            // submit — measured, the draft cleared and a real answer started —
            // which turns "I want a new line" into a sent half-written question.
            // Consuming it is what keeps that from happening. The box still
            // reads as multi-line, because a long question wraps inside it.
            //
            // The catch-all `phases:` overload, not `onKeyPress(.return)`, is
            // deliberate: this one is documented to receive every key-down (its
            // own example switches on `keyPress.key`), so Shift+Return is
            // guaranteed to arrive here whatever SwiftUI's KeyEquivalent
            // matching does with the modifier.
            .onSubmit {
                onSubmit()
            }
            .onKeyPress(phases: .down) { keyPress in
                guard keyPress.key == .return, keyPress.modifiers.contains(.shift) else {
                    return .ignored
                }
                return .handled
            }
            .padding(.horizontal, 12)
            .padding(.vertical, Self.verticalTextInset)
            .padding(.trailing, Self.trailingButtonInset)
            .frame(height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused.wrappedValue ? Color.white.opacity(0.25) : Color.white.opacity(0.1),
                        lineWidth: 0.5
                    )
            )
            .overlay(alignment: .topTrailing) { expandButton }
            .overlay(alignment: .bottomTrailing) { clearButton }
    }

    /// How many lines the box can show at its current height. Expanding the box
    /// has to raise this too — a fixed 3 with a tall box would leave the user
    /// typing into a field of blank.
    private var maximumVisibleLineCount: Int {
        let textHeight = height - Self.verticalTextInset * 2
        return max(Self.minimumVisibleLineCount, Int(textHeight / Self.lineHeight))
    }

    /// Top-right: expand to 30% of the content column, collapse back to three
    /// lines. Focus is handed back to the field afterwards — clicking the
    /// button would otherwise end the typing session the user is in the middle
    /// of, which is exactly the wrong moment to lose it.
    private var expandButton: some View {
        Button {
            onToggleExpansion()
            isFocused.wrappedValue = true
        } label: {
            Image(systemName: isExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(isExpandButtonHovered ? 0.8 : 0.4))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: canToggleExpansion)
        .disabled(!canToggleExpansion)
        .opacity(canToggleExpansion ? 1 : 0.35)
        .onHover { hovering in
            isExpandButtonHovered = hovering
        }
        .padding(.top, 3)
        .padding(.trailing, 4)
        .help(isExpanded ? "收起输入框" : "展开输入框（占右侧高度的 30%）")
    }

    /// Bottom-right: emptying the box. The ✕ moved down from the row's middle
    /// when 展开 took the top corner.
    @ViewBuilder
    private var clearButton: some View {
        if !draft.isEmpty {
            Button {
                draft = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(isClearButtonHovered ? 0.7 : 0.4))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                isClearButtonHovered = hovering
            }
            .padding(.bottom, 2)
            .padding(.trailing, 4)
            .help("清空输入")
        }
    }
}
