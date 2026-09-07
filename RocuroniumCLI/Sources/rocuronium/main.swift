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

Observe
  status                                   presence, permissions, halted, display hold
  diag                                     what each permission check really returns
  apps                                     running apps: name, bundle id, pid, frontmost
  windows    --app <a>                     titles and frames
  find       --app <a> [--label <t>] [--role <r>] [--all] [--limit <n>] [--offset <n>] [--ocr]
  read       --app <a> [--label <t>] [--role <r>] [--since <token>] [--ocr]   text, or the delta
  wait       --app <a> (--label <t> [--role <r>] [--gone] | --for '<guard json>')
                        [--timeout <s, max 25>]
  screenshot [--app <a> | --x --y --w --h] [--path <f.png>] [--since <token>]
  activity                                 the last 50 acting commands with verdicts

Act — ghost first; every reply carries verdict, tentacle, attempts
  type       --app <a> --text <t> [--label <t>] [--role <r>] [--submit]
  click      --app <a> (--label <t> [--role <r>] | --x <n> --y <n>) [--observe]
             [--button left|right] [--count 2] [--modifiers cmd,shift] [--foreground]
  key        --app <a> --keys <escape|return|tab|shift+tab|cmd+down|…>
  shortcut   --app <a> --keys <cmd+a> [--resolve-only] [--confirm] [--observe]   presses the menu item
  menu       --app <a> --path "File > Export" [--resolve-only] [--confirm] [--observe]
  scroll     --app <a> (--label <t> | --to <0..1> | --dy <px> [--dx <px>]
                        | --until-text <s> [--dy <±1>])
  statusitem --app <a> [--label <t>] [--press]
  launch     --app <name|bundle id|path> [--confirm]   (--confirm to interrupt a fullscreen app)
  activate   --app <a> [--confirm]                      (--confirm to interrupt a fullscreen app)
  plan       --file <steps.json>           (or JSON on stdin)

Cursor paths — take the real cursor; refused while a human is present or an app is fullscreen unless --confirm
  move       (--to <x,y> | --app <a> --label <t> [--role <r>]) [--from <x,y>]
             [--via "<x,y> <x,y>…"] [--duration <s>] [--dwell <ms>]
             [--easing <linear|ease-in|ease-out|ease-in-out>] [--restore] [--confirm]
             (with --app, reports what the hover revealed in the tree)
  drag       --from <x,y> --to <x,y> [--via …] [--button <left|right>] [--app <a>]
             [--duration <s>] [--dwell <ms>] [--easing <e>] [--restore] [--confirm]

Windows
  resize     --app <a> --width <w> --height <h> [--x <px> --y <py>]   ghost AX resize/move
  display    <acquire|release|status> [--reason <t>] [--minutes <n>] [--lease <id>]
  park       --app <a> [--x <n> --y <n>]   onto the virtual display, or back to a point

Meta
  busy       [on|off] [--note <t>]           hold the presence overlay up while you work,
                                             so "creature gone" means "nothing is coming"
  demo       [show|reset|hide|render --path <f.png>]   practice window, --app Rocuronium
  request-capture                          fire the Screen Recording prompt
  mcp                                      serve these verbs as MCP tools over stdio

Options
  --pid <n>                 target a process directly; overrides --app
  --window <title substr>   scope to one window (find/read/click/type/wait/screenshot/
                            move/drag/park/resize); ambiguity is refused with each
                            candidate's index and frame
  --window-index <n>        pick among same-titled windows by 0-based position (the order
                            `windows` prints and the ambiguity error lists)
  --window-at <x,y>         pick the window whose frame contains this screen point
  --allow-hardware-input    permit the sting on type, click, key: real cursor, session keys
  --foreground              on click, skip the ghost tentacles: activate the app and click with
                            the real cursor so the press is a genuine gesture that can raise a
                            system permission prompt (TCC, notifications). Implies
                            --allow-hardware-input; refused while a human is present unless --confirm
  --observe                 on click/shortcut/menu, diff the window's AX tree across the
                            action and report what changed (walks a large tree it would skip)
  --ocr                     on read/find, read the window's pixels instead of the AX tree —
                            for apps whose tree is empty. Text rows come back groundedBy ocr;
                            with the UI Detector model installed, control boxes (icon buttons
                            included) come back groundedBy detector (needs Screen Recording)
  --json                    print the raw reply

