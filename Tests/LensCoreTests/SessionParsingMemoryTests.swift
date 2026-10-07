import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LensCore

/// Run this filter in its own test process: unrelated allocations invalidate a process-footprint comparison.
final class SessionParsingMemoryTests: XCTestCase {
    func testManyNestedJSONRecordsKeepParsingFootprintBoundedAndLazySourceExact() async throws {
        let fixture = try ParsingMemoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertGreaterThanOrEqual(fixture.byteCount, 20 * 1024 * 1024)
        XCTAssertLessThanOrEqual(fixture.byteCount, 40 * 1024 * 1024)
        let engine = SessionEngine(home: fixture.home, cacheDirectory: fixture.directory.appendingPathComponent("cache"))
        let measurements = ParsingFootprintMeasurements()
        measurements.record(stage: "before-open")
        let snapshot = try await engine.open(id: fixture.rootID, progress: { progress in
            // This callback executes synchronously inside collection. Sampling
            // only after await could miss autoreleases drained at task return.
            measurements.record(stage: String(describing: progress.stage), completed: progress.completed, total: progress.total)
        })
        measurements.record(stage: "after-open")
        let samples = measurements.samples
        XCTAssertTrue(samples.allSatisfy { $0.status == KERN_SUCCESS }, "TASK_VM_INFO must succeed; missing measurements are not zero usage")
        let baseline = try XCTUnwrap(samples.first)
        let peak = try XCTUnwrap(samples.map(\.bytes).max())
        let growth = peak >= baseline.bytes ? peak - baseline.bytes : 0
        let allowance: UInt64 = 128 * 1024 * 1024
        print("SESSION_PARSING_MEMORY fixtureBytes=\(fixture.byteCount) records=\(fixture.recordCount) baseline=\(baseline.bytes) peak=\(peak) growth=\(growth) allowance=\(allowance)")
        for sample in samples {
            print("SESSION_PARSING_MEMORY_STAGE stage=\(sample.stage) completed=\(sample.completed) total=\(sample.total.map(String.init) ?? "unknown") bytes=\(sample.bytes) status=\(sample.status)")
        }
        XCTAssertTrue(samples.contains { $0.stage == "readingHistory" && $0.completed == Int64(fixture.byteCount) && $0.total == Int64(fixture.byteCount) },
                      "Measure the completed synchronous read while its temporary allocations are still observable")
        // The allowance includes retained indexes, snapshots, allocator caches
        // and cache serialization. The unpooled nested Foundation object graphs
        // must not accumulate with the entire ~35 MiB source stream.
        XCTAssertLessThanOrEqual(growth, allowance, "Per-record temporary JSON graphs accumulated during collection; inspect stage footprint logs")

        XCTAssertEqual(snapshot.events.count, fixture.recordCount, "Memory bounds must not discard source events")
        XCTAssertTrue(snapshot.coverage.allSatisfy { $0.category != "limite d'index" && $0.category != "événement volumineux" })
        let selected = try XCTUnwrap(snapshot.events.first { $0.callID == "memory-result-\(fixture.recordCount - 1)" })
        XCTAssertEqual(selected.kind, .toolResult)
        XCTAssertEqual(selected.source.offset, fixture.lastOffset)
        XCTAssertEqual(selected.source.length, fixture.lastRaw.count)
        XCTAssertEqual(selected.source.line, fixture.recordCount + 1)
        XCTAssertEqual(selected.source.sha256, ParsingMemoryFixture.digest(fixture.lastRaw))
        XCTAssertEqual(URL(fileURLWithPath: selected.source.path).standardizedFileURL, fixture.rollout.standardizedFileURL)
        XCTAssertEqual(selected.id, fixture.rootID + ":" + ParsingMemoryFixture.digest(Data(selected.source.path.utf8)) + ":" + String(fixture.lastOffset))
        XCTAssertFalse(selected.preview.contains(fixture.lastMarker), "The end marker must require a lazy source read beyond the preview")
        let detail = try await engine.sourceDetail(for: selected)
        XCTAssertEqual(detail.output, fixture.lastOutput)
        XCTAssertTrue(detail.output.contains(fixture.lastMarker))
        var recovered = Data(), offset = 0
        repeat {
            let page = try await engine.rawChunk(source: selected.source, offset: offset, limit: 4096)
            recovered.append(page.data)
            if let next = page.nextOffset { offset = next } else { break }
        } while offset < selected.source.length
        XCTAssertEqual(recovered, fixture.lastRaw, "Original source coordinates must still retrieve every byte")
        XCTAssertEqual(try ParsingMemoryFixture.fileDigest(fixture.rollout), fixture.originalDigest, "Collection and lazy reads preserve source bytes")
    }
}

