//
//  AnswerCardView.swift
//  leanring-buddy
//
//  The assistant reply's card, in one of three themes (blue / black / paper)
//  chosen in 设置 → 交互样式. Ported from the user's reference spec
//  (「clip 卡片样式」, 实现说明.md): a 10pt-corner card with a 1.5pt border,
//  tight 10/12 padding, 13.5pt text on a ~22pt line pitch — and the spec's
//  signature text animation, the blur-focus stream: every new character
//  enters blurred (blur 2.6) and half-transparent (opacity 0.2), and settles
//  to fully sharp with a 0.3s ease once five more units have arrived behind
//  it, leaving a ~5-unit blurred tail at the writing edge.
//
//  SwiftUI cannot blur individual characters inside one Text, so the text is
//  split into units (one unit per CJK character, contiguous Latin/digit runs
//  kept whole so English words never wrap mid-word). Newlines become break
//  markers: 「\n\n」 opens a 14pt paragraph gap, a bare 「\n」 just ends the line.
//
//  ONE line-breaking rule renders both states. `CardTextLineBreaker` packs the
//  units into lines, and both the streaming card and the settled card are drawn
//  from those same lines — the settled card as one Text per paragraph, the
//  streaming card as those same paragraphs plus its still-growing last line
//  rendered per unit (that is where the blur-focus tail lives). The card used to
//  break its lines twice — a greedy flow Layout while streaming, one whole-string
//  Text once settled — and the two engines disagreed: measured on a real
//  1482-character reply, 55 lines streaming against 62 settled, so the card grew
//  seven lines (~150 pt) the instant a reply finished. Per-unit views also cost
//  far more than they look: one Text per unit through SwiftUI's layout on every
//  streamed character measured at 88% of the main thread and ~117% of one CPU
//  core, against 12% idle.
//
//  系统开启「减弱动态效果」时全部直接清晰显示，不做任何动画
//  (the reference's prefers-reduced-motion degradation).
//

import SwiftUI
import AppKit
import CoreText
import QuartzCore

// MARK: - Theme

/// The three reference themes, verbatim from 实现说明.md §3.3–3.4:
/// blue #0B57D0 / white text, black #000 / white text,
/// paper #F7F2E7 / ink #2E2A24 with 22pt ruled draft-paper lines.
struct AnswerCardTheme {
    let backgroundColor: Color
    let borderColor: Color
    let textColor: Color
    let drawsRuledLines: Bool

    init(style: AnswerCardStyle) {
        switch style {
        case .blue:
            self.backgroundColor = Color(red: 11 / 255, green: 87 / 255, blue: 208 / 255)
            self.borderColor = Color.white.opacity(0.30)
            self.textColor = .white
            self.drawsRuledLines = false
        case .black:
            // 2026-09-23：底色从纯黑抬到 #26262B。用户的原话是「AI 回复消息的
            // 颜色现在是全黑色，可以变得浅一点，或者用灰色，颜色可以稍微有一点
            // 差别，但不要这么深的黑色，体验不是特别好，因为颜色太深了」——
            // 面板地面是 #18181C，纯黑卡片在它上面是一块挖空的洞，抬到这一档
            // 之后它读起来是浮在面板上的一块深灰。边框同步从 16% 提到 20%，
            // 否则浅底上那条 1.5pt 的线会淡到看不见。
            //
            // 名字仍然是「黑」：`AnswerCardStyle` 是按 rawValue 存进
            // AppSettings.json 的，改 case 名会让老配置文件解不出来，而这一档
            // 相对另外两档（实心蓝 / 米黄宣纸）本来就还是"深色那一档"。
            self.backgroundColor = Color(red: 38 / 255, green: 38 / 255, blue: 43 / 255)
            self.borderColor = Color.white.opacity(0.20)
            self.textColor = .white
            self.drawsRuledLines = false
        case .paper:
            self.backgroundColor = Color(red: 247 / 255, green: 242 / 255, blue: 231 / 255)
            self.borderColor = Color.black.opacity(0.18)
            self.textColor = Color(red: 46 / 255, green: 42 / 255, blue: 36 / 255)
            self.drawsRuledLines = true
        }
    }

    // Reference spec §3.3: 宣纸卡片 every 22pt one very faint ruled line
    // (rgba(43,43,43,.055)), aligned to the 22pt line pitch.
    static let ruledLineSpacing: CGFloat = 22
    static let ruledLineColor = Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255).opacity(0.055)
}

// MARK: - Text units

/// One rendering unit of the streaming reply. CJK text is one character per
/// unit (the blur tail is per-character, as in the reference); a contiguous
/// run of ASCII letters/digits (plus intra-word `-` and `'`) is ONE unit, so
/// "qwen3-vl-plus" enters as a word instead of shattering and wrapping
/// mid-word. Break markers carry the newline information the flow layout
/// needs.
nonisolated enum CardTextUnitKind {
    case content
    case lineBreak
    case paragraphGap
}

nonisolated struct CardTextUnit: Identifiable {
    let id: Int
    let text: String
    let kind: CardTextUnitKind
    /// How many characters of the reply this unit was built from. Always equal
    /// to `text.count` for a content unit, but a `"\n\n"` paragraph gap carries
    /// no text at all while consuming two characters — so this is the only way
    /// to know where the final unit began, which is what lets the builder resume
    /// from it instead of re-splitting the whole reply.
    let characterCount: Int
}

