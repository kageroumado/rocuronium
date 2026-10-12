import Foundation
import Testing
@testable import Rocuronium

@MainActor
struct PlanExecutorTests {
    private func plan(_ steps: [[String: Any]]) throws -> SequencePlan {
        try JSONDecoder().decode(SequencePlan.self, from: JSONSerialization.data(withJSONObject: ["profile": "ghost", "steps": steps]))
    }

    @Test func refusalAbortsWithoutAnExplicitGuard() async throws {
        var commands: [String] = []
        let executor = PlanExecutor(dispatch: { request in
            commands.append(request.command)
            return ["ok": false, "error": "start refused"]
        }, resolvePid: { _ in nil }, engine: Engine(), overlay: nil, activityLog: ActivityLog())
        let reply = await executor.execute(try plan([["command": "session", "action": "start"], ["command": "status"]]))
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["stepsTotal"] as? Int == 2)
        #expect(reply["stepsCompleted"] as? Int == 1)
        #expect(commands == ["session"])
        #expect((reply["abortReason"] as? String)?.contains("start refused") == true)
    }

    @Test func continuingAfterFailureRetainsAggregateFailure() async throws {
        let executor = PlanExecutor(dispatch: { request in
            ["ok": request.command == "status"]
        }, resolvePid: { _ in nil }, engine: Engine(), overlay: nil, activityLog: ActivityLog())
        let reply = await executor.execute(try plan([["command": "key", "onFail": "continue"], ["command": "status"]]))
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["stepsCompleted"] as? Int == 2)
        #expect(reply["stepsFailed"] as? Int == 1)
        #expect(reply["abortReason"] == nil)
    }

    @Test func passingGuardDoesNotOverrideCommandFailure() async throws {
        let executor = PlanExecutor(dispatch: { _ in ["ok": false, "verdict": "unverifiable"] },
                                    resolvePid: { _ in nil }, engine: Engine(), overlay: nil, activityLog: ActivityLog())
        let reply = await executor.execute(try plan([["command": "key", "expect": ["type": "verdict", "verdict": "unverifiable"]]]))
        #expect(reply["ok"] as? Bool == false)
    }

    @Test(arguments: [true, false])
    func fallbackMustSucceedAndSatisfyItsGuard(_ guardPasses: Bool) async throws {
        let executor = PlanExecutor(dispatch: { request in
            ["ok": request.command == "status", "verdict": "confirmed"]
        }, resolvePid: { _ in nil }, engine: Engine(), overlay: nil, activityLog: ActivityLog())
        let fallback: [String: Any] = ["command": "status", "expect": ["type": "verdict", "verdict": guardPasses ? "confirmed" : "noEffect"]]
        let reply = await executor.execute(try plan([["command": "key", "onFail": ["fallback": fallback]]]))
        #expect(reply["ok"] as? Bool == guardPasses)
        #expect(reply["stepsFailed"] as? Int == (guardPasses ? 0 : 1))
    }

    @Test func thrownCommandFailureIsReported() async throws {
        let executor = PlanExecutor(dispatch: { _ in throw CocoaError(.fileReadNoSuchFile) },
                                    resolvePid: { _ in nil }, engine: Engine(), overlay: nil, activityLog: ActivityLog())
        let reply = await executor.execute(try plan([["command": "read"]]))
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["stepsFailed"] as? Int == 1)
    }
}
