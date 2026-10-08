import SwiftUI

/// Who has one of the human's input devices at an instant.
enum DeckOwner: Equatable {
    /// Nobody is using it.
    case idle
    /// The human is using it: keys light, a fingertip moves on the trackpad.
    case human
    /// A ghost action is running and this device stays the human's.
    case stillYours
    /// A hands-off action drives this device.
    case agent
    /// A hands-off action drives the other device; any input here would stop it.
    case paused
}

/// The human's keyboard and trackpad at one instant, mirroring only their physical input.
struct InputDeckState: Equatable {
    /// Per key id, 0…1: how brightly the key is lit by the human's press.
    var keyGlow: [String: Double] = [:]
    var keyboard = DeckOwner.idle
    var trackpad = DeckOwner.idle
    /// The fingertip on the trackpad, in unit coordinates (0…1, top-left origin).
    var finger: CGPoint?
    /// Where the fingertip was a moment ago, newest first, in unit coordinates.
    var fingerTrail: [CGPoint] = []
    /// 0…1 while the human's click presses the trackpad.
    var fingerPress = 0.0
    /// The pointer the agent's hands-off action is moving, in trackpad unit coordinates.
    var agentPointer: CGPoint?
}

/// A key on the pretend keyboard: its id (what the typing maps to), its cap, and its width in
/// key units.
struct KeyCap {
    let id: String
    let label: String
    let units: Double

    init(_ id: String, _ label: String? = nil, _ units: Double = 1) {
        self.id = id
        self.label = label ?? id.uppercased()
        self.units = units
    }
}

/// The pretend keyboard's layout and which keys a typed character presses.
enum MockKeyboardLayout {
    static let rows: [[KeyCap]] = [
        "`1234567890-=".map { KeyCap(String($0)) } + [KeyCap("delete", "⌫", 1.5)],
        [KeyCap("tab", "⇥", 1.5)] + "qwertyuiop[]\\".map { KeyCap(String($0)) },
        [KeyCap("caps", "⇪", 1.75)] + "asdfghjkl;'".map { KeyCap(String($0)) } + [KeyCap("return", "↩", 1.75)],
        [KeyCap("lshift", "⇧", 2.25)] + "zxcvbnm,./".map { KeyCap(String($0)) } + [KeyCap("rshift", "⇧", 2.25)],
        [
            KeyCap("fn", "fn"), KeyCap("control", "⌃"), KeyCap("option", "⌥"), KeyCap("lcommand", "⌘", 1.25),
            KeyCap("space", "", 5), KeyCap("rcommand", "⌘", 1.25), KeyCap("roption", "⌥"),
            KeyCap("left", "◀"), KeyCap("updown", "▴▾"), KeyCap("right", "▶"),
        ],
    ]

    /// Every row spans this many key units.
    static let rowUnits = 14.5

    /// The keys one typed character presses: `A` is shift and a, `:` is shift and ;, an en
    /// dash is option and -.
    static func keys(for character: Character) -> [String] {
        switch character {
        case " ": return ["space"]
        case "\n": return ["return"]
        case ":": return [";", "lshift"]
        case "–": return ["-", "option"]
        case "@": return ["2", "lshift"]
        default:
            let lower = String(character).lowercased()
            let known = rows.joined().contains { $0.id == lower }
            guard known else { return [] }
            return character.isUppercase ? [lower, "lshift"] : [lower]
        }
    }
}

/// The colors the deck wears: the human's blue (the same as the pointer's "you" tag) and the
/// hands-off amber the panel and the screen border use.
enum DeckPalette {
    static let human = Color(red: 0.20, green: 0.45, blue: 0.85)
    static let agent = PanelPalette.tint(for: .handsOff)
}

/// The human's keyboard and trackpad, bottom-left of the pretend desktop: what the human's
/// hands are doing, and when a hands-off action has them.
struct InputDeckView: View {
    let state: InputDeckState
    @Environment(\.colorScheme) private var scheme

