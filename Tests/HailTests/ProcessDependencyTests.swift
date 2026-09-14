import HailCore
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Process dependency")
struct ProcessDependencyTests {
    @Test("a runnable executable captures stdout and exit code")
    func capturesOutput() async throws {
        let result = try await ProcessDependency.live.run(
            ProcessRequest(executable: "/bin/echo", arguments: ["hello"])
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines) == "hello")
        #expect(result.standardError.isEmpty)
    }

    @Test("a non-zero exit is data, not an error")
    func nonZeroExitIsData() async throws {
        let result = try await ProcessDependency.live.run(
            ProcessRequest(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"])
        )
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .newlines) == "oops")
    }

    @Test("standard input is written and closed")
    func writesStandardInput() async throws {
        let result = try await ProcessDependency.live.run(
            ProcessRequest(
                executable: "/bin/cat",
                standardInput: Data("hello from stdin".utf8)
            )
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello from stdin")
    }

    @Test("an unrunnable executable throws")
    func unrunnableThrows() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessDependency.live.run(
                ProcessRequest(executable: "/definitely/not/here")
            )
        }
    }

    @Test("large output is drained before process termination")
    func largeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessDependency.live.run(
            ProcessRequest(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 1048576 /dev/zero"]
            )
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.count == 1_048_576)
    }

    @Test("signal termination remains distinguishable from exit")
    func reportsSignalTermination() async throws {
        let result = try await ProcessDependency.live.run(
            ProcessRequest(executable: "/bin/sh", arguments: ["-c", "kill -TERM $$"])
        )
        #expect(result.termination == .signaled(15))
        #expect(result.exitCode == -15)
    }

    @Test("output overflow is reported")
    func reportsOutputOverflow() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessDependency.live.run(
                ProcessRequest(
                    executable: "/bin/sh",
                    arguments: ["-c", "head -c 1024 /dev/zero"],
                    maximumOutputBytes: 128
                )
            )
        }
    }

    @Test("an invalid output limit is rejected before launch")
    func rejectsInvalidOutputLimit() async {
        await #expect(throws: ProcessDependencyError.invalidOutputLimit(-1)) {
            _ = try await ProcessDependency.live.run(
                ProcessRequest(
                    executable: "/bin/echo",
                    arguments: ["should not run"],
                    maximumOutputBytes: -1
                )
            )
        }
    }

    @Test("cancellation tears down a shell process promptly")
    func cancellationTearsDownProcess() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-process-cancel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = directory.appendingPathComponent("started")
        let childFinished = directory.appendingPathComponent("child-finished")
        let command =
            ": > started; "
            + "(sleep 0.5; : > child-finished) & wait"
        let clock = ContinuousClock()
        let start = clock.now
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    _ = try await ProcessDependency.live.run(
                        ProcessRequest(
                            executable: "/bin/sh",
                            arguments: ["-c", command],
                            workingDirectory: directory.path
                        )
                    )
                } catch {
                    // Cancellation is the expected completion path.
                }
            }
            await Task.yield()
            for _ in 0..<40 where !FileManager.default.fileExists(atPath: started.path) {
                try? await Task.sleep(for: .milliseconds(25))
            }
            #expect(FileManager.default.fileExists(atPath: started.path))
            group.cancelAll()
            try? await group.waitForAll()
        }
        #expect(clock.now - start < .seconds(2))
        try? await Task.sleep(for: .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: childFinished.path))
    }

}
