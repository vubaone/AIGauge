// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeGauge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClaudeGauge",
            targets: ["ClaudeGauge"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClaudeGauge",
            dependencies: [],
            path: "Sources",
            exclude: [
                "AppDelegate.swift",
                "MenuBarManager.swift",
                "SettingsView.swift",
                "LaunchAtLoginHelper.swift"
            ]
        )
    ]
)
