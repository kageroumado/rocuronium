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

    enum Action: Sendable {
        case setText(String)
        case click
        case press
    }

    // MARK: - Entry point

    /// Stop after the accessibility rung, whatever it reports.
    ///
    /// For a menu item this is not a preference but a correctness requirement: the rungs below
    /// aim real input at `frame.midX/midY`, and a closed menu item's rectangle is meaningless
    /// — so a declined rung 1 would post a click at an arbitrary point inside the target app,
    /// or, with hardware input allowed, move the physical cursor there. `AXPress` is the only
    /// meaningful way to actuate a menu item.
    let accessibilityOnly: Bool

    init(allowHardwareInput: Bool = false, accessibilityOnly: Bool = false) {
        self.allowHardwareInput = allowHardwareInput
        self.accessibilityOnly = accessibilityOnly
    }

    func perform(
        _ action: Action, on element: AXElement, pid: pid_t,
        refetch: () -> AXElement? = { nil }
    ) async -> Evidence {
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
            cursorBefore, frontBefore, focusBefore, refetch,
        ) {
            return await evidence.addingVisualEvidence(
                delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch),
            )
        }

        // Menu items stop here: everything below aims at a rectangle that means nothing while
        // the menu is closed. Rung 1's own verdict is the answer.
        if accessibilityOnly {
            attempts.append(.init(
                rung: .postedEvent,
                outcome: "not attempted: this target is only meaningfully actuated through accessibility",
            ))
            return await finish(
                action, element, .accessibility, .unverifiable, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )
        }

        // Rung 2 — posted events, delivered to this process only.
        if let evidence = await tryPostedEvents(
            action, element, pid, &attempts,
            cursorBefore, frontBefore, focusBefore, focusDeltaIsUsable, refetch,
        ) {
            return await evidence.addingVisualEvidence(
                delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch),
            )
        }

        // Rung 3 — a referral, not an adapter. Web page content is the one surface OS input
        // cannot reach at all, and the channel that can (refrax-ctl, CDP, Safari's own
        // scripting) belongs to the calling agent, which holds the task context and the
        // launch flags. The honest move is structured evidence naming that channel.
        let referral = WebContent.referral(for: element, pid: pid)
        attempts.append(.init(
            rung: .appAutomation,
            outcome: referral.map { "unreachable by OS input — refer to \($0.channel)" }
                ?? "no adapter for this target",
        ))

        // Rung 4 — the cursor-stealing path. Never silent, never implicit.
        guard allowHardwareInput else {
            attempts.append(.init(rung: .hardwareInput, outcome: "declined: not permitted by caller"))
            // The one verdict the design calls most important deserves the evidence we already
            // captured: pixels are the only signal left once every rung has declined.
            return await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
        }
        // A cancelled request must not go on to take the cursor: by this point the socket has
        // already told the caller the action timed out.
        guard !Task.isCancelled else {
            attempts.append(.init(rung: .hardwareInput, outcome: "refused: the request was cancelled before the cursor was taken"))
            return await finish(
                action, element, .postedEvent, .unverifiable, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            )
        }
        // The lock screen owns the console while locked: a hardware keystroke would land in
        // the password field. Ghost rungs are safe there — this one is categorically not.
        guard !UserPresence.read().screenLocked else {
            attempts.append(.init(
                rung: .hardwareInput,
                outcome: "refused: the screen is locked and hardware input would type into the lock screen",
            ))
            return await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
        }

        let live = element.isValid ? element : (refetch() ?? element)
        // A zero-area frame is not a frame. Measured across Finder, Safari, TextEdit and
        // others: a closed menu item reports a *non-nil* (0, screen-bottom) 0×0 rect, so a
        // plain nil-check passes and the midpoint lands one pixel below the bottom-left
        // corner — the Dock, or whatever hot corner is configured there.
        guard let frame = live.frame, frame.width >= 1, frame.height >= 1 else {
            attempts.append(.init(rung: .hardwareInput, outcome: "element has no frame to aim the real cursor at"))
            // Tagged with the last rung that actually posted anything: nothing was delivered
            // here, and a `hardwareInput` tag would falsely warn that the cursor was taken.
            return await finish(
                action, element, .postedEvent, .unverifiable, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            )
        }
        let aim = CGPoint(x: frame.midX, y: frame.midY)

        // A real HID click goes to whatever window is topmost at the coordinate, unlike
        // `postToPid`, which reaches a process through any amount of occlusion. Clicking an
        // occluded target would take the user's cursor and click *somebody else's* app.
        // Refuse instead, and name what is in the way. (Parking the target on the virtual
        // display is the reliable way to make this check pass.)
        if let owner = HardwareInput.ownerOfWindow(at: aim), owner != pid {
            let occluder = await MainActor.run {
                NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)"
            }
            attempts.append(.init(
                rung: .hardwareInput,
                outcome: "refused: '\(occluder)' covers the target at (\(Int(aim.x)), \(Int(aim.y))) — a real click there would hit it, not us",
            ))
            return await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
        }

        switch action {
        case let .setText(text):
            await HardwareInput.click(at: aim)
            try? await Task.sleep(for: .milliseconds(200))
            // Look before typing. The occlusion check ran *before* the click, and the click
            // itself takes ~110 ms — long enough for an app finishing launch, a ⌘-Tab, or a
            // modal from elsewhere to take the console. Unlike rung 2's `postToPid`, these
            // keystrokes go wherever the system's focus now is, so a payload with `submit`
            // could be a line run in a terminal or a message sent in an unrelated app.
            let targetBundle = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            let frontNow = await MainActor.run { EventPoster.frontmostBundleID }
            guard frontNow == targetBundle else {
                attempts.append(.init(
                    rung: .hardwareInput,
                    outcome: "clicked, but '\(frontNow)' holds the keyboard instead of the target — refusing to type into it",
                ))
                return await finish(
                    action, element, .hardwareInput, .noEffect, nil, nil,
                    focusBefore, ElementQuery.focused(pid: pid)?.signature,
                    cursorBefore, frontBefore, attempts, pid, referral: referral,
                )
            }
            let delivered = await HardwareInput.type(text)
            if delivered != text {
                // The screen locked partway through; say how far it got rather than letting
                // a partial write be judged as if the whole payload had been attempted.
                attempts.append(.init(
                    rung: .hardwareInput,
                    outcome: "typing stopped after \(delivered.count) of \(text.count) characters — the screen locked mid-run",
                ))
            }
            try? await Task.sleep(for: .milliseconds(400))
            // Same read-back discipline as rung 2: only the aimed-at element counts, and a
            // handle killed by the focus change is re-resolved before it can misreport.
            let target = live.isValid ? live : (refetch() ?? live)
            let focused = ElementQuery.focused(pid: pid)
            let isOurTarget = focused?.signature == target.signature
            let landed = isOurTarget ? focused?.value : target.value
            let arrived = text.isEmpty ? (landed?.isEmpty ?? false) : (landed?.contains(text) == true)
            // Three-way, not two: a field that exposes no readable value cannot refute the
            // write, and claiming no-effect there would send the caller retrying an action
            // that may well have landed.
            let verdict: Evidence.Verdict = arrived ? .confirmed : (landed == nil ? .unverifiable : .noEffect)
            attempts.append(.init(
                rung: .hardwareInput,
                outcome: arrived ? "confirmed by read-back" : (landed == nil ? "typed; target exposes no value to read back" : "typed, did not land in target"),
            ))
            return await finish(
                action, element, .hardwareInput, verdict, landed, nil,
                focusBefore, focused?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))

        case .click, .press:
            await HardwareInput.click(at: aim)
            try? await Task.sleep(for: .milliseconds(300))
            let focusAfter = ElementQuery.focused(pid: pid)?.signature
            let verdict: Evidence.Verdict = (focusDeltaIsUsable && focusAfter != focusBefore)
                ? .confirmed : .unverifiable
            attempts.append(.init(rung: .hardwareInput, outcome: "clicked with the real cursor"))
            return await finish(
                action, element, .hardwareInput, verdict, nil, nil,
                focusBefore, focusAfter,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
        }
    }

    // MARK: - Rungs

    private func tryAccessibility(
        _ action: Action, _ element: AXElement, _ pid: pid_t,
        _ attempts: inout [Evidence.Attempt],
        _ cursorBefore: CGPoint, _ frontBefore: String, _ focusBefore: String?,
        _ refetch: () -> AXElement?
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
            // A write can kill its own handle — Electron rebuilds elements on focus — and a
            // dead handle answers nil, which reads as "the field is untouched" and turns a
            // landed write into a false no-effect. Re-resolve only when provably dead.
            var readbackSource = element
            if !element.isValid, let replacement = refetch() {
                attempts.append(.init(
                    rung: .accessibility,
                    outcome: "element handle went stale after the write — re-resolved via the original locator",
                ))
                readbackSource = replacement
            }
            let readback = readbackSource.value
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
            // `AXShowMenu` counts as a press: menu buttons (and the remote elements System
            // Settings panes host) expose only it, and a human clicks them like any button.
            guard let pressish = element.pressishAction else {
                attempts.append(.init(rung: .accessibility, outcome: "element exposes no press or show-menu action"))
                return nil
            }
            let code = element.perform(pressish)
            guard code == .success else {
                attempts.append(.init(rung: .accessibility, outcome: "\(pressish) failed (\(code.rawValue))"))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
            // A press has no read-back; the honest verdict is unverifiable until the pixel
            // diff runs, which the caller supplies for visual targets.
            attempts.append(.init(
                rung: .accessibility,
                outcome: pressish == kAXPressAction
                    ? "press accepted"
                    : "show-menu action accepted — a menu appearing is the consequence to watch for",
            ))
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
        _ focusDeltaIsUsable: Bool, _ refetch: () -> AXElement?
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

            // The click that focused the field is exactly what makes Electron rebuild the
            // element, so the handle we aimed with may now be dead — in which case its
            // signature reads "?|…" and its value nil, misreporting a landed write as lost.
            let target = element.isValid ? element : (refetch() ?? element)
            // Read back only from the element we aimed at. Posted keys go to whatever the app
            // considers first responder, which may be something else entirely — measured on
            // Safari's address bar, where the text lands in the page instead. Accepting the
            // focused element's value as proof would report "confirmed" for text delivered to
            // the wrong field, which breaks the one promise this tool makes.
            let focused = ElementQuery.focused(pid: pid)
            let isOurTarget = focused?.signature == target.signature
            let landed = isOurTarget ? focused?.value : target.value
            let arrived = text.isEmpty ? (landed?.isEmpty ?? false) : (landed?.contains(text) == true)
            guard arrived else {
                let elsewhere = !isOurTarget && focused?.value?.contains(text) == true
                // Unreadable is not refuted. A nil read-back means the target exposes no
                // value, or its handle died and could not be re-resolved — in neither case
                // do we know the text failed to land. Falling through from here would let
                // rung 4 retype the whole payload on top of a write that may have succeeded,
                // and `contains` would then confirm the *doubled* text. Rung 1 already
                // refuses to retry for exactly this reason; rung 2 must too.
                guard landed != nil else {
                    attempts.append(.init(
                        rung: .postedEvent,
                        outcome: "posted; the target exposes no readable value, so this cannot be confirmed or refuted — not retrying, to avoid typing it twice",
                    ))
                    return await finish(
                        action, element, .postedEvent, .unverifiable, nil, nil,
                        focusBefore, focused?.signature,
                        cursorBefore, frontBefore, attempts, pid,
                    )
                }
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
            // Zero-area counts as no frame — see the note on the hardware rung; a closed menu
            // item reports a 0×0 rect at the screen corner rather than nothing at all.
            guard let frame = element.frame, frame.width >= 1, frame.height >= 1 else {
                attempts.append(.init(rung: .postedEvent, outcome: "element has no usable frame to click"))
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
    /// A dead handle reports no frame at all, which would silently drop the one signal left
    /// on the no-effect path — so it is re-resolved first, like every other read.
    private func pixelDelta(
        from baseline: CGImage?, at baselineRect: CGRect?, of element: AXElement,
        _ refetch: () -> AXElement?
    ) async -> Double? {
        guard let baseline, let baselineRect else { return nil }
        let source = element.isValid ? element : (refetch() ?? element)
        guard let frame = source.frame else { return nil }
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
        _ attempts: [Evidence.Attempt], _ pid: pid_t,
        referral: Evidence.Referral? = nil
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
            referral: referral,
        )
    }
}
