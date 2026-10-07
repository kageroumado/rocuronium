import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Writes every scene's key moments to PNGs, so the look can be reviewed without playing
/// anything: `Rocuronium --render-showcase <dir>`.
///
/// Each frame is the whole pretend desktop with a caption strip under it, at 2×, once light
/// and once dark (`NN-slug-tT.png`, `NN-slug-tT-dark.png`). `closeups/` holds the panel's
/// corner of each frame at full resolution. Glass cannot render offline, so the panel draws
/// its flat surface here.
@MainActor
enum ShowcaseRenderer {
    enum Constants {
        static let scale: CGFloat = 2
        static let captionHeight: CGFloat = 64
        /// The panel's neighborhood on the 1280 × 800 desktop, in points.
        static let closeup = CGRect(x: 300, y: 470, width: 680, height: 260)
    }

    static let argument = "--render-showcase"

    /// The output directory when the app was launched to render, else nil.
    static func requestedDirectory(arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Renders every scene and returns the files written.
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

    static func fileName(scene: ShowcaseScene, t: TimeInterval, dark: Bool) -> String {
        String(format: "%02d-%@-t%.2f%@.png", scene.number, scene.slug, t, dark ? "-dark" : "")
    }

    static func frame(scene: ShowcaseScene, t: TimeInterval, scheme: ColorScheme) -> CGImage? {
        let content = VStack(spacing: 0) {
            ShowcaseStage(scene: scene, t: t)
            CaptionStrip(scene: scene, t: t)
        }
        .environment(\.panelSurface, .flat)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
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