nonisolated enum CardTextUnitBuilder {

    /// Split reply text into rendering units. `"\n\n"` becomes a paragraph
    /// gap (a 14pt vertical pause in the reference timeline), a bare `"\n"`
    /// a line break.
    static func units(from text: String) -> [CardTextUnit] {
        units(from: text, extending: [], resumingAfterCharacterCount: 0)
    }

    /// Split `text` into rendering units, reusing `previousUnits` when `text`
    /// merely continues the text they were built from.
    ///
    /// This is where the card stops being quadratic. The card re-evaluates its
    /// body on every streamed character, and splitting the whole reply each time
    /// allocated one `String` per character of it — 5936 characters at ~21
    /// evaluations a second. But the split is left to right and a unit is closed
    /// only when the next character begins a different kind of run, so a
    /// character appended at the end can extend the final unit or begin a new
    /// one and **can change no other**. Every unit before the last is therefore
    /// reusable verbatim, and only the last is dropped and re-derived — from the
    /// character offset it began at, which `CardTextUnit.characterCount` is what
    /// makes knowable. Dropping that one unit is also what turns a trailing
    /// 「\n」 into a paragraph gap when a second one arrives.
    ///
    /// - Parameters:
    ///   - previousUnits: the units `text` was last split into, or `[]`.
    ///   - previousTextCharacterCount: the length of the text those units were
    ///     split from. Must not exceed `text.count`.
    static func units(
        from text: String,
        extending previousUnits: [CardTextUnit],
        resumingAfterCharacterCount previousTextCharacterCount: Int
    ) -> [CardTextUnit] {
        var units = previousUnits
        var characterIndex = previousTextCharacterCount
        if let finalUnit = units.popLast() {
            characterIndex -= finalUnit.characterCount
        }
        // The surviving units are contiguous from the start of the text, so each
        // one's id is still its own position — the live line's `ForEach` and the
        // line breaker both index units by position, and neither may see a gap.
        var nextID = units.count

        func appendUnit(_ unitText: String, _ kind: CardTextUnitKind, _ characterCount: Int) {
            units.append(CardTextUnit(
                id: nextID,
                text: unitText,
                kind: kind,
                characterCount: characterCount
            ))
            nextID += 1
        }

        var index = text.index(text.startIndex, offsetBy: characterIndex)
        let endIndex = text.endIndex

        while index < endIndex {
            let character = text[index]

            if character == "\n" {
                let nextIndex = text.index(after: index)
                if nextIndex < endIndex, text[nextIndex] == "\n" {
                    appendUnit("", .paragraphGap, 2)
                    index = text.index(after: nextIndex)
                } else {
                    appendUnit("", .lineBreak, 1)
                    index = nextIndex
                }
                continue
            }

            if CardTextUnitBuilder.isLatinWordCharacter(character) {
                var word = ""
                var wordCharacterCount = 0
                var wordEndIndex = index
                while wordEndIndex < endIndex,
                      CardTextUnitBuilder.isLatinWordCharacter(text[wordEndIndex]) {
                    word.append(text[wordEndIndex])
                    wordCharacterCount += 1
                    wordEndIndex = text.index(after: wordEndIndex)
                }
                appendUnit(word, .content, wordCharacterCount)
                index = wordEndIndex
                continue
            }

            appendUnit(String(character), .content, 1)
            index = text.index(after: index)
        }

        return units
    }

    /// ASCII letters, digits and intra-word `-` / `'` group into one unit.
    /// Everything else — CJK characters, punctuation, spaces — is its own unit.
    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.asciiValue else { return false }
        let isUppercase = scalar >= 65 && scalar <= 90
        let isLowercase = scalar >= 97 && scalar <= 122
        let isDigit = scalar >= 48 && scalar <= 57
        let isIntraWordPunctuation = scalar == 45 || scalar == 39
        return isUppercase || isLowercase || isDigit || isIntraWordPunctuation
    }
}

// MARK: - Line breaking

/// One rendered line of the reply: the units that sit on it, and whether a
/// 「\n\n」 opened a paragraph gap in front of it.
nonisolated struct CardTextPackedLine {
    var unitIndices: [Int]
    var opensParagraph: Bool
}

/// The card's ONE line-breaking rule, and the reason this file no longer
/// contains a flow `Layout`.
///
/// Both the streaming card and the settled card are rendered from the lines
/// this returns, and that is the point: the card used to break its lines twice —
/// the streaming card through a greedy per-unit flow layout, the settled card by
/// handing the whole string to a single `Text` — and the two engines disagreed
/// about where the lines went. Measured 2026-09-23 on the user's own longest
/// reply (1482 characters, read back from
/// `~/Library/Application Support/Clicky/ConversationSessions.json`): the flow
/// layout packed it into **55 lines** and `Text` laid the same string out in
/// **62**, so the instant a reply finished the card re-wrapped and grew seven
/// lines (≈150 pt) under the person reading it.
///
/// The rule is CSS's own greedy inline flow: append a unit while it fits, close
/// the line when it does not, and let a `\n` close a line outright.
nonisolated enum CardTextLineBreaker {

    /// - Parameters:
    ///   - units: the reply's rendering units, in reading order.
    ///   - unitWidths: each unit's measured width, index-aligned with `units`.
    ///   - lineWidth: the width the rendered text will actually be given.
    ///   - previousState: where the last pack left off — `CardTextBreakState()`
    ///     for a fresh pack, or `stateBeforeFinalLine` of the previous one to
    ///     continue a reply that has only grown.
    /// - Returns: the packing state. `closedLines` is the finished result; the
    ///   rest is what a later call resumes from.
    static func breakIntoLines(
        units: [CardTextUnit],
        unitWidths: [CGFloat],
        lineWidth: CGFloat,
        resumingFrom previousState: CardTextBreakState
    ) -> CardTextBreakState {
        var state = previousState

        func closeLine() {
            // A break with nothing in front of it is skipped rather than
            // emitted: 「text\n\nmore」 is a lineBreak followed by a paragraphGap,
            // and closing the empty line between them would double the gap,
            // while a reply ending in 「\n」 must not gain a phantom blank line.
            guard !state.currentUnitIndices.isEmpty else { return }
            state.closedLines.append(CardTextPackedLine(
                unitIndices: state.currentUnitIndices,
                opensParagraph: state.pendingParagraphGap
            ))
            state.currentUnitIndices = []
            state.currentLineWidth = 0
            state.pendingParagraphGap = false
        }

        var unitIndex = state.nextUnitIndex
        while unitIndex < units.count {
            let unit = units[unitIndex]
            defer { unitIndex += 1 }

            guard unit.kind == .content else {
                closeLine()
                if unit.kind == .paragraphGap {
                    state.pendingParagraphGap = true
                }
                continue
            }
            guard unitIndex < unitWidths.count else { continue }
            let unitWidth = unitWidths[unitIndex]
            // A paragraph flag belongs to the line that STARTS after the gap, and
            // the `closeLine()` above consumed it when it ended the paragraph, so
            // a line that wraps later in the paragraph can never inherit it.
            if !state.currentUnitIndices.isEmpty
                && state.currentLineWidth + unitWidth > lineWidth {
                closeLine()
            }
            state.currentUnitIndices.append(unitIndex)
            state.currentLineWidth += unitWidth
        }
        state.nextUnitIndex = units.count

        closeLine()
        return state
    }
}

