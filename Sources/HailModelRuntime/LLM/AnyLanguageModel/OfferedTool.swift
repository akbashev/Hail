import AnyLanguageModel
import HailCore

/// A Hail tool as AnyLanguageModel declares it to the model: its name, description and
/// parameters. Calls never run here: each one goes, through the session's tool execution
/// delegate, to the agent's session the request runs in, which runs it under its authority.
struct OfferedTool: AnyLanguageModel.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = GeneratedContent

    private let tool: AnyTool

    init(_ tool: AnyTool) {
        self.tool = tool
    }

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { tool.schema.parameters }

    /// Reached only by a model that runs tools without asking the session's delegate.
    func call(arguments: GeneratedContent) async throws -> GeneratedContent {
        throw ToolRunsInSession(name: name)
    }
}

/// A model ran a tool itself instead of asking the agent's session to.
struct ToolRunsInSession: Error, CustomStringConvertible {
    let name: String
    var description: String { "`\(name)` runs in the agent's session; this model ran it without asking." }
}
