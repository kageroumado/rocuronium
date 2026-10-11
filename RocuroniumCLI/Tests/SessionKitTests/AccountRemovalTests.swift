import Darwin
import Testing
@testable import SessionKit

/// Deleting an account whose GUI session is still running wedged the console WindowServer on
/// 2026-08-28: a physical display vanished from the display list and every screen capture
/// failed system-wide until logout. These tests pin the only order that may end an agent
/// account — bootout, then confirm that no process of the uid survives, then delete — and the
/// refusals around it.
struct AccountRemovalTests {
    /// Records every call in order, and plays back a scripted process table.
    final class FakeSystem: AccountSystem, @unchecked Sendable {
        var calls: [String] = []
        var accounts: [String: uid_t] = ["agent": 502]
        var admins: Set<String> = []
        /// Accounts the helper provisioned; removal and bootout touch nothing else.
        var registered: Set<String> = ["agent"]
        /// What `processes(of:)` returns, call by call; the last entry repeats.
        var processTable: [[pid_t]] = [[]]
        var bootoutStatus: Int32 = 0
        var deleteStatus: Int32 = 0
        private var processReads = 0

        func uid(of name: String) -> uid_t? { accounts[name] }
        func isAdmin(_ name: String) -> Bool { admins.contains(name) }
        func isRegistered(_ name: String) -> Bool { registered.contains(name) }
        func register(_ name: String) { registered.insert(name) }
        func unregister(_ name: String) { registered.remove(name) }

        func processes(of uid: uid_t) -> [pid_t] {
            calls.append("processes")
            let index = min(processReads, processTable.count - 1)
            processReads += 1
            return processTable[index]
        }

        func bootout(uid: uid_t) -> CommandResult {
            calls.append("bootout \(uid)")
            return CommandResult(status: bootoutStatus, output: "")
        }

        func deleteAccount(_ name: String) -> CommandResult {
            calls.append("delete \(name)")
            return CommandResult(status: deleteStatus, output: "")
        }

        func pause(seconds _: Double) {}
    }

    @Test func bootoutPrecedesDelete() {
        let system = FakeSystem()
        system.processTable = [[401, 402], []]
        let outcome = AccountRemoval.run(name: "agent", system: system)
        #expect(outcome == .removed(uid: 502))
        let bootout = system.calls.firstIndex(of: "bootout 502")
        let delete = system.calls.firstIndex(of: "delete agent")
        #expect(bootout != nil && delete != nil && bootout! < delete!)
    }

    /// The bootout runs even when no process is visible: a session can exist with every
    /// process hidden from an unprivileged listing, and the bootout is harmless when there is
    /// nothing to stop.
    @Test func bootoutRunsEvenWhenNothingIsVisible() {
        let system = FakeSystem()
        _ = AccountRemoval.run(name: "agent", system: system)
        #expect(system.calls.first == "bootout 502")
    }

    @Test func survivingProcessesRefuseTheDelete() {
        let system = FakeSystem()
        system.processTable = [[401]]
        let outcome = AccountRemoval.run(name: "agent", system: system)
        guard case let .refused(reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("401"))
        #expect(!system.calls.contains("delete agent"))
    }

    @Test func aFailedBootoutStillWaitsForTheProcessTable() {
        let system = FakeSystem()
        system.bootoutStatus = 150
        system.processTable = [[401]]
        #expect(AccountRemoval.run(name: "agent", system: system) != .removed(uid: 502))
        #expect(!system.calls.contains("delete agent"))
    }

    @Test func processesThatExitDuringTheWaitAllowTheDelete() {
        let system = FakeSystem()
        system.processTable = [[401, 402], [402], [402], []]
        #expect(AccountRemoval.run(name: "agent", system: system) == .removed(uid: 502))
    }

    @Test func adminAccountsAreNeverRemoved() {
        let system = FakeSystem()
        system.admins = ["agent"]
        #expect(AccountRemoval.run(name: "agent", system: system) == .refused("'agent' is an administrator; an agent account is never one, so this is not an agent account"))
        #expect(system.calls.isEmpty)
    }

    @Test func systemAccountsAreNeverRemoved() {
        let system = FakeSystem()
        system.accounts = ["_www": 70, "kirie": 501]
        if case .removed = AccountRemoval.run(name: "_www", system: system) { Issue.record("removed a system account") }
        #expect(system.calls.isEmpty)
    }

    @Test func theCallersOwnAccountIsNeverRemoved() {
        let system = FakeSystem()
        system.accounts = ["kirie": 501]
        if case .removed = AccountRemoval.run(name: "kirie", system: system, protecting: 501) {
            Issue.record("removed the caller's own account")
        }
        #expect(system.calls.isEmpty)
    }

    /// Another person's standard account on the same Mac is never the helper's to end or
    /// delete, however it is asked: only accounts it provisioned itself.
    @Test func unregisteredAccountsAreNeverRemoved() {
        let system = FakeSystem()
        system.accounts = ["agent": 502, "ely": 503]
        guard case .refused = AccountRemoval.run(name: "ely", system: system) else {
            Issue.record("removed an account the helper never provisioned")
            return
        }
        #expect(system.calls.isEmpty)
    }

    @Test func removalUnregistersTheAccount() {
        let system = FakeSystem()
        #expect(AccountRemoval.run(name: "agent", system: system) == .removed(uid: 502))
        #expect(!system.registered.contains("agent"))
    }

    @Test func aMissingAccountIsAlreadyGone() {
        let system = FakeSystem()
        system.accounts = [:]
        #expect(AccountRemoval.run(name: "agent", system: system) == .absent)
        #expect(system.calls.isEmpty)
    }

    /// Provisioning over an account whose session is live would rewrite preferences under a
    /// running cfprefsd and a LaunchAgent under a running launchd — refused, not attempted.
    @Test func provisioningRefusesALiveSession() {
        let system = FakeSystem()
        system.processTable = [[401]]
        #expect(Provisioning.gate(name: "agent", system: system) == .refused("'agent' has a running session (1 process) — stop it first: rocuronium session stop"))
    }

    @Test func provisioningAcceptsAnIdleOrNewAccount() {
        let system = FakeSystem()
        #expect(Provisioning.gate(name: "agent", system: system) == .existing(uid: 502))
        system.accounts = [:]
        #expect(Provisioning.gate(name: "agent", system: system) == .new)
    }
}
