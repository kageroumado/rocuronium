import Foundation
import Testing
@testable import rocuronium

@MainActor
struct DesktopArgumentTests {
    @Test func extractsTargetAndPreservesLiteralText() throws {
        var arguments = ["type", "--text", "--desktop", "--desktop", "agent", "--json"]
        #expect(try DesktopArgument.extract(from: &arguments) == "agent")
        #expect(arguments == ["type", "--text", "--desktop", "--json"])
    }

    @Test(arguments: [["status", "--desktop"], ["status", "--desktop", "other"], ["status", "--desktop", "agent", "--desktop", "current"]])
    func refusesAmbiguousOrMalformedCLI(arguments: [String]) {
        var arguments = arguments
        #expect(throws: DesktopArgument.Invalid.self) { try DesktopArgument.extract(from: &arguments) }
    }

    @Test func equalsSpellingSelectsTheAgent() throws {
        var arguments = ["read", "--desktop=agent", "--app", "TextEdit"]
        #expect(try DesktopArgument.extract(from: &arguments) == "agent")
        #expect(arguments == ["read", "--app", "TextEdit"])
    }

    @Test func wireCommandFailsClosedOnOlderDaemons() {
        let request = DesktopArgument.wireRequest(["command": "type", "desktop": "agent", "text": "example"])
        #expect(request["command"] as? String == "desktop-target")
        let inner = request["request"] as? [String: Any]
        #expect(inner?["command"] as? String == "type")
        #expect(inner?["desktop"] == nil)
        #expect(DesktopArgument.wireRequest(["command": "read"])["command"] as? String == "read")
    }

    @Test func mcpPropagatesTargetAndRefusesInvalidSelectionBeforeForwarding() {
        var requests: [[String: Any]] = []
        let forward: ([String: Any]) -> [String: Any]? = { requests.append($0); return ["ok": true] }
        let result = MCPServer.call(["name": "read", "arguments": ["app": "TextEdit", "desktop": "agent"]], forward: forward)
        #expect(result["isError"] as? Bool == false)
        #expect(requests.first?["desktop"] as? String == "agent")
        for value in ["agnt", true, NSNull()] as [Any] {
            let refused = MCPServer.call(["name": "read", "arguments": ["app": "TextEdit", "desktop": value]], forward: forward)
            #expect(refused["isError"] as? Bool == true)
        }
        #expect(requests.count == 1)
    }

    @Test func lifecycleStaysOnOwningDesktop() {
        var forwarded = false
        let result = MCPServer.call(["name": "session", "arguments": ["action": "stop", "desktop": "agent"]]) { _ in
            forwarded = true
            return ["ok": true]
        }
        #expect(result["isError"] as? Bool == true)
        #expect(!forwarded)
        #expect(MCPServer.schemaProperties(of: "plan").contains("desktop"))
        #expect(!MCPServer.schemaProperties(of: "session").contains("desktop"))
    }
}
