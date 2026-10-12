import Foundation

/// A loopback Screen Sharing connection holds the agent's independent desktop open.
@MainActor
final class AgentRFBBringUp: AgentSessionBringUp {
    let route = "local Screen Sharing"
    private let connection = AgentRFBConnection()
    private var monitor: Task<Void, Never>?
    var onDisconnected: (@MainActor (String) -> Void)?
    var isHeld: Bool { connection.isHeld }

    func open(account: String, password: String, progress: @escaping @MainActor (String) -> Void) async throws {
        let connection = connection
        // macOS completes a submitted login even after the socket closes. Await its result
        // so the controller can remove that session before completing a canceled start.
        try await Task.detached(name: "agent Screen Sharing handshake") {
            try connection.open(account: account, password: password) { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(line) } }
            }
        }.value
        monitor = Task.detached(name: "agent Screen Sharing connection") { [weak self] in
            do { try connection.hold() }
            catch is CancellationError { return }
            catch {
                let message = String(describing: error)
                await self?.connectionEnded(message)
            }
        }
    }

    private func connectionEnded(_ message: String) { onDisconnected?(message) }

    func close() {
        onDisconnected = nil
        connection.cancel()
        monitor?.cancel()
        monitor = nil
    }

    isolated deinit { connection.cancel() }
}
