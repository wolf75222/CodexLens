import Darwin
import Foundation
import XCTest
@testable import LensCore

final class SparseTraceStorageTests: XCTestCase {
    private struct OriginalWire: Codable {
        var compaction: RecordedCompactionFacts?
        var usage: RecordedUsageFacts?
        var communication: RecordedCommunicationFacts?
        var toolObservation: RecordedToolObservationFacts?
        var explanation: RecordedExplanationFacts?
        var recordedAt: Date?
        var collectedAt: Date?
        var sourceIdentifiers: [String: String]?
        init(_ value: RecordedTraceFacts) {
            compaction = value.compaction; usage = value.usage; communication = value.communication
            toolObservation = value.toolObservation; explanation = value.explanation
            recordedAt = value.recordedAt; collectedAt = value.collectedAt; sourceIdentifiers = value.sourceIdentifiers
        }
    }
    private func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value
    }
    func testEverySparsePayloadKeepsOriginalWireShapeAndValueHashing() throws {
        let values = [
            RecordedTraceFacts(),
            RecordedTraceFacts(sourceIdentifiers: ["payload.id": "anonymous"]),
            RecordedTraceFacts(compaction: .init(phase: .checkpoint, threadID: "fixture")),
            RecordedTraceFacts(usage: .init(kind: .requestRecord, threadID: "fixture", request: .init(input: 12, output: 3, total: 15))),
            RecordedTraceFacts(communication: .init(kind: .message, stage: .sendRequested, recipientThreadIDs: ["fixture"])),
            RecordedTraceFacts(toolObservation: .init(toolName: "fixture_read", callID: "call", status: "recorded")),
            RecordedTraceFacts(explanation: .init(kind: .reasoningSummary, availability: .available, threadID: "fixture", preview: "Anonymous explanation")),
            RecordedTraceFacts(recordedAt: Date(timeIntervalSince1970: 100), collectedAt: Date(timeIntervalSince1970: 200))
        ]
        for value in values {
            let wire = try encoder().encode(OriginalWire(value))
            let restored = try JSONDecoder().decode(RecordedTraceFacts.self, from: wire)
            XCTAssertEqual(restored, value)
            XCTAssertEqual(try encoder().encode(restored), wire)
            XCTAssertEqual(Set([value, restored]).count, 1, "Payload box identity is not fact identity")
        }
        XCTAssertEqual(String(decoding: try encoder().encode(RecordedTraceFacts()), as: UTF8.self), "{}")
        let nulls = Data(#"{"compaction":null,"usage":null,"communication":null,"toolObservation":null,"explanation":null}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RecordedTraceFacts.self, from: nulls), RecordedTraceFacts())
    }
    func testSparsePayloadNestedMutationAndReplacementPreserveOtherCopies() throws {
        let original = RecordedTraceFacts(toolObservation: .init(toolName: "fixture_read", callID: "original", status: "recorded"),
            sourceIdentifiers: ["payload.id": "source"])
        let event = LensEvent(id: "fixture-event", agentID: "fixture", source: SourceRef(path: "/fixture/log.jsonl"), trace: original)
        let snapshot = SessionSnapshot(root: .init(id: "fixture"), events: [event])
        let lookup = [event.id: event]
        var copy = event
        copy.trace?.recordedAt = Date(timeIntervalSince1970: 400)
        copy.trace?.sourceIdentifiers?["payload.id"] = "changed"
        copy.trace?.toolObservation?.callID = "changed"
        copy.trace?.toolObservation?.outputs.append(.init(kind: .toolResult, fieldPath: "output", utf8Count: 12))
        XCTAssertEqual(snapshot.events[0].trace, original)
        XCTAssertEqual(lookup[event.id]?.trace, original)
        XCTAssertEqual(original.toolObservation?.callID, "original")
        XCTAssertTrue(original.toolObservation?.outputs.isEmpty == true)
        copy.trace?.toolObservation = nil
        XCTAssertNil(copy.trace?.toolObservation)
        XCTAssertNotNil(original.toolObservation)
        copy.trace = original
        XCTAssertEqual(copy, event)
        XCTAssertEqual(try encoder().encode(copy.trace), try encoder().encode(event.trace))
    }
    func testIndependentSendableCopiesKeepImmutablePayloadsIsolated() async {
        let original = RecordedTraceFacts(toolObservation: .init(toolName: "fixture_read", callID: "original"),
            sourceIdentifiers: ["payload.id": "source"])
        let copies = await withTaskGroup(of: RecordedTraceFacts.self) { group in
            for index in 0..<64 {
                group.addTask {
                    var value = original
                    value.collectedAt = Date(timeIntervalSince1970: Double(index))
                    value.toolObservation?.callID = "copy-\(index)"
                    value.sourceIdentifiers?["task"] = String(index)
                    return value
                }
            }
            var values: [RecordedTraceFacts] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(copies.count, 64)
        XCTAssertEqual(Set(copies.compactMap { $0.toolObservation?.callID }).count, 64)
        XCTAssertEqual(original.toolObservation?.callID, "original")
        XCTAssertNil(original.collectedAt)
        XCTAssertNil(original.sourceIdentifiers?["task"])
    }
    func testEqualAssignmentsAndAbsentNestedWritebacksKeepSharedStorage() throws {
        let full = RecordedTraceFacts(
            compaction: .init(phase: .checkpoint, threadID: "fixture", opaqueItemIDs: ["opaque"]),
            usage: .init(kind: .requestRecord, threadID: "fixture", request: .init(input: 12)),
            communication: .init(kind: .message, stage: .sendRequested, recipientThreadIDs: ["fixture"]),
            toolObservation: .init(toolName: "fixture_read", callID: "original", status: "recorded"),
            explanation: .init(kind: .reasoningSummary, availability: .available, threadID: "fixture", preview: "Anonymous"),
            recordedAt: Date(timeIntervalSince1970: 100), collectedAt: Date(timeIntervalSince1970: 200),
            sourceIdentifiers: ["payload.id": "source"])
        for original in [RecordedTraceFacts(), RecordedTraceFacts(sourceIdentifiers: ["payload.id": "sparse"]), full] {
            var copy = original
            let shared = try storageIdentity(original)
            copy.compaction = original.compaction
            copy.usage = original.usage
            copy.communication = original.communication
            copy.toolObservation = original.toolObservation
            copy.explanation = original.explanation
            copy.recordedAt = original.recordedAt
            copy.collectedAt = original.collectedAt
            copy.sourceIdentifiers = original.sourceIdentifiers
            XCTAssertEqual(try storageIdentity(copy), shared, "All eight equal assignments preserve the same COW allocation")
            copy.compaction?.opaqueItemIDs = original.compaction?.opaqueItemIDs ?? []
            copy.usage?.request?.input = original.usage?.request?.input
            copy.communication?.recipientThreadIDs = original.communication?.recipientThreadIDs ?? []
            copy.toolObservation?.status = original.toolObservation?.status
            copy.explanation?.preview = original.explanation?.preview ?? ""
            copy.sourceIdentifiers?["payload.id"] = original.sourceIdentifiers?["payload.id"]
            XCTAssertEqual(copy, original)
            XCTAssertEqual(try storageIdentity(copy), shared, "A nil or unchanged nested optional writeback must not clone storage")
            XCTAssertEqual(try encoder().encode(copy), try encoder().encode(original))
            copy.collectedAt = Date(timeIntervalSince1970: 999)
            XCTAssertNotEqual(try storageIdentity(copy), shared)
            XCTAssertEqual(try storageIdentity(original), shared)
            XCTAssertNotEqual(copy, original)
        }
    }
    func testIdentifierOnlyTraceAllocationDoesNotReserveAbsentPayloadStructs() throws {
        let count = 100_000
        let before = try footprint()
        var values: [RecordedTraceFacts] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(RecordedTraceFacts(recordedAt: Date(timeIntervalSince1970: Double(index)),
                sourceIdentifiers: ["payload.id": String(index)]))
        }
        let retained = try withExtendedLifetime(values) { try footprint() }
        let growth = retained >= before ? retained - before : 0
        print("SPARSE_TRACE_ALLOCATION count=\(count) before=\(before) retained=\(retained) growth=\(growth) allowance=100663296")
        XCTAssertEqual(values.count, count)
        XCTAssertEqual(values.first?.sourceIdentifiers?["payload.id"], "0")
        XCTAssertEqual(values.last?.sourceIdentifiers?["payload.id"], String(count - 1))
        XCTAssertLessThanOrEqual(growth, 96 * 1024 * 1024,
            "Absent payload fields must not reserve the former 1216-byte inline state per trace; run this filter in a separate process for comparison")
        XCTAssertEqual(MemoryLayout<RecordedTraceFacts>.stride, MemoryLayout<UnsafeRawPointer>.stride)
        XCTAssertEqual(MemoryLayout<RecordedTraceFacts?>.stride, MemoryLayout<UnsafeRawPointer>.stride)
    }
    private func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: "SparseTraceFootprint", code: Int(status)) }
        return info.phys_footprint
    }
    private func storageIdentity(_ value: RecordedTraceFacts) throws -> ObjectIdentifier {
        let storage = try XCTUnwrap(Mirror(reflecting: value).children.first { $0.label == "storage" })
        XCTAssertEqual(Mirror(reflecting: storage.value).displayStyle, .class)
        return ObjectIdentifier(storage.value as AnyObject)
    }
}
