import AnyLanguageModel
import HailCore
import Synchronization
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Calls that land on a page: the history keeps what they did and the address; the page is
/// opened from its address, in one tab per address, whenever it's shown.
@Suite("Pages and tabs")
struct PageTabTests {
    /// A place whose state the test changes: what it shows, and the tools it offers.
    final class Place: Sendable {
        let state = Mutex<(text: String, tools: [String])?>(("counter: 0", ["add"]))

        var current: (text: String, tools: [String])? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    struct PlacePages: ToolPages {
        let place: Place

        func open(_ address: ToolPageAddress) async throws(ToolPageUnavailable) -> ToolPage {
            guard let current = place.current else { throw .gone }
            return ToolPage(.text(current.text), links: current.tools.map { OfferedTool(name: $0) })
        }
    }

    /// A tool the page offers; calling it lands back on the page.
    struct OfferedTool: HailCore.Tool {
        let name: String
        var description: String { "\(name) on the counter" }

        func effect(for input: EmptyToolInput) throws -> ClockEffect { ClockEffect() }

        func run(
            _ input: EmptyToolInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<ClockEffect>
        ) async throws
            -> CallReturn
        {
            .text("did \(name)", landing: ToolPageAddress(rawValue: "counter"))
        }
    }

    private func call(_ session: inout AgentSession, _ id: String, _ name: String) async throws -> ToolExecution {
        try await session.execute(ToolCall(id: id, name: name, arguments: GeneratedContent(properties: [:])))
    }

    private func session(_ place: Place) -> AgentSession {
        var session = AgentSession()
        session.offer(TurnTools(tools: [OfferedTool(name: "open")], pages: PlacePages(place: place)))
        return session
    }

    @Test(
        "a group is a page: the turn starts from its link, which says what it's for in a sentence; going there shows the rest and its tools"
    )
    func aGroupIsAPage() async throws {
        var session = AgentSession()
        session.offer(
            TurnTools(
                tools: [OfferedTool(name: "alone")],
                groups: [
                    ToolGroup(
                        name: "counter", description: "Counts cups. Add one for each cup.",
                        tools: [OfferedTool(name: "counter_add"), OfferedTool(name: "counter_reset")])
                ]))
        #expect(session.schemas().map(\.name).sorted() == ["alone", "counter"])
        #expect(session.tool(named: "counter")?.description == "Counts cups.")
        let opened = try await call(&session, "1", "counter")
        #expect(opened.result.landed == ToolPageAddress(rawValue: "counter"))
        let reading = opened.page.map { ToolAnswer(result: opened.result, page: $0, tools: []).reading }
        #expect(reading?.contains("Counts cups. Add one for each cup.") == true)
        #expect(reading?.contains("Now you can use:\n- `counter_add`: counter_add on the counter") == true)
        #expect(Set(session.schemas().map(\.name)).isSuperset(of: ["counter_add", "counter_reset"]))
    }

    @Test("a call that lands on a page keeps what it did and the address, and shows the page now")
    func landingKeepsTheAddress() async throws {
        let place = Place()
        var session = session(place)
        let opened = try await call(&session, "1", "open")

        #expect(opened.result.output == .text("did open"))
        #expect(opened.result.landed == ToolPageAddress(rawValue: "counter"))
        #expect(opened.page?.output == .text("counter: 0"))
        #expect(session.schemas().map(\.name) == ["add", "open"])
    }

    @Test("landing on an open page again keeps one tab, with its tools as they are now")
    func oneTabPerAddress() async throws {
        let place = Place()
        var session = session(place)
        _ = try await call(&session, "1", "open")
        place.current = ("counter: 1", ["add", "reset"])
        let added = try await call(&session, "2", "add")

        #expect(added.page?.output == .text("counter: 1"))
        #expect(session.schemas().map(\.name) == ["add", "reset", "open"])
    }

    @Test("a page stays open across turns and refreshes the tools it offers, adding nothing to the request")
    func pagesStayOpenAcrossTurns() async throws {
        let place = Place()
        var session = session(place)
        _ = try await call(&session, "1", "open")
        #expect(session.schemas().map(\.name) == ["add", "open"])

        place.current = ("counter: 1", ["reset"])
        let arrivals = await session.begin(TurnID())

        #expect(arrivals.isEmpty)
        #expect(session.schemas().map(\.name) == ["reset", "open"])
        #expect(try await call(&session, "2", "reset").result.output == .text("did reset"))
    }

    @Test("a page tab closes when its resource is gone")
    func gonePagesCloseAcrossTurns() async throws {
        let place = Place()
        var session = session(place)
        _ = try await call(&session, "1", "open")

        place.current = nil
        let arrivals = await session.begin(TurnID())

        #expect(arrivals.isEmpty)
        #expect(session.schemas().map(\.name) == ["open"])
    }
}
