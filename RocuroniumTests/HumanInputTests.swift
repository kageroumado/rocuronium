import CoreGraphics
import Foundation
import Testing
@testable import Rocuronium

/// Attribution of a verdict between the agent and the human, on synthetic event lists, and the
/// reply shape it produces.
struct HumanInputAttributionTests {
    private let target: pid_t = 4242
    private let elsewhere: pid_t = 777

    private func event(_ kind: HumanInputEvent.Kind, pid: pid_t?, at offset: TimeInterval = 0.1) -> HumanInputEvent {
        HumanInputEvent(kind: kind, offset: offset, location: CGPoint(x: 10, y: 10), pid: pid)
    }

    @Test func aConfirmedActionWithNoHumanInputIsTheAgents() {
        #expect(HumanInputReport.attribution(verdict: "confirmed", events: [], target: target) == "agent")
    }

    @Test func aClickKeyOrScrollInTheTargetMakesAConfirmationMixed() {
        for kind in [HumanInputEvent.Kind.mouseDown, .keyDown, .scroll] {
            let events = [event(kind, pid: target)]
            #expect(HumanInputReport.attribution(verdict: "confirmed", events: events, target: target) == "mixed")
        }
    }

    @Test func inputElsewhereIsTheHumanUsingTheirMac() {
        let events = [event(.mouseDown, pid: elsewhere), event(.keyDown, pid: elsewhere), event(.scroll, pid: nil)]
        #expect(HumanInputReport.attribution(verdict: "confirmed", events: events, target: target) == "agent")
    }

    @Test func pointerMotionNeverMakesAConfirmationMixed() {
        let events = [event(.pointerMotion, pid: target)]
        #expect(HumanInputReport.attribution(verdict: "confirmed", events: events, target: target) == "agent")
    }

    /// Only a confirmation can be wrongly credited; noEffect and unverifiable claim no change.
    @Test func onlyAConfirmedVerdictBecomesMixed() {
        let events = [event(.mouseDown, pid: target)]
        #expect(HumanInputReport.attribution(verdict: "noEffect", events: events, target: target) == "agent")
        #expect(HumanInputReport.attribution(verdict: "unverifiable", events: events, target: target) == "agent")
    }

    @Test func withoutATargetNothingIsInTarget() {
        let events = [event(.mouseDown, pid: target)]
        #expect(HumanInputReport.attribution(verdict: "confirmed", events: events, target: nil) == "agent")
        #expect(!HumanInputReport.inTarget(events[0], target: nil))
    }

    @Test func replyFieldsCarryEventsInMillisecondsAndAttribution() throws {
        let report = HumanInputReport(
            monitored: true,
            events: [event(.mouseDown, pid: target, at: 0.4126), event(.keyDown, pid: elsewhere, at: 1.2)],
            stopped: false, targetPid: target,
        )
        let fields = report.replyFields(verdict: "confirmed")
        #expect(fields["attribution"] as? String == "mixed")
        let block = try #require(fields["humanInput"] as? [String: Any])
        #expect(block["monitored"] as? Bool == true)
        #expect(block["stopped"] as? Bool == false)
        let events = try #require(block["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(events[0]["kind"] as? String == "mouseDown")
        #expect(events[0]["inTarget"] as? Bool == true)
        #expect(events[0]["atMs"] as? Int == 413)
        #expect(events[1]["inTarget"] as? Bool == false)
    }

    @Test func emptyEventsAreOmitted() throws {
        let report = HumanInputReport(monitored: true, events: [], stopped: true, targetPid: target)
        let fields = report.replyFields(verdict: "unverifiable")
        let block = try #require(fields["humanInput"] as? [String: Any])
        #expect(block["events"] == nil)
        #expect(block["stopped"] as? Bool == true)
        #expect(fields["attribution"] as? String == "agent")
    }

    /// An unwatched action has no basis to vouch for itself, and a verdict-less reply has nothing
    /// to attribute.
    @Test func attributionNeedsMonitoringAndAVerdict() throws {
        let unwatched = HumanInputReport.unmonitored.replyFields(verdict: "confirmed")
        #expect(unwatched["attribution"] == nil)
        #expect((unwatched["humanInput"] as? [String: Any])?["monitored"] as? Bool == false)
        let watched = HumanInputReport(monitored: true, events: [], stopped: false, targetPid: target)
        #expect(watched.replyFields(verdict: nil)["attribution"] == nil)
    }
}

/// Every synthesized event must carry the mark, or the human-input monitor counts our own input
/// as a human's and the hardware tentacle stops itself. The mark is applied by `postTagged`; this
/// fails on any raw post call elsewhere in the app.
struct SyntheticInputTests {
    @Test func everyPostGoesThroughTheTaggingHelper() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RocuroniumTests
            .deletingLastPathComponent()  // repo root
            .appending(path: "Rocuronium")
        try #require(FileManager.default.fileExists(atPath: appDirectory.path), "app sources absent — not a repository checkout")
        let rawPost = try Regex(#"\.(post\(tap:|postToPid\()"#)
        let enumerator = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "SyntheticInput.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                if code.contains(rawPost) { offenders.append("\(url.lastPathComponent):\(number + 1)") }
            }
        }
        #expect(offenders.isEmpty, "raw event posts bypass the synthetic mark: \(offenders)")
    }

    @Test func theMarkIsRecognized() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.tag)
        #expect(SyntheticInput.isOurs(event))
    }
}

