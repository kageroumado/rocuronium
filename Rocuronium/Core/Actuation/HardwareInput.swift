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

    /// Types into the frontmost first responder, like hands on the keyboard. Same unicode
    /// payload as the ghost variant, for the same measured reason: Chromium reads the
    /// string, not the keycode.
    static func type(_ text: String) async {
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: Constants.perCharacterDelay)
        }
    }
}
