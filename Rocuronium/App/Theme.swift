import Propofol
import SwiftUI

/// Rocuronium's palette on top of Propofol's shared tokens. The identity color is the jellyfish's
/// bioluminescent violet: violet is "an agent has hands", cool grey is standing by, amber is the
/// ⌥⎋ halt (the same hue the overlay's needs-human state wears).
extension Theme {
    /// The agent violet — "driving". Matches the overlay's effects and the mascot's glow.
    static let agent = JellyPalette.agent
    /// Standing by.
    static let idle = Color.secondary
    /// The ⌥⎋ halt — the human took the machine back.
    static let halted = Color.orange
    /// A grant that must exist before anything works.
    static let blocked = Color.red
    static let ok = Color.green
}
