import CoreGraphics
import Foundation

/// How the engine tells the overlay what it is about to do, without Core importing any UI.
///
/// Core must stay headless (testable without the app, reusable from the CLI path), so the
/// dependency points the other way: the app installs these hooks once at launch, and the
/// engine calls through them blindly. The defaults are no-ops, which is also the behavior
/// when the overlay is not part of the session — never nil-checks in the actuation path.
nonisolated enum PresenceRelay {
    /// Called with the aim point right before a hardware-tentacle click or trace begins.
    ///
    /// When the overlay is visible this draws the charge-up ring and *waits out its wind-up*
    /// (~600 ms) — the deliberate window in which ⌃⌥⇧⎋ can land before the click does. When the
    /// overlay is hidden it returns immediately, so invisible sessions pay nothing.
    nonisolated(unsafe) static var telegraph: @Sendable (CGPoint) async -> Void = { _ in }

    /// Called after a hardware-tentacle click lands; draws the ripple. Fire-and-forget.
    nonisolated(unsafe) static var impact: @Sendable (CGPoint) -> Void = { _ in }

    /// Called after a *ghost* (posted, cursor-free) click lands, with the click point. The
    /// overlay pings there only when the human asked to watch every action and is present to
    /// see it, so an invisible action's location is legible without taking the cursor. The
    /// gate lives in the installed hook; the actuation path calls unconditionally.
    nonisolated(unsafe) static var ghostImpact: @Sendable (CGPoint) -> Void = { _ in }
}
