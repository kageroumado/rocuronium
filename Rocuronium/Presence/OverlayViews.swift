import AppKit
import SwiftUI

/// The visible-agent overlay: whisper tint, centered bezel, jellyfish escort, and the
/// click effects. Everything renders from one `OverlayModel`, so the surfaces cannot
/// disagree about what the agent is doing.
struct OverlayRootView: View {
    let model: OverlayModel

    var body: some View {
        ZStack(alignment: .bottom) {
            // The from-across-the-room cue: ~5% dim, never enough to hide the work.
            Rectangle()
                .fill(Color.black.opacity(0.05))
            OverlayEffectsView(model: model)
            BezelView(model: model)
                .padding(.bottom, 52)
        }
        .ignoresSafeArea()
    }
}

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

    private struct Tentacle {
        let start: CGPoint
        let curves: [(c1: CGPoint, c2: CGPoint, to: CGPoint)]

        var path: Path {
            var path = Path()
            path.move(to: start)
            for curve in curves {
                path.addCurve(to: curve.to, control1: curve.c1, control2: curve.c2)
            }
            return path
        }
    }

    private static let longTentacles: [Tentacle] = [
        .init(start: .init(x: 17, y: 43), curves: [
            (.init(x: 15.5, y: 52), .init(x: 19, y: 59), .init(x: 15.5, y: 68)),
            (.init(x: 14, y: 72.5), .init(x: 16, y: 77), .init(x: 14.5, y: 80)),
        ]),
        .init(start: .init(x: 24.5, y: 44.5), curves: [
            (.init(x: 24, y: 54), .init(x: 21.5, y: 60), .init(x: 24.5, y: 69)),
            (.init(x: 25.8, y: 73), .init(x: 24, y: 77.5), .init(x: 25, y: 81)),
        ]),
        .init(start: .init(x: 32, y: 45), curves: [
            (.init(x: 32.5, y: 55), .init(x: 30, y: 62), .init(x: 33, y: 71)),
            (.init(x: 34, y: 74.5), .init(x: 32.5, y: 79), .init(x: 33.5, y: 82)),
        ]),
        .init(start: .init(x: 39.5, y: 44.5), curves: [
            (.init(x: 40.5, y: 54), .init(x: 38, y: 60), .init(x: 41, y: 68)),
            (.init(x: 42.3, y: 72), .init(x: 40.5, y: 76.5), .init(x: 41.5, y: 80)),
        ]),
        .init(start: .init(x: 47, y: 43), curves: [
            (.init(x: 48.5, y: 52), .init(x: 45.5, y: 59), .init(x: 48.5, y: 67)),
            (.init(x: 50, y: 71), .init(x: 48.5, y: 75.5), .init(x: 49.5, y: 79)),
        ]),
    ]

    /// The needs-human posture: tentacles curled up — visibly holding, touching nothing.
    private static let curledTentacles: [Tentacle] = [
        .init(start: .init(x: 17, y: 43), curves: [
            (.init(x: 14, y: 47), .init(x: 16, y: 51), .init(x: 19.5, y: 50)),
            (.init(x: 22, y: 49.2), .init(x: 20.5, y: 45.5), .init(x: 18, y: 46.5)),
        ]),
        .init(start: .init(x: 24.5, y: 44.5), curves: [
            (.init(x: 22.5, y: 49.5), .init(x: 25, y: 53), .init(x: 28, y: 51.5)),
            (.init(x: 30.2, y: 50.4), .init(x: 28.5, y: 47), .init(x: 26.2, y: 48)),
        ]),
        .init(start: .init(x: 32, y: 45), curves: [
            (.init(x: 30.5, y: 50.5), .init(x: 33.5, y: 54), .init(x: 36.2, y: 52)),
            (.init(x: 38.2, y: 50.5), .init(x: 36, y: 47.2), .init(x: 34, y: 48.5)),
        ]),
        .init(start: .init(x: 39.5, y: 44.5), curves: [
            (.init(x: 38, y: 49.5), .init(x: 41, y: 52.8), .init(x: 43.8, y: 51)),
            (.init(x: 45.8, y: 49.6), .init(x: 43.8, y: 46.4), .init(x: 41.8, y: 47.6)),
        ]),
        .init(start: .init(x: 47, y: 43), curves: [
            (.init(x: 45.5, y: 47.5), .init(x: 48, y: 51), .init(x: 51, y: 49.5)),
            (.init(x: 53.2, y: 48.4), .init(x: 51.4, y: 45), .init(x: 49.2, y: 46.2)),
        ]),
    ]

    private static let bellPath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 32, y: 7))
        path.addCurve(to: CGPoint(x: 7.5, y: 31), control1: CGPoint(x: 16, y: 7), control2: CGPoint(x: 7.5, y: 20))
        path.addCurve(to: CGPoint(x: 17, y: 41), control1: CGPoint(x: 7.5, y: 37), control2: CGPoint(x: 12, y: 40.5))
        path.addCurve(to: CGPoint(x: 32, y: 42), control1: CGPoint(x: 22, y: 41.5), control2: CGPoint(x: 26.5, y: 42))
        path.addCurve(to: CGPoint(x: 47, y: 41), control1: CGPoint(x: 37.5, y: 42), control2: CGPoint(x: 42, y: 41.5))
        path.addCurve(to: CGPoint(x: 56.5, y: 31), control1: CGPoint(x: 52, y: 40.5), control2: CGPoint(x: 56.5, y: 37))
        path.addCurve(to: CGPoint(x: 32, y: 7), control1: CGPoint(x: 56.5, y: 20), control2: CGPoint(x: 48, y: 7))
        path.closeSubpath()
        return path
    }()

    /// Smoothstep interpolation through keyframes, `t` in 0…1 — the prototype's CSS
    /// keyframe animations as a pure function.
    private static func keyframed(_ t: Double, _ keys: [(Double, Double)]) -> Double {
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

    /// Draws the jellyfish scaled into `rect`. `lean` tilts the whole creature into its
    /// direction of travel (degrees); `moving` speeds the choreography up while escorting.
    static func draw(
        in context: GraphicsContext, rect: CGRect,
        time: TimeInterval, phase: OverlayModel.Phase,
        lean: Double = 0, moving: Bool = false
    ) {
        var ctx = context
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / designSize.width, y: rect.height / designSize.height)

        let pulsing = phase == .acting || moving

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
        switch phase {
        case .acting:
            let t = (time / 1.25).truncatingRemainder(dividingBy: 1)
            body.translateBy(x: 0, y: keyframed(t, [(0, 0), (0.16, 3), (0.46, -12), (0.78, -5), (1, 0)]))
        case .thinking, .needsHuman:
            body.translateBy(x: 0, y: -3.5 + 3.5 * cos(time * 2 * .pi / 2.6))
        default:
            body.translateBy(x: 4 * sin(time * 2 * .pi / 7), y: -4 - 4 * sin(time * 2 * .pi / 4.1))
            body.translateBy(x: 32, y: 25)
            body.rotate(by: .degrees(1.5 * sin(time * 2 * .pi / 9)))
            body.translateBy(x: -32, y: -25)
        }
        if lean != 0 {
            body.translateBy(x: 32, y: 25)
            body.rotate(by: .degrees(lean))
            body.translateBy(x: -32, y: -25)
        }

        // Tentacles first, behind the bell. Lagging wave: each has its own period and phase.
        let tentacles = phase == .needsHuman ? curledTentacles : longTentacles
        let periods = [3.1, 3.5, 2.9, 3.4, 3.2]
        let offsets = [0.0, 0.35, 0.6, 0.2, 0.5]
        let tentacleGradient = Gradient(colors: [JellyPalette.bellRim, JellyPalette.bellMid, JellyPalette.pink])
        for (index, tentacle) in tentacles.enumerated() {
            let period = pulsing ? periods[index] * 0.42 : periods[index]
            let sway = 3.5 * sin((time + offsets[index]) * 2 * .pi / period)
            var tctx = body
            tctx.translateBy(x: tentacle.start.x, y: tentacle.start.y)
            tctx.rotate(by: .degrees(sway))
            tctx.translateBy(x: -tentacle.start.x, y: -tentacle.start.y)
            tctx.stroke(
                tentacle.path,
                with: .linearGradient(
                    tentacleGradient,
                    startPoint: CGPoint(x: tentacle.start.x, y: 43),
                    endPoint: CGPoint(x: tentacle.start.x, y: 82),
                ),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round),
            )
        }

        // The bell, squashing-and-stretching toward the target while acting (the propel —
        // the pre-action telegraph the design replaced the ghost's glancing eyes with).
        var bell = body
        if pulsing {
            let t = (time / 1.25).truncatingRemainder(dividingBy: 1)
            let sx = keyframed(t, [(0, 1), (0.16, 1.14), (0.42, 0.93), (0.7, 1.02), (1, 1)])
            let sy = keyframed(t, [(0, 1), (0.16, 0.8), (0.42, 1.09), (0.7, 0.98), (1, 1)])
            bell.translateBy(x: 32, y: 21)
            bell.scaleBy(x: sx, y: sy)
            bell.translateBy(x: -32, y: -21)
        }
        bell.fill(
            bellPath,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: JellyPalette.bellTop.opacity(0.92), location: 0),
                    .init(color: JellyPalette.bellMid.opacity(0.92), location: 0.46),
                    .init(color: JellyPalette.bellRim.opacity(0.92), location: 0.88),
                ]),
                center: CGPoint(x: 32, y: 16), startRadius: 0, endRadius: 40,
            ),
        )
        bell.fill(
            Path(ellipseIn: CGRect(x: 17, y: 13, width: 30, height: 22)),
            with: .color(.white.opacity(0.22)),
        )
        // Cute eyes with glints, and the pink cheeks.
        for eyeX in [26.0, 38.0] {
            bell.fill(Path(ellipseIn: CGRect(x: eyeX - 2.6, y: 29.9, width: 5.2, height: 5.2)), with: .color(JellyPalette.eye))
            bell.fill(Path(ellipseIn: CGRect(x: eyeX + 0.05, y: 30.75, width: 1.7, height: 1.7)), with: .color(.white))
        }
        for cheekX in [20.5, 43.5] {
            bell.fill(
                Path(ellipseIn: CGRect(x: cheekX - 1.5, y: 34.5, width: 3, height: 3)),
                with: .color(JellyPalette.pink.opacity(0.7)),
            )
        }
    }
}

