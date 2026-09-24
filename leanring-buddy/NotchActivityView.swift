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
    /// VoiceWeb 外部语音会话**连接中**——从发起连接到页面回报 ready 之前。
    /// 左翼显示 Connecting，右翼是连接动画；挂断图标只在连上之后出现
    /// （用户 2026-09-23：「连接中的时候不知道……右侧不要有挂断按钮，而应该
    /// 是一个连接中的动画效果。只有连接成功之后，右侧才是挂断按钮」）。
    case externalConnecting
    /// VoiceWeb 外部语音会话进行中——连接成功到挂断的整个会话持续显示
    /// 「聊天中」（用户的要求：连接过程中两翼就持续显示，而不是短暂一闪）。
    case externalChatting
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
        // 2026-09-23：用户要求这一格也走英文——「如果用户正在语音聊天，把左侧的
        // "聊天中"也换成英文，比如 Chatting（C H A T I N G），显示效果会更好」。
        // 前四个状态本来就是英文，只有这一格是中文，在一排英文词里它自己就是那个
        // 不一致的东西。
        //
        // 括号里把字母拆开写曾经被读成了「拉大字距」的指令，于是这一格独有的
        // `.tracking(1.4)` 存在了一段时间 —— 用户 2026-09-24 指出那是误读：
        // 「chatting 这个单词，每个字母间距太大了，connecting 是正常的」。
        // 那些字母是在**描述字距拉开的样子**，不是在要求字距；六个状态词现在
        // 共用同一套字距（不设 `.tracking`，即 `0`），和 `Connecting` 一致。
        case .externalConnecting: return "Connecting"
        case .externalChatting: return "Chatting"
        }
    }

    var notchAnimationTint: Color {
        switch self {
        case .idle: return .white
        case .listening: return Color(red: 0.37, green: 0.92, blue: 0.83)   // #5EEAD4
        case .thinking: return Color(red: 0.77, green: 0.49, blue: 0.94)    // #C47CF0
        case .speaking: return Color(red: 0.98, green: 0.57, blue: 0.24)    // #FB923C
        case .transcribing: return Color(red: 0.72, green: 0.75, blue: 0.80) // #B7C0CC
        case .externalConnecting: return Color(red: 0.98, green: 0.75, blue: 0.24)  // #FBBF24 琥珀
        case .externalChatting: return Color(red: 0.29, green: 0.87, blue: 0.50)  // #4ADE80 绿
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
        case .externalConnecting: return Color(red: 0.30, green: 0.20, blue: 0.05)  // #4D330D 深琥珀
        case .externalChatting: return Color(red: 0.04, green: 0.27, blue: 0.15)  // #0B4627 深绿
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

    /// Corner radius of the sheet body's TOP two corners. Larger than the
    /// bottom pair at the user's request (「左上角和右上角的圆角再大一点，
    /// 现在的圆角太小」). The sheet hangs from the screen's top edge, so the
    /// top arcs show a sliver of the menu bar and wallpaper behind them — that
    /// is the intended look, and the panel's shadow is what keeps the
    /// silhouette readable against it.
    var topCornerRadius: CGFloat = 36

    /// Corner radius of the sheet body's BOTTOM two corners — the figure the
    /// user gave directly on 2026-09-23 (「上下都是 24」), unchanged when the
    /// top pair grew.
    var bottomCornerRadius: CGFloat = 24

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

        // All four corners round, the top pair wider than the bottom. Each
        // radius has to be clamped to half the body's shorter side or the arcs
        // cross each other: the collapse animation walks the body back down to
        // the resting pill (190×32), and not even 24pt fits in a 32pt-tall
        // body. 16 happened to equal exactly half of that height, which is why
        // this never showed up before the radius grew.
        let maximumFittingRadius = min(bodyWidth, bodyHeight) / 2
        let topRadius = min(topCornerRadius, maximumFittingRadius)
        let bottomRadius = min(bottomCornerRadius, maximumFittingRadius)

        path.move(to: CGPoint(x: bodyRect.minX + topRadius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - topRadius, y: bodyRect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + topRadius),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX - bottomRadius, y: bodyRect.maxY),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRect.minX + bottomRadius, y: bodyRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - bottomRadius),
            control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.minX + topRadius, y: bodyRect.minY),
            control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
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
    ///
    /// 2026-09-23：两个数字搬去了 `NotchSupport`。语音聊天进行中右翼同时是
    /// **挂断按钮**，`NotchWindowController.handleGlobalClick` 要用同一对数
    /// 反推出它的命中矩形（`NotchSupport.restingTrailingWingFrame`）—— 画的
    /// 和点的是两处代码，数字只留一份才不会改了一边忘了另一边。
    private static var leadingWingWidth: CGFloat { NotchSupport.leadingWingWidth }
    private static var trailingWingWidth: CGFloat { NotchSupport.trailingWingWidth }

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
                // Negative spacing: each wing overlaps the middle segment by
                // 2pt. With flush adjacency (spacing 0) the wing's edge and
                // the pill's edge antialias independently at the SAME
                // coordinate, and whenever that coordinate lands on a pixel
                // boundary the pair leaves a see-through slit — a full-height
                // hairline showing the desktop through the band on BOTH sides
                // of the notch (recorded 2026-09-23 from a 30fps screen
                // recording of the live animation; the user reported it as
                // 「刘海的左侧和右侧分别有一个空白间隙」). With the overlap,
                // every one of those four edges lands inside the other view's
                // solid black — black-on-black — so the slit cannot exist and
                // the wings read as growing out of the notch's interior.
                // The layout still resolves to the pill EXACTLY centered at
                // rest (both wings 0 wide: pill_left = center + 0 − 2 −
                // (0 + 0 − 4)/2 … = center), and the ±1pt drift mid-animation
                // is black-on-black and invisible.
                HStack(spacing: -2) {
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

    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion

    /// 连接成功那一下的弹入倍数。1 是常态；`.externalChatting` 到达时先落到
    /// 0.5 再弹回 1，作为「连上了」的一次性确认动画。
    ///
    /// 为什么挂在相位变化上：`.externalConnecting → .externalChatting` 只在
    /// 会话真正连上之后发生（`VoiceChatController`
    /// 的成功分支），所以这个 onChange 天生就是"真连上才响一次"。而这一格
    /// 原本没有任何动画 —— 唯一的 `.animation` 驱动的是两翼**宽度**，连接成功
    /// 时宽度本来就已经到位，所以那一下是纯粹的、没有反馈的瞬间切换。
    @State private var connectPulseScale: CGFloat = 1

    /// The wing's outer bottom corner radius. Measured 2026-09-22 off the
    /// user's target screenshot (L29938, Listening, 1.635 px/pt): a corner of
    /// roughly 14–16 pt, notably larger than the resting pill's 6. Briefly
    /// set to 0 on 2026-09-23 while chasing the corner's see-through arc —
    /// the user then asked for the rounding back (「应该添加圆角，你给删除了」),
    /// so 14 pt stands. The inner edge stays square: it meets the middle
    /// segment, and a rounded seam there is G8's notch-shaped gap.
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
                    //
                    // 2026-09-23：语音聊天进行中这一格换成一颗粒红色的挂断
                    // 图标。它同时是**按钮** —— 这块区域可以直接点，点了就挂断，
                    // 不必展开刘海（用户第 6 条：「菜单栏刘海屏右侧应显示一个
                    // 挂断动画，或者保留菜单栏当前样式风格，把它做成挂断按钮，
                    // 用户可以直接点击挂断，不必展开刘海屏再点击挂断」）。命中
                    // 矩形由 `NotchSupport.restingTrailingWingFrame` 给出。
                    Group {
                        if phase == .externalChatting {
                            NotchHangUpGlyph()
                        } else {
                            NotchActivityView(
                                phase: phase,
                                audioHistoryProvider: audioHistoryProvider,
                                tint: phase.notchAnimationTint
                            )
                        }
                    }
                    .frame(height: 20)
                    .scaleEffect(connectPulseScale)
                    .onChange(of: phase) { _, newPhase in
                        guard newPhase == .externalChatting, !shouldReduceMotion else { return }
                        // 落下去不带动画（瞬间到 0.5），再弹回 1 —— 这一落一弹
                        // 就是那一下「连上了」的观感。约 0.32 秒，和挂断音同时。
                        connectPulseScale = 0.5
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                            connectPulseScale = 1
                        }
                    }
                    .padding(.trailing, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }
}

