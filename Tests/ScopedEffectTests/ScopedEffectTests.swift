import Testing

@testable import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A demo effect used to spike the mechanism: configuration on the outside,
/// operations gated on the token.
struct GreeterEffect: ScopedEffect {
    let name = "greeter"
    let greeting: String
}

extension EffectToken where Effect == GreeterEffect {
    func greet(_ who: String) -> String {
        withConfiguration { "\($0.greeting), \(who)!" }
    }

    /// Spikes the hard question: can the non-escapable token be used across
    /// a suspension point inside the scope?
    func greetAfterPause(_ who: String) async -> String {
        try? await Task.sleep(for: .milliseconds(1))
        return greet(who)
    }
}

@Suite("Scoped effect scopes")
struct ScopedEffectTests {

    @Test("The token works inside the scope")
    func tokenWorksInsideScope() async {
        let effect = GreeterEffect(greeting: "Hello")
        let greeting = await _withEffectUnchecked(effect) { token in
            token.greet("world")
        }
        #expect(greeting == "Hello, world!")
    }

    @Test("rethrows: a non-throwing operation needs no try")
    func rethrowsInference() async {
        let effect = GreeterEffect(greeting: "Hi")
        // This line only compiles because the internal mechanism rethrows: there is no
        // `try` here and the result is non-optional.
        let greeting: String = await _withEffectUnchecked(effect) { token in
            token.greet("there")
        }
        #expect(greeting == "Hi, there!")
    }

    @Test("The token survives suspension points inside the scope")
    func tokenAcrossAwait() async throws {
        let effect = GreeterEffect(greeting: "Yo")
        let greeting = await _withEffectUnchecked(effect) { token in
            await token.greetAfterPause("async")
        }
        #expect(greeting == "Yo, async!")
    }

    @Test("The scope runs on the caller's isolation")
    func callerIsolation() async {
        let effect = GreeterEffect(greeting: "Hello")
        let probe = IsolationProbe()
        await probe.run(effect)
    }
}

/// Verifies the scoped operation stays on the caller's actor.
private actor IsolationProbe {
    func run(_ effect: GreeterEffect) async {
        await _withEffectUnchecked(effect) { token in
            // Inside the probe's isolation: touching actor state directly
            // (no await hop) only compiles if the operation inherits it.
            self.note(token.greet("actor"))
        }
    }

    private var notes: [String] = []
    private func note(_ value: String) {
        notes.append(value)
        #expect(value == "Hello, actor!")
    }
}
