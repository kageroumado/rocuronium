// swift-tools-version: 6.2
import PackageDescription

/// The CLI is deliberately a separate, dependency-free package: it holds no permissions,
/// contains no automation logic, and exists only to forward JSON to the app's control socket.
///
/// Swift 6 language mode with complete concurrency checking, stated explicitly rather than left
/// to the tools-version default so a later bump cannot quietly loosen it, and matching the app's
/// caller-runs isolation (SE-0461). Note this only guards the CLI's own sources: `Engine` and
/// `CommandRouter` live in the app target and are never compiled here, so the app archive is
/// still where their concurrency is proved.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "RocuroniumCLI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "rocuronium", path: "Sources/rocuronium", swiftSettings: swiftSettings),
        .testTarget(
            name: "rocuroniumTests", dependencies: ["rocuronium"], path: "Tests/rocuroniumTests",
            swiftSettings: swiftSettings,
        ),
    ],
)
