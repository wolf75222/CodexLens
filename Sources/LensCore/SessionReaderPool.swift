import Foundation

/// A publication is shared; receiving it does not consume it for another window.
public struct SessionReaderUpdate: Sendable {
    public let snapshot: SessionSnapshot
    public let revision: UInt64
}

/// This engine's root never changes. Window navigation and visual following stay outside the reader.
public actor SessionReader {
    public nonisolated let engine: SessionEngine
    private let rootID: String?
    private var latest: SessionReaderUpdate?
    private struct Flight { let id: UUID; let task: Task<Void, Never> }
    private var flight: Flight?
    private var waiters: [UUID: CheckedContinuation<SessionReaderUpdate, Error>] = [:]
    private var catalogFlight: Flight?
    private var retiringCatalogFlights: [UUID: Task<Void, Never>] = [:]
    private var catalogWaiters: [UUID: CheckedContinuation<[SessionSummary], Error>] = [:]
    private var catalogObservers: [UUID: SessionProgressHandler] = [:]
    private var loadObservers: [UUID: SessionProgressHandler] = [:]
    private var catalogProgress: SessionLoadingProgress?
    private var loadProgress: SessionLoadingProgress?
    private var closed = false
    private var closingTask: Task<Void, Never>?
    internal private(set) var startedCollections = 0
    internal private(set) var startedCatalogs = 0

    fileprivate init(engine: SessionEngine, rootID: String?) { self.engine = engine; self.rootID = rootID }

    public func catalog(progress: SessionProgressHandler? = nil) async throws -> [SessionSummary] {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let waiterID = UUID()
        let result: [SessionSummary] = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                catalogWaiters[waiterID] = continuation
                catalogObservers[waiterID] = progress
                if let catalogProgress { progress?(catalogProgress) }
                if catalogFlight == nil { beginCatalog() }
            }
        }, onCancel: { Task { await self.cancelCatalogWaiter(waiterID) } })
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return result
    }

    private func beginCatalog() {
        let engine = self.engine, id = UUID()
        let (updates, continuation) = AsyncStream<SessionLoadingProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Task { [weak self] in
            for await progress in updates { await self?.publishProgress(progress, id: id, catalog: true) }
        }
        let task = Task { [weak self] in
            let result: Result<[SessionSummary], Error>
            do { result = .success(try await engine.catalog(progress: { continuation.yield($0) })) }
            catch { result = .failure(error) }
            continuation.finish()
            await observer.value
            await self?.finishCatalog(id: id, result: result)
        }
        catalogFlight = Flight(id: id, task: task); startedCatalogs += 1
    }
    private func finishCatalog(id: UUID, result: Result<[SessionSummary], Error>) {
        retiringCatalogFlights[id] = nil
        guard !closed, catalogFlight?.id == id else { return }
        catalogFlight = nil
        catalogObservers = [:]; catalogProgress = nil
        let pending = catalogWaiters; catalogWaiters = [:]
        for continuation in pending.values { continuation.resume(with: result) }
    }
    private func cancelCatalogWaiter(_ id: UUID) {
        catalogObservers[id] = nil
        catalogWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if catalogWaiters.isEmpty, let flight = catalogFlight {
            flight.task.cancel(); retiringCatalogFlights[flight.id] = flight.task; catalogFlight = nil
            catalogProgress = nil
        }
    }

    public func load(progress: SessionProgressHandler? = nil) async throws -> SessionReaderUpdate { try await collect(refresh: false, progress: progress) }
    public func refresh() async throws -> SessionReaderUpdate { try await collect(refresh: true) }

    private func collect(refresh: Bool, progress: SessionProgressHandler? = nil) async throws -> SessionReaderUpdate {
        try Task.checkCancellation()
        guard !closed, let rootID else { throw LensError.unavailable("Lecteur de session fermé ou réservé au catalogue.") }
        if !refresh, let latest { return latest }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[waiterID] = continuation
                loadObservers[waiterID] = progress
                if let loadProgress { progress?(loadProgress) }
                if flight == nil { beginCollection(rootID: rootID) }
            }
        }, onCancel: { Task { await self.cancelWaiter(waiterID) } })
    }

    private func beginCollection(rootID: String) {
        let engine = self.engine, initial = latest == nil, id = UUID()
        let (updates, continuation) = AsyncStream<SessionLoadingProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Task { [weak self] in
            for await progress in updates { await self?.publishProgress(progress, id: id, catalog: false) }
        }
        // The task belongs to the reader. A cancelled waiter is resumed immediately,
        // while a peer's in-flight collection remains alive until its last lease is released.
        let task = Task { [weak self] in
            let result: Result<SessionSnapshot?, Error>
            do {
                result = .success(initial ? try await engine.open(id: rootID, progress: { continuation.yield($0) }) : try await engine.refresh())
            } catch { result = .failure(error) }
            continuation.finish()
            await observer.value
            await self?.finishCollection(id: id, result: result)
        }
        flight = Flight(id: id, task: task); startedCollections += 1
    }

    private func finishCollection(id: UUID, result: Result<SessionSnapshot?, Error>) {
        guard !closed, flight?.id == id else { return }
        flight = nil
        loadObservers = [:]; loadProgress = nil
        let publication: Result<SessionReaderUpdate, Error>
        switch result {
        case .success(let snapshot):
            if let snapshot { latest = SessionReaderUpdate(snapshot: snapshot, revision: (latest?.revision ?? 0) &+ 1) }
            publication = latest.map { .success($0) } ?? .failure(LensError.unavailable("Aucun historique disponible pour cette session."))
        case .failure(let error): publication = .failure(error)
        }
        let pending = waiters; waiters = [:]
        for continuation in pending.values { continuation.resume(with: publication) }
    }

    private func cancelWaiter(_ id: UUID) { loadObservers[id] = nil; waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }

    private func publishProgress(_ progress: SessionLoadingProgress, id: UUID, catalog: Bool) {
        guard !closed, (catalog ? catalogFlight?.id : flight?.id) == id else { return }
        if catalog {
            catalogProgress = progress
            for observer in catalogObservers.values { observer(progress) }
        } else {
            loadProgress = progress
            for observer in loadObservers.values { observer(progress) }
        }
    }

    fileprivate func close() async {
        if closed { await closingTask?.value; return }
        closed = true
        let tasks = [flight?.task, catalogFlight?.task].compactMap { $0 } + Array(retiringCatalogFlights.values)
        for task in tasks { task.cancel() }
        closingTask = Task { for task in tasks { await task.value } }
        flight = nil; catalogFlight = nil; retiringCatalogFlights = [:]; latest = nil
        loadObservers = [:]; catalogObservers = [:]; loadProgress = nil; catalogProgress = nil
        let pending = waiters; waiters = [:]
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        let pendingCatalogs = catalogWaiters; catalogWaiters = [:]
        for continuation in pendingCatalogs.values { continuation.resume(throwing: CancellationError()) }
        // Cancellation alone doesn't wait for an already-running cache write.
        await closingTask?.value
        closingTask = nil
    }
}

