import Foundation
import XCTest
@testable import LensCore

final class EscapedPathAcceptanceTests: XCTestCase {
    func testEscapedPatchCodeNeverBecomesAConcatenatedResourcePath() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LensEscaped-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("codex-home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("AcceptanceTests.swift")
        try Data("import Foundation\n".utf8).write(to: file)
        let missing = base.appendingPathComponent("provided document with spaces.pdf")
        let patch = "*** Begin Patch\n*** Update File: \(file.path)\n@@\n+import Foundation\n+// Acceptance scenarios are temporary\n*** End Patch"
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: patch, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        let id = "99999999-9999-4999-8999-999999999999"
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": base.path, "cli_version": "0.159.2"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Files supplied by the user:\n\(missing.path)"]]]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "functions.exec", "call_id": "escaped-patch", "input": "text(await tools.apply_patch(\(quoted)));" ]]
        ]
        var bytes = Data()
        for var record in records {
            record["timestamp"] = "2026-10-01T12:00:00.000Z"
            bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10)
        }
        try bytes.write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
        let engine = SessionEngine(home: home, cacheDirectory: base.appendingPathComponent("cache"))
        let snapshot = try await engine.open(id: id)
        XCTAssertTrue(snapshot.resources.contains { $0.location == file.path })
        XCTAssertFalse(snapshot.resources.contains { $0.location.contains("\\n") || $0.location.contains("+import") })
        let supplied = try XCTUnwrap(snapshot.resources.first { $0.location == missing.path })
        XCTAssertTrue(supplied.roles.contains(.supplied))
        XCTAssertEqual(supplied.availability, .missing)
        let pending = try XCTUnwrap(snapshot.events.first { $0.callID == "escaped-patch" })
        XCTAssertFalse(pending.isError)
        XCTAssertNil(pending.relatedEventID)
        XCTAssertTrue(snapshot.coverage.contains { $0.category == "résultat non observé" && $0.message.contains("escaped-patch") })
    }
}
