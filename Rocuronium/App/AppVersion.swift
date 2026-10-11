import Foundation

/// The version Xcode stamped on the bundle this process runs from.
///
/// Read from `Bundle.main`, so a daemon started from an older install reports that install:
/// the `status` reply carries it, and the CLI compares it against the bundle its own binary
/// lives in to tell a stale daemon from a current one.
nonisolated enum AppVersion {
    static let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static var display: String { "\(marketing) (\(build))" }
}
