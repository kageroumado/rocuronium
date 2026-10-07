import AppKit
import Propofol
import SwiftUI

/// The Overlay Showcase window: the ten presence scenes, playable and scrubbable, rendered
/// with the real panel and effects views on a pretend desktop.
@MainActor
final class ShowcaseWindowController {
    /// One showcase window per app, opened from the popover, the demo stage, or a Debug launch.
    static let shared = ShowcaseWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false,
            )
            window.title = "Overlay Showcase"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ShowcasePlayer())
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Playback state: which scene, where in it, whether it runs, and how fast.
@MainActor
@Observable
final class ShowcasePlayback {
    var sceneIndex = 0
    var playing = true
    var speed = 1.0
    var appearance: Appearance = .system
    /// Scene time when playback last started or was scrubbed.
    private(set) var anchorTime: TimeInterval = 0
    private(set) var anchorDate = Date()

    enum Appearance: String, CaseIterable, Identifiable {
        case system = "Auto", light = "Light", dark = "Dark"
        var id: String { rawValue }

        var scheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Constants {
        /// The pause at the end of a scene before it loops.
        static let loopRest: TimeInterval = 1.2
    }

    var scene: ShowcaseScene { ShowcaseScene.all[sceneIndex] }

    func time(at date: Date) -> TimeInterval {
        guard playing else { return anchorTime }
        let t = anchorTime + date.timeIntervalSince(anchorDate) * speed
        let cycle = scene.duration + Constants.loopRest
        return min(scene.duration, t.truncatingRemainder(dividingBy: cycle))
    }

    func select(_ index: Int) {
        sceneIndex = index
        seek(to: 0)
        playing = true
    }

    func seek(to t: TimeInterval) {
        anchorTime = max(0, min(scene.duration, t))
        anchorDate = Date()
    }

    func togglePlaying() {
        let now = time(at: Date())
        playing.toggle()
        seek(to: now >= scene.duration ? 0 : now)
    }

    func setSpeed(_ value: Double) {
        let now = time(at: Date())
        speed = value
        seek(to: now)
    }
}

struct ShowcasePlayer: View {
    @State private var playback = ShowcasePlayback()

    var body: some View {
        HStack(spacing: 0) {
            SceneList(playback: playback)
                .frame(width: 250)
            Divider()
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playback.playing)) { timeline in
                let t = playback.time(at: timeline.date)
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    SceneHeader(scene: playback.scene)
                    StageViewport(scene: playback.scene, t: t, scheme: playback.appearance.scheme)
                    TransportBar(playback: playback, t: t)
                }
                .padding(Theme.Space.lg)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

private struct SceneList: View {
    let playback: ShowcasePlayback

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Scenes")
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xs)
                ForEach(Array(ShowcaseScene.all.enumerated()), id: \.offset) { index, scene in
                    Button {
                        playback.select(index)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                            Text("\(scene.number)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(scene.title)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, Theme.Space.sm)
                        .background(
                            Theme.innerShape.fill(index == playback.sceneIndex ? Theme.agent.opacity(0.16) : .clear),
                        )
                        .contentShape(Theme.innerShape)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.md)
        }
    }
}

private struct SceneHeader: View {
    let scene: ShowcaseScene

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(scene.title).font(.heroTitle)
            Text(scene.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The 1280 × 800 stage scaled to whatever room the window gives it.
private struct StageViewport: View {
    let scene: ShowcaseScene
    let t: TimeInterval
    let scheme: ColorScheme?
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        GeometryReader { geometry in
            let size = MockLayout.desktop
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            ShowcaseStage(scene: scene, t: t)
                .environment(\.colorScheme, scheme ?? systemScheme)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .clipShape(Theme.cardShape)
                .overlay(Theme.cardShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(MockLayout.desktop.width / MockLayout.desktop.height, contentMode: .fit)
    }
}

private struct TransportBar: View {
    @Bindable var playback: ShowcasePlayback
    let t: TimeInterval

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button {
                playback.togglePlaying()
            } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(playback.playing ? "Pause" : "Play")

            Slider(
                value: Binding(
                    get: { t },
                    set: { value in
                        playback.playing = false
                        playback.seek(to: value)
                    },
                ),
                in: 0 ... playback.scene.duration,
            )
            Text(String(format: "%.1f / %.1f s", t, playback.scene.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            Picker("Speed", selection: Binding(get: { playback.speed }, set: { playback.setSpeed($0) })) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            Picker("Appearance", selection: $playback.appearance) {
                ForEach(ShowcasePlayback.Appearance.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        }
    }
}
