import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures a region of the screen so an action can be judged by its consequences.
///
/// **The coordinate trap.** Accessibility frames are in *points* with a top-left origin.
/// Capture output is in *pixels*, which on a Retina display is two per point. Mixing the two
/// silently produces a region offset and half the size intended, and the resulting "nothing
/// changed" verdict looks like a failed click rather than a measurement bug. Every conversion
/// here is explicit, and the scale factor comes from the display being captured rather than
/// being assumed to be 2.
nonisolated enum ScreenCapture {
    private enum Constants {
        /// Long enough for a loaded window server to answer, short enough that a missing grant
        /// reads as a refusal rather than a wedge.
        static let enumerationTimeout: Duration = .seconds(3)
    }

    enum CaptureError: LocalizedError {
        case noDisplayContains(CGRect)
        case noWindowForApp(pid_t)
        case permissionDenied
        case enumerationTimedOut

        var errorDescription: String? {
            switch self {
            case .enumerationTimedOut:
                "Screen capture did not answer. ScreenCaptureKit blocks instead of failing when Screen Recording is not granted — check Privacy & Security ▸ Screen & System Audio Recording."
            case let .noDisplayContains(rect):
                "No display contains \(rect) — the window may be offscreen or on another Space."
            case let .noWindowForApp(pid):
                "ScreenCaptureKit lists no on-screen window for pid \(pid)."
            case .permissionDenied:
                "Screen Recording permission is required to verify actions visually."
            }
        }
    }

    /// Captures `rect`, given in global accessibility points (top-left origin).
    ///
    /// Returns nil rather than throwing when the region is degenerate, since a zero-area
    /// element is a normal thing to encounter and not an error worth propagating.
    static func image(of rect: CGRect) async throws -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let content = try await shareableContent()
        // No fallback to displays.first: a window on another Space, or a stale offscreen AX
        // frame, would otherwise be captured from display 0 at negative coordinates and return
        // unrelated pixels — which then feed the verdict as if they meant something.
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) })
        else { throw CaptureError.noDisplayContains(rect) }

        // sourceRect is relative to the display's own origin, not the global space.
        let local = rect.offsetBy(dx: -display.frame.origin.x, dy: -display.frame.origin.y)
        let scale = scaleFactor(for: display)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = Int((local.width * scale).rounded())
        configuration.height = Int((local.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false  // a blinking cursor is not a change worth counting

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration,
        )
    }

    /// Captures one window's own pixels, even where other windows cover it.
    ///
    /// This exists because a region capture of "where the window is" returns whatever is
    /// **topmost** there — measured directly: asking for an occluded TextEdit window that way
    /// returned a Discord conversation at exactly TextEdit's size, a correct-looking image of
    /// entirely the wrong thing. `desktopIndependentWindow` composites the window itself, so
    /// occlusion (and parking on the virtual display) cannot substitute someone else's pixels.
    ///
    /// `near` disambiguates multi-window apps: the accessibility frame of the window the
    /// caller means, matched against ScreenCaptureKit's own window list by overlap.
    ///
    /// The reply names the window and frame actually captured, so a fallback pick is visible
    /// to the caller instead of silently substituting a sibling window.
    struct WindowCapture {
        let image: CGImage
        let windowTitle: String
        let windowFrame: CGRect
    }

    static func windowImage(ownedBy pid: pid_t, near rect: CGRect) async throws -> WindowCapture {
        let content = try await shareableContent()
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid }
        // Best overlap with the AX frame wins; a window list and an AX tree can disagree by a
        // few points, so exact equality would be wrong. No overlap at all falls back to the
        // largest window rather than failing — a capture of the wrong window is at least
        // visibly wrong, where an error here would hide that the app has windows.
        let window = candidates.max { lhs, rhs in
            let left = lhs.frame.intersection(rect)
            let right = rhs.frame.intersection(rect)
            let leftArea = left.isNull ? -lhs.frame.width * lhs.frame.height : left.width * left.height
            let rightArea = right.isNull ? -rhs.frame.width * rhs.frame.height : right.width * right.height
            return leftArea < rightArea
        }
        guard let window else { throw CaptureError.noWindowForApp(pid) }

        let scale = content.displays.first(where: { $0.frame.intersects(window.frame) })
            .map(scaleFactor(for:)) ?? 2

        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration,
        )
        return WindowCapture(image: image, windowTitle: window.title ?? "", windowFrame: window.frame)
    }

    /// Points-to-pixels for a display. `SCDisplay` reports its frame in points, while the
    /// underlying mode reports pixel dimensions; their ratio is the backing scale.
    private static func scaleFactor(for display: SCDisplay) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), display.frame.width > 0 else {
            return 1
        }
        return CGFloat(mode.pixelWidth) / display.frame.width
    }

    /// Enumerates capturable content, but refuses to wait forever for it.
    ///
    /// `SCShareableContent` does not fail when Screen Recording is missing or has been
    /// invalidated — it simply never returns. Every verb that verifies visually then hangs until
    /// the socket times out, and the daemon reads as wedged while `status` and `apps` keep
    /// answering, which sends the reader looking in entirely the wrong place. Measured after a
    /// reinstall replaced the bundle. A bounded wait turns that into a sentence naming the grant.
    private static func shareableContent() async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            group.addTask {
                try await Task.sleep(for: Constants.enumerationTimeout)
                throw CaptureError.enumerationTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CaptureError.enumerationTimedOut }
            return first
        }
    }

    /// Whether visual verification is available at all. Screen Recording is a separate grant
    /// from Accessibility, and the engine must degrade rather than fail when it is missing.
    static var isPermitted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
}
