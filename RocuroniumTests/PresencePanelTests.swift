import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Rocuronium

/// The panel's words, from requests and replies shaped like the router's.
struct PanelTextTests {
    private func action(_ verb: String, app: String? = "Safari", label: String? = nil, text: String? = nil,
                        secure: Bool = false, keys: String? = nil, menu: String? = nil,
                        hands: Bool = false) -> PanelAction {
        PanelAction(verb: verb, app: app, label: label, text: text, secure: secure, keys: keys, menuPath: menu, cursorTaking: hands)
    }

    @Test func actionPhrases() {
        #expect(PanelText.actionLine(for: action("click", label: "Sign In")) == "Clicking “Sign In”")
        #expect(PanelText.actionLine(
            for: action("click", label: "Sign In"),
            resolved: .init(role: "AXButton", label: "Sign In"),
        ) == "Clicking the “Sign In” button")
        var point = action("click")
        point.point = CGPoint(x: 640, y: 412)
        #expect(PanelText.actionLine(for: point) == "Clicking at 640, 412 in Safari")
        #expect(PanelText.actionLine(for: action("key", app: "Finder", keys: "escape")) == "Pressing Escape in Finder")
        #expect(PanelText.actionLine(for: action("key", app: "Ghostty", keys: "cmd+=")) == "Pressing ⌘= in Ghostty")
        #expect(PanelText.actionLine(for: action("menu", app: "Ghostty", menu: "View > Increase Font Size"))
            == "Choosing View ▸ Increase Font Size in Ghostty")
        #expect(PanelText.actionLine(for: action("launch", app: "Ghostty")) == "Opening Ghostty")
        #expect(PanelText.actionLine(for: action("activate", app: "Discord")) == "Bringing Discord to the front")
        #expect(PanelText.actionLine(for: action("park", app: "Ghostty")) == "Moving Ghostty to the virtual display")
        var stroke = action("drag")
        stroke.strokePoints = 24
        #expect(PanelText.actionLine(for: stroke) == "Drawing a stroke")
        #expect(PanelText.outcome(for: ["verdict": "confirmed", "pixelDelta": 0.08], action: stroke)?.text
            == "Drew a stroke · ✓ the line shows on screen")
        var scroll = action("scroll")
        scroll.untilText = "Terms"
        #expect(PanelText.actionLine(for: scroll) == "Scrolling until “Terms” is visible")
        scroll.untilText = nil
        scroll.direction = "bottom"
        #expect(PanelText.actionLine(for: scroll) == "Scrolling Safari to the bottom")
    }

    @Test func waitNamesWhatAndForHowLong() {
        var wait = action("wait", label: "Dashboard")
        wait.timeout = 25
        #expect(PanelText.waitLine(for: wait) == "Waiting for “Dashboard” to appear · up to 0:25")
        wait.gone = true
        #expect(PanelText.actionLine(for: wait) == "Waiting for “Dashboard” to go away")
    }

    /// The engine cannot know a field is secure before typing, so typed text never appears.
    @Test func typedTextIsNeverEchoed() {
        let line = PanelText.actionLine(for: action("type", label: "Email", text: "alex@example.com"))
        #expect(line == "Typing into “Email”")
        #expect(!line.contains("alex"))
        #expect(PanelText.actionLine(for: action("type", app: "Terminal", text: "ls")) == "Typing into Terminal")
        #expect(PanelText.actionLine(for: action("type", label: "Password", text: "hunter2", secure: true))
            == "Typing a password into “Password” (hidden)")
    }

    @Test func handsOffNamesTheHand() {
        #expect(PanelText.handsOffLine(for: action("click", label: "Sign In", hands: true))
            == "Using your mouse to click “Sign In”")
        #expect(PanelText.handsOffLine(for: action("type", app: "Terminal", text: "ls", hands: true))
            == "Typing with your keyboard into Terminal")
        #expect(PanelText.handsOffLine(for: action("key", app: "Ghostty", keys: "cmd+=", hands: true))
            == "Using your keyboard to press ⌘= in Ghostty")
    }

    /// The outcome replaces the action phrase: past tense, then what was observed.
    @Test func outcomes() {
        let type = action("type", label: "Email", text: "alex@example.com")
        #expect(PanelText.outcome(for: ["verdict": "confirmed", "readback": "alex@example.com"], action: type)?.text
            == "Typed into “Email” · ✓ reads alex@example.com")
        let click = action("click", label: "Sign In")
        #expect(PanelText.outcome(for: [
            "verdict": "confirmed",
            "treeDelta": "value changed: AXStaticText 'count': 'clicks: 0' → 'clicks: 1'\nappeared: AXSheet 'Save'\n…and 2 more change(s)",
        ], action: click)?.text == "Clicked “Sign In” · ✓ “clicks: 0” → “clicks: 1” (+3 more)")
        #expect(PanelText.outcome(for: ["verdict": "confirmed", "readback": "the target's on-screen window count changed 1 → 2"], action: click)?.text
            == "Clicked “Sign In” · ✓ a new window opened")
        #expect(PanelText.outcome(for: ["verdict": "confirmed", "menuItem": "View > Increase Font Size"], action: action("menu", app: "Ghostty", menu: "View > Increase Font Size"))?.text
            == "✓ Chose View ▸ Increase Font Size in Ghostty")
        #expect(PanelText.outcome(for: ["verdict": "confirmed", "pixelDelta": 0.1], action: click)?.text
            == "Clicked “Sign In” · ✓ 10% of it redrew")
        #expect(PanelText.outcome(for: ["verdict": "noEffect"], action: click)?.text == "Clicked “Sign In” · ✗ nothing changed")
        #expect(PanelText.outcome(for: ["verdict": "unverifiable"], action: click)?.text == "Clicked “Sign In” · ? Safari can’t confirm it")
        #expect(PanelText.outcome(for: ["error": "No element matched 'Sign In'."], action: click)?.text
            == "✗ Couldn’t find “Sign In” in Safari")
        #expect(PanelText.outcome(for: ["error": "'Notes' covers the target app at (1, 2) — the hover would land on it instead."], action: click)?.text
            == "Didn’t click “Sign In” · ✗ Notes was covering it")
        #expect(PanelText.outcome(for: ["error": "the click was declined by the human"], action: click)?.text
            == "Didn’t click “Sign In” · you declined")
        var wait = action("wait", label: "Dashboard")
        wait.timeout = 25
        #expect(PanelText.outcome(for: ["ok": true, "satisfied": true, "elapsedSeconds": 2.6], action: wait)?.text
            == "Waited for “Dashboard” · ✓ appeared after 2.6 s")
        #expect(PanelText.outcome(for: ["ok": false, "satisfied": false], action: wait)?.text
            == "Waited for “Dashboard” · ✗ not yet after 0:25")
    }

    @Test func stoppedSaysWhatTheHumanDidAndWhatItCost() {
        let click = action("click", label: "Sign In", hands: true)
        let moved: [String: Any] = ["humanInput": [
            "monitored": true, "stopped": true,
            "events": [["kind": "pointerMotion", "inTarget": false, "atMs": 300]],
        ]]
        #expect(PanelText.stopped(for: moved, action: click) == "You moved the mouse — the click didn’t happen")
        let typing: [String: Any] = [
            "humanInput": ["monitored": true, "stopped": true, "events": [["kind": "keyDown", "inTarget": true, "atMs": 300]]],
            "attempts": [["tentacle": "hardwareInput", "outcome": "typing stopped after 12 of 40 characters — the human used the mouse or keyboard"]],
        ]
        #expect(PanelText.stopped(for: typing, action: action("type", label: "Notes", hands: true))
            == "You pressed a key — typing stopped after 12 of 40 characters")
        #expect(PanelText.stopped(for: ["verdict": "confirmed"], action: click) == nil)
    }

    @Test func notCountedNamesWhatTheHumanDid() {
        let click = action("click", label: "Sign In")
        let clicked: [String: Any] = [
            "verdict": "confirmed", "attribution": "mixed",
            "humanInput": ["monitored": true, "stopped": false, "events": [["kind": "mouseDown", "inTarget": true, "atMs": 10]]],
        ]
        let outcome = PanelText.outcome(for: clicked, action: click)
        #expect(outcome?.text == "◐ Not counted — you clicked in Safari during the check")
        #expect(outcome?.result.kind == .notCounted)
        let typed: [String: Any] = [
            "verdict": "confirmed", "attribution": "mixed",
            "humanInput": ["monitored": true, "stopped": false, "events": [["kind": "keyDown", "inTarget": true, "atMs": 10]]],
        ]
        #expect(PanelText.outcome(for: typed, action: click)?.text == "◐ Not counted — you typed in Safari during the check")
        // Input elsewhere is the human using their Mac, not a question about the result.
        let elsewhere: [String: Any] = [
            "verdict": "confirmed", "pixelDelta": 0.1, "attribution": "agent",
            "humanInput": ["monitored": true, "stopped": false, "events": [["kind": "keyDown", "inTarget": false, "atMs": 10]]],
        ]
        #expect(PanelText.outcome(for: elsewhere, action: click)?.result.kind == .confirmed)
    }

    /// ✓ appears only where an action's result was observed.
    @Test func theTickMeansObserved() {
        let click = action("click", label: "X")
        for reply: [String: Any] in [["verdict": "noEffect"], ["verdict": "unverifiable"], ["error": "Something failed."]] {
            let text = PanelText.outcome(for: reply, action: click)?.text ?? ""
            #expect(text.range(of: "✓") == nil, "\(text)")
        }
    }

    @Test func userFacingTextNeverSaysEvidence() {
        let replies: [[String: Any]] = [
            ["verdict": "confirmed"], ["verdict": "noEffect"], ["verdict": "unverifiable"],
            ["error": "Something failed. Details."], ["ok": true],
        ]
        for reply in replies {
            let text = PanelText.outcome(for: reply, action: action("click", label: "X"))?.text ?? ""
            #expect(!text.lowercased().contains("evidence"))
        }
    }

    @Test func clocksPrefixesAndTruncation() {
        #expect(PanelText.clock(48) == "0:48")
        #expect(PanelText.clock(3723) == "1:02:03")
        #expect(PanelText.truncate("alex@example.com", limit: 8) == "alex@exa…")
        #expect(PanelText.truncate("a\n  b", limit: 10) == "a b")
        #expect(PanelText.stepPrefix(index: 1, count: 4) == "2/4")
        #expect(PanelText.stepPrefix(index: 4, count: 4) == "4/4")
        #expect(PanelText.stepPrefix(index: nil, count: 0) == nil)
    }
}