/// Where a pack of the reply's lines left off.
///
/// Kept so the next pack can continue instead of starting over — see
/// `stateBeforeFinalLine` for the invariant that makes that exact.
nonisolated struct CardTextBreakState {

    /// Every line already closed. A line lands here when a later unit overflows
    /// it or a break marker follows it, and **nothing appended afterwards can
    /// change it**: the pack only ever moves forward.
    var closedLines: [CardTextPackedLine] = []

    /// The line currently being packed. Empty between lines.
    var currentUnitIndices: [Int] = []
    var currentLineWidth: CGFloat = 0

    /// Set by a paragraph gap, consumed by the next `closeLine()`, where it
    /// becomes that line's `opensParagraph`.
    var pendingParagraphGap = false

    /// The first unit not yet visited.
    var nextUnitIndex = 0

    /// The state this pack was in just before its final line began.
    ///
    /// This is the whole reason the card can render a streamed reply in constant
    /// time per character. A line's content depends only on the units from its
    /// own first one onward and on the width in play, and both are unchanged by
    /// a character appended at the end — so re-packing from that unit reproduces
    /// the final line exactly, while every line before it is already closed and
    /// stays closed. Only the last line is ever re-packed, and a line is bounded
    /// by the width it was packed into, so that is a handful of units rather
    /// than the whole reply.
    ///
    /// The last line's `opensParagraph` is what `pendingParagraphGap` held while
    /// it was open: a paragraph gap closes the line in front of it, so the flag
    /// can only have been set before this line began, and `closeLine()` is what
    /// clears it.
    var stateBeforeFinalLine: CardTextBreakState {
        guard let finalLine = closedLines.last,
              let firstUnitIndex = finalLine.unitIndices.first else {
            // No line to roll back: every unit so far was a break marker, and
            // whatever it set is already in `pendingParagraphGap`.
            return self
        }
        var state = CardTextBreakState()
        state.closedLines = Array(closedLines.dropLast())
        state.pendingParagraphGap = finalLine.opensParagraph
        state.nextUnitIndex = firstUnitIndex
        return state
    }
}

