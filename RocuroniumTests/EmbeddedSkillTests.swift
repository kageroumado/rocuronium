import Foundation
import Testing
@testable import Rocuronium

/// The generated `EmbeddedSkill.swift` must match the skill directory it was baked from;
/// otherwise the app installs, and the CLI prints, a manual the repository no longer says.
struct EmbeddedSkillTests {
    /// `<repo>/.claude/skills/rocuronium`, resolved from this file's location.
    private static var skillDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RocuroniumTests
            .deletingLastPathComponent()  // repo root
            .appending(path: ".claude").appending(path: "skills").appending(path: "rocuronium")
    }

    @Test func embeddedFilesMatchTheSkillDirectory() throws {
        let directory = Self.skillDirectory
        try #require(FileManager.default.fileExists(atPath: directory.path), "skill directory absent — not a repository checkout")
        let onDisk = try Self.markdownFiles(under: directory)
        let embedded = Dictionary(uniqueKeysWithValues: EmbeddedSkill.files.map { ($0.path, $0.contents) })
        #expect(Set(onDisk.keys) == Set(embedded.keys), "file set differs — rerun Scripts/embed-skill.py")
        for (path, contents) in onDisk {
            #expect(embedded[path] == contents, "\(path) differs — rerun Scripts/embed-skill.py")
        }
    }

    @Test func skillFileComesFirstAndEveryReferenceIsInTheGuide() {
        let guide = EmbeddedSkill.guideText
        #expect(guide.hasPrefix(EmbeddedSkill.files.first { $0.path == "SKILL.md" }?.contents ?? "∅"))
        for path in EmbeddedSkill.referencePaths {
            #expect(guide.contains(path))
        }
    }

    @Test func installRoundTripsAndDetectsDrift() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(EmbeddedSkill.state(at: directory) == .notInstalled)
        try EmbeddedSkill.install(into: directory)
        #expect(EmbeddedSkill.state(at: directory) == .current)
        try "stale".write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(EmbeddedSkill.state(at: directory) == .outdated(["SKILL.md"]))
    }

    private static func markdownFiles(under directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            result[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }
}
