import Foundation
import XCTest
@testable import LensCore

final class TimelineInteractionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_784_000)
    private func geometry(width: Double = 2400) throws -> TimelineGeometry {
        try TimelineGeometry(window: TimelineWindow(start: epoch, end: epoch.addingTimeInterval(3600)), contentWidth: width)
    }
    private func item(at start: Double, end: Double? = nil) throws -> TimelineItem {
        let event = LensEvent(id: "call", timestamp: epoch.addingTimeInterval(start),
                              endTime: end.map { epoch.addingTimeInterval($0) }, agentID: "beta",
                              kind: .toolCall, title: "Recorded call", source: SourceRef(path: "/anonymous/beta.jsonl", offset: 1))
        return try XCTUnwrap(TimelineProjection.prepare(events: [event], agents: []).item(id: "call"))
    }
    func testPinchKeepsInstantUnderCursorAndRoundTripReturnsOrigin() throws {
        let before = try geometry(), focal = 430.0, origin = 900.0
        let result = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 600,
                                                                   viewportWidth: 600, originX: origin,
                                                                   focalViewportX: focal, targetZoom: 6))
        let after = try geometry(width: 3600)
        let observed = after.date(atX: result.originX + focal, clamped: false)
        XCTAssertEqual(observed.timeIntervalSince1970, before.date(atX: origin + focal, clamped: false).timeIntervalSince1970, accuracy: 0.000_001)
        let restored = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: after, baseContentWidth: 600,
                                                                     viewportWidth: 600, originX: result.originX,
                                                                     focalViewportX: focal, targetZoom: 4))
        XCTAssertEqual(restored.originX, origin, accuracy: 0.000_001)
    }
    func testPlotAnchorAccountsForStickyLabelsRatherThanZoomingLabels() throws {
        let before = try geometry()
        let result = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 600,
                                                                   viewportWidth: 600, originX: 600,
                                                                   focalViewportX: 20, targetZoom: 5))
        XCTAssertEqual(result.anchorViewportX, before.labelWidth + 8)
        XCTAssertEqual(result.anchorDate.timeIntervalSince1970,
                       before.date(atX: 600 + before.labelWidth + 8, clamped: false).timeIntervalSince1970, accuracy: 0.000_001)
    }
    func testZoomAndEdgesStayBoundedWithoutNaNOrBlankSpace() throws {
        let before = try geometry()
        let inResult = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 600,
                                                                     viewportWidth: 600, originX: 10_000,
                                                                     focalViewportX: 599, targetZoom: 900))
        XCTAssertEqual(inResult.zoom, 80)
        XCTAssertGreaterThanOrEqual(inResult.originX, 0); XCTAssertLessThanOrEqual(inResult.originX, 600 * 80 - 600)
        let outResult = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 600,
                                                                      viewportWidth: 600, originX: 1800,
                                                                      focalViewportX: 599, targetZoom: -5))
        XCTAssertEqual(outResult.zoom, 1); XCTAssertEqual(outResult.originX, 0)
        XCTAssertNil(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 600, viewportWidth: 600, originX: 0, focalViewportX: .nan, targetZoom: 2))
        XCTAssertNil(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 600, viewportWidth: 100, originX: 0, focalViewportX: 50, targetZoom: 2))
        XCTAssertNil(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: .infinity, viewportWidth: 600, originX: 0, focalViewportX: 300, targetZoom: 2))
    }
    func testZoomWorksWithSmallViewportAndMinimumDocumentWidth() throws {
        let before = try geometry(width: 1000)
        let result = try XCTUnwrap(TimelineInteraction.anchoredZoom(geometry: before, baseContentWidth: 500,
                                                                   viewportWidth: 360, originX: 250,
                                                                   focalViewportX: 240, targetZoom: 3))
        let next = try geometry(width: 1500)
        XCTAssertEqual(next.date(atX: result.originX + 240, clamped: false).timeIntervalSince1970,
                       before.date(atX: 490, clamped: false).timeIntervalSince1970, accuracy: 0.000_001)
    }
    func testFocusUsesRecordedIntervalWithPaddingButDoesNotInventUnknownDuration() throws {
        let bounds = try TimelineWindow(start: epoch, end: epoch.addingTimeInterval(3600))
        let recorded = try item(at: 900, end: 960)
        let focus = try XCTUnwrap(TimelineInteraction.focusWindow(for: recorded, within: bounds))
        XCTAssertEqual(focus.start, epoch.addingTimeInterval(870)); XCTAssertEqual(focus.end, epoch.addingTimeInterval(990))
        XCTAssertEqual(recorded.recordedDuration, 60)
        let unknown = try item(at: 300)
        let pointFocus = try XCTUnwrap(TimelineInteraction.focusWindow(for: unknown, within: bounds))
        XCTAssertEqual(pointFocus.duration, 10); XCTAssertNil(unknown.recordedDuration)
        let reversed = try item(at: 300, end: 200)
        XCTAssertEqual(TimelineInteraction.focusWindow(for: reversed, within: bounds), pointFocus)
        XCTAssertNil(reversed.recordedDuration)
    }
    func testFocusClipsToActualBoundsAndRejectsUnrelatedPeriod() throws {
        let bounds = try TimelineWindow(start: epoch, end: epoch.addingTimeInterval(100))
        let atStart = try XCTUnwrap(TimelineInteraction.focusWindow(for: item(at: 0), within: bounds))
        XCTAssertEqual(atStart.start, bounds.start); XCTAssertEqual(atStart.end, epoch.addingTimeInterval(5))
        let long = try XCTUnwrap(TimelineInteraction.focusWindow(for: item(at: 0, end: 100), within: bounds))
        XCTAssertEqual(long, bounds)
        XCTAssertNil(TimelineInteraction.focusWindow(for: try item(at: 900), within: bounds))
    }
}
