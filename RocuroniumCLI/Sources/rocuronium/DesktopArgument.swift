import Foundation

/// An explicit desktop selection shared by CLI parsing and MCP validation.
enum DesktopArgument {
    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func validate(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let name = value as? String, ["current", "agent"].contains(name) else {
            throw Invalid("desktop must be 'current' or 'agent'")
        }
        return name
    }

    /// A distinct command makes older daemons refuse agent targeting instead of ignoring it.
    static func wireRequest(_ payload: [String: Any]) -> [String: Any] {
        guard payload["desktop"] as? String == "agent" else { return payload }
        var request = payload
        request.removeValue(forKey: "desktop")
        return ["command": "desktop-target", "desktop": "agent", "request": request]
    }

    static func extract(from arguments: inout [String]) throws -> String? {
        let switches: Set<String> = ["--json", "--help", "--allow-hardware-input", "--foreground", "--submit", "--gone", "--press", "--resolve-only", "--confirm", "--done", "--restore", "--observe", "--ocr", "--all", "--exact", "--minimize", "--unminimize", "--zoom", "--next", "--prev"]
        var selected: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--desktop=") {
                guard selected == nil else { throw Invalid("supply --desktop current|agent exactly once") }
                selected = try validate(String(argument.dropFirst("--desktop=".count)))
                arguments.remove(at: index)
            } else if argument == "--desktop" {
                guard selected == nil, index + 1 < arguments.count else {
                    throw Invalid("supply --desktop current|agent exactly once")
                }
                selected = try validate(arguments[index + 1])
                arguments.removeSubrange(index ... index + 1)
            } else {
                index += argument.hasPrefix("--") && !switches.contains(argument) ? 2 : 1
            }
        }
        return selected
    }
}
