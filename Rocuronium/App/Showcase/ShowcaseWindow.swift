import AppKit
import Propofol
import SwiftUI

/// How the showcase opens, from the launch arguments — so a recording can start the window
/// on one scene, playing, with nothing around the stage:
///
///     Rocuronium --showcase-scene hero --autoplay --loop --hide-chrome --window-size 1280x800 \
///         [--window-origin 1600,100]
///
/// A bare window comes up without activating the app. With none of these, the window opens on
/// the first scene, playing and looping, with its scene list and transport.
struct ShowcaseLaunchOptions: Equatable {
    var sceneSlug: String?
    var autoplay = true
    var loop = true
    /// Only the mock desktop: no scene list, header, transport or title bar.
    var hideChrome = false
    /// The window's content size in points.
    var windowSize: CGSize?
    /// The window's top-left corner in global top-left points — on the virtual display, say.
    var windowOrigin: CGPoint?
    /// Seconds the first frame holds before autoplay starts, so a recording opens on a still.
    var leadIn: TimeInterval = 0

    enum Constants {
        static let recordingLeadIn: TimeInterval = 1.5
    }

    static func parse(_ arguments: [String] = CommandLine.arguments) -> ShowcaseLaunchOptions {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        var options = ShowcaseLaunchOptions()
        let explicit = ["--showcase-scene", "--autoplay", "--loop", "--hide-chrome", "--window-size", "--window-origin"]
            .contains { arguments.contains($0) }
        guard explicit else { return options }
        options.sceneSlug = value("--showcase-scene")
        options.autoplay = arguments.contains("--autoplay")
        options.loop = arguments.contains("--loop")
        options.hideChrome = arguments.contains("--hide-chrome")
        options.leadIn = options.autoplay ? Constants.recordingLeadIn : 0
        if let size = value("--window-size") {
            let parts = size.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts.allSatisfy({ $0 >= 200 && $0 <= 8000 }) {
                options.windowSize = CGSize(width: parts[0], height: parts[1])
            }
        }
        if let origin = value("--window-origin") {
            let parts = origin.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { options.windowOrigin = CGPoint(x: parts[0], y: parts[1]) }
        }
        return options
    }
}

/// The Overlay Showcase window: the presence scenes, playable and scrubbable, rendered with
/// the real panel and effects views on a pretend desktop.
@MainActor
final class ShowcaseWindowController {
    /// One showcase window per app, opened from the popover, the demo stage, or a Debug launch.
    static let shared = ShowcaseWindowController()

    private var window: NSWindow?

    enum Constants {
        static let defaultSize = CGSize(width: 1320, height: 820)
    }

    func show(options: ShowcaseLaunchOptions = ShowcaseLaunchOptions()) {
        if window == nil {
            let size = options.windowSize ?? Constants.defaultSize
            // Borderless when bare: no title bar, so no safe area eating into the stage.
            let style: NSWindow.StyleMask = options.hideChrome
                ? [.borderless]
                : [.titled, .closable, .resizable, .miniaturizable]
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: style, backing: .buffered, defer: false,
            )
            window.title = "Overlay Showcase"
            window.isReleasedWhenClosed = false
            if options.hideChrome {
                window.backgroundColor = .black
                window.isMovableByWindowBackground = true
            }
            let playback = ShowcasePlayback(options: options)
            let player = ShowcasePlayer(playback: playback, hideChrome: options.hideChrome)
            let hosting = NSHostingView(rootView: player)
            hosting.sizingOptions = options.windowSize == nil ? [.minSize] : []
            window.contentView = hosting
            window.setContentSize(size)
            if let origin = options.windowOrigin, let primary = NSScreen.screens.first {
                // Top-left global points, the coordinates `rocuronium windows` reports.
                window.setFrameTopLeftPoint(NSPoint(x: origin.x, y: primary.frame.maxY - origin.y))
            } else {
                window.center()
            }
            self.window = window
            if options.hideChrome {
                // Wall-clock instant of scene time 0, so a recording can be cut on a loop boundary.
                print("showcase anchor: \(playback.anchorDate.timeIntervalSince1970)")
            }
        }
        if options.hideChrome {
            // A recording window comes up without taking focus from whoever is using the Mac.
            window?.orderFrontRegardless()
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        if options.hideChrome, let window, let screen = NSScreen.screens.first {
            let frame = window.frame
            // The window's id and its rectangle in top-left global points.
            let top = screen.frame.maxY - frame.maxY
            print("showcase window: id \(window.windowNumber) -R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
            // Unbuffered: a recording script reads these lines while the app keeps running.
            fflush(stdout)
        }
    }
}

/// Playback state: which scene, where in it, whether it runs, and how fast.
@MainActor
@Observable
final class ShowcasePlayback {
    var sceneIndex = 0
    var playing = true
    var loops = true
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

    init(options: ShowcaseLaunchOptions = ShowcaseLaunchOptions()) {
        if let slug = options.sceneSlug, let index = ShowcaseScene.all.firstIndex(where: { $0.slug == slug }) {
            sceneIndex = index
        }
        playing = options.autoplay
        loops = options.loop
        anchorDate = Date().addingTimeInterval(options.leadIn)
    }

    var scene: ShowcaseScene { ShowcaseScene.all[sceneIndex] }

    func time(at date: Date) -> TimeInterval {
        guard playing else { return anchorTime }
        let t = anchorTime + max(0, date.timeIntervalSince(anchorDate)) * speed
        guard loops else { return min(scene.duration, t) }
        let cycle = scene.duration + scene.loopRest
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
    /// Owned by the window: one playback per showcase window, for the window's life.
    let playback: ShowcasePlayback
    var hideChrome = false

    var body: some View {
        if hideChrome {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !playback.playing)) { timeline in
                StageViewport(scene: playback.scene, t: playback.time(at: timeline.date), scheme: nil, bare: true)
            }
            .ignoresSafeArea()
        } else {
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

/// The 1280 × 800 stage scaled to whatever room the window gives it. `bare` drops the card
/// frame, for a window that is nothing but the stage.
private struct StageViewport: View {
    let scene: ShowcaseScene
    let t: TimeInterval
    let scheme: ColorScheme?
    var bare = false
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        GeometryReader { geometry in
            let size = MockLayout.desktop
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            ShowcaseStage(scene: scene, t: t)
                .environment(\.colorScheme, scheme ?? systemScheme)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .clipShape(bare ? AnyShape(Rectangle()) : AnyShape(Theme.cardShape))
                .overlay {
                    if !bare { Theme.cardShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                }
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
