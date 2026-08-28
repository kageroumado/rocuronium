import AppKit
import CoreGraphics

/// What the frontmost app is doing with the screen, when that changes what is safe to do.
///
/// The case this exists for: a fullscreen app owns a Space of its own, and macOS switches
/// Spaces when a window appears on another one. So an action that is otherwise perfectly
/// ghost-safe — launching an app without activating it, which is how `launch` already behaves —
/// can still throw a human out of a fullscreen game, because the *new window* moves the Space,
/// not the launch. Measured 2026-08-26: driving a freshly launched test app pulled Kiri out of
/// fullscreen Subnautica, and nothing in the ghost tentacles had touched the cursor.
nonisolated enum Foreground {
    /// Whether the frontmost application is filling a whole display.
    ///
    /// Read from the window list rather than the accessibility tree on purpose: the apps that
    /// matter here are games, and a Unity or SDL title typically publishes no usable AX tree at
    /// all — the absence that makes AX detection useless is itself part of the profile. A
    /// window at the normal layer whose frame matches a display's bounds is either fullscreen or
    /// so thoroughly maximized that the distinction does not matter to the human in front of it.
    static var frontmostIsFullscreen: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID,
        ) as? [[String: Any]] else { return false }

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        let screens = displays.map { CGDisplayBounds($0) }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            // Exact equality is too brittle across scale factors; a window within a point of a
            // display's bounds on every edge is covering it.
            if screens.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) && frame.width >= $0.width - 1 && frame.height >= $0.height - 1 }) {
                return true
            }
        }
        return false
    }

    /// The frontmost app's name, for saying *what* would be disturbed rather than that something
    /// would be.
    static var frontmostName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
    }
}
