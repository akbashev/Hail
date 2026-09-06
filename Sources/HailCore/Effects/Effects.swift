import ScopedEffect

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Generic effect descriptions used by Hail's tools and model harnesses.
///
/// An effect is inert data. Performing it requires an ``EffectToken`` issued
/// by ``withEffect(_:authority:)`` after the current authority grants it.
public struct FileEffect: ScopedEffect, Sendable {
    public enum Action: String, Sendable { case read, write, list }

    public let name = "file"
    public let path: String
    public let action: Action

    public init(path: String, action: Action) {
        self.path = path
        self.action = action
    }
}

public struct TerminalEffect: ScopedEffect, Sendable {
    public let name = "terminal"
    public let command: String
    public let arguments: [String]
    public let cwd: String

    public init(command: String, arguments: [String] = [], cwd: String) {
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
    }

    public var tokens: [String] {
        command.split(separator: " ").map(String.init) + arguments
    }
}

public struct ProcessEffect: ScopedEffect, Sendable {
    public let name = "process"
    public let executable: String
    public let arguments: [String]
    public let cwd: String?

    public init(executable: String, arguments: [String], cwd: String?) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
    }
}

public struct NetworkEffect: ScopedEffect, Sendable {
    public let name = "network"
    public let host: String
    public let operation: String

    public init(host: String, operation: String) {
        self.host = host
        self.operation = operation
    }
}

/// An externally visible host operation that is not naturally a file,
/// terminal, process, or network effect.
public struct CoordinationEffect: ScopedEffect, Sendable {
    public let name = "coordination"
    public let subsystem: String
    public let action: String

    public init(subsystem: String, action: String) {
        self.subsystem = subsystem
        self.action = action
    }
}

public struct ClockEffect: ScopedEffect, Sendable {
    public let name = "clock"

    fileprivate let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }
}

extension EffectToken where Effect == ClockEffect {
    /// Reads the clock only while the clock capability is in scope.
    public func now() -> Date {
        withConfiguration { $0.now() }
    }
}

public enum EffectPath {
    public static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        let components = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
        var stack: [String] = []
        for component in components {
            switch component {
            case "", ".": break
            case "..":
                if !stack.isEmpty, stack.last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(component)
                }
            default: stack.append(component)
            }
        }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }
}

extension FileEffect {
    public static func pathPolicy(scopedTo root: String) -> @Sendable (FileEffect) -> EffectDecision {
        let normalizedRoot = EffectPath.normalize(root)
        return { effect in
            let path = EffectPath.normalize(effect.path)
            return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
                ? .granted
                : .denied("path '\(effect.path)' is outside the allowed root '\(normalizedRoot)'")
        }
    }

    public static func readOnlyPathPolicy(scopedTo root: String) -> @Sendable (FileEffect) -> EffectDecision {
        let scoped = pathPolicy(scopedTo: root)
        return { effect in
            guard effect.action != .write else { return .denied("read-only authority: writes are not permitted") }
            return scoped(effect)
        }
    }
}

private func tokensAllowed(_ tokens: [String], by prefixes: [[String]]) -> Bool {
    prefixes.contains { prefix in
        prefix.count <= tokens.count && Array(tokens.prefix(prefix.count)) == prefix
    }
}

private func commandDenial(_ tokens: [String], _ allowed: [String]) -> EffectDecision {
    .denied("command '\(tokens.joined(separator: " "))' is not in the allowlist (\(allowed.joined(separator: ", ")))")
}

extension TerminalEffect {
    private static let shellMetacharacters = ["&&", "||", ";", "|", ">", "<", "`", "$("]

    public static func commandPolicy(allowing allowed: [String]) -> @Sendable (TerminalEffect) -> EffectDecision {
        let prefixes = allowed.map { $0.split(separator: " ").map(String.init) }
        return { effect in
            tokensAllowed(effect.tokens, by: prefixes) ? .granted : commandDenial(effect.tokens, allowed)
        }
    }