fileprivate struct SessionReaderKey: Hashable, Sendable {
    let home: String, cache: String
    let rootID: String?
}

/// An explicit subscription; release is idempotent. Deinit is a fallback for an unclosed window.
public final class SessionReaderLease: Sendable {
    public let id: UUID
    public let reader: SessionReader
    public let engine: SessionEngine
    private let pool: SessionReaderPool
    private let key: SessionReaderKey
    fileprivate init(id: UUID, reader: SessionReader, pool: SessionReaderPool, key: SessionReaderKey) {
        self.id = id; self.reader = reader; self.engine = reader.engine; self.pool = pool; self.key = key
    }
    public func release() async { await pool.release(id: id, key: key) }
    deinit {
        let pool = pool, id = id, key = key
        Task { await pool.release(id: id, key: key) }
    }
}

/// Share only readers with the same source, own cache and root. Repository paths never establish identity.
public actor SessionReaderPool {
    public static let shared = SessionReaderPool()
    private struct Entry { let reader: SessionReader; var subscribers: Set<UUID> }
    private var entries: [SessionReaderKey: Entry] = [:]
    private var closingReaders: [UUID: SessionReader] = [:]
    private var acquisitionsSuspended = false
    private let investigationRegistryDirectory: URL?
    public init(investigationRegistryDirectory: URL? = nil) { self.investigationRegistryDirectory = investigationRegistryDirectory }
    internal var activeReaderCount: Int { entries.count }
    public func setAcquisitionsSuspended(_ value: Bool) { acquisitionsSuspended = value }

    /// Drain existing readers, including a last-lease release already in progress.
    /// A later user-requested acquisition can create a fresh reader after recovery.
    public func quiesce() async {
        let readers = entries.values.map(\.reader) + Array(closingReaders.values)
        entries.removeAll()
        for reader in readers { await closeReader(reader) }
    }
    private func closeReader(_ reader: SessionReader) async {
        let id = UUID(); closingReaders[id] = reader
        await reader.close()
        closingReaders[id] = nil
    }

    public func acquire(home: URL, cacheDirectory: URL? = nil, rootID: String? = nil) throws -> SessionReaderLease {
        try Task.checkCancellation()
        guard !acquisitionsSuspended else { throw CancellationError() }
        let cache = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexLens/Index-v1")
        guard home.isFileURL, cache.isFileURL else { throw LensError.unsupported("Les lecteurs utilisent des sources et caches locaux.") }
        let root = rootID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root != "" else { throw LensError.unavailable("ID de session vide.") }
        let sourceURL = home.standardizedFileURL.resolvingSymlinksInPath(), cacheURL = cache.standardizedFileURL.resolvingSymlinksInPath()
        let key = SessionReaderKey(home: Self.canonicalKeyURL(home).path, cache: Self.canonicalKeyURL(cache).path, rootID: root)
        let reader: SessionReader
        if let entry = entries[key] { reader = entry.reader }
        else { reader = SessionReader(engine: SessionEngine(home: sourceURL, cacheDirectory: cacheURL, investigationRegistryDirectory: investigationRegistryDirectory), rootID: root) }
        let id = UUID()
        var subscribers = entries[key]?.subscribers ?? []; subscribers.insert(id)
        entries[key] = Entry(reader: reader, subscribers: subscribers)
        return SessionReaderLease(id: id, reader: reader, pool: self, key: key)
    }

    /// Foundation may leave an entire nonexistent path unresolved. Resolve its
    /// existing ancestor first so creating the cache does not change pool identity.
    /// This reads metadata only; the engine keeps its existing source/cache URLs
    /// and remains responsible for reporting inaccessible cache locations.
    private static func canonicalKeyURL(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var canonical = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return canonical.standardizedFileURL
    }

    fileprivate func release(id: UUID, key: SessionReaderKey) async {
        guard var entry = entries[key], entry.subscribers.remove(id) != nil else { return }
        if entry.subscribers.isEmpty { entries.removeValue(forKey: key); await closeReader(entry.reader) }
        else { entries[key] = entry }
    }
}