// MARK: - Effects + escort

/// The full-screen effects layer: charge rings, click ripples, the cursor's wake, and the
/// jellyfish spring-following the real cursor.
///
/// The escort reads `NSEvent.mouseLocation` per frame — zero engine coupling: the overlay
/// watches the same cursor the human does, whoever is moving it.
struct OverlayEffectsView: View {
    let model: OverlayModel
    @State private var follow = EscortState()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate

                // Cocoa's cursor is bottom-left global; the window covers the primary
                // screen, so flipping through the view height lands in view space.
                let mouse = NSEvent.mouseLocation
                let cursor = CGPoint(x: mouse.x, y: size.height - mouse.y)
                follow.update(now: now, cursor: cursor)

                for dot in follow.trail {
                    let age = now - dot.time
                    guard age < EscortState.trailLifetime else { continue }
                    let fade = 1 - age / EscortState.trailLifetime
                    let radius = 4.5 * (0.22 + 0.78 * fade)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: dot.point.x - radius, y: dot.point.y - radius,
                            width: radius * 2, height: radius * 2,
                        )),
                        with: .color(JellyPalette.trail.opacity(fade)),
                    )
                }

                if let ring = model.chargeRing {
                    let progress = min(1, timeline.date.timeIntervalSince(ring.start) / ring.duration)
                    let radius = 24.0
                    let track = Path(ellipseIn: CGRect(
                        x: ring.point.x - radius, y: ring.point.y - radius,
                        width: radius * 2, height: radius * 2,
                    ))
                    context.stroke(track, with: .color(JellyPalette.agent.opacity(0.25)), lineWidth: 3)
                    var arc = Path()
                    arc.addArc(
                        center: ring.point, radius: radius,
                        startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress),
                        clockwise: false,
                    )
                    context.stroke(arc, with: .color(JellyPalette.agent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }

                for ripple in model.ripples {
                    let age = timeline.date.timeIntervalSince(ripple.start)
                    guard age >= 0, age < 0.55 else { continue }
                    let progress = age / 0.55
                    let radius = 11 + 20 * progress
                    context.stroke(
                        Path(ellipseIn: CGRect(
                            x: ripple.point.x - radius, y: ripple.point.y - radius,
                            width: radius * 2, height: radius * 2,
                        )),
                        with: .color(JellyPalette.agent.opacity(0.9 * (1 - progress))),
                        lineWidth: 2.5,
                    )
                }

                JellyfishArt.draw(
                    in: context,
                    rect: CGRect(x: follow.position.x, y: follow.position.y, width: 46, height: 60),
                    time: now,
                    phase: model.phase,
                    lean: follow.lean,
                    moving: follow.isMoving,
                )
            }
        }
        .allowsHitTesting(false)
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

    func update(now: TimeInterval, cursor: CGPoint) {
        defer {
            lastUpdate = now
            lastCursor = cursor
        }
        guard let lastUpdate else {
            position = CGPoint(x: cursor.x - 44, y: cursor.y - 62)
            return
        }
        let dt = min(0.05, max(0.001, now - lastUpdate))

        // The prototype's spring: exponential approach toward a perch above-left, with the
        // lean derived from horizontal velocity.
        let k = 1 - pow(0.0025, dt)
        let target = CGPoint(x: cursor.x - 44, y: cursor.y - 62)
        let next = CGPoint(
            x: position.x + (target.x - position.x) * k,
            y: position.y + (target.y - position.y) * k,
        )
        let velocity = CGPoint(x: (next.x - position.x) / (dt * 1000), y: (next.y - position.y) / (dt * 1000))
        position = next
        lean = max(-13, min(13, velocity.x * 55))
        isMoving = hypot(velocity.x, velocity.y) > 0.04

        // The wake follows the *cursor*, not the jellyfish — motion history a human can
        // read at a glance. Dropped only while the pointer actually moves.
        trail.removeAll { now - $0.time >= Self.trailLifetime }
        if let lastCursor, hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) > 1.5,
           now - lastTrailDrop > 0.036 {
            lastTrailDrop = now
            trail.append(TrailDot(point: cursor, time: now))
        }
    }
}

