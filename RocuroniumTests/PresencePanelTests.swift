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
        #expect(PanelText.actionLine(for: action("click", label: "Sign In")) == "Clicking “Sign In” in Safari")
        #expect(PanelText.actionLine(
            for: action("click", label: "Sign In"),
            resolved: .init(role: "AXButton", label: "Sign In"),
        ) == "Clicking the “Sign In” button in Safari")
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
        #expect(PanelText.actionLine(for: stroke) == "Drawing a stroke (24 points) in Safari")
        var scroll = action("scroll")
        scroll.untilText = "Terms"
        #expect(PanelText.actionLine(for: scroll) == "Scrolling until “Terms” is visible")
        scroll.untilText = nil
        scroll.direction = "bottom"
        #expect(PanelText.actionLine(for: scroll) == "Scrolling Safari to the bottom")
    }

    /// The engine cannot know a field is secure before typing, so typed text never appears.
    @Test func typedTextIsNeverEchoed() {
        let line = PanelText.actionLine(for: action("type", label: "Email", text: "kiri@example.com"))
        #expect(line == "Typing into “Email” in Safari")
        #expect(!line.contains("kiri"))
        #expect(PanelText.actionLine(for: action("type", app: "Terminal", text: "ls")) == "Typing into Terminal")
        #expect(PanelText.actionLine(for: action("type", label: "Password", text: "hunter2", secure: true))
            == "Typing a password into “Password” (hidden)")
    }

    @Test func handsOffNamesTheHand() {
        #expect(PanelText.handsOffLine(for: action("click", label: "Sign In", hands: true))
            == "Using your mouse to click “Sign In” in Safari")
        #expect(PanelText.handsOffLine(for: action("type", app: "Terminal", text: "ls", hands: true))
            == "Typing with your keyboard into Terminal")
        #expect(PanelText.handsOffLine(for: action("key", app: "Ghostty", keys: "cmd+=", hands: true))
            == "Using your keyboard to press ⌘= in Ghostty")
    }

    @Test func resultPhrases() {
        let type = action("type", label: "Email", text: "kiri@example.com")
        #expect(PanelText.result(for: ["verdict": "confirmed", "readback": "kiri@example.com"], action: type)?.text
            == "✓ “Email” now reads kiri@example.com")
        let click = action("click", label: "Sign In")
        #expect(PanelText.result(for: [
            "verdict": "confirmed",
            "treeDelta": "value changed: AXStaticText 'count': 'clicks: 0' → 'clicks: 1'\nappeared: AXSheet 'Save'\n…and 2 more change(s)",
        ], action: click)?.text == "✓ “clicks: 0” became “clicks: 1” (+3 more)")
        #expect(PanelText.result(for: ["verdict": "confirmed", "readback": "the target's on-screen window count changed 1 → 2"], action: click)?.text
            == "✓ A new window opened")
        #expect(PanelText.result(for: ["verdict": "confirmed", "menuItem": "View > Increase Font Size"], action: click)?.text
            == "✓ View ▸ Increase Font Size ran")
        #expect(PanelText.result(for: ["verdict": "confirmed", "pixelDelta": 0.1], action: click)?.text
            == "✓ Safari changed where it clicked")
        #expect(PanelText.result(for: ["verdict": "noEffect"], action: click)?.text == "✗ Nothing changed after clicking “Sign In”")
        #expect(PanelText.result(for: ["verdict": "unverifiable"], action: click)?.text == "? Sent — Safari offers no way to check it")
        #expect(PanelText.result(for: ["error": "No element matched 'Sign In'."], action: click)?.text
            == "✗ Couldn’t find “Sign In” in Safari")
        #expect(PanelText.result(for: ["error": "'Notes' covers the target app at (1, 2) — the hover would land on it instead."], action: click)?.text
            == "Didn’t click: Notes was covering “Sign In”")
    }

    @Test func humanInputResults() {
        let click = action("click", label: "Sign In", hands: true)
        let stopped: [String: Any] = ["humanInput": [
            "monitored": true, "stopped": true,
            "events": [["kind": "pointerMotion", "inTarget": false, "atMs": 300]],
        ]]
        #expect(PanelText.result(for: stopped, action: click)?.text == "⚠ You moved the mouse during the click — stopped")
        let mixed: [String: Any] = [
            "verdict": "confirmed", "attribution": "mixed",
            "humanInput": ["monitored": true, "stopped": false, "events": [["kind": "mouseDown", "inTarget": true, "atMs": 10]]],
        ]
        #expect(PanelText.result(for: mixed, action: click)?.text == "⚠ You clicked in Safari during the check — the change may be yours")
        // Input elsewhere is the human using their Mac, not a question about the result.
        let elsewhere: [String: Any] = [
            "verdict": "confirmed", "pixelDelta": 0.1, "attribution": "agent",
            "humanInput": ["monitored": true, "stopped": false, "events": [["kind": "keyDown", "inTarget": false, "atMs": 10]]],
        ]
        #expect(PanelText.result(for: elsewhere, action: click)?.kind == .confirmed)
    }

    @Test func userFacingTextNeverSaysEvidence() {
        let replies: [[String: Any]] = [
            ["verdict": "confirmed"], ["verdict": "noEffect"], ["verdict": "unverifiable"],
            ["error": "Something failed. Details."], ["ok": true],
        ]
        for reply in replies {
            let text = PanelText.result(for: reply, action: action("click", label: "X"))?.text ?? ""
            #expect(!text.lowercased().contains("evidence"))
        }
    }

    @Test func clocksAndTruncation() {
        #expect(PanelText.clock(48) == "0:48")
        #expect(PanelText.clock(3723) == "1:02:03")
        #expect(PanelText.truncate("kiri@example.com", limit: 8) == "kiri@exa…")
        #expect(PanelText.truncate("a\n  b", limit: 10) == "a b")
        #expect(PanelText.stepLine(index: 1, count: 5, body: "Typing") == "Step 2 of 5 · Typing")
    }
}

