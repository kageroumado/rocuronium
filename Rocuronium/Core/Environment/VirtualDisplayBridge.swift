import AppKit
import Observation

/// `nonisolated` because the module defaults to main-actor isolation, and these are read from
/// default arguments and error descriptions that are not themselves isolated.
private nonisolated enum Constants {
    /// Backstop: no explicit lease outlives this without renewal.
    static let defaultLeaseDuration: Duration = .seconds(30 * 60)
    /// Auto-leases are shorter: teardown always un-parks first, so expiry is safe, and a
    /// forgotten park should not pin an invisible display for half an hour. Renewed by any
    /// command that touches an app with a parked window.
    static let autoLeaseDuration: Duration = .seconds(10 * 60)
    /// How often the maintenance pass prunes closed windows and recounts strays.
    static let maintenanceInterval: Duration = .seconds(60)
    /// Bounded wait for the willTerminate un-park sweep, so a wedged AX target cannot stall
    /// quit; the startup sweep reaps whatever is left on the next launch.
    static let terminationSweepTimeout: TimeInterval = 2
    /// Where swept windows land when their original frame is unknown or no longer on any
    /// display: inset from the main display's corner, clear of the menu bar.
    static let sweepInset = 40.0
}

/// Owns the headless virtual display for the duration of a task, then puts it away.
///
/// A virtual screen is the strongest isolation available: windows parked there are invisible
/// and unreachable on the real display, so an agent can work without occupying any pixels the
/// user is looking at. It is also expensive to leave running, and a stray one is confusing —
/// so it is modeled as a **lease**, not a mode.
///
/// The display itself is created in process by `VirtualDisplayManager`, which makes the two
/// rules enforceable by construction rather than by protocol:
/// - Ownership: our display dies with the last lease or with this process.
/// - Expiry: a lease has a deadline, so a crashed or wedged agent cannot strand a virtual
///   screen — and teardown always sweeps parked windows home *first*, because tearing the
///   display out from under a window strands it somewhere no one can see or reach
///   (measured on a real Finder window).
@MainActor
@Observable
final class VirtualDisplayBridge {
    struct Lease: Identifiable, Sendable {
        enum Kind: String, Sendable {
            /// Asked for by name; released by whoever asked.
            case explicit
            /// Taken as a side effect of `park`; releases itself when its last parked
            /// window is returned or closes. Traceable through its recorded reason.
            case auto
        }

        let id: UUID
        let reason: String
        let kind: Kind
        let expiresAt: ContinuousClock.Instant
    }

    /// A window a sweep failed to move home: it is still on the invisible display, the exact
    /// harm the lease model exists to prevent, so the release reply must be able to name it.
    struct StrandedWindow: Sendable {
        let pid: pid_t
        let title: String
    }

    /// What a release did, for the reply that reports it.
    struct ReleaseOutcome: Sendable {
        var holdersRemaining: Int
        var sweptParked: Int
        var sweptStrays: Int
        /// Windows a sweep could not move off the virtual display — under-counting these as
        /// merely "not swept" would hide that they are stranded where no one can see them.
        var stranded: [StrandedWindow]
        var tornDown: Bool
    }

    /// Every outstanding lease, not just the latest. Concurrent tasks each hold their own, and
    /// the display is torn down only when the last one goes. Handing two callers the *same*
    /// lease id would let whoever releases first kill the display underneath the other — the
    /// refcount in Adrafinil's holds exists precisely to prevent that.
    private(set) var leases: [UUID: Lease] = [:]
    /// The parked set: which windows are on the virtual display on purpose, and where they
    /// belong. Everything else on that display is a stray.
    private(set) var ledger = ParkLedger()
    /// Strays as of the last count — for the menu bar badge, which cannot afford an AX walk
    /// per redraw. Refreshed by the maintenance pass and after every park/release.
    private(set) var strayCount = 0

    private let manager = VirtualDisplayManager()
    private let engine: Engine
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// Kept for the menu bar, which only needs to know whether anything is holding it.
    var activeLease: Lease? { leases.values.first }

