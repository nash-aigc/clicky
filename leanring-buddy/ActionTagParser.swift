//
//  ActionTagParser.swift
//  leanring-buddy
//
//  Parses the "action tags" a model is allowed to put at the end of its reply —
//  [POINT:…], [CLICK:…], [SCROLL:…], [TYPE:…], [SELECT:…], [PRESS:…], [OPEN:…],
//  [WAIT:…], [AX_TREE].
//
//  Pointing lives in this file too, but it is deliberately kept out of the
//  returned `actions` list. Pointing only moves the blue cursor; everything in
//  `actions` changes the user's actual machine. Keeping the two apart means the
//  code that executes actions can never accidentally run a point, and the
//  setting that turns pointing off cannot turn acting off along with it.
//
//  This is the single place either tag family is parsed. `CompanionManager`'s
//  older point-only parser is now a thin adapter over `parse(from:)` rather than
//  a second regex, because two regexes for one tag would eventually disagree.
//

import CoreGraphics
import Foundation

/// A coordinate the model reported, together with the optional element name and
/// the screen it belongs to.
///
/// `normalizedCoordinate` is on the model's **0–1000 grid**, not in screenshot
/// pixels and not in screen points. The name says so on purpose: a normalized
/// value and a plausible pixel value look identical, so mixing them up fails
/// silently rather than crashing — the cursor simply lands somewhere else. See
/// `CompanionManager.screenshotPixelCoordinate(fromNormalizedPoint:...)` for the
/// documented conversion and why it exists.
nonisolated struct ModelReportedCoordinate: Sendable {
    let normalizedCoordinate: CGPoint
    let elementLabel: String?
    /// Which screen the coordinate refers to, 1-based as the model numbers them,
    /// or nil to mean "whichever screen the mouse is on".
    let screenNumber: Int?
}

nonisolated enum ScrollDirection: String, Sendable {
    case up
    case down
}

/// A green mark the model wants drawn over the user's screen with a
/// `[SHAPE:…]` tag — a ring around the thing it means, an arrow showing where
/// something goes, a curve tracing a flow. Purely visual: unlike
/// `CompanionAction`, none of these touch the machine, which is why they ride
/// in `ActionParseResult` beside `pointingRequest` rather than in `actions`.
nonisolated enum AnnotationShapeKind: String, Sendable {
    /// A ring around something: the first point is its centre, the second a
    /// point just past its edge — the distance between the two is the radius.
    case circle
    /// From the first point to the second, with an arrowhead at the second.
    case arrow
    /// A plain segment between two points.
    case line
    /// A smooth curve through three or more points.
    case curve
    /// A closed outline through three or more points.
    case polygon

    /// How many points each kind needs to be drawable. Fewer is a malformed
    /// tag rather than a draw request — a ring around nothing has no meaning.
    var minimumPointCount: Int {
        switch self {
        case .circle, .arrow, .line:
            return 2
        case .curve, .polygon:
            return 3
        }
    }
}

nonisolated struct AnnotationShapeRequest: Sendable {
    let kind: AnnotationShapeKind
    /// The shape's points on the model's **0–1000 normalized grid**, in the
    /// order the model wrote them. Same grid as `[POINT:…]`, same conversion
    /// machinery — never screenshot pixels, which is what a raw value looks
    /// like and fails silently as.
    let points: [CGPoint]
    /// Short text the drawing is about ("export", "付款流程"), drawn in a small
    /// capsule beside the shape, or nil. Also the **anchor**: enclosing shapes
    /// look an element up by it in the AX tree. The two jobs are separable —
    /// `label` stays the element's own on-screen words while `displayLabel`
    /// carries whatever caption the user asked for (`锚定词|显示文字`).
    let label: String?
    /// The caption to actually draw, when the tag wrote `anchor|display` and
    /// the user asked for a label different from the element's own name. nil
    /// means draw `label` unchanged.
    let displayLabel: String?
    /// Which screen the shape belongs to, 1-based as the model numbers them,
    /// or nil to mean "whichever screen the mouse is on" — same rule as
    /// `[POINT:…]`.
    let screenNumber: Int?
}

