import CoreGraphics
import Foundation

/// Holds the most recent capture per screenshot target, so `screenshot --since <token>`
/// has a frame to diff against. Owned by `CommandRouter`; the socket serializes requests,
/// so main-actor isolation is all the protection this state needs.
///
/// Frames are stored as `ScreenDiff.normalizedBytes` output rather than as images: the
/// stored side of a diff then never needs re-decoding, and the memory cost is exact and
/// boundable. Raw RGBA is big — one 5K display frame is ~56 MB — so the store keeps one
/// frame per target and evicts by LRU under a byte budget rather than by count.
@MainActor
final class FrameStore {
    struct Frame {
        let token: String
        /// The capture target ("app:<pid>", "rect:…", "display:main"). A token only diffs
        /// against a capture of the same target — same-sized pixels of a different window
        /// would produce a confident, wrong answer.
        let key: String
        /// Normalized RGBA, `pixelWidth * pixelHeight * 4` bytes.
        let bytes: [UInt8]
        let pixelWidth: Int
        let pixelHeight: Int
        /// Pixels per point of the captured surface, for mapping diff rectangles back to
        /// the screen coordinates every other verb speaks.
        let scale: Double
        /// Top-left of the captured rect in global screen points.
        let origin: CGPoint
    }

    private enum Constants {
        /// Roughly three window frames or two full display frames. Past it the oldest
        /// target's frame goes — bounded memory beats a longer diff history.
        static let byteBudget = 160 * 1024 * 1024
    }

    private var frames: [String: Frame] = [:]
    /// Token order, oldest first — the eviction order.
    private var order: [String] = []

    /// Stores a capture and returns its observation token. Any previous frame for the same
    /// target is replaced: one frame per target is the contract, and the newest is the
    /// only one the next `--since` can honestly want.
    func store(key: String, bytes: [UInt8], pixelWidth: Int, pixelHeight: Int, scale: Double, origin: CGPoint) -> String {
        for stale in order where frames[stale]?.key == key {
            evict(stale)
        }
        let token = "px-\(UUID().uuidString.prefix(8).lowercased())"
        frames[token] = Frame(
            token: token, key: key, bytes: bytes,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            scale: scale, origin: origin,
        )
        order.append(token)
        while totalBytes > Constants.byteBudget, order.count > 1 {
            evict(order.first!)
        }
        return token
    }

    func frame(for token: String) -> Frame? {
        frames[token]
    }

    private var totalBytes: Int {
        frames.values.reduce(0) { $0 + $1.bytes.count }
    }

    private func evict(_ token: String) {
        frames[token] = nil
        if let index = order.firstIndex(of: token) { order.remove(at: index) }
    }
}
