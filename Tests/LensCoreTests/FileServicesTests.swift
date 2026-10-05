import Foundation
import XCTest
@testable import LensCore

final class FileServicesTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexLens-FileServices-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTextPagesPreserveUTF8WithoutSilentTruncation() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("unicode.swift")
        let original = "aé😊中\n" + String(repeating: "une sortie longue\n", count: 100)
        try Data(original.utf8).write(to: file)
        for limit in [1, 2, 3, 4, 17, 64] {
            let service = FileService()
            var result = ""
            var offset: UInt64 = 0
            var version: String?
            repeat {
                let page = try await service.readText(path: file.path, offset: offset, limit: limit, expectedVersion: version)
                XCTAssertEqual(page.totalBytes, UInt64(original.utf8.count))
                XCTAssertFalse(page.version.isEmpty)
                result += page.text
                version = page.version
                guard let next = page.nextOffset else { break }
                XCTAssertGreaterThan(next, offset)
                offset = next
            } while true
            XCTAssertEqual(result, original)
        }
    }

    func testModificationBetweenPagesIsExplicit() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("output.txt")
        try Data("first recorded local content".utf8).write(to: file)
        let service = FileService()
        let first = try await service.readText(path: file.path, limit: 5)
        try Data("second current local content".utf8).write(to: file)
        do {
            _ = try await service.readText(path: file.path, offset: try XCTUnwrap(first.nextOffset), limit: 5, expectedVersion: first.version)
            XCTFail("A current file must not be combined with an earlier page")
        } catch FileServiceError.staleFile { }
        let reloaded = try await service.readText(path: file.path)
        XCTAssertEqual(reloaded.text, "second current local content")
    }

    func testDeletedEnvironmentPreservesHistoricalIdentity() async throws {
        let root = try temporaryDirectory()
        let gone = root.appendingPathComponent("deleted-worktree")
        let environment = EnvironmentRecord(path: gone.path, repositoryPath: root.path, recordedBranch: "historical-branch", recordedRef: "recorded-ref")
        let inspected = try await FileService().inspect(environment: environment)
        XCTAssertFalse(inspected.exists)
        XCTAssertEqual(inspected.path, gone.path)
        XCTAssertNil(inspected.head)
        XCTAssertNil(inspected.branch)
        XCTAssertEqual(environment.recordedBranch, "historical-branch")
        do {
            _ = try await FileService().children(path: gone.path)
            XCTFail("A deleted directory has no current tree")
        } catch FileServiceError.unavailable { }
    }

    func testBinaryAndIncompleteUTF8AreRejected() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("broken.txt")
        let samples: [[UInt8]] = [[65, 0, 66], [65, 0xf0, 0x9f], [0xff, 0x01]]
        for bytes in samples {
            try Data(bytes).write(to: file)
            do {
                _ = try await FileService().readText(path: file.path, limit: 1)
                XCTFail("Invalid/binary data must not be decoded with replacement characters")
            } catch FileServiceError.binary { }
        }
        try Data().write(to: file)
        let empty = try await FileService().readText(path: file.path)
        XCTAssertEqual(empty.text, "")
        XCTAssertNil(empty.nextOffset)
        XCTAssertEqual(empty.totalBytes, 0)
    }

    func testAuthenticationAndSymlinkTargetsAreNotReadOrPreviewed() async throws {
        let root = try temporaryDirectory()
        let secret = root.appendingPathComponent(".env")
        try Data("EXAMPLE_ONLY=fixture".utf8).write(to: secret)
        let link = root.appendingPathComponent("apparently-safe.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let service = FileService()
        let tree = try await service.children(path: root.path)
        XCTAssertTrue(try XCTUnwrap(tree.first { $0.id == link.path }).isSymbolicLink)
        XCTAssertTrue(try XCTUnwrap(tree.first { $0.id == link.path }).isRestricted)
        for path in [secret.path, link.path] {
            do { _ = try await service.readText(path: path); XCTFail("Authentication path read") }
            catch FileServiceError.restricted { }
            do { _ = try await service.previewURL(path: path); XCTFail("Authentication path preview") }
            catch FileServiceError.restricted { }
        }
        let ordinaryName = root.appendingPathComponent("notes.txt")
        try Data(("sk-" + String(repeating: "a", count: 35)).utf8).write(to: ordinaryName)
        do { _ = try await service.readText(path: ordinaryName.path, limit: 4); XCTFail("Recognizable key split across pages") }
        catch FileServiceError.restricted { }
    }

    func testNativePreviewHasOnlyCurrentAccessibleRegularFiles() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("image.png")
        try Data([137, 80, 78, 71]).write(to: file)
        let service = FileService()
        let preview = try await service.previewURL(path: file.path)
        XCTAssertEqual(preview, file.resolvingSymlinksInPath())
        do { _ = try await service.previewURL(path: root.path); XCTFail("A directory is not an attachment preview") }
        catch FileServiceError.unavailable { }
        try FileManager.default.removeItem(at: file)
        do { _ = try await service.previewURL(path: file.path); XCTFail("Missing attachment") }
        catch FileServiceError.unavailable { }
    }

    func testCurrentDiffExcludesAuthenticationAndDoesNotRunDiffDrivers() async throws {
        let root = try temporaryDirectory()
        try git(["init", "-q"], at: root)
        try git(["config", "user.name", "Lens Test"], at: root)
        try git(["config", "user.email", "lens@example.invalid"], at: root)
        let text = root.appendingPathComponent("file.txt")
        let secret = root.appendingPathComponent(".env")
        try Data("first\n".utf8).write(to: text)
        try Data("fixture-before\n".utf8).write(to: secret)
        try Data("file.txt diff=fixture\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        let driver = root.appendingPathComponent("driver.sh")
        try Data("#!/bin/sh\ntouch \"$PWD/driver-was-run\"\nprintf 'should never run'\n".utf8).write(to: driver)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driver.path)
        try git(["config", "diff.fixture.command", driver.path], at: root)
        try git(["config", "diff.fixture.textconv", driver.path], at: root)
        try git(["add", "file.txt", ".env", ".gitattributes"], at: root)
        try git(["commit", "-qm", "fixture"], at: root)
        try Data("manually edited\n".utf8).write(to: text)
        try Data("fixture-after-never-display\n".utf8).write(to: secret)
        let diff = try await FileService().currentDiff(environment: EnvironmentRecord(path: root.path))
        XCTAssertTrue(diff.text.contains("manually edited"))
        XCTAssertFalse(diff.text.contains("fixture-after-never-display"))
        XCTAssertEqual(diff.excludedPaths, [".env"])
        XCTAssertTrue(diff.reference.contains("Index actuel"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("driver-was-run").path))
        try git(["add", "file.txt"], at: root)
        let service = FileService()
        let inspected = try await service.inspect(environment: EnvironmentRecord(path: root.path))
        let staged = try await service.currentDiff(environment: EnvironmentRecord(path: root.path), staged: true)
        XCTAssertTrue(staged.text.contains("manually edited"))
        XCTAssertTrue(staged.reference.contains(try XCTUnwrap(inspected.head)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("driver-was-run").path))
    }

    func testHistoricalBlobUsesRecordedCommitWithoutMutatingDirtyFilesOrBranches() async throws {
        let root = try temporaryDirectory()
        try git(["init", "-q"], at: root)
        try git(["config", "user.name", "Lens Test"], at: root)
        try git(["config", "user.email", "lens@example.invalid"], at: root)
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file with space.swift")
        let initial = "let value = 1\n"
        try Data(initial.utf8).write(to: file)
        try git(["add", "nested/file with space.swift"], at: root)
        try git(["commit", "-qm", "first"], at: root)
        let firstRef = try gitOutput(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = EnvironmentRecord(path: root.path, recordedRef: firstRef)
        try Data("let value = 2\n".utf8).write(to: file)
        try git(["add", "nested/file with space.swift"], at: root)
        try git(["commit", "-qm", "second"], at: root)
        let secondRef = try gitOutput(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        // Git replacement refs must not change what an immutable recorded SHA means.
        try git(["replace", firstRef, secondRef], at: root)
        let dirty = "manual edit outside every commit\n"
        try Data(dirty.utf8).write(to: file)
        let branchBefore = try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let service = FileService()
        let historical = try await service.historicalText(environment: environment, relativePath: "nested/file with space.swift", reference: firstRef)
        XCTAssertEqual(historical.text, initial)
        XCTAssertEqual(historical.reference, firstRef)
        XCTAssertEqual(historical.path, "nested/file with space.swift")
        XCTAssertEqual(historical.blobID.count, 40)
        let originalBlob = try gitOutput(["--no-replace-objects", "rev-parse", firstRef + ":nested/file with space.swift"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(historical.blobID, originalBlob)
        XCTAssertEqual(try Data(contentsOf: file), Data(dirty.utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), branchBefore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), indexBefore)
        let current = try await service.readText(path: file.path)
        XCTAssertEqual(current.text, dirty)
        let removedEnvironment = EnvironmentRecord(path: root.appendingPathComponent("removed-worktree").path, repositoryPath: root.path, recordedRef: firstRef)
        let retained = try await service.historicalText(environment: removedEnvironment, relativePath: "nested/file with space.swift", reference: firstRef)
        XCTAssertEqual(retained.blobID, historical.blobID)
    }

    func testHistoricalMissingRefPathSecretsAndOversizedBlobFailExplicitly() async throws {
        let root = try temporaryDirectory()
        try git(["init", "-q"], at: root)
        try git(["config", "user.name", "Lens Test"], at: root)
        try git(["config", "user.email", "lens@example.invalid"], at: root)
        try Data("ordinary\n".utf8).write(to: root.appendingPathComponent("small.txt"))
        try Data("fixture-auth-data\n".utf8).write(to: root.appendingPathComponent(".env"))
        try Data(repeating: 65, count: 8_388_609).write(to: root.appendingPathComponent("large.txt"))
        try Data(("sk-" + String(repeating: "a", count: 35)).utf8).write(to: root.appendingPathComponent("secret-in-content.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked.txt").path, withDestinationPath: "small.txt")
        try git(["add", "small.txt", ".env", "large.txt", "secret-in-content.txt", "linked.txt"], at: root)
        try git(["commit", "-qm", "fixture"], at: root)
        let reference = try gitOutput(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = EnvironmentRecord(path: root.path, recordedRef: reference)
        let service = FileService()
        do { _ = try await service.historicalText(environment: environment, relativePath: "small.txt", reference: "HEAD"); XCTFail("Symbolic reference") }
        catch FileServiceError.invalidReference { }
        let absent = String(repeating: "0", count: 40)
        do { _ = try await service.historicalText(environment: EnvironmentRecord(path: root.path, recordedRef: absent), relativePath: "small.txt", reference: absent); XCTFail("Absent commit") }
        catch FileServiceError.historicalUnavailable { }
        for path in ["absent.txt", "linked.txt"] {
            do { _ = try await service.historicalText(environment: environment, relativePath: path, reference: reference); XCTFail("Absent/nonregular entry") }
            catch FileServiceError.historicalUnavailable { }
        }
        for path in [".env", "secret-in-content.txt"] {
            do { _ = try await service.historicalText(environment: environment, relativePath: path, reference: reference); XCTFail("Historical auth content") }
            catch FileServiceError.restricted { }
        }
        do { _ = try await service.historicalText(environment: environment, relativePath: "large.txt", reference: reference); XCTFail("Oversized blob") }
        catch FileServiceError.outputTooLarge { }
        do { _ = try await service.historicalText(environment: environment, relativePath: "../small.txt", reference: reference); XCTFail("Path escape") }
        catch FileServiceError.invalidPath { }
        // A valid zlib object stored under the wrong hash must not become a verified past version.
        let smallBlob = try gitOutput(["rev-parse", reference + ":small.txt"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementFile = root.appendingPathComponent("replacement.txt")
        try Data("different object bytes\n".utf8).write(to: replacementFile)
        let wrongBlob = try gitOutput(["hash-object", "-w", "replacement.txt"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        func objectURL(_ hash: String) -> URL {
            root.appendingPathComponent(".git/objects").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(String(hash.dropFirst(2)))
        }
        try FileManager.default.removeItem(at: objectURL(smallBlob))
        try FileManager.default.copyItem(at: objectURL(wrongBlob), to: objectURL(smallBlob))
        do { _ = try await service.historicalText(environment: environment, relativePath: "small.txt", reference: reference); XCTFail("Misnamed object bytes") }
        catch FileServiceError.historicalUnavailable { }
    }

    private func git(_ arguments: [String], at root: URL) throws {
        _ = try gitOutput(arguments, at: root)
    }

    private func gitOutput(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LensGitFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
