import Testing
@testable import Rocuronium

/// The pixel-region differ behind `screenshot --since`, exercised on synthetic bitmaps —
/// no capture, no CGImage.
struct FrameDiffTests {
    private let width = 200
    private let height = 200

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0 ..< width * height {
            bytes[pixel * 4] = r
            bytes[pixel * 4 + 1] = g
            bytes[pixel * 4 + 2] = b
        }
        return bytes
    }

    private func fill(
        _ bytes: inout [UInt8], x: Int, y: Int, w: Int, h: Int,
        _ r: UInt8, _ g: UInt8, _ b: UInt8
    ) {
        for row in y ..< min(y + h, height) {
            for column in x ..< min(x + w, width) {
                let offset = (row * width + column) * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
            }
        }
    }

    /// Structured content whose rows are individually distinctive — what scroll detection
    /// needs to correlate on.
    private func textured() -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let value = UInt8((x * 7 + y * 13) % 251)
                bytes[offset] = value
                bytes[offset + 1] = value &+ 40
                bytes[offset + 2] = value ^ 0x55
            }
        }
        return bytes
    }

    @Test func identicalFramesAreUnchanged() {
        let frame = textured()
        #expect(FrameDiff.analyze(before: frame, after: frame, width: width, height: height) == .unchanged)
    }

    @Test func mismatchedSizesRefuseToCompare() {
        let frame = solid(0, 0, 0)
        #expect(FrameDiff.analyze(before: frame, after: Array(frame.dropLast(4)), width: width, height: height) == nil)
        #expect(FrameDiff.analyze(before: frame, after: frame, width: width, height: height - 1) == nil)
    }

    /// Sub-tolerance drift everywhere — compression noise, a subtle shade — is no change.
    @Test func subNoiseDeltaIsIgnored() {
        let before = solid(100, 100, 100)
        let after = solid(105, 106, 104)
        #expect(FrameDiff.analyze(before: before, after: after, width: width, height: height) == .unchanged)
    }

    /// A few scattered hot pixels never make a region: below the per-cell floor they are
    /// speckle, not something worth a crop.
    @Test func scatteredSpecklesAreIgnored() {
        let before = solid(0, 0, 0)
        var after = before
        for (x, y) in [(10, 10), (90, 40), (150, 170)] {
            fill(&after, x: x, y: y, w: 1, h: 1, 255, 255, 255)
        }
        #expect(FrameDiff.analyze(before: before, after: after, width: width, height: height) == .unchanged)
    }

    @Test func singleBlockClustersIntoOneRegionContainingIt() throws {
        let before = solid(0, 0, 0)
        var after = before
        fill(&after, x: 60, y: 50, w: 40, h: 30, 255, 255, 255)
        let analysis = FrameDiff.analyze(before: before, after: after, width: width, height: height)
        guard case let .regions(regions, changedFraction)? = analysis else {
            Issue.record("expected regions, got \(String(describing: analysis))")
            return
        }
        #expect(regions.count == 1)
        let region = try #require(regions.first)
        #expect(region.x <= 60 && region.y <= 50)
        #expect(region.maxX >= 100 && region.maxY >= 80)
        // Tight, not the whole frame: the crop is the economy.
        #expect(region.width <= 40 + 2 * 16 + 8 && region.height <= 30 + 2 * 16 + 8)
        #expect(abs(changedFraction - Double(40 * 30) / Double(width * height)) < 0.005)
    }

    @Test func distantBlocksBecomeSeparateRegions() {
        let before = solid(0, 0, 0)
        var after = before
        fill(&after, x: 10, y: 10, w: 20, h: 20, 255, 255, 255)
        fill(&after, x: 150, y: 160, w: 30, h: 20, 255, 0, 0)
        guard case let .regions(regions, _)? = FrameDiff.analyze(before: before, after: after, width: width, height: height) else {
            Issue.record("expected regions")
            return
        }
        #expect(regions.count == 2)
        // Sorted top-to-bottom.
        #expect(regions[0].y < regions[1].y)
    }

    /// Two blocks a few pixels apart are one dialog, not two crops.
    @Test func nearbyBlocksMergeIntoOneRegion() {
        let before = solid(0, 0, 0)
        var after = before
        fill(&after, x: 40, y: 40, w: 30, h: 20, 255, 255, 255)
        fill(&after, x: 40, y: 68, w: 30, h: 20, 255, 255, 255)
        guard case let .regions(regions, _)? = FrameDiff.analyze(before: before, after: after, width: width, height: height) else {
            Issue.record("expected regions")
            return
        }
        #expect(regions.count == 1)
    }

    @Test func wholesaleChangeDegradesInsteadOfCropping() {
        let before = solid(0, 0, 0)
        let after = solid(255, 255, 255)
        guard case let .wholesale(changedFraction)? = FrameDiff.analyze(before: before, after: after, width: width, height: height) else {
            Issue.record("expected wholesale")
            return
        }
        #expect(changedFraction > 0.99)
    }

    /// The scroll case: the new frame is the old one translated up 24 px with fresh rows
    /// entering at the bottom — reported as a scroll plus the revealed strip, never as one
    /// giant changed region.
    @Test func verticalScrollIsDetectedWithItsMagnitude() {
        let scrolled = 24
        let before = textured()
        var after = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height - scrolled {
            let source = (y + scrolled) * width * 4
            let target = y * width * 4
            after.replaceSubrange(target ..< target + width * 4, with: before[source ..< source + width * 4])
        }
        for y in height - scrolled ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let value = UInt8((x * 11 + y * 3) % 200)
                after[offset] = value
                after[offset + 1] = 255 - value
                after[offset + 2] = value
            }
        }
        guard case let .scrolled(dy, revealed)? = FrameDiff.analyze(before: before, after: after, width: width, height: height) else {
            Issue.record("expected scrolled")
            return
        }
        #expect(dy == scrolled)
        #expect(revealed == FrameDiff.Region(x: 0, y: height - scrolled, width: width, height: scrolled))
    }

    /// Scrolling the other way reveals content at the top.
    @Test func upwardScrollRevealsTheTop() {
        let scrolled = 32
        let before = textured()
        var after = [UInt8](repeating: 255, count: width * height * 4)
        for y in scrolled ..< height {
            let source = (y - scrolled) * width * 4
            let target = y * width * 4
            after.replaceSubrange(target ..< target + width * 4, with: before[source ..< source + width * 4])
        }
        for y in 0 ..< scrolled {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                after[offset] = UInt8((x * 5 + y * 17) % 199)
            }
        }
        guard case let .scrolled(dy, revealed)? = FrameDiff.analyze(before: before, after: after, width: width, height: height) else {
            Issue.record("expected scrolled")
            return
        }
        #expect(dy == -scrolled)
        #expect(revealed == FrameDiff.Region(x: 0, y: 0, width: width, height: scrolled))
    }
}
