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
  rocuronium find   --app <name> [--label <text>]
  rocuronium type   --app <name> --text <text> [--label <text>]
  rocuronium click  --app <name> [--label <text>] [--x <n> --y <n>]

Options:
  --allow-hardware-input   permit the one rung that moves the real cursor (default: no)
  --json                   print the raw reply

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

var payload: [String: Any] = ["command": command]
for flag in ["app", "label", "text"] {
    if let found = value(for: flag) { payload[flag] = found }
}
for flag in ["x", "y"] {
    if let found = value(for: flag), let number = Double(found) { payload[flag] = number }
}
if arguments.contains("--allow-hardware-input") { payload["allowHardwareInput"] = true }
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

default:
    print(reply["summary"] as? String ?? "done")
    if let readback = reply["readback"] as? String, !readback.isEmpty {
        print("read back: \(readback.prefix(60))")
    }
    // The whole point of the tool: say plainly whether the human's cursor was touched.
    // Movement under a ghost rung is the user's own hand — warning about it would train
    // people to ignore the one warning that matters.
    if reply["cursorMovedByUs"] as? Bool == true { print("⚠︎ the cursor was taken") }
    else if reply["cursorMovedByUser"] as? Bool == true { print("(cursor moved — yours, not ours)") }
    if reply["frontmostChanged"] as? Bool == true { print("⚠︎ the frontmost app changed") }
    if let attempts = reply["attempts"] as? [[String: Any]] {
        for attempt in attempts { print("  · \(attempt["rung"] ?? "?"): \(attempt["outcome"] ?? "")") }
    }
}

exit(reply["ok"] as? Bool == true ? 0 : 1)
