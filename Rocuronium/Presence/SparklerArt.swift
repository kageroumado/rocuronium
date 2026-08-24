import SwiftUI

/// Built on a real animal: the flower hat jelly, *Olindias formosa*, which is vivid pink,
/// carries dark opaque pinstripes radiating from the crown to the margin, and has
/// **bioluminescent tips on its tentacles**. So the lights on the legs are not an invention;
/// they are the animal's own.
///
/// The mechanism is what earns her a place in a cast of four. The others all keep their
/// light *in the bell* — a bloom inside the ghost, a curtain inside the aurora, a glyph on
/// Bitjelly's forehead. This one sends it away: beads are born at the hem and run all the
/// way down the legs. On needs-human they stop dead where they are and flash together, which
/// is the only honest picture of an agent that is holding — still lit, still loaded, going
/// nowhere until a human says so.
@MainActor
enum SparklerArt {
    private enum P {
        static let hi = Color(hex: 0xFFE9F4)
        static let bell = Color(hex: 0xF79ACB)
        static let deep = Color(hex: 0xB8478F)
        static let tent = Color(hex: 0xF9C2DF)
        static let bead = Color(hex: 0xFFFAFD)
        static let beadGlow = Color(hex: 0xFF9FD8)
        static let alarm = Color(hex: 0xFFAE3A)
        static let ink = Color(hex: 0x3D0F2C)
        static let blush = Color(hex: 0xE2488C, opacity: 0.30)
    }

    static let period: [Double] = [5.2, 3.2, 1.6, 3.0]
    static let amp: [Double] = [0.30, 0.44, 0.74, 0.26]

    /// Shorter than the prototype's 26, for the same reason as Aurora's: what reads as
    /// streaming on a big card is a smear in a 46×60 rect.
    private static let legLength = 12.5

