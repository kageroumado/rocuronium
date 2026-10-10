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

    /// The signed CLI inside the installed bundle. Tests that need real signed bytes are
    /// skipped where it is absent (a CI runner), since nothing else on a clean machine
    /// carries the team's signature.
    private static let installedCLI = "/Applications/Rocuronium.app/Contents/Resources/rocuronium"
    private static let installedBundlePresent = FileManager.default.isExecutableFile(atPath: installedCLI)

    @Test(.enabled(if: installedBundlePresent, "installed bundle absent"))
    func teamSignedBinaryWithForeignIdentifierIsNotTrusted() {
        // Our own CLI, checked under an identifier it does not carry: team alone is not enough.
        let cli = Self.installedCLI
        #expect(CodeIdentity.isTrusted(executableAt: cli, identifiers: ["rocuronium"]))
        #expect(!CodeIdentity.isTrusted(executableAt: cli, identifiers: ["adrafinil"]))
    }

    @Test(.enabled(if: installedBundlePresent, "installed bundle absent"))
    func unsignedCopyOfTrustedBinaryIsNotTrusted() throws {
        // The same bytes minus the signature: what a planted file at the expected path is.
        let cli = Self.installedCLI
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

    // MARK: - CodeIdentity: running peers

    @Test func testHostIsNotATrustedPeer() throws {
        // A real audit token for a live process that is not one of ours.
        let token = try #require(Self.auditToken(of: getpid()))
        #expect(!CodeIdentity.isTrusted(auditToken: token, identifiers: ["rocuronium", "glass.kagerou.rocuronium"]))
    }

    @Test(.enabled(if: installedBundlePresent, "installed bundle absent"))
    func runningSignedCLIIsTrustedOnlyUnderItsTeamAndIdentifier() throws {
        let peer = try RunningPeer(executable: Self.installedCLI)
        defer { peer.stop() }
        #expect(CodeIdentity.isTrusted(auditToken: peer.token, identifiers: ["rocuronium"]))
        #expect(!CodeIdentity.isTrusted(auditToken: peer.token, identifiers: ["adrafinil"]))
        #expect(!CodeIdentity.isTrusted(auditToken: peer.token, team: "ZZZZZZZZZZ", identifiers: ["rocuronium"]))
    }

    /// The reinstall case: a long-lived MCP server whose bundle went to the Trash and was
    /// overwritten there. The process still runs the code it was signed as, so it stays trusted.
    @Test(.enabled(if: installedBundlePresent, "installed bundle absent"))
    func runningPeerStaysTrustedAfterItsFileIsReplaced() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "rocuronium").path
        try FileManager.default.copyItem(atPath: Self.installedCLI, toPath: path)
        let peer = try RunningPeer(executable: path)
        defer { peer.stop() }

        let replacement = directory.appending(path: "replacement").path
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: replacement)
        try #require(rename(replacement, path) == 0)

        #expect(CodeIdentity.isTrusted(auditToken: peer.token, identifiers: ["rocuronium"]))
    }

    @Test(.enabled(if: installedBundlePresent, "installed bundle absent"))
    func adHocPeerClaimingOurIdentifierIsNotTrusted() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "rocuronium").path
        try FileManager.default.copyItem(atPath: Self.installedCLI, toPath: path)
        try Self.codesign(["--force", "--sign", "-", "--identifier", "rocuronium", path])
        let peer = try RunningPeer(executable: path)
        defer { peer.stop() }

        #expect(!CodeIdentity.isTrusted(auditToken: peer.token, identifiers: ["rocuronium"]))
    }

    @Test(.enabled(if: installedBundlePresent, "installed bundle absent"))
    func exitedPeerIsNotTrusted() throws {
        let peer = try RunningPeer(executable: Self.installedCLI)
        peer.stop()
        #expect(!CodeIdentity.isTrusted(auditToken: peer.token, identifiers: ["rocuronium"]))
    }

    /// A CLI held open as an MCP server, the shape of a real long-lived peer.
    private final class RunningPeer {
        let process = Process()
        let input = Pipe()
        let token: audit_token_t

        init(executable: String) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["mcp"]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            guard let token = TrustBoundaryTests.auditToken(of: process.processIdentifier) else {
                process.terminate()
                throw CocoaError(.featureUnsupported)
            }
            self.token = token
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    private static func auditToken(of pid: pid_t) -> audit_token_t? {
        var task: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? token : nil
    }

    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func codesign(_ arguments: [String]) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        tool.arguments = arguments
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        tool.waitUntilExit()
        try #require(tool.terminationStatus == 0)
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
