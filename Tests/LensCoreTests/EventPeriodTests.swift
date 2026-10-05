import XCTest
@testable import LensCore

final class EventPeriodTests: XCTestCase {
    func testCallBeginningBeforeSelectedPeriodStillOverlaps() {
        let origin = Date(timeIntervalSince1970: 1000)
        let event = LensEvent(id: "wait", timestamp: origin, endTime: origin.addingTimeInterval(20), agentID: "a", kind: .wait, source: SourceRef(path: "/trace", offset: 0, length: 1, line: 1))
        XCTAssertTrue(event.overlaps(origin.addingTimeInterval(10)...origin.addingTimeInterval(12)))
        XCTAssertFalse(event.overlaps(origin.addingTimeInterval(21)...origin.addingTimeInterval(22)))
    }
    func testPointEventsAndInvalidNegativeDurationUseRecordedStart() {
        let origin = Date(timeIntervalSince1970: 1000)
        var event = LensEvent(id: "point", timestamp: origin, agentID: "a", source: SourceRef(path: "/trace", offset: 0, length: 1, line: 1))
        XCTAssertTrue(event.overlaps(origin...origin))
        event.endTime = origin.addingTimeInterval(-20)
        XCTAssertFalse(event.overlaps(origin.addingTimeInterval(-10)...origin.addingTimeInterval(-5)))
        XCTAssertTrue(event.overlaps(origin...origin.addingTimeInterval(1)))
    }
}
