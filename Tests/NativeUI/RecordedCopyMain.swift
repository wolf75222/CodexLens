import Foundation
import CryptoKit
import LensCore

/// Logic probe built with the application sources, outside the production app target.
/// It never accesses the system clipboard, starts Codex, executes a command, or makes a model request.
@main struct RecordedCopyProbeMain {
    static func main() async {
        do { try await run() }
        catch { fputs("RECORDED_COPY_PROBE_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--output"), index + 1 < args.count else { throw failure("Missing own --output directory") }
        let output = URL(fileURLWithPath: args[index + 1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws { guard value else { throw failure(name) }; checks.append(name) }
        func recorded(_ input: String, name: String, environment: String) throws -> LensEvent {
            let bytes = try JSONSerialization.data(withJSONObject: ["payload": ["type": "custom_tool_call", "input": input]], options: [.sortedKeys, .withoutEscapingSlashes])
            let path = output.appendingPathComponent(name); try bytes.write(to: path)
            return LensEvent(id: name, agentID: "fixture-agent", kind: .toolCall, toolName: "apply_patch", environmentID: environment,
                source: SourceRef(path: path.path, length: bytes.count, line: 1, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
        }
        let sentinel = output.appendingPathComponent("MUST-NOT-EXECUTE")
        let input = "touch '" + sentinel.path + "'\n" + "*** Begin Patch\n*** Update File: src/main.swift\n@@\n" + String(repeating: "+é👩🏽‍💻\\\"\t\n", count: 90000) + "*** End Patch\nTRAILING-MARKER\n"
        let a = try recorded(input, name: "trace-a.jsonl", environment: "/fixture/worktrees/a")
        let b = try recorded("COMMAND-B\n", name: "trace-b.jsonl", environment: "/fixture/worktrees/b")
        let pager = RecordedPager()
        let copied = try await Task.detached { try await RecordedCopyReader.read(pager: pager, event: a, related: nil, part: "input", source: a.source) }.value
        try check(copied == input, "Complete decoded input including trailing marker equals recorded input")
        try check(!copied.contains("[Source"), "Single-source complete copy excludes presentation headers")
        try check(!FileManager.default.fileExists(atPath: sentinel.path), "Recorded command was never executed")
        let bCopy = try await RecordedCopyReader.read(pager: pager, event: a, related: b, part: "input", source: b.source)
        try check(bCopy == "COMMAND-B\n", "Chosen trace excludes the other worktree and call")
        let generic = try await RecordedCopyReader.read(pager: pager, event: a, related: b, part: "input", source: nil)
        try check(generic.contains("[Source 1") && generic.contains("[Source 2"), "Generic multi-source copy preserves explicit source separators")
        do { _ = try await RecordedCopyReader.read(pager: pager, event: a, related: nil, part: "input", source: a.source, maximumBytes: 128); throw failure("Copy budget silently accepted") }
        catch RecordedCopyFailure.budget { checks.append("Budget refuses complete copy without returning partial text") }
        do { _ = try await RecordedCopyReader.read(pager: pager, event: a, related: nil, part: "output", source: a.source); throw failure("Missing field silently accepted") }
        catch RecordedCopyFailure.empty { checks.append("Missing or empty rubric is explicit") }
        let secret = try recorded("Bearer ABCdef123 sk-example-secret\nEND", name: "secret.jsonl", environment: "/fixture/worktrees/a")
        let masked = try await RecordedCopyReader.read(pager: pager, event: secret, related: nil, part: "input", source: secret.source)
        try check(masked.contains("[REDACTED]") && !masked.contains("ABCdef123") && !masked.contains("sk-example-secret"), "Undecorated copy retains known secret masking")
        let version = RecordedCopySourceVersion(event: a, related: b)
        try check(version == RecordedCopySourceVersion(event: a, related: b), "Identical source version remains stable")
        var changed = a; changed.source.sha256 = String(repeating: "0", count: 64)
        try check(version != RecordedCopySourceVersion(event: changed, related: b), "Recorded SHA change invalidates copy version")
        changed = a; changed.environmentID = b.environmentID
        try check(version != RecordedCopySourceVersion(event: changed, related: b), "Environment reassociation invalidates copy version")
        var changedRelated = b; changedRelated.source.offset = 4
        try check(version != RecordedCopySourceVersion(event: a, related: changedRelated), "Related trace coordinate change invalidates copy version")
        changed = a; changed.relatedEventID = "new-related"
        try check(version != RecordedCopySourceVersion(event: changed, related: b), "Recorded relation change invalidates copy version")
        var duplicate = a; duplicate.supplementarySources = [a.source, b.source]
        let entries = RecordedCopySourceEntry.entries(event: duplicate, related: b)
        try check(entries.map(\.source) == [a.source,b.source], "Copy menu deduplicates exact SourceRefs only")
        let partialBytes = Data(("{\"payload\":{\"input\":\"" + String(repeating: "q", count: 100000)).utf8)
        let partialPath = output.appendingPathComponent("partial.jsonl"); try partialBytes.write(to: partialPath)
        let partial = LensEvent(id: "partial", agentID: "fixture-agent", source: SourceRef(path: partialPath.path, length: partialBytes.count, line: 1))
        do { _ = try await RecordedCopyReader.read(pager: pager, event: partial, related: nil, part: "input", source: partial.source); throw failure("Incomplete source returned complete copy") }
        catch let error as LensError { try check(error.localizedDescription.contains("incomplète"), "Incomplete source fails before complete copy returns") }
        let gate = RecordedCopyProgressGate()
        let cancelled = Task.detached { try await RecordedCopyReader.read(pager: pager, event: a, related: nil, part: "input", source: a.source) { _ in await gate.markAndWait() } }
        while !(await gate.arrived) { await Task.yield() }
        cancelled.cancel(); await gate.release()
        do { _ = try await cancelled.value; throw failure("Cancelled copy returned complete text") }
        catch is CancellationError { checks.append("Cancellation prevents complete text from returning") }
        let receipt: [String: Any] = ["allPassed": true, "assertions": checks.count, "checks": checks, "sourceType": "Deterministic anonymous own recorded fixtures", "systemClipboardAccessed": false, "modelRequests": 0, "commandsExecuted": 0, "UIInteractionQualified": false, "scope": "Pager decoration, complete-copy reader, budget, missing/incomplete data, source version, cancellation; not native menu targeting or clipboard publication"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("recorded-copy-receipt.json"))
        print("Recorded copy logic probe: \(checks.count) assertions passed")
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "RecordedCopyProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
actor RecordedCopyProgressGate {
    private(set) var arrived = false
    private var continuation: CheckedContinuation<Void, Never>?
    func markAndWait() async { arrived = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
