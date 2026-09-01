// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HailCompaction",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HailCompaction", targets: ["HailCompaction"]),
    ],
    dependencies: [
        // The library is a plugin of hail: it depends on hail, never the reverse.
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "HailCompaction",
            dependencies: [
                .product(name: "HailCore", package: "hail"),
                .product(name: "HailAgentRuntime", package: "hail"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "HailCompactionTests",
            dependencies: ["HailCompaction"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
    ]
)