/// The lifecycle: what is up, in which mode, at which instant.
@MainActor
struct PanelLifecycleTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private let click = PanelAction(verb: "click", app: "Safari", label: "Sign In", cursorTaking: false)

    @Test func withoutAHoldThePanelFadesSoonAfterTheResult() {
        let model = OverlayModel(showForAllActions: true)
        model.begin(click, at: at(0))
        #expect(model.presentation(at: at(0.5)).mode == .background)
        model.finish(reply: ["verdict": "confirmed"], at: at(1))
        #expect(model.presentation(at: at(3.4)).opacity == 1)
        #expect(model.presentation(at: at(3.8)).opacity < 1)
        #expect(!model.presentation(at: at(5)).isUp)
    }

    @Test func aHoldThinksThenWarnsThenFades() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Testing", steps: [], at: at(0))
        #expect(model.presentation(at: at(2)).mode == .background)
        #expect(model.presentation(at: at(5)).mode == .thinking)
        #expect(model.presentation(at: at(30)).quietFor == nil)
        #expect(model.presentation(at: at(61)).quietFor != nil)
        #expect(model.presentation(at: at(89)).isUp)
        #expect(!model.presentation(at: at(92)).isUp)
    }

    @Test func endHoldShowsTheSummaryThenFades() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Testing", steps: [], at: at(0))
        model.begin(click, at: at(1))
        model.finish(reply: ["verdict": "confirmed"], at: at(2))
        model.endHold(result: nil, at: at(48))
        #expect(model.presentation(at: at(49)).mode == .done)
        #expect(PanelLines(model: model, at: at(49)).now == "Done · 1 action · 0:48")
        #expect(!model.presentation(at: at(51)).isUp)
    }

    @Test func handsOffAndEffectsOnlyWhileTheActionRuns() {
        let model = OverlayModel(showForAllActions: true)
        var hands = click
        hands.cursorTaking = true
        model.begin(hands, at: at(0))
        #expect(model.presentation(at: at(0.1)).mode == .handsOff)
        #expect(model.presentation(at: at(0.1)).effectsVisible)
        model.finish(reply: ["verdict": "confirmed"], at: at(1))
        #expect(model.presentation(at: at(2)).mode == .background)
        #expect(!model.presentation(at: at(2)).effectsVisible)
    }

    @Test func stepsAndWaits() {
        let model = OverlayModel(showForAllActions: true)
        model.beginHold(goal: "Goal", steps: ["a", "b", "c"], at: at(0))
        #expect(model.stepIndex == 0)
        model.advanceStep(to: nil, at: at(1))
        #expect(model.stepIndex == 1)
        model.advanceStep(to: 3, at: at(2))
        #expect(PanelLines(model: model, at: at(2)).now == "Step 3 of 3 · c")
        model.beginWait(what: "the build", seconds: 120, at: at(3))
        let waiting = PanelLines(model: model, at: at(45))
        #expect(waiting.mode == .waiting)
        #expect(waiting.chipDetail == "0:42 / ~2:00")
        model.begin(click, at: at(50))
        #expect(model.wait == nil)
    }

    @Test func consentIsNeedsYouAndHoldsBackTheEffects() {
        let model = OverlayModel(showForAllActions: true)
        var hands = click
        hands.cursorTaking = true
        model.begin(hands, at: at(0))
        model.presentConsent(prompt: "Bring Safari forward", detail: "Safari · click", at: at(0.1))
        #expect(model.presentation(at: at(0.5)).mode == .needsYou)
        #expect(!model.presentation(at: at(0.5)).effectsVisible)
        model.resolveConsent(.approve, at: at(1))
        #expect(model.presentation(at: at(1.1)).mode == .handsOff)
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
    @Test func tenScenesWithKeyMomentsInsideTheirDuration() {
        #expect(ShowcaseScene.all.count == 10)
        for scene in ShowcaseScene.all {
            #expect(!scene.keyMoments.isEmpty)
            #expect(scene.keyMoments.allSatisfy { $0 >= 0 && $0 <= scene.duration })
        }
    }

    @Test func aFrameRendersOffline() {
        let scene = ShowcaseScene.handsOffClick
        let image = ShowcaseRenderer.frame(scene: scene, t: 2.0, scheme: .light)
        #expect(image?.width == Int(MockLayout.desktop.width * ShowcaseRenderer.Constants.scale))
    }
}
