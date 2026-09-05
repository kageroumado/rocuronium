import CoreGraphics
import CoreML
import Vision

nonisolated struct DetectorBackend: GroundingBackend {
    let identifier = "yolo-detector"

    var isAvailable: Bool { true }

    /// Whether the detector weights are on disk. When false, `detect` returns nothing and the
    /// vision path is OCR-only — a working, degraded configuration, never a broken one.
    var isModelInstalled: Bool { hasYOLO }

    private var hasYOLO: Bool {
        FileManager.default.fileExists(atPath: Self.modelPath.path)
    }

    /// One proposed UI-element box in image pixel coordinates, top-left origin.
    struct DetectedBox: Sendable {
        let rect: CGRect
        let confidence: Double
    }

    /// Every control box the detector proposes for a window, unfiltered — the "parse the
    /// window" primitive behind detector rows. Empty when no model is installed. The model is
    /// single-class (`UIElement`), so the box carries a frame and a confidence; the caller
    /// derives the label from the OCR text inside the box.
    func detect(in image: CGImage) throws -> [DetectedBox] {
        guard hasYOLO else { return [] }
        return try detectBoxes(in: image).map { detection in
            DetectedBox(
                rect: denormalize(detection.rect, imageWidth: image.width, imageHeight: image.height),
                confidence: Double(detection.confidence),
            )
        }
    }

    private static var modelPath: URL {
        ModelStore.directory(for: "yolo-detector").appending(path: "model.mlpackage")
    }

    private enum Constants {
        static let inputSize = 640
        static let confidenceThreshold: Float = 0.25
        static let iouThreshold: Float = 0.45
    }

    func locate(_ description: String, in image: CGImage) async throws -> [GroundingCandidate] {
        let sightings = TextSighting.sight(in: image)
        let needle = description.lowercased()

        if hasYOLO {
            let candidates = try locateWithYOLO(needle: needle, sightings: sightings, in: image)
            if !candidates.isEmpty { return candidates }
        }

        return locateWithOCR(needle: needle, sightings: sightings, imageWidth: image.width, imageHeight: image.height)
    }

    private func locateWithOCR(needle: String, sightings: [TextSighting.Sighting], imageWidth: Int, imageHeight: Int) -> [GroundingCandidate] {
        var candidates: [GroundingCandidate] = []

        for sighting in sightings {
            guard sighting.text.lowercased().contains(needle) else { continue }
            let pixelRect = fromVisionCoords(sighting.box, imageHeight: imageHeight, imageWidth: imageWidth)
            let similarity = Double(needle.count) / Double(max(sighting.text.count, 1))
            candidates.append(GroundingCandidate(
                rect: pixelRect,
                confidence: similarity,
                describedAs: sighting.text
            ))
        }

        candidates.sort { $0.confidence > $1.confidence }
        return candidates
    }

    private func locateWithYOLO(needle: String, sightings: [TextSighting.Sighting], in image: CGImage) throws -> [GroundingCandidate] {
        let boxes = try detectBoxes(in: image)
        if boxes.isEmpty { return [] }

        var candidates: [GroundingCandidate] = []

        for box in boxes {
            let boxRect = denormalize(box.rect, imageWidth: image.width, imageHeight: image.height)

            let matchedSighting = sightings.first { sighting in
                let sightingPixelRect = fromVisionCoords(sighting.box, imageHeight: image.height, imageWidth: image.width)
                let overlap = boxRect.intersection(sightingPixelRect)
                guard !overlap.isNull else { return false }
                let overlapArea = overlap.width * overlap.height
                let sightingArea = sightingPixelRect.width * sightingPixelRect.height
                guard sightingArea > 0 else { return false }
                return overlapArea / sightingArea > 0.3 && sighting.text.lowercased().contains(needle)
            }

            if let matched = matchedSighting {
                candidates.append(GroundingCandidate(
                    rect: boxRect,
                    confidence: Double(box.confidence),
                    describedAs: matched.text
                ))
            }
        }

        candidates.sort { $0.confidence > $1.confidence }
        return candidates
    }

    func judge(intent: String, before: CGImage, after: CGImage) async throws -> GroundingJudgement {
        GroundingJudgement(happened: false, confidence: 0, explanation: "deferred to caller")
    }

    // MARK: - YOLO detection

    private struct Detection {
        let rect: CGRect
        let confidence: Float
        let classID: Int
    }

    private func detectBoxes(in image: CGImage) throws -> [Detection] {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let modelURL = Self.modelPath
        guard let compiledURL = try? MLModel.compileModel(at: modelURL) else { return [] }
        guard let model = try? MLModel(contentsOf: compiledURL, configuration: config) else { return [] }
        defer { try? FileManager.default.removeItem(at: compiledURL) }

        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        return (request.results as? [VNRecognizedObjectObservation] ?? [])
            .filter { $0.confidence >= Constants.confidenceThreshold }
            .map { obs in
                Detection(
                    rect: obs.boundingBox,
                    confidence: obs.confidence,
                    classID: obs.labels.first.map { Int($0.identifier) ?? 0 } ?? 0
                )
            }
    }

    // MARK: - Coordinate helpers

    private func denormalize(_ visionRect: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        return CGRect(
            x: visionRect.minX * w,
            y: (1 - visionRect.maxY) * h,
            width: visionRect.width * w,
            height: visionRect.height * h
        )
    }

    private func toVisionCoords(_ pixelRect: CGRect, imageHeight: Int) -> CGRect {
        let h = CGFloat(imageHeight)
        return CGRect(
            x: pixelRect.minX,
            y: h - pixelRect.maxY,
            width: pixelRect.width,
            height: pixelRect.height
        )
    }

    private func fromVisionCoords(_ visionRect: CGRect, imageHeight: Int, imageWidth: Int) -> CGRect {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        return CGRect(
            x: visionRect.minX * w,
            y: (1 - visionRect.maxY) * h,
            width: visionRect.width * w,
            height: visionRect.height * h
        )
    }
}
