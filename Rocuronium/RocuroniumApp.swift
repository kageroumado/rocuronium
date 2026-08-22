import ApplicationServices
import SwiftUI

@main
struct RocuroniumApp: App {
    @State private var engine = EngineHost()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(engine: engine)
        } label: {
            // The icon is the safety indicator: the jellyfish is filled while the engine is
            // driving something, outlined when idle. A user must never have to wonder
            // whether an agent has hands.
            Image(nsImage: engine.isDriving ? MenuBarGlyph.driving : MenuBarGlyph.idle)
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

    private let router = CommandRouter()
    private var server: ControlServer?

    var activityLog: ActivityLog { router.activityLog }
    var overlayModel: OverlayModel { router.overlay.model }

    /// The one way back from ⌥⎋ — a human clicking a button in this popover.
    func resumeFromHalt() {
        router.resumeFromHalt()
        isHalted = false
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

private struct MenuBarContent: View {
    let engine: EngineHost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("rocuronium").font(.headline)

            if engine.isHalted {
                // The only way back from ⌥⎋. Human-only by design: no socket verb can
                // clear the halt, so the agent cannot un-halt itself.
                VStack(alignment: .leading, spacing: 4) {
                    Label("Halted by you (⌥⎋)", systemImage: "hand.raised.fill")
                        .font(.callout).foregroundStyle(.orange)
                    Text("Every agent verb is refused until you resume.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Resume agent commands") { engine.resumeFromHalt() }
                }
            }

            if !engine.isTrusted {
                // Without this grant nothing works at all, so it is the first thing shown.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility access is required.").font(.callout)
                    Text("Add Rocuronium in the list, then relaunch it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Accessibility settings…") { engine.requestAccessibilityPermission() }
                }
            }

            if !engine.canCaptureScreen {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording is optional.").font(.callout)
                    Text("Without it, clicks that expose no value stay unverifiable. If Rocuronium isn't in the list yet, press this once more.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Screen Recording settings…") { engine.requestScreenRecordingPermission() }
                }
            }

            LabeledContent("Presence", value: engine.presence.state.rawValue)
            LabeledContent("Can see", value: engine.presence.canSee ? "yes" : "display asleep")
            if engine.presence.screenLocked {
                Text("Screen is locked — this does not block the engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let startupError = engine.startupError {
                Text(startupError).font(.caption).foregroundStyle(.red)
            }

            @Bindable var overlayModel = engine.overlayModel
            Toggle("Show overlay for every action", isOn: $overlayModel.showForAllActions)
                .font(.callout)
                .toggleStyle(.checkbox)

            let recent = engine.activityLog.recent(5)
            if !recent.isEmpty {
                Divider()
                Text("Recent activity").font(.caption).foregroundStyle(.secondary)
                ForEach(recent.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Text("\(entry.action) \(entry.target)")
                            .font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entry.verdict)
                            .font(.caption)
                            .foregroundStyle(entry.verdict == "confirmed" ? .green : .secondary)
                    }
                }
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }
}
