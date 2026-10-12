import Foundation
import Testing
@testable import Rocuronium

@MainActor
struct SessionHelperRegistrationTests {
    @Test(arguments: [SessionHelperClient.Availability.notFound, .notRegistered])
    func absentRecordRegistersAndRequestsApproval(initial: SessionHelperClient.Availability) {
        var status = initial
        var registrations = 0
        var openedSettings = false
        let message = SessionHelperClient.registerIfNeeded(
            status: { status },
            register: { registrations += 1; status = .requiresApproval },
            openSettings: { openedSettings = true },
        )
        #expect(registrations == 1)
        #expect(openedSettings)
        #expect(message?.contains("approve") == true)
    }

    @Test func enabledServiceIsReady() {
        let message = SessionHelperClient.registerIfNeeded(
            status: { .enabled },
            register: { Issue.record("Enabled service was registered again") },
            openSettings: { Issue.record("Enabled service requested approval") },
        )
        #expect(message == nil)
    }

    @Test func pendingApprovalOpensSettings() {
        var openedSettings = false
        let message = SessionHelperClient.registerIfNeeded(
            status: { .requiresApproval },
            register: { Issue.record("Pending registration was repeated") },
            openSettings: { openedSettings = true },
        )
        #expect(openedSettings)
        #expect(message?.contains("approve") == true)
    }

    @Test func registrationErrorPreservesDiagnosis() {
        let message = SessionHelperClient.registerIfNeeded(
            status: { .notFound },
            register: { throw NSError(domain: "RegistrationTest", code: 42) },
            openSettings: { Issue.record("Failed registration requested approval") },
        )
        #expect(message?.contains("RegistrationTest 42") == true)
    }

    @Test func unresolvedRegistrationReportsItsState() {
        let message = SessionHelperClient.registerIfNeeded(
            status: { .notFound },
            register: {},
            openSettings: { Issue.record("Unresolved registration requested approval") },
        )
        #expect(message?.contains("status: notFound") == true)
    }
}
