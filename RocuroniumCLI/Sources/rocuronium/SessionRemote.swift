import CoreGraphics
import Darwin
import Foundation
import SessionKit
import SystemConfiguration

/// The two `session` subcommands that run inside the agent account rather than talking to a
/// daemon: `session watch`, the dead-man's switch, and `session remote`, the forced command
/// rocuronium's SSH key is restricted to. The rest of `session` (enable, start, stop, status)
/// goes over the socket like every other verb.
///
/// These are the one place this binary acts on its own instead of forwarding: the watcher must
/// be able to end the session when the daemon inside it is the thing that has hung, so it
/// cannot route its kill through that daemon.
enum SessionRemote {
    /// `session remote`: reads the request sshd put in `SSH_ORIGINAL_COMMAND` and runs it if it
    /// is one of `RemoteCommand`'s; anything else, a shell included, exits 2.
    @MainActor
    static func run(forward: ([String: Any]) -> [String: Any]?) -> Never {
        let original = ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"]
        guard let command = RemoteCommand.parse(original) else {
            fail("session remote: refused '\(original ?? "")' — this key runs rocuronium session commands only", code: 2)
        }
        switch command {
        case let .watch(deadline):
            watch(deadlineSeconds: SessionWatch.deadline(requested: deadline))
        case let .watchLogin(deadline):
            watchLogin(deadlineSeconds: SessionWatch.deadline(requested: deadline))
        case .stop:
            let result = bootoutOwnSession()
            emit(["ok": result.succeeded, "status": Int(result.status), "output": result.output])
        case .facts:
            emit(facts())
        case .forward:
            let line = FileHandle.standardInput.readDataToEndOfFile()
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                fail("session remote forward: stdin is not one JSON object", code: 2)
            }
            guard let reply = forward(request) else {
                emit(["ok": false, "error": "no daemon answers in this session", "daemonAnswered": false])
            }
            emit(reply)
        case .startDaemon:
            emit(startDaemon())
        case .restartDaemon:
            guard SessionWatch.armingRefusal(onConsole: onConsole()) == nil else {
                emit(["ok": false, "error": "refused: restart-daemon requires an off-console session"])
            }
            emit(startDaemon(restart: true))
        }
    }

    /// `session watch [seconds]`: the dead-man's switch, also reachable without SSH for a
    /// human testing it by hand inside the agent session.
    static func watch(deadlineSeconds: Int) -> Never {
        if let refusal = SessionWatch.armingRefusal(onConsole: onConsole()) {
            fail("session watch: \(refusal)", code: 2)
        }
        let outcome = SessionWatch.run(
            input: STDIN_FILENO,
            deadlineSeconds: deadlineSeconds,
            announce: {
                print("armed uid=\(getuid()) deadline=\(deadlineSeconds)")
                fflush(stdout)
            },
            bootout: { _ in bootoutOwnSession() },
        )
        print("bootout reason=\"\(outcome.reason)\" status=\(outcome.bootout.status)")
        fflush(stdout)
        exit(outcome.bootout.succeeded ? 0 : 1)
    }

    /// `session remote watch-login [seconds]`: the switch armed before the login request, so a
    /// console daemon that stops while the session is still coming up cannot leave it unguarded.
    /// Refused when this account already has a session on the console.
    static func watchLogin(deadlineSeconds: Int) -> Never {
        if accountOnConsole() == true {
            fail("session watch-login: this account has a session on the console; the watcher only guards an off-console agent session", code: 2)
        }
        let outcome = SessionWatch.run(
            input: STDIN_FILENO,
            deadlineSeconds: deadlineSeconds,
            announce: {
                print("armed uid=\(getuid()) deadline=\(deadlineSeconds) before-login")
                fflush(stdout)
            },
            bootout: { event in bootoutWhenLoginAppears(within: PendingLoginWatch.loginWait(after: event)) },
        )
        print("bootout reason=\"\(outcome.reason)\" status=\(outcome.bootout.status) \(outcome.bootout.output)")
        fflush(stdout)
        exit(outcome.bootout.succeeded ? 0 : 1)
    }

    /// Waits up to `seconds` for this account's loginwindow, then boots the session out once it is
    /// listed off-console. A session listed on the console is refused, never booted.
    static func bootoutWhenLoginAppears(within seconds: Int) -> CommandResult {
        let uid = getuid()
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        repeat {
            if ProcessTable.loginWindow(of: uid) != nil {
                switch accountOnConsole() {
                case false?: return Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)"], timeout: 30)
                case true?: return CommandResult(status: 2, output: "refused: this account's session is on the console")
                case nil: break
                }
            }
            usleep(250_000)
        } while Date() < deadline
        return ProcessTable.loginWindow(of: uid) == nil
            ? CommandResult(status: 0, output: "no session appeared within \(seconds) s")
            : CommandResult(status: 2, output: "refused: the session never listed as off-console")
    }

    /// Whether this account's GUI session is on the console, readable from a process started
    /// before that session existed: the console-user session list, plus this process's own
    /// CGSession when it has one. Either one saying on-console wins.
    static func accountOnConsole() -> Bool? {
        let sessions = SCDynamicStoreCopyValue(nil, "State:/Users/ConsoleUser" as CFString)
            .flatMap { ($0 as? [String: Any])?["SessionInfo"] as? [[String: Any]] } ?? []
        let listed = PendingLoginWatch.onConsole(sessions: sessions, uid: getuid())
        let own = onConsole()
        if listed == true || own == true { return true }
        return listed ?? own
    }

    /// `launchctl bootout gui/<own uid>` — no privilege needed, and it ends the whole GUI
    /// session. Refused on the console, where it would log the human out.
    static func bootoutOwnSession() -> CommandResult {
        guard SessionWatch.armingRefusal(onConsole: onConsole()) == nil else {
            return CommandResult(status: 2, output: "refused: not an off-console session")
        }
        return Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())"], timeout: 30)
    }

    /// `kCGSSessionOnConsoleKey`, never `/dev/console`: an off-console session can own the
    /// console device node while the human's screen is untouched (measured 2026-08-28).
    static func onConsole() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["kCGSSessionOnConsoleKey"] as? Bool
    }

    static func facts() -> [String: Any] {
        let uid = getuid()
        var reply: [String: Any] = [
            "ok": true,
            "uid": Int(uid),
            "user": NSUserName(),
            "processes": ProcessTable.pids(ownedBy: uid).count,
        ]
        if let onConsole = onConsole() { reply["onConsole"] = onConsole }
        if let loginWindow = ProcessTable.loginWindow(of: uid) {
            reply["loginwindowPid"] = Int(loginWindow)
            if let started = ProcessTable.startDate(of: loginWindow) {
                reply["loginwindowAgeSeconds"] = max(0, Int(Date().timeIntervalSince(started)))
            }
        }
        reply["displays"] = displays()
        return reply
    }

    static func displays() -> [[String: Any]] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return [
                "id": Int(id),
                "x": Int(bounds.origin.x), "y": Int(bounds.origin.y),
                "w": Int(bounds.width), "h": Int(bounds.height),
                "main": CGDisplayIsMain(id) != 0,
                "active": CGDisplayIsActive(id) != 0,
                "mirrored": CGDisplayIsInMirrorSet(id) != 0,
            ]
        }
    }

    static func startDaemon(restart: Bool = false) -> [String: Any] {
        let uid = getuid()
        let label = "gui/\(uid)/glass.kagerou.rocuronium"
        if Shell.run("/bin/launchctl", ["print", label]).succeeded {
            let kick = Shell.run("/bin/launchctl", ["kickstart"] + (restart ? ["-k"] : []) + [label])
            return ["ok": kick.succeeded, "loaded": true, "output": kick.output]
        }
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/glass.kagerou.rocuronium.plist"
        let boot = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
        return ["ok": boot.succeeded, "loaded": false, "output": boot.output]
    }

    private static func emit(_ object: [String: Any]) -> Never {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + [0x0A])
        exit(object["ok"] as? Bool == false ? 1 : 0)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
