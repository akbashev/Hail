#if os(macOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The portable policy requested for a native process.
///
/// This is deliberately a capability description rather than an operating
/// system profile. The live process dependency translates it to the host's
/// sandbox primitive. A policy is fail-closed: if the platform backend is not
/// available, the process is not launched.
public struct ProcessSandboxPolicy: Sendable, Equatable {
    public enum Network: String, Sendable, Equatable {
        case denied
        case inherited
    }

    public enum Environment: String, Sendable, Equatable {
        case clear
        case inherited
    }

    /// Paths the child may read but not write. Paths must be absolute. If a
    /// path appears in both lists, read-only wins.
    public let readOnlyPaths: [String]
    /// Paths the child may read and write. Paths must be absolute.
    public let readWritePaths: [String]
    public let network: Network
    public let environment: Environment

    public init(
        readOnlyPaths: [String] = [],
        readWritePaths: [String] = [],
        network: Network = .denied,
        environment: Environment = .clear
    ) {
        self.readOnlyPaths = readOnlyPaths
        self.readWritePaths = readWritePaths
        self.network = network
        self.environment = environment
    }
}

public enum ProcessSandboxError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedPlatform
    case backendUnavailable(String)
    case invalidPolicy(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            "native process sandboxing is unsupported on this platform"
        case .backendUnavailable(let backend):
            "native process sandbox backend is unavailable: \(backend)"
        case .invalidPolicy(let reason):
            "invalid native process sandbox policy: \(reason)"
        }
    }
}

/// Converts a portable policy into a concrete launcher request.
///
/// This type is intentionally internal. Hail exposes the policy and keeps
/// the OS-specific command construction behind the live dependency boundary.
enum ProcessSandboxLauncher {
    static func prepare(_ request: ProcessRequest) throws -> ProcessRequest {
        guard let policy = request.sandbox else { return request }
        try validate(request: request, policy: policy)

        #if os(Linux)
            return try LinuxProcessSandbox.prepare(request, policy: policy)
        #elseif os(macOS)
            return try MacOSProcessSandbox.prepare(request, policy: policy)
        #else
            throw ProcessSandboxError.unsupportedPlatform
        #endif
    }

    static func validate(
        request: ProcessRequest,
        policy: ProcessSandboxPolicy
    ) throws {
        guard !request.executable.isEmpty else {
            throw ProcessSandboxError.invalidPolicy("executable must not be empty")
        }
        guard !request.executable.contains("\0"),
            !request.executable.contains("\n"),
            !request.executable.contains("\r")
        else {
            throw ProcessSandboxError.invalidPolicy("executable contains a control character")
        }

        let paths = policy.readOnlyPaths + policy.readWritePaths
        for path in paths {
            guard path.hasPrefix("/") else {
                throw ProcessSandboxError.invalidPolicy(
                    "sandbox paths must be absolute: \(path)"
                )
            }
            guard !path.contains("\0") else {
                throw ProcessSandboxError.invalidPolicy("sandbox path contains NUL")
            }
            guard !path.contains("\n") && !path.contains("\r") else {
                throw ProcessSandboxError.invalidPolicy(
                    "sandbox path contains a line break: \(path)"
                )
            }
        }

        if let cwd = request.workingDirectory {
            guard cwd.hasPrefix("/") else {
                throw ProcessSandboxError.invalidPolicy(
                    "working directory must be absolute: \(cwd)"
                )
            }
            guard paths.contains(where: { isWithin(cwd, root: $0) }) else {
                throw ProcessSandboxError.invalidPolicy(
                    "working directory is not covered by the sandbox paths: \(cwd)"
                )
            }
        }
    }

    static func isWithin(_ path: String, root: String) -> Bool {
        let normalizedPath = canonicalPath(path)
        let normalizedRoot = canonicalPath(root)
        guard normalizedPath != normalizedRoot else { return true }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return normalizedPath.hasPrefix(prefix)
    }

    static func uniqueExistingPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            let normalized = canonicalPath(path)
            guard !seen.contains(normalized),
                FileManager.default.fileExists(atPath: normalized)
            else { return nil }
            seen.insert(normalized)
            return normalized
        }
    }

    static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        #if os(macOS)
            return standardized.withCString { pointer in
                guard let resolved = Darwin.realpath(pointer, nil) else { return standardized }
                defer { Darwin.free(resolved) }
                return String(cString: resolved)
            }
        #elseif os(Linux)
            return standardized.withCString { pointer in
                guard let resolved = Glibc.realpath(pointer, nil) else { return standardized }
                defer { Glibc.free(resolved) }
                return String(cString: resolved)
            }
        #else
            return standardized
        #endif
    }

    static func pathVariants(_ path: String) -> [String] {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let canonical = canonicalPath(path)
        return standardized == canonical ? [standardized] : [standardized, canonical]
    }

    static func effectiveEnvironment(
        _ request: ProcessRequest,
        policy: ProcessSandboxPolicy
    ) -> [String: String]? {
        switch policy.environment {
        case .inherited:
            return request.environment
        case .clear:
            var environment = request.environment ?? [:]
            if environment["PATH"] == nil {
                #if os(macOS)
                    environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                #else
                    environment["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                #endif
            }
            return environment
        }
    }
}

