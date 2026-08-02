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
    /// Whether the app we were driving is the one that came forward. Distinguishes us
    /// activating a target from the user (or an unrelated launch) switching apps.
    let frontmostBecameTarget: Bool

    /// Rungs that were tried and fell through, with why. Makes a fallback to hardware input
    /// visible instead of silent.
    let attempts: [Attempt]

    struct Attempt: Codable, Sendable {
        let rung: Rung
        let outcome: String
    }

    var succeeded: Bool { verdict == .confirmed }

    /// Whether *we* moved the cursor, as opposed to the cursor having moved.
    ///
    /// The raw measurement cannot tell the difference: a human moving the mouse while an action
    /// runs registers identically to us stealing it. But only `hardwareInput` is capable of
    /// moving the pointer — every other rung delivers events to a process without touching the
    /// system cursor — so movement under any other rung was the user's own hand. Reporting it
    /// as ours trains people to ignore the warning, which is worse than not having one.
    var cursorMovedByUs: Bool { cursorMoved && rung == .hardwareInput }

    /// Movement that happened during the action but cannot have been ours. Evidence a human is
    /// actively at the machine, not a warning.
    var cursorMovedByUser: Bool { cursorMoved && rung != .hardwareInput }

    /// Focus we took. Unlike the cursor, an action genuinely can raise its target — so the
    /// test is whether the *target* came forward, not merely that something did.
    var focusTakenByUs: Bool { frontmostChanged && frontmostBecameTarget }

    /// Folds a visual measurement into an existing verdict.
    ///
    /// Only ever *upgrades* `unverifiable`: a read-back that already confirmed or refuted the
    /// action is stronger evidence than pixels, and must not be overridden by an unrelated
    /// animation somewhere in the same rectangle.
    func addingVisualEvidence(delta: Double?) -> Evidence {
        guard verdict == .unverifiable, let delta else { return self }
        return Evidence(
            action: action, target: target, rung: rung,
            verdict: Verifier.verdict(expected: nil, readback: nil, pixelDelta: delta),
            readback: readback, pixelDelta: delta,
            focusBefore: focusBefore, focusAfter: focusAfter,
            cursorMoved: cursorMoved, frontmostChanged: frontmostChanged,
            frontmostBecameTarget: frontmostBecameTarget,
            attempts: attempts,
        )
    }

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
