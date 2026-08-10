// swift-tools-version:6.1
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
        )
    ]
)
