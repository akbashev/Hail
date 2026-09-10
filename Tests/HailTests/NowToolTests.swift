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
    @Test("returns the injected time in the requested timezone and in UTC")
    func returnsInjectedTime() async throws {
        let expected = Date(timeIntervalSince1970: 1_704_167_045)
        let result = try await withDependencies {
            $0.date = .fixed(expected)
        } operation: {
            try await NowTool().run(
                input: .init(timeZone: TimeZone(identifier: "Europe/Berlin")!),
                authority: FullAuthority()
            )
        }

        #expect(result.contains("UTC instant: \(expected.ISO8601Format())"))
        #expect(result.contains("Local (Europe/Berlin):"))
    }

    @Test("renders the wall clock in the explicitly requested timezone")
    func allowsTimezoneOverride() async throws {
        let expected = Date(timeIntervalSince1970: 1_704_167_045)
        let result = try await withDependencies {
            $0.date = .fixed(expected)
        } operation: {
            try await NowTool().run(
                input: .init(timeZone: TimeZone(identifier: "America/New_York")!),
                authority: FullAuthority()
            )
        }

        #expect(result.contains("Local (America/New_York):"))
        #expect(result.contains("UTC instant: \(expected.ISO8601Format())"))
    }

    @Test("withDependencies changes the clock seen by tools")
    func withDependenciesChangesDate() async throws {
        let expected = Date(timeIntervalSince1970: 1_704_167_045)
        let utc = TimeZone(identifier: "UTC")!

        let overridden = try await withDependencies {
            $0.date = .fixed(expected)
        } operation: {
            try await NowTool().run(
                input: .init(timeZone: utc),
                authority: FullAuthority()
            )
        }
        let live = try await NowTool().run(
            input: .init(timeZone: utc),
            authority: FullAuthority()
        )

        #expect(overridden.contains("UTC instant: \(expected.ISO8601Format())"))
        #expect(!live.contains("UTC instant: \(expected.ISO8601Format())"))
    }

    @Test("requires an explicit timezone")
    func requiresExplicitTimezone() {
        let schema = NowTool().schema

        let encoded = try! JSONEncoder().encode(schema.parameters)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(serialized.contains("time_zone"))
    }

    @Test("encodes the timezone across the model boundary")
    func encodesTimezoneForModelBoundary() throws {
        let input = NowTool.Input(timeZone: TimeZone(identifier: "Europe/Berlin")!)
        let data = try JSONEncoder().encode(input)

        #expect(String(data: data, encoding: .utf8) == "{\"time_zone\":\"Europe\\/Berlin\"}")
    }
}
