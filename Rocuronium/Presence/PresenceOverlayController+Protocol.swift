import Foundation

/// The overlay-facing half of the panel protocol: the calls the router makes for `busy` and for
/// each acting command. Forwards to the overlay's existing session API.
extension PresenceOverlayController {
    /// `busy on --goal … [--steps …]`: the agent declares what it is trying to do.
    func beginHold(goal: String, steps: [String]) {
        beginHold(note: goal)
    }

    /// `busy step [next|<n>]`: nil advances to the next step; n is 1-based.
    func advanceStep(to step: Int?) {}

    /// `busy wait --for … [--seconds …]`: the agent is waiting on something outside the Mac's UI.
    func beginWait(what: String, seconds: TimeInterval?) {}

    /// `busy off [--result …]`.
    func endHold(result: String?) {
        endHold()
    }

    /// An acting command is starting.
    func begin(action: PanelAction) {
        var phrase = action.verb
        if let label = action.label { phrase += " '\(label)'" }
        if let keys = action.keys { phrase += " '\(keys)'" }
        if let menuPath = action.menuPath { phrase += " '\(menuPath)'" }
        if let point = action.point { phrase += " (\(Int(point.x)), \(Int(point.y)))" }
        if let app = action.app { phrase += " in \(app)" }
        begin(action: phrase + "…", deferAppearance: action.cursorTaking)
    }
}