/// The lifecycle: what is up, in which mode, saying what, at which instant.
@MainActor
struct PanelLifecycleTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private let click = PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: false)

    /// After an action with no end signal, the agent is thinking — never "finished".
    @Test func betweenActionsTheAgentIsThinking() {
        let model = OverlayModel(showForAllActions: true)
        model.begin(click, at: at(0))
        #expect(model.presentation(at: at(0.5)).mode == .background)
        #expect(PanelLines(model: model, at: at(0.5)).line2 == "Clicking “Sign In”…")
        model.finish(reply: ["verdict": "confirmed", "treeDelta": "appeared: AXStaticText 'Welcome'"], at: at(1))
        let lines = PanelLines(model: model, at: at(4))
        #expect(lines.mode == .thinking)
        #expect(lines.pill == "Thinking 0:04")
        #expect(lines.line2 == "Clicked “Sign In” · ✓ “Welcome” appeared")
        #expect(model.presentation(at: at(15)).isUp)
    }

    /// An agent that never declared a session may never send `--done`; its silence ends the
    /// session after 20 s rather than 90.
    @Test func undeclaredSilenceEndsSooner() {
        let model = OverlayModel(showForAllActions: true)
        model.begin(click, at: at(0))
        model.finish(reply: ["verdict": "confirmed"], at: at(1))
        #expect(PanelLines(model: model, at: at(20)).mode == .thinking)
        let ended = PanelLines(model: model, at: at(21.5))
        #expect(ended.mode == .ended)
        #expect(ended.line2 == "Ended — the agent went quiet")
        #expect(!model.presentation(at: at(24)).isUp)
    }

    @Test func silenceWarnsThenEnds() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Testing the login flow", steps: [], at: at(0))
        model.begin(click, at: at(0))
        model.finish(reply: ["verdict": "confirmed"], at: at(1))
        #expect(model.presentation(at: at(30)).quietFor == nil)
        #expect(PanelLines(model: model, at: at(61)).line2 == "No word from the agent for 1:00")
        let ended = PanelLines(model: model, at: at(91.5))
        #expect(ended.mode == .ended)
        #expect(ended.line2 == "Ended — the agent went quiet")
        #expect(model.presentation(at: at(92.9)).opacity == 1)
        #expect(model.presentation(at: at(93.3)).opacity < 1)
        #expect(!model.presentation(at: at(94)).isUp)
    }

    @Test func doneOnTheLastActionEndsTheSession() {
        let model = OverlayModel(showForAllActions: true)
        var last = click
        last.endsSession = true
        model.begin(last, at: at(0))
        model.finish(reply: ["verdict": "confirmed"], at: at(1))
        let lines = PanelLines(model: model, at: at(1.5))
        #expect(lines.mode == .done)
        #expect(lines.line2 == "✓ Clicked “Sign In”")
        #expect(lines.pill == "Done 0:01")
        #expect(!model.presentation(at: at(4)).isUp)
    }

    @Test func busyOffEndsDoneWithTheResult() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Testing", steps: [], at: at(0))
        #expect(model.presentation(at: at(1)).mode == .thinking)
        model.begin(click, at: at(1))
        model.finish(reply: ["verdict": "confirmed"], at: at(2))
        model.endHold(result: "All green", at: at(48))
        let lines = PanelLines(model: model, at: at(49))
        #expect(lines.mode == .done)
        #expect(lines.line2 == "All green")
        #expect(lines.pill == "Done 0:48")
        #expect(!model.presentation(at: at(51)).isUp)
    }

    @Test func aStopHoldsUntilTheNextCommand() {
        let model = OverlayModel(showForAllActions: true)
        var hands = click
        hands.cursorTaking = true
        model.begin(hands, at: at(0))
        #expect(model.presentation(at: at(0.1)).mode == .handsOff)
        #expect(PanelLines(model: model, at: at(0.1)).line2 == "Using your mouse to click “Sign In”")
        model.finish(reply: ["ok": false, "humanInput": [
            "monitored": true, "stopped": true, "events": [["kind": "pointerMotion", "inTarget": false, "atMs": 300]],
        ]], at: at(1))
        let held = PanelLines(model: model, at: at(20))
        #expect(held.mode == .stopped)
        #expect(held.line2 == "You moved the mouse — the click didn’t happen")
        #expect(!model.presentation(at: at(20)).effectsVisible)
        model.begin(click, at: at(21))
        #expect(model.presentation(at: at(21.1)).mode == .background)
    }

    @Test func stepsPrefixLineTwo() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Goal", steps: ["a", "b", "c", "d"], at: at(0))
        #expect(PanelLines(model: model, at: at(0.5)).line2 == "1/4 · a")
        model.advanceStep(to: nil, at: at(1))
        model.begin(click, at: at(2))
        #expect(PanelLines(model: model, at: at(2.1)).line2 == "2/4 · Clicking “Sign In”…")
        model.finish(reply: ["verdict": "noEffect"], at: at(3))
        #expect(PanelLines(model: model, at: at(3.1)).line2 == "2/4 · Clicked “Sign In” · ✗ nothing changed")
        model.advanceStep(to: 3, at: at(4))
        #expect(PanelLines(model: model, at: at(4.1)).line2 == "3/4 · c")
    }

    @Test func aNonUIWaitReleasesTheScreen() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Building", steps: ["Build", "Test"], at: at(0))
        model.beginWait(what: "the build", seconds: 120, at: at(1))
        let released = model.presentation(at: at(30))
        #expect(!released.isUp)
        #expect(released.released)
        model.advanceStep(to: 2, at: at(130))
        #expect(model.presentation(at: at(130.1)).isUp)
        #expect(PanelLines(model: model, at: at(130.1)).line2 == "2/2 · Test")
    }

    @Test func aPlanRunsWithoutThinkingAndEndsDone() {
        let model = OverlayModel(showForAllActions: true)
        model.beginPlan(intents: ["Type", "Click"], at: at(0))
        #expect(PanelLines(model: model, at: at(0.1)).goal == "Running a 2-step plan")
        model.advanceStep(to: 1, at: at(0.1))
        model.begin(click, at: at(0.1))
        model.finish(reply: ["verdict": "confirmed"], at: at(0.4))
        #expect(model.presentation(at: at(0.45)).mode == .background)
        model.endPlan(abortReason: nil, at: at(1))
        #expect(model.presentation(at: at(1.1)).mode == .done)
        model.reset()
        model.beginPlan(intents: ["Type"], at: at(10))
        model.endPlan(abortReason: "guard failed on step 1", at: at(11))
        let ended = PanelLines(model: model, at: at(11.1))
        #expect(ended.mode == .ended)
        #expect(ended.line2 == "1/1 · Plan stopped: guard failed on step 1")
    }

    @Test func withoutAGoalTheWhyIsTheHeadline() {
        let model = OverlayModel(showForAllActions: true)
        var park = PanelAction(verb: "park", app: "Notes", cursorTaking: false)
        model.begin(park, at: at(0))
        #expect(PanelLines(model: model, at: at(0.1)).goal == "Working in Notes")
        park.why = "Filing the note out of your way"
        model.begin(park, at: at(1))
        #expect(PanelLines(model: model, at: at(1.1)).goal == "Filing the note out of your way")
    }

    @Test func consentIsOneQuestionInThePanel() {
        let model = OverlayModel(showForAllActions: true)
        var hands = click
        hands.cursorTaking = true
        model.begin(hands, at: at(0))
        model.presentConsent(prompt: "Bring Safari to the front and click “Sign In”", at: at(0.1))
        let lines = PanelLines(model: model, at: at(0.5))
        #expect(lines.mode == .needsYou)
        #expect(lines.line2 == "Bring Safari to the front and click “Sign In”?")
        #expect(!model.presentation(at: at(0.5)).effectsVisible)
        model.resolveConsent(.approve, at: at(1))
        #expect(model.presentation(at: at(1.1)).mode == .handsOff)
    }
}

