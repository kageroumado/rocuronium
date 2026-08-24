import SwiftUI

/// The pixel mascot: a 14×18 sprite in four frames, ported from
/// `Prototypes/overlay/bitjelly.html` with the repairs that prototype's testing pass found.
///
/// Drawn into the same 64×84 design space as `JellyfishArt`, and handed a context that has
/// already had the shared glow, the whole-body motion and the escort lean applied — so the
/// two styles are the same creature in the same water, differing only in how it is drawn.
///
/// Every cell group is accumulated into one `Path` and filled once. Filling cell-by-cell
/// leaves a hairline seam wherever two rectangles abut, because each edge antialiases
/// against the background separately; one path is one coverage calculation, so a flat bell
/// comes out flat. That was the single worst artefact in the HTML prototype.
@MainActor
enum BitjellyArt {
    // MARK: - The sprite

    private static let gridW = 14
    private static let cell = 3.9
    private static let originX = 32.0 - Double(gridW) * cell / 2
    private static let originY = 6.0

    /// `1` bell, `2` a light pixel on the bell, `.` open water. Row 8 is the hem the
    /// strands hang from; row 9 is empty and exists so the hem has something to sit above.
    private static let frames: [[String]] = [
        [ // 0 · rest
            "..1111111111..", ".111111111111.", "11111111111111", "12111111111121",
            "11111111111111", "11111111111111", "11211111111211", "11111111111111",
            ".1.11.11.11.1.", "..............",
        ],
        [ // 1 · squeeze ¼
            "...11111111...", "..1111111111..", ".111111111111.", "11211111111211",
            "11111111111111", "11111111111111", "11211111111211", ".111111111111.",
            "...11.11.11...", "..............",
        ],
        [ // 2 · squeeze full
            "....111111....", "...11111111...", "..1111111111..", ".112111111211.",
            ".111111111111.", ".111111111111.", ".112111111211.", "..1111111111..",
            "....1.11.1....", "..............",
        ],
        [ // 3 · refill — the bell springing back open, so its crown is the widest of the four
            ".111111111111.", "11111111111111", "11111111111111", "12111111111121",
            "11111111111111", "11111111111111", "11211111111211", "11111111111111",
            ".1.11.11.11.1.", "..............",
        ],
    ]

    /// The forehead glyph: a 2×2 core between the crown and the eyes with one ring around
    /// it. The frame table's own `2` pixels are the outermost ring, so light travels
    /// core → ring → edge and the state reads as something radiating from the mark rather
    /// than four dots scattered on the body. Every cell is a mirror pair about column 6.5.
    private static let glyphCore: [(r: Int, q: Int)] = [(1, 6), (1, 7), (2, 6), (2, 7)]
    private static let glyphRing: [(r: Int, q: Int)] = [
        (0, 6), (0, 7), (1, 5), (1, 8), (2, 5), (2, 8), (3, 6), (3, 7),
    ]

    /// Strand roots in the rest hem, mirrored about column 6.5.
    private static let strandCols = [1, 4, 6, 7, 9, 12]
    private static let eyeRow = 4
    private static let eyeCols = [4, 9]

    // MARK: - Palette

    /// The accent is what the status light is made of. Acting deliberately runs much paler
    /// than the prototype's `#9C9AFF`, which sat so close to the bell that a lit edge pixel
    /// read as a blemish on the body rather than a light.
    private static func accent(_ phase: OverlayModel.Phase) -> Color {
        switch phase {
        case .thinking: JellyPalette.glowThinking
        case .acting: Color(red: 0.80, green: 0.84, blue: 1.0)
        case .needsHuman: JellyPalette.glowAttention
        default: JellyPalette.bellRim
        }
    }

    // MARK: - The beat

    /// Acting shares the classic style's 1.25 s cycle so the bell's squeeze lands on the
    /// same beat as the whole-body surge; the calmer states keep the prototype's timings.
    private static func beat(_ phase: OverlayModel.Phase) -> (period: Double, amp: Double) {
        switch phase {
        case .thinking: (2.15, 0.60)
        case .acting: (1.25, 1.00)
        case .needsHuman: (3.40, 0.40)
        default: (4.60, 0.42)
        }
    }

