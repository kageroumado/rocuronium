import AppKit
import SwiftUI

/// The presence panel's window, built like the ⌘⇧5 capture bar: a borderless non-activating
/// panel one level under assistive-tech chrome, on every Space and over fullscreen apps, that
/// never becomes key or main — so clicking or dragging it never takes focus from the human's
/// app.
///
/// It stays visible to screen recording on purpose: a human recording their screen should see
/// the agent's panel. Rocuronium's own evidence captures exclude it instead
/// (`ScreenCapture.excludeFromCaptures`).
final class PresencePanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        isFloatingPanel = true
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // The SwiftUI chrome draws its own shadow.
        hasShadow = false
        animationBehavior = .none
        isMovable = true
        isReleasedWhenClosed = false
        allowsCursorRectsWhenInactive = true
        acceptsMouseMovedEvents = true
        self.contentView = contentView
    }

    /// `kCGAssistiveTechHighWindowLevelKey − 1` (1499): Apple's own value for the capture bar.
    static let level = NSWindow.Level(Int(CGWindowLevelForKey(.assistiveTechHighWindow)) - 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Unconstrained, like the capture bar: the human may park it over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
}

/// Where the panel sits, remembered per display the way the capture bar remembers its origin.
///
/// The origin is stored relative to its display's frame under the display's UUID, so a panel
/// dragged to the top of the laptop screen comes back there, and the external display keeps
/// its own spot. A remembered spot that no longer fits inside its display falls back to the
/// default: bottom-center, clear of the Dock.
enum PanelPlacement {
    enum Constants {
        /// Clearance from the visible frame's bottom edge (above the Dock).
        static let bottomInset: CGFloat = 20
        static let defaultsKey = "PresencePanelOrigins"
    }

    static func displayKey(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "main"
        }
        let id = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "\(id)"
    }

    static func defaultOrigin(size: CGSize, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        return CGPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + Constants.bottomInset)
    }

    /// The remembered origin for this display if the panel still fits there, else the default.
    static func origin(size: CGSize, on screen: NSScreen, defaults: UserDefaults = .standard) -> CGPoint {
        let saved = defaults.dictionary(forKey: Constants.defaultsKey) as? [String: String]
        if let text = saved?[displayKey(for: screen)] {
            let relative = NSPointFromString(text)
            let origin = CGPoint(x: screen.frame.minX + relative.x, y: screen.frame.minY + relative.y)
            if screen.frame.contains(CGRect(origin: origin, size: size)) { return origin }
        }
        return defaultOrigin(size: size, on: screen)
    }

    /// Records where the human left the panel, against the display it is mostly on. A spot
    /// equal to the default is forgotten, so a later change of default applies.
    static func remember(frame: CGRect, defaults: UserDefaults = .standard) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return }
        var saved = defaults.dictionary(forKey: Constants.defaultsKey) as? [String: String] ?? [:]
        let key = displayKey(for: screen)
        if frame.origin == defaultOrigin(size: frame.size, on: screen) {
            saved[key] = nil
        } else {
            let relative = CGPoint(x: frame.minX - screen.frame.minX, y: frame.minY - screen.frame.minY)
            saved[key] = NSStringFromPoint(relative)
        }
        defaults.set(saved, forKey: Constants.defaultsKey)
    }

    /// The display the human is looking at: the one under the pointer.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
