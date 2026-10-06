import XCTest
@testable import LensCore

final class SessionTrendsTests: XCTestCase {
    func testEmptyProjectionHasNoInventedPeriodOrBuckets() throws {
        let projection = try SessionTrendProjection(events: [])
        XCTAssertTrue(projection.buckets.isEmpty)
        XCTAssertTrue(projection.totalCounts.isEmpty)
        XCTAssertNil(projection.recordedPeriod)
        XCTAssertNil(projection.bucketWidth)
        XCTAssertNil(projection.bucket(containing: Date()))
    }

    func testCallMirrorsResultsAndDescendantCallIDsDoNotDoubleCountCalls() throws {
        let events = [event("root-call", at: 10, kind: .toolCall, tool: "mcp__files__read", call: "shared"),
                      event("root-mirror", at: 11, kind: .toolCall, tool: "mcp__files__read", call: "shared"),
                      event("root-result", at: 12, kind: .toolResult, tool: "mcp__files__read", call: "shared"),
                      event("child-call", at: 13, agent: "child", kind: .toolCall, tool: "exec_command", call: "shared"),
                      event("child-result", at: 14, agent: "child", kind: .toolResult, tool: "exec_command", call: "shared")]
        let projection = try SessionTrendProjection(events: events)
        XCTAssertEqual(projection.totalCounts[.activity], 5, "Recorded timeline items remain distinct from logical call counts")
        XCTAssertEqual(projection.totalCounts[.toolCalls], 2)
        XCTAssertEqual(projection.totalCounts[.mcpCalls], 1)
        let root = try XCTUnwrap(projection.bucket(containing: events[0].timestamp))
        XCTAssertEqual(projection.eventIDs(for: .toolCalls, in: root.id), ["root-call", "root-mirror", "root-result"])
        XCTAssertEqual(root.count(for: .toolCalls), 1)
        XCTAssertEqual(projection.buckets.last?.cumulativeCount(for: .toolCalls), 2)
    }

    func testMCPRequiresAnExplicitQualifiedToolName() throws {
        var shell = event("shell", at: 10, kind: .toolCall, tool: "exec_command", call: "shell")
        shell.preview = "mcp__server__tool in a command or log is not a tool identity"
        var structured = event("structured", at: 11, kind: .toolCall, call: "structured")
        structured.trace = RecordedTraceFacts(toolObservation: RecordedToolObservationFacts(toolName: "mcp__docs__search"))
        let falseNames = ["mcp_helper", "functions.mcp__docs__search", "mcp____search", "mcp__docs__", "some_mcp__docs__search"]
        let events = [shell, structured] + falseNames.enumerated().map { event("false-\($0.offset)", at: Double(12 + $0.offset), kind: .toolCall, tool: $0.element) }
        let projection = try SessionTrendProjection(events: events)
        XCTAssertEqual(projection.totalCounts[.toolCalls], events.count)
        XCTAssertEqual(projection.totalCounts[.mcpCalls], 1)
        XCTAssertEqual(projection.buckets.flatMap { projection.eventIDs(for: .mcpCalls, in: $0.id) }, [structured.id])
    }

    func testAnonymousInvocationCannotCollideWithALiteralCallID() throws {
        let events = [event("anonymous", at: 10, kind: .toolCall, tool: "exec_command"),
                      event("named", at: 11, kind: .toolCall, tool: "exec_command", call: "event:anonymous")]
        XCTAssertEqual(try SessionTrendProjection(events: events).totalCounts[.toolCalls], 2)
    }

