/// Logical identity of a workspace: a durable resource namespace, distinct
/// from the agent identity that uses it.
///
/// An agent's identity, its model, and its workspace are three independent
/// concerns. Two different agents (e.g. a coding agent and a reviewer agent,
/// or the same role serving two different channels) may legitimately share
/// one `WorkspaceID`; conversely one user may own several workspaces. Hosts
/// decide what a `WorkspaceID` means — Hail only carries it from the spawn
/// intent through to the ``AgentRuntimePlugin/WorkspaceProvider`` that
/// resolves it to a physical location at activation.
///
/// This is a logical identifier, not a filesystem path. It may be journaled
/// as part of ``AgentSpawnConfig``, so a host must treat its raw value as
/// untrusted input when deriving a physical path from it — see the warning
/// on the workspace provider a host supplies.
public struct WorkspaceID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
