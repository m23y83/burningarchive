// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BluRayBurner",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BurnCore"),
        .executableTarget(name: "BluRayBurner", dependencies: ["BurnCore"]),
        .testTarget(name: "BurnCoreTests", dependencies: ["BurnCore"]),
    ],
    swiftLanguageModes: [.v5]
)
