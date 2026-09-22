//
//  NotchActivityView.swift
//  leanring-buddy
//
//  What the notch pill and the expanded sheet's header draw while the
//  companion works — the activity phases HeyClicky recovered as
//  `NotchActivityPhase`:
//
//    idle         nothing (the pill is exactly the notch and disappears into it)
//    listening    four thin waveform bars fed by the live microphone power
//    thinking     three pulsing dots
//    speaking     a five-bar synthetic equalizer
//    transcribing three typing dashes — the gap after key release while the
//                 ASR provider settles the final transcript (the recovered
//                 `legacyDictationTypingDashes`)
//
//  The resting presentation is the user-measured original: the notch itself
//  NEVER grows. Two black "wings" extend horizontally out of the notch's
//  left and right edges — same height as the notch, outer bottom corner
//  rounded, fused with the menu-bar band. The leading wing carries the bold
//  state word (Listening / Thinking / Speaking / Typing…), the trailing
//  wing carries the phase animation in its phase colour over a soft same-
//  colour glow: listening teal, thinking purple, speaking orange.
//  (Recovered symbol names predicted exactly this layout:
//  `labelView(phase:)` on the left + `trailingAnimation(phase:)` on the
//  trailing side.)
//
//  Also home to `HomeSpaceSheetShape`, the custom `Shape` that draws the
//  expanded sheet's outline: a narrow "stem" connecting the sheet's top edge
//  into the hardware notch, animated by `expansionProgress` so the sheet
//  reads as growing *out of the notch* rather than fading in next to it.
//
//  All animation is TimelineView-driven from provider closures rather than
//  @Published state — the pill redraws tens of times a second while
//  listening, and per-frame @Published writes through Combine would buy
//  nothing but diffing cost.
//

import SwiftUI

/// What the notch is currently doing. Mapped from `CompanionVoiceState` —
/// separate type so the notch subsystem keeps its own vocabulary and does not
/// drag the whole companion state machine into every notch view's signature.
enum NotchActivityPhase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case transcribing
}

/// The bold state word the leading wing carries, and each phase's animation
/// colour — the user's screenshots of the original are the reference:
/// listening teal, thinking purple, speaking orange, typing grey.
extension NotchActivityPhase {

    var notchStateWord: String {
        switch self {
        case .idle: return ""
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .transcribing: return "Typing…"
        }
    }

    var notchAnimationTint: Color {
        switch self {
        case .idle: return .white
        case .listening: return Color(red: 0.37, green: 0.92, blue: 0.83)   // #5EEAD4
        case .thinking: return Color(red: 0.77, green: 0.49, blue: 0.94)    // #C47CF0
        case .speaking: return Color(red: 0.98, green: 0.57, blue: 0.24)    // #FB923C
        case .transcribing: return Color(red: 0.72, green: 0.75, blue: 0.80) // #B7C0CC
        }
    }

    /// The colour of the glow behind the phase animation — **not** the same
    /// colour as the animation itself, which is why this is its own table.
    ///
    /// Measured 2026-09-22 off the original's own screenshots (the ones the user
    /// supplied as the target). In the original, a thinking reply draws bright
    /// magenta dots (#F35FD7) over a glow that peaks at **#540067** — a deep,
    /// fully saturated violet with no green at all. Sampling the listening peak
    /// the same way gives **#12464C**, and speaking **#45230F**. The animation
    /// is a light; the glow is a *dye*.
    ///
    /// The first version of this glow composited the phase tint at 50% opacity,
    /// which is what made it read as grey haze rather than coloured light: half
    /// of the listening tint #5EEAD4 over black is (47, 117, 106), a desaturated
    /// teal whose *green* channel is the largest. Against the bright teal
    /// wallpaper the user runs, that is the same hue as the desktop at half the
    /// saturation — a dirty smudge on the end of the band, which is exactly what
    /// they reported. Keeping each channel where the measurement put it is the
    /// whole fix; there is no alpha to apply here at all.
    var notchGlowColor: Color {
        switch self {
        case .idle: return .clear
        case .listening: return Color(red: 0.07, green: 0.27, blue: 0.30)    // #12464C
        case .thinking: return Color(red: 0.33, green: 0.00, blue: 0.40)     // #540067
        case .speaking: return Color(red: 0.27, green: 0.14, blue: 0.06)     // #45230F
        case .transcribing: return Color(red: 0.20, green: 0.22, blue: 0.25) // #333840
        }
    }

