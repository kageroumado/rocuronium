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
    enum CaptureError: LocalizedError {
        case noDisplayContains(CGRect)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case let .noDisplayContains(rect):
                "No display contains \(rect) — the window may be offscreen or on another Space."
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

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true,
        )
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

    /// Points-to-pixels for a display. `SCDisplay` reports its frame in points, while the
    /// underlying mode reports pixel dimensions; their ratio is the backing scale.
    private static func scaleFactor(for display: SCDisplay) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), display.frame.width > 0 else {
            return 1
        }
        return CGFloat(mode.pixelWidth) / display.frame.width
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
