import CoreGraphics
import Foundation

/// The state the presence panel and the effects layer render.
///
/// One model drives every visible surface, so the panel, the screen border and the jellyfish
/// can never disagree about what the agent is doing. Every transition takes the instant it
/// happens (`at:`), and everything the surfaces show — mode, lines, whether anything is up at
/// all — is a pure function of the model and a clock (`presentation(at:)`). The live overlay
/// passes the wall clock; the showcase passes scene time and replays the same transitions.
@MainActor
@Observable
final class OverlayModel {
    /// The jellyfish's choreography channel.
    /// `nonisolated`: a plain value read from `Canvas` renderers.
    nonisolated enum Phase {
        case hidden
        /// Nothing in flight — dim drift.
        case idle
        /// Resolving a target, waiting, or between steps — cyan glow, hover.
        case thinking
        /// Input is being delivered — bell pulse, tentacles streaming.
        case acting
        /// The human is being asked something — amber, tentacles curled.
        case needsHuman
    }

    /// The panel's answer to "may I keep using my Mac?", the single most important signal.
    nonisolated enum Mode: Equatable, Sendable {
        /// Only ghost deliveries in flight: the human keeps working.
        case background
        /// A hardware action is armed or running: the human's mouse or keyboard is in use.
        case handsOff
        /// The agent declared it is waiting on something (`busy wait`).
        case waiting
        /// A consent prompt is up.
        case needsYou
        /// A hold is active and nothing has happened for a few seconds.
        case thinking
        /// The hold ended; the summary shows briefly before the panel fades.
        case done
    }

    nonisolated enum Constants {
        /// A hold with nothing in flight reads as Thinking after this long.
        static let thinkingAfter: TimeInterval = 4
        /// A hold this quiet warns that the agent may have stopped.
        static let quietWarningAfter: TimeInterval = 60
        /// A hold this quiet fades by itself, so a crashed agent never strands the panel.
        static let holdSafety: TimeInterval = 90
        /// Without a hold, the panel outlives the last result by this — enough to read line 3.
        static let resultLinger: TimeInterval = 2.5
        /// How long line 3 keeps a result before it clears.
        static let resultShown: TimeInterval = 4
        /// How long the `busy off` summary stays before the fade.
        static let doneShown: TimeInterval = 2
        /// The panel's fade-out.
        static let fadeOut: TimeInterval = 0.6
        /// A ripple's life; the effects layer stays up until the last one finishes.
        static let rippleLife: TimeInterval = 0.55
        /// The hands-off panel pulse on entry.
        static let pulse: TimeInterval = 0.6
    }

    // MARK: - Session

    /// When the visible session began; drives the elapsed clock. `nil` = nothing is up.
    var sessionStart: Date?
    /// Between `beginHold` and `endHold`: the agent declared a bracket of work.
    var holdActive = false
    /// Line 1: what the agent is trying to do, in its own words.
    var goal = ""
    var steps: [String] = []
    /// The current step, 0-based; `steps.count` once every step is done.
    var stepIndex: Int?
    /// The app the last command aimed at — line 1 without a goal says `Working in <app>`.
    var lastApp: String?
    var actionCount = 0
    /// Last time anything happened: a command began or finished, a step moved, a wait began.
    var lastActivity = Date.distantPast
    /// The step list under the panel is open.
    var panelExpanded = false

    // MARK: - The command in flight

    var action: PanelAction?
    var actionStart: Date?
    /// The command that finished last — line 2 says it in the past tense until the next one.
    var lastAction: PanelAction?
    /// The element the last reply said it resolved to, for line 2's role noun.
    var resolved: PanelText.Resolved?
    var lastFinish: Date?
    var result: PanelResult?
    var resultAt: Date?

    /// A declared wait: what for, since when, and until when if the agent said.
    struct Wait: Equatable {
        var what: String
        var start: Date
        var deadline: Date?
    }

    var wait: Wait?
    /// The `busy off` summary and when it began showing.
    var done: (text: String, at: Date)?

    // MARK: - Consent

    /// A disruptive action is waiting on the human. `nil` when nothing is pending.
    struct ConsentRequest {
        /// One line naming what will happen: "Bring Discord to the front and click 'Inbox'".
        let prompt: String
        /// The app the action targets, for the second line ("Discord · click").
        let detail: String
    }

    var consent: ConsentRequest?
    /// While a confirm key is held, which answer it is and how far toward the threshold.
    var consentHold: (answer: ConsentAnswer, fraction: Double)?

    // MARK: - Effects

    /// The pre-click wind-up ring: fills over `duration` at the aim point, then the click.
    struct ChargeRing {
        let point: CGPoint
        let start: Date
        let duration: TimeInterval
    }