    /// Adds filesystem containment and rejects compound shell syntax while
    /// retaining token-prefix command matching.
    public static func commandPolicy(allowing allowed: [String], root: String)
        -> @Sendable (TerminalEffect) -> EffectDecision
    {
        let prefixes = allowed.map { $0.split(separator: " ").map(String.init) }
        let normalizedRoot = EffectPath.normalize(root)
        return { effect in
            guard
                !effect.tokens.contains(where: { token in
                    shellMetacharacters.contains(where: token.contains)
                })
            else {
                return .denied("compound commands are not permitted; run each step separately")
            }
            guard tokensAllowed(effect.tokens, by: prefixes) else {
                return commandDenial(effect.tokens, allowed)
            }
            for path in effect.tokens.dropFirst().filter({ $0.hasPrefix("/") }) {
                let normalized = EffectPath.normalize(path)
                guard normalized == normalizedRoot || normalized.hasPrefix(normalizedRoot + "/") else {
                    return .denied("path '\(path)' is outside the allowed root '\(normalizedRoot)'")
                }
            }
            return .granted
        }
    }
}

extension ProcessEffect {
    public static func commandPolicy(allowing allowed: [String]) -> @Sendable (ProcessEffect) -> EffectDecision {
        let prefixes = allowed.map { $0.split(separator: " ").map(String.init) }
        return { effect in
            let basename = effect.executable.split(separator: "/").last.map(String.init) ?? effect.executable
            let tokens = [basename] + effect.arguments
            return tokensAllowed(tokens, by: prefixes) ? .granted : commandDenial(tokens, allowed)
        }
    }
}

private func normalizeHost(_ host: String) -> String {
    var normalized = host.lowercased()
    while normalized.hasSuffix(".") { normalized.removeLast() }
    return normalized
}

extension NetworkEffect {
    public static func hostPolicy(allowing hosts: [String]) -> @Sendable (NetworkEffect) -> EffectDecision {
        let allowed = hosts.map(normalizeHost)
        return { effect in
            allowed.contains(normalizeHost(effect.host))
                ? .granted
                : .denied("host '\(effect.host)' is not in the allowlist (\(allowed.joined(separator: ", ")))")
        }
    }
}

extension CompositeAuthority {
    /// A practical default for an autonomous agent: filesystem access remains
    /// inside its workspace while other generic runtime effects are granted.
    public static func workspaceDefault(root: String) -> CompositeAuthority {
        CompositeAuthority()
            .granting(for: FileEffect.self, decide: FileEffect.pathPolicy(scopedTo: root))
            .grantingAll(for: TerminalEffect.self)
            .grantingAll(for: ProcessEffect.self)
            .grantingAll(for: NetworkEffect.self)
            .grantingAll(for: CoordinationEffect.self)
            .grantingAll(for: ClockEffect.self)
    }

    public static var untrustedInput: CompositeAuthority {
        CompositeAuthority()
            .granting(for: FileEffect.self) { _ in .denied("untrusted-input lane cannot access files") }
            .granting(for: TerminalEffect.self) { _ in .denied("untrusted-input lane cannot run terminal commands") }
            .granting(for: ProcessEffect.self) { _ in .denied("untrusted-input lane cannot spawn processes") }
            .granting(for: NetworkEffect.self) { _ in .denied("untrusted-input lane cannot access the network") }
            .granting(for: CoordinationEffect.self) { _ in
                .denied("untrusted-input lane cannot perform coordination operations")
            }
            .granting(for: ClockEffect.self) { _ in .denied("untrusted-input lane cannot read the clock") }
    }
}

public enum TurnAuthorityLane: String, Codable, Sendable {
    case untrustedInput

    public var authority: any Authority {
        switch self {
        case .untrustedInput: CompositeAuthority.untrustedInput
        }
    }
}
