import CoreGraphics
import Foundation

/// The one rung that takes the real cursor and the real keyboard.
///
/// Events go to `SessionContext.eventTap`, so they behave exactly like a human's input: the
/// pointer moves, the click activates whatever window is under it, keystrokes land in the
/// frontmost app's first responder. That is the entire point (some targets honor nothing less)
/// and the entire cost. It is reachable only when the caller passes `allowHardwareInput`, and
/// its use is always visible in the evidence — this is the moment the user loses their hands,
/// and the design treats it as such.
///
/// The tap is chosen per session rather than fixed at `.cghidEventTap`, because the HID tap
/// posts into the *seat*, not into the caller's session: from an off-console session it drives
/// the console user's cursor. `SessionContext` carries the measurement and the mechanism.
nonisolated enum HardwareInput {
    private enum Constants {
        static let clickHoldDuration: Duration = .milliseconds(30)
        static let perCharacterDelay: Duration = .milliseconds(12)
        static let settleDelay: Duration = .milliseconds(80)
        /// Ordinary application windows. Higher layers are the Dock and menu bar, whose
        /// full-screen backing windows would otherwise look like they cover everything.
        static let normalWindowLayer = 0
        /// Trace pacing waits with (near-)zero tolerance. The system's default timer
        /// tolerance coalesces a ~8 ms frame sleep up to tens of ms, which is exactly the
        /// "cursor moves at 20 fps" complaint — the plan samples at 120 Hz, and only
        /// uncoalesced sleeps deliver it.
        static let traceTolerance: Duration = .milliseconds(1)
        /// Elasticity: cursor movement below this between two of our samples is rounding
        /// noise, not a hand.
        static let humanNoiseFloor = 1.0
        /// Per-posted-frame decay (~120 Hz) of the elastic offset: a nudge is absorbed and
        /// eased back onto the path over roughly half a second.
        static let offsetDecay = 0.94
        /// The grab detector counts *events*, not positions: our own absolute posts
        /// overwrite a hand's displacement within ~9 ms, so position sampling misses all
        /// but a lucky race — but the HID system counts every motion event, ours and the
        /// human's alike (verified 1:1), and the excess over what we posted is the hand.
        /// A decaying excess above this yields; a physical mouse reports at 60–125 Hz, so
        /// this is roughly a quarter-second of sustained deliberate motion, while an
        /// accidental brush's short burst decays away below it.
        static let yieldExcessEvents = 20.0
        /// Per-check (~40 Hz) decay of the excess-event accumulator.
        static let excessDecay = 0.9
    }

    /// Who owns the frontmost ordinary window at `point`.
    ///
    /// This check exists because the hardware rung differs from every other rung in a way
    /// that is easy to miss: `postToPid` delivers to a *process* regardless of stacking, but
    /// a real HID click goes to whatever window is **topmost at that coordinate**. Measured
    /// on this Mac: fifteen windows overlapped a single test point. Clicking an occluded
    /// target would silently click a different app — with the user's own cursor, at a
    /// coordinate the caller believed belonged to its target.
    static func ownerOfWindow(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID,
        ) as? [[String: Any]] else { return nil }
        // The list is front-to-back, so the first hit is the one that would receive the click.
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == Constants.normalWindowLayer,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point)
            else { continue }
            return (window[kCGWindowOwnerPID as String] as? pid_t)
        }
        return nil
    }

    /// Moves the pointer to `point`, clicks, and puts the pointer back where it was.
    ///
    /// The restore is courtesy, not concealment: `Evidence.cursorMovedByUs` reports true for
    /// every hardware-rung action regardless, because the takeover happened even when undone.
    static func click(at point: CGPoint) async {
        // Hardware events reset HIDIdleTime like any human input; record them so presence
        // detection is not fooled by our own hands.
        InputAttribution.shared.noteSyntheticInput()
        let restore = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)

        CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left,
        )?.post(tap: SessionContext.eventTap)
        try? await Task.sleep(for: Constants.settleDelay)
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left,
        )?.post(tap: SessionContext.eventTap)
        try? await Task.sleep(for: Constants.clickHoldDuration)
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left,
        )?.post(tap: SessionContext.eventTap)

        if let restore {
            try? await Task.sleep(for: Constants.settleDelay)
            CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: restore, mouseButton: .left,
            )?.post(tap: SessionContext.eventTap)
        }
    }

    enum MouseButton: String, Sendable {
        case left, right

        var cgButton: CGMouseButton { self == .left ? .left : .right }
        var down: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var up: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
        var dragged: CGEventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
    }

    struct TraceOutcome: Sendable {
        let samplesPosted: Int
        let samplesTotal: Int
        /// Where the system says the cursor actually is now — the read-back, not the plan.
        let cursorEnd: CGPoint
        /// Why the walk stopped early, when it did. A drag aborted mid-run has already
        /// released its button at the last posted point; it is never left held.
        let abortReason: String?
    }

    /// Walks the real cursor along a planned path, optionally with a button held.
    ///
    /// Everything here is a hardware-rung operation by measurement, not by choice: per-pid
    /// posted motion is dropped wholesale by the window server (cursor-paths experiment,
    /// 2026-08-20 — tracking areas, `.onHover`, WebKit hover, content drags and title-bar
    /// drags all stayed silent), so hover and drag exist only with the real pointer.
    ///
    /// Two synthetic-event traps the same experiment measured, both handled here:
    /// - Motion events carry zero `deltaX`/`deltaY` unless stamped, and drag code that reads
    ///   deltas (games, pane splitters) sees no motion while position-based code works.
    /// - Integer delta stamping accumulates rounding across a stream (+33% over 40 steps);
    ///   the fields are written as doubles.
    /// A cancellation signal a raw thread can poll: the walk runs outside Swift concurrency,
    /// where `Task.isCancelled` does not exist.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }

    static func trace(
        _ plan: PathPlan, button: MouseButton?, restoreCursor: Bool,
    ) async -> TraceOutcome {
        InputAttribution.shared.noteSyntheticInput()
        let restore = CGEvent(source: nil)?.location

        // The walk runs on a dedicated `.userInteractive` thread with `mach_wait_until`
        // pacing, not on Swift concurrency timers. Measured (2026-08-23): the async loop —
        // even at raised priority, even with 1 ms tolerance — delivered ~43 of 120 planned
        // samples/s, which reads as ~20 fps cursor motion; a mach-paced thread posts a
        // clean 120/s, saturating the window server's ~60 Hz pointer publication, which is
        // display rate. The thread also makes the pacing independent of whatever else the
        // engine actor is doing.
        let cancelled = CancelFlag()
        let walk = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Walk, Never>) in
                let thread = Thread {
                    continuation.resume(returning: walkSamples(plan: plan, button: button, cancelled: cancelled))
                }
                thread.name = "rocuronium.trace"
                thread.qualityOfService = .userInteractive
                thread.start()
            }
        } onCancel: {
            cancelled.cancel()
        }

        if restoreCursor, let restore {
            try? await Task.sleep(for: Constants.settleDelay)
            InputAttribution.shared.noteSyntheticInput()
            CGEvent(
                mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                mouseCursorPosition: restore, mouseButton: .left,
            )?.post(tap: SessionContext.eventTap)
        }
        // The window server publishes the pointer a frame or two behind a 120 Hz post
        // stream, and the lag varies — an immediate read reported the cursor ~13 pt short
        // of a destination it demonstrably reached (misread as "a human hand may be on the
        // mouse"), and a fixed settle still missed one run in three. Poll until the read
        // agrees with the last posted point; a genuine post-walk human displacement
        // outlasts the poll and still reports honestly.
        var cursorEnd = CGEvent(source: nil)?.location ?? walk.lastPoint
        var settlePolls = 0
        while settlePolls < 8, hypot(cursorEnd.x - walk.lastPoint.x, cursorEnd.y - walk.lastPoint.y) > 2 {
            settlePolls += 1
            try? await Task.sleep(for: .milliseconds(30))
            cursorEnd = CGEvent(source: nil)?.location ?? cursorEnd
        }
        return TraceOutcome(
            samplesPosted: walk.posted,
            samplesTotal: plan.samples.count,
            cursorEnd: cursorEnd,
            abortReason: walk.abort,
        )
    }

    private struct Walk {
        let posted: Int
        let lastPoint: CGPoint
        let abort: String?
    }

    /// The synchronous sample walk: arrive, settle, press, glide, release — mach-paced.
    private static func walkSamples(plan: PathPlan, button: MouseButton?, cancelled: CancelFlag) -> Walk {
        let source = CGEventSource(stateID: .hidSystemState)
        var previous = plan.start

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func absoluteTime(after offset: Duration, of start: UInt64) -> UInt64 {
            let nanoseconds = UInt64(offset.components.seconds) * 1_000_000_000
                + UInt64(offset.components.attoseconds / 1_000_000_000)
            return start + nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer)
        }

        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: (button ?? .left).cgButton,
            ) else { return }
            if type != button?.down, type != button?.up {
                event.setDoubleValueField(.mouseEventDeltaX, value: point.x - previous.x)
                event.setDoubleValueField(.mouseEventDeltaY, value: point.y - previous.y)
            }
            if type == button?.down { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            event.post(tap: SessionContext.eventTap)
            previous = point
        }

        // Arrive, settle, then press — a down on the very first event of a motion stream is
        // a shape real input never has, and the settle gives the window under the point its
        // hover state before the button lands. Thread.sleep is fine here: this thread has
        // nothing else to do, and the durations are choreography, not pacing.
        InputAttribution.shared.noteSyntheticInput()
        post(.mouseMoved, at: plan.start)
        Thread.sleep(forTimeInterval: 0.08)
        if let button {
            post(button.down, at: plan.start)
            Thread.sleep(forTimeInterval: 0.03)
        }

        let moveType = button?.dragged ?? CGEventType.mouseMoved
        func motionEventCount() -> UInt32 {
            CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
                &+ CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDragged)
                &+ CGEventSource.counterForEventType(.hidSystemState, eventType: .rightMouseDragged)
        }
        let begin = mach_absolute_time()
        var posted = 0
        // Elasticity: the hand's displacement, absorbed and eased back onto the path. The
        // ring of recent posts is the lag filter — the window server publishes the pointer
        // asynchronously, so a read can return a position we posted a frame or two ago;
        // matching against recent posts keeps our own latency from reading as a hand.
        var humanOffset = CGPoint.zero
        var recentPosts: [CGPoint] = []
        // The grab detector: motion events beyond the ones we posted are the human's.
        var countedEvents = motionEventCount()
        var postedSinceCount = 0
        var humanEvents = 0.0
        var lockCountdown = 0
        var index = 0
        let count = plan.samples.count
        while index < count {
            // Cheap flags every frame; the screen-lock read (~1 ms of session queries) every
            // ~130 ms — a lock cannot matter faster than that, and per-frame it taxes the rate.
            lockCountdown -= 1
            var revoked = cancelled.isCancelled || EmergencyStop.isHalted
            if !revoked, lockCountdown <= 0 {
                lockCountdown = 16
                // Off-console the lock flag only tracks whether a viewer is attached, and a
                // viewer detaching mid-path is not a human reclaiming anything.
                revoked = UserPresence.screenIsLocked && SessionContext.isOnConsole
            }
            if revoked {
                InputAttribution.shared.noteSyntheticInput()
                if let button { post(button.up, at: previous) }
                let abort = if EmergencyStop.isHalted {
                    "halted by the human (⌥⎋) mid-path"
                } else if cancelled.isCancelled {
                    "the request was cancelled mid-path"
                } else {
                    "the screen locked mid-path"
                }
                return Walk(posted: posted, lastPoint: previous, abort: abort)
            }

            // The hand on the mouse, detected two ways, checked every third frame (~40 Hz).
            //
            // The *grab detector* is event accounting: the HID system counts every motion
            // event, ours and the human's alike, so the excess over what we posted is
            // exactly the hand — position sampling cannot do this job, because our own
            // absolute posts overwrite a displacement within ~9 ms (measured: a 350 pt
            // synthetic "grab" went entirely unseen by position reads). Sustained excess
            // yields the gesture rather than fighting the hand; a brushed mouse's short
            // burst decays away below the threshold.
            //
            // The *elastic bend* stays position-based and cosmetic: when a read does catch
            // the displaced cursor, the path absorbs the offset and eases back. The ring
            // of recent posts filters window-server lag out of that read.
            if posted > 2, posted.isMultiple(of: 3) {
                let events = motionEventCount()
                let excess = Int(events &- countedEvents) - postedSinceCount
                countedEvents = events
                postedSinceCount = 0
                if excess > 0 { humanEvents += Double(excess) }
                if humanEvents > Constants.yieldExcessEvents {
                    InputAttribution.shared.noteSyntheticInput()
                    if let button { post(button.up, at: previous) }
                    return Walk(
                        posted: posted, lastPoint: previous,
                        abort: "the human moved the cursor mid-path — yielded to the hand on the mouse",
                    )
                }
                humanEvents *= Constants.excessDecay

                if let actual = CGEvent(source: nil)?.location {
                    let deviation = recentPosts
                        .map { hypot(actual.x - $0.x, actual.y - $0.y) }
                        .min() ?? 0
                    if deviation > Constants.humanNoiseFloor {
                        let nearest = recentPosts.min {
                            hypot(actual.x - $0.x, actual.y - $0.y) < hypot(actual.x - $1.x, actual.y - $1.y)
                        } ?? previous
                        humanOffset.x += actual.x - nearest.x
                        humanOffset.y += actual.y - nearest.y
                    }
                    humanOffset.x *= Constants.offsetDecay
                    humanOffset.y *= Constants.offsetDecay
                }
            }

            // Taper the elastic offset out over the final stretch, so a nudged glide still
            // lands exactly on the destination the caller was promised.
            let progress = Double(index) / Double(max(count - 1, 1))
            let taper = min(1, (1 - progress) / 0.15)
            let sample = plan.samples[index]
            InputAttribution.shared.noteSyntheticInput()
            post(moveType, at: CGPoint(
                x: sample.point.x + humanOffset.x * taper,
                y: sample.point.y + humanOffset.y * taper,
            ))
            posted += 1
            postedSinceCount += 1
            recentPosts.append(previous)
            if recentPosts.count > 8 { recentPosts.removeFirst() }

            let next = index + 1
            guard next < count else { break }
            // Catch up rather than burst: when behind schedule, skip to the sample due now
            // (never past the final one) instead of machine-gunning stale points.
            let now = mach_absolute_time()
            var target = next
            while target < count - 1, absoluteTime(after: plan.samples[target].offset, of: begin) < now {
                target += 1
            }
            index = target
            mach_wait_until(absoluteTime(after: plan.samples[index].offset, of: begin))
        }

        if let button {
            Thread.sleep(forTimeInterval: 0.03)
            post(button.up, at: plan.end)
        }
        return Walk(posted: posted, lastPoint: previous, abort: nil)
    }

    /// Types into the frontmost first responder, like hands on the keyboard. Same unicode
    /// payload as the ghost variant, for the same measured reason: Chromium reads the
    /// string, not the keycode.
    /// Whether the console is still ours to type into.
    ///
    /// Checked between characters, not only before the first: this rung types at ~12 ms a
    /// character, so a 5,000-character payload holds the physical keyboard for a minute. Two
    /// things can revoke permission mid-run, and both must be observed here because
    /// `try? await Task.sleep` swallows cancellation silently:
    ///
    /// - The user locks the screen (⌃⌘Q, a hot corner, the lid), after which every remaining
    ///   character goes into the login window's password field — the precise harm the
    ///   pre-flight check exists to prevent, arriving a moment after that check passed.
    /// - The socket times out and cancels the request. The caller has by then been told the
    ///   action failed; continuing to drive the physical keyboard afterwards is the one thing
    ///   a tool built on "the evidence matches reality" must never do.
    /// - The human presses ⌥⎋. That is the fastest stop path in the system — the next sample
    ///   or character observes the flag, a held button is released, and the hands are theirs.
    ///
    /// The lock clause applies to the console only. An off-console session reports itself
    /// locked whenever no viewer is attached, which is its ordinary resting state rather than
    /// a human engaging a lock — gating on it there would refuse every keystroke in exactly
    /// the session the engine is meant to drive, and there is no login window to mistype into.
    private static var consoleIsStillOurs: Bool {
        guard !Task.isCancelled, !EmergencyStop.isHalted else { return false }
        return SessionContext.isOffConsole || !UserPresence.read().screenLocked
    }

    /// Presses a key chord on the console pipeline. Key-equivalent dispatch — sheet Escape,
    /// default-button Return — hears these where per-pid posted events do not (those loops
    /// run their own event handling). The cursor is untouched, but the keystroke lands in
    /// the frontmost app's first responder like any human keypress, which is why the router
    /// only reaches this when the target is frontmost and the hardware gates are passed.
    static func pressKey(_ chord: EventPoster.KeyChord) async {
        guard consoleIsStillOurs else { return }
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
        else { return }
        down.flags = chord.flags
        up.flags = chord.flags
        down.post(tap: SessionContext.eventTap)
        try? await Task.sleep(for: Constants.clickHoldDuration)
        up.post(tap: SessionContext.eventTap)
    }

    /// Returns how much of `text` was actually delivered, so a run cut short is reported
    /// rather than assumed complete.
    @discardableResult
    static func type(_ text: String) async -> String {
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .hidSystemState)
        var delivered = ""
        // Per-scalar UTF-16 payloads, not `UniChar(scalar.value)` — that truncating
        // conversion traps on any non-BMP scalar. See `EventPoster.utf16Payloads`.
        let scalars = Array(text.unicodeScalars)
        for (index, var units) in EventPoster.utf16Payloads(of: text).enumerated() {
            guard consoleIsStillOurs else { return delivered }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: SessionContext.eventTap)
            up.post(tap: SessionContext.eventTap)
            delivered.unicodeScalars.append(scalars[index])
            try? await Task.sleep(for: Constants.perCharacterDelay)
        }
        return delivered
    }
}
