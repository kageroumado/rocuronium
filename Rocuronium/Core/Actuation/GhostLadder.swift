import AppKit
import ApplicationServices

/// The core of the app: deliver an action by the least invasive means that actually works,
/// and prove what happened.
///
/// Rungs are attempted in order and each is verified before falling through. Rungs 0–3 never
/// move the cursor or change the frontmost app; only `hardwareInput` does, and it is opt-in
/// per call. Falling through to it is recorded in the evidence rather than done quietly,
/// because that is the moment the user loses their hands.
nonisolated struct GhostLadder {
    /// Whether the caller accepts the cursor being taken if nothing else works.
    let allowHardwareInput: Bool

    init(allowHardwareInput: Bool = false) {
        self.allowHardwareInput = allowHardwareInput
    }

    enum Action {
        case setText(String)
        case click
        case press
    }

    // MARK: - Entry point

    func perform(_ action: Action, on element: AXElement, pid: pid_t) async -> Evidence {
        var attempts: [Evidence.Attempt] = []

        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }
        let focusBefore = ElementQuery.focused(pid: pid)?.signature

        // Rung 0 — without this the tree below is a fiction.
        let wake = await DisplayWake.ensureAwake()
        attempts.append(.init(rung: .displayWake, outcome: wake.rawValue))
        if wake == .failed {
            return await finish(
                action, element, .displayWake, .unverifiable, nil, nil,
                focusBefore, focusBefore, cursorBefore, frontBefore, attempts, pid,
            )
        }

        // Rung 1 — accessibility, then read back. A success code proves nothing.
        if let evidence = await tryAccessibility(
            action, element, pid, &attempts,
            cursorBefore, frontBefore, focusBefore,
        ) {
            return evidence
        }

        // Rung 2 — posted events, delivered to this process only.
        if let evidence = await tryPostedEvents(
            action, element, pid, &attempts,
            cursorBefore, frontBefore, focusBefore,
        ) {
            return evidence
        }

        // Rung 3 (app automation) is delegated to the target adapters: WebKit and Chromium page
        // content cannot be reached by OS input at all, and needs the app's own protocol.
        attempts.append(.init(rung: .appAutomation, outcome: "no adapter for this target"))

        // Rung 4 — the cursor-stealing path. Never silent, never implicit.
        guard allowHardwareInput else {
            attempts.append(.init(rung: .hardwareInput, outcome: "declined: not permitted by caller"))
            return await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )
        }
        attempts.append(.init(rung: .hardwareInput, outcome: "engaged — cursor is no longer the user's"))
        return await finish(
            action, element, .hardwareInput, .unverifiable, nil, nil,
            focusBefore, ElementQuery.focused(pid: pid)?.signature,
            cursorBefore, frontBefore, attempts, pid,
        )
    }

    // MARK: - Rungs

    private func tryAccessibility(
        _ action: Action, _ element: AXElement, _ pid: pid_t,
        _ attempts: inout [Evidence.Attempt],
        _ cursorBefore: CGPoint, _ frontBefore: String, _ focusBefore: String?
    ) async -> Evidence? {
        switch action {
        case let .setText(text):
            let code = element.setValue(text)
            guard code == .success else {
                attempts.append(.init(rung: .accessibility, outcome: "setValue failed (\(code.rawValue))"))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
            let readback = element.value
            // The WebKit case: the write reported success and changed nothing.
            guard readback?.contains(text) == true else {
                attempts.append(.init(rung: .accessibility, outcome: "reported success, read-back unchanged"))
                return nil
            }
            attempts.append(.init(rung: .accessibility, outcome: "confirmed by read-back"))
            return await finish(
                action, element, .accessibility, .confirmed, readback, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )

        case .click, .press:
            guard element.actionNames.contains(kAXPressAction) else {
                attempts.append(.init(rung: .accessibility, outcome: "element exposes no press action"))
                return nil
            }
            let code = element.perform()
            guard code == .success else {
                attempts.append(.init(rung: .accessibility, outcome: "press failed (\(code.rawValue))"))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
            // A press has no read-back; the honest verdict is unverifiable until the pixel
            // diff runs, which the caller supplies for visual targets.
            attempts.append(.init(rung: .accessibility, outcome: "press accepted"))
            return await finish(
                action, element, .accessibility, .unverifiable, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )
        }
    }

    private func tryPostedEvents(
        _ action: Action, _ element: AXElement, _ pid: pid_t,
        _ attempts: inout [Evidence.Attempt],
        _ cursorBefore: CGPoint, _ frontBefore: String, _ focusBefore: String?
    ) async -> Evidence? {
        switch action {
        case let .setText(text):
            // Focus the field first when we know where it is: posted keys go to the app's
            // current first responder, which may not be the element we are aiming at.
            if let frame = element.frame {
                await EventPoster.click(at: CGPoint(x: frame.midX, y: frame.midY), pid: pid)
                try? await Task.sleep(for: .milliseconds(200))
            }
            await EventPoster.type(text, pid: pid)
            try? await Task.sleep(for: .milliseconds(400))

            // Re-resolve through the focused element: in Electron the composer only becomes
            // reachable once it holds focus, so the original handle can be stale.
            let landed = ElementQuery.focused(pid: pid)?.value ?? element.value
            guard landed?.contains(text) == true else {
                attempts.append(.init(rung: .postedEvent, outcome: "posted, did not land in target"))
                return nil
            }
            attempts.append(.init(rung: .postedEvent, outcome: "confirmed by read-back"))
            return await finish(
                action, element, .postedEvent, .confirmed, landed, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )

        case .click, .press:
            guard let frame = element.frame else {
                attempts.append(.init(rung: .postedEvent, outcome: "element has no frame to click"))
                return nil
            }
            await EventPoster.click(at: CGPoint(x: frame.midX, y: frame.midY), pid: pid)
            try? await Task.sleep(for: .milliseconds(300))
            let focusAfter = ElementQuery.focused(pid: pid)?.signature
            // A focus change is weak but real evidence that the click was received.
            let verdict: Evidence.Verdict = focusAfter != focusBefore ? .confirmed : .unverifiable
            attempts.append(.init(rung: .postedEvent, outcome: "click posted"))
            return await finish(
                action, element, .postedEvent, verdict, nil, nil,
                focusBefore, focusAfter, cursorBefore, frontBefore, attempts, pid,
            )
        }
    }

    // MARK: - Evidence assembly

    private func finish(
        _ action: Action, _ element: AXElement, _ rung: Evidence.Rung,
        _ verdict: Evidence.Verdict, _ readback: String?, _ pixelDelta: Double?,
        _ focusBefore: String?, _ focusAfter: String?,
        _ cursorBefore: CGPoint, _ frontBefore: String,
        _ attempts: [Evidence.Attempt], _: pid_t
    ) async -> Evidence {
        let cursorAfter = EventPoster.cursorLocation
        let moved = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y) >= 1
        let frontAfter = await MainActor.run { EventPoster.frontmostBundleID }
        return Evidence(
            action: String(describing: action),
            target: "\(element.role) '\(element.label)'",
            rung: rung,
            verdict: verdict,
            readback: readback,
            pixelDelta: pixelDelta,
            focusBefore: focusBefore,
            focusAfter: focusAfter,
            cursorMoved: moved,
            frontmostChanged: frontAfter != frontBefore,
            attempts: attempts,
        )
    }
}
