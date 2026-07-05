// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacDirStat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDirStat", targets: ["MacDirStat"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "MacDirStat",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MacDirStatTests",
            dependencies: ["MacDirStat"],
            path: "Tests"
        )
    ]
)
