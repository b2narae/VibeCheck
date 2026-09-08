// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VibeCheck",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VibeCheck",
            path: "Sources/VibeCheck"
        ),
        // The detection logic has been corrected four times (turn state,
        // stale hook reports, one-shot invocations, Codex turns). These lock
        // each of those fixes in place.
        .testTarget(
            name: "VibeCheckTests",
            dependencies: ["VibeCheck"],
            path: "Tests/VibeCheckTests"
        ),
    ]
)
