import Foundation
import XCTest
@testable import LensCore

/// These tests read immutable local Git objects only. Fixtures never fetch, install
/// hooks, or ask the resolver to inspect the current worktree as historical data.
final class RecordedFileVersionTests: XCTestCase {
    private let zero = String(repeating: "0", count: 40)

    func testFullIndexNamesRemainScopedToTheirFileAndDocument() throws {
        let firstBefore = RecordedFileVersion.objectID(text: "first old\n")
        let firstAfter = RecordedFileVersion.objectID(text: "first new\n")
        let secondBefore = RecordedFileVersion.objectID(text: "second old\n")
        let secondAfter = RecordedFileVersion.objectID(text: "second new\n")
        let first = patch(path: "one.swift", before: firstBefore, after: firstAfter, removed: "first old", added: "first new")
        let second = patch(path: "two.swift", before: secondBefore, after: secondAfter, removed: "second old", added: "second new", mode: "100755")
        let unindexed = "diff --git a/three.swift b/three.swift\n--- a/three.swift\n+++ b/three.swift\n@@ -1 +1 @@\n-old\n+new\n"
        let document = try RecordedDiff.parse(first + second + unindexed, provenance: provenance("/fixture/A"))
        XCTAssertEqual(document.files.count, 3)
        XCTAssertEqual(RecordedFileVersion.plan(file: document.files[0], side: .before), .blob(id: firstBefore, path: "one.swift"))
        XCTAssertEqual(RecordedFileVersion.plan(file: document.files[0], side: .after), .blob(id: firstAfter, path: "one.swift"))
        XCTAssertEqual(document.files[1].beforeBlobID, secondBefore)
        XCTAssertEqual(document.files[1].afterBlobID, secondAfter)
        XCTAssertEqual(document.files[1].beforeMode, "100755")
        XCTAssertEqual(document.files[1].afterMode, "100755")
        XCTAssertNil(document.files[2].beforeBlobID)
        XCTAssertNil(document.files[2].afterBlobID)
        XCTAssertNil(document.files[2].beforeMode)
        XCTAssertNil(document.files[2].afterMode)
        let independent = try RecordedDiff.parse(unindexed, provenance: provenance("/fixture/B"))
        XCTAssertNil(independent.files[0].beforeBlobID)
        XCTAssertNotEqual(document.files[2].id, independent.files[0].id)
        XCTAssertEqual(try JSONDecoder().decode(RecordedDiffDocument.self, from: JSONEncoder().encode(document)), document)
    }

    func testAbbreviatedNamesSymbolicReferencesAndNonregularModesAreUnavailable() throws {
        let id = RecordedFileVersion.objectID(text: "same\n")
        var file = try parsedFile(patch(path: "file.swift", before: id, after: id, removed: "same", added: "same"), environment: "/fixture")
        for invalid in [String(id.prefix(7)), "HEAD", "../object", String(repeating: "g", count: 40), id + "0"] {
            file.beforeBlobID = invalid
            assertUnavailable(RecordedFileVersion.plan(file: file, side: .before))
            XCTAssertFalse(RecordedFileVersion.isFullObjectID(invalid))
        }
        file.beforeBlobID = id
        for mode in [nil, "120000", "160000", "040000", "100600", ""] as [String?] {
            file.beforeMode = mode
            assertUnavailable(RecordedFileVersion.plan(file: file, side: .before))
        }
        file.beforeMode = "100644"
        file.beforeBlobID = id.uppercased()
        XCTAssertEqual(RecordedFileVersion.plan(file: file, side: .before), .blob(id: id, path: "file.swift"))
        let sha256 = RecordedFileVersion.objectID(text: "same\n", length: 64)
        XCTAssertEqual(sha256.count, 64)
        XCTAssertTrue(RecordedFileVersion.isFullObjectID(sha256))
    }

