import ApplicationServices
import SwiftUI

@main
struct RocuroniumApp: App {
    @State private var engine = EngineHost()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(engine: engine)
        } label: {
            // The icon is the safety indicator: filled while the engine is driving something,
            // outlined when idle. A user must never have to wonder whether an agent has hands.
            Image(systemName: engine.isDriving ? "cursorarrow.rays" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the control socket and the shared engine state for the app's lifetime.
@MainActor
@Observable
final class EngineHost {
    private(set) var isDriving = false
    private(set) var startupError: String?
    private(set) var presence = UserPresence.read()

    private let router = CommandRouter()
    private var server: ControlServer?

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
    func requestScreenRecordingPermission() {
        ScreenCapture.requestPermission()
        openSettings(pane: "Privacy_ScreenCapture")
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
                    Text("Without it, clicks that expose no value stay unverifiable.")
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

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }
}
