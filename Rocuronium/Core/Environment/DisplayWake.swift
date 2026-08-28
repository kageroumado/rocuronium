import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Tentacle 0 of the ghost reach, and the precondition nobody documents.
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

    /// Reused across wakes, per the IOPMLib contract.
    private nonisolated(unsafe) static var userActivityAssertion: IOPMAssertionID = 0

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

        // IOPMLib is explicit that the id returned by the first call must be passed back on
        // every subsequent one; passing 0 each time creates a fresh assertion per wake that is
        // never released.
        let result = IOPMAssertionDeclareUserActivity(
            "Rocuronium is driving the interface" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertion,
        )
        guard result == kIOReturnSuccess else { return .failed }

        try? await Task.sleep(for: Constants.settleAfterWake)
        return displayIsAsleep ? .failed : .woken
    }

    /// Whether perception can be trusted right now. Callers should refuse to report "this app
    /// has no such element" while this is false — the correct answer is "I cannot see."
    static var perceptionIsReliable: Bool { !displayIsAsleep }

    /// Holds the display awake for the lifetime of the object, releasing on deinit.
    ///
    /// Waking once is not enough for a long task: the display can sleep again mid-run and take
    /// every accessibility tree with it. This is the assertion to hold — **not** the system
    /// one. `PreventUserIdleSystemSleep` keeps the machine running while letting the panel
    /// sleep, which is exactly the state that blinds the engine; it is the right choice for a
    /// headless coding agent and the wrong one for anything that looks at the screen.
    ///
    /// An assertion is used rather than spawning `caffeinate`: a child process leaks if we
    /// crash, can be killed independently, and clutters the process list, while an assertion
    /// dies with us.
    final class Hold {
        private var assertion: IOPMAssertionID = 0
        private(set) var isHeld = false

        /// Apple defines these assertion types as `CFSTR(...)` macros, which do not import as
        /// constants, so the raw string is the only way to name them.
        private static let preventDisplaySleep = "PreventUserIdleDisplaySleep" as CFString

        init?(reason: String) {
            let result = IOPMAssertionCreateWithName(
                Self.preventDisplaySleep,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertion,
            )
            guard result == kIOReturnSuccess else { return nil }
            isHeld = true
        }

        func release() {
            guard isHeld else { return }
            IOPMAssertionRelease(assertion)
            isHeld = false
        }

        deinit {
            if isHeld { IOPMAssertionRelease(assertion) }
        }
    }
}
