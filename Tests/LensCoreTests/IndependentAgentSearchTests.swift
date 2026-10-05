import XCTest
@testable import LensCore

final class IndependentAgentSearchTests: XCTestCase {
    private var fixture: SessionSnapshot {
        let alpha = AgentRecord(id: "alpha-id", name: "Alpha reader", mission: "Inspect supplied document", paths: ["/fixture/alpha/trace.jsonl"], environmentIDs: ["/fixture/first/worktree"])
        let beta = AgentRecord(id: "beta-id", parentID: "alpha-id", name: "Beta reviewer", relation: .subagent, mission: "Review a manual edit", paths: ["/fixture/beta/trace.jsonl"], environmentIDs: ["/fixture/second/worktree"])
        let first = LensEvent(id: "alpha-event", timestamp: Date(timeIntervalSince1970: 100), agentID: alpha.id, kind: .toolCall, title: "visible alpha preview", toolName: "read", environmentID: alpha.environmentIDs[0], source: SourceRef(path: alpha.paths[0]))
        let second = LensEvent(id: "beta-event", timestamp: Date(timeIntervalSince1970: 200), agentID: beta.id, kind: .toolCall, title: "visible beta preview", toolName: "read", environmentID: beta.environmentIDs[0], source: SourceRef(path: beta.paths[0]))
        return SessionSnapshot(root: SessionSummary(id: "root"), agents: [alpha, beta], events: [first, second])
    }

    func testActivityQueryAndFiltersDoNotNarrowExplicitUnfilteredAgentGraph() async throws {
        let snapshot = fixture
        let filters = EventFilters(agentID: "alpha-id", environmentID: "/fixture/first/worktree", period: Date(timeIntervalSince1970: 90)...Date(timeIntervalSince1970: 110), query: "visible alpha", sourceMatches: ["alpha-event"])
        let value = try await SessionPresentationBuilder().prepare(snapshot: snapshot, revision: 1, filters: filters, agentFilters: AgentFilters())
        XCTAssertEqual(value.filteredEvents.map(\.id), ["alpha-event"])
        XCTAssertEqual(value.agentRows.map { $0.0.id }, ["alpha-id", "beta-id"])
        XCTAssertEqual(value.agentRows.map { $0.1 }, [0, 1])
        XCTAssertEqual(value.eventCountByAgent["beta-id"], 1, "Activity filtering must not hide recorded per-agent totals")
    }

    func testIndependentAgentMetadataSearchPreservesEveryRecordedField() async throws {
        let snapshot = fixture
        let builder = SessionPresentationBuilder()
        let queries = ["ALPHA READER", "alpha-id", "supplied document", "first/worktree", "/alpha/trace.jsonl"]
        for query in queries {
            let value = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: query))
            XCTAssertEqual(value.agentRows.map { $0.0.id }, ["alpha-id"], query)
            XCTAssertEqual(value.filteredEvents.map(\.id), ["alpha-event", "beta-event"], "Agent search must not change the activity result for " + query)
        }
    }

    func testIndependentRecordedTraceMatchesUseAgentQueryNotActivityQuery() async throws {
        let builder = SessionPresentationBuilder()
        let activity = EventFilters(query: "full alpha output", sourceMatches: ["alpha-event"])
        let value = try await builder.prepare(snapshot: fixture, revision: 1, filters: activity, agentFilters: AgentFilters(query: "full beta output", sourceMatches: ["beta-event", "missing-event"]))
        XCTAssertEqual(value.filteredEvents.map(\.id), ["alpha-event"])
        XCTAssertEqual(value.filteredCalls.map(\.id), ["alpha-event"])
        XCTAssertEqual(value.agentRows.map { $0.0.id }, ["beta-id"])
        XCTAssertEqual(value.agentsByID["beta-id"]?.parentID, "alpha-id", "An omitted parent in search results is still a recorded parent, not a new root")
        XCTAssertEqual(value.eventIDsByAgent["alpha-id"], ["alpha-event"])
        XCTAssertEqual(value.eventIDsByAgent["beta-id"], ["beta-event"])
    }

    func testAgentRequestParticipatesInCacheIdentityWithoutChangingEventSelection() async throws {
        let builder = SessionPresentationBuilder()
        let first = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "Alpha"))
        let repeatFirst = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "Alpha"))
        XCTAssertEqual(first.id, repeatFirst.id)
        let second = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "Beta"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.agentRows.map { $0.0.id }, ["beta-id"])
        XCTAssertEqual(first.filteredEvents, second.filteredEvents)
        let sourceOnly = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "unrecorded in metadata", sourceMatches: ["alpha-event"]))
        XCTAssertEqual(sourceOnly.agentRows.map { $0.0.id }, ["alpha-id"])
        let changedSource = try await builder.prepare(snapshot: fixture, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "unrecorded in metadata", sourceMatches: ["beta-event"]))
        XCTAssertNotEqual(sourceOnly.id, changedSource.id)
        XCTAssertEqual(changedSource.agentRows.map { $0.0.id }, ["beta-id"])
    }

    func testStreamingAndDifferentRootsCannotReuseAnEarlierAgentAssociation() async throws {
        let builder = SessionPresentationBuilder()
        var snapshot = fixture
        let query = AgentFilters(query: "search only recorded output", sourceMatches: ["beta-event"])
        let first = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: query)
        XCTAssertEqual(first.agentRows.map { $0.0.id }, ["beta-id"])
        snapshot.events[1].agentID = "alpha-id"
        let streamed = try await builder.prepare(snapshot: snapshot, revision: 2, filters: EventFilters(), agentFilters: query)
        XCTAssertEqual(streamed.agentRows.map { $0.0.id }, ["alpha-id"])
        let other = SessionSnapshot(root: SessionSummary(id: "different-root"), agents: [AgentRecord(id: "other")])
        let switched = try await builder.prepare(snapshot: other, revision: 2, filters: EventFilters(), agentFilters: query)
        XCTAssertTrue(switched.agentRows.isEmpty)
        XCTAssertNil(switched.eventsByID["beta-event"])
    }

    func testOmittedAgentFiltersKeepLegacySharedSearchBehavior() async throws {
        let value = try await SessionPresentationBuilder().prepare(snapshot: fixture, revision: 1, filters: EventFilters(query: "visible beta", sourceMatches: ["beta-event"]))
        XCTAssertEqual(value.filteredEvents.map(\.id), ["beta-event"])
        XCTAssertEqual(value.agentRows.map { $0.0.id }, ["beta-id"])
    }
}
