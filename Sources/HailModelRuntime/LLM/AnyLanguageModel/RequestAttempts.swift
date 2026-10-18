import HailCore

/// How far a request got: nothing back yet, the model answering, or tools it called, which ran
/// in the agent's session.
enum RequestProgress: Equatable {
    case notStarted
    case answering
    case calledTools
}

/// What a request may still be asked again for: the rules for asking a model again, apart from
/// the asking. Only a request that produced nothing is asked again; one that called tools is
/// under way in the agent's session, and asked again, its tools would run again.
struct RequestAttempts: Equatable {
    /// How an attempt ended without an answer.
    enum Ending: Equatable {
        case failed(RequestFailure)
        /// The model wrote nothing after its last tool call: it thought its whole length.
        case wroteNothing
    }

    /// What follows an attempt that ended without an answer.
    enum Next: Equatable {
        case askAgain(after: Duration)
        case fail(ModelEndpointError)
    }

    /// The most times a busy provider is waited for in one request.
    static let mostBusyWaits = 3
    /// The longest a busy provider is waited for; one that asks for longer fails.
    static let longestWait: Duration = .seconds(60)
    /// How long a busy provider that doesn't say is waited for.
    static let usualWait: Duration = .seconds(10)
    /// How long before a request that didn't reach the model is sent again.
    static let unreachedWait: Duration = .seconds(1)

    /// The thinking the next attempt asks for.
    private(set) var thinking: ModelReasoningOverride
    /// Whether this endpoint can ask without thinking.
    private let thinkingCanBeTurnedOff: Bool
    private var unreachedAskedAgain = false
    private var busyWaits = 0

    init(thinking: ModelReasoningOverride, thinkingCanBeTurnedOff: Bool) {
        self.thinking = thinking
        self.thinkingCanBeTurnedOff = thinkingCanBeTurnedOff
    }

    /// What follows an attempt that ended so, having got as far as `progress`.
    mutating func next(after ending: Ending, progress: RequestProgress) -> Next {
        switch ending {
        case .failed(.failed(let error)):
            return .fail(error)
        case .failed(.unreached(let error)):
            guard progress == .notStarted, !unreachedAskedAgain else { return .fail(error) }
            unreachedAskedAgain = true
            return .askAgain(after: Self.unreachedWait)
        case .failed(.busy(let error, let retryAfter)):
            let wait = retryAfter ?? Self.usualWait
            guard progress == .notStarted, busyWaits < Self.mostBusyWaits, wait <= Self.longestWait else {
                return .fail(error)
            }
            busyWaits += 1
            return .askAgain(after: wait)
        case .wroteNothing:
            // Without thinking, which is where it went round.
            guard progress != .calledTools, thinkingCanBeTurnedOff, thinking != .disabled else {
                return .fail(.thoughtPastAnswer)
            }
            thinking = .disabled
            return .askAgain(after: .zero)
        }
    }
}