    func testErrorResultsAreLinkedOnceAndDoNotAddInvocations() throws {
        let call = event("call", at: 10, kind: .toolCall, tool: "exec_command", call: "c")
        var firstResult = event("error-result", at: 11, kind: .toolResult, tool: "exec_command", call: "c")
        firstResult.trace = RecordedTraceFacts(toolObservation: RecordedToolObservationFacts(exitCode: 2))
        var mirror = event("error-mirror", at: 12, kind: .error)
        mirror.relatedEventID = call.id
        let orphan = event("orphan-result", at: 14, kind: .toolResult, tool: "exec_command", call: "only-result")
        let projection = try SessionTrendProjection(events: [call, firstResult, mirror, orphan])
        XCTAssertEqual(projection.totalCounts[.toolCalls], 1)
        XCTAssertEqual(projection.totalCounts[.errors], 1)
        let bucket = try XCTUnwrap(projection.bucket(containing: firstResult.timestamp))
        XCTAssertEqual(bucket.count(for: .errors), 1)
        XCTAssertEqual(projection.eventIDs(for: .errors, in: bucket.id), [call.id, firstResult.id, mirror.id])
        XCTAssertEqual(projection.bucket(containing: call.timestamp)?.count(for: .errors), 0, "Errors are placed at the recorded error, not the call start")
    }

    func testRequestCountsKeepWorktreesAndExcludeResultsAndObservations() throws {
        let first = event("patch-one", at: 10, kind: .toolCall, tool: "apply_patch")
        let later = event("patch-two", at: 11, kind: .toolCall, tool: "apply_patch")
        let changes: [String: [ChangeRecord]] = [first.id: [change("a", event: first.id, environment: "/fixture/alpha"),
            change("a-mirror", event: first.id, environment: "/fixture/alpha"),
            change("b", event: first.id, environment: "/fixture/beta"),
            change("result", event: first.id, environment: "/fixture/alpha", kind: .recordedResult),
            change("manual", event: first.id, environment: "/fixture/alpha", kind: .observedChange),
            change("wrong-index-entry", event: "not-present", environment: "/fixture/alpha")],
            later.id: [change("later-a", event: later.id, environment: "/fixture/alpha")]]
        let projection = try SessionTrendProjection(events: [first, later], changesByEvent: changes)
        XCTAssertEqual(projection.totalCounts[.requestedFileChanges], 3)
        let bucket = try XCTUnwrap(projection.bucket(containing: first.timestamp))
        XCTAssertEqual(bucket.count(for: .requestedFileChanges), 2)
        XCTAssertEqual(projection.eventIDs(for: .requestedFileChanges, in: bucket.id), [first.id])
    }

    func testMirroredPatchRequestsShareCallIdentityButKeepAgentsAndNewCallsDistinct() throws {
        let first = event("patch-call", at: 1, kind: .toolCall, tool: "apply_patch", call: "shared")
        let mirror = event("patch-mirror", at: 3, kind: .toolCall, tool: "apply_patch", call: "shared")
        let child = event("child-patch", at: 2, agent: "child", kind: .toolCall, tool: "apply_patch", call: "shared")
        let next = event("next-patch", at: 4, kind: .toolCall, tool: "apply_patch", call: "next")
        let changes = Dictionary(uniqueKeysWithValues: [first, mirror, child, next].map {
            ($0.id, [change("change-" + $0.id, event: $0.id, environment: "/fixture/alpha")])
        })
        let mirrored = try SessionTrendProjection(events: [mirror, first], changesByEvent: changes)
        XCTAssertEqual(mirrored.totalCounts[.requestedFileChanges], 1)
        let bucket = try XCTUnwrap(mirrored.bucket(containing: first.timestamp))
        XCTAssertEqual(bucket.count(for: .requestedFileChanges), 1)
        XCTAssertEqual(Set(mirrored.eventIDs(for: .requestedFileChanges, in: bucket.id)), Set([first.id, mirror.id]))
        XCTAssertEqual(mirrored.bucket(containing: mirror.timestamp)?.count(for: .requestedFileChanges), 0)
        let descendants = try SessionTrendProjection(events: [first, mirror, child], changesByEvent: changes)
        XCTAssertEqual(descendants.totalCounts[.requestedFileChanges], 2, "The same call ID in another agent remains another request")
        let repeated = try SessionTrendProjection(events: [first, mirror, child, next], changesByEvent: changes)
        XCTAssertEqual(repeated.totalCounts[.requestedFileChanges], 3, "Another recorded call remains another request")
    }

