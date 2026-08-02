import Foundation

/// What happened, and how we know.
///
/// This is the feature, not the logging. Every action returns one of these, and the verdict is
/// *computed* from observation rather than inferred from a return code — because return codes
/// lie: `AXSetValue` reports `.success` on WebKit content while changing nothing at all.
nonisolated struct Evidence: Codable, Sendable {
    /// Which rung of the ghost ladder actually delivered the action.
    enum Rung: String, Codable, Sendable {
        case displayWake
        case accessibility
        case postedEvent
        case appAutomation
        case hardwareInput
    }

    enum Verdict: String, Codable, Sendable {
        /// Something observably changed: a read-back matched, or pixels in the target moved.
        case confirmed
        /// The call claimed success and nothing changed. The most important case in the system.
        case noEffect
        /// No readable value and no pixel access. Says so rather than claiming success.
        case unverifiable
    }

    let action: String
    let target: String
    let rung: Rung
    let verdict: Verdict

    /// Value read back from the target after acting, when it exposes one.
    let readback: String?
    /// Fraction of pixels that changed inside the target's rectangle, when captured.
    let pixelDelta: Double?
    /// Which element the app reported as focused, before and after.
    let focusBefore: String?
    let focusAfter: String?

    /// Proof the cursor was not stolen. Sampled around every action, never assumed.
    let cursorMoved: Bool
    let frontmostChanged: Bool

    /// Rungs that were tried and fell through, with why. Makes a fallback to hardware input
    /// visible instead of silent.
    let attempts: [Attempt]

    struct Attempt: Codable, Sendable {
        let rung: Rung
        let outcome: String
    }

    var succeeded: Bool { verdict == .confirmed }

    /// One line for the activity log and the CLI.
    var summary: String {
        let marker = switch verdict {
        case .confirmed: "ok"
        case .noEffect: "NO EFFECT"
        case .unverifiable: "unverified"
        }
        return "\(action) → \(target) [\(rung.rawValue)] \(marker)"
    }
}

/// Decides a verdict from what was observed. Kept separate from the actuation path so the
/// rule "success is not evidence" is enforced in exactly one place.
nonisolated enum Verifier {
    private enum Constants {
        /// Below this, a pixel change is antialiasing, a caret blink, or a hover highlight.
        static let significantPixelDelta = 0.01
    }

    static func verdict(
        expected: String?,
        readback: String?,
        pixelDelta: Double?
    ) -> Evidence.Verdict {
        if let expected, let readback {
            return readback.contains(expected) ? .confirmed : .noEffect
        }
        if let pixelDelta {
            return pixelDelta > Constants.significantPixelDelta ? .confirmed : .noEffect
        }
        return .unverifiable
    }
}
