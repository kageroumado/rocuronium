import SwiftUI

/// Koko, the ghost. Not a jellyfish, and that is deliberate — it was one for a while, with oral
/// arms and marginal tentacles and a gonad ring showing through the bell, and all of it was
/// anatomically earned and none of it was wanted.
///
/// What survives from the medusa is the hem: five lobes that billow. Everything else is a
/// round head, two big lit eyes and a blush. The eyes matter more than the shape does — an
/// unlit hole is a socket, and a socket is a skull.
@MainActor
enum GhostArt {
    private enum P {
        static let veil = Color(hex: 0xF1EDFF)
        static let core = Color(hex: 0xFFFFFF)
        static let deep = Color(hex: 0xA9A2DC)
        static let eye = Color(hex: 0x2B2450)
        static let blush = Color(hex: 0xFF96BE, opacity: 0.36)
        static let alarm = Color(hex: 0xFFC46B)
    }

    static let period: [Double] = [6.4, 4.0, 2.2, 3.6]
    static let amp: [Double] = [0.20, 0.28, 0.46, 0.18]

    static func draw(in context: GraphicsContext, time: TimeInterval, phase: OverlayModel.Phase) {
        var ctx = context
        let i = JellyStyle.phaseIndex(phase)
        let c = JellyKit.squeeze(time: time, period: period[i], amp: amp[i])
        let lev = JellyKit.lightLevel(phase, time: time, c: c)
        let curled = JellyKit.curled(phase)
        let tint = phase == .needsHuman ? P.alarm : P.veil

        let w = 7.8 * (1 - 0.10 * c)
        let h = 6.6 * (1 + 0.13 * c)
        let s = (curled ? 7.0 : 11.5) * (1 - 0.10 * c)
        let lag = JellyKit.lag(time: time, phase: phase, age: 0.07)
        let waist = s * 0.38, wb = w * 1.06
        let dx = lag.x * 0.35, dy = lag.y * 0.40
        let lobes = 5
        let rest = waist + (s - waist) * 0.52

        // One clock for the whole sheet. Every part reads the same travelling wave at its own
        // offset — crown first, then the shoulders, then each hem lobe a fixed step later —
        // so what you see is a single ripple passing down the body rather than a top and a
        // bottom moving on unrelated timers.
        func wave(_ off: Double) -> Double { sin(time * 2 * .pi / 3.0 - off) }
        let tilt = wave(0) * 0.058

        // Two wisps trailing behind, blurred by being drawn where the body used to be. Not
        // inside the lean: they mark where it *was*, so they must not swing with where it is.
        for layer in [1, 0] {
            let l = JellyKit.lag(time: time, phase: phase, age: 0.16 + Double(layer) * 0.13)
            let k = 1.10 + Double(layer) * 0.22
            JellyKit.bloom(
                in: &ctx, at: CGPoint(x: l.x, y: -h * 0.3 + l.y + s * 0.25),
                rx: w * k * 1.5, ry: (h + s * 0.5) * k,
                color: tint, opacity: 0.10 - Double(layer) * 0.035,
            )
        }

        // The sheet leans about its own hem, so the head swings further than the tail does —
        // which is what "the top moves too" has to mean for something with no skeleton.
        ctx.translateBy(x: 0, y: waist)
        ctx.rotate(by: .radians(tilt))
        ctx.translateBy(x: 0, y: -waist)

        // One closed silhouette, dome into hem with no corner between them. The apex sits
        // level with both of its neighbouring control points, so the crown keeps a horizontal
        // tangent and rides the wave without developing a kink at the top.
        let shoulderL = wave(0.75) * 0.80, shoulderR = wave(-0.75) * 0.80
        let crown = wave(0.25) * 0.70
        let apexY = -h * 1.58 + crown * 0.8

        var body = Path()
        body.move(to: CGPoint(x: -wb + dx, y: waist + dy))
        body.addCurve(
            to: CGPoint(x: crown * 1.3, y: apexY),
            control1: CGPoint(x: -wb * 1.03, y: -h * 0.90 + shoulderL),
            control2: CGPoint(x: -w * 0.60, y: apexY),
        )
        body.addCurve(
            to: CGPoint(x: wb + dx, y: waist + dy),
            control1: CGPoint(x: w * 0.60, y: apexY),
            control2: CGPoint(x: wb * 1.03, y: -h * 0.90 + shoulderR),
        )
        for lobe in 0 ..< lobes {
            let x0 = JellyKit.lerp(wb, -wb, Double(lobe) / Double(lobes))
            let x1 = JellyKit.lerp(wb, -wb, Double(lobe + 1) / Double(lobes))
            let span = x0 - x1
            // Cubic, not quadratic: a quadratic can only make a point, and cloth does not
            // come to a point. The notches stop a third of the way back up, so it is one hem
            // that ripples rather than five separate tongues.
            let swell = wave(1.7 + Double(lobe) * 0.52) * 1.5
            let tip = (lobe.isMultiple(of: 2) ? s * 0.84 : s) + swell
            let last = lobe == lobes - 1
            let nx = last ? -wb : x1
            let ny = last ? waist : rest + wave(2.0 + Double(lobe) * 0.52) * 0.9
            body.addCurve(
                to: CGPoint(x: nx + dx, y: ny + dy),
                control1: CGPoint(x: x0 - span * 0.50 + lag.x * 0.8, y: tip + lag.y * 0.9),
                control2: CGPoint(x: nx + span * 0.50 + lag.x * 0.8, y: tip + lag.y * 0.9),
            )
        }
        body.closeSubpath()

        // Pearl, not steel. The first ramp ran white into a cold blue-grey, which is the
        // colour of a thing that has been dead a while.
        ctx.fill(
            body,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: P.core.opacity(0.74 + 0.24 * lev), location: 0),
                    .init(color: tint.opacity(0.58 + 0.20 * lev), location: 0.32),
                    .init(color: tint.opacity(0.36), location: 0.60),
                    .init(color: P.deep.opacity(0.17), location: 0.84),
                    .init(color: P.deep.opacity(0.01), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: -h * 1.58),
                endPoint: CGPoint(x: 0, y: s * 1.04),
            ),
        )

        // the light it is made of, blooming out past its own edge
        JellyKit.bloom(
            in: &ctx, at: CGPoint(x: 0, y: -h * 0.40),
            rx: w * 2.3, ry: h * 2.3, color: tint, opacity: 0.22 * lev,
        )
        // A crown highlight that never reaches its own edge — a flat ellipse read as a bald
        // patch.
        JellyKit.bloom(
            in: &ctx, at: CGPoint(x: crown * 1.1, y: -h * 0.88 + crown * 0.7),
            rx: w * 0.80, ry: h * 0.56, color: P.core, opacity: 0.30 + 0.18 * lev,
        )

        // Big, low, and lit, and riding inside the lean so the swing reads as a head tilt.
        JellyKit.face(
            in: &ctx, time: time, phase: phase,
            at: CGPoint(x: crown * 0.5, y: -h * 0.44 + crown * 0.3),
            spread: w * 0.32, r: 1.30,
            ink: P.eye.opacity(0.90), glint: Color.white.opacity(0.95), blush: P.blush,
        )
    }
}
