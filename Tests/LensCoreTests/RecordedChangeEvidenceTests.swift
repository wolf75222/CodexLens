import XCTest
@testable import LensCore

final class RecordedChangeEvidenceTests: XCTestCase {
    private let environment = "/fixture/worktrees/alpha"
    private let patch = "*** Begin Patch\n*** Update File: Sources/A.swift\n@@\n-old\n+new\n*** End Patch"
    private func event(_ id: String, kind: EventKind, related: String? = nil, error: Bool = false) -> LensEvent {
        LensEvent(id: id, agentID: "fixture-agent", kind: kind, callID: "fixture-call", environmentID: environment, relatedEventID: related, source: SourceRef(path: "/fixture/session.jsonl", line: id == "call" ? 1 : 2), isError: error)
    }
    private func change(_ kind: ChangeKind, eventID: String) -> ChangeRecord {
        ChangeRecord(id: "fixture-change", path: environment + "/Sources/A.swift", environmentID: environment, agentID: "fixture-agent", eventID: eventID, kind: kind)
    }
    func testFrozenDiffIncludesRecordedLinesEnvironmentAndExactSource() throws {
        let change = change(.requestedPatch, eventID: "call")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("call", kind: .toolCall))
        let cut = Date(timeIntervalSince1970: 1_700_000_000)
        let piece = try XCTUnwrap(RecordedChangeEvidence.frozenPieces(change: change, selection: selected, detail: EventDetail(arguments: patch), capturedAt: cut).first)
        XCTAssertEqual(piece.kind, "recordedDiffDocument")
        XCTAssertEqual(piece.environmentID, environment)
        XCTAssertEqual(piece.eventID, "call")
        XCTAssertEqual(piece.sourceRefs, [selected.source.source])
        XCTAssertEqual(piece.capturedAt, cut)
        XCTAssertTrue(piece.text.contains("old") && piece.text.contains("new"))
        XCTAssertTrue(piece.text.contains("requestedPatch"))
        XCTAssertThrowsError(try RecordedChangeEvidence.frozenPieces(change: change, selection: selected, detail: EventDetail(arguments: patch), capturedAt: cut, maximumBytes: 1))
    }
    func testFrozenResultDoesNotSubstituteTheRequestedPatch() throws {
        let change = change(.recordedResult, eventID: "result")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("result", kind: .toolResult, related: "call"), related: event("call", kind: .toolCall))
        XCTAssertTrue(try RecordedChangeEvidence.frozenPieces(change: change, selection: selected, detail: EventDetail(arguments: patch, output: "Success"), capturedAt: Date()).isEmpty)
    }
    func testSuccessfulResultWithoutDiffDoesNotPromoteCallPatch() throws {
        let change = change(.recordedResult, eventID: "result")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("result", kind: .toolResult, related: "call"), related: event("call", kind: .toolCall, related: "result"))
        XCTAssertEqual(selected.source.id, "result")
        XCTAssertEqual(selected.call?.id, "call")
        XCTAssertEqual(selected.result?.id, "result")
        let documents = try RecordedChangeEvidence.documents(change: change, selection: selected, detail: EventDetail(arguments: patch, output: "Success. Updated Sources/A.swift", raw: #"{"type":"response_item","payload":{"type":"function_call_output","output":"Success"}}"#))
        XCTAssertTrue(documents.isEmpty)
    }
    func testRequestedPatchKeepsCallSourceAndSeparateResultContext() throws {
        let change = change(.requestedPatch, eventID: "call")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("call", kind: .toolCall, related: "result"), related: event("result", kind: .toolResult, related: "call"))
        let document = try XCTUnwrap(RecordedChangeEvidence.documents(change: change, selection: selected, detail: EventDetail(arguments: patch)).first)
        XCTAssertEqual(document.kind, .requestedPatch)
        XCTAssertEqual(document.provenance.eventIDs, ["call"])
        XCTAssertEqual(document.provenance.sources.first?.line, 1)
        XCTAssertEqual(selected.result?.id, "result")
        XCTAssertNotNil(document.provenance.authorEvidence)
    }
    func testRecordedDiffRetainsExactResultSourceWithoutAuthorship() throws {
        let change = change(.recordedResult, eventID: "result")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("result", kind: .toolResult))
        let document = try XCTUnwrap(RecordedChangeEvidence.documents(change: change, selection: selected, detail: EventDetail(output: "--- a/Sources/A.swift\n+++ b/Sources/A.swift\n@@ -1 +1 @@\n-old\n+new\n")).first)
        XCTAssertEqual(document.kind, .recordedDiff)
        XCTAssertEqual(document.provenance.eventIDs, ["result"])
        XCTAssertEqual(document.provenance.sources.first?.line, 2)
        XCTAssertNil(document.provenance.authorEvidence)
        XCTAssertEqual(document.provenance.environmentID, environment)
    }
    func testFailedResultRetainsFailureWithoutInventingFileBytes() throws {
        let change = change(.recordedResult, eventID: "result")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("result", kind: .toolResult, related: "call", error: true), related: event("call", kind: .toolCall))
        XCTAssertTrue(selected.result?.isError == true)
        XCTAssertTrue(try RecordedChangeEvidence.documents(change: change, selection: selected, detail: EventDetail(output: "Patch failed", raw: "Patch failed")).isEmpty)
    }
    func testNativeCompletedFileChangeCanBeReadFromExactRawResult() throws {
        let change = change(.recordedResult, eventID: "completed")
        let selected = try RecordedChangeEvidence.select(change: change, event: event("completed", kind: .toolResult))
        let raw = #"{"type":"item_completed","item":{"type":"FileChange","changes":[{"path":"Sources/A.swift","diff":"@@ -1 +1 @@\n-old\n+new\n"}]}}"#
        let document = try XCTUnwrap(RecordedChangeEvidence.documents(change: change, selection: selected, detail: EventDetail(raw: raw)).first)
        XCTAssertEqual(document.kind, .recordedDiff)
        XCTAssertEqual(document.provenance.eventIDs, ["completed"])
    }
    func testDifferentSourceIsRejectedAndSameRepositoryDoesNotLinkPeer() throws {
        let change = change(.recordedResult, eventID: "result")
        XCTAssertThrowsError(try RecordedChangeEvidence.select(change: change, event: event("call", kind: .toolCall)))
        let selected = try RecordedChangeEvidence.select(change: change, event: event("result", kind: .toolResult, related: "call"), related: event("unrelated", kind: .toolCall))
        XCTAssertNil(selected.call)
        XCTAssertTrue(selected.missingLinkedContext)
    }
    func testEngineExactResultSourcesDoNotIncludeRelatedCallPatch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LensChangeSource-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let root = UUID().uuidString
        let records: [[String: Any]] = [
            ["timestamp": "2026-10-02T00:00:00Z", "type": "session_meta", "payload": ["id": root, "cwd": base.path, "cli_version": "0.159.2"]],
            ["timestamp": "2026-10-02T00:00:01Z", "type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "fixture-call", "input": patch]],
            ["timestamp": "2026-10-02T00:00:02Z", "type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "fixture-call", "output": "Success. Updated the following files:\nM Sources/A.swift"]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: sessions.appendingPathComponent("rollout-" + root + ".jsonl"))
        let engine = SessionEngine(home: home, cacheDirectory: base.appendingPathComponent("cache"))
        let snapshot = try await engine.open(id: root)
        let result = try XCTUnwrap(snapshot.events.first { $0.kind == .toolResult })
        let call = try XCTUnwrap(snapshot.events.first { $0.kind == .toolCall })
        let combined = try await engine.detail(for: result)
        XCTAssertTrue(combined.raw.contains("*** Begin Patch"), "The general inspector intentionally includes linked context")
        let exact = try await engine.sourceDetail(for: result)
        XCTAssertFalse(exact.raw.contains("*** Begin Patch"))
        XCTAssertTrue(exact.raw.contains("Success"))
        let recorded = ChangeRecord(id: "fixture-change", path: base.path + "/Sources/A.swift", environmentID: result.environmentID ?? base.path, agentID: result.agentID, eventID: result.id, kind: .recordedResult)
        let selected = try RecordedChangeEvidence.select(change: recorded, event: result, related: call)
        XCTAssertEqual(selected.call?.id, call.id)
        XCTAssertTrue(try RecordedChangeEvidence.documents(change: recorded, selection: selected, detail: exact).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path + "/Sources/A.swift"), "Inspecting the patch never executes it")
    }
    func testCoalescedCallAndCompletedItemKeepRequestedAndRecordedDocumentsDistinct() throws {
        let call = event("shared", kind: .toolCall), requested = change(.requestedPatch, eventID: "shared"), recorded = change(.recordedResult, eventID: "shared")
        let nativeDiff = "@@ -1 +1 @@\n-old\n+actually-recorded\n"
        let records: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "custom_tool_call", "call_id": "shared", "input": patch]],
            ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "FileChange", "id": "shared", "changes": [["path": "Sources/A.swift", "diff": nativeDiff]]]]]
        ]
        let raw = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n\n")
        let detail = EventDetail(arguments: patch, raw: raw)
        let resultDocuments = try RecordedChangeEvidence.documents(change: recorded, selection: RecordedChangeEvidence.select(change: recorded, event: call), detail: detail)
        XCTAssertEqual(resultDocuments.count, 1)
        XCTAssertEqual(resultDocuments.first?.kind, .recordedDiff)
        XCTAssertTrue(resultDocuments.first?.files.first?.hunks.first?.lines.contains { $0.text == "actually-recorded" } == true)
        let requestDocuments = try RecordedChangeEvidence.documents(change: requested, selection: RecordedChangeEvidence.select(change: requested, event: call), detail: detail)
        XCTAssertEqual(requestDocuments.count, 1)
        XCTAssertEqual(requestDocuments.first?.kind, .requestedPatch)
        XCTAssertFalse(requestDocuments.first?.files.first?.hunks.first?.lines.contains { $0.text == "actually-recorded" } == true)
    }

}