    /// The glow's falloff, as fractions of its own elliptical radius. The
    /// shape is a Gaussian-ish blob, not a straight ramp: a broad bright core
    /// that then falls away quickly.
    ///
    /// Fitted 2026-09-22 to the original's measured Listening glow — the
    /// alpha at each measured distance from the peak — and verified by
    /// rendering the candidate at the reference screenshots' own scale and
    /// scanning the two side by side rather than eyeballing them. The proof
    /// it is right is that the numbers agree in four places at once: at the
    /// wing's outer edge ~0.60, at the band's top edge ~0.36, zero about 44%
    /// of the way in, and the peak itself ~14pt in from the outer edge.
    var notchGlowStops: [Gradient.Stop] {
        [
            .init(color: notchGlowColor.opacity(1.00), location: 0.00),
            .init(color: notchGlowColor.opacity(0.85), location: 0.30),
            .init(color: notchGlowColor.opacity(0.62), location: 0.50),
            .init(color: notchGlowColor.opacity(0.36), location: 0.70),
            .init(color: notchGlowColor.opacity(0.16), location: 0.85),
            .init(color: notchGlowColor.opacity(0.00), location: 1.00),
        ]
    }
}

// MARK: - Sheet shape

/// The expanded sheet's outline. Two joined regions, both filled black:
/// a centered **stem** from the top of the window down to the body, and the
/// **body** — a rounded rectangle hanging below the menu-bar band.
///
/// `expansionProgress` lerps the body from the resting notch's size to the
/// full window. At 0 the shape is exactly the resting pill; at 1 the body
/// reaches the top of the window and the stem disappears into it. The value
/// is not animated on its own — the controller derives it from the panel's
/// live frame on every `windowDidResize`, so the shape re-renders once per
/// animation frame of the window morph and tracks it exactly.
struct HomeSpaceSheetShape: Shape {
    var expansionProgress: CGFloat

    /// Height of the transparent band at the top of the sheet through which
    /// only the stem passes — visually the sheet's "neck" below the notch.
    var menuBarBandHeight: CGFloat = 20

    /// Width of the stem connecting the sheet to the notch.
    var stemWidth: CGFloat = 150

    /// Corner radius of the sheet body's bottom corners — the top two stay
    /// square because the sheet hangs from the screen's top edge.
    var cornerRadius: CGFloat = 20

    /// The resting pill's drawn size — what the body lerps from.
    var restingNotchSize: CGSize = CGSize(width: 190, height: 32)

    // No animatableData: the progress value updates per animation frame from
    // the window's live frame (see the doc comment above), so there is no
    // transaction animation for SwiftUI to interpolate.

    func path(in rect: CGRect) -> Path {
        let progress = min(max(expansionProgress, 0), 1)

        // The body lerps from a notch-sized rect centered at the top of the
        // window to the full window rect.
        let bodyWidth = restingNotchSize.width + (rect.width - restingNotchSize.width) * progress
        let bodyHeight = restingNotchSize.height + (rect.height - restingNotchSize.height) * progress
        let bodyRect = CGRect(
            x: rect.midX - bodyWidth / 2,
            y: rect.minY,
            width: bodyWidth,
            height: bodyHeight
        )

        var path = Path()

        // The stem is only visible while the body's top corners are still
        // narrower than the stem — past that the body itself covers the
        // notch-to-sheet seam. Drawing it regardless is harmless (it is
        // behind/inside the body) and keeps the geometry branch-free.
        let stemRect = CGRect(
            x: rect.midX - stemWidth / 2,
            y: rect.minY,
            width: stemWidth,
            height: menuBarBandHeight + 2
        )
        path.addRect(stemRect)

        // The sheet hangs from the screen's top edge, so its top corners stay
        // square (fused with the menu bar band) and only the bottom two
        // corners round — the same shape grammar as the resting pill.
        let radius = cornerRadius
        path.move(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius),
            control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
        )
        path.closeSubpath()

