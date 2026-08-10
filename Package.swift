// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Gallop",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Gallop",
            path: "Sources/Gallop"
        )
    ]
)
