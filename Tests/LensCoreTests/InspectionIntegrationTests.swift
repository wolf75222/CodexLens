import Foundation
import XCTest
@testable import LensCore

final class InspectionIntegrationTests: XCTestCase {
    func testRealJSONLAdapterLinksOneCompactionToSourcesWithoutExposingOpaqueContent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write(fixture.root, records: fixture.compactionRecords)
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.cache)
        let snapshot = try await engine.open(id: fixture.root)
        let builder = SessionPresentationBuilder()
        let projection = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(kind: .compaction))
        XCTAssertEqual(projection.contextInspection.identifiedOperationCount, 1)
        XCTAssertEqual(projection.filteredEvents.count, 1, "Lifecycle and checkpoint are one timeline operation")
        let compaction = try XCTUnwrap(projection.contextInspection.compactions.first)
        XCTAssertEqual(compaction.eventIDs.count, 3)
        XCTAssertEqual(compaction.sourceRefs.count, 3)
        XCTAssertEqual(compaction.visibility, .mixed)
        XCTAssertNil(compaction.duration, "Only record times exist, not two explicit operation bounds")
        let event = try XCTUnwrap(projection.eventsByID[compaction.eventID])
        let pieces = try InspectionEvidence.pieces(event: event, presentation: projection, collectionCut: snapshot.collectedAt)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertFalse(pieces[0].text.contains("OPAQUE-PRIVATE-BYTES"))
        XCTAssertTrue(pieces[0].sourceRefs.allSatisfy { $0.sha256 != nil })
        let capsule = try EvidenceCapsule.build(rootThreadID: fixture.root, collectionCut: snapshot.collectedAt, pieces: pieces)
        let address = try EvidenceAddress(rootID: fixture.root, capsuleID: capsule.id, pieceID: capsule.pieces[0].id)
        XCTAssertEqual(try address.resolve(in: capsule).text, pieces[0].text)
        let page = try await RecordedPager().begin(event: event, part: "content")
        XCTAssertTrue(page.text.contains("retained instruction"))
        XCTAssertFalse(page.text.contains("OPAQUE-PRIVATE-BYTES"))
    }

    func testCopiedChildPrefixRemainsInspectableContextWithoutBecomingChildActivity() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write(fixture.root, records: [fixture.message("origin", text: "parent instruction")])
        try fixture.write(fixture.child, parent: fixture.root, historyStart: 2, records: [
            fixture.message("copy", text: "parent instruction"), fixture.message("own", text: "child instruction")])
        let snapshot = try await SessionEngine(home: fixture.home, cacheDirectory: fixture.cache).open(id: fixture.root)
        let projection = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        let inherited = try XCTUnwrap(projection.communicationInspection.instructions.first { $0.kind == .inherited })
        XCTAssertEqual(inherited.agentID, fixture.child)
        XCTAssertEqual(inherited.inheritedFromThreadID, fixture.root)
        XCTAssertFalse(projection.filteredEvents.contains { $0.id == inherited.eventID })
        let event = try XCTUnwrap(projection.eventsByID[inherited.eventID])
        let content = try await RecordedPager().begin(event: event, part: "content")
        XCTAssertTrue(content.text.contains("parent instruction"))
        XCTAssertTrue(snapshot.events.contains { $0.agentID == fixture.child && $0.preview == "child instruction" })
    }

    func testIndexedGraphAndFrozenEvidenceNeedNoSourceReRead() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write(fixture.root, records: fixture.compactionRecords)
        let snapshot = try await SessionEngine(home: fixture.home, cacheDirectory: fixture.cache).open(id: fixture.root)
        try FileManager.default.removeItem(at: fixture.home)
        let builder = SessionPresentationBuilder()
        let first = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        let changedFilter = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(kind: .compaction))
        XCTAssertEqual(first.contextInspection.compactions, changedFilter.contextInspection.compactions)
        let event = try XCTUnwrap(changedFilter.filteredEvents.first)
        let pieces = try InspectionEvidence.pieces(event: event, presentation: changedFilter, collectionCut: snapshot.collectedAt)
        XCTAssertFalse(pieces.isEmpty)
        do { _ = try await RecordedPager().begin(event: event, part: "raw"); XCTFail("Raw source is unavailable, never replaced by current data") }
        catch {
            guard case LensError.unavailable(let reason) = error else { return XCTFail("Expected an unavailable-source error, got \(error)") }
            XCTAssertTrue(reason.contains(event.source.path))
        }
    }

    func testVersionFourCacheCannotHideNewTraceFactsAfterRestart() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write(fixture.root, records: fixture.compactionRecords)
        _ = try await SessionEngine(home: fixture.home, cacheDirectory: fixture.cache).open(id: fixture.root)
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        cache["version"] = 4
        var files = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        for path in files.keys { files[path]?["records"] = [] }
        cache["files"] = files
        try JSONSerialization.data(withJSONObject: cache).write(to: url)
        let restarted = try await SessionEngine(home: fixture.home, cacheDirectory: fixture.cache).open(id: fixture.root)
        XCTAssertEqual(ContextInspectionIndex(events: restarted.events).identifiedOperationCount, 1)
    }

    func testSequenceBoundDeclaresEveryGroupedIdentityAndKeepsStableEventLinks() {
        let events = (0..<5).map { i -> LensEvent in
            LensEvent(id: "e\(i)", agentID: "a\(i)", kind: .delegation, source: SourceRef(path: "/fixture/\(i)"),
                trace: RecordedTraceFacts(communication: RecordedCommunicationFacts(kind: .message, stage: .sendRequested,
                    senderThreadID: "a\(i)", recipientThreadIDs: ["b\(i)"])))
        }
        let index = CommunicationInspectionIndex(events: events, agents: [])
        let projection = CommunicationSequenceProjection(communications: index.communications, agents: [], maximumLanes: 2)
        XCTAssertEqual(projection.lanes.count, 3)
        XCTAssertEqual(projection.omittedAgentCount, 8)
        XCTAssertEqual(Set(projection.routes.map(\.eventID)), Set(events.map(\.id)))
    }

    private struct Fixture {
        let root = "11111111-1111-4111-8111-111111111111"
        let child = "33333333-3333-4333-8333-333333333333"
        let directory: URL
        let home: URL
        let cache: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("LensInspection-" + UUID().uuidString)
            home = directory.appendingPathComponent("home"); cache = directory.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        func message(_ id: String, text: String) -> [String: Any] {
            ["type": "response_item", "payload": ["type": "message", "id": id, "role": "user", "content": [["type": "input_text", "text": text]]]]
        }
        var compactionRecords: [[String: Any]] { [
            ["type": "event_msg", "payload": ["type": "item_started", "item": ["type": "ContextCompaction", "id": "operation"]]],
            ["type": "compacted", "payload": ["window_id": "window", "message": "retained instruction", "replacement_history": [["type": "compaction", "encrypted_content": "OPAQUE-PRIVATE-BYTES"]]]],
            ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "ContextCompaction", "id": "operation"], "completed_at_ms": 0]]
        ] }
        func write(_ owner: String, parent: String? = nil, historyStart: Int? = nil, records: [[String: Any]]) throws {
            var meta: [String: Any] = ["id": owner, "cwd": directory.path, "cli_version": "0.159.2"]
            if let parent { meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent, "agent_name": "/root/worker"]]] }
            if let historyStart { meta["subagent_history_start_ordinal"] = historyStart }
            var data = Data()
            for (i, var record) in ([["type": "session_meta", "payload": meta]] + records).enumerated() {
                record["timestamp"] = "2026-10-01T14:00:\(String(format: "%02d", i))Z"
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
            }
            try data.write(to: home.appendingPathComponent("sessions/rollout-\(owner).jsonl"))
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