/// The panel-facing request fields: decoding the two shapes of `steps`, and the bounds the router
/// enforces before anything reaches the overlay.
@MainActor
struct PanelProtocolTests {
    private func request(_ json: String) throws -> CommandRouter.Request {
        try JSONDecoder().decode(CommandRouter.Request.self, from: Data(json.utf8))
    }

    @Test func stepsDecodeFromAPipeStringOrAnArray() throws {
        #expect(try request(#"{"command":"busy","steps":"Open | Type|Submit"}"#).stepLabels == ["Open", "Type", "Submit"])
        #expect(try request(#"{"command":"busy","steps":["Open","Type"]}"#).stepLabels == ["Open", "Type"])
        #expect(try request(#"{"command":"busy"}"#).stepLabels == nil)
    }

    @Test func planStepsStillDecodeAsCommands() throws {
        let plan = try request(#"{"command":"plan","steps":[{"command":"click","app":"Finder","label":"OK"}]}"#)
        #expect(plan.planSteps?.count == 1)
        #expect(plan.stepLabels == nil)
    }

    @Test func stepPointerAcceptsStringsAndNumbers() throws {
        #expect(try request(#"{"command":"busy","action":"step","step":3}"#).step?.raw == "3")
        #expect(try request(#"{"command":"busy","action":"step","step":"next"}"#).step?.raw == "next")
    }

    private func complaint(_ json: String, steps: Int = 0) throws -> String? {
        CommandRouter.validatePanelFields(try request(json), declaredStepCount: steps)
    }

    @Test func wellFormedPanelFieldsPass() throws {
        #expect(try complaint(#"{"command":"busy","action":"on","goal":"Testing the login flow","steps":"a|b|c"}"#) == nil)
        #expect(try complaint(#"{"command":"click","app":"Safari","label":"Sign In","why":"submit the form"}"#) == nil)
        #expect(try complaint(#"{"command":"busy","action":"wait","for":"the build","seconds":120}"#) == nil)
        #expect(try complaint(#"{"command":"busy","action":"step","step":3}"#, steps: 3) == nil)
        #expect(try complaint(#"{"command":"busy","action":"step","step":"next"}"#, steps: 3) == nil)
    }

    @Test func overlongTextIsRefused() throws {
        let long = String(repeating: "x", count: 121)
        #expect(try complaint(#"{"command":"click","why":"\#(long)"}"#)?.contains("'why'") == true)
        #expect(try complaint(#"{"command":"busy","goal":"\#(long)"}"#)?.contains("'goal'") == true)
        #expect(try complaint(#"{"command":"busy","note":"\#(long)"}"#)?.contains("'note'") == true)
        #expect(try complaint(#"{"command":"busy","action":"off","result":"\#(long)"}"#)?.contains("'result'") == true)
        #expect(try complaint(#"{"command":"busy","action":"wait","for":"\#(long)"}"#)?.contains("'for'") == true)
    }

    @Test func badStepListsAreRefused() throws {
        let many = (1 ... 21).map(String.init).joined(separator: "|")
        #expect(try complaint(#"{"command":"busy","steps":"\#(many)"}"#) != nil)
        #expect(try complaint(#"{"command":"busy","steps":"a||c"}"#)?.contains("step 2") == true)
        #expect(try complaint(#"{"command":"busy","steps":["\#(String(repeating: "y", count: 81))"]}"#) != nil)
        #expect(try complaint(#"{"command":"plan","steps":"a|b"}"#) != nil)
        #expect(try complaint(#"{"command":"busy","steps":[{"command":"click"}]}"#) != nil)
    }

    @Test func waitSecondsAreBounded() throws {
        #expect(try complaint(#"{"command":"busy","action":"wait","for":"x","seconds":-1}"#) != nil)
        #expect(try complaint(#"{"command":"busy","action":"wait","for":"x","seconds":3601}"#) != nil)
        #expect(try complaint(#"{"command":"busy","action":"wait","for":"x","seconds":0}"#) == nil)
        #expect(try complaint(#"{"command":"busy","action":"wait","for":"x","seconds":3600}"#) == nil)
    }

    @Test func stepTargetsAreBoundedByTheDeclaredSteps() throws {
        #expect(try complaint(#"{"command":"busy","action":"step","step":4}"#, steps: 3)?.contains("out of range") == true)
        #expect(try complaint(#"{"command":"busy","action":"step","step":0}"#, steps: 3)?.contains("out of range") == true)
        #expect(try complaint(#"{"command":"busy","action":"step","step":2}"#, steps: 0)?.contains("no steps declared") == true)
        #expect(try complaint(#"{"command":"busy","action":"step","step":"later"}"#, steps: 3) != nil)
    }

    @Test func panelActionCarriesTheRequestsWords() throws {
        let menu = try request(#"{"command":"menu","app":"Ghostty","path":"View > Increase Font Size","why":"bigger text"}"#)
        let action = CommandRouter.panelAction(for: menu, cursorTaking: false)
        #expect(action.verb == "menu")
        #expect(action.menuPath == "View > Increase Font Size")
        #expect(action.why == "bigger text")
        let click = try request(#"{"command":"click","app":"Safari","x":640,"y":412,"allowHardwareInput":true}"#)
        let clickAction = CommandRouter.panelAction(for: click, cursorTaking: true)
        #expect(clickAction.point == CGPoint(x: 640, y: 412))
        #expect(clickAction.menuPath == nil)
        #expect(clickAction.cursorTaking)
        #expect(clickAction.why == nil)
    }
}
