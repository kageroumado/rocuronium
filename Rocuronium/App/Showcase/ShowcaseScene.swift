import SwiftUI

/// One timestamped thing that happens in a showcase scene: a call the router or the relay would
/// make on the overlay, or a change on the pretend desktop.
struct ShowcaseEvent {
    enum Kind {
        // What the live overlay receives.
        case begin(PanelAction)
        case finish([String: Any])
        case hold(goal: String, steps: [String])
        case step(Int?)
        /// `busy wait`: the agent waits on something that is not the UI.
        case busyWait(String, seconds: TimeInterval?)
        case endHold(String?)
        case plan([String])
        case planEnd(String?)
        case charge(CGPoint, TimeInterval)
        case ripple(CGPoint)
        case consent(String)
        /// The human holding a consent key; the fill grows over `over`.
        case consentHold(ConsentAnswer, over: TimeInterval)
        case consentResolve(ConsentAnswer)
        case expand(Bool)
        // What happens on the pretend desktop.
        case pointer(to: CGPoint, over: TimeInterval, by: PointerActor)
        /// The pointer follows `path` from its first point to its last, at the pace the
        /// `stroke` change draws it.
        case trace([CGPoint], over: TimeInterval, by: PointerActor)
        case desktop(DesktopChange, over: TimeInterval)
    }

    let at: TimeInterval
    let kind: Kind

