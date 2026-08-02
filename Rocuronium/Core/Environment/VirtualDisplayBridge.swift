import AppKit
import Observation

/// `nonisolated` because the module defaults to main-actor isolation, and these are read from
/// default arguments and error descriptions that are not themselves isolated.
private nonisolated enum Constants {
    static let bundleIdentifier = "glass.kagerou.testdisplay"
    static let applicationPath = "/Applications/Test Display.app"
    /// How long to wait for the virtual screen to register after launch.
    static let attachTimeout: Duration = .seconds(6)
    static let pollInterval: Duration = .milliseconds(250)
    /// Backstop: no lease outlives this without renewal.
    static let defaultLeaseDuration: Duration = .seconds(30 * 60)
}

/// Borrows a headless virtual display for the duration of a task, then puts it away.
///
/// A virtual screen is the strongest isolation available: windows parked there are invisible
/// and unreachable on the real display, so an agent can work without occupying any pixels the
/// user is looking at. It is also expensive to leave running, and a stray one is confusing —
/// so it is modeled as a **lease**, not a mode.
///
/// Two rules keep it from becoming a liability:
/// - Ownership: the display is only torn down if this app started it. A display the user
///   started themselves is theirs, and is left exactly as found.
/// - Expiry: a lease has a deadline. A crashed or wedged agent cannot strand a virtual screen,
///   which is the same reasoning behind Adrafinil's hold TTLs.
@MainActor
@Observable
final class VirtualDisplayBridge {
    struct Lease: Identifiable, Sendable {
        let id: UUID
        let reason: String
        let expiresAt: ContinuousClock.Instant
    }

    private(set) var isInstalled = false
    private(set) var activeLease: Lease?
    /// Whether *we* launched the display. Determines whether we are allowed to close it.
    private var startedByUs = false
    private var expiryTask: Task<Void, Never>?

    var isRunning: Bool { runningApplication != nil }

    init() {
        isInstalled = FileManager.default.fileExists(atPath: Constants.applicationPath)
    }

    private var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Constants.bundleIdentifier).first
    }

    /// The screen the virtual display registered as, if it is attached.
    ///
    /// Matched by name rather than by "the one that is not main": with a real external monitor
    /// attached, the naive test picks the user's second display and parks agent windows on a
    /// screen they are looking at — the exact opposite of the intent.
    var virtualScreen: NSScreen? {
        guard isRunning else { return nil }
        return NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("Test Display") }
    }

    // MARK: - Lease lifecycle

    /// Ensures a virtual display exists and returns a lease for it.
    ///
    /// Idempotent: an existing lease is extended rather than duplicated, so concurrent tasks
    /// share one display instead of fighting over it.
    @discardableResult
    func acquire(
        reason: String,
        duration: Duration = Constants.defaultLeaseDuration
    ) async throws -> Lease {
        guard isInstalled else { throw BridgeError.notInstalled }

        if activeLease != nil {
            return renew(reason: reason, duration: duration)
        }

        if runningApplication == nil {
            // Claim ownership *before* awaiting attachment: launch() can throw after the app
            // has already started (attach timeout), and a throw between start and this line
            // would strand a virtual display nobody believes they own.
            startedByUs = true
            do {
                try await launch()
            } catch {
                release()
                throw error
            }
        }

        guard virtualScreen != nil else { throw BridgeError.displayNeverAttached }

        let lease = Lease(
            id: UUID(),
            reason: reason,
            expiresAt: ContinuousClock().now.advanced(by: duration),
        )
        activeLease = lease
        scheduleExpiry(after: duration)
        return lease
    }

    /// Releases the lease and tears the display down if we own it.
    func release(_ lease: Lease? = nil) {
        if let lease, lease.id != activeLease?.id { return }
        expiryTask?.cancel()
        expiryTask = nil
        activeLease = nil

        // Never close a display the user opened. Theirs is not ours to reclaim.
        guard startedByUs, let application = runningApplication else { return }
        application.terminate()
        startedByUs = false
    }

    private func renew(reason: String, duration: Duration) -> Lease {
        let lease = Lease(
            id: activeLease?.id ?? UUID(),
            reason: reason,
            expiresAt: ContinuousClock().now.advanced(by: duration),
        )
        activeLease = lease
        scheduleExpiry(after: duration)
        return lease
    }

    private func scheduleExpiry(after duration: Duration) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    // MARK: - Launching

    private func launch() async throws {
        let url = URL(fileURLWithPath: Constants.applicationPath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false  // never steal focus to attach a screen
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        // Wait for the screen to actually register: launching is not attaching.
        let deadline = ContinuousClock().now.advanced(by: Constants.attachTimeout)
        while ContinuousClock().now < deadline {
            if virtualScreen != nil { return }
            try? await Task.sleep(for: Constants.pollInterval)
        }
        throw BridgeError.displayNeverAttached
    }

    enum BridgeError: LocalizedError {
        case notInstalled
        case displayNeverAttached

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Test Display is not installed at \(Constants.applicationPath)."
            case .displayNeverAttached:
                "Test Display launched but no virtual screen appeared."
            }
        }
    }
}