/// The reply's units, their measured widths, the lines they pack into, and the
/// paragraphs those lines fold into — every one of them extended rather than
/// rebuilt as the reply streams.
///
/// This exists because the card re-evaluates its body on every streamed
/// character, and the three passes that build that plan are each O(reply
/// length). Measured 2026-09-23 with `sample`, streaming a 5936-character reply
/// at the app's real ~21 evaluations a second: `cardContent` held **22.8% of the
/// main thread**, `makeRenderPlan` alone **10.2%**, and the run was the reason
/// the last lines of a long reply hitch hardest — the work per character grew
/// with the reply, so the whole thing cost O(n²).
///
/// Rebuilding is also unnecessary, and that is the point. Every pass here walks
/// left to right and only ever affects what is at the END of the reply:
/// `CardTextUnitBuilder` closes a unit only when the next character begins a
/// different kind of run, and `CardTextLineBreaker` closes a line only when the
/// next unit overflows it. So a character appended at the end can change the
/// final unit and the final line and nothing else. One streamed character now
/// costs one measurement and one re-pack of the line it landed on — a handful of
/// units, bounded by the width that line was packed into — instead of a pass
/// over the whole reply.
///
/// A reference type held in `@State` rather than a `Layout`'s cache, because the
/// measurement happens in the view body: what SwiftUI does with a layout's cache
/// across a changed layout value is not something correctness may rest on.
nonisolated final class CardRenderPlanCache {

    /// A run of lines that share one `Text` — a paragraph, in other words.
    struct SettledParagraph {
        var text: String
        var opensWithGap: Bool
    }

    private let fontSize: CGFloat
    private let letterSpacing: CGFloat

    init(fontSize: CGFloat, letterSpacing: CGFloat) {
        self.fontSize = fontSize
        self.letterSpacing = letterSpacing
    }

    private(set) var units: [CardTextUnit] = []
    private(set) var lines: [CardTextPackedLine] = []

    private var unitWidths: [CGFloat] = []
    private var breakState = CardTextBreakState()

    /// The paragraphs folded out of the lines a later line has already made
    /// immutable, in reading order.
    private var settledParagraphs: [SettledParagraph] = []

    /// How many of `lines` have been folded into `settledParagraphs`.
    private var foldedLineCount = 0

    /// The text and the line width this plan was built for.
    private var planText = ""
    private var planLineWidth: CGFloat = -1

    /// 每一次文字真的变长时记一个样本：**那一刻一共有多少个 unit**，以及**那一刻的
    /// 时间**。尾巴的**时间**上界就是从这里算出来的 —— 见
    /// `firstUnitArrivedWithin(_:now:)`。
    ///
    /// 为什么需要它：模糊表达的是「这个字刚出现」，那是一个**时间**概念，而原先的
    /// 判据是 `freshTailUnitCount = 5` 个 unit —— 一个**字数**概念。两者只有在文字
    /// 匀速到达时才等价，而这个应用里有两条速率差 5 倍的管线：
    ///
    /// | 管线 | 文字到达 | 5 个字尾巴的实际时长 |
    /// |---|---|---|
    /// | 三段式（DeepSeek 流式） | 实测约 30 字/秒 | 约 0.17 秒 —— 察觉不到 |
    /// | 全双工（模型说话的转写） | 实测约 6.1 字/秒 | **约 0.8 秒 —— 一直糊着** |
    ///
    /// 后者的速率不是缺陷，是物理限制：字幕不可能比它转写的那段话更快。所以错的
    /// 只能是判据。用户 2026-09-25 报的「三段式好了、全双工还是卡」就是这一列。
    ///
    /// 只留最近几十个样本就够：新鲜窗口只有 5 个 unit，它们的到达时间必然落在最后
    /// 几个样本里；更老的 unit 一律当作"早就到了"。
    private var arrivalSamples: [(unitCount: Int, time: TimeInterval)] = []
    private static let maximumArrivalSampleCount = 64

    /// The lines for `text` at `lineWidth`, extending the previous plan when
    /// `text` merely continues the text it was built from.
    @discardableResult
    func plan(for text: String, lineWidth: CGFloat) -> [CardTextPackedLine] {
        guard text != planText || lineWidth != planLineWidth else { return lines }

        // Either invalidation rebuilds everything. A width change leaves every
        // unit alone but invalidates every line — the pack is per width — and
        // with them the paragraphs folded from those lines; anything but an
        // append (a different reply, a settled re-render, a cleared card) can
        // change any unit at all. Both are once-per-card events, so keeping the
        // units across a width change would buy nothing for a second path
        // through this method that has to be right.
        if lineWidth != planLineWidth || !text.hasPrefix(planText) {
            reset()
            planLineWidth = lineWidth
        }

        guard text != planText else { return lines }

        units = CardTextUnitBuilder.units(
            from: text,
            extending: units,
            resumingAfterCharacterCount: planText.count
        )
        // The final unit may have been extended, replaced or newly begun, so it
        // is measured again; no earlier unit's text can have changed.
        measureUnitWidths(from: max(0, units.count - 1))
        breakState = CardTextLineBreaker.breakIntoLines(
            units: units,
            unitWidths: unitWidths,
            lineWidth: lineWidth,
            resumingFrom: breakState.stateBeforeFinalLine
        )
        lines = breakState.closedLines
        planText = text
        recordArrivalSample()
        return lines
    }

    /// 记一次「文字在这一刻长到了这么多 unit」。见 `arrivalSamples`。
    ///
    /// 只在**文字真的变长**时追加：`plan` 已经在入口挡掉了文字没变的调用，所以走
    /// 到这里就说明多了一个 unit 或更多。unit 数相同的那一次不重复记 —— 样本表是
    /// 用来定位"某个 unit 是什么时候到的"，重复的时间戳只会把它撑大。
    private func recordArrivalSample() {
        if let lastSample = arrivalSamples.last, lastSample.unitCount == units.count {
            return
        }
        arrivalSamples.append((units.count, Date().timeIntervalSince1970))
        if arrivalSamples.count > Self.maximumArrivalSampleCount {
            arrivalSamples.removeFirst(arrivalSamples.count - Self.maximumArrivalSampleCount)
        }
    }

    /// 尾巴的**时间**下界：返回「在这段时间内才到达的第一个 unit」的下标。
    ///
    /// 一个 unit 的下标 ≥ 这个值，就说明它是最近 `maximumAge` 秒内出现的，还在
    /// 模糊尾巴里；小于它的都早就到了，应该是清晰的。
    ///
    /// 样本表为空 = 这个卡片从来没有观察到文字增长（历史卡片、重放的回复、
    /// 空的卡片），此时返回 `units.count` —— **没有任何 unit 算"刚到"**，整段直接
    /// 清晰，不靠调用方另外判一次。
    ///
    /// 样本全都比 cutoff 新 = 这一段文字整体就是刚出现的（快流速、或者刚开始流），
    /// 此时返回 0，让 `freshTailUnitCount` 那个字数上界去管 —— 快流速下它才是
    /// 真正起作用的那一条，行为与改动前完全一致。
    func firstUnitArrivedWithin(_ maximumAge: TimeInterval, now: TimeInterval) -> Int {
        guard !arrivalSamples.isEmpty else { return units.count }
        let cutoff = now - maximumAge
        var boundary = 0
        for sample in arrivalSamples {
            if sample.time <= cutoff {
                boundary = sample.unitCount
            } else {
                break
            }
        }
        return boundary
    }

    /// The settled paragraphs, folding in every line the live region has now
    /// left behind.
    ///
    /// A paragraph is append-stable for the same reason a line is — once a later
    /// line exists, this one can never change — so the fold only ever adds. That
    /// matters as much as the incremental pack: this used to re-join every line
    /// of the whole reply into strings on every streamed character.
    ///
    /// - Parameter liveLineCount: how many trailing lines stay in the live
    ///   region and are therefore **not** folded — see
    ///   `AnswerCardView.liveLineRegionLineCount` for why the fold has to stop
    ///   before the writing edge rather than one line short of the end.
    func paragraphs(liveLineCount: Int) -> [SettledParagraph] {
        let lineCountToFold = max(0, lines.count - liveLineCount)
        while foldedLineCount < lineCountToFold {
            foldLine(at: foldedLineCount)
            foldedLineCount += 1
        }
        return settledParagraphs
    }

    /// How many of `lines` have been folded into `settledParagraphs` — and
    /// therefore the index the live region starts at.
    var foldedLineCountValue: Int { foldedLineCount }

    private func foldLine(at lineIndex: Int) {
        let line = lines[lineIndex]
        let lineText = line.unitIndices.map { units[$0].text }.joined()
        // A paragraph gap closes the paragraph in front of it, so the flag
        // belongs to the line that opens the next paragraph.
        if line.opensParagraph || settledParagraphs.isEmpty {
            settledParagraphs.append(SettledParagraph(
                text: lineText,
                opensWithGap: line.opensParagraph
            ))
        } else {
            let lastParagraphIndex = settledParagraphs.count - 1
            settledParagraphs[lastParagraphIndex].text += "\n" + lineText
        }
    }

    private func reset() {
        units = []
        unitWidths = []
        lines = []
        breakState = CardTextBreakState()
        settledParagraphs = []
        foldedLineCount = 0
        planText = ""
        arrivalSamples = []
    }

    /// The measured width of every unit, extended rather than re-measured.
    private func measureUnitWidths(from firstUnitIndexToMeasure: Int) {
        if unitWidths.count > firstUnitIndexToMeasure {
            unitWidths.removeLast(unitWidths.count - firstUnitIndexToMeasure)
        }
        for unitIndex in unitWidths.count..<units.count {
            let unit = units[unitIndex]
            // A line break or a paragraph gap draws nothing: it carries no width,
            // only the structure the line breaker reads.
            unitWidths.append(unit.kind == .content ? unitWidth(of: unit.text) : 0)
        }
    }

    /// How full a packed line is, as a fraction of the width it was packed
    /// against — 0 when the line has nothing in it yet, 1 when it is at the
    /// limit it was broken at.
    ///
    /// This is what makes the card's growth continuous. A line of text is one
    /// line tall no matter whether it holds one character or twenty-seven, so
    /// without this the card's height can only change in whole lines. The
    /// fraction is the one continuous quantity available, and it is exact rather
    /// than estimated: it is the same measured unit widths the line breaker
    /// packed with, summed over the units it actually put on this line.
    func fillFraction(ofLine line: CardTextPackedLine, lineWidth: CGFloat) -> CGFloat {
        guard lineWidth > 0 else { return 0 }
        var packedWidth: CGFloat = 0
        for unitIndex in line.unitIndices where unitIndex < unitWidths.count {
            packedWidth += unitWidths[unitIndex]
        }
        return min(1, max(0, packedWidth / lineWidth))
    }

    /// One unit's width, measured with the font and letter spacing the card
    /// actually renders with.
    ///
    /// CoreText rather than SwiftUI's own `sizeThatFits`, which cannot be called
    /// outside a layout pass and so is not available in a view body. Measured
    /// 2026-09-23 against the same units measured inside a `Layout` — what the
    /// previous flow layout used — the two agree to within 0.45 pt across a real
    /// 1482-character reply, which is why `lineFitSafetyMargin` exists rather
    /// than trusting them to agree exactly.
    private func unitWidth(of unitText: String) -> CGFloat {
        guard !unitText.isEmpty else { return 0 }
        let attributedUnit = NSAttributedString(
            string: unitText,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .kern: letterSpacing,
            ]
        )
        let unitLine = CTLineCreateWithAttributedString(attributedUnit)
        return CGFloat(CTLineGetTypographicBounds(unitLine, nil, nil, nil))
    }
}

