import HailCore
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Process sandbox")
struct ProcessSandboxTests {
    @Test("a sandboxed process can write its allowed directory but not a sibling")
    func restrictsFilesystem() async throws {
        #if os(macOS) || os(Linux)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hail-process-sandbox-\(UUID().uuidString)", isDirectory: true)
            let allowed = root.appendingPathComponent("allowed", isDirectory: true)
            let denied = root.appendingPathComponent("denied", isDirectory: true)
            try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
            let secret = denied.appendingPathComponent("secret.txt")
            try Data("secret".utf8).write(to: secret)
            defer { try? FileManager.default.removeItem(at: root) }

            let readOnlyPaths: [String]
            #if os(macOS)
                readOnlyPaths = [
                    "/System",
                    "/usr",
                    "/bin",
                    "/sbin",
                    "/private/var/db/dyld",
                ]
            #else
                readOnlyPaths = [
                    "/usr",
                    "/bin",
                    "/sbin",
                    "/lib",
                    "/lib64",
                    "/etc",
                ]
            #endif

            let outputFile = allowed.appendingPathComponent("output.txt")
            let command =
                "printf allowed > '\(outputFile.path)'; "
                + "if cat '\(secret.path)' >/dev/null 2>&1; then "
                + "printf leaked; else printf blocked; fi"
            let result: ProcessResult
            do {
                result = try await ProcessDependency.live.run(
                    ProcessRequest(
                        executable: "/bin/sh",
                        arguments: ["-c", command],
                        workingDirectory: allowed.path,
                        environment: ["PATH": "/usr/bin:/bin"],
                        sandbox: ProcessSandboxPolicy(
                            readOnlyPaths: readOnlyPaths,
                            readWritePaths: [allowed.path],
                            network: .denied,
                            environment: .clear
                        )
                    )
                )
            } catch ProcessSandboxError.backendUnavailable {
                // Linux CI machines may not have bubblewrap installed. The
                // backend is deliberately fail-closed; absence is not a reason
                // to execute the same request raw.
                return
            }

            #expect(result.exitCode == 0)
            #expect(String(decoding: result.standardOutput, as: UTF8.self) == "blocked")
            #expect(String(decoding: try Data(contentsOf: outputFile), as: UTF8.self) == "allowed")
        #else
            return
        #endif
    }
}
