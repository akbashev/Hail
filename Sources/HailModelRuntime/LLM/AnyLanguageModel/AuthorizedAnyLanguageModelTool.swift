import AnyLanguageModel
import HailCore

/// Adapts a Hail tool to AnyLanguageModel's tool protocol without moving
/// effect authorization into the model session.
///
/// AnyLanguageModel supplies decoded `GeneratedContent`; Hail decodes that
/// content through the tool's native input boundary and opens the concrete
/// effect token with the supplied authority.
struct AuthorizedAnyLanguageModelTool: AnyLanguageModel.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    private let tool: AnyTool
    private let authority: any Authority

    init(tool: AnyTool, authority: any Authority) {
        self.tool = tool
        self.authority = authority
    }

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { tool.schema.parameters }

    func call(arguments: GeneratedContent) async throws -> String {
        try await tool.run(
            generatedContent: arguments,
            authority: authority
        )
    }
}
