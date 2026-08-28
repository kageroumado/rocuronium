import Darwin
import Foundation

// rocuronium — a thin client for the control socket.
//
// This binary intentionally knows nothing about accessibility, input synthesis, or windows.
// All of that lives in Rocuronium.app, which holds the Accessibility grant; a CLI would need
// its own grant and would lose it on every rebuild. Here we only translate arguments into
// JSON, hand them to the socket, and print what comes back.

let socketPath = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "glass.kagerou.rocuronium")
    .appending(path: "control.sock")
    .path

let usage = """
rocuronium — drive this Mac without taking the cursor

  rocuronium status
  rocuronium apps
  rocuronium windows    --app <name>
  rocuronium find       --app <name> [--label <text>] [--role <button|…>]
  rocuronium read       --app <name> [--label <text>] [--role <r>] [--since <token>]
  rocuronium wait       --app <name> --label <text> [--role <r>] [--gone] [--timeout <s, max 25>]
  rocuronium type       --app <name> --text <text> [--label <text>] [--role <r>]
  rocuronium click      --app <name> [--label <text>] [--role <r>] [--x <n> --y <n>]
  rocuronium scroll     --app <name> --label <text> --dy <px>   (bring element into view)
  rocuronium scroll     --app <name> (--dy <px> [--dx <px>] | --to <0..1>)
  rocuronium scroll     --app <name> --until-text <string> [--dy <±px: direction>]
  rocuronium statusitem --app <name> [--label <text>] [--press]
  rocuronium shortcut   --app <name> --keys <cmd+a> [--resolve-only] [--confirm]
  rocuronium menu       --app <name> --path "File > Export" [--resolve-only] [--confirm]
  rocuronium key        --app <name> --keys <escape|shift+tab|cmd+down|…>
  rocuronium move       (--to <x,y> | --app <name> --label <text> [--role <r>])
                        [--from <x,y>] [--via "<x,y> <x,y>…"] [--duration <s>]
                        [--easing <linear|ease-in|ease-out|ease-in-out>] [--restore] [--confirm]
  rocuronium drag       --from <x,y> --to <x,y> [--via …] [--button <left|right>]
                        [--app <name>] [--duration <s>] [--easing <e>] [--restore] [--confirm]
  rocuronium launch     --app <name>
  rocuronium activate   --app <name> [--confirm]
  rocuronium activity   (recent agent actions with their evidence verdicts)
  rocuronium demo       [show|reset|hide]  (deterministic practice window, --app Rocuronium)
  rocuronium display    <acquire|release|status> [--reason <text>] [--minutes <n>] [--lease <id>]
  rocuronium park       --app <name> [--x <n> --y <n>]
  rocuronium screenshot [--app <name>] [--x <n> --y <n> --w <n> --h <n>] [--path <file>]
                        [--since <token>]
  rocuronium mcp        (serve these commands as MCP tools over stdio)
  rocuronium guide      (print the operator's manual — evidence, presence, refusals)

Options:
  --allow-hardware-input   permit the hardware tentacle: real-cursor actions, session-level keys (default: no)
  --pid <n>                target a process directly (when two instances share a bundle id)
  --json                   print the raw reply

'read' dumps an app's text via accessibility — no pixels, works behind a locked screen.
Every 'read' and 'screenshot' reply carries an observation token; pass it back as
--since to get only what changed — appeared/vanished/value-changed elements for 'read',
changed-region crops (or "content scrolled ~N") for 'screenshot'. A token that cannot be
diffed honestly (evicted, other window, resized) degrades to a full reply with a note.
'key' posts a bare named key (escape, return, tab, arrows, home/end, page up/down) with
optional modifiers — for what 'type' (text) and 'shortcut' (menu items) cannot send;
AppKit honors it, Electron ignores posted keycodes. '--role' narrows a label match when
two roles share the text (a button and a menu item both named "Restart", say).
'wait' blocks until the element appears (--gone: disappears); a timed-out reply says to
call again, because the socket cancels requests at 30 s. 'launch' starts an app without
taking focus and returns once it can be driven; 'activate' takes focus on purpose and is
refused while a human is present unless --confirm. 'display' leases the headless virtual
screen; 'park' moves an app's window onto it (or to an explicit point — the reply carries
the previous position, which is how you put it back). Parking with no lease takes an
auto-lease (reason recorded from the command, id in the reply) that releases itself when
its last parked window is returned or closes; attaching the display is visually silent on
the real screen (measured), so no extra flag is needed. 'display status'
also lists strays — windows on the virtual display nobody parked. 'screenshot' hands the
pixels to you, the caller: your model does the looking.

'scroll --until-text' captures the window each step, OCRs it locally, and stops the moment
the string is legible — deterministic where a pixel delta overshoots; the reply carries the
sighting's screen rectangle, ready for a coordinate click. 'statusitem' lists an app's menu
bar status items (a separate bar no window walk reaches) and --press opens one's menu or
popover, cursor-free.

'move' glides the REAL cursor along a path (straight line, or a curve through --via
waypoints) and leaves it on the destination — the way to drive hover menus, tooltips, and
hover-intent flows; 'drag' does the same with a button held. Both take the physical
cursor, so both are refused while a human is present unless --confirm, and both leave the
pointer where the path ends unless --restore. With --app they refuse when another app's
window covers the action point, and they report the target's window count before/after —
a flyout appearing is a window appearing.

Cursor-taking commands show the visible-agent overlay (tint + bezel + jellyfish); ⌃⌥⇧⎋
halts the engine mid-action, and every verb is then refused until the human resumes from
the Rocuronium menu bar. 'activity' returns the session's action log with verdicts.

Every reply reports whether a human is present; hardware input stays off unless asked for.
"""

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !command.hasPrefix("-") else {
    print(usage)
    exit(arguments.isEmpty ? 0 : 2)
}
arguments.removeFirst()

