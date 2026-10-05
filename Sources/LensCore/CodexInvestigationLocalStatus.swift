import Foundation
import Darwin

public struct CodexInvestigationLocalStatus: Sendable, Equatable {
    public let executable: URL
    public let version: String?
    public let usesChatGPT: Bool
    public let signedOut: Bool

    /// Bounded, cancellable version probe; does not inspect authentication.
    public static func inspectVersion(executable: URL) async throws -> String? {
        let probe = CodexInvestigationProcessProbe(executable: executable)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: parseVersion(try probe.run(arguments: ["--version"]))) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { probe.cancel() }
    }
    static func parseVersion(_ data: Data) -> String? {
        let first = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return first.range(of: #"^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-A-Za-z0-9.]*)?$"#, options: .regularExpression) == nil ? nil : String(first.dropFirst("codex-cli ".count))
    }

    /// Metadata only. Raw login output, including possible API-key information,
    /// is discarded. No login/logout, app-server daemon, or model call occurs.
    public static func inspect(executable: URL) async throws -> CodexInvestigationLocalStatus {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LensError.unavailable("Exécutable Codex local introuvable.")
        }
        let probe = CodexInvestigationProcessProbe(executable: executable)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let versionOutput = try probe.run(arguments: ["--version"])
                        let version = parseVersion(versionOutput)
                        let login = String(decoding: try probe.run(arguments: ["login", "status"]), as: UTF8.self)
                        let value = CodexInvestigationLocalStatus(executable: executable, version: version,
                            usesChatGPT: login.contains("Logged in using ChatGPT"), signedOut: login.contains("Not logged in"))
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { probe.cancel() }
    }

    /// No shell PATH discovery is executed. These are conventional locations,
    /// and the UI can offer an explicit native executable picker as a fallback.
    public static func conventionalExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".npm-global/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

private final class CodexInvestigationProcessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private var process: Process?
    private var cancelled = false
    init(executable: URL) { self.executable = executable }
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
    func run(arguments: [String]) throws -> Data {
        let task = Process(), pipe = Pipe()
        task.executableURL = executable; task.arguments = arguments
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        // A GUI app launched without a terminal still resolves npm's env-node
        // wrapper. Existing authentication remains exclusively Codex-owned.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        task.environment = environment
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); throw LensError.unavailable("Codex local ne peut pas être interrogé.") }
        lock.unlock()
        // Consume continuously to avoid pipe backpressure; no buffer exceeds16K.
        let capture = CodexInvestigationProbeCapture()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !capture.append(data), task.isRunning { task.terminate() }
        }
        let expired = done.wait(timeout: .now() + 8) == .timedOut
        if expired, task.isRunning { task.terminate(); _ = done.wait(timeout: .now() + 1) }
        if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); process = nil; let cancelled = cancelled; lock.unlock()
        if cancelled { throw CancellationError() }
        guard !expired, !capture.overflowed else { throw LensError.unavailable("Vérification du statut Codex interrompue ou trop volumineuse.") }
        guard task.terminationStatus == 0 || arguments == ["login", "status"] else { throw LensError.unavailable("Codex n’a pas retourné sa version correctement.") }
        if !task.isRunning { _ = capture.append(pipe.fileHandleForReading.readDataToEndOfFile()) }
        guard !capture.overflowed else { throw LensError.unavailable("Statut Codex trop volumineux.") }
        return capture.data
    }
}

private final class CodexInvestigationProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var exceeded = false
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    @discardableResult func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !exceeded, storage.count + data.count <= 16 * 1024 else { exceeded = true; return false }
        storage.append(data); return true
    }
}
