import ACP
import ACPModel
import HailCore
import Logging
import ScopedEffect

private let codexClientLogger = Logger(label: "CodexAppServerClient")

/// Native App Server transport. It knows JSON messages and process lifecycle,
/// but nothing about Codex threads, turns, or Hail authority policy.
actor CodexAppServerClient {
    private let executablePath: String
    private let arguments: [String]
    private let workingDirectory: String
    private let environment: [String: String]
    private let authority: any Authority

    private var transport: StdioTransport?
    private var readerTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<CodexRPCEnvelope>.Continuation?
    private var eventStream: AsyncStream<CodexRPCEnvelope>?
    private var pendingResponses: [Int: CheckedContinuation<CodexRPCEnvelope, any Error>] = [:]
    private var requestID = 0

    init(
        executablePath: String,
        workingDirectory: String,
        environment: [String: String],
        authority: any Authority
    ) {
        self.executablePath = executablePath
        self.arguments = ["codex", "app-server", "--listen", "stdio://"]
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.authority = authority
    }

    func connect() async throws {
        if let transport, await transport.isConnected { return }

        let transport = StdioTransport()
        codexClientLogger.info(
            "Launching Codex App Server",
            metadata: ["workingDirectory": .string(workingDirectory)]
        )
        try await withEffect(
            ProcessEffect(executable: executablePath, arguments: arguments, cwd: workingDirectory),
            authority: authority
        ) { _ in
            try await transport.launch(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }
        self.transport = transport
        let (events, continuation) = AsyncStream.makeStream(of: CodexRPCEnvelope.self)
        eventStream = events
        eventContinuation = continuation
        readerTask = Task { [weak self] in
            for await data in transport.messages {
                guard !Task.isCancelled else { break }
                do {
                    await self?.receive(try CodexAppServerWire.decode(data))
                } catch {
                    await self?.disconnect(with: error)
                    return
                }
            }
            await self?.disconnect(with: CodexSessionError.disconnected)
        }

        _ = try await request(
            "initialize",
            params: CodexInitializeParams(
                clientInfo: .init(name: "hail", title: "Hail", version: "0.1.0"),
                capabilities: .init(experimentalApi: true)
            )
        )
        try await send(CodexRPCNotification<AnyCodable>(method: "initialized"))
    }

    func request<Params: Encodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> CodexRPCEnvelope {
        requestID += 1
        let id = requestID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingResponses[id] = continuation
                Task {
                    do {
                        try await send(CodexRPCRequest(id: id, method: method, params: params))
                    } catch {
                        failResponse(id: id, with: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failResponse(id: id, with: CancellationError()) }
        }
    }

    func events() throws -> AsyncStream<CodexRPCEnvelope> {
        guard let eventStream else { throw CodexSessionError.disconnected }
        return eventStream
    }

    private func receive(_ message: CodexRPCEnvelope) {
        if message.method != nil {
            eventContinuation?.yield(message)
            return
        }
        guard let id = message.id?.integer,
            let continuation = pendingResponses.removeValue(forKey: id)
        else { return }
        if let error = message.error {
            continuation.resume(
                throwing: CodexSessionError.requestFailed(
                    error.message.isEmpty ? "Codex App Server request \(id) failed." : error.message
                )
            )
        } else {
            continuation.resume(returning: message)
        }
    }

    private func failResponse(id: Int, with error: any Error) {
        pendingResponses.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func disconnect(with error: any Error) {
        guard transport != nil else { return }
        transport = nil
        readerTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }

    func send<Message: Encodable & Sendable>(_ message: Message) async throws {
        guard let transport else { throw CodexSessionError.disconnected }
        try await transport.send(CodexAppServerWire.encode(message))
    }

    func close() async {
        readerTask?.cancel()
        readerTask = nil
        if let transport { await transport.close() }
        disconnect(with: CodexSessionError.disconnected)
    }
}