#if os(Linux)
    private enum LinuxProcessSandbox {
        static func prepare(
            _ request: ProcessRequest,
            policy: ProcessSandboxPolicy
        ) throws -> ProcessRequest {
            let bwrap = try findExecutable(named: "bwrap")
            var arguments: [String] = [
                "--die-with-parent",
                "--new-session",
                "--unshare-user",
                "--unshare-pid",
                "--unshare-ipc",
                "--unshare-uts",
                "--proc", "/proc",
                "--dev", "/dev",
                "--tmpfs", "/tmp",
            ]

            if policy.network == .denied {
                arguments += ["--unshare-net"]
            }

            let environment = ProcessSandboxLauncher.effectiveEnvironment(request, policy: policy) ?? [:]
            if policy.environment == .clear {
                arguments += ["--clearenv"]
            }
            for key in environment.keys.sorted() {
                arguments += ["--setenv", key, environment[key] ?? ""]
            }

            // Writable mounts come first. Read-only mounts are applied after them
            // so a tool bundle nested in a writable workspace remains read-only.
            for path in ProcessSandboxLauncher.uniqueExistingPaths(policy.readWritePaths) {
                arguments += ["--bind", path, path]
            }
            for path in ProcessSandboxLauncher.uniqueExistingPaths(policy.readOnlyPaths) {
                arguments += ["--ro-bind", path, path]
            }

            if let cwd = request.workingDirectory {
                arguments += ["--chdir", ProcessSandboxLauncher.canonicalPath(cwd)]
            }
            let executable: String
            if request.executable.hasPrefix("/") {
                // Preserve argv[0] and the executable's original path. If its
                // parent is outside the declared mounts, create only the empty
                // directory chain needed for the individual read-only bind.
                let originalPath = URL(fileURLWithPath: request.executable)
                    .standardizedFileURL.path
                let parent = URL(fileURLWithPath: originalPath)
                    .deletingLastPathComponent().path
                let declaredPaths = policy.readOnlyPaths + policy.readWritePaths
                if !declaredPaths.contains(where: {
                    ProcessSandboxLauncher.isWithin(parent, root: $0)
                }) {
                    arguments += directoryChain(for: parent).flatMap { ["--dir", $0] }
                }
                arguments += [
                    "--ro-bind",
                    ProcessSandboxLauncher.canonicalPath(request.executable),
                    originalPath,
                ]
                executable = originalPath
            } else {
                executable = request.executable
            }
            arguments += ["--", executable]
            arguments += request.arguments

            return ProcessRequest(
                executable: bwrap,
                arguments: arguments,
                workingDirectory: nil,
                standardInput: request.standardInput,
                environment: policy.environment == .clear ? [:] : request.environment
            )
        }

        private static func findExecutable(named name: String) throws -> String {
            let path =
                ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/local/bin:/usr/bin:/bin"
            for directory in path.split(separator: ":").map(String.init) {
                let candidate = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name)
                    .path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            throw ProcessSandboxError.backendUnavailable(
                "bubblewrap (bwrap) was not found in PATH"
            )
        }

        private static func directoryChain(for path: String) -> [String] {
            var result: [String] = []
            var current = URL(fileURLWithPath: path).standardizedFileURL.path
            while current != "/" {
                result.insert(current, at: 0)
                let parent = URL(fileURLWithPath: current)
                    .deletingLastPathComponent().path
                guard parent != current else { break }
                current = parent
            }
            return result
        }
    }
#endif

#if os(macOS)
    private enum MacOSProcessSandbox {
        static func prepare(
            _ request: ProcessRequest,
            policy: ProcessSandboxPolicy
        ) throws -> ProcessRequest {
            let executable = "/usr/bin/sandbox-exec"
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw ProcessSandboxError.backendUnavailable(executable)
            }

            let profile = makeProfile(policy: policy, executable: request.executable)
            return ProcessRequest(
                executable: executable,
                arguments: ["-p", profile, request.executable] + request.arguments,
                workingDirectory: request.workingDirectory.map(ProcessSandboxLauncher.canonicalPath),
                standardInput: request.standardInput,
                environment: ProcessSandboxLauncher.effectiveEnvironment(request, policy: policy)
            )
        }

        private static func makeProfile(
            policy: ProcessSandboxPolicy,
            executable: String
        ) -> String {
            var rules = [
                "(version 1)",
                "(deny default)",
                "(import \"system.sb\")",
                "(allow process-exec)",
                "(allow process-fork)",
            ]

            for path in policy.readOnlyPaths.flatMap(ProcessSandboxLauncher.pathVariants) {
                let escaped = escape(path)
                rules.append("(allow file-read* file-map-executable (subpath \"\(escaped)\"))")
            }
            for path in policy.readWritePaths.flatMap(ProcessSandboxLauncher.pathVariants) {
                let escaped = escape(path)
                rules.append("(allow file-read* file-map-executable file-write* (subpath \"\(escaped)\"))")
            }
            for path in policy.readOnlyPaths.flatMap(ProcessSandboxLauncher.pathVariants) {
                let escaped = escape(path)
                // Seatbelt rules are additive, so an explicit deny is required
                // when a read-only tool directory is nested in a writable root.
                rules.append("(deny file-write* (subpath \"\(escaped)\"))")
            }
            // Permit the executable itself, including a selector symlink and its
            // resolved target. Do not grant its whole parent directory: that could
            // expose unrelated files beside a user supplied executable.
            for path in ProcessSandboxLauncher.pathVariants(executable) {
                let escaped = escape(path)
                rules.append("(allow file-read* file-map-executable (literal \"\(escaped)\"))")
            }
            if policy.network == .inherited {
                rules.append("(allow network*)")
            }
            return rules.joined(separator: " ")
        }

        private static func escape(_ path: String) -> String {
            path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
    }
#endif
