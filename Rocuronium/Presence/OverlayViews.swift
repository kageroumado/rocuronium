import AppKit
import SwiftUI

// MARK: - Palette

/// The bioluminescent palette from the approved prototype (`Prototypes/overlay/`). The
/// overlay floats over an arbitrary desktop, so it commits to the dark-water look rather
/// than theming: the creature is its own light source.
enum JellyPalette {
    static let bellTop = Color(red: 0.929, green: 0.937, blue: 1.0)
    static let bellMid = Color(red: 0.545, green: 0.533, blue: 1.0)
    static let bellRim = Color(red: 0.345, green: 0.878, blue: 0.961)
    static let pink = Color(red: 1.0, green: 0.608, blue: 0.867)
    static let eye = Color(red: 0.149, green: 0.141, blue: 0.392)
    static let glow = Color(red: 0.47, green: 0.608, blue: 1.0)
    static let glowThinking = Color(red: 0.376, green: 0.863, blue: 0.98)
    static let glowAttention = Color(red: 0.906, green: 0.651, blue: 0.298)
    static let agent = Color(red: 0.49, green: 0.478, blue: 1.0)
    static let trail = Color(red: 0.345, green: 0.878, blue: 0.961).opacity(0.4)
}

// MARK: - The jellyfish

/// Draws the creature into a `GraphicsContext`, in the prototype's 64×84 design space.
///
/// Canvas-drawn rather than composed from SwiftUI shapes so the choreography — tentacle
/// wave phases, the propel squash, the attention curl — is one pure function of time and
/// phase, exactly like the prototype's keyframes.
@MainActor
enum JellyfishArt {
    static let designSize = CGSize(width: 64, height: 84)

    /// Smoothstep interpolation through keyframes, `t` in 0…1 — the prototype's CSS
    /// keyframe animations as a pure function.
    static func keyframed(_ t: Double, _ keys: [(Double, Double)]) -> Double {
        var previous = keys[0]
        for key in keys.dropFirst() {
            if t <= key.0 {
                let span = key.0 - previous.0
                let f = span > 0 ? (t - previous.0) / span : 1
                let eased = f * f * (3 - 2 * f)
                return previous.1 + (key.1 - previous.1) * eased
            }
            previous = key
        }
        return keys.last?.1 ?? 0
    }

    /// The whole-body motion — surge while acting, hover while thinking, drift otherwise —
    /// as a pure function of time. Keeping it a function rather than an inline transform is
    /// what lets a lagging part ask where the body *was*: Bitjelly's strands trail by
    /// evaluating this in the past instead of carrying a history buffer.
    ///
    /// The idle rotation is deliberately not here. It is a rotation, not a translation, and
    /// a strand only needs to know where its root travelled.
    static func bodyOffset(time: TimeInterval, phase: OverlayModel.Phase) -> CGPoint {
        switch phase {
        case .acting:
            let t = (time / 1.25).truncatingRemainder(dividingBy: 1)
            return CGPoint(x: 0, y: keyframed(t, [(0, 0), (0.16, 3), (0.46, -12), (0.78, -5), (1, 0)]))
        case .thinking, .needsHuman:
            return CGPoint(x: 0, y: -3.5 + 3.5 * cos(time * 2 * .pi / 2.6))
        default:
            return CGPoint(x: 4 * sin(time * 2 * .pi / 7), y: -4 - 4 * sin(time * 2 * .pi / 4.1))
        }
    }

    /// Draws the jellyfish scaled into `rect`. `lean` tilts the whole creature into its
    /// direction of travel (degrees); `moving` speeds the choreography up while escorting.
    ///
    /// The glow, the body motion and the lean are shared by every style — they are the
    /// state channel and the choreography, which must not change when the skin does. Only
    /// the creature itself is style-specific.
    static func draw(
        in context: GraphicsContext, rect: CGRect,
        time: TimeInterval, phase: OverlayModel.Phase,
        lean: Double = 0, moving: Bool = false,
        style: JellyStyle? = nil
    ) {
        // Resolved here, not in a default argument: default arguments are evaluated at the
        // call site, which for a `Canvas` renderer is a nonisolated context.
        let style = style ?? JellyStyleStore.shared.style
        var ctx = context
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / designSize.width, y: rect.height / designSize.height)

        // Halo — bioluminescence as the status channel.
        let (glowColor, glowPeriod, glowRange): (Color, Double, ClosedRange<Double>) = switch phase {
        case .thinking: (JellyPalette.glowThinking, 1.7, 0.5 ... 1.0)
        case .acting: (JellyPalette.glow, 1.25, 0.5 ... 1.0)
        case .needsHuman: (JellyPalette.glowAttention, 2.4, 0.4 ... 0.75)
        default: (JellyPalette.glow, moving ? 1.6 : 5.5, 0.3 ... 0.55)
        }
        let breathe = 0.5 + 0.5 * sin(time * 2 * .pi / glowPeriod)
        let glowOpacity = glowRange.lowerBound + (glowRange.upperBound - glowRange.lowerBound) * breathe
        let glowRadius = 34.0 + 4 * breathe
        ctx.fill(
            Path(ellipseIn: CGRect(x: 32 - glowRadius, y: 26 - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [glowColor.opacity(glowOpacity * 0.55), glowColor.opacity(0)]),
                center: CGPoint(x: 32, y: 26), startRadius: 0, endRadius: glowRadius,
            ),
        )

