import CoreGraphics
import Vision

/// On-device OCR over captured pixels — the first piece of the vision tier that ships.
///
/// The job this exists for: **deterministic scrolling**. "Scroll down 100 px" overshoots or
/// undershoots blindly, but "scroll until the frame contains the string 'Claude'" terminates
/// exactly when the target is visible — each frame is OCRed locally (~100 ms, no model
/// download, no tokens) and the loop stops on sight. The same primitive answers "is this text
/// on screen right now?" for windows whose accessibility tree lies or is empty.
///
/// Vision's fast recognition path is used deliberately: this is a presence test, not a
/// transcription. Language correction is off because it "fixes" exactly the strings agents
/// search for — identifiers, button labels, file names.
nonisolated enum TextSighting {
    struct Sighting: Sendable {
        let text: String
        /// Vision's normalized image coordinates: origin bottom-left, 0…1 on both axes.
        let box: CGRect
    }

    /// Every line of text Vision can see in the image, with where it sits.
    static func sight(in image: CGImage) -> [Sighting] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Sighting(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// The first sighted line containing `needle`, case-insensitively.
    static func find(_ needle: String, in sightings: [Sighting]) -> Sighting? {
        let wanted = needle.lowercased()
        return sightings.first { $0.text.lowercased().contains(wanted) }
    }

    /// A sighting's rectangle in global screen points, given the frame of the window the
    /// image captured. Vision's y axis points up from the bottom of the image; screen
    /// coordinates point down from the top — hence the flip.
    static func screenRect(of sighting: Sighting, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + sighting.box.minX * windowFrame.width,
            y: windowFrame.minY + (1 - sighting.box.maxY) * windowFrame.height,
            width: sighting.box.width * windowFrame.width,
            height: sighting.box.height * windowFrame.height,
        )
    }

    /// A cheap fingerprint of what is legible in a frame, for detecting that scrolling is no
    /// longer changing anything — the end of a document, or a scroll mechanism the target
    /// ignores. Joined text alone (without geometry) is deliberate: a caret blink or hover
    /// highlight changes pixels but not words.
    static func fingerprint(of sightings: [Sighting]) -> String {
        sightings.map(\.text).joined(separator: "\n")
    }
}
