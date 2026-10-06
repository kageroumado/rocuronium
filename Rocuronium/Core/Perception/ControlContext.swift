import ApplicationServices
import CoreGraphics
import Foundation

/// A name for a control that carries none of its own, read from where a human reads it.
///
/// SwiftUI renders a `Form` row's switch as an `AXCheckBox` (subrole `AXSwitch`) with an empty
/// title, the row's text sitting beside it as a sibling `AXStaticText` — measured on
/// Sevoflurane's Settings, 2026-09-20: `find --role AXCheckBox` listed every switch unlabeled
/// and `click --label` could not name one. The derived label is what the row says, so it is
/// both reported (`label`, with `labelSource: "row"`) and matched by `--label`.
nonisolated struct DerivedLabel: Sendable {
    let text: String
    /// The `signature` of the element the text was read from — the static text that *is* the
    /// label. A `--label` query matching both that text and the control it names is one target,
    /// not two, and the control wins.
    let sourceSignature: String?
}

nonisolated extension AXElement {
    /// The control roles whose unnamed instances get a label from their surroundings.
    static let rowLabelledRoles: Set<String> = [
        "AXCheckBox", "AXSwitch", "AXRadioButton", "AXPopUpButton", "AXSlider",
    ]

    private enum ContextConstants {
        /// Parent, then grandparent — a Form row's cell, then the row. Further up is someone
        /// else's text.
        static let ancestorLevels = 2
        /// A container wider than this is a section, not a row; its text does not name one
        /// control.
        static let maxSiblings = 12
    }

    /// The label a human reads for this control, when it has no title, description, or
    /// placeholder of its own. In order: `AXTitleUIElement`, `AXLabelUIElements`, then the
    /// nearest static text in the same row (the parent, then the grandparent), preferring text
    /// to the left on the same line. Nil for a control that names itself or sits alone.
    var derivedLabel: DerivedLabel? {
        guard Self.rowLabelledRoles.contains(role), title.isEmpty else { return nil }
        if let titled = linkedElement(kAXTitleUIElementAttribute), let text = titled.spokenText {
            return DerivedLabel(text: text, sourceSignature: titled.signature)
        }
        if let labels = attribute("AXLabelUIElements") as? [AXUIElement],
           let first = labels.first.map(AXElement.init), let text = first.spokenText {
            return DerivedLabel(text: text, sourceSignature: first.signature)
        }
        guard let frame else { return nil }
        var container = parent
        for _ in 0 ..< ContextConstants.ancestorLevels {
            guard let current = container,
                  !["AXWindow", "AXSheet", "AXApplication", "AXScrollArea", "AXOutline", "AXTable"].contains(current.role)
            else { return nil }
            let texts = rowTexts(in: current)
            if let best = Self.nearestText(to: frame, among: texts.map { ($0.text, $0.frame) }) {
                return DerivedLabel(text: texts[best].text, sourceSignature: texts[best].signature)
            }
            container = current.parent
        }
        return nil
    }

    /// The static texts directly in `container` or one level into its children (a row's
    /// cells), with their frames. Bounded: a container with more children than a row has is
    /// skipped.
    private func rowTexts(in container: AXElement) -> [(text: String, frame: CGRect, signature: String)] {
        let children = container.children
        guard children.count <= ContextConstants.maxSiblings else { return [] }
        var found: [(String, CGRect, String)] = []
        for child in children where !CFEqual(child.raw, raw) {
            if child.role == "AXStaticText" {
                if let text = child.spokenText, let frame = child.frame { found.append((text, frame, child.signature)) }
            } else if ["AXCell", "AXGroup"].contains(child.role) {
                let grandchildren = child.children
                guard grandchildren.count <= ContextConstants.maxSiblings else { continue }
                for grandchild in grandchildren where grandchild.role == "AXStaticText" {
                    if let text = grandchild.spokenText, let frame = grandchild.frame {
                        found.append((text, frame, grandchild.signature))
                    }
                }
            }
        }
        return found
    }

    /// The text of a static-text element: its value, else its own name.
    private var spokenText: String? {
        let text = (value ?? "").isEmpty ? title : (value ?? "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func linkedElement(_ name: String) -> AXElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    /// Which of `texts` names a control at `frame`: text on the same line beats text above
    /// or below it, and on the same line, text to the left (where a row's title sits) beats
    /// text to the right. Nil when there is none. Pure, for the tests.
    static func nearestText(to frame: CGRect, among texts: [(text: String, frame: CGRect)]) -> Int? {
        func score(_ candidate: CGRect) -> Double {
            let sameLine = candidate.maxY > frame.minY && candidate.minY < frame.maxY
            let dx = candidate.midX < frame.midX ? frame.minX - candidate.maxX : candidate.minX - frame.maxX
            let dy = abs(candidate.midY - frame.midY)
            // Same-line text is always closer than any other line; leftward text gets a
            // head start over rightward text the same distance away.
            let lineRank = sameLine ? 0.0 : 100_000.0
            let sideRank = candidate.midX <= frame.midX ? 0.0 : 10_000.0
            return lineRank + sideRank + max(dx, 0) + dy
        }
        return texts.indices.min { score(texts[$0].frame) < score(texts[$1].frame) }
    }
}
