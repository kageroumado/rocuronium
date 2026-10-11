import Darwin
import Foundation

/// The version stamped on the app bundle this CLI binary lives in.
///
/// The CLI is a bare SwiftPM executable with no Info.plist of its own; it ships inside
/// `Rocuronium.app/Contents/Resources/`, and the bundle's `Contents/Info.plist` is the one
/// version stamp both it and the daemon carry. The path is the executable the kernel is
/// actually running (`proc_pidpath`), never `argv[0]`, so a process launched from a bundle that
/// has since been replaced or trashed reports the install it came from.
nonisolated enum InstalledVersion {
    struct Stamp: Equatable {
        let version: String
        let build: String
        var display: String { "\(version) (\(build))" }
    }

    /// The stamp of the bundle around the running executable, or nil when this binary is not
    /// inside one (a `swift build` product run from `.build/`).
    static func read() -> Stamp? {
        read(executablePath: StaleInstall.runningExecutablePath())
    }

    static func read(executablePath: String?) -> Stamp? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let plist = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String
        else { return nil }
        return Stamp(version: version, build: dictionary["CFBundleVersion"] as? String ?? "0")
    }

    /// The bundle path the stamp was read from, for the `version` printout.
    static func bundlePath(executablePath: String?) -> String? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        return URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
}
