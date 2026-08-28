import Foundation
import Synchronization

/// The ⌃⌥⇧⎋ halt: one flag every long-running path checks, set by the human, cleared by the
/// human.
///
/// The flag lives in Core so that walks, poll loops, and the hardware tentacle can consult it
/// without any UI import, and it is process-global on purpose: an emergency stop that only
/// halts *future* requests is not an emergency stop. The fastest path from keypress to
/// stillness is `HardwareInput`'s per-sample check — about one 8 ms sample.
///
/// Resume is deliberately not reachable from the control socket. The halt means a human took
/// the machine back; only a human at the machine — the menu bar popover — may hand it over
/// again. A socket verb that cleared this flag would let the agent un-halt itself.
nonisolated enum EmergencyStop {
    /// Checked from hot loops (one atomic load), so the flag is separate from the reason.
    private static let halted = Atomic<Bool>(false)
    private static let detail = Mutex<String?>(nil)

    static var isHalted: Bool { halted.load(ordering: .relaxed) }

    /// What every refused verb replies while halted.
    static let refusalMessage = "halted by the human (⌃⌥⇧⎋) — resume from the Rocuronium menu bar"

    static var reason: String? {
        detail.withLock { $0 }
    }

    static func halt(reason: String) {
        detail.withLock { $0 = reason }
        halted.store(true, ordering: .relaxed)
    }

    static func resume() {
        halted.store(false, ordering: .relaxed)
        detail.withLock { $0 = nil }
    }
}
