import Foundation

/// The panel's three lines, its chip and its clock at one instant — everything the panel view
/// draws, computed from the model so tests can read exactly what the human would.
struct PanelLines: Equatable {
    /// What line 3 holds when it is not a fresh result.
    enum Note: Equatable {
        case result(PanelResult)
        /// Guidance or a warning, colored by `caution`.
        case hint(String, caution: Bool)
        case empty
    }

    var mode: OverlayModel.Mode
    var goal: String
    var now: String
    var note: Note
    /// The chip's bold word: `Background`, `Hands off`, …
    var chipTitle: String
    /// The chip's detail after the dot: `keep working`, `0:42 / ~2:00`.
    var chipDetail: String
    /// 0…1 for a wait with a deadline; drawn as the chip's fill.
    var chipProgress: Double?
    var clock: String

    @MainActor
    init(model: OverlayModel, at date: Date) {
        let presentation = model.presentation(at: date)
        mode = presentation.mode
        goal = model.goal.isEmpty ? PanelText.fallbackGoal(app: model.lastApp) : model.goal

        let elapsedEnd = model.done?.at ?? date
        clock = PanelText.clock(model.sessionStart.map { elapsedEnd.timeIntervalSince($0) } ?? 0)

        now = Self.nowLine(model: model, mode: presentation.mode, date: date)
        note = Self.note(model: model, presentation: presentation, date: date)
        (chipTitle, chipDetail, chipProgress) = Self.chip(model: model, mode: presentation.mode, date: date)
    }

    private static func withStep(_ model: OverlayModel, _ body: String) -> String {
        PanelText.stepLine(index: model.stepIndex, count: model.steps.count, body: body)
    }

    private static func nowLine(model: OverlayModel, mode: OverlayModel.Mode, date: Date) -> String {
        if let done = model.done { return done.text }
        if let consent = model.consent { return consent.prompt }
        if let action = model.action {
            if action.cursorTaking { return withStep(model, PanelText.handsOffLine(for: action, resolved: model.resolved)) }
            if model.steps.isEmpty, let why = action.why, !why.isEmpty { return why }
            return withStep(model, PanelText.actionLine(for: action, resolved: model.resolved))
        }
        if let wait = model.wait { return withStep(model, "Waiting for \(wait.what)") }
        if let index = model.stepIndex, index < model.steps.count {
            return withStep(model, model.steps[index])
        }
        if mode == .thinking { return "Deciding what to do next" }
        // Without a hold, nothing more is promised: say so rather than repeat line 3.
        if !model.holdActive, model.lastAction != nil { return "Finished — nothing else is running" }
        if let last = model.lastAction {
            let phrase = PanelText.phrase(for: last, resolved: model.resolved)
            // Past tense only for what evidently happened; a stopped or failed action was tried.
            switch model.result?.kind {
            case .confirmed?, .unverified?, nil: return phrase.joined(phrase.past)
            default: return phrase.joined("Tried to \(phrase.infinitive)")
            }
        }
        return "Starting"
    }

    private static func note(model: OverlayModel, presentation: OverlayModel.Presentation, date: Date) -> Note {
        if model.consent != nil { return .hint("Hold Y to approve or N to decline", caution: true) }
        if let result = model.freshResult(at: date) { return .result(result) }
        if let quiet = presentation.quietFor { return .hint(PanelText.quietLine(for: quiet), caution: true) }
        if let action = model.action, action.cursorTaking {
            let hand = PanelText.phrase(for: action).hardware == .keyboard ? "keyboard" : "mouse"
            return .hint("Your \(hand) is in use until this finishes — ⌃⌥⇧⎋ takes it back", caution: true)
        }
        if let wait = model.wait, let deadline = wait.deadline {
            let left = deadline.timeIntervalSince(date)
            return left > 0
                ? .hint("About \(PanelText.clock(left)) left", caution: false)
                : .hint("Taking longer than expected", caution: false)
        }
        return .empty
    }

    private static func chip(model: OverlayModel, mode: OverlayModel.Mode, date: Date) -> (String, String, Double?) {
        switch mode {
        case .background:
            return ("Background", "keep working", nil)
        case .handsOff:
            // Which hand is borrowed, not a second clock: the elapsed time is already on line 2.
            let hand = model.action.map { PanelText.phrase(for: $0).hardware == .keyboard ? "keyboard" : "mouse" } ?? "mouse"
            return ("Hands off", hand, nil)
        case .waiting:
            guard let wait = model.wait else { return ("Waiting", "", nil) }
            let elapsed = date.timeIntervalSince(wait.start)
            guard let deadline = wait.deadline else { return ("Waiting", PanelText.clock(elapsed), nil) }
            let total = deadline.timeIntervalSince(wait.start)
            let progress = total > 0 ? min(1, elapsed / total) : 1
            return ("Waiting", "\(PanelText.clock(elapsed)) / ~\(PanelText.clock(total))", progress)
        case .needsYou:
            return ("Needs you", "hold Y / N", nil)
        case .thinking:
            return ("Thinking", PanelText.clock(date.timeIntervalSince(model.lastActivity)), nil)
        case .done:
            return ("Done", "", nil)
        }
    }
}
