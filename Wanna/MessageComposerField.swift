//
//  MessageComposerField.swift
//  Wanna
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

/// 输入框右下角除 ✕ 之外的那个按钮。目前只有 Ask 页的静音开关用它。
///
/// 做成一个值类型而不是泛型插槽，是因为这里只需要「一个纯图标按钮」这一种形状：
/// 泛型会把三个调用点的类型签名都改一遍，而它们要的只是「有没有这个按钮」。
/// 图标与颜色由调用方按自己的状态算好传进来，输入框不持有那个状态。
struct ComposerAccessoryButton {
    let systemImageName: String
    let tint: Color
    let helpText: String
    let action: () -> Void
}

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
    /// 「长方形加圆角」 — 参考页's chat-card radius, not a capsule.
    static let cornerRadius: CGFloat = DS.CornerRadius.large
    /// The trailing inset that keeps text out from under the two corner
    /// buttons (they are 20pt wide and sit 4pt from the edge).
    static let trailingButtonInset: CGFloat = 26
    /// 右下角多一个附加按钮时的右侧留白：✕(20) + 间隔(2) + 附加按钮(24) + 余量(6)。
    static let trailingButtonInsetWithAccessory: CGFloat = 52

    /// The stop button: 「长方形的、竖向的」, and its height is exactly the
    /// box's own — the user's 「停止按钮的高度必须与输入框高度完全相同」
    /// (2026-09-23): the earlier fixed 42pt read as a stub beside the
    /// three-line box, and collapsed further against the expanded one. The
    /// height is the `height` parameter, so it tracks the box in both states.
    /// Only the width is fixed.
    static let stopButtonWidth: CGFloat = 24
    static let stopButtonCornerRadius: CGFloat = 6
    /// 「小细缝就可以，不要边距太大」 — a hairline of air, not a gutter.
    static let stopButtonGap: CGFloat = 6

    @State private var isExpandButtonHovered = false
    @State private var isClearButtonHovered = false
    @State private var isStopButtonHovered = false
    @State private var isAccessoryButtonHovered = false

    /// 右下角的附加图标按钮（可选）。默认没有 —— 只有 Ask 页传它。
    ///
    /// **它必须在输入框内部**，这是用户 2026-09-25 的直接要求：「把声音按钮移到
    /// 用户输入框的右下角，减少空间占用。现在用户发送提示词后，声音按钮会挡住
    /// 提示词」。原先它是输入框上方独立的一行，而那一行与输入框之间只有 10 pt，
    /// 提示词一长就往那一行底下钻，正好被它盖住。
    var composerAccessory: ComposerAccessoryButton? = nil

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
        // 右侧给角上按钮留的宽度随「有没有附加按钮」变化：✕ 一个要 26，✕ 加静音
        // 要 52（20 + 2 + 24），否则最后一行文字会钻到静音图标底下。
        .padding(.trailing, composerAccessory == nil
                 ? Self.trailingButtonInset
                 : Self.trailingButtonInsetWithAccessory)
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
        // 右下角是一组，不是单个：✕ 只在有字时出现，附加按钮（静音）常驻。
        // 并排放才不会有字的时候两者抢同一个角落。
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                clearButton
                accessoryButton
            }
        }
    }

    /// 右下角常驻的那个图标按钮（Ask 页的静音开关）。
    ///
    /// 纯图标、无文字（用户要求），因此比 ✕ 稍大一点以保证可点面积 ——
    /// 22 pt 的图标落在 24 pt 的方形热区里，比 ✕ 的 20 pt 大一档。
    @ViewBuilder
    private var accessoryButton: some View {
        if let composerAccessory {
            Button(action: composerAccessory.action) {
                Image(systemName: composerAccessory.systemImageName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isAccessoryButtonHovered
                        ? composerAccessory.tint
                        : composerAccessory.tint.opacity(0.75)
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                isAccessoryButtonHovered = hovering
            }
            .help(composerAccessory.helpText)
        }
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
                .frame(width: Self.stopButtonWidth, height: height)
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
        textView.handleFocusChange = { [weak coordinator = context.coordinator] isFocusedNow in
            coordinator?.reportFocusChange(isFocusedNow)
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

        let isEditing = textView.window?.firstResponder === textView

        // **用户正在编辑时绝不回写字符串。**
        //
        // 用户 2026-09-25 报的「打好的字会被自动退回／按住回车或空格之后这些字就
        // 被删掉」就是这一行造成的：`text` 是 SwiftUI 侧的绑定，而 `updateNSView`
        // 完全可能带着**还没跟上的旧值**跑一次 —— 此时视图里已经是用户新打的字，
        // 比较必然不等，于是把旧串写回去，用户刚敲的字符被抹掉。
        //
        // 为什么偏偏在对话里明显：回复流式期间父视图每个 delta 都重渲染，
        // `updateNSView` 跟着跑一次，每次都有一次抹掉的机会；按住键（键盘连发）
        // 会把这件事的命中率放大成「几乎必然」。
        //
        // 打字期间**用户输入的才是权威**：`textDidChange` 会把视图的真实内容同步给
        // 绑定，所以这里什么都不用做就是对的。程序性改动（提交后清空）走的是另外的
        // 顺序 —— 清除时同时把 `isFocused` 置假，视图先退出第一响应者，下一次更新
        // 就走下面这条分支把新值写进来了。
        if !isEditing, textView.string != text {
            textView.string = text
        }

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
                // **退出第一响应者之后，把外部那份值补写进去。**
                //
                // 用户 2026-09-25：「发送之后，提示词还卡在输入框里，过了几秒钟才消失」。
                //
                // 顺序是这样的：发送时调用方把草稿置空、把 `isFocused` 置假 → 这一次
                // `updateNSView` 带着空串跑，但**此时输入框还是第一响应者**，于是上面那条
                // 回写被 `isEditing` 挡掉 → 这里排的这个延迟块确实让它退了第一响应者，
                // 可是 `reportFocusChange` 发现 `isFocused` **本来就是 false**，状态没变，
                // **不会触发新的渲染** —— 于是"下一次更新"永远不来，那笔回写没人补，
                // 文字就一直留在框里，直到焦点因为别的原因变化（用户点别处）才消失。
                //
                // 所以补写在**这里**做：它是同一件事的后半段，而不是等一次不会发生的渲染。
                if textView.string != text {
                    textView.string = text
                }
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

        /// 把 AppKit 的**响应者转移**翻译成 SwiftUI 的 `isFocused`。
        ///
        /// 唯一的写入点，由 `ComposerNSTextView.becomeFirstResponder` /
        /// `resignFirstResponder` 调用 —— 不再监听 `textDidBeginEditing` /
        /// `textDidEndEditing`，原因见那里关于「编辑会话 ≠ 第一响应者」的注释。
        func reportFocusChange(_ isFocusedNow: Bool) {
            if parent.isFocused != isFocusedNow {
                parent.isFocused = isFocusedNow
            }
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

    /// 焦点变化的上报口，由 coordinator 接住（见 `reportFocusChange`）。
    var handleFocusChange: ((Bool) -> Void)?

    /// **焦点状态由「第一响应者转移」上报，不由「编辑会话」上报。**
    ///
    /// 这是 2026-09-25 「点输入框无法输入」的根因修复。原实现只在
    /// `textDidBeginEditing` / `textDidEndEditing` 里翻转 `isFocused`，而那对
    /// 通知描述的是 AppKit 的**编辑会话**：NSTextView 只在窗口为 key 时才进入
    /// 编辑会话。于是能造出这样一条不一致状态 —— 视图**已经是**第一响应者，
    /// 但一个通知都没发过。装探针实测到的现场（日志原文）：
    ///
    ///     mouseDown 到达；isKeyWindow=true  点击前 firstResponder=ComposerNSTextView
    ///     （此后 textDidBeginEditing 从未出现）
    ///     updateNSView isFocused=false isEditing=true
    ///     textDidEndEditing → 异步 makeFirstResponder(nil)
    ///
    /// 三步合起来是一个**自我加固的死锁**：视图已是第一响应者 → 再点它不产生
    /// 转移 → 通知不再发 → `isFocused` 永远是 false；而 `updateNSView` 一旦看到
    /// 「isFocused=false 而 isEditing=true」就主动把它踢出第一响应者，把失败钉死。
    /// 用户看到的「偶尔能用、偶尔不能用」正是它：取决于第一次点击落在窗口是否
    /// 已经 key 的时刻。
    ///
    /// `becomeFirstResponder` / `resignFirstResponder` 在**响应者转移**时必然被
    /// 调用，与窗口是否 key 无关，所以上面那条状态造不出来。
    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { handleFocusChange?(true) }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { handleFocusChange?(false) }
        return resignedFirstResponder
    }

    /// **首次点击就能聚焦**（用户 2026-09-25：「点击 Asking 后立即点击输入框……
    /// 无法输入任何问题；只有点击输入框上面，光标才能定位到输入框」）。
    ///
    /// 默认行为下，非 key 窗口（或刚重建完视图树的窗口）里的第一次点击只用于
    /// 「激活窗口」，不会投递给视图 —— 于是点在输入框上的第一下被吃掉，光标
    /// 不会进来。`acceptsFirstMouse` 让第一击既激活窗口又完成聚焦。
    ///
    /// 它同时覆盖「切换分区后视图树刚重建」的场景：新视图实例在第一次点击时
    /// 直接接管，不再依赖外层那颗 `onTapGesture` 先把 `isFocused` 置真。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// 双保险：即使第一击被窗口激活吞掉（`acceptsFirstMouse` 之外的路徑），
    /// `mouseDown` 也确保自己成为第一响应者 —— AppKit 对 text view 的默认
    /// mouseDown 链只有在已经是/能成为 first responder 时才进编辑态。
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self, window?.makeFirstResponder(self) == true {
            // 让出这次 mouseDown 给 super，caret 会落在点击位置。
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleSendKeyEvent?(event) == true { return }
        super.keyDown(with: event)
    }
}
