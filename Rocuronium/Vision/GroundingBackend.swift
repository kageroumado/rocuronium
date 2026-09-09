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
