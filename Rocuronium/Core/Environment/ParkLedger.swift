import CoreGraphics
import Foundation

/// The record of every window parked on the virtual display, and which lease put it there.
///
/// Pure bookkeeping, deliberately free of AX, screens, and actors, so the two policies that
/// hang off it are unit-testable: auto-leases self-release when their last parked window is
/// returned or closes, and any window on the virtual display that this ledger does not know
/// about is a **stray** — something restored or launched there that nobody is watching.
///
/// Windows are identified by `(pid, title)`. Titles can drift while parked (a document
/// gaining an edited marker, say); the sweep paths tolerate that by falling back to the
/// stray sweep, which reads current titles from the window list.
nonisolated struct ParkLedger: Sendable, Equatable {
    /// A window's identity as the ledger sees it.
    struct WindowRef: Sendable, Equatable, Hashable {
        var pid: pid_t
        var title: String
    }

    struct Entry: Sendable, Equatable {
        var window: WindowRef
        /// The frame the window had before parking — the position an un-park or a teardown
        /// sweep writes back. `nil` for a window that never had an on-screen home (launched
        /// directly onto the virtual display); those sweep to a fixed main-screen point.
        var before: CGRect?
        /// The auto-lease this park counts against, when one was in force. Explicit-lease
        /// parks carry `nil`: whoever acquired explicitly must release explicitly, so their
        /// parks never decrement anything.
        var leaseID: UUID?
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    func contains(_ window: WindowRef) -> Bool {
        entries.contains { $0.window == window }
    }

    func entries(under leaseID: UUID) -> [Entry] {
        entries.filter { $0.leaseID == leaseID }
    }

    /// Records a park. Re-parking a window that is already in the ledger keeps its original
    /// `before` — the window's real home is where it stood before the *first* park, not
    /// wherever the last shuffle left it.
    mutating func recordPark(_ window: WindowRef, before: CGRect?, leaseID: UUID?) {
        if let index = entries.firstIndex(where: { $0.window == window }) {
            entries[index].leaseID = leaseID
            return
        }
        entries.append(Entry(window: window, before: before, leaseID: leaseID))
    }

    /// Removes a window from the ledger (it was un-parked, or it closed). Returns the entry
    /// so the caller can act on its `before` frame and check its lease's remaining count.
    @discardableResult
    mutating func recordUnpark(_ window: WindowRef) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.window == window }) else { return nil }
        return entries.remove(at: index)
    }

    /// Drops and returns every entry under one lease — the expiry/release sweep's worklist.
    mutating func removeAll(under leaseID: UUID) -> [Entry] {
        let removed = entries.filter { $0.leaseID == leaseID }
        entries.removeAll { $0.leaseID == leaseID }
        return removed
    }

    /// Drops and returns everything — the final-teardown sweep's worklist.
    mutating func removeAll() -> [Entry] {
        let removed = entries
        entries.removeAll()
        return removed
    }

    /// Whether removing this entry left its auto-lease with nothing parked — the signal for
    /// an auto-lease to release itself.
    func leaseIsDrained(_ leaseID: UUID?) -> Bool {
        guard let leaseID else { return false }
        return entries(under: leaseID).isEmpty
    }

    /// The windows on the virtual display that nobody parked: everything in `onVirtualDisplay`
    /// that the parked set does not account for.
    static func strays(onVirtualDisplay: [WindowRef], parked: [WindowRef]) -> [WindowRef] {
        let known = Set(parked)
        return onVirtualDisplay.filter { !known.contains($0) }
    }
}
