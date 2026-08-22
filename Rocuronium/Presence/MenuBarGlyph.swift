import AppKit

/// The menu bar jellyfish, drawn as a template image so it follows the menu bar's tint.
///
/// Template images are monochrome, so state is carried by fill and weight, not color:
/// idle is a stroked bell, driving is filled with heavier tentacles. The proportions are
/// deliberately narrower than the prototype's 17 px sketch — at menu bar size a wide bell
/// over short strokes reads as a mushroom, so the bell is kept slim and the tentacles long.
@MainActor
enum MenuBarGlyph {
    static let idle = make(driving: false)
    static let driving = make(driving: true)

    private static func make(driving: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let bell = NSBezierPath()
            bell.move(to: NSPoint(x: 4.9, y: 7.9))
            bell.curve(to: NSPoint(x: 9, y: 1.6),
                       controlPoint1: NSPoint(x: 4.9, y: 3.6),
                       controlPoint2: NSPoint(x: 6.4, y: 1.6))
            bell.curve(to: NSPoint(x: 13.1, y: 7.9),
                       controlPoint1: NSPoint(x: 11.6, y: 1.6),
                       controlPoint2: NSPoint(x: 13.1, y: 3.6))
            // A gentle scallop across the bottom, so the silhouette says bell, not cap.
            bell.curve(to: NSPoint(x: 4.9, y: 7.9),
                       controlPoint1: NSPoint(x: 10.6, y: 9.1),
                       controlPoint2: NSPoint(x: 7.4, y: 9.1))
            bell.close()
            if driving {
                bell.fill()
            } else {
                bell.lineWidth = 1.2
                bell.stroke()
            }

            let tentacleXs: [CGFloat] = [6.1, 8.1, 10.1, 12.1]
            for (index, x) in tentacleXs.enumerated() {
                // Alternate the sway so the strokes read as drifting, not as prongs.
                let sway: CGFloat = index.isMultiple(of: 2) ? -0.9 : 0.9
                let tentacle = NSBezierPath()
                tentacle.move(to: NSPoint(x: x, y: 9.6))
                tentacle.curve(to: NSPoint(x: x + sway * 0.4, y: 16.8),
                               controlPoint1: NSPoint(x: x - sway, y: 12.0),
                               controlPoint2: NSPoint(x: x + sway, y: 14.4))
                tentacle.lineWidth = driving ? 1.5 : 1.2
                tentacle.lineCapStyle = .round
                tentacle.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
