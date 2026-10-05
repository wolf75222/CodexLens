import Foundation
import XCTest
@testable import LensCore

/// These readers consume only invented histories in /private/tmp, never the user's Codex home.
final class SessionReaderPoolTests: XCTestCase {
    func testSameCanonicalSourceCacheAndRootShareReaderButOtherKeysDoNot() async throws {
        let f = try ReaderFixture(); defer { f.remove() }
        let pool = SessionReaderPool()
        let first = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let alias = f.base.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.home)
        let second = try await pool.acquire(home: alias, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let otherRoot = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.b)
        let otherCache = try await pool.acquire(home: f.home, cacheDirectory: f.base.appendingPathComponent("other-cache"), rootID: ReaderFixture.a)
        let catalog = try await pool.acquire(home: f.home, cacheDirectory: f.cache)
        XCTAssertTrue(first.reader === second.reader); XCTAssertTrue(first.engine === second.engine)
        XCTAssertFalse(first.reader === otherRoot.reader, "A common directory cannot associate independent root histories")
        XCTAssertFalse(first.reader === otherCache.reader); XCTAssertFalse(first.reader === catalog.reader)
        var count = await pool.activeReaderCount; XCTAssertEqual(count, 4)
        await first.release(); count = await pool.activeReaderCount; XCTAssertEqual(count, 4)
        for lease in [second, otherRoot, otherCache, catalog] { await lease.release() }
        count = await pool.activeReaderCount; XCTAssertEqual(count, 0)
    }

    func testCoalescedInitialLoadAndSequentialRefreshPublishAppendToEverySubscriber() async throws {
        let f = try ReaderFixture(); defer { f.remove() }
        let path = try f.write(id: ReaderFixture.a, count: 120)
        let before = try Data(contentsOf: path), pool = SessionReaderPool()
        let first = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let second = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        async let one = first.reader.load()
        async let two = second.reader.load()
        let (initial, peerInitial) = try await (one, two)
        XCTAssertEqual(initial.revision, peerInitial.revision)
        XCTAssertEqual(initial.snapshot.events.map(\.id), peerInitial.snapshot.events.map(\.id))
        let starts = await first.reader.startedCollections; XCTAssertEqual(starts, 1)
        XCTAssertEqual(try Data(contentsOf: path), before)
        try f.append("append available to both windows", to: path)
        let next = try await first.reader.refresh()
        let peerNext = try await second.reader.refresh()
        XCTAssertEqual(next.revision, initial.revision + 1); XCTAssertEqual(peerNext.revision, next.revision)
        XCTAssertTrue(peerNext.snapshot.events.contains { $0.preview.contains("append available to both windows") })
        await first.release()
        try f.append("remaining window still observes", to: path)
        let stillOpen = try await second.reader.refresh()
        XCTAssertTrue(stillOpen.snapshot.events.contains { $0.preview.contains("remaining window still observes") })
        await second.release()
        let count = await pool.activeReaderCount; XCTAssertEqual(count, 0)
    }

    func testDistinctRootsInSameEnvironmentKeepTheirOwnSelection() async throws {
        let f = try ReaderFixture(); defer { f.remove() }
        let firstPath = try f.write(id: ReaderFixture.a, count: 2)
        _ = try f.write(id: ReaderFixture.b, count: 3)
        let pool = SessionReaderPool()
        let first = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let second = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.b)
        _ = try await first.reader.load(); _ = try await second.reader.load()
        try f.append("append belongs only to root A", to: firstPath)
        let updated = try await first.reader.refresh(), unchanged = try await second.reader.refresh()
        XCTAssertEqual(updated.snapshot.root.id, ReaderFixture.a); XCTAssertEqual(unchanged.snapshot.root.id, ReaderFixture.b)
        XCTAssertFalse(unchanged.snapshot.events.contains { $0.preview.contains("append belongs only to root A") })
        XCTAssertFalse(updated.snapshot.agents.contains { $0.id == ReaderFixture.b })
        await first.release(); await second.release()
    }

    func testCancellingOneWaiterDoesNotCancelItsPeersCollection() async throws {
        let f = try ReaderFixture(); defer { f.remove() }
        let path = try f.write(id: ReaderFixture.a, count: 8000)
        let before = try Data(contentsOf: path), pool = SessionReaderPool()
        let cancelledLease = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let peerLease = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let cancelled = Task { try await cancelledLease.reader.load() }
        let peer = Task { try await peerLease.reader.load() }
        try await Task.sleep(nanoseconds: 5_000_000); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A cancelled waiter must not publish a late success") }
        catch is CancellationError { }
        await cancelledLease.release()
        let publication = try await peer.value
        XCTAssertEqual(publication.snapshot.root.id, ReaderFixture.a)
        XCTAssertEqual(publication.snapshot.events.filter { $0.kind == .assistant }.count, 8000)
        let starts = await peerLease.reader.startedCollections; XCTAssertEqual(starts, 1)
        XCTAssertEqual(try Data(contentsOf: path), before)
        await peerLease.release()
    }

    func testLastReleaseCancelsOnlyOwnedReadAndOldReleaseCannotCloseNewLease() async throws {
        let f = try ReaderFixture(); defer { f.remove() }
        let path = try f.write(id: ReaderFixture.a, count: 8000)
        let before = try Data(contentsOf: path), pool = SessionReaderPool()
        let lease = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        let loading = Task { try await lease.reader.load() }
        try await Task.sleep(nanoseconds: 5_000_000); await lease.release()
        do { _ = try await loading.value; XCTFail("The last release must resume outstanding consumers with cancellation") }
        catch is CancellationError { }
        var count = await pool.activeReaderCount; XCTAssertEqual(count, 0)
        let reopened = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        await lease.release() // idempotent even after the same key has been reused
        count = await pool.activeReaderCount; XCTAssertEqual(count, 1)
        let result = try await reopened.reader.load(); XCTAssertEqual(result.snapshot.root.id, ReaderFixture.a)
        XCTAssertEqual(try Data(contentsOf: path), before)
        await reopened.release()
    }

    func testLeaseDeinitReleasesPoolEntryWhenWindowOwnerDisappears() async throws {
        let f = try ReaderFixture(); defer { f.remove() }
        let pool = SessionReaderPool()
        var lease: SessionReaderLease? = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: ReaderFixture.a)
        weak var formerLease = lease
        lease = nil
        var count = await pool.activeReaderCount
        for _ in 0..<100 where count != 0 { try await Task.sleep(nanoseconds: 10_000_000); count = await pool.activeReaderCount }
        XCTAssertNil(formerLease); XCTAssertEqual(count, 0)
    }
}

private struct ReaderFixture {
    static let a = "cccccccc-0000-4000-8000-000000000001", b = "cccccccc-0000-4000-8000-000000000002"
    let base: URL, home: URL, cache: URL, directory: URL, environment: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lens-reader-tests-" + UUID().uuidString)
        home = base.appendingPathComponent("home"); cache = base.appendingPathComponent("cache")
        directory = home.appendingPathComponent("sessions/2026/10/02"); environment = base.appendingPathComponent("same-environment")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        var result = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-02T00:00:00.000Z", "type": type, "payload": payload], options: [.sortedKeys]); result.append(10)
        return result
    }
    func message(_ text: String) throws -> Data { try record("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]) }
    func write(id: String, count: Int) throws -> URL {
        let path = directory.appendingPathComponent("rollout-2026-10-02T00-00-00-" + id + ".jsonl")
        var bytes = try record("session_meta", ["id": id, "cwd": environment.path, "source": "cli"])
        for index in 0..<count { bytes.append(try message("Recorded message \(index) in \(id) " + String(repeating: "invented history ", count: 20))) }
        try bytes.write(to: path); return path
    }
    func append(_ text: String, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: message(text))
    }
}