/// 语音聊天进行中画在右翼上的那颗挂断图标：话筒向下 + 一圈呼吸的红色光晕。
///
/// 它不只是装饰——那一整块区域是一颗真的按钮，在收起状态下直接点击就挂断
/// （`NotchWindowController.handleGlobalClick` 判的是
/// `NotchSupport.restingTrailingWingFrame`）。所以它必须一眼看上去像能按的
/// 东西：`phone.down.fill` 是通话里"挂断"的通用符号，呼吸只是让它在一片黑里
/// 被注意到，不做任何会让人误判成"正在拨号"的动作。
///
/// **2026-09-23 三处放大，一次都没有加宽两翼**：用户的原话是「右侧的挂断按钮，
/// 可以把光晕或亮度变得再大一点，现在这个动画效果或者挂断按钮有点小」，紧接着
/// 又补了一句「比如这个红色的挂断按钮，是不是可以再大一点？」，并在同一段里立了
/// 约束——「整个弹出的弹窗一定要在刘海屏左右两侧宽度固定的情况下，在宽度内做文字
/// 和图标调整，不要增加宽度，只调整图标大小和整个动画」。所以两翼的 88pt 一点没动，
/// 变大的是三样看得见的东西：
///
///   1. 图标 12 → 15pt；
///   2. 光晕从**只有一层 `.shadow`** 变成两层：底下加一颗 30pt 的实心圆、模糊 7pt
///      做底光，外面再叠 `.shadow`。单靠 shadow 拉大半径只会得到一圈越扩越淡的雾，
///      看不出"更大"；实心圆撑出明确的体积，shadow 再补它外缘的辉光。这颗圆挂在
///      `.background` 上（只画不占位），所以图标本身没有被挪动——理由见下面那段；
///   3. 呼吸的幅度与亮度一起抬：暗端 0.3 → 0.45、亮端 0.85 → 1.0，半径 3/7 → 4/11，
///      缩放 0.94/1.08 → 0.96/1.10。暗端提起来是关键——原来的 0.3 在脉冲谷底几乎
///      看不见，用户看到的"小"有一半是"有一半时间根本没在亮"。
///
/// 光晕直径 44pt（30 + 上下各 7 的模糊）比 32pt 的带子高，会被外面那层
/// `clipShape(outline)` 裁掉——这正是参考页里那圈光晕的做法（顶到底都被带子切），
/// 不是需要回避的溢出。
private struct NotchHangUpGlyph: View {

