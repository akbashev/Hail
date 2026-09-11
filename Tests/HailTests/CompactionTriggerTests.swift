import HailCore
import Testing

@testable import HailAgentRuntime

@Suite("Compaction trigger")
struct CompactionTriggerTests {
    @Test("a reported floor at the window is offered as the trigger measurement")
    func reportedFloorAtWindowIsOffered() {
        let measurement = ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(
            usage: ContextUsage(usedTokens: 12_000, limitTokens: 16_384, source: .reported),
            window: 16_384
        )
        #expect(measurement?.tokenCount == 12_000)
        #expect(measurement?.source == .reported)
    }

    @Test("a missing report yields no floor")
    func missingUsageYieldsNoFloor() {
        #expect(
            ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(usage: nil, window: 100)
                == nil
        )
    }

    @Test("a report against a different window is not trusted")
    func mismatchedWindowYieldsNoFloor() {
        let measurement = ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(
            usage: ContextUsage(usedTokens: 90, limitTokens: 100, source: .reported),
            window: 16_384
        )
        #expect(measurement == nil)
    }

    @Test("a zero-usage report yields no floor")
    func zeroUsageYieldsNoFloor() {
        let measurement = ReasoningLoop<ContinuousClock>.reportedFloorMeasurement(
            usage: ContextUsage(usedTokens: 0, limitTokens: 16_384, source: .reported),
            window: 16_384
        )
        #expect(measurement == nil)
    }
}
