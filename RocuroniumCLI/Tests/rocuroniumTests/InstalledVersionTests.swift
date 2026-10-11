import Foundation
import Testing
@testable import rocuronium

/// `rocuronium version` has to say which install a binary came from, so the stamp is read
/// relative to the running executable's real path, and a binary outside any bundle says so
/// instead of inventing a number.
struct InstalledVersionTests {
    private func makeBundle(version: String, build: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocuronium-version-\(UUID().uuidString)")
            .appendingPathComponent("Rocuronium.app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true,
        )
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleVersion": build]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return root
    }

    @Test func readsTheStampOfTheBundleAroundTheExecutable() throws {
        let bundle = try makeBundle(version: "1.5.0", build: "6")
        let executable = bundle.appendingPathComponent("Contents/Resources/rocuronium").path
        #expect(InstalledVersion.read(executablePath: executable) == .init(version: "1.5.0", build: "6"))
        #expect(InstalledVersion.bundlePath(executablePath: executable) == bundle.path)
    }

    @Test func aBinaryOutsideAnyBundleHasNoStamp() {
        #expect(InstalledVersion.read(executablePath: "/tmp/nowhere/.build/debug/rocuronium") == nil)
        #expect(InstalledVersion.read(executablePath: nil) == nil)
        #expect(InstalledVersion.read(executablePath: "") == nil)
    }
}