    @State private var isPulsing = false

    /// 和 `NotchActivityPhase.externalChatting` 的状态色同源（#4ADE80 是聊天
    /// 中的绿），这里是它的对立面——挂断用红，因为按下去结束的正是那个绿。
    private static let hangUpRed = Color(red: 1.0, green: 0.42, blue: 0.38)

    var body: some View {
        Image(systemName: "phone.down.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Self.hangUpRed)
            // 光晕挂在 `.background` 上，**就是为了不参与布局**。这一格的高宽由上面
            // 那层 `.frame(height: 20)` 和右翼的 `.padding(.trailing, 10)` 决定，而
            // 那个 padding 是四个相位共用的——挂断之外的三格（波形 / 脉冲 / 均衡器）
            // 也走同一个 Group。给图标加一个显式的 `.frame(width: 30)` 会把它的中心
            // 从距右缘 ~19pt 推到 ~25pt，等于顺手把挂断图标挪了位置；而 `.background`
            // 只画不定尺寸，光晕尽管往外铺，图标自己还站在原来的地方。
            .background(
                Circle()
                    .fill(Self.hangUpRed.opacity(isPulsing ? 0.42 : 0.16))
                    .frame(width: 30, height: 30)
                    .blur(radius: 7)
            )
            .shadow(
                color: Self.hangUpRed.opacity(isPulsing ? 1.0 : 0.45),
                radius: isPulsing ? 11 : 4
            )
            .scaleEffect(isPulsing ? 1.10 : 0.96)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
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
        case .externalConnecting:
            // 连接中：琥珀色脉冲点。不用等化器（那是"已经在说话"的形状），
            // 点的节律读作"正在握手"，和 thinking 的语义同族但颜色不同。
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                NotchThinkingDotsView(timelineDate: timeline.date, tint: tint)
            }
        case .externalChatting:
            // 整个会话持续显示：绿色等化器比静止图形更像「在聊着」
            TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timeline in
                NotchSpeakingEqualizerView(timelineDate: timeline.date, tint: tint)
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
    /// 「打开」按钮让位用的两半 —— 一路透传到 `AgentSessionView`，见
    /// `NotchSheetRootView` 的同名属性。
    var hideSheetAction: () -> Void
    var revealSheetAction: () -> Void
    var companionManager: CompanionManager
    /// 展开态那条状态带的几何。由 `NotchWindowController` 在装配这个视图时算好
    /// （它手里才有 `NSScreen`），见 `NotchExpandedWingBand`。
    var notchBandHeight: CGFloat = 0
    var notchCenterXInWindow: CGFloat = 0
    var wingBandWidth: CGFloat = 0
    var restingPillWidth: CGFloat = 0

    var body: some View {
        if panelModel.isExpanded {
            NotchExpandedSheetView(
                panelModel: panelModel,
                audioHistoryProvider: audioHistoryProvider,
                collapseAction: collapseAction,
                hideSheetAction: hideSheetAction,
                revealSheetAction: revealSheetAction,
                companionManager: companionManager
            )
            // 状态带压在整块面板**之上**（用户 2026-09-24：「在整个对话界面顶部，
            // 刘海屏左右两侧应该持续显示 chatting 和挂断按钮，并覆盖在窗口上方」）。
            // 收起态那条带子是 `NotchPillRootView` 画的，展开态这里补上同一条，
            // 两态的几何由 `NotchSupport` 的同一批函数给出，所以切换时不跳。
            .overlay(alignment: .top) {
                if panelModel.activityPhase != .idle {
                    NotchExpandedWingBand(
                        phase: panelModel.activityPhase,
                        audioHistoryProvider: audioHistoryProvider,
                        notchCenterXInWindow: notchCenterXInWindow,
                        notchBandHeight: notchBandHeight,
                        wingBandWidth: wingBandWidth,
                        restingPillWidth: restingPillWidth,
                        hangUpAction: {
                            companionManager.voiceChatController.disconnectCurrentSession()
                        }
                    )
                }
            }
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

// MARK: - Expanded-state wing band

/// 展开态下压在面板之上的那条状态带（2026-09-24）。
///
/// **为什么需要它。** 收起态的窗口里，`NotchPillRootView` 画了「左翼 + 中段 +
/// 右翼」这条带子；展开态的窗口里 `NotchPanelRootSwitchingView` 只画
/// `NotchExpandedSheetView` —— 那条带子**根本不参与布局**。于是用户在对话界面上
/// （面板几乎总是展开的）看不到任何状态：语音聊天连着的时候看不见「Chatting」和
/// 挂断按钮，普通对话时看不见 Listening / Thinking / Speaking。用户 2026-09-24
/// 的原话是「在整个对话界面顶部，刘海屏左右两侧应该持续显示 chatting 和挂断按钮，
/// 并覆盖在窗口上方。现在要么没有显示，要么被窗口覆盖了」。
///
/// **位置与收起态逐像素一致**，办法是把带子放回一个与收起窗口**同宽**的虚拟窗口
/// 里居中（`.position` 定的是中心点），而不是在展开窗口里另推一套几何。所以两态
/// 之间切换时带子不会横向跳一下，收起态那条翼和展开态这条翼落在同一排像素上。
///
/// **只有右翼那颗按钮吃点击。** 面板展开时它自己是接收事件的（`ignoresMouseEvents`
/// 在 `expand` 里被翻成 false），所以挂断这一下走真实控件；而带子的装饰部分必须
/// 完全不吃点击，否则「再点一次刘海收起」（`handleGlobalClick` 展开分支的第一条）
/// 会被它吞掉，用户就会发现刘海点不动了。做法是 ZStack 分两层：装饰层整体
/// `.allowsHitTesting(false)`，按钮是它的兄弟节点，各管各的命中。
///
/// 右翼的命中矩形由 `NotchSupport.trailingWingOriginX(inWindowOfWidth:)` 给出 ——
/// 和收起态点击命中的 `restingTrailingWingFrame` 同一个函数，所以画的和点的不会
/// 各推一遍几何、错位了还不报错。
struct NotchExpandedWingBand: View {

    let phase: NotchActivityPhase
    var audioHistoryProvider: () -> [CGFloat]
    /// 刘海中心在展开窗口里的 x（窗口左上角为 0）。
    let notchCenterXInWindow: CGFloat
    /// 刘海本身的高度 —— 也是收起态两条翼的高度。
    let notchBandHeight: CGFloat
    /// 收起态那条带子的总宽和它中段的宽，都由 `NotchSupport` 给出。
    let wingBandWidth: CGFloat
    let restingPillWidth: CGFloat
    /// 语音聊天进行中，右翼是一颗真的挂断按钮。
    var hangUpAction: (() -> Void)?

    /// 右翼左边界在**展开窗口**里的 x。
    ///
    /// 带子整体居中在刘海中心上，所以带子的左边界要先算出来，再加上
    /// `trailingWingOriginX(inBandOfWidth:)` —— 那个函数给的是右翼在**带子里**
    /// 的偏移。传的是带子宽，不是窗口宽：两者差两个 `activeFlankWidth`。
    private var trailingWingLeftXInWindow: CGFloat {
        let bandLeftX = notchCenterXInWindow - wingBandWidth / 2
        return bandLeftX + NotchSupport.trailingWingOriginX(inBandOfWidth: wingBandWidth)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 装饰层：整条都不吃点击 —— 见类型注释里「只有右翼那颗按钮吃点击」。
            HStack(spacing: -2) {
                NotchWingView(
                    phase: phase,
                    audioHistoryProvider: audioHistoryProvider,
                    isLeading: true
                )
                .frame(width: NotchSupport.leadingWingWidth, height: notchBandHeight)
                .clipped()

                // 中段永远是方的（radius 0）：带子只要出场，中段和两条翼就是
                // 一整条黑带，圆角只留在两个外端 —— 与 `NotchPillRootView` 在
                // `isActive` 时的取值一致，所以两态看起来是同一条带子。
                PillShape(bottomCornerRadius: 0)
                    .fill(Color.black)
                    .frame(width: restingPillWidth, height: notchBandHeight)

                NotchWingView(
                    phase: phase,
                    audioHistoryProvider: audioHistoryProvider,
                    isLeading: false
                )
                .frame(width: NotchSupport.trailingWingWidth, height: notchBandHeight)
                .clipped()
            }
            // `.position` 把视图的**中心**放在这一点上，而收起窗口的中心正是
            // 刘海的中心，所以这一行就是「和收起态对齐」的全部。
            .position(x: notchCenterXInWindow, y: notchBandHeight / 2)
            .allowsHitTesting(false)

            // 语音聊天进行中：右翼那颗红色的挂断，是这一层唯一吃点击的东西。
            if phase == .externalChatting, let hangUpAction {
                Button(action: hangUpAction) {
                    // 图形由下面的装饰层画（`NotchHangUpGlyph` 在
                    // `NotchWingView` 里），这里只要一块透明的命中区 —— 用
                    // `Color.clear` 加 `contentShape` 而不是让按钮自己画，
                    // 免得同一颗图标有两份来源。
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: NotchSupport.trailingWingWidth, height: notchBandHeight)
                .position(
                    x: trailingWingLeftXInWindow + NotchSupport.trailingWingWidth / 2,
                    y: notchBandHeight / 2
                )
                .help("挂断")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: notchBandHeight, alignment: .topLeading)
    }
}

// MARK: - Expanded sheet (Phase C placeholder content)

/// 展开面板的配色。
///
/// 面板表面 = 参考页 `.window` 的 `rgba(24,24,28,.94)`。这里**只有**一块皮：
/// 早期版本还有一条蓝紫渐变，取自 `design-preview/notch-glow-expand.html`，
/// 只当左、右、下三边露出的 1.5pt 边光用、从没铺过面——用户 2026-09-23
/// 要求删掉那圈外框高亮线，渐变的四个取色和两个端点一起删了。
/// internal（不再是 private）：`NotchWindowController` 的展开驻留层要在
/// SwiftUI 内容画出来之前，先用同一份表面色和底角半径铺出一块临时的
/// 「空面板皮」，颜色和圆角只能有一份真相。
enum NotchExpandedSheetStyle {

    /// 面板皮肤的深色底——2026-09-23 UI 化改造换成参考页 `.window` 的
    /// `rgba(24,24,28,.94)` 原值（旧值 rgba(14,14,13,.92) 是另一份 demo
    /// 的 `.skin`）。
    ///
    /// **那 6% 的透明后来被用户去掉了**：参考页的窗口浮在它自己的页面背景
    /// 上，透一点出来是设计的一部分；而这里的「背景」是用户的桌面 —— 透出
    /// 来的是壁纸和别人的窗口，用户 2026-09-23 报「现在是透明状态」，要求
    /// 「整个弹出窗口调整为完全不透明」。所以这一层、以及三处侧栏底，全部
    /// 取不透明值。
    static let surfaceColor = Color(red: 24 / 255, green: 24 / 255, blue: 28 / 255)

    /// 面板左上、右上两角的圆角半径（用户 2026-09-23 要求「再大一点」，
    /// 因为面板顶边就是屏幕上沿，顶角大一点会多露出一点菜单栏——正是用户
    /// 要的那圈弧）。
    static let sheetTopCornerRadius: CGFloat = 36

    /// 面板左下、右下两角的圆角半径——用户直接给的数：24。
    static let sheetBottomCornerRadius: CGFloat = 24
}

/// The expanded sheet: the `HomeSpaceSheetShape` body carrying the session
/// sidebar and the conversation/settings content (`NotchSheetRootView`), with
/// the live activity drawing in the header and the close button.
struct NotchExpandedSheetView: View {

    @ObservedObject var panelModel: NotchPanelModel
    var audioHistoryProvider: () -> [CGFloat]
    var collapseAction: () -> Void
    var hideSheetAction: () -> Void
    var revealSheetAction: () -> Void
    var companionManager: CompanionManager

    /// 参考页 01 中心缩放的内容入场（'line' 模式）：窗口本体沿 frame 驱动
    /// 器的缩放路径长出来，内容块则延迟 230ms、从「+8pt 下移 + 8pt 模糊 +
    /// 全透明」浮现到清晰（0.45s ease）——「内容整块错峰浮现」。视图在
    /// 每次展开时重新插入（root 切换分支），所以 @State 每次都从入场态
    /// 重新走一遍；折叠期间不驻留，不会中途触发。
    @State private var hasContentSettledIn = false
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // 面板底色就是这一层。以前这里有三层：一层渐变只当三边露出的
            // 1.5pt 边光、一层让出边光的深色皮、一层内容。用户 2026-09-23
            // 要求「把整个弹出窗口的外边框高亮线删掉，不需要这个边框线」，
            // 于是边光整层去掉——少一层，也少一次裁剪。
            NotchExpandedSheetStyle.surfaceColor

            // 仿 HeyClicky：会话侧栏通高，顶栏属于内容区，都在
            // NotchSheetRootView 内部。原来这里还要让出边光那 1.5pt，
            // 边光删掉后内容直接铺满。
            NotchSheetRootView(
                panelModel: panelModel,
                companionManager: companionManager,
                collapseAction: collapseAction,
                hideSheetAction: hideSheetAction,
                revealSheetAction: revealSheetAction,
                audioHistoryProvider: audioHistoryProvider
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 内容入场两件套：透明、模糊，同时归零。reduceMotion 时直接落在
            // 清晰态。
            //
            // 参考页的三件套还有第三件 —— translateY(8px)（.unit.line 的
            // from{transform:translateY(8px)}，仓库自己的移植记录
            // design-preview/中心缩放-重设计演示.html:129 写的就是它）——这里
            // **故意不移植**，2026-09-24：参考页那 8px 是在一个静态演示面板上
            // 播的，没有滚动、没有实时列表，谁也不挡谁；这里是活的对话列，
            // onAppear 的滚动和这 8pt 的上滑叠加（SwiftUI 接口证实
            // _OffsetEffect 可插值），滚动 0.2s 硬停、偏移继续到 0.34s——
            // 两个停止点被眼睛读成「弹一下」，即用户报的
            // 「所有消息整体向上抖动一下，然后又下来」，左右两列都有
            // （侧栏没有滚动，它看到的抖动只能来自这个偏移）。淡入 + 模糊
            // 仍然是参考页的入场语言；丢掉的只有那 8pt。
            .opacity(hasContentSettledIn ? 1 : 0)
            .blur(radius: hasContentSettledIn ? 0 : 8)
            .onAppear {
                guard !shouldReduceMotion else {
                    hasContentSettledIn = true
                    return
                }
                // 延迟跟着用户选的窗口样式走：参考页里 02 幕布垂落配 140ms、
                // 01 中心缩放配 230ms，各自跟自己的窗口动画成对
                // （见 NotchSupport.expansionContentEntranceDelay）。用幕布那
                // 个延迟配缩放，内容会在板子还只有一半大的时候就完整画出来，
                // 两个动画看起来是两件事。样式在这里现读一次：它跟
                // `beginExpansion` 读的是同一个值，而中间没有人能改设置。
                let appSettingsSnapshot = AppSettingsStore.snapshot()
                let entranceDelay = appSettingsSnapshot.expansionContentEntranceDelayInForce(
                    appSettingsSnapshot.notchExpansionSpeedMultiplier
                )(appSettingsSnapshot.windowExpansionStyle)
                // The entrance animation itself is scaled with the window: at 2×
                // the panel grows twice as fast, so a 0.45 s entrance would finish
                // long after a 0.215 s reveal had landed. Same duration, same curve
                // family, same relative shape — just faster with everything else.
                withAnimation(.easeOut(duration: 0.45 / appSettingsSnapshot.notchExpansionSpeedMultiplier).delay(entranceDelay)) {
                    hasContentSettledIn = true
                }
            }
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
