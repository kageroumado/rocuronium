import CoreGraphics
import Foundation

/// Compares two captures of the same region and reports how much of it changed.
///
/// This is the cheap tier of verification, and it covers most of the question an agent
/// actually asks: *did my click do anything at all?* No model is required, it costs
/// milliseconds, and it works on interfaces that expose nothing useful through accessibility.
/// A model is only needed for the harder question — did the **right** thing happen.
nonisolated enum ScreenDiff {
    private enum Constants {
        /// Per-channel difference below this is compression noise, antialiasing, or a subtle
        /// hover shade — not evidence that anything happened.
        static let channelTolerance = 12
        static let bytesPerPixel = 4
    }

    /// Fraction of pixels that differ meaningfully, in 0...1.
    ///
    /// Returns nil when the two images cannot be compared (different sizes, unreadable data),
    /// which the verifier must treat as `unverifiable` rather than as "no change".
    static func changedFraction(from before: CGImage, to after: CGImage) -> Double? {
        guard before.width == after.width, before.height == after.height,
              before.width > 0, before.height > 0
        else { return nil }

        guard let beforeBytes = normalizedBytes(of: before),
              let afterBytes = normalizedBytes(of: after),
              beforeBytes.count == afterBytes.count
        else { return nil }

        var changed = 0
        let pixelCount = beforeBytes.count / Constants.bytesPerPixel
        for pixel in 0 ..< pixelCount {
            let offset = pixel * Constants.bytesPerPixel
            // Alpha is skipped: it is constant in screen captures and only adds noise.
            let deltaRed = abs(Int(beforeBytes[offset]) - Int(afterBytes[offset]))
            let deltaGreen = abs(Int(beforeBytes[offset + 1]) - Int(afterBytes[offset + 1]))
            let deltaBlue = abs(Int(beforeBytes[offset + 2]) - Int(afterBytes[offset + 2]))
            if max(deltaRed, max(deltaGreen, deltaBlue)) > Constants.channelTolerance {
                changed += 1
            }
        }
        return Double(changed) / Double(pixelCount)
    }

    /// Redraws into a known layout so two captures are byte-comparable regardless of the
    /// color space or alpha layout each arrived in.
    private static func normalizedBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * Constants.bytesPerPixel)
        let context = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * Constants.bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            )
        }
        guard let context else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