// MARK: - Bezel

/// The centered HUD, volume-bezel lineage: jellyfish mark, narration in evidence-verdict
/// language, elapsed session time, and the stop chord. Rests translucent, wakes to full
/// opacity for a few seconds around each action, and decays back slowly.
struct BezelView: View {
    let model: OverlayModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let engaged = timeline.date.timeIntervalSince(model.lastEngagement) < 3
            HStack(spacing: 11) {
                BezelMarkView(model: model)
                    .frame(width: 30, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.narration)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 300, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 6) {
                        Text("Agent session")
                        Text(elapsed(at: timeline.date))
                            .monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Divider()
                    .frame(height: 26)
                Text("take over")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                KeyChip("⌥")
                KeyChip("⎋")
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 16))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1),
            )
            .opacity(engaged ? 1 : 0.62)
            .animation(.easeOut(duration: 1.4), value: engaged)
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = model.sessionStart else { return "00:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// The bezel's small jellyfish mark — the same renderer, gently animated in place.
private struct BezelMarkView: View {
    let model: OverlayModel

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                JellyfishArt.draw(
                    in: context,
                    rect: CGRect(origin: .zero, size: size),
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    phase: model.phase == .hidden ? .idle : model.phase,
                )
            }
        }
    }
}

private struct KeyChip: View {
    let symbol: String

    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 21, minHeight: 21)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1),
            )
    }
}