    /// The post-click ripple.
    struct Ripple: Identifiable {
        let id = UUID()
        let point: CGPoint
        let start: Date
    }

    var chargeRing: ChargeRing?
    var ripples: [Ripple] = []
    /// When the human pressed ⌃⌥⇧⎋ or the command finished, the hands-off layer lets go.
    var handsOffStart: Date?

    /// Show the overlay for every acting verb, not only cursor-taking ones. Persisted.
    var showForAllActions: Bool {
        didSet {
            guard persistsPreference else { return }
            UserDefaults.standard.set(showForAllActions, forKey: Self.showForAllActionsKey)
        }
    }

    private static let showForAllActionsKey = "ShowOverlayForAllActions"
    private let persistsPreference: Bool

    init() {
        showForAllActions = UserDefaults.standard.bool(forKey: Self.showForAllActionsKey)
        persistsPreference = true
    }

    /// A model that never reads or writes the stored preference — the showcase's.
    init(showForAllActions: Bool) {
        self.showForAllActions = showForAllActions
        persistsPreference = false
    }

    // MARK: - Transitions

    /// Opens a session if none is up (or the last one is finishing), keeping the hold's state.
    private func ensureSession(at now: Date) {
        if sessionStart == nil || done != nil {
            sessionStart = now
            done = nil
            actionCount = 0
            if !holdActive {
                goal = ""
                steps = []
                stepIndex = nil
            }
        }
    }

    /// A command is starting.
    func begin(_ action: PanelAction, at now: Date) {
        ensureSession(at: now)
        self.action = action
        actionStart = now
        resolved = nil
        result = nil
        resultAt = nil
        // Any acting command ends a declared wait: the thing waited for has evidently arrived.
        wait = nil
        if let app = action.app, !app.isEmpty { lastApp = app }
        handsOffStart = action.cursorTaking ? now : nil
        lastActivity = now
    }

    /// The command's reply is in.
    func finish(reply: [String: Any], at now: Date) {
        guard sessionStart != nil else { return }
        resolved = PanelText.Resolved(reply: reply)
        result = PanelText.result(for: reply, action: action)
        resultAt = result == nil ? nil : now
        lastAction = action
        action = nil
        actionStart = nil
        chargeRing = nil
        handsOffStart = nil
        actionCount += 1
        lastFinish = now
        lastActivity = now
    }

    /// The agent declares a bracket of work, optionally with the steps it will take. A new goal
    /// with steps replaces the list; a new goal without steps moves the pointer to the next step.
    func beginHold(goal newGoal: String, steps newSteps: [String], at now: Date) {
        ensureSession(at: now)
        let trimmed = PanelText.truncate(newGoal, limit: PanelText.Constants.goalLimit)
        if !newSteps.isEmpty {
            steps = newSteps
            stepIndex = 0
        } else if holdActive, !trimmed.isEmpty, trimmed != goal, let index = stepIndex {
            stepIndex = min(index + 1, steps.count)
        }
        if !trimmed.isEmpty { goal = trimmed }
        holdActive = true
        lastActivity = now
    }

    /// Moves the step pointer: `nil` = the next step, otherwise 1-based.
    func advanceStep(to step: Int?, at now: Date) {
        guard !steps.isEmpty else { return }
        if let step {
            stepIndex = max(0, min(step - 1, steps.count))
        } else {
            stepIndex = min((stepIndex ?? -1) + 1, steps.count)
        }
        lastActivity = now
    }

    func beginWait(what: String, seconds: TimeInterval?, at now: Date) {
        ensureSession(at: now)
        wait = Wait(what: what, start: now, deadline: seconds.map { now.addingTimeInterval($0) })
        lastActivity = now
    }

    /// The hold ends: the summary shows for `doneShown`, then everything fades.
    func endHold(result text: String?, at now: Date) {
        guard holdActive || sessionStart != nil else { return }
        holdActive = false
        wait = nil
        if !steps.isEmpty { stepIndex = steps.count }
        guard let start = sessionStart else { return }
        let summary = text.flatMap { $0.isEmpty ? nil : PanelText.truncate($0, limit: PanelText.Constants.goalLimit) }
        done = (summary ?? PanelText.doneLine(actions: actionCount, elapsed: now.timeIntervalSince(start)), now)
        lastActivity = now
    }

    func presentConsent(prompt: String, detail: String, at now: Date) {
        ensureSession(at: now)
        consent = ConsentRequest(prompt: prompt, detail: detail)
        consentHold = nil
        lastActivity = now
    }

