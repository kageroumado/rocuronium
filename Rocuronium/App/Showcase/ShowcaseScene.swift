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
        case wait(String, seconds: TimeInterval?)
        case endHold(String?)
        case charge(CGPoint, TimeInterval)
        case ripple(CGPoint)
        case consent(prompt: String, detail: String)
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
/// (text appearing letter by letter, a progress bar filling).
enum DesktopChange {
    case focus(MockWindowID)
    case email(String)
    case password(Int)
    case remember(Bool)
    case pressSignIn
    case signedIn
    case notesTitle(String)
    case humanTypesNotes(String)
    case humanClick
    case terminal(String)
    case build(from: Double, to: Double)
    case buildDone
    case stroke([CGPoint])
    case parkNotes

    func apply(to state: inout MockDesktopState, progress: Double) {
        switch self {
        case let .focus(id):
            state.windows.removeAll { $0 == id }
            state.windows.append(id)
        case let .email(text):
            state.email = String(text.prefix(Int((Double(text.count) * progress).rounded())))
        case let .password(count):
            state.passwordLength = Int((Double(count) * progress).rounded())
        case let .remember(on):
            state.remember = on
        case .pressSignIn:
            state.signInPress = sin(progress * .pi)
        case .signedIn:
            state.signedIn = true
        case let .notesTitle(title):
            state.notesTitle = title
        case let .humanTypesNotes(text):
            state.notesText = String(text.prefix(Int((Double(text.count) * progress).rounded())))
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
        case .parkNotes:
            state.notesParked = progress * progress * (3 - 2 * progress)
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
            case let .wait(what, seconds): model.beginWait(what: what, seconds: seconds, at: now)
            case let .endHold(result): model.endHold(result: result, at: now)
            case let .charge(point, duration): model.charge(at: point, duration: duration, now: now)
            case let .ripple(point): model.addRipple(at: point, now: now)
            case let .consent(prompt, detail): model.presentConsent(prompt: prompt, detail: detail, at: now)
            case let .consentHold(answer, over):
                model.consentHold = (answer, min(1, (t - event.at) / over))
            case let .consentResolve(answer):
                model.consent = model.consent ?? OverlayModel.ConsentRequest(prompt: "", detail: "")
                model.resolveConsent(answer, at: now)
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
    func pointer(at t: TimeInterval) -> (point: CGPoint, actor: PointerActor) {
        var point = initial.pointer
        var actor = initial.pointerActor
        for event in events where event.at <= t {
            guard case let .pointer(target, over, by) = event.kind else { continue }
            let raw = over > 0 ? min(1, (t - event.at) / over) : 1
            let eased = raw * raw * (3 - 2 * raw)
            point = CGPoint(x: point.x + (target.x - point.x) * eased, y: point.y + (target.y - point.y) * eased)
            actor = by
        }
        return (point, actor)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - The ten scenes

extension ShowcaseScene {
    static let all: [ShowcaseScene] = [
        ghostWhileTyping, multiStep, handsOffClick, handsOffInterrupted, mayBeYours,
        waitingOnBuild, parking, drawingPath, consent, doneAndGone,
    ]

    private static let safariSignedOut = MockDesktopState(windows: [.notes, .safari])
    private static let notes = "Groceries for the week:\n– oat milk\n– eggs\n– coffee beans\n– lemons, two"

    static let ghostWhileTyping = ShowcaseScene(
        number: 1, slug: "ghost-click-while-typing",
        title: "Background work while you type",
        caption: "The agent fills Safari's sign-in form with ghost input while you keep typing in Notes. The chip stays green — Background · keep working — and line 3 says what each action did.",
        duration: 8.5, keyMoments: [1.2, 2.6, 3.9, 5.0, 7.0],
        initial: MockDesktopState(windows: [.safari, .notes]),
        events: [
            .init(0.2, .desktop(.humanTypesNotes(notes), over: 7.5)),
            .init(0.6, .begin(PanelAction(verb: "type", app: "Safari", label: "Email", text: "kiri@example.com", why: nil, cursorTaking: false))),
            .init(0.7, .desktop(.email("kiri@example.com"), over: 1.0)),
            .init(1.9, .finish(["ok": true, "verdict": "confirmed", "tentacle": "accessibility", "readback": "kiri@example.com"])),
            .init(3.4, .begin(PanelAction(verb: "click", app: "Safari", label: "Remember me", cursorTaking: false))),
            .init(4.0, .ripple(MockLayout.rememberBox.center)),
            .init(4.0, .desktop(.remember(true), over: 0)),
            .init(4.2, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "postedEvents",
                "treeDelta": "value changed: AXCheckBox 'Remember me': 'off' → 'on'",
            ])),
        ],
    )

    static let multiStep = ShowcaseScene(
        number: 2, slug: "multi-step-goal",
        title: "A goal with steps",
        caption: "The agent declares its goal and four steps. Line 1 is the goal, line 2 says which step it is on and what it is doing, and the chevron opens the step list. A password is typed without ever being shown.",
        duration: 11.5, keyMoments: [1.3, 3.3, 5.0, 7.5, 9.5],
        initial: safariSignedOut,
        events: [
            .init(0.2, .hold(goal: "Signing in to Example with the test account", steps: [
                "Open the sign-in form", "Type the credentials", "Submit", "Check the dashboard loads",
            ])),
            .init(0.7, .expand(true)),
            .init(1.0, .begin(PanelAction(verb: "click", app: "Safari", label: "Sign in", cursorTaking: false))),
            .init(1.3, .ripple(MockLayout.signInLink.center)),
            .init(1.6, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "appeared: AXTextField 'Email'\nappeared: AXSecureTextField 'Password'",
            ])),
            .init(2.4, .step(nil)),
            .init(2.8, .begin(PanelAction(verb: "type", app: "Safari", label: "Email", text: "kiri@example.com", cursorTaking: false))),
            .init(2.9, .desktop(.email("kiri@example.com"), over: 0.9)),
            .init(3.9, .finish(["ok": true, "verdict": "confirmed", "readback": "kiri@example.com"])),
            .init(4.5, .begin(PanelAction(verb: "type", app: "Safari", label: "Password", text: "correct horse", secure: true, cursorTaking: false))),
            .init(4.6, .desktop(.password(13), over: 0.8)),
            .init(5.5, .finish(["ok": true, "verdict": "confirmed", "readback": "•••••••••••••"])),
            .init(6.2, .step(nil)),
            .init(6.5, .begin(PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: false))),
            .init(7.0, .ripple(MockLayout.signInButton.center)),
            .init(7.1, .desktop(.signedIn, over: 0)),
            .init(7.2, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "appeared: AXStaticText 'Welcome back, Kiri'\nvanished: AXButton 'Sign In'",
            ])),
            .init(8.0, .step(nil)),
            .init(9.0, .endHold(nil)),
        ],
    )

    static let handsOffClick = ShowcaseScene(
        number: 3, slug: "hands-off-click",
        title: "Hands off: a hardware click",
        caption: "This click needs the real mouse. The panel turns amber and says so before the pointer moves; a thin amber border frames the screen, the jellyfish escorts the pointer, and the sigil charges for 0.6 s — the window to grab the mouse back. Everything returns to normal the moment the click is checked.",
        duration: 7.5, keyMoments: [1.2, 2.0, 2.45, 3.3, 5.0],
        initial: MockDesktopState(windows: [.notes, .safari], email: "kiri@example.com", passwordLength: 13),
        events: [
            .init(0.2, .hold(goal: "Submitting the sign-in form", steps: [])),
            .init(0.8, .begin(PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: true))),
            .init(0.9, .pointer(to: MockLayout.signInButton.center, over: 0.8, by: .agent)),
            .init(1.7, .charge(MockLayout.signInButton.center, 0.6)),
            .init(2.3, .ripple(MockLayout.signInButton.center)),
            .init(2.3, .desktop(.pressSignIn, over: 0.3)),
            .init(2.6, .desktop(.signedIn, over: 0)),
            .init(2.9, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "hardwareInput", "cursorMovedByUs": true,
                "element": ["role": "AXButton", "label": "Sign In"],
                "treeDelta": "appeared: AXStaticText 'Welcome back, Kiri'",
                "humanInput": ["monitored": true, "stopped": false],
                "attribution": "agent",
            ])),
            .init(4.5, .endHold(nil)),
        ],
    )

    static let handsOffInterrupted = ShowcaseScene(
        number: 4, slug: "hands-off-interrupted",
        title: "Hands off, interrupted",
        caption: "Mid-move, the human nudges the mouse. Any untagged input during a hands-off action stops the rest of it, and line 3 says exactly that — the agent's reply carries it too, so it doesn't retry blindly.",
        duration: 5.5, keyMoments: [1.2, 1.6, 2.2, 4.4],
        initial: MockDesktopState(windows: [.notes, .safari], email: "kiri@example.com", passwordLength: 13),
        events: [
            .init(0.5, .begin(PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: true))),
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
        ],
    )

    static let mayBeYours = ShowcaseScene(
        number: 5, slug: "change-may-be-yours",
        title: "When the change may be yours",
        caption: "A ghost click on “Remember me” while the human clicks the same checkbox. The checkbox did change — but the panel will not claim it: the human's click landed in Safari during the check, so the result is flagged, and the agent's reply says attribution: mixed.",
        duration: 6, keyMoments: [1.0, 1.75, 2.6, 4.0],
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
        ],
    )

    static let waitingOnBuild = ShowcaseScene(
        number: 6, slug: "waiting-on-a-build",
        title: "Waiting, with a countdown",
        caption: "The agent starts a build and declares what it is waiting for and roughly how long. The chip counts against the estimate and fills as it goes; the next acting command ends the wait.",
        duration: 14.5, keyMoments: [1.0, 4.0, 9.0, 13.4],
        initial: MockDesktopState(
            windows: [.notes, .terminal],
            terminalLines: ["kiri@studio rocuronium % xcodebuild test -scheme Rocuronium"],
        ),
        events: [
            .init(0.2, .hold(goal: "Building and testing Rocuronium", steps: ["Build the app", "Run the tests", "Report the results"])),
            .init(0.5, .begin(PanelAction(verb: "key", app: "Terminal", keys: "return", cursorTaking: false))),
            .init(1.1, .finish(["ok": true, "verdict": "unverifiable", "tentacle": "postedEvents"])),
            .init(1.2, .desktop(.terminal("Resolving package graph… done"), over: 0)),
            .init(1.6, .wait("the build to finish", seconds: 20)),
            .init(1.8, .desktop(.terminal("Compiling Rocuronium (412 files)"), over: 0)),
            .init(1.9, .desktop(.build(from: 0, to: 1), over: 10.5)),
            .init(12.4, .desktop(.buildDone, over: 0)),
            .init(12.4, .desktop(.terminal("** BUILD SUCCEEDED ** [10.5 s]"), over: 0)),
            .init(12.6, .step(2)),
            .init(12.8, .begin(PanelAction(verb: "key", app: "Terminal", keys: "cmd+k", cursorTaking: false))),
            .init(13.2, .finish(["ok": true, "verdict": "unverifiable"])),
        ],
    )

    static let parking = ShowcaseScene(
        number: 7, slug: "parking-on-the-virtual-display",
        title: "Parking a window off-screen",
        caption: "The agent moves Notes to the virtual display — a screen only it can see — and keeps working there. The mini-map at bottom-right shows both displays; your own screen is left alone.",
        duration: 7, keyMoments: [1.2, 2.4, 4.0, 5.2],
        initial: MockDesktopState(windows: [.notes, .safari], notesText: notes),
        events: [
            .init(0.5, .begin(PanelAction(verb: "park", app: "Notes", cursorTaking: false))),
            .init(0.8, .desktop(.parkNotes, over: 1.0)),
            .init(2.0, .finish(["ok": true, "summary": "parked 'Notes' on the virtual display"])),
            .init(3.0, .begin(PanelAction(verb: "click", app: "Notes", label: "Done", cursorTaking: false))),
            .init(3.6, .finish([
                "ok": true, "verdict": "confirmed",
                "treeDelta": "value changed: AXButton 'Done': 'Done' → 'Saved'",
            ])),
        ],
    )

    static let strokePoints: [CGPoint] = (0 ... 23).map { index in
        let t = Double(index) / 23
        let angle = t * 2 * .pi
        // A wide figure-eight across the canvas: a logo-ish loop.
        return CGPoint(x: 550 + 230 * sin(angle), y: 320 + 110 * sin(2 * angle))
    }

    static let drawingPath = ShowcaseScene(
        number: 8, slug: "drawing-a-path",
        title: "Drawing with drag --via",
        caption: "A hands-off drag through 24 points. The pointer is the agent's for three seconds, so the panel and the screen edge say so, and the line names the stroke rather than a click.",
        duration: 8.5, keyMoments: [0.8, 2.2, 3.6, 4.6, 6.0],
        initial: MockDesktopState(windows: [.notes, .sketch]),
        events: [
            .init(0.2, .hold(goal: "Sketching the logo outline", steps: [])),
            .init(0.5, .begin(PanelAction(verb: "drag", app: "Freeform", cursorTaking: true, strokePoints: 24))),
            .init(0.6, .pointer(to: strokePoints[0], over: 0.5, by: .agent)),
        ] + strokePoints.enumerated().dropFirst().map { index, point in
            .init(1.1 + Double(index - 1) * 0.13, .pointer(to: point, over: 0.13, by: .agent))
        } + [
            .init(1.1, .desktop(.stroke(strokePoints), over: 23 * 0.13)),
            .init(4.4, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "hardwareInput", "pixelDelta": 0.08,
                "humanInput": ["monitored": true, "stopped": false], "attribution": "agent",
            ])),
            .init(5.5, .endHold("Drew the logo outline")),
        ],
    )

    static let consent = ShowcaseScene(
        number: 9, slug: "consent-prompt",
        title: "Asking first",
        caption: "Bringing Safari forward would take your focus, so the panel asks. Holding Y for a second approves (a tap does nothing); only then does the hands-off click run.",
        duration: 7, keyMoments: [0.8, 1.6, 2.2, 3.2, 4.4],
        initial: MockDesktopState(windows: [.safari, .notes], email: "kiri@example.com", passwordLength: 13),
        events: [
            .init(0.3, .begin(PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: true))),
            .init(0.4, .consent(prompt: "Bring Safari to the front and click “Sign In”", detail: "Safari · click")),
            .init(1.0, .consentHold(.approve, over: 1.0)),
            .init(2.0, .consentResolve(.approve)),
            .init(2.0, .desktop(.focus(.safari), over: 0)),
            .init(2.1, .pointer(to: MockLayout.signInButton.center, over: 0.7, by: .agent)),
            .init(2.8, .charge(MockLayout.signInButton.center, 0.6)),
            .init(3.4, .ripple(MockLayout.signInButton.center)),
            .init(3.4, .desktop(.pressSignIn, over: 0.3)),
            .init(3.7, .desktop(.signedIn, over: 0)),
            .init(3.9, .finish([
                "ok": true, "verdict": "confirmed", "tentacle": "hardwareInput", "consent": "approved",
                "treeDelta": "appeared: AXStaticText 'Welcome back, Kiri'",
            ])),
        ],
    )

    static let doneAndGone = ShowcaseScene(
        number: 10, slug: "done-then-gone",
        title: "Thinking, done, gone",
        caption: "Between commands the agent is thinking, and the panel says so after four quiet seconds. When the agent ends its hold the panel shows a two-second summary and fades: no panel means nothing more is coming.",
        duration: 11.5, keyMoments: [1.0, 3.0, 7.5, 8.6, 10.3, 11.0],
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
}
