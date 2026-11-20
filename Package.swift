// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OverlayActivity",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OverlayCore"),
        .executableTarget(name: "OverlayActivity", dependencies: ["OverlayCore"]),
        .testTarget(name: "OverlayCoreTests", dependencies: ["OverlayCore"]),
    ]
)
