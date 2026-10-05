import XCTest
@testable import LensCore

final class FrozenCapsuleIdentityTests: XCTestCase {
    func testSubmillisecondDatesDoNotCreateANewRecordedVersion() throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let piece = EvidencePiece(id: "E001", kind: "recorded", title: "Fixture", text: "preuve", environmentID: "/fixture/worktree-a", capturedAt: time)
        let original = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: time, pieces: [piece], createdAt: time)
        let reloaded = try CapsuleJSON.decode(EvidenceCapsule.self, from: CapsuleJSON.encode(original))
        XCTAssertNotEqual(original, reloaded)
        XCTAssertTrue(try original.verifyDigest()); XCTAssertTrue(try reloaded.verifyDigest())
        XCTAssertEqual(try original.transmissionJSON(), try reloaded.transmissionJSON())
        XCTAssertTrue(original.representsSameFrozenContent(as: reloaded))
    }
    func testChangedContentOrWorktreeWithSameCapsuleIDIsAnotherVersion() throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        func capsule(text: String, environment: String, root: String = "root") throws -> EvidenceCapsule {
            try EvidenceCapsule.build(rootThreadID: root, collectionCut: time, pieces: [EvidencePiece(id: "E001", kind: "recorded", title: "same.swift", text: text, environmentID: environment, capturedAt: time)], id: "same-capsule", createdAt: time)
        }
        let original = try capsule(text: "avant", environment: "/fixture/worktree-a")
        XCTAssertFalse(original.representsSameFrozenContent(as: try capsule(text: "après", environment: "/fixture/worktree-a")))
        XCTAssertFalse(original.representsSameFrozenContent(as: try capsule(text: "avant", environment: "/fixture/worktree-b")))
        XCTAssertFalse(original.representsSameFrozenContent(as: try capsule(text: "avant", environment: "/fixture/worktree-a", root: "another-root")))
    }
}
