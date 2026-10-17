// swift-tools-version:5.9
import PackageDescription

#if os(Windows)
let products: [Product] = [
    .library(name: "SlashCommandCore", targets: ["SlashCommandCore"]),
    .executable(name: "slashcommand", targets: ["slashcommand"]),
    .executable(name: "SlashCommandWin", targets: ["SlashCommandWin"]),
]
let targets: [Target] = [
    .target(name: "CWindowsTerminal", linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("oleaut32"), .linkedLibrary("uiautomationcore"), .linkedLibrary("user32"), .linkedLibrary("uuid")]),
    .target(name: "SlashCommandCore", dependencies: ["CWindowsTerminal"]),
    .target(name: "CWindowsConsoleFixture", path: "Tests/CWindowsConsoleFixture"),
    .executableTarget(name: "WindowsConsoleFixture", dependencies: ["CWindowsConsoleFixture"], path: "Tests/WindowsConsoleFixture"),
    .executableTarget(name: "slashcommand", dependencies: ["SlashCommandCore"]),
    .executableTarget(name: "SlashCommandWin", dependencies: ["SlashCommandCore"],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]),
    .testTarget(name: "SlashCommandCoreTests", dependencies: ["SlashCommandCore", "CWindowsConsoleFixture", "WindowsConsoleFixture"], resources: [.copy("Fixtures")]),
]
#else
let products: [Product] = [
    .library(name: "SlashCommandCore", targets: ["SlashCommandCore"]),
    .executable(name: "slashcommand", targets: ["slashcommand"]),
    .executable(name: "SlashCommandApp", targets: ["SlashCommandApp"]),
]
let targets: [Target] = [
    .target(name: "SlashCommandCore"),
    .executableTarget(name: "slashcommand", dependencies: ["SlashCommandCore"]),
    .executableTarget(name: "SlashCommandApp", dependencies: ["SlashCommandCore"]),
    .testTarget(name: "SlashCommandCoreTests", dependencies: ["SlashCommandCore"], resources: [.copy("Fixtures")]),
]
#endif

let package = Package(
    name: "SlashCommand",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
