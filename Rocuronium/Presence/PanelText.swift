import Foundation

/// What the last action came to, as the panel's third line says it.
nonisolated struct PanelResult: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        /// Something observable changed the way the action intended.
        case confirmed
        /// The action ran and nothing changed, or it failed outright.
        case failed
        /// The action was sent and the app offers no way to check it.
        case unverified
        /// A refusal or a human decision: declined, halted, approved.
        case refused
        /// The human's own input landed during the action or its check.
        case humanInput
    }

    var kind: Kind
    /// The sentence after the glyph.
    var message: String

    /// The glyph that leads the line in plain text: ✓ ✗ ? ⚠, or none for a decision.
    var glyph: String {
        switch kind {
        case .confirmed: "✓"
        case .failed: "✗"
        case .unverified: "?"
        case .humanInput: "⚠"
        case .refused: ""
        }
    }

    /// The whole line as plain text — what the tests read and what a log would print.
    var text: String { glyph.isEmpty ? message : "\(glyph) \(message)" }
}

/// The panel's words: action phrases, result phrases, step lines and clocks.
///
/// Pure functions of the request and the reply, so the live overlay, the showcase and the tests
/// all say the same sentence for the same command. Present participle for what is happening,
/// the object in curly quotes, the app last. Secure text is never echoed.
nonisolated enum PanelText {
    enum Constants {
        /// An element label in quotes.
        static let labelLimit = 28
        /// A read-back value on line 3.
        static let valueLimit = 32
        /// An error sentence carried through to line 3 when no specific phrase fits.
        static let errorLimit = 72
        /// The goal is a headline, never a paragraph.
        static let goalLimit = 64
    }

    // MARK: - Quoting

    /// Collapses whitespace runs (newlines included) to one space and cuts at `limit`
    /// characters with an ellipsis.
    static func truncate(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(1, limit))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `“text”`, truncated.
    static func quote(_ text: String, limit: Int = Constants.labelLimit) -> String {
        "“\(truncate(text, limit: limit))”"
    }

    /// A field whose contents must never be shown: the caller said so, or its name gives it away.
    static func isSecure(_ action: PanelAction) -> Bool {
        if action.secure { return true }
        let label = (action.label ?? "").lowercased()
        return ["password", "passcode", "passwort", "mot de passe", "secret"].contains { label.contains($0) }
    }

    /// The plain noun for an accessibility role, or nil when the role has none worth saying.
    static func roleNoun(_ role: String) -> String? {
        let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return switch bare {
        case "Button": "button"
        case "TextField", "TextArea", "SearchField", "ComboBox": "field"
        case "SecureTextField": "password field"
        case "CheckBox": "checkbox"
        case "RadioButton": "option"
        case "Link": "link"
        case "MenuItem": "menu item"
        case "MenuBarItem": "menu"
        case "PopUpButton", "MenuButton": "pop-up menu"
        case "Tab": "tab"
        case "Slider": "slider"
        case "Switch", "Toggle": "switch"
        case "Row", "Cell", "OutlineRow": "row"
        case "Image": "image"
        case "StaticText": "text"
        default: nil
        }
    }

    /// `cmd+shift+z` → `⇧⌘Z`, `escape` → `Escape`, `cmd+=` → `⌘=`.
    static func keysDisplay(_ keys: String) -> String {
        let parts = keys.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // `cmd++` splits into ["cmd", "", ""]: the trailing empties are the plus key itself.
        var key = parts.last ?? ""
        var modifiers = Array(parts.dropLast())
        if key.isEmpty, keys.hasSuffix("+") {
            key = "+"
            while modifiers.last == "" { modifiers.removeLast() }
        }
        let order: [(names: Set<String>, glyph: String)] = [
            (["ctrl", "control"], "⌃"), (["opt", "alt", "option"], "⌥"),
            (["shift"], "⇧"), (["cmd", "command"], "⌘"),
        ]
        let glyphs = order.filter { !$0.names.isDisjoint(with: modifiers) }.map(\.glyph).joined()
        let named: [String: String] = [
            "escape": "Escape", "esc": "Escape", "return": "Return", "enter": "Return", "tab": "Tab",
            "space": "Space", "delete": "Delete", "forwarddelete": "Forward Delete",
            "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "Home", "end": "End",
            "pageup": "Page Up", "pagedown": "Page Down", "plus": "+", "minus": "-",
            "comma": ",", "period": ".", "equal": "=", "equals": "=",
        ]
        let shown = named[key] ?? (key.count == 1 ? key.uppercased() : key.capitalized)
        // A bare named key reads as a word ("Escape"); with modifiers it reads as a chord (⇧Tab).
        return glyphs + shown
    }

    /// `View > Increase Font Size` → `View ▸ Increase Font Size`.
    static func menuDisplay(_ path: String) -> String {
        path.replacingOccurrences(of: "▸", with: ">")
            .split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ▸ ")
    }

    /// A destination spelled `x,y` reads as coordinates; anything else is a label to quote.
    private static func place(_ destination: String) -> String {
        let numbers = destination.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if numbers.count == 2 { return "\(Int(numbers[0])), \(Int(numbers[1]))" }
        return quote(destination)
    }

    // MARK: - Action phrases

    /// One action, split so it can be said three ways: happening (`Clicking`), asked of the
    /// human's hardware (`to click`), and done (`Clicked`).
    struct Phrase: Equatable {
        var participle: String
        var infinitive: String
        var past: String
        /// What is acted on: `“Sign In”`, `the “Sign In” button`, `at 640, 412`.
        var object: String
        /// Where: `Safari`, or empty.
        var app: String
        /// The preposition that joins object and app: `in`, `into`.
        var preposition = "in"
        /// Which of the human's hands a hardware delivery borrows.
        var hardware: Hardware = .mouse

        enum Hardware { case mouse, keyboard, other }

        /// `object in App`, or whichever half exists.
        var target: String {
            switch (object.isEmpty, app.isEmpty) {
            case (false, false): "\(object) \(preposition) \(app)"
            case (false, true): object
            case (true, false): app
            case (true, true): ""
            }
        }

        func joined(_ verb: String) -> String {
            target.isEmpty ? verb : "\(verb) \(target)"
        }
    }

    /// The element a reply says the action resolved to, when it says.
    struct Resolved: Equatable {
        var role: String?
        var label: String?

        init(role: String?, label: String?) {
            self.role = role
            self.label = label
        }

        /// Reads `element: {role, label}` from a reply; nil when the reply names no element.
        init?(reply: [String: Any]) {
            guard let element = reply["element"] as? [String: Any] else { return nil }
            role = element["role"] as? String
            label = element["label"] as? String
            if role == nil, label == nil { return nil }
        }
    }

    static func phrase(for action: PanelAction, resolved: Resolved? = nil) -> Phrase {
        let app = action.app ?? ""
        let label = action.label.map { quote($0) }
        switch action.verb {
        case "click":
            if let resolved, let name = resolved.label ?? action.label, !name.isEmpty {
                let noun = resolved.role.flatMap(roleNoun)
                let object = noun.map { "the \(quote(name)) \($0)" } ?? quote(name)
                return Phrase(participle: "Clicking", infinitive: "click", past: "Clicked", object: object, app: app)
            }
            if let label {
                return Phrase(participle: "Clicking", infinitive: "click", past: "Clicked", object: label, app: app)
            }
            let object = action.point.map { "at \(Int($0.x)), \(Int($0.y))" } ?? ""
            return Phrase(participle: "Clicking", infinitive: "click", past: "Clicked", object: object, app: app)

        case "type":
            let into = label ?? app
            if isSecure(action) {
                return Phrase(
                    participle: "Typing a password into", infinitive: "type a password into",
                    past: "Typed a password into", object: label.map { "\($0) (hidden)" } ?? "the field (hidden)",
                    app: "", hardware: .keyboard,
                )
            }
            // The typed text is never echoed: the engine cannot know a field is secure before it
            // types, so line 2 names only the field. The read-back on line 3 shows what landed.
            return Phrase(
                participle: "Typing into", infinitive: "type into", past: "Typed into",
                object: into.isEmpty ? "the focused field" : into,
                app: label == nil ? "" : app, hardware: .keyboard,
            )

        case "key", "shortcut":
            let chord = action.keys.map(keysDisplay) ?? "a key"
            return Phrase(
                participle: "Pressing", infinitive: "press", past: "Pressed",
                object: chord, app: app, hardware: .keyboard,
            )

        case "menu":
            let path = action.menuPath.map(menuDisplay) ?? action.label ?? "a menu item"
            return Phrase(
                participle: "Choosing", infinitive: "choose", past: "Chose",
                object: path, app: app, hardware: .keyboard,
            )

        case "scroll":
            if let needle = action.untilText {
                return Phrase(
                    participle: "Scrolling until", infinitive: "scroll until", past: "Scrolled until",
                    object: "\(quote(needle)) is visible", app: "",
                )
            }
            if let edge = action.direction, edge == "top" || edge == "bottom" {
                return Phrase(
                    participle: "Scrolling", infinitive: "scroll", past: "Scrolled",
                    object: app.isEmpty ? "to the \(edge)" : "\(app) to the \(edge)", app: "",
                )
            } else {
                let subject = app.isEmpty ? "" : app
                let way = action.direction.map { subject.isEmpty ? $0 : "\(subject) \($0)" } ?? subject
                return Phrase(participle: "Scrolling", infinitive: "scroll", past: "Scrolled", object: way, app: "")
            }

        case "move":
            let destination = label ?? action.destination.map(place)
                ?? action.point.map { "\(Int($0.x)), \(Int($0.y))" }
            return Phrase(
                participle: "Moving the pointer", infinitive: "move the pointer", past: "Moved the pointer",
                object: destination.map { "to \($0)" } ?? "", app: "",
            )

        case "drag":
            if let points = action.strokePoints {
                return Phrase(
                    participle: "Drawing", infinitive: "draw", past: "Drew",
                    object: "a stroke (\(points) points)", app: app,
                )
            }
            let source = label ?? action.point.map { "from \(Int($0.x)), \(Int($0.y))" } ?? ""
            let destination = action.destination.map { "to \(place($0))" } ?? ""
            let object = [source, destination].filter { !$0.isEmpty }.joined(separator: " ")
            return Phrase(participle: "Dragging", infinitive: "drag", past: "Dragged", object: object, app: "")

        case "launch":
            return Phrase(participle: "Opening", infinitive: "open", past: "Opened", object: app, app: "", hardware: .other)

        case "activate":
            return Phrase(
                participle: "Bringing", infinitive: "bring", past: "Brought",
                object: "\(app.isEmpty ? "the app" : app) to the front", app: "", hardware: .other,
            )

        case "park":
            return Phrase(
                participle: "Moving", infinitive: "move", past: "Moved",
                object: "\(app.isEmpty ? "the window" : app) to the virtual display", app: "", hardware: .other,
            )

        case "resize":
            let size = action.size.map { " to \(Int($0.width)) × \(Int($0.height))" } ?? ""
            return Phrase(
                participle: "Resizing", infinitive: "resize", past: "Resized",
                object: (app.isEmpty ? "the window" : app) + size, app: "", hardware: .other,
            )

        case "window":
            return Phrase(
                participle: "Arranging", infinitive: "arrange", past: "Arranged",
                object: app.isEmpty ? "the window" : "\(app)’s window", app: "", hardware: .other,
            )

        case "statusitem":
            return Phrase(
                participle: "Clicking", infinitive: "click", past: "Clicked",
                object: label ?? "a menu bar item", app: "the menu bar",
            )

        case "wait":
            let what = label.map { "\($0) to appear" } ?? "the app to settle"
            return Phrase(participle: "Waiting for", infinitive: "wait for", past: "Waited for", object: what, app: app, hardware: .other)

        case "read", "find", "map", "screenshot", "windows":
            return Phrase(
                participle: "Looking at", infinitive: "look at", past: "Looked at",
                object: app.isEmpty ? "the screen" : app, app: "", hardware: .other,
            )

        default:
            let verb = action.verb.prefix(1).uppercased() + action.verb.dropFirst()
            return Phrase(participle: verb, infinitive: action.verb, past: verb, object: label ?? "", app: app, hardware: .other)
        }
    }

    /// Line 2 for an action delivered in the background: `Clicking “Sign In” in Safari`.
    static func actionLine(for action: PanelAction, resolved: Resolved? = nil) -> String {
        let phrase = phrase(for: action, resolved: resolved)
        return phrase.joined(phrase.participle)
    }

    /// Line 2 for an action that borrows the human's hardware, naming which hand it takes:
    /// `Using your mouse to click “Sign In” in Safari`, `Typing with your keyboard into Terminal`.
    static func handsOffLine(for action: PanelAction, resolved: Resolved? = nil) -> String {
        let phrase = phrase(for: action, resolved: resolved)
        if action.verb == "type" {
            let secure = isSecure(action)
            let lead = secure ? "Typing a password with your keyboard into" : "Typing with your keyboard into"
            return phrase.joined(lead)
        }
        return switch phrase.hardware {
        case .mouse: phrase.joined("Using your mouse to \(phrase.infinitive)")
        case .keyboard: phrase.joined("Using your keyboard to \(phrase.infinitive)")
        case .other: phrase.joined("Taking over to \(phrase.infinitive)")
        }
    }

    /// `Step 2 of 5 · Typing …`; the bare body when no steps were declared.
    static func stepLine(index: Int?, count: Int, body: String) -> String {
        guard let index, count > 0 else { return body }
        let shown = min(index + 1, count)
        return body.isEmpty ? "Step \(shown) of \(count)" : "Step \(shown) of \(count) · \(body)"
    }

    /// `0:48`, `12:03`, `1:02:03`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Line 1 without a declared goal: `Working in Safari`.
    static func fallbackGoal(app: String?) -> String {
        guard let app, !app.isEmpty else { return "Working on your Mac" }
        return "Working in \(app)"
    }

    /// The summary `busy off` shows for its last two seconds: `Done · 12 actions · 0:48`.
    static func doneLine(actions: Int, elapsed: TimeInterval) -> String {
        "Done · \(actions) action\(actions == 1 ? "" : "s") · \(clock(elapsed))"
    }

    /// Line 3 after a long silence inside a hold.
    static func quietLine(for seconds: TimeInterval) -> String {
        "No activity for \(clock(seconds)) — the agent may have stopped"
    }

    // MARK: - Result phrases

    /// Line 3 for a finished command, or nil when the reply has nothing worth saying.
    static func result(for reply: [String: Any], action: PanelAction?) -> PanelResult? {
        let action = action ?? PanelAction(verb: "", cursorTaking: false)
        let phrase = phrase(for: action, resolved: Resolved(reply: reply))
        if let human = humanInputResult(reply, action: action, phrase: phrase) { return human }
        if reply["halted"] as? Bool == true {
            return PanelResult(kind: .refused, message: "Stopped by ⌃⌥⇧⎋")
        }
        if let error = reply["error"] as? String {
            return errorResult(error, action: action, phrase: phrase)
        }
        switch reply["verdict"] as? String {
        case "confirmed": return confirmedResult(reply, action: action, phrase: phrase)
        case "noEffect":
            return PanelResult(kind: .failed, message: "Nothing changed after \(phrase.participle.lowercasedFirst) \(phrase.object)".trimmed)
        case "unverifiable":
            let app = action.app ?? "the app"
            return PanelResult(kind: .unverified, message: "Sent — \(app) offers no way to check it")
        default:
            guard reply["ok"] as? Bool == true else { return nil }
            return PanelResult(kind: .confirmed, message: phrase.joined(phrase.past))
        }
    }

    /// The human's own input during the action. Hands off, any of it stops the payload; in the
    /// background only input in the target app matters, because it may be what changed.
    private static func humanInputResult(_ reply: [String: Any], action: PanelAction, phrase: Phrase) -> PanelResult? {
        guard let block = reply["humanInput"] as? [String: Any] else { return nil }
        let events = block["events"] as? [[String: Any]] ?? []
        let stopped = block["stopped"] as? Bool == true
        let app = action.app
        if stopped {
            let first = events.first
            let did = humanActivity(first?["kind"] as? String, inTarget: first?["inTarget"] as? Bool == true, app: app)
            return PanelResult(kind: .humanInput, message: "You \(did) during \(actionNoun(action.verb)) — stopped")
        }
        let mixed = reply["attribution"] as? String == "mixed"
        guard let inTarget = events.first(where: { $0["inTarget"] as? Bool == true }) ?? (mixed ? events.first : nil)
        else { return nil }
        let did = humanActivity(inTarget["kind"] as? String, inTarget: true, app: app)
        return PanelResult(kind: .humanInput, message: "You \(did) during the check — the change may be yours")
    }

    private static func humanActivity(_ kind: String?, inTarget: Bool, app: String?) -> String {
        let place = inTarget ? app.map { " in \($0)" } ?? "" : ""
        switch kind?.lowercased() {
        case "mousedown", "click", "leftmousedown", "rightmousedown": return "clicked\(place)"
        case "keydown", "key": return "pressed a key\(place)"
        case "scroll", "scrollwheel": return "scrolled\(place)"
        case "pointermotion", "mousemoved", "mousemove", "move", "motion", "mousedragged": return "moved the mouse"
        default: return "used the mouse or keyboard"
        }
    }

    private static func actionNoun(_ verb: String) -> String {
        switch verb {
        case "click", "statusitem": "the click"
        case "type": "the typing"
        case "key", "shortcut": "the key press"
        case "drag": "the drag"
        case "move": "the move"
        case "scroll": "the scroll"
        case "menu": "the menu choice"
        default: "the action"
        }
    }

    private static func errorResult(_ error: String, action: PanelAction, phrase: Phrase) -> PanelResult {
        if error.contains("was declined by the human") {
            return PanelResult(kind: .refused, message: "Declined")
        }
        if let occluder = firstMatch(#"'([^']+)' covers the target"#, in: error) {
            let verb = action.verb == "drag" ? "drag" : action.verb == "move" ? "move" : "click"
            let target = action.label.map { quote($0) } ?? "the target"
            return PanelResult(kind: .refused, message: "Didn’t \(verb): \(occluder) was covering \(target)")
        }
        if error.hasPrefix("No element matched") {
            let target = action.label.map { quote($0) } ?? "the target"
            let app = action.app.map { " in \($0)" } ?? ""
            return PanelResult(kind: .failed, message: "Couldn’t find \(target)\(app)")
        }
        if error.contains("halted") || error.contains("⌃⌥⇧⎋") {
            return PanelResult(kind: .refused, message: "Stopped by ⌃⌥⇧⎋")
        }
        let sentence = error.split(separator: ".", maxSplits: 1).first.map(String.init) ?? error
        return PanelResult(kind: .failed, message: truncate(sentence, limit: Constants.errorLimit))
    }

    private static func confirmedResult(_ reply: [String: Any], action: PanelAction, phrase: Phrase) -> PanelResult {
        if let menu = reply["menuItem"] as? String, !menu.isEmpty {
            return PanelResult(kind: .confirmed, message: "\(menuDisplay(menu)) ran")
        }
        let readback = (reply["readback"] as? String) ?? ""
        if let counts = windowCountChange(readback) {
            return PanelResult(kind: .confirmed, message: counts.after > counts.before ? "A new window opened" : "A window closed")
        }
        if action.verb == "type", !readback.isEmpty {
            let field = action.label.map { quote($0) } ?? "The field"
            if isSecure(action) {
                return PanelResult(kind: .confirmed, message: "\(field) was filled (hidden)")
            }
            return PanelResult(kind: .confirmed, message: "\(field) now reads \(truncate(readback, limit: Constants.valueLimit))")
        }
        if let delta = reply["treeDelta"] as? String, let change = treeChange(delta) {
            return PanelResult(kind: .confirmed, message: change)
        }
        if reply["pixelDelta"] != nil {
            let app = action.app ?? "The window"
            let where_ = action.verb == "click" ? " where it clicked" : action.verb == "type" ? " where it typed" : ""
            return PanelResult(kind: .confirmed, message: "\(app) changed\(where_)")
        }
        return PanelResult(kind: .confirmed, message: phrase.joined(phrase.past))
    }

    /// `the target's on-screen window count changed 1 → 2` → (1, 2).
    private static func windowCountChange(_ readback: String) -> (before: Int, after: Int)? {
        guard readback.contains("window count changed"),
              let before = firstMatch(#"(\d+) →"#, in: readback).flatMap(Int.init),
              let after = firstMatch(#"→ (\d+)"#, in: readback).flatMap(Int.init)
        else { return nil }
        return (before, after)
    }

    /// The first line of a rendered `TreeDelta`, said plainly, with `+N more` for the rest.
    static func treeChange(_ delta: String) -> String? {
        let lines = delta.split(separator: "\n").map(String.init)
        guard let first = lines.first, first != "no changes" else { return nil }
        var more = lines.count - 1
        if let last = lines.last, last.hasPrefix("…and "), let hidden = firstMatch(#"…and (\d+)"#, in: last).flatMap(Int.init) {
            more += hidden - 1
        }
        let suffix = more > 0 ? " (+\(more) more)" : ""
        if first.hasPrefix("value changed:") {
            let values = allMatches(#"'([^']*)'"#, in: first)
            // The last two quoted strings are old → new; a label, when present, comes first.
            if values.count >= 2 {
                let old = values[values.count - 2], new = values[values.count - 1]
                return "\(quote(old, limit: Constants.valueLimit)) became \(quote(new, limit: Constants.valueLimit))\(suffix)"
            }
        }
        for (prefix, verb) in [("appeared:", "appeared"), ("vanished:", "went away")] where first.hasPrefix(prefix) {
            let body = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let name = allMatches(#"'([^']*)'"#, in: body).first, !name.isEmpty {
                return "\(quote(name)) \(verb)\(suffix)"
            }
            let role = String(body.split(separator: " ").first ?? "")
            let noun = roleNoun(role) ?? "An element"
            return "\(noun.prefix(1).uppercased() + noun.dropFirst()) \(verb)\(suffix)"
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let group = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[group])
        }
    }
}

private extension String {
    nonisolated var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
