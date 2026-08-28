import Carbon.HIToolbox
import Foundation

/// The ⌃⌥⇧⎋ emergency stop, as a system-wide hotkey.
///
/// Carbon's `RegisterEventHotKey` rather than a CGEvent tap: a tap needs Input Monitoring
/// and sees every keystroke, which is far more access than one chord justifies — and the
/// hotkey API delivers exactly the chord, works while other apps have focus, and needs no
/// additional permission.
///
/// Registered only while the overlay is visible: the chord means "stop the agent I can see
/// working", and a registered hotkey is consumed system-wide, so holding one around the clock
/// would take it from every other app for a shortcut with nothing to stop.
///
/// Three modifiers, and deliberately no Command. ⌃⌥⇧⎋ — the obvious choice — is Force Quit
/// (⌘⌃⌥⇧⎋) without its Command key, which puts the stop chord directly under the muscle memory
/// of the shortcut people reach for when something misbehaves; it was hit by accident. Any
/// chord containing ⌘ has the mirror problem: a slipped finger opens Force Quit at the exact
/// moment the user wants the agent to stop, not their apps to die.
@MainActor
final class HotkeyMonitor {
    struct Chord {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let displayKeys: [String]

        var displayString: String { displayKeys.joined() }
    }

    static let chord = Chord(
        keyCode: UInt32(kVK_Escape),
        carbonModifiers: UInt32(controlKey | optionKey | shiftKey),
        displayKeys: ["⌃", "⌥", "⇧", "esc"],
    )

    var onHalt: (@MainActor () -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        guard hotKey == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        // The C callback carries no context, so `self` rides in userData. `passUnretained`
        // is safe because `unregister()` removes the handler before this object can die.
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            // Carbon dispatches on the main run loop; assert rather than hop.
            MainActor.assumeIsolated { monitor.onHalt?() }
            return noErr
        }, 1, &eventType, selfPointer, &handler)

        let chord = Self.chord
        let id = EventHotKeyID(signature: OSType(0x524F_4355), id: 1)  // 'ROCU'
        RegisterEventHotKey(
            chord.keyCode, chord.carbonModifiers, id,
            GetEventDispatcherTarget(), 0, &hotKey,
        )
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    isolated deinit {
        unregister()
    }
}
