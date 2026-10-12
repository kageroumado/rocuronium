import Foundation
import Testing
@testable import Rocuronium

@MainActor
struct AgentDesktopTargetTests {
    let identity = AgentDesktopIdentity(uid: 502, account: "agent", loginWindowPID: 123)

    func parse(_ request: [String: Any]) throws -> AgentDesktopTarget.Parsed {
        try AgentDesktopTarget.parse(JSONSerialization.data(withJSONObject: request))
    }

    @Test func currentDesktopRemainsTheDefault() throws {
        let target = try parse(["command": "read", "app": "TextEdit"])
        #expect(target.desktop == "current")
        #expect(target.identity == nil)
    }

    @Test func explicitWireTargetAndRemoteEnvelopePreservePayload() throws {
        let target = try parse(["command": "desktop-target", "desktop": "agent", "request": ["command": "type", "text": "example"]])
        #expect(target.desktop == "agent")
        #expect(target.request["text"] as? String == "example")
        let received = try parse(AgentDesktopTarget.envelope(target.request, identity: identity))
        #expect(received.identity == identity)
        #expect(received.request["command"] as? String == "type")
    }

    @Test func identityRequiresTheExactOffConsoleLogin() {
        #expect(identity.refusal(uid: 502, account: "agent", loginWindowPID: 123, offConsole: true) == nil)
        #expect(identity.refusal(uid: 501, account: "agent", loginWindowPID: 123, offConsole: true) != nil)
        #expect(identity.refusal(uid: 502, account: "other", loginWindowPID: 123, offConsole: true) != nil)
        #expect(identity.refusal(uid: 502, account: "agent", loginWindowPID: 456, offConsole: true) != nil)
        #expect(identity.refusal(uid: 502, account: "agent", loginWindowPID: nil, offConsole: true) != nil)
        #expect(identity.refusal(uid: 502, account: "agent", loginWindowPID: 123, offConsole: false) != nil)
    }

    @Test func invalidSelectionsAndLifecycleAreRefused() {
        #expect(throws: (any Error).self) { try parse(["command": "type", "desktop": "agnt"]) }
        #expect(throws: (any Error).self) { try parse(["command": "type", "desktop": false]) }
        #expect(throws: (any Error).self) { try parse(["command": "session", "action": "start", "desktop": "agent"]) }
    }

    @Test func plansCannotSwitchDesktopsOrManageSessionsInAgentAccount() {
        #expect(throws: (any Error).self) { try parse(["command": "plan", "steps": [["command": "type", "desktop": "agent"]]]) }
        #expect(throws: (any Error).self) { try parse(["command": "plan", "desktop": "agent", "steps": [["command": "session", "action": "stop"]]]) }
    }

    @Test func nestedEnvelopeAndReceiverOverrideAreRefused() throws {
        #expect(throws: (any Error).self) { try parse(["command": "desktop-target", "desktop": "agent", "request": AgentDesktopTarget.envelope(["command": "type"], identity: identity)]) }
        #expect(throws: (any Error).self) { try parse(AgentDesktopTarget.envelope(["command": "type", "desktop": "current"], identity: identity)) }
        #expect(throws: (any Error).self) { try parse(AgentDesktopTarget.envelope(["command": "agent-desktop"], identity: identity)) }
    }

    @Test func unavailableAgentNeverForwards() async {
        let controller = AgentSessionController()
        let reply = await controller.forwardToDesktop(["command": "type", "text": "must not land"])
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["desktop"] as? String == "agent")
    }

    @Test func resolvedPlanFieldsPreserveLifecycleAndCaptureRestrictions() {
        #expect(AgentDesktopTarget.planStepRefusal(command: "screenshot", path: "/tmp/from-reference.png") != nil)
        #expect(AgentDesktopTarget.planStepRefusal(command: "session", path: nil) != nil)
        #expect(AgentDesktopTarget.planStepRefusal(command: "screenshot", path: nil) == nil)
        #expect(AgentDesktopTarget.planStepRefusal(command: "menu", path: "File > New") == nil)
    }
}

@MainActor
struct AgentDesktopCaptureTests {
    @Test func nestedCapturesAreCopiedAndPathsRewritten() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-capture-test-\(UUID().uuidString)")
        let remote = root.appending(path: "remote")
        let local = root.appending(path: "local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let path = remote.appending(path: "capture.png")
        let bytes = AgentDesktopCapture.pngSignature + Data([1, 2, 3])
        try bytes.write(to: path)
        let reply: [String: Any] = ["ok": true, "regions": [["path": path.path, "summary": "capture at \(path.path)"]]]
        let directoryWithoutSlash = URL(fileURLWithPath: remote.path, isDirectory: false)
        let packed = try AgentDesktopCapture.pack(reply, directory: directoryWithoutSlash)
        #expect((packed["regions"] as? [[String: Any]])?.first?["_agentPNG"] != nil)
        let unpacked = try AgentDesktopCapture.unpack(packed, directory: local)
        let region = try #require((unpacked["regions"] as? [[String: Any]])?.first)
        let imported = try #require(region["path"] as? String)
        #expect(imported.hasPrefix(local.path + "/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: imported)) == bytes)
        #expect(region["_agentPNG"] == nil)
        #expect(region["summary"] as? String == "capture at \(imported)")
    }

    @Test func corruptCaptureAndOverwriteAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-capture-test-\(UUID().uuidString)")
        let bad: [String: Any] = ["path": "/remote.png", "_agentPNG": Data("bad".utf8).base64EncodedString()]
        #expect(throws: (any Error).self) { try AgentDesktopCapture.unpack(bad, directory: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appending(path: "existing.png")
        try Data("keep".utf8).write(to: existing)
        let valid: [String: Any] = ["path": "/remote.png", "_agentPNG": AgentDesktopCapture.pngSignature.base64EncodedString()]
        #expect(throws: (any Error).self) { try AgentDesktopCapture.unpack(valid, directory: directory, destination: existing) }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    }
}
