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
        var fallbackGuardResult: PlanGuard.Result?

        var succeeded: Bool {
            if let fallbackReply {
                return fallbackReply["ok"] as? Bool == true && (fallbackGuardResult?.passed ?? true)
            }
            return reply["ok"] as? Bool == true && (guardResult?.passed ?? true)
        }
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

    /// Wakes a plan paused by `pause-for-human`. Called from `resumeFromHalt()`; a no-op when
    /// no plan is paused. The paused state itself is visible through `EmergencyStop.reason`,
    /// which a pause sets to "Plan paused: …".
    func resume() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func execute(_ plan: SequencePlan) async -> [String: Any] {
        var results: [StepResult] = []
        var abortReason: String?
        // Each step's reply, keyed by 1-based step number, so a later step's `refs` can read
        // it ("$2.foundAt.cx").
        var priorReplies: [Int: [String: Any]] = [:]

        // The plan's intents are the panel's step list, and its end is the session's end: a plan
        // knows its whole sequence, so it never leaves the panel guessing what comes next.
        overlay?.beginPlan(intents: plan.steps.map(\.intent))

        for (index, step) in plan.steps.enumerated() {
            if EmergencyStop.isHalted {
                abortReason = "halted by the human (⌃⌥⇧⎋)"
                break
            }

            overlay?.advanceStep(to: index + 1)
            overlay?.begin(action: PanelAction(
                verb: step.command, app: step.app, label: step.label, text: step.text,
                point: step.x.flatMap { x in step.y.map { CGPoint(x: x, y: $0) } },
                keys: step.keys, menuPath: step.command == "menu" ? step.path : nil,
                why: step.why,
                cursorTaking: step.allowHardwareInput == true || step.command == "move" || step.command == "drag",
            ))

            let (reply, resolvedPid) = await executeStep(step, profile: plan.profile, priorReplies: priorReplies)
            priorReplies[index + 1] = reply
            overlay?.commandFinished(reply)

            let guardResult = await evaluateGuard(step.expect, reply: reply, pid: resolvedPid)
            let commandPassed = reply["ok"] as? Bool == true
            let passed = commandPassed && (guardResult?.passed ?? true)
            let failureReason = commandPassed
                ? "guard failed: \(guardResult?.reason ?? "unknown")"
                : "command failed: \(reply["error"] ?? reply["summary"] ?? "command returned no success")"
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
                    // No append here: the common append below records this step exactly once, and
                    // `abortReason != nil` then breaks the loop. Appending in the switch too would
                    // list the aborted step twice and inflate stepsCompleted.
                    abortReason = "step \(index + 1) \(failureReason)"

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
                        reason: "Step \(index + 1) \(failureReason)",
                    )
                    continue

                case let .fallback(fallbackStep):
                    let (fallbackReply, fallbackPid) = await executeStep(fallbackStep, profile: plan.profile, priorReplies: priorReplies)
                    result = StepResult(
                        index: index, command: step.command, intent: step.intent,
                        reply: reply, guardResult: guardResult,
                        policy: "fallback", fallbackReply: fallbackReply,
                    )
                    result.fallbackGuardResult = await evaluateGuard(fallbackStep.expect, reply: fallbackReply, pid: fallbackPid)
                    if result.succeeded {
                        priorReplies[index + 1] = fallbackReply
                    } else {
                        abortReason = "fallback failed on step \(index + 1): \(fallbackReply["error"] ?? result.fallbackGuardResult?.reason ?? "command failed")"
                    }
                }
            }

            results.append(result)

            if abortReason != nil { break }

            if plan.profile == .visible {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        let failedCount = results.filter { !$0.succeeded }.count
        let completedWithFailures = failedCount > 0 ? "plan completed with \(failedCount) failed step(s)" : nil
        overlay?.endPlan(abortReason: abortReason ?? completedWithFailures)
        let reply = buildTranscriptReply(results: results, total: plan.steps.count, abortReason: abortReason)
        activityLog.append(
            action: "plan",
            target: "\(plan.steps.count) step(s), \(plan.profile.rawValue)",
            verdict: reply["ok"] as? Bool == true ? "ok" : "failed",
            summary: reply["summary"] as? String ?? "plan ended",
        )
        return reply
    }

    private func evaluateGuard(_ expect: PlanGuard?, reply: [String: Any], pid: pid_t?) async -> PlanGuard.Result? {
        guard let expect else { return nil }
        try? await Task.sleep(for: .milliseconds(150))
        if expect.needsLivePerception, !DisplayWake.perceptionIsReliable {
            return PlanGuard.Result(passed: false, reason: "could not evaluate the guard: the display is asleep")
        }
        return await expect.evaluate(reply: reply, pid: pid, engine: engine)
    }

    // MARK: - Private

    private func executeStep(
        _ step: SequencePlan.Step, profile: SequencePlan.Profile,
        priorReplies: [Int: [String: Any]]
    ) async -> ([String: Any], pid_t?) {
        var json = step.asRequestJSON(profile: profile)
        // Resolve `refs` — a field set from an earlier step's reply, like a scroll's foundAt
        // rectangle feeding the click that follows. An unresolved reference is reported rather
        // than silently dropped: a plan that meant to click where step 2 found text must not
        // instead click the focused element.
        if let refs = step.refs {
            for (field, reference) in refs {
                guard let value = Self.resolveReference(reference, in: priorReplies) else {
                    return (["ok": false, "error": "could not resolve reference '\(reference)' for '\(field)' — no such step reply or path"], nil)
                }
                json[field] = value
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: json)
            let request = try JSONDecoder().decode(CommandRouter.Request.self, from: data)
            let reply = try await dispatch(request)
            return (reply, resolvePid(request))
        } catch {
            // Route the error through the same extraction `route()` uses, so a step that fails on
            // an occluded target keeps its `suggestion` and an ambiguous window keeps its
            // `windowCandidates` — the actionable next move a bare localizedDescription would drop.
            return (CommandRouter.errorReply(from: error), nil)
        }
    }

    /// Resolves one `$<step>.<key>.<key>` reference against the transcript so far. One level of
    /// expression: dotted reply keys, plus `cx`/`cy` derived as the center of a `{x,y,w,h}`
    /// block (a `foundAt` or `frame` rectangle). Nil when the step, a key, or the shape is
    /// missing — the caller turns that into a visible error.
    static func resolveReference(_ reference: String, in priorReplies: [Int: [String: Any]]) -> Any? {
        guard reference.hasPrefix("$") else { return nil }
        let segments = reference.dropFirst().split(separator: ".").map(String.init)
        guard let head = segments.first, let step = Int(head), let reply = priorReplies[step] else { return nil }
        func number(_ any: Any?) -> Double? { (any as? Double) ?? (any as? NSNumber)?.doubleValue }
        var current: Any = reply
        for segment in segments.dropFirst() {
            if segment == "cx" || segment == "cy", let rect = current as? [String: Any],
               let x = number(rect["x"]), let y = number(rect["y"]),
               let w = number(rect["w"]), let h = number(rect["h"]) {
                // Center of the rect; a terminal derivation, so return straight away.
                return segment == "cx" ? x + w / 2 : y + h / 2
            }
            guard let dict = current as? [String: Any], let next = dict[segment] else { return nil }
            current = next
        }
        return current
    }

    private func pauseForHuman(reason: String) async {
        EmergencyStop.halt(reason: "Plan paused: \(reason) — resume from the Rocuronium menu bar")
        overlay?.pausePlan()
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
    }

    private func buildTranscriptReply(
        results: [StepResult], total: Int, abortReason: String?
    ) -> [String: Any] {
        var reply: [String: Any] = [
            "ok": abortReason == nil && results.allSatisfy(\.succeeded),
            "stepsTotal": total,
            "stepsFailed": results.filter { !$0.succeeded }.count,
            "stepsCompleted": results.count,
            "transcript": results.map { stepReplyDict($0) },
        ]
        if let abortReason {
            reply["abortReason"] = abortReason
        }
        reply["summary"] = abortReason != nil
            ? "plan aborted at step \(results.count): \(abortReason!)"
            : (results.allSatisfy(\.succeeded) ? "plan completed — \(results.count) step(s)" : "plan completed with \(results.filter { !$0.succeeded }.count) failed step(s)")
        return reply
    }

    private func stepReplyDict(_ result: StepResult) -> [String: Any] {
        var dict: [String: Any] = [
            "step": result.index + 1,
            "command": result.command,
            "intent": result.intent,
            "succeeded": result.succeeded,
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
                "guardPassed": result.fallbackGuardResult?.passed,
                "guardReason": result.fallbackGuardResult?.reason,
            ].compactMapValues { $0 }
        }
        return dict
    }
}
