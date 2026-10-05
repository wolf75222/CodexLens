import XCTest
@testable import LensCore

final class RecordedTraceStorageTests: XCTestCase {
    // The pre-0.39.3 synthesized wire shape, including omitted optional fields.
    private struct Legacy: Codable {
        var compaction: RecordedCompactionFacts?
        var usage: RecordedUsageFacts?
        var communication: RecordedCommunicationFacts?
        var toolObservation: RecordedToolObservationFacts?
        var explanation: RecordedExplanationFacts?
        var recordedAt: Date?
        var collectedAt: Date?
        var sourceIdentifiers: [String: String]?
        init(_ facts: RecordedTraceFacts) {
            compaction = facts.compaction; usage = facts.usage; communication = facts.communication
            toolObservation = facts.toolObservation; explanation = facts.explanation
            recordedAt = facts.recordedAt; collectedAt = facts.collectedAt; sourceIdentifiers = facts.sourceIdentifiers
        }
    }
    private func facts() -> RecordedTraceFacts {
        RecordedTraceFacts(compaction: .init(phase: .checkpoint, threadID: "child", visibility: .opaque, opaqueItemCount: 1, opaqueItemIDs: ["opaque"]),
            usage: .init(kind: .requestRecord, threadID: "child", request: .init(input: 10, output: 2, total: 12)),
            communication: .init(kind: .message, stage: .sendRequested, recipientThreadIDs: ["child"], isOpaque: true),
            toolObservation: .init(toolName: "fixture_read", callID: "call", environmentID: "beta", outputs: [], status: "recorded"),
            explanation: .init(kind: .reasoningSummary, availability: .opaque, threadID: "child", encryptedContentPresent: true),
            recordedAt: Date(timeIntervalSince1970: 100), collectedAt: Date(timeIntervalSince1970: 200),
            sourceIdentifiers: ["payload.id": "source"])
    }
    func testLegacyJSONCompatibilityForEmptySparseAndPopulatedRecords() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for original in [RecordedTraceFacts(), RecordedTraceFacts(sourceIdentifiers: ["id": "sparse"]), facts()] {
            let oldBytes = try encoder.encode(Legacy(original))
            let restored = try decoder.decode(RecordedTraceFacts.self, from: oldBytes)
            XCTAssertEqual(restored, original)
            XCTAssertEqual(try encoder.encode(restored), oldBytes)
            XCTAssertFalse(String(decoding: oldBytes, as: UTF8.self).contains("storage"))
        }
    }
    func testNestedMutationDoesNotAlterSnapshotOrDictionaryCopies() {
        let original = LensEvent(id: "event", agentID: "child", source: SourceRef(path: "/beta/log.jsonl"), trace: facts())
        let snapshot = SessionSnapshot(root: .init(id: "root"), events: [original])
        let byID = [original.id: original]
        var copy = original
        copy.trace?.compaction?.opaqueItemIDs.append("new")
        copy.trace?.usage?.request?.input = 999
        copy.trace?.communication?.recipientThreadIDs.append("other")
        copy.trace?.toolObservation?.status = "changed"
        copy.trace?.explanation?.preview = "changed"
        copy.trace?.sourceIdentifiers?["payload.id"] = "changed"
        copy.trace?.recordedAt = .distantFuture
        copy.trace?.collectedAt = .distantFuture
        XCTAssertEqual(snapshot.events[0], original)
        XCTAssertEqual(byID["event"], original)
        XCTAssertNotEqual(copy, original)
        XCTAssertEqual(original.trace, facts())
    }
    func testEqualityAndHashIgnoreStorageIdentity() throws {
        let original = facts()
        let decoded = try JSONDecoder().decode(RecordedTraceFacts.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(Set([original, decoded]).count, 1)
        var changed = original; changed.sourceIdentifiers?["new"] = "value"
        XCTAssertEqual(Set([original, decoded, changed]).count, 2)
        XCTAssertEqual([original: "saved"][decoded], "saved")
    }
    func testIndependentTaskCopiesPreserveOriginal() async throws {
        let original = facts()
        let values = try await withThrowingTaskGroup(of: RecordedTraceFacts.self) { group in
            for index in 0..<100 {
                group.addTask {
                    var local = original
                    local.sourceIdentifiers?["task"] = String(index)
                    local.usage?.request?.total = Int64(index)
                    return local
                }
            }
            var results: [RecordedTraceFacts] = []
            for try await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(original, facts())
        XCTAssertEqual(values.count, 100)
        XCTAssertEqual(Set(values.compactMap { $0.sourceIdentifiers?["task"] }).count, 100)
    }
    func testAbsentTraceDoesNotReserveAllSparsePayloadsInEachEvent() {
        // Protect the measured 1472-byte per-event regression on supported arm64.
        XCTAssertLessThanOrEqual(MemoryLayout<RecordedTraceFacts>.stride, 16)
        XCTAssertLessThanOrEqual(MemoryLayout<LensEvent>.stride, 384)
    }
}