/// Reports the width the card's text is actually given, so the line breaker can
/// break for the width in play instead of an assumed one — the three call sites
/// frame the card at 300 pt, at 340 pt, and at their own column width.
struct CardTextColumnWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The card

struct AnswerCardView: View {

    let text: String
    /// True only for the reply currently streaming in — the blur-focus tail
    /// exists only while text is still arriving. A finished reply (history or
    /// the settled stream) shows every unit fully sharp.
    let isStreaming: Bool
    let style: AnswerCardStyle

    /// The reply's units, widths, lines and settled paragraphs so far, extended
    /// across the streamed updates — see `CardRenderPlanCache` for why one
    /// streamed character must not cost a pass over the whole reply.
    @State private var renderPlanCache = CardRenderPlanCache(
        fontSize: AnswerCardView.fontSize,
        letterSpacing: AnswerCardView.letterSpacing
    )

    /// The width the card's text is actually given, reported back by the
    /// invisible probe in `body`. The line breaker breaks for the width in play
    /// rather than an assumed one, because the three call sites frame the card
    /// differently (300 pt in the settings preview, 340 pt at the cursor, and
    /// whatever the notch sheet's column measures).
    ///
    /// 0 means "no layout pass has reported a width yet", which is also why the
    /// card renders its plain text for that one frame — see `cardContent`.
    @State private var textColumnWidth: CGFloat = 0

    /// How many trailing units stay blurred while streaming (the reference's
    /// settle rule: the unit five positions back is settled to sharp).
    ///
    /// **这是一个字数上界，不是时长。** 尾巴真正由时间决定 —— 见
    /// `freshTailMaximumAge` 和 `CardRenderPlanCache.firstUnitArrivedWithin`。
    private static let freshTailUnitCount = 5

    /// 一个 unit 最多模糊多久 —— 尾巴的**时间**上界。
    ///
    /// 取值就是它自己那次淡出动画的时长（`settleAnimationDuration`），这不是巧合
    /// 而是定义：**一个字"该模糊"的时间，就是它"变清晰"所需要的时间**。比这更久，
    /// 它已经清晰了却还被画成模糊；比这更短，动画还没走完就被下一帧打断。
    ///
    /// 为什么必须是时间而不是字数：模糊的含义是「这个字刚出现」，那是时间。全双工
    /// 那条路的文字速率由模型说话速度决定（实测 6.1 字/秒），5 个字于是要糊
    /// **0.8 秒**，而三段式同样是 5 个字只糊 0.17 秒 —— 用户报的「三段式好了、
    /// 全双工还是卡」，差的就是这 5 倍。
    ///
    /// 两个上界取**较小者**（`firstFreshIndex` 取 max）：快流速下时间上界放在 9 个字
    /// 以外，字数上界（5）才是 binding 的那条，所以**三段式的观感不变** —— 这一点是
    /// 有意的，用户刚确认过三段式已经对了。
    private static let freshTailMaximumAge: TimeInterval = settleAnimationDuration

    /// How many trailing lines are drawn as the live region instead of being
    /// folded into a settled paragraph.
    ///
    /// **Two, and it is exactly two — this used to be one, and that one is what
    /// the user kept reporting as 「每一句回复内容的最后几个字，总是会卡一下」.**
    ///
    /// The live region is the only place that can draw a blurred tail, because a
    /// settled paragraph is a single plain `Text` with no blur modifier on it.
    /// The tail is measured from the END OF THE REPLY (`unitCount − 1 − unitIndex`),
    /// so at the instant a line wraps its last few units are still inside the
    /// 5-unit window — and with a one-line live region that line had *already*
    /// been folded, so those characters were redrawn sharp in the same frame,
    /// with no fade. One such snap at the right margin of the row above the
    /// writing edge, on every single line of every reply.
    ///
    /// Keeping the trailing **two** lines live removes it exactly, with no new
    /// predicate to get wrong: the fresh window is five units, every line holds
    /// at least one unit, so five units can never span more than two lines. A
    /// second line's tail is inside the window only while the last line is still
    /// shorter than five units — which is precisely the case that used to snap.
    /// Every line that leaves the region has therefore already settled, and
    /// leaving it is invisible.
    private static let liveLineRegionLineCount = 2
    private static let freshBlurRadius: CGFloat = 2.6
    private static let freshOpacity: Double = 0.2
    private static let settleAnimationDuration: TimeInterval = 0.3

    /// Reference spec §3.1–3.4: corner 10, border 1.5, padding 10px 12px,
    /// font 13.5, letter-spacing .02em, on the reference's ~22pt line pitch.
    private static let cardCornerRadius: CGFloat = 10
    private static let cardBorderWidth: CGFloat = 1.5
    private static let fontSize: CGFloat = 13.5
    private static let letterSpacing: CGFloat = 13.5 * 0.02

    /// The gap between two rendered lines that share a paragraph. `Text` reports
    /// its own line pitch as font line height + this, so it is also exactly the
    /// gap the block arithmetic in `paragraphBlocks` has to leave.
    private static let lineSpacing: CGFloat = 5

