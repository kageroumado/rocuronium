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

/// The color each mode wears on its chip and, for the modes that ask something of the human,
/// on the panel's edge.
enum PanelPalette {
    static func tint(for mode: OverlayModel.Mode) -> Color {
        switch mode {
        case .background: .green
        case .handsOff, .needsYou: EffectsRenderer.amber
        case .waiting: .blue
        case .thinking: Theme.agent
        case .done: .secondary
        }
    }

    /// The modes that ask something of the human paint the panel's edge.
    static func accent(for mode: OverlayModel.Mode) -> Color? {
        switch mode {
        case .handsOff, .needsYou: EffectsRenderer.amber
        default: nil
        }
    }

    static func color(for kind: PanelResult.Kind) -> Color {
        switch kind {
        case .confirmed: .green
        case .failed: .red
        case .unverified: .secondary
        case .refused: .orange
        case .humanInput: .orange
        }
    }

    static func symbol(for kind: PanelResult.Kind) -> String {
        switch kind {
        case .confirmed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unverified: "questionmark.circle"
        case .refused: "hand.raised.fill"
        case .humanInput: "exclamationmark.triangle.fill"
        }
    }
}

/// The presence panel: goal, now, result — and the mode chip that answers "may I keep using
/// my Mac?" before anything else.
///
/// Renders from the model at an instant. Live, it ticks its own clock; the showcase and the
/// offline renderer pass `fixedNow` (scene time), so every frame is reproducible.
struct PanelView: View {
    enum Constants {
        static let width: CGFloat = 540
        /// Apple's capture bar radius.
        static let cornerRadius: CGFloat = 15
        static let markSize = CGSize(width: 26, height: 34)
        static let columnSpacing: CGFloat = 10
        static let lineSpacing: CGFloat = 3
        static let titleSize: CGFloat = 13
        static let bodySize: CGFloat = 12
        static let chipSize: CGFloat = 11
        /// Line 3's height, fixed so the panel never jumps as results come and go.
        static let noteHeight: CGFloat = 16
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

    var body: some View {
        let lines = PanelLines(model: model, at: now)
        let accent = PanelPalette.accent(for: lines.mode)
        VStack(alignment: .leading, spacing: 0) {
            header(lines)
            if model.panelExpanded, !model.steps.isEmpty {
                StepList(steps: model.steps, current: model.stepIndex)
                    .padding(.leading, PanelView.Constants.markSize.width + PanelView.Constants.columnSpacing)
                    .padding(.top, Theme.Space.sm)
            }
        }
        .padding(.vertical, Theme.Space.sm + 2)
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, Theme.Space.md + 2)
        .frame(width: PanelView.Constants.width, alignment: .leading)
        .modifier(PanelChrome(accent: accent, pulse: pulse(lines.mode)))
        .modifier(PanelDragBehavior())
        // Chrome, not content: the overlay must stay out of the accessibility tree, or its own
        // narration matches label queries aimed at this app.
        .accessibilityHidden(true)
    }

    /// A one-shot swell as hands-off begins, so the change of mode is felt, not just read.
    private func pulse(_ mode: OverlayModel.Mode) -> Double {
        guard mode == .handsOff, let start = model.handsOffStart else { return 0 }
        let t = now.timeIntervalSince(start) / OverlayModel.Constants.pulse
        guard t >= 0, t < 1 else { return 0 }
        return sin(t * .pi)
    }

