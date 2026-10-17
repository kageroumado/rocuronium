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
        var shortcutHeld = false
        controller.retainEmergencyShortcut = { shortcutHeld = true }
        controller.releaseEmergencyShortcut = { shortcutHeld = false }
        #expect(controller.start()["state"] as? String == "starting")
        try await waitUntil { route.entered }

        let stop = await controller.stop(reason: "test cancellation")
        #expect(stop["state"] as? String == "stopping")
        #expect(!route.closed)
        #expect(shortcutHeld)
        #expect(controller.start()["ok"] as? Bool == false)
        #expect(await controller.stop(reason: "repeated stop")["state"] as? String == "stopping")
        #expect(fixture.endCalls == 0)

        route.complete()
        try await waitUntil { controller.phase == .idle }
        #expect(route.closed)
        #expect(fixture.pid == nil)
        #expect(fixture.endCalls == 1)
        #expect(shortcutHeld == false)
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

    @Test func accountCannotChangeDuringStartup() async {
        let fixture = SessionFixture()
        let controller = AgentSessionController(runtime: fixture.runtime)
        controller.makeBringUp = { DeferredLogin { fixture.pid = 123 } }
        _ = controller.start()
        let reply = await controller.enable(password: nil, account: "another-agent")
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("wait for idle") == true)
        _ = await controller.stop(reason: "test cleanup")
    }

    @Test func unavailableEmergencyShortcutRefusesLogin() {
        let fixture = SessionFixture()
        let route = DeferredLogin { fixture.pid = 123 }
        let controller = AgentSessionController(runtime: fixture.runtime)
        controller.makeBringUp = { route }
        controller.retainEmergencyShortcut = { throw AgentRFBError("shortcut occupied") }
        let reply = controller.start()
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["error"] as? String == "shortcut occupied")
        #expect(controller.phase == .idle)
        #expect(route.entered == false)
    }

    @Test func restartedDaemonCleansLateLoginBeforeAllowingStart() async throws {
        let fixture = SessionFixture()
        let now = Date()
        var saved: PendingAgentLogin? = .init(account: "agent", uid: 502, observationDeadline: now.addingTimeInterval(90))
        var runtime = fixture.runtime
        runtime.loadPendingLogin = { saved }
        runtime.savePendingLogin = { saved = $0 }
        var paused = false
        runtime.recoveryPause = {
            paused = true
            try await Task.sleep(for: .milliseconds(10))
        }
        let controller = AgentSessionController(runtime: runtime)
        #expect(controller.phase == .stopping)
        #expect(controller.start()["ok"] as? Bool == false)
        try await waitUntil { paused }
        #expect(saved != nil)
        fixture.pid = 456
        try await waitUntil { controller.phase == .idle }
        #expect(saved == nil)
        #expect(fixture.pid == nil)
        #expect(fixture.endCalls == 1)
    }

    @Test func timedOutAcknowledgmentWaitsForLateSession() async throws {
        let fixture = SessionFixture()
        var saved: PendingAgentLogin?
        var runtime = fixture.runtime
        runtime.savePendingLogin = { saved = $0 }
        var paused = false
        runtime.recoveryPause = {
            paused = true
            try await Task.sleep(for: .milliseconds(10))
        }
        let route = DeferredLogin { throw AgentRFBError("acknowledgment timed out") }
        let controller = AgentSessionController(runtime: runtime)
        controller.makeBringUp = { route }
        _ = controller.start()
        try await waitUntil { route.entered }
        #expect(saved != nil)
        route.complete()
        try await waitUntil { paused }
        fixture.pid = 789
        try await waitUntil {
            if case .failed = controller.phase { return true }
            return false
        }
        #expect(fixture.pid == nil)
        #expect(fixture.endCalls == 1)
        #expect(saved == nil)
    }

    @Test func unreadableRecoveryRecordRefusesStartup() {
        let fixture = SessionFixture()
        var runtime = fixture.runtime
        runtime.loadPendingLogin = { throw AgentRFBError("unreadable journal") }
        let controller = AgentSessionController(runtime: runtime)
        #expect(controller.start()["ok"] as? Bool == false)
    }

    @Test func failedCleanupRetainsRecordForRetry() async throws {
        let fixture = SessionFixture()
        fixture.pid = 456
        var now = Date()
        var saved: PendingAgentLogin? = .init(account: "agent", uid: 502, observationDeadline: now)
        var runtime = fixture.runtime
        runtime.loadPendingLogin = { saved }
        runtime.savePendingLogin = { saved = $0 }
        runtime.now = { now }
        runtime.recoveryPause = { now = now.addingTimeInterval(11) }
        runtime.endSession = { _ in .success(["ok": false]) }
        let controller = AgentSessionController(runtime: runtime)
        try await waitUntil {
            if case .failed = controller.phase { return true }
            return false
        }
        #expect(saved != nil)
        #expect(controller.start()["ok"] as? Bool == false)
        fixture.pid = nil
        let retry = await controller.stop(reason: "retry cleanup")
        #expect(retry["state"] as? String == "stopping")
        try await waitUntil { controller.phase == .idle }
        #expect(saved == nil)
        #expect(controller.phase == .idle)
    }

    @Test func recoveryRefusesChangedAccountIdentity() async throws {
        let fixture = SessionFixture()
        var runtime = fixture.runtime
        let pending = PendingAgentLogin(account: "agent", uid: 999, observationDeadline: Date())
        runtime.loadPendingLogin = { pending }
        var cleared = false
        runtime.savePendingLogin = { _ in cleared = true }
        let controller = AgentSessionController(runtime: runtime)
        try await waitUntil {
            if case .failed = controller.phase { return true }
            return false
        }
        #expect(fixture.endCalls == 0)
        #expect(cleared == false)
        #expect(controller.start()["ok"] as? Bool == false)
    }

    @Test func recoveryObservesTheWholeWindowWhenNoSessionAppears() async throws {
        let fixture = SessionFixture()
        var now = Date()
        let began = now
        var saved: PendingAgentLogin? = .init(account: "agent", uid: 502, observationDeadline: now.addingTimeInterval(90))
        var runtime = fixture.runtime
        runtime.loadPendingLogin = { saved }
        runtime.savePendingLogin = { saved = $0 }
        runtime.now = { now }
        runtime.recoveryPause = { now = now.addingTimeInterval(30) }
        let controller = AgentSessionController(runtime: runtime)
        #expect(controller.start()["ok"] as? Bool == false)
        try await waitUntil { controller.phase == .idle }
        #expect(now.timeIntervalSince(began) == 90)
        #expect(saved == nil)
        #expect(fixture.endCalls == 0)
    }

    @Test func journalWriteFailurePreventsLoginRequest() async throws {
        let fixture = SessionFixture()
        var runtime = fixture.runtime
        runtime.savePendingLogin = { _ in throw AgentRFBError("journal write failed") }
        let route = DeferredLogin { fixture.pid = 123 }
        let controller = AgentSessionController(runtime: runtime)
        controller.makeBringUp = { route }
        _ = controller.start()
        try await waitUntil {
            if case .failed = controller.phase { return true }
            return false
        }
        #expect(route.entered == false)
        #expect(fixture.endCalls == 0)
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
              }, makeSwitch: { TestSwitch() })
    }
}

/// Arms at once and never reaches an account over SSH.
private final class TestSwitch: AgentSessionSwitch, @unchecked Sendable {
    var onEnded: (@Sendable (String) -> Void)?
    private(set) var isArmed = false
    var beats: Int { 0 }
    private(set) var endReason: String?
    func arm(link: AgentSessionLink, beforeLogin: Bool) async throws { isArmed = true }
    func noteMainActorAlive() {}
    func stopNow() { close() }
    func close() {
        guard isArmed else { return }
        isArmed = false
        endReason = "closed"
        onEnded?("closed")
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
