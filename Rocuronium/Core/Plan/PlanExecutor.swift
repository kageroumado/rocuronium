import Foundation

/// Runs a sequence plan to completion, dispatching each step through the command router
/// and evaluating guards between them. The reply is one transcript.
@MainActor
final class PlanExecutor {
    /// Per-step result in the transcript.
    struct StepResult: Sendable {
        let index: Int
        let command: String
        let intent: String
        let reply: [String: Any]
        let guardResult: PlanGuard.Result?
        let policy: String?
        let fallbackReply: [String: Any]?
    }

    private let dispatch: (CommandRouter.Request) async throws -> [String: Any]
    private let resolvePid: (CommandRouter.Request) -> pid_t?
    private let engine: Engine
    private let overlay: PresenceOverlayController?
    private let activityLog: ActivityLog

    /// Set by `pauseForHuman()`, resumed by `resume()`.
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    init(
        dispatch: @escaping (CommandRouter.Request) async throws -> [String: Any],
        resolvePid: @escaping (CommandRouter.Request) -> pid_t?,
        engine: Engine,
        overlay: PresenceOverlayController?,
        activityLog: ActivityLog
    ) {
        self.dispatch = dispatch
        self.resolvePid = resolvePid
        self.engine = engine
        self.overlay = overlay
        self.activityLog = activityLog
    }

    /// Wakes a plan paused by `pause-for-human`. Called from `resumeFromHalt()`.
    func resume() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    /// Whether a plan is currently paused and waiting for the human.
    var isPaused: Bool { pauseContinuation != nil }

    func execute(_ plan: SequencePlan) async -> [String: Any] {
        var results: [StepResult] = []
        var abortReason: String?

        if plan.profile == .visible {
            overlay?.begin(
                action: "Plan: \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")",
            )
        }

        for (index, step) in plan.steps.enumerated() {
            if EmergencyStop.isHalted {
                abortReason = "halted by the human (⌃⌥⇧⎋)"
                break
            }

            if plan.profile == .visible {
                overlay?.begin(
                    action: "Step \(index + 1)/\(plan.steps.count): \(step.intent)",
                )
            }

            let (reply, resolvedPid) = await executeStep(step, profile: plan.profile)

            var guardResult: PlanGuard.Result?
            if let expect = step.expect {
                try? await Task.sleep(for: .milliseconds(150))
                guardResult = await expect.evaluate(
                    reply: reply, pid: resolvedPid, engine: engine,
                )
            }

            let passed = guardResult?.passed ?? true
            var result = StepResult(
                index: index, command: step.command, intent: step.intent,
                reply: reply, guardResult: guardResult,
                policy: nil, fallbackReply: nil,
            )

            if !passed {
                let policy = step.onFail ?? .abort

                switch policy {
                case .abort:
                    result = StepResult(
                        index: index, command: step.command, intent: step.intent,
                        reply: reply, guardResult: guardResult,
                        policy: "abort", fallbackReply: nil,
                    )
                    results.append(result)
                    abortReason = "guard failed on step \(index + 1): \(guardResult?.reason ?? "unknown")"
                    break

                case .continue:
                    result = StepResult(
                        index: index, command: step.command, intent: step.intent,
                        reply: reply, guardResult: guardResult,
                        policy: "continue", fallbackReply: nil,
                    )

                case .pauseForHuman:
                    result = StepResult(
                        index: index, command: step.command, intent: step.intent,
                        reply: reply, guardResult: guardResult,
                        policy: "pause-for-human", fallbackReply: nil,
                    )
                    results.append(result)
                    await pauseForHuman(
                        reason: "Step \(index + 1) guard failed: \(guardResult?.reason ?? "unknown")",
                    )
                    continue

                case let .fallback(fallbackStep):
                    let (fallbackReply, _) = await executeStep(fallbackStep, profile: plan.profile)
                    result = StepResult(
                        index: index, command: step.command, intent: step.intent,
                        reply: reply, guardResult: guardResult,
                        policy: "fallback", fallbackReply: fallbackReply,
                    )
                }
            }

            results.append(result)

            if abortReason != nil { break }

            if plan.profile == .visible {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        if plan.profile == .visible {
            overlay?.commandFinished(buildTranscriptReply(results: results, abortReason: abortReason))
        }

        activityLog.append(
            action: "plan",
            target: "\(plan.steps.count) step(s), \(plan.profile.rawValue)",
            verdict: abortReason == nil ? "ok" : "aborted",
            summary: abortReason ?? "plan completed — \(results.count)/\(plan.steps.count) step(s)",
        )

        return buildTranscriptReply(results: results, abortReason: abortReason)
    }

    // MARK: - Private

    private func executeStep(
        _ step: SequencePlan.Step, profile: SequencePlan.Profile
    ) async -> ([String: Any], pid_t?) {
        let json = step.asRequestJSON(profile: profile)
        do {
            let data = try JSONSerialization.data(withJSONObject: json)
            let request = try JSONDecoder().decode(CommandRouter.Request.self, from: data)
            let reply = try await dispatch(request)
            return (reply, resolvePid(request))
        } catch {
            return (["ok": false, "error": error.localizedDescription], nil)
        }
    }

    private func pauseForHuman(reason: String) async {
        EmergencyStop.halt(reason: "Plan paused: \(reason) — resume from the Rocuronium menu bar")
        overlay?.begin(action: reason)
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    private func buildTranscriptReply(
        results: [StepResult], abortReason: String?
    ) -> [String: Any] {
        var reply: [String: Any] = [
            "ok": abortReason == nil,
            "stepsTotal": results.isEmpty ? 0 : results.last!.index + 1,
            "stepsCompleted": results.count,
            "transcript": results.map { stepReplyDict($0) },
        ]
        if let abortReason {
            reply["abortReason"] = abortReason
        }
        let lastGuardFailed = results.last.flatMap(\.guardResult).map { !$0.passed } ?? false
        reply["summary"] = abortReason != nil
            ? "plan aborted at step \(results.count): \(abortReason!)"
            : "plan completed — \(results.count) step(s)"
        return reply
    }

    private func stepReplyDict(_ result: StepResult) -> [String: Any] {
        var dict: [String: Any] = [
            "step": result.index + 1,
            "command": result.command,
            "intent": result.intent,
            "ok": result.reply["ok"] as? Bool ?? false,
        ]
        if let verdict = result.reply["verdict"] { dict["verdict"] = verdict }
        if let summary = result.reply["summary"] { dict["summary"] = summary }
        if let readback = result.reply["readback"] { dict["readback"] = readback }
        if let error = result.reply["error"] { dict["error"] = error }

        if let guard_ = result.guardResult {
            dict["guardPassed"] = guard_.passed
            dict["guardReason"] = guard_.reason
        }
        if let policy = result.policy { dict["policy"] = policy }
        if let fallback = result.fallbackReply {
            dict["fallback"] = [
                "ok": fallback["ok"] as? Bool ?? false,
                "verdict": fallback["verdict"],
                "summary": fallback["summary"],
                "error": fallback["error"],
            ].compactMapValues { $0 }
        }
        return dict
    }
}
