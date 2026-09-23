//
//  AnswerCardView.swift
//  leanring-buddy
//
//  The assistant reply's card, in one of three themes (blue / black / paper)
//  chosen in 对话与记忆 → 卡片样式. Ported from the user's reference spec
//  (「clip 卡片样式」, 实现说明.md): a 10pt-corner card with a 1.5pt border,
//  tight 10/12 padding, 13.5pt text on a ~22pt line pitch — and the spec's
//  signature text animation, the blur-focus stream: every new character
//  enters blurred (blur 2.6) and half-transparent (opacity 0.2), and settles
//  to fully sharp with a 0.3s ease once five more units have arrived behind
//  it, leaving a ~5-unit blurred tail at the writing edge.
//
//  SwiftUI cannot blur individual characters inside one Text, so the text is
//  split into units (one unit per CJK character, contiguous Latin/digit runs
//  kept whole so English words never wrap mid-word) and each unit is its own
//  small Text inside a custom flow Layout. Newlines become layout break
//  markers (carried as custom LayoutValueKey values, because Layout sees
//  only subviews, not content): 「\n\n」 opens a 14pt paragraph gap, a bare
//  「\n」 just ends the row.
//
//  A finished reply renders as one plain Text — a 600-character reply would
//  otherwise be 600 Text views in a ScrollView that is rebuilt on every
//  session switch. Only the live stream needs per-unit views.
//
//  系统开启「减弱动态效果」时全部直接清晰显示，不做任何动画
//  (the reference's prefers-reduced-motion degradation).
//

import SwiftUI
import AppKit

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
            self.backgroundColor = .black
            self.borderColor = Color.white.opacity(0.16)
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
enum CardTextUnitKind {
    case content
    case lineBreak
    case paragraphGap
}

struct CardTextUnit: Identifiable {
    let id: Int
    let text: String
    let kind: CardTextUnitKind
}

enum CardTextUnitBuilder {

