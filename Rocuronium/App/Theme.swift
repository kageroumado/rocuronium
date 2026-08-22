import SwiftUI

/// Rocuronium's design tokens — the suite's shared language (Adrafinil, Phosphene): Liquid
/// Glass surfaces, one radius/spacing scale, rounded hero typography. The identity color is
/// the jellyfish's bioluminescent violet: violet is "an agent has hands", cool grey is
/// standing by, amber is the ⌥⎋ halt (the same hue the overlay's needs-human state wears).
enum Theme {
    // MARK: - Palette

    /// The agent violet — "driving". Matches the overlay's effects and the mascot's glow.
    static let agent = JellyPalette.agent
    /// Standing by.
    static let idle = Color.secondary
    /// The ⌥⎋ halt — the human took the machine back.
    static let halted = Color.orange
    /// A grant that must exist before anything works.
    static let blocked = Color.red
    static let ok = Color.green

    // MARK: - Geometry

    enum Radius {
        /// Outer cards / panels.
        static let card: CGFloat = 14
        /// Rows and grouped controls inside a card.
        static let inner: CGFloat = 10
        /// Small controls, chips, hover fills.
        static let control: CGFloat = 8
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Fixed width of the menu-bar popover (matches the platform norm and the suite).
    static let popoverWidth: CGFloat = 320

    // MARK: - Shapes

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    }
    static var innerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
    }
    static var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
    }
}

extension Font {
    /// Rounded title for hero lines and headers — friendlier than the default for a utility app.
    static let heroTitle = Font.system(.headline, design: .rounded).weight(.semibold)
    /// Rounded medium-weight body for verb/target names.
    static let toolName = Font.system(.body, design: .rounded).weight(.medium)
}

// MARK: - Glass surfaces

extension View {
    /// Wraps the view in a Liquid Glass card with the standard radius. Pass `tint` to give
    /// the glass a cast (violet for the driving hero, amber for the halt).
    func glassCard(cornerRadius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
        return glassEffect(glass, in: shape)
    }
}

// MARK: - Status dot

/// A small filled state indicator. `glow` adds a soft halo for the active state.
struct StatusDot: View {
    let color: Color
    var glow: Bool = false
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: glow ? color.opacity(0.7) : .clear, radius: glow ? 4 : 0)
    }
}

// MARK: - State chip

/// A compact pill for presence, hold, and verdict badges.
struct StateChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}