    /// The height one rendered line occupies: the font's own line height plus
    /// `lineSpacing`, i.e. exactly how far the next line starts below this one.
    ///
    /// This is the unit the live-line buffer trades in — see `cardContent`. The
    /// buffer holds a fraction of one pitch in reserve and pays it out as the
    /// line fills, so a line wrapping spends exactly one whole pitch: the reserve
    /// empties by one pitch while the text grows by one line, and the card's
    /// bottom edge does not move at the wrap at all.
    private static let linePitch: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize)
        return font.ascender - font.descender + font.leading + lineSpacing
    }()

    /// The reference's 14pt paragraph pause, added on top of `lineSpacing` at a
    /// 「\n\n」 boundary — matching the flow layout's old `paragraphGapSpacing`.
    private static let paragraphGapSpacing: CGFloat = 14

    /// Slack in the fit test, because the line breaker's CoreText measurement and
    /// the width `Text` lays out at are two different engines: measured
    /// 2026-09-23 they agree to within 0.45 pt per unit, but a line packed to
    /// within a fraction of a point of the limit is a line that can come out one
    /// unit too wide and wrap where the breaker said it would not — which would
    /// put the rendered text permanently one line taller than the card computed.
    /// A point of slack costs nothing (the last unit of a line rarely lands
    /// within a point of the edge) and makes that impossible by construction.
    private static let lineFitSafetyMargin: CGFloat = 1

    var body: some View {
        let theme = AnswerCardTheme(style: style)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        return cardContent(reduceMotion: reduceMotion)
            // 宽度由「容器给了多少」决定，不由「内容有多宽」决定。
            //
            // 这是 2026-09-23 用户报的「第一行从 10 个字变成 11 个、再变成 12 个」
            // 的根因修复。原来的卡片是被内容撑开的：短回复窄、文字长一点就宽一点，
            // 而那把宽度尺子量出来的数字又被喂回断行器当断行宽度 —— 于是一旦卡片
            // 变宽，断行宽度跟着变（实测 314 → 315），**整篇回复每一行的断点全部
            // 重算**，第一行就多吃进一个字。实测两轮，每次都一模一样：
            //   t=10.3  0.0 -> 315.0 -> 316.0
            //   t=55.4  0.0 -> 315.0 -> 316.0
            // 而且宽度一变，`CardRenderPlanCache` 的增量缓存整块作废、从头重排。
            //
            // 撑满之后，文字列宽度在第一次布局就是定值，之后再也不会变：断行只算
            // 一次，第一行不动，缓存永不失效 —— 也就是用户要的「最开始宽度就固定，
            // 然后从上到下展开」。代价是短回答也会占满整张卡片的宽度，这是这个
            // 取舍必然的一面。
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: Self.fontSize))
            .kerning(Self.letterSpacing)
            .foregroundColor(theme.textColor)
            // Reports the width the text is given, so the line breaker can break
            // for the width actually in play instead of an assumed one — the
            // three call sites frame this card at 300 pt, at 340 pt, and at
            // whatever the notch sheet's column measures. It sits inside the
            // padding, so it measures the text column itself: exactly the width
            // `Text` lays out in. A preference rather than a `GeometryReader` on
            // purpose — a reader would add a layout container of its own, and
            // worse, would feed its own measurement back into the content it is
            // measuring.
            .background(
                GeometryReader { textColumnGeometry in
                    Color.clear.preference(
                        key: CardTextColumnWidthKey.self,
                        value: textColumnGeometry.size.width
                    )
                }
            )
            .onPreferenceChange(CardTextColumnWidthKey.self) { measuredTextColumnWidth in
                // Guarded so the state write happens once per real change: this
                // closure runs on every streamed character, and an unconditional
                // write would re-enter the layout each time.
                if abs(measuredTextColumnWidth - textColumnWidth) > 0.5 {
                    textColumnWidth = measuredTextColumnWidth
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(cardBackground(theme: theme))
            .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: Self.cardBorderWidth)
            )
    }

    /// A run of lines that share one `Text` — a paragraph, in other words — and
    /// the space to leave below it before whatever is drawn next.
    private struct CardTextParagraphBlock {
        var text: String
        var spaceBelow: CGFloat
    }

    /// The card's text, rendered from ONE set of lines in both states.
    ///
    /// While a reply streams, the last line is the only one still changing, so
    /// it is rendered per unit — that is where the blur-focus tail lives — and
    /// every line above it is folded into one `Text` per paragraph. That is the
    /// whole point of this rewrite. The card used to put one `Text` per unit
    /// through SwiftUI's layout on every streamed character (a 1482-character
    /// reply is 1017 units), and measured 2026-09-23 with `sample` that cost
    /// **88% of the main thread and ~117% of one CPU core** against a 12% idle —
    /// and the settled card alone, with nothing streaming at all, still sat at
    /// ~32%.
    ///
    /// When the reply settles, the growing line is folded into its paragraph and
    /// the blur is dropped: the same lines, the same breaks, the same heights.
    /// Nothing moves at all — including the buffer below the last line, which is
    /// read from `lines` in both states rather than falling to zero once the
    /// reply stops streaming. See `liveLineFill`.
    @ViewBuilder
    private func cardContent(reduceMotion: Bool) -> some View {
        // The width is measured, not assumed (see `textColumnWidth`), and there
        // is no width to break against until the first layout pass reports one.
        // Packing against a guess is exactly how a line ends up wider than the
        // space it is drawn in, so that one frame renders the plain text instead.
        if textColumnWidth > 0 {
            let lineWidth = max(0, textColumnWidth - Self.lineFitSafetyMargin)
            let lines = renderPlanCache.plan(for: text, lineWidth: lineWidth)
            // **实时区那几行永远由同一个视图画，流式与定稿都一样。**
            //
            // 原先 `settlingFinalLine: !isStreaming` 在回复结束的那一刻把最后一行也
            // 折进段落里，同时实时行那条 `if isStreaming` 又被拆掉 —— 于是末尾那 5 个
            // 还模糊着的字**换了一个视图**去画，模糊瞬间消失、没有任何过渡。用户
            // 2026-09-25：「每一句回复内容的最后几个字，总是会卡一下」（三段式同样）。
            //
            // 两种状态用**同一个视图**画，`isFresh` 就是在同一个视图里翻转的，它自己
            // 那个 `.animation(value: isFresh)` 会把模糊**淡出**（0.3 秒），不再有跳变；
            // 而且断行、行数、行距三个量两边完全一致，所以切换时**版面一动不动**。
            //
            // 2026-09-25 再次修正：实时区是**两行**不是一行，理由见
            // `liveLineRegionLineCount` —— 一行时，换行那一刻刚闭合的那一行已经
            // 被折进段落、用没有模糊的 `Text` 重画，它末尾那几个还在新鲜窗口里的字
            // 于是**每一行都跳一次**。两行正好覆盖住「5 个 unit 可能落在哪几行」。
            let settledParagraphs = renderPlanCache.paragraphs(
                liveLineCount: Self.liveLineRegionLineCount
            )
            // The lines the fold has not taken — the writing edge and, while the
            // last line is still under five units, the one it just wrapped off.
            // See `liveLineRegionLineCount`: a line only leaves this region once
            // its tail has settled, so nothing here is ever redrawn sharp by a
            // fold that arrives too early.
            let liveLines = Array(
                lines.dropFirst(renderPlanCache.foldedLineCountValue)
            )
            let hasLiveLine = !liveLines.isEmpty
            // 模糊尾巴的**时间**上界 —— 下标 ≥ 它的 unit 是最近
            // `freshTailMaximumAge` 秒内才到的，才该模糊。字数上界由
            // `liveLineView` 自己那一刀负责（它同时决定谁单独成视图），两个判据
            // 分开是有意的，理由见 `liveLineView`。
            //
            // 快流速下（三段式，实测约 30 字/秒）这个上界落在 9 个字以外，于是全部
            // 尾巴都在窗口内，行为与改动前逐帧一致；慢流速下（全双工，实测
            // 6.1 字/秒）它才是 binding 的那条。详见 `freshTailMaximumAge`。
            let firstFreshUnitIndexByElapsedTime = renderPlanCache.firstUnitArrivedWithin(
                Self.freshTailMaximumAge,
                now: Date().timeIntervalSince1970
            )
            let blocks = paragraphBlocks(
                from: settledParagraphs,
                hasLiveLine: hasLiveLine
            )
            // How full the reply's LAST line is — read from `lines` whether the
            // card is streaming or settled, because it is the same line either
            // way and the buffer must not change value when the reply finishes.
            //
            // That is what stops the card shrinking at the end. A settled card
            // carries its last line inside the paragraph rather than as its own
            // view, but that paragraph grew by exactly the one line the live view
            // used to occupy — the text below the buffer is the same height in
            // both states — so holding the buffer steady holds the whole card
            // steady. Letting it fall to zero here (as it first did) returns up
            // to a full pitch in one frame, which is the bottom edge springing
            // back up that the card was reported doing 2026-09-23.
            let liveLineFill: CGFloat = lines.last.map {
                renderPlanCache.fillFraction(ofLine: $0, lineWidth: lineWidth)
            } ?? 0

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    Text(block.text)
                        .lineSpacing(Self.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                    if block.spaceBelow > 0 {
                        Color.clear.frame(height: block.spaceBelow)
                    }
                }
                liveLineRegion(
                    lines: liveLines,
                    units: renderPlanCache.units,
                    firstFreshUnitIndexByElapsedTime: firstFreshUnitIndexByElapsedTime,
                    reduceMotion: reduceMotion
                )
                // The live-line buffer: blank space held below the reply's last
                // line, worth one line pitch when that line is empty and nothing
                // when it is full. It is drawn for a settled card too — see
                // `liveLineFill` above — which is what keeps the card's bottom
                // edge from moving when the reply ends.
                //
                // Without it the card can only grow in whole lines, because a line
                // of text is one line tall whether it holds one character or
                // twenty-seven — so every twenty-seven characters the bottom edge
                // jumps a full 22.5 pt at once, and a reader sees a staircase
                // rather than a card sliding open. The buffer is the continuous
                // quantity the layout otherwise lacks: it pays the line's own fill
                // fraction back out as the line fills, so the bottom edge tracks
                // the text character by character instead (measured 2026-09-23:
                // 0.83 pt per character rather than a 22.5 pt step per line).
                //
                // A FIXED reserve does not work and is worth understanding before
                // changing this. Held at a constant, it does nothing at all while a
                // line fills — the line's height is fixed too, so the bottom edge
                // would not move for twenty-seven characters — and then still jumps
                // a whole pitch when the line finally wraps. The reserve has to
                // swing over exactly one pitch for the wrap to be free: at the wrap
                // the fill fraction falls from ~1 to ~0 while the text grows by
                // exactly one line, and the two cancel.
                //
                // The cost, accepted deliberately: the buffer still holds whatever
                // the last line's fill fraction was, so a reply that ends mid-line
                // keeps a little more room below it than one that ends flush. That
                // is the extra space the card is given in exchange for never
                // springing back, and it is bounded by one line pitch.
                Color.clear
                    .frame(height: liveLineFill * Self.linePitch)
            }
        } else {
            Text(text)
                .lineSpacing(Self.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Folds consecutive lines into paragraphs — one `Text` each — and works out
    /// the space each one leaves below itself.
    ///
    /// The arithmetic is exact, not tuned. An n-line `Text` with line spacing `s`
    /// measures `n·LH + (n−1)·s`, so the line after it must start at
    /// `n·(LH + s)` — exactly `s` below that `Text`'s own bottom edge. The gap
    /// between two blocks is therefore the line spacing itself, and a paragraph
    /// boundary adds the reference's paragraph pause on top of it. Being a point
    /// out here would show up as the pitch changing at every paragraph.
    ///
    /// The paragraphs themselves come from the cache already folded, so this is
    /// a walk over the paragraphs (a handful) rather than a re-join of every
    /// line in the reply (which is what it used to be, on every character).
    private func paragraphBlocks(
        from settledParagraphs: [CardRenderPlanCache.SettledParagraph],
        hasLiveLine: Bool
    ) -> [CardTextParagraphBlock] {
        settledParagraphs.enumerated().map { paragraphIndex, paragraph in
            let isLastParagraph = paragraphIndex == settledParagraphs.count - 1
            let spaceBelow: CGFloat
            if isLastParagraph {
                // Only the still-growing line follows a final paragraph, and it
                // sits one line pitch below. With the reply finished nothing
                // follows at all, and a trailing gap would only make the card
                // taller than its own text.
                spaceBelow = hasLiveLine ? Self.lineSpacing : 0
            } else {
                let nextParagraphOpensWithGap = settledParagraphs[paragraphIndex + 1].opensWithGap
                spaceBelow = Self.lineSpacing
                    + (nextParagraphOpensWithGap ? Self.paragraphGapSpacing : 0)
            }
            return CardTextParagraphBlock(
                text: paragraph.text,
                spaceBelow: spaceBelow
            )
        }
    }

    /// The lines still being written — the writing edge, plus the line it wrapped
    /// off while that line's own tail is still inside the fresh window.
    ///
    /// Two lines is not a tuning choice; it is the exact bound. `isFresh` counts
    /// from the end of the reply and covers five units, and a line holds at least
    /// one unit, so five units cannot span more than two lines. Drawing those two
    /// here (instead of folding all but the last) is what stops the fold from
    /// redrawing a just-wrapped line's blurred tail as sharp text with no fade —
    /// see `liveLineRegionLineCount`.
    ///
    /// The inter-line gap is `lineSpacing`, the same one the settled paragraphs
    /// use, so a line crossing out of this region into a paragraph does not move:
    /// the paragraph's own `spaceBelow` accounts for the gap either way.
    @ViewBuilder
    private func liveLineRegion(
        lines: [CardTextPackedLine],
        units: [CardTextUnit],
        firstFreshUnitIndexByElapsedTime: Int,
        reduceMotion: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                liveLineView(
                    line: line,
                    units: units,
                    firstFreshUnitIndexByElapsedTime: firstFreshUnitIndexByElapsedTime,
                    reduceMotion: reduceMotion
                )
            }
        }
    }

    /// The one line still being written: a small `Text` per unit, so the last
    /// `freshTailUnitCount` of them can stay blurred and translucent — SwiftUI
    /// cannot blur part of a `Text`. This is the only place per-unit views
    /// survive, and it is the live region (at most two lines, about 25 views
    /// each) rather than every unit in the reply.
    ///
    /// **只有尾巴那几个 unit 需要各自的 `Text`，前面的合并成一个。**
    ///
    /// 原先这一行把**整行每个 unit** 都做成一个 `Text` 塞进 `HStack`（一行最多
    /// 33 个，实测）。`HStack` 不会换行 —— 宽度不够时它**压缩**子视图，而每个
    /// `Text` 被压窄之后会在自己内部换行，于是那一行渲染出来成了「一个 unit 一行」
    /// 的碎片。用户 2026-09-25 报的「全双工回复乱码」正是这个形状（截图里
    /// 「止 / 宣告 / 纪念 / 大 / ** / 八 / 代表性 / 防御」逐行排列）。
    ///
    /// 断行器本身是好的：实测一行 33 个 unit、首行填充 98%，没有任何一行只剩一个
    /// unit —— 碎的只有渲染。而模糊只发生在末尾 `freshTailUnitCount` 个 unit 上，
    /// 所以前面那一段完全可以是一个 `Text`：既保住了模糊尾巴，又把这一行从
    /// 33 个子视图降到 6 个，压缩换行在结构上不可能再发生。
    /// - Parameter firstFreshUnitIndexByElapsedTime: 时间上界 —— 下标 ≥ 它的 unit 是
    ///   最近 `freshTailMaximumAge` 秒内才到的，才该模糊。它只改变**模糊与否**，
    ///   不改变哪些 unit 单独成视图（那是字数上界的事），理由见下。
    private func liveLineView(
        line: CardTextPackedLine,
        units: [CardTextUnit],
        firstFreshUnitIndexByElapsedTime: Int,
        reduceMotion: Bool
    ) -> some View {
        let unitCount = units.count
        // 末尾那几个单独成视图；其余合并。
        //
        // **这一刀仍然按字数切，不按时间切**，而这不是遗漏 —— 恰恰相反：单独成视图
        // 的那个集合，就是「模糊状态可能发生变化」的那个集合，`.animation(value: isFresh)`
        // 只有在这个视图还活着的时候才会跑。按字数切（固定 5 个）保证一个 unit 从
        // "还在模糊"到"已经清晰"的那一帧，视图一定还在，淡出因此真的会播。
        //
        // 时间上界只用来决定**糊不糊**：慢流速下（全双工，实测 6.1 字/秒）时间上界
        // 落在字数上界之内，于是最后几个 unit 仍是独立视图、但已经不糊了 —— 看上去
        // 与合并进前面那段文字完全一样，却让它们有了一个能播动画的落点。
        let firstFreshIndex = max(0, unitCount - Self.freshTailUnitCount)
        let sharpUnitIndices = line.unitIndices.filter { $0 < firstFreshIndex }
        let freshUnitIndices = line.unitIndices.filter { $0 >= firstFreshIndex }
        let sharpText = sharpUnitIndices.map { units[$0].text }.joined()

        return HStack(alignment: .top, spacing: 0) {
            if !sharpText.isEmpty {
                // 已经不再模糊的那一段：一个 `Text`，与上面段落同一套字体与字距。
                Text(sharpText)
                    .blur(radius: 0)
                    .opacity(1)
            }
            ForEach(freshUnitIndices, id: \.self) { unitIndex in
                // 模糊的**两个**判据，缺一不可：
                //
                //  · 还在流（`isStreaming`）：历史卡片、定稿的回复一律清晰。
                //  · 是**刚到的**（`unitIndex >= firstFreshUnitIndexByElapsedTime`）：
                //    这就是时间上界。全双工那条路文字速率由模型说话速度决定，恒定的
                //    5 个字要糊 0.8 秒，这个条件把它压回 0.3 秒 —— 见
                //    `freshTailMaximumAge`。
                //
                // 原先这里是 `positionsFromEnd < freshTailUnitCount`，与下面
                // `freshUnitIndices` 的判据是同一个集合，于是 unit 一离开 ForEach
                // 就换了个视图重画，`.animation` 根本没机会跑 —— 是「跳」不是「淡」。
                // 现在两个判据分开，时间先到的那一批**在同一个视图里**翻成清晰，
                // 动画于是真的播出来。
                let isFresh = isStreaming && !reduceMotion
                    && unitIndex >= firstFreshUnitIndexByElapsedTime
                Text(units[unitIndex].text)
                    .blur(radius: isFresh ? Self.freshBlurRadius : 0)
                    .opacity(isFresh ? Self.freshOpacity : 1)
                    .animation(.easeInOut(duration: Self.settleAnimationDuration), value: isFresh)
            }
        }
        // **不让这个 HStack 被压缩。**
        //
        // `HStack` 在放不下时**压缩子视图**，而不是溢出 —— 被压的 `Text` 会在自己
        // 内部折行，于是尾巴那几个字会**重新排一次版**：这正是用户报的
        // 「卡片最后几个字还是卡」在渲染侧的形状（审计也把这一条列为已知弱点）。
        //
        // 这一行的宽度是断行器**按同一个宽度算出来的**（`lineWidth` 还留了 1pt 余量），
        // 所以取自然宽度既不会真的溢出、也不会被压。`fixedSize` 只放开横轴：
        // 纵轴仍按版面走，行高不受影响。
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The card's fill: the theme color, plus the paper theme's ruled lines
    /// — one very faint horizontal line every 22pt, drawn from the card's
    /// top edge the way the reference's repeating-linear-gradient does.
    @ViewBuilder
    private func cardBackground(theme: AnswerCardTheme) -> some View {
        if theme.drawsRuledLines {
            ZStack {
                theme.backgroundColor
                Canvas { context, size in
                    var lineY = AnswerCardTheme.ruledLineSpacing
                    while lineY < size.height {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: lineY))
                        path.addLine(to: CGPoint(x: size.width, y: lineY))
                        context.stroke(
                            path,
                            with: .color(AnswerCardTheme.ruledLineColor),
                            lineWidth: 1
                        )
                        lineY += AnswerCardTheme.ruledLineSpacing
                    }
                }
            }
        } else {
            theme.backgroundColor
        }
    }
}
