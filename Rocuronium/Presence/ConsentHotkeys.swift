import AppKit

/// Hold-to-confirm keys for the consent prompt: hold **Y** for yes or **N** for no, for one
/// second. A tap cannot cross the threshold, so a stray keystroke — the hazard of a plain
/// shortcut while the human is typing elsewhere — cannot answer for them.
///
/// `NSEvent` monitors rather than a Carbon hotkey: the hold needs a dependable key-up to
/// cancel a tap, and the global keyboard monitor (which the Accessibility grant already
/// permits) delivers key-down and key-up cleanly. It is listen-only, so the keys also reach
/// whatever is focused — acceptable, because a deliberate one-second hold is not prose.
@MainActor
final class ConsentHotkeys {
    /// Reports the held answer and how far toward the one-second threshold (0…1), each tick.
    var onProgress: (@MainActor (_ answer: Bool, _ fraction: Double) -> Void)?
    /// Fires once when a key has been held the full second.
    var onResolve: (@MainActor (_ answer: Bool) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdAnswer: Bool?
    private var ticker: Task<Void, Never>?

    private enum Constants {
        static let holdDuration: TimeInterval = 1.0
        // kVK_ANSI_Y / kVK_ANSI_N
        static let yesKey: UInt16 = 0x10
        static let noKey: UInt16 = 0x2D
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        ticker?.cancel()
        ticker = nil
        holdAnswer = nil
    }

    private func handle(_ event: NSEvent) {
        let answer: Bool? = switch event.keyCode {
        case Constants.yesKey: true
        case Constants.noKey: false
        default: nil
        }
        guard let answer else { return }

        if event.type == .keyDown {
            guard !event.isARepeat else { return }
            beginHold(answer)
        } else {
            endHold(answer)
        }
    }

    private func beginHold(_ answer: Bool) {
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

    private func endHold(_ answer: Bool) {
        guard holdAnswer == answer else { return }
        holdAnswer = nil
        ticker?.cancel()
        ticker = nil
        onProgress?(answer, 0)
    }

    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
