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
        // Focus is sampled after rung 0, not here: while the display sleeps every tree is
        // degenerate, so a pre-wake signature necessarily differs from a post-wake one and the
        // focus-delta click check below would read "confirmed" for every wake-then-click cycle
        // — precisely the unattended overnight case this exists for.
        var focusBefore: String?

        // Preflight the grant, because the failure without it is silent. An ungranted
        // CGEvent post returns no error and simply does nothing, which would surface here as
        // an ordinary "no effect" verdict and send the caller hunting for a bug in the app it
        // is driving. This is the single most common way tools like this appear broken.
        guard AXIsProcessTrusted() else {
            attempts.append(.init(
                rung: .accessibility,
                outcome: "Accessibility is not granted — the system discards synthesized input silently",
            ))
            focusBefore = ElementQuery.focused(pid: pid)?.signature
            return await finish(
                action, element, .accessibility, .unverifiable, nil, nil,
                focusBefore, focusBefore, cursorBefore, frontBefore, attempts, pid,
            )
        }

        // Rung 0 — without this the tree below is a fiction.
        let wake = await DisplayWake.ensureAwake()
        attempts.append(.init(rung: .displayWake, outcome: wake.rawValue))
        focusBefore = ElementQuery.focused(pid: pid)?.signature
        // A wake reshapes every tree, so focus deltas across it prove nothing.
        let focusDeltaIsUsable = wake != .woken
        if wake == .failed {
            return await finish(
                action, element, .displayWake, .unverifiable, nil, nil,
                focusBefore, focusBefore, cursorBefore, frontBefore, attempts, pid,
            )
        }

        // A baseline for visual verification, taken after the wake so it depicts a screen
        // that is actually on. Absent when Screen Recording was never granted, in which case
        // actions without a read-back stay honestly unverifiable.
        let baselineRect = element.frame
        let baseline = await baselineImage(of: element)

        // Hold the panel awake for the whole action, not just past the initial wake: a long
        // sequence can outlive the wake and take every accessibility tree down with it.
        let hold = DisplayWake.Hold(reason: "Rocuronium is driving the interface")
        defer { hold?.release() }

        // Rung 1 — accessibility, then read back. A success code proves nothing.
        if let evidence = await tryAccessibility(
            action, element, pid, &attempts,
            cursorBefore, frontBefore, focusBefore,
        ) {
            return await evidence.addingVisualEvidence(
                delta: pixelDelta(from: baseline, at: baselineRect, of: element),
            )
        }

        // Rung 2 — posted events, delivered to this process only.
        if let evidence = await tryPostedEvents(
            action, element, pid, &attempts,
            cursorBefore, frontBefore, focusBefore, focusDeltaIsUsable,
        ) {
            return await evidence.addingVisualEvidence(
                delta: pixelDelta(from: baseline, at: baselineRect, of: element),
            )
        }

        // Rung 3 (app automation) is delegated to the target adapters: WebKit and Chromium page
        // content cannot be reached by OS input at all, and needs the app's own protocol.
        attempts.append(.init(rung: .appAutomation, outcome: "no adapter for this target"))

        // Rung 4 — the cursor-stealing path. Never silent, never implicit.
        guard allowHardwareInput else {
            attempts.append(.init(rung: .hardwareInput, outcome: "declined: not permitted by caller"))
            // The one verdict the design calls most important deserves the evidence we already
            // captured: pixels are the only signal left once every rung has declined.
            return await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element))
        }
        attempts.append(.init(rung: .hardwareInput, outcome: "not implemented — no hardware-input path exists yet"))
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
            let before = element.value
            let code = element.setValue(text)
            guard code == .success else {
                attempts.append(.init(rung: .accessibility, outcome: "setValue failed (\(code.rawValue))"))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
            let readback = element.value
            // An empty probe would "match" anything, so a cleared field must be verified by
            // emptiness rather than by containment.
            let landed = text.isEmpty ? (readback?.isEmpty ?? false) : (readback?.contains(text) == true)
            // The WebKit case: the write reported success and changed nothing.
            guard landed else {
                // Falling through would type the same text again on top of a write that may
                // have actually landed — doubling it. Read-back can differ from what we wrote
                // for innocent reasons: AppKit's smart quotes turn "don't" into "don’t", and
                // `"don’t".contains("don't")` is false. Only continue if the field is provably
                // untouched; otherwise report what is actually there.
                if readback != before {
                    attempts.append(.init(
                        rung: .accessibility,
                        outcome: "value changed but does not match what was written — not retrying, to avoid duplicating it",
                    ))
                    return await finish(
                        action, element, .accessibility, .noEffect, readback, nil,
                        focusBefore, ElementQuery.focused(pid: pid)?.signature,
                        cursorBefore, frontBefore, attempts, pid,
                    )
                }
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
        _ cursorBefore: CGPoint, _ frontBefore: String, _ focusBefore: String?,
        _ focusDeltaIsUsable: Bool
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
            // Read back only from the element we aimed at. Posted keys go to whatever the app
            // considers first responder, which may be something else entirely — measured on
            // Safari's address bar, where the text lands in the page instead. Accepting the
            // focused element's value as proof would report "confirmed" for text delivered to
            // the wrong field, which breaks the one promise this tool makes.
            let focused = ElementQuery.focused(pid: pid)
            let isOurTarget = focused?.signature == element.signature
            let landed = isOurTarget ? focused?.value : element.value
            let arrived = text.isEmpty ? (landed?.isEmpty ?? false) : (landed?.contains(text) == true)
            guard arrived else {
                let elsewhere = !isOurTarget && focused?.value?.contains(text) == true
                attempts.append(.init(
                    rung: .postedEvent,
                    outcome: elsewhere
                        ? "posted, but the text landed in \(focused?.role ?? "?") '\(focused?.label ?? "")' instead"
                        : "posted, did not land in target",
                ))
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
            // A focus change is weak but real evidence that the click was received — unless a
            // display wake intervened, which changes every signature by itself.
            let verdict: Evidence.Verdict = (focusDeltaIsUsable && focusAfter != focusBefore)
                ? .confirmed : .unverifiable
            attempts.append(.init(rung: .postedEvent, outcome: "click posted"))
            return await finish(
                action, element, .postedEvent, verdict, nil, nil,
                focusBefore, focusAfter, cursorBefore, frontBefore, attempts, pid,
            )
        }
    }

    // MARK: - Visual verification

    /// Captures the target's rectangle before acting, when that is possible at all.
    private func baselineImage(of element: AXElement) async -> CGImage? {
        guard ScreenCapture.isPermitted, let frame = element.frame else { return nil }
        return try? await ScreenCapture.image(of: frame)
    }

    /// Re-captures the same rectangle and reports how much of it moved. The element is
    /// re-read for its frame because a confirmed action may have resized or moved it; if it
    /// did, the rectangles no longer match and the diff correctly declines to answer.
    private func pixelDelta(
        from baseline: CGImage?, at baselineRect: CGRect?, of element: AXElement
    ) async -> Double? {
        guard let baseline, let baselineRect, let frame = element.frame else { return nil }
        // Same size is not the same place. A row that scrolled, or a field shifted by a layout
        // change, yields two equally-sized captures of *different* regions — which diff as a
        // large delta and would read as a confident confirmation.
        guard frame == baselineRect else { return nil }
        guard let after = try? await ScreenCapture.image(of: frame) else { return nil }
        return ScreenDiff.changedFraction(from: baseline, to: after)
    }

    // MARK: - Evidence assembly

    private func finish(
        _ action: Action, _ element: AXElement, _ rung: Evidence.Rung,
        _ verdict: Evidence.Verdict, _ readback: String?, _ pixelDelta: Double?,
        _ focusBefore: String?, _ focusAfter: String?,
        _ cursorBefore: CGPoint, _ frontBefore: String,
        _ attempts: [Evidence.Attempt], _ pid: pid_t
    ) async -> Evidence {
        let cursorAfter = EventPoster.cursorLocation
        let moved = hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y) >= 1
        let frontAfter = await MainActor.run { EventPoster.frontmostBundleID }
        let targetBundle = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
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
            frontmostBecameTarget: frontAfter != frontBefore && frontAfter == targetBundle,
            attempts: attempts,
        )
    }
}
