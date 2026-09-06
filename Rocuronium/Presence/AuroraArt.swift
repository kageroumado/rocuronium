import SwiftUI

/// A clear bell with a curtain of light standing up inside it, coloured the way a real
/// aurora is: a magenta fringe along the bottom edge, brilliant green through the body,
/// violet where it thins out at the top.
///
/// The bands are laid down **additively**. Alpha-blending a colour over a dark bell can only
/// ever make the bell paler; adding light to it is what makes an aurora look like it is
/// emitting rather than tinted. They also overlap by a quarter of their width, so they fuse
/// into one sheet instead of reading as sixteen bars.
@MainActor
enum AuroraArt {
    private enum P {
        static let glass = Color(hex: 0x7FCDE8)
        static let rim = Color(hex: 0xEAFBFF)
        static let fringe = Color(hex: 0xFF3DC4)
        static let green = Color(hex: 0x22FF9B)
        static let teal = Color(hex: 0x2FE3FF)
        static let crown = Color(hex: 0xB44BFF)
        static let alarm = Color(hex: 0xFFB03A)
        static let tent = Color(hex: 0xCFF3FF)
        static let ink = Color(hex: 0x0E2430)
        static let blush = Color(hex: 0x5ADCBE, opacity: 0.30)
    }

    static let period: [Double] = [5.0, 3.0, 1.5, 3.2]
    static let amp: [Double] = [0.30, 0.46, 0.80, 0.30]

    /// Shorter than the prototype's 27. On a 620×560 card a tendril four bell-heights long
    /// is gorgeous; inside a 46×60 overlay rect it is a smear, and it would force the bell
    /// down to a dot to fit.
    private static let legLength = 13.0

