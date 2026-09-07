import Testing
@testable import rocuronium

/// The usage text and the MCP tool schemas are the agent's whole interface — an agent picks
/// verbs by reading them, so a command the router grew but the docs never mentioned is
/// invisible, and a flag the docs promise but the router dropped is a lie. These tests keep the
/// two the CLI owns — `usage` and `MCPServer.tools` — honest against each other and against the
/// canonical command set, so drift fails the build instead of a session.
///
/// House rule: a command or flag change lands in the router's `dispatch`, the CLI `usage`,
/// `MCPServer.tools`, and the skill (`.claude/skills/rocuronium`). This suite covers the three
/// that live in the CLI and router.
@MainActor
struct DocsConsistencyTests {
    /// Every verb `CommandRouter.dispatch` handles. Kept here as the cross-check's fixed point:
    /// add a command to the router and this list, and the tests below prove the docs kept up.
    static let commands: Set<String> = [
        "status", "diag", "request-capture", "find", "read", "apps", "windows",
        "type", "click", "scroll", "shortcut", "menu", "key", "move", "drag",
        "wait", "launch", "activate", "display", "park", "resize", "screenshot", "statusitem",
        "activity", "demo", "plan",
    ]

    /// Commands with no MCP tool, and why. `request-capture` fires the Screen Recording
    /// prompt — a human-in-the-loop action an agent has no use for; `mcp` is a CLI-only
    /// entry point, not a socket verb.
    static let noMCPTool: Set<String> = ["request-capture"]

    private var toolNames: [String] {
        MCPServer.tools.compactMap { $0["name"] as? String }
    }

    @Test func everyMCPToolIsAKnownCommand() {
        for name in toolNames {
            #expect(Self.commands.contains(name), "MCP exposes '\(name)', which is not a known router command")
        }
    }

    @Test func everyCommandHasAnMCPToolUnlessExcepted() {
        let tools = Set(toolNames)
        for command in Self.commands where !Self.noMCPTool.contains(command) {
            #expect(tools.contains(command), "command '\(command)' has no MCP tool (add it, or list it in noMCPTool with a reason)")
        }
    }

    @Test func everyCommandAppearsInUsage() {
        for command in Self.commands {
            #expect(usage.contains(command), "command '\(command)' is absent from the CLI usage text")
        }
    }

    @Test func toolNamesAreUnique() {
        var seen = Set<String>()
        for name in toolNames {
            #expect(seen.insert(name).inserted, "MCP tool '\(name)' is declared twice")
        }
    }

    @Test func everyToolHasADescription() {
        for tool in MCPServer.tools {
            let name = tool["name"] as? String ?? "?"
            let description = tool["description"] as? String ?? ""
            #expect(!description.isEmpty, "MCP tool '\(name)' has no description")
        }
    }

    /// Every declared input property carries its own description — the agent reads these to
    /// know what a field does, and a bare `{"type":"string"}` tells it nothing. `app` and
    /// `pid` are auto-injected with descriptions by `tool(...)`, so they are covered too.
    @Test func everyToolPropertyHasADescription() {
        for tool in MCPServer.tools {
            let name = tool["name"] as? String ?? "?"
            guard let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any] else { continue }
            for (key, value) in properties {
                let description = (value as? [String: Any])?["description"] as? String ?? ""
                // Enums are self-describing through their `enum` list; everything else needs prose.
                let hasEnum = (value as? [String: Any])?["enum"] != nil
                #expect(!description.isEmpty || hasEnum, "MCP tool '\(name)' property '\(key)' has no description")
            }
        }
    }
}