    func resolveConsent(_ answer: ConsentAnswer, at now: Date) {
        consent = nil
        consentHold = nil
        let message = switch answer {
        case .approve: "Approved"
        case .approveForAWhile: "Approved for \(StandingApproval.minutes) minutes"
        case .decline: "Declined"
        }
        result = PanelResult(kind: .refused, message: message)
        resultAt = now
        lastActivity = now
    }

    func charge(at point: CGPoint, duration: TimeInterval, now: Date) {
        chargeRing = ChargeRing(point: point, start: now, duration: duration)
        if action?.cursorTaking == true, handsOffStart == nil { handsOffStart = now }
    }

    func addRipple(at point: CGPoint, now: Date) {
        chargeRing = nil
        // Prune here rather than during drawing: the draw pass must not mutate observable state.
        ripples.removeAll { now.timeIntervalSince($0.start) > 1 }
        ripples.append(Ripple(point: point, start: now))
    }

    /// Clears everything the session showed; the stored preference and the expansion stay.
    func reset() {
        sessionStart = nil
        holdActive = false
        goal = ""
        steps = []
        stepIndex = nil
        lastApp = nil
        actionCount = 0
        action = nil
        actionStart = nil
        lastAction = nil
        resolved = nil
        lastFinish = nil
        result = nil
        resultAt = nil
        wait = nil
        done = nil
        consent = nil
        consentHold = nil
        chargeRing = nil
        ripples = []
        handsOffStart = nil
    }

    // MARK: - What is shown

    /// Everything the surfaces need at one instant.
    struct Presentation: Equatable {
        var isUp: Bool
        /// 1 while up; ramps to 0 over the fade.
        var opacity: Double
        var mode: Mode
        /// The full-screen layer: hands-off border and escort, charge ring, ripples.
        var effectsVisible: Bool
        /// Seconds of silence inside a hold, once it is long enough to warn about.
        var quietFor: TimeInterval?

        static let down = Presentation(isUp: false, opacity: 0, mode: .background, effectsVisible: false, quietFor: nil)
    }

    func presentation(at now: Date) -> Presentation {
        guard sessionStart != nil else { return .down }
        let effects = effectsVisible(at: now)
        func up(_ mode: Mode, quiet: TimeInterval? = nil) -> Presentation {
            Presentation(isUp: true, opacity: 1, mode: mode, effectsVisible: effects, quietFor: quiet)
        }
        /// Up until `end`, then fading over `fadeOut`, then down.
        func until(_ end: Date, _ mode: Mode, quiet: TimeInterval? = nil) -> Presentation {
            let past = now.timeIntervalSince(end)
            if past <= 0 { return up(mode, quiet: quiet) }
            let opacity = 1 - past / Constants.fadeOut
            guard opacity > 0 else { return .down }
            return Presentation(isUp: true, opacity: opacity, mode: mode, effectsVisible: effects, quietFor: quiet)
        }

        if consent != nil { return up(.needsYou) }
        if let action { return up(action.cursorTaking ? .handsOff : .background) }
        if let done { return until(done.at.addingTimeInterval(Constants.doneShown), .done) }
        if let wait {
            return until((wait.deadline ?? wait.start).addingTimeInterval(Constants.holdSafety), .waiting)
        }
        let idle = now.timeIntervalSince(lastActivity)
        if holdActive {
            let mode: Mode = idle > Constants.thinkingAfter ? .thinking : .background
            let quiet = idle >= Constants.quietWarningAfter ? idle : nil
            return until(lastActivity.addingTimeInterval(Constants.holdSafety), mode, quiet: quiet)
        }
        return until((lastFinish ?? lastActivity).addingTimeInterval(Constants.resultLinger), .background)
    }

    /// The full-screen layer is up only while it has something to show: a hands-off action,
    /// a charging ring, or a ripple still spreading. Never while idle.
    func effectsVisible(at now: Date) -> Bool {
        if action?.cursorTaking == true { return true }
        if chargeRing != nil { return true }
        return ripples.contains { now.timeIntervalSince($0.start) < Constants.rippleLife }
    }

    /// The jellyfish phase for a mode.
    func phase(at now: Date) -> Phase {
        let presentation = presentation(at: now)
        guard presentation.isUp else { return .hidden }
        return switch presentation.mode {
        case .handsOff: .acting
        case .needsYou: .needsHuman
        case .background: action == nil ? .idle : .thinking
        case .waiting, .thinking: .thinking
        case .done: .idle
        }
    }

    /// Line 3's result, while it is still fresh.
    func freshResult(at now: Date) -> PanelResult? {
        guard let result, let resultAt, now.timeIntervalSince(resultAt) < Constants.resultShown else { return nil }
        return result
    }
}
