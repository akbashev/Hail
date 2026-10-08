import AnyLanguageModel
import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Tool(
    "file",
    description: "Read and write files in the project. Use this to read code, write new files, or edit existing ones."
)
public struct FileTool {
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
                    ),
                ]
            )
        )
    }

    private let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Pure: resolves the model-supplied path against the project root into
    /// the effect configuration. A model-supplied leading slash is treated as
    /// workspace-relative (like a chroot), never as a host-absolute path — the
    /// model has no way to name anything outside `projectRoot` by
    /// construction. Whether the resolved path is still allowed is the
    /// authority's decision (see `FileEffect.pathPolicy(scopedTo:)`), not the
    /// tool's.
    ///
    /// Deliberately not lexically collapsed here (see `EffectPath.resolveReal`
    /// for why): the authority needs the real, uncollapsed structure to
    /// detect a symlink-then-".." escape, and `runOutput` executes this exact
    /// same string, so the operating system resolves it identically to how
    /// the authority checked it.
    public func effect(for input: FileToolInput) throws -> FileEffect {
        let relative = input.path.hasPrefix("/") ? String(input.path.dropFirst()) : input.path
        let resolved = projectRoot.path + "/" + relative
        return FileEffect(path: resolved, action: input.action.effectAction)
    }

    public func run(_ input: FileToolInput, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<FileEffect>) async throws -> Page {
        let path = input.path
        let fullPath = token.withConfiguration { URL(fileURLWithPath: $0.path) }
        let fileManager = FileManager.default

        switch input.action {
        case .read:
            guard fileManager.fileExists(atPath: fullPath.path) else {
                return .text("Error: File not found at \(path)")
            }
            let content = try String(contentsOf: fullPath, encoding: .utf8)
            return .text(content)

        case .write:
            guard let content = input.content else {
                throw ToolError.missingArgument("content")
            }
            let directory = fullPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            try content.write(to: fullPath, atomically: true, encoding: .utf8)
            return .text("Wrote to \(path)")

        case .replace:
            guard let oldContent = input.oldContent else {
                throw ToolError.missingArgument("old_content")
            }
            guard let newContent = input.newContent else {
                throw ToolError.missingArgument("new_content")
            }
            guard fileManager.fileExists(atPath: fullPath.path) else {
                return .text("Error: File not found at \(path)")
            }
            let content = try String(contentsOf: fullPath, encoding: .utf8)
            guard content.contains(oldContent) else {
                throw ToolError.invalidArgument("old_content", value: "not found in \(path)")
            }
            let updated = content.replacingOccurrences(of: oldContent, with: newContent)
            try updated.write(to: fullPath, atomically: true, encoding: .utf8)
            return .text("Replaced text in \(path)")

        case .list:
            let contents = try fileManager.contentsOfDirectory(atPath: fullPath.path)
            return .text(contents.joined(separator: "\n"))

        case .exists:
            let exists = fileManager.fileExists(atPath: fullPath.path)
            return .text(exists ? "exists" : "not found")
        }
    }
}

@Generable
public enum FileToolAction: String, Codable, Sendable {
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

@Generable
public struct FileToolInput: Sendable {
    public let action: FileToolAction
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
