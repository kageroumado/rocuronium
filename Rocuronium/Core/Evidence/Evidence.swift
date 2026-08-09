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

    /// Where to go when no rung can reach the target. Rung 3 is a signpost, not an adapter:
    /// web page content needs the browser's own protocol, and the calling agent — which has
    /// the task context and the launch flags — is the one who can use it. Set only when the
    /// ladder was exhausted on a target it recognizes as unreachable.
    let referral: Referral?

    struct Attempt: Codable, Sendable {
        let rung: Rung
        let outcome: String
    }

    struct Referral: Codable, Sendable {
        /// The protocol that can reach this target: "refrax-ctl", "cdp", "safari-js", …
        let channel: String
        /// Why the ghost rungs cannot.
        let reason: String
        /// The concrete next move, written for the agent on the other end of the socket.
        let advice: String
    }

    var succeeded: Bool { verdict == .confirmed }

    /// Whether *we* moved the cursor, as opposed to the cursor having moved.
    ///
    /// The raw measurement cannot tell the difference: a human moving the mouse while an action
    /// runs registers identically to us stealing it. But only `hardwareInput` is capable of
    /// moving the pointer — every other rung delivers events to a process without touching the
    /// system cursor — so movement under any other rung was the user's own hand. Reporting it
    /// as ours trains people to ignore the warning, which is worse than not having one.
    ///
    /// Conversely, the hardware rung **always** took the cursor, even when the before/after
    /// measurement reads zero: the rung moves the pointer to aim, clicks, and restores it as
    /// a courtesy. The restore must never conceal the takeover.
    var cursorMovedByUs: Bool { rung == .hardwareInput }

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
        guard verdict != .confirmed, let delta else { return self }
        // `.noEffect` participates too, and it must: the ladder's fall-through paths assert
        // no-effect while holding a capture, which is exactly where the pixels are the only
        // signal left. The previous guard admitted only `.unverifiable`, so those call sites
        // captured a baseline, diffed it, and discarded the answer — the fix recorded as
        // item 11 in the review was inert from the day it was written.
        //
        // A well-evidenced `.noEffect` is only ever overturned by a *strong* signal, never
        // softened to `.unverifiable` by a caret blink: read-back that refuted the action is
        // better evidence than a mid-band flicker in the same rectangle.
        let visual = Verifier.verdict(expected: nil, readback: nil, pixelDelta: delta)
        let resolved: Verdict = if verdict == .noEffect {
            visual == .confirmed ? .confirmed : .noEffect
        } else {
            visual
        }
        return Evidence(
            action: action, target: target, rung: rung,
            verdict: resolved,
            readback: readback, pixelDelta: delta,
            focusBefore: focusBefore, focusAfter: focusAfter,
            cursorMoved: cursorMoved, frontmostChanged: frontmostChanged,
            frontmostBecameTarget: frontmostBecameTarget,
            attempts: attempts, referral: referral,
        )
    }

    /// Selection as read-back: a selection that changed across a press is direct evidence the
    /// command ran, for the commands that act on selection (Select All, Find). Only upgrades,
    /// and only on a non-empty selection — an emptied one is indistinguishable from a focus
    /// change or a click elsewhere.
    func addingSelectionEvidence(before: String?, after: String?) -> Evidence {
        // `before` must be a real reading, not nil. `selectedText` returns nil both for "no
        // selection" and for "the read failed" — nothing focused, a non-text element, or a 2 s
        // AX timeout on a busy app. Accepting nil as a baseline would confirm a press that did
        // nothing whenever the before-read raced a beachball and the after-read caught the
        // selection that was there all along.
        guard verdict == .unverifiable, let before, let after,
              !after.isEmpty, after != before else { return self }
        return Evidence(
            action: action, target: target, rung: rung,
            verdict: .confirmed,
            readback: after, pixelDelta: pixelDelta,
            focusBefore: focusBefore, focusAfter: focusAfter,
            cursorMoved: cursorMoved, frontmostChanged: frontmostChanged,
            frontmostBecameTarget: frontmostBecameTarget,
            attempts: attempts, referral: referral,
        )
    }

    /// The target process exited after the action — the read-back for actions that close
    /// their own app. Every other channel needs a live process, so a fully successful Quit
    /// or restart-to-update otherwise reports `unverifiable`, and an unverified-looking
    /// "error" on a press that worked invites the one retry a just-quit app must not get.
    func confirmedByProcessExit() -> Evidence {
        Evidence(
            action: action, target: target, rung: rung,
            verdict: .confirmed,
            readback: "the target process exited after the press",
            pixelDelta: pixelDelta,
            focusBefore: focusBefore, focusAfter: focusAfter,
            cursorMoved: cursorMoved, frontmostChanged: frontmostChanged,
            frontmostBecameTarget: frontmostBecameTarget,
            attempts: attempts + [.init(
                rung: rung,
                outcome: "the target process exited — an action that closes its app cannot read back; the exit is the evidence",
            )],
            referral: referral,
        )
    }

    /// Like `addingVisualEvidence`, but pixels may only **confirm**, never refute.
    ///
    /// In an *element's* rectangle, "nothing changed" is real evidence a click failed. In a
    /// whole window it is not: copy and its siblings succeed while changing no pixels at
    /// all, and a click's consequence can land in a popover outside the captured window —
    /// so a quiet window never downgrades. It can, however, *overturn* a noEffect: the
    /// element-rect diff refutes from too small a rectangle when the consequence lands
    /// elsewhere in the window (measured on Calculator — the pressed button read quiet
    /// while the display changed).
    func addingConfirmingVisualEvidence(delta: Double?) -> Evidence {
        guard verdict != .confirmed, let delta else { return self }
        // The measurement is recorded even when it decides nothing: a sub-threshold delta
        // that vanished without trace once read as a mystery, not as a number to reason about.
        let visual = Verifier.verdict(expected: nil, readback: nil, pixelDelta: delta)
        // A mid-band delta on a window that was provably still is conflicting evidence
        // against an element-rect refutation — the consequence of a real press can be small
        // at window scale (Calculator's display changing is 0.27% of the window). Refuting
        // on the element while the window moved would tell the caller "did not happen"
        // about an action that observably did something; unverifiable is the honest middle.
        let resolved: Verdict = switch visual {
        case .confirmed: .confirmed
        case .unverifiable: verdict == .noEffect ? .unverifiable : verdict
        case .noEffect: verdict
        }
        return Evidence(
            action: action, target: target, rung: rung,
            verdict: resolved,
            readback: readback, pixelDelta: delta,
            focusBefore: focusBefore, focusAfter: focusAfter,
            cursorMoved: cursorMoved, frontmostChanged: frontmostChanged,
            frontmostBecameTarget: frontmostBecameTarget,
            attempts: attempts, referral: referral,
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
        /// A blinking text caret in a small field is the calibration case: roughly 2×16 pt in a
        /// 100×20 pt field is about 1.6% of it, so a flat 1% threshold would read a caret blink
        /// as a confirmed click.
        static let significantPixelDelta = 0.02
        /// Any change at all, however small, still rules out "nothing happened".
        static let noChangeAtAll = 0.0005
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
            // Three bands, because a weak signal is not evidence of absence. Claiming
            // `.noEffect` on a faint delta makes an agent retry — or escalate to hardware
            // input — for an action that already worked.
            if pixelDelta > Constants.significantPixelDelta { return .confirmed }
            return pixelDelta <= Constants.noChangeAtAll ? .noEffect : .unverifiable
        }
        return .unverifiable
    }
}
