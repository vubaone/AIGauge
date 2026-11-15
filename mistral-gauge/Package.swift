// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MistralGauge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MistralGauge", targets: ["MistralGauge"])],
    targets: [
        .executableTarget(name: "MistralGauge", path: "Sources"),
        .testTarget(name: "MistralGaugeTests", dependencies: ["MistralGauge"],
                    path: "Tests/MistralGaugeTests")
    ]
)
