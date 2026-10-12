import Testing
@testable import rocuronium

struct SessionTransitionResultTests {
    @Test func successfulStatusRequestCanReportFailedStartup() {
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "failed", "lastError": "selection refused"], action: "start") == "selection refused")
    }

    @Test func interruptedProgressTrackingFails() {
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "starting"], action: "start") != nil)
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "idle"], action: "start") != nil)
    }

    @Test func onlyRunningCompletesStartup() {
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "running"], action: "start") == nil)
        #expect(SessionTransitionResult.failure(in: ["ok": false, "state": "running", "error": "lookup failed"], action: "start") == "lookup failed")
    }
    @Test func stopWaitsForIdle() {
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "stopping"], action: "stop") != nil)
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "idle"], action: "stop") == nil)
        #expect(SessionTransitionResult.failure(in: ["ok": true, "state": "failed", "lastError": "session survived"], action: "stop") == "session survived")
    }
}