    func testFailedCompletedItemIsPlottedAtRecordedEndWhileInvocationStaysAtStart() throws {
        var item = event("failed-item", at: 1, kind: .toolCall, tool: "exec_command", call: "failed")
        item.endTime = Date(timeIntervalSince1970: 5)
        item.trace = RecordedTraceFacts(toolObservation: RecordedToolObservationFacts(exitCode: 2, executionEvidence: [.completedItem],
            recordedStartTime: item.timestamp, recordedEndTime: item.endTime))
        let projection = try SessionTrendProjection(events: [item])
        XCTAssertEqual(projection.totalCounts[.toolCalls], 1)
        XCTAssertEqual(projection.totalCounts[.errors], 1)
        XCTAssertEqual(projection.bucket(containing: item.timestamp)?.count(for: .toolCalls), 1)
        XCTAssertEqual(projection.bucket(containing: item.timestamp)?.count(for: .errors), 0)
        let end = try XCTUnwrap(projection.bucket(containing: item.endTime!))
        XCTAssertEqual(end.count(for: .errors), 1)
        XCTAssertEqual(projection.eventIDs(for: .errors, in: end.id), [item.id])
        XCTAssertEqual(projection.recordedPeriod?.upperBound, item.endTime)
        item.endTime = nil; item.trace?.toolObservation?.recordedEndTime = nil
        let missingEnd = try SessionTrendProjection(events: [item])
        XCTAssertEqual(missingEnd.unplottedCounts[.errors], 1, "A recorded start cannot date an undated completion failure")
        XCTAssertEqual(missingEnd.buckets.last?.cumulativeCount(for: .errors), 0)
    }

    func testExplicitErrorOutputTimeTakesPriorityOverAggregatedInvocationFlag() throws {
        var invocation = event("aggregate", at: 1, kind: .toolCall, tool: "exec_command", call: "c")
        invocation.isError = true; invocation.endTime = Date(timeIntervalSince1970: 4)
        invocation.trace = RecordedTraceFacts(toolObservation: RecordedToolObservationFacts(exitCode: 1, executionEvidence: [.completedItem]))
        var output = event("output", at: 5, kind: .toolResult, tool: "exec_command", call: "c")
        output.isError = true
        let projection = try SessionTrendProjection(events: [invocation, output])
        XCTAssertEqual(projection.totalCounts[.errors], 1)
        XCTAssertEqual(projection.bucket(containing: invocation.endTime!)?.count(for: .errors), 0)
        let bucket = try XCTUnwrap(projection.bucket(containing: output.timestamp))
        XCTAssertEqual(bucket.count(for: .errors), 1)
        XCTAssertEqual(Set(projection.eventIDs(for: .errors, in: bucket.id)), Set([invocation.id, output.id]))
    }

    func testWaitMirrorsAndStandaloneWaitsRemainObservations() throws {
        let events = [event("wait", at: 10, kind: .wait, tool: "wait_agent", call: "w"),
                      event("wait-mirror", at: 11, kind: .wait, tool: "wait_agent", call: "w"),
                      event("wait-result", at: 12, kind: .toolResult, tool: "wait_agent", call: "w"),
                      event("standalone-wait", at: 13, kind: .wait)]
        let projection = try SessionTrendProjection(events: events)
        XCTAssertEqual(projection.totalCounts[.waits], 2)
        XCTAssertEqual(projection.totalCounts[.toolCalls], 1)
    }

    func testCompactionsReuseCanonicalIndexAndKeepSeparateThreads() throws {
        let records = compaction(thread: "root", base: 10) + compaction(thread: "child", base: 20)
        let context = ContextInspectionIndex(events: records)
        XCTAssertEqual(context.identifiedOperationCount, 2)
        let projection = try SessionTrendProjection(events: records, contextInspection: context)
        XCTAssertEqual(projection.sourceEventCount, 2)
        XCTAssertEqual(projection.totalCounts[.activity], 2)
        XCTAssertEqual(projection.totalCounts[.compactions], 2)
        for operation in context.compactions {
            let date = operation.startTime ?? records.first { $0.id == operation.eventID }!.timestamp
            let bucket = try XCTUnwrap(projection.bucket(containing: date))
            XCTAssertEqual(Set(projection.eventIDs(for: .compactions, in: bucket.id)), Set(operation.eventIDs))
        }
    }

