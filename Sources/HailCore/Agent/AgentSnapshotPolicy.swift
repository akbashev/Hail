/// Serializable snapshot intent supplied when an agent is spawned.
///
/// The runtime turns this value into EventSourcing's executable
/// ``Snapshotting`` value. Keeping the intent here means it can cross a
/// distributed-actor boundary; executable snapshot predicates remain an
/// activation-time concern.
public enum AgentSnapshotRetention: Codable, Equatable, Sendable {
    /// Retain every snapshot.
    case keepAll
    /// Retain the most recent periodic snapshots for the given number of
    /// intervals. Values less than one are normalized by the runtime.
    case keepLast(Int)
}

public enum AgentSnapshotPolicy: Codable, Equatable, Sendable {
    /// Do not save snapshots.
    case disabled
    /// Save periodically.
    case periodic(every: Int, retention: AgentSnapshotRetention)
    /// Save periodically and after a domain-level compaction event.
    case periodicOrWhenCompacted(every: Int, retention: AgentSnapshotRetention)
    /// Save only after a domain-level compaction event.
    case whenCompacted

    /// The default used by Hail agents. Hosts can select another policy per
    /// spawn without changing the agent implementation.
    public static let `default`: Self = .periodicOrWhenCompacted(
        every: 250,
        retention: .keepLast(2)
    )
}
