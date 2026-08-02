import Darwin
import Foundation
import os

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
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            handle(client: client, router: router)
            close(client)
        }
    }

    private nonisolated static func handle(client: Int32, router: CommandRouter) {
        guard let request = readRequest(from: client) else { return }

        // The engine is main-actor bound; this is a socket thread. Hand the work over and wait
        // for the reply rather than touching any engine state from here.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply = Data()
        Task { @MainActor in
            reply = await router.route(request)
            semaphore.signal()
        }
        semaphore.wait()

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