        // Stem and body overlap, so the union is one continuous black shape.
        return path
    }
}

// MARK: - Pill root view

/// The resting pill's entire content: a black pill exactly the notch's size
/// that NEVER grows, plus two black wings that extend horizontally out of
/// the notch's left and right edges while the companion is active — the
/// user-measured original layout. The leading wing carries the bold state
/// word; the trailing wing carries the phase animation in its phase colour
/// over a same-colour glow. Both wings are exactly the notch's height, so
/// the whole assembly reads as the notch stretching sideways, not growing.
struct NotchPillRootView: View {

    @ObservedObject var panelModel: NotchPanelModel
    var audioHistoryProvider: () -> [CGFloat]

    /// Wing widths measured off the original running it live (2026-09-22:
    /// the full band spans ~355pt — left wing ~78, right wing ~87). The word
    /// is right-aligned against the notch, so the left wing only needs to
    /// hold the longest word ("Listening") plus a small margin.
    private static let leadingWingWidth: CGFloat = 86
    private static let trailingWingWidth: CGFloat = 88

    var body: some View {
        GeometryReader { geometry in
            let notchHeight = geometry.size.height - NotchSupport.restingPillAnimationHeadroom
            // The pill stays exactly notch-width; the window is wider by
            // activeFlankWidth on each side, which is the wings' canvas.
            // The extra area is transparent at rest, so the pill still fuses
            // with the hardware notch.
            let pillWidth = geometry.size.width - NotchSupport.activeFlankWidth * 2
            let isActive = panelModel.activityPhase != .idle

            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    NotchWingView(
                        phase: panelModel.activityPhase,
                        audioHistoryProvider: audioHistoryProvider,
                        isLeading: true
                    )
                    .frame(
                        width: isActive ? Self.leadingWingWidth : 0,
                        height: notchHeight
                    )
                    // The clip lives OUTSIDE the animated width frame: inside
                    // the wing the natural content size (the fixed 88×40 glow)
                    // would win, and a width-0 frame does not clip on its own
                    // — the idle glow would keep leaking past the pill's edge.
                    .clipped()

                    // The middle segment's bottom corners are rounded ONLY at
                    // rest, when the pill stands alone and its little radius
                    // is what makes it read as a pill. The moment the wings
                    // slide out it must go square (0), because the wings are
                    // square where they meet it: a rounded corner here cuts
                    // the shared bottom edge and leaves a notch-shaped blank
                    // on BOTH sides of the hardware notch — the two gaps the
                    // user reported as 「刘海左下角有一个空白」. Square on all
                    // four bottom corners is what keeps the SEAMS straight —
                    // the band's rounding lives only at its two outer ends,
                    // each wing's own outline (see NotchWingView).
                    PillShape(bottomCornerRadius: isActive ? 0 : 6)
                        .fill(Color.black)
                        .frame(width: pillWidth, height: notchHeight)

                    NotchWingView(
                        phase: panelModel.activityPhase,
                        audioHistoryProvider: audioHistoryProvider,
                        isLeading: false
                    )
                    .frame(
                        width: isActive ? Self.trailingWingWidth : 0,
                        height: notchHeight
                    )
                    .clipped()
                }
                // The wing extension/retraction rides the phase change, so
                // the wings slide out of the notch instead of popping.
                .animation(.easeInOut(duration: 0.38), value: panelModel.activityPhase)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

/// One side wing: a black rectangle exactly the notch's height extending
/// horizontally from the notch's edge, its OUTER bottom corner rounded and
/// its top fused with the menu-bar band. The leading wing draws the bold
/// state word at its outer end; the trailing wing draws the phase animation
/// in the phase colour over a soft radial glow of the same colour.
struct NotchWingView: View {

    let phase: NotchActivityPhase
    var audioHistoryProvider: () -> [CGFloat]
    let isLeading: Bool

    /// The wing's outer bottom corner radius. Measured 2026-09-22 off the
    /// user's target screenshot (L29938, Listening, 1.635 px/pt): the band's
    /// bottom edge recedes 26 px ≈ 16 pt at the outer edge column, flattening
    /// over ~23 px ≈ 14 pt — i.e. a corner of roughly 14–16 pt, notably larger
    /// than the resting pill's 6. (A second reference, L31041, measures ~10 pt;
    /// the two disagree within their compression blur, and the user's own
    /// target image is the one to match.) The inner edge stays square: it meets
    /// the middle segment, and a rounded seam there is G8's notch-shaped gap.
    static let outerBottomCornerRadius: CGFloat = 14

    /// The wing's outline: square along the top (it fuses with the notch) and
    /// on the edge that meets the middle segment, rounded only at the outer
    /// bottom corner. Both the black fill and the content clipped into it use
    /// this one shape.
    private var outline: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: isLeading ? Self.outerBottomCornerRadius : 0,
            bottomTrailingRadius: isLeading ? 0 : Self.outerBottomCornerRadius,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        // The outline is the BASE and everything else rides in an `overlay`,
        // which never contributes to its parent's layout size. That distinction
        // is the whole fix for 「右边没有圆角」 (measured 2026-09-22).
        //
        // It used to be a `ZStack`, and a ZStack sizes itself to its largest
        // child. The trailing wing's glow is deliberately 64pt tall — taller
        // than the 32pt band, so its vertical falloff reaches past the band's
        // edges and is trimmed by them (see the glow's own comment below). So
        // the ZStack became 64pt, the parent `.frame(height: notchHeight)`
        // centred it, and the black rectangle's bottom edge landed 16pt BELOW
        // the band — taking its entire 10pt bottom corner with it. The
        // call-site `.clipped()` then cut along the band's real bottom edge,
        // leaving a hard 90° corner.
        //
        // Only the trailing wing had a tall child, so only its corner died:
        // measured live, the bottom edge of the band ran dead flat at y=64 for
        // every column from x=820 to the band's right edge at x=850, while the
        // leading wing's receded 64 → 63 → 60 → 56 → 43 over the same span.
        // One rounded corner and one square one, from the same code.
        outline
            .fill(Color.black)
            .overlay {
                wingContent
            }
            // Clip the content to the same silhouette, so the glow's outer
            // corner is rounded with the band rather than poking a square
            // sliver of colour past it.
            .clipShape(outline)
    }

    @ViewBuilder
    private var wingContent: some View {
            if isLeading {
                if phase != .idle {
                    // The original right-aligns the state word against the
                    // notch (measured 2026-09-22: "Listening" ends ~5pt before
                    // the notch's edge), so the whole band's content clusters
                    // at the notch instead of stranding the word at the far
                    // left.
                    HStack {
                        Spacer(minLength: 0)
                        Text(phase.notchStateWord)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 6)
                }
            } else {
                // The glow is a soft blob sitting inside the wing, not a ramp
                // that runs its whole width and stops dead at the silhouette.
                //
                // Measured 2026-09-22 off the original's own Listening
                // screenshot — the one the user supplied as the target. The
                // wing is 88pt wide and 32pt tall, so the reference's own
                // pixels are 1.635 to the point; scanning across its
                // mid-height row, and down a column through the peak:
                //
                //   across   x=708 #010507   x=744 #113D45
                //            x=720 #091417   x=756 #104149  ← peak
                //            x=732 #0F2A30   x=776 #0F3035  (silhouette)
                //            …zero by x=706, so the inner 44% is pure black
                //
                //   down     the band is lit from its very top edge (36% at
                //            2px in) through the peak and back to black at the
                //            bottom — the light reaches both edges and is
                //            trimmed by them, it does not fade out first.
                //
                // Four numbers fall out, and they are what the parameters
                // below are fitted to: peak ~14pt in from the outer edge,
                // ~60% brightness where it meets that edge, ~36% at the
                // band's top edge, zero about 44% of the way in.
                //
                // What the previous version did instead was `center: .trailing`
                // with `endRadiusFraction: 1`: peak exactly ON the outer edge
                // fading to exactly zero at the inner one. A wedge filling the
                // wing corner to corner, brightest precisely where the black
                // stops. Measured live on 2026-09-22 over the user's teal
                // desktop it ramped to #245E51 at the silhouette and then
                // jumped straight to the wallpaper's #0080A6 — a long grey-green
                // wash across the whole wing, ending in a hard edge. That is
                // the 「过渡不自然」 the user reported, and it is also why the
                // old glow looked wrong in colour: the phase tint at 50% alpha
                // is a desaturated version of the tint, so on a coloured
                // desktop it read as haze rather than light. See
                // `notchGlowColor` for the colour half of the fix.
                //
                // Re-measured live after the fix, same method, over that same
                // teal desktop: black until 39pt into the wing, peak #204249
                // (32,66,73) at 16pt in from the outer edge, then back down to
                // #193439 (25,52,57) at the silhouette — peak position, the
                // black inner half and the ~55% edge value all land where the
                // reference put them. The parabola is what "natural" means
                // here: the band's outer edge is now a plain vertical cut
                // between two dark values instead of a bright ramp meeting the
                // wallpaper.
                ZStack(alignment: .trailing) {
                    EllipticalGradient(
                        stops: phase.notchGlowStops,
                        center: UnitPoint(x: 0.84, y: 0.5),
                        startRadiusFraction: 0,
                        endRadiusFraction: 0.40
                    )
                    .frame(maxWidth: .infinity)
                    // Still taller than the band (64 vs its 32) — but now for
                    // the measured reason rather than as a way to hide the
                    // falloff. The reference is genuinely still ~36% lit where
                    // it meets the band's top and bottom edges, so the glow's
                    // vertical radius has to reach past them and be trimmed by
                    // the wing, exactly as the original's is. Sizing this to
                    // the band instead would force the light to zero at the
                    // edges and leave a dark rim along the top and bottom of a
                    // glow that should be touching them.
                    .frame(height: 64)

                    // The animation rides inside the glow, toward its bright
                    // end. Only the animation is inset from the edge — the
                    // glow's own centre is what places it now.
                    NotchActivityView(
                        phase: phase,
                        audioHistoryProvider: audioHistoryProvider,
                        tint: phase.notchAnimationTint
                    )
                    .frame(height: 20)
                    .padding(.trailing, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }
}

/// A rectangle rounded only at the bottom — the pill hangs from the screen's
/// top edge, so its top corners must stay square to fuse with the notch.
private struct PillShape: Shape {
    var bottomCornerRadius: CGFloat

    /// Without this the radius would SNAP between its resting and active
    /// values while the wings are still sliding (0.38 s), so the corner the
    /// user is watching would pop square in a single frame instead of
    /// opening up with the band. Declaring the radius as the shape's
    /// animatable data lets the surrounding phase animation interpolate it
    /// like any other geometry.
    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Activity drawing

/// The phase-specific animation, sized to fill whatever container it is given
/// (the trailing wing, or the expanded sheet's header). `tint` is the
/// animation colour — the wings pass the phase colour, the sheet header keeps
/// the neutral white.
struct NotchActivityView: View {

    let phase: NotchActivityPhase
    var audioHistoryProvider: () -> [CGFloat] = { [] }
    var tint: Color = .white

    var body: some View {
        switch phase {
        case .idle:
            Color.clear
        case .listening:
            TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timeline in
                NotchListeningWaveformView(
                    timelineDate: timeline.date,
                    audioHistoryProvider: audioHistoryProvider,
                    tint: tint
                )
            }
        case .thinking:
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                NotchThinkingDotsView(timelineDate: timeline.date, tint: tint)
            }
        case .speaking:
            TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timeline in
                NotchSpeakingEqualizerView(timelineDate: timeline.date, tint: tint)
            }
        case .transcribing:
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                NotchTypingDashesView(timelineDate: timeline.date, tint: tint)
            }
        }
    }
}

/// Four thin bars driven by the real microphone power history — the same
/// published array the overlay waveform consumes (`BuddyDictationManager.recordedAudioPowerHistory`).
/// Four bars at the measured original's proportions: thin, short, gently
/// alive rather than a full equalizer.
struct NotchListeningWaveformView: View {

