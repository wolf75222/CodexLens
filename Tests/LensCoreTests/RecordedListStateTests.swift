import XCTest
@testable import LensCore

final class RecordedListStateTests: XCTestCase {
    func testLoadingDoesNotBecomeAnEmptyResult() {
        XCTAssertEqual(state(preparing: true, available: false), .preparing)
    }
    func testUnavailableSourcesDoNotProveNoActivity() {
        XCTAssertEqual(state(available: false), .sourcesUnavailable)
    }
    func testEmptyPartialRecordingRemainsExplicit() {
        XCTAssertEqual(state(partial: true), .noRecordedEvents(partial: true))
        XCTAssertEqual(state(), .noRecordedEvents(partial: false))
    }
    func testNoRecordedCallsDiffersFromAFilteredResult() {
        XCTAssertEqual(state(events: 10, callsOnly: true, partial: true), .noRecordedCalls(partial: true))
        XCTAssertEqual(state(events: 10, calls: 2, callsOnly: true), .noMatches)
        XCTAssertEqual(state(events: 10), .noMatches)
    }
    func testArchivedEventsRemainUsableWithoutSourceReader() {
        XCTAssertEqual(state(available: false, events: 10), .noMatches)
    }
    func testReversedPeriodCannotCreateARange() {
        let start = Date(timeIntervalSince1970: 10)
        XCTAssertNil(TimelinePeriodSelection(start: start, end: start.addingTimeInterval(-1)).range)
    }
    func testPeriodPreservesExactBoundsAndInstantSelection() {
        let start = Date(timeIntervalSince1970: 123.456)
        let end = start.addingTimeInterval(90000)
        XCTAssertEqual(TimelinePeriodSelection(start: start, end: end).range, start...end)
        XCTAssertEqual(TimelinePeriodSelection(start: start, end: start).range, start...start)
    }
    func testNonFinitePeriodIsRejected() {
        XCTAssertNil(TimelinePeriodSelection(start: Date(timeIntervalSince1970: .infinity), end: Date()).range)
    }
    private func state(preparing: Bool = false, available: Bool = true, events: Int = 0, calls: Int = 0, callsOnly: Bool = false, partial: Bool = false) -> RecordedListEmptyState {
        .resolve(isPreparing: preparing, sourcesAvailable: available, recordedEventCount: events, recordedCallCount: calls, callsOnly: callsOnly, hasCoverageIssues: partial)
    }
}
