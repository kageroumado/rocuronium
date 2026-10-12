import Darwin
import Foundation

/// Runs system tools with arguments as an argv array — never through a shell — and collects
/// their output, bounded by a timeout.
public enum Shell {
    /// - Parameters:
    ///   - environment: added to a minimal environment; a secret handed to a child goes here,
    ///     never on argv, because argv is world-readable through `ps` while a root process's
    ///     environment is not.
    ///   - input: written to the child's stdin, which is then closed.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval = 60,
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            .merging(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let collected = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: 127, output: "could not run \(executable): \(error.localizedDescription)")
        }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: 124, output: collected.text + "\n(timed out after \(Int(timeout)) s)")
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        return CommandResult(status: process.terminationStatus, output: collected.text)
    }

    /// Runs `argv` under `expect`, answering one exact prompt with a secret.
    ///
    /// `sysadminctl` and `dscl -authonly` take a password on argv or from a terminal prompt
    /// only, so they get a pty. The prompt is matched **exactly**: a loose pattern such as
    /// `(?i)password.*:` also matches sysadminctl's own warning line about clear-text
    /// passwords, which precedes the real prompt — the secret then goes into the log stream
    /// and the account is created with no password at all, silently. The secret reaches
    /// expect through its environment.
    public static func answeringPrompt(_ prompt: String, with secret: String, argv: [String], timeout: TimeInterval = 60) -> CommandResult {
        let script = """
            set timeout \(Int(timeout))
            log_user 0
            spawn -noecho {*}$argv
            expect {
                "\(prompt)" { send -- "$env(ROCURONIUM_SECRET)\\r"; exp_continue }
                timeout { exit 124 }
                eof
            }
            catch wait result
            exit [lindex $result 3]
            """
        return run(
            "/usr/bin/expect", ["-f", "-", "--"] + argv,
            environment: ["ROCURONIUM_SECRET": secret], input: Data(script.utf8), timeout: timeout + 5,
        )
    }
}

/// Collects a pipe's output from its readability handler, which runs on an arbitrary queue.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

/// The real ``AccountSystem``: Directory Services, launchd, and the process table.
public struct LiveAccountSystem: AccountSystem {
    public init() {}

    public func uid(of name: String) -> uid_t? {
        guard let entry = getpwnam(name) else { return nil }
        return entry.pointee.pw_uid
    }

    public func isAdmin(_ name: String) -> Bool {
        // dsmemberutil resolves nested groups, which a GroupMembership read would miss.
        Shell.run("/usr/bin/dsmemberutil", ["checkmembership", "-U", name, "-G", "admin"])
            .output.contains("is a member")
    }

    public func processes(of uid: uid_t) -> [pid_t] {
        ProcessTable.pids(ownedBy: uid)
    }

    public func loginWindow(of uid: uid_t) -> pid_t? {
        ProcessTable.loginWindow(of: uid)
    }

    public func isRegistered(_ name: String) -> Bool { AccountRegistry.names().contains(name) }
    public func register(_ name: String) { AccountRegistry.update { $0.insert(name) } }
    public func unregister(_ name: String) { AccountRegistry.update { $0.remove(name) } }

    public func bootout(uid: uid_t) -> CommandResult {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)"], timeout: 30)
    }

    public func deleteAccount(_ name: String) -> CommandResult {
        Shell.run("/usr/sbin/sysadminctl", ["-deleteUser", name], timeout: 120)
    }

    public func pause(seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}

/// Process-table reads through libproc: who owns what, and since when.
public enum ProcessTable {
    public static func pids(ownedBy uid: uid_t) -> [pid_t] {
        let capacity = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 32)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// The short command name (`p_comm`, 16 bytes), which is what `ps -o comm` truncates to.
    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// When the process started, from its BSD info.
    public static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The `loginwindow` that owns `uid`'s GUI session, if one is running: each GUI login
    /// session, console or off-console, has exactly one, running as that user.
    public static func loginWindow(of uid: uid_t) -> pid_t? {
        pids(ownedBy: uid).first { name(of: $0) == "loginwindow" }
    }
}

/// The accounts the session helper provisioned: a root-owned list outside every user's home,
/// so no user — the console user included — can add another person's account to it.
public enum AccountRegistry {
    static let directory = "/Library/Application Support/glass.kagerou.rocuronium"
    static let path = directory + "/agent-accounts.plist"

    public static func names() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return Set(list)
    }

    /// Root only. Writes `0644 root:wheel` atomically, after checking the directory is root's.
    static func update(_ change: (inout Set<String>) -> Void) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        guard let attributes = try? manager.attributesOfItem(atPath: directory),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0 else { return }
        var current = names()
        change(&current)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: current.sorted(), format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: path)
    }
}
