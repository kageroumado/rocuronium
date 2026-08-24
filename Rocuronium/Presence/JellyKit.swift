import SwiftUI

extension Color {
    /// `0xRRGGBB`, so a colour tuned by eye in `Prototypes/overlay/pretty.html` is verbatim
    /// the same colour here rather than a re-derived approximation.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity,
        )
    }
}

/// Shared machinery for the three vector mascots. `BitjellyArt` needs none of it — it is a
/// sprite — but Ghost, Aurora and Sparkler are all built from the same four things: one
/// contraction curve, a tapered ribbon, a trail that lags behind the body, and one face.
///
/// The light *dial* lives here too. Every creature expresses state differently — a bloom, a
/// curtain, beads running down the legs — but they all read the same two numbers, so the
/// four of them can never disagree about how urgent the moment is.
@MainActor
enum JellyKit {
    // MARK: - The beat

    /// A fast squeeze and a long glide back. The asymmetry — and the dip below zero at the
    /// end, which is the refill overshoot — is the whole difference between a swimming bell
    /// and a bouncing ball.
    static func contraction(_ u: Double) -> Double {
        let up = 0.26
        if u < up {
            let f = u / up
            return 1 - pow(1 - f, 3)
        }
        let v = (u - up) / (1 - up)
        let smoother = v * v * v * (v * (v * 6 - 15) + 10)
        return (1 - smoother) - 0.17 * sin(.pi * pow(v, 0.72))
    }

    /// How hard the bell is squeezing right now, on its own clock. Never negative: the
    /// undershoot is a real part of the curve but no creature should invert on it.
    static func squeeze(time: TimeInterval, period: Double, amp: Double) -> Double {
        let u = (time / period).truncatingRemainder(dividingBy: 1)
        return max(0, contraction(u) * amp)
    }

    // MARK: - The light dial

    static func lightSpeed(_ phase: OverlayModel.Phase) -> Double {
        switch phase {
        case .thinking: 0.65
        case .acting: 1.7
        case .needsHuman: 2.4
        default: 0.22
        }
    }

    /// Needs-human is a square blink, not a fade: a request for a human is a warning light,
    /// and a warning light does not breathe.
    static func lightLevel(_ phase: OverlayModel.Phase, time: TimeInterval, c: Double) -> Double {
        switch phase {
        case .needsHuman: sin(time * 2 * .pi * 1.5) > -0.2 ? 1 : 0.16
        case .acting: 0.55 + 0.45 * max(0, c)
        case .thinking: 0.46 + 0.32 * sin(time * 2 * .pi / 1.1)
        default: 0.26 + 0.14 * sin(time * 2 * .pi / 3.2)
        }
    }

    /// Held: everything that hangs curls up, so the creature is visibly touching nothing.
    static func curled(_ phase: OverlayModel.Phase) -> Bool { phase == .needsHuman }

    // MARK: - Lag

    /// Where the body was `age` seconds ago, relative to where it is now. The whole-body
    /// motion is a pure function of time, so a lagging part evaluates it in the past rather
    /// than carrying a history buffer — exact under scrubbing or a dropped frame.
    static func lag(time: TimeInterval, phase: OverlayModel.Phase, age: Double) -> CGPoint {
        let now = JellyfishArt.bodyOffset(time: time, phase: phase)
        let then = JellyfishArt.bodyOffset(time: time - age, phase: phase)
        return CGPoint(x: then.x - now.x, y: then.y - now.y)
    }

    /// Trailing points that remember where the body was, so a strand lags instead of
    /// steering. `curled` bunches it into a held loop rather than shortening it.
    static func trail(
        time: TimeInterval, phase: OverlayModel.Phase, from origin: CGPoint,
        length: Double, segments: Int, sway: Double, period: Double,
        offset: Double, curled: Bool,
    ) -> [CGPoint] {
        (0 ... segments).map { k in
            let t = Double(k) / Double(segments)
            let l = lag(time: time, phase: phase, age: Double(k) * 0.045)
            let s = sin(time * 2 * .pi / period - Double(k) * 0.5 + offset) * sway * (0.2 + t)
            let drop = curled ? sin(t * .pi) * length * 0.45 : t * length
            return CGPoint(x: origin.x + s + l.x * 0.9, y: origin.y + drop + l.y * 0.9)
        }
    }

    // MARK: - Geometry

