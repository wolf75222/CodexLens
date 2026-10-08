import Foundation
import XCTest
@testable import LensCore

final class TimelineDensityTests: XCTestCase {
    func testFractionalGroupWindowKeepsPinchAnchorAndScale() throws {
        let start = Date(timeIntervalSince1970: 1_790_784_000)
        let geometry = try TimelineGeometry(window: TimelineWindow(start: start, end: start.addingTimeInterval(0.03)), contentWidth: 900, minimumTimeSpan: 0.001)
        let placement = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: geometry, baseContentWidth: 900, viewportWidth: 900, originX: 0, focalViewportX: 450, targetZoom: 2))
        let next = try TimelineGeometry(window: geometry.window, contentWidth: 1800, minimumTimeSpan: geometry.minimumTimeSpan)
        XCTAssertEqual(next.date(atX: placement.originX + placement.anchorViewportX).timeIntervalSince(placement.anchorDate), 0, accuracy: 0.000001)
        XCTAssertEqual(next.window.duration, geometry.window.duration, accuracy: 0.000001)
    }

    func testSeparatedMarksRemainDetailedAboveTheOldTwoItemThreshold() throws {
        let viewport = try geometry(0, 100)
        let rows = (0..<12).map { event("separated-\($0)", date: viewport.date(atX: 220 + Double($0) * 8, clamped: false)) }
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        XCTAssertEqual(result.totalMatches, rows.count)
        XCTAssertEqual(Set(result.details.map(\.id)), Set(rows.map(\.id)))
        XCTAssertTrue(result.clusters.isEmpty, "A bin with several spatially separated marks is not dense")
    }

    func testSmallSimultaneousGroupsUseExactEffectiveKinds() throws {
        let rows = [event("call", at: 10, kind: .toolCall),
                    event("failed-response", at: 10, kind: .assistant, isError: true),
                    event("explicit-error", at: 10, kind: .error, isError: true)]
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(0, 100)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        XCTAssertTrue(result.details.isEmpty, "Simultaneous marks overlap even below the detail-count limit")
        let cluster = try XCTUnwrap(result.clusters.first)
        XCTAssertEqual(cluster.count, 3)
        XCTAssertEqual(cluster.kindCounts, [.toolCall: 1, .error: 2])
        XCTAssertEqual(cluster.kindCounts.values.reduce(0, +), cluster.count)
        XCTAssertEqual(projection.item(id: "failed-response")?.effectiveKind, .error)
        XCTAssertEqual(cluster.errorCount, 2, "The explicit error with an error flag is counted once")
    }

    func testMarkerOverlapAcrossBinsDoesNotLeakASupposedlySeparateDetail() throws {
        let viewport = try geometry(0, 100)
        let binCount = ceil(viewport.timeWidth / 32)
        let edge = viewport.labelWidth + viewport.timeWidth * 3 / binCount
        let rows = [event("before-edge", date: viewport.date(atX: edge - 2, clamped: false)),
                    event("after-edge", date: viewport.date(atX: edge + 2, clamped: false))]
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        XCTAssertEqual(result.totalMatches, 2)
        XCTAssertTrue(result.details.isEmpty, "The five-pixel markers overlap across a bin boundary")
        XCTAssertTrue(result.clusters.contains { $0.count == 2 })
        XCTAssertTrue(result.clusters.allSatisfy { $0.kindCounts.values.reduce(0, +) == $0.count })
    }

    func testLongMarkIsGroupedWhenItOverlapsALaterEventBeyondItsFirstBin() throws {
        let rows = [event("long", at: 0, end: 100, kind: .toolCall), event("later", at: 90, kind: .assistant)]
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(0, 100)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        XCTAssertEqual(result.totalMatches, 2)
        XCTAssertTrue(result.details.isEmpty)
        XCTAssertTrue(result.clusters.contains { $0.kindCounts == [.toolCall: 1, .assistant: 1] })
        XCTAssertEqual(projection.item(id: "long")?.recordedDuration, 100)
    }

    func testMixedHundredThousandGroupCompositionDoesNotComeFromItsSample() throws {
        let rows: [LensEvent] = (0..<100_000).map { (index: Int) -> LensEvent in
            let kind: EventKind
            if index < 50_000 { kind = .assistant }
            else if index < 80_000 { kind = .toolCall }
            else if index < 99_999 { kind = .toolResult }
            else { kind = .compaction }
            let identifier: String = "mixed-\(index)"
            let failed: Bool = index == 99_999
            let offset: UInt64 = UInt64(index)
            return event(identifier, at: 10, offset: offset, kind: kind, isError: failed)
        }
        let projection = try TimelineProjection.prepare(events: rows, agents: [], budget: TimelineBuildBudget(maxQueryItems: 1))
        let viewport = try geometry(0, 600)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        let cluster = try XCTUnwrap(result.clusters.first)
        let expected: [EventKind: Int] = [.assistant: 50_000, .toolCall: 30_000, .toolResult: 19_999, .error: 1]
        XCTAssertEqual(cluster.kindCounts, expected)
        XCTAssertEqual(cluster.kindCounts.values.reduce(0, +), 100_000)
        XCTAssertEqual(cluster.sampleEventIDs, ["mixed-0"])
        XCTAssertFalse(cluster.sampleEventIDs.contains("mixed-99999"))
        XCTAssertEqual(cluster.errorCount, 1)
        XCTAssertEqual(cluster.compactionCount, 1, "Raw compaction statistics are separate from error-priority display kinds")
        XCTAssertNil(cluster.kindCounts[.compaction])
        XCTAssertLessThan(result.visitedNodes, 2048, "Exact colors use prepared indexes, not enumeration of the group")
        XCTAssertNotNil(projection.item(id: "mixed-99999"))
    }

    func testMixedMarkerFringesAndLongIntervalsKeepExactKindComposition() throws {
        let rows = (0..<2048).map { index in
            event("fringe-\(index)", at: index.isMultiple(of: 2) ? 99.998 : 99.9,
                  end: index.isMultiple(of: 2) ? nil : 100.6, offset: UInt64(index),
                  kind: index.isMultiple(of: 3) ? .compaction : .toolResult, isError: index.isMultiple(of: 7))
        }
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(100, 101)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        let padding = viewport.window.duration * viewport.minimumMarkerWidth / viewport.timeWidth
        XCTAssertFalse(result.clusters.isEmpty)
        for cluster in result.clusters {
            let matching = rows.filter { event in
                event.timestamp <= cluster.window.end
                    && max(event.timestamp.addingTimeInterval(padding), event.endTime ?? event.timestamp) >= cluster.window.start
            }
            let reference = matching.reduce(into: [EventKind: Int]()) { $0[$1.isError ? .error : $1.kind, default: 0] += 1 }
            XCTAssertEqual(cluster.kindCounts, reference)
            XCTAssertEqual(cluster.kindCounts.values.reduce(0, +), cluster.count)
        }
        XCTAssertLessThan(result.visitedNodes, 4096, "Mixed fringe queries must not scan 2048 items for every bin")
    }

    func testZoomAndDezoomRestoreGroupsAndTheirExactColors() throws {
        let kinds: [EventKind] = [.user, .assistant, .toolCall, .toolResult, .delegation, .wait]
        let rows = (0..<500).map { event("zoom-\($0)", at: Double($0) * 0.25, offset: UInt64($0), kind: kinds[$0 % kinds.count]) }
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let overviewGeometry = try geometry(0, 500)
        let overview = projection.density(lane: 0, geometry: overviewGeometry, xRange: axis(overviewGeometry))
        XCTAssertFalse(overview.clusters.isEmpty)
        let middleGeometry = try geometry(0, 20)
        let middle = projection.density(lane: 0, geometry: middleGeometry, xRange: axis(middleGeometry))
        XCTAssertEqual(middle.totalMatches, 81)
        XCTAssertEqual(middle.details.count, 81)
        XCTAssertTrue(middle.clusters.isEmpty)
        let closeGeometry = try geometry(5, 6.75)
        let close = projection.density(lane: 0, geometry: closeGeometry, xRange: axis(closeGeometry))
        XCTAssertEqual(close.details.count, 8)
        XCTAssertTrue(close.clusters.isEmpty)
        let restored = projection.density(lane: 0, geometry: overviewGeometry, xRange: axis(overviewGeometry))
        XCTAssertEqual(restored.totalMatches, overview.totalMatches)
        XCTAssertEqual(restored.clusters.map(\.id), overview.clusters.map(\.id))
        XCTAssertEqual(restored.clusters.map(\.kindCounts), overview.clusters.map(\.kindCounts))
        XCTAssertEqual(projection.eventCount, 500)
        XCTAssertNotNil(projection.item(id: "zoom-499"))
    }

    private let epoch = Date(timeIntervalSince1970: 1_790_784_000)

    func testDenseOverviewKeepsAll12014EventsAndZoomRevealsIndividualEvents() throws {
        let rows = (0..<12_014).map { event("event-\($0)", at: Double($0), offset: UInt64($0)) }
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let overviewGeometry = try geometry(0, 12_014)
        let overview = projection.density(lane: 0, geometry: overviewGeometry, xRange: axis(overviewGeometry))

        XCTAssertEqual(overview.totalMatches, 12_014)
        XCTAssertFalse(overview.clusters.isEmpty)
        XCTAssertLessThan(overview.details.count + overview.clusters.count, 100,
                          "The overview should draw groups, not thousands of overlapping marks")
        XCTAssertTrue(overview.clusters.allSatisfy { $0.count > 2 })
        XCTAssertEqual(projection.eventCount, 12_014, "Grouping changes the display, not the indexed events")

        let zoomGeometry = try geometry(6000, 6001)
        let zoom = projection.density(lane: 0, geometry: zoomGeometry, xRange: axis(zoomGeometry))
        XCTAssertEqual(zoom.totalMatches, 2)
        XCTAssertEqual(zoom.details.map(\.id), ["event-6000", "event-6001"])
        XCTAssertTrue(zoom.clusters.isEmpty)
    }

    func testHundredThousandSimultaneousEventsAreCountedWithoutEnumeratingThem() throws {
        let rows = (0..<100_000).map { event("event-\($0)", at: 10, offset: UInt64($0)) }
        let projection = try TimelineProjection.prepare(
            events: rows, agents: [], budget: TimelineBuildBudget(maxQueryItems: 1))
        let viewport = try geometry(0, 600)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))

        XCTAssertEqual(result.totalMatches, 100_000)
        XCTAssertTrue(result.details.isEmpty)
        let cluster = try XCTUnwrap(result.clusters.first)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(cluster.count, 100_000,
                       "A small detail/sample budget must not hide events from the group count")
        XCTAssertLessThanOrEqual(cluster.sampleEventIDs.count, 1)
        XCTAssertEqual(cluster.sampleEventIDs.first, "event-0")
        XCTAssertLessThan(result.visitedNodes, 1024,
                          "Queries should count covered tree nodes rather than visit all 100k events")
        XCTAssertNotNil(projection.item(id: "event-99999"),
                        "A selected event remains addressable even when it is not in the group sample")
    }

    func testAlternatingLongAndFinishedIntervalsUseBoundedQueriesFor100kEvents() throws {
        let rows = (0..<100_000).map { index in
            event("event-\(index)", at: 0, end: index.isMultiple(of: 2) ? 3600 : 0,
                  offset: UInt64(index))
        }
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(100, 200, width: 900)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))

        XCTAssertEqual(result.totalMatches, 50_000)
        XCTAssertTrue(result.details.isEmpty)
        XCTAssertGreaterThan(result.clusters.count, 1)
        XCTAssertTrue(result.clusters.allSatisfy { $0.count == 50_000 })
        XCTAssertTrue(result.clusters.flatMap(\.sampleEventIDs).allSatisfy {
            projection.item(id: $0)?.recordedDuration == 3600
        })
        XCTAssertLessThan(result.visitedNodes, 4096,
                          "Alternating finished intervals must not force a 100k-node scan for every group")
    }

    func testLongIntervalsMayAppearInSeveralGroupsButTotalIsUnique() throws {
        var rows = (0..<20).map { event("long-\($0)", at: 0, end: 1000, offset: UInt64($0)) }
        rows.append(event("middle-a", at: 550))
        rows.append(event("middle-b", at: 551))
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(500, 600)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport), bucketWidth: 80)

        XCTAssertEqual(result.totalMatches, 22)
        XCTAssertTrue(result.details.isEmpty)
        XCTAssertGreaterThan(result.clusters.count, 2)
        XCTAssertTrue(result.clusters.allSatisfy { $0.count >= 20 })
        XCTAssertGreaterThan(result.clusters.reduce(0) { $0 + $1.count }, result.totalMatches,
                             "Overlapping groups are not a sum of unique event counts")
        XCTAssertGreaterThan(result.clusters.filter { $0.sampleEventIDs.contains("long-0") }.count, 1)
        XCTAssertEqual(projection.item(id: "long-0")?.recordedDuration, 1000)
        XCTAssertTrue(result.clusters.allSatisfy {
            $0.window.start >= viewport.window.start && $0.window.end <= viewport.window.end
        }, "Group windows describe the visible bins; they do not replace recorded intervals")
    }

    func testGlobalDetailBudgetUsesGroupsForRemainingSparseEvents() throws {
        let rows = [event("first", at: 10), event("second", at: 50), event("third", at: 90)]
        let projection = try TimelineProjection.prepare(
            events: rows, agents: [], budget: TimelineBuildBudget(maxQueryItems: 1))
        let viewport = try geometry(0, 100)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))

        XCTAssertEqual(result.totalMatches, 3)
        XCTAssertEqual(result.details.count, 1)
        XCTAssertFalse(result.clusters.isEmpty)
        let visibleIDs = Set(result.details.map(\.id) + result.clusters.flatMap(\.sampleEventIDs))
        XCTAssertEqual(visibleIDs, Set(["first", "second", "third"]),
                       "When the global detail budget is spent, later sparse bins still have a representation")
        XCTAssertTrue(result.clusters.allSatisfy { $0.count == 1 && $0.sampleEventIDs.count == 1 })
    }

    func testMinimumMarkerAndClosedViewportEdgesIncludeOnlyIntersectingEvents() throws {
        let viewport = try geometry(0, 10)
        let range: ClosedRange<Double> = 300...344
        let rows = [
            event("marker-overlap", date: viewport.date(atX: range.lowerBound - 2, clamped: false)),
            event("before-marker", date: viewport.date(atX: range.lowerBound - 7, clamped: false)),
            event("inside", date: viewport.date(atX: range.lowerBound + 10, clamped: false)),
            event("right-edge", date: viewport.date(atX: range.upperBound, clamped: false)),
            event("after-edge", date: viewport.date(atX: range.upperBound + 1, clamped: false))
        ]
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let result = projection.density(lane: 0, geometry: viewport, xRange: range, detailLimit: 4)

        XCTAssertEqual(result.totalMatches, 3)
        XCTAssertEqual(Set(result.details.map(\.id)), Set(["marker-overlap", "inside", "right-edge"]))
        XCTAssertTrue(result.clusters.isEmpty)
    }

    func testOverlapBoundsAndGroupStatisticsExcludeAlreadyFinishedEvents() throws {
        let rows = [
            event("finished-before", at: 0, end: 99, kind: .compaction, isError: true),
            event("touches-lower", at: 0, end: 100, kind: .error),
            event("crosses-lower", at: 50, end: 150, kind: .toolResult, isError: true),
            event("point-before-marker", at: 99, kind: .error),
            event("marker-overlaps-lower", at: 99.9, kind: .compaction, isError: true),
            event("inside", at: 150, kind: .assistant),
            event("touches-upper", at: 200, kind: .compaction),
            event("after-upper", at: 200.01, kind: .compaction, isError: true)
        ]
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(100, 200, width: 900)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport),
                                        bucketWidth: 1000, detailLimit: 0)
        let cluster = try XCTUnwrap(result.clusters.first)

        XCTAssertEqual(result.totalMatches, 5)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(cluster.count, 5)
        XCTAssertEqual(cluster.errorCount, 3)
        XCTAssertEqual(cluster.compactionCount, 2)
        XCTAssertEqual(cluster.kindCounts, [.error: 3, .assistant: 1, .compaction: 1])
        XCTAssertTrue(result.details.isEmpty)
        XCTAssertFalse(cluster.sampleEventIDs.contains("finished-before"))
        XCTAssertFalse(cluster.sampleEventIDs.contains("point-before-marker"))
        XCTAssertFalse(cluster.sampleEventIDs.contains("after-upper"))
        XCTAssertEqual(cluster.window.start, viewport.window.start)
        XCTAssertEqual(cluster.window.end, viewport.window.end)
    }

    func testSameTimeInDifferentAgentLanesDoesNotCombineTheirGroups() throws {
        let root = (0..<10).map { event("root-\($0)", at: 10, agent: "root", offset: UInt64($0)) }
        let child = (0..<5).map { event("child-\($0)", at: 10, agent: "child", offset: UInt64($0)) }
        let projection = try TimelineProjection.prepare(events: root + child, agents: [
            AgentRecord(id: "root", name: "Main"),
            AgentRecord(id: "child", parentID: "root", name: "Reader")
        ])
        let viewport = try geometry(0, 100)
        let first = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        let second = projection.density(lane: 1, geometry: viewport, xRange: axis(viewport))

        XCTAssertEqual(first.totalMatches, 10)
        XCTAssertEqual(second.totalMatches, 5)
        let rootCluster = try XCTUnwrap(first.clusters.first)
        let childCluster = try XCTUnwrap(second.clusters.first)
        XCTAssertEqual(rootCluster.laneIndex, 0)
        XCTAssertEqual(childCluster.laneIndex, 1)
        XCTAssertNotEqual(rootCluster.id, childCluster.id)
        XCTAssertTrue(rootCluster.sampleEventIDs.allSatisfy { projection.item(id: $0)?.agentID == "root" })
        XCTAssertTrue(childCluster.sampleEventIDs.allSatisfy { projection.item(id: $0)?.agentID == "child" })
    }

    func testFiltersAndStreamingUseTheirOwnProjectionAndPreserveSelectedIdentity() async throws {
        let model = TimelineModel()
        var rows = (0..<100).map { event("event-\($0)", at: 10, offset: UInt64($0)) }
        let before = try await model.prepare(events: rows, agents: [])
        let filtered = try await model.prepare(events: Array(rows.prefix(50)), agents: [])
        let viewport = try geometry(0, 100)

        XCTAssertEqual(before.density(lane: 0, geometry: viewport, xRange: axis(viewport)).totalMatches, 100)
        XCTAssertEqual(filtered.density(lane: 0, geometry: viewport, xRange: axis(viewport)).totalMatches, 50)
        XCTAssertNotEqual(before.fingerprintSHA256, filtered.fingerprintSHA256)

        rows[99].isError = true
        let updated = try await model.prepare(events: rows, agents: [])
        XCTAssertNotEqual(before.fingerprintSHA256, updated.fingerprintSHA256)
        XCTAssertEqual(updated.density(lane: 0, geometry: viewport, xRange: axis(viewport)).clusters.first?.errorCount, 1)
        rows.append(event("streamed", at: 11, offset: 100))
        let appended = try await model.prepare(events: rows, agents: [])
        XCTAssertEqual(appended.density(lane: 0, geometry: viewport, xRange: axis(viewport)).totalMatches, 101)
        XCTAssertNotEqual(updated.fingerprintSHA256, appended.fingerprintSHA256)
        XCTAssertEqual(before.item(id: "event-99")?.id, appended.item(id: "event-99")?.id)
        XCTAssertEqual(before.item(id: "event-99")?.start, appended.item(id: "event-99")?.start)
        XCTAssertFalse(before.item(id: "event-99")?.isError ?? true,
                       "A prepared historical projection must not change when later data arrives")
        XCTAssertTrue(appended.item(id: "event-99")?.isError ?? false)
    }

    func testGroupsCountErrorsAndCompactionsWithoutInventingInvalidDuration() throws {
        let rows = [
            event("reverse", at: 10, end: 4),
            event("unknown-end", at: 10),
            event("error-kind", at: 10, kind: .error),
            event("failed-result", at: 10, kind: .toolResult, isError: true),
            event("compaction", at: 10, kind: .compaction),
            event("failed-compaction", at: 10, kind: .compaction, isError: true)
        ]
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(0, 100)
        let result = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        let cluster = try XCTUnwrap(result.clusters.first)

        XCTAssertEqual(result.totalMatches, 6)
        XCTAssertEqual(cluster.count, 6)
        XCTAssertEqual(cluster.errorCount, 3)
        XCTAssertEqual(cluster.compactionCount, 2)
        XCTAssertEqual(projection.invalidDurationEventIDs, ["reverse"])
        XCTAssertNil(projection.item(id: "reverse")?.recordedDuration)
        XCTAssertEqual(projection.item(id: "reverse")?.recordedEnd, epoch.addingTimeInterval(4))
        XCTAssertEqual(projection.item(id: "reverse")?.effectiveEnd, epoch.addingTimeInterval(10))
        XCTAssertNil(projection.item(id: "unknown-end")?.recordedDuration)
    }

    func testUnchangedRebuildProducesStableGroupsWindowsAndSamples() throws {
        let rows = (0..<200).map { event("event-\($0)", at: Double($0), offset: UInt64($0)) }
        let first = try TimelineProjection.prepare(events: rows, agents: [])
        let second = try TimelineProjection.prepare(events: rows.reversed(), agents: [])
        let viewport = try geometry(0, 200)
        let a = first.density(lane: 0, geometry: viewport, xRange: axis(viewport))
        let b = second.density(lane: 0, geometry: viewport, xRange: axis(viewport))

        XCTAssertEqual(first.fingerprintSHA256, second.fingerprintSHA256)
        XCTAssertEqual(a.totalMatches, b.totalMatches)
        XCTAssertEqual(a.details.map(\.id), b.details.map(\.id))
        XCTAssertEqual(a.clusters.map(\.id), b.clusters.map(\.id))
        XCTAssertEqual(a.clusters.map(\.window), b.clusters.map(\.window))
        XCTAssertEqual(a.clusters.map(\.count), b.clusters.map(\.count))
        XCTAssertEqual(a.clusters.map(\.sampleEventIDs), b.clusters.map(\.sampleEventIDs))
        XCTAssertTrue(a.clusters.allSatisfy { $0.sampleEventIDs.count <= 4 })
        XCTAssertTrue(a.clusters.flatMap(\.sampleEventIDs).allSatisfy { first.item(id: $0) != nil })
    }

    func testMaximumBucketBudgetCoarsensTheWholeViewportWithoutDroppingCounts() throws {
        let rows = (0..<2000).map { event("event-\($0)", at: Double($0), offset: UInt64($0)) }
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let viewport = try geometry(0, 2000, width: 25_000)
        let small = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport), maximumBuckets: 3)
        let oversized = projection.density(lane: 0, geometry: viewport, xRange: axis(viewport), maximumBuckets: 4096)

        XCTAssertEqual(small.totalMatches, 2000)
        XCTAssertEqual(small.clusters.count, 3)
        XCTAssertTrue(small.details.isEmpty)
        XCTAssertEqual(oversized.totalMatches, 2000)
        XCTAssertLessThanOrEqual(oversized.clusters.count, 256,
                                 "Drawing allocation remains bounded even when callers request an excessive bin budget")
        XCTAssertTrue(small.clusters.allSatisfy { $0.count > 0 })
        XCTAssertEqual(small.clusters.first?.window.start, viewport.window.start)
        XCTAssertEqual(small.clusters.last?.window.end, viewport.window.end)
    }

    func testEmptyOrInvalidLaneProducesNoGroupsOrDetails() throws {
        let projection = try TimelineProjection.prepare(events: [], agents: [AgentRecord(id: "root")])
        let viewport = try geometry(0, 100)
        for lane in [-1, 0, 1] {
            let result = projection.density(lane: lane, geometry: viewport, xRange: axis(viewport))
            XCTAssertEqual(result.totalMatches, 0)
            XCTAssertTrue(result.details.isEmpty)
            XCTAssertTrue(result.clusters.isEmpty)
        }
    }

    private func event(_ id: String, at seconds: Double, end: Double? = nil, agent: String = "root",
                       offset: UInt64 = 0, kind: EventKind = .toolCall, isError: Bool = false) -> LensEvent {
        LensEvent(id: id, timestamp: epoch.addingTimeInterval(seconds), endTime: end.map { epoch.addingTimeInterval($0) },
                  agentID: agent, kind: kind, title: "Recorded event",
                  source: SourceRef(path: "/recorded/\(agent).jsonl", offset: offset), isError: isError)
    }

    private func event(_ id: String, date: Date) -> LensEvent {
        LensEvent(id: id, timestamp: date, agentID: "root", kind: .toolCall,
                  title: "Recorded event", source: SourceRef(path: "/recorded/root.jsonl"))
    }

    private func geometry(_ start: Double, _ end: Double, width: Double = 1000) throws -> TimelineGeometry {
        try TimelineGeometry(window: TimelineWindow(start: epoch.addingTimeInterval(start), end: epoch.addingTimeInterval(end)),
                             contentWidth: width)
    }

    private func axis(_ geometry: TimelineGeometry) -> ClosedRange<Double> {
        geometry.labelWidth...(geometry.contentWidth - geometry.rightInset)
    }
}
