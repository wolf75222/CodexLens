import XCTest
@testable import LensCore

final class SessionPresentationTests: XCTestCase {
    func testPublishedGenerationIsBoundedAndInvalidatedOnClose() async throws {
        let builder = SessionPresentationBuilder()
        var snapshot = LensDemoFixtures.snapshot(eventCount: 24)
        let first = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        await builder.didPublish(first, sequence: 1)
        snapshot.events[0].preview = "New evidence"
        let second = try await builder.prepare(snapshot: snapshot, revision: 2, filters: EventFilters())
        let retainedWhilePreparing = await builder.publishedPresentationID
        XCTAssertEqual(retainedWhilePreparing, first.id)
        await builder.didPublish(second, sequence: 3)
        await builder.didPublish(first, sequence: 2)
        let latest = await builder.publishedPresentationID
        XCTAssertEqual(latest, second.id, "A stale acknowledgement cannot retain an old generation")
        await builder.invalidateCache()
        let closed = await builder.publishedPresentationID
        XCTAssertNil(closed, "Closing the window must release the retained index")
    }
    func testCancelledPublicationCannotRepopulateClosedBuilder() async throws {
        let builder = SessionPresentationBuilder()
        let presentation = try await builder.prepare(snapshot: LensDemoFixtures.snapshot(eventCount: 24), revision: 1, filters: EventFilters())
        await builder.invalidateCache()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await builder.didPublish(presentation, sequence: 1)
        }
        await task.value
        let retained = await builder.publishedPresentationID
        XCTAssertNil(retained)
    }
    func testIdenticalPresentationRequestKeepsNativeTableVersionButRevisionInvalidates() async throws {
        var fixture = LensDemoFixtures.snapshot(eventCount: 24)
        let builder = SessionPresentationBuilder()
        let first = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters())
        let repeated = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters())
        XCTAssertEqual(first.id, repeated.id, "An unchanged request should not force native table reloadData")
        fixture.events[0].preview = "Updated recorded preview"
        let changed = try await builder.prepare(snapshot: fixture, revision: 2, filters: EventFilters())
        XCTAssertNotEqual(first.id, changed.id)
        XCTAssertEqual(changed.eventsByID[fixture.events[0].id]?.preview, "Updated recorded preview")
        await builder.invalidateCache()
        let reopened = try await builder.prepare(snapshot: fixture, revision: 2, filters: EventFilters())
        XCTAssertNotEqual(changed.id, reopened.id)
    }

    func testFilterKeepsOverlappingCallAndExactWorktree() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let a = LensEvent(id: "a", timestamp: start, endTime: start.addingTimeInterval(100), agentID: "agent", kind: .toolCall, environmentID: "/fixture/A", source: SourceRef(path: "/fixture/trace"))
        let b = LensEvent(id: "b", timestamp: start.addingTimeInterval(50), agentID: "agent", kind: .toolCall, environmentID: "/fixture/B", source: a.source)
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: [a,b])
        let p = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters(environmentID: "/fixture/A", period: start.addingTimeInterval(40)...start.addingTimeInterval(60)))
        XCTAssertEqual(p.filteredEvents.map(\.id), ["a"]); XCTAssertEqual(p.eventsByID["b"], b)
    }
    func testIndexesUpdateOnStreamingRevisionAndSeparateWindows() async throws {
        let first = LensEvent(id: "same-id", agentID: "a", title: "first", source: SourceRef(path: "/fixture/a"))
        var snapshot = SessionSnapshot(root: SessionSummary(id: "A"), events: [first])
        let builder = SessionPresentationBuilder()
        let p = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(query: "first"))
        XCTAssertEqual(p.filteredEvents.count, 1)
        snapshot.events[0].title = "changed"
        let next = try await builder.prepare(snapshot: snapshot, revision: 2, filters: EventFilters(query: "changed"))
        XCTAssertEqual(next.eventsByID[first.id]?.title, "changed")
        let other = try await SessionPresentationBuilder().prepare(snapshot: SessionSnapshot(root: SessionSummary(id: "B"), events: [first]), revision: 2, filters: EventFilters())
        XCTAssertEqual(other.eventsByID[first.id]?.title, "first"); XCTAssertEqual(other.rootID, "B")
    }
    func testFullSourceMatchesAreDistinctFromPreviewSearch() async throws {
        let e = LensEvent(id: "recorded", agentID: "a", title: "unrelated preview", source: SourceRef(path: "/fixture/trace"))
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: [e])
        let builder = SessionPresentationBuilder()
        let absent = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(query: "full text"))
        let matched = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(query: "full text", sourceMatches: [e.id]))
        XCTAssertTrue(absent.filteredEvents.isEmpty); XCTAssertEqual(matched.filteredEvents.map(\.id), [e.id])
    }
    func testNativeRowIndexesKeepCallResultDistinctAfterFiltering() async throws {
        var fixture = LensDemoFixtures.snapshot(eventCount: 24)
        let builder = SessionPresentationBuilder()
        let all = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters())
        for event in all.filteredCalls {
            let row = try XCTUnwrap(all.filteredCallRowIndices[event.id])
            XCTAssertEqual(all.filteredCalls[row].id, event.id)
            XCTAssertNotEqual(event.kind, .toolResult)
        }
        let filtered = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters(environmentID: fixture.environments[1].id))
        XCTAssertNotEqual(all.id, filtered.id)
        for event in filtered.filteredEvents {
            XCTAssertEqual(filtered.filteredEvents[try XCTUnwrap(filtered.filteredEventRowIndices[event.id])].id, event.id)
            XCTAssertEqual(event.environmentID, fixture.environments[1].id)
        }
        fixture.events.removeFirst()
        let next = try await builder.prepare(snapshot: fixture, revision: 2, filters: EventFilters())
        XCTAssertEqual(next.filteredEventRowIndices[fixture.events[0].id], 0)
        XCTAssertEqual(all.filteredEventRowIndices[fixture.events[0].id], 1)
    }

    func testPreparedAgentTreeKeepsCyclesOrphansAndExactWorktreeSourceQueries() async throws {
        let firstWorktree = "/fixture/project/worktree-one", secondWorktree = "/fixture/project/worktree-two"
        let agents = [
            AgentRecord(id: "root", name: "Root"),
            AgentRecord(id: "orphan", parentID: "missing-parent", name: "Orphan", relation: .fork, mission: "Review second checkout", environmentIDs: [secondWorktree]),
            AgentRecord(id: "cycle-a", parentID: "cycle-b", name: "A", relation: .subagent, environmentIDs: [firstWorktree]),
            AgentRecord(id: "cycle-b", parentID: "cycle-a", name: "B", relation: .subagent, environmentIDs: [secondWorktree])
        ]
        let first = LensEvent(id: "one", agentID: "cycle-a", title: "read shared.swift", environmentID: firstWorktree, source: SourceRef(path: "/fixture/a"))
        let second = LensEvent(id: "two", agentID: "cycle-b", title: "read shared.swift", environmentID: secondWorktree, source: SourceRef(path: "/fixture/b"))
        let orphan = LensEvent(id: "orphan-event", agentID: "orphan", source: SourceRef(path: "/fixture/orphan"))
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), agents: agents, events: [first, second, orphan])
        let builder = SessionPresentationBuilder()
        let all = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        XCTAssertEqual(all.agentRows.map { $0.0.id }, ["root", "orphan", "cycle-a", "cycle-b"])
        XCTAssertEqual(all.agentRows.map { $0.1 }, [0, 0, 0, 1])
        XCTAssertEqual(all.agentsByID["orphan"]?.parentID, "missing-parent")
        XCTAssertEqual(all.agentsByID["orphan"]?.relation, .fork)
        XCTAssertEqual(all.agentsByID["cycle-a"]?.parentID, "cycle-b")
        XCTAssertEqual(all.eventIDsByAgent["cycle-a"], ["one"])
        XCTAssertEqual(all.eventCountByAgent["cycle-b"], 1)
        let metadata = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(query: "worktree-one"))
        XCTAssertEqual(metadata.agentRows.map { $0.0.id }, ["cycle-a"])
        let source = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(environmentID: secondWorktree, query: "recorded full output", sourceMatches: ["two"]))
        XCTAssertEqual(source.filteredEvents.map(\.id), ["two"])
        XCTAssertEqual(source.agentRows.map { $0.0.id }, ["cycle-b"])
        XCTAssertEqual(source.eventIDsByAgent["cycle-a"], ["one"], "Filtering must preserve full recorded per-agent indexes")
        XCTAssertEqual(source.eventCountByAgent["orphan"], 1)
    }

    func testRecentChangesKeepSamePathInDifferentWorktreesAndExcludeSuccessResults() async throws {
        let events = [recentEvent("alpha", at: 100), recentEvent("beta", at: 200), recentEvent("success", at: 300)]
        let changes = [
            recentChange("alpha-patch", event: "alpha", environment: "/fixture/alpha"),
            recentChange("beta-observation", event: "beta", environment: "/fixture/beta", kind: .observedChange),
            recentChange("success-result", event: "success", environment: "/fixture/beta", kind: .recordedResult)
        ]
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: events, changes: changes)
        let presentation = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        XCTAssertEqual(presentation.recentRecordedChanges.map(\.id), ["beta-observation", "alpha-patch"])
        XCTAssertEqual(presentation.recentRecordedChanges.map(\.path), ["src/Same.swift", "src/Same.swift"])
        XCTAssertEqual(presentation.recentRecordedChanges.map(\.environmentID), ["/fixture/beta", "/fixture/alpha"])
        XCTAssertNotNil(presentation.changesByID["success-result"], "A result remains inspectable without being advertised as a diff")
    }

    func testRecentChangesAdvanceOnNewRevisionWithoutActivityFilterScope() async throws {
        let builder = SessionPresentationBuilder()
        var snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: [recentEvent("old", at: 100)], changes: [recentChange("old-patch", event: "old")])
        let initial = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        snapshot.events.append(recentEvent("new", at: 200))
        snapshot.changes.append(recentChange("new-patch", event: "new", environment: "/fixture/beta"))
        let updated = try await builder.prepare(snapshot: snapshot, revision: 2, filters: EventFilters())
        XCTAssertEqual(updated.recentRecordedChanges.map(\.id), ["new-patch", "old-patch"])
        XCTAssertEqual(initial.recentRecordedChanges.map(\.id), ["old-patch"])
        let excludingFilters = EventFilters(agentID: "absent", environmentID: "/other", kind: .user, period: Date(timeIntervalSince1970: 500)...Date(timeIntervalSince1970: 600), query: "absent")
        let hidden = try await builder.prepare(snapshot: snapshot, revision: 2, filters: excludingFilters)
        XCTAssertTrue(hidden.filteredEvents.isEmpty)
        XCTAssertEqual(hidden.recentRecordedChanges, updated.recentRecordedChanges)
        for change in hidden.recentRecordedChanges { XCTAssertEqual(change, hidden.changesByID[change.id]) }
        let repeated = try await builder.prepare(snapshot: snapshot, revision: 2, filters: excludingFilters)
        XCTAssertEqual(repeated.id, hidden.id)
    }

    func testRecentChangesDeduplicateConsistentlyAndUseStableTiesWithMissingDatesLast() async throws {
        let events = [recentEvent("dated-a", at: 100), recentEvent("dated-b", at: 100), recentEvent("future-duplicate", at: 900), LensEvent(id: "undated", agentID: "root", source: SourceRef(path: "/fixture/trace"))]
        let canonical = recentChange("a", event: "dated-a", environment: "/fixture/alpha")
        let conflictingDuplicate = recentChange("a", event: "future-duplicate", environment: "/fixture/beta")
        let changes = [recentChange("z-undated", event: "undated"), recentChange("b", event: "dated-b"), canonical, conflictingDuplicate, recentChange("c-missing", event: "missing")]
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: events, changes: changes)
        let result = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        XCTAssertEqual(result.recentRecordedChanges.map(\.id), ["a", "b", "c-missing", "z-undated"])
        XCTAssertEqual(result.recentRecordedChanges.first, canonical)
        XCTAssertEqual(result.recentRecordedChanges.first, result.changesByID["a"])
        let reordered = SessionSnapshot(root: snapshot.root, events: Array(events.reversed()), changes: [canonical, conflictingDuplicate] + Array(changes.filter { $0.id != "a" }.reversed()))
        let other = try await SessionPresentationBuilder().prepare(snapshot: reordered, revision: 1, filters: EventFilters())
        XCTAssertEqual(other.recentRecordedChanges, result.recentRecordedChanges, "Dictionary enumeration and unrelated input order cannot change tied results")
    }

    func testRecentChangesKeepOnlyTwelveNewestCanonicalRecords() async throws {
        let events = (0..<1000).map { recentEvent("event-\($0)", at: TimeInterval($0)) }
        let changes = (0..<1000).map { recentChange("change-\($0)", event: "event-\($0)") }
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: events, changes: changes)
        let result = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        XCTAssertEqual(result.recentRecordedChanges.count, 12)
        XCTAssertEqual(result.recentRecordedChanges.map(\.id), (988..<1000).reversed().map { "change-\($0)" })
    }

    func testChangesOverviewFiltersBeforeGroupingAndCachesSameFilters() async throws {
        let builder = SessionPresentationBuilder()
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"),
            events: [recentEvent("alpha", at: 100), recentEvent("beta", at: 200)],
            changes: [recentChange("alpha-patch", event: "alpha"), recentChange("beta-result", event: "beta", environment: "/fixture/beta", kind: .recordedResult)])
        let all = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        XCTAssertEqual(all.changesOverview.files.count, 2)
        let filter = EventFilters(changeKind: .recordedResult)
        let result = try await builder.prepare(snapshot: snapshot, revision: 1, filters: filter)
        XCTAssertEqual(result.filteredChanges.map(\.id), ["beta-result"])
        XCTAssertEqual(result.changesOverview.groups.map(\.id), ["/fixture/beta"])
        XCTAssertEqual(result.changesOverview.traceIDs, ["beta-result"])
        let again = try await builder.prepare(snapshot: snapshot, revision: 1, filters: filter)
        XCTAssertEqual(again.id, result.id)
    }

    func testChangesOverviewCannotExposeConflictingDuplicateThroughFilter() async throws {
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"),
            events: [recentEvent("alpha", at: 100), recentEvent("beta", at: 200)],
            changes: [recentChange("same-id", event: "alpha"), recentChange("same-id", event: "beta", environment: "/fixture/beta")])
        let result = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: EventFilters(environmentID: "/fixture/beta"))
        XCTAssertTrue(result.filteredChanges.isEmpty)
        XCTAssertTrue(result.changesOverview.groups.isEmpty)
        XCTAssertEqual(result.changesByID["same-id"]?.environmentID, "/fixture/alpha")
    }

    func testChangesOverviewSearchMatchesSourceAndHonorsRecordedPeriod() async throws {
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"),
            events: [recentEvent("before", at: 100), recentEvent("inside", at: 200)],
            changes: [recentChange("old", event: "before"), recentChange("visible", event: "inside")])
        let result = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1,
            filters: EventFilters(period: Date(timeIntervalSince1970: 150)...Date(timeIntervalSince1970: 250), query: "captured output", sourceMatches: ["inside"]))
        XCTAssertEqual(result.filteredChanges.map(\.id), ["visible"])
        XCTAssertEqual(result.changesOverview.activityCount, 1)
        XCTAssertEqual(result.changesOverview.firstTimestamp, Date(timeIntervalSince1970: 200))
    }

    private func recentEvent(_ id: String, at timestamp: TimeInterval) -> LensEvent {
        LensEvent(id: id, timestamp: Date(timeIntervalSince1970: timestamp), agentID: "root", kind: .toolCall, source: SourceRef(path: "/fixture/trace"))
    }

    private func recentChange(_ id: String, event: String, environment: String = "/fixture/alpha", kind: ChangeKind = .requestedPatch) -> ChangeRecord {
        ChangeRecord(id: id, path: "src/Same.swift", environmentID: environment, agentID: "root", eventID: event, kind: kind)
    }
}