    init(_ at: TimeInterval, _ kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

/// A change to the pretend desktop; `over` stretches it across time where that makes sense
/// (text appearing letter by letter, a progress bar filling, a window sliding away).
enum DesktopChange {
    case focus(MockWindowID)
    /// The window appears on top, settling in as it fades up.
    case open(MockWindowID)
    case email(String)
    case password(Int)
    case remember(Bool)
    case pressSignIn
    case signingIn
    case signedIn
    case notesTitle(String)
    /// The human types `text` into Notes, from its `from`-th character to the end.
    case humanTypes(String, from: Int)
    case humanClick
    case terminal(String)
    case build(from: Double, to: Double)
    case buildDone
    case stroke([CGPoint])
    case park(MockWindowID)

    /// Smoothstep: motion that starts and lands softly.
    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    func apply(to state: inout MockDesktopState, progress: Double) {
        switch self {
        case let .focus(id):
            state.windows.removeAll { $0 == id }
            state.windows.append(id)
        case let .open(id):
            if !state.windows.contains(id) { state.windows.append(id) }
            state.opening[id] = progress < 1 ? Self.ease(progress) : nil
        case let .email(text):
            state.email = String(text.prefix(Int((Double(text.count) * progress).rounded())))
        case let .password(count):
            state.passwordLength = Int((Double(count) * progress).rounded())
        case let .remember(on):
            state.remember = on
        case .pressSignIn:
            state.signInPress = sin(progress * .pi)
        case .signingIn:
            state.signingIn = true
        case .signedIn:
            state.signingIn = false
            state.signedIn = true
        case let .notesTitle(title):
            state.notesTitle = title
        case let .humanTypes(text, from):
            let position = Double(from) + Double(text.count - from) * progress
            let count = Int(position.rounded(.down))
            state.notesText = String(text.prefix(count))
            state.humanTyping = progress < 1
            state.keyGlow = progress < 1 ? Self.keyGlow(typing: Array(text), at: position) : [:]
        case .humanClick:
            state.humanClick = progress < 1 ? progress : 0
        case let .terminal(line):
            state.terminalLines.append(line)
        case let .build(from, to):
            state.buildProgress = from + (to - from) * progress
        case .buildDone:
            state.buildProgress = nil
        case let .stroke(points):
            state.stroke = StrokeTrace(points).prefix(at: StrokeTrace.ease(progress))
        case let .park(id):
            state.parked[id] = Self.ease(progress)
        }
    }

    /// The keys lit while the human types: the key just pressed at full strength, fading over
    /// one keystroke, with the one before it dimming out.
    private static func keyGlow(typing text: [Character], at position: Double) -> [String: Double] {
        let index = Int(position.rounded(.down))
        let since = position - Double(index)
        var glow: [String: Double] = [:]
        for (back, strength) in [(1, 1 - 0.4 * since), (2, 0.35 * (1 - since))] where index - back >= 0 && index - back < text.count {
            for key in MockKeyboardLayout.keys(for: text[index - back]) {
                glow[key] = max(glow[key] ?? 0, strength)
            }
        }
        return glow
    }
}

/// A path walked at constant speed: the stroke and the pointer drawing it read the same point
/// for the same progress, so the line always ends under the pointer.
struct StrokeTrace {
    let points: [CGPoint]
    /// Distance along the path at each point.
    private let distances: [Double]

    init(_ points: [CGPoint]) {
        self.points = points
        var total = 0.0
        var distances = [0.0]
        for (a, b) in zip(points, points.dropFirst()) {
            total += hypot(b.x - a.x, b.y - a.y)
            distances.append(total)
        }
        self.distances = distances
    }

    /// A drag's pace: it sets off and arrives gently and keeps an even speed between.
    static func ease(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return 0.5 * clamped + 0.5 * clamped * clamped * (3 - 2 * clamped)
    }

    /// The point `progress` (0…1) of the way along the path.
    func point(at progress: Double) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1, let total = distances.last, total > 0 else { return first }
        let target = min(1, max(0, progress)) * total
        let index = max(1, distances.firstIndex { $0 >= target } ?? points.count - 1)
        let span = distances[index] - distances[index - 1]
        let f = span > 0 ? (target - distances[index - 1]) / span : 0
        let a = points[index - 1], b = points[index]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// The path drawn up to `progress`, ending exactly at `point(at: progress)`.
    func prefix(at progress: Double) -> [CGPoint] {
        guard progress > 0, let total = distances.last else { return [] }
        let target = min(1, progress) * total
        var drawn = Array(zip(points, distances).prefix { $0.1 < target }.map(\.0))
        drawn.append(point(at: progress))
        return drawn
    }
}

/// A scripted scene: what it demonstrates, how long it runs, the moments worth a still frame,
/// and its events as data.
struct ShowcaseScene: Identifiable {
    let number: Int
    let slug: String
    let title: String
    /// One or two sentences under the stage saying what to watch for.
    let caption: String
    let duration: TimeInterval
    /// Scene times the offline renderer captures.
    let keyMoments: [TimeInterval]
    let initial: MockDesktopState
    let events: [ShowcaseEvent]

    var id: Int { number }

    enum Constants {
        /// An agent move this long or longer curves gently, the way a hand moves a mouse;
        /// shorter ones are path segments and stay straight.
        static let arcMinimumDuration: TimeInterval = 0.3
        /// The curve's bulge as a fraction of the move's length.
        static let arcBulge = 0.09
        /// The pointer keeps its "you" tag this long after the human's hand stops.
        static let youTagLinger: TimeInterval = 1.0
        /// The fingertip stays on the trackpad this long after the pointer stops.
        static let fingerLinger: TimeInterval = 0.35
        static let fingerTrailDots = 7
        static let fingerTrailStep: TimeInterval = 0.035
        /// The trackpad's unused border, as a fraction of each side.
        static let trackpadMargin = 0.12
        /// The pause at the end of a scene before it loops.
        static let loopRest: TimeInterval = 1.2
        /// Samples along the logo stroke: fifteen per segment between its 24 via points.
        static let strokeSamples = 345
    }

    /// Seconds the last frame holds before the scene loops.
    var loopRest = Constants.loopRest
    /// The closing seconds that dissolve into the first frame, so the loop has no seam.
    var loopDissolve: TimeInterval = 0

    /// A fixed instant, so every render of a scene is identical, frame for frame.
    static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func date(_ t: TimeInterval) -> Date { Self.epoch.addingTimeInterval(t) }

    /// The overlay model and the desktop at scene time `t`, replayed from the start — so
    /// scrubbing backward is as exact as playing forward.
    func frame(at t: TimeInterval) -> (model: OverlayModel, desktop: MockDesktopState) {
        let model = OverlayModel(showForAllActions: true)
        var desktop = initial
        for event in events where event.at <= t {
            let now = date(event.at)
            switch event.kind {
            case let .begin(action): model.begin(action, at: now)
            case let .finish(reply): model.finish(reply: reply, at: now)
            case let .hold(goal, steps): model.beginHold(goal: goal, steps: steps, at: now)
            case let .step(step): model.advanceStep(to: step, at: now)
            case let .busyWait(what, seconds): model.beginWait(what: what, seconds: seconds, at: now)
            case let .endHold(result): model.endHold(result: result, at: now)
            case let .plan(intents): model.beginPlan(intents: intents, at: now)
            case let .planEnd(reason): model.endPlan(abortReason: reason, at: now)
            case let .charge(point, duration): model.charge(at: point, duration: duration, now: now)
            case let .ripple(point): model.addRipple(at: point, now: now)
            case let .consent(prompt): model.presentConsent(prompt: prompt, at: now)
            case let .consentHold(answer, over):
                model.consentHold = (answer, min(1, (t - event.at) / over))
            case let .consentResolve(answer): model.resolveConsent(answer, at: now)
            case let .expand(open): model.panelExpanded = open
            case .pointer, .trace: break
            case let .desktop(change, over):
                change.apply(to: &desktop, progress: over > 0 ? min(1, (t - event.at) / over) : 1)
            }
        }
        let pointer = pointer(at: t)
        desktop.pointer = pointer.point
        desktop.pointerActor = pointer.actor
        desktop.humanHandRecent = humanMovedPointer(near: t, linger: Constants.youTagLinger) || desktop.humanClick > 0
        desktop.deck = deck(at: t, model: model, desktop: desktop)
        return (model, desktop)
    }

    /// The human moved the pointer within `linger` of `t`.
    private func humanMovedPointer(near t: TimeInterval, linger: TimeInterval) -> Bool {
        events.contains { event in
            guard let move = pointerMove(event), move.by == .human else { return false }
            return event.at <= t && t <= event.at + move.over + linger
        }
    }

    private func pointerMove(_ event: ShowcaseEvent) -> (over: TimeInterval, by: PointerActor)? {
        switch event.kind {
        case let .pointer(_, over, by), let .trace(_, over, by): (over, by)
        default: nil
        }
    }

    /// Where the pointer is at `t` and who moved it last, eased between scripted positions.
    /// The agent's longer moves bow slightly to one side, as a hand's do.
    func pointer(at t: TimeInterval) -> (point: CGPoint, actor: PointerActor) {
        var point = initial.pointer
        var actor = initial.pointerActor
        for event in events where event.at <= t {
            let raw: (TimeInterval) -> Double = { over in over > 0 ? min(1, (t - event.at) / over) : 1 }
            switch event.kind {
            case let .pointer(target, over, by):
                let progress = raw(over)
                let eased = progress * progress * (3 - 2 * progress)
                var next = CGPoint(x: point.x + (target.x - point.x) * eased, y: point.y + (target.y - point.y) * eased)
                if over >= Constants.arcMinimumDuration {
                    let dx = target.x - point.x, dy = target.y - point.y
                    let bulge = Constants.arcBulge * sin(eased * .pi)
                    next.x -= dy * bulge
                    next.y += dx * bulge
                }
                point = next
                actor = by
            case let .trace(path, over, by):
                point = StrokeTrace(path).point(at: StrokeTrace.ease(raw(over)))
                actor = by
            default:
                continue
            }
        }
        return (point, actor)
    }

    // MARK: - The human's keyboard and trackpad

    /// Who has the keyboard and the trackpad at `t`, and what the human's hands are doing on
    /// them. Hands-off actions take the device they drive and pause the other; ghost actions
    /// leave both with the human.
    private func deck(at t: TimeInterval, model: OverlayModel, desktop: MockDesktopState) -> InputDeckState {
        var deck = InputDeckState(keyGlow: desktop.keyGlow)
        if let hold = model.consentHold, hold.fraction > 0 {
            deck.keyGlow[Self.consentKey(hold.answer)] = 1
        }
        if let action = model.action, model.consent == nil {
            if action.cursorTaking {
                let keyboard = PanelText.phrase(for: action).hardware == .keyboard
                deck.keyboard = keyboard ? .agent : .paused
                deck.trackpad = keyboard ? .paused : .agent
                if !keyboard { deck.agentPointer = Self.trackpadPoint(desktop.pointer) }
            } else {
                deck.keyboard = .stillYours
                deck.trackpad = .stillYours
            }
        }
        if !deck.keyGlow.isEmpty || desktop.humanTyping, deck.keyboard != .agent {
            deck.keyboard = .human
        }
        let touching = humanMovedPointer(near: t, linger: Constants.fingerLinger) || desktop.humanClick > 0
        if touching {
            deck.finger = Self.trackpadPoint(desktop.pointer)
            deck.fingerPress = desktop.humanClick
            deck.fingerTrail = (1 ... Constants.fingerTrailDots).compactMap { step in
                let earlier = t - Double(step) * Constants.fingerTrailStep
                guard humanMovedPointer(near: earlier, linger: 0) else { return nil }
                return Self.trackpadPoint(pointer(at: earlier).point)
            }
            // The human's touch on an amber trackpad is what stops a hands-off action, so the
            // pad stays the agent's until the reply says it stopped.
            if deck.trackpad != .agent { deck.trackpad = .human }
        }
        return deck
    }

    /// The consent key the human holds for an answer.
    private static func consentKey(_ answer: ConsentAnswer) -> String {
        switch answer {
        case .approve: "y"
        case .approveForAWhile: "a"
        case .decline: "n"
        }
    }

    /// A desktop point on the trackpad, in unit coordinates with a margin so the fingertip
    /// never sits on the edge.
    private static func trackpadPoint(_ point: CGPoint) -> CGPoint {
        let margin = Constants.trackpadMargin
        return CGPoint(
            x: margin + (1 - 2 * margin) * min(1, max(0, point.x / MockLayout.desktop.width)),
            y: margin + (1 - 2 * margin) * min(1, max(0, point.y / MockLayout.desktop.height)),
        )
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - The scenes

extension ShowcaseScene {
    static let all: [ShowcaseScene] = [
        hero, ghostWhileTyping, multiStep, handsOffClick, handsOffInterrupted, notCounted,
        waitingForTheUI, parking, drawingPath, consent, thinkingThenDone, planBatch, releasingTheScreen,
    ]

    private static let notes = "Groceries for the week:\n– oat milk\n– eggs\n– coffee beans\n– lemons, two"
    private static let signedOut = MockDesktopState(windows: [.notes, .safari])
    private static let filledIn = MockDesktopState(windows: [.notes, .safari], email: "alex@example.com", passwordLength: 13)

    // MARK: Actions the scenes repeat

    private static func typeEmail(hands: Bool = false) -> PanelAction {
        PanelAction(verb: "type", app: "Safari", label: "Email", text: "alex@example.com", cursorTaking: hands)
    }

    private static func typePassword() -> PanelAction {
        PanelAction(verb: "type", app: "Safari", label: "Password", text: "correct horse", secure: true, cursorTaking: false)
    }

    private static func clickSignIn(hands: Bool, done: Bool = false) -> PanelAction {
        PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: hands, endsSession: done)
    }

    private static let emailTyped: [String: Any] = [
        "ok": true, "verdict": "confirmed", "tentacle": "accessibility", "readback": "alex@example.com",
    ]
    private static let passwordTyped: [String: Any] = ["ok": true, "verdict": "confirmed", "readback": "•••••••••••••"]
    private static let welcomed: [String: Any] = [
        "ok": true, "verdict": "confirmed",
        "element": ["role": "AXButton", "label": "Sign In"],
        "treeDelta": "appeared: AXStaticText 'Welcome back, Alex'",
    ]
    private static let hardwareClean: [String: Any] = ["monitored": true, "stopped": false]

    /// The `drag --via` points the agent sends for the logo stroke.
    static let strokeViaCount = 24

    /// The logo stroke: a wide figure-eight across the canvas, sampled densely enough to draw
    /// as a smooth curve. The agent's via points are every fifteenth sample of it.
    static let strokeCurve: [CGPoint] = (0 ... Constants.strokeSamples).map { index in
        let angle = Double(index) / Double(Constants.strokeSamples) * 2 * .pi
        return CGPoint(x: 550 + 230 * sin(angle), y: 320 + 110 * sin(2 * angle))
    }

    private static func drawStroke() -> PanelAction {
        PanelAction(verb: "drag", app: "Freeform", cursorTaking: true, strokePoints: strokeViaCount)
    }

    // MARK: 0 — the hero clip

    static let hero = ShowcaseScene(
        number: 0, slug: "hero",
        title: "The whole range in twelve seconds",
        caption: "Ghost typing while you write in Notes — your keyboard shows only your keys. A hands-off click takes the trackpad (amber), Safari is parked on the virtual display, a stroke is drawn in Freeform, a beat of thinking, then --done.",
        duration: 12, keyMoments: [0.8, 1.6, 2.5, 3.0, 4.2, 5.2, 6.2, 7.3, 8.6, 9.4, 11.0],
        initial: MockDesktopState(windows: [.safari, .notes]),
        events: [
            .init(0.1, .hold(goal: "Getting the launch demo ready", steps: [
                "Fill in the sign-in form", "Sign in", "Clear Safari off the screen", "Sketch the logo",
            ])),
            .init(0.2, .desktop(.humanTypes(String(notes.prefix(34)), from: 0), over: 1.8)),
            .init(0.35, .begin(typeEmail())),
            .init(0.4, .desktop(.email("alex@example.com"), over: 0.6)),
            .init(1.1, .finish(emailTyped)),
            .init(1.25, .begin(typePassword())),
            .init(1.3, .desktop(.password(13), over: 0.45)),
            .init(1.85, .finish(passwordTyped)),
            .init(1.95, .step(nil)),
            .init(2.05, .begin(clickSignIn(hands: true))),
            .init(2.1, .pointer(to: MockLayout.signInButton.center, over: 0.6, by: .agent)),
            .init(2.7, .charge(MockLayout.signInButton.center, 0.5)),
            .init(3.2, .ripple(MockLayout.signInButton.center)),
            .init(3.2, .desktop(.pressSignIn, over: 0.25)),
            .init(3.4, .desktop(.signedIn, over: 0)),
            .init(3.5, .finish(welcomed.merging(["tentacle": "hardwareInput", "humanInput": hardwareClean, "attribution": "agent"]) { $1 })),
            .init(3.6, .step(nil)),
            .init(3.6, .desktop(.humanTypes(notes, from: 34), over: 1.1)),
            .init(3.7, .begin(PanelAction(verb: "park", app: "Safari", cursorTaking: false))),
            .init(3.75, .desktop(.park(.safari), over: 0.8)),
            .init(4.6, .finish(["ok": true, "summary": "parked 'Safari' on the virtual display"])),
            .init(4.7, .step(nil)),
            .init(4.7, .desktop(.open(.sketch), over: 0.35)),
            .init(4.95, .begin(drawStroke())),
            .init(5.0, .pointer(to: strokeCurve[0], over: 0.35, by: .agent)),
            .init(5.35, .trace(strokeCurve, over: 1.6, by: .agent)),
            .init(5.35, .desktop(.stroke(strokeCurve), over: 1.6)),
            .init(7.05, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "hardwareInput", "pixelDelta": 0.08,
                "humanInput": hardwareClean, "attribution": "agent",
            ])),
            .init(7.85, .begin(PanelAction(verb: "shortcut", app: "Freeform", keys: "cmd+s", cursorTaking: false, endsSession: true))),
            .init(8.2, .finish(["ok": true, "verdict": "confirmed", "menuItem": "File > Save"])),
            // The Mac is the human's again: their hand takes the pointer back.
            .init(9.0, .pointer(to: MockLayout.restingPointer, over: 0.8, by: .human)),
        ],
        loopRest: 0, loopDissolve: 0.6,
    )

    // MARK: 1–12

    static let ghostWhileTyping = ShowcaseScene(
        number: 1, slug: "ghost-while-typing",
        title: "Background work while you type",
        caption: "Ghost input fills Safari's form while you keep typing in Notes. Your keyboard lights only with your own keys. Between actions the pill says Thinking; the last action carries --done, so the panel goes to Done and fades.",
        duration: 8.2, keyMoments: [1.2, 2.6, 3.9, 4.7, 6.0, 7.5],
        initial: MockDesktopState(windows: [.safari, .notes]),
        events: [
            .init(0.2, .desktop(.humanTypes(notes, from: 0), over: 7.5)),
            .init(0.6, .begin(typeEmail())),
            .init(0.7, .desktop(.email("alex@example.com"), over: 1.0)),
            .init(1.9, .finish(emailTyped)),
            .init(4.4, .begin(PanelAction(verb: "click", app: "Safari", label: "Remember me", cursorTaking: false, endsSession: true))),
            .init(5.0, .ripple(MockLayout.rememberBox.center)),
            .init(5.0, .desktop(.remember(true), over: 0)),
            .init(5.2, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "postedEvents",
                "treeDelta": "value changed: AXCheckBox 'Remember me': 'off' → 'on'",
            ])),
        ],
    )

    static let multiStep = ShowcaseScene(
        number: 2, slug: "multi-step-goal",
        title: "A goal with steps",
        caption: "The agent declares its goal and four steps. Line 2 leads with 2/4, and the list shows numbered dots: done, now, still to come. The last step is a wait sent with --done, so the panel ends Done when the dashboard appears.",
        duration: 12.4, keyMoments: [1.3, 3.3, 5.0, 7.5, 8.6, 10.0],
        initial: signedOut,
        events: [
            .init(0.2, .hold(goal: "Signing in to Example with the test account", steps: [
                "Open the sign-in form", "Type the credentials", "Submit", "Check the dashboard loads",
            ])),
            .init(0.5, .expand(true)),
            .init(1.0, .begin(PanelAction(verb: "click", app: "Safari", label: "Sign in", cursorTaking: false))),
            .init(1.3, .ripple(MockLayout.signInLink.center)),
            .init(1.6, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "appeared: AXTextField 'Email'\nappeared: AXSecureTextField 'Password'",
            ])),
            .init(2.4, .step(nil)),
            .init(2.8, .begin(typeEmail())),
            .init(2.9, .desktop(.email("alex@example.com"), over: 0.9)),
            .init(3.9, .finish(emailTyped)),
            .init(4.5, .begin(typePassword())),
            .init(4.6, .desktop(.password(13), over: 0.8)),
            .init(5.5, .finish(passwordTyped)),
            .init(6.2, .step(nil)),
            .init(6.5, .begin(clickSignIn(hands: false))),
            .init(7.0, .ripple(MockLayout.signInButton.center)),
            .init(7.05, .desktop(.signingIn, over: 0)),
            .init(7.2, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "value changed: AXButton 'Sign In': 'Sign In' → 'Signing in…'",
            ])),
            .init(7.8, .step(nil)),
            .init(8.0, .begin(PanelAction(verb: "wait", app: "Safari", label: "Dashboard", cursorTaking: false, endsSession: true, timeout: 10))),
            .init(9.4, .desktop(.signedIn, over: 0)),
            .init(9.5, .finish(["ok": true, "satisfied": true, "elapsedSeconds": 1.5])),
        ],
    )

    static let handsOffClick = ShowcaseScene(
        number: 3, slug: "hands-off-click",
        title: "Hands off: a hardware click",
        caption: "This click needs the real mouse. The panel turns amber before the pointer moves; an amber border frames the screen, your trackpad turns amber, the jellyfish escorts the pointer, and the ring charges for 0.6 s — the window to grab the mouse back. The click carries --done.",
        duration: 6, keyMoments: [1.2, 2.0, 2.45, 3.3, 5.1],
        initial: filledIn,
        events: [
            .init(0.2, .hold(goal: "Submitting the sign-in form", steps: [])),
            .init(0.8, .begin(clickSignIn(hands: true, done: true))),
            .init(0.9, .pointer(to: MockLayout.signInButton.center, over: 0.8, by: .agent)),
            .init(1.7, .charge(MockLayout.signInButton.center, 0.6)),
            .init(2.3, .ripple(MockLayout.signInButton.center)),
            .init(2.3, .desktop(.pressSignIn, over: 0.3)),
            .init(2.6, .desktop(.signedIn, over: 0)),
            .init(2.9, .finish(welcomed.merging(["tentacle": "hardwareInput", "humanInput": hardwareClean, "attribution": "agent"]) { $1 })),
        ],
    )

    static let handsOffInterrupted = ShowcaseScene(
        number: 4, slug: "hands-off-interrupted",
        title: "Hands off, interrupted",
        caption: "Mid-move, your finger touches the amber trackpad. That touch stops the rest of the action and the panel holds in Stopped — no fade, no snap back — until the agent's next command. Here it retries with a ghost click that needs no mouse.",
        duration: 9.4, keyMoments: [1.2, 1.5, 1.7, 4.5, 6.2, 7.2],
        initial: filledIn,
        events: [
            .init(0.3, .hold(goal: "Submitting the sign-in form", steps: [])),
            .init(0.5, .begin(clickSignIn(hands: true))),
            .init(0.6, .pointer(to: CGPoint(x: 700, y: 520), over: 0.8, by: .agent)),
            .init(1.4, .pointer(to: CGPoint(x: 760, y: 560), over: 0.35, by: .human)),
            .init(1.55, .finish([
                "ok": false,
                "error": "Stopped: the human moved the mouse during the click, so the rest of it was not delivered.",
                "humanInput": [
                    "monitored": true, "stopped": true,
                    "events": [["kind": "pointerMotion", "inTarget": false, "atMs": 640]],
                ],
            ])),
            .init(1.9, .pointer(to: CGPoint(x: 880, y: 600), over: 1.2, by: .human)),
            .init(6.0, .begin(clickSignIn(hands: false, done: true))),
            .init(6.5, .ripple(MockLayout.signInButton.center)),
            .init(6.6, .desktop(.signedIn, over: 0)),
            .init(6.7, .finish(welcomed)),
        ],
    )

    static let notCounted = ShowcaseScene(
        number: 5, slug: "not-counted",
        title: "When you caused the change",
        caption: "A ghost click on “Remember me” while you click the same checkbox on your trackpad. The checkbox did change, but your click landed in Safari during the check, so the panel does not count it — and the agent's reply says attribution: mixed.",
        duration: 7.6, keyMoments: [1.0, 1.75, 2.6, 4.0, 5.2],
        initial: MockDesktopState(windows: [.notes, .safari]),
        events: [
            .init(0.4, .begin(PanelAction(verb: "click", app: "Safari", label: "Remember me", cursorTaking: false))),
            .init(0.5, .pointer(to: MockLayout.rememberBox.center, over: 1.0, by: .human)),
            .init(1.6, .desktop(.humanClick, over: 0.4)),
            .init(1.65, .desktop(.remember(true), over: 0)),
            .init(1.9, .ripple(MockLayout.rememberBox.center)),
            .init(2.2, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "value changed: AXCheckBox 'Remember me': 'off' → 'on'",
                "humanInput": [
                    "monitored": true, "stopped": false,
                    "events": [["kind": "mouseDown", "inTarget": true, "atMs": 1180]],
                ],
                "attribution": "mixed",
            ])),
            .init(4.8, .endHold("Left “Remember me” as you set it")),
        ],
    )

    static let waitingForTheUI = ShowcaseScene(
        number: 6, slug: "waiting-for-the-ui",
        title: "Waiting for the screen",
        caption: "The agent clicks Sign In, then waits for “Dashboard” to appear — a wait on the UI, so the panel stays and says what it is watching for and for how long. The wait carries --done.",
        duration: 7, keyMoments: [0.7, 1.3, 2.5, 4.4, 6.4],
        initial: filledIn,
        events: [
            .init(0.2, .hold(goal: "Signing in to Example", steps: [])),
            .init(0.5, .begin(clickSignIn(hands: false))),
            .init(0.9, .ripple(MockLayout.signInButton.center)),
            .init(0.9, .desktop(.pressSignIn, over: 0.25)),
            .init(1.0, .desktop(.signingIn, over: 0)),
            .init(1.1, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "value changed: AXButton 'Sign In': 'Sign In' → 'Signing in…'",
            ])),
            .init(1.5, .begin(PanelAction(verb: "wait", app: "Safari", label: "Dashboard", cursorTaking: false, endsSession: true, timeout: 25))),
            .init(4.0, .desktop(.signedIn, over: 0)),
            .init(4.1, .finish(["ok": true, "satisfied": true, "elapsedSeconds": 2.6])),
        ],
    )

    static let parking = ShowcaseScene(
        number: 7, slug: "parking-on-the-virtual-display",
        title: "Parking a window off-screen",
        caption: "No goal was declared, so the action's --why is the headline. The agent moves Notes to the virtual display — a screen only it can see — and keeps working there; the mini-map shows both displays.",
        duration: 6.6, keyMoments: [1.2, 2.4, 3.3, 4.2],
        initial: MockDesktopState(windows: [.notes, .safari], notesText: notes),
        events: [
            .init(0.5, .begin(PanelAction(verb: "park", app: "Notes", why: "Filing the grocery note out of your way", cursorTaking: false))),
            .init(0.8, .desktop(.park(.notes), over: 1.0)),
            .init(2.0, .finish(["ok": true, "summary": "parked 'Notes' on the virtual display"])),
            .init(3.0, .begin(PanelAction(verb: "click", app: "Notes", label: "Done", cursorTaking: false, endsSession: true))),
            .init(3.6, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "value changed: AXButton 'Done': 'Done' → 'Saved'",
            ])),
        ],
    )

    static let drawingPath = ShowcaseScene(
        number: 8, slug: "drawing-a-path",
        title: "Drawing with drag --via",
        caption: "A hands-off drag through 24 points: the pointer is the agent's for three seconds, so the panel, the screen edge and your amber trackpad say so. Then a beat of thinking, and busy off --result ends it.",
        duration: 8.4, keyMoments: [0.8, 2.2, 3.6, 4.9, 6.0],
        initial: MockDesktopState(windows: [.notes, .sketch]),
        events: [
            .init(0.2, .hold(goal: "Sketching the logo outline", steps: [])),
            .init(0.5, .begin(drawStroke())),
            .init(0.6, .pointer(to: strokeCurve[0], over: 0.5, by: .agent)),
            .init(1.1, .trace(strokeCurve, over: 3.0, by: .agent)),
            .init(1.1, .desktop(.stroke(strokeCurve), over: 3.0)),
            .init(4.4, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "hardwareInput", "pixelDelta": 0.08,
                "humanInput": hardwareClean, "attribution": "agent",
            ])),
            .init(5.5, .endHold("Drew the logo outline")),
        ],
    )

    static let consent = ShowcaseScene(
        number: 9, slug: "consent-prompt",
        title: "Asking first",
        caption: "Bringing Safari forward would take your focus, so the panel grows to ask, once. Holding Y for a second approves (a tap does nothing); only then does the hands-off click run.",
        duration: 6.8, keyMoments: [0.8, 1.6, 2.2, 3.2, 4.4],
        initial: MockDesktopState(windows: [.safari, .notes], email: "alex@example.com", passwordLength: 13),
        events: [
            .init(0.2, .hold(goal: "Signing in to Example", steps: [])),
            .init(0.3, .begin(clickSignIn(hands: true, done: true))),
            .init(0.4, .consent("Bring Safari to the front and click “Sign In”")),
            .init(1.0, .consentHold(.approve, over: 1.0)),
            .init(2.0, .consentResolve(.approve)),
            .init(2.0, .desktop(.focus(.safari), over: 0)),
            .init(2.1, .pointer(to: MockLayout.signInButton.center, over: 0.7, by: .agent)),
            .init(2.8, .charge(MockLayout.signInButton.center, 0.6)),
            .init(3.4, .ripple(MockLayout.signInButton.center)),
            .init(3.4, .desktop(.pressSignIn, over: 0.3)),
            .init(3.7, .desktop(.signedIn, over: 0)),
            .init(3.9, .finish(welcomed.merging(["tentacle": "hardwareInput", "consent": "approved"]) { $1 })),
        ],
    )

    static let thinkingThenDone = ShowcaseScene(
        number: 10, slug: "thinking-done-gone",
        title: "Thinking, done, gone",
        caption: "Between commands the agent is thinking, and the pill keeps the session clock running. Nothing ends the session but the agent: busy off turns it Done for two seconds, then the panel fades — no panel means nothing more is coming.",
        duration: 11, keyMoments: [1.0, 3.0, 7.5, 8.6, 10.3],
        initial: MockDesktopState(windows: [.safari, .notes], notesText: notes),
        events: [
            .init(0.2, .hold(goal: "Filing today’s grocery list", steps: ["Title the note", "Move it to the Archive folder"])),
            .init(0.6, .begin(PanelAction(verb: "type", app: "Notes", label: "Title", text: "Groceries — Oct 7", cursorTaking: false))),
            .init(1.3, .desktop(.notesTitle("Groceries — Oct 7"), over: 0)),
            .init(1.4, .finish(["ok": true, "verdict": "confirmed", "readback": "Groceries — Oct 7"])),
            .init(1.8, .step(2)),
            .init(2.0, .begin(PanelAction(verb: "menu", app: "Notes", menuPath: "Note > Move To > Archive", cursorTaking: false))),
            .init(2.6, .finish(["ok": true, "verdict": "confirmed", "menuItem": "Note > Move To > Archive"])),
            .init(8.0, .endHold(nil)),
        ],
    )

    static let planBatch = ShowcaseScene(
        number: 11, slug: "plan-batch",
        title: "A plan, start to finish",
        caption: "A known sequence sent as one plan: the panel takes its steps, runs them back to back with no thinking between, and ends Done the moment the last one lands.",
        duration: 5, keyMoments: [0.6, 1.1, 1.7, 2.6],
        initial: signedOut,
        events: [
            .init(0.2, .plan(["Type the email", "Type the password", "Tick “Remember me”", "Sign in"])),
            .init(0.25, .expand(true)),
            .init(0.4, .step(1)),
            .init(0.4, .begin(typeEmail())),
            .init(0.45, .desktop(.email("alex@example.com"), over: 0.3)),
            .init(0.8, .finish(emailTyped)),
            .init(0.85, .step(2)),
            .init(0.85, .begin(typePassword())),
            .init(0.9, .desktop(.password(13), over: 0.3)),
            .init(1.25, .finish(passwordTyped)),
            .init(1.3, .step(3)),
            .init(1.3, .begin(PanelAction(verb: "click", app: "Safari", label: "Remember me", cursorTaking: false))),
            .init(1.45, .ripple(MockLayout.rememberBox.center)),
            .init(1.45, .desktop(.remember(true), over: 0)),
            .init(1.55, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "value changed: AXCheckBox 'Remember me': 'off' → 'on'",
            ])),
            .init(1.6, .step(4)),
            .init(1.6, .begin(clickSignIn(hands: false))),
            .init(1.8, .ripple(MockLayout.signInButton.center)),
            .init(1.8, .desktop(.pressSignIn, over: 0.2)),
            .init(1.95, .desktop(.signedIn, over: 0)),
            .init(2.05, .finish(welcomed)),
            .init(2.05, .planEnd(nil)),
        ],
    )

    static let releasingTheScreen = ShowcaseScene(
        number: 12, slug: "busy-wait-releases-the-screen",
        title: "Waiting on something that isn't the screen",
        caption: "busy wait --for \"the build\" means the agent is not using the UI, so the panel gets out of the way entirely. It comes back with the next step.",
        duration: 16.2, keyMoments: [1.0, 1.9, 6.0, 12.8, 13.8],
        initial: MockDesktopState(
            windows: [.notes, .terminal],
            terminalLines: ["alex@mac rocuronium % xcodebuild build -scheme Rocuronium"],
        ),
        events: [
            .init(0.2, .hold(goal: "Building and testing Rocuronium", steps: ["Start the build", "Run the tests", "Report the results"])),
            .init(0.5, .begin(PanelAction(verb: "key", app: "Terminal", keys: "return", cursorTaking: false))),
            .init(1.1, .finish(["ok": true, "verdict": "unverifiable", "tentacle": "postedEvents"])),
            .init(1.2, .desktop(.terminal("Resolving package graph… done"), over: 0)),
            .init(1.6, .busyWait("the build", seconds: 12)),
            .init(1.8, .desktop(.terminal("Compiling Rocuronium (412 files)"), over: 0)),
            .init(1.9, .desktop(.build(from: 0, to: 1), over: 10.5)),
            .init(12.4, .desktop(.buildDone, over: 0)),
            .init(12.4, .desktop(.terminal("** BUILD SUCCEEDED ** [10.5 s]"), over: 0)),
            .init(12.6, .step(2)),
            .init(12.9, .begin(PanelAction(verb: "type", app: "Terminal", text: "make test", cursorTaking: false, endsSession: true))),
            .init(13.0, .desktop(.terminal("alex@mac rocuronium % make test"), over: 0)),
            .init(13.4, .finish(["ok": true, "verdict": "confirmed", "readback": "make test"])),
        ],
    )
}
