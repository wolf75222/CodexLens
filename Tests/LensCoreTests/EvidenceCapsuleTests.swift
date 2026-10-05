import Foundation
import XCTest
@testable import LensCore

final class EvidenceCapsuleTests: XCTestCase {
    private let cut = Date(timeIntervalSince1970: 1_790_784_000)
    private func capsule(text: String = "Recorded output", count: Int = 1, maxBytes: Int = 256 * 1024, pieceMaxBytes: Int = 64 * 1024) throws -> EvidenceCapsule {
        try EvidenceCapsule.build(rootThreadID: "source-thread", collectionCut: cut, pieces: (1...count).map { EvidencePiece(id: String(format: "E%03d", $0), kind: "event", title: "Recorded event", text: text, eventID: "event-\($0)", sourceRefs: [SourceRef(path: "/private/tmp/nonexistent-source.jsonl", offset: 10, length: 20, line: 2)], capturedAt: cut) }, maxBytes: maxBytes, pieceMaxBytes: pieceMaxBytes, createdAt: cut)
    }
    func testEntryAndPacketBudgetsPreserveUTF8AndDeclareOmissions() throws {
        let value = try capsule(text: String(repeating: "é😀文\n", count: 20_000), maxBytes: 8192, pieceMaxBytes: 4096)
        XCTAssertLessThanOrEqual(try value.transmissionJSON().count, 8192)
        XCTAssertLessThanOrEqual(try CapsuleJSON.encode(value.pieces[0]).count, 4096)
        XCTAssertFalse(value.pieces[0].text.contains("\u{FFFD}"))
        XCTAssertTrue(value.pieces[0].text.contains("Extrait limité"))
        XCTAssertTrue(value.omissions.contains { $0.pieceID == "E001" && ($0.originalUTF8Bytes ?? 0) > ($0.retainedUTF8Bytes ?? 0) })
        XCTAssertTrue(try value.verifyDigest())
        let decoded = try CapsuleJSON.decode(EvidenceCapsule.self, from: value.transmissionJSON())
        XCTAssertTrue(try decoded.verifyDigest())
        XCTAssertEqual(value.digestSHA256, decoded.digestSHA256)
    }
    func testStructuredOriginSurvivesJSONEscapingWithoutPartialReferences() throws {
        let data = try JSONSerialization.data(withJSONObject: ["sourceTable": ["S1": ["path": "/tmp/beta/Origin.swift"]], "selection": String(repeating: "référence \"S1\"\n", count: 3600)])
        let text = String(decoding: data, as: UTF8.self)
        let piece = EvidencePiece(id: "E001", kind: "originEvidence", title: "Origin", text: text, capturedAt: cut)
        XCTAssertGreaterThan(try JSONEncoder().encode(piece).count, 64 * 1024)
        let value = try EvidenceCapsule.build(rootThreadID: "source-thread", collectionCut: cut, pieces: [piece])
        XCTAssertEqual(value.pieces.first?.text, text)
        XCTAssertTrue(value.omissions.isEmpty)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value.pieces.first).text.utf8)))
        XCTAssertLessThanOrEqual(try value.transmissionJSON().count, value.maxEncodedBytes)
    }

    func testOversizedStructuredOriginIsOmittedAsAWhole() throws {
        let piece = EvidencePiece(id: "E001", kind: "originEvidence", title: "Origin", text: String(repeating: "x", count: 140 * 1024), capturedAt: cut)
        let value = try EvidenceCapsule.build(rootThreadID: "source-thread", collectionCut: cut, pieces: [piece])
        XCTAssertTrue(value.pieces.isEmpty)
        XCTAssertEqual(value.omissions.first?.pieceID, "E001")
        XCTAssertEqual(value.omissions.first?.retainedUTF8Bytes, 0)
        XCTAssertTrue(value.omissions.first?.reason.contains("pièce entière omise") == true)
    }

    func testStructuredOriginRespectsSmallerTotalBudgetWithoutPartialJSON() throws {
        let piece = EvidencePiece(id: "E001", kind: "originEvidence", title: "Origin", text: String(repeating: "x", count: 6000), capturedAt: cut)
        let value = try EvidenceCapsule.build(rootThreadID: "source-thread", collectionCut: cut, pieces: [piece], maxBytes: 4096, pieceMaxBytes: 4096)
        XCTAssertTrue(value.pieces.isEmpty)
        XCTAssertEqual(value.omissions.first?.retainedUTF8Bytes, 0)
        XCTAssertLessThanOrEqual(try value.transmissionJSON().count, 4096)
    }

    func testTotalBudgetOmitsEntriesExplicitly() throws {
        let value = try capsule(text: String(repeating: "context ", count: 350), count: 20, maxBytes: 8192, pieceMaxBytes: 4096)
        XCTAssertLessThan(value.pieces.count, 20)
        XCTAssertFalse(value.omissions.isEmpty)
        XCTAssertLessThanOrEqual(try value.transmissionJSON().count, 8192)
        XCTAssertEqual(value.collectionCut, cut)
        XCTAssertTrue(value.excludedFromAutocollection)
    }
    func testCitationsSeparateValidInvalidAndUncitedSources() throws {
        let value = try capsule(count: 2)
        let citations = value.validateCitations(in: "Observation [E001]. Bad [E999] and again [E999], malformed [E02].")
        XCTAssertEqual(citations.validIDs, ["E001"])
        XCTAssertEqual(citations.invalidIDs, ["E999", "E02"])
        XCTAssertEqual(citations.uncitedSourceIDs, ["E002"])
        XCTAssertFalse(citations.isValid)
        XCTAssertEqual(value.pieces.count, 2, "Analysis does not become source evidence")
    }
    func testRecognizableSecretsAreMaskedBeforeTransmissionAndArchive() async throws {
        let secretText = "Authorization: Bearer abcdefghijklmnop123\napi_key='private-api-value'\npassword=\"two secret words\"\nhttps://alice:private-password@example.invalid\nhttps://example.invalid?token=query-secret&ok=yes\nsk-testabcdefghijklmnop"
        let value = try capsule(text: secretText)
        let text = String(decoding: try value.transmissionJSON(), as: UTF8.self)
        for secret in ["abcdefghijklmnop123", "private-api-value", "two secret words", "private-password", "query-secret", "sk-testabcdefghijklmnop"] { XCTAssertFalse(text.contains(secret)) }
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root)
        let saved = try await archive.save(capsule: value, question: "password='question-secret'")
        let updated = try await archive.updateResponse(id: saved.record.id, response: "api_key=response-secret")
        XCTAssertFalse(updated.record.question.contains("question-secret"))
        XCTAssertFalse(updated.record.response?.contains("response-secret") == true)
        let bytes = try Data(contentsOf: root.appendingPathComponent(saved.record.id + ".json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("response-secret"))
    }
    func testArchiveRoundtripKeepsAISeparateAndPublishesExclusions() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try capsule()
        let archive = InvestigationArchive(directory: root)
        let saved = try await archive.save(capsule: value, question: "Why did the tool fail?", inferenceIDs: ["response-original"])
        let updated = try await archive.updateResponse(id: saved.record.id, response: "The recorded output supports this [E001].", inferenceIDs: ["response-final", "response-original"])
        XCTAssertFalse(updated.record.analysisIsSourceEvidence)
        XCTAssertTrue(updated.record.excludedFromAutocollection)
        XCTAssertEqual(updated.record.capsule.pieces.count, 1)
        let restarted = InvestigationArchive(directory: root)
        let loaded = try await restarted.load(id: saved.record.id)
        XCTAssertEqual(loaded?.response, updated.record.response)
        XCTAssertEqual(loaded?.capsule.digestSHA256, value.digestSHA256)
        let list = try await restarted.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].responseAvailable)
        let exclusions = try await restarted.collectionExclusions()
        XCTAssertTrue(exclusions.directories.contains(root.path))
        XCTAssertTrue(exclusions.directories.contains(root.standardizedFileURL.path))
        XCTAssertEqual(exclusions.inferenceIDs, ["response-final", "response-original"])
        XCTAssertEqual(exclusions.investigationIDs, [saved.record.id])
    }
    func testArchiveQuotaRotatesWithExplicitRemovedIDs() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root, quotaBytes: 4096)
        let value = try capsule()
        let first = try await archive.save(capsule: value, question: String(repeating: "A", count: 1500))
        let second = try await archive.save(capsule: value, question: String(repeating: "B", count: 1500))
        XCTAssertTrue(second.removedIDs.contains(first.record.id))
        XCTAssertLessThanOrEqual(second.bytesUsed, 4096)
        let removed = try await archive.load(id: first.record.id)
        XCTAssertNil(removed)
        let retained = try await archive.load(id: second.record.id)
        XCTAssertNotNil(retained)
    }
    func testConversationSummaryRetainsChatMappingAndDecodesOlderSummary() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root)
        let empty = try EvidenceCapsule.build(rootThreadID: "anonymous-chat-root", collectionCut: Date(), pieces: [])
        let chatID = "66666666-6666-4666-8666-666666666666"
        let saved = try await archive.save(capsule: empty, question: "Bonjour", codexChatID: chatID)
        _ = try await archive.updateResponse(id: saved.record.id, response: "Bonjour, continuons.")
        let summaries = try await InvestigationArchive(directory: root).list()
        XCTAssertEqual(summaries.first?.codexChatID, chatID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summaries[0])) as? [String: Any])
        object.removeValue(forKey: "codexChatID")
        let old = try JSONDecoder().decode(InvestigationSummary.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.codexChatID)
        XCTAssertEqual(old.id, saved.record.id)
    }
    func testArchiveRejectsOversizedRecordWithoutTruncationOrSourceWrite() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original-rollout.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("original source bytes".utf8); try original.write(to: source)
        let archive = InvestigationArchive(directory: root.appendingPathComponent("archive"), quotaBytes: 1024)
        do { _ = try await archive.save(capsule: capsule(), question: String(repeating: "Q", count: 5000)); XCTFail("Must reject oversize") } catch { XCTAssertTrue(error.localizedDescription.contains("quota")) }
        XCTAssertEqual(try Data(contentsOf: source), original)
        do { _ = try await archive.load(id: "../../original-rollout"); XCTFail("Must reject path traversal") } catch { XCTAssertTrue(error.localizedDescription.contains("invalide")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive").path))
    }
    func testTamperedCapsuleCannotBeArchived() async throws {
        let value = try capsule()
        var object = try JSONSerialization.jsonObject(with: value.transmissionJSON()) as! [String: Any]
        object["rootThreadID"] = "another-source"
        let data = try JSONSerialization.data(withJSONObject: object)
        let tampered = try CapsuleJSON.decode(EvidenceCapsule.self, from: data)
        XCTAssertFalse(try tampered.verifyDigest())
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root)
        do { _ = try await archive.save(capsule: tampered, question: "Question"); XCTFail("Must reject altered capsule") } catch { XCTAssertTrue(error.localizedDescription.contains("altéré")) }
    }
    func testSymlinkedArchiveRecordDoesNotReadCapturedSource() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root)
        let saved = try await archive.save(capsule: capsule(), question: "Question")
        let source = root.appendingPathComponent("source-rollout.jsonl")
        let original = Data("not an investigation and never parsed".utf8); try original.write(to: source)
        let location = root.appendingPathComponent(saved.record.id + ".json")
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createSymbolicLink(at: location, withDestinationURL: source)
        do { _ = try await archive.load(id: saved.record.id); XCTFail("Must reject symbolic link") } catch { XCTAssertTrue(error.localizedDescription.contains("symbolique")) }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testInvalidDateRejectsInsteadOfTrapping() throws {
        XCTAssertThrowsError(try EvidenceCapsule.build(rootThreadID: "source", collectionCut: cut, pieces: [], createdAt: Date(timeIntervalSince1970: .infinity)))
    }
    func testDraftQuestionPersistsAcrossRestartWithoutChangingFrozenCapsule() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root)
        let saved = try await archive.save(capsule: capsule(), question: "Initial draft", inferenceIDs: ["excluded-inference"])
        let beforeValue = try await archive.load(id: saved.record.id)
        let before = try XCTUnwrap(beforeValue)
        _ = try await archive.updateQuestion(id: saved.record.id, question: "New draft\napi_key=draft-private-value")
        let restarted = InvestigationArchive(directory: root)
        let loadedValue = try await restarted.load(id: saved.record.id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.id, before.id)
        XCTAssertEqual(loaded.createdAt, before.createdAt)
        XCTAssertEqual(loaded.capsule, before.capsule)
        XCTAssertEqual(loaded.inferenceIDs, before.inferenceIDs)
        XCTAssertEqual(loaded.excludedFromAutocollection, before.excludedFromAutocollection)
        XCTAssertEqual(loaded.analysisIsSourceEvidence, before.analysisIsSourceEvidence)
        XCTAssertTrue(loaded.question.contains("New draft"))
        XCTAssertFalse(loaded.question.contains("draft-private-value"))
        XCTAssertNil(loaded.response)
    }
    func testAnsweredQuestionCannotBeChangedAndArchiveBytesRemainIntact() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = InvestigationArchive(directory: root)
        let saved = try await archive.save(capsule: capsule(), question: "Original audited question")
        _ = try await archive.updateResponse(id: saved.record.id, response: "Recorded analysis [E001]")
        let path = root.appendingPathComponent(saved.record.id + ".json")
        let before = try Data(contentsOf: path)
        do { _ = try await archive.updateQuestion(id: saved.record.id, question: "A different question"); XCTFail("Answered question must be immutable") } catch { XCTAssertTrue(error.localizedDescription.contains("déjà une réponse")) }
        XCTAssertEqual(try Data(contentsOf: path), before)
        let loaded = try await archive.load(id: saved.record.id)
        XCTAssertEqual(loaded?.question, "Original audited question")
        XCTAssertEqual(loaded?.response, "Recorded analysis [E001]")
    }
    private func temporaryDirectory() -> URL { URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("LensInvestigationTests-" + UUID().uuidString) }
}
