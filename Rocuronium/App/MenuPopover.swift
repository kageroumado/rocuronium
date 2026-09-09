import AppKit
import Propofol
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
        "\(hero)|\(engine.canCaptureScreen)|\(engine.startupError != nil)|\(engine.activityLog.entries.count)|\(engine.strayCount)|\(engine.skillState == .current)"
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

                if engine.strayCount > 0 {
                    problemCard(
                        icon: "macwindow.badge.plus", tint: Theme.halted,
                        title: engine.strayCount == 1
                            ? "A stray window is on the virtual display"
                            : "\(engine.strayCount) stray windows are on the virtual display",
                        detail: "Nobody parked them, so nobody will sweep them home — they are invisible from here. 'display status' names them; releasing the display sweeps them back.",
                    )
                }

                visionCard

                if engine.skillState != .current {
                    skillCard
                }

                if !engine.activityLog.entries.isEmpty {
                    activityCard
                }

                stylePickerCard
                overlayToggleCard
                bottomBar
            }
            .padding(Theme.Space.lg)
        }
        .task { engine.refreshSkillState() }
    }

    // MARK: - Header

    private var header: some View {
        PopoverHeader("Rocuronium")
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
            (Theme.halted, "Halted by you (\(HotkeyMonitor.chord.displayString))",
             "Every agent verb is refused until you resume. Only this popover can.", false)
        case .driving:
            (Theme.agent, "An agent has hands", drivingSubtitle, false)
        case .idle:
            (Theme.idle, "Standing by", idleSubtitle, true)
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
                        .frame(width: 44, height: 58)
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
        case .present: "You're at the keyboard — agents stay on the ghost tentacles"
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

    /// Live swatches rather than a segmented control with names in it: the thing being
    /// chosen is a drawing, so the choice should be made by looking at drawings. Each
    /// swatch animates in the phase the agent is actually in, so you pick the style while
    /// watching it say the thing it will have to say.
    private var stylePickerCard: some View {
        @Bindable var styles = JellyStyleStore.shared
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Mascot")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(JellyStyle.allCases) { style in
                    let chosen = styles.style == style
                    Button {
                        styles.style = style
                    } label: {
                        VStack(spacing: Theme.Space.xs) {
                            JellyfishStateView(phase: jellyfishPhase, style: style)
                                .frame(width: 48, height: 66)
                            Text(style.title)
                                .font(.caption2.weight(chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? Theme.agent : .secondary)
                        }
                        .padding(.vertical, Theme.Space.xs)
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(chosen ? Theme.agent.opacity(0.14) : .clear)
                            .strokeBorder(chosen ? Theme.agent.opacity(0.55) : .clear, lineWidth: 1)
                    }
                    .help(style.blurb)
                    .accessibilityLabel("\(style.title) — \(style.blurb)")
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            HStack(spacing: 0) { Spacer(minLength: 0); MascotCredit() }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var visionCard: some View {
        let vlmInstalled = ModelStore.isInstalled("holo-3.1-4b")
        let detectorInstalled = ModelStore.isInstalled("yolo-detector")
        let anyInstalled = vlmInstalled || detectorInstalled

        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: anyInstalled ? "eye.fill" : "eye.slash")
                .foregroundStyle(anyInstalled ? Theme.agent : .secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(anyInstalled ? "Vision grounding" : "Vision grounding (not set up)")
                    .font(.callout.weight(.medium))
                Text(anyInstalled
                    ? (vlmInstalled ? "VLM + detector ready" : "Detector only")
                    : "Download models to find UI elements when accessibility is empty.")
                    .font(.caption).foregroundStyle(.secondary)
                if !anyInstalled {
                    Button("Set up in Settings…") { engine.showSettings() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .glassCard(tint: anyInstalled ? nil : Theme.agent.opacity(0.08))
    }

    /// Shown while the user-level copy of the agent skill is missing or differs from this
    /// build. The skill is the operator manual; a harness that loads it drives the engine as
    /// documented, and `rocuronium guide` prints the same text for one that does not.
    private var skillCard: some View {
        let outdated = if case .outdated = engine.skillState { true } else { false }
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "text.book.closed.fill")
                .foregroundStyle(Theme.agent)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(outdated ? "Agent skill is out of date" : "Agent skill not installed")
                    .font(.callout.weight(.medium))
                Text(outdated
                    ? "The copy in ~/.claude/skills differs from this build's operator guide."
                    : "Install the operator guide as a Claude Code skill in ~/.claude/skills/rocuronium.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(outdated ? "Update skill" : "Install skill") { engine.installSkill() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                if let error = engine.skillError {
                    Text(error).font(.caption2).foregroundStyle(Theme.blocked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .glassCard(tint: Theme.agent.opacity(0.08))
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
                        engine.showSettings()
                    } label: {
                        Image(systemName: "gearshape").frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Settings — models, preferences")
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

// MARK: - Credits

/// The faintest thing in the window, on purpose. The four mascots were drawn by someone
/// other than the app's author, and the credit she asked for is one you have to be looking
/// for — so it sits under the swatches, at nine points, at a quarter opacity, and only comes
/// up to legible when the pointer is on it. It is next to the art rather than in the header
/// because the person who goes looking for who drew the jellyfish is already looking at them.
private struct MascotCredit: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/pharmacykitty")!) {
            Text("jellyfish girl")
                .font(.system(size: 9, design: .rounded))
                .underline(hovering)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 0.85 : 0.24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Who drew the mascots")
        .accessibilityLabel("Mascots by jellyfish girl")
    }
}
