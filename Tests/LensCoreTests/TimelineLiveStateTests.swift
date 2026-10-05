import Foundation
import XCTest
@testable import LensCore

final class TimelineLiveStateTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_784_000.125)

    func testInitialStateIsStoppedWithoutAnInventedPeriod() {
        let state = TimelineLiveState()
        XCTAssertEqual(state.span, 300)
        XCTAssertNil(state.window)
        XCTAssertFalse(state.following)
        XCTAssertEqual(TimelineLiveState.suggestedSpans, [60, 300, 900])
    }

    func testSpanNormalizationIsFiniteBoundedAndPreservesFractions() {
        for invalid in [TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertEqual(TimelineLiveState(span: invalid).span, 300)
        }
        XCTAssertEqual(TimelineLiveState(span: -1).span, 10)
        XCTAssertEqual(TimelineLiveState(span: 0).span, 10)
        XCTAssertEqual(TimelineLiveState(span: 100_000).span, 3600)
        XCTAssertEqual(TimelineLiveState(span: 60.25).span, 60.25)
    }

    func testResumeFramesExactInstantAndChosenSpan() throws {
        var state = TimelineLiveState(span: 60.25)
        state.resume(at: epoch)
        let window = try XCTUnwrap(state.window)
        XCTAssertTrue(state.following)
        XCTAssertEqual(window.end, epoch)
        XCTAssertEqual(window.start, epoch.addingTimeInterval(-60.25))
        XCTAssertEqual(window.duration, 60.25)
    }

    func testTickAdvancesWithoutRoundingRecordedInstants() throws {
        var state = TimelineLiveState(span: 60)
        state.resume(at: epoch)
        let now = epoch.addingTimeInterval(1.0625)
        state.tick(at: now)
        XCTAssertEqual(try XCTUnwrap(state.window).end, now)
        XCTAssertEqual(state.window?.start, now.addingTimeInterval(-60))
    }

    func testTickDoesNotStartFollowingByItself() {
        var state = TimelineLiveState()
        let initial = state
        state.tick(at: epoch)
        XCTAssertEqual(state, initial)
    }

    func testPauseKeepsExactWindowDespiteCollectionClockAdvancing() {
        var state = TimelineLiveState()
        state.resume(at: epoch)
        state.pause()
        let paused = state
        state.tick(at: epoch.addingTimeInterval(900))
        XCTAssertEqual(state, paused)
    }

    func testResumeAfterPauseUsesPresentWithoutDependingOnAnEvent() throws {
        var state = TimelineLiveState()
        state.resume(at: epoch)
        state.pause()
        let now = epoch.addingTimeInterval(900)
        state.resume(at: now)
        XCTAssertTrue(state.following)
        XCTAssertEqual(try XCTUnwrap(state.window).end, now)
        XCTAssertEqual(state.window?.duration, 300)
    }

    func testExplicitResumeCanReframeToAnEarlierInstant() {
        var state = TimelineLiveState()
        state.resume(at: epoch.addingTimeInterval(500))
        state.resume(at: epoch)
        XCTAssertEqual(state.window?.end, epoch)
        state.tick(at: epoch.addingTimeInterval(1))
        XCTAssertEqual(state.window?.end, epoch.addingTimeInterval(1))
    }

    func testClockReversalKeepsWindowUntilPreviousInstantIsPassed() {
        var state = TimelineLiveState()
        state.resume(at: epoch)
        state.tick(at: epoch.addingTimeInterval(2))
        let beforeReversal = state
        state.tick(at: epoch.addingTimeInterval(-30))
        state.tick(at: epoch)
        state.tick(at: epoch.addingTimeInterval(2))
        XCTAssertEqual(state, beforeReversal)
        state.tick(at: epoch.addingTimeInterval(3))
        XCTAssertEqual(state.window?.end, epoch.addingTimeInterval(3))
    }

    func testSpanChangeInFollowKeepsEndMonotone() {
        var state = TimelineLiveState(span: 60)
        state.resume(at: epoch)
        state.setSpan(900, at: epoch.addingTimeInterval(-5))
        XCTAssertEqual(state.span, 900)
        XCTAssertEqual(state.window?.end, epoch)
        XCTAssertEqual(state.window?.start, epoch.addingTimeInterval(-900))
        state.setSpan(60, at: epoch.addingTimeInterval(10))
        XCTAssertEqual(state.window?.end, epoch.addingTimeInterval(10))
        XCTAssertEqual(state.window?.duration, 60)
    }

    func testSpanChangeWhilePausedRetainsSelectedPeriodUntilResume() {
        var state = TimelineLiveState(span: 60)
        state.resume(at: epoch)
        state.pause()
        let pausedWindow = state.window
        state.setSpan(900, at: epoch.addingTimeInterval(500))
        XCTAssertEqual(state.window, pausedWindow)
        XCTAssertEqual(state.span, 900)
        XCTAssertFalse(state.following)
        state.resume(at: epoch.addingTimeInterval(600))
        XCTAssertEqual(state.window?.duration, 900)
    }

    func testInspectKeepsChosenHistoricalPeriodWithoutChangingLiveSpan() throws {
        var state = TimelineLiveState(span: 900)
        state.resume(at: epoch)
        let historical = try TimelineWindow(start: epoch.addingTimeInterval(-4000), end: epoch.addingTimeInterval(-3999.5))
        state.inspect(window: historical)
        state.tick(at: epoch.addingTimeInterval(10))
        XCTAssertEqual(state.window, historical)
        XCTAssertFalse(state.following)
        XCTAssertEqual(state.span, 900)
        state.resume(at: epoch.addingTimeInterval(10))
        XCTAssertEqual(state.window?.duration, 900)
    }

    func testInspectionAlsoAcceptsExactPointSelection() throws {
        var state = TimelineLiveState()
        let point = try TimelineWindow(start: epoch, end: epoch)
        state.inspect(window: point)
        XCTAssertEqual(state.window, point)
        XCTAssertFalse(state.following)
    }

    func testInvalidAndUnrepresentableDatesDoNotDestroyState() {
        var state = TimelineLiveState()
        state.resume(at: epoch)
        let before = state
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            let invalid = Date(timeIntervalSince1970: value)
            state.tick(at: invalid)
            XCTAssertEqual(state, before)
            state.resume(at: invalid)
            XCTAssertEqual(state, before)
        }
        var initial = TimelineLiveState()
        initial.resume(at: Date(timeIntervalSince1970: .infinity))
        XCTAssertNil(initial.window)
        XCTAssertFalse(initial.following)
    }

    func testDistantFiniteDatesWithRepresentableSpansStillWork() {
        for date in [Date.distantPast, Date.distantFuture] {
            var state = TimelineLiveState(span: 3600)
            state.resume(at: date)
            XCTAssertEqual(state.window?.end, date)
            XCTAssertEqual(state.window?.duration, 3600)
            XCTAssertTrue(state.following)
        }
    }

    func testInvalidClockDuringSpanChangeDefersWindowUpdateUntilValidTick() {
        var state = TimelineLiveState(span: 60)
        state.resume(at: epoch)
        let original = state.window
        state.setSpan(.nan, at: Date(timeIntervalSince1970: .nan))
        XCTAssertEqual(state.span, 300)
        XCTAssertEqual(state.window, original)
        state.tick(at: epoch.addingTimeInterval(1))
        XCTAssertEqual(state.window?.duration, 300)
    }

    func testResetRetainsPreferenceButClearsClockAndFollowingState() {
        var state = TimelineLiveState(span: 900)
        state.resume(at: epoch)
        state.reset()
        XCTAssertEqual(state, TimelineLiveState(span: 900))
        state.tick(at: epoch.addingTimeInterval(1000))
        XCTAssertNil(state.window)
    }

    func testViewingClockDoesNotRewriteRecordedStartOrUnknownEnd() throws {
        let item = TimelineItem(eventID: "recorded-call", agentID: "child", laneIndex: 0, lanePosition: 0,
                                start: epoch, recordedEnd: nil, kind: .toolCall, isError: false)
        var state = TimelineLiveState(span: 60)
        state.resume(at: epoch)
        state.tick(at: epoch.addingTimeInterval(30))
        let overlap = try XCTUnwrap(item.overlap(with: XCTUnwrap(state.window)))
        XCTAssertEqual(overlap.visibleStart, epoch)
        XCTAssertEqual(overlap.visibleEnd, epoch)
        XCTAssertEqual(item.start, epoch)
        XCTAssertNil(item.recordedEnd)
        XCTAssertNil(item.recordedDuration)
        requireSendable(state)
    }

    private func requireSendable<T: Sendable>(_ value: T) {}
}
