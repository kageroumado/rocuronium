import Darwin
import Foundation
import Synchronization

/// The console end of the dead-man's switch: an SSH pipe to `session remote watch` inside the
/// agent account, with a beat written down it every couple of seconds.
///
/// The watcher at the far end ends the agent session on any of: a missed deadline, the pipe
/// closing, or a `stop` line. So each way this daemon can stop caring arrives there as a
/// bootout without this side having to do anything right:
///
/// - **crash, kill -9, clean quit** — the write end dies with the process, ssh reads EOF on
///   its stdin and passes it on;
/// - **a wedged main actor** — beats come from a thread of their own, but each one first checks
///   that the main actor has checked in recently (``noteMainActorAlive()``), so a daemon that
///   can no longer serve ⌃⌥⇧⎋ also stops vouching for the session;
/// - **⌃⌥⇧⎋** — ``stopNow()`` writes `stop`, which ends the session at once rather than after
///   the deadline.
nonisolated final class AgentSessionHeartbeat: @unchecked Sendable {
    enum Constants {
        static let beatInterval: TimeInterval = 2
        /// The watcher's deadline. Long enough to ride out a busy second or a slow ssh write;
        /// short enough that an abandoned session ends within one of them.
        static let deadlineSeconds = 15
        /// How stale the main actor's check-in may get before beats stop. Longer than the
        /// control socket's 30 s request bound, so a legitimately long request never trips it.
        static let mainActorGrace: TimeInterval = 45
        /// How long the watcher gets to say it is armed.
        static let armTimeout: TimeInterval = 10
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lastMainActorCheckIn = Mutex<TimeInterval>(ProcessInfo.processInfo.systemUptime)
    private let state = Mutex<(armed: Bool, beats: Int, ended: String?)>((false, 0, nil))
    private var beatThread: Thread?

    /// Called once, off the main actor, when the watcher's ssh exits — the switch is gone, and
    /// the session with it unless the bootout failed.
    var onEnded: (@Sendable (String) -> Void)?

    var isArmed: Bool { state.withLock { $0.armed && $0.ended == nil } }
    var beats: Int { state.withLock { $0.beats } }
    var endReason: String? { state.withLock { $0.ended } }

    /// Starts the watcher and waits until it reports armed. Throws when it refuses, fails to
    /// connect, or stays silent — and then no session may run, since nothing would end it.
    func arm(link: AgentSessionLink) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = link.arguments("watch \(Constants.deadlineSeconds)", keepAlive: true)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        // The write end must belong to this process alone: a child that inherited it would hold
        // the pipe open after we die, and the watcher would never see EOF.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        // A write after ssh exits must fail, not raise SIGPIPE and take the daemon down with it.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let signal = ArmSignal()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if signal.append(handle.availableData) {
                self?.state.withLock { $0.armed = true }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let text = signal.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = text.isEmpty ? "the watcher exited (\(finished.terminationStatus))" : text
            self?.state.withLock { $0.ended = reason }
            signal.fail(HeartbeatError.refused(reason))
            self?.onEnded?(reason)
        }
        try process.run()
        try await signal.wait(timeout: Constants.armTimeout)
        startBeating()
    }

    /// The main actor's proof of life; called from its periodic timer.
    func noteMainActorAlive() {
        lastMainActorCheckIn.withLock { $0 = ProcessInfo.processInfo.systemUptime }
    }

    /// ⌃⌥⇧⎋, or `session stop`: ends the agent session now, then closes the pipe.
    func stopNow() {
        write("stop\n")
        close()
    }

    /// Closes the pipe; the watcher reads EOF and ends the session.
    func close() {
        beatThread?.cancel()
        try? input.fileHandleForWriting.close()
    }

    private func startBeating() {
        let thread = Thread { [weak self] in
            while let self, !Thread.current.isCancelled, self.state.withLock({ $0.ended == nil }) {
                let silence = ProcessInfo.processInfo.systemUptime - self.lastMainActorCheckIn.withLock { $0 }
                if silence < Constants.mainActorGrace, self.write("beat \(Int(Date().timeIntervalSince1970))\n") {
                    self.state.withLock { $0.beats += 1 }
                }
                Thread.sleep(forTimeInterval: Constants.beatInterval)
            }
        }
        thread.name = "rocuronium.agent-session.heartbeat"
        thread.qualityOfService = .userInitiated
        beatThread = thread
        thread.start()
    }

    @discardableResult
    private func write(_ line: String) -> Bool {
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            return false
        }
    }

    /// The watcher's output, and the one wait for its "armed" line — resolved by that line, by
    /// the watcher exiting, or by the timeout, whichever comes first.
    private final class ArmSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var outcome: Result<Void, any Error>?
        private var waiter: CheckedContinuation<Void, any Error>?

        var text: String { lock.withLock { String(decoding: output, as: UTF8.self) } }

        /// Appends output; returns true the first time the armed line is complete.
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                output.append(chunk)
                guard outcome == nil, String(decoding: output, as: UTF8.self).contains("armed uid=") else { return false }
                resolve(.success(()))
                return true
            }
        }

        func fail(_ error: any Error) {
            lock.withLock { if outcome == nil { resolve(.failure(error)) } }
        }

        func wait(timeout: TimeInterval) async throws {
            let timer = Task {
                try await Task.sleep(for: .seconds(timeout))
                self.fail(HeartbeatError.silent)
            }
            defer { timer.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let outcome { continuation.resume(with: outcome) } else { waiter = continuation }
                }
            }
        }

        /// Called with the lock held.
        private func resolve(_ result: Result<Void, any Error>) {
            outcome = result
            waiter?.resume(with: result)
            waiter = nil
        }
    }

    enum HeartbeatError: Error, CustomStringConvertible {
        case refused(String)
        case silent

        var description: String {
            switch self {
            case let .refused(reason): "the dead-man's switch would not arm: \(reason)"
            case .silent: "the dead-man's switch did not report armed within \(Int(Constants.armTimeout)) s"
            }
        }
    }
}
