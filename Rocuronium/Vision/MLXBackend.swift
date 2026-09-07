import CoreGraphics
import Foundation
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

actor MLXBackend: GroundingBackend {
    nonisolated let identifier = "holo-3.1-4b"

    nonisolated var isAvailable: Bool { ModelStore.isInstalled("holo-3.1-4b") }

    private var container: ModelContainer?
    private var lastUsed: ContinuousClock.Instant?
    private var evictionTask: Task<Void, Never>?

    private enum Constants {
        static let maxPixels = 1_003_520
        static let patchBoundary = 28
        static let maxTokens = 40
        static let evictionTimeout: Duration = .seconds(300)
        static let systemPrompt = "You are Holo, a GUI grounding agent for computer-use automation. Given a screenshot and a task, locate the correct UI element and call the appropriate tool."
        static let promptTemplate = "Localize the element and output Click(x, y) with coordinates in [0, 1000] normalized space.\nFind: %@"
    }

    // MARK: - GroundingBackend

    func locate(_ description: String, in image: CGImage) async throws -> [GroundingCandidate] {
        let container = try await ensureLoaded()
        let resizedURL = try prepareImage(image)
        defer { try? FileManager.default.removeItem(at: resizedURL) }

        let prompt = String(format: Constants.promptTemplate, description)
        let userInput = UserInput(
            chat: [
                .system(Constants.systemPrompt),
                .user(prompt, images: [.url(resizedURL)]),
            ]
        )

        let lmInput = try await container.prepare(input: userInput)
        var params = GenerateParameters(temperature: 0)
        params.maxTokens = Constants.maxTokens
        var output = ""
        for await generation in try await container.generate(input: lmInput, parameters: params) {
            if case let .chunk(text) = generation { output += text }
        }

        touchTimer()

        guard let (nx, ny) = parseNormalized(output) else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty output is "the model saw nothing to click" — a legitimate empty result. Text
            // that named no coordinates is a parse miss worth surfacing, with a snippet, rather
            // than silently reading as "nothing there".
            if trimmed.isEmpty { return [] }
            throw GroundingError.unparsableOutput(String(trimmed.prefix(200)))
        }
        let absX = nx / 1000.0 * Double(image.width)
        let absY = ny / 1000.0 * Double(image.height)
        let rect = CGRect(x: absX - 5, y: absY - 5, width: 10, height: 10)

        return [GroundingCandidate(
            rect: rect,
            confidence: 1.0,
            describedAs: "Click(\(Int(nx)), \(Int(ny)))"
        )]
    }

    func judge(intent: String, before: CGImage, after: CGImage) async throws -> GroundingJudgement {
        GroundingJudgement(happened: false, confidence: 0, explanation: "deferred to caller")
    }

    // MARK: - Lifecycle

    func warmUp() async throws {
        _ = try await ensureLoaded()
    }

    func evict() {
        evictionTask?.cancel()
        evictionTask = nil
        container = nil
        Memory.clearCache()
        lastUsed = nil
    }

    var isLoaded: Bool { container != nil }

    // MARK: - Internals

    private func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }

        let modelDir = ModelStore.directory(for: "holo-3.1-4b")
        guard FileManager.default.fileExists(atPath: modelDir.appending(path: ModelStore.Constants.manifestName).path)
        else {
            throw GroundingError.modelNotInstalled(
                "The VLM is not installed. Run `rocuronium setup` to download Holo-3.1-4B (~3.7 GB)."
            )
        }

        let tokenizer = LocalTokenizerLoader()
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: tokenizer
        )
        container = loaded
        touchTimer()
        return loaded
    }

    private func touchTimer() {
        lastUsed = .now
        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            try? await Task.sleep(for: Constants.evictionTimeout)
            guard let self, !Task.isCancelled else { return }
            let elapsed = ContinuousClock.now - (await self.lastUsed ?? .now)
            if elapsed >= Constants.evictionTimeout {
                await self.evict()
            }
        }
    }

    // MARK: - Image preprocessing

    private func prepareImage(_ image: CGImage) throws -> URL {
        let w = image.width
        let h = image.height
        let totalPixels = w * h

        var nw = w
        var nh = h
        if totalPixels > Constants.maxPixels {
            let scale = sqrt(Double(Constants.maxPixels) / Double(totalPixels))
            nw = (Int(Double(w) * scale) / Constants.patchBoundary) * Constants.patchBoundary
            nh = (Int(Double(h) * scale) / Constants.patchBoundary) * Constants.patchBoundary
        }

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: nw, height: nh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw GroundingError.imagePreprocessingFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))

        guard let resized = ctx.makeImage() else {
            throw GroundingError.imagePreprocessingFailed
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appending(path: "rocuronium-vlm-input.png")
        guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, "public.png" as CFString, 1, nil)
        else { throw GroundingError.imagePreprocessingFailed }
        CGImageDestinationAddImage(dest, resized, nil)
        guard CGImageDestinationFinalize(dest) else { throw GroundingError.imagePreprocessingFailed }

        return tmpURL
    }

    // MARK: - Coordinate parsing

    private func parseNormalized(_ output: String) -> (Double, Double)? {
        let pattern = #"(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)"#
        guard let match = output.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(output[match])
        let parts = matched.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else { return nil }
        guard x >= 0, x <= 1000, y >= 0, y <= 1000 else { return nil }
        return (x, y)
    }
}

private struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum GroundingError: LocalizedError {
    case modelNotInstalled(String)
    case imagePreprocessingFailed
    case screenRecordingRequired
    case unparsableOutput(String)

    var errorDescription: String? {
        switch self {
        case let .modelNotInstalled(message): message
        case .imagePreprocessingFailed: "Failed to preprocess the image for the VLM."
        case .screenRecordingRequired: "Screen Recording permission is required for vision grounding."
        case let .unparsableOutput(snippet): "The VLM returned output that named no coordinates: \"\(snippet)\""
        }
    }
}
