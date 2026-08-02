import Foundation

/// Separates input we synthesized from input a human actually produced.
///
/// **Measured bug this exists to fix.** `HIDIdleTime` is reset by our own posted events: with
/// the machine untouched for 63 seconds, a single `postToPid` keystroke dropped the reading to
/// 658 ms. Left uncorrected, the engine types, then observes "someone is at the keyboard,"
/// reports `present` to the agent, and keeps doing so for as long as it keeps working —
/// manufacturing the very evidence it uses to decide how careful to be. An agent working alone
/// overnight would believe a human was present the entire time.
///
/// The correction: remember when we last injected input. If the system's last-input moment
/// coincides with ours, that activity was ours, and the estimate of when a *human* last
/// touched the machine is left unchanged.
/// `nonisolated` and lock-guarded rather than an actor: it is consulted from the synthesis
/// paths and from presence reads, neither of which can afford to suspend for it.
nonisolated final class InputAttribution: @unchecked Sendable {
    static let shared = InputAttribution()

    private enum Constants {
        /// How close the system's last-input moment must be to our injection to call it ours.
        /// Kept tight: over-attributing would hide a real person, which is the dangerous
        /// direction. A human typing within this window of us is simply credited to us for one
        /// reading, and the next reading corrects it.
        static let attributionWindow: TimeInterval = 1.5
    }

    private let lock = NSLock()
    private var lastSyntheticInput: Date?
    /// Best estimate of when a human last touched the machine.
    private var lastHumanInput = Date()

    private init() {}

    /// Called by every path that synthesizes input.
    func noteSyntheticInput() {
        lock.lock()
        defer { lock.unlock() }
        lastSyntheticInput = Date()
    }

    /// Converts a raw `HIDIdleTime` reading into seconds since a *human* last did something.
    ///
    /// Returns the raw value unchanged when no synthetic input could account for it, so the
    /// common case — nobody automating anything — is unaffected.
    func humanIdleSeconds(rawIdle: TimeInterval) -> TimeInterval {
        guard rawIdle >= 0 else { return rawIdle }
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let lastInputMoment = now.addingTimeInterval(-rawIdle)

        if let lastSyntheticInput,
           abs(lastInputMoment.timeIntervalSince(lastSyntheticInput)) < Constants.attributionWindow
        {
            // That was us. The human's last real input is still whenever it was.
            return now.timeIntervalSince(lastHumanInput)
        }

        // Genuinely someone else — trust it, and remember it.
        lastHumanInput = lastInputMoment
        return rawIdle
    }
}
