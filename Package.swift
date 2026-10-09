// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlashCommand",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SlashCommandCore", targets: ["SlashCommandCore"]),
        .executable(name: "slashcommand", targets: ["slashcommand"]),
        .executable(name: "SlashCommandApp", targets: ["SlashCommandApp"]),
    ],
    targets: [
        .target(name: "SlashCommandCore"),
        .executableTarget(name: "slashcommand", dependencies: ["SlashCommandCore"]),
        .executableTarget(name: "SlashCommandApp", dependencies: ["SlashCommandCore"]),
        .testTarget(name: "SlashCommandCoreTests", dependencies: ["SlashCommandCore"], resources: [.copy("Fixtures")]),
    ]
)
