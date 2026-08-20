import CoreGraphics
import Foundation

/// The one rung that takes the real cursor and the real keyboard.
///
/// Events go to `.cghidEventTap` — the system-wide console pipeline — so they behave exactly
/// like a human's input: the pointer moves, the click activates whatever window is under it,
/// keystrokes land in the frontmost app's first responder. That is the entire point (some
/// targets honor nothing less) and the entire cost. It is reachable only when the caller
/// passes `allowHardwareInput`, and its use is always visible in the evidence — this is the
/// moment the user loses their hands, and the design treats it as such.
nonisolated enum HardwareInput {
    private enum Constants {
        static let clickHoldDuration: Duration = .milliseconds(30)
        static let perCharacterDelay: Duration = .milliseconds(12)
        static let settleDelay: Duration = .milliseconds(80)
        /// Ordinary application windows. Higher layers are the Dock and menu bar, whose
        /// full-screen backing windows would otherwise look like they cover everything.
        static let normalWindowLayer = 0
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
        )?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: Constants.settleDelay)
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left,
        )?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: Constants.clickHoldDuration)
        CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left,
        )?.post(tap: .cghidEventTap)

        if let restore {
            try? await Task.sleep(for: Constants.settleDelay)
            CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: restore, mouseButton: .left,
            )?.post(tap: .cghidEventTap)
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
    static func trace(
        _ plan: PathPlan, button: MouseButton?, restoreCursor: Bool,
    ) async -> TraceOutcome {
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .hidSystemState)
        let restore = CGEvent(source: nil)?.location
        var previous = plan.start

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
            event.post(tap: .cghidEventTap)
            previous = point
        }

        func finish(posted: Int, abort: String?) async -> TraceOutcome {
            if restoreCursor, let restore {
                try? await Task.sleep(for: Constants.settleDelay)
                post(.mouseMoved, at: restore)
            }
            return TraceOutcome(
                samplesPosted: posted,
                samplesTotal: plan.samples.count,
                cursorEnd: CGEvent(source: nil)?.location ?? previous,
                abortReason: abort,
            )
        }

        // Arrive, settle, then press — a down on the very first event of a motion stream is
        // a shape real input never has, and the settle gives the window under the point its
        // hover state before the button lands.
        post(.mouseMoved, at: plan.start)
        try? await Task.sleep(for: Constants.settleDelay)
        if let button {
            post(button.down, at: plan.start)
            try? await Task.sleep(for: Constants.clickHoldDuration)
        }

        let moveType = button?.dragged ?? CGEventType.mouseMoved
        let clock = ContinuousClock()
        let begin = clock.now
        var posted = 0
        for sample in plan.samples {
            // Same mid-run revocation checks as `type`, for the same two reasons: a lock
            // means the cursor now belongs to the login window, and a cancelled request has
            // already been reported failed. A held button is released where the walk stopped
            // — aborting a drag must never leave the system in "button down" limbo.
            guard consoleIsStillOurs else {
                InputAttribution.shared.noteSyntheticInput()
                if let button { post(button.up, at: previous) }
                return await finish(
                    posted: posted,
                    abort: Task.isCancelled
                        ? "the request was cancelled mid-path"
                        : "the screen locked mid-path",
                )
            }
            InputAttribution.shared.noteSyntheticInput()
            post(moveType, at: sample.point)
            posted += 1
            try? await clock.sleep(until: begin + sample.offset)
        }

        if let button {
            try? await Task.sleep(for: Constants.clickHoldDuration)
            post(button.up, at: plan.end)
        }
        return await finish(posted: posted, abort: nil)
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
    private static var consoleIsStillOurs: Bool {
        !Task.isCancelled && !UserPresence.read().screenLocked
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
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            delivered.unicodeScalars.append(scalars[index])
            try? await Task.sleep(for: Constants.perCharacterDelay)
        }
        return delivered
    }
}
