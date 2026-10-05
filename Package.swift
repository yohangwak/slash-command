// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Gear",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GearCore", targets: ["GearCore"]),
        .executable(name: "gear", targets: ["gear"]),
        .executable(name: "GearApp", targets: ["GearApp"]),
    ],
    targets: [
        .target(name: "GearCore"),
        .executableTarget(name: "gear", dependencies: ["GearCore"]),
        .executableTarget(name: "GearApp", dependencies: ["GearCore"]),
        .testTarget(name: "GearCoreTests", dependencies: ["GearCore"], resources: [.copy("Fixtures")]),
    ]
)