private final class ParsingFootprintMeasurements: @unchecked Sendable {
    struct Sample {
        let stage: String
        let completed: Int64
        let total: Int64?
        let bytes: UInt64
        let status: kern_return_t
    }
    private let lock = NSLock()
    private var storage: [Sample] = []
    var samples: [Sample] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(stage: String, completed: Int64 = 0, total: Int64? = nil) {
        var info = task_vm_info_data_t()
        var words = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &words)
            }
        }
        let sample = Sample(stage: stage, completed: completed, total: total, bytes: info.phys_footprint, status: status)
        lock.lock(); storage.append(sample); lock.unlock()
    }
}

private struct ParsingMemoryFixture {
    private static let identity = "12345678-1234-4123-8123-123456789abc"
    private static let count = 1600
    var rootID: String { Self.identity }
    var recordCount: Int { Self.count }
    let directory: URL
    let home: URL
    let rollout: URL
    let byteCount: Int
    let lastOffset: UInt64
    let lastRaw: Data
    let lastOutput: String
    let lastMarker: String
    let originalDigest: String

    init() throws {
        let rootID = Self.identity, recordCount = Self.count
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensParsingMemory-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        let sourceHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessions = sourceHome.appendingPathComponent("sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let source = sessions.appendingPathComponent("rollout-anonymous-memory.jsonl")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        var hasher = SHA256(), written = 0
        func append(_ data: Data) throws {
            try writer.write(contentsOf: data); try writer.write(contentsOf: Data([10]))
            hasher.update(data: data); hasher.update(data: Data([10]))
            written += data.count + 1
        }
        try autoreleasepool {
            try append(JSONSerialization.data(withJSONObject: ["type": "session_meta",
                "payload": ["id": rootID, "cwd": "/fixture/memory/worktree"]], options: [.sortedKeys]))
        }
        var finalOffset: UInt64 = 0, finalRaw = Data(), finalOutput = "", finalMarker = ""
        for index in 0..<recordCount {
            try autoreleasepool {
                let marker = "ANONYMOUS_FULL_OUTPUT_END_\(index) café Ω"
                let items: [[String: Any]] = (0..<96).map { unit in
                    ["text": "anonymous nested string \(unit)", "attributes": ["ordinal": unit,
                        "labels": ["anonymous repeated label alpha", "anonymous repeated label beta",
                                   "anonymous repeated label gamma", "anonymous repeated label delta"]]] as [String: Any]
                }
                let output: [String: Any] = ["items": items, "tail": marker]
                let record: [String: Any] = ["type": "response_item", "timestamp": "2026-01-01T00:00:00Z",
                    "payload": ["type": "function_call_output", "call_id": "memory-result-\(index)", "output": output]]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                if index == recordCount - 1 {
                    finalOffset = UInt64(written); finalRaw = data; finalMarker = marker
                    finalOutput = String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
                }
                try append(data)
            }
        }
        directory = root; home = sourceHome; rollout = source; byteCount = written
        lastOffset = finalOffset; lastRaw = finalRaw; lastOutput = finalOutput; lastMarker = finalMarker
        originalDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func fileDigest(_ path: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: path)
        defer { try? reader.close() }
        var hasher = SHA256()
        while let block = try autoreleasepool(invoking: { try reader.read(upToCount: 1024 * 1024) }), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
