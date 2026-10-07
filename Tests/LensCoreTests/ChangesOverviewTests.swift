import XCTest
@testable import LensCore

final class ChangesOverviewTests: XCTestCase {
    private let alpha = "/fixture/does-not-exist/worktrees/alpha"
    private let beta = "/fixture/does-not-exist/worktrees/beta"

    private func event(_ id: String, environment: String? = nil, agent: String = "root", callID: String? = nil,
                       time: Double? = 100, kind: EventKind = .toolCall) -> LensEvent {
        LensEvent(id: id, timestamp: time.map(Date.init(timeIntervalSince1970:)) ?? .distantPast,
            agentID: agent, kind: kind, toolName: "apply_patch", callID: callID, environmentID: environment,
            source: SourceRef(path: "/fixture/no-journal/" + agent + ".jsonl"))
    }
    private func change(_ id: String, event: LensEvent, environment: String? = nil, path: String = "src/Same.swift",
                        kind: ChangeKind = .requestedPatch) -> ChangeRecord {
        ChangeRecord(id: id, path: path, environmentID: environment ?? event.environmentID ?? "", agentID: event.agentID,
                     eventID: event.id, kind: kind)
    }
    private func snapshot(events: [LensEvent], changes: [ChangeRecord], environments: [EnvironmentRecord] = [],
                          resources: [ResourceRecord] = []) -> SessionSnapshot {
        SessionSnapshot(root: SessionSummary(id: "overview-fixture"), events: events, environments: environments,
                        resources: resources, changes: changes)
    }
    private func index(_ snapshot: SessionSnapshot) -> ChangesOverviewIndex {
        ChangesOverviewIndex(snapshot: snapshot,
            activity: ActivityEvidenceIndex(events: snapshot.events, changes: snapshot.changes, resources: snapshot.resources))
    }
    private func projection(_ snapshot: SessionSnapshot) -> ChangesOverviewProjection {
        index(snapshot).projection(visibleChangeIDs: Set(snapshot.changes.map(\.id)))
    }

    func testSamePathInTwoWorktreesRetainsExactEnvironmentsAndRecordedMetadata() throws {
        let a = event("alpha", environment: alpha), b = event("beta", environment: beta)
        let fixture = snapshot(events: [a, b], changes: [change("a", event: a), change("b", event: b)], environments: [
            EnvironmentRecord(path: alpha, repositoryPath: "/fixture/repository", recordedBranch: "feature/alpha", recordedRef: "recorded-alpha"),
            EnvironmentRecord(path: beta, repositoryPath: "/fixture/repository", recordedBranch: "feature/beta", recordedRef: "recorded-beta")
        ])
        let result = projection(fixture)
        XCTAssertEqual(result.groups.map(\.id), [alpha, beta])
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(Set(result.files.map(\.id)).count, 2)
        XCTAssertEqual(result.files.map(\.relativePath), ["src/Same.swift", "src/Same.swift"])
        XCTAssertEqual(result.groups.map { $0.environment.recordedBranch }, ["feature/alpha", "feature/beta"])
        XCTAssertEqual(result.groups.map { $0.environment.recordedRef }, ["recorded-alpha", "recorded-beta"])
        XCTAssertTrue(result.groups.allSatisfy { !$0.isSynthetic })
    }

    func testLexicalRelativeAndAbsolutePathsShareFileWithoutNormalizingEnvironmentIdentity() throws {
        let e = event("event", environment: alpha)
        let otherIdentity = alpha + "/."
        let other = event("other", environment: otherIdentity)
        let result = projection(snapshot(events: [e, other], changes: [
            change("relative", event: e, path: "src/./nested/../Same.swift"),
            change("absolute", event: e, path: alpha + "/src//Same.swift"),
            change("other-environment", event: other, path: alpha + "/src/Same.swift")
        ]))
        XCTAssertEqual(result.files.count, 2)
        let file = try XCTUnwrap(result.files.first { $0.environmentID == alpha })
        XCTAssertEqual(file.path, alpha + "/src/Same.swift")
        XCTAssertEqual(file.traceIDs, ["absolute", "relative"])
        XCTAssertEqual(Set(result.files.map(\.environmentID)), [alpha, otherIdentity])
        XCTAssertEqual(ChangesOverviewFileKey(environmentID: "", path: "a/../src/Same.swift").path, "src/Same.swift")
        XCTAssertEqual(ChangesOverviewFileKey(environmentID: "", path: "../src/Same.swift").path, "../src/Same.swift")
    }