    var timelineDate: Date
    var audioHistoryProvider: () -> [CGFloat]
    var tint: Color = .white

    static let barCount = 4

    var body: some View {
        let history = audioHistoryProvider()
        HStack(spacing: 3.5) {
            ForEach(0..<Self.barCount, id: \.self) { barIndex in
                let historyIndex = history.count - Self.barCount + barIndex
                let level = historyIndex >= 0 && historyIndex < history.count
                    ? history[historyIndex]
                    : CGFloat(0)
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 3.5, height: max(3, min(11, level * 40)))
            }
        }
    }
}

/// Three dots pulsing out of phase — thinking.
struct NotchThinkingDotsView: View {

    var timelineDate: Date
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let phaseOffset = Double(dotIndex) * 0.2
                let cycle = (timelineDate.timeIntervalSinceReferenceDate * 1.3 + phaseOffset)
                    .truncatingRemainder(dividingBy: 1)
                let pulse = max(0, sin(cycle * .pi))
                Circle()
                    .fill(tint.opacity(0.25 + 0.75 * pulse))
                    .frame(width: 5, height: 5)
                    .scaleEffect(0.85 + 0.25 * pulse)
            }
        }
    }
}

/// A five-bar equalizer for speaking — the audio being played is not the
/// companion's to sample, so the bars dance on sine waves instead.
struct NotchSpeakingEqualizerView: View {

