// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Hail",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Hail", targets: ["Hail"]),
        .library(name: "HailCore", targets: ["HailCore"]),
        .library(name: "HailModelRuntime", targets: ["HailModelRuntime"]),
        .library(name: "HailAgentRuntime", targets: ["HailAgentRuntime"]),
        .library(name: "HailCompaction", targets: ["HailCompaction"]),
        .library(name: "ScopedEffect", targets: ["ScopedEffect"]),
    ],
    traits: [
        .trait(name: "Llama", description: "Local GGUF models run by llama.cpp, which builds only for Apple platforms.")
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"605.0.0"),
        .package(url: "https://github.com/turgai-labs/swift-distributed-actors.git", branch: "turgai-integration"),
        .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "stable-references"),
        .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "turgai-integration"),
        .package(
            // Ollama's API key, until huggingface/AnyLanguageModel releases it.
            url: "https://github.com/akbashev/AnyLanguageModel.git",
            branch: "feat/list-models",
            traits: ["AsyncHTTPClient", .trait(name: "Llama", condition: .when(traits: ["Llama"]))]
        ),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .macro(
            name: "HailMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "ScopedEffect",
            exclude: ["README.md"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .target(
            name: "HailCore",
            dependencies: [
                "ScopedEffect",
                "HailMacros",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .target(
            name: "HailModelRuntime",
            dependencies: [
                "HailCore",
                "ScopedEffect",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .target(
            name: "HailAgentRuntime",
            dependencies: [
                "HailCore",
                "HailModelRuntime",
                "ScopedEffect",
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "VirtualActors", package: "cluster-virtual-actors"),
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .target(
            name: "Hail",
            dependencies: ["HailCore", "HailModelRuntime", "HailAgentRuntime", "HailCompaction", "ScopedEffect"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .target(
            name: "HailCompaction",
            dependencies: [
                "HailCore",
                "HailAgentRuntime",
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/HailCompaction",
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "HailTests",
            dependencies: [
                "Hail", "HailCore", "HailModelRuntime", "HailAgentRuntime", "ScopedEffect",
                .product(name: "EventSourcing", package: "cluster-event-sourcing"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "HailMacrosTests",
            dependencies: [
                "HailMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "ScopedEffectTests",
            dependencies: ["ScopedEffect"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "HailCompactionTests",
            dependencies: ["HailCompaction"],
            path: "Tests/HailCompactionTests",
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
    ]
)

// Swift 7's language, ahead of it. Among it, every async function runs on its caller's executor
// unless it says otherwise: what an actor owns, such as a borrowed effect token, stays on that actor.
for target in package.targets where target.type != .binary {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("ImmutableWeakCaptures"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        ]
}

// Code slow to type-check is told, except in tests: each expectation is a macro, and a test of
// many crosses the limit by itself.
for target in package.targets where target.type != .binary && target.type != .test {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .unsafeFlags([
                "-Xfrontend", "-warn-long-function-bodies=100",
                "-Xfrontend", "-warn-long-expression-type-checking=100",
            ])
        ]
}
