import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Writes showcase frames to PNGs, so the look can be reviewed without playing anything.
///
/// `Rocuronium --render-showcase <dir> [--scene <slug>]` writes each scene's key moments: the
/// whole pretend desktop with a caption strip under it, at 2×, once light and once dark
/// (`NN-slug-tT.png`, `NN-slug-tT-dark.png`), and `closeups/` holds the panel's corner of each
/// frame. Adding `--fps <n>` writes every frame instead — the bare stage, no caption — into
/// `NN-slug-light/` and `NN-slug-dark/` as `frame-00001.png`…, ready for ffmpeg. Glass cannot
/// render offline, so the panel draws its flat surface here.
@MainActor
enum ShowcaseRenderer {
    enum Constants {
        static let scale: CGFloat = 2
        static let captionHeight: CGFloat = 64
        /// The panel's neighborhood on the 1280 × 800 desktop, in points.
        static let closeup = CGRect(x: 330, y: 440, width: 620, height: 290)
        static let maximumFPS = 120
    }

    /// What to render, from the launch arguments.
    struct Request: Equatable {
        var directory: URL
        /// One scene by slug; every scene when nil.
        var sceneSlug: String?
        /// Every frame at this rate instead of the key moments.
        var fps: Int?

        static let argument = "--render-showcase"

        /// The request when the app was launched to render, else nil.
        static func parse(_ arguments: [String] = CommandLine.arguments) -> Request? {
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            guard let path = value(argument) else { return nil }
            let fps = value("--fps").flatMap(Int.init).map { max(1, min($0, Constants.maximumFPS)) }
            return Request(
                directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                sceneSlug: value("--scene"), fps: fps,
            )
        }
    }

    /// Renders what the request asks for and returns the files written.
    @discardableResult
    static func render(_ request: Request) throws -> [URL] {
        let scenes = ShowcaseScene.all.filter { request.sceneSlug == nil || $0.slug == request.sceneSlug }
        guard !scenes.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no scene with slug '\(request.sceneSlug ?? "")'"])
        }
        if let fps = request.fps {
            return try scenes.flatMap { try renderEveryFrame($0, fps: fps, to: request.directory) }
        }
        return try render(to: request.directory, scenes: scenes)
    }

    /// Renders every listed scene's key moments and returns the files written.
    @discardableResult
    static func render(to directory: URL, scenes: [ShowcaseScene] = ShowcaseScene.all) throws -> [URL] {
        let closeups = directory.appending(path: "closeups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: closeups, withIntermediateDirectories: true)
        var written: [URL] = []
        for scene in scenes {
            for moment in scene.keyMoments {
                for scheme in [ColorScheme.light, .dark] {
                    let name = fileName(scene: scene, t: moment, dark: scheme == .dark)
                    guard let image = frame(scene: scene, t: moment, scheme: scheme) else { continue }
                    let url = directory.appending(path: name)
                    try write(image, to: url)
                    written.append(url)
                    let crop = Constants.closeup.applying(CGAffineTransform(scaleX: Constants.scale, y: Constants.scale))
                    if let closeup = image.cropping(to: crop) {
                        try write(closeup, to: closeups.appending(path: name))
                    }
                }
            }
        }
        return written
    }

    /// Every frame of one scene at `fps`, light and dark, the bare stage.
    private static func renderEveryFrame(_ scene: ShowcaseScene, fps: Int, to directory: URL) throws -> [URL] {
        var written: [URL] = []
        let count = Int((scene.duration * Double(fps)).rounded(.down)) + 1
        for scheme in [ColorScheme.light, .dark] {
            let folder = directory.appending(
                path: String(format: "%02d-%@-%@", scene.number, scene.slug, scheme == .dark ? "dark" : "light"),
                directoryHint: .isDirectory,
            )
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0 ..< count {
                let t = Double(index) / Double(fps)
                guard let image = stage(scene: scene, t: t, scheme: scheme) else { continue }
                let url = folder.appending(path: String(format: "frame-%05d.png", index + 1))
                try write(image, to: url)
                written.append(url)
            }
        }
        return written
    }

    static func fileName(scene: ShowcaseScene, t: TimeInterval, dark: Bool) -> String {
        String(format: "%02d-%@-t%.2f%@.png", scene.number, scene.slug, t, dark ? "-dark" : "")
    }

    static func frame(scene: ShowcaseScene, t: TimeInterval, scheme: ColorScheme) -> CGImage? {
        image(of: VStack(spacing: 0) {
            ShowcaseStage(scene: scene, t: t)
            CaptionStrip(scene: scene, t: t)
        }, scheme: scheme)
    }

    /// The stage alone, for video frames.
    static func stage(scene: ShowcaseScene, t: TimeInterval, scheme: ColorScheme) -> CGImage? {
        image(of: ShowcaseStage(scene: scene, t: t), scheme: scheme)
    }

    private static func image(of content: some View, scheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: content
            .environment(\.panelSurface, .flat)
            .environment(\.colorScheme, scheme))
        renderer.scale = Constants.scale
        return renderer.cgImage
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private struct CaptionStrip: View {
        let scene: ShowcaseScene
        let t: TimeInterval
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                Text(String(format: "%d · t = %.2f s", scene.number, t))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title).font(.system(size: 13, weight: .semibold))
                    Text(scene.caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .frame(width: MockLayout.desktop.width, height: Constants.captionHeight, alignment: .leading)
            .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.96))
        }
    }
}
