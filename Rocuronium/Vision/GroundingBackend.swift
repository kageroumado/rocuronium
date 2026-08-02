import CoreGraphics
import Foundation

/// Turning a human description into something clickable.
///
/// Models are an **enhancement, never a dependency**. With none installed, targeting falls back
/// to accessibility plus hit-testing and verification falls back to a pixel diff — degraded,
/// but never broken. This matters because the apps where accessibility is weakest are exactly
/// the ones a user is most likely to have, so "no model" must remain a working configuration.
nonisolated protocol GroundingBackend: Sendable {
    var identifier: String { get }
    var isAvailable: Bool { get }

    /// Locates candidates matching a description within a captured screen region.
    func locate(_ description: String, in image: CGImage) async throws -> [GroundingCandidate]

    /// Answers the question a return code cannot: did the intended thing actually happen?
    /// Given before/after images and what was attempted, judge semantically.
    func judge(intent: String, before: CGImage, after: CGImage) async throws -> GroundingJudgement
}

nonisolated struct GroundingCandidate: Sendable {
    let rect: CGRect
    let confidence: Double
    let describedAs: String
}

nonisolated struct GroundingJudgement: Sendable {
    let happened: Bool
    let confidence: Double
    let explanation: String
}

/// The default backend: hand the pixels back to whoever called us.
///
/// The calling agent already has a capable vision model, so shipping screenshots upward costs
/// nothing, needs no download, and is usually the best answer. A local model is worth it only
/// when round-trip latency or unattended operation matters.
nonisolated struct ScreenshotBackend: GroundingBackend {
    let identifier = "screenshot"
    let isAvailable = true

    func locate(_: String, in _: CGImage) async throws -> [GroundingCandidate] {
        []  // Deliberately empty: the caller's own model does the locating.
    }

    func judge(intent _: String, before _: CGImage, after _: CGImage) async throws -> GroundingJudgement {
        GroundingJudgement(happened: false, confidence: 0, explanation: "deferred to caller")
    }
}

/// Where local weights live, and the rules that keep them from becoming a liability.
///
/// Models are **never** bundled in the app: a multi-gigabyte `.app` cannot be notarized
/// sensibly, cannot ship as a homebrew cask, and would make every user pay for a feature most
/// will not enable. They are downloaded on explicit request, verified, and disposable —
/// deleting a model directory degrades the app, it does not break it.
nonisolated enum ModelStore {
    enum Constants {
        static let bundleIdentifier = "glass.kagerou.rocuronium"
        static let manifestName = "manifest.json"
    }

    /// `~/Library/Application Support/glass.kagerou.rocuronium/Models`
    static var root: URL {
        URL.applicationSupportDirectory
            .appending(path: Constants.bundleIdentifier)
            .appending(path: "Models")
    }

    static func directory(for modelID: String) -> URL {
        root.appending(path: modelID)
    }

    /// A model the app knows how to fetch. Size and license are surfaced in the UI before any
    /// download starts — a several-gigabyte fetch is never implicit.
    struct Descriptor: Codable, Sendable {
        let id: String
        let displayName: String
        let revision: String
        let sha256: String
        let bytes: Int64
        let license: String
        let source: URL
    }

    /// Candidates, both Apache-2.0 and runnable on Apple silicon via MLX.
    static let known: [Descriptor] = []

    static func isInstalled(_ modelID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(for: modelID).appending(path: Constants.manifestName).path,
        )
    }

    static func installedBytes() -> Int64 {
        guard let entries = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, entry in
            let path = root.appending(path: entry).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            total += size
        }
    }

    static func evict(_ modelID: String) throws {
        try FileManager.default.removeItem(at: directory(for: modelID))
    }
}
