import AppKit
import Propofol
import SwiftUI

/// How the panel's surface is drawn. Liquid Glass live; a flat translucent fill where glass
/// cannot render — offline `ImageRenderer` captures and Reduce Transparency.
enum PanelSurface {
    case glass
    case flat
}

extension EnvironmentValues {
    @Entry var panelSurface: PanelSurface = .glass
    /// The live panel moves its window when dragged by its body; the showcase's copy does not.
    @Entry var panelDraggable = false
}

/// One color per mode, worn by the pill, its dot, the current step's dot, and — for the modes
/// that ask something of the human — the panel's edge. System colors, so each holds up in
/// light and dark.
enum PanelPalette {
    static func tint(for mode: OverlayModel.Mode) -> Color {
        switch mode {
        case .background: .blue
        case .thinking: .purple
        case .handsOff: EffectsRenderer.amber
        case .needsYou: .orange
        case .stopped: .red
        case .done: .green
        case .ended: .gray
        }
    }

    /// The modes that ask something of the human paint the panel's edge.
    static func accent(for mode: OverlayModel.Mode) -> Color? {
        switch mode {
        case .handsOff, .needsYou, .stopped: tint(for: mode)
        default: nil
        }
    }

    static func color(for kind: PanelResult.Kind) -> Color {
        switch kind {
        case .confirmed: .green
        case .failed: .red
        case .unverified: .secondary
        case .refused: .secondary
        case .notCounted: .orange
        }
    }

    static func symbol(for kind: PanelResult.Kind) -> String {
        switch kind {
        case .confirmed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unverified: "questionmark.circle"
        case .refused: "hand.raised.fill"
        case .notCounted: "circle.lefthalf.filled"
        }
    }
}

/// The presence panel: two lines and one pill. Line 1 is the goal and the mode pill, the
/// answer to "may I keep using my Mac?"; line 2 is what is happening now and, at its right,
/// the stop chord. A consent prompt or the step list opens underneath.
///
/// Renders from the model at an instant. Live, it ticks its own clock; the showcase and the
/// offline renderer pass `fixedNow` (scene time), so every frame is reproducible.
struct PanelView: View {
    enum Constants {
        static let width: CGFloat = 540
        /// Apple's capture bar radius, grown with the panel's height.
        static let cornerRadius: CGFloat = 18
        static let markSize = CGSize(width: 26, height: 34)
        static let columnSpacing: CGFloat = 12
        static let lineSpacing: CGFloat = 5
        static let titleSize: CGFloat = 13
        static let bodySize: CGFloat = 12
        static let pillSize: CGFloat = 11
        static let pillHeight: CGFloat = 20
        static let chevronWidth: CGFloat = 20
        static let stepDot: CGFloat = 16
        /// How often the live panel redraws its clocks and lines.
        static let tick: TimeInterval = 0.25
    }

    let model: OverlayModel
    var fixedNow: Date?
    @State private var hidden = false

    var body: some View {
        if let fixedNow {
            PanelContent(model: model, now: fixedNow, animatesMark: false)
        } else {
            TimelineView(.animation(minimumInterval: Constants.tick, paused: hidden)) { timeline in
                PanelContent(model: model, now: timeline.date, animatesMark: true)
            }
            .pausedWhileWindowHidden($hidden)
        }
    }
}

private struct PanelContent: View {
    let model: OverlayModel
    let now: Date
    let animatesMark: Bool

    private typealias Metrics = PanelView.Constants