Eight things to know:
  1. Trust `verdict`, never the exit code. confirmed · noEffect (success was reported and
     nothing changed: change mechanism, do not retry harder) · unverifiable (it may have
     landed: verify before retrying).
  2. Coordinates are points, origin at the top-left of the main display, everywhere.
  3. `--label` is a case-insensitive substring of title, description, placeholder, then
     value. Ambiguity is refused; narrow with --role. An icon-only button has an empty
     label and a roleDescription of 'button' — match its help, identifier, or near instead.
  4. `type` sets the field's value through accessibility; when that is refused it falls
     through to keystrokes at the caret. The reply's tentacle says which happened.
  5. `read` returns a token; `read --since <token>` returns only what changed. Pixels miss
     small consequences; the tree diff does not.
  6. `shortcut` presses the menu item bound to the keys; `key` sends a bare key. Electron
     ignores posted keycodes; unicode text still lands.
  7. Every reply reports presence. Cursor-taking verbs are refused while someone is here.
  8. Display asleep blinds every app; a locked screen does not.
"""

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
// Asking for help is a success; only an unparseable invocation exits 2.
let helpWords: Set<String> = ["--help", "-h", "help"]
guard let command = arguments.first, !command.hasPrefix("-"), !helpWords.contains(command) else {
    print(usage)
    exit(arguments.isEmpty || helpWords.contains(arguments[0]) ? 0 : 2)
}
arguments.removeFirst()

@MainActor
func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(flag)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// MCP mode: a stdio tool server for agent harnesses. Register with e.g.
//   claude mcp add rocuronium -- /Applications/Rocuronium.app/Contents/Resources/rocuronium mcp
// Runs until stdin closes; every tool call is one authenticated socket round-trip.
if command == "mcp" {
    MCPServer.run(forward: send)
}

var payload: [String: Any] = ["command": command]
// `display` and `demo` take a positional subcommand: `rocuronium display acquire`.
if command == "display" || command == "demo" || command == "busy", let action = arguments.first, !action.hasPrefix("-") {
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
for flag in ["app", "label", "role", "text", "reason", "lease", "path", "keys", "easing", "button", "via", "since", "window", "modifiers", "note"] {
    if let found = value(for: flag) { payload[flag] = found }
}
// Kebab-case on the command line, camelCase on the wire.
if let found = value(for: "until-text") { payload["untilText"] = found }
if let found = value(for: "window-at") { payload["windowAt"] = found }
// `wait --for` carries a JSON guard object, forwarded as `expect` — the same grammar a
// plan step's `expect` uses.
if let guardJSON = value(for: "for") {
    guard let object = try? JSONSerialization.jsonObject(with: Data(guardJSON.utf8)) as? [String: Any] else {
        FileHandle.standardError.write(Data(
            "rocuronium wait: --for expects a JSON guard object, e.g. --for '{\"type\":\"quiet\",\"ms\":800}'\n".utf8))
        exit(2)
    }
    payload["expect"] = object
}
// The path verbs speak in points: --from/--to are "x,y" strings there, while scroll's
// --to is the numeric 0…1 fraction the loop below parses.
let pathVerb = command == "move" || command == "drag"
if pathVerb {
    if let found = value(for: "from") { payload["start"] = found }
    if let found = value(for: "to") { payload["end"] = found }
}
for flag in ["x", "y", "w", "h", "minutes", "timeout", "dx", "dy", "duration", "pid", "dwell", "count", "limit", "offset"] + (pathVerb ? [] : ["to"]) {
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
// Kebab-case numeric aliases: `resize` reads --width/--height (mapped to w/h), and
// --window-index picks among same-titled windows.
for (flag, key) in [("width", "w"), ("height", "h"), ("window-index", "windowIndex")] {
    guard let found = value(for: flag) else { continue }
    guard let number = Double(found), number.isFinite else {
        FileHandle.standardError.write(Data("rocuronium: --\(flag) must be a finite number, got '\(found)'\n".utf8))
        exit(2)
    }
    payload[key] = number
}
if arguments.contains("--allow-hardware-input") { payload["allowHardwareInput"] = true }
if arguments.contains("--foreground") { payload["foreground"] = true }
if arguments.contains("--submit") { payload["submit"] = true }
if arguments.contains("--gone") { payload["gone"] = true }
if arguments.contains("--press") { payload["press"] = true }
// `shortcut` can reach Log Out from any app, so seeing what a shortcut resolves to is a
// first-class operation, and pressing a destructive item takes a deliberate second flag.
if arguments.contains("--resolve-only") { payload["resolveOnly"] = true }
if arguments.contains("--confirm") { payload["confirm"] = true }
if arguments.contains("--restore") { payload["restore"] = true }
if arguments.contains("--observe") { payload["observe"] = true }
if arguments.contains("--ocr") { payload["ocr"] = true }
if arguments.contains("--all") { payload["all"] = true }
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
    If the app IS running, a debug build may have bound this path and then quit, leaving a
    dead socket file — the running daemon rebinds within ~10s, so retry; or restart the
    release daemon with Scripts/install-launchagent.sh.

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

// A disruptive action that a present human approved in the popup says so, so the outcome is
// not mistaken for one that ran unattended. (A decline surfaces as the error above.)
if let consent = reply["consent"] as? String {
    FileHandle.standardError.write(Data("rocuronium: the human \(consent) this action.\n".utf8))
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
        // An element's own name if it has one; otherwise the kind, the tooltip, and where it
        // sits — everything that lets an agent aim at an icon-only control.
        let label = match["label"] as? String ?? ""
        var name = label.isEmpty ? "" : "'\(label)'"
        if label.isEmpty, let roleDescription = match["roleDescription"] as? String { name = "(\(roleDescription))" }
        let extras = [
            (match["help"] as? String).map { "help '\($0)'" },
            (match["identifier"] as? String).map { "id '\($0)'" },
            (match["near"] as? String).map { "near \($0)" },
        ].compactMap { $0 }
        let suffix = extras.isEmpty ? "" : "  " + extras.joined(separator: "  ")
        let grounded = match["groundedBy"].map { "  [\($0)]" } ?? ""
        print("\(match["role"] ?? "?")  \(name)\(position)\(suffix)  depth \(match["depth"] ?? "?")\(grounded)")
    }
    let shown = reply["shown"] as? Int ?? matches.count
    let total = reply["total"] as? Int ?? shown
    let offset = reply["offset"] as? Int ?? 0
    let range = total > shown ? "shown \(offset + 1)–\(offset + shown) of \(total)" : "\(shown) shown"
    let page = total > offset + shown ? " · more with --offset \(offset + shown)" : ""
    print("\n\(range) · \(reply["elementsVisited"] ?? 0) elements visited\(page)"
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
        // Static text and OCR rows read as prose; anything interactive keeps its role visible
        // so the reader knows it can be acted on.
        var annotation = (role == "AXStaticText" || role == "OCRText") ? "" : "  [\(role)]"
        // A detector control often has no label — show its click point so an icon button is
        // aimable straight from the read.
        if role == "UIElement", let frame = line["frame"] as? [String: Any],
           let x = frame["x"] as? Double, let y = frame["y"] as? Double,
           let w = frame["w"] as? Double, let h = frame["h"] as? Double {
            annotation += "  @(\(Int(x + w / 2)),\(Int(y + h / 2)))"
        }
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
            // The last 8 chars of the ISO timestamp are HH:MM:SS — enough to tell two
            // instances of one bundle apart.
            (app["launchedAt"] as? String).map { "  (since \($0.suffix(9).prefix(8)))" } ?? "",
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

case "resize":
    print(reply["summary"] as? String ?? "done")
    // before → after frames are the evidence: the AX return code is not trustworthy, the
    // read-back frame is.
    func frameText(_ key: String) -> String? {
        guard let f = reply[key] as? [String: Any] else { return nil }
        return "@(\(Int(f["x"] as? Double ?? 0)),\(Int(f["y"] as? Double ?? 0))) "
            + "\(Int(f["w"] as? Double ?? 0))x\(Int(f["h"] as? Double ?? 0))"
    }
    if let before = frameText("before"), let after = frameText("after") {
        print("\(before)  →  \(after)")
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
    // What the AX tree diff caught — a sibling value ticking, a panel appearing — that the
    // pixel and window-count channels could not see.
    if let treeDelta = reply["treeDelta"] as? String, !treeDelta.isEmpty {
        print("tree changed:")
        for line in treeDelta.split(separator: "\n") { print("  \(line)") }
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
