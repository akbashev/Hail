import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The agent's history: who said what to it, and its work on each.
///
/// Turns come in order, and at most one is open: the last. Compaction moves the work of earlier
/// turns into a summary; what was said to the agent stays, word for word, as far as its budget
/// allows.
public struct AgentHistory: Codable, Sendable, Equatable {
    /// What compacted turns came to.
    public private(set) var earlier: Earlier?
    /// The closed turns since the last compaction, in order.
    public private(set) var closed: [ClosedTurn]
    /// The turn being worked on. One still open after a replay is a turn a crash interrupted.
    public private(set) var open: OpenTurn?

    public init() {
        self.init(earlier: nil, closed: [], open: nil)
    }

    private init(earlier: Earlier?, closed: [ClosedTurn], open: OpenTurn?) {
        self.earlier = earlier
        self.closed = closed
        self.open = open
    }

    /// The history after `event`. Each step and outcome belongs to the open turn, and a turn
    /// opens only when none is.
    public func applying(_ event: Event) throws(InvalidEvent) -> AgentHistory {
        switch event {
        case .received(let input, let turn):
            if let open { throw .turnStillOpen(open.id) }
            return AgentHistory(earlier: earlier, closed: closed, open: OpenTurn(id: turn, input: input))
        case .called(let call, let at):
            return AgentHistory(earlier: earlier, closed: closed, open: try openTurn().adding(.called(call, at: at)))
        case .resulted(let result, let at):
            return AgentHistory(earlier: earlier, closed: closed, open: try openTurn().adding(.resulted(result, at: at)))
        case .replied(let reply):
            return try closing(as: .replied(reply))
        case .failed(let failure):
            return try closing(as: .failed(failure))
        case .cancelled(let at):
            return try closing(as: .cancelled(at: at))
        case .interrupted(let at):
            return try closing(as: .interrupted(at: at))
        case .compacted(let summary, let through, let kept):
            return try folding(through: through, kept: kept).summarized(by: summary)
        }
    }

    /// Everything before `cut` taken out, for a summary to cover: closed turns' inputs join the
    /// earlier ones, of which `kept` stay; the open turn keeps its input, and its work after the
    /// cut.
    public func folding(through cut: Cut, kept: KeptInputs) throws(InvalidEvent) -> Fold {
        let (folded, work): ([ClosedTurn], Int)
        switch cut {
        case .after(let turn) where open?.id == turn:
            (folded, work) = (closed, open?.steps.count ?? 0)
        case .after(let turn):
            guard let last = closed.firstIndex(where: { $0.id == turn }) else { throw .unknownTurn(turn) }
            (folded, work) = (Array(closed[...last]), 0)
        case .within(let turn, let steps):
            // A cut inside the open turn falls after a result, never between a call and its result.
            guard let open, open.id == turn, steps > 0, steps <= open.steps.count,
                case .resulted = open.steps[steps - 1]
            else { throw .invalidCut(cut) }
            (folded, work) = (closed, steps)
        }
        let earlierInputs = earlier?.kept ?? []
        let stays = kept.selecting(earlierInputs + folded.map { Archived(turn: $0.id, input: $0.input) })
        let staying = Set(stays.map(\.turn))
        return Fold(
            kept: stays,
            closed: Array(closed.dropFirst(folded.count)),
            open: open.map { OpenTurn(id: $0.id, input: $0.input, steps: Array($0.steps.dropFirst(work))) },
            folded: folded,
            foldedWork: work > 0 ? open.map { OpenTurn(id: $0.id, input: $0.input, steps: Array($0.steps.prefix(work))) } : nil,
            dropped: earlierInputs.filter { !staying.contains($0.turn) }
        )
    }

    private func openTurn() throws(InvalidEvent) -> OpenTurn {
        guard let open else { throw .noOpenTurn }
        return open
    }

    private func closing(as outcome: Outcome) throws(InvalidEvent) -> AgentHistory {
        let turn = try openTurn()
        return AgentHistory(
            earlier: earlier, closed: closed + [ClosedTurn(id: turn.id, input: turn.input, steps: turn.steps, outcome: outcome)],
            open: nil)
    }
}

extension AgentHistory {
    /// An event the history can't take: replaying one means the journal isn't this agent's.
    public enum InvalidEvent: Error, Sendable, Equatable, Codable {
        /// A turn opened while another still was.
        case turnStillOpen(TurnID)
        /// A step or outcome with no turn open.
        case noOpenTurn
        /// A compaction through a turn the history doesn't have.
        case unknownTurn(TurnID)
        /// A compaction cutting the open turn where it can't: past its work, or between a call and
        /// its result.
        case invalidCut(Cut)
    }

    /// A history with some turns' work taken out, before its summary is written.
    public struct Fold: Sendable, Equatable {
        /// What stays: earlier inputs word for word, the turns after the fold, the open turn.
        public let kept: [Archived]
        public let closed: [ClosedTurn]
        public let open: OpenTurn?
        /// What the summary is to cover: the folded turns, the open turn's work when it's folded,
        /// and earlier inputs no longer kept word for word.
        public let folded: [ClosedTurn]
        public let foldedWork: OpenTurn?
        public let dropped: [Archived]

