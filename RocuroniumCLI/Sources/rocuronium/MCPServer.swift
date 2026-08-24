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
            """
            List interactive elements of a running app via accessibility. Give `label` to \
            search by visible text/placeholder (labels first; element *values* as the \
            fallback, so text seen in `read` output is findable); give `role` alone to list \
            all elements of a role; omit both to list editable fields.
            """,
            properties: [
                "app": ["type": "string", "description": "App name or bundle id, e.g. 'Discord'"],
                "label": ["type": "string", "description": "Substring of the element's label/placeholder"],
                "role": ["type": "string", "description": "Element role filter, e.g. 'button' or 'AXButton'"],
            ], required: ["app"],
        ),
        tool(
            "read",
            """
            Read an app's text via accessibility — static text, field values, button titles, \
            checked states — with no pixels and no model. Orders of magnitude cheaper than a \
            screenshot for text-shaped questions, and it works while the screen is locked \
            (though not while the display sleeps; the reply refuses honestly then). Give \
            `label` to read one element's subtree; omit it for the whole main window. \
            Web page content that exposes no accessibility text is reported with a referral \
            naming the channel that can read the DOM — an empty dump there means 'hidden', \
            never 'blank page'.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Read just this element's subtree; the main window when omitted"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
            ], required: ["app"],
        ),
        tool(
            "apps",
            "List running apps (the set a human would see in the Dock): name, bundle id, pid, frontmost, hidden. Read-only.",
            properties: [:], required: [],
        ),
        tool(
            "windows",
            "List an app's windows: title, frame, minimized, main, which display each is on and whether that is the virtual one (rows on the virtual display that nobody parked are flagged 'stray'). Read-only. Use before aiming a click, park, or capture.",
            properties: [
                "app": ["type": "string"],
            ], required: ["app"],
        ),
        tool(
            "wait",
            """
            Block until an element appears (or with `gone`, disappears), polling accessibility. \
            `timeout` caps at 25 seconds because the control socket cancels requests at 30 — a \
            timed-out reply sets callAgain:true and is not an error to retry differently; just \
            call again to keep waiting. `ok` mirrors whether the condition was met.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Substring of the element's label to watch for"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "gone": ["type": "boolean", "description": "Wait for the element to disappear instead"],
                "timeout": ["type": "number", "description": "Seconds to block, 1–25 (default 10)"],
            ], required: ["app", "label"],
        ),
        tool(
            "launch",
            "Launch an app without taking focus, and return only once its accessibility tree answers — ready:true means 'you can drive it now', not merely 'the process started'. Reports alreadyRunning when it was.",
            properties: [
                "app": ["type": "string", "description": "App name, bundle id, or full path"],
            ], required: ["app"],
        ),
        tool(
            "activate",
            """
            Bring an app to the foreground, taking focus — the one thing the ghost verbs \
            promise never to do, offered deliberately as a named, gated verb. Refused while a \
            human is present or recently active unless `confirm` is true. Use when background \
            delivery is not dependable (AppKit apps never validate menus in the background) \
            and bringing the app forward is the honest option. Read-back confirms whether the \
            target actually came forward.
            """,
            properties: [
                "app": ["type": "string"],
                "confirm": ["type": "boolean", "description": "Take focus even though someone is at the Mac"],
            ], required: ["app"],
        ),
        tool(
            "type",
            "Type text into an app without taking the cursor or focus. Confirmed by read-back; control characters are refused unless `submit` is true, so a newline cannot send a message by accident. Pass empty text explicitly to clear a field.",
            properties: [
                "app": ["type": "string"],
                "text": ["type": "string"],
                "label": ["type": "string", "description": "Target field's label; the focused element when omitted"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "submit": ["type": "boolean", "description": "Allow Return/Tab in the text"],
                "allowHardwareInput": ["type": "boolean", "description": "Permit the cursor-taking rung as a last resort"],
            ], required: ["app", "text"],
        ),
        tool(
            "click",
            """
            Click an element by label or screen point, ghost-first (no cursor movement). The \
            reply's verdict says what observably happened; `cursorMovedByUs` reports any \
            takeover. When a label matches several roles (button and menu item sharing a \
            title), pass `role` to disambiguate. A point that lands on a plain group ascends \
            to the enclosing pressable control (SwiftUI wraps buttons this way).
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string"],
                "role": ["type": "string", "description": "Narrow the label match by element role, e.g. 'button'"],
                "x": ["type": "number"], "y": ["type": "number"],
                "allowHardwareInput": ["type": "boolean"],
            ], required: ["app"],
        ),
        tool(
            "shortcut",
            """
            Deliver a keyboard shortcut (e.g. 'cmd+a') by pressing the menu item that carries it — \
            works on Chromium, which ignores synthetic keycodes. Dependable on the frontmost app, \
            best-effort in the background; trust the verdict, not the return.
            HAZARD: every app's menu bar includes the Apple menu, so session-wide items are reachable \
            from any target — cmd+shift+q resolves to Log Out. Items that end the session or destroy \
            data are refused unless `confirm` is true. Use `resolveOnly` to see which menu item a \
            shortcut maps to before pressing it.
            """,
            properties: [
                "app": ["type": "string"],
                "keys": ["type": "string", "description": "cmd+a, cmd+shift+z, cmd+left, ..."],
                "resolveOnly": ["type": "boolean", "description": "Report the menu item without pressing it"],
                "confirm": ["type": "boolean", "description": "Permit a session- or data-destroying item"],
            ], required: ["app", "keys"],
        ),
        tool(
            "scroll",
            """
            Reach off-screen content without touching the cursor. Prefer `label` + any `dy`: \
            the app is asked to bring that element into view (AXScrollToVisible — the one \
            cursor-free scroll mechanism that works, measured), confirmed by the element's \
            frame moving. `to` (0=top … 1=bottom) writes the vertical scroll bar where one \
            exists — some AppKit views expose one; Chromium/Electron never do. Bare `dy`/`dx` \
            falls back to posted wheel events, which every toolkit measured so far ignores — \
            an honest noEffect there means "use label instead", not "retry harder". \
            `untilText` scrolls deterministically to a string the AX tree may not even \
            contain: each step captures the window and OCRs it locally, stopping the moment \
            the text is legible; the reply's foundAt rectangle is ready for a coordinate \
            click, and callAgain:true means the step budget ran out with document left.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Element to bring into view (the mechanism that actually works)"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "dy": ["type": "number", "description": "Vertical pixel delta; positive reveals content below (with untilText: just the direction sign)"],
                "dx": ["type": "number", "description": "Horizontal pixel delta"],
                "to": ["type": "number", "description": "Absolute vertical position, 0 (top) to 1 (bottom)"],
                "untilText": ["type": "string", "description": "Scroll until this string is legible in the frame (local OCR per step; needs Screen Recording)"],
            ], required: ["app"],
        ),
        tool(
            "statusitem",
            """
            List an app's menu bar status items, or press one (press:true) to open its menu \
            or popover — cursor-free. Status items live in a separate extras menu bar that \
            no window walk or find reaches, so this is the only ghost path to a MenuBarExtra. \
            With several items, `label` picks one. Evidence: the target's window count — a \
            popover or status menu opening is a window appearing.
            """,
            properties: [
                "app": ["type": "string"],
                "label": ["type": "string", "description": "Pick one item by label when the app installs several"],
                "press": ["type": "boolean", "description": "Press the item (default: just list)"],
            ], required: ["app"],
        ),
        tool(
            "menu",
            """
            Press a menu item by title path, e.g. path "File > Export" ("▸" works too; \
            matching is case-insensitive and a trailing "…" is optional). Reaches every \
            command that has no keyboard shortcut. Same rails as `shortcut`: dependable on \
            the frontmost app, best-effort in the background (trust the verdict, not the \
            return); session- or data-destroying items are refused unless `confirm` is true; \
            `resolveOnly` reports the resolved item without pressing. A path that names a \
            submenu is refused with its items listed — go one level deeper.
            """,
            properties: [
                "app": ["type": "string"],
                "path": ["type": "string", "description": "Menu title path, levels separated by '>' or '▸'"],
                "resolveOnly": ["type": "boolean", "description": "Report the resolved item without pressing it"],
                "confirm": ["type": "boolean", "description": "Permit a session- or data-destroying item"],
            ], required: ["app", "path"],
        ),
        tool(
            "key",
            """
            Post a bare named key — escape, return, enter, tab, space, delete, forwarddelete, \
            left/right/up/down, home, end, pageup, pagedown — with optional modifiers \
            ('shift+tab', 'cmd+down'). The gap the other input verbs leave: `type` sends text \
            only and `shortcut` reaches only keys a menu item carries. Delivered per-pid \
            without touching cursor or focus. Measured reach: lands in the app's focused \
            text control (`return` in an address bar commits navigation) — but sheet \
            key-equivalents do NOT actuate: escape will not cancel a save sheet; press the \
            sheet's button instead (click label 'Cancel' role 'button'). Electron/Chromium \
            ignore posted keycodes entirely. For printable characters use `type`; for \
            letter shortcuts use `shortcut`.
            """,
            properties: [
                "app": ["type": "string"],
                "keys": ["type": "string", "description": "escape, shift+tab, cmd+down, ..."],
            ], required: ["app", "keys"],
        ),
        tool(
            "move",
            """
            Glide the REAL cursor along a path and leave it on the destination — the verb for \
            hover menus, tooltips, hover-intent flows, and anything that tracks pointer \
            motion. There is no ghost variant: per-pid posted motion is dropped by the window \
            server (measured), so this takes the physical cursor and is refused while a human \
            is present unless `confirm` is true. Destination is `end` ("x,y" in screen \
            points) or an element by `label` (+`app`); `via` waypoints bend the path into a \
            smooth curve through them (glide from a nav tab down into its flyout). Starts \
            from the current cursor position unless `start` is given. Evidence: the cursor's \
            actual end position is read back, and with `app` the target's window count \
            before/after is reported — a flyout appearing is a window appearing. Caveats \
            measured: hover lands on whatever window is TOPMOST at the point (occlusion is \
            refused when `app` is given); WebKit/WKWebView pages ignore motion while their \
            app is not frontmost — `activate` first for web hover.
            """,
            properties: [
                "end": ["type": "string", "description": "Destination \"x,y\" in screen points (top-left origin)"],
                "app": ["type": "string", "description": "Target app — enables label aiming, occlusion refusal, window-count evidence"],
                "label": ["type": "string", "description": "Aim at this element's center instead of end"],
                "role": ["type": "string", "description": "Narrow the label match by element role"],
                "start": ["type": "string", "description": "Path start \"x,y\"; current cursor position when omitted"],
                "via": ["type": "string", "description": "Waypoints the curve passes through: \"x,y x,y …\""],
                "duration": ["type": "number", "description": "Gesture seconds, 0.05–10; distance-based default"],
                "easing": ["type": "string", "enum": ["linear", "ease-in", "ease-out", "ease-in-out"]],
                "restore": ["type": "boolean", "description": "Put the cursor back afterwards (defeats hover — default off)"],
                "confirm": ["type": "boolean", "description": "Take the cursor even though someone is at the Mac"],
            ], required: [],
        ),
        tool(
            "drag",
            """
            Drag along a path with a mouse button held: down at `start`, real motion through \
            any `via` waypoints, up at `end`. Moves content, sliders, selection ranges, and \
            windows (title-bar drags work even on background windows, measured). Same \
            hardware-rung rules as `move`: takes the physical cursor, presence-gated behind \
            `confirm`, occlusion at the start point refused when `app` is given. An aborted \
            drag (lock/cancel mid-path) releases the button where it stopped — never left \
            held. Note: apps reading drag *deltas* get exact double-precision values; apps \
            reading positions get the same path — both measured working.
            """,
            properties: [
                "start": ["type": "string", "description": "Where the button goes down: \"x,y\""],
                "end": ["type": "string", "description": "Where it is released: \"x,y\""],
                "app": ["type": "string", "description": "Target app — enables occlusion refusal and window-count evidence"],
                "via": ["type": "string", "description": "Waypoints the drag curves through: \"x,y x,y …\""],
                "button": ["type": "string", "enum": ["left", "right"]],
                "duration": ["type": "number", "description": "Gesture seconds, 0.05–10; distance-based default"],
                "easing": ["type": "string", "enum": ["linear", "ease-in", "ease-out", "ease-in-out"]],
                "restore": ["type": "boolean", "description": "Put the cursor back after releasing"],
                "confirm": ["type": "boolean", "description": "Take the cursor even though someone is at the Mac"],
            ], required: ["start", "end"],
        ),
        tool(
            "display",
            "Manage the headless virtual display: action 'acquire' leases it (returns a lease id), 'release' gives it back and sweeps parked windows home, 'status' reports leases, parked windows, and strays (windows on the display nobody parked). Windows parked there are invisible to the person at the Mac.",
            properties: [
                "action": ["type": "string", "enum": ["acquire", "release", "status"]],
                "reason": ["type": "string", "description": "Recorded on the lease — who/why"],
                "minutes": ["type": "number", "description": "Lease duration; 30 by default"],
                "lease": ["type": "string", "description": "Lease id, for release"],
            ], required: ["action"],
        ),
        tool(
            "park",
            "Move an app's primary window onto the virtual display (or to explicit x/y — the reply carries the previous position, which is the undo). Landing is read back as evidence. With no lease in force this takes an auto-lease (id in the reply) that releases itself — and sweeps its windows home — when the last parked window is returned or closes. Attaching a display while a human is at the keyboard is refused without allowDisplayAttach, since attach is a visible event.",
            properties: [
                "app": ["type": "string"],
                "x": ["type": "number"], "y": ["type": "number"],
                "allowDisplayAttach": ["type": "boolean", "description": "Attach a virtual display even though someone is at the Mac"],
            ], required: ["app"],
        ),
        tool(
            "activity",
            """
            The session's recent agent actions with their evidence verdicts (last 200, \
            newest last) — the same record the human sees in the menu bar. Read-only. Also \
            reports `halted`: true means the human pressed ⌥⎋ and every acting/perceiving \
            verb is refused until they resume from the Rocuronium menu bar — do not retry, \
            and do not attempt to work around it.
            """,
            properties: [:], required: [],
        ),
        tool(
            "demo",
            """
            Open Rocuronium's deterministic demo stage — a fixed practice window at \
            (720, 200), 560×720, with instrumented targets for every verb: a click counter, \
            a text field with an echo, a switch, a slider, a hover pad, and a 120-row \
            scroll list whose needle is 'Row 87 · the needle'. Drive it with app \
            'Rocuronium'; every consequence is readable back. Action 'reset' (default) \
            zeroes the counters, 'show' keeps state, 'hide' closes it.
            """,
            properties: [
                "action": ["type": "string", "enum": ["show", "reset", "hide"]],
            ], required: [],
        ),
        tool(
            "screenshot",
            "Capture pixels for the calling model to look at: an app's window (occlusion-proof, works while parked), an explicit region, or the main display. Returns the PNG path.",
            properties: [
                "app": ["type": "string"],
                "x": ["type": "number"], "y": ["type": "number"],
                "w": ["type": "number"], "h": ["type": "number"],
                "path": ["type": "string", "description": "Where to write the PNG. Must end in .png, must not already exist, and must be under Desktop, Downloads, Pictures, /tmp, or the app's captures folder. Omit for a default path."],
            ], required: [],
        ),
    ]

    private static func tool(
        _ name: String, _ description: String,
        properties: [String: Any], required: [String]
    ) -> [String: Any] {
        // Every tool that targets an app also accepts a pid, uniformly: it overrides `app`
        // and is the only unambiguous address when two instances share a bundle id.
        var properties = properties
        if properties["app"] != nil, properties["pid"] == nil {
            properties["pid"] = [
                "type": "number",
                "description": "Target this process id directly (overrides 'app') — for when two running instances share a name or bundle id",
            ]
        }
        return [
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
        // Forward only the keys this tool declares. A schema is documentation, not a filter:
        // copying `arguments` wholesale would honor properties the tool never advertised —
        // `allowHardwareInput` smuggled into a tool whose schema has no such field, for
        // instance, escalating past the rungs the description promised. `command` is assigned
        // after the copy so it can never be overridden by an argument.
        let declared = Set(schemaProperties(of: name))
        let arguments = (parameters["arguments"] as? [String: Any]) ?? [:]
        var payload = arguments.filter { declared.contains($0.key) }
        let rejected = arguments.keys.filter { !declared.contains($0) }.sorted()
        guard rejected.isEmpty else {
            return errorContent(
                "'\(name)' does not accept \(rejected.map { "'\($0)'" }.joined(separator: ", "))"
                    + " — accepted: \(declared.sorted().joined(separator: ", "))",
            )
        }
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

    private static func schemaProperties(of tool: String) -> [String] {
        guard let definition = tools.first(where: { $0["name"] as? String == tool }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any]
        else { return [] }
        return Array(properties.keys)
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