        // Whole-body motion: surge while acting, hover while thinking, drift otherwise.
        var body = ctx
        let offset = bodyOffset(time: time, phase: phase)
        body.translateBy(x: offset.x, y: offset.y)
        switch phase {
        case .acting, .thinking, .needsHuman: break
        default:
            body.translateBy(x: 32, y: 25)
            body.rotate(by: .degrees(1.5 * sin(time * 2 * .pi / 9)))
            body.translateBy(x: -32, y: -25)
        }
        if lean != 0 {
            body.translateBy(x: 32, y: 25)
            body.rotate(by: .degrees(lean))
            body.translateBy(x: -32, y: -25)
        }

        // The creature itself. Everything above this line — the halo, the body motion, the
        // lean — is shared, because that is the state channel and the choreography, and it
        // must not change when the skin does.
        switch style {
        case .classic:
            ClassicArt.drawBody(in: body, time: time, phase: phase, lean: lean, moving: moving)
        case .bitjelly:
            BitjellyArt.drawBody(in: body, time: time, phase: phase, lean: lean, moving: moving)
        case .ghost, .aurora, .sparkler:
            // The vector three are drawn about their own origin in their own units, so each
            // gets placed into the 64×84 box by its own anchor and scale. A creature with
            // long legs has to be drawn smaller to fit, and that is a real difference in how
            // big it looks — not a crop.
            var creature = body
            creature.translateBy(x: designSize.width / 2, y: style.anchorY)
            creature.scaleBy(x: style.unit, y: style.unit)
            switch style {
            case .ghost: GhostArt.draw(in: creature, time: time, phase: phase)
            case .aurora: AuroraArt.draw(in: creature, time: time, phase: phase)
            default: SparklerArt.draw(in: creature, time: time, phase: phase)
            }
        }
    }
}

/// The destination sigil: where the action lands, and how far the wind-up has gotten. A faint
/// breathing seal — outer ring, slowly rotating dashed rune ring, counter-rotating diamond
/// marks, a center point — with the progress arc kept at full strength on top, because the
/// wind-up is the interrupt window and must stay legible.
@MainActor
enum SigilArt {
    static func draw(
        in context: GraphicsContext, at center: CGPoint,
        progress: Double, elapsed: TimeInterval, time: TimeInterval
    ) {
        var ctx = context
        // Bloom in over the first beat, then breathe gently in place.
        let appear = min(1, max(0, elapsed / 0.15))
        let breathe = sin(time * 2 * .pi / 1.8)
        let scale = (0.85 + 0.15 * appear) * (1 + 0.04 * breathe)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.opacity = appear * (0.85 + 0.15 * breathe)

        func circle(_ radius: Double) -> Path {
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        }

        ctx.stroke(circle(26), with: .color(JellyPalette.agent.opacity(0.3)), lineWidth: 1.5)

        var runes = ctx
        runes.rotate(by: .degrees(time * 24))
        runes.stroke(
            circle(19.5),
            with: .color(JellyPalette.agent.opacity(0.45)),
            style: StrokeStyle(lineWidth: 1, dash: [7, 9]),
        )

        var marks = ctx
        marks.rotate(by: .degrees(-time * 16))
        for index in 0 ..< 4 {
            let angle = Double(index) * .pi / 2
            let point = CGPoint(x: 12.5 * cos(angle), y: 12.5 * sin(angle))
            var diamond = Path()
            diamond.move(to: CGPoint(x: point.x, y: point.y - 3))
            diamond.addLine(to: CGPoint(x: point.x + 2.2, y: point.y))
            diamond.addLine(to: CGPoint(x: point.x, y: point.y + 3))
            diamond.addLine(to: CGPoint(x: point.x - 2.2, y: point.y))
            diamond.closeSubpath()
            marks.fill(diamond, with: .color(JellyPalette.agent.opacity(0.5)))
        }

        ctx.fill(circle(2), with: .color(JellyPalette.agent.opacity(0.6)))

        var arc = Path()
        arc.addArc(
            center: .zero, radius: 26,
            startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress),
            clockwise: false,
        )
        ctx.stroke(arc, with: .color(JellyPalette.agent.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
}

/// The mascot in one state, gently animated in place — reused by the popover's hero card
/// and the demo stage's gallery.
struct JellyfishStateView: View {
    let phase: OverlayModel.Phase
    var dimmed = false
    /// `nil` follows whatever style the user picked; a value pins one, which is how the
    /// picker draws a live swatch of a style that is not currently chosen.
    var style: JellyStyle?
    @State private var hidden = false

    /// Where to put the 64×84 design box inside a view that clips, so the creature stays in
    /// its own frame while it swims.
    ///
    /// The overlay draws edge to edge and can overflow freely — it lives on a full-screen
    /// canvas with nothing to hit. Every *boxed* presentation (the picker's swatches, the
    /// popover hero, the demo gallery) clips, and `bodyOffset` moves the creature by up to
    /// 12 units up and 3 down out of 84, and 4 either side out of 64 — a seventh of the
    /// height. Drawn flush, every style therefore swam out of the top of its own tile on
    /// each acting pulse.
    ///
    /// So the box is placed inside a *travel* box big enough to hold the design box plus the
    /// full excursion, and the headroom is asymmetric because the surge is: far more of it
    /// is needed above than below.
    static func roomForTheBounce(in size: CGSize) -> CGRect {
        // A unit of slack past the measured excursion. Sized exactly to it, Koko's crown
        // and Remi's tentacle tips came within half a point of the edge, which is contained
        // but has nothing left for antialiasing.
        let up = 13.0, down = 4.0, side = 4.5
        let travel = CGSize(
            width: JellyfishArt.designSize.width + side * 2,
            height: JellyfishArt.designSize.height + up + down,
        )
        let k = min(size.width / travel.width, size.height / travel.height)
        let box = CGSize(width: JellyfishArt.designSize.width * k, height: JellyfishArt.designSize.height * k)
        return CGRect(
            x: (size.width - box.width) / 2,
            y: (size.height - travel.height * k) / 2 + up * k,
            width: box.width, height: box.height,
        )
    }

    var body: some View {
        // Read the store here rather than inside the Canvas closure: observation tracks
        // what `body` touches, and a pick made in the popover has to repaint the hero and
        // the demo gallery immediately, not on the next unrelated invalidation.
        let drawn = style ?? JellyStyleStore.shared.style
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: hidden)) { timeline in
            Canvas { context, size in
                JellyfishArt.draw(
                    in: context,
                    rect: Self.roomForTheBounce(in: size),
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    phase: phase,
                    style: drawn,
                )
            }
        }
        .opacity(dimmed ? 0.66 : 1)
        .pausedWhileWindowHidden($hidden)
    }
}

