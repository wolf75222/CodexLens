import Foundation
import CryptoKit
import XCTest
@testable import LensCore

final class ResourceRecoveryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lens-resource-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ text: String, path: String, root: URL) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }
    private func resource(_ name: String = "request.txt") -> ResourceRecord {
        .init(id: "recorded-resource", location: "/gone/attachments/" + name, roles: [.supplied], eventIDs: ["original-message"], availability: .missing)
    }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func search(_ root: URL, resource: ResourceRecord? = nil, proof: ResourceRecoveryRecordedDigest? = nil, limits: ResourceRecoveryLimits = .init()) async throws -> ResourceRecoveryReport {
        try await ResourceRecoveryService().search(resource: resource ?? self.resource(), roots: [.init(path: root.path, reason: "Fixture")], recordedDigest: proof, limits: limits)
    }

    func testNameAndVariantsRemainSeparateWithoutHistoricalClaim() async throws {
        let root = try fixture()
        _ = try write("current", path: "one/request.txt", root: root)
        _ = try write("old", path: "two/request-old.txt", root: root)
        _ = try write("copy", path: "two/request (2).txt", root: root)
        _ = try write("unrelated", path: "requester.txt", root: root)
        _ = try write("wrong type", path: "request.png", root: root)
        let report = try await search(root)
        XCTAssertEqual(report.candidates.count, 3)
        XCTAssertEqual(Set(report.candidates.map(\.id)).count, 3)
        XCTAssertEqual(report.candidates.filter { $0.confidence == .filename }.count, 1)
        XCTAssertTrue(report.candidates.allSatisfy { $0.confidence != .recordedDigest && $0.resourceID == "recorded-resource" && $0.originalLocation == "/gone/attachments/request.txt" })
        XCTAssertTrue(report.candidates.allSatisfy { $0.sha256.count == 64 && $0.filePreviewVersion != nil })
    }

    func testExplicitDigestFindsRenamedFileAndDoesNotCertifyOtherVersion() async throws {
        let root = try fixture()
        _ = try write("original bytes", path: "renamed.txt", root: root)
        _ = try write("later version", path: "request.txt", root: root)
        _ = try write("original bytes", path: "wrong-type.png", root: root)
        let proof = ResourceRecoveryRecordedDigest(sha256: digest("original bytes"), evidence: "Attachment bytes recorded in original-message")
        let report = try await search(root, proof: proof)
        XCTAssertEqual(report.candidates.count, 2)
        XCTAssertEqual(report.candidates.first?.confidence, .recordedDigest)
        XCTAssertEqual(report.candidates.first?.recordedDigest, proof)
        XCTAssertEqual(report.candidates.first?.path, root.appendingPathComponent("renamed.txt").path)
        XCTAssertEqual(report.candidates.last?.confidence, .filename)
    }

    func testMalformedDigestOrNoEvidenceIsRejected() async throws {
        let root = try fixture()
        for proof in [ResourceRecoveryRecordedDigest(sha256: "bad", evidence: "record"), ResourceRecoveryRecordedDigest(sha256: String(repeating: "a", count: 64), evidence: " ")] {
            do { _ = try await search(root, proof: proof); XCTFail("Unproven digest cannot establish identity") }
            catch ResourceRecoveryError.invalidDigest { }
        }
    }

    func testDuplicateAndOverlappingRootsDoNotDuplicateCandidates() async throws {
        let root = try fixture()
        _ = try write("same", path: "nested/request.txt", root: root)
        let roots: [ResourceRecoveryRoot] = [.init(path: root.path, reason: "A"), .init(path: root.path, reason: "B"), .init(path: root.appendingPathComponent("nested").path, reason: "C")]
        let report = try await ResourceRecoveryService().search(resource: resource(), roots: roots)
        XCTAssertEqual(report.candidates.count, 1)
    }

    func testMissingRootsAndSymlinksAreExplicitAndNotTraversed() async throws {
        let root = try fixture(), outside = try fixture()
        _ = try write("outside", path: "request.txt", root: outside)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("request.txt").path, withDestinationPath: outside.appendingPathComponent("request.txt").path)
        let report = try await ResourceRecoveryService().search(resource: resource(), roots: [.init(path: root.path, reason: "A"), .init(path: root.appendingPathComponent("gone").path, reason: "Missing")])
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertTrue(report.issues.contains { $0.category == "rootUnavailable" })
        XCTAssertEqual(report.issues.filter { $0.message == ResourceRecoveryError.symbolicLink.localizedDescription }.count, 2)
        do { _ = try await ResourceRecoveryService().inspectChosenFile(resource: resource(), path: root.appendingPathComponent("linked/request.txt").path); XCTFail("Ancestor symlink cannot escape the explicit path") }
        catch ResourceRecoveryError.symbolicLink { }
    }

    func testAuthenticationNamesAndContentsNeverBecomeCandidates() async throws {
        let root = try fixture()
        _ = try write("ordinary", path: "auth.json", root: root)
        _ = try write("-----BEGIN PRIVATE KEY-----\nsecret", path: "request.txt", root: root)
        _ = try write("ordinary", path: ".ssh/request-old.txt", root: root)
        let report = try await search(root)
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertTrue(report.issues.contains { $0.message == ResourceRecoveryError.restricted.localizedDescription })
        do { _ = try await ResourceRecoveryService().inspectChosenFile(resource: resource("auth.json"), path: root.appendingPathComponent("auth.json").path); XCTFail("Chosen files obey the same auth guard") }
        catch ResourceRecoveryError.restricted { }
    }

    func testChangedOrDeletedFileInvalidatesCandidate() async throws {
        let root = try fixture(), service = ResourceRecoveryService()
        let file = try write("version one", path: "request.txt", root: root)
        let candidate = try await service.inspectChosenFile(resource: resource(), path: file.path)
        XCTAssertEqual(candidate.confidence, .explicitlyChosen)
        let verified = try await service.validate(candidate)
        XCTAssertEqual(verified.version, candidate.version)
        try Data("version two, longer".utf8).write(to: file)
        do { _ = try await service.validate(candidate); XCTFail("A later file cannot be served as the observed version") }
        catch ResourceRecoveryError.changed { }
        try FileManager.default.removeItem(at: file)
        do { _ = try await service.validate(candidate); XCTFail("Deleted bytes stay unavailable") }
        catch ResourceRecoveryError.unavailable { }
    }

    func testCaptureRejectsChangeAfterValidationAndKeepsImmutableBytes() async throws {
        let root = try fixture(), service = ResourceRecoveryService()
        let file = try write("original bytes", path: "request.txt", root: root)
        let candidate = try await service.inspectChosenFile(resource: resource(), path: file.path)
        _ = try await service.validate(candidate)
        let captured = try await service.captureValidated(candidate)
        XCTAssertEqual(captured, Data("original bytes".utf8))
        try Data("changed after validation".utf8).write(to: file)
        do { _ = try await service.captureValidated(candidate); XCTFail("Image/PDF preview must not reopen a later version") }
        catch ResourceRecoveryError.changed { }
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(captured, Data("original bytes".utf8), "Already captured bytes remain frozen even after deletion")
        do { _ = try await service.captureValidated(candidate); XCTFail("A deleted path cannot be captured again") }
        catch ResourceRecoveryError.unavailable { }
    }

    func testEntryAndTimeLimitsRemainExplicit() async throws {
        let root = try fixture()
        for index in 0..<20 { _ = try write("version", path: "request-\(index).txt", root: root) }
        var entries = ResourceRecoveryLimits(); entries.maximumEntries = 3
        let partial = try await search(root, limits: entries)
        XCTAssertEqual(partial.inspectedEntries, 3)
        XCTAssertTrue(partial.wasLimited)
        XCTAssertLessThanOrEqual(partial.candidates.count, 3)
        var time = ResourceRecoveryLimits(); time.maximumSeconds = 0
        let expired = try await search(root, limits: time)
        XCTAssertTrue(expired.wasLimited)
        XCTAssertEqual(expired.inspectedEntries, 0)
    }

    func testCandidateDepthAndRootLimitsRemainBounded() async throws {
        let root = try fixture()
        _ = try write("root", path: "request.txt", root: root)
        _ = try write("nested", path: "nested/request-old.txt", root: root)
        var depth = ResourceRecoveryLimits(); depth.maximumDepth = 0
        let shallow = try await search(root, limits: depth)
        XCTAssertEqual(shallow.candidates.count, 1)
        XCTAssertTrue(shallow.wasLimited)
        XCTAssertTrue(shallow.issues.contains { $0.category == "depthLimit" })
        var count = ResourceRecoveryLimits(); count.maximumCandidates = 1
        let one = try await search(root, limits: count)
        XCTAssertEqual(one.candidates.count, 1)
        XCTAssertTrue(one.wasLimited)
        var noRoots = ResourceRecoveryLimits(); noRoots.maximumRoots = 0
        let empty = try await search(root, limits: noRoots)
        XCTAssertEqual(empty.inspectedEntries, 0)
        XCTAssertTrue(empty.wasLimited)
        XCTAssertTrue(empty.issues.contains { $0.category == "rootLimit" })
    }

    func testByteBudgetCountsRejectedSecretReadsAndExcludesLargeFiles() async throws {
        let root = try fixture()
        let secret = "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "s", count: 120)
        _ = try write(secret, path: "request-old.txt", root: root)
        _ = try write(String(repeating: "x", count: 1000), path: "request.txt", root: root)
        var limits = ResourceRecoveryLimits(); limits.maximumFileBytes = 500; limits.maximumTotalReadBytes = 500
        let report = try await search(root, limits: limits)
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.bytesRead, UInt64(secret.utf8.count))
        XCTAssertTrue(report.issues.contains { $0.message == ResourceRecoveryError.tooLarge.localizedDescription })
    }

    func testCancellationDoesNotReturnPartialSuccess() async throws {
        let root = try fixture()
        _ = try write("x", path: "request.txt", root: root)
        let task = Task { try await self.search(root) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search must not publish stale candidates") }
        catch is CancellationError { }
    }

    func testBroadScopeDeniedAndSuggestionsStayLocal() async throws {
        let report = try await ResourceRecoveryService().search(resource: resource(), roots: [.init(path: FileManager.default.homeDirectoryForCurrentUser.path, reason: "Too broad")])
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.issues.first?.message, ResourceRecoveryError.broadRoot.localizedDescription)
        let snapshot = SessionSnapshot(root: .init(id: "root", cwd: "/work/alpha", paths: ["/logs/session.jsonl"]), environments: [.init(path: "/work/beta"), .init(path: "/work/alpha")])
        let suggested = ResourceRecoveryRoots.suggested(resource: resource(), snapshot: snapshot, attachmentDirectories: ["/attachments", "/attachments"])
        XCTAssertEqual(Set(suggested.map(\.path)), Set(["/gone/attachments", "/attachments", "/logs", "/work/alpha", "/work/beta"]))
        XCTAssertTrue(ResourceRecoveryRoots.suggested(resource: .init(location: "https://example.invalid/image.png"), snapshot: nil).isEmpty)
    }

    func testEmptyFileIsValidCurrentObservation() async throws {
        let root = try fixture()
        let file = try write("", path: "request.txt", root: root)
        let candidate = try await ResourceRecoveryService().inspectChosenFile(resource: resource(), path: file.path)
        XCTAssertEqual(candidate.byteCount, 0)
        XCTAssertEqual(candidate.sha256, digest(""))
    }
}