    func testRequestAndLinkedResultReuseCanonicalActivityOnceAcrossFiles() throws {
        var request = event("request", environment: alpha, callID: "patch", time: 100)
        var result = event("result", environment: alpha, callID: "patch", time: 105, kind: .toolResult)
        request.relatedEventID = result.id
        result.relatedEventID = request.id
        let fixture = snapshot(events: [request, result], changes: [
            change("request-a", event: request), change("result-a", event: result, kind: .recordedResult),
            change("request-b", event: request, path: "src/B.swift"),
            change("result-b", event: result, path: "src/B.swift", kind: .recordedResult)
        ])
        let activity = ActivityEvidenceIndex(events: fixture.events, changes: fixture.changes, resources: [])
        let overview = ChangesOverviewIndex(snapshot: fixture, activity: activity)
        let projected = overview.projection(visibleChangeIDs: Set(fixture.changes.map(\.id)))
        XCTAssertEqual(projected.activityCount, 1)
        XCTAssertEqual(projected.groups[0].activities.count, 1)
        XCTAssertEqual(projected.files.map(\.activityCount), [1, 1])
        XCTAssertEqual(projected.groups[0].activities[0].canonicalActivityID, activity.fileHistories[0].activities[0].id)
        XCTAssertEqual(projected.groups[0].activities[0].traceIDs.count, 4)
        XCTAssertEqual(Set(projected.files.map { $0.activities[0].id }).count, 1)
        XCTAssertEqual(projected.firstTimestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(projected.lastTimestamp, Date(timeIntervalSince1970: 105))
        XCTAssertEqual(Set(projected.kinds), [.requestedPatch, .recordedResult])
    }

    func testSameCallIDDifferentAgentsOrEnvironmentsRemainsSeparate() {
        let events = [event("root-alpha", environment: alpha, agent: "root", callID: "shared"),
                      event("child-alpha", environment: alpha, agent: "child", callID: "shared"),
                      event("root-beta", environment: beta, agent: "root", callID: "shared")]
        let result = projection(snapshot(events: events, changes: events.map { change("change-" + $0.id, event: $0) }))
        XCTAssertEqual(result.activityCount, 3)
        XCTAssertEqual(result.groups.map(\.activityCount), [2, 1])
        XCTAssertEqual(Set(result.groups.flatMap(\.activities).map(\.id)).count, 3)
    }

    func testMissingDescriptorsEventsAndDatesRemainAvailableWithoutAnyFilesystem() throws {
        let unknown = event("undated", environment: nil, time: nil)
        let missingEvent = ChangeRecord(id: "missing-event-change", path: "src/Missing.swift", environmentID: beta,
                                        agentID: "missing-agent", eventID: "missing-event", kind: .recordedResult)
        let result = projection(snapshot(events: [unknown], changes: [change("unknown", event: unknown), missingEvent]))
        XCTAssertEqual(result.groups.map(\.id), ["", beta])
        XCTAssertTrue(result.groups.allSatisfy(\.isSynthetic))
        XCTAssertTrue(result.groups.allSatisfy { $0.environment.recordedBranch == nil && $0.environment.recordedRef == nil })
        XCTAssertEqual(result.files[0].path, "src/Same.swift", "Unknown relative paths must not acquire the process working directory")
        XCTAssertNil(result.firstTimestamp)
        XCTAssertNil(result.lastTimestamp)
        XCTAssertEqual(result.unknownTimestampCount, 2)
        XCTAssertEqual(result.activityCount, 2)
        XCTAssertEqual(result.groups[1].agentIDs, ["missing-agent"])
        XCTAssertFalse(result.groups[0].environment.evidence.isEmpty)
    }

    func testVisibleTraceFilterRunsBeforeKindsActivityCountsAndDatesAreAggregated() throws {
        let request = event("request", environment: alpha, callID: "patch", time: 100)
        let completion = event("completion", environment: alpha, callID: "patch", time: 200, kind: .toolResult)
        let hidden = event("hidden", environment: beta, time: 300)
        let undated = event("undated", environment: alpha, time: nil)
        let fixture = snapshot(events: [request, completion, hidden, undated], changes: [
            change("request", event: request), change("completion", event: completion, kind: .recordedResult),
            change("hidden", event: hidden), change("undated", event: undated, path: "src/Undated.swift")
        ])
        let overview = index(fixture)
        let result = overview.projection(visibleChangeIDs: ["request"])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.activityCount, 1)
        XCTAssertEqual(result.traceIDs, ["request"])
        XCTAssertEqual(result.eventIDs, ["request"])
        XCTAssertEqual(result.kinds, [.requestedPatch])
        XCTAssertEqual(result.firstTimestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.lastTimestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.unknownTimestampCount, 0)
        XCTAssertEqual(result.groups[0].activities[0].traceIDs, ["request"])
        XCTAssertTrue(overview.projection(visibleChangeIDs: []).groups.isEmpty)
        XCTAssertEqual(overview.projection(visibleChangeIDs: ["nonexistent"]).activityCount, 0)
    }

