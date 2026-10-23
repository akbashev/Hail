import ScopedEffect
import Subprocess

#if os(macOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Foundation)
    import Foundation
#endif

/// Generic effect descriptions used by Hail's tools.
///
/// An effect is inert data. Performing it requires an ``EffectToken`` issued
/// by ``withEffect(_:authority:)`` after the current authority grants it.
public struct FileEffect: ScopedEffect, Sendable {
    public enum Action: String, Sendable { case read, write, list }

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
    /// Optional caller-defined operation identity for policy and audit
    /// decisions. It does not affect process execution.
    public let operation: String?
    public let executable: String
    public let arguments: [String]
    public let cwd: String?
    /// Optional bytes written to the child process's standard input after it
    /// starts. The process effect remains unbounded in time; callers own
    /// cancellation and lifecycle policy.
    public let standardInput: Data?
    /// `nil` inherits the host environment; a value replaces it exactly.
    public let environment: [String: String]?
    /// Maximum bytes collected from each output stream. `nil` preserves
    /// unbounded collection for callers that need it.
    public let maximumOutputBytes: Int?
    /// Optional operating-system sandbox policy. `nil` preserves the
    /// historical raw-process behavior; a non-nil policy is enforced by the
    /// live process dependency before the child is launched.
    public let sandbox: ProcessSandboxPolicy?

