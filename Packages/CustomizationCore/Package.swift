// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CustomizationCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CustomizationCore", targets: ["CustomizationCore"])],
    targets: [
        .target(name: "CustomizationCore", resources: [.process("Resources")]),
        .testTarget(name: "CustomizationCoreTests", dependencies: ["CustomizationCore"]),
    ]
)
