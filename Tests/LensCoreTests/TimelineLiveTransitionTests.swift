import XCTest
@testable import LensCore

final class TimelineLiveTransitionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func window(end: Date, span: TimeInterval = 60) throws -> TimelineWindow {
        try TimelineWindow(start: end.addingTimeInterval(-span), end: end)
    }
    func testDisplayMovesMonotonicallyWithoutChangingItsSpanOrClockEndpoints() throws {
        let source = try window(end: date), target = try window(end: date.addingTimeInterval(1))
        let transition = try XCTUnwrap(TimelineLiveTransition(source: source, target: target))
        var previous = source.end
        for step in 0...30 {
            let shown = transition.window(at: Double(step) / 30)
            XCTAssertGreaterThanOrEqual(shown.end, previous)
            XCTAssertLessThanOrEqual(shown.end, target.end)
            XCTAssertEqual(shown.duration, 60, accuracy: 0.000_01)
            previous = shown.end
        }
        XCTAssertEqual(transition.window(at: 0), source)
        XCTAssertEqual(transition.window(at: 1), target)
        XCTAssertEqual(transition.queryWindow.start, source.start)
        XCTAssertEqual(transition.queryWindow.end, target.end)
    }
    func testExplicitNavigationZoomAndClockJumpsHaveNoTransition() throws {
        let source = try window(end: date)
        for target in [try window(end: date), try window(end: date.addingTimeInterval(-1)),
                       try window(end: date.addingTimeInterval(3)), try window(end: date.addingTimeInterval(1), span: 300)] {
            XCTAssertNil(TimelineLiveTransition(source: source, target: target))
        }
    }
    func testInvalidProgressCannotMoveTheAxisOutsideTheRecordedDisplayBounds() throws {
        let source = try window(end: date), target = try window(end: date.addingTimeInterval(1))
        let transition = try XCTUnwrap(TimelineLiveTransition(source: source, target: target))
        XCTAssertEqual(transition.window(at: -.infinity), source)
        XCTAssertEqual(transition.window(at: .nan), source)
        XCTAssertEqual(transition.window(at: -5), source)
        XCTAssertEqual(transition.window(at: 5), target)
    }
}
