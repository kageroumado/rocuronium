import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Rung 0 of the ghost ladder, and the precondition nobody documents.
///
/// **When the display sleeps, every app's accessibility tree collapses.** `AXWindows` and
/// `AXChildren` start returning the application element itself, all window content disappears,
/// and only the menu bar survives. Safari drops from five reachable text fields to one. An
/// agent that skips this step is blind and does not know it — it concludes that apps have no
/// UI and reports confident nonsense.
///
/// Screen *lock* is harmless: with the display awake and the session locked, full trees are
/// readable. That, not a private API, is why agents can drive a locked Mac.
nonisolated enum DisplayWake {
    private enum Constants {
        /// The display needs a moment after the wake assertion before trees repopulate.
        static let settleAfterWake: Duration = .milliseconds(1200)
    }

    enum Outcome: String, Sendable {
        case alreadyAwake
        case woken
        case failed
    }

    static var displayIsAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Ensures the display is awake, waking it if necessary.
    ///
    /// Note this is *not* what `caffeinate -d` does: that prevents future sleep but will not
    /// wake a display that is already asleep, which makes it useless as a precondition.
    /// Declaring user activity is the operation that actually wakes it.
    @discardableResult
    static func ensureAwake() async -> Outcome {
        guard displayIsAsleep else { return .alreadyAwake }

        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "Rocuronium is driving the interface" as CFString,
            kIOPMUserActiveLocal,
            &assertion,
        )
        guard result == kIOReturnSuccess else { return .failed }

        try? await Task.sleep(for: Constants.settleAfterWake)
        return displayIsAsleep ? .failed : .woken
    }

    /// Whether perception can be trusted right now. Callers should refuse to report "this app
    /// has no such element" while this is false — the correct answer is "I cannot see."
    static var perceptionIsReliable: Bool { !displayIsAsleep }
}
