import AppKit
import CoreGraphics

/// What the human at the machine answered a consent prompt with.
enum ConsentAnswer: Sendable, Equatable {
    case approve
    /// Approve this, and everything else that would ask, for ``StandingApproval/duration``.
    case approveForAWhile
    case decline
}

/// Hold-to-confirm keys for the consent prompt: hold **Y** for yes, **A** for yes to everything
/// for a while, or **N** for no, for one second. A tap cannot cross the threshold, so a stray
/// keystroke — the hazard of a plain shortcut while the human is typing elsewhere — cannot
/// answer for them.
///
/// The keys are taken by a session event tap, which swallows them: a one-second hold
/// auto-repeats, and a listen-only monitor lets every repeat through to whatever is focused
/// (a held Y typed "yyyyyyyy" into the front window). The tap lives only while a prompt is up,
/// and only the three bare keys are taken; a chord with ⌘, ⌃ or ⌥ passes untouched. The
/// Accessibility grant the app already holds is what permits an active tap.
@MainActor
final class ConsentHotkeys {
    /// Reports the held answer and how far toward the one-second threshold (0…1), each tick.
    var onProgress: (@MainActor (_ answer: ConsentAnswer, _ fraction: Double) -> Void)?
    /// Fires once when a key has been held the full second.
    var onResolve: (@MainActor (_ answer: ConsentAnswer) -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var holdAnswer: ConsentAnswer?
    private var ticker: Task<Void, Never>?

    private enum Constants {
        static let holdDuration: TimeInterval = 1.0
        // kVK_ANSI_Y / kVK_ANSI_A / kVK_ANSI_N
        static let yesKey: Int64 = 0x10
        static let yesForAWhileKey: Int64 = 0x00
        static let noKey: Int64 = 0x2D
        static let chordFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: consentTapCallback, userInfo: context,
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        ticker?.cancel()
        ticker = nil
        holdAnswer = nil
    }

    /// The tap's verdict on one event: `true` to swallow it. Runs on the main run loop.
    fileprivate func take(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // The system switches a slow tap off; this one is quick, and comes back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard event.flags.intersection(Constants.chordFlags).isEmpty else { return false }
        let answer: ConsentAnswer? = switch event.getIntegerValueField(.keyboardEventKeycode) {
        case Constants.yesKey: .approve
        case Constants.yesForAWhileKey: .approveForAWhile
        case Constants.noKey: .decline
        default: nil
        }
        guard let answer else { return false }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { beginHold(answer) }
        } else {
            endHold(answer)
        }
        return true
    }

    private func beginHold(_ answer: ConsentAnswer) {
        guard holdAnswer == nil else { return }
        holdAnswer = answer
        let start = Date()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let fraction = min(Date().timeIntervalSince(start) / Constants.holdDuration, 1)
                self?.onProgress?(answer, fraction)
                if fraction >= 1 {
                    self?.onResolve?(answer)
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func endHold(_ answer: ConsentAnswer) {
        guard holdAnswer == answer else { return }
        holdAnswer = nil
        ticker?.cancel()
        ticker = nil
        onProgress?(answer, 0)
    }

    isolated deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }
}

/// The tap's C callback. It is installed on the main run loop, so it runs on the main thread.
private nonisolated func consentTapCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<ConsentHotkeys>.fromOpaque(userInfo).takeUnretainedValue()
    let swallowed = MainActor.assumeIsolated { keys.take(type, event) }
    return swallowed ? nil : Unmanaged.passUnretained(event)
}