    enum Constants {
        static let padding: CGFloat = 10
        static let keyPitch: CGFloat = 19
        static let keyGap: CGFloat = 2.5
        static let deviceGap: CGFloat = 12
        static let headerHeight: CGFloat = 14
        static let headerSpacing: CGFloat = 6
        static let trackpadAspect: CGFloat = 1.32
        static let fingerDiameter: CGFloat = 14

        static var keyboardSize: CGSize {
            CGSize(width: MockKeyboardLayout.rowUnits * keyPitch - keyGap,
                   height: CGFloat(MockKeyboardLayout.rows.count) * keyPitch - keyGap)
        }

        static var trackpadSize: CGSize {
            CGSize(width: (keyboardSize.height * trackpadAspect).rounded(), height: keyboardSize.height)
        }

        /// The whole card.
        static var size: CGSize {
            CGSize(
                width: padding * 2 + keyboardSize.width + deviceGap + trackpadSize.width,
                height: padding * 2 + headerHeight + headerSpacing + keyboardSize.height,
            )
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.deviceGap) {
            VStack(alignment: .leading, spacing: Constants.headerSpacing) {
                DeckHeader(title: "KEYBOARD", owner: state.keyboard)
                KeyboardView(state: state)
                    .frame(width: Constants.keyboardSize.width, height: Constants.keyboardSize.height)
            }
            VStack(alignment: .leading, spacing: Constants.headerSpacing) {
                DeckHeader(title: "TRACKPAD", owner: state.trackpad)
                TrackpadView(state: state)
                    .frame(width: Constants.trackpadSize.width, height: Constants.trackpadSize.height)
            }
        }
        .padding(Constants.padding)
        .frame(width: Constants.size.width, height: Constants.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill((scheme == .dark ? Color.black : Color.white).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// A device's name and, when someone has it, a small chip saying who.
private struct DeckHeader: View {
    let title: String
    let owner: DeckOwner

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            chip
            Spacer(minLength: 0)
        }
        .frame(height: InputDeckView.Constants.headerHeight)
    }

    @ViewBuilder private var chip: some View {
        switch owner {
        case .idle: EmptyView()
        case .human: DeckChip(text: "you", color: DeckPalette.human, filled: true)
        case .stillYours: DeckChip(text: "still yours", color: .secondary, filled: false)
        case .agent: DeckChip(text: "hands off", color: DeckPalette.agent, filled: true)
        case .paused: DeckChip(text: "paused", color: DeckPalette.agent, filled: false)
        }
    }
}

private struct DeckChip: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(color))
            .padding(.horizontal, 6)
            .frame(height: 14)
            .background(Capsule().fill(filled ? color : .clear))
            .overlay(Capsule().strokeBorder(filled ? .clear : color.opacity(0.7), lineWidth: 0.75))
            .fixedSize()
    }
}

/// Rounded caps on an aluminum base; a pressed key lights in the human's blue and sinks a little.
/// One `Canvas` pass, so seventy keys cost one draw at 60 fps.
private struct KeyboardView: View {
    let state: InputDeckState
    @Environment(\.colorScheme) private var scheme
    private typealias Metrics = InputDeckView.Constants

