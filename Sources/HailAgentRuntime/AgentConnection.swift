import AnyLanguageModel
import Distributed
import DistributedCluster
import HailCore
import HailModelRuntime

/// A distributed callback handle that lets an agent push live updates to a
/// caller without the caller conforming to a generic peer protocol.
///
/// `AgentConnection` is intentionally dumb: it only holds a closure. The caller
/// creates it, passes it to ``Agent/stream(_:connection:)``, and consumes
/// updates through the closure or via ``AgentStream``. Updates include typed
/// structured partial snapshots as well as the final result.
public distributed actor AgentConnection<Output>
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
    public typealias ActorSystem = ClusterSystem

    private let onUpdate: @Sendable (AgentRunEvent<Output>) async throws -> Void

    public init(
        actorSystem: ClusterSystem,
        onUpdate: @escaping @Sendable (AgentRunEvent<Output>) async throws -> Void
    ) {
        self.actorSystem = actorSystem
        self.onUpdate = onUpdate
    }

    public distributed func broadcast(_ update: AgentRunEvent<Output>) async throws {
        try await onUpdate(update)
    }
}

/// Local convenience wrapper that exposes an ``AsyncStream`` of ``AgentRunEvent``
/// together with the ``AgentConnection`` that feeds it.
///
/// This matches the `seamless-llms` pattern: callers pull updates from a stream
/// created on their own node, while the distributed actor reference is what gets
/// passed to the remote agent.
public actor AgentStream<Output>
where Output: Codable & Sendable, Output: Generable, Output.PartiallyGenerated: Codable & Sendable {
    // Immutable and safe to read from outside the actor.
    public nonisolated let connection: AgentConnection<Output>
    public nonisolated let updates: AsyncStream<AgentRunEvent<Output>>
    private nonisolated let continuation: AsyncStream<AgentRunEvent<Output>>.Continuation

    public init(actorSystem: ClusterSystem) {
        let (stream, continuation) = AsyncStream<AgentRunEvent<Output>>.makeStream()
        self.updates = stream
        self.continuation = continuation
        self.connection = AgentConnection(actorSystem: actorSystem) { [continuation] update in
            continuation.yield(update)
        }
    }

    public nonisolated func finish() {
        continuation.finish()
    }
}

extension AgentStream {
    /// Sends a typed input through this stream's connection. Live updates are
    /// yielded to ``updates``; structured partial snapshots appear as
    /// ``AgentRunEvent/modelOutputPartialUpdated(content:at:)`` events and the
    /// final response appears as a ``AgentRunEvent/responseRecorded`` event.
    public func send<Input: Codable & Sendable>(
        _ input: Input,
        message: ChatMessage,
        referenceEntries: [Transcript.Entry] = [],
        inputID: String? = nil,
        to agent: Agent
    ) async throws {
        try await agent.stream(
            input,
            message: message,
            referenceEntries: referenceEntries,
            inputID: inputID,
            through: connection
        )
    }
}
