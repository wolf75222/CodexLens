import Foundation
import XCTest
@testable import LensCore

final class TimelineZoomRoundTripTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_784_000)
    private let viewportWidth = 900.0

    func testGroupFocusDetailsAndZoomOutRestoreTheOriginalGroups() throws {
        let projection = try denseProjection()
        let bounds = try XCTUnwrap(projection.bounds)
        let originalIDs = projection.orderedEventIDs
        let originalFingerprint = projection.fingerprintSHA256
        let overviewGeometry = try geometry(bounds: bounds, zoom: 1)
        let overview = density(projection, geometry: overviewGeometry, origin: 0)
        let selected = try XCTUnwrap(projection.item(id: "event-6000"))
        let clickedGroup = try XCTUnwrap(overview.clusters.first { contains($0.window, selected.start) })
        XCTAssertEqual(overview.totalMatches, 12_014)
        XCTAssertGreaterThan(clickedGroup.count, 2)

        let firstFocus = try focus(clickedGroup.window, bounds: bounds)
        var placement = firstFocus
        var focusedGeometry = try geometry(bounds: bounds, zoom: placement.zoom)
        var focused = density(projection, geometry: focusedGeometry, origin: placement.originX)
        // A crowded group can require another focus before its events have room.
        // Every step keeps the full session axis so a later zoom-out can recover it.
        for _ in 0..<6 where !focused.details.contains(where: { $0.id == selected.id }) {
            let group = try XCTUnwrap(focused.clusters.first { contains($0.window, selected.start) })
            let next = try focus(group.window, bounds: bounds)
            XCTAssertGreaterThan(next.zoom, placement.zoom)
            placement = next
            focusedGeometry = try geometry(bounds: bounds, zoom: placement.zoom)
            focused = density(projection, geometry: focusedGeometry, origin: placement.originX)
        }
        XCTAssertTrue(focused.details.contains { $0.id == selected.id })
        XCTAssertGreaterThan(placement.zoom, TimelineInteraction.zoomRange.upperBound,
                             "A long session needs a focus finer than the former 80× ceiling")
        XCTAssertEqual(focusedGeometry.window, bounds)

        let restoredPlacement = try zoomOut(focusedGeometry, from: placement)
        XCTAssertEqual(restoredPlacement.zoom, 1)
        XCTAssertEqual(restoredPlacement.originX, 0)
        let restoredGeometry = try geometry(bounds: bounds, zoom: restoredPlacement.zoom)
        let restored = density(projection, geometry: restoredGeometry, origin: restoredPlacement.originX)
        assertSameRepresentation(restored, overview)
        XCTAssertEqual(try focus(clickedGroup.window, bounds: bounds), firstFocus,
                       "The restored group must remain focusable with the same target")
        XCTAssertEqual(projection.orderedEventIDs, originalIDs)
        XCTAssertEqual(projection.fingerprintSHA256, originalFingerprint)
        XCTAssertEqual(projection.item(id: selected.id), selected)
    }

    func testFineFocusAbove80KeepsPinchAnchorAndCanReturnToOverview() throws {
        let bounds = try window(0, 3600)
        let requested = try window(1799.999, 1800.001)
        let placement = try focus(requested, bounds: bounds)
        XCTAssertGreaterThan(placement.zoom, 80)
        XCTAssertLessThanOrEqual(placement.zoom, TimelineInteraction.maximumFocusZoom)
        let before = try geometry(bounds: bounds, zoom: placement.zoom)
        assertVisible(requested, geometry: before, origin: placement.originX)

        let focalX = 510.0
        let pinched = try XCTUnwrap(TimelineInteraction.anchoredZoom(
            geometry: before, baseContentWidth: viewportWidth, viewportWidth: viewportWidth,
            originX: placement.originX, focalViewportX: focalX, targetZoom: placement.zoom * 0.8,
            maximumZoom: TimelineInteraction.maximumFocusZoom))
        XCTAssertGreaterThan(pinched.zoom, 80)
        let after = try geometry(bounds: bounds, zoom: pinched.zoom)
        XCTAssertEqual(after.window, bounds)
        XCTAssertEqual(after.date(atX: pinched.originX + pinched.anchorViewportX, clamped: false)
            .timeIntervalSince(pinched.anchorDate), 0, accuracy: 0.000_001)

        // Existing callers retain their documented 80× ceiling unless they opt in.
        let legacy = try XCTUnwrap(TimelineInteraction.anchoredZoom(
            geometry: before, baseContentWidth: viewportWidth, viewportWidth: viewportWidth,
            originX: placement.originX, focalViewportX: focalX, targetZoom: placement.zoom))
        XCTAssertEqual(legacy.zoom, 80)
        let overview = try zoomOut(after, from: pinched)
        XCTAssertEqual(overview.zoom, 1)
        XCTAssertEqual(overview.originX, 0)
    }

    func testFocusAtBothSessionEdgesStaysVisibleWithoutBlankSpace() throws {
        let bounds = try window(0, 3600)
        for requested in [try window(0, 0.01), try window(3599.99, 3600)] {
            let placement = try focus(requested, bounds: bounds)
            let focused = try geometry(bounds: bounds, zoom: placement.zoom)
            XCTAssertTrue(placement.originX.isFinite)
            XCTAssertGreaterThanOrEqual(placement.originX, 0)
            XCTAssertLessThanOrEqual(placement.originX, focused.contentWidth - viewportWidth)
            assertVisible(requested, geometry: focused, origin: placement.originX)
            let restored = try zoomOut(focused, from: placement)
            XCTAssertEqual(restored.originX, 0)
            XCTAssertEqual(try geometry(bounds: bounds, zoom: restored.zoom).window, bounds)
        }
    }

    func testSimultaneousEventsStayGroupedWhenZoomCannotSeparateTheirTimes() throws {
        var rows = (0..<100).map { event("same-\($0)", at: 10, offset: UInt64($0)) }
        rows.append(event("start", at: 0, offset: 100))
        rows.append(event("end", at: 20, offset: 101))
        let projection = try TimelineProjection.prepare(events: rows, agents: [])
        let bounds = try XCTUnwrap(projection.bounds)
        let overviewGeometry = try geometry(bounds: bounds, zoom: 1)
        let overview = density(projection, geometry: overviewGeometry, origin: 0)
        let placement = try focus(try window(10, 10), bounds: bounds)
        let focusedGeometry = try geometry(bounds: bounds, zoom: placement.zoom)
        let focused = density(projection, geometry: focusedGeometry, origin: placement.originX)
        XCTAssertEqual(focused.totalMatches, 100)
        XCTAssertTrue(focused.details.isEmpty)
        XCTAssertFalse(focused.clusters.isEmpty)
        XCTAssertTrue(focused.clusters.allSatisfy { $0.count == 100 })
        XCTAssertNotNil(projection.item(id: "same-99"),
                        "Grouping must not make an event outside the bounded sample inaccessible")

        let restored = try zoomOut(focusedGeometry, from: placement)
        assertSameRepresentation(density(projection, geometry: try geometry(bounds: bounds, zoom: restored.zoom),
                                         origin: restored.originX), overview)
        XCTAssertEqual(projection.eventCount, 102)
    }

    func testRepeatedZoomCyclesPreserveIndexedIDsAndRestoreCounts() throws {
        let projection = try denseProjection()
        let bounds = try XCTUnwrap(projection.bounds)
        let originalIDs = projection.orderedEventIDs
        let originalFingerprint = projection.fingerprintSHA256
        let overviewGeometry = try geometry(bounds: bounds, zoom: 1)
        let overview = density(projection, geometry: overviewGeometry, origin: 0)
        let group = try XCTUnwrap(overview.clusters.dropFirst(8).first)
        let selectedID = "event-6000"
        for cycle in 0..<20 {
            let placement = try focus(group.window, bounds: bounds)
            let focusedGeometry = try geometry(bounds: bounds, zoom: placement.zoom)
            let restored = try zoomOut(focusedGeometry, from: placement)
            let result = density(projection, geometry: try geometry(bounds: bounds, zoom: restored.zoom),
                                 origin: restored.originX)
            assertSameRepresentation(result, overview)
            XCTAssertEqual(projection.orderedEventIDs, originalIDs, "Cycle \(cycle)")
            XCTAssertEqual(projection.fingerprintSHA256, originalFingerprint, "Cycle \(cycle)")
            XCTAssertEqual(projection.item(id: selectedID)?.id, selectedID, "Cycle \(cycle)")
        }
    }

    func testFocusRejectsUnrelatedRangesAndInvalidViewportSizes() throws {
        let bounds = try window(0, 3600)
        for unrelated in [try window(-1, 1), try window(3599, 3601), try window(4000, 4001)] {
            XCTAssertNil(TimelineInteraction.focusPlacement(window: unrelated, within: bounds,
                                                            baseContentWidth: viewportWidth,
                                                            viewportWidth: viewportWidth))
        }
        let requested = try window(10, 11)
        XCTAssertNil(TimelineInteraction.focusPlacement(window: requested, within: bounds,
                                                        baseContentWidth: .infinity, viewportWidth: viewportWidth))
        XCTAssertNil(TimelineInteraction.focusPlacement(window: requested, within: bounds,
                                                        baseContentWidth: viewportWidth, viewportWidth: .nan))
        XCTAssertNil(TimelineInteraction.focusPlacement(window: requested, within: bounds,
                                                        baseContentWidth: 800, viewportWidth: viewportWidth))
        XCTAssertNil(TimelineInteraction.focusPlacement(window: requested, within: bounds,
                                                        baseContentWidth: viewportWidth, viewportWidth: 160))
    }

    private func denseProjection() throws -> TimelineProjection {
        try TimelineProjection.prepare(events: (0..<12_014).map {
            event("event-\($0)", at: Double($0), offset: UInt64($0))
        }, agents: [])
    }

    private func event(_ id: String, at seconds: Double, offset: UInt64) -> LensEvent {
        LensEvent(id: id, timestamp: epoch.addingTimeInterval(seconds), agentID: "root", kind: .toolCall,
                  title: "Recorded event", source: SourceRef(path: "/anonymous/root.jsonl", offset: offset))
    }

    private func window(_ start: Double, _ end: Double) throws -> TimelineWindow {
        try TimelineWindow(start: epoch.addingTimeInterval(start), end: epoch.addingTimeInterval(end))
    }

    private func contains(_ window: TimelineWindow, _ date: Date) -> Bool {
        date >= window.start && date <= window.end
    }

    private func geometry(bounds: TimelineWindow, zoom: Double) throws -> TimelineGeometry {
        try TimelineGeometry(window: bounds, contentWidth: viewportWidth * zoom, minimumTimeSpan: 0.001)
    }

    private func focus(_ window: TimelineWindow, bounds: TimelineWindow) throws -> TimelineZoomPlacement {
        try XCTUnwrap(TimelineInteraction.focusPlacement(window: window, within: bounds,
                                                        baseContentWidth: viewportWidth,
                                                        viewportWidth: viewportWidth))
    }

    private func zoomOut(_ geometry: TimelineGeometry, from placement: TimelineZoomPlacement) throws -> TimelineZoomPlacement {
        try XCTUnwrap(TimelineInteraction.anchoredZoom(
            geometry: geometry, baseContentWidth: viewportWidth, viewportWidth: viewportWidth,
            originX: placement.originX, focalViewportX: placement.anchorViewportX, targetZoom: 1,
            maximumZoom: TimelineInteraction.maximumFocusZoom))
    }

    private func density(_ projection: TimelineProjection, geometry: TimelineGeometry,
                         origin: Double) -> TimelineDensityResult {
        projection.density(lane: 0, geometry: geometry,
                           xRange: (origin + geometry.labelWidth)...(origin + viewportWidth - geometry.rightInset))
    }

    private func assertVisible(_ requested: TimelineWindow, geometry: TimelineGeometry, origin: Double,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(geometry.x(for: requested.start) - origin,
                                   geometry.labelWidth - 0.000_1, file: file, line: line)
        XCTAssertLessThanOrEqual(geometry.x(for: requested.end) - origin,
                                viewportWidth - geometry.rightInset + 0.000_1, file: file, line: line)
    }

    private func assertSameRepresentation(_ result: TimelineDensityResult, _ expected: TimelineDensityResult,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.totalMatches, expected.totalMatches, file: file, line: line)
        XCTAssertEqual(result.details.map(\.id), expected.details.map(\.id), file: file, line: line)
        XCTAssertEqual(result.clusters.map(\.id), expected.clusters.map(\.id), file: file, line: line)
        XCTAssertEqual(result.clusters.map(\.window), expected.clusters.map(\.window), file: file, line: line)
        XCTAssertEqual(result.clusters.map(\.count), expected.clusters.map(\.count), file: file, line: line)
        XCTAssertEqual(result.clusters.map(\.errorCount), expected.clusters.map(\.errorCount), file: file, line: line)
        XCTAssertEqual(result.clusters.map(\.compactionCount), expected.clusters.map(\.compactionCount), file: file, line: line)
        XCTAssertEqual(result.clusters.map(\.sampleEventIDs), expected.clusters.map(\.sampleEventIDs), file: file, line: line)
    }
}
