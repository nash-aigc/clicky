//
//  MessageComposerField.swift
//  leanring-buddy
//
//  The text box at the bottom of all three content columns (对话 / Agent /
//  语音聊天). Shared rather than cloned three times because the behaviour the
//  user asked for is fiddly and identical everywhere:
//
//    · it is the ONLY control on its row apart from the stop button — the
//      语音 / Agent state badges that used to sit to its left are gone (the
//      user's 「右侧下方只有一个输入框」);
//    · it is a three-line rounded rectangle, not a 34pt capsule — a single-line
//      box made a long typed question unreadable;
//    · it carries a 展开 button in its own top-right corner (the user's
//      「点击这个展开按钮后，输入框的高度占据右侧高度的 30%」) and a clear ✕ in
//      its bottom-right, so the two never fight for one spot;
//    · it carries a 停止 button just outside its bottom-right corner, with a
//      thin gap rather than a margin (the user: 「在输入框的最右侧增加一个停止
//      按钮……跟输入框要留一条小的边距，小细缝就可以……长方形的、竖向的这样一个
//      按钮，减少空间的占用」);
//    · 回车 / Shift+回车 (or Command+回车 / 回车) do what the 交互 page's
//      「发送方式」 says they do.
//
//  The height is the caller's: it measures the content column and passes
//  `threeLineHeight` when collapsed and 30% of that column when expanded.
//
//  ## Why this is an `NSTextView` and not a `TextField(axis: .vertical)`
//
//  The user asked for 「按住 Shift 加回车换行」 (2026-09-23) and a vertical
//  SwiftUI `TextField` **cannot take a newline from the keyboard at all** —
//  measured over four build-and-probe rounds against the live field that day:
//  with the whole key handler removed, Shift+Return produced `onSubmit` and no
//  change to the bound text; appending "\n" to the binding from a handler ran
//  (the log proved the shift was seen) and left the value byte-unchanged; and
//  writing "\n" into the field editor itself via `NSTextView.insertText` ran
//  without error and left the value byte-exactly as it was. Only an
//  accessibility-level write of the whole string holds a "\n", which is not a
//  path a keyboard can take. So the field was left swallowing Shift+Return
//  rather than sending a half-written question.
//
//  A plain `NSTextView` has none of that: it is the same engine Notes and
//  Messages type into, `insertNewline:` inserts a real break, and — because
//  this one overrides `keyDown` — the send key is decided from the raw
//  `NSEvent` before any key binding can reinterpret it. That last part is what
//  makes 「按 Command + Enter 发送」 possible at all: Command+Return is not a
//  text command, so a `doCommandBy`-based gate would never see it.
//

import AppKit
import SwiftUI

struct MessageComposerField: View {

    let placeholder: String
    @Binding var draft: String
    /// The caller's focus flag. A plain `Binding<Bool>` rather than a
    /// `FocusState<Bool>.Binding` because the field below is an AppKit
    /// representable: it makes itself first responder, and reports back when
    /// AppKit ends the editing session, instead of going through SwiftUI's
    /// focus system.
    @Binding var isFocused: Bool

    /// The box's height right now — `threeLineHeight` collapsed, the caller's
    /// 30%-of-column figure expanded. The stop button is unaffected by it.
    let height: CGFloat

    let isExpanded: Bool
    let canToggleExpansion: Bool
    let onToggleExpansion: () -> Void

    /// The send key (whatever the 交互 page's 「发送方式」 currently says), or
    /// the field's submit. Callers own what sending means.
    let onSubmit: () -> Void

    /// Whether the assistant is working right now. The stop button's one input:
    /// grey when nothing is running, red while something is, grey again the
    /// moment it finishes — the user's own three states.
    let isResponding: Bool
    let onStop: () -> Void

    /// Room for the text: text is inset this far from the top and bottom, so
    /// the first line never touches the border.
    static let verticalTextInset: CGFloat = 8
    /// One line of the 13pt field. Deliberately a round number rather than a
    /// measured text line height: it only ever decides how tall the collapsed
    /// box is, and being slightly generous leaves a hair of slack at the bottom.
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

    /// The stop button: 「长方形的、竖向的」, and small — 「减少空间的占用」.
    /// Taller than it is wide is the whole of "vertical rectangle", and 42pt
    /// keeps it clear of the box's own 67pt without pretending to be a column.
    static let stopButtonWidth: CGFloat = 24
    static let stopButtonHeight: CGFloat = 42
    static let stopButtonCornerRadius: CGFloat = 6
    /// 「小细缝就可以，不要边距太大」 — a hairline of air, not a gutter.
    static let stopButtonGap: CGFloat = 6

