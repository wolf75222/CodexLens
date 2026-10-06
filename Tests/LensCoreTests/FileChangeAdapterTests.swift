import Foundation
import XCTest
@testable import LensCore

final class FileChangeAdapterTests: XCTestCase {
    func testCamelCaseArrayCompletionRetainsExactSourceAndDeduplicatesPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let changes: [[String: Any]] = [
            ["path": "src/A.swift", "kind": ["type": "update"], "diff": "@@ -1 +1 @@\n-old\n+new\n"],
            ["path": "src/A.swift", "kind": ["type": "update"]],
            ["file_path": "src/B.swift", "kind": ["type": "add"]],
            ["kind": ["type": "update"]], ["path": ""], ["path": "invalid\0name"]
        ]
        try fixture.write([fixture.item("array-item", type: "fileChange", status: "completed", changes: changes)])
        let bytes = try Data(contentsOf: fixture.rollout)
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let snapshot = try await engine.open(id: fixture.root)
        let event = try XCTUnwrap(snapshot.events.first { $0.callID == "array-item" })
        XCTAssertEqual(event.kind, .toolResult)
        XCTAssertEqual(event.toolName, "apply_patch")
        XCTAssertFalse(event.isError)
        XCTAssertTrue(event.title.contains("completed"))
        XCTAssertEqual(Set(snapshot.changes.map(\.path)), Set([fixture.cwd.path + "/src/A.swift", fixture.cwd.path + "/src/B.swift"]))
        XCTAssertEqual(snapshot.changes.count, 2)
        XCTAssertTrue(snapshot.changes.allSatisfy { $0.kind == .recordedResult && $0.environmentID == fixture.cwd.path && $0.eventID == event.id })
        XCTAssertTrue(snapshot.resources.allSatisfy { $0.roles == [.modified] && $0.eventIDs == [event.id] })
        let detail = try await engine.sourceDetail(for: event)
        XCTAssertTrue(detail.raw.contains("fileChange"))
        XCTAssertTrue(detail.raw.contains("-old"))
        XCTAssertEqual(try Data(contentsOf: fixture.rollout), bytes, "Reading a completion preserves source bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cwd.path + "/src/A.swift"), "Inspection never applies a recorded patch")
    }