    func testReadOnlyResourcesNeverCreateChangedFileGroups() {
        let e = event("read", environment: alpha)
        let fixture = snapshot(events: [e], changes: [], environments: [EnvironmentRecord(path: alpha)], resources: [
            ResourceRecord(location: alpha + "/src/Read.swift", roles: [.recordedRead], environmentID: alpha, eventIDs: [e.id])
        ])
        let activity = ActivityEvidenceIndex(events: fixture.events, changes: [], resources: fixture.resources)
        XCTAssertEqual(activity.fileHistories.count, 1)
        let overview = ChangesOverviewIndex(snapshot: fixture, activity: activity)
        XCTAssertTrue(overview.groups.isEmpty)
        XCTAssertTrue(overview.projection(visibleChangeIDs: []).files.isEmpty)
    }

    func testStreamingAddsTracesWithoutChangingFileOrCanonicalActivityIdentity() throws {
        let request = event("request", environment: alpha, callID: "patch", time: 100)
        var fixture = snapshot(events: [request], changes: [change("request", event: request)])
        let first = projection(fixture)
        let completion = event("completion", environment: alpha, callID: "patch", time: 200, kind: .toolResult)
        fixture.events.insert(completion, at: 0)
        fixture.changes.insert(change("completion", event: completion, path: alpha + "/src/Same.swift", kind: .recordedResult), at: 0)
        let streamed = projection(fixture)
        XCTAssertEqual(first.groups[0].id, streamed.groups[0].id)
        XCTAssertEqual(first.files[0].id, streamed.files[0].id)
        XCTAssertEqual(first.files[0].activities[0].id, streamed.files[0].activities[0].id)
        XCTAssertEqual(streamed.activityCount, 1)
        XCTAssertEqual(streamed.traceIDs, ["completion", "request"])
        XCTAssertEqual(streamed.lastTimestamp, Date(timeIntervalSince1970: 200))
    }

    func testIdentityEncodingAndDuplicateChangeSelectionAreUnambiguousAndStable() {
        XCTAssertNotEqual(ChangesOverviewFileKey(environmentID: "/a", path: "/bc").id,
                          ChangesOverviewFileKey(environmentID: "/ab", path: "/c").id)
        XCTAssertNotEqual(ChangesOverviewFileKey(environmentID: "/a\0/b", path: "/c").id,
                          ChangesOverviewFileKey(environmentID: "/a", path: "/b\0/c").id)
        let first = event("first", environment: alpha), duplicate = event("duplicate", environment: beta)
        let result = projection(snapshot(events: [first, duplicate], changes: [change("same-id", event: first), change("same-id", event: duplicate)]))
        XCTAssertEqual(result.groups.map(\.id), [alpha])
        XCTAssertEqual(result.traceIDs, ["same-id"])
        XCTAssertEqual(result.eventIDs, ["first"])
    }
}
