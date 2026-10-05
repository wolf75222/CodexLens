import Foundation
import XCTest
@testable import LensCore

final class LensArchiveTransferTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let codex: URL
        let archive: InvestigationArchive
        let transfer: LensArchiveTransfer
    }
    private func fixture(quotaBytes: Int = 32 * 1024 * 1024, maximumBytes: Int = 32 * 1024 * 1024) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensTransfer-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        let source = root.appendingPathComponent("observed worktree")
        let codex = root.appendingPathComponent("custom-codex-home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let archive = InvestigationArchive(directory: root.appendingPathComponent("private-archive"), quotaBytes: quotaBytes)
        let transfer = LensArchiveTransfer(archive: archive, protectedSourceRoots: [source], codexDirectories: [codex], maximumBytes: maximumBytes)
        return Fixture(root: root, source: source, codex: codex, archive: archive, transfer: transfer)
    }
    private func capsule(source: URL? = nil, text: String = "Sortie enregistrée, anonymisée.", version: String = "recorded-version-1") throws -> EvidenceCapsule {
        let date = Date(timeIntervalSince1970: 1_759_392_000)
        let piece = EvidencePiece(id: "E001", kind: "toolOutput", title: "Résultat figé", text: text, eventID: "event-1", agentID: "agent-1", environmentID: "worktree-1", sourceRefs: source.map { [SourceRef(path: $0.path, offset: 0, length: 30, line: 1)] } ?? [], knownVersion: version, capturedAt: date, location: source.map { EvidenceLocation(environmentID: "worktree-1", path: $0.path, versionKind: .recordedFragment, version: version) })
        return try EvidenceCapsule.build(rootThreadID: "11111111-1111-4111-8111-111111111111", collectionCut: date, pieces: [piece], id: "22222222-2222-4222-8222-222222222222", createdAt: date)
    }
    private func envelope(_ f: Fixture, question: String = "Pourquoi cet appel a-t-il échoué ?", response: String? = "Le résultat enregistré l'indique [E001].") async throws -> LensArchiveEnvelope {
        try await f.transfer.freeze(capsule: capsule(), question: question, response: response, recordID: nil)
    }
    private func write(_ envelope: LensArchiveEnvelope, to file: URL) throws { try CapsuleJSON.encode(envelope).write(to: file) }
    private func mutate(_ envelope: LensArchiveEnvelope, to file: URL, _ change: (inout [String: Any]) -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: CapsuleJSON.encode(envelope)) as? [String: Any])
        change(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: file)
    }

    func testRoundtripUsesNewPrivateIDsAndPreservesFrozenVersions() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let output = f.root.appendingPathComponent("enquête.codexlens.json")
        let receipt = try await f.transfer.export(envelope: frozen, to: output)
        XCTAssertEqual(receipt.byteCount, try Data(contentsOf: output).count)
        let inspected = try await f.transfer.inspectImport(from: output)
        XCTAssertEqual(inspected, frozen)
        let first = try await f.transfer.import(envelope: inspected)
        let second = try await f.transfer.import(envelope: inspected)
        XCTAssertNotEqual(first.record.id, frozen.record.id)
        XCTAssertNotEqual(first.record.id, second.record.id)
        XCTAssertEqual(first.record.capsule, frozen.record.capsule)
        XCTAssertEqual(first.record.question, frozen.record.question)
        XCTAssertEqual(first.record.response, frozen.record.response)
        XCTAssertEqual(first.record.createdAt, frozen.record.createdAt)
        XCTAssertEqual(first.record.inferenceIDs, frozen.record.inferenceIDs)
        XCTAssertTrue(first.record.excludedFromAutocollection)
        XCTAssertFalse(first.record.analysisIsSourceEvidence)
        XCTAssertTrue(first.removedIDs.isEmpty)
        let loaded = try await f.archive.load(id: first.record.id)
        XCTAssertEqual(loaded, first.record)
        let exclusions = try await f.archive.collectionExclusions()
        XCTAssertTrue(exclusions.investigationIDs.contains(first.record.id))
        XCTAssertEqual(first.record.capsule.pieces.first?.knownVersion, "recorded-version-1")
    }

    func testNativeCodexlensExtensionExportsAndImports() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let destination = f.root.appendingPathComponent("archive.codexlens")
        try await f.transfer.validateExportDestination(destination, record: frozen.record)
        _ = try await f.transfer.export(envelope: frozen, to: destination)
        let inspected = try await f.transfer.inspectImport(from: destination)
        XCTAssertEqual(inspected, frozen)
    }

    func testUserSelectedArchiveInsideWorktreeCanBeReadWithoutSourceWrites() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let source = f.source.appendingPathComponent("archive fournie.codexlens")
        try write(frozen, to: source)
        let original = try Data(contentsOf: source)
        let inspected = try await f.transfer.inspectImport(from: source)
        _ = try await f.transfer.import(envelope: inspected)
        XCTAssertEqual(try Data(contentsOf: source), original)
        do { _ = try await f.transfer.export(envelope: frozen, to: source, replaceExisting: true); XCTFail("Read permission never permits source export writes") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.source.path), ["archive fournie.codexlens"])
    }

    func testFreezePrecedesPanelAndDoesNotReloadUpdatedQuestion() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try await f.archive.save(capsule: capsule(), question: "Question avant panneau", inferenceIDs: ["excluded-inference"])
        let frozen = try await f.transfer.freeze(record: saved.record)
        _ = try await f.archive.updateQuestion(id: saved.record.id, question: "Question modifiée pendant le panneau")
        let output = f.root.appendingPathComponent("figée.codexlens.json")
        _ = try await f.transfer.export(envelope: frozen, to: output)
        let inspected = try await f.transfer.inspectImport(from: output)
        XCTAssertEqual(inspected.record.question, "Question avant panneau")
        XCTAssertEqual(inspected.sourceRecordID, saved.record.id)
        XCTAssertTrue(inspected.recordDatesAreHistorical)
        let imported = try await f.transfer.import(envelope: inspected)
        XCTAssertEqual(imported.record.inferenceIDs, ["excluded-inference"])
        let original = try await f.archive.load(id: saved.record.id)
        XCTAssertEqual(original?.question, "Question modifiée pendant le panneau")
    }

    func testImportUsesInspectedValueEvenIfSelectedFileChanges() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await envelope(f, question: "Question figée à la lecture")
        let file = f.root.appendingPathComponent("sélection.codexlens.json")
        try write(first, to: file)
        let inspected = try await f.transfer.inspectImport(from: file)
        let replacement = try await envelope(f, question: "Autre question ajoutée ensuite")
        try write(replacement, to: file)
        let imported = try await f.transfer.import(envelope: inspected)
        XCTAssertEqual(imported.record.question, "Question figée à la lecture")
        XCTAssertEqual(imported.envelopeSHA256, first.envelopeSHA256)
    }

    func testMissingCapturedFileIsNotReadOrReplacedByItsCurrentContent() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let missing = f.source.appendingPathComponent("source supprimée.swift")
        let frozen = try await f.transfer.freeze(capsule: capsule(source: missing, text: "Fragment historique réellement enregistré."), question: "Version historique", response: nil, recordID: nil)
        try Data("Contenu courant différent, modification manuelle.".utf8).write(to: missing)
        let imported = try await f.transfer.import(envelope: frozen)
        XCTAssertEqual(imported.record.capsule.pieces.first?.text, "Fragment historique réellement enregistré.")
        XCTAssertEqual(imported.record.capsule.pieces.first?.sourceRefs.first?.path, missing.path)
        XCTAssertEqual(String(decoding: try Data(contentsOf: missing), as: UTF8.self), "Contenu courant différent, modification manuelle.")
    }

    func testRejectsUnknownVersionAndTamperedQuestionOrCapsule() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let file = f.root.appendingPathComponent("altérée.codexlens.json")
        try mutate(frozen, to: file) { $0["schemaVersion"] = 999 }
        do { _ = try await f.transfer.inspectImport(from: file); XCTFail("Unknown version must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("version")) }
        try mutate(frozen, to: file) { json in
            var record = json["record"] as! [String: Any]; record["question"] = "Question altérée"; json["record"] = record
        }
        do { _ = try await f.transfer.inspectImport(from: file); XCTFail("Record hash must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Intégrité")) }
        try mutate(frozen, to: file) { json in
            var record = json["record"] as! [String: Any]
            var capsule = record["capsule"] as! [String: Any]
            var pieces = capsule["pieces"] as! [[String: Any]]; pieces[0]["text"] = "Preuve altérée"
            capsule["pieces"] = pieces; record["capsule"] = capsule; json["record"] = record
        }
        do { _ = try await f.transfer.inspectImport(from: file); XCTFail("Capsule digest must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Contexte altéré")) }
        let records = try await f.archive.list()
        XCTAssertEqual(records.count, 0)
    }

    func testTamperedEnvelopeMetadataIsRejected() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let file = f.root.appendingPathComponent("metadata.codexlens.json")
        try mutate(frozen, to: file) { $0["recordDatesAreHistorical"] = true }
        do { _ = try await f.transfer.inspectImport(from: file); XCTFail("Envelope metadata hash must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("enveloppe")) }
    }

    func testOversizedImportFailsBeforeDecodingAndWritesNothing() async throws {
        let f = try fixture(maximumBytes: 8192); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("trop-grand.codexlens.json")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data("invalid json".utf8))
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 8193); try handle.close()
        do { _ = try await f.transfer.inspectImport(from: file); XCTFail("Must refuse oversize before decode") }
        catch { XCTAssertTrue(error.localizedDescription.contains("fichier non lu")) }
        let records = try await f.archive.list()
        XCTAssertTrue(records.isEmpty)
    }

    func testProtectedSourceRootsCodexHomesAndLogNamesAreRejected() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let paths = [f.source.appendingPathComponent("export.codexlens.json"), f.codex.appendingPathComponent("export.codexlens.json"), f.root.appendingPathComponent("rollout-source.jsonl"), f.root.appendingPathComponent("auth.json"), f.root.appendingPathComponent(".env.json"), f.root.appendingPathComponent(".codex/export.json")]
        for file in paths {
            do { _ = try await f.transfer.export(envelope: frozen, to: file); XCTFail("Protected destination \(file.path)") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        try write(frozen, to: f.codex.appendingPathComponent("selected.json"))
        do { _ = try await f.transfer.inspectImport(from: f.codex.appendingPathComponent("selected.json")); XCTFail("Do not read Codex sources as imports") } catch {}
    }

    func testCapturedPathOutsideKnownSourceRootCannotBeOverwritten() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let captured = f.root.appendingPathComponent("captured.json")
        let original = Data("Source fournie à préserver.".utf8); try original.write(to: captured)
        let frozen = try await f.transfer.freeze(capsule: capsule(source: captured), question: "Preuve", response: nil, recordID: nil)
        do { _ = try await f.transfer.export(envelope: frozen, to: captured, replaceExisting: true); XCTFail("Captured source cannot be overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: captured), original)
    }

    func testSymlinkedSourcesAndDestinationsAndHardlinksAreRefused() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let existing = f.root.appendingPathComponent("existing.codexlens.json"); try write(frozen, to: existing)
        let link = f.root.appendingPathComponent("link.codexlens.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        do { _ = try await f.transfer.inspectImport(from: link); XCTFail("Symlink input") } catch {}
        do { _ = try await f.transfer.export(envelope: frozen, to: link, replaceExisting: true); XCTFail("Symlink output") } catch {}
        let alias = f.root.appendingPathComponent("hardlink.codexlens.json")
        try FileManager.default.linkItem(at: existing, to: alias)
        do { _ = try await f.transfer.export(envelope: frozen, to: alias, replaceExisting: true); XCTFail("Hardlink output") } catch {}
        XCTAssertEqual(try Data(contentsOf: existing), try CapsuleJSON.encode(frozen))
    }

    func testSymlinkedDirectoryCannotBypassProtectedRoot() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let link = f.root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        let frozen = try await envelope(f)
        do { _ = try await f.transfer.export(envelope: frozen, to: link.appendingPathComponent("export.codexlens.json")); XCTFail("Resolved source root must be blocked") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.source.path).isEmpty)
    }

    func testRepointedSourceRootProtectsInitialAndCurrentDirectTargets() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let nextRoot = f.root.appendingPathComponent("second observed worktree")
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: true)
        let alias = f.root.appendingPathComponent("observed-root-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        let transfer = LensArchiveTransfer(archive: f.archive, protectedSourceRoots: [alias], codexDirectories: [f.codex])
        let frozen = try await envelope(f)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nextRoot)
        for target in [f.source, nextRoot] {
            do { _ = try await transfer.export(envelope: frozen, to: target.appendingPathComponent("export.codexlens")); XCTFail("Both historical and current root targets stay protected") } catch {}
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testRepointedCodexHomeCannotBeReadAsAnArchive() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let nextHome = f.root.appendingPathComponent("next-custom-codex-home")
        try FileManager.default.createDirectory(at: nextHome, withIntermediateDirectories: true)
        let alias = f.root.appendingPathComponent("codex-home-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.codex)
        let transfer = LensArchiveTransfer(archive: f.archive, protectedSourceRoots: [], codexDirectories: [alias])
        let frozen = try await envelope(f)
        let source = nextHome.appendingPathComponent("selected.codexlens"); try write(frozen, to: source)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nextHome)
        do { _ = try await transfer.inspectImport(from: source); XCTFail("Current Codex alias target must remain unreadable") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Codex")) }
    }

    func testOverwriteRequiresExplicitFlagAndCommitsOnlyCompleteJSON() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let destination = f.root.appendingPathComponent("replaced.codexlens.json")
        let original = Data("ancien fichier complet".utf8); try original.write(to: destination)
        do { _ = try await f.transfer.export(envelope: frozen, to: destination); XCTFail("Unconfirmed overwrite must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), original)
        _ = try await f.transfer.export(envelope: frozen, to: destination, replaceExisting: true)
        XCTAssertEqual(try Data(contentsOf: destination), try CapsuleJSON.encode(frozen))
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") })
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCancelledExportDoesNotReplaceExistingFileOrLeavePartial() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frozen = try await envelope(f)
        let destination = f.root.appendingPathComponent("cancelled.codexlens.json")
        let original = Data("à préserver".utf8); try original.write(to: destination)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await f.transfer.export(envelope: frozen, to: destination, replaceExisting: true)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail before commit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasSuffix(".partial") })
    }

    func testInsufficientArchiveQuotaPreservesExistingRecords() async throws {
        let f = try fixture(quotaBytes: 4096); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try await f.archive.save(capsule: capsule(), question: String(repeating: "Q", count: 1500))
        let directory = await f.archive.directory
        let file = directory.appendingPathComponent(saved.record.id + ".json")
        let original = try Data(contentsOf: file)
        let frozen = try await f.transfer.freeze(record: saved.record)
        do { _ = try await f.transfer.import(envelope: frozen); XCTFail("Import must not rotate existing records") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Espace insuffisant")) }
        let retained = try Data(contentsOf: file)
        XCTAssertEqual(retained, original)
        let records = try await f.archive.list()
        XCTAssertEqual(records.map(\.id), [saved.record.id])
    }

    func testImportCannotUseSourceDirectoryAsPrivateArchive() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let dangerousArchive = InvestigationArchive(directory: f.source)
        let transfer = LensArchiveTransfer(archive: dangerousArchive, protectedSourceRoots: [f.source], codexDirectories: [f.codex])
        let frozen = try await envelope(f)
        do { _ = try await transfer.import(envelope: frozen); XCTFail("Private archive cannot be a source directory") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.source.path).isEmpty)
    }
}
