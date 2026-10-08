import Foundation

/// What an action came to: the words after the glyph on line 2, and which glyph leads them.
nonisolated struct PanelResult: Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        /// Something observable changed the way the action intended.
        case confirmed
        /// The action ran and nothing changed, or it failed outright.
        case failed
        /// The action was sent and the app offers no way to check it.
        case unverified
        /// A human decision: declined, approved.
        case refused
        /// The change happened, but the human's own input landed in the target app during the
        /// check, so it is not counted as the agent's.
        case notCounted
    }

    var kind: Kind
    /// The words after the glyph: `reads alex@example.com`, `nothing changed`.
    var detail: String

    /// The glyph in plain text: ✓ ✗ ? ◐, or none for a decision.
    var glyph: String {
        switch kind {
        case .confirmed: "✓"
        case .failed: "✗"
        case .unverified: "?"
        case .notCounted: "◐"
        case .refused: ""
        }
    }

    /// Glyph and detail as plain text.
    var text: String { glyph.isEmpty ? detail : "\(glyph) \(detail)" }
}

/// Line 2 once an action's reply is in: what was done, then what came of it —
/// `Typed into “Email” · ✓ reads alex@example.com`.
nonisolated struct PanelOutcome: Equatable, Sendable {
    /// The action in the past tense, or nil when the result says everything on its own.
    var lead: String?
    var result: PanelResult

    /// The whole line as plain text — what the tests read and what a log would print.
    var text: String {
        guard let lead else { return result.text }
        return "\(lead) · \(result.text)"
    }
}

