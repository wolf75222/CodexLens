import XCTest
@testable import LensCore

final class EvidenceAddressTests: XCTestCase {
    func testExactCapturedWorktreeAndVersionRemainIndependentOfCurrentFile() throws {
        let location = EvidenceLocation(environmentID: "/fixture/A", path: "/fixture/A/main.swift", versionKind: .capturedCurrent, version: "captured-version", side: .after, firstLine: 17, lastLine: 19)
        let capsule = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(timeIntervalSince1970: 1), pieces: [EvidencePiece(id: "E001", kind: "code", title: "main.swift", text: "old captured bytes", location: location)], id: "old")
        let address = try EvidenceAddress(rootID: "root", capsuleID: capsule.id, pieceID: "E001")
        XCTAssertEqual(try EvidenceAddress(url: address.url), address)
        XCTAssertEqual(try address.resolve(in: capsule).text, "old captured bytes")
        XCTAssertEqual(try address.resolve(in: capsule).location, location)
        let newer = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: [EvidencePiece(id: "E001", kind: "code", title: "main.swift", text: "changed bytes")], id: "new")
        XCTAssertThrowsError(try address.resolve(in: newer))
        XCTAssertThrowsError(try EvidenceAddress(rootID: "other-root", capsuleID: capsule.id, pieceID: "E001").resolve(in: capsule))
        XCTAssertThrowsError(try EvidenceAddress(rootID: "root", capsuleID: capsule.id, pieceID: "E999").resolve(in: capsule))
    }
    func testLegacyCapsuleStillDecodesAndVerifiesWithoutLocation() throws {
        let capsule = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(timeIntervalSince1970: 1), pieces: [EvidencePiece(id: "E001", kind: "event", title: "legacy", text: "recorded")], id: "legacy")
        let data = try capsule.transmissionJSON()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("location"))
        let decoded = try CapsuleJSON.decode(EvidenceCapsule.self, from: data)
        XCTAssertNil(decoded.pieces[0].location); XCTAssertTrue(try decoded.verifyDigest())
    }
    func testUnknownExternalAndAmbiguousLinksAreRejected() {
        for raw in ["https://example.com/a", "codexlens://session/root?type=evidence&id=E001&capsule=a&capsule=b", "codexlens://session/root?type=evidence&id=E001&capsule=a&file=/current", "codexlens://session/root?type=evidence&id=Ebad&capsule=a", "codexlens://session/root/other?type=evidence&id=E001&capsule=a", "codexlens://session/root?type=evidence&id=E001&capsule=a#current"] { XCTAssertThrowsError(try EvidenceAddress(url: URL(string: raw)!)) }
    }
    func testCoordinatesSeparateFragmentSideAndWorktree() throws {
        let a = EvidenceLocation(environmentID: "/fixture/A", path: "main.swift", versionKind: .recordedFragment, side: .before, coordinates: .fragment, firstLine: 2, hunkID: "h1")
        let b = EvidenceLocation(environmentID: "/fixture/B", path: "main.swift", versionKind: .recordedFragment, side: .after, coordinates: .fragment, firstLine: 2, hunkID: "h1")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try JSONDecoder().decode(EvidenceLocation.self, from: JSONEncoder().encode(a)), a)
    }
}
