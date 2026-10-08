import Foundation
import XCTest
@testable import LensCore

final class OperationProgressTests: XCTestCase {
    func testRemainingIsPhaseLocalAndUnknownWorkDoesNotInventPercentage() {
        let measured = OperationProgress(stage: .readingMessages, completed: 7, total: 20, unit: .messages)
        XCTAssertEqual(measured.remaining, 13)
        XCTAssertEqual(measured.fraction, 0.35)
        let next = OperationProgress(stage: .savingExport)
        XCTAssertNil(next.fraction)
        XCTAssertNil(next.remaining)
        XCTAssertNil(OperationProgress(stage: .preparingTimeline, total: 0).fraction)
        let growing = OperationProgress(stage: .readingMessages, completed: 22, total: 20, unit: .messages)
        XCTAssertEqual(growing.remaining, 0)
        XCTAssertEqual(growing.fraction, 1)
    }

    func testReporterBoundsGrowingCompletionsAndPreservesPhaseChanges() {
        let capture = OperationProgressCapture()
        let reporter = OperationProgressReporter { capture.append($0) }
        reporter.send(.init(stage: .readingMessages, total: 10, unit: .messages))
        for value in 10...1000 { reporter.send(.init(stage: .readingMessages, completed: Int64(value), total: Int64(value), unit: .messages)) }
        XCTAssertLessThan(capture.values.count, 10)
        XCTAssertTrue(capture.values.contains { $0.completed == 10 })
        reporter.send(.init(stage: .savingExport, total: 1))
        reporter.send(.init(stage: .savingExport, completed: 1, total: 1))
        XCTAssertEqual(capture.values.suffix(2).map(\.remaining), [1, 0])
    }
}

private final class OperationProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OperationProgress] = []
    func append(_ progress: OperationProgress) { lock.lock(); defer { lock.unlock() }; storage.append(progress) }
    var values: [OperationProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}
