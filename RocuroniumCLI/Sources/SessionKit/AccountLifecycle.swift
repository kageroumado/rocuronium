import Darwin
import Foundation

/// What a shell-level step returned: its exit status and its combined output.
public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }
}

/// The operating-system surface account lifecycle needs, behind a protocol so the order of
/// operations can be tested without creating or deleting anyone.
public protocol AccountSystem: Sendable {
    func uid(of name: String) -> uid_t?
    func isAdmin(_ name: String) -> Bool
    /// Whether the helper provisioned this account. Removal and bootout touch only these.
    func isRegistered(_ name: String) -> Bool
    func register(_ name: String)
    func unregister(_ name: String)
    /// Every live process owned by `uid`, whatever session it belongs to.
    func processes(of uid: uid_t) -> [pid_t]
    /// The loginwindow that owns the account's GUI session, when logged in.
    func loginWindow(of uid: uid_t) -> pid_t?
    /// `launchctl bootout gui/<uid>`: ends the account's GUI login session.
    func bootout(uid: uid_t) -> CommandResult
    func deleteAccount(_ name: String) -> CommandResult
    func pause(seconds: Double)
}

/// The lowest uid an agent account can have: macOS hands local users 501 upward, and
/// everything below belongs to the system.
let firstUserUID: uid_t = 501

/// Ending an agent account, in the one order that is safe.
///
/// **Never delete an account while its session runs.** On 2026-08-28 an account was deleted
/// with its GUI session still up, leaving a session owned by a uid with no user record (it
/// showed in `ps` as a bare `505`). The shared WindowServer wedged: a physical display left
/// the display list, and every screen capture on the machine failed — Apple's Screenshot
/// included — until the console user logged out. Sessions share one WindowServer, so this is
/// the one way an agent session reaches the human's.
///
/// So removal is bootout first, then a wait until **no process of the uid** is left (any
/// process, since the orphan that did the damage was not a loginwindow), and only then the
/// delete. A survivor refuses the delete and names its pid.
public enum AccountRemoval {
    public enum Outcome: Equatable, Sendable {
        case removed(uid: uid_t)
        case absent
        case refused(String)
    }

    /// How long the process table gets to drain after the bootout. A session's ~250
    /// processes exit within a second or two of a bootout; ten seconds covers a slow one.
    static let settleSeconds: Double = 10
    static let pollSeconds: Double = 0.5

    /// - Parameter protecting: a uid this call must never remove — the requesting user's own.
    public static func run(name: String, system: any AccountSystem, protecting: uid_t? = nil) -> Outcome {
        guard let uid = system.uid(of: name) else { return .absent }
        if let refusal = Provisioning.refusal(name: name, uid: uid, system: system, protecting: protecting) {
            return .refused(refusal)
        }
        guard system.isRegistered(name) else { return .refused(Provisioning.notRegistered(name)) }
        let bootout = system.bootout(uid: uid)
        var survivors = system.processes(of: uid)
        var waited = 0.0
        while !survivors.isEmpty, waited < settleSeconds {
            system.pause(seconds: pollSeconds)
            waited += pollSeconds
            survivors = system.processes(of: uid)
        }
        guard survivors.isEmpty else {
            let pids = survivors.prefix(8).map(String.init).joined(separator: ", ")
            let bootoutNote = bootout.succeeded ? "" : " (bootout exited \(bootout.status))"
            return .refused(
                "'\(name)' still has \(survivors.count) process(es) after the bootout\(bootoutNote): pid \(pids). "
                    + "Deleting an account under a live session wedges the shared WindowServer; "
                    + "log the session out (or restart) and try again.",
            )
        }
        let deleted = system.deleteAccount(name)
        guard deleted.succeeded else {
            return .refused("deleting '\(name)' failed (exit \(deleted.status)): \(deleted.output)")
        }
        system.unregister(name)
        return .removed(uid: uid)
    }
}

/// The checks every provisioning run makes before it touches anything.
public enum Provisioning {
    public enum Gate: Equatable, Sendable {
        case new
        case existing(uid: uid_t)
        case refused(String)
    }

    /// A short name `sysadminctl` accepts and nothing can misread as an option or a path.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase else { return false }
        return name.count <= 31
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Whether `name` may be provisioned now: refused when it is not a valid short name, names
    /// an administrator or a system account, or has a running session.
    public static func gate(name: String, system: any AccountSystem, protecting: uid_t? = nil) -> Gate {
        guard isValidName(name) else {
            return .refused("'\(name)' is not a usable short name (lowercase letters, digits, - and _, at most 31)")
        }
        guard let uid = system.uid(of: name) else { return .new }
        if let refusal = refusal(name: name, uid: uid, system: system, protecting: protecting) {
            return .refused(refusal)
        }
        if let pid = system.loginWindow(of: uid) {
            return .refused("'\(name)' has a running session (loginwindow pid \(pid)) — stop it first: rocuronium session stop")
        }
        return .existing(uid: uid)
    }

    /// The refusal for an account this helper did not provision.
    static func notRegistered(_ name: String) -> String {
        "'\(name)' was not provisioned by Rocuronium's session helper, so the helper will not end or delete it"
    }

    /// Whether the helper may bootout `name`'s session: a provisioned agent account, never the
    /// requester's own, never an administrator — another person's session is not the helper's.
    public static func bootoutRefusal(name: String, uid: uid_t, system: any AccountSystem, protecting: uid_t?) -> String? {
        if let refusal = refusal(name: name, uid: uid, system: system, protecting: protecting) { return refusal }
        return system.isRegistered(name) ? nil : notRegistered(name)
    }

    /// The accounts no agent-session operation may touch, whatever the request says.
    static func refusal(name: String, uid: uid_t, system: any AccountSystem, protecting: uid_t?) -> String? {
        if uid < firstUserUID {
            return "'\(name)' is a system account (uid \(uid))"
        }
        if uid == protecting {
            return "'\(name)' is the requesting user's own account"
        }
        if system.isAdmin(name) {
            return "'\(name)' is an administrator; an agent account is never one, so this is not an agent account"
        }
        return nil
    }
}
