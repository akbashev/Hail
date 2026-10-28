// Compile check for the README's examples. Nothing here runs.
import AnyLanguageModel
import DistributedCluster
import Foundation
import HailAgentRuntime
import HailCompaction
import HailCore
import HailModelRuntime
import ScopedEffect

@Generable
struct ChatReply: Codable, Sendable {
    let content: String
}

extension ChatReply.PartiallyGenerated: Codable {}

enum ReadmeExamples {
    static func spawn(system: ClusterSystem) async throws -> Agent {
        let scoutID = AgentID(role: Role("scout"), contextID: AgentContextID("mission-7"))
        let scout = try await system.agent(scoutID)
        return scout
    }

    static func talk(scout: Agent) async throws {
        let reply: ChatReply = try await scout.respond("Survey the area and report anything unusual.")
        print(reply.content)
    }

    struct Navigator {
        let brain: Agent
        let scout: Agent

        func investigate() async throws -> ChatReply {
            let report: ChatReply = try await scout.respond("Inspect the signal and report your findings.")
            return try await brain.respond("The scout reported: \(report.content). Decide what we should do next.")
        }
    }

    static func stream(system: ClusterSystem, scout: Agent) async throws {
        let stream = AgentStream<ChatReply>(actorSystem: system)
        let updates = Task {
            for await update in stream.updates {
                switch update {
                case .toolRequested(let call, _):
                    print("Scout called:", call.name)
                case .responseRecorded(let reply, _):
                    print("Scout replied:", reply.content)
                default:
                    break
                }
            }
        }
        try await stream.send("Inspect the signal and explain how confident you are.", to: scout)
        stream.finish()
        await updates.value
    }

    static func follow(scout: Agent) async throws {
        for await activity in scout {
            if case .turn(.progress(.partial(let content)), _) = activity {
                let soFar = try ChatReply.PartiallyGenerated(content)
                print(soFar.content ?? "")
            }
        }
    }

    static func effect(projectRoot: String) {
        let requestedRead = FileEffect(path: projectRoot + "/README.md", action: .read)
        _ = requestedRead
    }

    static func authority(projectRoot: String) async throws {
        let authority = CompositeAuthority()
            .granting(for: FileEffect.self, decide: FileEffect.pathPolicy(scopedTo: projectRoot))
        let file = AnyTool(FileTool(projectRoot: URL(fileURLWithPath: projectRoot)))
        let read = try await file.runOutput(
            generatedContent: try GeneratedContent(json: #"{"action":"read","path":"README.md"}"#),
            authority: authority
        )
        print(read.result.textRepresentation)
    }

    static func secret() async throws {
        let apiKey = SecretRef.env("SEARCH_API_KEY")
        let search = NetworkEffect(
            host: "api.example.com",
            operation: "GET /search",
            request: NetworkRequest(url: "https://api.example.com/search?q=signal")
        )
        let authority = CompositeAuthority()
            .granting(for: NetworkEffect.self, decide: NetworkEffect.hostPolicy(allowing: ["api.example.com"]))
        try await withEffect(search, authority: authority) { token in
            _ = apiKey
        }
    }

    static func host(
        definitions: [Role: AgentDefinition],
        workspaces: String,
        directory: @escaping @Sendable (WorkspaceID) -> String
    ) throws -> AgentRuntimePlugin {
        try AgentRuntimePlugin(
            maxToolRounds: 25,
            routerConfiguration: try ModelRouterConfiguration(temperature: 0.7),
            turnToolsProvider: { _, _ in
                TurnTools(tools: [NowTool()])
            },
            authority: { _ in CompositeAuthority.workspaceDefault(root: workspaces) },
            workspaceProvider: { spawn in
                AgentWorkspace(rootPath: directory(spawn.workspaceID))
            },
            definitionProvider: { spawn in
                definitions[spawn.agentID.role]
            },
            modelSelectionProvider: { _ in
                ModelConfiguration(model: try AgentModel("ollama/qwen3:8b"))
            },
            contextCompactor: SlidingWindowCompactor()
        )
    }

    static func definition() -> AgentDefinition {
        AgentDefinition(
            role: Role("scout"),
            behavior: .init(systemPrompt: "You are a careful signal scout.")
        )
    }

    static func router() throws -> ModelRouterConfiguration {
        try ModelRouterConfiguration(
            temperature: 0.7,
            baseURLs: [.ollama: URL(string: "http://localhost:11434")!],
            modelContextWindows: [try AgentModel("ollama/qwen3:8b"): 32_768]
        )
    }
}

@Generable
struct SignalInput: Sendable {
    /// The frequency to listen on, in megahertz.
    let frequency: Double
}

@Tool("listen", description: "Listen on a frequency and report what is heard.")
struct ListenTool {
    func effect(for input: SignalInput) throws -> ClockEffect { ClockEffect() }

    func run(
        _ input: SignalInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>
    ) async throws -> CallReturn {
        .text("Static on \(input.frequency) MHz.")
    }
}
