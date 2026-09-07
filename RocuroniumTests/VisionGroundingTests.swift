import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import Rocuronium

struct VisionGroundingTests {
    // MARK: - Tokenizer config normalization

    /// The `pipenetwork/Holo-3.1-4B-MLX-4bit` download ships
    /// `tokenizer_class: "TokenizersBackend"`, which swift-transformers cannot map. The load
    /// path rewrites it to `Qwen2Tokenizer` (Holo is Qwen3.5-VL) while preserving every other
    /// field.
    @Test func normalizeRewritesBogusTokenizerClass() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "holo-norm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "tokenizer_config.json")
        try #"{"tokenizer_class":"TokenizersBackend","backend":"tokenizers","eos_token":"<|im_end|>"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        MLXBackend.normalizeTokenizerConfig(in: dir)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["tokenizer_class"] as? String == "Qwen2Tokenizer")
        #expect(obj?["backend"] as? String == "tokenizers")
        #expect(obj?["eos_token"] as? String == "<|im_end|>")
    }

    /// A file already naming a mappable class is left byte-for-byte alone, so a correct
    /// download (or a future upstream fix) is never rewritten.
    @Test func normalizeLeavesMappableClassUntouched() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "holo-norm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "tokenizer_config.json")
        let original = #"{"tokenizer_class":"Qwen2Tokenizer"}"#
        try original.write(to: url, atomically: true, encoding: .utf8)

        MLXBackend.normalizeTokenizerConfig(in: dir)

        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    // MARK: - Chat template patch

    /// johnmai-dev/Jinja evaluates `messages[::-1]` to an empty array, so Qwen3-VL's
    /// reversed query-detection loop raises "No user query found in messages." The load path
    /// rewrites the slice to the `reverse` filter, which the engine supports.
    @Test func patchRewritesReversedSlice() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "holo-tmpl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "chat_template.jinja")
        try "{%- for message in messages[::-1] %}{{ message.role }}{%- endfor %}"
            .write(to: url, atomically: true, encoding: .utf8)

        MLXBackend.patchChatTemplate(in: dir)

        let patched = try String(contentsOf: url, encoding: .utf8)
        #expect(!patched.contains("messages[::-1]"))
        #expect(patched.contains("messages | reverse"))
    }

    // MARK: - End-to-end grounding

    /// The full Swift grounding path — tokenizer load, chat-template application, model
    /// inference, coordinate parse — against the installed Holo weights. Runs only when the
    /// model is present. The image is synthesized (a single obvious button on white) so the
    /// test ships no captured screen content; a non-empty, in-bounds result confirms the three
    /// glue faults are gone and the model returns a parseable `Click(x, y)`.
    @Test(.enabled(if: MLXBackend().isAvailable))
    func locateGroundsWithInstalledModel() async throws {
        let image = Self.buttonOnWhite()

        let candidates = try await MLXBackend().locate(
            "the Submit button", in: image)

        let best = try #require(candidates.first)
        #expect(best.rect.midX >= 0 && best.rect.midX <= CGFloat(image.width))
        #expect(best.rect.midY >= 0 && best.rect.midY <= CGFloat(image.height))
    }

    /// A 1000×700 white canvas with one dark rounded "Submit" button centered — a target any
    /// GUI-grounding model resolves, carrying no real screen content.
    private static func buttonOnWhite() -> CGImage {
        let width = 1000
        let height = 700
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let button = CGRect(x: 410, y: 320, width: 180, height: 60)
        context.setFillColor(CGColor(red: 0.15, green: 0.17, blue: 0.2, alpha: 1))
        context.addPath(CGPath(roundedRect: button, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()

        let label = "Submit" as CFString
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil),
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, label, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(
            x: button.midX - bounds.width / 2, y: button.midY - bounds.height / 2)
        CTLineDraw(line, context)

        return context.makeImage()!
    }
}
