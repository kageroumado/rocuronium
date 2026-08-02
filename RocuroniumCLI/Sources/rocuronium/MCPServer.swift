import Foundation

// The MCP face of the control socket: `rocuronium mcp` speaks Model Context Protocol over
// stdio so agent harnesses get typed tools instead of shelling out to the CLI.
//
// Deliberately minimal. The server implements exactly the four requests a tools-only MCP
// server needs (initialize, ping, tools/list, tools/call) by hand — a dependency-free JSON-RPC
// loop is ~150 lines, and pulling in an SDK would mean a second build product to sign and
// notarize. Every tool call is translated to the same JSON the CLI sends and forwarded to
// Rocuronium.app through the authenticated socket; the reply comes back verbatim as text, so
// the agent sees the identical evidence a CLI user would.
@MainActor
enum MCPServer {
    private static let protocolVersion = "2024-11-05"

    /// Tool definitions mirror the socket commands one-to-one. The descriptions carry the
    /// safety semantics — an agent picks tools by reading these, so the cursor and evidence
    /// guarantees belong here, not only in documentation.
    private static let tools: [[String: Any]] = [
        tool(
            "status",
            "Presence and capability report: whether a human is at the keyboard, whether the display can be seen, whether the cursor may be taken. Every action reply also carries this.",
            properties: [:], required: [],
        ),
        tool(
            "find",
            "List interactive elements of a running app via accessibility. Give `label` to search by visible text/placeholder; omit it to list editable fields.",
            properties: [
                "app": ["type": "string", "description": "App name or bundle id, e.g. 'Discord'"],
                "label": ["type": "string", "description": "Substring of the element's label/placeholder"],
            ], required: ["app"],
        ),
        tool(
            "type",
            "Type text into an app without taking the cursor or focus. Confirmed by read-back; control characters are refused unless `submit` is true, so a newline cannot send a message by accident. Pass empty text explicitly to clear a field.",
            properties: [
                "app": ["type": "string"],
                "text": ["type": "string"],
                "label": ["type": "string", "description": "Target field's label; the focused element when omitted"],
                "submit": ["type": "boolean", "description": "Allow Return/Tab in the text"],
                "allowHardwareInput": ["type": "boolean", "description": "Permit the cursor-taking rung as a last resort"],
            ], required: ["app", "text"],
        ),
        tool(
            "click",
            "Click an element by label or screen point, ghost-first (no cursor movement). The reply's verdict says what observably happened; `cursorMovedByUs` reports any takeover.",
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string"],
                "x": ["type": "number"], "y": ["type": "number"],
                "allowHardwareInput": ["type": "boolean"],
            ], required: ["app"],
        ),
        tool(
            "shortcut",
            "Deliver a keyboard shortcut (e.g. 'cmd+a') by pressing the menu item that carries it — works on Chromium, which ignores synthetic keycodes. Dependable on the frontmost app, best-effort in the background; trust the verdict.",
            properties: [
                "app": ["type": "string"],
                "keys": ["type": "string", "description": "cmd+a, cmd+shift+z, cmd+left, ..."],
            ], required: ["app", "keys"],
        ),
        tool(
            "display",
            "Manage the headless virtual display: action 'acquire' leases it (returns a lease id), 'release' gives it back, 'status' reports. Windows parked there are invisible to the person at the Mac.",
            properties: [
                "action": ["type": "string", "enum": ["acquire", "release", "status"]],
                "reason": ["type": "string", "description": "Recorded on the lease — who/why"],
                "minutes": ["type": "number", "description": "Lease duration; 30 by default"],
                "lease": ["type": "string", "description": "Lease id, for release"],
            ], required: ["action"],
        ),
        tool(
            "park",
            "Move an app's primary window onto the virtual display (or to explicit x/y — the reply carries the previous position, which is the undo). Landing is read back as evidence.",
            properties: [
                "app": ["type": "string"],
                "x": ["type": "number"], "y": ["type": "number"],
            ], required: ["app"],
        ),
        tool(
            "screenshot",
            "Capture pixels for the calling model to look at: an app's window (occlusion-proof, works while parked), an explicit region, or the main display. Returns the PNG path.",
            properties: [
                "app": ["type": "string"],
                "x": ["type": "number"], "y": ["type": "number"],
                "w": ["type": "number"], "h": ["type": "number"],
                "path": ["type": "string", "description": "Where to write the PNG; a default under Application Support otherwise"],
            ], required: [],
        ),
    ]

    private static func tool(
        _ name: String, _ description: String,
        properties: [String: Any], required: [String]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
    }

    // MARK: - The loop

    /// Reads newline-delimited JSON-RPC from stdin until EOF. `forward` is the existing
    /// socket transport; each tool call becomes one socket round-trip.
    static func run(forward: ([String: Any]) -> [String: Any]?) -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = message["method"] as? String
            else { continue }
            let id = message["id"]

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "rocuronium", "version": "1.0"],
                ])
            case "ping":
                reply(id, result: [String: Any]())
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                guard let id else { break }  // a call needs an id to answer
                let parameters = message["params"] as? [String: Any] ?? [:]
                reply(id, result: call(parameters, forward: forward))
            default:
                // Notifications (no id) are fine to ignore; unknown *requests* get the
                // standard method-not-found so the client is not left waiting.
                if let id {
                    replyError(id, code: -32601, message: "method '\(method)' not supported")
                }
            }
        }
        exit(0)
    }

    private static func call(
        _ parameters: [String: Any],
        forward: ([String: Any]) -> [String: Any]?
    ) -> [String: Any] {
        guard let name = parameters["name"] as? String,
              tools.contains(where: { $0["name"] as? String == name })
        else {
            return errorContent("unknown tool '\(parameters["name"] ?? "?")'")
        }
        var payload = (parameters["arguments"] as? [String: Any]) ?? [:]
        payload["command"] = name
        guard let socketReply = forward(payload) else {
            return errorContent("could not reach Rocuronium.app — is it running?")
        }
        let text = (try? JSONSerialization.data(withJSONObject: socketReply, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [
            "content": [["type": "text", "text": text]],
            "isError": socketReply["ok"] as? Bool != true,
        ]
    }

    private static func errorContent(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - Transport out

    private static func reply(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func replyError(_ id: Any, code: Int, message: String) {
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
