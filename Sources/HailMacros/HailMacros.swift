import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private struct EffectMethod {
    let function: FunctionDeclSyntax
    let name: String
    let description: String?
    let argumentsType: String?
    let effectType: String
    let argumentLabel: String?
    let isThrowing: Bool
}

private struct ToolMetadata {
    let name: String?
    let description: String?
}

private func stringLiteral(_ expression: ExprSyntax?) -> String? {
    guard let expression = expression?.as(StringLiteralExprSyntax.self) else { return nil }
    return expression.segments.compactMap {
        $0.as(StringSegmentSyntax.self)?.content.text
    }.joined()
}

private func metadata(_ node: AttributeSyntax) -> ToolMetadata {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
        return ToolMetadata(name: nil, description: nil)
    }

    let positionalName = arguments.first(where: { $0.label == nil }).flatMap {
        stringLiteral($0.expression)
    }
    let labeledDescription = arguments.first(where: { $0.label?.text == "description" }).flatMap {
        stringLiteral($0.expression)
    }
    return ToolMetadata(name: positionalName, description: labeledDescription)
}

private func stringArgument(_ node: AttributeSyntax) -> String? {
    metadata(node).name
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
            let returnType = function.signature.returnClause?.type
        else { return nil }

        let parameters = function.signature.parameterClause.parameters
        guard parameters.count <= 1 else { return nil }
        let parameter = parameters.first
        return EffectMethod(
            function: function,
            name: stringArgument(command) ?? function.name.text,
            description: metadata(command).description,
            argumentsType: parameter?.type.trimmedDescription,
            effectType: returnType.trimmedDescription,
            argumentLabel: parameter.flatMap { $0.firstName.text == "_" ? nil : $0.firstName.text },
            isThrowing: function.signature.effectSpecifiers?.throwsClause != nil
        )
    }
}

private func standaloneEffect(in declaration: some DeclGroupSyntax) -> EffectMethod? {
    declaration.memberBlock.members.compactMap { member in
        guard let function = member.decl.as(FunctionDeclSyntax.self),
            function.name.text == "effect",
            let returnType = function.signature.returnClause?.type
        else { return nil }

        let parameters = function.signature.parameterClause.parameters
        guard parameters.count <= 1 else { return nil }
        let parameter = parameters.first
        return EffectMethod(
            function: function,
            name: "",
            description: nil,
            argumentsType: parameter?.type.trimmedDescription,
            effectType: returnType.trimmedDescription,
            argumentLabel: parameter.flatMap { $0.firstName.text == "_" ? nil : $0.firstName.text },
            isThrowing: function.signature.effectSpecifiers?.throwsClause != nil
        )
    }.first
}

private func hasRenderMethod(in declaration: some DeclGroupSyntax) -> Bool {
    declaration.memberBlock.members.contains { member in
        member.decl.as(FunctionDeclSyntax.self)?.name.text == "render"
    }
}

private func hasExistingToolImplementation(in declaration: some DeclGroupSyntax) -> Bool {
    return declaration.memberBlock.members.contains { member in
        member.decl.as(FunctionDeclSyntax.self)?.name.text == "run"
    }
}

private func hasStoredProperty(named name: String, in declaration: some DeclGroupSyntax) -> Bool {
    declaration.memberBlock.members.contains { member in
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
        return variable.bindings.contains { binding in
            binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name
        }
    }
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
            guard let method = standaloneEffect(in: declaration) else {
                return []
            }
            let toolMetadata = metadata(node)
            var generated: [DeclSyntax] = []
            if !hasStoredProperty(named: "name", in: declaration), let name = toolMetadata.name {
                generated.append(DeclSyntax(stringLiteral: #"public let name = "\#(name)""#))
            }
            if !hasStoredProperty(named: "description", in: declaration), let description = toolMetadata.description {
                generated.append(DeclSyntax(stringLiteral: #"public let description = "\#(description)""#))
            }

            // Existing run/schema implementations only need metadata. The
            // macro must not replace their execution path.
            guard !hasExistingToolImplementation(in: declaration), hasRenderMethod(in: declaration) else {
                return generated
            }

            let input =
                method.argumentsType.map { "public typealias Input = \($0)" }
                ?? "public typealias Input = HailCore.EmptyToolInput"
            generated.append(contentsOf: [
                DeclSyntax(stringLiteral: input),
                DeclSyntax(stringLiteral: "public typealias Effect = \(method.effectType)"),
                DeclSyntax(
                    stringLiteral:
                        "public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: Input.generationSchema) }"
                ),
                DeclSyntax(
                    stringLiteral: """
                        public func run(
                            input: Input,
                            token: borrowing EffectToken<Effect>
                        ) async throws -> String {
                            let output: Effect.Output = try await Effect.run(in: token)
                            return render(output)
                        }
                        """),
            ])
            return generated
        }

        let type = declaration.as(StructDeclSyntax.self)?.name.text ?? "Tool"
        let inferredName =
            type.hasSuffix("Tools")
            ? String(type.dropLast(5)).lowercased()
            : type.lowercased()
        let groupName = stringArgument(node) ?? inferredName
        var generated: [DeclSyntax] = []
        var tools: [String] = []

        for command in commands {
            let wrapper = command.name.prefix(1).uppercased() + command.name.dropFirst() + "Tool"
            tools.append("\(wrapper)(owner: self)")
            let input =
                command.argumentsType.map { "public typealias Input = \($0)" }
                ?? "public typealias Input = HailCore.EmptyToolInput"
            let invocation: String
            if let argumentLabel = command.argumentLabel {
                let call = "owner.\(command.function.name.text)(\(argumentLabel): input)"
                invocation = command.isThrowing ? "try \(call)" : call
            } else if command.argumentsType != nil {
                let call = "owner.\(command.function.name.text)(input)"
                invocation = command.isThrowing ? "try \(call)" : call
            } else {
                let call = "owner.\(command.function.name.text)()"
                invocation = command.isThrowing ? "try \(call)" : call
            }
            generated.append(
                DeclSyntax(
                    stringLiteral: """
                            public struct \(wrapper): HailCore.Tool {
                            \(input)
                            public typealias Effect = \(command.effectType)
                            public let owner: \(type)
                            public var name: String { "\(groupName)_\(command.name)" }
                            public var description: String { "\(command.description ?? command.name)" }
                            public var schema: ToolDefinition { ToolDefinition(name: name, description: description, parameters: Input.generationSchema) }
                            public func effect(for input: Input) throws -> Effect { \(invocation) }
                            public func run(input: Input, token: borrowing EffectToken<Effect>) async throws -> String {
                                let output: Effect.Output = try await Effect.run(in: token)
                                return owner.render(output)
                            }
                        }
                        """))
        }

        generated.append(
            DeclSyntax(stringLiteral: "public var tools: [any HailCore.Tool] { [\(tools.joined(separator: ", "))] }"))
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
            hasRenderMethod(in: declaration) || hasExistingToolImplementation(in: declaration)
        else {
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