    @State private var isExpandButtonHovered = false
    @State private var isClearButtonHovered = false
    @State private var isStopButtonHovered = false

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.stopButtonGap) {
            composerBox
            stopButton
        }
    }

    // MARK: - The box

    private var composerBox: some View {
        ComposerTextView(
            text: $draft,
            isFocused: $isFocused,
            onSubmit: onSubmit
        )
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
                    isFocused ? Color.white.opacity(0.25) : Color.white.opacity(0.1),
                    lineWidth: 0.5
                )
        )
        // `NSTextView` has no placeholder of its own, and faking one by seeding
        // the text with grey characters means every "is the draft empty" test in
        // the app has to know about it. A `Text` behind a hit-testing-disabled
        // overlay is the version that cannot leak into the value.
        .overlay(alignment: .topLeading) { placeholderLabel }
        .overlay(alignment: .topTrailing) { expandButton }
        .overlay(alignment: .bottomTrailing) { clearButton }
    }

    @ViewBuilder
    private var placeholderLabel: some View {
        if draft.isEmpty {
            Text(placeholder)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.32))
                .lineLimit(1)
                .padding(.leading, 12)
                .padding(.top, Self.verticalTextInset)
                .allowsHitTesting(false)
        }
    }

    /// Top-right: expand to 30% of the content column, collapse back to three
    /// lines. Focus is handed back to the field afterwards — clicking the
    /// button would otherwise end the typing session the user is in the middle
    /// of, which is exactly the wrong moment to lose it.
    private var expandButton: some View {
        Button {
            onToggleExpansion()
            isFocused = true
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

    // MARK: - The stop button

    /// 「如果没有输入，它就是灰色；如果 AI 正在回复……它是红色；如果回复完成，
    /// 它又变成灰色。」 So the button is always on screen and only its colour
    /// changes — hiding it would take away the one thing that tells the user a
    /// reply is still running, and the box would jump sideways every time one
    /// started or ended.
    private var stopButton: some View {
        Button {
            onStop()
        } label: {
            RoundedRectangle(cornerRadius: Self.stopButtonCornerRadius, style: .continuous)
                .strokeBorder(stopButtonBorderColor, lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: Self.stopButtonCornerRadius, style: .continuous)
                        .fill(stopButtonFillColor)
                )
                // 「做一个红色的框就可以了」 — the glyph is a square rather than
                // the word 停止, and it is the same shape in both states so only
                // the colour reads as the change.
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(stopButtonGlyphColor)
                        .frame(width: 8, height: 8)
                )
                .frame(width: Self.stopButtonWidth, height: Self.stopButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isResponding)
        .pointerCursor(isEnabled: isResponding)
        .onHover { hovering in
            isStopButtonHovered = hovering
        }
        .help(isResponding ? "停止" : "现在没有在回复")
    }

    private var stopButtonBorderColor: Color {
        guard isResponding else { return Color.white.opacity(0.12) }
        return Color.red.opacity(isStopButtonHovered ? 0.95 : 0.7)
    }

    private var stopButtonFillColor: Color {
        guard isResponding else { return Color.white.opacity(0.04) }
        return Color.red.opacity(isStopButtonHovered ? 0.3 : 0.2)
    }

    private var stopButtonGlyphColor: Color {
        guard isResponding else { return Color.white.opacity(0.22) }
        return Color(red: 1.0, green: 0.42, blue: 0.42)
    }
}

// MARK: - The text engine

/// The composer's editable text, backed by `NSTextView`.
///
/// The measurements that ruled out `TextField(axis: .vertical)` are in this
/// file's header. What is left is a scroll view that grows with its text and
/// the two-way focus bridge SwiftUI needs for an AppKit field.
private struct ComposerTextView: NSViewRepresentable {

    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text

        // `isRichText = false` because the composer is plain text: without it the
        // view accepts pasted attributes and the value stops matching what the
        // user sees.
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        // Both of these are indents the text view adds on its own. Left at their
        // defaults the first character sits ~5pt right of the placeholder's
        // first character, which reads as the placeholder being misaligned
        // rather than the text being padded. The real padding is the SwiftUI
        // modifiers around this view.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        textView.handleSendKeyEvent = { [weak coordinator = context.coordinator] event in
            coordinator?.handleSendKeyEvent(event) ?? false
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        // The box already has a visible edge; a focus ring drawn just inside it
        // would be a second border. The SwiftUI stroke under it is the focus
        // indicator.
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.focusRingType = .none
        textView.focusRingType = .none

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Only ever written when it differs, and `textDidChange` keeps the
        // binding in step while typing — so this cannot fight the user's cursor.
        if textView.string != text {
            textView.string = text
        }

        let isEditing = textView.window?.firstResponder === textView
        // Deferred by one run-loop turn: `makeFirstResponder` during a SwiftUI
        // update re-enters AppKit's responder chain in the middle of a layout
        // pass, and the window may not exist yet on the first update.
        if isFocused, !isEditing {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused, isEditing {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// Returns true when the event was the send key, in which case it has
        /// already been sent and must not also reach the text view.
        ///
        /// The decision is made from the raw `NSEvent` rather than from a text
        /// command, because Command+Return is not bound to one: `doCommandBy`
        /// would never be called for it. Everything that is NOT the send key
        /// falls through to `super.keyDown`, which is what makes the matching
        /// key the "new line" key in both settings.
        ///
        /// The setting is read here, at the moment of the keypress, rather than
        /// passed in as a view parameter: `AppSettingsStore.snapshot()` is
        /// always current (a save swaps the cache and posts a notification), so
        /// a change made on the 交互 page applies to the very next Return, with
        /// no view rebuild in between.
        func handleSendKeyEvent(_ event: NSEvent) -> Bool {
            guard event.keyCode == 36 || event.keyCode == 76 else { return false }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let sendsOnCommand = AppSettingsStore.snapshot().composerSendShortcut == .commandReturn

            // 按 Enter 发送: Return sends, Shift+Return is left to the text view
            // (a newline). 按 Command + Enter 发送: only Command+Return sends, so
            // plain Return and Shift+Return both insert a newline.
            let shouldSend = sendsOnCommand
                ? modifiers.contains(.command)
                : !modifiers.contains(.shift)
            guard shouldSend else { return false }

            parent.onSubmit()
            return true
        }
    }
}

/// An `NSTextView` that gets first refusal on every key-down.
///
/// `keyDown` rather than `doCommandBy` because of Command+Return (see the
/// coordinator); `keyDown` is also the only hook that runs before the key
/// binding system turns Return into `insertNewline:`.
private final class ComposerNSTextView: NSTextView {

    var handleSendKeyEvent: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleSendKeyEvent?(event) == true { return }
        super.keyDown(with: event)
    }
}
