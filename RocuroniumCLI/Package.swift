// swift-tools-version: 6.2
import PackageDescription

/// The CLI is deliberately a separate, dependency-free package: it holds no permissions,
/// contains no automation logic, and exists only to forward JSON to the app's control socket.
let package = Package(
    name: "RocuroniumCLI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "rocuronium", path: "Sources/rocuronium"),
        .testTarget(name: "rocuroniumTests", dependencies: ["rocuronium"], path: "Tests/rocuroniumTests"),
    ],
)
