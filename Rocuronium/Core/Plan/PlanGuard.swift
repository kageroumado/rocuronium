import Foundation

/// A postcondition on a plan step, drawn from the evidence vocabulary.
enum PlanGuard: Decodable, Sendable {
    /// The step's own evidence verdict must match.
    case verdict(String)
    /// The step's readback must contain this text.
    case readbackContains(String)
    /// A window with a matching title must exist after the step.
    case windowAppears(title: String)
    /// A window with a matching title must be gone after the step.
    case windowVanishes(title: String)
    /// An element with matching text must be findable in the AX tree.
    case textVisible(label: String)
    /// An element with matching text must NOT be in the AX tree.
    case textVanishes(label: String)

    struct Result: Sendable {
        let passed: Bool
        let reason: String
    }

    private enum CodingKeys: String, CodingKey {
        case type, verdict, text, title, label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "verdict":
            self = .verdict(try container.decode(String.self, forKey: .verdict))
        case "readback-contains":
            self = .readbackContains(try container.decode(String.self, forKey: .text))
        case "window-appears":
            self = .windowAppears(title: try container.decode(String.self, forKey: .title))
        case "window-vanishes":
            self = .windowVanishes(title: try container.decode(String.self, forKey: .title))
        case "text-visible":
            self = .textVisible(label: try container.decode(String.self, forKey: .label))
        case "text-vanishes":
            self = .textVanishes(label: try container.decode(String.self, forKey: .label))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown guard type '\(type)' — use verdict, readback-contains, window-appears, window-vanishes, text-visible, text-vanishes",
            )
        }
    }

    /// Evaluates the guard against the step's reply and, when needed, the live AX state.
    func evaluate(reply: [String: Any], pid: pid_t?, engine: Engine) async -> Result {
        switch self {
        case let .verdict(expected):
            let actual = reply["verdict"] as? String ?? "none"
            return Result(
                passed: actual == expected,
                reason: actual == expected
                    ? "verdict is \(expected)"
                    : "expected verdict '\(expected)', got '\(actual)'",
            )

        case let .readbackContains(text):
            let readback = reply["readback"] as? String
            let contains = readback?.contains(text) == true
            return Result(
                passed: contains,
                reason: contains
                    ? "readback contains '\(text)'"
                    : "readback \(readback.map { "'\($0)'" } ?? "nil") does not contain '\(text)'",
            )

        case let .windowAppears(title):
            guard let pid else {
                return Result(passed: false, reason: "no pid resolved — cannot check windows")
            }
            let found = await windowExists(title: title, pid: pid, engine: engine)
            return Result(
                passed: found,
                reason: found
                    ? "window '\(title)' appeared"
                    : "window '\(title)' not found",
            )

        case let .windowVanishes(title):
            guard let pid else {
                return Result(passed: true, reason: "no pid resolved — assuming vanished")
            }
            let found = await windowExists(title: title, pid: pid, engine: engine)
            return Result(
                passed: !found,
                reason: found
                    ? "window '\(title)' still exists"
                    : "window '\(title)' is gone",
            )

        case let .textVisible(label):
            guard let pid else {
                return Result(passed: false, reason: "no pid resolved — cannot search")
            }
            let found = await elementExists(label: label, pid: pid, engine: engine)
            return Result(
                passed: found,
                reason: found
                    ? "text '\(label)' found"
                    : "text '\(label)' not found in the AX tree",
            )

        case let .textVanishes(label):
            guard let pid else {
                return Result(passed: true, reason: "no pid resolved — assuming vanished")
            }
            let found = await elementExists(label: label, pid: pid, engine: engine)
            return Result(
                passed: !found,
                reason: found
                    ? "text '\(label)' still present"
                    : "text '\(label)' gone from the AX tree",
            )
        }
    }

    private func windowExists(title: String, pid: pid_t, engine: Engine) async -> Bool {
        guard let windows = try? await engine.windowList(pid: pid) else { return false }
        return windows.contains { $0.title.localizedCaseInsensitiveContains(title) }
    }

    private func elementExists(label: String, pid: pid_t, engine: Engine) async -> Bool {
        guard let outcome = try? await engine.find(pid: pid, query: label) else { return false }
        return !outcome.elements.isEmpty
    }
}

/// What to do when a guard fails.
indirect enum FailurePolicy: Decodable, Sendable {
    case abort
    case `continue`
    case pauseForHuman
    case fallback(SequencePlan.Step)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            switch string {
            case "abort": self = .abort
            case "continue": self = .continue
            case "pause-for-human": self = .pauseForHuman
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unknown failure policy '\(string)' — use abort, continue, pause-for-human, or {\"fallback\": {...}}",
                )
            }
            return
        }
        let keyed = try decoder.container(keyedBy: FallbackKeys.self)
        let step = try keyed.decode(SequencePlan.Step.self, forKey: .fallback)
        self = .fallback(step)
    }

    private enum FallbackKeys: String, CodingKey {
        case fallback
    }
}
