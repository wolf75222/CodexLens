import XCTest
@testable import LensCore

final class RecordedCommandStatusTests: XCTestCase {
    func testReportedSuccessAndFailureRemainIndependent() {
        for output in ["Process exited with code 0", "Process exit code: 0", "exit code=0", "exited with status 0", "Success. Updated the following files:\nM A.swift", "note\nSuccess. Done", #"{"exit_code":0}"#, #"{"status":"completed"}"#] {
            XCTAssertTrue(SessionEngine.outputSucceeded(output), output)
            XCTAssertFalse(SessionEngine.outputFailed(output), output)
        }
        for output in ["Process exited with code 3", "exit code: 1", "exited with status 9", "Error: failed", "note\nFailed to read", #"{"isError":true}"#] {
            XCTAssertTrue(SessionEngine.outputFailed(output), output)
            XCTAssertFalse(SessionEngine.outputSucceeded(output), output)
        }
        XCTAssertTrue(SessionEngine.outputSucceeded("Success. Done\nError: later failure"))
        XCTAssertTrue(SessionEngine.outputFailed("Success. Done\nError: later failure"))
    }
    func testUnknownAndLargeResultsDoNotGainAnInventedStatus() {
        for output in ["done", "Success", "Not Success. Done", "not Error: failed", "exit code: 01"] {
            XCTAssertFalse(SessionEngine.outputSucceeded(output), output)
        }
        let padding = String(repeating: "unrelated output\n", count: 2000)
        XCTAssertFalse(SessionEngine.outputSucceeded(padding))
        XCTAssertFalse(SessionEngine.outputFailed(padding))
        XCTAssertTrue(SessionEngine.outputSucceeded(padding + "Process exited with code 0"))
        XCTAssertTrue(SessionEngine.outputFailed(padding + "Error: failed"))
        XCTAssertFalse(SessionEngine.outputSucceeded(String(repeating: "x", count: 9000) + "Success. Done"))
    }
}
