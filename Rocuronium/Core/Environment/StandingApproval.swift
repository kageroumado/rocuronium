import Foundation

/// An approval the human gave for a stretch of work rather than for one action: holding **A**
/// at a consent prompt answers every prompt that would follow for ``duration``. It is theirs
/// alone to give — no verb grants it — and the stop chord (⌃⌥⇧⎋) ends it at once.
///
/// It stands in for the consent prompt and for nothing else: the fullscreen guard, the
/// locked-screen refusal and the occlusion check still decide on their own.
@MainActor
enum StandingApproval {
    static let minutes = 30
    static var duration: TimeInterval { TimeInterval(minutes * 60) }

    private static var until: Date?

    static var isStanding: Bool { secondsLeft > 0 }

    static var secondsLeft: Int {
        guard let until else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow.rounded()))
    }

    static func grant(now: Date = Date()) {
        until = now.addingTimeInterval(duration)
    }

    static func end() {
        until = nil
    }
}
