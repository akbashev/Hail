import ScopedEffect

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Foundation)
    import Foundation
#endif

/// Generic effect descriptions used by Hail's tools and model harnesses.
///
/// An effect is inert data. Performing it requires an ``EffectToken`` issued
/// by ``withEffect(_:authority:)`` after the current authority grants it.
public struct FileEffect: ScopedEffect, Sendable {
    public enum Action: String, Sendable { case read, write, list }
    public typealias Output = FileResult

    public let name = "file"
    public let path: String
    public let action: Action
    public let content: String?

    public init(path: String, action: Action, content: String? = nil) {
        self.path = path
        self.action = action
        self.content = content
    }
}

public enum FileResult: Sendable, Equatable {
    case text(String)
    case entries([String])
    case written
}

public enum FileEffectError: Error, Equatable, Sendable {
    case missingContent
}

public struct TerminalEffect: ScopedEffect, Sendable {
    public typealias Output = ProcessResult

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
    public typealias Output = ProcessResult

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
    public typealias Output = NetworkResponse

    public let name = "network"
    public let host: String
    public let operation: String
    public let request: NetworkRequest

    public init(
        host: String,
        operation: String,
        request: NetworkRequest
    ) {
        self.host = host
        self.operation = operation
        self.request = request
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        exitCode: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct ProcessRequest: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct ProcessDependency: Sendable {
    public let run: @Sendable (ProcessRequest) async throws -> ProcessResult

    public init(
        run: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult
    ) {
        self.run = run
    }

    public static let live = Self { request in
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: request.executable)
            process.arguments = request.arguments
            process.currentDirectoryURL = request.workingDirectory.map(URL.init(fileURLWithPath:))
            process.standardOutput = standardOutput
            process.standardError = standardError
            process.terminationHandler = { process in
                continuation.resume(
                    returning: ProcessResult(
                        exitCode: process.terminationStatus,
                        standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                        standardError: standardError.fileHandleForReading.readDataToEndOfFile()
                    )
                )
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The request data authorized by ``NetworkEffect``.
public struct NetworkRequest: Sendable, Equatable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let maximumResponseBytes: Int

    public init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        maximumResponseBytes: Int = 16 * 1024 * 1024
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.maximumResponseBytes = maximumResponseBytes
    }

    public var host: String? {
        URL(string: url)?.host
    }
}

/// The transport result returned by a network effect.
public struct NetworkResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum NetworkDependencyError: Error, Equatable, Sendable {
    case unavailable
    case invalidURL
    case invalidResponse
    case responseTooLarge
}

/// The actual HTTP boundary used by ``NetworkEffect.run(in:)``.
///
/// It is a dependency rather than part of the effect configuration. The
/// effect carries only request data; callers cannot obtain this client from an
/// effect token. Tests can replace it with ``withDependencies``.
public struct NetworkDependency: Sendable {
    public let send: @Sendable (NetworkRequest) async throws -> NetworkResponse

    public init(
        send: @escaping @Sendable (NetworkRequest) async throws -> NetworkResponse
    ) {
        self.send = send
    }

    public static let live = Self { request in
        guard let url = URL(string: request.url) else {
            throw NetworkDependencyError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { name, value in
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await URLSession.shared.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw NetworkDependencyError.invalidResponse
        }
        guard body.count <= request.maximumResponseBytes else {
            throw NetworkDependencyError.responseTooLarge
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else { return }
            result[key] = String(describing: item.value)
        }
        return NetworkResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: body
        )
    }
}

public enum NetworkEffectError: Error, Equatable, Sendable {
    case requestHostMismatch(expected: String, actual: String?)
}

/// An externally visible host operation that is not naturally a file,
/// terminal, process, or network effect.
public struct CoordinationEffect: ScopedEffect, Sendable {
    public typealias Output = String

    public let name = "coordination"
    public let subsystem: String
    public let action: String

    public init(subsystem: String, action: String) {
        self.subsystem = subsystem
        self.action = action
    }
}

public struct CoordinationRequest: Sendable, Equatable {
    public let subsystem: String
    public let action: String

    public init(subsystem: String, action: String) {
        self.subsystem = subsystem
        self.action = action
    }
}

public struct CoordinationDependency: Sendable {
    public let run: @Sendable (CoordinationRequest) async throws -> String

    public init(
        run: @escaping @Sendable (CoordinationRequest) async throws -> String
    ) {
        self.run = run
    }

    public static let live = Self { request in
        "\(request.subsystem).\(request.action)"
    }
}

/// The dependency used to read the current wall-clock instant.
///
/// It is installed once at an application or test boundary. Individual
/// effects only request the clock capability; they do not have to carry a
/// copy of this implementation around.
public struct DateDependency: Sendable {
    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public static let live = Self()

    public static func fixed(_ date: Date) -> Self {
        Self(now: { date })
    }
}

/// The dependency values available to Hail effects.
public struct HailDependencies: Sendable {
    public var date: DateDependency
    public var network: NetworkDependency
    public var process: ProcessDependency
    public var coordination: CoordinationDependency

    public init(
        date: DateDependency = .live,
        network: NetworkDependency = .live,
        process: ProcessDependency = .live,
        coordination: CoordinationDependency = .live
    ) {
        self.date = date
        self.network = network
        self.process = process
        self.coordination = coordination
    }

    public static let live = Self()
}

private enum HailDependencyScope {
    @TaskLocal
    static var values: HailDependencies = .live
}

/// Runs an operation with scoped Hail dependencies.
///
/// Overrides are task-local: concurrent operations do not affect one another,
/// and child tasks inherit the values of their parent operation.
public func withDependencies<Result>(
    _ update: (inout HailDependencies) -> Void,
    operation: () async throws -> Result
) async rethrows -> Result {
    var values = HailDependencyScope.values
    update(&values)
    return try await HailDependencyScope.$values.withValue(values) {
        try await operation()
    }
}

public struct ClockEffect: ScopedEffect, Sendable {
    public typealias Output = Date
    public let name = "clock"

    public init() {}
}

extension ClockEffect {
    /// Reads the clock only while the clock capability is in scope.
    public static func run(
        in token: borrowing EffectToken<ClockEffect>
    ) async throws -> Date {
        HailDependencyScope.values.date.now()
    }
}

extension FileEffect {
    public static func run(
        in token: borrowing EffectToken<FileEffect>
    ) async throws -> FileResult {
        let effect = token.withConfiguration { $0 }
        let fileManager = FileManager.default
        switch effect.action {
        case .read:
            return .text(try String(contentsOfFile: effect.path, encoding: .utf8))
        case .write:
            guard let content = effect.content else {
                throw FileEffectError.missingContent
            }
            let directory = URL(fileURLWithPath: effect.path).deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try content.write(toFile: effect.path, atomically: true, encoding: .utf8)
            return .written
        case .list:
            return .entries(
                try fileManager.contentsOfDirectory(atPath: effect.path).sorted()
            )
        }
    }
}

public enum ProcessEffectError: Error, Equatable, Sendable {
    case emptyCommand
}

extension ProcessEffect {
    public static func run(
        in token: borrowing EffectToken<ProcessEffect>
    ) async throws -> ProcessResult {
        let request = token.withConfiguration { effect in
            ProcessRequest(
                executable: effect.executable,
                arguments: effect.arguments,
                workingDirectory: effect.cwd
            )
        }
        return try await HailDependencyScope.values.process.run(request)
    }
}

extension TerminalEffect {
    public static func run(
        in token: borrowing EffectToken<TerminalEffect>
    ) async throws -> ProcessResult {
        let request = try token.withConfiguration { effect in
            let tokens = effect.tokens
            guard let executable = tokens.first else {
                throw ProcessEffectError.emptyCommand
            }
            return ProcessRequest(
                executable: executable,
                arguments: Array(tokens.dropFirst()),
                workingDirectory: effect.cwd
            )
        }
        return try await HailDependencyScope.values.process.run(request)
    }
}

extension NetworkEffect {
    public static func run(
        in token: borrowing EffectToken<NetworkEffect>
    ) async throws -> NetworkResponse {
        let (host, request) = token.withConfiguration { ($0.host, $0.request) }
        let actualHost = request.host
        guard normalizeHost(actualHost ?? "") == normalizeHost(host) else {
            throw NetworkEffectError.requestHostMismatch(
                expected: host,
                actual: actualHost
            )
        }
        return try await HailDependencyScope.values.network.send(request)
    }
}

extension CoordinationEffect {
    public static func run(
        in token: borrowing EffectToken<CoordinationEffect>
    ) async throws -> String {
        let request = token.withConfiguration {
            CoordinationRequest(subsystem: $0.subsystem, action: $0.action)
        }
        return try await HailDependencyScope.values.coordination.run(request)
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