    static func draw(in context: GraphicsContext, time: TimeInterval, phase: OverlayModel.Phase) {
        var ctx = context
        let i = JellyStyle.phaseIndex(phase)
        let c = JellyKit.squeeze(time: time, period: period[i], amp: amp[i])
        let lev = JellyKit.lightLevel(phase, time: time, c: c)
        let spd = JellyKit.lightSpeed(phase)
        let curled = JellyKit.curled(phase)

        let w = 8.4 * (1 - 0.12 * c)
        let h = 7.6 * (1 + 0.15 * c)
        let sag = h * 0.24
        let sagY = sag * 1.15
        let rimX = w * 0.94

        // A wide shallow parasol. The first outline put both control points at the far
        // corners, which gives a flat top and hard shoulders: a lid, not a bell.
        let hem = [
            CGPoint(x: rimX, y: 0), CGPoint(x: w * 0.58, y: sagY),
            CGPoint(x: -w * 0.58, y: sagY), CGPoint(x: -rimX, y: 0),
        ]
        func rootAt(_ u: Double) -> CGPoint { JellyKit.bez3(hem[0], hem[1], hem[2], hem[3], u) }
        var bell: Path {
            var p = Path()
            p.move(to: CGPoint(x: -rimX, y: 0))
            p.addCurve(
                to: CGPoint(x: 0, y: -h * 1.30),
                control1: CGPoint(x: -w * 1.08, y: -h * 0.44),
                control2: CGPoint(x: -w * 0.78, y: -h * 1.30),
            )
            p.addCurve(
                to: CGPoint(x: rimX, y: 0),
                control1: CGPoint(x: w * 0.78, y: -h * 1.30),
                control2: CGPoint(x: w * 1.08, y: -h * 0.44),
            )
            p.addCurve(to: hem[3], control1: hem[1], control2: hem[2])
            p.closeSubpath()
            return p
        }

        // Tendrils first, so the bell lands on top of their roots and the join disappears.
        // Each root is sampled off the hem curve itself: guessing a flat y leaves the outer
        // ones hanging in open water, because the hem rises to zero at the bell's edges.
        let legs = 9
        let len = curled ? 8.0 : legLength
        for n in 0 ..< legs {
            let u = 0.07 + Double(n) * (0.86 / Double(legs - 1))
            let root = rootAt(u)
            let l = len * (0.54 + 0.46 * sin(u * .pi)) * (0.86 + 0.28 * Double((n * 7) % 5) / 5)
            let pts = JellyKit.trail(
                time: time, phase: phase,
                from: CGPoint(x: root.x, y: root.y - 0.6),
                length: l, segments: 24,
                sway: 1.5 + 0.9 * sin(u * .pi), period: 2.4 + Double(n) * 0.31,
                offset: Double(n) * 0.77, curled: curled,
            )
            ctx.fill(JellyKit.ribbon(pts, 0.78, 0.02), with: .color(P.tent.opacity(0.26)))
            let hue: Color = phase == .needsHuman ? P.alarm : (u < 0.40 ? P.green : (u > 0.60 ? P.crown : P.teal))
            for pass in 0 ..< 3 {
                let cut = Int((Double(pts.count) * (0.46 - Double(pass) * 0.13)).rounded(.up))
                ctx.fill(
                    JellyKit.ribbon(Array(pts.prefix(max(2, cut))), 0.52, 0.05),
                    with: .color(hue.opacity(0.09 + 0.18 * lev)),
                )
            }
        }

        var inside = ctx
        inside.clip(to: bell)
        inside.fill(
            bell,
            with: .linearGradient(
                Gradient(colors: [P.rim.opacity(0.34), P.glass.opacity(0.14)]),
                startPoint: CGPoint(x: 0, y: -h * 1.30), endPoint: CGPoint(x: 0, y: h * 0.3),
            ),
        )

        var curtain = inside
        curtain.blendMode = .plusLighter
        let bands = 16
        let floor = sagY * 0.72
        let span = w * 1.88
        for b in 0 ..< bands {
            let t = Double(b) / Double(bands - 1)
            let x = JellyKit.lerp(-w * 0.92, w * 0.92, t)
            let bw = span / Double(bands) * 1.25
            let ph = time * spd * 1.05 + t * 4.0
            // Height barely varies; the shimmer is carried by `intensity` instead. Letting
            // height do the work meant the short bands left the top of the bell empty, and a
            // half-empty bell is what made her look like the small one of the four.
            //
            // Capped at 1.56 bell-heights so the fade completes *inside* the bell: past the
            // crown the gradient is cut off mid-curve, leaving a flat bright bar at the top
            // rather than a curtain thinning out.
            let tall = (0.82 + 0.18 * pow(max(0, sin(ph)), 1.3)) * h * 1.56
            // A floor under `lev`, so idle still has real colour in it. A curtain that is
            // only visible while working is not a curtain, it is a progress bar.
            let intensity = (0.34 + 0.66 * lev) * (0.42 + 0.58 * pow(max(0, sin(ph + 0.6)), 1.1))

            let stops: [Gradient.Stop] = if phase == .needsHuman {
                [
                    .init(color: P.alarm.opacity(0), location: 0),
                    .init(color: P.alarm.opacity(0.90 * intensity), location: 0.12),
                    .init(color: P.alarm.opacity(0.38 * intensity), location: 0.55),
                    .init(color: P.alarm.opacity(0), location: 1),
                ]
            } else {
                // The body of the curtain sits high. Weighting green a quarter of the way up
                // left the top two thirds as empty glass with a green stripe under it — an
                // aurora is mostly aurora, not mostly sky.
                [
                    .init(color: P.fringe.opacity(0.30 * intensity), location: 0),
                    .init(color: P.fringe.opacity(0.95 * intensity), location: 0.06),
                    .init(color: P.green.opacity(1.00 * intensity), location: 0.20),
                    .init(color: P.green.opacity(0.88 * intensity), location: 0.46),
                    .init(color: P.teal.opacity(0.60 * intensity), location: 0.66),
                    .init(color: P.crown.opacity(0.34 * intensity), location: 0.86),
                    .init(color: P.crown.opacity(0), location: 1),
                ]
            }
            curtain.fill(
                Path(CGRect(x: x - bw / 2, y: floor - tall, width: bw, height: tall)),
                with: .linearGradient(
                    Gradient(stops: stops),
                    startPoint: CGPoint(x: 0, y: floor), endPoint: CGPoint(x: 0, y: floor - tall),
                ),
            )
        }

        // a sheen on the crown, so the top of the glass catches something even when the
        // curtain up there has thinned to nothing
        JellyKit.bloom(
            in: &inside, at: CGPoint(x: -w * 0.22, y: -h * 1.00),
            rx: w * 0.92, ry: w * 0.92, color: P.rim, opacity: 0.32,
        )

        // the rim, the one hard line on it — a bell needs one edge or it stops being glass
        ctx.stroke(bell, with: .color(P.rim.opacity(0.50)), lineWidth: 0.42)
        // Big eyes and a blush, like the rest of the cast. She had neither, which was the
        // other half of why she read as the small one — not size, seriousness.
        JellyKit.face(
            in: &ctx, time: time, phase: phase, at: CGPoint(x: 0, y: -h * 0.40),
            spread: w * 0.28, r: 1.16,
            ink: P.ink.opacity(0.88), glint: Color(hex: 0xF0FFFF, opacity: 0.95), blush: P.blush,
        )
    }
}