    init(engine: Engine) {
        self.engine = engine
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminationSweep() }
        }
    }

    // MARK: - The display

    var displayID: CGDirectDisplayID? { manager.displayID }
    var isAttached: Bool { displayID != nil }

    /// The virtual screen's bounds in the top-left-origin global space that AX frames and
    /// synthetic events use. `NSScreen.frame` is in Cocoa's bottom-left space; going through
    /// the display ID to `CGDisplayBounds` gets the flip right instead of doing it by hand.
    var virtualScreenBounds: CGRect? {
        displayID.map(CGDisplayBounds)
    }

    /// Every attached display's bounds, in the top-left-origin global space AX frames use.
    var displayBounds: [CGRect] {
        Self.onlineDisplayIDs().map(CGDisplayBounds)
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - Lease lifecycle

    /// Takes out a lease, creating a display if none is in force. Each caller gets its own
    /// lease — sharing is by refcount, not by handing out the same id.
    @discardableResult
    func acquire(
        reason: String,
        duration: Duration? = nil,
        kind: Lease.Kind = .explicit,
    ) throws -> Lease {
        if displayID == nil { try manager.create() }
        guard isAttached else { throw BridgeError.displayNeverAttached }

        let leaseDuration = duration
            ?? (kind == .auto ? Constants.autoLeaseDuration : Constants.defaultLeaseDuration)
        let lease = Lease(
            id: UUID(),
            reason: reason,
            kind: kind,
            expiresAt: ContinuousClock().now.advanced(by: leaseDuration),
        )
        leases[lease.id] = lease
        scheduleExpiry(of: lease, after: leaseDuration)
        startMaintenance()
        return lease
    }

    /// Release by id, for callers on the far side of the socket who hold a string, not a
    /// `Lease`. `nil` when the id names no outstanding lease.
    func release(id: UUID) async -> ReleaseOutcome? {
        guard let lease = leases[id] else { return nil }
        return await release(lease)
    }

    /// Gives up one lease. Its parked windows are swept home first; the display goes away
    /// only when the last holder lets go.
    func release(_ lease: Lease) async -> ReleaseOutcome {
        guard leases.removeValue(forKey: lease.id) != nil else {
            return ReleaseOutcome(holdersRemaining: leases.count, sweptParked: 0, sweptStrays: 0, stranded: [], tornDown: false)
        }
        expiryTasks.removeValue(forKey: lease.id)?.cancel()

        let firstSweep = await sweep(entries: ledger.removeAll(under: lease.id))
        var swept = firstSweep.swept
        var stranded = firstSweep.stranded
        var sweptStrays = 0
        var tornDown = false
        if leases.isEmpty {
            let finalSweep = await sweep(entries: ledger.removeAll())
            swept += finalSweep.swept
            stranded += finalSweep.stranded
            let strayResult = await sweepStrays()
            sweptStrays = strayResult.swept
            stranded += strayResult.stranded
            tornDown = teardown()
        }
        await refreshStrayCount()
        return ReleaseOutcome(
            holdersRemaining: leases.count,
            sweptParked: swept,
            sweptStrays: sweptStrays,
            stranded: stranded,
            tornDown: tornDown,
        )
    }

    /// Drops every lease and sweeps everything home. For deliberate resets, where nothing
    /// else is going to release them.
    func releaseAll() async {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        leases.removeAll()
        _ = await sweep(entries: ledger.removeAll())
        _ = await sweepStrays()
        _ = teardown()
        await refreshStrayCount()
    }

    private func scheduleExpiry(of lease: Lease, after duration: Duration) {
        expiryTasks[lease.id]?.cancel()
        expiryTasks[lease.id] = Task(name: "virtual display lease expiry") { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            _ = await self?.release(lease)
        }
    }

    /// Tears down the display. Returns whether it actually went away.
    private func teardown() -> Bool {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        guard manager.displayID != nil else { return false }
        manager.destroy()
        return true
    }

    // MARK: - The parked set

    /// Records a landed park. When an auto-lease is in force the window counts against it;
    /// explicit-lease parks are recorded for the sweep and the stray check but decrement
    /// nothing. Parking also renews the auto-lease — activity on the display is the signal
    /// it is still wanted.
    func recordPark(pid: pid_t, title: String, before: CGRect?) {
        let autoLease = leases.values.first { $0.kind == .auto }
        ledger.recordPark(.init(pid: pid, title: title), before: before, leaseID: autoLease?.id)
        if let autoLease { renew(autoLease) }
        Task(name: "stray recount after park") { [weak self] in await self?.refreshStrayCount() }
    }

    /// Records an un-park (the window moved off the virtual display, or closed). If that
    /// drained an auto-lease, the lease releases itself; the id of the released lease is
    /// returned so the caller can report it.
    func recordUnpark(pid: pid_t, title: String) async -> UUID? {
        guard let entry = ledger.recordUnpark(.init(pid: pid, title: title)) else { return nil }
        guard let leaseID = entry.leaseID, ledger.leaseIsDrained(leaseID),
              let lease = leases[leaseID], lease.kind == .auto else {
            await refreshStrayCount()
            return nil
        }
        _ = await release(lease)
        return leaseID
    }

    func isParked(pid: pid_t, title: String) -> Bool {
        ledger.contains(.init(pid: pid, title: title))
    }

    /// Pushes an auto-lease's deadline out. Called when a command touches an app that has a
    /// window parked under it — a lease being used is a lease still wanted.
    func renewAutoLease(touching pid: pid_t) {
        let leaseIDs = Set(ledger.entries.filter { $0.window.pid == pid }.compactMap(\.leaseID))
        for id in leaseIDs {
            guard let lease = leases[id], lease.kind == .auto else { continue }
            renew(lease)
        }
    }

    private func renew(_ lease: Lease) {
        let renewed = Lease(
            id: lease.id, reason: lease.reason, kind: lease.kind,
            expiresAt: ContinuousClock().now.advanced(by: Constants.autoLeaseDuration),
        )
        leases[lease.id] = renewed
        scheduleExpiry(of: renewed, after: Constants.autoLeaseDuration)
    }

    // MARK: - Strays

    struct StrayWindow: Sendable {
        let pid: pid_t
        let app: String
        let title: String
    }

    /// Windows on the virtual display that the parked set does not account for: an app
    /// restoring a saved frame there at launch, a second window of a parked app, a dialog
    /// that outlived its lease. Zero cost when no display is attached.
    func strays() async -> [StrayWindow] {
        guard virtualScreenBounds != nil else { return [] }
        let candidates = await windowsOnVirtualDisplay()
        let parked = ledger.entries.map(\.window)
        let strayRefs = ParkLedger.strays(onVirtualDisplay: candidates.map(\.0), parked: parked)
        let strays = Set(strayRefs)
        return candidates.filter { strays.contains($0.0) }.map {
            StrayWindow(pid: $0.0.pid, app: $0.1, title: $0.0.title)
        }
    }

    /// Every regular app's windows whose frame centers on the virtual display, with app
    /// names for reporting. AX-walked per app, so this is for the maintenance pass and
    /// on-demand status — never a per-redraw path.
    private func windowsOnVirtualDisplay() async -> [(ParkLedger.WindowRef, String)] {
        guard let bounds = virtualScreenBounds else { return [] }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var found: [(ParkLedger.WindowRef, String)] = []
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            let pid = application.processIdentifier
            guard pid != ownPid else { continue }
            guard let windows = try? await engine.windowList(pid: pid) else { continue }
            for window in windows {
                guard let frame = window.frame else { continue }
                let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                guard bounds.contains(center) else { continue }
                found.append((
                    .init(pid: pid, title: window.title),
                    application.localizedName ?? "pid \(pid)",
                ))
            }
        }
        return found
    }

    private func refreshStrayCount() async {
        strayCount = await strays().count
    }

    // MARK: - Sweeps

    /// Moves swept entries back to their recorded `before` origins — or, when there is none
    /// (or the recorded home is on a display that has since gone), to a fixed main-screen
    /// point. Returns how many windows were actually asked to move.
    private func sweep(entries: [ParkLedger.Entry]) async -> (swept: Int, stranded: [StrandedWindow]) {
        var swept = 0
        var stranded: [StrandedWindow] = []
        for entry in entries {
            let destination = sweepDestination(for: entry.before?.origin)
            guard (try? await engine.moveWindow(
                pid: entry.window.pid, title: entry.window.title, to: destination,
            )) != nil else {
                stranded.append(StrandedWindow(pid: entry.window.pid, title: entry.window.title))
                continue
            }
            swept += 1
        }
        return (swept, stranded)
    }

    /// Sweeps stray windows to the main screen before the display goes.
    private func sweepStrays() async -> (swept: Int, stranded: [StrandedWindow]) {
        let strays = await strays()
        var swept = 0
        var stranded: [StrandedWindow] = []
        for stray in strays {
            let destination = sweepDestination(for: nil)
            guard (try? await engine.moveWindow(pid: stray.pid, title: stray.title, to: destination)) != nil else {
                stranded.append(StrandedWindow(pid: stray.pid, title: stray.title))
                continue
            }
            swept += 1
        }
        return (swept, stranded)
    }

    /// Where a swept window goes: its recorded origin when that still lands on a current
    /// display, the main display's inset corner otherwise.
    private func sweepDestination(for recorded: CGPoint?) -> CGPoint {
        if let recorded, displayBounds.contains(where: {
            $0.insetBy(dx: -Constants.sweepInset, dy: -Constants.sweepInset).contains(recorded)
        }), virtualScreenBounds?.contains(recorded) != true {
            return recorded
        }
        let main = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: main.origin.x + Constants.sweepInset, y: main.origin.y + Constants.sweepInset)
    }

    // MARK: - Maintenance

    /// While anything is leased: prune parked windows that no longer exist (their auto-lease
    /// self-releases when drained) and keep the stray count honest for the menu bar.
    private func startMaintenance() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task(name: "virtual display maintenance") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Constants.maintenanceInterval)
                guard let self, !Task.isCancelled else { return }
                await self.maintenanceTick()
            }
        }
    }

    private func maintenanceTick() async {
        guard isAttached else { return }
        for entry in ledger.entries {
            let alive: Bool
            if NSRunningApplication(processIdentifier: entry.window.pid) == nil {
                alive = false
            } else if let windows = try? await engine.windowList(pid: entry.window.pid) {
                alive = windows.contains { $0.title == entry.window.title }
            } else {
                // The AX tree not answering is not evidence the window closed.
                alive = true
            }
            guard !alive else { continue }
            _ = await recordUnpark(pid: entry.window.pid, title: entry.window.title)
        }
        await refreshStrayCount()
    }

    // MARK: - Termination

    /// Best-effort un-park on quit, bounded so a wedged AX target cannot stall termination.
    /// The engine runs on its own executor, so blocking the main thread here cannot
    /// deadlock the sweep — a timeout means some windows stay out, and the startup sweep
    /// reclaims them on the next launch.
    private func terminationSweep() {
        let entries = ledger.removeAll()
        guard manager.displayID != nil else { return }
        if !entries.isEmpty {
            let jobs = entries.map { ($0.window.pid, $0.window.title, sweepDestination(for: $0.before?.origin)) }
            let engine = engine
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(name: "termination un-park") {
                for (pid, title, destination) in jobs {
                    _ = try? await engine.moveWindow(pid: pid, title: title, to: destination)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + Constants.terminationSweepTimeout)
        }
        manager.destroy()
    }

    enum BridgeError: LocalizedError {
        case displayNeverAttached

        var errorDescription: String? {
            "No virtual screen appeared — isolation is unavailable right now."
        }
    }
}
