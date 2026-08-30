import ScopedEffect
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A test-only access conformer. The protocol is public so modules can hold
/// access values; production conformers (e.g. `SecretStore.Access`) keep
/// their inits internal so feature code never creates one.
private struct TestAccess: SecretAccess {}

@Suite("Classified secret wrapper")
struct ClassifiedTests {

    @Test("Descriptions are redacted, including string interpolation")
    func redaction() {
        let secret = Classified(sealing: "hunter2", access: TestAccess())
        #expect(secret.description == "Classified(****)")
        #expect(secret.debugDescription == "Classified(****)")
        #expect("\(secret)" == "Classified(****)")
    }

    @Test("Classified has no Codable conformance — it cannot be journaled or serialized")
    func noCodableConformance() {
        #expect(!(Classified<String>.self is any Codable.Type))
        #expect(!(Classified<Data>.self is any Codable.Type))
    }

    @Test("map transforms the value without it leaving the wrapper")
    func mapKeepsSecrecy() {
        let secret = Classified(sealing: "token", access: TestAccess())
        let length = secret.map { $0.count }
        #expect(length.description == "Classified(****)")
        #expect(length.reveal(TestAccess()) == 5)
    }

    @Test("reveal unwraps only with an access value")
    func revealNeedsAccess() {
        let secret = Classified(sealing: "hunter2", access: TestAccess())
        #expect(secret.reveal(TestAccess()) == "hunter2")
    }

    @Test("Reflection (dump, String(reflecting:)) never exposes the secret")
    func reflectionIsRedacted() {
        let secret = Classified(sealing: "hunter2-s3cret", access: TestAccess())
        #expect(!String(reflecting: secret).contains("hunter2-s3cret"))
        #expect(!String(describing: secret).contains("hunter2-s3cret"))
        #expect(!"\(secret)".contains("hunter2-s3cret"))
        var dumpOutput = ""
        dump(secret, to: &dumpOutput)
        #expect(!dumpOutput.contains("hunter2-s3cret"))
    }
}

@Suite("SecretRef")
struct SecretRefTests {

    @Test("Codable round-trip preserves every case")
    func codableRoundTrip() throws {
        let refs: [SecretRef] = [.env("KIMI_API_KEY"), .store("anthropic-token")]
        let data = try JSONEncoder().encode(refs)
        #expect(try JSONDecoder().decode([SecretRef].self, from: data) == refs)
    }

    @Test("The encoded shape is tagged by case, never carrying a value shape")
    func encodedShape() throws {
        let data = try JSONEncoder().encode(SecretRef.env("KIMI_API_KEY"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["env"] != nil)
        #expect(object["store"] == nil)
    }
}