        public func summarized(by summary: Summary) -> AgentHistory {
            AgentHistory(earlier: Earlier(summary: summary, kept: kept), closed: closed, open: open)
        }
    }

    /// Who spoke to the agent.
    public enum Participant: Codable, Sendable, Equatable, Hashable {
        /// A person, by the host's identifier for them.
        case user(id: String)
        /// Another agent.
        case agent(AgentID)
    }

    /// What someone said to the agent: what a turn answers.
    public struct Input: Codable, Sendable, Equatable {
        public let from: Participant
        public let content: GeneratedContent
        public let at: Date

        public init(from: Participant, content: GeneratedContent, at: Date) {
            self.from = from
            self.content = content
            self.at = at
        }
    }

    /// The agent's answer, which closes its turn.
    public struct Reply: Codable, Sendable, Equatable {
        public let content: GeneratedContent
        public let at: Date

        public init(content: GeneratedContent, at: Date) {
            self.content = content
            self.at = at
        }
    }

    /// Why a turn ended without an answer.
    public struct Failure: Codable, Sendable, Equatable {
        public let error: AgentRuntimeError
        public let at: Date

        public init(error: AgentRuntimeError, at: Date) {
            self.error = error
            self.at = at
        }
    }

    /// One piece of the agent's work in a turn.
    public enum Step: Codable, Sendable, Equatable {
        /// A tool call the model made.
        case called(ToolCall, at: Date)
        /// A call's result.
        case resulted(ToolResult, at: Date)

        /// The page a result landed on.
        public var landed: PageAddress? {
            if case .resulted(let result, _) = self { result.landed } else { nil }
        }
    }

    /// How a closed turn ended.
    public enum Outcome: Codable, Sendable, Equatable {
        case replied(Reply)
        case failed(Failure)
        /// Abandoned by whoever asked, before it had an answer.
        case cancelled(at: Date)
        /// Cut off by a crash, and closed instead of resumed.
        case interrupted(at: Date)
    }

    /// The turn being worked on: an input, and the work on it so far.
    public struct OpenTurn: Codable, Sendable, Equatable, Identifiable {
        public let id: TurnID
        public let input: Input
        public let steps: [Step]

        init(id: TurnID, input: Input, steps: [Step] = []) {
            self.id = id
            self.input = input
            self.steps = steps
        }

        func adding(_ step: Step) -> OpenTurn {
            OpenTurn(id: id, input: input, steps: steps + [step])
        }
    }

    /// An input, the work on it, and how it ended.
    public struct ClosedTurn: Codable, Sendable, Equatable, Identifiable {
        public let id: TurnID
        public let input: Input
        public let steps: [Step]
        public let outcome: Outcome
    }

    /// What compacted turns came to: their summary, and what was said in them, as far as the
    /// summary doesn't cover it.
    public struct Earlier: Codable, Sendable, Equatable {
        public let summary: Summary
        public let kept: [Archived]
    }

    /// Where a compaction cuts the history: everything before it goes into the summary.
    public enum Cut: Codable, Sendable, Equatable, Hashable {
        /// After this turn: it, and every turn before it. After the open turn, all of its work.
        case after(TurnID)
        /// Inside the open turn, after its first `steps` steps: every closed turn, and that much
        /// of its work.
        case within(TurnID, steps: Int)
    }

    /// Which earlier inputs stay word for word after a compaction.
    public enum KeptInputs: Codable, Sendable, Equatable {
        case all
        /// From this turn's input on; earlier ones are the summary's.
        case from(TurnID)
        case none

        func selecting(_ inputs: [Archived]) -> [Archived] {
            switch self {
            case .all: inputs
            case .from(let first): Array(inputs.drop { $0.turn != first })
            case .none: []
            }
        }
    }

    /// What was said in a turn whose work is compacted.
    public struct Archived: Codable, Sendable, Equatable {
        public let turn: TurnID
        public let input: Input
    }

    /// What compacted work came to: the summary the model is shown, and the report it was
    /// projected from.
    public struct Summary: Codable, Sendable, Equatable {
        /// What the model is shown in place of the compacted work.
        public let context: GeneratedContent
        /// The compaction report, as generated.
        public let report: GeneratedContent

        public init(context: GeneratedContent, report: GeneratedContent) {
            self.context = context
            self.report = report
        }

        /// The summary before it's written, for measuring what a fold leaves: its framing costs,
        /// its content doesn't.
        public static let unwritten = Summary(context: GeneratedContent(""), report: GeneratedContent(""))
    }

    /// What happened in the agent's history.
    public enum Event: Codable, Sendable, Equatable {
        /// Someone spoke to the agent, opening turn `turn`.
        case received(Input, turn: TurnID)
        case called(ToolCall, at: Date)
        case resulted(ToolResult, at: Date)
        case replied(Reply)
        case failed(Failure)
        case cancelled(at: Date)
        /// The open turn, cut off by a crash, is closed instead of resumed.
        case interrupted(at: Date)
        /// The work of every turn up to and including `through` is in `summary`. Of the earlier
        /// inputs, those `kept` stay word for word; the rest are the summary's too.
        case compacted(Summary, through: Cut, kept: KeptInputs)
    }
}
