import Foundation
import XCTest
@testable import LensCore

/// Acceptance scenarios use temporary, invented history. No personal rollout is bundled.
final class AcceptanceTests: XCTestCase {
    func testOpaqueDelegationKeepsExactRawSourceButDoesNotPresentCiphertextAsMission() async throws {
        let f = try Fixture(); defer { f.remove() }
        var wire = Data(repeating: 0, count: 89); wire[0] = 0x80
        let encrypted = wire.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let path = try f.rollout(Fixture.root, cwd: f.first, records: [f.call("opaque-spawn", "spawn_agent", ["task_name": "reader", "message": encrypted]), f.result("opaque-spawn", "{\"agent_id\":\"\(Fixture.child)\"}")])
        try f.rollout(Fixture.child, cwd: f.second, parent: Fixture.root, records: [f.message("assistant", "Visible separate child explanation")])
        let original = try Data(contentsOf: path)
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let spawn = try XCTUnwrap(snapshot.events.first { $0.callID == "opaque-spawn" && $0.kind == .delegation })
        XCTAssertEqual(spawn.trace?.communication?.isOpaque, true)
        XCTAssertFalse(spawn.preview.contains(encrypted))
        XCTAssertTrue(try XCTUnwrap(snapshot.agents.first { $0.id == Fixture.child }).mission.contains("opaque"))
        XCTAssertTrue(snapshot.coverage.contains { $0.category == "mission opaque" })
        let detail = try await engine.sourceDetail(for: spawn)
        XCTAssertTrue(detail.raw.contains(encrypted))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
    func testCancelledSessionLoadLeavesPreviousSessionObservable() async throws {
        let f = try Fixture(); defer { f.remove() }
        let previousPath = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("assistant", "Original session")])
        _ = try f.rollout(Fixture.unrelated, cwd: f.second, records: (0..<8000).map { f.message("assistant", "Independent history \($0) " + String(repeating: "content ", count: 30)) })
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        _ = try await engine.open(id: Fixture.root)
        let loading = Task { try await engine.open(id: Fixture.unrelated) }
        try await Task.sleep(nanoseconds: 10_000_000)
        loading.cancel()
        do { _ = try await loading.value; XCTFail("The long source load should observe cancellation") }
        catch is CancellationError { }
        try f.append(try f.data(f.message("assistant", "Still observing the original session")) + Data([10]), to: previousPath)
        let refreshed = try await engine.refresh()
        let current = try XCTUnwrap(refreshed)
        XCTAssertEqual(current.root.id, Fixture.root)
        XCTAssertTrue(current.events.contains { $0.preview.contains("Still observing the original session") })
        XCTAssertFalse(current.events.contains { $0.agentID == Fixture.unrelated })
    }

    func testSearchKeepsCapturedCallResultGraphAfterAnotherSessionOpens() async throws {
        let f = try Fixture(); defer { f.remove() }
        let alpha = "marker_only_in_recorded_result_alpha", beta = "marker_only_in_recorded_result_beta"
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [f.call("shared-call-id", "exec_command", ["cmd": "echo recorded"]), f.result("shared-call-id", alpha)])
        _ = try f.rollout(Fixture.unrelated, cwd: f.second, records: [f.call("shared-call-id", "exec_command", ["cmd": "echo other"]), f.result("shared-call-id", beta)])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let captured = try await engine.open(id: Fixture.root)
        let call = try XCTUnwrap(captured.events.first { $0.kind == .toolCall })
        let result = try XCTUnwrap(captured.events.first { $0.kind == .toolResult })
        XCTAssertFalse(call.preview.contains(alpha))
        _ = try await engine.open(id: Fixture.unrelated)
        let matched = try await engine.matchingEventIDs(query: alpha, snapshot: captured)
        XCTAssertTrue(matched.contains(call.id), "A captured call must still search its own recorded result after the engine switches roots")
        XCTAssertTrue(matched.contains(result.id))
        let foreign = try await engine.search(query: beta, snapshot: captured)
        XCTAssertTrue(foreign.isEmpty, "A shared call ID must not associate outputs from another agent/session")
    }

    func testCancelledSearchThrowsAndLeavesRecordedSourceAndNextSearchIntact() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("assistant", "Searchable captured marker")])
        let bytes = try Data(contentsOf: path)
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await engine.search(query: "captured marker", snapshot: snapshot)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search must not publish a partial success") }
        catch is CancellationError { }
        let next = try await engine.search(query: "captured marker", snapshot: snapshot)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testSessionToSeparateChildToolEnvironmentAndSuppliedResource() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let supplied = f.base.appendingPathComponent("provided design.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: supplied)
        let source = f.second.appendingPathComponent("Sources/shared.swift")
        try f.file(source, "current second-worktree content")
        try f.file(f.first.appendingPathComponent("Sources/shared.swift"), "different first-worktree content")
        let root = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.context("turn-one", cwd: f.first),
            f.message("user", "Files supplied by the user:\n" + supplied.path, extra: [["type": "localImage", "path": supplied.path]]),
            f.call("delegate", "spawn_agent", ["task_name": "reader", "message": "Read the second worktree source."]),
            f.result("delegate", "{\"agent_id\":\"\(Fixture.child)\"}"),
            f.message("assistant", "The reader is working independently.")
        ])
        _ = try f.rollout(Fixture.child, cwd: f.second, parent: Fixture.root, records: [
            f.context("child-turn", cwd: f.second),
            f.call("read-one", "exec_command", ["cmd": "cat Sources/shared.swift", "workdir": f.second.path]),
            f.result("read-one", "historical recorded content\n"),
            f.message("assistant", "Read completed.")
        ])
        let original = try Data(contentsOf: root)
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        XCTAssertEqual(Set(snapshot.agents.map(\.id)), Set([Fixture.root, Fixture.child]))
        let child = try XCTUnwrap(snapshot.agents.first { $0.id == Fixture.child })
        XCTAssertEqual(child.parentID, Fixture.root)
        XCTAssertEqual(child.relation, .subagent)
        let read = try XCTUnwrap(snapshot.events.first { $0.callID == "read-one" && $0.kind == .toolCall })
        XCTAssertEqual(read.agentID, Fixture.child)
        XCTAssertEqual(read.environmentID, f.second.path)
        let detail = try await engine.detail(for: read)
        let readArguments = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(detail.arguments.utf8)) as? [String: Any])
        XCTAssertEqual(readArguments["cmd"] as? String, "cat Sources/shared.swift")
        XCTAssertTrue(detail.output.contains("historical recorded content"))
        XCTAssertTrue(detail.raw.contains("read-one"))
        XCTAssertTrue(snapshot.environments.contains { $0.path == f.first.path })
        XCTAssertTrue(snapshot.environments.contains { $0.path == f.second.path })
        let resource = try XCTUnwrap(snapshot.resources.first { $0.location == supplied.path })
        XCTAssertTrue(resource.roles.contains(.supplied))
        XCTAssertFalse(resource.eventIDs.isEmpty)
        XCTAssertTrue(resource.agentIDs.contains(Fixture.root))
        XCTAssertTrue(snapshot.resources.contains { $0.location == source.path && $0.environmentID == f.second.path })
        XCTAssertEqual(try Data(contentsOf: root), original, "Opening must not alter its source rollout")
    }

    func testLiveAppendRetriesUnfinishedLineAndRetainsSelectionIdentifiers() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let path = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("user", "Begin")])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let before = try await engine.open(id: Fixture.root)
        let selectedID = try XCTUnwrap(before.events.first { $0.kind == .user }).id
        let next = try f.data(f.message("assistant", "A complete event arrived later."))
        let midpoint = next.count / 2
        try f.append(Data(next.prefix(midpoint)), to: path)
        let partialRefresh = try await engine.refresh()
        let partial = try XCTUnwrap(partialRefresh)
        XCTAssertEqual(partial.events.count, before.events.count)
        try f.append(Data(next.dropFirst(midpoint)) + Data([0x0a]), to: path)
        let fullRefresh = try await engine.refresh()
        let after = try XCTUnwrap(fullRefresh)
        XCTAssertEqual(after.events.count, before.events.count + 1)
        XCTAssertTrue(after.events.contains { $0.id == selectedID })
        let repeatedRefresh = try await engine.refresh()
        if let repeated = repeatedRefresh {
            XCTAssertEqual(repeated.events.map(\.id), after.events.map(\.id), "Polling must not duplicate old events")
        }
    }

    func testLogGrowingDuringInitialReadDoesNotUnderflowItsPendingByteCount() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let records = (0..<6_000).map { f.message("assistant", "Synthetic initial event \($0): " + String(repeating: "payload ", count: 24)) }
        let path = try f.rollout(Fixture.root, cwd: f.first, records: records)
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        async let initialRead = engine.open(id: Fixture.root)
        let writer = Task.detached {
            try await Task.sleep(nanoseconds: 20_000_000)
            for i in 0..<20 {
                try f.append(try f.data(f.message("assistant", "Concurrent append \(i)")) + Data([0x0a]), to: path)
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let initial = try await initialRead
        try await writer.value
        XCTAssertGreaterThan(initial.events.count, 6_000, "The writer must overlap ingestion for this regression scenario")
        let refreshed = try await engine.refresh()
        let final = try XCTUnwrap(refreshed)
        XCTAssertEqual(final.events.count, 6_020)
        XCTAssertEqual(Set(final.events.map(\.id)).count, 6_020)
    }

    func testMalformedRecordAndUnavailableChildAreVisibleCoverageGaps() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let path = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.call("missing-agent", "spawn_agent", ["task_name": "missing", "message": "Inspect unavailable source."]),
            f.result("missing-agent", "{\"agent_id\":\"\(Fixture.child)\"}"),
            f.message("assistant", "Still readable before the malformed record.")
        ])
        try f.append(Data("{ malformed record }\n".utf8), to: path)
        try f.append(try f.data(f.message("assistant", "Still readable after the malformed record.")) + Data([0x0a]), to: path)
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        XCTAssertTrue(snapshot.events.contains { $0.preview.contains("after the malformed") })
        XCTAssertFalse(snapshot.coverage.isEmpty)
        XCTAssertTrue(snapshot.agents.contains { $0.id == Fixture.child && !$0.accessible })
        XCTAssertTrue(snapshot.coverage.contains { $0.category.localizedCaseInsensitiveContains("JSON") })
    }

    func testAssociationRequiresRecordedParentAndPreservesForkDistinction() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("user", "Inspect this session")])
        _ = try f.rollout(Fixture.child, cwd: f.first, oldParent: Fixture.root, records: [f.message("assistant", "Legacy subagent")])
        _ = try f.rollout(Fixture.fork, cwd: f.first, fork: Fixture.root, records: [f.message("assistant", "Fork continuation")])
        _ = try f.rollout(Fixture.unrelated, cwd: f.first, records: [f.message("assistant", "Unrelated session in the same repository")])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        XCTAssertEqual(snapshot.agents.first { $0.id == Fixture.child }?.relation, .subagent)
        XCTAssertEqual(snapshot.agents.first { $0.id == Fixture.fork }?.relation, .fork)
        XCTAssertFalse(snapshot.agents.contains { $0.id == Fixture.unrelated })
        XCTAssertFalse(snapshot.events.contains { $0.agentID == Fixture.unrelated })
        let catalog = try await engine.catalog()
        XCTAssertTrue(catalog.contains { $0.id == Fixture.unrelated }, "Catalog discoverability is separate from session membership")
    }

    func testToolInspectionDoesNotExecuteRecordedCommandAndLoadsFullLongOutput() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let marker = f.base.appendingPathComponent("must-never-exist")
        let longOutput = String(repeating: "an invented output line\n", count: 12_000) + "UNIQUE_END_OF_RECORDED_OUTPUT"
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.call("dangerous-replay", "exec_command", ["cmd": "touch \(marker.path)", "workdir": f.first.path]),
            f.result("dangerous-replay", longOutput)
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let call = try XCTUnwrap(snapshot.events.first { $0.callID == "dangerous-replay" && $0.kind == .toolCall })
        let detail = try await engine.detail(for: call)
        XCTAssertEqual(detail.output, longOutput)
        let hits = try await engine.search(query: "UNIQUE_END_OF_RECORDED_OUTPUT", snapshot: snapshot)
        XCTAssertFalse(hits.isEmpty, "Search must include lazy output beyond the preview")
        let result = try XCTUnwrap(snapshot.events.first { $0.callID == "dangerous-replay" && $0.kind == .toolResult })
        var rawBytes = Data(), offset = 0, pageCount = 0
        repeat {
            let page = try await engine.rawChunk(source: result.source, offset: offset, limit: 4096)
            rawBytes.append(page.data)
            pageCount += 1
            if let next = page.nextOffset { offset = next } else { break }
        } while pageCount < 1000
        XCTAssertGreaterThan(pageCount, 1)
        XCTAssertEqual(rawBytes, try f.data(f.result("dangerous-replay", longOutput)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMentionedFileIsNotClaimedAsRecordedReadAndMissingAttachmentStaysMissing() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let mentioned = f.first.appendingPathComponent("mentioned-only.txt")
        let missing = f.base.appendingPathComponent("attachment no longer available.pdf")
        try f.file(mentioned, "present current bytes")
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.message("user", "Consider the path \(mentioned.path).", extra: [["type": "localImage", "path": missing.path]])
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let mention = try XCTUnwrap(snapshot.resources.first { $0.location == mentioned.path })
        XCTAssertTrue(mention.roles.contains(.referenced))
        XCTAssertFalse(mention.roles.contains(.recordedRead))
        let attachment = try XCTUnwrap(snapshot.resources.first { $0.location == missing.path })
        XCTAssertTrue(attachment.roles.contains(.supplied))
        XCTAssertEqual(attachment.availability, .missing)
    }

    func testExplicitProvidedFilesSectionPreservesAbsolutePathWithSpaces() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let document = f.base.appendingPathComponent("user supplied document.pdf")
        try Data("synthetic document bytes".utf8).write(to: document)
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("user", "Files:\n- \"\(document.path)\"")])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let provided = try XCTUnwrap(snapshot.resources.first { $0.location == document.path })
        XCTAssertTrue(provided.roles.contains(.supplied))
        XCTAssertEqual(provided.availability, .accessible)
    }

    func testProvidedEmbeddedImageOpensFromItsExactHistoricalMessageBytes() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6rEAAAAAASUVORK5CYII="
        let expected = try XCTUnwrap(Data(base64Encoded: encoded))
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.message("user", "This image was supplied with the request.", extra: [["type": "input_image", "image_url": "data:image/png;base64," + encoded]])
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let image = try XCTUnwrap(snapshot.resources.first { $0.roles.contains(.supplied) && $0.location.hasPrefix("trace:") })
        XCTAssertEqual(image.availability, .accessible)
        let originID = try XCTUnwrap(image.eventIDs.first)
        let origin = try XCTUnwrap(snapshot.events.first { $0.id == originID })
        XCTAssertEqual(origin.kind, .user)
        let detail = try await engine.detail(for: origin)
        let decoded = try EmbeddedResource.decodeImage(resource: image, detail: detail)
        XCTAssertEqual(decoded, expected)
        XCTAssertFalse(snapshot.coverage.contains { $0.category == "pièce jointe indisponible" && $0.source == image.location })
    }

    func testArchivedHistoryAndEngineRestartKeepStableEventIDs() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.rollout(Fixture.root, cwd: f.first, archived: true, records: [f.message("user", "Historical archived request"), f.message("assistant", "Historical response")])
        let firstEngine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let catalog = try await firstEngine.catalog()
        XCTAssertTrue(catalog.contains { $0.id == Fixture.root })
        let first = try await firstEngine.open(id: Fixture.root)
        let secondEngine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let reopened = try await secondEngine.open(id: Fixture.root)
        XCTAssertEqual(first.events.map(\.id), reopened.events.map(\.id))
        XCTAssertEqual(first.events.count, 2)
    }

    func testChangedRecordedBytesCannotMasqueradeAsSelectedHistoricalEvent() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("assistant", "first recorded message")])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let selected = try XCTUnwrap(snapshot.events.first { $0.kind == .assistant })
        let replacement = try f.data(f.message("assistant", "later modified message"))
        XCTAssertEqual(replacement.count, selected.source.length, "Changing only equal-length content must still invalidate historical evidence")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: selected.source.path))
        try handle.seek(toOffset: selected.source.offset)
        try handle.write(contentsOf: replacement)
        try handle.close()
        var rejected = false
        do { _ = try await engine.detail(for: selected) }
        catch { rejected = true }
        XCTAssertTrue(rejected, "An old selection must never display replacement source bytes as its original event")
    }

    func testRequestedPatchAndRecordedResultDoNotAttributeOtherCurrentFiles() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let manual = f.first.appendingPathComponent("manual.txt")
        let recorded = f.first.appendingPathComponent("recorded.txt")
        try f.file(manual, "edited separately by a person")
        try f.file(recorded, "current content differs from recorded patch")
        let patch = "*** Begin Patch\n*** Update File: recorded.txt\n@@\n-before\n+after\n*** End Patch"
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.customCall("patch-one", "apply_patch", patch),
            f.customResult("patch-one", "Success. Updated the following files:\nM recorded.txt")
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        XCTAssertTrue(snapshot.changes.contains { $0.path == recorded.path && $0.kind == .requestedPatch })
        XCTAssertTrue(snapshot.changes.contains { $0.path == recorded.path && $0.kind == .recordedResult })
        XCTAssertFalse(snapshot.changes.contains { $0.path == manual.path })
        XCTAssertFalse(snapshot.changes.contains { $0.kind == .observedChange }, "Recorded patch success alone cannot certify observed filesystem state")
    }

    func testTwoGitWorktreesKeepSameRelativeFilesAndManualDiffSeparate() async throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.git(["init", "-b", "main", f.first.path])
        try f.git(["config", "user.name", "Lens Acceptance"], at: f.first)
        try f.git(["config", "user.email", "lens@example.invalid"], at: f.first)
        try f.file(f.first.appendingPathComponent("Sources/shared.swift"), "baseline\n")
        try f.file(f.first.appendingPathComponent("manual.txt"), "baseline manual\n")
        try f.git(["add", "."], at: f.first)
        try f.git(["commit", "-m", "Synthetic test baseline"], at: f.first)
        try f.git(["worktree", "add", "-b", "independent-reader", f.second.path], at: f.first)
        try f.file(f.first.appendingPathComponent("Sources/shared.swift"), "first-worktree current content\n")
        try f.file(f.second.appendingPathComponent("Sources/shared.swift"), "second-worktree current content\n")
        try f.file(f.first.appendingPathComponent("manual.txt"), "manual change absent from the session\n")
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [
            f.call("worktree-read", "exec_command", ["cmd": "cat Sources/shared.swift", "workdir": f.second.path]),
            f.result("worktree-read", "recorded historical source")
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let service = FileService()
        let a = EnvironmentRecord(path: f.first.path)
        let b = EnvironmentRecord(path: f.second.path)
        let ai = try await service.inspect(environment: a)
        let bi = try await service.inspect(environment: b)
        XCTAssertEqual(ai.worktreePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, f.first.resolvingSymlinksInPath().path)
        XCTAssertEqual(bi.worktreePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, f.second.resolvingSymlinksInPath().path)
        XCTAssertEqual(ai.branch, "main")
        XCTAssertEqual(bi.branch, "independent-reader")
        XCTAssertEqual(ai.repositoryPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, bi.repositoryPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let aText = try await service.readText(path: f.first.appendingPathComponent("Sources/shared.swift").path)
        let bText = try await service.readText(path: f.second.appendingPathComponent("Sources/shared.swift").path)
        XCTAssertNotEqual(aText.text, bText.text)
        let current = try await service.currentDiff(environment: a)
        XCTAssertTrue(current.text.contains("manual change absent from the session"))
        XCTAssertTrue(current.reference.contains("HEAD"))
        XCTAssertFalse(snapshot.changes.contains { $0.path.hasSuffix("manual.txt") })
        let call = try XCTUnwrap(snapshot.events.first { $0.callID == "worktree-read" && $0.kind == .toolCall })
        let historical = try await engine.detail(for: call)
        XCTAssertEqual(historical.output, "recorded historical source")
        XCTAssertNotEqual(historical.output, bText.text)
    }

    func testPaginatedCompletedItemDoesNotDuplicateItsResponsesCall() async throws {
        let f = try Fixture()
        defer { f.remove() }
        var call = f.call("same-call", "exec_command", ["cmd": "pwd", "workdir": f.first.path])
        var payload = call["payload"] as! [String: Any]
        payload["id"] = "same-call"
        call["payload"] = payload
        let completed = f.event("event_msg", [
            "type": "item_completed", "thread_id": Fixture.root, "turn_id": "turn-one",
            // Native start precedes the Responses timestamp: replacement must retain its evidence.
            "started_at_ms": 1_790_762_399_000, "completed_at_ms": 1_790_762_401_200,
            "item": ["type": "CommandExecution", "id": "same-call", "command": "pwd", "cwd": f.first.path,
                     "status": "Failed", "exit_code": 7, "stdout": f.first.path + "\n", "stderr": "synthetic recorded failure",
                     "aggregated_output": f.first.path + "\n", "duration": ["secs": 1, "nanos": 200_000_000]]
        ])
        _ = try f.rollout(Fixture.root, cwd: f.first, metaExtras: ["history_mode": "paginated"], records: [
            f.context("turn-one", cwd: f.first), call, f.result("same-call", f.first.path + "\n"), completed
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let calls = snapshot.events.filter { $0.callID == "same-call" && $0.kind == .toolCall }
        XCTAssertEqual(calls.count, 1)
        let one = try XCTUnwrap(calls.first)
        XCTAssertFalse(one.supplementarySources.isEmpty, "Both representations must remain inspectable as evidence")
        XCTAssertTrue(one.isError, "Replacing a native completion with its Responses call must retain the known failure")
        let detail = try await engine.detail(for: one)
        XCTAssertTrue(detail.output.contains(f.first.path))
    }

    func testInheritedSubagentPrefixIsNotMisattributedToChild() async throws {
        let f = try Fixture()
        defer { f.remove() }
        _ = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("user", "Root-only inherited request")])
        _ = try f.rollout(Fixture.child, cwd: f.second, parent: Fixture.root, metaExtras: ["subagent_history_start_ordinal": 3], records: [
            f.event("session_meta", ["id": Fixture.root, "cwd": f.first.path, "source": "cli"]),
            f.message("user", "Root-only inherited request"),
            f.message("assistant", "Child-native action after the inherited prefix")
        ])
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        let inheritedAsChild = snapshot.events.filter { $0.agentID == Fixture.child && $0.preview.contains("Root-only inherited") }
        XCTAssertTrue(inheritedAsChild.isEmpty)
        XCTAssertTrue(snapshot.events.contains { $0.agentID == Fixture.child && $0.preview.contains("Child-native action") })
        XCTAssertEqual(snapshot.agents.first { $0.id == Fixture.child }?.parentID, Fixture.root)
    }

    func testReadOnlyDatabaseSpawnEdgeAttachesSeparateLogWithoutMetadataParent() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let root = try f.rollout(Fixture.root, cwd: f.first, records: [f.message("user", "Root request")])
        let child = try f.rollout(Fixture.child, cwd: f.second, records: [f.message("assistant", "Database-linked separate descendant")])
        let unrelated = try f.rollout(Fixture.unrelated, cwd: f.first, records: [f.message("assistant", "Same path without edge")])
        let database = f.home.appendingPathComponent("state_5.sqlite")
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads VALUES ('\(Fixture.root)', '\(root.path)');
        INSERT INTO threads VALUES ('\(Fixture.child)', '\(child.path)');
        INSERT INTO threads VALUES ('\(Fixture.unrelated)', '\(unrelated.path)');
        INSERT INTO thread_spawn_edges VALUES ('\(Fixture.root)', '\(Fixture.child)', 'completed');
        """
        try f.command("/usr/bin/sqlite3", [database.path, sql])
        let before = try Data(contentsOf: database)
        let engine = SessionEngine(home: f.home, cacheDirectory: f.cache)
        let snapshot = try await engine.open(id: Fixture.root)
        XCTAssertTrue(snapshot.agents.contains { $0.id == Fixture.child && $0.parentID == Fixture.root })
        XCTAssertFalse(snapshot.agents.contains { $0.id == Fixture.unrelated })
        XCTAssertTrue(snapshot.events.contains { $0.agentID == Fixture.child })
        XCTAssertEqual(try Data(contentsOf: database), before)
    }
}

private struct Fixture {
    static let root = "11111111-1111-4111-8111-111111111111"
    static let child = "22222222-2222-4222-8222-222222222222"
    static let fork = "33333333-3333-4333-8333-333333333333"
    static let unrelated = "44444444-4444-4444-8444-444444444444"
    let base: URL
    let home: URL
    let first: URL
    let second: URL
    let cache: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("CodexLensAcceptance-" + UUID().uuidString)
        home = base.appendingPathComponent("codex-home")
        first = base.appendingPathComponent("worktree A")
        second = base.appendingPathComponent("worktree B")
        cache = base.appendingPathComponent("lens-cache")
        for directory in [home, first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func file(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    func data(_ record: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) }
    func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    func git(_ arguments: [String], at directory: URL? = nil) throws {
        try command("/usr/bin/git", arguments, at: directory)
    }
    func command(_ executable: String, _ arguments: [String], at directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? base
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SyntheticFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
        }
    }
    func event(_ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["timestamp": "2026-09-30T10:00:00.000Z", "type": type, "payload": payload]
    }
    func context(_ id: String, cwd: URL) -> [String: Any] { event("turn_context", ["turn_id": id, "cwd": cwd.path]) }
    func message(_ role: String, _ text: String, extra: [[String: Any]] = []) -> [String: Any] {
        event("response_item", ["type": "message", "role": role, "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]] + extra])
    }
    func call(_ id: String, _ name: String, _ arguments: [String: Any]) -> [String: Any] {
        event("response_item", ["type": "function_call", "call_id": id, "name": name, "namespace": name == "spawn_agent" ? "agents" : "functions", "arguments": String(data: try! data(arguments), encoding: .utf8)!])
    }
    func result(_ id: String, _ output: String) -> [String: Any] { event("response_item", ["type": "function_call_output", "call_id": id, "output": output]) }
    func customCall(_ id: String, _ name: String, _ input: String) -> [String: Any] {
        event("response_item", ["type": "custom_tool_call", "call_id": id, "name": name, "input": input])
    }
    func customResult(_ id: String, _ output: String) -> [String: Any] { event("response_item", ["type": "custom_tool_call_output", "call_id": id, "output": output]) }
    @discardableResult func rollout(_ id: String, cwd: URL, parent: String? = nil, oldParent: String? = nil, fork: String? = nil, archived: Bool = false, metaExtras: [String: Any] = [:], records: [[String: Any]]) throws -> URL {
        let folder = home.appendingPathComponent(archived ? "archived_sessions" : "sessions/2026/09/30")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("rollout-2026-09-30T10-00-00-" + id + ".jsonl")
        var meta: [String: Any] = ["id": id, "session_id": parent ?? fork ?? id, "cwd": cwd.path, "cli_version": "0.159.2", "history_mode": "legacy", "source": "cli", "timestamp": "2026-09-30T10:00:00.000Z"]
        if let parent { meta["parent_thread_id"] = parent; meta["agent_path"] = "/root/reader" }
        if let oldParent { meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": oldParent, "depth": 1, "agent_path": "/root/legacy-reader"]]] }
        if let fork { meta["forked_from_id"] = fork }
        meta.merge(metaExtras) { _, new in new }
        var bytes = Data()
        for record in [event("session_meta", meta)] + records { bytes.append(try data(record)); bytes.append(0x0a) }
        try bytes.write(to: path)
        return path
    }
}
