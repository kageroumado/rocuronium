import Darwin
import Foundation

/// The dead-man's switch for an agent session, run inside the agent account.
///
/// ⌃⌥⇧⎋ is a hotkey registered in the console session, and hotkeys are session-scoped: a human
/// at the physical keyboard cannot halt an off-console session with it. So the console-side
/// daemon holds an SSH pipe into the agent account and writes a beat down it every couple of
/// seconds; this watcher, at the other end, ends its own session when the beats stop. Each way
/// the console side can go away arrives here as one of three events:
///
/// | console side | arrives as |
/// |---|---|
/// | daemon crashes, quits, or is killed | the pipe closes → end of input |
/// | daemon hangs, or the SSH link stalls | no line before the deadline → timeout |
/// | the human presses ⌃⌥⇧⎋ | a `stop` line |
///
/// The bootout is `launchctl bootout gui/<own uid>`, which needs no privilege and tears the
/// whole GUI session down — measured on 2026-08-28. The watcher runs outside that domain (it
/// is the SSH session's child), so it survives its own bootout long enough to report it.
public enum SessionWatch {
    public enum Event: Equatable, Sendable {
        case line(String)
        case endOfInput
        case timeout
    }

    public enum Verdict: Equatable, Sendable {
        case keepWatching
        case bootout(reason: String)
    }

    public static let defaultDeadlineSeconds = 15
    public static let minimumDeadlineSeconds = 4
    public static let maximumDeadlineSeconds = 120

    public static func deadline(requested: Int?) -> Int {
        guard let requested else { return defaultDeadlineSeconds }
        return min(max(requested, minimumDeadlineSeconds), maximumDeadlineSeconds)
    }

    public static func verdict(for event: Event) -> Verdict {
        switch event {
        case .endOfInput:
            .bootout(reason: "the console side closed the heartbeat pipe")
        case .timeout:
            .bootout(reason: "no heartbeat from the console side before the deadline")
        case let .line(text):
            switch text.split(separator: " ").first {
            case "beat": .keepWatching
            case "stop": .bootout(reason: "stopped from the console")
            default: .bootout(reason: "unrecognized heartbeat line")
            }
        }
    }

    /// Why the watcher must not arm here, or nil when it may. The bootout targets this
    /// process's own uid, so in the human's console session it would log the human out.
    public static func armingRefusal(onConsole: Bool?) -> String? {
        switch onConsole {
        case false?: nil
        case true?: "this is the console session; the watcher only guards an off-console agent session"
        case nil: "no GUI session is readable from here, so there is nothing to guard"
        }
    }

    /// Reads `input` until the verdict is a bootout, then performs it. Returns the reason.
    ///
    /// - Parameters:
    ///   - deadlineSeconds: how long a silence may last before it counts as the console side gone.
    ///   - announce: called once when the watcher is armed, so the console side can confirm
    ///     the switch exists before it lets the session do anything.
    public static func run(
        input: Int32,
        deadlineSeconds: Int,
        announce: () -> Void,
        bootout: () -> CommandResult,
    ) -> (reason: String, bootout: CommandResult) {
        announce()
        var pending = Data()
        while true {
            let event = nextEvent(input: input, buffer: &pending, deadlineSeconds: deadlineSeconds)
            if case let .bootout(reason) = verdict(for: event) {
                return (reason, bootout())
            }
        }
    }

    private static func nextEvent(input: Int32, buffer: inout Data, deadlineSeconds: Int) -> Event {
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex ... newline)
                return .line(line.trimmingCharacters(in: .whitespaces))
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timeout }
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return .endOfInput
            }
            if ready == 0 { return .timeout }
            var chunk = [UInt8](repeating: 0, count: 256)
            let count = read(input, &chunk, chunk.count)
            guard count > 0 else { return .endOfInput }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }
}

/// What rocuronium's SSH key may run inside the agent account.
///
/// The key is installed in the agent's `authorized_keys` as
/// `restrict,command="<cli> session remote"`, so sshd ignores whatever the client asked to
/// run and starts the CLI with the request in `SSH_ORIGINAL_COMMAND`. This is the whole
/// vocabulary; anything else, a shell included, is refused.
public enum RemoteCommand: Equatable, Sendable {
    /// Arm the dead-man's switch; the deadline is in seconds.
    case watch(deadlineSeconds: Int?)
    /// `launchctl bootout gui/<uid>` at once.
    case stop
    /// The session as seen from inside: uid, console-ness, displays, uptime.
    case facts
    /// One JSON request from stdin to this account's daemon socket, its reply to stdout.
    case forward
    /// Start this account's Rocuronium LaunchAgent if it is not running.
    case startDaemon

    public static func parse(_ original: String?) -> RemoteCommand? {
        guard let words = original?.split(separator: " ").map(String.init), let verb = words.first else { return nil }
        switch (verb, words.count) {
        case ("watch", 1): return .watch(deadlineSeconds: nil)
        case ("watch", 2): return Int(words[1]).map { .watch(deadlineSeconds: $0) }
        case ("stop", 1): return .stop
        case ("facts", 1): return .facts
        case ("forward", 1): return .forward
        case ("start-daemon", 1): return .startDaemon
        default: return nil
        }
    }
}
