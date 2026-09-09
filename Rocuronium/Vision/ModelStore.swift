import CryptoKit
import Foundation
import Hub

/// Where local weights live, and the rules that keep them from becoming a liability.
///
/// Models are **never** bundled in the app: a multi-gigabyte `.app` cannot be notarized
/// sensibly, cannot ship as a homebrew cask, and would make every user pay for a feature most
/// will not enable. They are downloaded on explicit request, pinned to a commit and checked
/// file by file against the digests recorded here, and disposable — deleting a model directory
/// degrades the app, it does not break it.
///
/// Verification runs on the download cache before anything is copied into place, and only the
/// pinned files are copied. Installed files are not re-verified afterwards: `MLXBackend` patches
/// the tokenizer config and chat template in place at load time, so the manifest's `verified`
/// flag and revision are the record that the bytes were checked at install.
nonisolated enum ModelStore {
    enum Constants {
        static let bundleIdentifier = "glass.kagerou.rocuronium"
        static let manifestName = "manifest.json"
        static let hashChunkBytes = 4 << 20
    }

    /// One file of a model, as it exists at the pinned revision.
    struct PinnedFile: Sendable, Hashable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    /// A model the app knows how to fetch. Size and license are surfaced in the UI before any
    /// download starts — a several-gigabyte fetch is never implicit.
    struct Descriptor: Identifiable, Sendable {
        let id: String
        let displayName: String
        let detail: String
        let icon: String
        let license: String
        let repo: String
        /// A commit hash, never a branch: what `main` points at can change under every user.
        let revision: String
        let files: [PinnedFile]

        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    }

    /// What an installed model directory records about itself.
    struct Manifest: Codable, Sendable {
        var source: String
        var revision: String?
        var verified: Bool?
        var downloadedAt: String
    }

    /// Both Apache-2.0 and runnable on Apple silicon. Digests were taken from the files at the
    /// pinned commit; a repo update that changes a file changes the pin here, deliberately.
    static let known: [Descriptor] = [
        Descriptor(
            id: "holo-3.1-4b",
            displayName: "Holo 3.1 4B",
            detail: "GUI grounding VLM — finds UI elements by description when accessibility is empty. "
                + "~3 seconds per query on Apple silicon.",
            icon: "eye.fill",
            license: "Apache-2.0",
            repo: "pipenetwork/Holo-3.1-4B-MLX-4bit",
            revision: "7c3327a5765ab21cefe2d91e953d1038b1d3ef3e",
            files: [
                PinnedFile(path: "chat_template.jinja", bytes: 7756,
                           sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                PinnedFile(path: "config.json", bytes: 3533,
                           sha256: "566798011e63a44255ef48add53620ff1da0ca9f2bb605930009fc5bbc5969f5"),
                PinnedFile(path: "generation_config.json", bytes: 213,
                           sha256: "a219dff6ed1d52d8a88fe50026de36ebcbcb913cbac0e70fdfaecf380949d7f1"),
                PinnedFile(path: "model.safetensors", bytes: 3_966_047_789,
                           sha256: "b2f1d58281865fdb1810ff93197b176702f38ad2fc925ebcd7af569a3ae485df"),
                PinnedFile(path: "model.safetensors.index.json", bytes: 101_944,
                           sha256: "e8ec3ed61bf79fba2d6e2a19fa28a379774352536d27b3a57b73dfdf70b787c1"),
                PinnedFile(path: "preprocessor_config.json", bytes: 390,
                           sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
                PinnedFile(path: "processor_config.json", bytes: 991,
                           sha256: "45fc17c8dd2474af6b493b52483c26c0584b0082d368c480f9fa611e73070040"),
                PinnedFile(path: "tokenizer.json", bytes: 19_989_343,
                           sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                PinnedFile(path: "tokenizer_config.json", bytes: 1139,
                           sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
                PinnedFile(path: "video_preprocessor_config.json", bytes: 385,
                           sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
                PinnedFile(path: "vocab.json", bytes: 6_722_759,
                           sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
            ],
        ),
        Descriptor(
            id: "yolo-detector",
            displayName: "UI Detector",
            detail: "Fast element detector — proposes control boxes in ~8 ms, so icon toolbars "
                + "become addressable. Each box is labeled from the text inside it; matched "
                + "before the VLM is loaded.",
            icon: "square.dashed",
            license: "Apache-2.0",
            repo: "kageroumado/rocuronium-ui-detector",
            revision: "ea555c1812c04761211b39c60ba9e24dffb648b3",
            files: [
                PinnedFile(path: "model.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 165_190,
                           sha256: "491ed685d1004551e09dc8218095fd4078cf27b0159b619b543caf2eb70813dc"),
                PinnedFile(path: "model.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 5_226_400,
                           sha256: "5c0a5bca16565b9447196a70c8394a197cc4ca9f28a1a6da37bd6b15a5397177"),
                PinnedFile(path: "model.mlpackage/Manifest.json", bytes: 617,
                           sha256: "98adefe93c973763d68ccab872fda6ee56bfddba109b213f775235eb7dfc9429"),
            ],
        ),
    ]

    static func descriptor(for modelID: String) -> Descriptor? {
        known.first { $0.id == modelID }
    }

    /// `~/Library/Application Support/glass.kagerou.rocuronium/Models`
    static var root: URL {
        URL.applicationSupportDirectory
            .appending(path: Constants.bundleIdentifier)
            .appending(path: "Models")
    }

    static func directory(for modelID: String) -> URL {
        root.appending(path: modelID)
    }

    static func isInstalled(_ modelID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(for: modelID).appending(path: Constants.manifestName).path,
        )
    }

    static func manifest(for modelID: String) -> Manifest? {
        guard let data = try? Data(contentsOf: directory(for: modelID).appending(path: Constants.manifestName))
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Installed from the pinned revision with every file's digest checked at install.
    static func isVerified(_ modelID: String) -> Bool {
        guard let descriptor = descriptor(for: modelID), let manifest = manifest(for: modelID) else { return false }
        return manifest.verified == true && manifest.revision == descriptor.revision
    }

    static func installedBytes() -> Int64 {
        guard let entries = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, entry in
            let path = root.appending(path: entry).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            total += size
        }
    }

    static func evict(_ modelID: String) throws {
        try FileManager.default.removeItem(at: directory(for: modelID))
    }

    // MARK: - Install

    /// Downloads the pinned revision, verifies every pinned file in the download cache, then
    /// copies those files — and nothing else — into the model directory. A mismatch throws
    /// before a byte lands in place; the cache is left for the next attempt to reuse.
    static func install(
        _ descriptor: Descriptor,
        progress: @escaping @Sendable (Double) -> Void,
        verifying: @escaping @Sendable () -> Void,
    ) async throws {
        let cache = try await HubApi().snapshot(
            from: descriptor.repo,
            revision: descriptor.revision,
            matching: descriptor.files.map(\.path),
        ) { progress($0.fractionCompleted) }

        verifying()
        try verify(descriptor, in: cache)

        let manager = FileManager.default
        let staging = root.appending(path: ".staging-\(descriptor.id)-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in descriptor.files {
                let target = staging.appending(path: file.path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: cache.appending(path: file.path), to: target)
            }
            let manifest = Manifest(
                source: descriptor.repo,
                revision: descriptor.revision,
                verified: true,
                downloadedAt: ISO8601DateFormatter().string(from: .now),
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: staging.appending(path: Constants.manifestName))

            let destination = directory(for: descriptor.id)
            if manager.fileExists(atPath: destination.path) {
                try manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Every pinned file present, at its size, with its digest.
    static func verify(_ descriptor: Descriptor, in directory: URL) throws {
        for file in descriptor.files {
            let url = directory.appending(path: file.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else { throw VerificationError.missing(file.path) }
            guard size == file.bytes else {
                throw VerificationError.sizeMismatch(file.path, expected: file.bytes, actual: size)
            }
            let digest = try sha256(of: url)
            guard digest == file.sha256 else {
                throw VerificationError.digestMismatch(file.path, expected: file.sha256, actual: digest)
            }
        }
    }

    /// Streaming, so a 4 GB weights file never sits in memory whole.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Constants.hashChunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum VerificationError: LocalizedError, Equatable {
        case missing(String)
        case sizeMismatch(String, expected: Int64, actual: Int64)
        case digestMismatch(String, expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case let .missing(path):
                "\(path) is missing from the download."
            case let .sizeMismatch(path, expected, actual):
                "\(path) is \(actual) bytes; the pinned revision has \(expected). The download was not installed."
            case let .digestMismatch(path, expected, actual):
                "\(path) does not match the pinned digest (got \(actual.prefix(12))…, pinned \(expected.prefix(12))…). "
                    + "The download was not installed."
            }
        }
    }
}
