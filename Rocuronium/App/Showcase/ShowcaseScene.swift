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
            let count = from + Int((Double(text.count - from) * progress).rounded())
            state.notesText = String(text.prefix(count))
            state.humanTyping = progress < 1
        case .humanClick:
            state.humanClick = progress < 1 ? progress : 0
        case let .terminal(line):
            state.terminalLines.append(line)
        case let .build(from, to):
            state.buildProgress = from + (to - from) * progress
        case .buildDone:
            state.buildProgress = nil
        case let .stroke(points):
            let count = Int((Double(points.count) * progress).rounded())
            state.stroke = Array(points.prefix(max(0, count)))
        case let .park(id):
            state.parked[id] = Self.ease(progress)
        }
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
    }

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
            case .pointer: break
            case let .desktop(change, over):
                change.apply(to: &desktop, progress: over > 0 ? min(1, (t - event.at) / over) : 1)
            }
        }
        let pointer = pointer(at: t)
        desktop.pointer = pointer.point
        desktop.pointerActor = pointer.actor
        desktop.humanHandRecent = humanMovedPointer(near: t) || desktop.humanClick > 0
        return (model, desktop)
    }

    /// The human moved the pointer within the last beat — the frame tags it as theirs.
    private func humanMovedPointer(near t: TimeInterval) -> Bool {
        events.contains { event in
            guard case let .pointer(_, over, by) = event.kind, by == .human else { return false }
            return event.at <= t && t <= event.at + over + 1.0
        }
    }

    /// Where the pointer is at `t` and who moved it last, eased between scripted positions.
    /// The agent's longer moves bow slightly to one side, as a hand's do.
    func pointer(at t: TimeInterval) -> (point: CGPoint, actor: PointerActor) {
        var point = initial.pointer
        var actor = initial.pointerActor
        for event in events where event.at <= t {
            guard case let .pointer(target, over, by) = event.kind else { continue }
            let raw = over > 0 ? min(1, (t - event.at) / over) : 1
            let eased = raw * raw * (3 - 2 * raw)
            var next = CGPoint(x: point.x + (target.x - point.x) * eased, y: point.y + (target.y - point.y) * eased)
            if over >= Constants.arcMinimumDuration {
                let dx = target.x - point.x, dy = target.y - point.y
                let bulge = Constants.arcBulge * sin(eased * .pi)
                next.x -= dy * bulge
                next.y += dx * bulge
            }
            point = next
            actor = by
        }
        return (point, actor)
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
    private static let filledIn = MockDesktopState(windows: [.notes, .safari], email: "kiri@example.com", passwordLength: 13)

    // MARK: Actions the scenes repeat

    private static func typeEmail(hands: Bool = false) -> PanelAction {
        PanelAction(verb: "type", app: "Safari", label: "Email", text: "kiri@example.com", cursorTaking: hands)
    }

    private static func typePassword() -> PanelAction {
        PanelAction(verb: "type", app: "Safari", label: "Password", text: "correct horse", secure: true, cursorTaking: false)
    }

    private static func clickSignIn(hands: Bool, done: Bool = false) -> PanelAction {
        PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: hands, endsSession: done)
    }

    private static let emailTyped: [String: Any] = [
        "ok": true, "verdict": "confirmed", "tentacle": "accessibility", "readback": "kiri@example.com",
    ]
    private static let passwordTyped: [String: Any] = ["ok": true, "verdict": "confirmed", "readback": "•••••••••••••"]
    private static let welcomed: [String: Any] = [
        "ok": true, "verdict": "confirmed",
        "element": ["role": "AXButton", "label": "Sign In"],
        "treeDelta": "appeared: AXStaticText 'Welcome back, Kiri'\nvanished: AXButton 'Sign In'",
    ]
    private static let hardwareClean: [String: Any] = ["monitored": true, "stopped": false]

    static let strokePoints: [CGPoint] = (0 ... 23).map { index in
        let t = Double(index) / 23
        let angle = t * 2 * .pi
        // A wide figure-eight across the canvas: a logo-ish loop.
        return CGPoint(x: 550 + 230 * sin(angle), y: 320 + 110 * sin(2 * angle))
    }

    /// The pointer walking a stroke's points, one segment every `step` seconds from `start`.
    private static func strokeWalk(from start: TimeInterval, step: TimeInterval) -> [ShowcaseEvent] {
        strokePoints.enumerated().dropFirst().map { index, point in
            .init(start + Double(index - 1) * step, .pointer(to: point, over: step, by: .agent))
        }
    }

    // MARK: 0 — the hero clip

    static let hero = ShowcaseScene(
        number: 0, slug: "hero",
        title: "The whole range in ten seconds",
        caption: "Ghost typing while you write in Notes, a hands-off click with the amber frame and the escort, Safari parked on the virtual display, a stroke drawn in Freeform, a beat of thinking, then --done.",
        duration: 11, keyMoments: [0.8, 1.6, 2.5, 3.0, 4.2, 5.2, 6.2, 7.3, 8.6, 10.5],
        initial: MockDesktopState(windows: [.safari, .notes]),
        events: [
            .init(0.1, .hold(goal: "Getting the launch demo ready", steps: [
                "Fill in the sign-in form", "Sign in", "Clear Safari off the screen", "Sketch the logo",
            ])),
            .init(0.2, .desktop(.humanTypes(String(notes.prefix(34)), from: 0), over: 1.8)),
            .init(0.35, .begin(typeEmail())),
            .init(0.4, .desktop(.email("kiri@example.com"), over: 0.6)),
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
            .init(4.95, .begin(PanelAction(verb: "drag", app: "Freeform", cursorTaking: true, strokePoints: 24))),
            .init(5.0, .pointer(to: strokePoints[0], over: 0.35, by: .agent)),
        ] + strokeWalk(from: 5.35, step: 0.065) + [
            .init(5.35, .desktop(.stroke(strokePoints), over: 23 * 0.065)),
            .init(6.95, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "hardwareInput", "pixelDelta": 0.08,
                "humanInput": hardwareClean, "attribution": "agent",
            ])),
            .init(7.85, .begin(PanelAction(verb: "shortcut", app: "Freeform", keys: "cmd+s", cursorTaking: false, endsSession: true))),
            .init(8.2, .finish(["ok": true, "verdict": "confirmed", "menuItem": "File > Save"])),
        ],
    )

    // MARK: 1–12

    static let ghostWhileTyping = ShowcaseScene(
        number: 1, slug: "ghost-while-typing",
        title: "Background work while you type",
        caption: "Ghost input fills Safari's form while you keep typing in Notes. Between actions the pill says Thinking and counts the pause; the last action carries --done, so the panel goes to Done and fades.",
        duration: 8.2, keyMoments: [1.2, 2.6, 3.9, 4.7, 6.0, 7.5],
        initial: MockDesktopState(windows: [.safari, .notes]),
        events: [
            .init(0.2, .desktop(.humanTypes(notes, from: 0), over: 7.5)),
            .init(0.6, .begin(typeEmail())),
            .init(0.7, .desktop(.email("kiri@example.com"), over: 1.0)),
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
            .init(2.9, .desktop(.email("kiri@example.com"), over: 0.9)),
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
        caption: "This click needs the real mouse. The panel turns amber before the pointer moves; an amber border frames the screen, the jellyfish escorts the pointer, and the ring charges for 0.6 s — the window to grab the mouse back. The click carries --done.",
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
        caption: "Mid-move, you nudge the mouse. Your input stops the rest of the action and the panel holds in Stopped — no fade, no snap back — until the agent's next command. Here it retries with a ghost click that needs no mouse.",
        duration: 9.4, keyMoments: [1.2, 1.7, 4.5, 6.2, 7.2],
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
        caption: "A ghost click on “Remember me” while you click the same checkbox. The checkbox did change, but your click landed in Safari during the check, so the panel does not count it — and the agent's reply says attribution: mixed.",
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
        caption: "A hands-off drag through 24 points: the pointer is the agent's for three seconds, so the panel and the screen edge say so. Then a beat of thinking, and busy off --result ends it.",
        duration: 8.4, keyMoments: [0.8, 2.2, 3.6, 4.9, 6.0],
        initial: MockDesktopState(windows: [.notes, .sketch]),
        events: [
            .init(0.2, .hold(goal: "Sketching the logo outline", steps: [])),
            .init(0.5, .begin(PanelAction(verb: "drag", app: "Freeform", cursorTaking: true, strokePoints: 24))),
            .init(0.6, .pointer(to: strokePoints[0], over: 0.5, by: .agent)),
        ] + strokeWalk(from: 1.1, step: 0.13) + [
            .init(1.1, .desktop(.stroke(strokePoints), over: 23 * 0.13)),
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
        initial: MockDesktopState(windows: [.safari, .notes], email: "kiri@example.com", passwordLength: 13),
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
        caption: "Between commands the agent is thinking, and the pill counts how long. Nothing ends the session but the agent: busy off turns it Done for two seconds, then the panel fades — no panel means nothing more is coming.",
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
            .init(0.45, .desktop(.email("kiri@example.com"), over: 0.3)),
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
            terminalLines: ["kiri@studio rocuronium % xcodebuild build -scheme Rocuronium"],
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
            .init(13.0, .desktop(.terminal("kiri@studio rocuronium % make test"), over: 0)),
            .init(13.4, .finish(["ok": true, "verdict": "confirmed", "readback": "make test"])),
        ],
    )
}