    private func header(_ lines: PanelLines) -> some View {
        HStack(alignment: .center, spacing: PanelView.Constants.columnSpacing) {
            PanelMark(phase: model.phase(at: now), time: animatesMark ? nil : now)
                .frame(width: PanelView.Constants.markSize.width, height: PanelView.Constants.markSize.height)
            VStack(alignment: .leading, spacing: PanelView.Constants.lineSpacing) {
                HStack(spacing: Theme.Space.sm) {
                    Text(lines.goal)
                        .font(.system(size: PanelView.Constants.titleSize, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Space.sm)
                    ModeChip(lines: lines)
                    StopChip()
                }
                HStack(spacing: 6) {
                    Text(lines.now)
                        .font(.system(size: PanelView.Constants.bodySize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Space.sm)
                    Text(lines.clock)
                        .font(.system(size: PanelView.Constants.chipSize).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !model.steps.isEmpty {
                        ExpandButton(model: model)
                    }
                }
                NoteLine(note: lines.note)
                    .frame(height: PanelView.Constants.noteHeight, alignment: .leading)
            }
        }
    }
}

/// The panel's surface: glass (or its flat stand-in), a hairline edge that turns amber when the
/// human's hands are needed, and the drag handle underneath everything.
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
                        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 12, y: 5)
                }
            }
            .modifier(GlassIfLive(enabled: !flat, tint: accent, shape: shape))
            .overlay(shape.strokeBorder(edge, lineWidth: accent == nil ? 0.5 : 1.25))
            .shadow(color: (accent ?? .clear).opacity(0.55 * pulse), radius: 14 * pulse)
            .scaleEffect(1 + 0.025 * pulse)
    }

    private var edge: Color {
        if let accent { return accent.opacity(0.9) }
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

/// The mode chip: bold mode, quiet detail, colored by mode. Hands off is a solid amber capsule —
/// the one state that asks the human to let go.
private struct ModeChip: View {
    let lines: PanelLines
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = PanelPalette.tint(for: lines.mode)
        let solid = lines.mode == .handsOff
        HStack(spacing: 5) {
            StatusDot(color: solid ? .black.opacity(0.75) : tint, glow: !solid, diameter: 6)
            Text(lines.chipTitle)
                .fontWeight(.semibold)
            if !lines.chipDetail.isEmpty {
                Text("· \(lines.chipDetail)")
                    .monospacedDigit()
                    .foregroundStyle(solid ? AnyShapeStyle(.black.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: PanelView.Constants.chipSize))
        .foregroundStyle(solid ? AnyShapeStyle(.black.opacity(0.88)) : AnyShapeStyle(.primary))
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 3)
        .background {
            ZStack(alignment: .leading) {
                Capsule().fill(solid ? tint : tint.opacity(scheme == .dark ? 0.22 : 0.16))
                if let progress = lines.chipProgress {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(tint.opacity(0.32))
                            .frame(width: max(geometry.size.height, geometry.size.width * progress))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .fixedSize()
    }
}

/// The stop chord, always in view while anything is up.
private struct StopChip: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Stop")
            Text(Self.chord).tracking(0.5)
        }
        .font(.system(size: PanelView.Constants.chipSize, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .fixedSize()
    }

    static let chord = HotkeyMonitor.chord.displayKeys
        .map { $0 == "esc" ? "⎋" : $0 }
        .joined()
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
                .frame(width: 18, height: 16)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.panelExpanded ? "Hide the steps" : "Show the steps")
    }
}

private struct NoteLine: View {
    let note: PanelLines.Note

    var body: some View {
        switch note {
        case let .result(result):
            HStack(spacing: 5) {
                Image(systemName: PanelPalette.symbol(for: result.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelPalette.color(for: result.kind))
                Text(result.message)
                    .font(.system(size: PanelView.Constants.bodySize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case let .hint(text, caution):
            Text(text)
                .font(.system(size: PanelView.Constants.bodySize))
                .foregroundStyle(caution ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.tail)
        case .empty:
            Color.clear
        }
    }
}

/// The declared steps: done, now, still to come.
private struct StepList: View {
    let steps: [String]
    let current: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                row(index: index, step: step)
            }
        }
        .padding(.top, Theme.Space.sm)
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
        return HStack(spacing: 7) {
            Image(systemName: state.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 14)
            Text(step)
                .font(.system(size: PanelView.Constants.bodySize, weight: state == .now ? .semibold : .regular))
                .foregroundStyle(state == .later ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if state == .now {
                Text("now")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.agent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.agent.opacity(0.15)))
            }
        }
    }

    private enum StepState {
        case done, now, later

        var symbol: String {
            switch self {
            case .done: "checkmark.circle.fill"
            case .now: "circle.inset.filled"
            case .later: "circle"
            }
        }

        var color: Color {
            switch self {
            case .done: .green
            case .now: Theme.agent
            case .later: .secondary
            }
        }
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
