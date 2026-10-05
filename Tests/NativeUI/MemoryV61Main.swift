import Foundation
import Darwin
import LensCore

/// Controlled Core-only allocation scenario, not a measurement of the GUI app.
/// Same entrypoint and generated records are compiled against both frozen versions.
@main struct MemoryV61Main {
    static func main() async throws {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String { args[args.firstIndex(of: name)! + 1] }
        let output = URL(fileURLWithPath: argument("--output"))
        let count = 100_000
        var samples: [[String: Any]] = []
        func sample(_ stage: String) {
            var info = task_vm_info_data_t()
            var words = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &words)
                }
            }
            samples.append(["stage": stage, "taskInfoStatus": status,
                            "physicalFootprintBytes": info.phys_footprint,
                            "residentBytes": info.resident_size])
        }
        sample("empty")
        let rootID = "aaaaaaaa-0000-4000-8000-000000000001"
        let source = SourceRef(path: "/anonymous/rollout.jsonl", offset: 0, length: 96, line: 1)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var events: [LensEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            // Three quarters are ordinary text records; the rest carry sparse metadata.
            let trace: RecordedTraceFacts? = index % 4 == 0 ? RecordedTraceFacts(
                recordedAt: start, collectedAt: start, sourceIdentifiers: ["payload.id": "record-\(index)"]) : nil
            events.append(LensEvent(id: "event-\(index)", timestamp: start.addingTimeInterval(Double(index)),
                agentID: rootID, kind: index % 8 == 0 ? .toolCall : .assistant,
                title: index % 8 == 0 ? "fixture_read" : "Recorded message",
                preview: "A recorded anonymous message retained unchanged for the memory comparison.",
                toolName: index % 8 == 0 ? "fixture_read" : nil,
                source: source, trace: trace))
        }
        var snapshot: SessionSnapshot? = SessionSnapshot(root: SessionSummary(id: rootID),
            agents: [AgentRecord(id: rootID, name: "Fixture")], events: events, collectedAt: start)
        sample("snapshot")
        let builder = SessionPresentationBuilder()
        var presentation: SessionPresentation? = try await builder.prepare(snapshot: snapshot!, revision: 1, filters: EventFilters())
        await builder.didPublish(presentation!, sequence: 1)
        sample("indexed")
        guard presentation?.filteredEvents.count == count, presentation?.eventsByID.count == count,
              presentation?.callCount == count / 8 else { fatalError("Lost records") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let serialized = try encoder.encode(Array(events.prefix(8)))
        try serialized.write(to: output.appendingPathComponent("record-sample.json"))
        var filtered: SessionPresentation? = try await builder.prepare(snapshot: snapshot!, revision: 1, filters: EventFilters(query: "fixture_read"))
        guard filtered?.filteredEvents.count == count / 8 else { fatalError("Lost filter results") }
        sample("filtered_previous_generation_retained")
        await builder.didPublish(filtered!, sequence: 2)
        presentation = nil
        sample("filtered_previous_generation_released")
        // Explicitly release all consumer copies and actor-owned indexes, as on window closure.
        filtered = nil; snapshot = nil; events.removeAll(keepingCapacity: false)
        await builder.invalidateCache()
        try await Task.sleep(nanoseconds: 150_000_000)
        sample("closed")
        let report: [String: Any] = ["sourceLabel": argument("--source-label"),
            "eventCount": count, "tracePresentCount": count / 4,
            "eventStrideBytes": MemoryLayout<LensEvent>.stride,
            "traceStrideBytes": MemoryLayout<RecordedTraceFacts>.stride,
            "samples": samples, "functionalChecksPassed": true,
            "measurementContract": "Release arm64 Core-only, physical footprint from TASK_VM_INFO at fixed stages; no GUI, no profiler overhead, same immutable record-sample JSON. Closed footprint includes allocator retention; this is not a leak scan."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("memory-report.json"), options: .atomic)
        print("MEMORY_COMPLETE eventStride=\(MemoryLayout<LensEvent>.stride) traceStride=\(MemoryLayout<RecordedTraceFacts>.stride)")
    }
}
