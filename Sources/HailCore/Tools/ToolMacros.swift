/// Generates one Hail ``Tool`` from a standalone tool type.
@attached(member, names: arbitrary)
@attached(extension, conformances: Tool)
public macro Tool(
    _ name: String? = nil,
    description: String? = nil
) = #externalMacro(module: "HailMacros", type: "ToolMacro")

@attached(peer)
public macro Command(
    _ name: String? = nil,
    description: String? = nil
) = #externalMacro(module: "HailMacros", type: "CommandMacro")
