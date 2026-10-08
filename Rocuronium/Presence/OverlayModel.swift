import CoreGraphics
import Foundation

/// The state the presence panel and the effects layer render.
///
/// One model drives every visible surface, so the panel, the screen border and the jellyfish
/// can never disagree about what the agent is doing. Every transition takes the instant it
/// happens (`at:`), and everything the surfaces show — mode, lines, whether anything is up at
/// all — is a pure function of the model and a clock (`presentation(at:)`). The live overlay
/// passes the wall clock; the showcase passes scene time and replays the same transitions.
///
/// A session ends only when the agent says so — `busy off`, an action sent with `--done`, the
/// end of a plan — or after `Constants.holdSafety` of silence. Between actions the agent is
/// thinking, and the panel says that rather than guessing it is finished.
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
        /// A consent prompt is up.
        case needsYou
        /// Nothing in flight and no end declared: the agent is reasoning about what comes next.
        case thinking
        /// The human's input stopped a hands-off action; held until the agent's next command.
        case stopped
        /// The agent declared the end; the outcome shows briefly before the panel fades.
        case done
        /// The session ended without a success: a plan aborted, or the agent went silent.
        case ended
    }

    nonisolated enum Constants {
        /// A session this quiet warns that the agent may have stopped.
        static let quietWarningAfter: TimeInterval = 60
        /// A session this quiet ends by itself, so a crashed agent never strands the panel.
        static let holdSafety: TimeInterval = 90
        /// How long a session that went quiet says so before it fades.
        static let endedShown: TimeInterval = 2
        /// How long the Done state stays before the fade.
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
    /// The `--why` of the latest action — line 1 when no goal was declared.
    var why: String?
    var steps: [String] = []
    /// The current step, 0-based; `steps.count` once every step is done.
    var stepIndex: Int?
    /// When the step pointer last moved: a step that moved after the last outcome names itself
    /// on line 2 instead of repeating that outcome.
    var stepMovedAt: Date?
    /// The app the last command aimed at — line 1 without a goal says `Working in <app>`.
    var lastApp: String?
    var actionCount = 0
    /// Last time the agent did anything: a command began or finished, a step moved, a wait began.
    var lastActivity = Date.distantPast
    /// The step list under the panel is open.
    var panelExpanded = false
    /// A plan is running: between its steps the agent is not thinking, the plan is.
    var planRunning = false

    // MARK: - The command in flight

    var action: PanelAction?
    var actionStart: Date?
    /// The element the last reply said it resolved to, for the outcome's role noun.
    var resolved: PanelText.Resolved?
    var lastFinish: Date?
    /// What the last action came to: line 2 until the next action begins.
    var outcome: PanelOutcome?

    /// A declared non-UI wait (`busy wait`): the panel releases the screen until the next
    /// action or step.
    struct Wait: Equatable {
        var what: String
        var start: Date
        var deadline: Date?
    }

    var wait: Wait?

    /// The human's input stopped an action, or a plan paused for them. Held until the agent's
    /// next command; `indefinite` also suspends the silence safety, because the agent is the
    /// one waiting.
    struct Stop: Equatable {
        var text: String
        var at: Date
        var indefinite = false
    }

    var stopped: Stop?

    /// The declared end: `text` is line 2 (nil keeps the last outcome), `success` picks Done
    /// over Ended.
    struct Finish: Equatable {
        var text: String?
        var success: Bool
        var at: Date
    }

    var done: Finish?

    // MARK: - Consent

    /// A disruptive action is waiting on the human. `nil` when nothing is pending.
    struct ConsentRequest: Equatable {
        /// What will happen, said once: "Bring Safari to the front and click “Sign In”".
        let prompt: String
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
    /// When the hands-off action began; the border fades in from here.
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

    /// Opens a session if none is up, the last one is finishing, or it already went quiet;
    /// a declared goal and steps carry over only while a hold is active.
    private func ensureSession(at now: Date) {
        let wentQuiet = now.timeIntervalSince(lastActivity) >= Constants.holdSafety && stopped?.indefinite != true
        if sessionStart == nil || done != nil || wentQuiet {
            sessionStart = now
            done = nil
            outcome = nil
            stopped = nil
            actionCount = 0
            planRunning = false
            if !holdActive || wentQuiet {
                holdActive = false
                goal = ""
                why = nil
                steps = []
                stepIndex = nil
            }
        }
    }

    /// A command is starting. It ends a declared wait and a held stop: the agent is back.
    func begin(_ action: PanelAction, at now: Date) {
        ensureSession(at: now)
        self.action = action
        actionStart = now
        resolved = nil
        wait = nil
        stopped = nil
        if let why = action.why, !why.isEmpty { self.why = PanelText.truncate(why, limit: PanelText.Constants.goalLimit) }
        if let app = action.app, !app.isEmpty { lastApp = app }
        handsOffStart = action.cursorTaking ? now : nil
        lastActivity = now
    }

    /// The command's reply is in. A stop the human caused holds the panel in Stopped; otherwise
    /// the outcome replaces the action phrase, and a `--done` action ends the session.
    func finish(reply: [String: Any], at now: Date) {
        guard sessionStart != nil else { return }
        let finished = action
        resolved = PanelText.Resolved(reply: reply)
        if let text = PanelText.stopped(for: reply, action: finished) {
            stopped = Stop(text: text, at: now)
            outcome = nil
        } else {
            outcome = PanelText.outcome(for: reply, action: finished)
        }
        action = nil
        actionStart = nil
        chargeRing = nil
        handsOffStart = nil
        actionCount += 1
        lastFinish = now
        lastActivity = now
        if finished?.endsSession == true, stopped == nil {
            declareEnd(text: nil, success: true, at: now)
        }
    }

    /// The agent declares a bracket of work, optionally with the steps it will take. A new goal
    /// with steps replaces the list; a new goal without steps moves the pointer to the next step.
    func beginHold(goal newGoal: String, steps newSteps: [String], at now: Date) {
        ensureSession(at: now)
        let trimmed = PanelText.truncate(newGoal, limit: PanelText.Constants.goalLimit)
        if !newSteps.isEmpty {
            steps = newSteps
            stepIndex = 0
            stepMovedAt = now
        } else if holdActive, !trimmed.isEmpty, trimmed != goal, let index = stepIndex {
            stepIndex = min(index + 1, steps.count)
            stepMovedAt = now
        }
        if !trimmed.isEmpty { goal = trimmed }
        holdActive = true
        wait = nil
        stopped = nil
        lastActivity = now
    }

    /// Moves the step pointer: `nil` = the next step, otherwise 1-based. A released screen
    /// comes back with the new step.
    func advanceStep(to step: Int?, at now: Date) {
        guard !steps.isEmpty else { return }
        if let step {
            stepIndex = max(0, min(step - 1, steps.count))
        } else {
            stepIndex = min((stepIndex ?? -1) + 1, steps.count)
        }
        stepMovedAt = now
        wait = nil
        stopped = nil
        lastActivity = now
    }

    /// The agent waits on something that is not the UI: the panel hides until it acts again.
    func beginWait(what: String, seconds: TimeInterval?, at now: Date) {
        ensureSession(at: now)
        wait = Wait(what: what, start: now, deadline: seconds.map { now.addingTimeInterval($0) })
        stopped = nil
        lastActivity = now
    }

    /// `busy off`: Done for `doneShown`, then everything fades.
    func endHold(result text: String?, at now: Date) {
        guard sessionStart != nil else {
            holdActive = false
            return
        }
        let summary = text.flatMap { $0.isEmpty ? nil : PanelText.truncate($0, limit: PanelText.Constants.goalLimit) }
        declareEnd(text: summary, success: true, at: now)
    }

    /// A plan takes the step list: its intents, under the declared goal or a goal naming it.
    func beginPlan(intents: [String], at now: Date) {
        ensureSession(at: now)
        if goal.isEmpty { goal = "Running a \(intents.count)-step plan" }
        steps = intents
        stepIndex = 0
        stepMovedAt = now
        planRunning = true
        wait = nil
        stopped = nil
        lastActivity = now
    }

    /// The plan is over: Done when every step ran, Ended with the reason when it stopped.
    func endPlan(abortReason: String?, at now: Date) {
        planRunning = false
        guard sessionStart != nil else { return }
        declareEnd(text: abortReason.map { PanelText.truncate("Plan stopped: \($0)", limit: PanelText.Constants.goalLimit) },
                   success: abortReason == nil, at: now)
    }

    /// A plan step's guard failed with `pause-for-human`: held in Stopped until resumed.
    func pausePlan(at now: Date) {
        ensureSession(at: now)
        stopped = Stop(text: "Paused — resume from the menu bar", at: now, indefinite: true)
        lastActivity = now
    }

    private func declareEnd(text: String?, success: Bool, at now: Date) {
        holdActive = false
        planRunning = false
        wait = nil
        stopped = nil
        if !steps.isEmpty, success { stepIndex = steps.count }
        done = Finish(text: text, success: success, at: now)
        lastActivity = now
    }

    func presentConsent(prompt: String, at now: Date) {
        ensureSession(at: now)
        consent = ConsentRequest(prompt: prompt)
        consentHold = nil
        stopped = nil
        lastActivity = now
    }

    /// The human answered. Approval lets the action continue; a decline is said by the
    /// action's own outcome when its reply comes back.
    func resolveConsent(_: ConsentAnswer, at now: Date) {
        consent = nil
        consentHold = nil
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
        why = nil
        steps = []
        stepIndex = nil
        stepMovedAt = nil
        lastApp = nil
        actionCount = 0
        planRunning = false
        action = nil
        actionStart = nil
        resolved = nil
        lastFinish = nil
        outcome = nil
        wait = nil
        stopped = nil
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
        /// Seconds of silence, once it is long enough to warn about.
        var quietFor: TimeInterval?
        /// Hidden while the agent waits on something that is not the UI; the session goes on
        /// and the panel comes back with the next action or step.
        var released = false

        static let down = Presentation(isUp: false, opacity: 0, mode: .thinking, effectsVisible: false, quietFor: nil)
        static let releasedScreen = Presentation(isUp: false, opacity: 0, mode: .thinking, effectsVisible: false, quietFor: nil, released: true)
    }

    func presentation(at now: Date) -> Presentation {
        guard sessionStart != nil else { return .down }
        let effects = effectsVisible(at: now)
        func up(_ mode: Mode, quiet: TimeInterval? = nil) -> Presentation {
            Presentation(isUp: true, opacity: 1, mode: mode, effectsVisible: effects, quietFor: quiet)
        }
        /// Up until `end`, then fading over `fadeOut`, then down.
        func until(_ end: Date, _ mode: Mode) -> Presentation {
            let past = now.timeIntervalSince(end)
            if past <= 0 { return up(mode) }
            let opacity = 1 - past / Constants.fadeOut
            guard opacity > 0 else { return .down }
            return Presentation(isUp: true, opacity: opacity, mode: mode, effectsVisible: effects, quietFor: nil)
        }

        if consent != nil { return up(.needsYou) }
        if let action { return up(action.cursorTaking ? .handsOff : .background) }
        if let done { return until(done.at.addingTimeInterval(Constants.doneShown), done.success ? .done : .ended) }
        if let stopped, stopped.indefinite { return up(.stopped) }
        if let wait {
            let end = (wait.deadline ?? wait.start).addingTimeInterval(Constants.holdSafety)
            return now < end ? .releasedScreen : .down
        }
        let idle = now.timeIntervalSince(lastActivity)
        let silenceEnd = lastActivity.addingTimeInterval(Constants.holdSafety)
        if idle >= Constants.holdSafety { return until(silenceEnd.addingTimeInterval(Constants.endedShown), .ended) }
        let quiet = idle >= Constants.quietWarningAfter ? idle : nil
        if stopped != nil { return up(.stopped, quiet: quiet) }
        return up(planRunning ? .background : .thinking, quiet: quiet)
    }

    /// The full-screen layer is up only while it has something to show: a hands-off action,
    /// a charging ring, or a ripple still spreading. Never while idle.
    func effectsVisible(at now: Date) -> Bool {
        // While the human is being asked, nothing has their hardware yet.
        if action?.cursorTaking == true, consent == nil { return true }
        if chargeRing != nil { return true }
        return ripples.contains { now.timeIntervalSince($0.start) < Constants.rippleLife }
    }

    /// The jellyfish phase for a mode.
    func phase(at now: Date) -> Phase {
        let presentation = presentation(at: now)
        guard presentation.isUp else { return .hidden }
        return switch presentation.mode {
        case .handsOff: .acting
        case .needsYou, .stopped: .needsHuman
        case .background: action == nil ? .idle : .thinking
        case .thinking: .thinking
        case .done, .ended: .idle
        }
    }
}
