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
/// Owned exclusively by `Engine`, which is an actor, so this needs no isolation of its own —
/// a second actor here would only add hops. `nonisolated` because the module defaults to
/// main-actor isolation and this must run wherever the engine runs.
nonisolated final class TreeCache {
    private enum Constants {
        /// Even a matching fingerprint expires: a tree can change without moving focus,
        /// window count, or the frontmost window's title. Kept short because the cost of a
        /// stale entry is a click at the wrong coordinates, while the cost of a miss is one
        /// walk.
        static let maximumAge: Duration = .seconds(2)
    }

    /// The O(1) reads that stand in for "has this app's UI changed?".
    ///
    /// The front window's **frame** matters as much as its title: moving or resizing a window
    /// leaves every other field identical while shifting every cached coordinate, and a cached
    /// frame is what a click is aimed at. `AXFocusedWindow` is used rather than `windows.first`
    /// because `AXWindows` ordering is not contractually front-to-back.
    private struct Fingerprint: Equatable {
        let focusedSignature: String?
        let windowCount: Int
        let frontWindowTitle: String?
        let frontWindowFrame: CGRect?
        /// Perception is worthless while the display sleeps, so a tree captured awake must
        /// never be served asleep, or vice versa.
        let displayAwake: Bool

        init(pid: pid_t) {
            let app = AXElement(pid: pid)
            windowCount = app.windows.count
            focusedSignature = app.focused?.signature
            let front: AXElement? = {
                guard let value = app.attribute(kAXFocusedWindowAttribute),
                      CFGetTypeID(value) == AXUIElementGetTypeID() else { return app.windows.first }
                return AXElement(value as! AXUIElement)
            }()
            frontWindowTitle = front?.string(kAXTitleAttribute)
            frontWindowFrame = front?.frame
            displayAwake = !DisplayWake.displayIsAsleep
        }
    }

    private struct Entry {
        let results: ElementQuery.Results
        let fingerprint: Fingerprint
        /// Where each matched element was when the walk ran. A cached result is only usable if
        /// the things it names are still where it says they are — scrolling a list, opening a
        /// dropdown, or a layout shift moves elements while leaving the fingerprint untouched,
        /// and a stale frame means clicking whatever now occupies those coordinates.
        let matchedFrames: [CGRect?]
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
           entry.capturedAt.duration(to: clock.now) < Constants.maximumAge,
           entry.results.matches.map(\.element.frame) == entry.matchedFrames
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
            matchedFrames: fresh.matches.map(\.element.frame),
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
