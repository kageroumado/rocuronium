import Darwin
import Foundation
import os
import System

/// A Unix-domain socket the CLI and MCP server talk to.
///
/// Everything that touches accessibility runs **inside this app**, because the Accessibility
/// permission is granted to a signed bundle, not to a binary. A standalone CLI would need its
/// own grant and would lose it on every rebuild. So the CLI is a dumb pipe: it forwards JSON
/// and prints the reply, holding no permissions and containing no automation logic.
///
/// Socket layout mirrors Refrax's control host: unlink-then-bind, `chmod 0600`, one accept
/// thread, `SO_NOSIGPIPE` so a client hanging up cannot kill the app.
@MainActor
final class ControlServer {
    private nonisolated static let log = Logger(
        subsystem: "glass.kagerou.rocuronium", category: "ControlServer",
    )

    private nonisolated enum Constants {
        static let maximumRequestBytes = 1 << 20
        static let socketPermissions: mode_t = 0o600
        /// Generous: a deep walk of a large Electron tree legitimately takes over a second.
        static let replyTimeout: TimeInterval = 30
        /// A connected client gets this long to actually send its request.
        static let readTimeout: TimeInterval = 10
    }

    static var socketPath: String {
        URL.applicationSupportDirectory
            .appending(path: "glass.kagerou.rocuronium")
            .appending(path: "control.sock")
            .path
    }

    private var listeningDescriptor: Int32 = -1
    private var acceptThread: Thread?
    private let router: CommandRouter

    init(router: CommandRouter) {
        self.router = router
    }

    // MARK: - Lifecycle

    func start() throws {
        let path = Self.socketPath
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.socketFailed(errno) }

        // A stale socket file from a crash would make bind fail with EADDRINUSE.
        unlink(path)

        // bind() creates the socket with 0777 & ~umask, and the chmod below only lands after.
        // Narrow the window rather than leaving a world-writable socket that can drive the
        // machine, however briefly.
        let previousMask = umask(0o177)
        defer { umask(previousMask) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else {
            close(descriptor)
            throw ControlError.pathTooLong
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                        source, maximumPathLength - 1)
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw ControlError.bindFailed(errno)
        }

        // Owner-only: this socket can drive the machine, so it must not be world-writable.
        chmod(path, Constants.socketPermissions)

        guard listen(descriptor, SOMAXCONN) == 0 else {
            close(descriptor)
            throw ControlError.listenFailed(errno)
        }

        listeningDescriptor = descriptor
        let thread = Thread { [router] in
            Self.acceptLoop(descriptor: descriptor, router: router)
        }
        thread.name = "rocuronium.control"
        thread.start()
        acceptThread = thread
        Self.log.notice("Control socket listening at \(path, privacy: .public)")
    }

    func stop() {
        if listeningDescriptor >= 0 {
            close(listeningDescriptor)
            listeningDescriptor = -1
        }
        unlink(Self.socketPath)
        acceptThread = nil
    }

    // MARK: - Accept loop

    private nonisolated static func acceptLoop(descriptor: Int32, router: CommandRouter) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                // The listening descriptor was closed by stop(); leaving the loop is correct.
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            guard let peer = Peer(descriptor: client), peer.isAuthorized else {
                let peerDescription = Peer(descriptor: client)?.description ?? "unidentified"
                log.error("Rejected control connection from \(peerDescription, privacy: .public)")
                _ = Data(#"{"ok":false,"error":"unauthorized"}"#.utf8).withUnsafeBytes {
                    write(client, $0.baseAddress, $0.count)
                }
                close(client)
                continue
            }
            // .notice, not .info: info-level entries are memory-only and vanish, and the
            // point of recording the caller is that it survives long enough to be read.
            log.notice("Control request from \(peer.description, privacy: .public)")

            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Without this, a client that connects and sends nothing blocks the single accept
            // thread in read() forever, and every later request — CLI or MCP — hangs with it.
            var timeout = timeval(tv_sec: Int(Constants.readTimeout), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handle(client: client, router: router)
            close(client)
        }
    }

    /// Who is on the other end of a control connection.
    ///
    /// The socket hands out this app's Accessibility grant to whoever can talk to it, so
    /// "same uid" — which is all `chmod 0600` establishes — is exactly the boundary TCC exists
    /// not to trust. This is the first half of closing that: identify and record the caller,
    /// and refuse anything not running as this user.
    ///
    /// **Known gap.** The second half is verifying the peer's code signature so that only known
    /// binaries can drive the machine. That is deliberately not done yet because the CLI ships
    /// unsigned from SwiftPM, and a check it cannot pass would be theatre. Until then every
    /// caller is logged with its pid and executable path, so an unexpected client is at least
    /// attributable after the fact.
    private nonisolated struct Peer: CustomStringConvertible {
        let pid: pid_t
        let uid: uid_t
        let executablePath: String

        init?(descriptor: Int32) {
            var credentials = xucred()
            var size = socklen_t(MemoryLayout<xucred>.size)
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) == 0 else { return nil }
            uid = credentials.cr_uid

            var peerPID: pid_t = 0
            var pidSize = socklen_t(MemoryLayout<pid_t>.size)
            pid = getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidSize) == 0 ? peerPID : -1

            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            executablePath = pid > 0 && proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0
                ? String(cString: buffer)
                : "unknown"
        }

        /// Only this user. A different uid cannot reach a 0600 socket anyway, so this is
        /// defense in depth against a permissions mistake rather than the primary control.
        var isAuthorized: Bool { uid == getuid() }

        var description: String { "pid \(pid) uid \(uid) — \(executablePath)" }
    }

    private nonisolated static func handle(client: Int32, router: CommandRouter) {
        guard let request = readRequest(from: client) else { return }

        // The engine is main-actor bound; this is a socket thread. Hand the work over and wait
        // for the reply rather than touching any engine state from here.
        // The semaphore both blocks this thread and establishes the happens-before edge that
        // makes the cross-thread write to `reply` safe.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply = Data()
        Task { @MainActor in
            reply = await router.route(request)
            semaphore.signal()
        }
        // Bounded: a wedged app (an unresponsive target can hold an AX call for seconds) must
        // not strand this thread forever. The accept loop is single-threaded, so one stuck
        // request would otherwise deadlock every future client.
        if semaphore.wait(timeout: .now() + Constants.replyTimeout) == .timedOut {
            writeAll(Data(#"{"ok":false,"error":"timed out waiting for the engine"}"#.utf8) + [0x0A], to: client)
            return
        }

        var payload = reply
        payload.append(0x0A)
        writeAll(payload, to: client)
    }

    private nonisolated static func readRequest(from client: Int32) -> Data? {
        var accumulated = Data()
        let chunkSize = 4096
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while accumulated.count < Constants.maximumRequestBytes {
            let count = read(client, &buffer, chunkSize)
            guard count > 0 else { break }
            accumulated.append(contentsOf: buffer[0 ..< count])
            // Requests are a single newline-terminated JSON object.
            if accumulated.last == 0x0A { break }
        }
        return accumulated.isEmpty ? nil : accumulated
    }

    private nonisolated static func writeAll(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(client, base + offset, data.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    enum ControlError: LocalizedError {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong

        var errorDescription: String? {
            switch self {
            case let .socketFailed(code): "socket() failed: \(String(cString: strerror(code)))"
            case let .bindFailed(code): "bind() failed: \(String(cString: strerror(code)))"
            case let .listenFailed(code): "listen() failed: \(String(cString: strerror(code)))"
            case .pathTooLong: "Socket path exceeds sun_path."
            }
        }
    }
}
