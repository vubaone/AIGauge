// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexGauge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CodexGauge",
            targets: ["CodexGauge"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CodexGauge",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "CodexGaugeTests",
            dependencies: ["CodexGauge"],
            path: "Tests/CodexGaugeTests"
        )
    ]
)