    /// Split reply text into rendering units. `"\n\n"` becomes a paragraph
    /// gap (a 14pt vertical pause in the reference timeline), a bare `"\n"`
    /// a line break.
    static func units(from text: String) -> [CardTextUnit] {
        var units: [CardTextUnit] = []
        var nextID = 0
        let characters = Array(text)
        var index = 0

        func appendUnit(_ text: String, _ kind: CardTextUnitKind) {
            units.append(CardTextUnit(id: nextID, text: text, kind: kind))
            nextID += 1
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\n" {
                if index + 1 < characters.count, characters[index + 1] == "\n" {
                    appendUnit("", .paragraphGap)
                    index += 2
                } else {
                    appendUnit("", .lineBreak)
                    index += 1
                }
                continue
            }

            if CardTextUnitBuilder.isLatinWordCharacter(character) {
                var word = ""
                while index < characters.count,
                      CardTextUnitBuilder.isLatinWordCharacter(characters[index]) {
                    word.append(characters[index])
                    index += 1
                }
                appendUnit(word, .content)
                continue
            }

            appendUnit(String(character), .content)
            index += 1
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

// MARK: - Flow layout

/// How a subview ends the current flow row. Carried per-subview through
/// `CardTextFlowLayout` via a custom LayoutValueKey — the layout cannot see
/// view content, only these values. `nonisolated` because the layout reads
/// them from nonisolated positions (the LayoutSubviews subscript).
nonisolated enum CardTextBreakKind {
    case none
    case lineBreak
    case paragraphGap
}

private nonisolated struct CardTextBreakKey: LayoutValueKey {
    static let defaultValue = CardTextBreakKind.none
}

extension View {
    /// Marks this subview as ending the current row, optionally opening a
    /// paragraph gap before the next row.
    func cardTextBreak(_ kind: CardTextBreakKind) -> some View {
        layoutValue(key: CardTextBreakKey.self, value: kind)
    }
}

/// The per-unit text layout: wraps units into rows like CSS inline text,
/// honors the break markers, keeps a 22pt line pitch (13.5pt font + 5pt row
/// spacing ≈ the reference's line-height 1.62), and — because
/// `sizeThatFits` reports the widest row actually used rather than the
/// proposal — lets the card hug a short reply and cap at `maxRowWidth` once
/// the text is long enough to wrap.
struct CardTextFlowLayout: Layout {

    /// Vertical space between rows. With the 13.5pt font this lands the
    /// ~22pt line pitch the reference sets (13.5 × 1.62 ≈ 21.9).
    var rowSpacing: CGFloat = 5
    /// Extra vertical space before the row after a 「\n\n」 (the reference's
    /// 14px paragraph gap).
    var paragraphGapSpacing: CGFloat = 14
    /// The row-width ceiling when the parent proposes more (or nothing).
    var maxRowWidth: CGFloat = 460

    struct Row {
        var unitIndices: [Int]
        var width: CGFloat
        var height: CGFloat
        /// Extra vertical space this row demands ABOVE itself (the paragraph
        /// gap opened by the break before it).
        var topGap: CGFloat
    }

    struct Cache {
        var rows: [Row] = []
        var proposalWidth: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    /// Rows for this proposal. An oversized single unit (wider than the
    /// available width) still gets its own row at full width — CSS behaves
    /// the same way for an unbreakable word.
    private func computeRows(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> [Row] {
        let proposedWidth = proposal.width
        let availableWidth = min(proposedWidth ?? maxRowWidth, maxRowWidth)

        var rows: [Row] = []
        var currentIndices: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var pendingTopGap: CGFloat = 0

        func closeRow() {
            // An empty row is skipped rather than appended: 「text\n\nmore」
            // produces a lineBreak followed by a paragraphGap, and closing
            // the empty row between them would double the gap; a reply that
            // ends with 「\n」 must not gain a phantom blank line's height.
            guard !currentIndices.isEmpty else { return }
            rows.append(Row(
                unitIndices: currentIndices,
                width: currentWidth,
                height: currentHeight,
                topGap: pendingTopGap
            ))
            currentIndices = []
            currentWidth = 0
            currentHeight = 0
            pendingTopGap = 0
        }

        for (index, subview) in subviews.enumerated() {
            let breakKind = subview[CardTextBreakKey.self]

            if breakKind != .none {
                closeRow()
                if breakKind == .paragraphGap {
                    pendingTopGap = paragraphGapSpacing
                }
                continue
            }

            let unitSize = subview.sizeThatFits(.unspecified)

            let needsWrap = currentWidth > 0 && currentWidth + unitSize.width > availableWidth
            if needsWrap {
                closeRow()
            }

            currentIndices.append(index)
            currentWidth += unitSize.width
            currentHeight = max(currentHeight, unitSize.height)
        }

        closeRow()

        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        cache.rows = rows
        cache.proposalWidth = proposal.width

        let usedWidth = rows.map(\.width).max() ?? 0
        let totalHeight = rows.reduce(0) { $0 + $1.topGap + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        return CGSize(width: usedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        // sizeThatFits always runs before placeSubviews in a layout pass, so
        // the cache holds this pass's rows — but recompute defensively rather
        // than trust call ordering.
        let rows = computeRows(proposal: proposal, subviews: subviews)

        var yOffset = bounds.minY
        for row in rows {
            yOffset += row.topGap
            var xOffset = bounds.minX
            for unitIndex in row.unitIndices {
                let unitSize = subviews[unitIndex].sizeThatFits(.unspecified)
                subviews[unitIndex].place(
                    at: CGPoint(x: xOffset, y: yOffset),
                    proposal: .unspecified
                )
                xOffset += unitSize.width
            }
            yOffset += row.height + rowSpacing
        }
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

    /// How many trailing units stay blurred while streaming (the reference's
    /// settle rule: the unit five positions back is settled to sharp).
    private static let freshTailUnitCount = 5
    private static let freshBlurRadius: CGFloat = 2.6
    private static let freshOpacity: Double = 0.2
    private static let settleAnimationDuration: TimeInterval = 0.3

    /// Reference spec §3.1–3.4: corner 10, border 1.5, padding 10px 12px,
    /// font 13.5, letter-spacing .02em.
    private static let cardCornerRadius: CGFloat = 10
    private static let cardBorderWidth: CGFloat = 1.5
    private static let fontSize: CGFloat = 13.5
    private static let letterSpacing: CGFloat = 13.5 * 0.02

    var body: some View {
        let theme = AnswerCardTheme(style: style)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        cardContent(reduceMotion: reduceMotion)
            .font(.system(size: Self.fontSize))
            .kerning(Self.letterSpacing)
            .foregroundColor(theme.textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(cardBackground(theme: theme))
            .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: Self.cardBorderWidth)
            )
    }

    @ViewBuilder
    private func cardContent(reduceMotion: Bool) -> some View {
        if isStreaming && !reduceMotion {
            streamingUnitsView
        } else {
            // A finished reply is one Text — per-unit views would put
            // hundreds of Texts into a ScrollView rebuilt on every switch.
            // The line spacing matches the flow layout's 22pt pitch.
            Text(text)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The live stream: one small Text per unit, the last `freshTailUnitCount`
    /// of them blurred and translucent. Each unit animates its own blur and
    /// opacity over the settle duration when the tail moves past it; a unit
    /// that just appeared enters in its blurred state with no transition,
    /// which is exactly the reference's per-character entrance.
    private var streamingUnitsView: some View {
        let units = CardTextUnitBuilder.units(from: text)
        let unitCount = units.count

        return CardTextFlowLayout {
            ForEach(units) { unit in
                switch unit.kind {
                case .content:
                    let positionsFromEnd = unitCount - 1 - unit.id
                    let isFresh = positionsFromEnd < Self.freshTailUnitCount
                    Text(unit.text)
                        .blur(radius: isFresh ? Self.freshBlurRadius : 0)
                        .opacity(isFresh ? Self.freshOpacity : 1)
                        .animation(.easeInOut(duration: Self.settleAnimationDuration), value: isFresh)
                case .lineBreak:
                    Color.clear
                        .frame(width: 0, height: 0)
                        .cardTextBreak(.lineBreak)
                case .paragraphGap:
                    Color.clear
                        .frame(width: 0, height: 0)
                        .cardTextBreak(.paragraphGap)
                }
            }
        }
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
