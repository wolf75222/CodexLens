import Foundation
import XCTest
@testable import LensCore

final class SessionLoadingProgressTests: XCTestCase {
    func testUnknownAndGrowingTotalsDoNotInventAWholeOperationPercentage() {
        XCTAssertNil(SessionLoadingProgress(stage: .discoveringSessions, completed: 10).fraction)
        XCTAssertNil(SessionLoadingProgress(stage: .readingMetadata, total: 0).fraction)
        XCTAssertEqual(SessionLoadingProgress(stage: .readingHistory, completed: 25, total: 100).fraction, 0.25)
        let growing = SessionLoadingProgress(stage: .readingHistory, completed: 120, total: 100)
        XCTAssertEqual(growing.total, 120)
        XCTAssertEqual(growing.fraction, 1)
    }

    func testHistoryUsesByteWeightsAndExpandsForNewlyDiscoveredFiles() {
        let history = SessionHistoryProgress()
        history.register(path: "small", bytes: 10); history.register(path: "large", bytes: 90)
        history.update(path: "small", completedBytes: 10, totalBytes: 10); history.finish(path: "small")
        let first = SessionLoadingProgress(stage: .readingHistory, completed: 10, total: 10, fileName: "small", history: history.snapshot)
        XCTAssertEqual(first.fraction, 0.1, "A complete small file is not half of the byte workload")
        XCTAssertEqual(first.history?.completedFiles, 1)
        XCTAssertEqual(first.history?.currentFile, 1)
        history.update(path: "large", completedBytes: 45, totalBytes: 90)
        XCTAssertEqual(history.snapshot.fraction, 0.55)
        XCTAssertEqual(history.snapshot.currentFile, 2)
        history.register(path: "late", bytes: 100)
        XCTAssertEqual(history.snapshot.totalFiles, 3)
        XCTAssertEqual(history.snapshot.completedBytes, 55)
        XCTAssertEqual(history.snapshot.totalBytes, 200)
        history.update(path: "large", completedBytes: 120, totalBytes: 120)
        XCTAssertEqual(history.snapshot.totalBytes, 230, "A live journal may grow after the initial plan")
        history.register(path: "unknown", bytes: nil)
        XCTAssertNil(history.snapshot.fraction, "Missing byte bounds must not produce a global percentage")
        XCTAssertEqual(SessionLoadingProgress(stage: .readingHistory, completed: 120, total: 120, history: history.snapshot).fraction, nil)
    }

    func testEngineReportsAggregateCompletionAcrossTwoJournalFiles() async throws {
        let f = try ProgressFixture(); defer { f.remove() }
        let a = try f.write(count: 6000), original = try Data(contentsOf: a)
        let b = f.home.appendingPathComponent("sessions/short-history.jsonl")
        var short = Data()
        for line in original.split(separator: 10).prefix(40) { short.append(contentsOf: line); short.append(10) }
        try short.write(to: b)
        let capture = ProgressCapture(), engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        _ = try await engine.open(id: ProgressFixture.id, progress: { capture.append($0) })
        let histories = capture.values.filter { $0.stage == .readingHistory }.compactMap(\.history)
        let last = try XCTUnwrap(histories.last)
        XCTAssertEqual(last.totalBytes, Int64(original.count + short.count))
        XCTAssertEqual(last.completedBytes, last.totalBytes)
        XCTAssertEqual(last.totalFiles, 2); XCTAssertEqual(last.completedFiles, 2)
        XCTAssertEqual(last.fraction, 1)
        XCTAssertTrue(histories.contains { $0.completedFiles == 1 && ($0.fraction ?? 1) < 1 })
        XCTAssertEqual(try Data(contentsOf: a), original); XCTAssertEqual(try Data(contentsOf: b), short)
        XCTAssertEqual(SessionLoadingProgress(stage: .readingHistory).openingStep, 2)
        XCTAssertEqual(SessionLoadingProgress(stage: .savingIndex).openingStep, 4)
    }

    func testReporterCoalescesRapidWorkButKeepsStageAndFileBoundaries() {
        let capture = ProgressCapture()
        let measured = SessionProgressReporter { capture.append($0) }
        for count in 0...100 { measured.send(.init(stage: .readingMetadata, completed: Int64(count), total: 100)) }
        XCTAssertEqual(capture.values.first?.completed, 0)
        XCTAssertEqual(capture.values.last?.completed, 100)
        XCTAssertLessThan(capture.values.count, 10)
        measured.send(.init(stage: .readingHistory, total: 100, fileName: "a.jsonl"))
        measured.send(.init(stage: .readingHistory, total: 100, fileName: "b.jsonl"))
        XCTAssertEqual(capture.values.suffix(2).map(\.fileName), ["a.jsonl", "b.jsonl"])
    }