    func testLegacyDictionaryAndPascalCaseArrayRemainSupported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.item("legacy-item", type: "FileChange", status: "Completed", changes: ["legacy.swift": ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new\n"]]),
            fixture.item("pascal-array", type: "FileChange", status: "completed", changes: [["path": "array.swift", "kind": ["type": "add"]]])
        ])
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let snapshot = try await engine.open(id: fixture.root)
        XCTAssertEqual(snapshot.events.filter { $0.toolName == "apply_patch" }.count, 2)
        XCTAssertEqual(Set(snapshot.changes.map(\.path)), Set([fixture.cwd.path + "/legacy.swift", fixture.cwd.path + "/array.swift"]))
        XCTAssertTrue(snapshot.resources.allSatisfy { $0.roles == [.modified] })
    }

    func testFailedDeclinedInProgressAndUnknownNeverBecomeSuccessFromExitCodeZero() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let statuses = ["failed", "declined", "inProgress", "unexpected", "unknown"]
        let records = statuses.map { status in
            fixture.item("status-" + status, type: "fileChange", status: status == "unknown" ? nil : status,
                         changes: [["path": status + ".swift"]], extras: ["exit_code": 0])
        }
        try fixture.write(records)
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let snapshot = try await engine.open(id: fixture.root)
        for status in statuses {
            let event = try XCTUnwrap(snapshot.events.first { $0.callID == "status-" + status })
            XCTAssertTrue(event.title.contains(status), "The recorded status remains distinct")
            XCTAssertEqual(event.isError, status == "failed" || status == "declined")
            if status == "inProgress" { XCTAssertNil(event.endTime, "An in-progress status does not claim a completion time") }
            let change = try XCTUnwrap(snapshot.changes.first { $0.eventID == event.id })
            XCTAssertTrue(change.evidence.contains("statut " + status))
            XCTAssertFalse(change.evidence.contains("succès déclaré"))
            let resource = try XCTUnwrap(snapshot.resources.first { $0.eventIDs.contains(event.id) })
            XCTAssertEqual(resource.roles, [.referenced])
        }
    }

    func testSameRelativePathInTwoRecordedDirectoriesRemainsTwoFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let beta = fixture.base.appendingPathComponent("beta")
        try fixture.write([
            fixture.item("alpha-item", type: "fileChange", status: "completed", changes: [["path": "src/Same.swift"]]),
            fixture.item("beta-item", type: "fileChange", status: "completed", changes: [["path": "src/Same.swift"]], extras: ["cwd": beta.path])
        ])
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let snapshot = try await engine.open(id: fixture.root)
        XCTAssertEqual(Set(snapshot.changes.map(\.environmentID)), Set([fixture.cwd.path, beta.path]))
        XCTAssertEqual(Set(snapshot.resources.map(\.location)), Set([fixture.cwd.path + "/src/Same.swift", beta.path + "/src/Same.swift"]))
        XCTAssertEqual(snapshot.resources.count, 2)
    }

    func testContradictoryCopiesOfOneItemDoNotCertifySuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.item("copied-item", type: "fileChange", status: "completed", changes: [["path": "same.swift"]]),
            fixture.item("copied-item", type: "fileChange", status: "failed", changes: [["path": "same.swift"]])
        ])
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let snapshot = try await engine.open(id: fixture.root)
        let events = snapshot.events.filter { $0.callID == "copied-item" }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(try XCTUnwrap(events.first).isError)
        XCTAssertEqual(events.first?.supplementarySources.count, 1)
        XCTAssertEqual(snapshot.changes.count, 1)
        let change = try XCTUnwrap(snapshot.changes.first)
        XCTAssertTrue(change.evidence.contains("completed / failed"))
        XCTAssertFalse(change.evidence.contains("succès déclaré"))
        XCTAssertFalse(snapshot.resources.contains { $0.roles.contains(.modified) })
    }

    func testVersionThreeCacheIsDiscardedAndUnchangedSourceReparsed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.item("cached-item", type: "fileChange", status: "completed", changes: [["path": "cached.swift"]])])
        let first = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let initial = try await first.open(id: fixture.root)
        XCTAssertEqual(initial.changes.count, 1)
        let cacheURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        XCTAssertEqual(cache["version"] as? Int, 8)
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        for key in Array(files.keys) {
            var index = try XCTUnwrap(files[key])
            index["records"] = [] // Simulate old parsing while keeping EOF offset/inode/boundary intact.
            files[key] = index
        }
        cache["version"] = 3; cache["files"] = files
        try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]).write(to: cacheURL)
        let second = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let restored = try await second.open(id: fixture.root)
        XCTAssertEqual(restored.changes.count, 1, "Stale classifications cannot be restored solely because source bytes are unchanged")
        XCTAssertEqual(restored.changes.first?.id, initial.changes.first?.id)
        let replaced = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        XCTAssertEqual(replaced["version"] as? Int, 8)
    }

    private struct Fixture {
        let base: URL
        let home: URL
        let cache: URL
        let cwd: URL
        let rollout: URL
        let root = UUID().uuidString
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("LensFileChangeAdapter-" + UUID().uuidString)
            home = base.appendingPathComponent("home"); cache = base.appendingPathComponent("cache")
            cwd = base.appendingPathComponent("alpha")
            let sessions = home.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            rollout = sessions.appendingPathComponent("rollout-" + root + ".jsonl")
        }
        func item(_ id: String, type: String, status: String?, changes: Any, extras: [String: Any] = [:]) -> [String: Any] {
            var item: [String: Any] = ["type": type, "id": id, "changes": changes, "cwd": cwd.path]
            if let status { item["status"] = status }
            for (key, value) in extras { item[key] = value }
            return ["timestamp": "2026-10-02T00:00:01Z", "type": "event_msg", "payload": ["type": "item_completed", "turn_id": "fixture-turn", "item": item]]
        }
        func write(_ records: [[String: Any]]) throws {
            let meta: [String: Any] = ["timestamp": "2026-10-02T00:00:00Z", "type": "session_meta", "payload": ["id": root, "cwd": cwd.path, "cli_version": "0.159.2"]]
            var data = Data()
            for record in [meta] + records { data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10) }
            try data.write(to: rollout)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