@MainActor
func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(flag)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// The operator's manual, embedded at build time from README.md. Needs no socket and no
// running app: an agent holding nothing but this binary can learn the contract.
if command == "guide" {
    print(Guide.text)
    exit(0)
}

// MCP mode: a stdio tool server for agent harnesses. Register with e.g.
//   claude mcp add rocuronium -- /Applications/Rocuronium.app/Contents/Resources/rocuronium mcp
// Runs until stdin closes; every tool call is one authenticated socket round-trip.
if command == "mcp" {
    MCPServer.run(forward: send)
}

var payload: [String: Any] = ["command": command]
// `display` and `demo` take a positional subcommand: `rocuronium display acquire`.
if command == "display" || command == "demo", let action = arguments.first, !action.hasPrefix("-") {
    payload["action"] = action
    arguments.removeFirst()
}
// `plan` reads its step list from --file <path> or stdin.
if command == "plan" {
    let jsonData: Data
    if let filePath = value(for: "file") {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            FileHandle.standardError.write(Data("rocuronium: cannot read '\(filePath)'\n".utf8))
            exit(2)
        }
        jsonData = data
    } else if isatty(STDIN_FILENO) == 0 {
        jsonData = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        FileHandle.standardError.write(Data("rocuronium plan: pipe JSON to stdin or pass --file <path>\n".utf8))
        exit(2)
    }
    do {
        guard let planJSON = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            FileHandle.standardError.write(Data("rocuronium plan: expected a JSON object with 'steps'\n".utf8))
            exit(2)
        }
        if let steps = planJSON["steps"] { payload["steps"] = steps }
        if let profile = planJSON["profile"] { payload["profile"] = profile }
    } catch {
        FileHandle.standardError.write(Data("rocuronium plan: invalid JSON — \(error.localizedDescription)\n".utf8))
        exit(2)
    }
}
for flag in ["app", "label", "role", "text", "reason", "lease", "path", "keys", "easing", "button", "via", "since"] {
    if let found = value(for: flag) { payload[flag] = found }
}
// Kebab-case on the command line, camelCase on the wire.
if let found = value(for: "until-text") { payload["untilText"] = found }
// The path verbs speak in points: --from/--to are "x,y" strings there, while scroll's
// --to is the numeric 0…1 fraction the loop below parses.
let pathVerb = command == "move" || command == "drag"
if pathVerb {
    if let found = value(for: "from") { payload["start"] = found }
    if let found = value(for: "to") { payload["end"] = found }
}
for flag in ["x", "y", "w", "h", "minutes", "timeout", "dx", "dy", "duration", "pid"] + (pathVerb ? [] : ["to"]) {
    guard let found = value(for: flag) else { continue }
    // `Double("inf")` and `Double("nan")` parse happily, and `JSONSerialization` then raises
    // an *uncatchable* ObjC exception ("Invalid number value (infinite) in JSON write") that
    // takes this process down before the request is ever sent. Reject it here, where the
    // caller can be told what was wrong, rather than dying mid-serialization.
    guard let number = Double(found), number.isFinite else {
        FileHandle.standardError.write(Data("rocuronium: --\(flag) must be a finite number, got '\(found)'\n".utf8))
        exit(2)
    }
    payload[flag] = number
}
if arguments.contains("--allow-hardware-input") { payload["allowHardwareInput"] = true }
if arguments.contains("--submit") { payload["submit"] = true }
if arguments.contains("--gone") { payload["gone"] = true }
if arguments.contains("--press") { payload["press"] = true }
// `shortcut` can reach Log Out from any app, so seeing what a shortcut resolves to is a
// first-class operation, and pressing a destructive item takes a deliberate second flag.
if arguments.contains("--resolve-only") { payload["resolveOnly"] = true }
if arguments.contains("--confirm") { payload["confirm"] = true }
if arguments.contains("--restore") { payload["restore"] = true }
let wantsRawJSON = arguments.contains("--json")

