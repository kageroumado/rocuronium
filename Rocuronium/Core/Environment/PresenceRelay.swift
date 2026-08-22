import CoreGraphics
import Foundation

/// How the engine tells the overlay what it is about to do, without Core importing any UI.
///
/// Core must stay headless (testable without the app, reusable from the CLI path), so the
/// dependency points the other way: the app installs these hooks once at launch, and the
/// engine calls through them blindly. The defaults are no-ops, which is also the behavior
/// when the overlay is not part of the session — never nil-checks in the actuation path.
nonisolated enum PresenceRelay {
    /// Called with the aim point right before a hardware-rung click or trace begins.
    ///
    /// When the overlay is visible this draws the charge-up ring and *waits out its wind-up*
    /// (~600 ms) — the deliberate window in which ⌥⎋ can land before the click does. When the
    /// overlay is hidden it returns immediately, so invisible sessions pay nothing.
    nonisolated(unsafe) static var telegraph: @Sendable (CGPoint) async -> Void = { _ in }

    /// Called after a hardware-rung click lands; draws the ripple. Fire-and-forget.
    nonisolated(unsafe) static var impact: @Sendable (CGPoint) -> Void = { _ in }
}