    /// A fast squeeze and a long glide back — the asymmetry that separates a swimming bell
    /// from a bouncing ball. The dip below zero at the end is the refill overshoot.
    private static func contraction(_ u: Double) -> Double {
        let up = 0.26
        if u < up {
            let f = u / up
            return 1 - pow(1 - f, 3)
        }
        let v = (u - up) / (1 - up)
        let smoother = v * v * v * (v * (v * 6 - 15) + 10)
        return (1 - smoother) - 0.17 * sin(.pi * pow(v, 0.72))
    }

    /// Brightness of core, ring and edge. Idle and thinking send a ripple outward through
    /// the three; acting rides the squeeze; needs-human blinks all three together, because
    /// a request for a human is a warning light and a warning light does not fade.
    private static func ringLevels(
        _ phase: OverlayModel.Phase, time: TimeInterval, c: Double
    ) -> (core: Double, ring: Double, edge: Double) {
        let k = max(0, c)
        switch phase {
        case .acting:
            return (1, 0.5 + 0.5 * k, 0.25 + 0.75 * k)
        case .needsHuman:
            let on = sin(time * 2 * .pi * 1.4) > -0.2
            return on ? (1, 0.95, 0.85) : (0.18, 0.10, 0.06)
        default:
            let period = phase == .thinking ? 1.15 : 3.40
            let w = (time / period).truncatingRemainder(dividingBy: 1)
            let base = phase == .thinking ? 0.18 : 0.10
            func bump(_ off: Double) -> Double {
                max(0, 1 - ((w - off + 1).truncatingRemainder(dividingBy: 1)) * 3.4)
            }
            return (max(base + 0.25, bump(0)), max(base, bump(0.16)), max(base, bump(0.32)))
        }
    }

    // MARK: - Drawing

    private static func rect(_ q: Int, _ r: Int, rows: Int = 1) -> CGRect {
        CGRect(
            x: originX + Double(q) * cell, y: originY + Double(r) * cell,
            width: cell, height: cell * Double(rows),
        )
    }

    /// `context` must already carry the design-space scale, the body motion and the lean.
    static func drawBody(
        in context: GraphicsContext, time: TimeInterval,
        phase: OverlayModel.Phase, lean: Double, moving: Bool,
    ) {
        var ctx = context
        let (period, amp) = beat(moving && phase != .acting ? .acting : phase)
        let u = (time / period).truncatingRemainder(dividingBy: 1)
        let raw = contraction(u) * amp
        let c = max(0, raw)
        // Gate the refill frame on cycle position, not on the undershoot: the beat bottoms
        // out around −0.03, so a `c < −0.04` test never fires and frame 3 never renders.
        let frameIndex = c > 0.72 ? 2 : (c > 0.34 ? 1 : (u > 0.88 ? 3 : 0))
        let grid = frames[frameIndex].map(Array.init)
        let levels = ringLevels(phase, time: time, c: raw)
        let light = accent(phase)

        // The bell, and the lights on it. A `2` gets the bell drawn under it first: in the
        // prototype a `2` was drawn *instead of* the bell, so a dim light was a translucent
        // square over open water — a hole punched in the silhouette, darker than the body.
        var bell = Path()
        var edgeLights = Path()
        for r in grid.indices {
            for q in grid[r].indices {
                let ch = grid[r][q]
                guard ch != "." else { continue }
                bell.addRect(rect(q, r))
                if ch == "2" { edgeLights.addRect(rect(q, r)) }
            }
        }
        ctx.fill(bell, with: .color(JellyPalette.bellMid.opacity(0.94)))
        ctx.fill(edgeLights, with: .color(light.opacity(0.20 + 0.75 * levels.edge)))

        // The glyph, drawn only where the bell actually is in this frame.
        for (cells, level) in [(glyphRing, levels.ring), (glyphCore, levels.core)] {
            var path = Path()
            for spot in cells where spot.r < grid.count && grid[spot.r][spot.q] != "." {
                path.addRect(rect(spot.q, spot.r))
            }
            ctx.fill(path, with: .color(light.opacity(0.12 + 0.83 * level)))
        }

        // The face. One blink on a slow clock; the eyes never move row, because tying them
        // to the frame put a one-pixel lurch in the face on every acting pulse.
        let blink = (time / 3.6).truncatingRemainder(dividingBy: 1) < 0.05
        var eyes = Path()
        for q in eyeCols {
            eyes.addRect(rect(q, blink ? eyeRow + 1 : eyeRow, rows: blink ? 1 : 2))
        }
        ctx.fill(eyes, with: .color(JellyPalette.eye.opacity(0.95)))
        if phase == .needsHuman {
            // Worried brows, and only where plain bell sits under them. Row 3 carries the
            // frame table's own lights at columns 3 and 10 in both squeeze frames, so a
            // fixed brow landed exactly on one every contraction and the pair stopped
            // reading as brows — they became two of four amber dots in a row.
            var brows = Path()
            for q in [3, 10] where grid[eyeRow - 1][q] == "1" {
                brows.addRect(rect(q, eyeRow - 1))
            }
            ctx.fill(brows, with: .color(JellyPalette.glowAttention.opacity(0.95)))
        }

        drawStrands(in: &ctx, grid: grid, time: time, phase: phase, moving: moving)
    }