    func testInheritedInstructionsAndDuplicateSourceIDsFollowTimelineVisibility() throws {
        let plain = event("plain", at: 10)
        var inherited = event("inherited", at: 11, agent: "child", kind: .instruction)
        inherited.trace = RecordedTraceFacts(communication: RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded, instructionKind: .inherited))
        let projection = try SessionTrendProjection(events: [plain, plain, inherited])
        XCTAssertEqual(projection.sourceEventCount, 1)
        XCTAssertEqual(projection.totalCounts[.activity], 1)
        XCTAssertEqual(projection.buckets.flatMap { projection.eventIDs(for: .activity, in: $0.id) }, [plain.id])
    }

    func testMissingAndUnrenderableDatesStayCountedButUnplotted() throws {
        let missingCall = event("missing", kind: .toolCall, tool: "exec_command", call: "c")
        var datedResult = event("dated-result", at: 10, kind: .toolResult, call: "c")
        datedResult.isError = true
        let invalid = event("invalid", at: .infinity)
        let extreme = event("extreme", at: Double.greatestFiniteMagnitude)
        let coverage = [CoverageIssue("partial", "A descendant journal is unavailable", source: "/fixture/child")]
        let projection = try SessionTrendProjection(events: [missingCall, datedResult, invalid, extreme], coverage: coverage)
        XCTAssertEqual(projection.totalCounts[.activity], 4)
        XCTAssertEqual(projection.unplottedCounts[.activity], 3)
        XCTAssertEqual(projection.unplottedCounts[.toolCalls], 1, "A result timestamp cannot supply a missing invocation timestamp")
        XCTAssertEqual(Set(projection.unplottedEventIDs(for: .toolCalls)), Set([missingCall.id, datedResult.id]))
        XCTAssertEqual(projection.buckets.last?.cumulativeCount(for: .toolCalls), 0)
        XCTAssertEqual(projection.totalCounts[.errors], 1)
        XCTAssertEqual(projection.unknownTimestampCount, 3)
        XCTAssertEqual(projection.datedEventCount, 1)
        XCTAssertEqual(projection.coverage, coverage)
        XCTAssertEqual(projection.coverageLimitCount, 1)
        XCTAssertNil(projection.bucket(containing: invalid.timestamp))
        let undatedOnly = try SessionTrendProjection(events: [missingCall])
        XCTAssertTrue(undatedOnly.buckets.isEmpty)
        XCTAssertEqual(undatedOnly.totalCounts[.toolCalls], 1)
    }

    func testFractionalBoundaryIsHalfOpenAndClosedFilterDoesNotIncludeNextBin() throws {
        let events = [event("first", at: 0.25), event("edge", at: 1), event("second", at: 1.5), event("last", at: 2)]
        let projection = try SessionTrendProjection(events: events)
        XCTAssertEqual(projection.bucketWidth, 1)
        XCTAssertEqual(projection.buckets.map { $0.count(for: .activity) }, [1, 2, 1])
        let first = try XCTUnwrap(projection.buckets.first)
        XCTAssertTrue(first.period.contains(events[0].timestamp))
        XCTAssertFalse(first.period.contains(events[1].timestamp))
        XCTAssertEqual(projection.bucket(containing: first.end)?.id, projection.buckets[1].id)
        XCTAssertNil(projection.bucket(containing: projection.buckets.last!.end))
    }

    func testAppendAndEarlierArrivalKeepUTCIdentitiesAtUnchangedResolution() throws {
        let events = [event("one", at: 10.25), event("two", at: 12.25)]
        let before = try SessionTrendProjection(events: events)
        let after = try SessionTrendProjection(events: events + [event("three", at: 13.25), event("earlier", at: 9.25)])
        XCTAssertEqual(before.bucketWidth, after.bucketWidth)
        for bucket in before.buckets {
            XCTAssertEqual(after.bucket(id: bucket.id)?.start, bucket.start)
            XCTAssertEqual(after.bucket(id: bucket.id)?.count(for: .activity), bucket.count(for: .activity))
        }
        XCTAssertEqual(before.buckets[1].count(for: .activity), 0)
        XCTAssertEqual(before.buckets[1].cumulativeCount(for: .activity), 1)
    }

    func testLongGapsAndAdversarialCapsRemainBoundedWithoutDroppingSourceIDs() throws {
        let events = (0..<20_000).map { event("e-\($0)", at: Double($0) * 86_400) }
        let projection = try SessionTrendProjection(events: events, maxBucketCount: 32)
        XCTAssertLessThanOrEqual(projection.buckets.count, 32)
        XCTAssertEqual(projection.totalCounts[.activity], events.count)
        XCTAssertEqual(projection.buckets.last?.cumulativeCount(for: .activity), events.count)
        XCTAssertEqual(Set(projection.buckets.flatMap { projection.eventIDs(for: .activity, in: $0.id) }), Set(events.map(\.id)))
        let gaps = try SessionTrendProjection(events: [event("start", at: 0), event("tail", at: 315_360_000)], maxBucketCount: 32)
        XCTAssertLessThanOrEqual(gaps.buckets.count, 32)
        XCTAssertTrue(gaps.buckets.dropFirst().dropLast().contains { $0.count(for: .activity) == 0 })
        let epoch = try SessionTrendProjection(events: [event("before", at: -1), event("after", at: 1)], maxBucketCount: 0)
        XCTAssertEqual(epoch.buckets.count, 2)
    }

    func testInputOrderingDoesNotChangeCallDatesCountsOrDrilldown() throws {
        let events = [event("late-mirror", at: 13, kind: .toolCall, tool: "exec_command", call: "c"),
                      event("result", at: 14, kind: .toolResult, call: "c"),
                      event("call", at: 10, kind: .toolCall, tool: "exec_command", call: "c")]
        let left = try SessionTrendProjection(events: events), right = try SessionTrendProjection(events: Array(events.reversed()))
        XCTAssertEqual(left.buckets.map(\.id), right.buckets.map(\.id))
        XCTAssertEqual(left.totalCounts, right.totalCounts)
        for bucket in left.buckets {
            XCTAssertEqual(bucket.counts, right.bucket(id: bucket.id)?.counts)
            XCTAssertEqual(left.eventIDs(for: .toolCalls, in: bucket.id), right.eventIDs(for: .toolCalls, in: bucket.id))
        }
    }

    func testCancelledPreparationCannotPublishAProjection() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SessionTrendProjection(events: [event("recorded", at: 10)])
        }
        do { _ = try await task.value; XCTFail("Cancelled work must not prepare stale chart metadata") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func event(_ id: String, at seconds: TimeInterval? = nil, agent: String = "root", kind: EventKind = .assistant,
                       tool: String? = nil, call: String? = nil) -> LensEvent {
        LensEvent(id: id, timestamp: seconds.map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
                  agentID: agent, kind: kind, toolName: tool, callID: call, source: SourceRef(path: "/fixture/\(agent).jsonl"))
    }
    private func change(_ id: String, event: String, environment: String, kind: ChangeKind = .requestedPatch) -> ChangeRecord {
        ChangeRecord(id: id, path: "src/Same.swift", environmentID: environment, agentID: "root", eventID: event, kind: kind)
    }
    private func compaction(thread: String, base: Int) -> [LensEvent] {
        [CompactionEvidencePhase.started, .checkpoint, .completed].enumerated().map { offset, phase in
            var value = event("\(thread)-\(phase.rawValue)", at: Double(base + offset), agent: thread, kind: .compaction)
            value.source.offset = UInt64(offset); value.source.line = offset + 1
            value.trace = RecordedTraceFacts(compaction: RecordedCompactionFacts(phase: phase, threadID: thread, turnID: "turn",
                itemID: phase == .checkpoint ? nil : "shared-operation", windowID: phase == .checkpoint ? "window" : nil,
                visibility: .opaque, opaqueItemCount: phase == .checkpoint ? 1 : 0))
            return value
        }
    }
}
