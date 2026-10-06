import Carbon.HIToolbox
import CoreGraphics

/// Which physical key types a character on the current keyboard layout.
///
/// The hardware tentacle stamps each keystroke with the real virtual keycode as well as the
/// unicode payload. Chromium reads the payload; games and Wine read the keycode and ignore
/// the payload — a keycode-0 event reads as the A key to them, whatever string it carries.
/// The map is built by asking the layout what every key produces, so it follows AZERTY,
/// Dvorak, or whatever is selected rather than assuming US ANSI.
nonisolated enum KeyLayout {
    struct Stroke: Equatable, Sendable {
        let keyCode: CGKeyCode
        let shift: Bool
    }

    /// The stroke for one character; a line feed is typed with Return, which layouts report
    /// as a carriage return.
    static func stroke(for character: String, in map: [String: Stroke]) -> Stroke? {
        map[character == "\n" ? "\r" : character]
    }

    /// Character → stroke for the current layout, preferring unshifted keys and lower keycodes
    /// (the main block before the keypad). Empty when the layout exposes no Unicode table,
    /// which leaves callers on their keycode-0 fallback.
    ///
    /// Text Input Sources asserts the main thread on current macOS — call through
    /// `MainActor.run`.
    @MainActor
    static func currentMap() -> [String: Stroke] {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var map: [String: Stroke] = [:]
            for shift in [false, true] {
                let modifiers = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for code in 0 ..< 128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState, characters.count, &length, &characters,
                    )
                    guard status == noErr, length > 0 else { continue }
                    let character = String(utf16CodeUnits: characters, count: length)
                    if map[character] == nil {
                        map[character] = Stroke(keyCode: CGKeyCode(code), shift: shift)
                    }
                }
            }
            return map
        }
    }
}
