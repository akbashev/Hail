import AnyLanguageModel
import HTTPTypes

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Whether a model can be used now, as asking where it runs says; when it can't, why.
public enum ModelAvailability: Sendable {
    /// It can be used, and this is what checking it learned about it.
    case available(ModelDetails)
    case unavailable(ModelUnavailability)
}

/// What checking a model learned about it, as where it runs says.
public struct ModelDetails: Sendable, Hashable {
    /// The most tokens the model takes at once, when where it runs says: none when it doesn't.
    ///
    /// Ollama says the most its model was made for, which a server of your own gives it only as
    /// much memory for as it's told, so how much of it to use is the caller's choice.
    public let contextSize: Int?

    public init(contextSize: Int? = nil) {
        self.contextSize = contextSize
    }
}

/// Why a model can't be used now.
public struct ModelUnavailability: Error, Sendable, CustomStringConvertible {
    /// What's in the way.
    public enum Kind: Sendable, Hashable {
        /// The device can't run the model.
        case deviceNotEligible
        /// Apple Intelligence is turned off.
        case appleIntelligenceNotEnabled
        /// The model isn't ready yet, such as while it downloads.
        case notReady
        /// The model named isn't where it's asked for: a provider that doesn't have it, or a file
        /// that isn't there.
        case modelNotFound
        /// The provider asks for a key, and none was given.
        case keyNeeded
        /// The provider refused the key given.
        case keyRefused
        /// The provider couldn't be reached.
        case unreachable
        /// The provider answered with something else: the underlying error has its answer.
        case providerError
        /// A reason the system gives that Hail doesn't know yet.
        case other
    }

    /// What's in the way.
    public let kind: Kind

    /// The error that says more, when there's one: the provider's answer, or the transport's.
    public let underlyingError: (any Error)?

    public init(kind: Kind, underlyingError: (any Error)? = nil) {
        self.kind = kind
        self.underlyingError = underlyingError
    }

    public var description: String {
        guard let underlyingError else { return "\(kind)" }
        return "\(kind): \(underlyingError)"
    }
}

extension ModelUnavailability {
    /// What `error`, from asking a provider about a model, says: that the key was missing or
    /// refused, that the provider doesn't have the model, that it couldn't be reached, or what it
    /// answered instead. A request that was cancelled throws.
    ///
    /// - Parameters:
    ///   - keyGiven: Whether the request carried a key: a refusal without one asks for a key.
    ///   - missingModel: Whether a `404 Not Found` means the provider doesn't have the model, as
    ///     it does when the model itself was asked for.
    ///   - refusesKey: Whether an answer refuses the key in the provider's own way, as Gemini's
    ///     `400 Bad Request` for a key that isn't valid does.
    init(
        asking error: any Error,
        keyGiven: Bool,
        missingModel: Bool,
        refusesKey: (HTTPTransportError) -> Bool = { _ in false }
    ) throws(CancellationError) {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if let unavailability = error as? ModelUnavailability {
            self = unavailability
            return
        }
        guard let error = error as? HTTPTransportError else {
            // It failed on the way, before the provider could answer.
            self.init(kind: .unreachable, underlyingError: error)
            return
        }
        if refusesKey(error) {
            self.init(kind: .keyRefused, underlyingError: error)
            return
        }
        switch error.response?.status {
        case .unauthorized?, .forbidden?:
            self.init(kind: keyGiven ? .keyRefused : .keyNeeded, underlyingError: error)
        case .notFound? where missingModel:
            self.init(kind: .modelNotFound, underlyingError: error)
        default:
            self.init(kind: .providerError, underlyingError: error)
        }
    }
}
