import Foundation
import XCTest
@testable import LensCore

final class RecordedCommitDiffTests: XCTestCase {
    func testRecordedCommitIncludesCommittedStagedAndUnstagedChangesWithoutMutatingSources() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("first.txt", "recorded first\n", at: root)
        try write("second with space.txt", "recorded second\n", at: root)
        try write("unchanged.txt", "unchanged source\n", at: root)
        try git(["add", "."], at: root)
        try git(["commit", "-qm", "recorded baseline"], at: root)
        let recorded = try head(at: root)
        let environment = EnvironmentRecord(path: root.path, recordedRef: recorded)
        try write("first.txt", "committed first\n", at: root)
        try git(["add", "first.txt"], at: root)
        try git(["commit", "-qm", "subsequent commit"], at: root)
        let currentHead = try head(at: root)
        // Replacement refs cannot change the recorded immutable baseline.
        try git(["replace", recorded, currentHead], at: root)
        try write("first.txt", "staged first\n", at: root)
        try git(["add", "first.txt"], at: root)
        try write("first.txt", "current first\n", at: root)
        try write("second with space.txt", "current second\n", at: root)
        try write("untracked.txt", "untracked source\n", at: root)
        let paths = ["first.txt", "second with space.txt", "unchanged.txt", "untracked.txt", ".git/HEAD", ".git/index"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let observedBefore = Date()
        let service = FileService()
        let diff = try await service.currentDiff(environment: environment, recordedReference: recorded)
        XCTAssertTrue(diff.text.contains("-recorded first"))
        XCTAssertTrue(diff.text.contains("+current first"))
        XCTAssertTrue(diff.text.contains("-recorded second"))
        XCTAssertTrue(diff.text.contains("+current second"))
        XCTAssertFalse(diff.text.contains("committed first"))
        XCTAssertFalse(diff.text.contains("staged first"))
        XCTAssertFalse(diff.text.contains("unchanged.txt"))
        XCTAssertFalse(diff.text.contains("untracked.txt"))
        XCTAssertEqual(diff.reference, "Commit enregistré \(recorded) → worktree actuel")
        XCTAssertGreaterThanOrEqual(diff.observedAt, observedBefore)
        XCTAssertLessThanOrEqual(diff.observedAt, Date())
        XCTAssertEqual(diff.excludedPaths, [])
        // A lingering index toggle cannot narrow an explicit worktree baseline.
        let withIndexToggle = try await service.currentDiff(environment: environment, staged: true, recordedReference: recorded)
        XCTAssertEqual(withIndexToggle.text, diff.text)
        let selected = try await service.currentDiff(environment: environment, relativePath: "second with space.txt", recordedReference: recorded)
        XCTAssertTrue(selected.text.contains("+current second"))
        XCTAssertFalse(selected.text.contains("first.txt"))
        let ordinary = try await service.currentDiff(environment: environment)
        XCTAssertTrue(ordinary.text.contains("-staged first"))
        XCTAssertFalse(ordinary.text.contains("-recorded first"))
        let staged = try await service.currentDiff(environment: environment, staged: true)
        XCTAssertTrue(staged.text.contains("-committed first"))
        XCTAssertTrue(staged.text.contains("+staged first"))
        XCTAssertTrue(staged.reference.contains(currentHead))
        XCTAssertEqual(try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
        XCTAssertEqual(try head(at: root), currentHead)
    }

    func testMissingMismatchedSymbolicAndAbbreviatedReferencesNeverFallBackToHEAD() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("file.txt", "recorded\n", at: root)
        try git(["add", "."], at: root)
        try git(["commit", "-qm", "baseline"], at: root)
        let recorded = try head(at: root)
        try write("file.txt", "committed\n", at: root)
        try git(["add", "."], at: root)
        try git(["commit", "-qm", "later"], at: root)
        let later = try head(at: root)
        try write("file.txt", "dirty\n", at: root)
        let service = FileService()
        for reference in ["HEAD", String(recorded.prefix(8)), recorded + "^{commit}", recorded + "\n", "--cached", String(repeating: "z", count: 40), later] {
            do {
                _ = try await service.currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: recorded), recordedReference: reference)
                XCTFail("Invalid reference must fail: " + reference)
            } catch FileServiceError.invalidReference { }
        }
        do {
            _ = try await service.currentDiff(environment: EnvironmentRecord(path: root.path), recordedReference: recorded)
            XCTFail("Missing recorded association must fail")
        } catch FileServiceError.invalidReference { }
        for missing in [String(repeating: "a", count: 40), String(repeating: "b", count: 64)] {
            do {
                _ = try await service.currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: missing), recordedReference: missing)
                XCTFail("Missing commit must fail")
            } catch FileServiceError.historicalUnavailable { }
        }
        let blob = try git(["rev-parse", recorded + ":file.txt"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await service.currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: blob), recordedReference: blob)
            XCTFail("A blob cannot be a commit baseline")
        } catch FileServiceError.historicalUnavailable { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file.txt")), Data("dirty\n".utf8))
        XCTAssertEqual(try head(at: root), later)
    }

    func testRecordedCommitExcludesAuthenticationPathsAndNeverRunsGitDriversOrMonitors() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("file.txt", "recorded public\n", at: root)
        try write(".env", "excluded environment before\n", at: root)
        try write("auth.json", "excluded authentication before\n", at: root)
        try write(".gitattributes", "file.txt diff=fixture\n", at: root)
        try git(["add", "."], at: root)
        try git(["commit", "-qm", "baseline"], at: root)
        let recorded = try head(at: root)
        let driver = root.appendingPathComponent("fixture-driver.sh")
        try write(driver.lastPathComponent, "#!/bin/sh\n/usr/bin/touch \"$PWD/driver-must-not-run\"\nexit 1\n", at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: driver.path)
        try git(["config", "diff.fixture.command", driver.path], at: root)
        try git(["config", "diff.fixture.textconv", driver.path], at: root)
        try git(["config", "core.fsmonitor", driver.path], at: root)
        try git(["config", "core.hooksPath", root.path], at: root)
        try write("file.txt", "current public\n", at: root)
        try write(".env", "excluded environment after\n", at: root)
        try write("auth.json", "excluded authentication after\n", at: root)
        let diff = try await FileService().currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: recorded), recordedReference: recorded)
        XCTAssertTrue(diff.text.contains("current public"))
        XCTAssertFalse(diff.text.contains("excluded environment"))
        XCTAssertFalse(diff.text.contains("excluded authentication"))
        XCTAssertEqual(Set(diff.excludedPaths), Set([".env", "auth.json"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("driver-must-not-run").path))
        do {
            _ = try await FileService().currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: recorded), relativePath: "auth.json", recordedReference: recorded)
            XCTFail("Explicit authentication path stays restricted")
        } catch FileServiceError.restricted { }
    }

    func testRecordedCommitRejectsCredentialPatternsInOtherwiseAllowedContent() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("public.txt", "recorded safe\n", at: root)
        try git(["add", "."], at: root)
        try git(["commit", "-qm", "baseline"], at: root)
        let recorded = try head(at: root)
        try write("public.txt", "sk-" + String(repeating: "x", count: 24) + "\n", at: root)
        do {
            _ = try await FileService().currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: recorded), recordedReference: recorded)
            XCTFail("Credential-shaped synthetic content must not be returned")
        } catch FileServiceError.restricted { }
    }

    func testRecordedCommitAcceptsFullSHA256OnlyWhenTheRepositoryVerifiesIt() async throws {
        let root: URL
        do { root = try repository(objectFormat: "sha256") }
        catch { throw XCTSkip("Installed Git does not support SHA-256 fixture repositories.") }
        defer { try? FileManager.default.removeItem(at: root) }
        try write("file.txt", "recorded\n", at: root)
        try git(["add", "."], at: root)
        try git(["commit", "-qm", "baseline"], at: root)
        let recorded = try head(at: root)
        XCTAssertEqual(recorded.count, 64)
        try write("file.txt", "current\n", at: root)
        let diff = try await FileService().currentDiff(environment: EnvironmentRecord(path: root.path, recordedRef: recorded), recordedReference: recorded)
        XCTAssertTrue(diff.text.contains("-recorded"))
        XCTAssertTrue(diff.text.contains("+current"))
        XCTAssertTrue(diff.reference.contains(recorded))
    }

    private func repository(objectFormat: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensRecordedCommitDiff-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try git(["init", "-q"] + (objectFormat.map { ["--object-format=" + $0] } ?? []), at: root)
            try git(["config", "user.name", "Lens Test"], at: root)
            try git(["config", "user.email", "lens@example.invalid"], at: root)
            return root
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    private func write(_ path: String, _ content: String, at root: URL) throws {
        try Data(content.utf8).write(to: root.appendingPathComponent(path))
    }

    private func head(at root: URL) throws -> String {
        try git(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult private func git(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LensRecordedCommitDiffFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: bytes, as: UTF8.self)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
