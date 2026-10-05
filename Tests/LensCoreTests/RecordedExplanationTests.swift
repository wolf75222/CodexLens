import Foundation
import XCTest
@testable import LensCore

final class RecordedExplanationTests: XCTestCase {
    private func event(time: Date = Date(timeIntervalSince1970: 100), thread: String = "producer", turn: String? = "turn") -> LensEvent {
        LensEvent(id: "event", timestamp: time, agentID: thread, turnID: turn, kind: .context,
                  source: SourceRef(path: "/anonymous/producer.jsonl", offset: 10, length: 20, line: 2))
    }
    private func response(_ payload: [String: Any]) -> [String: Any] { ["type": "response_item", "payload": payload] }
    private func completed(_ item: [String: Any]) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "item_completed", "item": item, "turn_id": "native-turn"]]
    }

    func testOpaqueReasoningNeverLeaksOrInventsReadableSummary() throws {
        let facts = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "reasoning", "id": "rs-private", "summary": [], "encrypted_content": "OPAQUE-DO-NOT-COPY"
        ]), event: event()))
        XCTAssertEqual(facts.kind, .reasoningSummary)
        XCTAssertEqual(facts.availability, .opaque)
        XCTAssertEqual(facts.summaryAvailability, .empty)
        XCTAssertEqual(facts.exposedReasoningAvailability, .unavailable)
        XCTAssertTrue(facts.encryptedContentPresent)
        XCTAssertTrue(facts.preview.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        XCTAssertFalse(encoded.contains("OPAQUE-DO-NOT-COPY"))
        XCTAssertFalse(encoded.contains("encrypted_content"))
        XCTAssertTrue(facts.limits.contains { $0.contains("not an exhaustive transcript") })
    }

    func testAbsentAndExplicitlyEmptySummaryAreDifferent() throws {
        let absent = try XCTUnwrap(RecordedExplanationFacts.decode(response(["type": "reasoning"]), event: event()))
        let empty = try XCTUnwrap(RecordedExplanationFacts.decode(response(["type": "reasoning", "summary": []]), event: event()))
        XCTAssertEqual(absent.availability, .unavailable)
        XCTAssertEqual(absent.summaryAvailability, .unavailable)
        XCTAssertEqual(empty.availability, .empty)
        XCTAssertEqual(empty.summaryAvailability, .empty)
        XCTAssertTrue(absent.preview.isEmpty)
        XCTAssertTrue(empty.preview.isEmpty)
    }

    func testSummaryAndExposedTextKeepTheirSeparateTypes() throws {
        let facts = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "reasoning", "summary": [["type": "summary_text", "text": "Original exposed summary"]],
            "content": [["type": "reasoning_text", "text": "Provider-exposed separate text"]],
            "encrypted_content": "PRIVATE-OPAQUE"
        ]), event: event()))
        XCTAssertEqual(facts.kind, .reasoningSummary)
        XCTAssertEqual(facts.preview, "Original exposed summary")
        XCTAssertEqual(facts.exposedReasoningPreview, "Provider-exposed separate text")
        XCTAssertEqual(facts.exposedReasoningAvailability, .available)
        XCTAssertEqual(facts.availability, .available)
        XCTAssertTrue(facts.encryptedContentPresent)
        let rawOnly = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "reasoning", "summary": [], "content": [["type": "text", "text": "Exposed original"]]
        ]), event: event()))
        XCTAssertEqual(rawOnly.kind, .exposedReasoning)
        XCTAssertEqual(rawOnly.preview, "Exposed original")
        XCTAssertEqual(rawOnly.summaryAvailability, .empty)
    }

    func testUnverifiedContentTypesAndProseCannotCreateExplanationLinks() throws {
        let facts = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "reasoning", "id": "rs1", "summary": [
                ["type": "summary_text", "text": "This explains patch-call-42 in /other-worktree/file.swift"],
                ["type": "encrypted_content", "text": "FALSE-READABLE-TEXT"],
                ["type": "new_unsupported_summary", "text": "UNVERIFIED"]
            ], "related_call_id": "patch-call-42", "explains_item_id": "patch-call-42", "reason": "fabricated relation"
        ]), event: event()))
        XCTAssertTrue(facts.explicitRelatedItemIDs.isEmpty)
        XCTAssertNil(facts.declaredForCallID)
        XCTAssertFalse(facts.preview.contains("FALSE-READABLE-TEXT"))
        XCTAssertFalse(facts.preview.contains("UNVERIFIED"))
        XCTAssertEqual(facts.threadID, "producer")
    }

    func testNativeAndDurableReasoningFieldNamesAreBothVerified() throws {
        let durable = try XCTUnwrap(RecordedExplanationFacts.decode(completed([
            "type": "Reasoning", "id": "rs-durable", "summary_text": ["Persisted TurnItem summary"], "raw_content": ["Persisted exposed text"]
        ]), event: event()))
        let notification = try XCTUnwrap(RecordedExplanationFacts.decode([
            "method": "item/completed", "params": ["threadId": "child", "turnId": "child-turn", "item": [
                "type": "reasoning", "id": "rs-native", "summary": ["Projected summary"], "content": ["Projected exposed text"]
            ]]
        ], event: event(thread: "parent")))
        XCTAssertEqual(durable.preview, "Persisted TurnItem summary")
        XCTAssertEqual(durable.exposedReasoningPreview, "Persisted exposed text")
        XCTAssertEqual(durable.turnID, "native-turn")
        XCTAssertEqual(notification.preview, "Projected summary")
        XCTAssertEqual(notification.threadID, "child")
        XCTAssertEqual(notification.turnID, "child-turn")
        XCTAssertEqual(notification.itemID, "rs-native")
    }

    func testLateNotificationAndRecordTimesNeverBecomeGenerationTimes() throws {
        let native = try XCTUnwrap(RecordedExplanationFacts.decode([
            "method": "item/completed", "generated_at": "earlier-unsupported", "params": ["completed_at_ms": 0,
                "item": ["type": "plan", "id": "plan1", "text": "A declaration received later"]]
        ], event: event()))
        XCTAssertEqual(native.timestampBasis, .notificationReceivedGenerationUnknown)
        XCTAssertEqual(native.phase, "completed")
        XCTAssertTrue(native.limits.contains { $0.contains("generation and decision times are unknown") })
        let unknown = try XCTUnwrap(RecordedExplanationFacts.decode(completed([
            "type": "Plan", "id": "plan2", "text": "Missing record time"
        ]), event: event(time: .distantPast)))
        XCTAssertEqual(unknown.timestampBasis, .unavailable)
        let persisted = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Statement"]]
        ]), event: event()))
        XCTAssertEqual(persisted.timestampBasis, .sourceRecordGenerationUnknown)
    }

    func testLegacyReasoningAndDurableAgentMessageMaintainOriginalText() throws {
        let raw = try XCTUnwrap(RecordedExplanationFacts.decode([
            "type": "event_msg", "payload": ["type": "agent_reasoning_raw_content", "text": "Exposed legacy text"]
        ], event: event()))
        XCTAssertEqual(raw.kind, .exposedReasoning)
        XCTAssertEqual(raw.preview, "Exposed legacy text")
        let message = try XCTUnwrap(RecordedExplanationFacts.decode(completed([
            "type": "AgentMessage", "id": "am1", "content": [["type": "Text", "text": "Durable original message"]]
        ]), event: event()))
        XCTAssertEqual(message.kind, .agentMessage)
        XCTAssertEqual(message.preview, "Durable original message")
        let projected = try XCTUnwrap(RecordedExplanationFacts.decode([
            "method": "item/started", "params": ["item": ["type": "agentMessage", "id": "am2", "text": ""]]
        ], event: event()))
        XCTAssertEqual(projected.availability, .empty)
        XCTAssertEqual(projected.phase, "started")
    }

    func testMixedInterAgentMessageNeverTreatsEncryptedPartAsExplanation() throws {
        let facts = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "agent_message", "id": "amsg1", "author": "sender", "recipient": "recipient", "content": [
                ["type": "input_text", "text": "Recorded clarification"],
                ["type": "encrypted_content", "encrypted_content": "SECRET-OPAQUE", "text": "FALSE-TEXT"]
            ]
        ]), event: event(thread: "actual-journal-owner")))
        XCTAssertEqual(facts.threadID, "actual-journal-owner", "Sender/recipient labels cannot reassign the producing journal")
        XCTAssertEqual(facts.preview, "Recorded clarification")
        XCTAssertTrue(facts.encryptedContentPresent)
        XCTAssertFalse(facts.preview.contains("FALSE-TEXT"))
    }

    func testPlanDeclaredMotiveIsScopedToItsExactToolCallOnly() throws {
        let args: [String: Any] = ["explanation": "Reorder the plan; patch-other is mentioned, not linked.",
                                  "plan": [["step": "Read historical evidence", "status": "in_progress"]]]
        let bytes = try JSONSerialization.data(withJSONObject: args)
        let facts = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "function_call", "call_id": "plan-call", "name": "functions.update_plan", "arguments": String(decoding: bytes, as: UTF8.self)
        ]), event: event()))
        XCTAssertEqual(facts.kind, .plan)
        XCTAssertEqual(facts.phase, "requested")
        XCTAssertEqual(facts.declaredForCallID, "plan-call")
        XCTAssertTrue(facts.explicitRelatedItemIDs.isEmpty)
        XCTAssertTrue(facts.preview.contains("Reorder the plan"))
        XCTAssertTrue(facts.preview.contains("Read historical evidence"))
        XCTAssertNil(RecordedExplanationFacts.decode(response([
            "type": "function_call", "call_id": "patch-other", "name": "apply_patch", "arguments": String(decoding: bytes, as: UTF8.self)
        ]), event: event()))
        let native = try XCTUnwrap(RecordedExplanationFacts.decode([
            "method": "thread/plan/updated", "params": args.merging(["threadId": "root", "turnId": "turn-plan"]) { _, new in new }
        ], event: event()))
        XCTAssertEqual(native.turnID, "turn-plan")
        XCTAssertNil(native.declaredForCallID)
    }

    func testIndexedPreviewHasExplicitBudgetAndSecretMasking() throws {
        let facts = try XCTUnwrap(RecordedExplanationFacts.decode(response([
            "type": "reasoning", "summary": [["type": "summary_text", "text": "Bearer abcdefghijklmnopqrstuvwxyz " + String(repeating: "x", count: 5_000)]]
        ]), event: event()))
        XCTAssertTrue(facts.previewTruncated)
        XCTAssertLessThanOrEqual(facts.preview.count, 1200)
        XCTAssertFalse(facts.preview.contains("abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(facts.preview.contains("[secret masked]"))
        XCTAssertTrue(facts.limits.contains { $0.contains("bounded preview") })
        let restored = try JSONDecoder().decode(RecordedTraceFacts.self, from: JSONEncoder().encode(RecordedTraceFacts(explanation: facts)))
        XCTAssertEqual(restored.explanation, facts)
    }

    func testIncrementalCompletionReplacesEmptyStartedExplanationWithExactContentSource() async throws {
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        try fixture.write(records: [fixture.context, fixture.notification("item/started", text: "")])
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let started = try await engine.open(id: fixture.rootID)
        let first = try XCTUnwrap(started.events.first { $0.trace?.explanation?.itemID == "rs-native" })
        XCTAssertEqual(first.trace?.explanation?.availability, .empty)
        let originalBytes = try Data(contentsOf: fixture.rollout)
        try fixture.append(fixture.notification("item/completed", text: "The completed original summary"))
        let refreshed = try await engine.refresh()
        let updated = try XCTUnwrap(refreshed)
        let second = try XCTUnwrap(updated.events.first { $0.trace?.explanation?.itemID == "rs-native" })
        XCTAssertEqual(updated.events.filter { $0.trace?.explanation?.itemID == "rs-native" }.count, 1)
        XCTAssertEqual(second.id, first.id, "Streaming publication preserves stable selection identity")
        XCTAssertEqual(second.trace?.explanation?.phase, "completed")
        XCTAssertEqual(second.trace?.explanation?.availability, .available)
        XCTAssertEqual(second.preview, "The completed original summary")
        XCTAssertGreaterThan(second.source.offset, first.source.offset)
        XCTAssertTrue(second.supplementarySources.contains(first.source))
        XCTAssertEqual(second.agentID, fixture.rootID)
        XCTAssertEqual(second.turnID, "turn-native")
        XCTAssertEqual(try Data(contentsOf: fixture.rollout).prefix(originalBytes.count), originalBytes)
        let reopened = try await SessionEngine(home: fixture.home, cacheDirectory: fixture.cache).open(id: fixture.rootID)
        XCTAssertEqual(reopened.events.first { $0.id == first.id }?.trace?.explanation, second.trace?.explanation)
    }

    func testUnavailableReasoningAdapterNeverDisplaysSummaryAvailablePlaceholder() async throws {
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        try fixture.write(records: [fixture.context, ["timestamp": "2026-10-03T12:00:00Z", "type": "response_item", "payload": ["type": "reasoning", "id": "missing"]]])
        let snapshot = try await SessionEngine(home: fixture.home, cacheDirectory: fixture.cache).open(id: fixture.rootID)
        let missing = try XCTUnwrap(snapshot.events.first { $0.trace?.explanation?.itemID == "missing" })
        XCTAssertEqual(missing.trace?.explanation?.availability, .unavailable)
        XCTAssertFalse(missing.preview.contains("Résumé disponible"))
        XCTAssertFalse(missing.preview.contains("summary available"))
    }
}

private struct ExplanationFixture {
    let rootID = "11111111-1111-4111-8111-111111111111"
    let base: URL
    let home: URL
    let cache: URL
    let rollout: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("CodexLensExplanation-" + UUID().uuidString)
        home = base.appendingPathComponent("codex-home")
        cache = base.appendingPathComponent("lens-cache")
        rollout = home.appendingPathComponent("sessions/2026/10/03/rollout-2026-10-03T12-00-00-11111111-1111-4111-8111-111111111111.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    var context: [String: Any] { ["timestamp": "2026-10-03T12:00:00Z", "type": "turn_context", "payload": ["turn_id": "turn-native", "cwd": base.path]] }
    func notification(_ method: String, text: String) -> [String: Any] {
        ["timestamp": method == "item/started" ? "2026-10-03T12:00:01Z" : "2026-10-03T12:00:03Z", "method": method,
         "params": ["threadId": rootID, "turnId": "turn-native", "item": ["type": "reasoning", "id": "rs-native", "summary": text.isEmpty ? [] : [text], "content": []]]]
    }
    func write(records: [[String: Any]]) throws {
        let meta: [String: Any] = ["type": "session_meta", "timestamp": "2026-10-03T12:00:00Z", "payload": ["id": rootID, "cwd": base.path, "cli_version": "0.159.2", "source": "cli"]]
        var bytes = Data()
        for record in [meta] + records { bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); bytes.append(10) }
        try bytes.write(to: rollout)
    }
    func append(_ record: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: rollout); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); try handle.write(contentsOf: Data([10]))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
