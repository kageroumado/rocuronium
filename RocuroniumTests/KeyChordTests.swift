import CoreGraphics
import Testing
@testable import Rocuronium

/// Shortcut and key-chord parsing, and menu key-equivalent matching, on raw values. The item
/// encodings below are what `AXMenuItemCmdChar`/`CmdModifiers`/`CmdVirtualKey` report on real
/// apps (Safari, Preview, Ghostty, Finder), read 2026-10-06.
struct KeyChordTests {
    private func rank(_ keys: String, char: String?, mods: Int, vk: Int? = nil) -> Int? {
        MenuQuery.Shortcut.parse(keys)?.rank(itemCharacter: char, itemModifiers: mods, itemVirtualKey: vk)
    }

    @Test func plainLettersMatchExactly() {
        #expect(rank("cmd+a", char: "A", mods: 0) == 0)
        #expect(rank("cmd+a", char: "a", mods: 0) == 0)
        #expect(rank("cmd+shift+z", char: "Z", mods: 1) == 0)
        #expect(rank("cmd+a", char: "A", mods: 1) == nil)
    }

    /// Ghostty's View ▸ Increase Font Size is `+` with modifiers 0; the keystroke is ⌘=.
    @Test func equalsFindsAnItemStoredAsPlus() {
        #expect(rank("cmd+=", char: "+", mods: 0) != nil)
        #expect(rank("cmd++", char: "+", mods: 0) == 0)
        #expect(rank("cmd+plus", char: "+", mods: 0) == 0)
        #expect(rank("cmd+shift+=", char: "+", mods: 0) != nil)
        #expect(rank("cmd+-", char: "-", mods: 0) == 0)
        #expect(rank("cmd+minus", char: "-", mods: 0) == 0)
        #expect(rank("cmd+comma", char: ",", mods: 0) == 0)
    }

    @Test func plusFindsAnItemStoredAsShiftedEquals() {
        #expect(rank("cmd++", char: "=", mods: 1) != nil)
        #expect(rank("cmd++", char: "=", mods: 0) == nil)
    }

    @Test func exactSpellingOutranksTheLooseEncoding() throws {
        let exact = try #require(rank("cmd+=", char: "=", mods: 0))
        let loose = try #require(rank("cmd+=", char: "+", mods: 0))
        #expect(exact < loose)
    }

    /// Ghostty's Equalize Splits is ⌃⌘= — the modifiers still have to agree.
    @Test func modifiersStillDecide() {
        #expect(rank("cmd+=", char: "=", mods: 4) == nil)
        #expect(rank("ctrl+cmd+=", char: "=", mods: 4) == 0)
        #expect(rank("cmd+[", char: "{", mods: 0) != nil)
        #expect(rank("cmd+shift+[", char: "{", mods: 0) != nil)
    }

    @Test func namedKeysMatchByKeycodeOrFunctionCharacter() {
        #expect(rank("cmd+up", char: "\u{F700}", mods: 0, vk: 126) == 0)
        #expect(rank("cmd+up", char: "\u{F700}", mods: 0) == 1)
        #expect(rank("opt+cmd+escape", char: "⎋", mods: 2, vk: 53) == 0)
        #expect(rank("cmd+up", char: nil, mods: 0, vk: 125) == nil)
    }

    @Test func parseRejectsJunk() {
        #expect(MenuQuery.Shortcut.parse("hyper+a") == nil)
        #expect(MenuQuery.Shortcut.parse("cmd+") == nil)
        #expect(MenuQuery.Shortcut.parse("cmd+ab") == nil)
        #expect(MenuQuery.Shortcut.parse("+")?.character == "+")
    }

    // MARK: - key chords

    @Test func namedChordsKeepTheirKeycodes() throws {
        let escape = try #require(EventPoster.KeyChord.parse("escape"))
        #expect(escape.keyCode == 0x35 && escape.flags.isEmpty && escape.character == nil)
        let backTab = try #require(EventPoster.KeyChord.parse("shift+tab"))
        #expect(backTab.keyCode == 0x30 && backTab.flags == .maskShift)
        #expect(EventPoster.KeyChord.parse("f5")?.keyCode == 0x60)
    }

    @Test func printableChordsMapThroughTheLayout() throws {
        let zoom = try #require(EventPoster.KeyChord.parse("cmd+=", layout: .ansi))
        #expect(zoom.keyCode == 0x18 && zoom.flags == .maskCommand && zoom.character == "=")
        #expect(zoom.name == "cmd+=")
        let plus = try #require(EventPoster.KeyChord.parse("cmd++", layout: .ansi))
        #expect(plus.keyCode == 0x18 && plus.flags == [.maskCommand, .maskShift] && plus.character == "+")
        #expect(EventPoster.KeyChord.parse("cmd+plus", layout: .ansi)?.character == "+")
        let bare = try #require(EventPoster.KeyChord.parse("r", layout: .ansi))
        #expect(bare.keyCode == 0x0F && bare.flags.isEmpty)
        #expect(EventPoster.KeyChord.parse("cmd+é", layout: .ansi) == nil)
    }

    /// AZERTY puts "a" where ANSI has "q" — the keycode must come from the layout.
    @Test func aCustomLayoutDecidesTheKeycode() {
        let azerty = KeyboardLayout(keys: ["a": .init(keyCode: 0x0C, shift: false)])
        #expect(EventPoster.KeyChord.parse("cmd+a", layout: azerty)?.keyCode == 0x0C)
        #expect(EventPoster.KeyChord.parse("cmd+A", layout: azerty)?.keyCode == 0x0C)
    }

    // MARK: - primary window

    /// The presence overlay is borderless (`AXUnknown`) and sorts first in `AXWindows`; the
    /// demo stage behind it is the window evidence must watch.
    @Test func primaryWindowSkipsABorderlessOverlay() {
        #expect(Engine.primaryWindowIndex([
            ("AXWindow", "AXUnknown"), ("AXWindow", "AXUnknown"), ("AXWindow", "AXStandardWindow"),
        ]) == 2)
        #expect(Engine.primaryWindowIndex([("AXWindow", "AXUnknown"), ("AXWindow", nil)]) == 0)
        #expect(Engine.primaryWindowIndex([("AXGroup", "AXStandardWindow"), ("AXWindow", "AXDialog")]) == 1)
        #expect(Engine.primaryWindowIndex([("AXGroup", nil)]) == nil)
    }
}
