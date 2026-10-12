import Darwin
import Foundation

/// One loopback socket. Shutdown is synchronized; its worker alone closes the descriptor.
nonisolated final class AgentRFBConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    private var held = false
    private let timeout: TimeInterval = 45

    var isHeld: Bool { lock.withLock { held && !cancelled } }

    func cancel() {
        lock.withLock {
            cancelled = true
            held = false
            if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
        }
    }

    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func finish() {
        lock.withLock {
            held = false
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        }
    }

    private func connect() throws -> Int32 {
        try checkCancellation()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentRFBError("Could not create the Screen Sharing socket") }
        let accepted = lock.withLock {
            guard !cancelled else { return false }
            descriptor = fd
            return true
        }
        guard accepted else { Darwin.close(fd); throw CancellationError() }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw AgentRFBError("Could not configure the Screen Sharing socket")
        }
        _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(5900).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 || errno == EINPROGRESS else { throw AgentRFBError("Could not connect to local Screen Sharing") }
        try wait(fd, event: Int16(POLLOUT), until: Date().addingTimeInterval(5))
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout.size(ofValue: error))
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            throw AgentRFBError("Local Screen Sharing is unavailable (\(error))")
        }
        return fd
    }

    private func wait(_ fd: Int32, event: Int16, until deadline: Date) throws {
        while Date() < deadline {
            try checkCancellation()
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, 250)
            if result < 0 {
                if errno == EINTR { continue }
                throw AgentRFBError("Screen Sharing socket polling failed")
            }
            if descriptor.revents & event != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw AgentRFBError("Screen Sharing disconnected")
            }
        }
        throw AgentRFBError("Screen Sharing timed out")
    }

    private func read(_ count: Int, from fd: Int32, until deadline: Date) throws -> Data {
        guard count >= 0, count <= 65536 else { throw AgentRFBError("Screen Sharing message exceeds the size limit") }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(fd, event: Int16(POLLIN), until: deadline)
            let received = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received < 0, errno == EAGAIN || errno == EINTR { continue }
            guard received > 0 else { throw AgentRFBError("Screen Sharing disconnected during startup") }
            offset += received
        }
        return data
    }

    private func write(_ data: Data, to fd: Int32, until deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, event: Int16(POLLOUT), until: deadline)
            let sent = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if sent < 0, errno == EAGAIN || errno == EINTR { continue }
            guard sent > 0 else { throw AgentRFBError("Screen Sharing disconnected while sending") }
            offset += sent
        }
    }

    private func selectionMessage(from fd: Int32, until deadline: Date) throws -> Data {
        let count = Int(try AgentRFBProtocol.integer(read(2, from: fd, until: deadline), at: 0, bytes: 2))
        guard count <= AgentRFBProtocol.maximumSelectionSize else { throw AgentRFBError("Screen Sharing selection message exceeds the size limit") }
        return try read(count, from: fd, until: deadline)
    }

    func open(account: String, password: String, progress: @Sendable (String) -> Void) throws {
        do {
            var credentials = try AgentRFBProtocol.credentials(account: account, password: password)
            defer { credentials.resetBytes(in: 0..<credentials.count) }
            let fd = try connect()
            let deadline = Date().addingTimeInterval(timeout)
            guard try read(12, from: fd, until: deadline) == AgentRFBProtocol.banner else {
                throw AgentRFBError("Local Screen Sharing does not speak RFB 3.889")
            }
            try write(AgentRFBProtocol.banner, to: fd, until: deadline)
            let count = Int(try read(1, from: fd, until: deadline)[0])
            guard count > 0, try read(count, from: fd, until: deadline).contains(30) else {
                throw AgentRFBError("Local Screen Sharing does not offer Apple account authentication")
            }
            try write(Data([30]), to: fd, until: deadline)
            let challenge = try read(4, from: fd, until: deadline)
            let generator = try AgentRFBProtocol.integer(challenge, at: 0, bytes: 2)
            let size = Int(try AgentRFBProtocol.integer(challenge, at: 2, bytes: 2))
            guard (64...1024).contains(size) else { throw AgentRFBError("Unsupported Screen Sharing key size \(size)") }
            let prime = try read(size, from: fd, until: deadline)
            let peer = try read(size, from: fd, until: deadline)
            let dh = try AgentRFBDiffieHellman(generator: generator, prime: prime)
            var key = try dh.encryptionKey(peer: peer)
            defer { key.resetBytes(in: 0..<key.count) }
            let encrypted = try AgentRFBProtocol.encrypt(credentials, key: key)
            try write(encrypted + dh.publicKey, to: fd, until: deadline)
            let authResult = try AgentRFBProtocol.integer(read(4, from: fd, until: deadline), at: 0, bytes: 4)
            guard authResult == 0 else { throw AgentRFBError("Screen Sharing authentication failed (result \(authResult))") }
            progress("Screen Sharing authenticated the agent account")
            // Shared connection, enhanced ServerInit, and explicit session selection.
            try write(Data([0xc1]), to: fd, until: deadline)
            let server = try read(24, from: fd, until: deadline)
            let nameSize = Int(try AgentRFBProtocol.integer(server, at: 20, bytes: 4))
            guard nameSize <= AgentRFBProtocol.maximumNameSize else { throw AgentRFBError("Screen Sharing server name exceeds the size limit") }
            try AgentRFBProtocol.validateServerName(read(nameSize, from: fd, until: deadline))
            try AgentRFBProtocol.validateSelectionInfo(selectionMessage(from: fd, until: deadline))
            progress("Screen Sharing offers a separate virtual session")
            try write(AgentRFBProtocol.selectVirtualSession(encryptedCredentials: encrypted), to: fd, until: deadline)
            try AgentRFBProtocol.validateSelectionResult(selectionMessage(from: fd, until: deadline))
            try checkCancellation()
            lock.withLock { held = !cancelled }
            progress("Screen Sharing accepted the virtual session; connection held")
        } catch {
            finish()
            throw error
        }
    }

    /// Drain unsolicited metadata without requesting framebuffer, clipboard, or input traffic.
    func hold() throws {
        defer { finish() }
        let fd = lock.withLock { descriptor }
        guard fd >= 0 else { throw AgentRFBError("Screen Sharing connection is closed") }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try checkCancellation()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 500)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw AgentRFBError("Screen Sharing connection monitoring failed") }
            if descriptor.revents & Int16(POLLIN) != 0 {
                let received = recv(fd, &buffer, buffer.count, 0)
                if received < 0, errno == EAGAIN || errno == EINTR { continue }
                guard received > 0 else { throw AgentRFBError("Screen Sharing connection ended") }
            } else if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw AgentRFBError("Screen Sharing connection ended")
            }
        }
    }
}
