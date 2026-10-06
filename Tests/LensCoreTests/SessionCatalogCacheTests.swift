import CSQLite
import Darwin
import Foundation
import XCTest
@testable import LensCore

/// Catalog changes use isolated synthetic sources, including their writable
/// fixture database. The adapter itself must leave every source byte intact.
final class SessionCatalogCacheTests: XCTestCase {
    func testWarmCatalogAndNewEngineReuseValidatedPersistentHeaders() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a", nickname: "Alpha")
        let original = try Data(contentsOf: path)
        let engine = f.engine()
        let first = try await engine.catalog(), cold = await diagnostics(engine)
        let second = try await engine.catalog(), warm = await diagnostics(engine)
        XCTAssertEqual(first, second)
        XCTAssertEqual(cold.reads, 1); XCTAssertEqual(cold.hits, 0)
        XCTAssertEqual(warm.reads, cold.reads); XCTAssertEqual(warm.hits, 1)

        let reopened = f.engine()
        let restored = try await reopened.catalog(), persisted = await diagnostics(reopened)
        XCTAssertEqual(restored, first)
        XCTAssertEqual(persisted.reads, 0); XCTAssertEqual(persisted.hits, 1)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testAppendAndTouchRevalidateOnlyTheChangedHeaderAndUpdateOrdering() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let a = try f.rollout(id: "thread-a"), b = try f.rollout(id: "thread-b")
        let initialDate = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.modificationDate: initialDate.addingTimeInterval(1)], ofItemAtPath: b.path)
        let originalB = try Data(contentsOf: b), engine = f.engine()
        _ = try await engine.catalog()
        let before = await diagnostics(engine)
        try f.appendMessage("Appended only to A", to: a)
        let appended = try await engine.catalog(), afterAppend = await diagnostics(engine)
        XCTAssertEqual(Set(appended.map(\.id)), ["thread-a", "thread-b"])
        XCTAssertEqual(appended.first?.id, "thread-a")
        XCTAssertEqual(afterAppend.reads, before.reads + 1); XCTAssertEqual(afterAppend.hits, before.hits + 1)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: b.path)
        let touched = try await engine.catalog(), afterTouch = await diagnostics(engine)
        XCTAssertEqual(touched.first?.id, "thread-b")
        XCTAssertEqual(afterTouch.reads, afterAppend.reads + 1); XCTAssertEqual(afterTouch.hits, afterAppend.hits + 1)
        XCTAssertEqual(try Data(contentsOf: b), originalB)
    }

    func testSameSizeHeaderEditWithExactlyRestoredMtimeDoesNotServeOldMetadata() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a", nickname: "Alpha")
        let engine = f.engine()
        _ = try await engine.catalog()
        let previous = try CatalogCacheFixture.fileStat(path)
        let before = try SessionCatalogStamp.read(path: path.path)
        let oldBytes = try Data(contentsOf: path)
        let changed = try f.bytes(id: "thread-a", nickname: "Bravo")
        XCTAssertEqual(changed.count, oldBytes.count)
        try await Task.sleep(nanoseconds: 2_000_000)
        try changed.write(to: path)
        try CatalogCacheFixture.restoreTimes(previous, to: path)
        let stamp = try SessionCatalogStamp.read(path: path.path)
        XCTAssertEqual(stamp.inode, before.inode); XCTAssertEqual(stamp.size, before.size)
        XCTAssertEqual(stamp.modifiedSeconds, before.modifiedSeconds); XCTAssertEqual(stamp.modifiedNanos, before.modifiedNanos)
        XCTAssertNotEqual(stamp, before, "ctime must distinguish this edit even after mtime is restored")
        let current = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(current.first?.agentName, "Bravo")
        XCTAssertEqual(counts.reads, 2)
        XCTAssertEqual(try Data(contentsOf: path), changed)
    }

    func testAtomicReplacementWithSameLengthAndMtimeUsesNewInodeOwner() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a", nickname: "Alpha")
        let engine = f.engine()
        _ = try await engine.catalog()
        let original = try CatalogCacheFixture.fileStat(path)
        let replacement = path.deletingLastPathComponent().appendingPathComponent("replacement.tmp")
        let bytes = try f.bytes(id: "thread-b", nickname: "Bravo")
        XCTAssertEqual(bytes.count, try Data(contentsOf: path).count)
        try bytes.write(to: replacement)
        try CatalogCacheFixture.restoreTimes(original, to: replacement)
        guard replacement.path.withCString({ old in path.path.withCString { new in Darwin.rename(old, new) } }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        XCTAssertNotEqual(try CatalogCacheFixture.fileStat(path).st_ino, original.st_ino)
        let catalog = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(catalog.map(\.id), ["thread-b"]); XCTAssertEqual(catalog.first?.agentName, "Bravo")
        XCTAssertEqual(counts.reads, 2)
    }

    func testTruncatedAndThenCompletedMetadataIsRetried() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a"), engine = f.engine()
        _ = try await engine.catalog()
        let truncated = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a".utf8)
        try truncated.write(to: path)
        let missing = try await engine.catalog(), afterTruncation = await diagnostics(engine)
        XCTAssertTrue(missing.isEmpty); XCTAssertEqual(afterTruncation.reads, 2)
        let completed = try f.bytes(id: "thread-b", nickname: "Bravo")
        try completed.write(to: path)
        let recovered = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(recovered.map(\.id), ["thread-b"]); XCTAssertEqual(counts.reads, 3)
        XCTAssertEqual(try Data(contentsOf: path), completed)
    }

    func testMalformedInitialMetadataIsNotPermanentlyNegativeCached() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = f.home.appendingPathComponent("sessions/new.jsonl")
        try Data().write(to: path)
        let engine = f.engine()
        let empty = try await engine.catalog()
        XCTAssertTrue(empty.isEmpty)
        try f.bytes(id: "thread-new").write(to: path)
        let completed = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(completed.map(\.id), ["thread-new"]); XCTAssertEqual(counts.reads, 2)
    }

    func testAdditionDeletionAndArchivalMovePreserveCurrentPathsAndPruneEntries() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let a = try f.rollout(id: "thread-a"), engine = f.engine()
        _ = try await engine.catalog()
        let b = try f.rollout(id: "thread-b")
        let added = try await engine.catalog(), afterAddition = await diagnostics(engine)
        XCTAssertEqual(Set(added.map(\.id)), ["thread-a", "thread-b"])
        XCTAssertEqual(afterAddition.reads, 2); XCTAssertEqual(afterAddition.hits, 1)
        try FileManager.default.removeItem(at: a)
        let removed = try await engine.catalog(), afterDeletion = await diagnostics(engine)
        XCTAssertEqual(removed.map(\.id), ["thread-b"])
        XCTAssertLessThan(afterDeletion.bytes, afterAddition.bytes)
        let archived = f.home.appendingPathComponent("archived_sessions/archive-b.jsonl")
        try FileManager.default.moveItem(at: b, to: archived)
        let moved = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(moved.map(\.id), ["thread-b"])
        XCTAssertEqual(CatalogCacheFixture.canonicalPaths(moved.first?.paths ?? []), CatalogCacheFixture.canonicalPaths([archived.path]))
        XCTAssertEqual(counts.reads, 3)
    }

    func testSameThreadIDInSeparateHomesSharingCacheKeepsWorktreeIdentity() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let other = f.base.appendingPathComponent("other-home")
        let id = "aaaaaaaa-1111-4111-8111-111111111111"
        try f.createSource(other)
        let a = try f.rollout(id: id, cwd: f.base.appendingPathComponent("alpha"))
        let b = try f.rollout(id: id, home: other, cwd: f.base.appendingPathComponent("bravo"))
        let first = f.engine(), second = f.engine(home: other)
        let one = try await first.catalog(), two = try await second.catalog()
        XCTAssertEqual(one.first?.id, two.first?.id)
        XCTAssertNotEqual(one.first?.cwd, two.first?.cwd)
        XCTAssertEqual(CatalogCacheFixture.canonicalPaths(one.first?.paths ?? []), CatalogCacheFixture.canonicalPaths([a.path]))
        XCTAssertEqual(CatalogCacheFixture.canonicalPaths(two.first?.paths ?? []), CatalogCacheFixture.canonicalPaths([b.path]))
        let reopened = f.engine()
        let restored = try await reopened.catalog(), counts = await diagnostics(reopened)
        XCTAssertEqual(restored, one); XCTAssertEqual(counts.reads, 0); XCTAssertEqual(counts.hits, 1)
        XCTAssertEqual(try f.cacheFiles().count, 2)
    }

    func testTitleIndexUpdateIsMergedWithWarmHeaders() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        _ = try f.rollout(id: "thread-a")
        try f.titleIndex("First title", id: "thread-a")
        let engine = f.engine(), first = try await engine.catalog()
        XCTAssertEqual(first.first?.title, "First title")
        try f.titleIndex("Second title", id: "thread-a")
        let second = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(second.first?.title, "Second title")
        XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.hits, 1)
    }

    func testWALTitleAndRemovedDatabaseParentDoNotMutateCachedRawParentage() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let parent = try f.rollout(id: "parent-thread"), child = try f.rollout(id: "child-thread")
        let db = try CatalogCacheDatabase(url: f.home.appendingPathComponent("state_5.sqlite"))
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,cwd TEXT,title TEXT,updated_at INTEGER); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT);")
        try db.execute("INSERT INTO threads VALUES('parent-thread',\(CatalogCacheDatabase.quote(parent.path)),\(CatalogCacheDatabase.quote(f.home.path)),'Parent',1); INSERT INTO threads VALUES('child-thread',\(CatalogCacheDatabase.quote(child.path)),\(CatalogCacheDatabase.quote(f.home.path)),'Before WAL',1); INSERT INTO thread_spawn_edges VALUES('parent-thread','child-thread');")
        let engine = f.engine(), first = try await engine.catalog()
        XCTAssertEqual(first.first(where: { $0.id == "child-thread" })?.parentID, "parent-thread")
        XCTAssertEqual(first.first(where: { $0.id == "child-thread" })?.relation, .subagent)
        let originalDB = try Data(contentsOf: db.url)
        try db.execute("UPDATE threads SET title='After WAL' WHERE id='child-thread'; DELETE FROM thread_spawn_edges;")
        XCTAssertEqual(try Data(contentsOf: db.url), originalDB, "This change must be visible through WAL without a main-file rewrite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.url.path + "-wal"))
        let second = try await engine.catalog(), counts = await diagnostics(engine)
        let updated = try XCTUnwrap(second.first { $0.id == "child-thread" })
        XCTAssertEqual(updated.title, "After WAL"); XCTAssertNil(updated.parentID); XCTAssertEqual(updated.relation, .root)
        XCTAssertEqual(counts.reads, 2); XCTAssertEqual(counts.hits, 2)
    }

    func testCorruptPersistentCacheFallsBackToSourcesAndRebuilds() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a"), original = try Data(contentsOf: path)
        let first = try await f.engine().catalog()
        let file = try XCTUnwrap(f.cacheFiles().first)
        try Data("invented corrupt cache".utf8).write(to: file)
        let reopened = f.engine(), current = try await reopened.catalog(), counts = await diagnostics(reopened)
        XCTAssertEqual(current, first); XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.hits, 0)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testUnavailableCacheStillAllowsCorrectInMemoryWarmCatalog() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a"), original = try Data(contentsOf: path)
        let blocker = Data("The cache path is an ordinary fixture file".utf8)
        try blocker.write(to: f.cache)
        let engine = f.engine(), first = try await engine.catalog(), second = try await engine.catalog()
        let counts = await diagnostics(engine)
        XCTAssertEqual(first, second); XCTAssertEqual(first.map(\.id), ["thread-a"])
        XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.hits, 1)
        XCTAssertEqual(try Data(contentsOf: f.cache), blocker); XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testValidSchemaPayloadChangeWithOldChecksumCannotReplaceSourceMetadata() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let path = try f.rollout(id: "thread-a", nickname: "Alpha"), originalSource = try Data(contentsOf: path)
        let original = try await f.engine().catalog()
        let file = try XCTUnwrap(f.cacheFiles().first)
        var container = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        let payload = try XCTUnwrap(container["payload"] as? Data)
        let checksum = try XCTUnwrap(container["checksum"] as? Data)
        var envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        var entries = try XCTUnwrap(envelope["entries"] as? [String: Any])
        let key = try XCTUnwrap(entries.keys.first)
        var entry = try XCTUnwrap(entries[key] as? [String: Any])
        var header = try XCTUnwrap(entry["header"] as? [String: Any])
        header["name"] = "Invented valid-schema cache replacement"
        entry["header"] = header; entries[key] = entry; envelope["entries"] = entries
        let changedPayload = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        XCTAssertNotEqual(changedPayload, payload)
        container["payload"] = changedPayload
        XCTAssertEqual(container["checksum"] as? Data, checksum)
        try PropertyListSerialization.data(fromPropertyList: container, format: .binary, options: 0).write(to: file)

        let reopened = f.engine(), restored = try await reopened.catalog(), counts = await diagnostics(reopened)
        XCTAssertEqual(restored, original); XCTAssertEqual(restored.first?.agentName, "Alpha")
        XCTAssertEqual(counts.reads, 1); XCTAssertEqual(counts.hits, 0)
        XCTAssertEqual(try Data(contentsOf: path), originalSource)
    }

    func testWarmHeadersRecheckOwnershipAndCorruptRegistryFailsClosed() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        _ = try f.rollout(id: "observed-source")
        _ = try f.rollout(id: "late-investigation", parent: "observed-source")
        _ = try f.rollout(id: "owned-child", parent: "late-investigation")
        let engine = f.engine(), initial = try await engine.catalog()
        XCTAssertEqual(Set(initial.map(\.id)), ["observed-source", "late-investigation", "owned-child"])
        _ = try await engine.catalog()
        let warmed = await diagnostics(engine)
        let registry = CodexInvestigationRegistry(directory: f.registry)
        let chat = try await registry.chat(root: "observed-source")
        _ = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "late-investigation")
        let excluded = try await engine.catalog(), afterOwnership = await diagnostics(engine)
        XCTAssertEqual(excluded.map(\.id), ["observed-source"])
        XCTAssertEqual(afterOwnership.reads, warmed.reads, "Ownership must update without reparsing unchanged headers")
        let validRegistry = try Data(contentsOf: registry.fileURL)
        try Data("corrupt ownership registry".utf8).write(to: registry.fileURL)
        do { _ = try await engine.catalog(); XCTFail("Cached success cannot bypass corrupt ownership") } catch { }
        let afterCorruption = await diagnostics(engine)
        XCTAssertEqual(afterCorruption.reads, afterOwnership.reads)
        try validRegistry.write(to: registry.fileURL)
        let recovered = try await engine.catalog()
        XCTAssertEqual(recovered.map(\.id), ["observed-source"])
    }

    func testPersistentHeaderIsCompactAndDoesNotRetainInstructionsOrMessages() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let marker = "INVENTED_PRIVATE_INSTRUCTION_NOT_A_CATALOG_FIELD"
        let instructions = String(repeating: marker + "\n", count: 2048)
        let path = try f.rollout(id: "thread-a", instructions: instructions)
        let source = try Data(contentsOf: path), engine = f.engine()
        let catalog = try await engine.catalog(), counts = await diagnostics(engine)
        XCTAssertEqual(catalog.map(\.id), ["thread-a"])
        XCTAssertGreaterThan(source.count, 64 * 1024)
        XCTAssertLessThan(counts.bytes, 4096)
        let file = try XCTUnwrap(f.cacheFiles().first), cached = try Data(contentsOf: file)
        XCTAssertNil(cached.range(of: Data(marker.utf8)))
        XCTAssertNil(cached.range(of: Data(CatalogCacheFixture.messageMarker.utf8)))
        XCTAssertLessThan(cached.count, 8192)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: path), source)
    }

    func testMetadataBudgetEvictsAndPrunesWithoutKeepingAllLargeCompactFields() throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let source = try f.rollout(id: "source"), stamp = try SessionCatalogStamp.read(path: source.path)
        var cache = SessionCatalogCache(home: f.home, cacheDirectory: f.cache)
        let largeCwd = "/anonymous/" + String(repeating: "x", count: 60_000)
        var paths: [String] = []
        for index in 0..<80 {
            let path = f.home.appendingPathComponent("sessions/header-\(index).jsonl").path
            paths.append(path)
            cache.insert(SessionCatalogHeader(id: "thread-\(index)", sessionID: nil, cwd: largeCwd, cliVersion: "0.159.2", name: "",
                branch: nil, gitRef: nil, parent: nil, relation: .root, historyStart: nil,
                source: SourceRef(path: path, offset: 0, length: 128, line: 1, sha256: String(repeating: "a", count: 64))), stamp: stamp)
        }
        XCTAssertGreaterThan(cache.count, 0); XCTAssertLessThan(cache.count, paths.count)
        XCTAssertLessThanOrEqual(cache.estimatedBytes, SessionCatalogCache.maximumBytes)
        let last = try XCTUnwrap(paths.last)
        XCTAssertEqual(cache.header(path: last, stamp: stamp)?.id, "thread-79")
        cache.prepare(paths: [last])
        XCTAssertEqual(cache.count, 1); XCTAssertLessThan(cache.estimatedBytes, 128 * 1024)
        cache.persist()
        let files = try f.cacheFiles()
        let diskBytes = try files.reduce(0) { total, file in total + (try Data(contentsOf: file).count) }
        XCTAssertLessThanOrEqual(diskBytes, SessionCatalogCache.maximumBytes)
    }

    func testConcurrentCatalogWaitersShareCompleteResultsWithFewerFlights() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let expected = try f.catalogFlightSources()
        let pool = SessionReaderPool(investigationRegistryDirectory: f.registry)
        let first = try await pool.acquire(home: f.home, cacheDirectory: f.cache)
        let second = try await pool.acquire(home: f.home, cacheDirectory: f.cache)
        XCTAssertTrue(first.reader === second.reader)
        let callers = 16, gate = CatalogCacheCallGate(participants: 16)
        let results = try await withThrowingTaskGroup(of: [SessionSummary].self, returning: [[SessionSummary]].self) { group in
            for number in 0..<callers {
                let reader = number.isMultiple(of: 2) ? first.reader : second.reader
                group.addTask { await gate.arrive(); return try await reader.catalog() }
            }
            var output: [[SessionSummary]] = []
            for try await result in group { output.append(result) }
            return output
        }
        XCTAssertEqual(results.count, callers)
        let complete = try XCTUnwrap(results.first)
        for result in results {
            XCTAssertEqual(Set(result.map(\.id)), expected)
            XCTAssertEqual(result, complete)
        }
        let starts = await first.reader.startedCatalogs
        XCTAssertGreaterThan(starts, 0)
        XCTAssertLessThan(starts, callers, "Overlapping subscriptions should not each scan the same catalog")
        await first.release(); await second.release()
        let remaining = await pool.activeReaderCount
        XCTAssertEqual(remaining, 0)
    }

    func testCancelledCatalogWaiterDoesNotPoisonPeerOrFollowingRequest() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        let expected = try f.catalogFlightSources()
        let pool = SessionReaderPool(investigationRegistryDirectory: f.registry)
        let cancelledLease = try await pool.acquire(home: f.home, cacheDirectory: f.cache)
        let peerLease = try await pool.acquire(home: f.home, cacheDirectory: f.cache)
        let gate = CatalogCacheCallGate(participants: 2)
        let cancelled = Task { await gate.arrive(); return try await cancelledLease.reader.catalog() }
        let peer = Task { await gate.arrive(); return try await peerLease.reader.catalog() }
        await waitForCatalogStart(cancelledLease.reader)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled catalog waiter must not receive a later shared success") }
        catch is CancellationError { }
        await cancelledLease.release()
        let peerResult = try await peer.value
        XCTAssertEqual(Set(peerResult.map(\.id)), expected)
        let following = try await peerLease.reader.catalog()
        XCTAssertEqual(Set(following.map(\.id)), expected)
        await peerLease.release()
        let remaining = await pool.activeReaderCount
        XCTAssertEqual(remaining, 0)
    }

    func testQuiesceDrainsCatalogAndRootFlightsWithoutLateCacheWrite() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        _ = try f.catalogFlightSources()
        let pool = SessionReaderPool(investigationRegistryDirectory: f.registry)
        let lease = try await pool.acquire(home: f.home, cacheDirectory: f.cache, rootID: "catalog-thread-0")
        let gate = CatalogCacheCallGate(participants: 2)
        let catalog = Task { await gate.arrive(); return try await lease.reader.catalog() }
        let root = Task { await gate.arrive(); return try await lease.reader.load() }
        await waitForCatalogStart(lease.reader)
        for _ in 0..<10_000 {
            if await lease.reader.startedCollections > 0 { break }
            await Task.yield()
        }
        let rootStarts = await lease.reader.startedCollections
        XCTAssertGreaterThan(rootStarts, 0)
        await pool.quiesce()
        _ = await catalog.result; _ = await root.result
        // An actor read passes any work already queued on the engine; the
        // filesystem snapshot then includes all writes completed by draining.
        _ = await lease.engine.catalogHeaderReads
        let afterDrain = try f.cacheSnapshot()
        let readsAfterDrain = await lease.engine.catalogHeaderReads
        do { _ = try await lease.reader.catalog(); XCTFail("A drained reader cannot begin another catalog") }
        catch is CancellationError { }
        do { _ = try await lease.reader.load(); XCTFail("A drained reader cannot resume its root") }
        catch LensError.unavailable(_) { }
        await lease.release()
        for _ in 0..<100 { await Task.yield() }
        let finalReads = await lease.engine.catalogHeaderReads
        XCTAssertEqual(finalReads, readsAfterDrain)
        XCTAssertEqual(try f.cacheSnapshot(), afterDrain, "No cancelled catalog/index task may write after the drain returned")
        let remaining = await pool.activeReaderCount
        XCTAssertEqual(remaining, 0)
    }

    func testSoleCancelledCatalogFlightIsDrainedByLastReleaseAndQuiesce() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        _ = try f.catalogFlightSources()
        let pool = SessionReaderPool(investigationRegistryDirectory: f.registry)
        let lease = try await pool.acquire(home: f.home, cacheDirectory: f.cache)
        let request = Task { try await lease.reader.catalog() }
        await waitForCatalogStart(lease.reader)
        request.cancel()
        do { _ = try await request.value; XCTFail("The sole waiter must receive cancellation") }
        catch is CancellationError { }
        // The waiter has now left. Its cancelled engine task must still be
        // retained and awaited even though it is no longer the active flight.
        await lease.release()
        await pool.quiesce()
        let diskAtDrainReturn = try f.cacheSnapshot()
        for _ in 0..<100 { await Task.yield() }
        _ = await lease.engine.catalogHeaderReads
        XCTAssertEqual(try f.cacheSnapshot(), diskAtDrainReturn, "A retired catalog flight cannot persist after its last lease is drained")
        do { _ = try await lease.reader.catalog(); XCTFail("Last release must leave the retired reader closed") }
        catch is CancellationError { }
        let remaining = await pool.activeReaderCount
        XCTAssertEqual(remaining, 0)
    }

    func testPoolsWithDistinctInjectedRegistriesDoNotShareExclusionsForSameHome() async throws {
        let f = try CatalogCacheFixture(); defer { f.remove() }
        _ = try f.rollout(id: "public-source")
        let a = try f.rollout(id: "thread-a", nickname: "Alpha")
        _ = try f.rollout(id: "thread-b", nickname: "Bravo")
        let otherRegistry = f.base.appendingPathComponent("other-ownership")
        let registryA = CodexInvestigationRegistry(directory: f.registry)
        let registryB = CodexInvestigationRegistry(directory: otherRegistry)
        let chatA = try await registryA.chat(root: "public-source")
        let chatB = try await registryB.chat(root: "public-source")
        _ = try await registryA.bind(chatID: chatA.chatID, root: "public-source", threadID: "thread-a")
        _ = try await registryB.bind(chatID: chatB.chatID, root: "public-source", threadID: "thread-b")
        let poolA = SessionReaderPool(investigationRegistryDirectory: f.registry)
        let poolB = SessionReaderPool(investigationRegistryDirectory: otherRegistry)
        let leaseA = try await poolA.acquire(home: f.home, cacheDirectory: f.cache)
        let leaseB = try await poolB.acquire(home: f.home, cacheDirectory: f.cache)
        XCTAssertFalse(leaseA.reader === leaseB.reader)
        let one = try await leaseA.reader.catalog(), two = try await leaseB.reader.catalog()
        XCTAssertEqual(Set(one.map(\.id)), ["public-source", "thread-b"])
        XCTAssertEqual(Set(two.map(\.id)), ["public-source", "thread-a"])
        XCTAssertEqual(one.first(where: { $0.id == "thread-b" })?.agentName, "Bravo")
        XCTAssertEqual(two.first(where: { $0.id == "thread-a" })?.agentName, "Alpha")

        let changed = try f.bytes(id: "thread-a", nickname: "Omega")
        try changed.write(to: a)
        let refreshedA = try await leaseA.reader.catalog(), refreshedB = try await leaseB.reader.catalog()
        XCTAssertEqual(Set(refreshedA.map(\.id)), ["public-source", "thread-b"])
        XCTAssertEqual(Set(refreshedB.map(\.id)), ["public-source", "thread-a"])
        XCTAssertEqual(refreshedB.first(where: { $0.id == "thread-a" })?.agentName, "Omega")
        XCTAssertEqual(try Data(contentsOf: a), changed)
        await leaseA.release(); await leaseB.release()
        let remainingA = await poolA.activeReaderCount, remainingB = await poolB.activeReaderCount
        XCTAssertEqual(remainingA, 0); XCTAssertEqual(remainingB, 0)
    }

    private func waitForCatalogStart(_ reader: SessionReader, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if await reader.startedCatalogs > 0 { return }
            await Task.yield()
        }
        XCTFail("Catalog flight did not start", file: file, line: line)
    }

    private func diagnostics(_ engine: SessionEngine) async -> (reads: Int, hits: Int, bytes: Int) {
        (await engine.catalogHeaderReads, await engine.catalogHeaderHits, await engine.catalogHeaderCacheBytes)
    }
}