    static func draw(in context: GraphicsContext, time: TimeInterval, phase: OverlayModel.Phase) {
        var ctx = context
        let i = JellyStyle.phaseIndex(phase)
        let c = JellyKit.squeeze(time: time, period: period[i], amp: amp[i])
        let lev = JellyKit.lightLevel(phase, time: time, c: c)
        let spd = JellyKit.lightSpeed(phase)
        let curled = JellyKit.curled(phase)

        let w = 6.9 * (1 - 0.11 * c)
        let h = 6.0 * (1 + 0.16 * c)
        let sag = h * 0.19
        let sagY = sag * 1.30
        let rimX = w * 0.88
        let beadCol = phase == .needsHuman ? P.alarm : P.bead
        let glowCol = phase == .needsHuman ? P.alarm : P.beadGlow
        // one strobe for every light on the animal, so a held state reads as a single alarm
        let strobe = phase == .needsHuman ? (sin(time * 2 * .pi * 1.5) > -0.2 ? 1.0 : 0.13) : 1.0

        // The standard jelly cap: chubby, wider than tall, widest a little above the rim so
        // the margin tucks under the way a real bell's does. Three cleverer silhouettes were
        // thrown away getting here and each failed the same way — by having a feature where
        // a jellyfish has none. A pinched bud (a point). A crown built from a radius
        // modulated over angle (a nub, dead centre). A tall waisted bell (a helmet).
        //
        // The apex sits level with both neighbouring control points, so the crown holds a
        // horizontal tangent and cannot grow a tip.
        let hem = [
            CGPoint(x: rimX, y: 0), CGPoint(x: w * 0.55, y: sagY),
            CGPoint(x: -w * 0.55, y: sagY), CGPoint(x: -rimX, y: 0),
        ]
        func rootAt(_ u: Double) -> CGPoint { JellyKit.bez3(hem[0], hem[1], hem[2], hem[3], u) }
        var bell: Path {
            var p = Path()
            p.move(to: CGPoint(x: -rimX, y: 0))
            p.addCurve(
                to: CGPoint(x: 0, y: -h * 1.34),
                control1: CGPoint(x: -w * 1.06, y: -h * 0.52),
                control2: CGPoint(x: -w * 0.86, y: -h * 1.34),
            )
            p.addCurve(
                to: CGPoint(x: rimX, y: 0),
                control1: CGPoint(x: w * 0.86, y: -h * 1.34),
                control2: CGPoint(x: w * 1.06, y: -h * 0.52),
            )
            p.addCurve(to: hem[3], control1: hem[1], control2: hem[2])
            p.closeSubpath()
            return p
        }

        let legs = 9
        let beads = 3
        let len = curled ? 7.0 : legLength
        for n in 0 ..< legs {
            let u = 0.07 + Double(n) * (0.86 / Double(legs - 1))
            let root = rootAt(u)
            let l = len * (0.60 + 0.40 * sin(u * .pi))
            let pts = JellyKit.trail(
                time: time, phase: phase,
                from: CGPoint(x: root.x, y: root.y - 0.4),
                length: l, segments: 22, sway: 1.5,
                period: 2.6 + Double(n) * 0.27, offset: Double(n) * 0.8, curled: curled,
            )
            ctx.fill(JellyKit.ribbon(pts, 0.55, 0.02), with: .color(P.tent.opacity(0.40)))

            for b in 0 ..< beads {
                // Frozen mid-leg on needs-human, not restarted from the hem.
                let f = phase == .needsHuman
                    ? 0.28 + Double(b) * 0.24
                    : ((time * spd * 0.42 - Double(b) / Double(beads) - Double(n) * 0.11)
                        .truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                let idx = f * Double(pts.count - 1)
                let i0 = min(pts.count - 1, max(0, Int(idx)))
                let fr = idx - Double(i0)
                let p0 = pts[i0], p1 = pts[min(pts.count - 1, i0 + 1)]
                let at = CGPoint(x: JellyKit.lerp(p0.x, p1.x, fr), y: JellyKit.lerp(p0.y, p1.y, fr))
                // It swells on the way out and dies at the tip, so a leg never looks like a
                // string of identical dots sliding along it.
                let env = sin(f * .pi)
                let a = (0.42 + 0.58 * lev) * env * strobe
                guard a > 0.04 else { continue }
                let r = 0.28 + 0.36 * env
                // A warm halo under a near-white core. A single pale dot at low alpha over a
                // dark stage reads as a grey pearl threaded on the leg; the halo is what
                // makes it a light.
                JellyKit.bloom(in: &ctx, at: at, rx: r * 4.2, ry: r * 4.2, color: glowCol, opacity: 0.55 * a)
                ctx.fill(JellyKit.ellipse(at.x, at.y, r, r), with: .color(beadCol.opacity(min(1, a))))
            }

            // The real animal's tips stay lit whatever else it is doing — that is the whole
            // reason it is called a flower hat. The travelling beads are ours; this is hers.
            if let tip = pts.last {
                let ta = 0.30 + 0.45 * lev * strobe
                JellyKit.bloom(in: &ctx, at: tip, rx: 1.5, ry: 1.5, color: glowCol, opacity: 0.55 * ta)
                ctx.fill(JellyKit.ellipse(tip.x, tip.y, 0.26, 0.26), with: .color(beadCol.opacity(ta)))
            }
        }

        var inside = ctx
        inside.clip(to: bell)
        inside.fill(
            bell,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: P.hi.opacity(0.97), location: 0),
                    .init(color: P.bell.opacity(0.94), location: 0.46),
                    .init(color: P.deep.opacity(0.92), location: 1),
                ]),
                center: CGPoint(x: -w * 0.26, y: -h * 1.10), startRadius: 0.4, endRadius: w * 1.8,
            ),
        )
        // the seam along the hem where the beads are made
        inside.fill(
            bell,
            with: .linearGradient(
                Gradient(colors: [glowCol.opacity(0.50 * lev * strobe), glowCol.opacity(0)]),
                startPoint: CGPoint(x: 0, y: sagY), endPoint: CGPoint(x: 0, y: -h * 0.55),
            ),
        )
        // The flower hat's pinstripes — dark opaque lines radiating from the top centre out
        // to the margin. This is what keeps her apart from the aurora now that they share the
        // standard cap: the aurora is plain glass with weather inside it, and this one has a
        // patterned skin.
        for k in 0 ..< 15 {
            let t = Double(k) / 14 * 2 - 1
            var stripe = Path()
            stripe.move(to: CGPoint(x: t * w * 0.05, y: -h * 1.30))
            stripe.addQuadCurve(
                to: CGPoint(x: t * rimX * 1.03, y: 0.3),
                control: CGPoint(x: t * w * 0.66, y: -h * 0.80),
            )
            inside.stroke(stripe, with: .color(P.deep.opacity(0.30)), lineWidth: 0.32)
        }

        ctx.stroke(bell, with: .color(P.hi.opacity(0.52)), lineWidth: 0.45)
        // Just under the bell's own midpoint. The usual baby-schema placement is the bottom
        // third, but that only works on a head wider than it is tall — on a tall bell it
        // turns the whole animal into forehead.
        JellyKit.face(
            in: &ctx, time: time, phase: phase, at: CGPoint(x: 0, y: -h * 0.44),
            spread: w * 0.30, r: 1.14,
            ink: P.ink.opacity(0.90), glint: Color(hex: 0xFFF7FB, opacity: 0.95), blush: P.blush,
        )
    }
}
