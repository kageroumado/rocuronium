import Darwin
import Foundation

/// Pins a forwarded command to one login of the provisioned account.
struct AgentDesktopIdentity: Codable, Equatable {
    let uid: UInt32
    let account: String
    let loginWindowPID: Int32

    func refusal(uid actualUID: UInt32, account actualAccount: String, loginWindowPID actualPID: Int32?, offConsole: Bool) -> String? {
        guard uid >= 501, loginWindowPID > 0, uid == actualUID, account == actualAccount,
              loginWindowPID == actualPID, offConsole else {
            return "agent desktop identity changed or is unavailable; command refused"
        }
        return nil
    }
}

/// Routes the entire request, including every plan step, to one desktop.
enum AgentDesktopTarget {
    static let envelopeCommand = "agent-desktop"
    struct Parsed {
        var request: [String: Any]
        let desktop: String
        let identity: AgentDesktopIdentity?
    }
    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid("request must be a JSON object")
        }
        var identity: AgentDesktopIdentity?
        if object["command"] as? String == "desktop-target" {
            guard object["desktop"] as? String == "agent",
                  var inner = object["request"] as? [String: Any], inner["desktop"] == nil,
                  inner["command"] as? String != envelopeCommand else {
                throw Invalid("desktop-target requires the agent desktop and one request")
            }
            inner["desktop"] = "agent"
            object = inner
        }
        if object["command"] as? String == envelopeCommand {
            let identityData = try JSONSerialization.data(withJSONObject: object["identity"] ?? [:])
            identity = try JSONDecoder().decode(AgentDesktopIdentity.self, from: identityData)
            guard let inner = object["request"] as? [String: Any], inner["desktop"] == nil else {
                throw Invalid("agent desktop envelope requires one request without a desktop override")
            }
            object = inner
        }
        let desktop: String
        if let supplied = object.removeValue(forKey: "desktop") {
            guard let value = supplied as? String, ["current", "agent"].contains(value) else {
                throw Invalid("desktop must be 'current' or 'agent'")
            }
            desktop = value
        } else { desktop = identity == nil ? "current" : "agent" }
        try validate(object, agent: desktop == "agent")
        return Parsed(request: object, desktop: desktop, identity: identity)
    }

    private static func validate(_ request: [String: Any], agent: Bool) throws {
        guard let command = request["command"] as? String else { throw Invalid("request requires a command") }
        guard command != envelopeCommand, command != "desktop-target" else { throw Invalid("nested agent desktop envelopes are refused") }
        if agent, command == "session" {
            throw Invalid("session lifecycle commands belong to the owning desktop; omit desktop: agent")
        }
        if command == "plan", let steps = request["steps"] as? [[String: Any]] {
            for step in steps {
                guard step["desktop"] == nil else {
                    throw Invalid("choose the desktop on the whole plan; steps cannot override it")
                }
                if agent, step["command"] as? String == "screenshot", step["path"] != nil {
                    throw Invalid("agent plan screenshots use managed local capture paths; omit the step's path")
                }
                try validate(step, agent: agent)
            }
        }
    }

    static func envelope(_ request: [String: Any], identity: AgentDesktopIdentity) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(identity)
        return ["command": envelopeCommand, "identity": try JSONSerialization.jsonObject(with: encoded), "request": request]
    }

    /// Validates the executed step after references have supplied its fields.
    static func planStepRefusal(command: String, path: String?) -> String? {
        if command == "session" {
            return "session lifecycle commands belong to the owning desktop"
        }
        if command == "screenshot", path != nil {
            return "agent plan screenshots use managed local capture paths; omit the step's path"
        }
        return nil
    }
}
