import Testing
@testable import Rocuronium

@MainActor
struct EmergencyHotkeyLifetimeTests {
    @Test(arguments: [EmergencyHotkeyLifetime.Owner.overlay, .agentSession])
    func shortcutSurvivesEitherOwnerReleasingFirst(first: EmergencyHotkeyLifetime.Owner) throws {
        var registrations = 0
        var releases = 0
        let lifetime = EmergencyHotkeyLifetime(register: { registrations += 1 }, unregister: { releases += 1 })
        try lifetime.acquire(.overlay)
        try lifetime.acquire(.agentSession)
        try lifetime.acquire(.agentSession)
        #expect(registrations == 1)
        lifetime.release(first)
        #expect(releases == 0)
        lifetime.release(first == .overlay ? .agentSession : .overlay)
        #expect(releases == 1)
        lifetime.release(first)
        #expect(releases == 1)
    }

    @Test func registrationFailureCanBeRetried() throws {
        var attempts = 0
        var releases = 0
        let lifetime = EmergencyHotkeyLifetime(register: {
            attempts += 1
            if attempts == 1 { throw AgentRFBError("registration refused") }
        }, unregister: { releases += 1 })
        #expect(throws: AgentRFBError.self) { try lifetime.acquire(.agentSession) }
        lifetime.release(.agentSession)
        #expect(releases == 0)
        try lifetime.acquire(.agentSession)
        #expect(attempts == 2)
        lifetime.release(.agentSession)
        #expect(releases == 1)
    }

    @Test func ownerTeardownReleasesRegistration() throws {
        var releases = 0
        var lifetime: EmergencyHotkeyLifetime? = EmergencyHotkeyLifetime(register: {}, unregister: { releases += 1 })
        try lifetime?.acquire(.agentSession)
        lifetime = nil
        #expect(releases == 1)
    }
}
