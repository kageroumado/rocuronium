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
    /// The primary window's tree must hold still for this many milliseconds — how "the view
    /// finished loading" is actually detected, since there is no "done" event to wait on.
    case quiet(ms: Int)
    /// The primary window's tree must differ from the walk this observation token recorded —
    /// "wait until anything at all changes", the general form of text-visible.
    case tokenChanged(token: String)

    struct Result: Sendable {
        let passed: Bool
        let reason: String
    }

    private enum CodingKeys: String, CodingKey {
        case type, verdict, text, title, label, ms, token
    }

    /// The default settle window for `quiet` — long enough that a mid-load pause between two
    /// bursts of tree mutation does not read as "settled", short enough to be responsive.
    private static let defaultQuietMilliseconds = 600

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
        case "quiet":
            self = .quiet(ms: try container.decodeIfPresent(Int.self, forKey: .ms) ?? Self.defaultQuietMilliseconds)
        case "token-changed":
            self = .tokenChanged(token: try container.decode(String.self, forKey: .token))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown guard type '\(type)' — use verdict, readback-contains, window-appears, window-vanishes, text-visible, text-vanishes, quiet, token-changed",
            )
        }
    }

    /// Whether this guard reads live UI state (the AX tree, the window list) rather than only the
    /// step's own reply. The plan path's perception pre-check skips evaluation for these when the
    /// display is asleep, so a degenerate tree cannot fabricate a pass/fail verdict; the
    /// reply-only guards (verdict, readback) stay meaningful and are always evaluated.
    var needsLivePerception: Bool {
        switch self {
        case .verdict, .readbackContains: false
        case .windowAppears, .windowVanishes, .textVisible, .textVanishes, .quiet, .tokenChanged: true
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
            do {
                let found = try await windowExists(title: title, pid: pid, engine: engine)
                return Result(
                    passed: found,
                    reason: found
                        ? "window '\(title)' appeared"
                        : "window '\(title)' not found",
                )
            } catch {
                // A thrown error is "could not look", not "not present" — surfacing it as absence
                // would let an asleep display read as "the window never appeared".
                return Result(passed: false, reason: "could not check whether '\(title)' appeared: \(failureReason(error))")
            }

        case let .windowVanishes(title):
            guard let pid else {
                // A mistyped --app resolves to no pid; assuming "vanished" would let that typo
                // silently pass a vanish guard. Fail with a reason that names the real cause.
                return Result(passed: false, reason: "target app never resolved — cannot confirm window '\(title)' vanished (a mistyped --app must not pass a vanish guard)")
            }
            do {
                let found = try await windowExists(title: title, pid: pid, engine: engine)
                return Result(
                    passed: !found,
                    reason: found
                        ? "window '\(title)' still exists"
                        : "window '\(title)' is gone",
                )
            } catch {
                // Cannot see is not the same as gone: a swallowed error here would confirm a
                // vanish that was never observed.
                return Result(passed: false, reason: "could not check whether '\(title)' vanished: \(failureReason(error))")
            }

        case let .textVisible(label):
            guard let pid else {
                return Result(passed: false, reason: "no pid resolved — cannot search")
            }
            do {
                let found = try await elementExists(label: label, pid: pid, engine: engine)
                return Result(
                    passed: found,
                    reason: found
                        ? "text '\(label)' found"
                        : "text '\(label)' not found in the AX tree",
                )
            } catch {
                return Result(passed: false, reason: "could not check whether '\(label)' is visible: \(failureReason(error))")
            }

        case let .textVanishes(label):
            guard let pid else {
                return Result(passed: false, reason: "target app never resolved — cannot confirm text '\(label)' vanished (a mistyped --app must not pass a vanish guard)")
            }
            do {
                let found = try await elementExists(label: label, pid: pid, engine: engine)
                return Result(
                    passed: !found,
                    reason: found
                        ? "text '\(label)' still present"
                        : "text '\(label)' gone from the AX tree",
                )
            } catch {
                return Result(passed: false, reason: "could not check whether '\(label)' vanished: \(failureReason(error))")
            }

        case let .quiet(ms):
            guard let pid else {
                return Result(passed: false, reason: "no pid resolved — cannot watch the tree")
            }
            let outcome = await engine.treeIsQuiet(pid: pid, over: .milliseconds(ms))
            return Result(
                passed: outcome.settled,
                reason: outcome.settled
                    ? "the window's tree held still for \(ms)ms"
                    // The honest reason when quiet could not be confirmed for a structural
                    // reason, and only "still changing" when the tree genuinely kept mutating.
                    : outcome.unconfirmedReason ?? "the window's tree is still changing",
            )

        case let .tokenChanged(token):
            guard let pid else {
                return Result(passed: false, reason: "no pid resolved — cannot diff the tree")
            }
            guard let changed = await engine.treeChangedSinceToken(token, pid: pid) else {
                return Result(passed: false, reason: "token '\(token.prefix(24))' is unknown, evicted, or was not a whole-window read")
            }
            return Result(
                passed: changed,
                reason: changed
                    ? "the window's tree changed since \(token.prefix(24))"
                    : "the window's tree is unchanged since \(token.prefix(24))",
            )
        }
    }

    /// Rethrows the engine error rather than swallowing it: the engine throws `.cannotSee` when
    /// perception is unreliable (an asleep display), and that must reach the caller as "could not
    /// check", never collapse into a genuinely empty tree's "not present". A `false` here means the
    /// tree answered and held no such window.
    private func windowExists(title: String, pid: pid_t, engine: Engine) async throws -> Bool {
        let windows = try await engine.windowList(pid: pid)
        return windows.contains { $0.title.localizedCaseInsensitiveContains(title) }
    }

    private func elementExists(label: String, pid: pid_t, engine: Engine) async throws -> Bool {
        let outcome = try await engine.find(pid: pid, query: label)
        return !outcome.elements.isEmpty
    }

    /// The human-readable reason a perception check could not run — the engine's own
    /// `.cannotSee` prose ("The display is asleep …") when it threw that, otherwise the raw error.
    private func failureReason(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? "\(error)"
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
