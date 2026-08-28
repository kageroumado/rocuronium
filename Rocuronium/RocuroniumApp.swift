import ApplicationServices
import SwiftUI

@main
struct RocuroniumApp: App {
    @State private var engine = EngineHost()

    var body: some Scene {
        MenuBarExtra {
            MenuPopover(engine: engine)
        } label: {
            // The icon is the safety indicator: the jellyfish is filled while the engine is
            // driving something, outlined when idle, and badged while stray windows sit on
            // the virtual display where a human cannot see them. A user must never have to
            // wonder whether an agent has hands — or windows.
            Image(nsImage: MenuBarGlyph.glyph(driving: engine.isDriving, badged: engine.strayCount > 0))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the control socket and the shared engine state for the app's lifetime.
@MainActor
@Observable
final class EngineHost {
    var isDriving: Bool { router.isDriving }
    private(set) var startupError: String?
    private(set) var presence = UserPresence.read()
    /// Mirrors `EmergencyStop` for the popover; refreshed on the presence timer and by the
    /// resume button, since the flag itself is a plain atomic the UI cannot observe.
    private(set) var isHalted = false
    /// Windows on the virtual display that nobody parked — invisible to the human, so the
    /// menu bar badges and the popover names them. Refreshed on the presence timer.
    private(set) var strayCount = 0

    private let router = CommandRouter()
    private var server: ControlServer?

    var activityLog: ActivityLog { router.activityLog }
    var overlayModel: OverlayModel { router.overlay.model }

    /// The one way back from ⌃⌥⇧⎋ — a human clicking a button in this popover.
    func resumeFromHalt() {
        router.resumeFromHalt()
        isHalted = false
    }

    func showDemoStage() {
        router.demoStage.show(reset: true)
    }

    init() {
        let server = ControlServer(router: router)
        self.server = server
        do {
            try server.start()
        } catch {
            startupError = error.localizedDescription
        }
        Task { await pollPresence() }
    }

    /// Presence drives the menu bar text, so it is refreshed on a slow timer rather than read
    /// on every access — the IOKit lookup is cheap but not free.
    private func pollPresence() async {
        while !Task.isCancelled {
            presence = UserPresence.read()
            isHalted = EmergencyStop.isHalted
            strayCount = router.virtualDisplayStrayCount
            try? await Task.sleep(for: .seconds(5))
        }
    }

    var isTrusted: Bool { AXIsProcessTrusted() }
    var canCaptureScreen: Bool { ScreenCapture.isPermitted }

    /// Asks for Accessibility, then opens the pane regardless.
    ///
    /// The system prompt from `AXIsProcessTrustedWithOptions` is shown **once per bundle** —
    /// after it has been dismissed or denied, the call does nothing visible, so a button
    /// wired only to it appears broken. Opening the pane directly is what actually helps.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(pane: "Privacy_Accessibility")
    }

    /// Screen Recording is a separate grant, needed only for visual verification. Without it
    /// the engine still works; actions without a read-back just stay unverifiable.
    ///
    /// Like the Accessibility prompt, `CGRequestScreenCaptureAccess` only ever shows its dialog
    /// once per bundle. Worse, an app is not even *listed* in the Screen Recording pane until
    /// it has attempted a capture — so a button that only opens Settings sends the user to look
    /// for a row that does not exist. Attempting a real capture first is what registers it.
    func requestScreenRecordingPermission() {
        ScreenCapture.requestPermission()
        Task {
            // The result does not matter; making the attempt is what registers the app.
            _ = try? await ScreenCapture.image(of: CGRect(x: 0, y: 0, width: 8, height: 8))
            openSettings(pane: "Privacy_ScreenCapture")
        }
    }

    private func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