    func testEnginePublishesMeasuredCatalogBytesAndRecordsWithoutChangingSources() async throws {
        let f = try ProgressFixture(); defer { f.remove() }
        let log = try f.write(count: 6000)
        let original = try Data(contentsOf: log)
        let originalBytes = Int64(original.count)
        let capture = ProgressCapture()
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: ProgressFixture.id, progress: { capture.append($0) })
        let values = capture.values
        XCTAssertEqual(snapshot.root.id, ProgressFixture.id)
        XCTAssertTrue(values.contains { $0.stage == .readingMetadata && $0.completed == 1 && $0.total == 1 })
        XCTAssertTrue(values.contains { $0.stage == .readingHistory && $0.completed == originalBytes && $0.total == originalBytes })
        XCTAssertTrue(values.contains { $0.stage == .organizingEvents && $0.completed == $0.total && ($0.total ?? 0) >= 6000 })
        XCTAssertEqual(values.last?.stage, .savingIndex)
        XCTAssertEqual(try Data(contentsOf: log), original)
        let history = values.filter { $0.stage == .readingHistory }
        XCTAssertEqual(history.first?.completed, 0)
        XCTAssertEqual(history.first?.fileName, log.lastPathComponent)
        XCTAssertTrue(zip(history, history.dropFirst()).allSatisfy { $0.completed <= $1.completed })
        // The cache is reused but still reports the measured indexed byte extent.
        let warm = ProgressCapture()
        _ = try await engine.open(id: ProgressFixture.id, progress: { warm.append($0) })
        XCTAssertTrue(warm.values.contains { $0.stage == .readingHistory && $0.completed == originalBytes })
        XCTAssertEqual(try Data(contentsOf: log), original)
    }

    func testSharedReadersFanOutProgressAndCancellationKeepsPeerLoadIntact() async throws {
        let f = try ProgressFixture(); defer { f.remove() }
        let log = try f.write(count: 15000)
        let original = try Data(contentsOf: log)
        let pool = SessionReaderPool()
        let a = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ProgressFixture.id)
        let b = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ProgressFixture.id)
        let cancelled = ProgressCapture(), peer = ProgressCapture()
        let taskA = Task { try await a.reader.load(progress: { cancelled.append($0) }) }
        let taskB = Task { try await b.reader.load(progress: { peer.append($0) }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while peer.values.isEmpty {
            guard ContinuousClock.now < deadline else { taskA.cancel(); taskB.cancel(); throw LensError.unavailable("Fixture reader did not publish progress") }
            try await Task.sleep(for: .milliseconds(1))
        }
        taskA.cancel()
        do { _ = try await taskA.value; XCTFail("Cancelled load must not report success") } catch is CancellationError { }
        let loaded = try await taskB.value
        XCTAssertEqual(loaded.snapshot.root.id, ProgressFixture.id)
        XCTAssertTrue(peer.values.contains { $0.stage == .readingHistory })
        XCTAssertEqual(peer.values.last?.stage, .savingIndex)
        let count = cancelled.values.count
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(cancelled.values.count, count, "Unsubscribed progress must stay stopped")
        let started = await a.reader.startedCollections
        XCTAssertEqual(started, 1)
        XCTAssertEqual(try Data(contentsOf: log), original)
        await a.release(); await b.release()
    }

    func testMissingSessionDoesNotPublishSuccessfulIndexCompletion() async throws {
        let f = try ProgressFixture(); defer { f.remove() }
        let capture = ProgressCapture()
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        do { _ = try await engine.open(id: ProgressFixture.id, progress: { capture.append($0) }); XCTFail("Missing source must fail") } catch { }
        XCTAssertFalse(capture.values.contains { $0.stage == .savingIndex || $0.stage == .restoringWorkspace })
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionLoadingProgress] = []
    func append(_ value: SessionLoadingProgress) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [SessionLoadingProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct ProgressFixture {
    static let id = "11111111-1111-4111-8111-111111111111"
    let base: URL, home: URL, cache: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lens-progress-" + UUID().uuidString)
        home = base.appendingPathComponent("codex"); cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }
    func write(count: Int) throws -> URL {
        let file = home.appendingPathComponent("sessions/history.jsonl")
        var data = Data()
        func line(_ record: [String: Any]) throws { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try line(["type": "session_meta", "timestamp": "2026-10-01T12:00:00Z", "payload": ["id": Self.id, "cwd": base.path, "cli_version": "0.159.0"]])
        for i in 0..<count {
            try line(["type": "event_msg", "timestamp": "2026-10-01T12:00:01Z", "payload": ["type": "user_message", "message": "Fixture message \(i) " + String(repeating: "x", count: 180)]])
        }
        try data.write(to: file); return file
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
