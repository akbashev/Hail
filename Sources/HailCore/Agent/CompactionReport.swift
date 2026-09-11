import AnyLanguageModel

/// The single typed value produced by a compaction request.
///
/// Hail does not interpret either component. The first component is projected
/// into the next model context; the second is application-owned material that
/// is reconciled at the host boundary.
@Generable
public struct CompactionReport<Summary, Memory>: Codable, Sendable
where
    Summary: Codable & Sendable & Generable,
    Memory: Codable & Sendable & Generable
{
    public let summary: Summary
    public let memories: [Memory]

}
