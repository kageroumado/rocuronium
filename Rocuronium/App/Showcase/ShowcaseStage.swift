import SwiftUI

/// One frame of a scene: the pretend desktop with the real effects layer and panel drawn over
/// it from the scene's own model, at scene time `t`.
///
/// Touches nothing live — no overlay controller, no engine, no input — so it can play in a
/// window and render to a PNG alike.
struct ShowcaseStage: View {
    enum Constants {
        /// How far the escort trails the pointer, and the step between the wake's dots.
        static let escortLag: TimeInterval = 0.12
        static let trailStep: TimeInterval = 0.04
        static let trailDots = 18
    }

    let scene: ShowcaseScene
    let t: TimeInterval

    var body: some View {
        ZStack(alignment: .topLeading) {
            layers(at: t)
            if let dissolve {
                layers(at: 0).opacity(dissolve)
            }
        }
        .frame(width: MockLayout.desktop.width, height: MockLayout.desktop.height, alignment: .topLeading)
        .clipped()
    }

    /// 0…1 over the scene's closing dissolve into its first frame; nil outside it.
    private var dissolve: Double? {
        guard scene.loopDissolve > 0 else { return nil }
        let start = scene.duration - scene.loopDissolve
        guard t > start else { return nil }
        return min(1, (t - start) / scene.loopDissolve)
    }

    private func layers(at t: TimeInterval) -> some View {
        let frame = scene.frame(at: t)
        let now = scene.date(t)
        let presentation = frame.model.presentation(at: now)
        return ZStack(alignment: .topLeading) {
            MockDesktopView(state: frame.desktop)
            if presentation.effectsVisible {
                effects(model: frame.model, now: now, t: t)
            }
            if presentation.isUp {
                chrome(model: frame.model, now: now)
                    .opacity(presentation.opacity)
            }
            MockPointer(state: frame.desktop)
        }
    }

    /// The panel at its default spot above the Dock, growing upward when it opens.
    private func chrome(model: OverlayModel, now: Date) -> some View {
        PanelView(model: model, fixedNow: now)
            .frame(width: MockLayout.desktop.width, height: MockLayout.panelBottom, alignment: .bottom)
    }

    private func effects(model: OverlayModel, now: Date, t: TimeInterval) -> some View {
        let escorting = model.action?.cursorTaking == true && model.consent == nil
        let pose = escorting ? escortPose(at: t) : nil
        let trail = escorting ? trailDots(at: t) : []
        let style = JellyStyleStore.shared.style
        return Canvas { context, size in
            EffectsRenderer.draw(
                in: context, size: size, model: model, now: now,
                escort: pose, trail: trail, style: style,
            )
        }
        .frame(width: MockLayout.desktop.width, height: MockLayout.desktop.height)
        .allowsHitTesting(false)
    }

    /// The live escort is a spring chasing the pointer; here it is the pointer a beat ago,
    /// leaning into its motion — the same look, reproducible at any `t`.
    private func escortPose(at t: TimeInterval) -> EscortPose {
        let lagged = scene.pointer(at: t - Constants.escortLag).point
        let earlier = scene.pointer(at: t - Constants.escortLag - 0.05).point
        let velocity = (lagged.x - earlier.x) / 50
        let offset = EffectsRenderer.Constants.escortOffset
        return EscortPose(
            position: CGPoint(x: lagged.x + offset.x, y: lagged.y + offset.y),
            lean: max(-13, min(13, velocity * 55)),
            moving: hypot(lagged.x - earlier.x, lagged.y - earlier.y) > 2,
        )
    }

    private func trailDots(at t: TimeInterval) -> [EffectsRenderer.TrailDot] {
        // A dot only where the pointer was moving, as the live wake drops them.
        (0 ..< Constants.trailDots).compactMap { index in
            let age = Double(index) * Constants.trailStep
            let point = scene.pointer(at: t - age).point
            let older = scene.pointer(at: t - age - Constants.trailStep).point
            guard hypot(point.x - older.x, point.y - older.y) > 1.5 else { return nil }
            return EffectsRenderer.TrailDot(point: point, age: age)
        }
    }
}