// MARK: - Transport

@MainActor
func send(_ payload: [String: Any]) -> [String: Any]? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard socketPath.utf8.count < capacity else { return nil }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        socketPath.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, capacity - 1)
        }
    }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    guard var request = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    request.append(0x0A)
    _ = request.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return 0 }
        var offset = 0
        while offset < request.count {
            let written = write(descriptor, base + offset, request.count - offset)
            guard written > 0 else { break }
            offset += written
        }
        return offset
    }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { break }
        reply.append(contentsOf: buffer[0 ..< count])
        if reply.last == 0x0A { break }
    }
    return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
}

// MARK: - Output

guard let reply = send(payload) else {
    FileHandle.standardError.write(Data("""
    rocuronium: could not reach Rocuronium.app.
    Is it running? The control socket is at \(socketPath)

    """.utf8))
    exit(1)
}

if wantsRawJSON, let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
    exit(reply["ok"] as? Bool == true ? 0 : 1)
}

if let error = reply["error"] as? String {
    FileHandle.standardError.write(Data("rocuronium: \(error)\n".utf8))
    exit(1)
}

switch command {
case "status":
    // JSON booleans arrive as NSNumber and would otherwise print as 0 and 1.
    func yesNo(_ key: String) -> String { reply[key] as? Bool == true ? "yes" : "no" }
    let trusted = reply["trusted"] as? Bool == true
    print("presence      \(reply["presence"] ?? "?")  (idle \(reply["idleSeconds"] ?? "?")s)")
    print("accessibility \(trusted ? "granted" : "NOT GRANTED — nothing works until it is")")
    print("can see       \(yesNo("canSee"))  (display asleep: \(yesNo("displayAsleep")))")
    print("screen locked \(yesNo("screenLocked"))  — harmless; only display sleep blinds the engine")
    if let advice = reply["advice"] as? String { print("\n\(advice)") }

case "find":
    let matches = reply["matches"] as? [[String: Any]] ?? []
    if matches.isEmpty {
        print("no matches" + ((reply["truncated"] as? Bool == true) ? " (search was truncated — try a narrower query)" : ""))
    }
    for match in matches {
        let frame = match["frame"] as? [String: Any] ?? [:]
        let position = frame.isEmpty ? "" : "  @(\(Int(frame["x"] as? Double ?? 0)),\(Int(frame["y"] as? Double ?? 0)))"
        print("\(match["role"] ?? "?")  '\(match["label"] ?? "")'\(position)  depth \(match["depth"] ?? "?")")
    }
    print("\n\(matches.count) shown · \(reply["elementsVisited"] ?? 0) elements visited"
        + ((reply["truncated"] as? Bool == true) ? " · TRUNCATED" : ""))

case "read" where reply["delta"] != nil:
    print(reply["delta"] as? String ?? "")
    print("\n\(reply["summary"] as? String ?? "")")
    if let token = reply["token"] as? String { print("token \(token)") }

case "read":
    for line in reply["lines"] as? [[String: Any]] ?? [] {
        let indent = String(repeating: "  ", count: line["depth"] as? Int ?? 0)
        let title = line["title"] as? String ?? ""
        let value = line["value"] as? String ?? ""
        let role = line["role"] as? String ?? "?"
        // Static text reads as prose; anything interactive keeps its role visible so the
        // reader knows it can be acted on.
        let annotation = role == "AXStaticText" ? "" : "  [\(role)]"
        let text = [title, value].filter { !$0.isEmpty }.joined(separator: ": ")
        print("\(indent)\(text)\(annotation)")
    }
    print("\nread \(reply["scope"] as? String ?? "?") · \(reply["characters"] ?? 0) chars · \(reply["elementsVisited"] ?? 0) elements"
        + ((reply["truncated"] as? Bool == true) ? " · TRUNCATED: \(reply["truncationReason"] as? String ?? "?")" : ""))
    if let note = reply["diffNote"] as? String { print("→ \(note)") }
    if let token = reply["token"] as? String { print("token \(token)") }
    if let referral = reply["referral"] as? [String: Any] {
        print("→ \(referral["reason"] ?? "")")
        print("→ use \(referral["channel"] ?? "?"): \(referral["advice"] ?? "")")
    }

case "apps":
    for app in reply["apps"] as? [[String: Any]] ?? [] {
        let marks = [
            app["frontmost"] as? Bool == true ? "  (frontmost)" : "",
            app["hidden"] as? Bool == true ? "  (hidden)" : "",
        ].joined()
        print("\(app["name"] ?? "?")  ·  \(app["bundleID"] ?? "?")  ·  pid \(app["pid"] ?? "?")\(marks)")
    }

case "windows":
    for window in reply["windows"] as? [[String: Any]] ?? [] {
        let frame = window["frame"] as? [String: Any] ?? [:]
        let geometry = frame.isEmpty ? "no frame" :
            "@(\(Int(frame["x"] as? Double ?? 0)),\(Int(frame["y"] as? Double ?? 0))) "
            + "\(Int(frame["w"] as? Double ?? 0))x\(Int(frame["h"] as? Double ?? 0))"
        let marks = [
            window["main"] as? Bool == true ? "  [main]" : "",
            window["minimized"] as? Bool == true ? "  [minimized]" : "",
            window["onVirtualDisplay"] as? Bool == true ? "  [virtual display]" : "",
            window["onAnyDisplay"] as? Bool == false ? "  [ON NO DISPLAY]" : "",
        ].joined()
        print("'\(window["title"] ?? "")'  \(geometry)\(marks)")
    }

case "display":
    print(reply["summary"] as? String ?? "done")
    // The lease id is the one thing the caller must keep; print it where a script can grab it.
    if let lease = reply["lease"] as? String { print("lease \(lease)") }
    for lease in reply["leases"] as? [[String: Any]] ?? [] {
        let kind = (lease["kind"] as? String).map { " [\($0)]" } ?? ""
        let parked = lease["parkedWindows"] as? Int ?? 0
        print("  · \(lease["id"] ?? "?")\(kind)  (\(lease["reason"] ?? ""))"
            + (parked > 0 ? "  \(parked) parked" : ""))
    }
    for window in reply["parked"] as? [[String: Any]] ?? [] {
        print("  parked: '\(window["title"] ?? "?")'  pid \(window["pid"] ?? "?")")
    }
    // A stray is a window a human cannot see and nobody is going to sweep home.
    for stray in reply["strays"] as? [[String: Any]] ?? [] {
        print("  STRAY: '\(stray["title"] ?? "?")'  (\(stray["app"] ?? "?"), pid \(stray["pid"] ?? "?"))")
    }
    if let screen = reply["screen"] as? [String: Any] {
        print("screen @(\(Int(screen["x"] as? Double ?? 0)),\(Int(screen["y"] as? Double ?? 0))) "
            + "\(Int(screen["w"] as? Double ?? 0))x\(Int(screen["h"] as? Double ?? 0)) pt")
    }

case "park":
    print(reply["summary"] as? String ?? "done")
    // The previous position is the undo: `park --x --y` with these numbers puts it back.
    if let before = reply["before"] as? [String: Any] {
        print("was @(\(Int(before["x"] as? Double ?? 0)),\(Int(before["y"] as? Double ?? 0)))")
    }
    // The auto-lease id, for a caller who wants to release explicitly rather than un-park.
    if let lease = reply["lease"] as? String { print("lease \(lease)") }

case "screenshot":
    if let regions = reply["regions"] as? [[String: Any]], reply["changed"] != nil {
        // Diff reply: region crops, a scroll report, or "nothing changed".
        if regions.isEmpty, reply["changed"] as? Bool == false {
            print(reply["summary"] as? String ?? "no visible change")
        }
        for (index, region) in regions.enumerated() {
            let rect = region["rect"] as? [String: Any] ?? [:]
            print("region \(index + 1): @(\(Int(rect["x"] as? Double ?? 0)),\(Int(rect["y"] as? Double ?? 0))) "
                + "\(Int(rect["w"] as? Double ?? 0))x\(Int(rect["h"] as? Double ?? 0)) → \(region["path"] ?? "?")")
        }
    } else if reply["scrolledBy"] != nil {
        print(reply["summary"] as? String ?? "content scrolled")
    } else {
        print(reply["path"] as? String ?? "done")
        if let note = reply["diffNote"] as? String { print("→ \(note)") }
    }
    if let token = reply["token"] as? String { print("token \(token)") }

case "plan":
    for step in reply["transcript"] as? [[String: Any]] ?? [] {
        let mark: String
        if step["guardPassed"] as? Bool == false {
            mark = " ✗ \(step["guardReason"] as? String ?? "guard failed")"
                + (step["policy"].map { " [\($0)]" } ?? "")
        } else if step["guardPassed"] as? Bool == true {
            mark = " ✓ \(step["guardReason"] as? String ?? "")"
        } else {
            mark = ""
        }
        let verdict = (step["verdict"] as? String).map { "  [\($0)]" } ?? ""
        print("  \(step["step"] ?? "?"). \(step["intent"] ?? "?")\(verdict)\(mark)")
        if let fallback = step["fallback"] as? [String: Any] {
            print("     fallback: \(fallback["summary"] as? String ?? fallback["error"] as? String ?? "?")")
        }
    }
    print(reply["summary"] as? String ?? "done")

case "activity":
    for entry in reply["entries"] as? [[String: Any]] ?? [] {
        let date = (entry["date"] as? String ?? "").suffix(9).prefix(8)  // HH:MM:SS out of ISO8601
        print("\(date)  \(entry["action"] ?? "?") \(entry["target"] ?? "")  → \(entry["verdict"] ?? "?")")
    }
    print(reply["summary"] as? String ?? "")

case "statusitem" where reply["items"] != nil:
    for item in reply["items"] as? [[String: Any]] ?? [] {
        let frame = item["frame"] as? [String: Any] ?? [:]
        let position = frame.isEmpty ? "" : "  @(\(Int(frame["x"] as? Double ?? 0)),\(Int(frame["y"] as? Double ?? 0)))"
        print("\(item["role"] ?? "?")  '\(item["label"] ?? "")'\(position)")
    }
    print(reply["summary"] as? String ?? "")

default:
    print(reply["summary"] as? String ?? "done")
    // Which menu item delivered a shortcut — "Edit ▸ Select All", not just "it was pressed".
    if let menuItem = reply["menuItem"] as? String, !menuItem.isEmpty {
        print("menu item: \(menuItem)")
    }
    if let hazard = reply["hazard"] as? String { print("⚠︎ this item \(hazard)") }
    if let note = reply["note"] as? String { print("note: \(note)") }
    if let readback = reply["readback"] as? String, !readback.isEmpty {
        print("read back: \(readback.prefix(80))")
    }
    // Where OCR sighted the text — the coordinates a follow-up click aims at.
    if let found = reply["foundAt"] as? [String: Any] {
        let x = (found["x"] as? Double ?? 0) + (found["w"] as? Double ?? 0) / 2
        let y = (found["y"] as? Double ?? 0) + (found["h"] as? Double ?? 0) / 2
        print("found at: center (\(Int(x)), \(Int(y)))")
    }
    if reply["callAgain"] as? Bool == true {
        print("more document remains — call again to keep searching")
    }
    // The whole point of the tool: say plainly whether the human's cursor was touched.
    // Movement under a ghost tentacle is the user's own hand — warning about it would train
    // people to ignore the one warning that matters.
    if reply["cursorMovedByUs"] as? Bool == true { print("⚠︎ the cursor was taken") }
    else if reply["cursorMovedByUser"] as? Bool == true { print("(cursor moved — yours, not ours)") }
    if reply["focusTakenByUs"] as? Bool == true { print("⚠︎ focus was taken — the target app came forward") }
    else if reply["frontmostChanged"] as? Bool == true { print("(frontmost changed — not to our target, so not ours)") }
    if let attempts = reply["attempts"] as? [[String: Any]] {
        for attempt in attempts { print("  · \(attempt["tentacle"] ?? "?"): \(attempt["outcome"] ?? "")") }
    }
    // The referral is the actionable part of a failure on web content: it names the channel
    // that can reach what the ghost tentacles cannot.
    if let referral = reply["referral"] as? [String: Any] {
        print("→ \(referral["reason"] ?? "unreachable")")
        print("→ use \(referral["channel"] ?? "?"): \(referral["advice"] ?? "")")
    }
}

exit(reply["ok"] as? Bool == true ? 0 : 1)
