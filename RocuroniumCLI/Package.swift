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
        .executableTarget(
            name: "rocuronium", dependencies: ["SessionKit"], path: "Sources/rocuronium",
            swiftSettings: swiftSettings,
        ),
        // The agent session's account lifecycle, shared by the CLI (the in-session watchdog and
        // the SSH forced command) and the root helper (provisioning and removal).
        .target(name: "SessionKit", path: "Sources/SessionKit", swiftSettings: swiftSettings),
        // The privileged half of `session enable`: a LaunchDaemon the app registers through
        // SMAppService and talks to over XPC. Root, so it holds as little as it can.
        .executableTarget(
            name: "rocuronium-session-helper", dependencies: ["SessionKit"],
            path: "Sources/rocuronium-session-helper", swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "rocuroniumTests", dependencies: ["rocuronium"], path: "Tests/rocuroniumTests",
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "SessionKitTests", dependencies: ["SessionKit"], path: "Tests/SessionKitTests",
            swiftSettings: swiftSettings,
        ),
    ],
)
