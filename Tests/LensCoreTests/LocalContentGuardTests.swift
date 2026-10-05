import XCTest
import Darwin
@testable import LensCore

final class LocalContentGuardTests: XCTestCase {
    func testKnownPlaceholderRejectedWithoutReadingOrHydration() {
        XCTAssertThrowsError(try LocalContentGuard.requireResident(path: "/cloud/absent.txt", flags: UInt32(SF_DATALESS))) { error in
            guard let lensError = error as? LensError, case .unavailable = lensError else {
                return XCTFail("A nonresident file must be rejected as unavailable, without opening it")
            }
        }
        XCTAssertNoThrow(try LocalContentGuard.requireResident(path: "/resident.txt", flags: 0))
        XCTAssertNoThrow(try LocalContentGuard.requireResident(path: "/compressed.txt", flags: UInt32(UF_COMPRESSED)))
    }
}
