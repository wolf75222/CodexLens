import XCTest
@testable import LensCore

final class SessionPickerTargetTests: XCTestCase {
    func testCodexThreadLinkResolvesBeforeUnrelatedSelection() {
        let id = "aaaaaaa1-1111-4111-8111-111111111111"
        for link in ["codex://threads/" + id, " \ncodex://threads/" + id.uppercased() + "?view=review#detail\n"] {
            XCTAssertEqual(SessionPickerTarget.sessionID(from: link), id)
            XCTAssertEqual(SessionPickerTarget.resolve(text: link, selectedID: "other", visibleIDs: ["other"]), id)
        }
    }
    func testInvalidOrUnrelatedURLNeverOpensAnotherVisibleSession() {
        let id = "aaaaaaa1-1111-4111-8111-111111111111"
        for link in ["https://example.com/threads/" + id, "codex://agents/" + id,
                     "codex://threads/" + id + "/extra", "codex://threads/" + id + "/",
                     "codex://threads", "codex://threads/not-a-thread", "codex://someone@threads/" + id,
                     "codex://threads:42/" + id, "codex://threads/" + id + " extra"] {
            XCTAssertNil(SessionPickerTarget.sessionID(from: link), link)
            XCTAssertNil(SessionPickerTarget.resolve(text: link, selectedID: "other", visibleIDs: ["other"]), link)
        }
    }
    func testSearchTitleIsNeverPassedAsAnID() {
        XCTAssertNil(SessionPickerTarget.resolve(text: "erreur compilation", selectedID: nil, visibleIDs: ["root-a", "root-b"]))
        XCTAssertEqual(SessionPickerTarget.resolve(text: "erreur compilation", selectedID: "root-b", visibleIDs: ["root-a", "root-b"]), "root-b")
    }
    func testSingleResultOpensItsIdentityAndObsoleteSelectionIsIgnored() {
        XCTAssertEqual(SessionPickerTarget.resolve(text: "rapport", selectedID: "old-root", visibleIDs: ["new-root"]), "new-root")
        XCTAssertNil(SessionPickerTarget.resolve(text: "rapport", selectedID: "old-root", visibleIDs: ["new-a", "new-b"]))
        XCTAssertNil(SessionPickerTarget.resolve(text: "rapport", selectedID: nil, visibleIDs: []))
    }
    func testPastedIDWinsOverSelectionAndTrimsOnlyOuterWhitespace() {
        let id = "aaaaaaa1-0000-4000-8000-000000000001"
        XCTAssertEqual(SessionPickerTarget.resolve(text: "  \(id)\n", selectedID: "another", visibleIDs: ["another"]), id)
        XCTAssertEqual(SessionPickerTarget.resolve(text: id.uppercased(), selectedID: nil, visibleIDs: []), id)
        XCTAssertNil(SessionPickerTarget.resolve(text: "aaaaaaa1-0000-4000-8000-000000000001 extra", selectedID: nil, visibleIDs: []))
    }
}
