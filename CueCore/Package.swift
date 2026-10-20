// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CueCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "CueCore", targets: ["CueCore"]),
    ],
    targets: [
        .target(name: "CueCore"),
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"]),
    ]
)