    var body: some View {
        let dark = scheme == .dark
        let agent = state.keyboard == .agent
        let metal = dark ? Color(white: 0.16) : Color(white: 0.86)
        let resting = dark ? Color(white: 0.07) : Color.white
        let shadow = Color.black.opacity(dark ? 0.55 : 0.16)
        let label = dark ? Color(white: 0.62) : Color(white: 0.45)
        return Canvas { context, size in
            let base = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: -3, dy: -3), cornerRadius: 7, style: .continuous)
            context.fill(base, with: .color(agent ? metal.mix(with: DeckPalette.agent, by: 0.35) : metal))
            if agent { context.stroke(base, with: .color(DeckPalette.agent.opacity(0.9)), lineWidth: 1.5) }
            var y: CGFloat = 0
            for row in MockKeyboardLayout.rows {
                var x: CGFloat = 0
                for key in row {
                    let width = key.units * Metrics.keyPitch - Metrics.keyGap
                    let glow = state.keyGlow[key.id] ?? 0
                    let rect = CGRect(x: x, y: y, width: width, height: Metrics.keyPitch - Metrics.keyGap)
                    let pressed = rect.insetBy(dx: 0.6 * glow, dy: 0.6 * glow).offsetBy(dx: 0, dy: 0.5 * glow)
                    let cap = Path(roundedRect: pressed, cornerRadius: 3.5, style: .continuous)
                    if glow > 0 {
                        context.fill(
                            Path(roundedRect: pressed.insetBy(dx: -2.5 * glow, dy: -2.5 * glow), cornerRadius: 5, style: .continuous),
                            with: .color(DeckPalette.human.opacity(0.35 * glow)),
                        )
                    } else {
                        context.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 1), cornerRadius: 3.5, style: .continuous), with: .color(shadow))
                    }
                    context.fill(cap, with: .color(resting.mix(with: DeckPalette.human, by: 0.9 * glow)))
                    if !key.label.isEmpty {
                        let text = Text(key.label)
                            .font(.system(size: key.label.count > 1 ? 6.5 : 8, weight: .medium))
                            .foregroundStyle(glow > 0.3 ? Color.white : label)
                        context.draw(text, at: CGPoint(x: pressed.midX, y: pressed.midY))
                    }
                    x += key.units * Metrics.keyPitch
                }
                y += Metrics.keyPitch
            }
        }
        .opacity(state.keyboard == .paused ? 0.6 : 1)
    }
}

/// A Magic Trackpad: a glass slab with the human's fingertip and its short trail, or amber while
/// a hands-off action has the pointer.
private struct TrackpadView: View {
    let state: InputDeckState
    @Environment(\.colorScheme) private var scheme
    private typealias Metrics = InputDeckView.Constants

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                shape.fill(surface)
                shape.strokeBorder(edge, lineWidth: state.trackpad == .agent ? 1.5 : 0.75)
                if let agent = state.agentPointer, state.trackpad == .agent {
                    dot(at: agent, in: size, color: DeckPalette.agent, diameter: 8)
                }
                trail(in: size)
                if let finger = state.finger {
                    fingertip(at: finger, in: size)
                }
            }
        }
        .opacity(state.trackpad == .paused ? 0.6 : 1)
    }

    private var surface: some ShapeStyle {
        let top = scheme == .dark ? Color(white: 0.20) : Color(white: 0.96)
        let bottom = scheme == .dark ? Color(white: 0.14) : Color(white: 0.88)
        let amber = state.trackpad == .agent ? 0.3 : 0
        return LinearGradient(
            colors: [top.mix(with: DeckPalette.agent, by: amber), bottom.mix(with: DeckPalette.agent, by: amber)],
            startPoint: .top, endPoint: .bottom,
        )
    }

    private var edge: Color {
        state.trackpad == .agent ? DeckPalette.agent.opacity(0.9) : Color.primary.opacity(scheme == .dark ? 0.3 : 0.18)
    }

    private func trail(in size: CGSize) -> some View {
        ForEach(Array(state.fingerTrail.enumerated()), id: \.offset) { index, point in
            let fade = 1 - Double(index + 1) / Double(state.fingerTrail.count + 1)
            dot(at: point, in: size, color: DeckPalette.human.opacity(0.45 * fade), diameter: 4 + 6 * fade)
        }
    }

    private func fingertip(at point: CGPoint, in size: CGSize) -> some View {
        let diameter = Metrics.fingerDiameter
        let press = state.fingerPress
        return ZStack {
            if press > 0 {
                Circle()
                    .stroke(DeckPalette.human.opacity(1 - press), lineWidth: 1.5)
                    .frame(width: diameter + 16 * press, height: diameter + 16 * press)
            }
            Circle()
                .fill(DeckPalette.human.opacity(0.85))
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .frame(width: diameter * (1 - 0.15 * press), height: diameter * (1 - 0.15 * press))
                .shadow(color: DeckPalette.human.opacity(0.5), radius: 4)
        }
        .position(x: point.x * size.width, y: point.y * size.height)
    }

    private func dot(at point: CGPoint, in size: CGSize, color: Color, diameter: CGFloat) -> some View {
        Circle().fill(color)
            .frame(width: diameter, height: diameter)
            .position(x: point.x * size.width, y: point.y * size.height)
    }
}