    var timelineDate: Date
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<5, id: \.self) { barIndex in
                let t = timelineDate.timeIntervalSinceReferenceDate
                let wave = abs(sin(t * 8.5 + Double(barIndex) * 1.9))
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 3.5, height: max(2, 2 + 13 * wave))
            }
        }
    }
}

/// Three dashes lighting up in sequence — the recovered
/// `legacyDictationTypingDashes`: shown in the gap after the user releases
/// the talk key while the transcription provider settles the final text.
struct NotchTypingDashesView: View {

    var timelineDate: Date
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { dashIndex in
                let cycle = (timelineDate.timeIntervalSinceReferenceDate * 1.1 + Double(dashIndex) * 0.18)
                    .truncatingRemainder(dividingBy: 1)
                let glow = max(0, sin(cycle * .pi))
                Capsule()
                    .fill(tint.opacity(0.15 + 0.8 * glow))
                    .frame(width: 11, height: 3.5)
            }
        }
    }
}

// MARK: - Panel root switching

/// The single SwiftUI root every notch panel hosts. Switches between the
/// resting pill and the expanded sheet on `panelModel.isExpanded` — the same
/// moment the window frame starts morphing, so the sheet's
/// `HomeSpaceSheetShape` (animated by `expansionProgress`) continues visually
/// from the pill the frame just was.
///
/// Holds `companionManager` strongly from inside the view tree. That is a
/// reference cycle (manager → controller → hosting view → this view →
/// manager) and it is deliberate: every participant lives for the whole app
/// run, exactly like the overlay windows, so the cycle never has to break.
struct NotchPanelRootSwitchingView: View {

