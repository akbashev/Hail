/// Durable token accounting projected from model-request events.
///
/// Counts are optional because providers are allowed to omit individual
/// fields. A dashboard can distinguish “not reported” from a real zero
/// without making the conversation state carry provider-specific data.
public struct AgentUsageSummary: Codable, Sendable, Equatable {
    public private(set) var requestCount: Int
    public private(set) var inputTokens: Int?
    public private(set) var outputTokens: Int?
    public private(set) var reasoningTokens: Int?
    public private(set) var cachedReadTokens: Int?
    public private(set) var cachedWriteTokens: Int?
    public private(set) var totalTokens: Int?

    public init(
        requestCount: Int = 0,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cachedReadTokens: Int? = nil,
        cachedWriteTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.totalTokens = totalTokens
    }

    public mutating func record(_ usage: ModelUsage) {
        requestCount += 1
        inputTokens = Self.add(inputTokens, usage.inputTokens)
        outputTokens = Self.add(outputTokens, usage.outputTokens)
        reasoningTokens = Self.add(reasoningTokens, usage.reasoningTokens)
        cachedReadTokens = Self.add(cachedReadTokens, usage.cachedReadTokens)
        cachedWriteTokens = Self.add(cachedWriteTokens, usage.cachedWriteTokens)
        totalTokens = Self.add(totalTokens, usage.totalTokens)
    }

    private static func add(_ current: Int?, _ value: Int?) -> Int? {
        guard let value else { return current }
        return (current ?? 0) + value
    }
}