/// The panel's words: action phrases, outcomes, step prefixes and clocks.
///
/// Pure functions of the request and the reply, so the live overlay, the showcase and the tests
/// all say the same sentence for the same command. Present participle for what is happening,
/// past tense for what happened, the object in curly quotes. Secure text is never echoed.
nonisolated enum PanelText {
    enum Constants {
        /// An element label in quotes; longer ones end in an ellipsis inside the quotes.
        static let labelLimit = 18
        /// A read-back or changed value on line 2.
        static let valueLimit = 24
        /// An error sentence carried through to line 2 when no specific phrase fits.
        static let errorLimit = 64
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
        /// Where, when the object does not already say it: `Safari`, or empty. A quoted label
        /// needs no app — line 1 names it.
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
                return Phrase(participle: "Clicking", infinitive: "click", past: "Clicked", object: object, app: "")
            }
            if let label {
                return Phrase(participle: "Clicking", infinitive: "click", past: "Clicked", object: label, app: "")
            }
            let object = action.point.map { "at \(Int($0.x)), \(Int($0.y))" } ?? ""
            return Phrase(participle: "Clicking", infinitive: "click", past: "Clicked", object: object, app: app)

        case "type":
            if isSecure(action) {
                return Phrase(
                    participle: "Typing a password into", infinitive: "type a password into",
                    past: "Typed a password into", object: label.map { "\($0) (hidden)" } ?? "the field (hidden)",
                    app: "", hardware: .keyboard,
                )
            }
            // The typed text is never echoed: the engine cannot know a field is secure before it
            // types, so line 2 names only the field. The read-back in the outcome shows what landed.
            let into = label ?? app
            return Phrase(
                participle: "Typing into", infinitive: "type into", past: "Typed into",
                object: into.isEmpty ? "the focused field" : into, app: "", hardware: .keyboard,
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
            }
            let way = action.direction.map { app.isEmpty ? $0 : "\(app) \($0)" } ?? app
            return Phrase(participle: "Scrolling", infinitive: "scroll", past: "Scrolled", object: way, app: "")

        case "move":
            let destination = label ?? action.destination.map(place)
                ?? action.point.map { "\(Int($0.x)), \(Int($0.y))" }
            return Phrase(
                participle: "Moving the pointer", infinitive: "move the pointer", past: "Moved the pointer",
                object: destination.map { "to \($0)" } ?? "", app: "",
            )

        case "drag":
            if action.strokePoints != nil {
                return Phrase(participle: "Drawing", infinitive: "draw", past: "Drew", object: "a stroke", app: "")
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
            let what = label.map { "\($0) to \(action.gone ? "go away" : "appear")" } ?? "the app to settle"
            return Phrase(
                participle: "Waiting for", infinitive: "wait for", past: "Waited for",
                object: what, app: label == nil ? app : "", hardware: .other,
            )

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

    /// The action as it happens: `Clicking “Sign In”`, `Pressing ⌘= in Ghostty`.
    static func actionLine(for action: PanelAction, resolved: Resolved? = nil) -> String {
        let phrase = phrase(for: action, resolved: resolved)
        return phrase.joined(phrase.participle)
    }

    /// Line 2 for an action that borrows the human's hardware, naming which hand it takes:
    /// `Using your mouse to click “Sign In”`, `Typing with your keyboard into Terminal`.
    static func handsOffLine(for action: PanelAction, resolved: Resolved? = nil) -> String {
        let phrase = phrase(for: action, resolved: resolved)
        if action.verb == "type" {
            let lead = isSecure(action) ? "Typing a password with your keyboard into" : "Typing with your keyboard into"
            return phrase.joined(lead)
        }
        return switch phrase.hardware {
        case .mouse: phrase.joined("Using your mouse to \(phrase.infinitive)")
        case .keyboard: phrase.joined("Using your keyboard to \(phrase.infinitive)")
        case .other: phrase.joined("Taking over to \(phrase.infinitive)")
        }
    }

    /// Line 2 while a `wait` runs: `Waiting for “Dashboard” to appear · up to 0:25`.
    static func waitLine(for action: PanelAction) -> String {
        let base = actionLine(for: action)
        guard let timeout = action.timeout, timeout > 0 else { return base }
        return "\(base) · up to \(clock(timeout))"
    }

    /// `2/4`: where the agent is in its declared steps; nil when none were declared.
    static func stepPrefix(index: Int?, count: Int) -> String? {
        guard let index, count > 0 else { return nil }
        return "\(min(index + 1, count))/\(count)"
    }

    /// `0:48`, `12:03`, `1:02:03`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Line 1 without a declared goal or a `--why`: `Working in Safari`.
    static func fallbackGoal(app: String?) -> String {
        guard let app, !app.isEmpty else { return "Working on your Mac" }
        return "Working in \(app)"
    }

    /// Line 2 after a long silence.
    static func quietLine(for seconds: TimeInterval) -> String {
        "No word from the agent for \(clock(seconds))"
    }

    /// Line 2 as the safety fade takes a silent session down.
    static let endedQuietLine = "Ended — the agent went quiet"

    // MARK: - Outcomes

    /// Line 2 for a finished command, or nil when the reply has nothing worth saying. A reply
    /// the human interrupted is not an outcome: `stopped(for:action:)` says it.
    static func outcome(for reply: [String: Any], action: PanelAction?) -> PanelOutcome? {
        let action = action ?? PanelAction(verb: "", cursorTaking: false)
        // The outcome names the element by its label alone: the role noun the running phrase
        // uses would push the result off the line.
        let resolved = Resolved(reply: reply).map { Resolved(role: nil, label: $0.label) }
        let phrase = phrase(for: action, resolved: resolved)
        let lead = pastLead(for: action, phrase: phrase)
        if let notCounted = notCountedResult(reply, action: action) {
            return PanelOutcome(lead: nil, result: notCounted)
        }
        if reply["halted"] as? Bool == true {
            return PanelOutcome(lead: phrase.joined("Didn’t \(phrase.infinitive)"), result: PanelResult(kind: .refused, detail: "you pressed the stop keys"))
        }
        if let error = reply["error"] as? String {
            return errorOutcome(error, action: action, phrase: phrase)
        }
        if action.verb == "wait", let satisfied = reply["satisfied"] as? Bool {
            return waitOutcome(reply, action: action, satisfied: satisfied, lead: lead)
        }
        switch reply["verdict"] as? String {
        case "confirmed":
            // With nothing more specific observed, the action itself is the result.
            guard let result = confirmedResult(reply, action: action) else {
                return PanelOutcome(lead: nil, result: PanelResult(kind: .confirmed, detail: lead))
            }
            return PanelOutcome(lead: lead, result: result)
        case "noEffect":
            return PanelOutcome(lead: lead, result: PanelResult(kind: .failed, detail: "nothing changed"))
        case "unverifiable":
            // The lead names the app when its phrase does; otherwise the result says whose app.
            let app = action.app ?? ""
            let detail = app.isEmpty || lead.hasSuffix(app) ? "no way to check" : "\(app) can’t confirm it"
            return PanelOutcome(lead: lead, result: PanelResult(kind: .unverified, detail: detail))
        default:
            guard reply["ok"] as? Bool == true else { return nil }
            return PanelOutcome(lead: nil, result: PanelResult(kind: .confirmed, detail: lead))
        }
    }

    /// The action in the past tense, short enough to leave room for its result: a wait names
    /// only what it waited for (the result says whether it appeared), and a password field
    /// is said once, with `(hidden)` left to the result.
    private static func pastLead(for action: PanelAction, phrase: Phrase) -> String {
        if action.verb == "wait", let label = action.label {
            return "Waited for \(quote(label))"
        }
        if action.verb == "type", isSecure(action) {
            return "Typed into \(action.label.map { quote($0) } ?? "the field")"
        }
        return phrase.joined(phrase.past)
    }

    /// The Stopped state's sentence when the human's input stopped a hands-off action:
    /// `You moved the mouse — the click didn't happen`. Nil when nothing was stopped.
    static func stopped(for reply: [String: Any], action: PanelAction?) -> String? {
        guard let block = reply["humanInput"] as? [String: Any], block["stopped"] as? Bool == true else { return nil }
        let action = action ?? PanelAction(verb: "", cursorTaking: false)
        let first = (block["events"] as? [[String: Any]])?.first
        let who = switch (first?["kind"] as? String)?.lowercased() {
        case "mousedown", "click", "leftmousedown", "rightmousedown": "You clicked"
        case "keydown", "key": "You pressed a key"
        case "scroll", "scrollwheel": "You scrolled"
        case "pointermotion", "mousemoved", "mousemove", "move", "motion", "mousedragged": "You moved the mouse"
        default: "You used the mouse or keyboard"
        }
        return "\(who) — \(consequence(of: action, reply: reply))"
    }

    /// What a stop did to the action, as far as the reply knows.
    private static func consequence(of action: PanelAction, reply: [String: Any]) -> String {
        switch action.verb {
        case "click", "statusitem": return "the click didn’t happen"
        case "type":
            if let typed = typedCount(reply) { return "typing stopped after \(typed.done) of \(typed.total) characters" }
            return "typing stopped"
        case "key", "shortcut": return "the key press didn’t happen"
        case "drag": return action.strokePoints == nil ? "the drag stopped partway" : "the stroke stopped partway"
        case "move": return "the pointer stopped where you took it"
        case "scroll": return "scrolling stopped"
        case "menu": return "the menu choice didn’t happen"
        default: return "the action stopped"
        }
    }

    /// `typing stopped after 12 of 40 characters`, from the reply's attempt log.
    private static func typedCount(_ reply: [String: Any]) -> (done: Int, total: Int)? {
        let outcomes = (reply["attempts"] as? [[String: Any]] ?? []).compactMap { $0["outcome"] as? String }
        for outcome in outcomes {
            if let done = firstMatch(#"stopped after (\d+) of"#, in: outcome).flatMap(Int.init),
               let total = firstMatch(#"of (\d+) characters"#, in: outcome).flatMap(Int.init) {
                return (done, total)
            }
        }
        return nil
    }

    /// The human's click, key or scroll in the target app during a background action's check:
    /// the change may be theirs, so it is not counted.
    private static func notCountedResult(_ reply: [String: Any], action: PanelAction) -> PanelResult? {
        guard let block = reply["humanInput"] as? [String: Any], block["stopped"] as? Bool != true else { return nil }
        let events = block["events"] as? [[String: Any]] ?? []
        let mixed = reply["attribution"] as? String == "mixed"
        guard let inTarget = events.first(where: { $0["inTarget"] as? Bool == true }) ?? (mixed ? events.first : nil)
        else { return nil }
        let place = action.app.map { " in \($0)" } ?? ""
        let did = switch (inTarget["kind"] as? String)?.lowercased() {
        case "keydown", "key": "typed"
        case "scroll", "scrollwheel": "scrolled"
        default: "clicked"
        }
        return PanelResult(kind: .notCounted, detail: "Not counted — you \(did)\(place) during the check")
    }

    private static func waitOutcome(_ reply: [String: Any], action: PanelAction, satisfied: Bool, lead: String) -> PanelOutcome {
        let elapsed = (reply["elapsedSeconds"] as? Double).map { String(format: "%.1f s", $0) }
        let event = action.gone ? "went away" : "appeared"
        if satisfied {
            return PanelOutcome(lead: lead, result: PanelResult(kind: .confirmed, detail: elapsed.map { "\(event) after \($0)" } ?? event))
        }
        let waited = action.timeout.map { " after \(clock($0))" } ?? ""
        return PanelOutcome(lead: lead, result: PanelResult(kind: .failed, detail: "not yet\(waited)"))
    }

    private static func errorOutcome(_ error: String, action: PanelAction, phrase: Phrase) -> PanelOutcome {
        let didNot = phrase.joined("Didn’t \(phrase.infinitive)")
        if error.contains("was declined by the human") {
            return PanelOutcome(lead: didNot, result: PanelResult(kind: .refused, detail: "you declined"))
        }
        if let occluder = firstMatch(#"'([^']+)' covers the target"#, in: error) {
            return PanelOutcome(lead: didNot, result: PanelResult(kind: .failed, detail: "\(occluder) was covering it"))
        }
        if error.hasPrefix("No element matched") {
            let target = action.label.map { quote($0) } ?? "the target"
            let app = action.app.map { " in \($0)" } ?? ""
            return PanelOutcome(lead: nil, result: PanelResult(kind: .failed, detail: "Couldn’t find \(target)\(app)"))
        }
        if error.contains("halted") || error.contains("⌃⌥⇧⎋") {
            return PanelOutcome(lead: didNot, result: PanelResult(kind: .refused, detail: "you pressed the stop keys"))
        }
        let sentence = error.split(separator: ".", maxSplits: 1).first.map(String.init) ?? error
        return PanelOutcome(lead: nil, result: PanelResult(kind: .failed, detail: truncate(sentence, limit: Constants.errorLimit)))
    }

    /// What a confirmed reply observed, or nil when it observed nothing beyond the action
    /// itself — then the past-tense action is the result.
    private static func confirmedResult(_ reply: [String: Any], action: PanelAction) -> PanelResult? {
        if let menu = reply["menuItem"] as? String, !menu.isEmpty {
            // A menu action already names its item; a shortcut learns which item it pressed.
            return action.verb == "menu" ? nil : PanelResult(kind: .confirmed, detail: "ran \(menuDisplay(menu))")
        }
        let readback = (reply["readback"] as? String) ?? ""
        if let counts = windowCountChange(readback) {
            return PanelResult(kind: .confirmed, detail: counts.after > counts.before ? "a new window opened" : "a window closed")
        }
        if action.verb == "type", !readback.isEmpty {
            if isSecure(action) { return PanelResult(kind: .confirmed, detail: "filled (hidden)") }
            return PanelResult(kind: .confirmed, detail: "reads \(truncate(readback, limit: Constants.valueLimit))")
        }
        if let delta = reply["treeDelta"] as? String, let change = treeChange(delta) {
            return PanelResult(kind: .confirmed, detail: change)
        }
        if let delta = reply["pixelDelta"] as? Double {
            return PanelResult(kind: .confirmed, detail: pixelChange(delta, action: action, reply: reply))
        }
        return nil
    }

    /// What a pixel-only confirmation saw: a stroke's line on screen, otherwise how much of the
    /// target redrew — `12% of it redrew` when the lead already names it.
    private static func pixelChange(_ delta: Double, action: PanelAction, reply: [String: Any]) -> String {
        if action.verb == "drag", action.strokePoints != nil { return "the line shows on screen" }
        let percent = delta * 100
        let amount = percent < 1 ? "under 1%" : "\(Int(percent.rounded()))%"
        let named = (Resolved(reply: reply)?.label ?? action.label).map { !$0.isEmpty } ?? false
        return "\(amount) of \(named ? "it" : "the target") redrew"
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
                return "\(quote(old, limit: Constants.valueLimit)) → \(quote(new, limit: Constants.valueLimit))\(suffix)"
            }
        }
        for (prefix, verb) in [("appeared:", "appeared"), ("vanished:", "went away")] where first.hasPrefix(prefix) {
            let body = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let name = allMatches(#"'([^']*)'"#, in: body).first, !name.isEmpty {
                return "\(quote(name)) \(verb)\(suffix)"
            }
            let role = String(body.split(separator: " ").first ?? "")
            let noun = roleNoun(role) ?? "element"
            let article = noun.first.map { "aeiou".contains($0) } == true ? "an" : "a"
            return "\(article) \(noun) \(verb)\(suffix)"
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
