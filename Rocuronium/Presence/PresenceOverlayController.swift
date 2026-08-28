import AppKit
import SwiftUI

/// Owns the overlay window and the session lifecycle: fade in on the first visible action,
/// linger briefly after the last, and vanish instantly on ⌃⌥⇧⎋.
///
/// One borderless window on the primary screen (v1). It ignores every mouse event and sits
/// above normal windows but below the lock screen, joining all Spaces so the session cue
/// survives a Space switch mid-task.
@MainActor
final class PresenceOverlayController {
    /// The relay hooks are `@Sendable` and cannot capture this MainActor object, so they
    /// reach it through a main-actor static instead.
    static weak var shared: PresenceOverlayController?

    let model = OverlayModel()
    /// Fires after ⌃⌥⇧⎋ has halted the engine and removed the chrome; the router logs it.
    var onEmergencyStop: (@MainActor () -> Void)?

    private var window: NSWindow?
    private var bezelWindow: NSWindow?
    private var bezelMoveObserver: (any NSObjectProtocol)?
    private let hotkey = HotkeyMonitor()
    private var lingerTask: Task<Void, Never>?

    private enum Constants {
        static let fadeIn: TimeInterval = 1.0
        static let fadeOut: TimeInterval = 0.8
        /// How long the session chrome outlives the last command before fading.
        static let linger: TimeInterval = 15
        /// The charge-up ring's wind-up — the visible interrupt window before each click.
        static let charge: TimeInterval = 0.6
    }

    init() {
        hotkey.onHalt = { [weak self] in self?.emergencyStop() }
    }

    var isSessionVisible: Bool { model.phase != .hidden }

    // MARK: - Session lifecycle (called by the router)

    /// A visible command is starting: show the chrome and narrate the intent.
    func begin(action: String) {
        show()
        if model.sessionStart == nil { model.sessionStart = Date() }
        model.phase = .thinking
        model.narration = action
        model.lastEngagement = Date()
        restartLinger()
    }

    /// The command's reply is in: narrate the verdict and settle back to idle — or to the
    /// amber needs-human posture when the refusal names a flag only a human should pass.
    func commandFinished(_ reply: [String: Any]) {
        guard isSessionVisible else { return }
        model.chargeRing = nil
        let error = reply["error"] as? String
        model.phase = error?.localizedCaseInsensitiveContains("confirm") == true ? .needsHuman : .idle
        model.narration = Self.narration(for: reply)
        model.lastEngagement = Date()
        restartLinger()
    }

    /// One line of evidence-verdict language for the bezel.
    static func narration(for reply: [String: Any]) -> String {
        if let verdict = reply["verdict"] as? String {
            let readback = (reply["readback"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch verdict {
            case "confirmed": return "Evidence: \(readback ?? "confirmed") ✓"
            case "noEffect": return "Evidence: no observable effect"
            default: return "Evidence: unverifiable"
            }
        }
        if let error = reply["error"] as? String { return error }
        return reply["summary"] as? String ?? "done"
    }

    // MARK: - Effects (called through the relay)

    func showChargeRing(at point: CGPoint, duration: TimeInterval) {
        model.phase = .acting
        model.chargeRing = OverlayModel.ChargeRing(point: point, start: Date(), duration: duration)
        model.lastEngagement = Date()
    }

    func showRipple(at point: CGPoint) {
        model.chargeRing = nil
        model.addRipple(at: point)
        model.lastEngagement = Date()
    }

    /// Installs the Core-side hooks. Called once at launch, after `shared` is set.
    static func installRelayHooks() {
        PresenceRelay.telegraph = { point in
            // The ring and its wind-up exist only while the overlay is visible; invisible
            // sessions return immediately and pay nothing.
            let armed = await MainActor.run {
                guard let overlay = shared, overlay.isSessionVisible else { return false }
                overlay.showChargeRing(at: point, duration: Constants.charge)
                return true
            }
            guard armed else { return }
            try? await Task.sleep(for: .seconds(Constants.charge))
        }
        PresenceRelay.impact = { point in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    shared?.showRipple(at: point)
                }
            }
        }
    }

    // MARK: - The emergency stop

    /// ⌃⌥⇧⎋: halt the engine, then just stop and quietly remove the chrome — no ceremony.
    private func emergencyStop() {
        EmergencyStop.halt(reason: "⌃⌥⇧⎋ pressed while the overlay was visible")
        lingerTask?.cancel()
        hotkey.unregister()
        model.phase = .hidden
        model.sessionStart = nil
        model.chargeRing = nil
        for panel in [window, bezelWindow] {
            panel?.orderOut(nil)
            panel?.alphaValue = 0
        }
        onEmergencyStop?()
    }

    // MARK: - Window

    private func show() {
        if window == nil { window = makeWindow() }
        if bezelWindow == nil { bezelWindow = makeBezelWindow() }
        for panel in [window, bezelWindow] {
            guard let panel else { continue }
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            if panel.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Constants.fadeIn
                    panel.animator().alphaValue = 1
                }
            }
        }
        publishBezelFrame()
        // The stop chord only exists while there is visibly something to stop.
        hotkey.register()
    }

    private func fadeOutAndHide() {
        hotkey.unregister()
        model.phase = .hidden
        model.sessionStart = nil
        model.chargeRing = nil
        for panel in [window, bezelWindow] {
            guard let panel else { continue }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Constants.fadeOut
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // AppKit calls this on the main thread; the closure is typed Sendable, so
                // assert rather than hop (assumeIsolated is near-free).
                MainActor.assumeIsolated {
                    // A new session may have begun during the fade; only order out while
                    // still hidden.
                    guard let self, self.model.phase == .hidden else { return }
                    panel.orderOut(nil)
                }
            })
        }
    }

    private func restartLinger() {
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.linger))
            guard !Task.isCancelled else { return }
            self?.fadeOutAndHide()
        }
    }

    private func makeWindow() -> NSWindow? {
        guard let screen = NSScreen.screens.first else { return nil }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OverlayRootView(model: model))
        return window
    }

    /// The bezel's own window: opaque chrome the human can drag anywhere, with the frame
    /// remembered across sessions and launches. Separate from the effects window because
    /// that one must stay mouse-transparent over the whole screen, while the bezel wants
    /// exactly the opposite — a small surface that catches the drag.
    private func makeBezelWindow() -> NSWindow? {
        guard let screen = NSScreen.screens.first else { return nil }
        let hosting = NSHostingView(rootView: BezelView(model: model))
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // The saved position wins; the default sits bottom-center, high enough to clear
        // the Dock. Only the origin is the human's — the size is ours, so a frame saved
        // by an older layout must not shrink the current one.
        if window.setFrameUsingName(Self.bezelFrameName) {
            window.setContentSize(size)
        } else {
            window.setFrameOrigin(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.minY + 160,
            ))
        }
        window.setFrameAutosaveName(Self.bezelFrameName)
        bezelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishBezelFrame() }
        }
        return window
    }

    private static let bezelFrameName = "PresenceBezel"

    /// Mirrors the bezel's frame into the model in the effects window's top-left
    /// coordinates, so the jellyfish's perch follows the bezel wherever it is dragged.
    private func publishBezelFrame() {
        guard let bezelWindow, let screen = NSScreen.screens.first else { return }
        let frame = bezelWindow.frame
        model.bezelFrame = CGRect(
            x: frame.minX,
            y: screen.frame.height - frame.maxY,
            width: frame.width,
            height: frame.height,
        )
    }
}