    @ObservedObject var panelModel: NotchPanelModel
    var audioHistoryProvider: () -> [CGFloat]
    var collapseAction: () -> Void
    var companionManager: CompanionManager

    var body: some View {
        if panelModel.isExpanded {
            NotchExpandedSheetView(
                panelModel: panelModel,
                audioHistoryProvider: audioHistoryProvider,
                collapseAction: collapseAction,
                companionManager: companionManager
            )
        } else if panelModel.expansionProgress > 0.01 {
            // 收起的这一路：`isExpanded` 已经翻成 false，窗口 frame 正沿收起
            // 曲线缩回刘海，`expansionProgress` 同步插值到 0——只画轮廓不画
            // 内容，面板就顺着同一条曲线退回去。展开时不经过这里：点击是
            // 即刻提交（`isExpanded` 与窗口形变同帧置位），第一分支直接接管。
            HomeSpaceSheetShape(expansionProgress: panelModel.expansionProgress)
                .fill(NotchExpandedSheetStyle.surfaceColor)
        } else {
            NotchPillRootView(
                panelModel: panelModel,
                audioHistoryProvider: audioHistoryProvider
            )
        }
    }
}

// MARK: - Expanded sheet (Phase C placeholder content)

/// 展开面板的配色，取色来源是 design-preview/notch-glow-expand.html。
///
/// 面板表面 = 那份文件 `.skin` 的深色皮 `rgba(14,14,13,.92)`——用户要的
/// 「深色背景」是这块皮，**不是**那条蓝紫渐变：渐变在文件里只当左、右、
/// 下三边露出的 1.5pt 边光（`.panel` 的 1.5px padding），从没铺过面。
private enum NotchExpandedSheetStyle {

