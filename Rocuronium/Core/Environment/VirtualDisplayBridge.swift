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
    /// Every outstanding lease, not just the latest. Concurrent tasks each hold their own, and
    /// the display is torn down only when the last one goes — previously a second caller was
    /// handed the *same* lease id, so whoever released first killed the display underneath the
    /// other, which is precisely what the refcount in Adrafinil's holds exists to prevent.
    private(set) var leases: [UUID: Lease] = [:]
    /// Whether *we* launched the display. Determines whether we are allowed to close it.
    private var startedByUs = false
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    /// Kept for the menu bar, which only needs to know whether anything is holding it.
    var activeLease: Lease? { leases.values.first }

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

    /// The virtual screen's bounds in the top-left-origin global space that AX frames and
    /// synthetic events use. `NSScreen.frame` is in Cocoa's bottom-left space; going through
    /// the display ID to `CGDisplayBounds` gets the flip right instead of doing it by hand.
    var virtualScreenBounds: CGRect? {
        guard let screen = virtualScreen,
              let number = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else { return nil }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    // MARK: - Lease lifecycle

    /// Ensures a virtual display exists and returns a lease for it.
    ///
    /// Idempotent: an existing lease is extended rather than duplicated, so concurrent tasks
    /// share one display instead of fighting over it.
    /// Takes out a lease, starting the display if nothing is holding one yet.
    ///
    /// Each caller gets its own lease. Sharing is by refcount, not by handing out the same id.
    @discardableResult
    func acquire(
        reason: String,
        duration: Duration = Constants.defaultLeaseDuration
    ) async throws -> Lease {
        guard isInstalled else { throw BridgeError.notInstalled }

        if leases.isEmpty, runningApplication == nil {
            try await launch()
        }
        guard virtualScreen != nil else {
            // Nothing is holding it and it never attached: don't leave a half-started display.
            if leases.isEmpty { teardown() }
            throw BridgeError.displayNeverAttached
        }

        let lease = Lease(
            id: UUID(),
            reason: reason,
            expiresAt: ContinuousClock().now.advanced(by: duration),
        )
        leases[lease.id] = lease
        expiryTasks[lease.id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.release(lease)
        }
        return lease
    }

    /// Release by id, for callers on the far side of the socket who hold a string, not a
    /// `Lease`. Returns whether the id named an outstanding lease.
    @discardableResult
    func release(id: UUID) -> Bool {
        guard let lease = leases[id] else { return false }
        release(lease)
        return true
    }

    /// Gives up one lease. The display goes away only when the last holder lets go.
    func release(_ lease: Lease) {
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        expiryTasks.removeValue(forKey: lease.id)?.cancel()
        guard leases.isEmpty else { return }
        teardown()
    }

    /// Drops every lease. For app termination, where nothing is going to release them.
    func releaseAll() {
        leases.removeAll()
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        teardown()
    }

    private func teardown() {
        // Cleared unconditionally: if the display died on us, leaving this set would make a
        // later release terminate a display the *user* had since started themselves.
        defer { startedByUs = false }
        // Never close a display the user opened. Theirs is not ours to reclaim.
        guard startedByUs, let application = runningApplication else { return }
        application.terminate()
    }

    // MARK: - Launching

    private func launch() async throws {
        let url = URL(fileURLWithPath: Constants.applicationPath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false  // never steal focus to attach a screen
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // Ownership is claimed the moment the app exists, not after it attaches: the wait below
        // can throw, and a throw in between would strand a display nobody believes they own.
        startedByUs = true

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
