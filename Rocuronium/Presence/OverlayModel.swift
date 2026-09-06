import CoreGraphics
import Foundation

/// The state the overlay renders: what the agent is doing, said in evidence language.
///
/// One model drives every visible surface — tint, bezel, jellyfish, effects — so they can
/// never disagree about whether a session is on or what the last verdict was.
@MainActor
@Observable
final class OverlayModel {
    /// The jellyfish's state channel. `hidden` doubles as "no session": the window is out.
    /// `nonisolated`: a plain value whose synthesized Equatable must stay callable from the
    /// animation completion handlers that check it.
    nonisolated enum Phase {
        case hidden
        /// Session on, nothing in flight — dim drift.
        case idle
        /// Resolving a target or waiting on a walk — cyan glow, hover.
        case thinking
        /// Input is being delivered — bell pulse, tentacles streaming.
        case acting
        /// A refusal that names a flag only a human should pass — amber, tentacles curled.
        case needsHuman
    }

    var phase: Phase = .hidden
    /// One line under the mark, in evidence-verdict language.
    var narration = ""
    /// When the visible session began; drives the bezel's elapsed clock.
    var sessionStart: Date?
    /// The bezel rests translucent and wakes to full opacity for a beat after each action.
    var lastEngagement = Date.distantPast

    /// The pre-click wind-up ring: fills over `duration` at the aim point, then the click.
    struct ChargeRing {
        let point: CGPoint
        let start: Date
        let duration: TimeInterval
    }

    /// The post-click ripple: expands and fades over ~0.55 s.
    struct Ripple: Identifiable {
        let id = UUID()
        let point: CGPoint
        let start: Date
    }

    var chargeRing: ChargeRing?
    var ripples: [Ripple] = []

    /// A disruptive action is waiting on the human at the machine. Rather than refuse with
    /// "pass --confirm" — a decision the caller has to guess — the overlay asks, and the
    /// socket call blocks on the answer. `nil` when nothing is pending.
    struct ConsentRequest {
        /// One line naming what will happen: "Bring Discord to the front and click 'Inbox'".
        let prompt: String
        /// The app the action targets, for the second line ("Discord · click").
        let detail: String
    }

    var consent: ConsentRequest?
    /// While a confirm key is held, which answer it is and how far toward the 1 s threshold —
    /// drives the fill on the Yes/No affordance so a hold reads as deliberate, and a tap does
    /// nothing. `true` = yes, `false` = no.
    var consentHold: (answer: Bool, fraction: Double)?
    /// The bezel window's frame, in the effects window's top-left coordinates — home for
    /// the jellyfish's perch, kept current as the human drags the bezel around.
    var bezelFrame: CGRect?

    /// Show the overlay for every acting verb, not only cursor-taking ones. The ghost tentacles
    /// are invisible by design, so this is opt-in — but "I want to watch it work" is a
    /// legitimate ask, and it persists across launches.
    var showForAllActions: Bool {
        didSet { UserDefaults.standard.set(showForAllActions, forKey: Self.showForAllActionsKey) }
    }

    private static let showForAllActionsKey = "ShowOverlayForAllActions"

    init() {
        showForAllActions = UserDefaults.standard.bool(forKey: Self.showForAllActionsKey)
    }

    func addRipple(at point: CGPoint) {
        // Prune here rather than during drawing: the draw pass runs per frame and must not
        // mutate observable state.
        let cutoff = Date(timeIntervalSinceNow: -1)
        ripples.removeAll { $0.start < cutoff }
        ripples.append(Ripple(point: point, start: Date()))
    }
}
