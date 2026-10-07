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
        /// Per-event scroll magnitude, in pixels — the size of a vigorous real wheel tick.
        static let scrollChunk = 80.0
        static let scrollChunkDelay: Duration = .milliseconds(8)
        /// AppKit's conversion for line-unit wheel events is roughly ten points per line.
        static let pixelsPerLine = 10.0
    }

    /// Splits text into per-scalar UTF-16 payloads.
    ///
    /// **`UniChar` is `UInt16`, so `UniChar(scalar.value)` traps on anything above U+FFFF** —
    /// every emoji, 𝄞, CJK extension B. Verified by execution: typing "hi👍" killed the
    /// process with SIGTRAP, which would take the control socket and every lease down with
    /// it, and a crashed app never runs its virtual-display teardown. A non-BMP scalar must
    /// be posted as its surrogate *pair* in one event, which is why this returns an array of
    /// code units per scalar rather than a single unit.
    static func utf16Payloads(of text: String) -> [[UniChar]] {
        text.unicodeScalars.map { Array(String($0).utf16) }
    }

    /// Types text into a process by unicode payload.
    ///
    /// The payload matters: **Chromium reads the unicode string, not the keycode.** Events
    /// carrying only a virtual keycode are silently ignored by Electron apps, which is why
    /// `sendKey` cannot be used for editing operations there — see `GhostReach`.
    ///
    /// Returns how much of `text` was actually posted, like `HardwareInput.type`: an event that
    /// fails to construct is skipped, and a run cut short should be reportable rather than
    /// silently assumed complete.
    @discardableResult
    static func type(_ text: String, pid: pid_t) async -> String {
        // Our own events reset HIDIdleTime; record them so presence is not fooled by us.
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .privateState)
        var delivered = ""
        let scalars = Array(text.unicodeScalars)
        for (index, var units) in utf16Payloads(of: text).enumerated() {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.postTagged(toPid: pid)
            up.postTagged(toPid: pid)
            delivered.unicodeScalars.append(scalars[index])
            try? await Task.sleep(for: Constants.perCharacterDelay)
        }
        return delivered
    }

    /// A keystroke for the `key` verb: a named key or a printable character, plus modifier
    /// flags — "escape", "shift+tab", "cmd+=", "cmd+shift+z", or a bare "r" for a game.
    ///
    /// A printable character is posted as its key position on the current layout, with the
    /// character also set as the event's unicode payload. Plain text still belongs to `type`,
    /// and a chord that a menu item carries is better sent with `shortcut` (which presses the
    /// item and therefore works on Chromium); this verb is for the keys neither reaches —
    /// Escape on a file-picker dialog, a terminal's own ⌘= binding, a game's hotkey.
    struct KeyChord {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        /// Canonical "cmd+escape" spelling, for the evidence.
        let name: String
        /// The character a printable key types, carried as the unicode payload. Nil for
        /// named keys.
        var character: String? = nil

        /// Parses "escape", "cmd+down", "shift+tab", "cmd+=", "cmd++", "cmd+plus". Returns nil
        /// for unknown modifiers and for characters the layout has no key for.
        static func parse(_ text: String, layout: KeyboardLayout = .ansi) -> KeyChord? {
            guard let (key, mask) = MenuQuery.Shortcut.tokenize(text) else { return nil }
            var flags: CGEventFlags = []
            if mask & 8 == 0 { flags.insert(.maskCommand) }
            if mask & 1 != 0 { flags.insert(.maskShift) }
            if mask & 2 != 0 { flags.insert(.maskAlternate) }
            if mask & 4 != 0 { flags.insert(.maskControl) }
            func spelled(_ flags: CGEventFlags, _ key: String) -> String {
                let names: [(CGEventFlags, String)] = [
                    (.maskControl, "ctrl"), (.maskAlternate, "opt"), (.maskShift, "shift"), (.maskCommand, "cmd"),
                ]
                return (names.filter { flags.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
            }
            if let keyCode = MenuQuery.Shortcut.namedKeys[key] {
                return KeyChord(keyCode: CGKeyCode(keyCode), flags: flags, name: spelled(flags, key))
            }
            let text = MenuQuery.Shortcut.characterNames[key] ?? key
            guard text.count == 1, let character = text.first, let physical = layout.key(for: character) else {
                return nil
            }
            // "+" is shift-"=": the shift the character needs is part of the chord.
            if physical.shift { flags.insert(.maskShift) }
            return KeyChord(keyCode: physical.keyCode, flags: flags, name: spelled(flags, text), character: text)
        }
    }

    /// Sends a keycode with optional modifiers, and the typed character as the unicode
    /// payload when the key is a printable one.
    ///
    /// Works for AppKit targets. **Does not work for Electron** — measured: Backspace and
    /// Cmd+A posted to Discord had no effect whatsoever while unicode text worked.
    static func sendKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags = [], character: String? = nil, pid: pid_t) async {
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        if var units = character.map({ Array($0.utf16) }), !units.isEmpty {
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        down.flags = modifiers
        up.flags = modifiers
        down.postTagged(toPid: pid)
        try? await Task.sleep(for: Constants.clickHoldDuration)
        up.postTagged(toPid: pid)
    }

    /// Clicks a screen point inside one process. The pointer is not moved: the coordinate
    /// rides on the event itself.
    static func click(
        at point: CGPoint, pid: pid_t,
        button: CGMouseButton = .left, count: Int = 1, modifiers: CGEventFlags = []
    ) async {
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .privateState)
        let (downType, upType): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)
        // Each click in a multi-click carries an increasing clickState (1, then 2) so the app
        // recognizes a double-click rather than two unrelated clicks. Capped so a stray large
        // count cannot hold the button through a long burst.
        for clickState in 1 ... min(max(count, 1), 3) {
            guard let down = CGEvent(
                mouseEventSource: source, mouseType: downType,
                mouseCursorPosition: point, mouseButton: button,
            ),
                let up = CGEvent(
                    mouseEventSource: source, mouseType: upType,
                    mouseCursorPosition: point, mouseButton: button,
                )
            else { return }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            if !modifiers.isEmpty { down.flags = modifiers; up.flags = modifiers }
            down.postTagged(toPid: pid)
            try? await Task.sleep(for: Constants.clickHoldDuration)
            up.postTagged(toPid: pid)
        }
    }

    /// Posts scroll-wheel events to a process, aimed at a screen point.
    ///
    /// Positive `deltaY` reveals content further down (the direction a human rolling the
    /// wheel toward themselves gets); the CGEvent axis is inverted relative to that, which is
    /// why the negation lives here and nowhere else. Deltas are chunked into wheel-sized
    /// events because a single huge event is exactly the shape real input never has, and
    /// toolkits are entitled to clamp or ignore it.
    static func scroll(deltaX: Double, deltaY: Double, at point: CGPoint, pid: pid_t) async {
        InputAttribution.shared.noteSyntheticInput()
        let source = CGEventSource(stateID: .privateState)
        func step(_ remaining: Double) -> Double {
            min(abs(remaining), Constants.scrollChunk) * (remaining < 0 ? -1 : 1)
        }
        var remainingX = deltaX
        var remainingY = deltaY
        while abs(remainingX) >= 1 || abs(remainingY) >= 1 {
            let stepX = step(remainingX)
            let stepY = step(remainingY)
            remainingX -= stepX
            remainingY -= stepY
            // Line units, not pixel: pixel-unit (continuous/trackpad-style) events posted to
            // a pid were ignored by every toolkit measured (Notes, Mail, Discord — still
            // windows, zero pixel delta). The discrete line-unit wheel is the classic mouse
            // path and is what gets a hearing, if anything does.
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                wheel1: Int32((-stepY / Constants.pixelsPerLine).rounded()),
                wheel2: Int32((-stepX / Constants.pixelsPerLine).rounded()),
                wheel3: 0,
            ) else { return }
            // Scroll events land on whatever is under the event's own location — the
            // pointer is not consulted and not moved.
            event.location = point
            event.postTagged(toPid: pid)
            try? await Task.sleep(for: Constants.scrollChunkDelay)
        }
    }

    // MARK: - Observable state, for proving the cursor was left alone

    static var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    @MainActor
    static var frontmostBundleID: String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    }
}