    var body: some View {
        let lines = PanelLines(model: model, at: now)
        let tint = PanelPalette.tint(for: lines.mode)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Metrics.columnSpacing) {
                PanelMark(phase: model.phase(at: now), time: animatesMark ? nil : now)
                    .frame(width: Metrics.markSize.width, height: Metrics.markSize.height)
                lineGrid(lines, tint: tint)
            }
            if model.consent != nil {
                ConsentBlock(model: model)
                    .padding(.leading, Metrics.markSize.width + Metrics.columnSpacing)
                    .padding(.top, Theme.Space.sm + 2)
            } else if model.panelExpanded, !model.steps.isEmpty {
                StepList(steps: model.steps, current: model.stepIndex, tint: tint)
                    .padding(.leading, Metrics.markSize.width + Metrics.columnSpacing)
                    .padding(.top, Theme.Space.sm + 2)
            }
        }
        .padding(.vertical, Theme.Space.md)
        .padding(.leading, Theme.Space.md + 2)
        .padding(.trailing, Theme.Space.md + 4)
        .frame(width: Metrics.width, alignment: .leading)
        .modifier(PanelChrome(accent: PanelPalette.accent(for: lines.mode), pulse: pulse(lines.mode)))
        .modifier(PanelDragBehavior())
        // Chrome, not content: the overlay must stay out of the accessibility tree, or its own
        // narration matches label queries aimed at this app.
        .accessibilityHidden(true)
    }

    /// Line 1 (goal · pill · chevron) over line 2 (step and now · stop chord), with the chord
    /// right-aligned under the pill.
    private func lineGrid(_ lines: PanelLines, tint: Color) -> some View {
        let hasSteps = !model.steps.isEmpty && model.consent == nil
        return Grid(alignment: .leading, horizontalSpacing: Theme.Space.md, verticalSpacing: Metrics.lineSpacing) {
            GridRow {
                Text(lines.goal)
                    .font(.system(size: Metrics.titleSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ModePill(lines: lines, tint: tint)
                    if hasSteps { ExpandButton(model: model) }
                }
                .gridColumnAlignment(.trailing)
            }
            GridRow {
                LineTwo(lines: lines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StopHint()
                    .padding(.trailing, hasSteps ? Metrics.chevronWidth + 6 : 0)
            }
        }
    }

    /// A one-shot swell as hands-off begins, so the change of mode is felt, not just read.
    private func pulse(_ mode: OverlayModel.Mode) -> Double {
        guard mode == .handsOff, let start = model.handsOffStart else { return 0 }
        let t = now.timeIntervalSince(start) / OverlayModel.Constants.pulse
        guard t >= 0, t < 1 else { return 0 }
        return sin(t * .pi)
    }
}

/// The panel's surface: glass (or its flat stand-in), a hairline edge that takes the mode's
/// color when the human's hands are needed, and the drag handle underneath everything.
struct PanelChrome: ViewModifier {
    var accent: Color?
    /// 0…1: the hands-off entry swell.
    var pulse: Double = 0
    @Environment(\.panelSurface) private var surface
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PanelView.Constants.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        let flat = surface == .flat || reduceTransparency
        return content
            .background {
                if flat {
                    shape.fill(flatFill)
                        .overlay { if let accent { shape.fill(accent.opacity(scheme == .dark ? 0.10 : 0.07)) } }
                        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 14, y: 6)
                }
            }
            .modifier(GlassIfLive(enabled: !flat, tint: accent, shape: shape))
            .overlay(shape.strokeBorder(edge, lineWidth: accent == nil ? 0.5 : 1.25))
            .shadow(color: (accent ?? .clear).opacity(0.55 * pulse), radius: 14 * pulse)
            .scaleEffect(1 + 0.025 * pulse)
    }

    private var edge: Color {
        if let accent { return accent.opacity(0.85) }
        return scheme == .dark ? .white.opacity(0.14) : .black.opacity(0.10)
    }

    /// Frosted rather than solid: enough of the desktop shows through to read as glass in a
    /// still image, and text keeps full contrast against it.
    private var flatFill: some ShapeStyle {
        scheme == .dark
            ? AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.20).opacity(0.92), Color(white: 0.14).opacity(0.94)],
                startPoint: .top, endPoint: .bottom,
            ))
            : AnyShapeStyle(LinearGradient(
                colors: [Color(white: 1).opacity(0.90), Color(white: 0.95).opacity(0.92)],
                startPoint: .top, endPoint: .bottom,
            ))
    }
}

