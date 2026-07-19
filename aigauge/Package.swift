// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIGauge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIGauge", targets: ["AIGauge"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AIGauge",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "AIGaugeTests",
            dependencies: ["AIGauge"],
            path: "Tests/AIGaugeTests"
        )
    ]
)