private struct CatalogCacheFixture {
    static let messageMarker = "INVENTED_MESSAGE_NOT_A_CATALOG_FIELD"
    let base: URL, home: URL, cache: URL, registry: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("LensCatalogCacheTests-" + UUID().uuidString)
        home = base.appendingPathComponent("home"); cache = base.appendingPathComponent("cache"); registry = base.appendingPathComponent("ownership")
        try createSource(home)
    }
    func createSource(_ home: URL) throws {
        for name in ["sessions", "archived_sessions"] { try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true) }
    }
    func engine(home override: URL? = nil) -> SessionEngine { SessionEngine(home: override ?? home, cacheDirectory: cache, investigationRegistryDirectory: registry) }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func bytes(id: String, nickname: String = "", cwd: URL? = nil, parent: String? = nil, instructions: String? = nil) throws -> Data {
        var metadata: [String: Any] = ["id": id, "cwd": (cwd ?? home).path, "cli_version": "0.159.2", "agent_nickname": nickname]
        if let parent { metadata["parent_thread_id"] = parent }
        if let instructions { metadata["instructions"] = instructions }
        var data = try record("session_meta", metadata)
        data.append(try record("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": Self.messageMarker]]]))
        return data
    }
    func rollout(id: String, home override: URL? = nil, cwd: URL? = nil, nickname: String = "", parent: String? = nil, instructions: String? = nil) throws -> URL {
        let path = (override ?? home).appendingPathComponent("sessions/rollout-" + id + ".jsonl")
        try bytes(id: id, nickname: nickname, cwd: cwd ?? override, parent: parent, instructions: instructions).write(to: path)
        return path
    }
    func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-07T00:00:00Z", "type": type, "payload": payload], options: [.sortedKeys]); bytes.append(10); return bytes
    }
    func appendMessage(_ message: String, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: record("event_msg", ["type": "agent_message", "message": message]))
    }
    func titleIndex(_ title: String, id: String) throws {
        var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": title]); bytes.append(10)
        try bytes.write(to: home.appendingPathComponent("session_index.jsonl"))
    }
    func cacheFiles() throws -> [URL] {
        let directory = cache.appendingPathComponent("Catalog-v1")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "plist" }
    }
    func catalogFlightSources() throws -> Set<String> {
        let instructions = String(repeating: "Invented catalog overlap data. ", count: 2200)
        var ids: Set<String> = []
        for number in 0..<128 {
            let id = "catalog-thread-\(number)"; ids.insert(id)
            _ = try rollout(id: id, instructions: instructions)
        }
        return ids
    }
    func cacheSnapshot() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: cache.path),
              let enumerator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var files: [String: Data] = [:]
        for case let file as URL in enumerator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[file.path] = try Data(contentsOf: file)
        }
        return files
    }
    static func fileStat(_ path: URL) throws -> stat {
        var value = stat()
        guard path.path.withCString({ Darwin.lstat($0, &value) }) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }
    static func canonicalPaths(_ paths: [String]) -> [String] {
        paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }.sorted()
    }
    static func restoreTimes(_ old: stat, to path: URL) throws {
        let times = [old.st_atimespec, old.st_mtimespec]
        let result = times.withUnsafeBufferPointer { buffer in path.path.withCString { Darwin.utimensat(AT_FDCWD, $0, buffer.baseAddress, 0) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

/// Release every caller together, so overlap is expressed by scheduling rather
/// than by an elapsed-time assertion or a sleep guessed from machine speed.
private actor CatalogCacheCallGate {
    private let participants: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0
    init(participants: Int) { self.participants = participants }
    func arrive() async {
        await withCheckedContinuation { continuation in
            arrived += 1; waiting.append(continuation)
            if arrived == participants {
                let ready = waiting; waiting = []
                for caller in ready { caller.resume() }
            }
        }
    }
}

private final class CatalogCacheDatabase {
    let url: URL
    private var database: OpaquePointer?
    init(url: URL) throws {
        self.url = url
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw NSError(domain: "CatalogFixtureSQLite", code: 1) }
    }
    deinit { sqlite3_close(database) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "CatalogFixtureSQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]) }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
}
