import CoreGraphics
import Darwin

/// The mark every event Rocuronium synthesizes carries, so input can be attributed: an event
/// with the mark is ours, an event without it is a human's.
///
/// The mark rides in `eventSourceUserData`, a field the window server carries through to every
/// tap and that no input device writes. Every post site goes through `postTagged`, so an event
/// cannot leave the process unmarked — `SyntheticInputTests` fails the build on a raw
/// `post(tap:)` or `postToPid` anywhere else in the app.
nonisolated enum SyntheticInput {
    /// "ROCURONI" in ASCII. Arbitrary but recognizable in a tap dump; positive, so it survives
    /// any signed/unsigned reinterpretation of the field.
    static let tag: Int64 = 0x524F_4355_524F_4E49

    /// Whether `event` is one we posted: it carries the mark, or its source process is this one
    /// (the fallback for an event whose user-data field a toolkit rewrote on the way through).
    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == tag
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }
}

extension CGEvent {
    /// Marks the event as ours and posts it to the session pipeline at `tap`.
    nonisolated func postTagged(tap: CGEventTapLocation) {
        setIntegerValueField(.eventSourceUserData, value: SyntheticInput.tag)
        post(tap: tap)
    }

    /// Marks the event as ours and posts it to one process's queue.
    nonisolated func postTagged(toPid pid: pid_t) {
        setIntegerValueField(.eventSourceUserData, value: SyntheticInput.tag)
        postToPid(pid)
    }
}
