import ApplicationServices
import Foundation

/// Caches accessibility walks between attempts.
///
/// A full walk of an Electron app costs ~1.2 s for ~5,300 elements, and the ghost ladder may
/// consult the tree several times while working through its rungs. Repeating that is the
/// difference between an agent that feels immediate and one that feels broken.
///
/// The hard part is not caching, it is knowing when the cache became a lie. Rather than trust
/// a timer alone, entries carry a cheap **fingerprint** — a handful of O(1) accessibility reads
/// — that is re-taken on every hit. If the fingerprint moved, the app's UI moved, and the walk
/// is redone.
actor TreeCache {
    private enum Constants {
        /// Even a matching fingerprint expires: a tree can change without moving focus,
        /// window count, or the frontmost window's title.
        static let maximumAge: Duration = .seconds(5)
    }

    /// The O(1) reads that stand in for "has this app's UI changed?".
    private struct Fingerprint: Equatable {
        let focusedSignature: String?
        let windowCount: Int
        let frontWindowTitle: String?
        /// Perception is worthless while the display sleeps, so a tree captured awake must
        /// never be served asleep, or vice versa.
        let displayAwake: Bool

        init(pid: pid_t) {
            let app = AXElement(pid: pid)
            let windows = app.windows
            focusedSignature = app.focused?.signature
            windowCount = windows.count
            frontWindowTitle = windows.first?.string(kAXTitleAttribute)
            displayAwake = !DisplayWake.displayIsAsleep
        }
    }

    private struct Entry {
        let results: ElementQuery.Results
        let fingerprint: Fingerprint
        let capturedAt: ContinuousClock.Instant
    }

    private var entries: [pid_t: [String: Entry]] = [:]
    private let clock = ContinuousClock()

    private(set) var hits = 0
    private(set) var misses = 0

    /// Returns a cached walk when it is still trustworthy, otherwise performs `walk` and
    /// stores the result. `key` distinguishes different queries against the same process.
    func results(
        for pid: pid_t,
        key: String,
        walk: () -> ElementQuery.Results
    ) -> ElementQuery.Results {
        let fingerprint = Fingerprint(pid: pid)

        if let entry = entries[pid]?[key],
           entry.fingerprint == fingerprint,
           entry.capturedAt.duration(to: clock.now) < Constants.maximumAge
        {
            hits += 1
            return entry.results
        }

        misses += 1
        let fresh = walk()
        // An app with no windows and nothing focused fingerprints identically to a dead one, so
        // caching it invites serving its results to a recycled pid later. Cheap to redo anyway.
        guard fingerprint.windowCount > 0 || fingerprint.focusedSignature != nil else {
            return fresh
        }
        // Re-fingerprint *after* walking: a walk takes over a second, and the UI may have moved
        // during it. Storing the pre-walk fingerprint would keep serving a tree we already know
        // is stale.
        entries[pid, default: [:]][key] = Entry(
            results: fresh,
            fingerprint: Fingerprint(pid: pid),
            capturedAt: clock.now,
        )
        return fresh
    }

    /// Drops everything for one process. Call after any action that is expected to change the
    /// interface — the ghost ladder does this itself once an action is confirmed.
    func invalidate(pid: pid_t) {
        entries[pid] = nil
    }

    /// Drops everything. Used on display power transitions, where every tree in every process
    /// changes shape at once.
    func invalidateAll() {
        entries.removeAll()
    }

    /// Drops entries for processes that no longer exist, so the cache cannot grow without
    /// bound and cannot serve a dead app's tree to whatever inherits its pid.
    func evictDeadProcesses(livePIDs: Set<pid_t>) {
        entries = entries.filter { livePIDs.contains($0.key) }
    }

    var statistics: (hits: Int, misses: Int) { (hits, misses) }
}
