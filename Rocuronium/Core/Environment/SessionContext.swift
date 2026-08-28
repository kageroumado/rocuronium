import CoreGraphics
import Foundation
import Synchronization

/// Which login session this process lives in, and where its synthetic events therefore belong.
///
/// macOS runs several GUI login sessions at once — fast user switching, and the off-console
/// sessions that Screen Sharing mints on virtual displays for a second user. One WindowServer
/// multiplexes them all; each has its own cursor, its own keyboard focus, and its own display
/// ids. An agent driving such a session is alone in it, which is the whole appeal.
///
/// **The trap this type exists for.** It is natural to assume `CGEventPost` is bound to the
/// posting process's session, so that the tap constant only chooses how deep in the event chain
/// the event is inserted. It is not, and measurement says so plainly: an event posted at
/// `.cghidEventTap` from a process in an off-console session moves **the console's** cursor —
/// the human's — while its own session's cursor never moves. Only `.cgSessionEventTap` stays
/// home.
///
/// The mechanism, read out of SkyLight: `SLEventPost` hands the tap constant to
/// `postEventsWithStyle` as a `CGSPostEventStyle`, and the events go to the port from
/// `CGSEventServerPort`, which is `CGSLookupServerRootPort(0)` — the *root* WindowServer port,
/// not a per-session one. So the client does not route; it names a style and the server routes.
/// HID style means "insert where the seat's hardware enters", and a seat's hardware belongs to
/// whichever session holds the console. That is the same seat-global behavior measured for
/// virtual HID devices, arriving by a different door.
///
/// The consequence for the ghost reach is worth stating, because it is the opposite of the
/// intuition: the sting in an off-console session is not *safer* than on the console, it is more
/// dangerous, because it reaches across into a session where a human is present and where none
/// of this engine's protections — presence gates, the overlay, ⌃⌥⇧⎋ — are watching.
nonisolated enum SessionContext {
    private enum Constants {
        /// A session changes console-ness only at a fast user switch, so a second of staleness
        /// costs nothing — while a 120 Hz cursor walk cannot afford a CGS round trip per frame.
        static let cacheLifetime: TimeInterval = 1
    }

    private static let cache = Mutex<(onConsole: Bool, readAt: TimeInterval)?>(nil)

    /// Whether this process's session is the one attached to the physical seat.
    ///
    /// Unreadable session state reads as `true`, which keeps the cautious path the default: a
    /// console-tapped event in a console session is the long-standing behavior, whereas
    /// wrongly believing we are off-console would silently retarget every hardware event.
    static var isOnConsole: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return cache.withLock { entry in
            if let entry, now - entry.readAt < Constants.cacheLifetime { return entry.onConsole }
            let fresh = readOnConsole()
            entry = (fresh, now)
            return fresh
        }
    }

    /// Whether this process drives a session with no physical seat — a Screen Sharing virtual
    /// display session, or a user backgrounded by fast user switching.
    static var isOffConsole: Bool { !isOnConsole }

    /// Where the hardware tentacle must post so its events land in *this* session.
    static var eventTap: CGEventTapLocation { isOnConsole ? .cghidEventTap : .cgSessionEventTap }

    private static func readOnConsole() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["kCGSSessionOnConsoleKey"] as? Bool ?? true
    }
}
