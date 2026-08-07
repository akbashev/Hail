import DistributedCluster
import HailCore
import HailModelRuntime

/// Provides context documents for an agent turn without coupling the runtime to
/// any specific transport (MCP, inline text, HTTP, etc.).
///
/// The provider is a value type (a struct of closures) so different products can
/// inject different context strategies while the runtime remains agnostic.
///
/// The closure receives the running `ClusterSystem` per call, so providers
/// resolve their actors through the virtual actor system per call and never
/// capture actor references.
public struct AgentContextProvider: Sendable {
    public let manifest: @Sendable (AgentID, ClusterSystem) async throws -> ContextManifest

    public init(manifest: @escaping @Sendable (AgentID, ClusterSystem) async throws -> ContextManifest) {
        self.manifest = manifest
    }

    /// A provider that returns an empty manifest. Useful for tests and for
    /// agents that receive all context inline.
    public static var empty: Self {
        Self { _, _ in ContextManifest(items: []) }
    }
}

/// A manifest of context items available to an agent during a turn.
public struct ContextManifest: Sendable {
    public let items: [ContextItem]

    public init(items: [ContextItem]) {
        self.items = items
    }
}

/// A typed identifier for a context document.
///
/// Wrapping the raw string prevents accidental mixing with URIs, tool names, or
/// other stringly-typed identifiers, and makes the document namespace explicit
/// in function signatures.
public struct ContextDocumentID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// A single piece of context available to an agent.
///
/// The runtime uses protocol-neutral identifiers. Adapters (MCP, HTTP, inline,
/// etc.) decide how to render each identifier for a specific model or transport.
public enum ContextItem: Sendable, Codable, Equatable {
    /// Plain text included directly in the prompt.
    case inline(text: String)

    /// A pointer to a named document the agent should read.
    ///
    /// The `id` is a product-defined identifier such as `context.current` or
    /// `project.spec`. It is not a URI; the adapter layer maps it to the
    /// appropriate transport-specific locator (the adapter may map `context.current`
    /// to a URI such as `hail://context.current`).
    case document(id: ContextDocumentID, title: String, description: String)

    /// A tool the agent may call to fetch context.
    case fetchTool(name: String, description: String, arguments: [String: String])
}
