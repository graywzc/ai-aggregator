// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIAggregator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIAggregatorApp", targets: ["AIAggregatorApp"]),
        .library(name: "AIAggregator", targets: ["AIAggregator"])
    ],
    targets: [
        .target(
            name: "AIAggregator",
            path: "Sources/AIAggregator"
        ),
        .executableTarget(
            name: "AIAggregatorApp",
            dependencies: ["AIAggregator"],
            path: "Sources/AIAggregatorApp",
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "AIAggregatorTests",
            dependencies: ["AIAggregator"],
            path: "Tests/AIAggregatorTests"
        )
    ]
)
