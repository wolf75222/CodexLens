import Foundation
import XCTest
@testable import LensCore

final class TimelineModelTests: XCTestCase {
    func testRetentionByteBudgetSkipsCachingWithoutDroppingLargeIdentifiers() async throws {
        let model = TimelineModel()
        let id = "large-" + String(repeating: "évidence", count: 2000)
        let rows = [event(id, at: 1)]
        let small = TimelineBuildBudget(maxRetentionBytes: 4096)
        let first = try await model.prepare(events: rows, agents: [], budget: small)
        let next = try await model.prepare(events: rows, agents: [], budget: small)
        XCTAssertEqual(first.orderedEventIDs, [id]); XCTAssertEqual(next.eventCount, 1)
        var count = await model.completedPreparations; XCTAssertEqual(count, 2)
        var retained = await model.retainedBytesEstimate; XCTAssertEqual(retained, 0)
        let sufficient = TimelineBuildBudget(maxRetentionBytes: 256 * 1024)
        _ = try await model.prepare(events: rows, agents: [], budget: sufficient)
        _ = try await model.prepare(events: rows, agents: [], budget: sufficient)
        count = await model.completedPreparations; XCTAssertEqual(count, 3)
        retained = await model.retainedBytesEstimate; XCTAssertGreaterThan(retained, 4096); XCTAssertLessThanOrEqual(retained, 256 * 1024)
        await model.invalidateCache()
        retained = await model.retainedBytesEstimate; XCTAssertEqual(retained, 0)
    }

    func testTimelineReuseChecksRenderFieldsOrderAndBudgetAndCanReleaseCache() async throws {
        let model = TimelineModel()
        var rows = [event("a", at: 3, offset: 1), event("b", at: 3, offset: 2)]
        var agents = [AgentRecord(id: "root", name: "Initial", accessible: true)]
        let first = try await model.prepare(events: rows, agents: agents)
        rows[0].preview = "New preview from streaming"; rows[0].title = "New inspector title"
        let preview = try await model.prepare(events: rows, agents: agents)
        XCTAssertEqual(first.fingerprintSHA256, preview.fingerprintSHA256)
        var count = await model.completedPreparations; XCTAssertEqual(count, 1)
        agents[0].name = "Renamed"; agents[0].accessible = false
        let renamed = try await model.prepare(events: rows, agents: agents)
        XCTAssertEqual(renamed.lanes[0].name, "Renamed"); XCTAssertEqual(renamed.lanes[0].accessible, false)
        rows[0].endTime = epoch.addingTimeInterval(20)
        let ended = try await model.prepare(events: rows, agents: agents)
        XCTAssertEqual(ended.bounds?.end, epoch.addingTimeInterval(20))
        rows[0].source.offset = 4
        let reordered = try await model.prepare(events: rows, agents: agents)
        XCTAssertEqual(reordered.orderedEventIDs, ["b", "a"])
        _ = try await model.prepare(events: Array(rows.reversed()), agents: agents)
        let budget = TimelineBuildBudget(maxQueryItems: 1)
        let bounded = try await model.prepare(events: rows, agents: agents, budget: budget)
        XCTAssertEqual(bounded.visible(lane: 0, window: try window(0, 30)).omittedCount, 1)
        count = await model.completedPreparations; XCTAssertEqual(count, 6)
        await model.invalidateCache()
        _ = try await model.prepare(events: rows, agents: agents, budget: budget)
        count = await model.completedPreparations; XCTAssertEqual(count, 7)
    }

    func testCancelledPreparationCannotReplaceExistingTimelineCache() async throws {
        let model = TimelineModel(), original = [event("one", at: 1)]
        let first = try await model.prepare(events: original, agents: [])
        let replacement = [event("one", at: 900)]
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await model.prepare(events: replacement, agents: [])
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation must not become a visible success") }
        catch is CancellationError { }
        let retained = try await model.prepare(events: original, agents: [])
        XCTAssertEqual(first.bounds, retained.bounds)
        let count = await model.completedPreparations; XCTAssertEqual(count, 1)
    }

