import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// JSON payloads remain opaque to this transport. The client owns authentication,
/// thread identity, tool restrictions, and interpretation of streamed items.
public struct CodexAppServerNotification: Sendable {
    public let method: String
    public let params: Data?
}

public struct CodexAppServerRequest: Sendable {
    /// A JSON string or integer, preserved for the corresponding response.
    public let id: Data
    public let method: String
    public let params: Data?
}

public enum CodexAppServerReply: Sendable {
    case result(Data)
    case error(code: Int, message: String)
}

public enum CodexAppServerTransportError: Error, Sendable, Equatable {
    case notStarted
    case alreadyStarted
    case processLaunchFailed
    case transportClosed
    case invalidMessage
    case lineTooLarge
    case backpressure
    case writeFailed
    case timeout(method: String)
    case rpc(code: Int, message: String)
}

/// One private child process and one JSONL connection. It never connects to the
/// desktop daemon, reads credentials, or retries a request after an ambiguous EOF.
public actor CodexAppServerTransport {
    public typealias ServerRequestHandler = @Sendable (CodexAppServerRequest) async -> CodexAppServerReply
    public nonisolated let notifications: AsyncThrowingStream<CodexAppServerNotification, Error>

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

    private let executableURL: URL
    private let arguments: [String]
    private let currentDirectoryURL: URL?
    private let environment: [String: String]?
    private let maximumLineBytes: Int
    private let requestTimeoutSeconds: Double
    private let serverRequestHandler: ServerRequestHandler?
    private let notificationContinuation: AsyncThrowingStream<CodexAppServerNotification, Error>.Continuation
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputReader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var outgoing: [Data] = []
    private var outgoingOffset = 0
    private var queuedWriteBytes = 0
    private var lineBuffer = Data()
    private var pending: [String: PendingRequest] = [:]
    private var serverRequests: [Data: Task<Void, Never>] = [:]
    private var started = false
    private var closed = false

    public init(
        executableURL: URL,
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        maximumLineBytes: Int = 1_048_576,
        requestTimeoutSeconds: Double = 30,
        serverRequestHandler: ServerRequestHandler? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.maximumLineBytes = max(64, min(16_777_216, maximumLineBytes))
        self.requestTimeoutSeconds = requestTimeoutSeconds.isFinite ? max(0.01, min(3_600, requestTimeoutSeconds)) : 30
        self.serverRequestHandler = serverRequestHandler
        let pair = AsyncThrowingStream<CodexAppServerNotification, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        notifications = pair.stream
        notificationContinuation = pair.continuation
    }

    deinit {
        notificationContinuation.finish()
        outputReader?.cancel()
        errorReader?.cancel()
        writerTask?.cancel()
        guard cleanupTask == nil else { return }
        let child = process
        let stdin = inputHandle, stdout = outputHandle, stderr = errorHandle
        Task.detached(priority: .utility) {
            try? stdin?.close()
            Self.reap(child: child, stdout: stdout, stderr: stderr)
        }
    }

    public func start() throws {
        guard !started else { throw CodexAppServerTransportError.alreadyStarted }
        guard !closed else { throw CodexAppServerTransportError.transportClosed }
        started = true
        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.currentDirectoryURL = currentDirectoryURL
        if let environment { child.environment = environment }
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        do { try child.run() }
        catch {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            beginShutdown(CodexAppServerTransportError.processLaunchFailed)
            throw CodexAppServerTransportError.processLaunchFailed
        }
        process = child
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = errors.fileHandleForReading
        let descriptor = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            beginShutdown(CodexAppServerTransportError.writeFailed)
            throw CodexAppServerTransportError.writeFailed
        }
        #if canImport(Darwin)
        // Suppress SIGPIPE on this pipe only, without changing the app's global
        // signal behavior when its private child closes stdin.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            beginShutdown(CodexAppServerTransportError.writeFailed)
            throw CodexAppServerTransportError.writeFailed
        }
        #endif
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        outputReader = Task.detached(priority: .utility) { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !Task.isCancelled {
                let count = buffer.withUnsafeMutableBytes { read(stdout.fileDescriptor, $0.baseAddress, $0.count) }
                if count > 0 { await self?.receive(Data(buffer.prefix(count))) }
                else if count < 0, errno == EINTR { continue }
                else { break }
            }
            await self?.outputReachedEOF()
        }
        errorReader = Task.detached(priority: .utility) {
            // Drain stderr so a child cannot block on it. It is deliberately not
            // retained or emitted: diagnostics can contain account information.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !Task.isCancelled {
                let count = buffer.withUnsafeMutableBytes { read(stderr.fileDescriptor, $0.baseAddress, $0.count) }
                if count > 0 { continue }
                if count < 0, errno == EINTR { continue }
                break
            }
        }
    }

    public func request(method: String, params: Data? = nil, timeoutSeconds: Double? = nil) async throws -> Data {
        try ensureOpen()
        try Task.checkCancellation()
        guard pending.count < 64 else { throw CodexAppServerTransportError.backpressure }
        let id = UUID().uuidString
        let duration = timeoutSeconds ?? requestTimeoutSeconds
        let boundedDuration = duration.isFinite ? max(0.01, min(3_600, duration)) : requestTimeoutSeconds
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(boundedDuration * 1_000_000_000)) }
                    catch { return }
                    await self?.requestTimedOut(id: id, method: method)
                }
                pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
                do { try writeMessage(method: method, id: id, params: params) }
                catch {
                    if let request = pending.removeValue(forKey: id) {
                        request.timeout.cancel()
                        request.continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    public func notify(method: String, params: Data? = nil) throws {
        try ensureOpen()
        try writeMessage(method: method, id: nil, params: params)
    }

    /// Completes pending requests, closes the input, terminates this private
    /// child, and awaits bounded termination cleanup. Foundation owns process
    /// reaping. Calling close repeatedly is harmless.
    public func close() async {
        beginShutdown(nil)
        if let cleanupTask { await cleanupTask.value }
    }

    private func ensureOpen() throws {
        guard !closed else { throw CodexAppServerTransportError.transportClosed }
        guard started, process != nil else { throw CodexAppServerTransportError.notStarted }
    }

    private func writeMessage(method: String, id: String?, params: Data?) throws {
        guard !method.isEmpty else { throw CodexAppServerTransportError.invalidMessage }
        var object: [String: Any] = ["method": method]
        if let id { object["id"] = id }
        if let params {
            do { object["params"] = try JSONSerialization.jsonObject(with: params, options: .fragmentsAllowed) }
            catch { throw CodexAppServerTransportError.invalidMessage }
        }
        try writeObject(object)
    }

    private func writeObject(_ object: [String: Any]) throws {
        let bytes: Data
        do { bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
        catch { throw CodexAppServerTransportError.invalidMessage }
        guard bytes.count <= maximumLineBytes else { throw CodexAppServerTransportError.lineTooLarge }
        guard inputHandle != nil, !closed else { throw CodexAppServerTransportError.transportClosed }
        guard queuedWriteBytes + bytes.count + 1 <= max(4_194_304, maximumLineBytes * 2) else {
            throw CodexAppServerTransportError.backpressure
        }
        var line = bytes
        line.append(0x0A)
        outgoing.append(line)
        queuedWriteBytes += line.count
        if writerTask == nil { writerTask = Task { [weak self] in await self?.flushWrites() } }
    }

    private func flushWrites() async {
        var lastProgress = Date.timeIntervalSinceReferenceDate
        while !closed, let line = outgoing.first, let inputHandle {
            let written = line.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(inputHandle.fileDescriptor, base.advanced(by: outgoingOffset), line.count - outgoingOffset)
            }
            if written > 0 {
                lastProgress = Date.timeIntervalSinceReferenceDate
                outgoingOffset += written
                queuedWriteBytes -= written
                if outgoingOffset == line.count { outgoing.removeFirst(); outgoingOffset = 0 }
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if Date.timeIntervalSinceReferenceDate - lastProgress >= requestTimeoutSeconds {
                    beginShutdown(CodexAppServerTransportError.writeFailed)
                    break
                }
                do { try await Task.sleep(nanoseconds: 2_000_000) }
                catch { break }
            } else {
                beginShutdown(CodexAppServerTransportError.writeFailed)
                break
            }
        }
        writerTask = nil
    }

    private func receive(_ chunk: Data) {
        guard !closed else { return }
        // Split each bounded read before appending: many small lines may fit in
        // one read even when their total size exceeds the per-line limit.
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 0x0A)
            let end = newline ?? chunk.endIndex
            guard lineBuffer.count + chunk.distance(from: start, to: end) <= maximumLineBytes else {
                beginShutdown(CodexAppServerTransportError.lineTooLarge)
                return
            }
            lineBuffer.append(contentsOf: chunk[start..<end])
            if let newline {
                let line = lineBuffer
                lineBuffer.removeAll(keepingCapacity: true)
                receiveLine(line)
                guard !closed else { return }
                start = chunk.index(after: newline)
            } else { break }
        }
    }

    private func receiveLine(_ line: Data) {
        guard !line.isEmpty else { return }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerTransportError.invalidMessage
            }
            object = parsed
        } catch {
            beginShutdown(CodexAppServerTransportError.invalidMessage)
            return
        }
        if let method = object["method"] as? String, !method.isEmpty {
            let params = object["params"].flatMap(Self.jsonData)
            if let idObject = object["id"] {
                guard let id = Self.jsonData(idObject), Self.validID(idObject) else {
                    beginShutdown(CodexAppServerTransportError.invalidMessage)
                    return
                }
                receiveServerRequest(CodexAppServerRequest(id: id, method: method, params: params))
            } else {
                switch notificationContinuation.yield(CodexAppServerNotification(method: method, params: params)) {
                case .dropped: beginShutdown(CodexAppServerTransportError.backpressure)
                case .terminated: beginShutdown(nil)
                case .enqueued: break
                @unknown default: beginShutdown(CodexAppServerTransportError.backpressure)
                }
            }
            return
        }
        guard let idObject = object["id"], Self.validID(idObject),
              (object["result"] != nil) != (object["error"] != nil) else {
            beginShutdown(CodexAppServerTransportError.invalidMessage)
            return
        }
        // Our request IDs are strings. An unknown/late response never resolves a
        // different request, including after cancellation or a timeout.
        guard let id = idObject as? String, let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if let result = object["result"], let data = Self.jsonData(result) {
            request.continuation.resume(returning: data)
        } else if let error = object["error"] as? [String: Any],
                  let codeObject = error["code"], Self.validID(codeObject),
                  let code = codeObject as? Int, let message = error["message"] as? String {
            request.continuation.resume(throwing: CodexAppServerTransportError.rpc(code: code, message: message))
        } else {
            request.continuation.resume(throwing: CodexAppServerTransportError.invalidMessage)
            beginShutdown(CodexAppServerTransportError.invalidMessage)
        }
    }

    private func receiveServerRequest(_ request: CodexAppServerRequest) {
        guard let handler = serverRequestHandler else {
            sendServerReply(.error(code: -32601, message: "Method unavailable in Codex Lens."), to: request)
            return
        }
        guard serverRequests.count < 32, serverRequests[request.id] == nil else {
            beginShutdown(CodexAppServerTransportError.backpressure)
            return
        }
        serverRequests[request.id] = Task { [weak self] in
            let reply = await handler(request)
            guard !Task.isCancelled else { return }
            await self?.sendServerReply(reply, to: request)
        }
    }

    private func sendServerReply(_ reply: CodexAppServerReply, to request: CodexAppServerRequest) {
        serverRequests.removeValue(forKey: request.id)
        guard !closed else { return }
        do {
            let id = try JSONSerialization.jsonObject(with: request.id, options: .fragmentsAllowed)
            var object: [String: Any] = ["id": id]
            switch reply {
            case .result(let result): object["result"] = try JSONSerialization.jsonObject(with: result, options: .fragmentsAllowed)
            case .error(let code, let message): object["error"] = ["code": code, "message": message]
            }
            try writeObject(object)
        } catch { beginShutdown(CodexAppServerTransportError.writeFailed) }
    }

    private func requestTimedOut(id: String, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CodexAppServerTransportError.timeout(method: method))
    }

    private func cancelRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func outputReachedEOF() {
        // Even exit status zero is not a successful RPC or a completed turn.
        beginShutdown(CodexAppServerTransportError.transportClosed)
    }

    private func beginShutdown(_ error: CodexAppServerTransportError?) {
        guard !closed else { return }
        closed = true
        for request in pending.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error ?? CodexAppServerTransportError.transportClosed)
        }
        pending.removeAll()
        for task in serverRequests.values { task.cancel() }
        serverRequests.removeAll()
        lineBuffer.removeAll()
        writerTask?.cancel()
        outgoing.removeAll()
        outgoingOffset = 0
        queuedWriteBytes = 0
        if let error { notificationContinuation.finish(throwing: error) }
        else { notificationContinuation.finish() }
        try? inputHandle?.close()
        inputHandle = nil
        outputReader?.cancel()
        errorReader?.cancel()
        let child = process
        let stdout = outputHandle, stderr = errorHandle
        cleanupTask = Task.detached(priority: .utility) {
            Self.reap(child: child, stdout: stdout, stderr: stderr)
        }
    }

    private static func reap(child: Process?, stdout: FileHandle?, stderr: FileHandle?) {
        if let child {
            if child.isRunning {
                child.terminate()
                for _ in 0..<40 {
                    if !child.isRunning { break }
                    usleep(50_000)
                }
                if child.isRunning {
                    _ = kill(child.processIdentifier, SIGKILL)
                    for _ in 0..<40 {
                        if !child.isRunning { break }
                        usleep(50_000)
                    }
                }
            }
            // On macOS 26.5, waitUntilExit from a cooperative executor can
            // remain in CFRunLoop after the process has already disappeared.
            // isRunning is updated by Foundation's own process reaper; never
            // enter that unbounded nested run loop during chat shutdown.
        }
        try? stdout?.close()
        try? stderr?.close()
    }

    private static func jsonData(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func validID(_ value: Any) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return false }
        let numberValue = number.doubleValue
        return numberValue.isFinite && numberValue.rounded() == numberValue
    }
}
