import CoreGraphics
import Foundation

@available(macOS 27, *)
nonisolated struct FoundationModelsBackend: GroundingBackend {
    let identifier = "foundation-models"
    let isAvailable = true

    func locate(_: String, in _: CGImage) async throws -> [GroundingCandidate] {
        []
    }

    func judge(intent: String, before: CGImage, after: CGImage) async throws -> GroundingJudgement {
        // TODO: Foundation Models Attachment API for semantic verification
        GroundingJudgement(happened: false, confidence: 0, explanation: "not yet implemented")
    }
}
