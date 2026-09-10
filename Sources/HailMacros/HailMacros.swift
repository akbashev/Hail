import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private struct EffectMethod {
    let function: FunctionDeclSyntax
    let name: String
    let argumentsType: String
    let effectType: String
    let argumentLabel: String?
}

private func stringArgument(_ node: AttributeSyntax) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
          let expression = arguments.first?.expression.as(StringLiteralExprSyntax.self)
    else { return nil }
    return expression.segments.compactMap {
        $0.as(StringSegmentSyntax.self)?.content.text
    }.joined()
}

private func attribute(named name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
    attributes.compactMap { $0.as(AttributeSyntax.self) }.first {
        $0.attributeName.trimmedDescription == name
    }
}

private func effectMethods(in declaration: some DeclGroupSyntax) -> [EffectMethod] {
    declaration.memberBlock.members.compactMap { member in
        guard let function = member.decl.as(FunctionDeclSyntax.self),
              let command = attribute(named: "Command", in: function.attributes),
              let parameter = function.signature.parameterClause.parameters.first,
              let returnType = function.signature.returnClause?.type
        else { return nil }

        let firstName = parameter.firstName.text
        return EffectMethod(
            function: function,
            name: stringArgument(command) ?? function.name.text,
            argumentsType: parameter.type.trimmedDescription,
            effectType: returnType.trimmedDescription,
            argumentLabel: firstName == "_" ? nil : firstName
        )
    }
}

private func standaloneEffect(in declaration: some DeclGroupSyntax) -> EffectMethod? {
    declaration.memberBlock.members.compactMap { member in
        guard let function = member.decl.as(FunctionDeclSyntax.self),
              function.name.text == "effect",
              let parameter = function.signature.parameterClause.parameters.first,
              let returnType = function.signature.returnClause?.type
        else { return nil }

        return EffectMethod(
            function: function,
            name: "",
            argumentsType: parameter.type.trimmedDescription,
            effectType: returnType.trimmedDescription,
            argumentLabel: parameter.firstName.text == "_" ? nil : parameter.firstName.text
        )
    }.first
}

private func hasRenderMethod(in declaration: some DeclGroupSyntax) -> Bool {
    declaration.memberBlock.members.contains { member in
        member.decl.as(FunctionDeclSyntax.self)?.name.text == "render"
    }
}

private func hasExistingToolImplementation(in declaration: some DeclGroupSyntax) -> Bool {
    let hasRun = declaration.memberBlock.members.contains { member in
        member.decl.as(FunctionDeclSyntax.self)?.name.text == "run"
    }
    let hasSchema = declaration.memberBlock.members.contains { member in
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
        return variable.bindings.contains {
            $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "schema"
        }
    }
    return hasRun && hasSchema
}

public struct CommandMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

public struct ToolMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let commands = effectMethods(in: declaration)
        guard !commands.isEmpty else {
            guard let method = standaloneEffect(in: declaration),
                  hasRenderMethod(in: declaration),
                  !hasExistingToolImplementation(in: declaration) else {
                return []
            }
            return [
                DeclSyntax(stringLiteral: "public typealias Input = \(method.argumentsType)"),
                DeclSyntax(stringLiteral: "public typealias Effect = \(method.effectType)"),
                DeclSyntax(stringLiteral: "public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: Input.generationSchema) }"),
                DeclSyntax(stringLiteral: """
                    public func run(
                        input: Input,
                        token: borrowing EffectToken<Effect>
                    ) async throws -> String {
                        let output = try await Effect.run(in: token)
                        return render(output)
                    }
                    """),
            ]
        }

        let type = declaration.as(StructDeclSyntax.self)?.name.text ?? "Tool"
        let inferredName = type.hasSuffix("Tools")
            ? String(type.dropLast(5)).lowercased()
            : type.lowercased()
        let groupName = stringArgument(node) ?? inferredName
        var generated: [DeclSyntax] = []
        var tools: [String] = []

        for command in commands {
            let wrapper = command.name.prefix(1).uppercased() + command.name.dropFirst() + "Tool"
            tools.append("\(wrapper)(owner: self)")
            let invocation = command.argumentLabel.map {
                "try owner.\(command.function.name.text)(\($0): input)"
            } ?? "try owner.\(command.function.name.text)(input)"
            generated.append(DeclSyntax(stringLiteral: """
                    public struct \(wrapper): HailCore.Tool {
                    public typealias Input = \(command.argumentsType)
                    public typealias Effect = \(command.effectType)
                    public let owner: \(type)
                    public var name: String { "\(groupName)_\(command.name)" }
                    public var description: String { "\(command.name)" }
                    public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: Input.generationSchema) }
                    public func effect(for input: Input) throws -> Effect { \(invocation) }
                    public func run(input: Input, token: borrowing EffectToken<Effect>) async throws -> String {
                        let output = try await Effect.run(in: token)
                        return owner.render(output)
                    }
                }
                """))
        }

        generated.append(DeclSyntax(stringLiteral: "public var tools: [any HailCore.Tool] { [\(tools.joined(separator: ", "))] }"))
        return generated
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard effectMethods(in: declaration).isEmpty,
              standaloneEffect(in: declaration) != nil,
              (hasRenderMethod(in: declaration) || hasExistingToolImplementation(in: declaration)) else {
            return []
        }
        let decl: DeclSyntax = "extension \(type.trimmed): HailCore.Tool {}"
        return [decl.cast(ExtensionDeclSyntax.self)]
    }
}

@main
struct HailPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ToolMacro.self, CommandMacro.self]
}
