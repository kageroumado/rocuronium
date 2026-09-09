import Foundation
import Testing
@testable import Rocuronium

/// The three checks that decide what runs with the app's grants: which binaries may drive the
/// socket or be spawned, which processes may be targeted, and which model bytes are installed.
struct TrustBoundaryTests {
    // MARK: - CodeIdentity

    @Test func requirementNamesTeamAndEveryIdentifier() {
        let requirement = CodeIdentity.requirement(identifiers: ["rocuronium", "glass.kagerou.rocuronium"])
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "52K336H235""#))
        #expect(requirement.contains(#"identifier "rocuronium""#))
        #expect(requirement.contains(#"identifier "glass.kagerou.rocuronium""#))
        #expect(requirement.hasPrefix("anchor apple generic and "))
    }

    @Test func appleSignedSystemBinaryIsNotTrusted() {
        // Validly signed, Apple-anchored, and still not ours: the team clause must hold.
        #expect(!CodeIdentity.isTrusted(executableAt: "/bin/ls", identifiers: ["ls", "adrafinil"]))
    }

    @Test func missingFileIsNotTrusted() {
        #expect(!CodeIdentity.isTrusted(executableAt: "/nonexistent/adrafinil", identifiers: ["adrafinil"]))
    }

    @Test func teamSignedBinaryWithForeignIdentifierIsNotTrusted() throws {
        // Our own CLI, checked under an identifier it does not carry: team alone is not enough.
        let cli = "/Applications/Rocuronium.app/Contents/Resources/rocuronium"
        try #require(FileManager.default.isExecutableFile(atPath: cli), "installed bundle absent — skipped")
        #expect(CodeIdentity.isTrusted(executableAt: cli, identifiers: ["rocuronium"]))
        #expect(!CodeIdentity.isTrusted(executableAt: cli, identifiers: ["adrafinil"]))
    }

    @Test func unsignedCopyOfTrustedBinaryIsNotTrusted() throws {
        // The same bytes minus the signature: what a planted file at the expected path is.
        let cli = "/Applications/Rocuronium.app/Contents/Resources/rocuronium"
        try #require(FileManager.default.isExecutableFile(atPath: cli), "installed bundle absent — skipped")
        let copy = FileManager.default.temporaryDirectory.appending(path: "rocuronium-\(UUID().uuidString)")
        try FileManager.default.copyItem(atPath: cli, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: copy) }
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        strip.arguments = ["--remove-signature", copy.path]
        strip.standardError = FileHandle.nullDevice
        try strip.run()
        strip.waitUntilExit()
        try #require(strip.terminationStatus == 0)
        #expect(!CodeIdentity.isTrusted(executableAt: copy.path, identifiers: ["rocuronium"]))
    }

    // MARK: - Credential surfaces

    @Test func lockScreenProcessesAreRefused() {
        for bundle in ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine"] {
            #expect(CommandRouter.isCredentialSurface(bundleIdentifier: bundle))
        }
    }

    @Test func ordinaryAppsAreNotRefused() {
        #expect(!CommandRouter.isCredentialSurface(bundleIdentifier: "com.apple.Safari"))
        #expect(!CommandRouter.isCredentialSurface(bundleIdentifier: "com.apple.finder"))
        #expect(!CommandRouter.isCredentialSurface(bundleIdentifier: nil))
    }

    // MARK: - ModelStore

    @Test func knownModelsArePinnedToCommits() {
        let ids = ModelStore.known.map(\.id)
        #expect(Set(ids).count == ids.count)
        for descriptor in ModelStore.known {
            #expect(descriptor.revision.count == 40, "\(descriptor.id): revision must be a full commit hash, not a branch")
            #expect(descriptor.revision.allSatisfy { $0.isHexDigit })
            #expect(!descriptor.files.isEmpty)
            for file in descriptor.files {
                #expect(file.sha256.count == 64, "\(descriptor.id)/\(file.path): digest is not SHA-256 hex")
                #expect(file.bytes > 0)
            }
        }
    }

    @Test func sha256MatchesKnownVector() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "abc-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = try ModelStore.sha256(of: url)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func verifyAcceptsPinnedBytesAndRefusesEverythingElse() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("abc".utf8).write(to: directory.appending(path: "nested/weights.bin"))

        let good = descriptor(files: [
            ModelStore.PinnedFile(path: "nested/weights.bin", bytes: 3,
                                  sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ])
        #expect(throws: Never.self) { try ModelStore.verify(good, in: directory) }

        let wrongDigest = descriptor(files: [
            ModelStore.PinnedFile(path: "nested/weights.bin", bytes: 3, sha256: String(repeating: "0", count: 64)),
        ])
        #expect(throws: ModelStore.VerificationError.digestMismatch(
            "nested/weights.bin", expected: String(repeating: "0", count: 64),
            actual: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        )) { try ModelStore.verify(wrongDigest, in: directory) }

        let wrongSize = descriptor(files: [
            ModelStore.PinnedFile(path: "nested/weights.bin", bytes: 4,
                                  sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ])
        #expect(throws: ModelStore.VerificationError.sizeMismatch("nested/weights.bin", expected: 4, actual: 3)) {
            try ModelStore.verify(wrongSize, in: directory)
        }

        let missing = descriptor(files: [
            ModelStore.PinnedFile(path: "absent.bin", bytes: 3, sha256: String(repeating: "0", count: 64)),
        ])
        #expect(throws: ModelStore.VerificationError.missing("absent.bin")) {
            try ModelStore.verify(missing, in: directory)
        }
    }

    private func descriptor(files: [ModelStore.PinnedFile]) -> ModelStore.Descriptor {
        ModelStore.Descriptor(
            id: "test", displayName: "Test", detail: "", icon: "circle", license: "none",
            repo: "example/test", revision: String(repeating: "a", count: 40), files: files,
        )
    }
}