/// `--done` is accepted where it means something and refused elsewhere.
@MainActor
struct DoneFlagValidationTests {
    private func request(_ json: String) throws -> CommandRouter.Request {
        try JSONDecoder().decode(CommandRouter.Request.self, from: Data(json.utf8))
    }

    @Test func doneGoesOnActingVerbsAndWait() throws {
        #expect(CommandRouter.validatePanelFields(try request(#"{"command":"click","label":"OK","done":true}"#), declaredStepCount: 0) == nil)
        #expect(CommandRouter.validatePanelFields(try request(#"{"command":"wait","label":"OK","done":true}"#), declaredStepCount: 0) == nil)
        #expect(CommandRouter.validatePanelFields(try request(#"{"command":"read","app":"Safari","done":true}"#), declaredStepCount: 0) != nil)
    }

    @Test func doneReachesThePanel() throws {
        let action = CommandRouter.panelAction(for: try request(#"{"command":"click","label":"OK","done":true}"#), cursorTaking: false)
        #expect(action.endsSession)
    }
}

/// Rocuronium's own captures leave out the overlay's windows and keep everything else.
struct CaptureExclusionTests {
    @Test func onlyRegisteredWindowsAreExcluded() {
        ScreenCapture.excludeFromCaptures(windowNumber: 987_654)
        let windows: [CGWindowID] = [1, 987_654, 3]
        #expect(ScreenCapture.excluded(from: windows, id: { $0 }) == [987_654])
    }
}

/// Every scene renders, at every key moment, with the panel on top.
@MainActor
struct ShowcaseTests {
    @Test func scenesWithKeyMomentsInsideTheirDuration() {
        #expect(ShowcaseScene.all.count == 13)
        #expect(ShowcaseScene.all.first?.slug == "hero")
        #expect(Set(ShowcaseScene.all.map(\.slug)).count == ShowcaseScene.all.count)
        for scene in ShowcaseScene.all {
            #expect(!scene.keyMoments.isEmpty)
            #expect(scene.keyMoments.allSatisfy { $0 >= 0 && $0 <= scene.duration })
        }
    }

    /// Every scene that ends declares its end: by the last frame, nothing is left up.
    @Test func everySceneEndsDownOrDeclared() {
        for scene in ShowcaseScene.all {
            let last = scene.frame(at: scene.duration)
            #expect(!last.model.presentation(at: scene.date(scene.duration)).isUp, "\(scene.slug) is still up at its end")
        }
    }

    /// No line in any scene is cut off: line 2 fits beside the stop chord and line 1 beside the
    /// pill, at every tenth of a second.
    @Test func noSceneLineTruncates() {
        for scene in ShowcaseScene.all {
            for tick in 0 ... Int(scene.duration * 10) {
                let t = Double(tick) / 10
                let model = scene.frame(at: t).model
                guard model.presentation(at: scene.date(t)).isUp, model.consent == nil else { continue }
                let lines = PanelLines(model: model, at: scene.date(t))
                let budget = PanelView.lineTwoBudget(hasSteps: !model.steps.isEmpty)
                let width = PanelView.textWidth(lines.line2, size: PanelView.Constants.bodySize, weight: .medium)
                #expect(width <= budget, "\(scene.slug) t=\(t): “\(lines.line2)” is \(Int(width)) of \(Int(budget))")
            }
        }
    }

    /// Every result names what was observed; none says just "done", "ran" or "changed".
    @Test func noSceneResultIsVague() {
        for scene in ShowcaseScene.all {
            for tick in 0 ... Int(scene.duration * 10) {
                let t = Double(tick) / 10
                let line = PanelLines(model: scene.frame(at: t).model, at: scene.date(t)).line2
                for vague in ["✓ done", "✓ ran", "✓ changed"] {
                    #expect(!line.hasSuffix(vague), "\(scene.slug) t=\(t): \(line)")
                }
            }
        }
    }

    /// The stroke ends under the pointer at every instant it is being drawn.
    @Test func theStrokeEndsUnderThePointer() {
        let scene = ShowcaseScene.hero
        for t in stride(from: 5.4, through: 6.9, by: 0.1) {
            let frame = scene.frame(at: t)
            guard let tip = frame.desktop.stroke.last else { continue }
            #expect(hypot(tip.x - frame.desktop.pointer.x, tip.y - frame.desktop.pointer.y) < 0.5, "t=\(t)")
        }
    }

    /// The human's keys light; the agent's ghost typing leaves the keyboard alone, and a
    /// hands-off click takes the trackpad.
    @Test func theDeckMirrorsOnlyTheHuman() {
        let typing = ShowcaseScene.hero.frame(at: 0.8).desktop.deck
        #expect(typing.keyboard == .human)
        #expect(!typing.keyGlow.isEmpty)
        let handsOff = ShowcaseScene.hero.frame(at: 2.5).desktop.deck
        #expect(handsOff.trackpad == .agent)
        #expect(handsOff.keyboard == .paused)
        #expect(handsOff.keyGlow.isEmpty)
        let ghostOnly = ShowcaseScene.planBatch.frame(at: 0.6).desktop.deck
        #expect(ghostOnly.keyboard == .stillYours)
        #expect(ghostOnly.keyGlow.isEmpty)
        #expect(MockKeyboardLayout.keys(for: "G") == ["g", "lshift"])
        #expect(MockKeyboardLayout.keys(for: "–") == ["-", "option"])
    }

    @Test func aFrameRendersOffline() {
        let image = ShowcaseRenderer.frame(scene: ShowcaseScene.handsOffClick, t: 2.0, scheme: .light)
        #expect(image?.width == Int(MockLayout.desktop.width * ShowcaseRenderer.Constants.scale))
    }

    @Test func launchOptionsParse() {
        let options = ShowcaseLaunchOptions.parse([
            "Rocuronium", "--showcase-scene", "hero", "--autoplay", "--hide-chrome", "--window-size", "1280x800",
        ])
        #expect(options.sceneSlug == "hero")
        #expect(options.autoplay)
        #expect(!options.loop)
        #expect(options.hideChrome)
        #expect(options.windowSize == CGSize(width: 1280, height: 800))
        #expect(ShowcaseLaunchOptions.parse(["Rocuronium", "--hide-chrome", "--window-origin", "1800,120"]).windowOrigin
            == CGPoint(x: 1800, y: 120))
        #expect(ShowcaseLaunchOptions.parse(["Rocuronium"]) == ShowcaseLaunchOptions())
        let render = ShowcaseRenderer.Request.parse(["Rocuronium", "--render-showcase", "/tmp/x", "--scene", "hero", "--fps", "30"])
        #expect(render?.sceneSlug == "hero")
        #expect(render?.fps == 30)
    }
}
