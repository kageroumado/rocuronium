import AppKit
import ApplicationServices

/// The core of the app: deliver an action by the least invasive means that actually works,
/// and prove what happened.
///
/// Tentacles are attempted in order and each is verified before falling through. Tentacles 0–3 never
/// move the cursor or change the frontmost app; only `hardwareInput` does, and it is opt-in
/// per call. Falling through to it is recorded in the evidence rather than done quietly,
/// because that is the moment the user loses their hands.
nonisolated struct GhostReach {
    /// Whether the caller accepts the cursor being taken if nothing else works.
    let allowHardwareInput: Bool

    enum Action: Sendable {
        case setText(String)
        case click
        case press
    }

    /// How a click is delivered — button, count, and held modifiers. The default is the plain
    /// left single click that `AXPress` can stand in for; anything else has no accessibility
    /// equivalent and is delivered as a real posted (or hardware) event carrying these.
    struct ClickOptions: Sendable {
        enum Button: String, Sendable { case left, right }
        var button: Button = .left
        var count: Int = 1
        var modifiers: CGEventFlags = []

        /// The one shape `AXPress` faithfully reproduces. Everything else must be an event.
        var isPlainLeftClick: Bool { button == .left && count == 1 && modifiers.isEmpty }
    }

    // MARK: - Entry point

    /// Stop after the accessibility tentacle, whatever it reports.
    ///
    /// For a menu item this is not a preference but a correctness requirement: the tentacles below
    /// aim real input at `frame.midX/midY`, and a closed menu item's rectangle is meaningless
    /// — so a declined tentacle 1 would post a click at an arbitrary point inside the target app,
    /// or, with hardware input allowed, move the physical cursor there. `AXPress` is the only
    /// meaningful way to actuate a menu item.
    let accessibilityOnly: Bool

    /// How a `.click` is delivered. Ignored by `.press` and `.setText`.
    let clickOptions: ClickOptions

    /// Skip the ghost tentacles and deliver a real activation + hardware click, so the action
    /// is a genuine user gesture.
    ///
    /// A `postToPid` click and an `AXPress` both actuate a control, but neither activates the app
    /// nor moves the cursor, and the system therefore treats them as not-a-real-user-gesture:
    /// `UNUserNotificationCenter.requestAuthorization` and the other TCC/consent prompts stay
    /// unshown under them, though the same button raises the prompt under a foreground click. When
    /// the caller needs the prompt to appear, this forces the one delivery the system honors as
    /// real. It implies hardware input, so it is presence-gated and only reached with the caller's
    /// consent.
    let foreground: Bool

    init(
        allowHardwareInput: Bool = false, accessibilityOnly: Bool = false,
        foreground: Bool = false, clickOptions: ClickOptions = .init()
    ) {
        self.allowHardwareInput = allowHardwareInput || foreground
        self.accessibilityOnly = accessibilityOnly
        self.foreground = foreground && !accessibilityOnly
        self.clickOptions = clickOptions
    }

    func perform(
        _ action: Action, on element: AXElement, pid: pid_t,
        refetch: () -> AXElement? = { nil }
    ) async -> Evidence {
        var attempts: [Evidence.Attempt] = []

        let cursorBefore = EventPoster.cursorLocation
        let frontBefore = await MainActor.run { EventPoster.frontmostBundleID }
        // Focus is sampled after tentacle 0, not here: while the display sleeps every tree is
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
                tentacle: .accessibility,
                outcome: "Accessibility is not granted — the system discards synthesized input silently",
            ))
            focusBefore = ElementQuery.focused(pid: pid)?.signature
            return await finish(
                action, element, .accessibility, .unverifiable, nil, nil,
                focusBefore, focusBefore, cursorBefore, frontBefore, attempts, pid,
            )
        }

        // Tentacle 0 — without this the tree below is a fiction.
        let wake = await DisplayWake.ensureAwake()
        attempts.append(.init(tentacle: .displayWake, outcome: wake.rawValue))
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

        // A gesture-only target: it exposes no `AXPress`/`AXShowMenu`, so no accessibility
        // tentacle can actuate it and a posted click at its point is swallowed by the enclosing
        // scroll view. Measured on SwiftUI `.onTapGesture` inside a ScrollView. This is the
        // signature that decides the escalation and the suggestion below.
        let liveForActions = element.isValid ? element : (refetch() ?? element)
        let gestureOnly: Bool = {
            if case .setText = action { return false }
            return !accessibilityOnly && liveForActions.pressishAction == nil
        }()

        // A referral is a signpost, not an adapter: web page content is the one surface OS input
        // cannot reach at all, and the channel that can (refrax-ctl, CDP, Safari's own scripting)
        // belongs to the calling agent, which holds the task context and the launch flags.
        var referral: Evidence.Referral?

        // The foreground path skips every ghost tentacle: `AXPress` and a posted click both
        // actuate the control without a real gesture, and the whole reason the caller asked for
        // foreground is that those do not raise the system prompt this action must surface. Go
        // straight to the sting, which activates the app and clicks with the real cursor.
        if !foreground {
            // Tentacle 1 — accessibility, then read back. A success code proves nothing.
            if let evidence = await tryAccessibility(
                action, element, pid, &attempts,
                cursorBefore, frontBefore, focusBefore, refetch,
            ) {
                return await evidence.addingVisualEvidence(
                    delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch),
                )
            }

            // Menu items stop here: everything below aims at a rectangle that means nothing while
            // the menu is closed. Tentacle 1's own verdict is the answer.
            if accessibilityOnly {
                attempts.append(.init(
                    tentacle: .postedEvent,
                    outcome: "not attempted: this target is only meaningfully actuated through accessibility",
                ))
                return await finish(
                    action, element, .accessibility, .unverifiable, nil, nil,
                    focusBefore, ElementQuery.focused(pid: pid)?.signature,
                    cursorBefore, frontBefore, attempts, pid,
                )
            }

            // Tentacle 2 — posted events, delivered to this process only.
            if let evidence = await tryPostedEvents(
                action, element, pid, &attempts,
                cursorBefore, frontBefore, focusBefore, focusDeltaIsUsable, refetch,
            ) {
                let seen = await evidence.addingVisualEvidence(
                    delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch),
                )
                // A posted click that moved neither focus nor pixels has demonstrably not landed,
                // which is precisely the precondition the sting exists for. Without this the sting
                // was unreachable for clicks: the posted branch returns evidence whenever the
                // element has a frame, so `allowHardwareInput` was accepted and then never acted
                // on. Measured case: SwiftUI `.onTapGesture` targets inside a ScrollView expose a
                // frame, accept the posted event, and do nothing with it.
                //
                // A gesture-only target also escalates on `unverifiable`: without Screen Recording
                // there is no pixel witness, so a swallowed tap reads unverifiable rather than
                // noEffect, and a control that exposes no readable value can never do better. A
                // retried click is at worst a second click, so escalating is safe. Text is excluded
                // on purpose — a retried write lands the payload twice, and `contains` would then
                // confirm the doubled text; the posted branch already declines to retry text.
                let isText: Bool = if case .setText = action { true } else { false }
                let escalate = seen.verdict == .noEffect
                    || (gestureOnly && seen.verdict == .unverifiable)
                guard allowHardwareInput, !isText, escalate else {
                    return gestureOnly ? seen.suggestingHardware() : seen
                }
                attempts.append(.init(
                    tentacle: .postedEvent,
                    outcome: gestureOnly
                        ? "gesture-only target: posted click swallowed by the scroll view — escalating to the sting"
                        : "posted, but neither focus nor pixels moved — escalating to the sting",
                ))
            }

            // Tentacle 3 — the referral signpost.
            referral = WebContent.referral(for: element, pid: pid)
            attempts.append(.init(
                tentacle: .appAutomation,
                outcome: referral.map { "unreachable by OS input — refer to \($0.channel)" }
                    ?? "no adapter for this target",
            ))
        } else {
            attempts.append(.init(
                tentacle: .hardwareInput,
                outcome: "foreground requested — skipping the ghost tentacles so a real activation + hardware click can raise system prompts",
            ))
        }

        // The sting — the cursor-stealing path. Never silent, never implicit.
        guard allowHardwareInput else {
            attempts.append(.init(tentacle: .hardwareInput, outcome: "declined: not permitted by caller"))
            // The one verdict the design calls most important deserves the evidence we already
            // captured: pixels are the only signal left once every tentacle has declined.
            let declined = await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
            // A gesture-only target left with no ghost tentacle to reach it: name the diagnosis
            // and the one path that lands, so the caller retries deliberately rather than reading
            // a bare noEffect as a mystery.
            return gestureOnly ? declined.suggestingHardware() : declined
        }
        // A cancelled request must not go on to take the cursor: by this point the socket has
        // already told the caller the action timed out.
        guard !Task.isCancelled else {
            attempts.append(.init(tentacle: .hardwareInput, outcome: "refused: the request was cancelled before the cursor was taken"))
            return await finish(
                action, element, .postedEvent, .unverifiable, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            )
        }
        // The lock screen owns the console while locked: a hardware keystroke would land in
        // the password field. Ghost tentacles are safe there — this one is categorically not.
        guard !UserPresence.read().lockBlocksHardware else {
            attempts.append(.init(
                tentacle: .hardwareInput,
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
            attempts.append(.init(tentacle: .hardwareInput, outcome: "element has no frame to aim the real cursor at"))
            // Tagged with the last tentacle that actually posted anything: nothing was delivered
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
            let (occluder, targetName) = await MainActor.run {
                (
                    NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)",
                    NSRunningApplication(processIdentifier: pid)?.localizedName,
                )
            }
            attempts.append(.init(
                tentacle: .hardwareInput,
                outcome: "refused: '\(occluder)' covers the target at (\(Int(aim.x)), \(Int(aim.y))) — a real click there would hit it, not us",
            ))
            var evidence = await finish(
                action, element, .postedEvent, .noEffect, nil, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
            // A suggestion, never an auto-park: moving a visible window off-screen as a side
            // effect of a failed click is the caller's decision — often the occluder is the
            // thing to handle, and only the agent has that context.
            evidence.suggestion = "park --app \(targetName ?? "pid \(pid)")"
            return evidence
        }

        switch action {
        case let .setText(text):
            // The charge-up ring: when the overlay is visible this waits out the wind-up,
            // which is the deliberate window in which ⌃⌥⇧⎋ can land before the click does.
            await PresenceRelay.telegraph(aim)
            guard !EmergencyStop.isHalted else {
                attempts.append(.init(
                    tentacle: .hardwareInput,
                    outcome: "halted by the human (⌃⌥⇧⎋) during the charge-up — the click was never delivered",
                ))
                return await finish(
                    action, element, .postedEvent, .unverifiable, nil, nil,
                    focusBefore, ElementQuery.focused(pid: pid)?.signature,
                    cursorBefore, frontBefore, attempts, pid, referral: referral,
                )
            }
            await HardwareInput.click(at: aim)
            PresenceRelay.impact(aim)
            try? await Task.sleep(for: .milliseconds(200))
            // Look before typing. The occlusion check ran *before* the click, and the click
            // itself takes ~110 ms — long enough for an app finishing launch, a ⌘-Tab, or a
            // modal from elsewhere to take the console. Unlike tentacle 2's `postToPid`, these
            // keystrokes go wherever the system's focus now is, so a payload with `submit`
            // could be a line run in a terminal or a message sent in an unrelated app.
            let targetBundle = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            let frontNow = await MainActor.run { EventPoster.frontmostBundleID }
            guard frontNow == targetBundle else {
                attempts.append(.init(
                    tentacle: .hardwareInput,
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
                // The console was revoked partway through — a lock, a cancel, or ⌃⌥⇧⎋. Say how
                // far it got rather than letting a partial write be judged as if the whole
                // payload had been attempted.
                let cause = EmergencyStop.isHalted ? "the human halted it (⌃⌥⇧⎋)" : "the screen locked mid-run"
                attempts.append(.init(
                    tentacle: .hardwareInput,
                    outcome: "typing stopped after \(delivered.count) of \(text.count) characters — \(cause)",
                ))
            }
            try? await Task.sleep(for: .milliseconds(400))
            // Same read-back discipline as tentacle 2: only the aimed-at element counts, and a
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
                tentacle: .hardwareInput,
                outcome: arrived ? "confirmed by read-back" : (landed == nil ? "typed; target exposes no value to read back" : "typed, did not land in target"),
            ))
            return await finish(
                action, element, .hardwareInput, verdict, landed, nil,
                focusBefore, focused?.signature,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))

        case .click, .press:
            await PresenceRelay.telegraph(aim)
            guard !EmergencyStop.isHalted else {
                attempts.append(.init(
                    tentacle: .hardwareInput,
                    outcome: "halted by the human (⌃⌥⇧⎋) during the charge-up — the click was never delivered",
                ))
                return await finish(
                    action, element, .postedEvent, .unverifiable, nil, nil,
                    focusBefore, ElementQuery.focused(pid: pid)?.signature,
                    cursorBefore, frontBefore, attempts, pid, referral: referral,
                )
            }
            let hwClick: GhostReach.ClickOptions = if case .click = action { clickOptions } else { .init() }
            await HardwareInput.click(
                at: aim, button: hwClick.button == .right ? .right : .left,
                count: hwClick.count, modifiers: hwClick.modifiers,
            )
            PresenceRelay.impact(aim)
            try? await Task.sleep(for: .milliseconds(300))
            let focusAfter = ElementQuery.focused(pid: pid)?.signature
            let verdict: Evidence.Verdict = (focusDeltaIsUsable && focusAfter != focusBefore)
                ? .confirmed : .unverifiable
            attempts.append(.init(tentacle: .hardwareInput, outcome: "clicked with the real cursor"))
            return await finish(
                action, element, .hardwareInput, verdict, nil, nil,
                focusBefore, focusAfter,
                cursorBefore, frontBefore, attempts, pid, referral: referral,
            ).addingVisualEvidence(delta: pixelDelta(from: baseline, at: baselineRect, of: element, refetch))
        }
    }

    // MARK: - Tentacles

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
                attempts.append(.init(tentacle: .accessibility, outcome: "setValue failed (\(code.rawValue))"))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
            // A write can kill its own handle — Electron rebuilds elements on focus — and a
            // dead handle answers nil, which reads as "the field is untouched" and turns a
            // landed write into a false no-effect. Re-resolve only when provably dead.
            var readbackSource = element
            if !element.isValid, let replacement = refetch() {
                attempts.append(.init(
                    tentacle: .accessibility,
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
                // for innocent reasons: AppKit’s smart quotes turn "don’t" into "don’t", and
                // `"don’t".contains("don’t")` is false. Only continue if the field is provably
                // untouched; otherwise report what is actually there.
                if readback != before {
                    attempts.append(.init(
                        tentacle: .accessibility,
                        outcome: "value changed but does not match what was written — not retrying, to avoid duplicating it",
                    ))
                    return await finish(
                        action, element, .accessibility, .noEffect, readback, nil,
                        focusBefore, ElementQuery.focused(pid: pid)?.signature,
                        cursorBefore, frontBefore, attempts, pid,
                    )
                }
                attempts.append(.init(tentacle: .accessibility, outcome: "reported success, read-back unchanged"))
                return nil
            }

            // SwiftUI’s `.searchable` binds through its own observation channel,
            // not NSTextField.delegate — AX setValue writes the backing store and
            // the readback confirms, but the binding never fires and the search
            // stays unfiltered. Undo the write so keystrokes don’t double it.
            if element.role == "AXSearchField" || element.subrole == "AXSearchField" {
                _ = element.setValue(before ?? "")
                attempts.append(.init(
                    tentacle: .accessibility,
                    outcome: "read-back confirms, but search field bindings ignore AX setValue — undone, falling through to keystrokes",
                ))
                return nil
            }

            attempts.append(.init(tentacle: .accessibility, outcome: "confirmed by read-back"))
            return await finish(
                action, element, .accessibility, .confirmed, readback, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )

        case .click, .press:
            // A non-plain click — right button, double, or modified — has no accessibility
            // equivalent (`AXPress` is a plain activation), so it falls straight through to a
            // posted event carrying the button, count, and flags. The exception is a
            // right-click on an element that exposes `AXShowMenu`: that opens the context menu
            // cursor-free, which is exactly what the right-click wanted.
            if case .click = action, !clickOptions.isPlainLeftClick {
                if clickOptions.button == .right, let showMenu = element.showMenuAction {
                    let code = element.perform(showMenu)
                    guard code == .success else {
                        attempts.append(.init(tentacle: .accessibility, outcome: "\(showMenu) failed (\(code.rawValue))"))
                        return nil
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    attempts.append(.init(tentacle: .accessibility, outcome: "show-menu action accepted — a context menu appearing is the consequence to watch for"))
                    return await finish(
                        action, element, .accessibility, .unverifiable, nil, nil,
                        focusBefore, ElementQuery.focused(pid: pid)?.signature,
                        cursorBefore, frontBefore, attempts, pid,
                    )
                }
                attempts.append(.init(tentacle: .accessibility, outcome: "no accessibility equivalent for a \(clickOptions.button.rawValue)/×\(clickOptions.count) click — falling through to a posted event"))
                return nil
            }
            // `AXShowMenu` counts as a press: menu buttons (and the remote elements System
            // Settings panes host) expose only it, and a human clicks them like any button.
            guard let pressish = element.pressishAction else {
                attempts.append(.init(tentacle: .accessibility, outcome: "element exposes no press or show-menu action"))
                return nil
            }
            let code = element.perform(pressish)
            guard code == .success else {
                attempts.append(.init(tentacle: .accessibility, outcome: "\(pressish) failed (\(code.rawValue))"))
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
            // A press has no read-back; the honest verdict is unverifiable until the pixel
            // diff runs, which the caller supplies for visual targets.
            attempts.append(.init(
                tentacle: .accessibility,
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
                // the sting retype the whole payload on top of a write that may have succeeded,
                // and `contains` would then confirm the *doubled* text. Tentacle 1 already
                // refuses to retry for exactly this reason; tentacle 2 must too.
                guard landed != nil else {
                    attempts.append(.init(
                        tentacle: .postedEvent,
                        outcome: "posted; the target exposes no readable value, so this cannot be confirmed or refuted — not retrying, to avoid typing it twice",
                    ))
                    return await finish(
                        action, element, .postedEvent, .unverifiable, nil, nil,
                        focusBefore, focused?.signature,
                        cursorBefore, frontBefore, attempts, pid,
                    )
                }
                attempts.append(.init(
                    tentacle: .postedEvent,
                    outcome: elsewhere
                        ? "posted, but the text landed in \(focused?.role ?? "?") '\(focused?.label ?? "")' instead"
                        : "posted, did not land in target",
                ))
                return nil
            }
            attempts.append(.init(tentacle: .postedEvent, outcome: "confirmed by read-back"))
            return await finish(
                action, element, .postedEvent, .confirmed, landed, nil,
                focusBefore, ElementQuery.focused(pid: pid)?.signature,
                cursorBefore, frontBefore, attempts, pid,
            )

        case .click, .press:
            // Zero-area counts as no frame — see the note on the hardware tentacle; a closed menu
            // item reports a 0×0 rect at the screen corner rather than nothing at all.
            guard let frame = element.frame, frame.width >= 1, frame.height >= 1 else {
                attempts.append(.init(tentacle: .postedEvent, outcome: "element has no usable frame to click"))
                return nil
            }
            let click: GhostReach.ClickOptions = if case .click = action { clickOptions } else { .init() }
            await EventPoster.click(
                at: CGPoint(x: frame.midX, y: frame.midY), pid: pid,
                button: click.button == .right ? .right : .left,
                count: click.count, modifiers: click.modifiers,
            )
            try? await Task.sleep(for: .milliseconds(300))
            let focusAfter = ElementQuery.focused(pid: pid)?.signature
            // A focus change is weak but real evidence that the click was received — unless a
            // display wake intervened, which changes every signature by itself.
            let verdict: Evidence.Verdict = (focusDeltaIsUsable && focusAfter != focusBefore)
                ? .confirmed : .unverifiable
            attempts.append(.init(tentacle: .postedEvent, outcome: "click posted"))
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
        _ action: Action, _ element: AXElement, _ tentacle: Evidence.Tentacle,
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
            tentacle: tentacle,
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
