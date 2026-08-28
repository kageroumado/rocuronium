import CoreGraphics
import Foundation
import IOKit

/// Whether a human is at this machine, and what the agent owes them because of it.
///
/// Invisibility is not the same as politeness. An agent working while someone is typing should
/// behave differently from one working at 4 a.m. against a locked screen — not because the
/// mechanism differs, but because the cost of being wrong does. This type answers "is anyone
/// there?" and hands the answer to the agent so it can decide, rather than deciding for it.
///
/// The default is **assume present**: if presence cannot be determined, the polite behavior is
/// the one that never takes the cursor.
nonisolated enum UserPresence {
    private enum Constants {
        /// Input this recent means hands are on the keyboard right now.
        static let presentWithin: TimeInterval = 60
        /// Beyond this with no input, the person has probably walked away.
        static let idleUntil: TimeInterval = 15 * 60
    }

    enum State: String, Codable, Sendable {
        /// Recent input — someone is actively using this Mac.
        case present
        /// No input for a while, but the session is live and visible.
        case idle
        /// Screen locked or display asleep: nobody is watching.
        case away
        /// Could not determine. Treated as `present`, because that is the cautious reading.
        case unknown
    }

    struct Reading: Codable, Sendable {
        let state: State
        let idleSeconds: TimeInterval
        let screenLocked: Bool
        let displayAsleep: Bool
        /// Whether this reading describes a session with no physical seat, in which case the
        /// idle and lock fields describe *the console user's* world, not this one.
        let offConsole: Bool

        /// Whether the agent may fall back to hardware input — the one tentacle that takes the
        /// cursor out of a human's hand. Only ever true when nobody is there to lose it.
        ///
        /// Never while the screen is locked. Synthetic keystrokes then go to the login window's
        /// password field: failed attempts, lockout delays on a FileVault machine, and someone
        /// who just pressed Ctrl-Cmd-Q standing right there. Hardware input cannot usefully
        /// reach an app behind the lock screen anyway.
        ///
        /// Off-console this is always true, and both clauses above are why it has to be stated
        /// separately rather than falling out of the same test: nobody holds this session's
        /// cursor, and its permanent "locked" reading is the absence of a viewer.
        var mayTakeCursor: Bool { offConsole || (state == .away && !screenLocked) }

        /// Whether a lock screen stands between the hardware tentacle and the apps it aims at.
        ///
        /// This is the question the gates actually want, and it is not `screenLocked`: an
        /// off-console session reports itself locked for as long as no viewer is attached,
        /// which is its normal state and puts no login window in front of anything.
        var lockBlocksHardware: Bool { screenLocked && !offConsole }

        /// Whether perception can be trusted at all right now.
        var canSee: Bool { !displayAsleep }

        /// A sentence for the agent, since this is propagated into every status response and
        /// the agent is the one making the call.
        var advice: String {
            if offConsole {
                return "This is an off-console session with no seat of its own — the idle and lock readings above belong to the console user, not here. Hardware input is fine and lands only in this session."
            }
            return switch state {
            case .present:
                "A person is using this Mac right now. Stay on the ghost tentacles; do not take the cursor or change the frontmost app."
            case .idle:
                "No input for \(Int(idleSeconds / 60)) minutes, but the session is live. Prefer ghost tentacles; a returning user must not find their cursor moving."
            case .away:
                if screenLocked {
                    "The screen is locked. Accessibility still works, but do not use hardware input — it would type into the login window."
                } else if displayAsleep {
                    "Nobody is watching and the display is asleep — wake it before trusting anything you read."
                } else {
                    "Nobody is watching. Hardware input is acceptable if the ghost tentacles fail."
                }
            case .unknown:
                "Presence unknown; assuming someone is here. Stay on the ghost tentacles."
            }
        }
    }

    static func read() -> Reading {
        // Corrected, not raw: our own synthetic input resets the system's idle timer.
        let idle = InputAttribution.shared.humanIdleSeconds(rawIdle: idleSeconds())
        let locked = screenIsLocked
        let asleep = DisplayWake.displayIsAsleep

        // Off-console there is no one in this session to be present *to*: HIDIdleTime is a
        // single system-wide counter driven by the seat's hardware, so it reports the console
        // user's hands, and this session's lock flag only means no viewer is attached.
        let offConsole = SessionContext.isOffConsole

        let state: State = if offConsole {
            .away
        } else if locked || asleep {
            .away
        } else if idle < 0 {
            .unknown
        } else if idle < Constants.presentWithin {
            .present
        } else if idle < Constants.idleUntil {
            .idle
        } else {
            .away
        }

        return Reading(
            state: state,
            idleSeconds: max(0, idle),
            screenLocked: locked,
            displayAsleep: asleep,
            offConsole: offConsole,
        )
    }

    /// Seconds since the last keyboard or pointer input, or a negative value if unavailable.
    static func idleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator,
        ) == KERN_SUCCESS else { return -1 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return -1 }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any],
              let nanoseconds = values["HIDIdleTime"] as? Int64
        else { return -1 }

        return TimeInterval(nanoseconds) / 1_000_000_000
    }

    /// Screen lock state. Note this does **not** imply blindness: a locked session with an
    /// awake display exposes full accessibility trees. Only display sleep blinds the agent.
    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