/// Something the companion can do to the user's machine.
nonisolated enum CompanionAction: Sendable {
    case click(at: ModelReportedCoordinate)
    case rightClick(at: ModelReportedCoordinate)
    case doubleClick(at: ModelReportedCoordinate)
    case scroll(at: ModelReportedCoordinate, direction: ScrollDirection, amountInSteps: Int)
    case typeText(String)
    case pressKey(keyName: String, modifierNames: [String])
    /// Select a stretch of text in the focused text area **by content**: from the
    /// first occurrence of `startMarker` to the end of `endMarker` (or just the
    /// `startMarker` occurrence when there is no end). Resolved against the text
    /// area's real value through Accessibility, so it needs no coordinates at all —
    /// which is the point: a model anchoring a range deletion on a clicked
    /// position deletes one line too much whenever the click lands one line off.
    case selectText(startMarker: String, endMarker: String?)
    case openApplication(named: String)
    /// Do nothing for `seconds` — the pause the agent loop needs when the screen
    /// is visibly mid-change (a page loading, a window animating in) and acting
    /// on the next step now would act on a screen that has not settled yet.
    /// Without it the model's only way to "wait" is to report the job finished.
    case wait(seconds: Int)
    /// Ask for a fresh read of the frontmost app's accessibility tree. The result
    /// arrives on the *next* turn, which is what makes a multi-step action
    /// possible: look at the interface, then act on what is really there.
    case readAccessibilityTree
}

nonisolated struct ActionParseResult: Sendable {
    /// The reply with every tag removed — this is what gets spoken aloud.
    let spokenText: String
    /// The first [POINT:…] tag, or nil when the model pointed at nothing (it
    /// wrote [POINT:none], or wrote no point tag at all).
    let pointingRequest: ModelReportedCoordinate?
    /// Every action tag, in the order the model wrote them.
    let actions: [CompanionAction]
    /// Every [SHAPE:…] tag, in the order the model wrote them — drawings for
    /// the user's eyes only, never executed and never fed back as actions.
    let shapeRequests: [AnnotationShapeRequest]

    init(
        spokenText: String,
        pointingRequest: ModelReportedCoordinate?,
        actions: [CompanionAction],
        shapeRequests: [AnnotationShapeRequest] = []
    ) {
        self.spokenText = spokenText
        self.pointingRequest = pointingRequest
        self.actions = actions
        self.shapeRequests = shapeRequests
    }
}

