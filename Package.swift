// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModelSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ModelSwitchCore", targets: ["ModelSwitchCore"]),
        .executable(name: "modelswitch", targets: ["modelswitch"]),
        .executable(name: "ModelSwitchApp", targets: ["ModelSwitchApp"]),
    ],
    targets: [
        .target(name: "ModelSwitchCore"),
        .executableTarget(name: "modelswitch", dependencies: ["ModelSwitchCore"]),
        .executableTarget(name: "ModelSwitchApp", dependencies: ["ModelSwitchCore"]),
        .testTarget(name: "ModelSwitchCoreTests", dependencies: ["ModelSwitchCore"], resources: [.copy("Fixtures")]),
    ]
)
