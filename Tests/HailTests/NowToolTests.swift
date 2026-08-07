import Hail
import ScopedEffect
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Now tool")
struct NowToolTests {
    @Test("returns the injected clock as an ISO 8601 timestamp")
    func returnsInjectedTime() async throws {
        let expected = Date(timeIntervalSince1970: 1_704_167_045)
        let tool = NowTool(clock: { expected })

        let result = try await tool.execute(input: .init(), authority: FullAuthority())

        #expect(result == expected.ISO8601Format())
        #expect(tool.schema.function.name == "now")
    }
}
