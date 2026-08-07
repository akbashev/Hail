// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Hail",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Hail", targets: ["Hail"]),
        .library(name: "HailCore", targets: ["HailCore"]),
        .library(name: "HailModelRuntime", targets: ["HailModelRuntime"]),
        .library(name: "HailAgentRuntime", targets: ["HailAgentRuntime"]),
        .library(name: "ScopedEffect", targets: ["ScopedEffect"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
        .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "main"),
        .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main"),
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel.git",
            from: "0.8.0",
            traits: ["AsyncHTTPClient"]
        ),
        .package(url: "https://github.com/wiedymi/swift-acp.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
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
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
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
                .product(name: "ACP", package: "swift-acp"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Logging", package: "swift-log"),
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
            dependencies: ["HailCore", "HailModelRuntime", "HailAgentRuntime", "ScopedEffect"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "HailTests",
            dependencies: ["Hail", "HailCore", "HailModelRuntime", "HailAgentRuntime", "ScopedEffect"],
            sources: [
                "ACPSessionResumeTests.swift",
                "ACPSessionTurnRoutingTests.swift",
                "AgentStateTurnTimingTests.swift",
                "ClaudeCliSessionRoutingTests.swift",
                "CodexAppServerSessionRoutingTests.swift",
                "KimiCodeStallWatchdogTests.swift",
                "ModelEndpointErrorTests.swift",
                "NowToolTests.swift",
                "PromptPolicyPersonaTests.swift",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
        .testTarget(
            name: "ScopedEffectTests",
            dependencies: ["ScopedEffect"],
            sources: [
                "ClassifiedTests.swift",
                "EffectAuditStressTests.swift",
                "EffectAuthorityTests.swift",
                "ScopedEffectTests.swift",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
    ]
)
