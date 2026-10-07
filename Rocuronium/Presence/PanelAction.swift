import CoreGraphics

/// One acting command as the presence panel narrates it: the verb, what it aims at, and
/// whether it takes the human's mouse or keyboard.
///
/// Built by the router from the request before the command runs; `PanelText` turns it into
/// the panel's second line. Plain values only, so the showcase can script the same actions the
/// live overlay narrates.
nonisolated struct PanelAction: Equatable, Sendable {
    /// The command verb as the socket spells it: `click`, `type`, `key`, `menu`, …
    var verb: String
    var app: String?
    /// The element query, or for `type` the field being typed into.
    var label: String?
    /// For `type`: the text being entered. Never shown when `secure` is set.
    var text: String?
    /// The text goes into a secure field; the panel names the field and never echoes the text.
    var secure: Bool = false
    /// A coordinate target, in global top-left points.
    var point: CGPoint?
    /// For `key` / `shortcut`: the chord as the caller spelled it (`cmd+=`, `escape`).
    var keys: String?
    /// For `menu`: the item path, `>`-separated (`View > Increase Font Size`).
    var menuPath: String?
    /// The caller's `--why`: line 2 when no steps are declared.
    var why: String?
    /// The command takes the real cursor or keyboard: the panel enters hands-off mode.
    var cursorTaking: Bool
    /// For `drag` / `move`: where the pointer ends, as a label or an `x,y` pair.
    var destination: String?
    /// For `scroll`: `up`, `down`, `left`, `right`, `top`, `bottom`.
    var direction: String?
    /// For `scroll --until-text`: the text being scrolled into view.
    var untilText: String?
    /// For a `drag --via` stroke: how many points the path passes through.
    var strokePoints: Int?
    /// For `resize`: the requested size in points.
    var size: CGSize?
}
