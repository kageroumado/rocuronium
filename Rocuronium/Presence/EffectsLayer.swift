import AppKit
import SwiftUI

/// Where the escorting jellyfish is drawn, and how it leans.
struct EscortPose {
    var position: CGPoint
    var lean: Double
    var moving: Bool
}

/// The full-screen effects, drawn as a pure function of the model and a clock: the amber
/// hands-off border, the charge sigil, click ripples, the pointer's wake and the escort.
///
/// The live overlay calls this from a 60 fps `Canvas` with the wall clock and the real pointer;
/// the showcase calls it with scene time and a scripted pointer, so both draw the same frame.
@MainActor
enum EffectsRenderer {
    enum Constants {
        /// The jellyfish's box beside the pointer.
        static let jellySize = CGSize(width: 46, height: 60)
        /// The escort rides a hand's width above-left of the pointer.
        static let escortOffset = CGPoint(x: -66, y: -80)
        /// The border eases in over this once hands-off begins.
        static let borderFadeIn: TimeInterval = 0.25
        static let borderWidth: CGFloat = 3
        /// Matches the rounded corners of a built-in display.
        static let borderCornerRadius: CGFloat = 10
        static let rippleStartRadius: CGFloat = 11
        static let rippleGrowth: CGFloat = 20
    }

    /// The hands-off color: amber, the same hue the jellyfish wears when it needs the human.
    static let amber = JellyPalette.glowAttention

    struct TrailDot {
        let point: CGPoint
        let age: TimeInterval
    }

    static func draw(
        in context: GraphicsContext, size: CGSize, model: OverlayModel, now: Date,
        escort: EscortPose?, trail: [TrailDot], style: JellyStyle,
    ) {
        let time = now.timeIntervalSinceReferenceDate
        if let start = model.handsOffStart, model.action?.cursorTaking == true, model.consent == nil {
            let fade = min(1, max(0, now.timeIntervalSince(start) / Constants.borderFadeIn))
            drawBorder(in: context, size: size, strength: fade, time: time)
        }

        for dot in trail where dot.age < EscortState.trailLifetime {
            let fade = 1 - dot.age / EscortState.trailLifetime
            let radius = 4.5 * (0.22 + 0.78 * fade)
            context.fill(
                Path(ellipseIn: CGRect(x: dot.point.x - radius, y: dot.point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(JellyPalette.trail.opacity(fade)),
            )
        }

        if let ring = model.chargeRing {
            let elapsed = now.timeIntervalSince(ring.start)
            SigilArt.draw(
                in: context, at: ring.point,
                progress: min(1, elapsed / ring.duration), elapsed: elapsed, time: time,
            )
        }

        for ripple in model.ripples {
            let age = now.timeIntervalSince(ripple.start)
            guard age >= 0, age < OverlayModel.Constants.rippleLife else { continue }
            let progress = age / OverlayModel.Constants.rippleLife
            let radius = Constants.rippleStartRadius + Constants.rippleGrowth * progress
            context.stroke(
                Path(ellipseIn: CGRect(x: ripple.point.x - radius, y: ripple.point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(JellyPalette.agent.opacity(0.9 * (1 - progress))),
                lineWidth: 2.5,
            )
        }

        if let escort {
            JellyfishArt.draw(
                in: context,
                rect: CGRect(origin: escort.position, size: Constants.jellySize),
                time: time, phase: .acting, lean: escort.lean, moving: escort.moving, style: style,
            )
        }
    }

    /// The hands-off frame: a thin amber line around the screen with a soft inner glow,
    /// breathing slowly so it reads as live rather than as a stuck highlight.
    private static func drawBorder(in context: GraphicsContext, size: CGSize, strength: Double, time: TimeInterval) {
        let breathe = 0.85 + 0.15 * sin(time * 2 * .pi / 1.6)
        let glows: [(width: CGFloat, opacity: Double)] = [(12, 0.07), (7, 0.14), (Constants.borderWidth, 0.95)]
        for glow in glows {
            let inset = glow.width / 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            context.stroke(
                Path(roundedRect: rect, cornerRadius: Constants.borderCornerRadius, style: .continuous),
                with: .color(amber.opacity(glow.opacity * strength * breathe)),
                lineWidth: glow.width,
            )
        }
    }
}

/// The live full-screen layer: the renderer at 60 fps against the real pointer, with the
/// spring-following escort while a hands-off action runs.
///
/// The escort reads `NSEvent.mouseLocation` per frame — zero engine coupling: the overlay
/// watches the same pointer the human does, whoever is moving it.
struct OverlayEffectsView: View {
    let model: OverlayModel
    @State private var follow = EscortState()
    @State private var hidden = false

    var body: some View {
        let style = JellyStyleStore.shared.style
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: hidden)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                // Cocoa's pointer is bottom-left global; the window covers the primary screen,
                // so flipping through the view height lands in view space.
                let mouse = NSEvent.mouseLocation
                let cursor = CGPoint(x: mouse.x, y: size.height - mouse.y)
                let escorting = model.action?.cursorTaking == true && model.consent == nil
                let offset = EffectsRenderer.Constants.escortOffset
                let target = CGPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)
                let seconds = now.timeIntervalSinceReferenceDate
                follow.update(now: seconds, cursor: cursor, target: target, escorting: escorting)
                EffectsRenderer.draw(
                    in: context, size: size, model: model, now: now,
                    escort: escorting ? EscortPose(position: follow.position, lean: follow.lean, moving: follow.isMoving) : nil,
                    trail: follow.trail.map { EffectsRenderer.TrailDot(point: $0.point, age: seconds - $0.time) },
                    style: style,
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Chrome, not content: the overlay must be invisible to accessibility, or its own
        // narration poisons label queries against this app.
        .accessibilityHidden(true)
        .pausedWhileWindowHidden($hidden)
    }
}
