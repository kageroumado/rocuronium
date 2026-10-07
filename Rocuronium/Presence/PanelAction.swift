import CoreGraphics

/// What an acting command is about to do, as the presence panel needs it to phrase line 2:
/// the verb and its object, the app, and the purpose the agent gave with `--why`.
///
/// Built by the router from the request before dispatch. Fields carry the request's own words
/// (the label query, the typed text); resolution details arrive later with the reply.
struct PanelAction: Equatable, Sendable {
    var verb: String
    var app: String?
    var label: String?
    var text: String?
    /// The target is a secure text field, so `text` must never be shown.
    var secure: Bool = false
    var point: CGPoint?
    var keys: String?
    /// For `menu`: the path as given, "File > Export".
    var menuPath: String?
    /// The agent's purpose for this one action, from `--why`.
    var why: String?
    /// The action takes the real cursor or keyboard: the panel's hands-off mode.
    var cursorTaking: Bool
}