    /// 边光渐变的四个取色——`.panel` 的
    /// `background:linear-gradient(115deg, …)`，顺序和位置
    /// （0 / 35% / 70% / 100%）与文件完全一致。只当边光用。
    private static let demoGradientRGB: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0x7C, 0x3A, 0xED), // #7C3AED 紫
        (0xC0, 0x84, 0xFC), // #C084FC 亮紫
        (0x22, 0xD3, 0xEE), // #22D3EE 亮青
        (0x08, 0x91, 0xB2), // #0891B2 深青
    ]

    /// 面板皮肤的深色底——demo `.skin` 的 `rgba(14,14,13,.92)` 原值。
    /// 保留 8% 透明和文件一致；面板后面是什么就透一点什么。
    static let surfaceColor = Color(red: 14 / 255, green: 14 / 255, blue: 13 / 255, opacity: 0.92)

    /// 三边边光的取色——同一条渐变，不打折（它是「光」，保持满饱和才亮
    /// 得起来）。
    static let edgeGlowGradientColors: [Color] = demoGradientRGB.map { rgb in
        Color(red: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255)
    }

    /// 渐变方向：文件里的 115deg——几乎竖直、略向右下偏。
    static let gradientStartPoint = UnitPoint(x: 0.18, y: 0)
    static let gradientEndPoint = UnitPoint(x: 0.82, y: 1)

    /// 面板底角的圆角半径。内层表面比外层小一个边光宽度，两层的圆角才是
    /// 同心弧——内层若用直角，圆角里会露出一块方形亮边。
    static let sheetCornerRadius: CGFloat = 20

    /// 边光露出的宽度（demo 的 1.5px padding）。
    static let edgeGlowInset: CGFloat = 1.5
}

/// The expanded sheet: the `HomeSpaceSheetShape` body carrying the session
/// sidebar and the conversation/settings content (`NotchSheetRootView`), with
/// the live activity drawing in the header and the close button.
struct NotchExpandedSheetView: View {

    @ObservedObject var panelModel: NotchPanelModel
    var audioHistoryProvider: () -> [CGFloat]
    var collapseAction: () -> Void
    var companionManager: CompanionManager

