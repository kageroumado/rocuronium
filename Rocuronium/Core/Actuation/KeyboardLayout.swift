import Carbon.HIToolbox
import CoreGraphics

/// Which physical key types a printable character. A keycode names a key position, not a
/// character, so the answer depends on the keyboard layout: on AZERTY "a" is keycode 0x0C,
/// not 0x00. Two callers: `key --keys cmd+=` needs a keycode for "=", and the hardware
/// tentacle stamps each typed character with its real keycode, because games and Wine read the
/// keycode and ignore the unicode payload — keycode 0 reads as the A key to them.
///
/// Control characters never get a key: a real Return, Tab, Escape or Delete submits, moves
/// focus, cancels or erases, and `type` admits a newline only behind `--submit` — so they keep
/// the keycode-0 + unicode-payload path, whose meaning is the toolkit's to interpret.
nonisolated struct KeyboardLayout: Sendable {
    struct Key: Sendable, Equatable {
        let keyCode: CGKeyCode
        /// Whether the character needs shift held on this key ("+" is shift-"=" on ANSI).
        let shift: Bool
    }

    /// Character → key, lowercase letters for letter keys.
    let keys: [Character: Key]

    func key(for character: Character) -> Key? {
        guard Self.isPrintable(character) else { return nil }
        return keys[character] ?? character.lowercased().first.flatMap { keys[$0] }
    }

    /// Every scalar is visible text or a space: no control (Cc), format (Cf), surrogate,
    /// private-use, unassigned, or line/paragraph separator scalars.
    static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned,
                 .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }
    }

    /// The ANSI US layout. The fallback when the current layout cannot be read (an input
    /// method with no `uchr` data, or no window server).
    static let ansi: KeyboardLayout = {
        let rows: [(CGKeyCode, Character, Character)] = [
            (0x00, "a", "A"), (0x0B, "b", "B"), (0x08, "c", "C"), (0x02, "d", "D"), (0x0E, "e", "E"),
            (0x03, "f", "F"), (0x05, "g", "G"), (0x04, "h", "H"), (0x22, "i", "I"), (0x26, "j", "J"),
            (0x28, "k", "K"), (0x25, "l", "L"), (0x2E, "m", "M"), (0x2D, "n", "N"), (0x1F, "o", "O"),
            (0x23, "p", "P"), (0x0C, "q", "Q"), (0x0F, "r", "R"), (0x01, "s", "S"), (0x11, "t", "T"),
            (0x20, "u", "U"), (0x09, "v", "V"), (0x0D, "w", "W"), (0x07, "x", "X"), (0x10, "y", "Y"),
            (0x06, "z", "Z"),
            (0x12, "1", "!"), (0x13, "2", "@"), (0x14, "3", "#"), (0x15, "4", "$"), (0x17, "5", "%"),
            (0x16, "6", "^"), (0x1A, "7", "&"), (0x1C, "8", "*"), (0x19, "9", "("), (0x1D, "0", ")"),
            (0x18, "=", "+"), (0x1B, "-", "_"), (0x21, "[", "{"), (0x1E, "]", "}"), (0x2A, "\\", "|"),
            (0x29, ";", ":"), (0x27, "'", "\""), (0x2B, ",", "<"), (0x2F, ".", ">"), (0x2C, "/", "?"),
            (0x32, "`", "~"),
        ]
        var keys: [Character: Key] = [:]
        for (code, plain, shifted) in rows {
            keys[plain] = Key(keyCode: code, shift: false)
            keys[shifted] = Key(keyCode: code, shift: true)
        }
        return KeyboardLayout(keys: keys)
    }()

    /// The current layout, read through `UCKeyTranslate`; ANSI when it cannot be read.
    /// `asciiCapable` reads the ASCII-capable layout a chord's letters live on; otherwise the
    /// selected layout, the one a human would type text with. Text Input Sources must be
    /// queried on the main thread.
    @MainActor
    static func current(asciiCapable: Bool = true) -> KeyboardLayout {
        let selected = asciiCapable ? nil : TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source = selected ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansi }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        var plain: [Character: Key] = [:]
        var shifted: [Character: Key] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Lowest keycode wins within each table, so the main rows beat the keypad (0x41+),
            // and a plain key beats a shifted one: "1" on AZERTY is shift-&, ";" is plain.
            for shift in [false, true] {
                let modifierState: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for code in 0 ..< 128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, UInt16(code), UInt16(kUCKeyActionDown), modifierState, keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters,
                    )
                    guard status == noErr, length == 1,
                          let scalar = Unicode.Scalar(characters[0]), isPrintable(Character(scalar))
                    else { continue }
                    let key = Key(keyCode: CGKeyCode(code), shift: shift)
                    if shift {
                        shifted[Character(scalar)] = shifted[Character(scalar)] ?? key
                    } else {
                        plain[Character(scalar)] = plain[Character(scalar)] ?? key
                    }
                }
            }
        }
        let keys = shifted.merging(plain) { _, plainKey in plainKey }
        return keys.isEmpty ? ansi : KeyboardLayout(keys: keys)
    }
}
