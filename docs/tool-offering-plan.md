# Tool offering plan

Status: proposal, to think about

Every tool's full definition goes into every model request. A tool with a large schema costs its tokens in every turn, whether or not the turn uses it. For Apple's on-device model, with 8,192 tokens of context, Turgai's `objects_define` alone takes 2,515: almost a third of the window, in turns that never make an object.

The goal is a dictionary: every tool has an **entry**, a line that says what it's for, and its **definition**, the schema, goes to the model only once it has looked the tool up.

## Where this comes from

- Agent Skills: a skill's name and one line are in context; its body loads when it's used.
- Deferred tools in coding agents: the tool list carries names, and a schema is fetched on demand.
- Apple's guidance for Foundation Models: tools and instructions count against one context per session, so load them by app state; `tokenCount(for:)` measures what they take.

Turgai does this by hand today: reading `objects_guide` adds `objects_define` to the turn, through a `ToolSource`. The plan makes it a rule hail applies to any tool.

## Design

How a tool is offered is part of the tool, not of the list it's put in:

```swift
/// How a tool is offered to a model.
public enum Offering: Sendable {
    /// In full, in every request.
    case always
    /// By its entry alone, until the model opens it.
    case onRequest(entry: String)
}

public protocol Tool {
    var offering: Offering { get }  // defaults to .always
}
```

- The tool owns its entry: one line written for that purpose, such as `@Command("define", entry: "Make or change an object")`.
- `TurnTools` doesn't change: the registry reads each tool's `offering`.
- Per turn, the registry holds each tool's state as a value: `enum Disclosed { case listed(entry: String), case open }`. Only open tools send their schema; listed ones add their entry line.
- One tool, `tools_open(name)`, returns the tool's description and opens it from the next round, through the refresh `ToolSource` already uses.
- A call to a listed tool that isn't open gets an error that says to open it, not "there's no tool".

Which tools are open depends on what the model does in a turn, so it's checked when a request is built, from those states, not at compile time.

## Costs

- Opening takes a round: one more model call, in turns that use a listed tool.
- Entries are short, so a model may open the wrong tool; the error and the entry wording are what keep that rare.

## Open questions

- Does an opened tool stay open for the rest of the conversation, or only for the turn?
- Should a tool open itself when the model calls it by name, skipping `tools_open`, at the cost of one failed call?
- How are entries shown: in the system prompt, or as `tools_open`'s description?

## Measure first

Count what tools take before and after: `tokenCount(for:)` for the system model, and the provider-reported prompt size (`prompt_eval_count` for Ollama) for the others.
