import SwiftUI

/// Remi, the original smooth jellyfish: a soft bell, five tentacles that lag behind it on their
/// own periods, and a drawn face. It is the one the app shipped with, and it stays — a cast
/// of five is not worse than a cast of four, and retiring the creature everybody already
/// recognises to make room for newcomers is a trade nobody asked for.
///
/// Kept in its own file rather than inline in `JellyfishArt`, so all five styles are found
/// the same way. It is handed a context that already carries the design-space scale, the
/// shared halo, the whole-body motion and the escort lean.
@MainActor
enum ClassicArt {
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

    /// `context` must already carry the design-space scale, the body motion and the lean.
    static func drawBody(
        in context: GraphicsContext, time: TimeInterval,
        phase: OverlayModel.Phase, lean: Double, moving: Bool,
    ) {
        let body = context
        let pulsing = phase == .acting || moving
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
        // the pre-action telegraph).
        var bell = body
        if pulsing {
            let t = (time / 1.25).truncatingRemainder(dividingBy: 1)
            let sx = JellyfishArt.keyframed(t, [(0, 1), (0.16, 1.14), (0.42, 0.93), (0.7, 1.02), (1, 1)])
            let sy = JellyfishArt.keyframed(t, [(0, 1), (0.16, 0.8), (0.42, 1.09), (0.7, 0.98), (1, 1)])
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
        // The face. Expression is the state made legible up close, the way the glow is
        // from afar: a blink on a slow clock keeps it alive; the gaze (the glint) wanders
        // idle, scans while thinking, and locks toward travel while acting; needs-human
        // widens the eyes and adds worried brows.
        let blinkPhase = (time / 4.4).truncatingRemainder(dividingBy: 1)
        let blink = blinkPhase < 0.055 ? sin(blinkPhase / 0.055 * .pi) : 0
        let (gazeX, gazeY, eyeScale, squint): (Double, Double, Double, Double) = switch phase {
        case .thinking: (0.9 * sin(time * 2 * .pi / 1.9), -1.0, 1, 1)
        case .acting: (max(-1, min(1, lean / 13)) * 1.2, 0.3, 1, 0.78)
        case .needsHuman: (0, 0.6, 1.15, 1)
        default: (0.6 * sin(time * 2 * .pi / 3.1), 0.4 * sin(time * 2 * .pi / 4.3), 1, 1)
        }
        let eyeRadius = 2.6 * eyeScale
        let eyeHeight = eyeRadius * squint * (1 - 0.85 * blink)
        for eyeX in [26.0, 38.0] {
            bell.fill(
                Path(ellipseIn: CGRect(
                    x: eyeX - eyeRadius, y: 32.5 - eyeHeight,
                    width: eyeRadius * 2, height: eyeHeight * 2,
                )),
                with: .color(JellyPalette.eye),
            )
            if blink < 0.5 {
                bell.fill(
                    Path(ellipseIn: CGRect(x: eyeX + 0.05 + gazeX, y: 30.75 + gazeY * 0.8, width: 1.7, height: 1.7)),
                    with: .color(.white),
                )
            }
        }
        if phase == .needsHuman {
            // Worried brows: inner ends raised.
            var leftBrow = Path()
            leftBrow.move(to: CGPoint(x: 23, y: 27.6))
            leftBrow.addLine(to: CGPoint(x: 28.3, y: 25.9))
            var rightBrow = Path()
            rightBrow.move(to: CGPoint(x: 35.7, y: 25.9))
            rightBrow.addLine(to: CGPoint(x: 41, y: 27.6))
            for brow in [leftBrow, rightBrow] {
                bell.stroke(
                    brow,
                    with: .color(JellyPalette.eye.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round),
                )
            }
        }
        for cheekX in [20.5, 43.5] {
            bell.fill(
                Path(ellipseIn: CGRect(x: cheekX - 1.5, y: 34.5, width: 3, height: 3)),
                with: .color(JellyPalette.pink.opacity(0.7)),
            )
        }
    }
}
