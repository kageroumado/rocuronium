import Foundation

/// Compares two same-sized frames and reports *where* they differ — the mechanism behind
/// `screenshot --since`. Where `ScreenDiff` answers "how much changed" for a verdict, this
/// answers "which rectangles changed" so the caller can read a 300×200 crop instead of the
/// frame.
///
/// Pure byte-buffer logic on the normalized RGBA layout `ScreenDiff.normalizedBytes`
/// produces — no CGImage, no capture — so it is unit-testable on synthetic bitmaps.
nonisolated enum FrameDiff {
    enum Constants {
        static let bytesPerPixel = ScreenDiff.Constants.bytesPerPixel
        /// Same per-channel calibration as the evidence diff: below it is compression
        /// noise, antialiasing, or a hover shade.
        static let channelTolerance = ScreenDiff.Constants.channelTolerance
        /// Changed pixels are accumulated per cell of this size, which is what makes
        /// clustering cheap and gives nearby changes a natural merge radius.
        static let cellSize = 16
        /// A cell with fewer meaningfully-changed pixels than this is speckle — a dithered
        /// gradient shimmering, a stray antialiased edge — not a changed region.
        static let minimumCellChangedPixels = 6
        /// A whole cluster below this many changed pixels is dropped for the same reason.
        static let minimumClusterChangedPixels = 24
        /// Clusters whose cells are within this many cells of each other merge: a dialog's
        /// text and its buttons should come back as one region, not confetti.
        static let mergeGapCells = 1
        /// Breathing room around each reported rect, so an edge antialiased just under
        /// tolerance is still inside its crop.
        static let regionPaddingPixels = 4
        /// Past either bound the reply degrades to the full frame: a diff that covers most
        /// of it (or shatters into a pile of crops) costs more than the truth.
        static let wholesaleAreaFraction = 0.5
        static let maximumRegions = 12
        /// Scroll detection: probe columns sampled per row, and the minimum displacement
        /// worth calling a scroll rather than jitter.
        static let scrollProbeColumns = 48
        static let minimumScrollPixels = 8
        /// Scrolls repaint most of the frame; small local change skips the row search.
        static let scrollAttemptFraction = 0.2
        /// Share of votable rows that must agree on one displacement, and the direct
        /// row-match fraction that displacement must then survive.
        static let scrollVoteFraction = 0.5
        static let scrollVerifyFraction = 0.75
        /// Per-sample tolerance when verifying a candidate displacement, in units of the
        /// r+2g+b probe luma (range 0…1020) — the channel tolerance scaled by that sum's
        /// four channel-weights.
        static let scrollSampleTolerance = channelTolerance * 4
        /// Fewer votable (non-flat) rows than this and row correlation is guesswork.
        static let minimumVotableRows = 20
    }

    /// A rectangle in pixel coordinates of the compared frames, top-left origin.
    struct Region: Equatable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        var maxX: Int { x + width }
        var maxY: Int { y + height }

        func intersects(_ other: Region) -> Bool {
            x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
        }
    }

    enum Analysis: Equatable, Sendable {
        /// Nothing above the noise floor moved.
        case unchanged
        /// The frame is the old frame translated vertically by `dy` pixels (positive:
        /// content moved up — the view scrolled toward the bottom). `revealed` is the edge
        /// strip of content that was not on screen before.
        case scrolled(dy: Int, revealed: Region)
        /// Localized change: the changed rectangles, nearby clusters merged.
        case regions([Region], changedFraction: Double)
        /// Too much of the frame changed for crops to be cheaper than the whole thing.
        case wholesale(changedFraction: Double)
    }

    /// Compares two frames in the normalized layout. Returns nil when the buffers cannot
    /// be compared (size mismatch) — the caller degrades honestly, never guesses.
    static func analyze(before: [UInt8], after: [UInt8], width: Int, height: Int) -> Analysis? {
        guard width > 0, height > 0,
              before.count == after.count,
              before.count == width * height * Constants.bytesPerPixel
        else { return nil }

        // One pass: count meaningfully-changed pixels, binned per cell.
        let cellsX = (width + Constants.cellSize - 1) / Constants.cellSize
        let cellsY = (height + Constants.cellSize - 1) / Constants.cellSize
        var cellCounts = [Int](repeating: 0, count: cellsX * cellsY)
        var changedPixels = 0
        before.withUnsafeBufferPointer { beforeBuffer in
            after.withUnsafeBufferPointer { afterBuffer in
                for y in 0 ..< height {
                    let rowBase = y * width * Constants.bytesPerPixel
                    let cellRow = (y / Constants.cellSize) * cellsX
                    for x in 0 ..< width {
                        let offset = rowBase + x * Constants.bytesPerPixel
                        // Alpha skipped, as in ScreenDiff: constant in captures.
                        let deltaRed = abs(Int(beforeBuffer[offset]) - Int(afterBuffer[offset]))
                        let deltaGreen = abs(Int(beforeBuffer[offset + 1]) - Int(afterBuffer[offset + 1]))
                        let deltaBlue = abs(Int(beforeBuffer[offset + 2]) - Int(afterBuffer[offset + 2]))
                        if max(deltaRed, max(deltaGreen, deltaBlue)) > Constants.channelTolerance {
                            changedPixels += 1
                            cellCounts[cellRow + x / Constants.cellSize] += 1
                        }
                    }
                }
            }
        }
        let changedFraction = Double(changedPixels) / Double(width * height)
        let changedCells = cellCounts.map { $0 >= Constants.minimumCellChangedPixels }
        guard changedCells.contains(true) else { return .unchanged }

        // Large-scale change is checked for translation before clustering: a scrolled
        // frame is "everything changed" to a pixel diff, but one number plus an edge
        // strip to the caller.
        if changedFraction >= Constants.scrollAttemptFraction,
           let dy = detectVerticalScroll(before: before, after: after, width: width, height: height) {
            let revealed = dy > 0
                ? Region(x: 0, y: height - dy, width: width, height: dy)
                : Region(x: 0, y: 0, width: width, height: -dy)
            return .scrolled(dy: dy, revealed: revealed)
        }

        let regions = cluster(
            cellCounts: cellCounts, cellsX: cellsX, cellsY: cellsY,
            width: width, height: height,
        )
        guard !regions.isEmpty else { return .unchanged }
        let regionArea = regions.reduce(0) { $0 + $1.width * $1.height }
        if regions.count > Constants.maximumRegions
            || Double(regionArea) / Double(width * height) > Constants.wholesaleAreaFraction {
            return .wholesale(changedFraction: changedFraction)
        }
        return .regions(regions, changedFraction: changedFraction)
    }

    // MARK: - Scroll detection

    /// Finds a vertical displacement `d` such that `after[y] ≈ before[y + d]` for most
    /// rows, by hashing downsampled row profiles and letting matching rows vote on their
    /// offset — O(rows) with a dictionary instead of O(rows × offsets) correlation.
    /// Flat rows (no horizontal variance) are excluded: a blank row matches every blank
    /// row and would vote for everything.
    private static func detectVerticalScroll(
        before: [UInt8], after: [UInt8], width: Int, height: Int
    ) -> Int? {
        let columns = min(Constants.scrollProbeColumns, width)
        let maxShift = height / 2
        let rowStep = max(1, height / 720)

        func profile(_ bytes: [UInt8], _ row: Int) -> [Int] {
            var samples = [Int](repeating: 0, count: columns)
            let rowBase = row * width * Constants.bytesPerPixel
            for k in 0 ..< columns {
                let x = (k * width + width / 2) / columns
                let offset = rowBase + min(x, width - 1) * Constants.bytesPerPixel
                samples[k] = Int(bytes[offset]) + 2 * Int(bytes[offset + 1]) + Int(bytes[offset + 2])
            }
            return samples
        }
        func isFlat(_ samples: [Int]) -> Bool {
            guard let low = samples.min(), let high = samples.max() else { return true }
            return high - low < 16
        }
        func quantizedHash(_ samples: [Int]) -> Int {
            var hasher = Hasher()
            for sample in samples { hasher.combine(sample >> 4) }
            return hasher.finalize()
        }

        // Rows of the old frame, indexed by profile hash. A hash matching too many rows is
        // repetitive texture (table stripes) and would flood the vote with false offsets.
        var oldRows: [Int: [Int]] = [:]
        for row in stride(from: 0, to: height, by: rowStep) {
            let samples = profile(before, row)
            guard !isFlat(samples) else { continue }
            oldRows[quantizedHash(samples), default: []].append(row)
        }

        var votes: [Int: Int] = [:]
        var votableRows = 0
        for row in stride(from: 0, to: height, by: rowStep) {
            let samples = profile(after, row)
            guard !isFlat(samples) else { continue }
            votableRows += 1
            guard let candidates = oldRows[quantizedHash(samples)], candidates.count <= 8 else { continue }
            for oldRow in candidates {
                let displacement = oldRow - row
                guard abs(displacement) >= Constants.minimumScrollPixels,
                      abs(displacement) <= maxShift else { continue }
                votes[displacement, default: 0] += 1
            }
        }
        guard votableRows >= Constants.minimumVotableRows,
              let (displacement, count) = votes.max(by: { $0.value < $1.value }),
              Double(count) >= Constants.scrollVoteFraction * Double(votableRows)
        else { return nil }

        // Direct verification at the winning displacement: hash votes can collide, and a
        // wrong scroll report would misdirect every follow-up read.
        var compared = 0
        var matched = 0
        for row in stride(from: 0, to: height, by: rowStep) {
            let oldRow = row + displacement
            guard oldRow >= 0, oldRow < height else { continue }
            let newSamples = profile(after, row)
            guard !isFlat(newSamples) else { continue }
            let oldSamples = profile(before, oldRow)
            compared += 1
            let agrees = zip(newSamples, oldSamples)
                .allSatisfy { abs($0 - $1) <= Constants.scrollSampleTolerance }
            if agrees { matched += 1 }
        }
        guard compared >= Constants.minimumVotableRows,
              Double(matched) >= Constants.scrollVerifyFraction * Double(compared)
        else { return nil }
        return displacement
    }

    // MARK: - Clustering

    /// Connected components over changed cells (with a one-cell merge gap), returned as
    /// padded pixel rectangles, overlaps merged, sorted top-to-bottom then left-to-right.
    private static func cluster(
        cellCounts: [Int], cellsX: Int, cellsY: Int, width: Int, height: Int
    ) -> [Region] {
        let gap = Constants.mergeGapCells + 1
        var componentOf = [Int](repeating: -1, count: cellsX * cellsY)
        var components: [(minX: Int, minY: Int, maxX: Int, maxY: Int, pixels: Int)] = []

        for start in 0 ..< cellCounts.count where cellCounts[start] >= Constants.minimumCellChangedPixels && componentOf[start] == -1 {
            let component = components.count
            var queue = [start]
            componentOf[start] = component
            var bounds = (minX: start % cellsX, minY: start / cellsX, maxX: start % cellsX, maxY: start / cellsX, pixels: 0)
            while let cell = queue.popLast() {
                let cellX = cell % cellsX
                let cellY = cell / cellsX
                bounds.minX = min(bounds.minX, cellX)
                bounds.minY = min(bounds.minY, cellY)
                bounds.maxX = max(bounds.maxX, cellX)
                bounds.maxY = max(bounds.maxY, cellY)
                bounds.pixels += cellCounts[cell]
                for dy in -gap ... gap {
                    for dx in -gap ... gap {
                        let nx = cellX + dx
                        let ny = cellY + dy
                        guard nx >= 0, nx < cellsX, ny >= 0, ny < cellsY else { continue }
                        let neighbor = ny * cellsX + nx
                        guard componentOf[neighbor] == -1,
                              cellCounts[neighbor] >= Constants.minimumCellChangedPixels else { continue }
                        componentOf[neighbor] = component
                        queue.append(neighbor)
                    }
                }
            }
            components.append(bounds)
        }

        var regions: [Region] = components
            .filter { $0.pixels >= Constants.minimumClusterChangedPixels }
            .map { bounds in
                let x = max(0, bounds.minX * Constants.cellSize - Constants.regionPaddingPixels)
                let y = max(0, bounds.minY * Constants.cellSize - Constants.regionPaddingPixels)
                let maxX = min(width, (bounds.maxX + 1) * Constants.cellSize + Constants.regionPaddingPixels)
                let maxY = min(height, (bounds.maxY + 1) * Constants.cellSize + Constants.regionPaddingPixels)
                return Region(x: x, y: y, width: maxX - x, height: maxY - y)
            }

        // Padding can make disjoint clusters overlap; merge to a fixed point so no two
        // reported crops cover the same pixels.
        var merged = true
        while merged {
            merged = false
            outer: for i in regions.indices {
                for j in regions.indices where j > i {
                    guard regions[i].intersects(regions[j]) else { continue }
                    let a = regions[i]
                    let b = regions[j]
                    let x = min(a.x, b.x)
                    let y = min(a.y, b.y)
                    regions[i] = Region(
                        x: x, y: y,
                        width: max(a.maxX, b.maxX) - x,
                        height: max(a.maxY, b.maxY) - y,
                    )
                    regions.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return regions.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}
