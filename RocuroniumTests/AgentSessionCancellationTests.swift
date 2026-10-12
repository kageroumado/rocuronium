import Darwin
import Foundation
import Testing
@testable import Rocuronium

@MainActor
struct AgentSessionCancellationTests {
    @Test func stopWaitsForLateLoginAndRefusesConcurrentStart() async throws {
        let fixture = SessionFixture()
        let route = DeferredLogin { fixture.pid = 123 }
        let controller = AgentSessionController(runtime: fixture.runtime)
        controller.makeBringUp = { route }
        #expect(controller.start()["state"] as? String == "starting")
        try await waitUntil { route.entered }

        let stop = await controller.stop(reason: "test cancellation")
        #expect(stop["state"] as? String == "stopping")
        #expect(!route.closed)
        #expect(controller.start()["ok"] as? Bool == false)
        #expect(await controller.stop(reason: "repeated stop")["state"] as? String == "stopping")
        #expect(fixture.endCalls == 0)

        route.complete()
        try await waitUntil { controller.phase == .idle }
        #expect(route.closed)
        #expect(fixture.pid == nil)
        #expect(fixture.endCalls == 1)
    }

    @Test func cancellationDuringCredentialReadCannotRequestLoginLater() async throws {
        let fixture = SessionFixture()
        let credential = DeferredCredential()
        var runtime = fixture.runtime
        runtime.password = { _ in await credential.read() }
        let route = DeferredLogin { fixture.pid = 123 }
        let controller = AgentSessionController(runtime: runtime)
        controller.makeBringUp = { route }
        _ = controller.start()
        try await waitUntil { credential.entered }
        #expect(await controller.stop(reason: "cancel credential read")["state"] as? String == "idle")
        credential.complete()
        try await waitUntil { route.closed }
        #expect(!route.entered)
        #expect(fixture.endCalls == 0)
        #expect(controller.phase == .idle)
    }

    @Test func failedLoginAcknowledgmentCleansCreatedSession() async throws {
        let fixture = SessionFixture()
        let route = DeferredLogin {
            fixture.pid = 123
            throw AgentRFBError("malformed acknowledgment")
        }
        let controller = AgentSessionController(runtime: fixture.runtime)
        controller.makeBringUp = { route }
        _ = controller.start()
        try await waitUntil { route.entered }
        route.complete()
        try await waitUntil {
            if case .failed = controller.phase { return true }
            return false
        }
        #expect(route.closed)
        #expect(fixture.pid == nil)
        #expect(fixture.endCalls == 1)
        #expect(controller.progress.contains("failed-start cleanup verified: agent loginwindow is gone"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition())
    }
}

@MainActor
private final class SessionFixture {
    var pid: pid_t?
    var endCalls = 0
    var runtime: AgentSessionController.Runtime {
        .init(enabled: { _ in true }, uid: { _ in 502 }, loginWindow: { _ in self.pid },
              password: { _ in "test credential" }, endSession: { _ in
                  self.endCalls += 1
                  self.pid = nil
                  return .success(["ok": true, "status": 0])
              })
    }
}

@MainActor
private final class DeferredLogin: AgentSessionBringUp {
    let route = "controlled login"
    var isHeld: Bool { entered && !closed }
    var entered = false
    var closed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let finish: () throws -> Void
    init(finish: @escaping () throws -> Void) { self.finish = finish }
    func open(account: String, password: String, progress: @escaping @MainActor (String) -> Void) async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        try finish()
    }
    func complete() { continuation?.resume(); continuation = nil }
    func close() { closed = true }
}

@MainActor
private final class DeferredCredential {
    var entered = false
    private var continuation: CheckedContinuation<String?, Never>?
    func read() async -> String? {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete() { continuation?.resume(returning: "test credential"); continuation = nil }
}
