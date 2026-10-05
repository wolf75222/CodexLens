import Foundation
import XCTest
@testable import LensCore

final class CachePreflightTests: XCTestCase {
    func testLowerBoundUsesUTF8AndKeepsEqualAndSmallInputsEligible() {
        XCTAssertFalse(SessionEngine.cacheTextExceedsByteLimit([], limit: 0))
        XCTAssertFalse(SessionEngine.cacheTextExceedsByteLimit(["é", "ab"], limit: 4))
        XCTAssertTrue(SessionEngine.cacheTextExceedsByteLimit(["é", "ab"], limit: 3))
        XCTAssertTrue(SessionEngine.cacheTextExceedsByteLimit(["x"], limit: 0))
        XCTAssertTrue(SessionEngine.cacheTextExceedsByteLimit([], limit: -1))
        XCTAssertFalse(SessionEngine.cacheTextExceedsByteLimit(["abc"], limit: Int.max))
    }

    func testLargeSharedPayloadStopsAtTheFirstProvablyOversizedPreview() {
        let oneMiB = String(repeating: "x", count: 1024 * 1024)
        var inspected = 0
        let previews = (0..<1000).lazy.map { _ in inspected += 1; return oneMiB }
        XCTAssertTrue(SessionEngine.cacheTextExceedsByteLimit(previews, limit: 64 * 1024 * 1024))
        XCTAssertEqual(inspected, 65, "Do not visit the remaining payload after proving it exceeds the cache limit")
    }

    func testLowerBoundNeverReplacesTheActualEncodedByteLimit() throws {
        let texts = ["\"\n\\é", "a/b"]
        let rawBytes = texts.reduce(0) { $0 + $1.utf8.count }
        let encodedBytes = try JSONEncoder().encode(texts).count
        XCTAssertGreaterThan(encodedBytes, rawBytes)
        XCTAssertFalse(SessionEngine.cacheTextExceedsByteLimit(texts, limit: rawBytes))
        XCTAssertTrue(SessionEngine.cacheTextExceedsByteLimit(texts, limit: rawBytes - 1))
    }
}