private struct GlassIfLive: ViewModifier {
    let enabled: Bool
    let tint: Color?
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(tint.map { .regular.tint($0.opacity(0.22)) } ?? .regular, in: shape)
        } else {
            content
        }
    }
}

/// The one pill: the mode's dot, its word, and the clock, tinted by mode.
private struct ModePill: View {
    let lines: PanelLines
    let tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: tint, glow: lines.mode != .ended, diameter: 6)
            Text(lines.pillTitle)
                .fontWeight(.semibold)
            Text(lines.pillClock)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: PanelView.Constants.pillSize))
        .padding(.horizontal, 9)
        .frame(height: PanelView.Constants.pillHeight)
        .background(Capsule().fill(tint.opacity(scheme == .dark ? 0.26 : 0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(scheme == .dark ? 0.45 : 0.35), lineWidth: 0.5))
        .fixedSize()
    }
}

/// The stop chord: small plain key glyphs and the word, right-aligned under the pill — the
/// only place the chord appears in the panel.
private struct StopHint: View {
    var body: some View {
        HStack(spacing: 4) {
            Text(Self.chord)
                .tracking(1.5)
            Text("stop")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    static let chord = HotkeyMonitor.chord.displayKeys
        .map { $0 == "esc" ? "⎋" : $0 }
        .joined()
}

/// Line 2: the step prefix, then the action phrase, its outcome, a state sentence, or the
/// consent question.
private struct LineTwo: View {
    let lines: PanelLines

    var body: some View {
        content
            .font(.system(size: PanelView.Constants.bodySize))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var prefix: Text {
        guard let step = lines.stepPrefix else { return Text(verbatim: "") }
        return Text("\(Text(verbatim: step).fontWeight(.semibold).monospacedDigit())\(Text(verbatim: "  ·  ").foregroundStyle(.tertiary))")
            .foregroundStyle(.secondary)
    }

    private var content: Text {
        switch lines.detail {
        case let .text(text, tone):
            let body: Text = switch tone {
            case .quiet: Text(verbatim: text).foregroundStyle(.secondary)
            case .caution: Text(verbatim: text).foregroundStyle(.orange)
            case .alert: Text(verbatim: text).fontWeight(.medium).foregroundStyle(.primary)
            }
            return Text("\(prefix)\(body)")
        case let .outcome(outcome):
            let glyph = Text(Image(systemName: PanelPalette.symbol(for: outcome.result.kind)))
                .foregroundStyle(PanelPalette.color(for: outcome.result.kind))
            let detail = Text(verbatim: outcome.result.detail).fontWeight(.medium).foregroundStyle(.primary)
            guard let lead = outcome.lead else {
                return Text("\(prefix)\(glyph) \(detail)")
            }
            let leading = Text(verbatim: lead).foregroundStyle(.secondary)
            let dot = Text(verbatim: "  ·  ").foregroundStyle(.tertiary)
            return Text("\(prefix)\(leading)\(dot)\(glyph) \(detail)")
        case let .question(question):
            return Text(verbatim: question).font(.system(size: PanelView.Constants.titleSize, weight: .medium)).foregroundStyle(.primary)
        }
    }
}

private struct ExpandButton: View {
    let model: OverlayModel

    var body: some View {
        Button {
            model.panelExpanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(model.panelExpanded ? 180 : 0))
                .foregroundStyle(.secondary)
                .frame(width: PanelView.Constants.chevronWidth, height: PanelView.Constants.pillHeight)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.panelExpanded ? "Hide the steps" : "Show the steps")
    }
}

/// The declared steps as numbered dots: done (neutral, filled), now (the mode's color, bold),
/// still to come (outlined).
private struct StepList: View {
    let steps: [String]
    let current: Int?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                row(index: index, step: step)
            }
        }
        .padding(.top, Theme.Space.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func row(index: Int, step: String) -> some View {
        let state: StepState = switch current {
        case let current? where index < current: .done
        case let current? where index == current: .now
        default: .later
        }
        return HStack(spacing: 8) {
            StepDot(number: index + 1, state: state, tint: tint)
            Text(step)
                .font(.system(size: PanelView.Constants.bodySize, weight: state == .now ? .semibold : .regular))
                .foregroundStyle(state == .now ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
    }
}

private enum StepState {
    case done, now, later
}

private struct StepDot: View {
    let number: Int
    let state: StepState
    let tint: Color

    var body: some View {
        let size = PanelView.Constants.stepDot
        ZStack {
            switch state {
            case .done: Circle().fill(Color.primary.opacity(0.12))
            case .now: Circle().fill(tint)
            case .later: Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1)
            }
            Text(verbatim: "\(number)")
                .font(.system(size: 9.5, weight: state == .now ? .bold : .semibold).monospacedDigit())
                .foregroundStyle(state == .now ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .frame(width: size, height: size)
    }
}

/// The consent prompt inside the panel: three hold-to-answer keys and one hint. The fill under
/// each key grows with the hold, so a deliberate one-second press reads as intent and a stray
/// tap visibly does nothing.
private struct ConsentBlock: View {
    let model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                ConsentKey(key: "Y", title: "Approve", tint: .green, fraction: fraction(.approve))
                ConsentKey(key: "A", title: "Approve all for \(StandingApproval.minutes) min", tint: .blue, fraction: fraction(.approveForAWhile))
                ConsentKey(key: "N", title: "Decline", tint: .gray, fraction: fraction(.decline))
            }
            Text("Hold a key for 1 second")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func fraction(_ answer: ConsentAnswer) -> Double {
        guard let hold = model.consentHold, hold.answer == answer else { return 0 }
        return hold.fraction
    }
}

private struct ConsentKey: View {
    let key: String
    let title: String
    let tint: Color
    let fraction: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 7) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .frame(height: 30)
        .background {
            ZStack(alignment: .leading) {
                shape.fill(tint.opacity(0.14))
                GeometryReader { geometry in
                    shape.fill(tint.opacity(0.45)).frame(width: geometry.size.width * fraction)
                }
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .fixedSize()
    }
}

/// The small jellyfish at the panel's left edge, in the phase the session is in.
struct PanelMark: View {
    let phase: OverlayModel.Phase
    /// A fixed instant to draw; `nil` animates.
    let time: Date?
    @State private var hidden = false

    var body: some View {
        if let time {
            canvas(at: time)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: hidden)) { timeline in
                canvas(at: timeline.date)
            }
            .pausedWhileWindowHidden($hidden)
        }
    }

    private func canvas(at date: Date) -> some View {
        let style = JellyStyleStore.shared.style
        let phase = phase == .hidden ? .idle : phase
        return Canvas { context, size in
            JellyfishArt.draw(
                in: context, rect: CGRect(origin: .zero, size: size),
                time: date.timeIntervalSinceReferenceDate, phase: phase, style: style,
            )
        }
    }
}

/// Dragging the panel by its body moves its window, the ⌘⇧5 bar's behavior. The SwiftUI
/// gesture covers the text; the AppKit handle underneath covers the padding, where SwiftUI
/// has nothing to hit. Buttons win over both, so the chevron still toggles.
private struct PanelDragBehavior: ViewModifier {
    @Environment(\.panelDraggable) private var draggable

    func body(content: Content) -> some View {
        if draggable {
            content
                .contentShape(.rect(cornerRadius: PanelView.Constants.cornerRadius, style: .continuous))
                .gesture(WindowDragGesture())
                .background(PanelDragHandle())
        } else {
            content
        }
    }
}

/// Behind the glass: a mouse-down here starts a WindowServer drag of the panel, so the human
/// can move it anywhere by its body while the buttons on top keep working.
struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context _: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_: DragHandleView, context _: Context) {}

    final class DragHandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            window.performDrag(with: event)
        }
    }
}
