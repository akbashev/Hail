import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Tool
public struct FileTool {
    public enum Action: String, Codable, Sendable {
        case read, write, replace, list, exists

        /// The effect-domain action this tool action funnels into.
        var effectAction: FileEffect.Action {
            switch self {
            case .read, .exists: .read
            case .write, .replace: .write
            case .list: .list
            }
        }
    }

    public struct Input: Codable, Sendable {
        public let action: Action
        public let path: String
        public let content: String?
        public let oldContent: String?
        public let newContent: String?

        enum CodingKeys: String, CodingKey {
            case action, path, content
            case oldContent = "old_content"
            case newContent = "new_content"
        }
    }

    public let name = "file"
    public let description =
        "Read and write files in the project. Use this to read code, write new files, or edit existing ones."

    public var schema: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            parameters: ToolSchema.object(
                name: "FileArguments",
                description: "Arguments for a file operation.",
                properties: [
                    .init(
                        name: "action",
                        description: "The action: read, write, replace, list, or exists.",
                        schema: ToolSchema.string(
                            name: "FileAction",
                            choices: ["read", "write", "replace", "list", "exists"]
                        )
                    ),
                    .init(
                        name: "path",
                        description: "Relative path to the file or directory.",
                        schema: ToolSchema.string(name: "FilePath")
                    ),
                    .init(
                        name: "content",
                        description: "File content for write action.",
                        schema: ToolSchema.string(name: "FileContent"),
                        isOptional: true
                    ),
                    .init(
                        name: "old_content",
                        description: "Exact existing text to replace for replace action.",
                        schema: ToolSchema.string(name: "OldFileContent"),
                        isOptional: true
                    ),
                    .init(
                        name: "new_content",
                        description: "Replacement text for replace action.",
                        schema: ToolSchema.string(name: "NewFileContent"),
                        isOptional: true
                    )
                ]
            )
        )
    }

    private let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Pure: resolves the model-supplied path against the project root into
    /// the effect configuration. Whether the resolved path is allowed is the
    /// authority's decision (see `FileEffect.pathPolicy(scopedTo:)`), not the
    /// tool's.
    public func effect(for input: Input) throws -> FileEffect {
        let resolved =
            input.path.hasPrefix("/")
            ? EffectPath.normalize(input.path)
            : EffectPath.normalize(projectRoot.path + "/" + input.path)
        return FileEffect(path: resolved, action: input.action.effectAction)
    }

    public func run(input: Input, token: borrowing EffectToken<FileEffect>) async throws -> String {
        let path = input.path
        let fullPath = token.withConfiguration { URL(fileURLWithPath: $0.path) }
        let fileManager = FileManager.default

        switch input.action {
        case .read:
            guard fileManager.fileExists(atPath: fullPath.path) else {
                return "Error: File not found at \(path)"
            }
            let content = try String(contentsOf: fullPath, encoding: .utf8)
            return content

        case .write:
            guard let content = input.content else {
                throw ToolError.missingArgument("content")
            }
            let directory = fullPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            try content.write(to: fullPath, atomically: true, encoding: .utf8)
            return "Wrote to \(path)"

        case .replace:
            guard let oldContent = input.oldContent else {
                throw ToolError.missingArgument("old_content")
            }
            guard let newContent = input.newContent else {
                throw ToolError.missingArgument("new_content")
            }
            guard fileManager.fileExists(atPath: fullPath.path) else {
                return "Error: File not found at \(path)"
            }
            let content = try String(contentsOf: fullPath, encoding: .utf8)
            guard content.contains(oldContent) else {
                throw ToolError.invalidArgument("old_content", value: "not found in \(path)")
            }
            let updated = content.replacingOccurrences(of: oldContent, with: newContent)
            try updated.write(to: fullPath, atomically: true, encoding: .utf8)
            return "Replaced text in \(path)"

        case .list:
            let contents = try fileManager.contentsOfDirectory(atPath: fullPath.path)
            return contents.joined(separator: "\n")

        case .exists:
            let exists = fileManager.fileExists(atPath: fullPath.path)
            return exists ? "exists" : "not found"
        }
    }
}
