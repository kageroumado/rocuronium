import Foundation

/// The panel's two lines and its pill at one instant — everything the panel view draws,
/// computed from the model so tests can read exactly what the human would.
///
/// Line 1 is the goal and the pill (mode word and clock). Line 2 is the step prefix, then what
/// is happening now: the action phrase while it runs, replaced in place by its outcome.
struct PanelLines: Equatable {
    /// How line 2's words are weighted.
    enum Tone: Equatable {
        /// What is happening: secondary text.
        case quiet
        /// Needs a glance: the silence warning.
        case caution
        /// The human interrupted: the Stopped sentence.
        case alert
    }

    /// What line 2 holds after the step prefix.
    enum Detail: Equatable {
        case text(String, Tone)
        case outcome(PanelOutcome)
        /// The consent prompt's question.
        case question(String)
    }

    var mode: OverlayModel.Mode
    var goal: String
    /// The pill's word: `Background`, `Hands off`, …
    var pillTitle: String
    /// The pill's clock: the session's elapsed time, or while thinking, how long it has been.
    var pillClock: String
    /// `2/4` when steps were declared.
    var stepPrefix: String?
    var detail: Detail

    /// Line 2 as plain text, prefix included — what the tests read.
    var line2: String {
        let body = switch detail {
        case let .text(text, _): text
        case let .outcome(outcome): outcome.text
        case let .question(question): question
        }
        return stepPrefix.map { "\($0) · \(body)" } ?? body
    }

    /// The pill as plain text: `Background 0:08`.
    var pill: String { "\(pillTitle) \(pillClock)" }

    @MainActor
    init(model: OverlayModel, at date: Date) {
        let presentation = model.presentation(at: date)
        mode = presentation.mode
        goal = Self.headline(model)
        pillTitle = Self.title(presentation.mode)
        pillClock = Self.clock(model: model, mode: presentation.mode, at: date)
        stepPrefix = model.consent == nil ? PanelText.stepPrefix(index: model.stepIndex, count: model.steps.count) : nil
        detail = Self.detail(model: model, presentation: presentation, at: date)
    }

    /// The declared goal; without one, the latest `--why`; without that, the app.
    private static func headline(_ model: OverlayModel) -> String {
        if !model.goal.isEmpty { return model.goal }
        if let why = model.why, !why.isEmpty { return why }
        return PanelText.fallbackGoal(app: model.lastApp)
    }

    static func title(_ mode: OverlayModel.Mode) -> String {
        switch mode {
        case .background: "Background"
        case .handsOff: "Hands off"
        case .needsYou: "Needs you"
        case .thinking: "Thinking"
        case .stopped: "Stopped"
        case .done: "Done"
        case .ended: "Ended"
        }
    }

    private static func clock(model: OverlayModel, mode: OverlayModel.Mode, at date: Date) -> String {
        if mode == .thinking {
            return PanelText.clock(date.timeIntervalSince(model.lastActivity))
        }
        let end = model.done?.at ?? date
        return PanelText.clock(model.sessionStart.map { end.timeIntervalSince($0) } ?? 0)
    }

    private static func detail(model: OverlayModel, presentation: OverlayModel.Presentation, at date: Date) -> Detail {
        if let consent = model.consent { return .question(consent.prompt + "?") }
        if let done = model.done {
            if let text = done.text { return .text(text, .quiet) }
            if let outcome = model.outcome { return .outcome(outcome) }
            return .text(model.actionCount == 0 ? "Nothing needed doing" : "Finished", .quiet)
        }
        if presentation.mode == .ended { return .text(PanelText.endedQuietLine, .quiet) }
        if let action = model.action {
            if action.verb == "wait" { return .text(PanelText.waitLine(for: action), .quiet) }
            if action.cursorTaking { return .text(PanelText.handsOffLine(for: action, resolved: model.resolved), .quiet) }
            return .text(PanelText.actionLine(for: action, resolved: model.resolved) + "…", .quiet)
        }
        if let stopped = model.stopped { return .text(stopped.text, .alert) }
        if let quiet = presentation.quietFor { return .text(PanelText.quietLine(for: quiet), .caution) }
        let stepIsNewer = model.stepMovedAt.map { moved in model.lastFinish.map { moved > $0 } ?? true } ?? false
        if let outcome = model.outcome, !stepIsNewer { return .outcome(outcome) }
        if let index = model.stepIndex, index < model.steps.count { return .text(model.steps[index], .quiet) }
        return .text(model.actionCount == 0 ? "Getting started" : "Working out what to do next", .quiet)
    }
}