    /// A tapered ribbon, built as a filled outline rather than a stroke, so the tip actually
    /// vanishes instead of ending in a round cap the width of the strand.
    static func ribbon(_ points: [CGPoint], _ w0: Double, _ w1: Double) -> Path {
        guard points.count > 1 else { return Path() }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in points.indices {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let m = max(hypot(dx, dy), 1e-6)
            dx /= m; dy /= m
            let w = (w0 + (w1 - w0) * Double(i) / Double(points.count - 1)) / 2
            left.append(CGPoint(x: points[i].x - dy * w, y: points[i].y + dx * w))
            right.append(CGPoint(x: points[i].x + dy * w, y: points[i].y - dx * w))
        }
        var path = Path()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// A point on a cubic, so a curve that was *drawn* can also be *walked*. That is how a
    /// tendril root lands exactly on the hem rather than near it — the edge gets described
    /// once and used twice, instead of the outline and the roots each guessing separately.
    static func bez3(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ s: Double) -> CGPoint {
        let m = 1 - s
        let a = m * m * m, b = 3 * m * m * s, c = 3 * m * s * s, d = s * s * s
        return CGPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
            y: a * p0.y + b * c1.y + c * c2.y + d * p3.y,
        )
    }

    static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// A radial bloom that reaches zero at its own edge — used for every soft glow in the
    /// cast, because a flat translucent ellipse reads as a disc and a gradient reads as light.
    static func bloom(
        in ctx: inout GraphicsContext, at c: CGPoint, rx: Double, ry: Double,
        color: Color, opacity: Double,
    ) {
        guard opacity > 0.004 else { return }
        ctx.fill(
            ellipse(c.x, c.y, rx, ry),
            with: .radialGradient(
                Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                center: c, startRadius: 0, endRadius: max(rx, ry),
            ),
        )
    }

    // MARK: - The face

    /// One face across the whole cast — the same eyes, the same slow blink, the same worried
    /// brows when a human is needed. That is what makes them read as friends rather than as
    /// four unrelated drawings, and it is why the blush lives here and not on one creature.
    static func face(
        in ctx: inout GraphicsContext, time: TimeInterval, phase: OverlayModel.Phase,
        at p: CGPoint, spread: Double, r: Double,
        ink: Color, glint: Color?, blush: Color? = nil,
    ) {
        let blink = (time / 3.9).truncatingRemainder(dividingBy: 1) < 0.05
        let wide = phase == .needsHuman ? 1.15 : 1.0
        let squint = phase == .acting ? 0.78 : 1.0
        let rr = r * wide
        let hh = max(rr * squint * (blink ? 0.12 : 1), 0.05)

        let gaze: CGPoint = switch phase {
        case .thinking: CGPoint(x: 0.30 * r * sin(time * 2 * .pi / 1.9), y: -0.28 * r)
        case .acting: CGPoint(x: 0, y: 0.10 * r)
        case .needsHuman: CGPoint(x: 0, y: 0.18 * r)
        default: CGPoint(x: 0.22 * r * sin(time * 2 * .pi / 3.1), y: 0.14 * r * sin(time * 2 * .pi / 4.3))
        }

        // Behind the eyes, so a blink never clips it.
        if let blush {
            for side in [-1.0, 1.0] {
                ctx.fill(
                    ellipse(p.x + side * (spread + r * 1.05), p.y + r * 1.05, r * 0.68, r * 0.46),
                    with: .color(blush),
                )
            }
        }
        for side in [-1.0, 1.0] {
            let ex = p.x + side * spread
            ctx.fill(ellipse(ex, p.y, rr, hh), with: .color(ink))
            if !blink, let glint {
                ctx.fill(
                    ellipse(ex + gaze.x + r * 0.26, p.y + gaze.y - r * 0.3, r * 0.3, r * 0.3),
                    with: .color(glint),
                )
            }
        }
        if phase == .needsHuman {
            for side in [-1.0, 1.0] {
                var brow = Path()
                brow.move(to: CGPoint(x: p.x + side * (spread + r * 1.5), y: p.y - r * 1.9))
                brow.addLine(to: CGPoint(x: p.x + side * (spread - r * 0.5), y: p.y - r * 2.6))
                ctx.stroke(brow, with: .color(ink), style: StrokeStyle(lineWidth: r * 0.32, lineCap: .round))
            }
        }
    }
}
