import Foundation
import XCTest
@testable import LensCore

final class ChatContextOverviewTests: XCTestCase {
    func testSameRelativeFileKeepsWorktreeAndVersionIdentity() throws {
        let pieces = [
            EvidencePiece(id: "E001", kind: "verifiedHistoricalCode", title: "src/Same.swift", text: "alpha old bytes", environmentID: "/alpha", knownVersion: "alpha-sha", location: EvidenceLocation(environmentID: "/alpha", path: "src/Same.swift", versionKind: .verifiedGitBlob, version: "alpha-sha")),
            EvidencePiece(id: "E002", kind: "recordedPatch", title: "src/Same.swift", text: "beta requested patch", environmentID: "/beta", location: EvidenceLocation(environmentID: "/beta", path: "src/Same.swift", versionKind: .recordedFragment))]
        let capsule = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: pieces)
        let overview = try ChatContextOverview(capsule: capsule)
        XCTAssertEqual(overview.environments, ["/alpha", "/beta"])
        XCTAssertEqual(overview.textBytes, pieces.reduce(0) { $0 + $1.text.utf8.count })
        XCTAssertNotEqual(overview.sources[0].id, overview.sources[1].id)
        XCTAssertEqual(overview.sources[0].version, "alpha-sha")
        XCTAssertNil(overview.sources[1].version)
        XCTAssertEqual(overview.sources[1].location?.versionKind, .recordedFragment)
        for (source, piece) in zip(overview.sources, pieces) { XCTAssertEqual(try source.address.resolve(in: capsule), capsule.pieces.first { $0.id == piece.id }) }
    }
    func testSameCitationIDInTwoQuestionsHasDistinctAddress() throws {
        let piece = EvidencePiece(id: "E001", kind: "user", title: "Instruction", text: "first")
        let a = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: [piece])
        let b = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: [piece])
        let first = try ChatContextOverview(capsule: a).sources[0]
        let second = try ChatContextOverview(capsule: b).sources[0]
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertThrowsError(try first.address.resolve(in: b))
    }
    func testOverviewDoesNotRetainLongOutputText() throws {
        let text = String(repeating: "output content ", count: 3500)
        let capsule = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: [EvidencePiece(id: "E001", kind: "output", title: "Command result", text: text)])
        let overview = try ChatContextOverview(capsule: capsule)
        XCTAssertEqual(overview.textBytes, text.utf8.count)
        XCTAssertLessThan(overview.estimatedRetainedBytes, overview.textBytes / 4)
        XCTAssertEqual(try overview.sources[0].address.resolve(in: capsule).text, text)
    }
    func testEmptyContextDoesNotInventFilesOrVersions() throws {
        let capsule = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: [], omissions: [EvidenceOmission(reason: "missing", omittedCount: 3)])
        let overview = try ChatContextOverview(capsule: capsule)
        XCTAssertTrue(overview.sources.isEmpty); XCTAssertTrue(overview.environments.isEmpty)
        XCTAssertEqual(overview.textBytes, 0); XCTAssertEqual(overview.omissionCount, 3)
    }
    func testTamperedArchiveCannotCreateSourceLinks() throws {
        let capsule = try EvidenceCapsule.build(rootThreadID: "root", collectionCut: Date(), pieces: [EvidencePiece(id: "E001", kind: "user", title: "Instruction", text: "original")])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(capsule)) as? [String: Any])
        var pieces = try XCTUnwrap(json["pieces"] as? [[String: Any]])
        pieces[0]["text"] = "changed"; json["pieces"] = pieces
        let tampered = try JSONDecoder().decode(EvidenceCapsule.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try ChatContextOverview(capsule: tampered))
    }
}
