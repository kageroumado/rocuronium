import Darwin
import Foundation

/// The console-side daemon's channel into the agent account: SSH to the loopback, as that
/// account, with a key only this app holds.
///
/// SSH is the channel because it is the one route into another user's session that needs no
/// privilege and survives the thing it controls: an SSH-spawned process lands *inside* the
/// account's GUI session (measured 2026-08-28: it gets a WindowServer connection, the session
/// dictionary, the virtual display list), and `launchctl bootout gui/<uid>` run that way ends
/// the session as the account itself, no root. The daemon socket inside the session is `0600`
/// and peer-checked against the account's uid, so nothing outside the account can reach it any
/// other way.
///
/// The key is installed in the account's `authorized_keys` behind
/// `restrict,command="<cli> session remote"`, so whoever holds it can run the
/// `RemoteCommand` vocabulary and nothing else — no shell, no forwarding, no pty.
nonisolated struct AgentSessionLink: Sendable {
    let account: String

    private enum Constants {
        /// Ties the host key to this alias instead of to "127.0.0.1", so the pinned key in our
        /// own known_hosts never collides with an entry the human's ssh keeps for localhost.
        static let hostAlias = "rocuronium-agent-session"
        static let hostKey = "/etc/ssh/ssh_host_ed25519_key.pub"
        static let connectTimeout = 5
    }

    /// `~/Library/Application Support/glass.kagerou.rocuronium/agent-session`, `0700`.
    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "glass.kagerou.rocuronium")
            .appending(path: "agent-session")
    }

    static var privateKey: URL { directory.appending(path: "id_ed25519") }
    static var publicKey: URL { directory.appending(path: "id_ed25519.pub") }
    static var knownHosts: URL { directory.appending(path: "known_hosts") }

    /// Creates the client key pair once and returns its public half.
    static func prepareClientKey() throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: privateKey.path) {
            let made = Subprocess.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "rocuronium-agent-session", "-f", privateKey.path])
            guard made.status == 0 else { throw LinkError.keygen(made.output) }
        }
        return try String(contentsOf: publicKey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pins the host key. It is read from `/etc/ssh` (world-readable) rather than learned on
    /// first connect, so there is no trust-on-first-use moment to intercept. Runs after
    /// provisioning: on a Mac that never had Remote Login on, the helper creates the key.
    static func pinHostKey() throws {
        guard let host = try? String(contentsOfFile: Constants.hostKey, encoding: .utf8) else { throw LinkError.hostKey }
        let fields = host.split(separator: " ")
        guard fields.count >= 2 else { throw LinkError.hostKey }
        try "\(Constants.hostAlias) \(fields[0]) \(fields[1])\n".write(to: knownHosts, atomically: true, encoding: .utf8)
    }

    static var hasKeys: Bool {
        FileManager.default.fileExists(atPath: privateKey.path) && FileManager.default.fileExists(atPath: knownHosts.path)
    }

    /// The argv for one SSH invocation of `remote`, which the forced command reads from
    /// `SSH_ORIGINAL_COMMAND`.
    func arguments(_ remote: String, keepAlive: Bool = false) -> [String] {
        var options = [
            "-F", "/dev/null",
            "-i", Self.privateKey.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "UserKnownHostsFile=\"\(Self.knownHosts.path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlias=\(Constants.hostAlias)",
            "-o", "ConnectTimeout=\(Constants.connectTimeout)",
            "-o", "LogLevel=ERROR",
            "-T",
        ]
        if keepAlive {
            // A hung link must look hung to *both* ends: the watcher sees the beats stop, and
            // ssh here exits so the daemon learns its switch is gone.
            options += ["-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=3"]
        }
        return options + ["\(account)@127.0.0.1", remote]
    }

    /// Runs one `RemoteCommand` and decodes its JSON reply.
    func call(_ remote: String, input: Data? = nil, timeout: TimeInterval = 15) async -> Result<[String: Any], LinkError> {
        guard Self.hasKeys else { return .failure(.notEnabled) }
        let argv = arguments(remote)
        let result = await Task.detached(priority: .userInitiated) {
            Subprocess.run("/usr/bin/ssh", argv, input: input, timeout: timeout)
        }.value
        let lastLine = result.output.split(separator: "\n").last.map(String.init) ?? ""
        guard let object = (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any] else {
            return .failure(.unreachable(status: result.status, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(object)
    }

    /// One request to the daemon inside the agent session, through `session remote forward`.
    func forward(_ request: [String: Any], timeout: TimeInterval = 15) async -> Result<[String: Any], LinkError> {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return .failure(.hostKey) }
        return await call("forward", input: body + [0x0A], timeout: timeout)
    }

    enum LinkError: Error, CustomStringConvertible {
        case notEnabled
        case keygen(String)
        case hostKey
        case unreachable(status: Int32, output: String)

        var description: String {
            switch self {
            case .notEnabled: "the agent session is not enabled on this Mac (rocuronium session enable)"
            case let .keygen(output): "ssh-keygen failed: \(output)"
            case .hostKey: "could not read this Mac's SSH host key at /etc/ssh/ssh_host_ed25519_key.pub"
            case let .unreachable(status, output):
                output.isEmpty ? "ssh into the agent account failed (exit \(status))" : "ssh into the agent account failed (exit \(status)): \(output)"
            }
        }
    }
}

/// Runs a system tool with an argv array — never through a shell — bounded by a timeout.
nonisolated enum Subprocess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 30) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return Result(status: 127, output: error.localizedDescription)
        }
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20000) }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        return Result(status: process.terminationStatus, output: collected.text)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