    private let epoch = Date(timeIntervalSince1970: 1_790_784_000)
    private func event(_ id: String, at seconds: Double, end: Double? = nil, agent: String = "root", offset: UInt64 = 0, kind: EventKind = .toolCall) -> LensEvent {
        LensEvent(id: id, timestamp: epoch.addingTimeInterval(seconds), endTime: end.map { epoch.addingTimeInterval($0) }, agentID: agent, kind: kind, title: "Recorded event", source: SourceRef(path: "/recorded/\(agent).jsonl", offset: offset))
    }
    private func window(_ lo: Double, _ hi: Double) throws -> TimelineWindow { try TimelineWindow(start: epoch.addingTimeInterval(lo), end: epoch.addingTimeInterval(hi)) }
    func testMissingAgentIsKeptWithoutInventingCatalogAvailability() throws {
        let value = try TimelineProjection.prepare(events: [event("unknown", at: 0, agent: "missing")], agents: [AgentRecord(id: "root", name: "Main"), AgentRecord(id: "offline", accessible: false)])
        XCTAssertEqual(value.lanes.map(\.id), ["root", "offline", "missing"])
        XCTAssertEqual(value.lanes.map(\.eventCount), [0, 0, 1])
        XCTAssertFalse(value.lanes[2].agentIsCatalogued)
        XCTAssertNil(value.lanes[2].accessible)
        XCTAssertEqual(value.lanes[1].accessible, false)
        XCTAssertEqual(value.item(id: "unknown")?.laneIndex, 2)
    }
    func testEqualTimestampsUseRecordedOffsetThenIDForStableNavigation() throws {
        let a = event("a", at: 3, offset: 20), b = event("b", at: 3, offset: 10), c = event("c", at: 4, agent: "child")
        let first = try TimelineProjection.prepare(events: [c, a, b], agents: [AgentRecord(id: "root"), AgentRecord(id: "child")])
        let second = try TimelineProjection.prepare(events: [b, c, a], agents: [AgentRecord(id: "root"), AgentRecord(id: "child")])
        XCTAssertEqual(first.orderedEventIDs, ["b", "a", "c"])
        XCTAssertEqual(first.orderedEventIDs, second.orderedEventIDs)
        XCTAssertEqual(first.fingerprintSHA256, second.fingerprintSHA256)
        XCTAssertEqual(first.next(of: "b"), "a")
        XCTAssertEqual(first.previous(of: "c"), "a")
        XCTAssertEqual(first.next(of: "b", inAgent: "root"), "a")
        XCTAssertNil(first.next(of: "a", inAgent: "root"))
        XCTAssertNil(first.previous(of: "b"))
        XCTAssertNil(first.next(of: "not-recorded"))
        XCTAssertNil(first.next(of: "b", inAgent: "child"))
    }
    func testLongRecordedCallOverlapsNarrowWindowAndClippingIsExplicit() throws {
        let value = try TimelineProjection.prepare(events: [event("long", at: 0, end: 1000), event("point", at: 501), event("outside", at: 700)], agents: [])
        let result = value.visible(lane: 0, window: try window(500, 502))
        XCTAssertEqual(result.items.map(\.id), ["long", "point"])
        let long = try XCTUnwrap(value.item(id: "long"))
        XCTAssertEqual(long.recordedDuration, 1000)
        let overlap = try XCTUnwrap(long.overlap(with: window(500, 502)))
        XCTAssertTrue(overlap.startsBeforeWindow)
        XCTAssertTrue(overlap.endsAfterWindow)
        XCTAssertEqual(overlap.visibleStart, epoch.addingTimeInterval(500))
        XCTAssertEqual(overlap.visibleEnd, epoch.addingTimeInterval(502))
        let geometry = try TimelineGeometry(window: window(500, 502), contentWidth: 600)
        XCTAssertLessThan(geometry.rect(for: long).x, geometry.labelWidth)
        XCTAssertGreaterThan(geometry.rect(for: long).maxX, 600)
        XCTAssertEqual(value.item(id: "point")?.recordedDuration, nil)
    }
    func testHitAmbiguityIsReportedAndRulerDoesNotSelectAnEvent() throws {
        let value = try TimelineProjection.prepare(events: [event("a", at: 5, end: 15, offset: 1), event("b", at: 5, end: 15, offset: 2), event("c", at: 6, end: 12, offset: 3)], agents: [])
        let geometry = try TimelineGeometry(window: window(0, 20), contentWidth: 600)
        let hits = value.hitTest(x: geometry.x(for: epoch.addingTimeInterval(8)), y: 68, geometry: geometry)
        XCTAssertEqual(Set(hits.eventIDs), Set(["a", "b", "c"]))
        XCTAssertEqual(hits.eventIDs.first, "c")
        XCTAssertEqual(hits.totalHits, 3)
        XCTAssertTrue(hits.requiresDisambiguation)
        XCTAssertTrue(hits.isComplete)
        XCTAssertEqual(value.hitTest(x: 300, y: 20, geometry: geometry).eventIDs, [])
        XCTAssertEqual(value.hitTest(x: 300, y: 900, geometry: geometry).eventIDs, [])
    }
    func testMutatedSameCountSeriesRebuildsBoundsAndFingerprint() async throws {
        let model = TimelineModel()
        let before = try await model.prepare(events: [event("same", at: 0, end: 2)], agents: [])
        let after = try await model.prepare(events: [event("same", at: 10, end: 30)], agents: [])
        XCTAssertEqual(before.orderedEventIDs, after.orderedEventIDs)
        XCTAssertNotEqual(before.fingerprintSHA256, after.fingerprintSHA256)
        XCTAssertEqual(before.bounds?.end, epoch.addingTimeInterval(2))
        XCTAssertEqual(after.bounds?.end, epoch.addingTimeInterval(30))
        XCTAssertEqual(after.item(id: "same")?.recordedDuration, 20)
    }
    func testInvalidRecordedEndAndUnknownEndAreNotInventedDurations() throws {
        let value = try TimelineProjection.prepare(events: [event("reverse", at: 4, end: 2), event("unknown", at: 5)], agents: [])
        XCTAssertEqual(value.invalidDurationEventIDs, ["reverse"])
        XCTAssertNil(value.item(id: "reverse")?.recordedDuration)
        XCTAssertEqual(value.item(id: "reverse")?.recordedEnd, epoch.addingTimeInterval(2))
        XCTAssertEqual(value.item(id: "reverse")?.effectiveEnd, epoch.addingTimeInterval(4))
        XCTAssertNil(value.item(id: "unknown")?.recordedDuration)
        XCTAssertEqual(value.item(id: "unknown")?.effectiveEnd, epoch.addingTimeInterval(5))
    }
    func testVisibleAndHitBudgetsDeclareEveryUninspectedCandidate() throws {
        let rows = (0..<30).map { event("e\($0)", at: 2, end: 4, offset: UInt64($0)) }
        let value = try TimelineProjection.prepare(events: rows, agents: [], budget: TimelineBuildBudget(maxQueryItems: 5))
        let visible = value.visible(lane: 0, window: try window(0, 10), limit: 100)
        XCTAssertEqual(visible.totalMatches, 30)
        XCTAssertEqual(visible.items.count, 5)
        XCTAssertEqual(visible.omittedCount, 25)
        XCTAssertEqual(visible.limitApplied, 5)
        let geometry = try TimelineGeometry(window: window(0, 10), contentWidth: 600)
        let hits = value.hitTest(x: geometry.x(for: epoch.addingTimeInterval(3)), y: 68, geometry: geometry, limit: 3)
        XCTAssertEqual(hits.eventIDs.count, 3)
        XCTAssertEqual(hits.uninspectedCandidates, 27)
        XCTAssertNil(hits.totalHits)
        XCTAssertTrue(hits.requiresDisambiguation)
        XCTAssertFalse(hits.isComplete)
        XCTAssertThrowsError(try TimelineProjection.prepare(events: rows, agents: [], budget: TimelineBuildBudget(maxEvents: 29)))
    }
    func testDuplicateIDsAndNonfiniteGeometryAreRejected() throws {
        XCTAssertThrowsError(try TimelineProjection.prepare(events: [event("same", at: 0), event("same", at: 1)], agents: []))
        XCTAssertThrowsError(try TimelineProjection.prepare(events: [], agents: [AgentRecord(id: "a"), AgentRecord(id: "a")]))
        XCTAssertThrowsError(try TimelineWindow(start: .init(timeIntervalSince1970: .infinity), end: epoch))
        XCTAssertThrowsError(try TimelineGeometry(window: window(0, 10), contentWidth: .nan))
        XCTAssertThrowsError(try TimelineGeometry(window: window(0, 10), contentWidth: 100))
        let empty = try TimelineProjection.prepare(events: [], agents: [])
        XCTAssertNil(empty.bounds)
        XCTAssertEqual(empty.eventCount, 0)
        XCTAssertEqual(empty.visible(lane: 0, window: try window(0, 1)).totalMatches, 0)
    }
    func testDatePixelMappingAndPointMarkerPadding() throws {
        let geometry = try TimelineGeometry(window: window(10, 10), contentWidth: 600)
        XCTAssertTrue(geometry.minimumSpanPaddingApplied)
        let point = epoch.addingTimeInterval(10.3)
        XCTAssertEqual(geometry.date(atX: geometry.x(for: point)).timeIntervalSince1970, point.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(geometry.lane(atY: 46), 0)
        XCTAssertEqual(geometry.lane(atY: 92), 1)
        XCTAssertNil(geometry.lane(atY: 20))
        let expanded = try geometry.window(forXRange: 200...300)
        XCTAssertLessThan(expanded.start, geometry.date(atX: 200, clamped: false))
        XCTAssertEqual(expanded.end, geometry.date(atX: 300, clamped: false))
    }
    func testHundredThousandEventsAreDeterministicAndNarrowQueryPrunesLongCall() throws {
        var rows = (0..<100_000).map { event(String(format: "e%06d", $0), at: Double($0), offset: UInt64($0)) }
        rows.append(event("long", at: -1, end: 1_000_000))
        let first = try TimelineProjection.prepare(events: rows, agents: [])
        let second = try TimelineProjection.prepare(events: rows.reversed(), agents: [])
        XCTAssertEqual(first.fingerprintSHA256, second.fingerprintSHA256)
        XCTAssertEqual(first.orderedEventIDs, second.orderedEventIDs)
        let narrow = first.visible(lane: 0, window: try window(99_950, 99_951))
        XCTAssertEqual(narrow.items.map(\.id), ["long", "e099950", "e099951"])
        XCTAssertEqual(narrow.totalMatches, 3)
        XCTAssertLessThan(narrow.visitedNodes, 200, "A long old call must not force a scan of the 100k short events")
        let all = first.visible(lane: 0, window: try window(-1, 1_000_000), limit: 20)
        XCTAssertEqual(all.totalMatches, 100_001)
        XCTAssertEqual(all.items.count, 20)
        XCTAssertEqual(all.omittedCount, 99_981)
        XCTAssertLessThan(all.visitedNodes, 5, "Fully covered subtrees are counted without enumerating hidden events")
    }

    func testLargeSessionKeepsEveryEventAndBoundedQueriesWithoutRetainingOversizedCache() async throws {
        let count = 323_000, model = TimelineModel()
        let rows = (0..<count).map { event("e\($0)", at: Double($0), offset: UInt64($0)) }
        let projection = try await model.prepare(events: rows, agents: [])
        XCTAssertEqual(projection.eventCount, count)
        XCTAssertEqual(projection.orderedEventIDs.count, count)
        XCTAssertEqual(projection.item(id: "e322999")?.lanePosition, count - 1)
        XCTAssertEqual(projection.previous(of: "e322999"), "e322998")
        let narrow = projection.visible(lane: 0, window: try window(322_950, 322_951))
        XCTAssertEqual(narrow.items.map(\.id), ["e322950", "e322951"])
        XCTAssertLessThan(narrow.visitedNodes, 200)
        let all = projection.visible(lane: 0, window: try window(0, Double(count)), limit: 20)
        XCTAssertEqual(all.totalMatches, count)
        XCTAssertEqual(all.omittedCount, count - 20)
        let geometry = try TimelineGeometry(window: window(0, Double(count)), contentWidth: 600)
        let density = projection.density(lane: 0, geometry: geometry, xRange: geometry.labelWidth...(geometry.contentWidth - geometry.rightInset))
        XCTAssertEqual(density.totalMatches, count)
        XCTAssertFalse(density.clusters.isEmpty)
        let retained = await model.retainedBytesEstimate
        XCTAssertEqual(retained, 0, "The oversized preparation must not create a second retained cache")
        XCTAssertEqual(TimelineBuildBudget().maxEvents, 500_000)
        XCTAssertEqual(TimelineBuildBudget().maxRetentionBytes, 64 * 1024 * 1024)
    }
}
