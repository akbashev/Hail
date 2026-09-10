import Hail

enum TestToolDefinition {
    static func empty(name: String, description: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: ToolSchema.object(
                name: "(name)Arguments",
                description: "Arguments for (name).",
                properties: []
            )
        )
    }
}