nonisolated enum ActionTagParser {

    // MARK: - Tag patterns

    /// `[POINT:x,y]`, `[POINT:x,y:label]`, `[POINT:x,y:label:screen2]`,
    /// `[POINT:none]` — and the same four shapes for the three click kinds.
    ///
    /// Capture groups: 1 = which tag, 2 = x, 3 = y, 4 = label, 5 = screen number.
    private static let pointingAndClickingPattern =
        #"\[(POINT|CLICK|RIGHT_CLICK|DOUBLE_CLICK):(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

    /// `[SCROLL:x,y:up:3]` with an optional `:label` and an optional `:screenN`.
    ///
    /// Capture groups: 1 = x, 2 = y, 3 = direction, 4 = steps, 5 = label, 6 = screen.
    private static let scrollingPattern =
        #"\[SCROLL:(\d+)\s*,\s*(\d+):(up|down):(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]"#

    private static let typingPattern = #"\[TYPE:([^\]]*)\]"#
    private static let selectingPattern = #"\[SELECT:([^\]]+)\]"#
    private static let pressingPattern = #"\[PRESS:([^\]]+)\]"#
    private static let openingPattern = #"\[OPEN:([^\]]+)\]"#
    private static let accessibilityTreePattern = #"\[AX_TREE\]"#
    private static let waitingPattern = #"\[WAIT:([^\]]+)\]"#

    /// `[SHAPE:circle:500,300;560,300:a label:screen2]` — kind, then two or more
    /// ";"-separated points, then an optional label and an optional screen.
    /// The label may carry an `anchor|display` split (`Manage|管理`): before
    /// the pipe is the element's own on-screen name the AX lookup anchors on,
    /// after it the caption the user asked to see drawn instead.
    ///
    /// Capture groups: 1 = kind, 2 = everything after the kind's colon (points,
    /// label, screen — split further below).
    private static let shapePattern = #"\[SHAPE:\s*([^\]]+)\]"#

    // MARK: - Parsing

    /// Pulls every action tag out of a model reply, and returns what is left to
    /// say out loud alongside the actions to perform.
    static func parse(from responseText: String) -> ActionParseResult {
        var claimedRanges: [Range<String.Index>] = []
        var pointingRequest: ModelReportedCoordinate?
        var actions: [CompanionAction] = []
        var shapeRequests: [AnnotationShapeRequest] = []

        // Tags are removed from the spoken text afterwards, so a tag nested inside
        // another tag's text would corrupt the result once both were cut. Letting
        // the first tag to claim a stretch of the reply keep it can't happen with
        // the shapes the prompt asks for; the guard is here so that it degrades
        // into "one tag ignored" instead of mangled speech.
        func claimTagRange(_ tagRange: Range<String.Index>) -> Bool {
            guard !claimedRanges.contains(where: { $0.overlaps(tagRange) }) else { return false }
            claimedRanges.append(tagRange)
            return true
        }

        forEachMatch(in: responseText, pattern: pointingAndClickingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }

            let tagName = capture(1, of: match, in: responseText)?.uppercased() ?? ""

            // [POINT:none] / [CLICK:none] carry no coordinate. They are treated as
            // "no tag" rather than as an error, so a model that answers a question
            // without pointing still gets its whole sentence spoken.
            guard let x = capture(2, of: match, in: responseText).flatMap(Double.init),
                  let y = capture(3, of: match, in: responseText).flatMap(Double.init) else {
                return
            }

            let reportedCoordinate = ModelReportedCoordinate(
                normalizedCoordinate: CGPoint(x: x, y: y),
                elementLabel: capture(4, of: match, in: responseText)?
                    .trimmingCharacters(in: .whitespaces),
                screenNumber: capture(5, of: match, in: responseText).flatMap(Int.init)
            )

            switch tagName {
            case "POINT":
                // Only the first point wins. A second one would have nowhere to
                // fly to — the cursor can only be in one place.
                if pointingRequest == nil {
                    pointingRequest = reportedCoordinate
                }
            case "CLICK":
                actions.append(.click(at: reportedCoordinate))
            case "RIGHT_CLICK":
                actions.append(.rightClick(at: reportedCoordinate))
            case "DOUBLE_CLICK":
                actions.append(.doubleClick(at: reportedCoordinate))
            default:
                break
            }
        }

        forEachMatch(in: responseText, pattern: scrollingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }

            guard let x = capture(1, of: match, in: responseText).flatMap(Double.init),
                  let y = capture(2, of: match, in: responseText).flatMap(Double.init),
                  let directionName = capture(3, of: match, in: responseText)?.lowercased(),
                  let direction = ScrollDirection(rawValue: directionName),
                  let amountInSteps = capture(4, of: match, in: responseText).flatMap(Int.init) else {
                return
            }

            actions.append(
                .scroll(
                    at: ModelReportedCoordinate(
                        normalizedCoordinate: CGPoint(x: x, y: y),
                        elementLabel: capture(5, of: match, in: responseText)?
                            .trimmingCharacters(in: .whitespaces),
                        screenNumber: capture(6, of: match, in: responseText).flatMap(Int.init)
                    ),
                    direction: direction,
                    amountInSteps: amountInSteps
                )
            )
        }

        forEachMatch(in: responseText, pattern: typingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let textToType = capture(1, of: match, in: responseText), !textToType.isEmpty else { return }
            actions.append(.typeText(textToType))
        }

        forEachMatch(in: responseText, pattern: selectingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let selectionDescription = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !selectionDescription.isEmpty else { return }

            // The separator is split ONCE, at its first occurrence: the start
            // marker therefore cannot contain ">>>", but the end marker may.
            let parts: [String]
            if let separatorRange = selectionDescription.range(of: ">>>") {
                parts = [
                    String(selectionDescription[..<separatorRange.lowerBound]),
                    String(selectionDescription[separatorRange.upperBound...])
                ]
            } else {
                parts = [selectionDescription]
            }

            let startMarker = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            guard !startMarker.isEmpty else { return }
            let endMarker = parts.count > 1
                ? parts[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                : nil

            actions.append(.selectText(
                startMarker: startMarker,
                endMarker: (endMarker?.isEmpty == false) ? endMarker : nil
            ))
        }

        forEachMatch(in: responseText, pattern: pressingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let keyDescription = capture(1, of: match, in: responseText) else { return }
            let (keyName, modifierNames) = splitKeyDescription(keyDescription)
            guard !keyName.isEmpty else { return }
            actions.append(.pressKey(keyName: keyName, modifierNames: modifierNames))
        }

        forEachMatch(in: responseText, pattern: openingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let applicationName = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !applicationName.isEmpty else { return }
            actions.append(.openApplication(named: applicationName))
        }

        forEachMatch(in: responseText, pattern: accessibilityTreePattern) { _, tagRange in
            guard claimTagRange(tagRange) else { return }
            actions.append(.readAccessibilityTree)
        }

        forEachMatch(in: responseText, pattern: waitingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            // The seconds are clamped rather than rejected: a model that writes
            // [WAIT:30] is asking for a pause, and refusing it silently would
            // leave the reply looking like it succeeded while nothing waited.
            // The text lands in a local first: chaining the conversion straight
            // onto the optional-capture call makes the overload resolution pick
            // the wrong flatMap, and this reads better anyway.
            let secondsText = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "s", with: "")
                .replacingOccurrences(of: "秒", with: "")
            guard let requestedSeconds = secondsText.flatMap({ Double($0) }) else {
                return
            }
            let clampedSeconds = max(1, min(10, requestedSeconds.rounded()))
            actions.append(.wait(seconds: Int(clampedSeconds)))
        }

        forEachMatch(in: responseText, pattern: shapePattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            // The pattern swallows *any* `[SHAPE:…]` tag — an unknown kind, a
            // malformed point list — and claims it above, so garbage never
            // reaches the spoken text. Only a fully valid request survives to
            // the drawing stage.
            guard let shapeBody = capture(1, of: match, in: responseText) else {
                return
            }
            let bodyParts = shapeBody.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let kindName = bodyParts.first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased(),
                  let kind = AnnotationShapeKind(rawValue: kindName),
                  bodyParts.count > 1 else {
                return
            }
            guard let shapeRequest = parseShapeBody(String(bodyParts[1]), kind: kind) else {
                return
            }
            shapeRequests.append(shapeRequest)
        }

        return ActionParseResult(
            spokenText: spokenTextByRemoving(claimedRanges, from: responseText),
            pointingRequest: pointingRequest,
            actions: actions,
            shapeRequests: shapeRequests
        )
    }

    /// Splits a `[SHAPE:…]` tag's body — everything after the kind's colon —
    /// into its points, label and screen number.
    ///
    /// The body reads `"x1,y1;x2,y2[;…][:label][:screenN]"`. The points are
    /// split off at the body's first `":"` so a label containing a colon still
    /// parses, and a trailing `:screenN` is only treated as a screen number when
    /// it actually says "screen" — otherwise it is part of the label.
    private static func parseShapeBody(
        _ shapeBody: String,
        kind: AnnotationShapeKind
    ) -> AnnotationShapeRequest? {
        let bodyParts = shapeBody.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let pointsPart = bodyParts.first else { return nil }
        let trailingPart = bodyParts.count > 1 ? String(bodyParts[1]) : nil

        var labelText: String?
        var displayText: String?
        var screenNumber: Int?
        if let trailingPart {
            if let screenMatch = trailingPart.range(of: #"(?:^|:)screen(\d+)\s*$"#, options: .regularExpression) {
                let screenText = trailingPart[screenMatch]
                    .replacingOccurrences(of: "screen", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                screenNumber = Int(screenText)
                let labelPart = String(trailingPart[..<screenMatch.lowerBound])
                let trimmedLabel = labelPart.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                labelText = trimmedLabel.isEmpty ? nil : trimmedLabel
            } else {
                labelText = trailingPart.isEmpty ? nil : trailingPart
            }
        }

        // Optional `anchor|display` split: everything before the first `|`
        // stays the AX-lookup anchor, everything after is what the capsule
        // draws. A label the user asked to rename/translate must keep the
        // element's own words as the anchor — a translated-only label matches
        // no element, the lookup fails, and the shape falls back to the
        // model's estimated coordinates (the "renamed it and it went crazy"
        // failure).
        if let existingLabelText = labelText, let pipeIndex = existingLabelText.firstIndex(of: "|") {
            let anchor = String(existingLabelText[existingLabelText.startIndex..<pipeIndex])
                .trimmingCharacters(in: .whitespaces)
            let display = String(existingLabelText[existingLabelText.index(after: pipeIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if anchor.isEmpty {
                // `|display` with no anchor: nothing to look up, so keep the
                // whole text as a plain display-only label.
                labelText = nil
                displayText = display.isEmpty ? nil : display
            } else {
                labelText = anchor
                displayText = display.isEmpty ? nil : display
            }
        }

        let parsedPoints: [CGPoint] = pointsPart
            .split(separator: ";")
            .compactMap { pointText in
                let coordinates = pointText.split(separator: ",")
                guard coordinates.count == 2,
                      let x = Double(coordinates[0].trimmingCharacters(in: .whitespaces)),
                      let y = Double(coordinates[1].trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                return CGPoint(x: x, y: y)
            }

        guard parsedPoints.count >= kind.minimumPointCount else { return nil }

        return AnnotationShapeRequest(
            kind: kind,
            points: parsedPoints,
            label: labelText,
            displayLabel: displayText,
            screenNumber: screenNumber
        )
    }

    // MARK: - Helpers

    /// Splits `"cmd+a"` into the key to press and the modifiers held with it.
    ///
    /// Which component is the key is decided by **name, not by position**.
    /// Position is the obvious way to write this and it is wrong: the prompt
    /// teaching this tag spells the combination key-first (`[PRESS:a+cmd]`),
    /// while macOS convention spells it modifier-first, and a model asked for
    /// "全选" can reasonably emit either. Read positionally, one of those two
    /// comes out as "hold A down and strike Command" — which the executor
    /// refuses as an unknown modifier, so the shortcut simply never fires.
    /// Deciding by name makes both orders the same request, which is what a tag
    /// written by a language model needs.
    ///
    /// A description that is nothing but modifiers (`cmd`) names that modifier
    /// key itself; there is no other component left to be the one struck.
    private static func splitKeyDescription(_ keyDescription: String) -> (keyName: String, modifierNames: [String]) {
        let components = keyDescription
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let modifierNames = components.filter { modifierFlag(named: $0) != nil }
        let otherNames = components.filter { modifierFlag(named: $0) == nil }

        guard let keyName = otherNames.last ?? modifierNames.last else { return ("", []) }
        return (keyName, modifierNames.filter { $0 != keyName })
    }

    /// Maps the words a model may write for a modifier key into the event flag
    /// they mean, or `nil` for anything that is not a modifier.
    ///
    /// This table lives with the tag parser rather than with the code that
    /// presses the keys, because "which of `cmd+a`'s two halves is the key" is
    /// a question about the *tag* — the parser has to answer it, and the answer
    /// has to be the same vocabulary the executor can turn into flags. Two
    /// tables would eventually disagree, and a disagreement here surfaces as a
    /// shortcut that quietly does nothing.
    ///
    /// Several spellings each, because these come from a language model and not
    /// from a keyboard: `cmd`, `command` and `⌘` all mean the same thing, and
    /// refusing one of them would look like the feature is broken.
    nonisolated static func modifierFlag(named modifierName: String) -> CGEventFlags? {
        switch modifierName.lowercased() {
        case "cmd", "command", "meta", "super", "⌘":
            return .maskCommand
        case "shift", "⇧":
            return .maskShift
        case "opt", "option", "alt", "⌥":
            return .maskAlternate
        case "ctrl", "control", "^":
            return .maskControl
        case "fn", "function":
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    /// Removes the claimed tag ranges and tidies the sentence left behind.
    ///
    /// Built by splicing the text *between* the ranges rather than by deleting
    /// them in place: deleting in place means mutating a string while holding
    /// indices into a different copy of it, which is the kind of thing that works
    /// until it doesn't.
    private static func spokenTextByRemoving(
        _ tagRanges: [Range<String.Index>],
        from responseText: String
    ) -> String {
        let sortedRanges = tagRanges.sorted { $0.lowerBound < $1.lowerBound }

        var spokenText = ""
        var nextCharacterToCopy = responseText.startIndex
        for tagRange in sortedRanges {
            spokenText += responseText[nextCharacterToCopy..<tagRange.lowerBound]
            nextCharacterToCopy = tagRange.upperBound
        }
        spokenText += responseText[nextCharacterToCopy...]

        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming speech support (逐句快答)

    /// The tag keywords one combined pattern for the streaming speech path —
    /// a keyword added to the parser above must be added here too, or the
    /// streaming speech would read the tag aloud instead of removing it.
    private static let streamingTagKeywords =
        "POINT|CLICK|RIGHT_CLICK|DOUBLE_CLICK|SCROLL|TYPE|SELECT|PRESS|OPEN|WAIT|AX_TREE|SHAPE"

    /// A complete tag, however far the reply has streamed: `[TYPE:北京新闻]`.
    private static let streamingCompleteTagPattern =
        "\\[(?:\(streamingTagKeywords))[^\\]]*\\]"

    /// A tag that has started but not closed yet — the tail of text still
    /// streaming in: `[POINT:123,45` (keyword whole, arguments still arriving)
    /// or `[POIN` (the keyword itself only half-streamed). The second shape
    /// needs its own arm: `[POIN` matches no keyword yet, so a keyword-only
    /// pattern would let it through and the tag's first letters would be
    /// spoken aloud — and the next call would retract them, which breaks the
    /// prefix monotonicity the session's cumulative feed diffs on. The arm
    /// matches a trailing `[` followed by letters only, however many: a
    /// bracketed English word (`[documentation`) is held too, but holding is
    /// always safe — releasing the held text later only extends the output,
    /// while leaking it early and removing it later is the break.
    private static let streamingOpenTagPattern =
        "\\[(?:\(streamingTagKeywords))[^\\]]*$|\\[[A-Za-z_]*$"

    /// Strips action tags from reply text that may still be mid-tag, for the
    /// streaming speech path.
    ///
    /// Complete tags are removed; a trailing stretch that could still be the
    /// beginning of a tag is held back (`[POINT:123,45` has not closed yet —
    /// speaking it now would read the tag aloud, and finding out one character
    /// too late is what this hold-back prevents). Once the tag closes it is
    /// removed on a later call, so each call's result always extends the
    /// previous call's — the session diffs on that property.
    static func speakableTextFromStreamedReply(_ streamedReplyText: String) -> String {
        var speakableText = streamedReplyText

        if let completeTagRegex = try? NSRegularExpression(pattern: streamingCompleteTagPattern, options: [.caseInsensitive]) {
            let wholeTextRange = NSRange(streamedReplyText.startIndex..., in: streamedReplyText)
            speakableText = completeTagRegex.stringByReplacingMatches(
                in: streamedReplyText,
                options: [],
                range: wholeTextRange,
                withTemplate: ""
            )
        }

        if let openTagRegex = try? NSRegularExpression(pattern: streamingOpenTagPattern, options: [.caseInsensitive]) {
            let wholeTextRange = NSRange(speakableText.startIndex..., in: speakableText)
            if let openTagMatch = openTagRegex.firstMatch(in: speakableText, options: [], range: wholeTextRange),
               let openTagRange = Range(openTagMatch.range, in: speakableText) {
                speakableText = String(speakableText[..<openTagRange.lowerBound])
            }
        }

        return speakableText
    }

    private static func forEachMatch(
        in text: String,
        pattern: String,
        _ body: (NSTextCheckingResult, Range<String.Index>) -> Void
    ) {
        // Case-insensitive on purpose: the tags are uppercase in the prompt, but a
        // model that writes [click:…] means exactly the same thing, and silently
        // speaking the tag aloud instead of clicking would be a confusing failure.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return
        }

        let wholeTextRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: wholeTextRange) {
            guard let tagRange = Range(match.range, in: text) else { continue }
            body(match, tagRange)
        }
    }

    private static func capture(
        _ groupIndex: Int,
        of match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        guard groupIndex < match.numberOfRanges,
              let groupRange = Range(match.range(at: groupIndex), in: text) else {
            return nil
        }
        return String(text[groupRange])
    }
}