/// The sigil cycling its wind-up forever — the demo stage's preview of the charge ring.
struct SigilPreviewView: View {
    @State private var hidden = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: hidden)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let cycle = time.truncatingRemainder(dividingBy: 2.4)
                SigilArt.draw(
                    in: context,
                    at: CGPoint(x: size.width / 2, y: size.height / 2),
                    progress: min(1, cycle / 1.8),
                    elapsed: cycle,
                    time: time,
                )
            }
        }
        .pausedWhileWindowHidden($hidden)
    }
}

/// The spring that keeps the jellyfish a hand's width above-left of the pointer — escorting
/// it, never riding it — plus the fading wake the cursor leaves while it moves.
@MainActor
final class EscortState {
    static let trailLifetime = 0.75

    struct TrailDot {
        let point: CGPoint
        let time: TimeInterval
    }

    private(set) var position = CGPoint(x: -200, y: -200)
    private(set) var lean = 0.0
    private(set) var isMoving = false
    private(set) var trail: [TrailDot] = []

    private var lastUpdate: TimeInterval?
    private var lastTrailDrop: TimeInterval = 0
    private var lastCursor: CGPoint?

    func update(now: TimeInterval, cursor: CGPoint, target: CGPoint, escorting: Bool) {
        defer {
            lastUpdate = now
            lastCursor = cursor
        }
        guard let lastUpdate else {
            position = target
            return
        }
        let dt = min(0.05, max(0.001, now - lastUpdate))

        // The prototype's spring: exponential approach, with the lean derived from
        // horizontal velocity. Escorting is snappy; the drift home is a lazy float.
        let k = 1 - pow(escorting ? 0.0025 : 0.15, dt)
        let next = CGPoint(
            x: position.x + (target.x - position.x) * k,
            y: position.y + (target.y - position.y) * k,
        )
        let velocity = CGPoint(x: (next.x - position.x) / (dt * 1000), y: (next.y - position.y) / (dt * 1000))
        position = next
        lean = max(-13, min(13, velocity.x * 55))
        isMoving = escorting && hypot(velocity.x, velocity.y) > 0.04

        // The wake follows the *cursor*, not the jellyfish — motion history a human can
        // read at a glance. Dropped only while the agent is actually escorting: a perched
        // jellyfish must not decorate the human's own mousing.
        trail.removeAll { now - $0.time >= Self.trailLifetime }
        if escorting, let lastCursor, hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) > 1.5,
           now - lastTrailDrop > 0.036 {
            lastTrailDrop = now
            trail.append(TrailDot(point: cursor, time: now))
        }
    }
}