    func testAddedDeletedAbsentMarkersAreDistinctFromAnEmptyFile() async throws {
        let root = try repository()
        let emptyID = try writeBlob("", at: root)
        let environment = EnvironmentRecord(path: root.path)
        let resolver = RecordedFileVersionResolver(files: FileService())
        let added = try parsedFile("diff --git a/empty.swift b/empty.swift\nnew file mode 100644\nindex \(zero)..\(emptyID)\n--- /dev/null\n+++ b/empty.swift\n", environment: root.path)
        XCTAssertEqual(added.operation, .added)
        XCTAssertEqual(RecordedFileVersion.plan(file: added, side: .before), .absent)
        let before = try await resolver.resolve(file: added, environment: environment, side: .before)
        let after = try await resolver.resolve(file: added, environment: environment, side: .after)
        XCTAssertTrue(before.isAbsent)
        XCTAssertNil(before.text)
        XCTAssertNil(before.objectID)
        XCTAssertFalse(after.isAbsent)
        XCTAssertEqual(after.text, "")
        XCTAssertEqual(after.objectID, emptyID)
        let deleted = try parsedFile("diff --git a/empty.swift b/empty.swift\ndeleted file mode 100644\nindex \(emptyID)..\(zero)\n--- a/empty.swift\n+++ /dev/null\n", environment: root.path)
        let removed = try await resolver.resolve(file: deleted, environment: environment, side: .after)
        XCTAssertTrue(removed.isAbsent)
        var inconsistent = added
        inconsistent.oldPath = "empty.swift"
        assertUnavailable(RecordedFileVersion.plan(file: inconsistent, side: .before))
        inconsistent = deleted
        inconsistent.operation = .modified
        assertUnavailable(RecordedFileVersion.plan(file: inconsistent, side: .after))
    }