    /// The strands hang from the hem, so their roots have to be on it. Mapping a rest
    /// column into the frame's hem span and rounding put four of the six roots on *empty*
    /// hem columns in both squeeze frames — strands dangling in open water — and collapsed
    /// all six onto six adjacent columns, which reads as one slab rather than six strands.
    private static func drawStrands(
        in ctx: inout GraphicsContext, grid: [[Character]],
        time: TimeInterval, phase: OverlayModel.Phase, moving: Bool,
    ) {
        let hem = grid[8]
        let hemCells = hem.indices.filter { hem[$0] != "." }
        guard let hemMin = hemCells.first, let hemMax = hemCells.last else { return }
        let hemCentre = Double(hemMin + hemMax) / 2
        let hemHalf = max(0.5, Double(hemMax - hemMin) / 2)
        let restCentre = 6.5, restHalf = 5.5

        let curled = phase == .needsHuman
        let length = curled ? 3 : 7
        let speed = (phase == .acting || moving) ? 0.45 : 1.0

        // One path per link index: the six strands share an alpha at the same depth, so the
        // whole fringe costs seven fills instead of forty-two.
        for k in 0 ..< length {
            var path = Path()
            let (lagX, lagY) = lag(time: time, phase: phase, age: Double(k + 1) * 0.049)
            let alpha = max(0.12, 0.85 - Double(k) * (curled ? 0.06 : 0.09))
            for (i, restCol) in strandCols.enumerated() {
                if (k + i) % 4 == 3 { continue }
                let wanted = hemCentre + (Double(restCol) - restCentre) * (hemHalf / restHalf)
                var root = hemCells[0]
                for q in hemCells where abs(Double(q) - wanted) < abs(Double(root) - wanted) {
                    root = q
                }
                // Walk the strand down from its root, one column of travel per link at most
                // — any more and a strand stops being a strand.
                var col = root
                for step in 0 ... k {
                    let sway = sin(time * 2 * .pi * speed / (2.4 + Double(i) * 0.3) - Double(step) * 0.7)
                    let want = Double(root) + sway * (curled ? 0.6 : 1.5) + lagX * 0.35
                    if want > Double(col) + 0.5 { col += 1 } else if want < Double(col) - 0.5 { col -= 1 }
                    col = min(max(col, 0), gridW - 1)
                }
                let fall = curled ? Int((sin(Double(k) / Double(length) * .pi) * 1.2).rounded()) : k
                var cellRect = rect(col, 9 + fall)
                cellRect.origin.y += lagY * 0.3
                path.addRect(cellRect)
            }
            ctx.fill(path, with: .color(JellyPalette.bellRim.opacity(alpha)))
        }
    }

    /// Where the body was `age` seconds ago, relative to where it is now. The whole-body
    /// motion is a pure function of time, so a lagging part can simply evaluate it in the
    /// past — no simulation history to keep, and it stays exact under scrubbing or a
    /// dropped frame.
    private static func lag(
        time: TimeInterval, phase: OverlayModel.Phase, age: Double
    ) -> (x: Double, y: Double) {
        let now = JellyfishArt.bodyOffset(time: time, phase: phase)
        let then = JellyfishArt.bodyOffset(time: time - age, phase: phase)
        return (then.x - now.x, then.y - now.y)
    }
}