    var body: some View {
        ZStack(alignment: .top) {
            // 外层：亮蓝紫渐变，本身不是面板的底色，只作为三边的边光——
            // 内层表面在左、右、下各让出 1.5pt，露出来的就是这条线。
            LinearGradient(
                colors: NotchExpandedSheetStyle.edgeGlowGradientColors,
                startPoint: NotchExpandedSheetStyle.gradientStartPoint,
                endPoint: NotchExpandedSheetStyle.gradientEndPoint
            )

            // 内层：整面深色皮（demo `.skin` 的 rgba(14,14,13,.92)）——
            // 面板的底色。顶部不让边（inset 为 0），顶边没有线，
            // 面板直接贴住屏幕最上沿和菜单栏连成一条。
            NotchExpandedSheetStyle.surfaceColor
            // 内层自己的底角半径要比外层小一个边光宽度，两层圆角才是
            // 同心弧；用直角内层会在圆角里露出一块方形亮边。
            .clipShape(HomeSpaceSheetShape(
                expansionProgress: 1,
                cornerRadius: NotchExpandedSheetStyle.sheetCornerRadius
                    - NotchExpandedSheetStyle.edgeGlowInset
            ))
            .padding(EdgeInsets(
                top: 0,
                leading: NotchExpandedSheetStyle.edgeGlowInset,
                bottom: NotchExpandedSheetStyle.edgeGlowInset,
                trailing: NotchExpandedSheetStyle.edgeGlowInset
            ))

            // 仿 HeyClicky：会话侧栏通高，顶栏（右上角关闭等）属于内容区，
            // 都在 NotchSheetRootView 内部。内容也一起让出边光那 1.5pt，
            // 否则侧栏自带的深色底会把左边光压暗。
            NotchSheetRootView(
                panelModel: panelModel,
                companionManager: companionManager,
                collapseAction: collapseAction,
                audioHistoryProvider: audioHistoryProvider
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(EdgeInsets(
                top: 0,
                leading: NotchExpandedSheetStyle.edgeGlowInset,
                bottom: NotchExpandedSheetStyle.edgeGlowInset,
                trailing: NotchExpandedSheetStyle.edgeGlowInset
            ))
        }
        // 整块内容裁进面板轮廓：底部操作条等自绘背景若不裁剪，会画到
        // 形状的圆角之上，把面板的下面两角顶成方角。
        .clipShape(HomeSpaceSheetShape(expansionProgress: 1))
        // 底缘的拖拽手柄：原版的 attachedSheetResizeGrip——按住往下/往上
        // 拖，调的是面板高度，存在 UserDefaults 里，跨启动保留。
        .overlay(alignment: .bottom) {
            NotchSheetResizeGripView()
        }
        // 同理不再挂视图侧动画：填充是常量，没有需要驱动的变化。
        .ignoresSafeArea()
    }
}

/// The sheet's bottom-edge resize grip (HeyClicky's `attachedSheetResizeGrip`
/// + persisted `attachedSheetSize`): dragging the bottom edge up/down changes
/// the sheet's height, persists it as a fraction of screen height, and
/// re-frames the live panel via `.clickyNotchSheetSizeDidChange`.
struct NotchSheetResizeGripView: View {

    @State private var dragStartHeight: CGFloat?
    @State private var isHoveringGrip = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // The visible handle: a short capsule that darkens on hover.
            Capsule()
                .fill(Color.white.opacity(isHoveringGrip ? 0.4 : 0.18))
                .frame(width: 40, height: 4)
                .padding(.bottom, 5)
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringGrip = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    // The cursor is on the sheet while dragging, so the screen
                    // under NSEvent.mouseLocation is the screen to size against.
                    guard let screen = NSScreen.screens.first(where: {
                        $0.frame.contains(NSEvent.mouseLocation)
                    }) else { return }

                    if dragStartHeight == nil {
                        dragStartHeight = NotchSupport.expandedSheetHeight(on: screen)
                    }
                    // The sheet hangs from the screen's top edge, so pulling
                    // the bottom edge down *grows* it — translation.y maps
                    // directly onto height.
                    NotchSupport.setExpandedSheetHeight(
                        dragStartHeight! + value.translation.height,
                        on: screen
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .pointerCursor()
    }
}
