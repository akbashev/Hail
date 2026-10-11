import AnyLanguageModel
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
            try await NowTool().runOutput(
                input: .init(timeZone: "Europe/Berlin"),
                authority: FullAuthority()
            )
        }

        #expect(result.result.textRepresentation.contains("UTC instant: \(expected.ISO8601Format())"))
        #expect(result.result.textRepresentation.contains("Local (Europe/Berlin):"))
    }

    @Test("renders the wall clock in the explicitly requested timezone")
    func allowsTimezoneOverride() async throws {
        let expected = Date(timeIntervalSince1970: 1_704_167_045)
        let result = try await withDependencies {
            $0.date = .fixed(expected)
        } operation: {
            try await NowTool().runOutput(
                input: .init(timeZone: "America/New_York"),
                authority: FullAuthority()
            )
        }

        #expect(result.result.textRepresentation.contains("Local (America/New_York):"))
        #expect(result.result.textRepresentation.contains("UTC instant: \(expected.ISO8601Format())"))
    }

    @Test("withDependencies changes the clock seen by tools")
    func withDependenciesChangesDate() async throws {
        let expected = Date(timeIntervalSince1970: 1_704_167_045)
        let utc = TimeZone(identifier: "UTC")!

        let overridden = try await withDependencies {
            $0.date = .fixed(expected)
        } operation: {
            try await NowTool().runOutput(
                input: .init(timeZone: utc.identifier),
                authority: FullAuthority()
            )
        }
        let live = try await NowTool().runOutput(
            input: .init(timeZone: utc.identifier),
            authority: FullAuthority()
        )

        #expect(overridden.result.textRepresentation.contains("UTC instant: \(expected.ISO8601Format())"))
        #expect(!live.result.textRepresentation.contains("UTC instant: \(expected.ISO8601Format())"))
    }

    @Test("requires an explicit timezone")
    func requiresExplicitTimezone() {
        let schema = NowTool().schema

        let encoded = try! JSONEncoder().encode(schema.parameters)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(serialized.contains("timeZone"))
    }

    @Test("decodes the generated timezone value")
    func decodesGeneratedTimezone() throws {
        let content = GeneratedContent(properties: ["timeZone": "Europe/Berlin"])
        let input = try NowToolInput(content)

        #expect(input.timeZone == "Europe/Berlin")
    }
}
