import AppKit
import SwiftUI

/// The window-style popover attached to the menu-bar status item — the suite's shared
/// popover shape (Adrafinil, Phosphene): a rounded header with attribution, one hero card
/// whose animated icon carries the state, supporting cards only when they earn their
/// place, and a glass bottom bar.
struct MenuPopover: View {
    let engine: EngineHost

    var body: some View {
        content
            .frame(width: Theme.popoverWidth)
            .animation(.smooth(duration: 0.3), value: layoutSignature)
    }

    /// Which sections are visible, so appearing/disappearing cards glide instead of snapping.
    private var layoutSignature: String {
        "\(hero)|\(engine.canCaptureScreen)|\(engine.startupError != nil)|\(engine.activityLog.entries.count)"
    }

    private enum Hero: Hashable {
        case blocked, halted, driving, idle
    }

    private var hero: Hero {
        if !engine.isTrusted { return .blocked }
        if engine.isHalted { return .halted }
        if engine.isDriving { return .driving }
        return .idle
    }

    private var content: some View {
        GlassEffectContainer(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                heroCard

                if hero == .halted {
                    Button {
                        engine.resumeFromHalt()
                    } label: {
                        Text("Resume agent commands")
                            .font(.toolName)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.xs)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.agent)
                }

                if let startupError = engine.startupError {
                    problemCard(
                        icon: "exclamationmark.octagon.fill", tint: Theme.blocked,
                        title: "The control socket did not start", detail: startupError,
                    )
                }

                if hero != .blocked, !engine.canCaptureScreen {
                    screenRecordingCard
                }

                if !engine.activityLog.entries.isEmpty {
                    activityCard
                }

                overlayToggleCard
                bottomBar
            }
            .padding(Theme.Space.lg)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Rocuronium").font(.heroTitle)
            Spacer()
            AttributionLink()
        }
    }

    // MARK: - Hero card

    /// One stable card across states so the jellyfish keeps its view identity and animates
    /// between poses (idle drift, acting pulse, the halt's amber curl) instead of being
    /// swapped out; only the missing-grant state replaces it with a warning symbol.
    private var heroCard: some View {
        let (tint, title, subtitle, dimmed): (Color, String, String, Bool) = switch hero {
        case .blocked:
            (Theme.blocked, "Accessibility is required",
             "Add Rocuronium in System Settings, then relaunch — nothing works without it.", false)
        case .halted:
            (Theme.halted, "Halted by you (⌥⎋)",
             "Every agent verb is refused until you resume. Only this popover can.", false)
        case .driving:
            (Theme.agent, "An agent has hands", drivingSubtitle, false)
        case .idle:
            (.secondary, "Standing by", idleSubtitle, true)
        }
        return HStack(spacing: Theme.Space.md) {
            Group {
                if hero == .blocked {
                    Image(systemName: "hand.raised.slash.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                } else {
                    JellyfishStateView(phase: jellyfishPhase, dimmed: dimmed)
                        .frame(width: 44, height: 52)
                }
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded).weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: dimmed ? nil : tint.opacity(0.18))
        .onTapGesture {
            if hero == .blocked { engine.requestAccessibilityPermission() }
        }
    }

    private var jellyfishPhase: OverlayModel.Phase {
        switch hero {
        case .halted: .needsHuman
        case .driving: .acting
        default: .idle
        }
    }

    private var drivingSubtitle: String {
        if let last = engine.activityLog.entries.last {
            return "\(last.action) \(last.target)"
        }
        return "A command is in flight right now"
    }

    private var idleSubtitle: String {
        let presence = engine.presence
        if presence.displayAsleep {
            return "Display asleep — the engine is blind until an action wakes it"
        }
        return switch presence.state {
        case .present: "You're at the keyboard — agents stay on the ghost rungs"
        case .idle: "Quiet for a while — still your cursor, still your focus"
        case .away: "Nobody watching — hardware input may be permitted"
        case .unknown: "Presence unknown — treated as you being here"
        }
    }

    // MARK: - Supporting cards

    private func problemCard(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .glassCard(tint: tint.opacity(0.14))
    }

    private var screenRecordingCard: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .foregroundStyle(Theme.halted)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Screen Recording is optional").font(.callout.weight(.medium))
                Text("Without it, actions with no read-back stay unverifiable. If Rocuronium isn't listed yet, press once more.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Screen Recording settings…") {
                    engine.requestScreenRecordingPermission()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .glassCard()
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Recent activity")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(engine.activityLog.recent(5).reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text(entry.date, format: .dateTime.hour().minute())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text("\(entry.action) \(entry.target)")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.xs)
                        StatusDot(color: verdictColor(entry.verdict), diameter: 6)
                            .help(entry.summary.isEmpty ? entry.verdict : entry.summary)
                    }
                }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "confirmed", "ok", "resumed": Theme.ok
        case "noEffect", "refused": Theme.halted
        case "halted": Theme.blocked
        default: .secondary
        }
    }

    private var overlayToggleCard: some View {
        @Bindable var model = engine.overlayModel
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $model.showForAllActions) {
                Text("Show overlay for every action").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Text("Ghost actions are invisible by design; cursor-taking ones always show it.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Theme.Space.sm) {
            StateChip(
                text: engine.presence.state.rawValue,
                systemImage: engine.presence.state == .present ? "person.fill" : "person",
                tint: engine.presence.state == .present ? Theme.agent : .secondary,
            )
            if engine.presence.screenLocked {
                StateChip(text: "locked", systemImage: "lock.fill")
            }
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Button {
                        engine.showDemoStage()
                    } label: {
                        Image(systemName: "theatermasks").frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Open the demo stage — deterministic targets for every verb")
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        // `xmark`, not `power`: a power glyph in a Mac context reads as
                        // "shut down the Mac" — the wrong mental model for quitting the app.
                        Image(systemName: "xmark").frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Quit Rocuronium — the control socket goes with it")
                }
            }
        }
    }
}

// MARK: - AttributionLink

private struct AttributionLink: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/kageroumado")!) {
            HStack(spacing: 2) {
                Text("made by kageroumado")
                    .underline(hovering)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
