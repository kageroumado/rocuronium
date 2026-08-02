import AppKit
import CoreGraphics

/// Synthetic input delivered to a single process.
///
/// `postToPid` puts events on one app's queue instead of the system-wide console pipeline, so
/// the real cursor never moves and the frontmost app never changes. That is the whole trick
/// behind ghost mode, and it was verified on every call during testing rather than assumed.
nonisolated enum EventPoster {
    private enum Constants {
        static let perCharacterDelay: Duration = .milliseconds(12)
        static let clickHoldDuration: Duration = .milliseconds(30)
    }

    /// Types text into a process by unicode payload.
    ///
    /// The payload matters: **Chromium reads the unicode string, not the keycode.** Events
    /// carrying only a virtual keycode are silently ignored by Electron apps, which is why
    /// `sendKey` cannot be used for editing operations there — see `GhostLadder`.
    static func type(_ text: String, pid: pid_t) async {
        let source = CGEventSource(stateID: .privateState)
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.postToPid(pid)
            up.postToPid(pid)
            try? await Task.sleep(for: Constants.perCharacterDelay)
        }
    }

    /// Sends a keycode with optional modifiers.
    ///
    /// Works for AppKit targets. **Does not work for Electron** — measured: Backspace and
    /// Cmd+A posted to Discord had no effect whatsoever while unicode text worked.
    static func sendKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags = [], pid: pid_t) async {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.postToPid(pid)
        try? await Task.sleep(for: Constants.clickHoldDuration)
        up.postToPid(pid)
    }

    /// Clicks a screen point inside one process. The pointer is not moved: the coordinate
    /// rides on the event itself.
    static func click(at point: CGPoint, pid: pid_t) async {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left,
        ),
            let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left,
            )
        else { return }
        down.postToPid(pid)
        try? await Task.sleep(for: Constants.clickHoldDuration)
        up.postToPid(pid)
    }

    // MARK: - Observable state, for proving the cursor was left alone

    static var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    @MainActor
    static var frontmostBundleID: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    }
}
