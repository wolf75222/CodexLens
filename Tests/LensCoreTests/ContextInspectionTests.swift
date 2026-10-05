import XCTest
@testable import LensCore

final class ContextInspectionTests: XCTestCase {
    func testSparseContextDoesNotSkipUsageOrSameSourceFollowingAction() {
        var unrelated = (0..<1024).map { offset in event("other-\(offset)", offset, [:], thread: "other") }
        let records = [usage("before", 0, total: 100, last: 10), lifecycle("start", 1, itemID: "op"), checkpoint("check", 2), lifecycle("end", 3, itemID: "op", completed: true)]
        var action = event("local-action", 5, [:]); action.kind = .toolCall
        unrelated.append(contentsOf: records.reversed())
        unrelated.append(action)
        unrelated.append(usage("after", 4, total: 200, last: 20))
        let index = ContextInspectionIndex(events: unrelated)
        XCTAssertEqual(index.compactions.count, 1)
        XCTAssertEqual(index.compactions.first?.beforeUsage?.eventID, "before")
        XCTAssertEqual(index.compactions.first?.afterUsage?.eventID, "after")
        XCTAssertEqual(index.compactions.first?.firstFollowingActionIDs, ["local-action"])
        XCTAssertEqual(Set(index.usageSamples.map(\.eventID)), ["before", "after"])
    }
    func testIndexedNeighborsStayInRecordedThreadAndSourceAcrossManyCompactions() throws {
        var records: [LensEvent] = []
        for number in 0..<32 {
            let base = number * 10, turn = "turn-\(number)", operation = "op-\(number)"
            records += [usage("before-\(number)", base, total: base + 100, last: 10),
                lifecycle("start-\(number)", base + 1, itemID: operation, turn: turn),
                checkpoint("checkpoint-\(number)", base + 2, window: "window-\(number)", turn: turn, opaque: "opaque-\(number)"),
                lifecycle("end-\(number)", base + 3, itemID: operation, completed: true, turn: turn),
                usage("after-\(number)", base + 4, total: base + 200, last: 20)]
            var action = event("action-\(number)", base + 5, [:]); action.kind = .toolCall
            records.append(action)
            var otherSource = usage("other-source-\(number)", base + 2, total: 999, last: 99)
            otherSource.source = SourceRef(path: "/fixture/another.jsonl", offset: UInt64(base + 2), length: 1, line: base + 3)
            records.append(otherSource)
            var otherThread = event("other-thread-\(number)", base + 4, [:], thread: "child"); otherThread.kind = .toolCall
            otherThread.source = SourceRef(path: "/fixture/root.jsonl", offset: UInt64(base + 4), length: 1, line: base + 5)
            records.append(otherThread)
        }
        let index = ContextInspectionIndex(events: Array(records.reversed()))
        XCTAssertEqual(index.compactions.count, 32)
        for number in 0..<32 {
            let compaction = try XCTUnwrap(index.compactions.first { $0.eventID == "checkpoint-\(number)" })
            XCTAssertEqual(compaction.beforeUsage?.eventID, "before-\(number)")
            XCTAssertEqual(compaction.afterUsage?.eventID, "after-\(number)")
            XCTAssertEqual(compaction.firstFollowingActionIDs, ["action-\(number)"])
        }
    }
    func testIndexedNeighborsKeepMissingEndsAndDoNotSubstituteOtherSource() {
        var other = usage("other-only", 50, total: 100, last: 10)
        other.source = SourceRef(path: "/fixture/other.jsonl", offset: 50, length: 1, line: 51)
        let index = ContextInspectionIndex(events: [checkpoint("terminal", 1), other])
        XCTAssertNil(index.compactions.first?.beforeUsage)
        XCTAssertNil(index.compactions.first?.afterUsage)
        XCTAssertEqual(index.compactions.first?.firstFollowingActionIDs, [])
    }
    func testNoContextFactsProducesEmptyIndexButLateUsageStillAppears() {
        var records = (0..<1024).map { event("plain-\($0)", $0, [:]) }
        let empty = ContextInspectionIndex(events: records)
        XCTAssertTrue(empty.compactions.isEmpty); XCTAssertTrue(empty.usageSamples.isEmpty)
        records.append(usage("late", 2000, total: 4000, last: 200))
        let next = ContextInspectionIndex(events: records)
        XCTAssertEqual(next.usageSamples.map(\.eventID), ["late"])
        XCTAssertTrue(next.compactions.isEmpty)
    }
    private func event(_ id: String, _ offset: Int, _ root: [String: Any], thread: String = "root", turn: String = "turn") -> LensEvent {
        var value = LensEvent(id: id, timestamp: Date(timeIntervalSince1970: Double(1_000 + offset)), agentID: thread,
                              turnID: turn, kind: .context, source: SourceRef(path: "/fixture/\(thread).jsonl", offset: UInt64(offset), length: 1, line: offset + 1))
        value.trace = RecordedTraceFacts(compaction: RecordedCompactionFacts.decode(root, event: value), usage: RecordedUsageFacts.decode(root, event: value))
        return value
    }
    private func lifecycle(_ id: String, _ offset: Int, itemID: String, completed: Bool = false, thread: String = "root", turn: String = "turn", time: Int? = nil) -> LensEvent {
        var payload: [String: Any] = ["type": completed ? "item_completed" : "item_started", "thread_id": thread,
                                     "turn_id": turn, "item": ["type": "ContextCompaction", "id": itemID]]
        if let time { payload[completed ? "completed_at_ms" : "started_at_ms"] = time }
        return event(id, offset, ["type": "event_msg", "payload": payload], thread: thread, turn: turn)
    }
    private func checkpoint(_ id: String, _ offset: Int, window: String = "window", thread: String = "root", turn: String = "turn", opaque: String? = "opaque", text: String = "") -> LensEvent {
        let history: [[String: Any]] = opaque.map { [["type": "compaction", "id": "cmp-\($0)", "encrypted_content": $0]] } ?? []
        return event(id, offset, ["type": "compacted", "payload": ["message": text, "window_id": window,
                                                                    "replacement_history": history]], thread: thread, turn: turn)
    }
    private func counts(_ total: Int, input: Int = 0, output: Int = 0) -> [String: Any] {
        ["total_tokens": total, "input_tokens": input, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
         "output_tokens": output, "reasoning_output_tokens": 0]
    }
    private func usage(_ id: String, _ offset: Int, total: Int, last: Int, input: Int = 0, output: Int = 0) -> LensEvent {
        event(id, offset, ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": counts(total, input: total),
                                                                                                 "last_token_usage": counts(last, input: input, output: output), "model_context_window": 128_000]]])
    }

    func testOpaqueCheckpointKeepsAvailabilityAndDoesNotStoreEncryptedBytes() throws {
        let value = checkpoint("checkpoint", 1)
        let facts = try XCTUnwrap(value.trace?.compaction)
        XCTAssertEqual(facts.visibility, .opaque)
        XCTAssertEqual(facts.opaqueItemIDs, ["cmp-opaque"])
        XCTAssertFalse(facts.readableTextPresent)
        let encoded = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        XCTAssertFalse(encoded.contains("encrypted_content"))
        XCTAssertFalse(encoded.contains("replacement_history"))
        XCTAssertTrue(facts.limits.contains { $0.contains("does not prove forgetting") })
    }

    func testCanonicalCheckpointAndUniqueSourceOrderDeduplication() throws {
        let events = [lifecycle("start", 0, itemID: "op", time: 1_000), checkpoint("checkpoint", 1),
                      lifecycle("end", 2, itemID: "op", completed: true, time: 3_000)]
        let index = ContextInspectionIndex(events: events)
        let op = try XCTUnwrap(index.compactions.first)
        XCTAssertEqual(index.compactions.count, 1)
        XCTAssertEqual(index.identifiedOperationCount, 1)
        XCTAssertEqual(op.eventID, "checkpoint")
        XCTAssertEqual(op.eventIDs, ["start", "checkpoint", "end"])
        XCTAssertEqual(op.association, .sourceOrderCorrelation)
        XCTAssertEqual(op.startTime, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(op.endTime, Date(timeIntervalSince1970: 3))
        XCTAssertTrue(op.isInstalled)
        XCTAssertEqual(index.compactionByEventID["start"]?.id, op.id)
    }

    func testCompletionOnlyNeverInventsStartOrZeroDuration() throws {
        let value = lifecycle("end", 0, itemID: "op", completed: true, time: 3_000)
        let op = try XCTUnwrap(ContextInspectionIndex(events: [value]).compactions.first)
        XCTAssertNil(op.startTime)
        XCTAssertNotNil(op.endTime)
        XCTAssertTrue(op.limits.contains { $0.contains("duration is unknown") })
        let legacy = lifecycle("end", 0, itemID: "op", completed: true, time: 0)
        XCTAssertNil(ContextInspectionIndex(events: [legacy]).compactions.first?.endTime)
    }

    func testMultipleCompactionsInSameTurnStayDistinct() {
        let events = [lifecycle("a-start", 0, itemID: "a"), checkpoint("a-check", 1, window: "a"), lifecycle("a-end", 2, itemID: "a", completed: true),
                      lifecycle("b-start", 3, itemID: "b"), checkpoint("b-check", 4, window: "b"), lifecycle("b-end", 5, itemID: "b", completed: true)]
        let index = ContextInspectionIndex(events: events)
        XCTAssertEqual(index.compactions.count, 2)
        XCTAssertEqual(index.installedCompactionCount, 2)
        XCTAssertNotEqual(index.compactionByEventID["a-start"]?.id, index.compactionByEventID["b-start"]?.id)
    }

    func testSameItemIDInDifferentThreadsNeverMerges() {
        let values = [lifecycle("parent", 0, itemID: "same"), lifecycle("child", 1, itemID: "same", thread: "child")]
        XCTAssertEqual(ContextInspectionIndex(events: values).compactions.count, 2)
    }

    func testParentHookSessionDoesNotReplaceChildIdentity() throws {
        let value = event("hook", 0, ["hook_event_name": "PreCompact", "session_id": "parent", "agent_id": "child", "turn_id": "child-turn", "trigger": "auto"], thread: "parent")
        let facts = try XCTUnwrap(value.trace?.compaction)
        XCTAssertEqual(facts.threadID, "child")
        XCTAssertEqual(facts.hookSessionID, "parent")
        XCTAssertEqual(facts.trigger, "auto")
        let index = ContextInspectionIndex(events: [value])
        XCTAssertEqual(index.identifiedOperationCount, 0)
        XCTAssertEqual(index.compactions.first?.association, .unassociated)
    }

    func testHookRunSummaryDoesNotInventUnrecordedTrigger() throws {
        let value = event("hook", 0, ["type": "event_msg", "payload": ["type": "hook_completed", "turn_id": "turn",
                                                                      "run": ["id": "handler", "event_name": "post_compact", "status": "completed"]]])
        XCTAssertNil(try XCTUnwrap(value.trace?.compaction).trigger)
        XCTAssertEqual(value.trace?.compaction?.phase, .postHook)
    }

    func testDuplicateCheckpointAndLegacyMirrorDoNotCountTwice() {
        let legacy = event("legacy", 2, ["type": "event_msg", "payload": ["type": "context_compacted"]])
        let events = [lifecycle("start", 0, itemID: "op"), checkpoint("check", 1), legacy,
                      lifecycle("end", 3, itemID: "op", completed: true), checkpoint("duplicate", 4)]
        let index = ContextInspectionIndex(events: events)
        XCTAssertEqual(index.compactions.count, 1)
        XCTAssertEqual(index.identifiedOperationCount, 1)
        XCTAssertEqual(Set(index.compactions[0].eventIDs), Set(events.map(\.id)))
    }

    func testCarriedOpaqueRepresentationDoesNotCreateOrExtendOperation() throws {
        let carried = event("carried", 5, ["type": "response_item", "payload": ["type": "compaction", "id": "cmp-opaque", "encrypted_content": "opaque"]])
        var action = event("following", 4, [:]); action.kind = .toolCall
        let events = [lifecycle("start", 0, itemID: "op"), checkpoint("check", 1), lifecycle("end", 3, itemID: "op", completed: true), action, carried]
        let index = ContextInspectionIndex(events: events)
        XCTAssertEqual(index.compactions.count, 1)
        XCTAssertEqual(index.compactions[0].firstFollowingActionIDs, ["following"])
        XCTAssertEqual(index.compactionByEventID["carried"]?.id, index.compactions[0].id)
        XCTAssertEqual(ContextInspectionIndex(events: [carried]).identifiedOperationCount, 0)
    }

    func testCumulativeSnapshotIsNotAddedAndAfterEstimateHasSeparateSemantics() throws {
        let values = [usage("before", 0, total: 20_000, last: 15_000, input: 14_000, output: 1_000),
                      lifecycle("start", 1, itemID: "op"), checkpoint("check", 2),
                      usage("after", 3, total: 21_000, last: 2_000), lifecycle("end", 4, itemID: "op", completed: true)]
        let index = ContextInspectionIndex(events: values)
        XCTAssertEqual(index.usageSamples.count, 2)
        XCTAssertEqual(index.usageSamples[0].semantics, .cumulativeAndLastRequest)
        XCTAssertEqual(index.usageSamples[1].semantics, .renderedContextEstimate)
        XCTAssertEqual(index.compactions[0].beforeUsage?.facts.cumulative?.total, 20_000)
        XCTAssertEqual(index.compactions[0].afterUsage?.facts.cumulative?.total, 21_000)
        XCTAssertEqual(index.compactions[0].afterUsage?.facts.last?.total, 2_000)
        XCTAssertEqual(ContextInspectionIndex(events: [usage("unknown", 0, total: 20_000, last: 2_000)]).usageSamples[0].semantics, .unknown)
    }

    func testProviderResponseRecordDeduplicatesAndCheckpointCopyIsIgnored() throws {
        let payload: [String: Any] = ["thread_id": "root", "turn_id": "turn", "response_id": "response",
                                     "usage": counts(100, input: 80, output: 20), "thread_token_usage": counts(1_000, input: 1_000)]
        let first = event("first", 0, ["type": "token_usage_record", "payload": payload])
        let duplicate = event("duplicate", 1, ["type": "token_usage_record", "payload": payload])
        let copy = event("checkpoint", 2, ["type": "compacted", "payload": ["message": "", "latest_token_usage_record": payload]])
        XCTAssertNil(copy.trace?.usage)
        let index = ContextInspectionIndex(events: [first, duplicate, copy])
        XCTAssertEqual(index.usageSamples.count, 1)
        XCTAssertEqual(index.usageSamples[0].sourceRefs.count, 2)
        XCTAssertEqual(index.usageSamples[0].facts.request?.total, 100)
        XCTAssertEqual(index.usageSamples[0].semantics, .providerRequest)
    }

    func testAppServerCamelCaseFieldsAndMissingCapacity() throws {
        let value = event("item", 0, ["method": "item/completed", "params": ["threadId": "child", "turnId": "turn", "completedAtMs": 5_000,
                                                                           "item": ["type": "contextCompaction", "id": "op"]]])
        XCTAssertEqual(value.trace?.compaction?.threadID, "child")
        XCTAssertEqual(value.trace?.compaction?.endTime, Date(timeIntervalSince1970: 5))
        let usageEvent = event("usage", 1, ["method": "thread/tokenUsage/updated", "params": ["threadId": "child", "turnId": "turn", "tokenUsage": ["total": ["totalTokens": 7], "last": ["inputTokens": 5, "totalTokens": 5]]]])
        XCTAssertEqual(usageEvent.trace?.usage?.cumulative?.total, 7)
        XCTAssertNil(usageEvent.trace?.usage?.modelContextWindow)
    }

    func testMissingReplacementAndMalformedMetadataStayVisible() throws {
        let missing = event("missing", 0, ["type": "compacted", "payload": ["message": ""]])
        XCTAssertEqual(missing.trace?.compaction?.visibility, .unavailable)
        XCTAssertFalse(try XCTUnwrap(missing.trace?.compaction).replacementHistoryPresent)
        let malformed = event("malformed", 1, ["type": "compacted", "payload": ["message": "readable", "replacement_history": [], "replacement_history_metadata": [[:]]]])
        XCTAssertTrue(try XCTUnwrap(malformed.trace?.compaction).limits.contains { $0.contains("counts differ") })
        XCTAssertEqual(malformed.trace?.compaction?.visibility, .readableText)
    }

    func testStableOperationIdentityAfterNewFollowingActivity() throws {
        let records = [lifecycle("start", 0, itemID: "op"), checkpoint("check", 1), lifecycle("end", 2, itemID: "op", completed: true)]
        var following = event("next", 3, [:]); following.kind = .toolCall
        XCTAssertEqual(ContextInspectionIndex(events: records).compactions.first?.id,
                       ContextInspectionIndex(events: records + [following]).compactions.first?.id)
    }

    func testHookAndLegacyAdjacentBoundariesAreCorrelationsAndNotExtraOperations() throws {
        let pre = event("pre", 0, ["type": "event_msg", "payload": ["type": "hook_completed", "turn_id": "turn", "run": ["id": "pre-handler", "event_name": "pre_compact"]]])
        let post = event("post", 4, ["type": "event_msg", "payload": ["type": "hook_completed", "turn_id": "turn", "run": ["id": "post-handler", "event_name": "post_compact"]]])
        let legacy = event("legacy", 5, ["type": "event_msg", "payload": ["type": "context_compacted"]])
        let records = [pre, lifecycle("start", 1, itemID: "op"), checkpoint("check", 2), lifecycle("end", 3, itemID: "op", completed: true), post, legacy]
        let index = ContextInspectionIndex(events: records)
        XCTAssertEqual(index.compactions.count, 1)
        XCTAssertEqual(index.identifiedOperationCount, 1)
        XCTAssertEqual(index.compactions[0].association, .sourceOrderCorrelation)
        XCTAssertEqual(Set(index.compactions[0].eventIDs), Set(records.map(\.id)))
    }

    func testAmbiguousCheckpointIsVisibleWithoutAnExtraCountedMirror() {
        let records = [lifecycle("a-start", 0, itemID: "a"), lifecycle("b-start", 1, itemID: "b"),
                       checkpoint("ambiguous", 2), lifecycle("a-end", 3, itemID: "a", completed: true), lifecycle("b-end", 4, itemID: "b", completed: true)]
        let index = ContextInspectionIndex(events: records)
        XCTAssertEqual(index.compactions.count, 3)
        XCTAssertEqual(index.identifiedOperationCount, 2)
        XCTAssertEqual(index.compactionByEventID["ambiguous"]?.association, .unassociated)
        XCTAssertEqual(index.compactionByEventID["ambiguous"]?.isCountedOperation, false)
        XCTAssertEqual(index.installedCompactionCount, 1)
    }

    func testSourceOrderNotClockOrderLinksCheckpointAndFollowingAction() {
        var start = lifecycle("start", 1, itemID: "op")
        var marker = checkpoint("check", 2)
        var end = lifecycle("end", 3, itemID: "op", completed: true)
        var action = event("action", 4, [:]); action.kind = .toolCall
        start.timestamp = Date(timeIntervalSince1970: 4_000)
        marker.timestamp = Date(timeIntervalSince1970: 2_000)
        end.timestamp = Date(timeIntervalSince1970: 1_000)
        let index = ContextInspectionIndex(events: [end, marker, action, start])
        XCTAssertEqual(index.compactions.count, 1)
        XCTAssertEqual(index.compactions[0].eventID, "check")
        XCTAssertEqual(index.compactions[0].firstFollowingActionIDs, ["action"])
        XCTAssertNil(index.compactions[0].startTime)
        XCTAssertNil(index.compactions[0].endTime)
    }

    func testIncoherentBoundsAndConflictingTriggersRemainUnknown() throws {
        var start = lifecycle("start", 0, itemID: "op", time: 9_000)
        var end = lifecycle("end", 2, itemID: "op", completed: true, time: 5_000)
        start.trace?.compaction?.trigger = "manual"
        end.trace?.compaction?.trigger = "auto"
        let op = try XCTUnwrap(ContextInspectionIndex(events: [start, checkpoint("check", 1), end]).compactions.first)
        XCTAssertNil(op.duration)
        XCTAssertNil(op.trigger)
        XCTAssertTrue(op.limits.contains { $0.contains("precedes start") })
        XCTAssertTrue(op.limits.contains { $0.contains("trigger sources disagree") })
    }
}