    public init(
        executable: String,
        arguments: [String],
        cwd: String?,
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        sandbox: ProcessSandboxPolicy? = nil,
        maximumOutputBytes: Int? = nil,
        operation: String? = nil
    ) {
        self.operation = operation
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.standardInput = standardInput
        self.environment = environment
        self.sandbox = sandbox
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct NetworkEffect: ScopedEffect, Sendable {

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

public enum ProcessTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
}

public enum ProcessDependencyError: Error, Equatable, Sendable {
    case invalidOutputLimit(Int)
}

public struct ProcessResult: Sendable, Equatable {
    public let termination: ProcessTermination
    public let standardOutput: Data
    public let standardError: Data

    /// Compatibility accessor for existing callers. Signal termination is
    /// represented losslessly by `termination`; this returns the historical
    /// negative-signal convention for callers that only need an integer.
    public var exitCode: Int32 {
        switch termination {
        case .exited(let code): return code
        case .signaled(let signal): return -signal
        }
    }

    public init(
        exitCode: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.termination = .exited(exitCode)
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public init(
        termination: ProcessTermination,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct ProcessRequest: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let standardInput: Data?
    public let environment: [String: String]?
    public let sandbox: ProcessSandboxPolicy?
    public let maximumOutputBytes: Int?

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        sandbox: ProcessSandboxPolicy? = nil,
        maximumOutputBytes: Int? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.environment = environment
        self.sandbox = sandbox
        self.maximumOutputBytes = maximumOutputBytes
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
        if let maximumOutputBytes = request.maximumOutputBytes,
            maximumOutputBytes < 0
        {
            throw ProcessDependencyError.invalidOutputLimit(maximumOutputBytes)
        }
        let launchRequest = try ProcessSandboxLauncher.prepare(request)
        let environment: Environment
        if let values = launchRequest.environment {
            environment = .custom(
                values.reduce(into: [Environment.Key: String]()) { result, item in
                    guard let key = Environment.Key(rawValue: item.key) else { return }
                    result[key] = item.value
                })
        } else {
            environment = .inherit
        }
        let executable: Executable = .path(FilePath(launchRequest.executable))
        let arguments = Arguments(launchRequest.arguments)
        let workingDirectory = launchRequest.workingDirectory.map { FilePath($0) }
        let output: BytesOutput = .bytes(limit: request.maximumOutputBytes ?? .max)
        let error: BytesOutput = .bytes(limit: request.maximumOutputBytes ?? .max)
        var platformOptions = PlatformOptions()
        #if os(macOS) || os(Linux)
            // Give the launcher and everything it starts a private session. The
            // group-targeted teardown then cleans up shell grandchildren when the
            // caller cancels this operation.
            platformOptions.createSession = true
            platformOptions.teardownSequence = [
                .gracefulShutDown(
                    toProcessGroup: true,
                    allowedDurationToNextStep: .zero
                )
            ]
        #endif
        let result: ExecutionResult<Void, BytesOutput, BytesOutput>
        if let standardInput = launchRequest.standardInput {
            let input: ArrayInput = .array(Array(standardInput))
            result = try await Subprocess.run(
                executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                platformOptions: platformOptions,
                input: input,
                output: output,
                error: error
            )
        } else {
            let input: NoInput = .none
            result = try await Subprocess.run(
                executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                platformOptions: platformOptions,
                input: input,
                output: output,
                error: error
            )
        }
        let termination: ProcessTermination
        switch result.terminationStatus {
        case .exited(let code):
            termination = .exited(Int32(code))
        case .signaled(let signal):
            termination = .signaled(Int32(signal))
        }
        return ProcessResult(
            termination: termination,
            standardOutput: Data(result.standardOutput),
            standardError: Data(result.standardError)
        )
    }
}

/// The request data authorized by ``NetworkEffect``.
public struct NetworkRequest: Sendable, Equatable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let maximumResponseBytes: Int
    /// When present, redirects are allowed only to these normalized hosts.
    /// nil preserves ordinary URLSession redirect behavior.
    public let allowedHosts: Set<String>?

    public init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        maximumResponseBytes: Int = 16 * 1024 * 1024,
        allowedHosts: Set<String>? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.maximumResponseBytes = maximumResponseBytes
        self.allowedHosts = allowedHosts
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
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let redirectPolicy = NetworkRedirectPolicy(allowedHosts: request.allowedHosts)
        let session = URLSession(
            configuration: .default,
            delegate: redirectPolicy,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(for: urlRequest)
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

private final class NetworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    private let allowedHosts: Set<String>?

    init(allowedHosts: Set<String>?) {
        self.allowedHosts = allowedHosts?.map { Self.normalize($0) }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let allowedHosts else {
            completionHandler(request)
            return
        }
        guard let host = request.url?.host,
            allowedHosts.contains(Self.normalize(host))
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func normalize(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

public enum NetworkEffectError: Error, Equatable, Sendable {
    case requestHostMismatch(expected: String, actual: String?)
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
                workingDirectory: effect.cwd,
                standardInput: effect.standardInput,
                environment: effect.environment,
                sandbox: effect.sandbox,
                maximumOutputBytes: effect.maximumOutputBytes
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
    /// Resolves `path` the way the operating system actually would: absolute,
    /// walked one component at a time, following a symlink the instant it is
    /// encountered, and computing `".."` against that real, post-symlink
    /// position — not against the written string.
    ///
    /// Nothing here is lexical. Collapsing `".."` as text silently assumes
    /// every traversed component is a real directory. That assumption is false the moment a
    /// component is a symlink: `link/..` means "the parent of wherever
    /// `link` points," which can be anywhere, not "cancel `link` back to
    /// nothing." A path containment check built on the lexical collapse can
    /// therefore approve a path whose real, symlink-aware resolution lands
    /// somewhere else entirely — including outside an allowed root — because
    /// the very information needed to catch that (that a symlink was
    /// traversed before the `".."`) was already discarded before the check
    /// ran. Resolving component-by-component, the same way `realpath` and
    /// the kernel itself do, cannot lose that information.
    ///
    /// A component that does not exist yet (for example a file about to be
    /// created by a `write`) is appended literally rather than resolved —
    /// nothing not yet on disk can be a symlink — so this also matches a
    /// not-yet-existing target correctly.
    public static func resolveReal(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        // Split on "/" only: on macOS and Linux a backslash is an ordinary
        // filename character, and treating it as a separator would check a
        // different path than the one the file system then opens.
        let rawComponents = path.split(separator: "/")
        var current = isAbsolute ? "/" : (realpathIfExists(".") ?? ".")
        for component in rawComponents {
            switch component {
            case ".":
                continue
            case "..":
                current = parent(of: current)
            default:
                let candidate = current.hasSuffix("/") ? current + component : current + "/" + component
                current = realpathIfExists(candidate) ?? candidate
            }
        }
        return current
    }

    /// True if `path`'s real, symlink-resolved location (see
    /// ``resolveReal(_:)``) is `root` or falls beneath it. This is the check
    /// every path-scoped authority policy must use: a syntactic prefix check
    /// on the raw or lexically normalized string is not sufficient, for the
    /// reason `resolveReal(_:)` documents.
    public static func isContained(_ path: String, in root: String) -> Bool {
        let resolvedRoot = resolveReal(root)
        let resolvedPath = resolveReal(path)
        return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let lastSlash = trimmed.lastIndex(of: "/") else { return "/" }
        let result = String(trimmed[trimmed.startIndex..<lastSlash])
        return result.isEmpty ? "/" : result
    }

    private static func realpathIfExists(_ path: String) -> String? {
        #if os(macOS)
            return path.withCString { pointer in
                guard let resolved = Darwin.realpath(pointer, nil) else { return nil }
                defer { Darwin.free(resolved) }
                return String(cString: resolved)
            }
        #elseif os(Linux)
            return path.withCString { pointer in
                guard let resolved = Glibc.realpath(pointer, nil) else { return nil }
                defer { Glibc.free(resolved) }
                return String(cString: resolved)
            }
        #else
            return nil
        #endif
    }
}

extension FileEffect {
    public static func pathPolicy(scopedTo root: String) -> @Sendable (FileEffect) -> EffectDecision {
        return { effect in
            guard EffectPath.isContained(effect.path, in: root) else {
                return .denied("path '\(effect.path)' is outside the allowed root '\(root)'")
            }
            return .granted
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
                guard EffectPath.isContained(path, in: root) else {
                    return .denied("path '\(path)' is outside the allowed root '\(root)'")
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