    func testRecordedBlobVerifiesBytesWithoutChangingDirtyFileIndexOrBranch() async throws {
        let root = try repository()
        let file = root.appendingPathComponent("file.swift")
        try Data("committed baseline\n".utf8).write(to: file)
        _ = try git(["add", "file.swift"], at: root)
        _ = try git(["commit", "-qm", "fixture baseline"], at: root)
        let object = try git(["rev-parse", "HEAD:file.swift"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = try writeBlob("replacement bytes\n", at: root)
        _ = try git(["replace", object, replacement], at: root)
        let dirty = "manual edit outside the recorded diff\n"
        try Data(dirty.utf8).write(to: file)
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let value = try await FileService().recordedBlob(environment: EnvironmentRecord(path: root.path), recordedPath: "file.swift", objectID: object)
        XCTAssertEqual(value.text, "committed baseline\n")
        XCTAssertEqual(value.objectID, object)
        XCTAssertEqual(value.kind, .gitBlob)
        XCTAssertNil(value.baseObjectID)
        XCTAssertEqual(try Data(contentsOf: file), Data(dirty.utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }

    func testOnlyOldBlobAvailableReconstructsExactAfterObjectAndRetainsBaseIdentity() async throws {
        let root = try repository()
        let before = "prefix\nold\ntail\n", after = "prefix\nnew\ntail\n"
        let oldID = try writeBlob(before, at: root), newID = RecordedFileVersion.objectID(text: after)
        let recorded = "diff --git a/file.swift b/file.swift\nindex \(oldID)..\(newID) 100644\n--- a/file.swift\n+++ b/file.swift\n@@ -1,3 +1,3 @@\n prefix\n-old\n+new\n tail\n"
        let file = try parsedFile(recorded, environment: root.path)
        let value = try await RecordedFileVersionResolver(files: FileService()).resolve(file: file, environment: EnvironmentRecord(path: root.path), side: .after)
        XCTAssertEqual(value.text, after)
        XCTAssertEqual(value.objectID, newID)
        XCTAssertEqual(value.baseObjectID, oldID)
        XCTAssertEqual(value.kind, .reconstructed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: looseObject(newID, root: root).path), "Reconstruction does not write a Git object")
    }

    func testOnlyAfterBlobAvailableSupportsVerifiedInverseReconstruction() async throws {
        let root = try repository()
        let before = "old\n", after = "new\n"
        let oldID = RecordedFileVersion.objectID(text: before), newID = try writeBlob(after, at: root)
        let file = try parsedFile(patch(path: "file.swift", before: oldID, after: newID, removed: "old", added: "new"), environment: root.path)
        let value = try await RecordedFileVersionResolver(files: FileService()).resolve(file: file, environment: EnvironmentRecord(path: root.path), side: .before)
        XCTAssertEqual(value.text, before)
        XCTAssertEqual(value.objectID, oldID)
        XCTAssertEqual(value.baseObjectID, newID)
        XCTAssertEqual(value.kind, .reconstructed)
    }

    func testReconstructionRefusesWrongBaseIncompleteFragmentsAndFalseTargetDigest() throws {
        let before = "old\n", after = "new\n"
        let oldID = RecordedFileVersion.objectID(text: before), newID = RecordedFileVersion.objectID(text: after)
        let file = try parsedFile(patch(path: "file.swift", before: oldID, after: newID, removed: "old", added: "new"), environment: "/fixture")
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: file, base: "manually changed\n", side: .after))
        var truncated = file
        truncated.hunks[0].isComplete = false
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: truncated, base: before, side: .after))
        truncated = file
        truncated.hunks[0].lines.removeLast()
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: truncated, base: before, side: .after))
        var falseTarget = file
        falseTarget.afterBlobID = RecordedFileVersion.objectID(text: "different complete content\n")
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: falseTarget, base: before, side: .after))
        var unknown = file
        unknown.issues.append(RecordedDiffIssue("incomplete", "missing recorded output"))
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: unknown, base: before, side: .after))
        var localOnly = file
        localOnly.hunks[0].beforeStart = nil
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: localOnly, base: before, side: .after))
        var conflicting = file
        conflicting.hunks[0].beforeStart = 2
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: conflicting, base: before, side: .after))
    }

    func testFinalNewlineIsVerifiedAsBytesInBothDirections() throws {
        for before in ["old", "old\n"] {
            for after in ["new", "new\n"] {
                let oldID = RecordedFileVersion.objectID(text: before), newID = RecordedFileVersion.objectID(text: after)
                let eof = (before.hasSuffix("\n") ? "" : "\\ No newline at end of file\n")
                let targetEOF = (after.hasSuffix("\n") ? "" : "\\ No newline at end of file\n")
                let input = "diff --git a/file b/file\nindex \(oldID)..\(newID) 100644\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n\(eof)+new\n\(targetEOF)"
                let file = try parsedFile(input, environment: "/fixture")
                let forward = try RecordedFileVersion.reconstruct(file: file, base: before, side: .after)
                let reverse = try RecordedFileVersion.reconstruct(file: file, base: after, side: .before)
                XCTAssertEqual(forward.text, after)
                XCTAssertEqual(reverse.text, before)
                XCTAssertEqual(forward.objectID, newID)
                XCTAssertEqual(reverse.objectID, oldID)
            }
        }
    }

    func testCRLFHunkBytesAreExactAndNormalizedPatchCannotFabricateThem() throws {
        let before = "old\r\n", after = "new\r\n"
        var file = try parsedFile(patch(path: "file", before: RecordedFileVersion.objectID(text: before), after: RecordedFileVersion.objectID(text: after), removed: "old", added: "new"), environment: "/fixture")
        // A normalized LF fragment is insufficient to reconstruct a CRLF blob.
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: file, base: before, side: .after))
        // When exact recorded row bytes are available, the hash verifies the full CRLF result.
        file.hunks[0].lines[0].text = "old\r"
        file.hunks[0].lines[1].text = "new\r"
        let value = try RecordedFileVersion.reconstruct(file: file, base: before, side: .after)
        XCTAssertEqual(value.text, after)
        XCTAssertNotEqual(value.objectID, RecordedFileVersion.objectID(text: "new\n"))
    }

    func testAbsentBaseCanReconstructAnAdditionWithoutTreatingEmptyFileAsAbsence() throws {
        let after = "created\n", id = RecordedFileVersion.objectID(text: after)
        let file = try parsedFile("diff --git a/new.swift b/new.swift\nnew file mode 100644\nindex \(zero)..\(id)\n--- /dev/null\n+++ b/new.swift\n@@ -0,0 +1 @@\n+created\n", environment: "/fixture")
        let value = try RecordedFileVersion.reconstruct(file: file, base: "", side: .after)
        XCTAssertEqual(value.text, after)
        XCTAssertEqual(value.baseObjectID, "absent")
        XCTAssertThrowsError(try RecordedFileVersion.reconstruct(file: file, base: "unrecorded data\n", side: .after))
    }

    func testRequestedOrFailedPatchDoesNotBecomeObservedWorktreeState() async throws {
        let root = try repository()
        let oldID = try writeBlob("old\n", at: root), newID = try writeBlob("proposed\n", at: root)
        let current = root.appendingPathComponent("file.swift")
        try Data("manual current version\n".utf8).write(to: current)
        var document = try RecordedDiff.parse(patch(path: "file.swift", before: oldID, after: newID, removed: "old", added: "proposed"), provenance: provenance(root.path), kind: .requestedPatch)
        document.result = RecordedDiffResult(status: .failed, message: "Context did not match", eventIDs: ["result-failed"])
        let file = document.files[0]
        let value = try await RecordedFileVersionResolver(files: FileService()).resolve(file: file, environment: EnvironmentRecord(path: root.path), side: .after)
        XCTAssertEqual(value.text, "proposed\n", "A cited target object is inspectable, even when application failed")
        XCTAssertEqual(value.kind, .gitBlob)
        XCTAssertEqual(document.kind, .requestedPatch)
        XCTAssertEqual(document.result?.status, .failed)
        XCTAssertEqual(document.coverage, .fragmentOnly)
        XCTAssertNil(file.provenance.authorEvidence)
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "manual current version\n")
        let codex = try RecordedDiff.parse("*** Begin Patch\n*** Update File: file.swift\n@@\n-old\n+proposed\n*** End Patch", provenance: provenance(root.path))
        assertUnavailable(RecordedFileVersion.plan(file: codex.files[0], side: .before))
        assertUnavailable(RecordedFileVersion.plan(file: codex.files[0], side: .after))
    }

    func testMissingObjectsNeverFallBackToAccessibleCurrentFile() async throws {
        let root = try repository()
        let fileURL = root.appendingPathComponent("file.swift")
        let current = "accessible current bytes must stay distinct\n"
        try Data(current.utf8).write(to: fileURL)
        let oldID = RecordedFileVersion.objectID(text: "missing old object\n")
        let newID = RecordedFileVersion.objectID(text: "missing new object\n")
        let file = try parsedFile(patch(path: "file.swift", before: oldID, after: newID, removed: "missing old object", added: "missing new object"), environment: root.path)
        do {
            _ = try await RecordedFileVersionResolver(files: FileService()).resolve(file: file, environment: EnvironmentRecord(path: root.path), side: .after)
            XCTFail("Both historical objects are absent; current contents are not a substitute")
        } catch FileServiceError.objectUnavailable { }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), current)
    }

    func testResolverRejectsWrongEnvironmentBeforeAnyBlobLoad() async throws {
        let root = try repository()
        let id = try writeBlob("same\n", at: root)
        let file = try parsedFile(patch(path: "file.swift", before: id, after: id, removed: "same", added: "same"), environment: "/different/worktree")
        let service = FileService()
        do {
            _ = try await RecordedFileVersionResolver(files: service).resolve(file: file, environment: EnvironmentRecord(path: root.path), side: .before)
            XCTFail("Provenance cannot be reassigned to another worktree")
        } catch FileServiceError.historicalUnavailable { }
        let stats = await service.blobCacheStatistics()
        XCTAssertEqual(stats.loads, 0)
    }

    func testIdenticalRelativePathsInTwoWorktreesUseDistinctCacheScopes() async throws {
        let root = try repository()
        let folder = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let relative = "src/Same.swift"
        try Data("shared committed blob\n".utf8).write(to: root.appendingPathComponent(relative))
        _ = try git(["add", relative], at: root)
        _ = try git(["commit", "-qm", "shared fixture"], at: root)
        let id = try git(["rev-parse", "HEAD:" + relative], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = root.appendingPathComponent("second-worktree")
        _ = try git(["worktree", "add", "--detach", second.path, "HEAD"], at: root)
        try Data("manual alpha\n".utf8).write(to: root.appendingPathComponent(relative))
        try Data("manual beta\n".utf8).write(to: second.appendingPathComponent(relative))
        let service = FileService()
        let alpha = EnvironmentRecord(path: root.path, repositoryPath: root.path)
        let beta = EnvironmentRecord(path: second.path, repositoryPath: root.path)
        let a = try await service.recordedBlob(environment: alpha, recordedPath: relative, objectID: id)
        let b = try await service.recordedBlob(environment: beta, recordedPath: relative, objectID: id)
        XCTAssertEqual(a.text, "shared committed blob\n")
        XCTAssertEqual(b.text, a.text)
        let stats = await service.blobCacheStatistics()
        XCTAssertEqual(stats.entries, 2)
        XCTAssertEqual(stats.loads, 2)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8), "manual alpha\n")
        XCTAssertEqual(try String(contentsOf: second.appendingPathComponent(relative), encoding: .utf8), "manual beta\n")
    }

    func testConcurrentRequestsCoalesceAndCacheClearForcesNewVerifiedRead() async throws {
        let root = try repository()
        let text = String(repeating: "coalesced fixture text\n", count: 12_000)
        let id = try writeBlob(text, at: root)
        let service = FileService(), environment = EnvironmentRecord(path: root.path)
        let values = try await withThrowingTaskGroup(of: VerifiedFileVersion.self) { group in
            for _ in 0..<24 {
                group.addTask { try await service.recordedBlob(environment: environment, recordedPath: "file.swift", objectID: id) }
            }
            var result: [VerifiedFileVersion] = []
            for try await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(values.count, 24)
        XCTAssertTrue(values.allSatisfy { $0.text == text && $0.objectID == id })
        let first = await service.blobCacheStatistics()
        XCTAssertEqual(first.loads, 1)
        XCTAssertEqual(first.entries, 1)
        XCTAssertEqual(first.bytes, text.utf8.count)
        XCTAssertEqual(first.inFlight, 0)
        await service.clearBlobCache()
        let cleared = await service.blobCacheStatistics()
        XCTAssertEqual(cleared.entries, 0)
        XCTAssertEqual(cleared.bytes, 0)
        _ = try await service.recordedBlob(environment: environment, recordedPath: "file.swift", objectID: id)
        let second = await service.blobCacheStatistics()
        XCTAssertEqual(second.loads, 2)
    }

    func testBlobCacheEvictsAtItsExplicitPayloadBudget() async throws {
        let root = try repository()
        let service = FileService(), environment = EnvironmentRecord(path: root.path)
        let bytes = 6 * 1024 * 1024
        var ids: [String] = []
        for marker in ["A", "B", "C"] {
            let text = String(repeating: marker, count: bytes)
            let id = try writeBlob(text, at: root)
            ids.append(id)
            let value = try await service.recordedBlob(environment: environment, recordedPath: "large.txt", objectID: id)
            XCTAssertEqual(value.text?.utf8.count, bytes)
            let stats = await service.blobCacheStatistics()
            XCTAssertLessThanOrEqual(stats.bytes, FileService.blobCacheBudget)
        }
        let bounded = await service.blobCacheStatistics()
        XCTAssertEqual(bounded.entries, 2)
        XCTAssertEqual(bounded.bytes, 2 * bytes)
        XCTAssertEqual(bounded.loads, 3)
        _ = try await service.recordedBlob(environment: environment, recordedPath: "large.txt", objectID: ids[0])
        let reloaded = await service.blobCacheStatistics()
        XCTAssertEqual(reloaded.loads, 4, "The least recently used immutable object was evicted")
        XCTAssertLessThanOrEqual(reloaded.bytes, FileService.blobCacheBudget)
        await service.clearBlobCache()
        let cleared = await service.blobCacheStatistics()
        XCTAssertEqual(cleared.bytes, 0)
        XCTAssertEqual(cleared.entries, 0)
    }

    func testDeletedWorktreeCanUseOnlyItsExplicitAssociatedRepository() async throws {
        let root = try repository()
        let id = try writeBlob("retained immutable bytes\n", at: root)
        let removed = root.appendingPathComponent("removed-worktree")
        let environment = EnvironmentRecord(path: removed.path, repositoryPath: root.path)
        let value = try await FileService().recordedBlob(environment: environment, recordedPath: "file.swift", objectID: id)
        XCTAssertEqual(value.text, "retained immutable bytes\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
    }

    func testPathRestrictionsApplyBeforeLoadAndOnCacheHits() async throws {
        let root = try repository()
        let id = try writeBlob("ordinary bytes\n", at: root)
        let environment = EnvironmentRecord(path: root.path), service = FileService()
        _ = try await service.recordedBlob(environment: environment, recordedPath: "file.swift", objectID: id)
        for path in ["../file.swift", "a/../../file.swift", root.deletingLastPathComponent().appendingPathComponent("outside.swift").path, "file\0.swift"] {
            do { _ = try await service.recordedBlob(environment: environment, recordedPath: path, objectID: id); XCTFail("Invalid path admitted: \(path)") }
            catch FileServiceError.invalidPath { }
        }
        for path in [".env", ".ssh/id_rsa", "credentials.json"] {
            do { _ = try await service.recordedBlob(environment: environment, recordedPath: path, objectID: id); XCTFail("Restricted path admitted") }
            catch FileServiceError.restricted { }
        }
        let cached = try await service.recordedBlob(environment: environment, recordedPath: "file.swift", objectID: id)
        XCTAssertEqual(cached.objectID, id)
        let stats = await service.blobCacheStatistics()
        XCTAssertEqual(stats.loads, 1)
        XCTAssertEqual(stats.hits, 1)
        try Data("local credential fixture\n".utf8).write(to: root.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("file.swift").path, withDestinationPath: ".env")
        do {
            _ = try await service.recordedBlob(environment: environment, recordedPath: "file.swift", objectID: id)
            XCTFail("A previously cached key must still pass current path restrictions")
        } catch FileServiceError.restricted { }
        let guarded = await service.blobCacheStatistics()
        XCTAssertEqual(guarded.loads, 1)
        XCTAssertEqual(guarded.hits, 1, "The excluded path is rejected before looking up the cache")
    }

    func testMissingNonblobBinaryAndMisnamedObjectsFailExplicitly() async throws {
        let root = try repository()
        let environment = EnvironmentRecord(path: root.path), service = FileService()
        let missing = RecordedFileVersion.objectID(text: "not stored\n")
        do { _ = try await service.recordedBlob(environment: environment, recordedPath: "file", objectID: missing); XCTFail("Missing object") }
        catch FileServiceError.objectUnavailable { }
        let binary = try writeBlob(Data([0, 65, 66]), at: root)
        do { _ = try await service.recordedBlob(environment: environment, recordedPath: "file", objectID: binary); XCTFail("Binary object") }
        catch FileServiceError.binary { }
        try Data("committed\n".utf8).write(to: root.appendingPathComponent("file"))
        _ = try git(["add", "file"], at: root)
        _ = try git(["commit", "-qm", "nonblob fixture"], at: root)
        let commit = try git(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        do { _ = try await service.recordedBlob(environment: environment, recordedPath: "file", objectID: commit); XCTFail("Commit presented as file blob") }
        catch FileServiceError.historicalUnavailable { }
        let original = try writeBlob("expected object bytes\n", at: root)
        let replacement = try writeBlob("misnamed object bytes\n", at: root)
        try FileManager.default.removeItem(at: looseObject(original, root: root))
        try FileManager.default.copyItem(at: looseObject(replacement, root: root), to: looseObject(original, root: root))
        do { _ = try await service.recordedBlob(environment: environment, recordedPath: "file", objectID: original); XCTFail("Wrong bytes under recorded digest") }
        catch FileServiceError.historicalUnavailable { }
        let stats = await service.blobCacheStatistics()
        XCTAssertEqual(stats.entries, 0, "Failed reads do not populate the historical cache")
    }

    func testAlreadyCancelledReadAndReconstructionDoNotStartWork() async throws {
        let root = try repository()
        let before = "old\n", after = "new\n"
        let id = try writeBlob(before, at: root)
        let service = FileService(), environment = EnvironmentRecord(path: root.path)
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.recordedBlob(environment: environment, recordedPath: "file", objectID: id)
        }
        do { _ = try await read.value; XCTFail("Already cancelled read") }
        catch is CancellationError { }
        let stats = await service.blobCacheStatistics()
        XCTAssertEqual(stats.loads, 0)
        XCTAssertEqual(stats.inFlight, 0)
        let file = try parsedFile(patch(path: "file", before: id, after: RecordedFileVersion.objectID(text: after), removed: "old", added: "new"), environment: root.path)
        let reconstruction = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RecordedFileVersion.reconstruct(file: file, base: before, side: .after)
        }
        do { _ = try await reconstruction.value; XCTFail("Already cancelled reconstruction") }
        catch is CancellationError { }
        let resolver = RecordedFileVersionResolver(files: service)
        let resolve = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await resolver.resolve(file: file, environment: environment, side: .before)
        }
        do { _ = try await resolve.value; XCTFail("Already cancelled resolver") }
        catch is CancellationError { }
        let end = await service.blobCacheStatistics()
        XCTAssertEqual(end.loads, 0)
    }

    func testCancellationAfterFlightStartsReleasesReaderAndPreservesOtherReaders() async throws {
        let root = try repository()
        let text = String(repeating: "Z", count: 2 * 1024 * 1024)
        let id = try writeBlob(text, at: root)
        let environment = EnvironmentRecord(path: root.path)
        let loneService = FileService()
        let loneReader = Task {
            try await loneService.recordedBlob(environment: environment, recordedPath: "large.txt", objectID: id)
        }
        var observedFlight = false
        for _ in 0..<4096 {
            let state = await loneService.blobCacheStatistics()
            if state.inFlight > 0 { observedFlight = true; break }
            if state.entries > 0 { break }
            await Task.yield()
        }
        guard observedFlight else {
            loneReader.cancel(); _ = try? await loneReader.value
            return XCTFail("The fixture must expose an active request before cancellation")
        }
        loneReader.cancel()
        do { _ = try await loneReader.value; XCTFail("A reader cancelled during an active request must not receive its text") }
        catch is CancellationError { }
        // The actor's cancellation handler may release its reader in a separate task.
        // This bounds observation of bookkeeping, not termination timing of a Git PID.
        for _ in 0..<4096 {
            let state = await loneService.blobCacheStatistics()
            if state.inFlight == 0 { break }
            await Task.yield()
        }
        let released = await loneService.blobCacheStatistics()
        XCTAssertEqual(released.loads, 1)
        XCTAssertEqual(released.entries, 0)
        XCTAssertEqual(released.inFlight, 0)

        let sharedService = FileService()
        let cancelledReader = Task {
            try await sharedService.recordedBlob(environment: environment, recordedPath: "large.txt", objectID: id)
        }
        let survivingReader = Task {
            try await sharedService.recordedBlob(environment: environment, recordedPath: "large.txt", objectID: id)
        }
        var observedBothReaders = false
        for _ in 0..<4096 {
            let state = await sharedService.blobCacheStatistics()
            if state.inFlight == 1 && state.readers == 2 { observedBothReaders = true; break }
            if state.entries > 0 { break }
            await Task.yield()
        }
        guard observedBothReaders else {
            cancelledReader.cancel(); survivingReader.cancel()
            _ = try? await cancelledReader.value; _ = try? await survivingReader.value
            return XCTFail("Both readers must be attached to the same active request before cancellation")
        }
        cancelledReader.cancel()
        do { _ = try await cancelledReader.value; XCTFail("Cancelled coalesced reader received a result") }
        catch is CancellationError { }
        let retained = try await survivingReader.value
        XCTAssertEqual(retained.text, text)
        XCTAssertEqual(retained.objectID, id)
        let shared = await sharedService.blobCacheStatistics()
        XCTAssertEqual(shared.loads, 1, "Cancelling one reader does not restart the surviving reader's request")
        XCTAssertEqual(shared.entries, 1)
        XCTAssertEqual(shared.inFlight, 0)
        XCTAssertEqual(shared.readers, 0)
    }

    private func provenance(_ environment: String) -> DiffProvenance {
        DiffProvenance(environmentID: environment, eventIDs: ["recorded-call"], sources: [SourceRef(path: "/fixture/session.jsonl", offset: 100, length: 200, line: 2)], agentID: "recorded-agent")
    }

    private func patch(path: String, before: String, after: String, removed: String, added: String, mode: String = "100644") -> String {
        "diff --git a/\(path) b/\(path)\nindex \(before)..\(after) \(mode)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n-\(removed)\n+\(added)\n"
    }

    private func parsedFile(_ text: String, environment: String) throws -> RecordedFileDiff {
        try XCTUnwrap(RecordedDiff.parse(text, provenance: provenance(environment)).files.first)
    }

    private func assertUnavailable(_ plan: RecordedFileVersionPlan, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable(let reason) = plan else { return XCTFail("Expected explicit unavailability; got \(plan)", file: file, line: line) }
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensRecordedVersionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try git(["init", "-q"], at: root)
        _ = try git(["config", "user.name", "Lens Fixture"], at: root)
        _ = try git(["config", "user.email", "fixture@example.invalid"], at: root)
        return root
    }

    private func writeBlob(_ text: String, at root: URL) throws -> String { try writeBlob(Data(text.utf8), at: root) }

    private func writeBlob(_ data: Data, at root: URL) throws -> String {
        let scratch = root.appendingPathComponent("blob-fixture-" + UUID().uuidString)
        try data.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try git(["hash-object", "-w", "--", scratch.path], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looseObject(_ id: String, root: URL) -> URL {
        root.appendingPathComponent(".git/objects").appendingPathComponent(String(id.prefix(2))).appendingPathComponent(String(id.dropFirst(2)))
    }

    private func git(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LensRecordedVersionGitFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
