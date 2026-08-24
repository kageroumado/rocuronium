import Foundation
import Observation

/// Which creature the mascot is drawn as. The state channel is the same in every style —
/// same four phases, same halo, same blink, same worried brows — so switching one is a
/// change of skin, never a change of what the overlay is telling you.
///
/// The four newer ones were each picked for carrying a **different light mechanism** — a
/// glyph, a bloom, a curtain and a run of beads stay apart at 46 pt, where four palettes
/// would not. Classic predates that rule and keeps its place regardless: it is the creature
/// people already recognise.
enum JellyStyle: String, CaseIterable, Identifiable, Sendable {
    /// Remi — the smooth jellyfish the app shipped with: soft bell, five lagging tentacles.
    case classic
    /// The 14×18 sprite, four frames, with the forehead glyph the status light radiates from.
    case bitjelly
    /// Koko — a round sheet with a hem that never holds still. Lights from inside.
    case ghost
    /// A clear bell with a curtain of aurora standing up inside it.
    case aurora
    /// After the flower hat jelly: beads of light run from the hem down the legs.
    case sparkler

    var id: String { rawValue }

    /// The name shown in the picker. Deliberately not the raw value: `classic` and `ghost`
    /// stay as they are in `UserDefaults`, so naming a creature never orphans the preference
    /// of anyone already using it.
    var title: String {
        switch self {
        case .classic: "Remi"
        case .bitjelly: "Bitjelly"
        case .ghost: "Koko"
        case .aurora: "Aurora"
        case .sparkler: "Sparkler"
        }
    }

    var blurb: String {
        switch self {
        case .classic: "Smooth bell, lagging tentacles"
        case .bitjelly: "14×18 pixels, four frames"
        case .ghost: "A sheet that lights from inside"
        case .aurora: "Weather in a bell"
        case .sparkler: "Lights that run down the legs"
        }
    }

    /// Where the creature's own origin sits in the 64×84 design box, and how many box units
    /// one creature unit is worth. Classic and Bitjelly ignore both — each lays itself out
    /// directly in the 64×84 box.
    ///
    /// These are tuned so the *whole* creature lands inside the box, legs included. The
    /// canvas clips, so a value that only fits the bell silently amputates the tendrils.
    ///
    /// They are measured against the bell at its **tallest**, not at rest: every creature
    /// stretches on the contraction — Aurora by 15% — and an anchor derived from the resting
    /// height puts her crown outside the box on every acting pulse.
    var anchorY: Double {
        switch self {
        case .classic, .bitjelly: 0
        case .ghost: 39
        case .aurora: 31
        case .sparkler: 29
        }
    }

    var unit: Double {
        switch self {
        case .classic, .bitjelly: 1
        case .ghost: 3.3
        case .aurora: 2.6
        case .sparkler: 3.0
        }
    }

    /// The index every creature's `period` and `amp` table is keyed by. `hidden` shares
    /// idle's row: the window is out, but the beat has to keep a defined value.
    static func phaseIndex(_ phase: OverlayModel.Phase) -> Int {
        switch phase {
        case .thinking: 1
        case .acting: 2
        case .needsHuman: 3
        default: 0
        }
    }
}

/// The chosen style, shared by every surface that draws the mascot and remembered across
/// launches. A singleton because there is exactly one mascot: the popover hero, the demo
/// gallery, the bezel mark and the escort overlay must never disagree about which creature
/// the user picked.
@MainActor
@Observable
final class JellyStyleStore {
    static let shared = JellyStyleStore()

    private static let key = "JellyStyle"

    var style: JellyStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.key) }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        style = saved.flatMap(JellyStyle.init(rawValue:)) ?? .classic
    }
}
