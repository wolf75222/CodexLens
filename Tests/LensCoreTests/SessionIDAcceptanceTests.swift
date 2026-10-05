import Foundation
import XCTest
@testable import LensCore

final class SessionIDAcceptanceTests: XCTestCase {
    func testSessionIDResolvesUniqueRootWithoutInventingParentage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LensSessionID-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let tree = UUID().uuidString, root = UUID().uuidString, child = UUID().uuidString
        func write(_ id: String, parent: String? = nil) throws {
            var payload: [String: Any] = ["id": id, "session_id": tree, "cwd": base.path, "cli_version": "0.159.2"]
            if let parent { payload["parent_thread_id"] = parent }
            var data = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-02T00:00:00Z", "type": "session_meta", "payload": payload])
            data.append(10)
            try data.write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
        }
        try write(root); try write(child, parent: root)
        let engine = SessionEngine(home: home, cacheDirectory: base.appendingPathComponent("cache"))
        let snapshot = try await engine.open(id: "  " + tree + "\n")
        XCTAssertEqual(snapshot.root.id, root)
        XCTAssertEqual(snapshot.root.sessionID, tree)
        XCTAssertEqual(Set(snapshot.agents.map(\.id)), Set([root, child]))
        let unrelated = UUID().uuidString
        try write(unrelated)
        do { _ = try await engine.open(id: tree); XCTFail("Ambiguous session ID must not choose a root") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ambigu")) }
        let explicit = try await engine.open(id: root)
        XCTAssertEqual(Set(explicit.agents.map(\.id)), Set([root, child]))
        let linked = try await engine.open(id: "codex://threads/" + root)
        XCTAssertEqual(linked.root.id, root)
    }
}
