import XCTest
@testable import LensCore

final class SessionTrendsPresentationTests: XCTestCase {
    func testCurvesUseTheSameAgentEnvironmentAndSourceSearchScopeAsActivity() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = event("a", agent: "root", environment: "/fixture/alpha", date: date)
        let b = event("b", agent: "child", environment: "/fixture/beta", date: date.addingTimeInterval(2))
        let snapshot = SessionSnapshot(root: SessionSummary(id: "session"), events: [a, b], changes: [
            ChangeRecord(id: "ca", path: "src/Same.swift", environmentID: "/fixture/alpha", agentID: "root", eventID: "a", kind: .requestedPatch),
            ChangeRecord(id: "cb", path: "src/Same.swift", environmentID: "/fixture/beta", agentID: "child", eventID: "b", kind: .requestedPatch)
        ])
        let builder = SessionPresentationBuilder()
        let all = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        XCTAssertEqual(all.trends.totalCounts[.mcpCalls], 2)
        XCTAssertEqual(all.trends.totalCounts[.requestedFileChanges], 2)
        let child = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(agentID: "child", environmentID: "/fixture/beta"))
        XCTAssertEqual(child.filteredEvents.map(\.id), ["b"])
        XCTAssertEqual(child.trends.totalCounts[.mcpCalls], 1)
        let bucket = try XCTUnwrap(child.trends.bucket(containing: b.timestamp))
        XCTAssertEqual(child.trends.eventIDs(for: .requestedFileChanges, in: bucket.id), ["b"])
        let searched = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(query: "recorded text", sourceMatches: ["a"]))
        XCTAssertEqual(searched.trends.totalCounts[.activity], 1)
        XCTAssertEqual(searched.trends.totalCounts[.mcpCalls], 1)
    }

    func testNewRevisionRebuildsCountsAndAnotherRootDoesNotReuseThem() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = event("a", agent: "root", environment: "/fixture/alpha", date: date)
        let builder = SessionPresentationBuilder()
        var snapshot = SessionSnapshot(root: SessionSummary(id: "session"), events: [a])
        let original = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        snapshot.events.append(event("b", agent: "root", environment: "/fixture/alpha", date: date.addingTimeInterval(1)))
        let updated = try await builder.prepare(snapshot: snapshot, revision: 2, filters: EventFilters())
        XCTAssertEqual(original.trends.totalCounts[.mcpCalls], 1)
        XCTAssertEqual(updated.trends.totalCounts[.mcpCalls], 2)
        XCTAssertEqual(original.trends.buckets.first?.id, updated.trends.buckets.first?.id)
        let other = try await builder.prepare(snapshot: SessionSnapshot(root: SessionSummary(id: "other")), revision: 2, filters: EventFilters())
        XCTAssertEqual(other.rootID, "other")
        XCTAssertTrue(other.trends.buckets.isEmpty)
        XCTAssertTrue(other.trends.totalCounts.isEmpty)
    }

    func testAgentTreeQueryKeepsTheEventCurveScopeAndCoverage() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let issue = CoverageIssue("missing-descendant", "A descendant is inaccessible.")
        let snapshot = SessionSnapshot(root: SessionSummary(id: "session"),
            agents: [AgentRecord(id: "root", name: "Root"), AgentRecord(id: "child", parentID: "root", name: "Child")],
            events: [event("a", agent: "root", environment: "/fixture/alpha", date: date),
                     event("b", agent: "child", environment: "/fixture/beta", date: .distantPast)], coverage: [issue])
        let builder = SessionPresentationBuilder()
        let all = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters())
        let treeQuery = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "Child"))
        XCTAssertEqual(all.trends.totalCounts, treeQuery.trends.totalCounts)
        XCTAssertEqual(treeQuery.trends.totalCounts[.mcpCalls], 2)
        XCTAssertEqual(treeQuery.trends.unplottedCounts[.mcpCalls], 1)
        XCTAssertEqual(treeQuery.filteredEvents.map(\.id), ["a", "b"])
        XCTAssertEqual(treeQuery.timelineEvents.map(\.id), ["a"])
        XCTAssertEqual(treeQuery.trends.coverage, [issue])
        XCTAssertEqual(treeQuery.agentRows.map { $0.0.id }, ["child"])
    }

    private func event(_ id: String, agent: String, environment: String, date: Date) -> LensEvent {
        LensEvent(id: id, timestamp: date, agentID: agent, kind: .toolCall, title: "Lookup",
                  toolName: "mcp__fixture__lookup", callID: "call-" + id, environmentID: environment,
                  source: SourceRef(path: "/fixture/" + agent + ".jsonl", line: 1))
    }
}
