import Foundation
import XCTest
@testable import LensCore

final class CodexInstallationTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensInstalledCodex-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func binary(_ path: URL, version: String, exit: Int = 0) throws -> URL {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = "#!/bin/sh\n[ \"$1\" = \"--version\" ] || exit 91\nprintf '%s\\n' 'codex-cli " + version + "'\nexit " + String(exit) + "\n"
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    func testDetectionIncludesUserAppsAndPathWithoutShellOrRelativeDirectory() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let app = try binary(base.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"), version: "0.159.2")
        let cli = try binary(base.appendingPathComponent("bin/codex"), version: "0.159.2")
        let links = base.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("codex"), withDestinationURL: cli)
        let found = CodexInstallation.candidates(home: base, path: "relative:.:" + cli.deletingLastPathComponent().path + ":" + links.path, applications: [base.appendingPathComponent("Applications")])
        XCTAssertEqual(found, [app, cli])
    }
    func testAutomaticDiscoverySkipsOldVersionButExplicitChoiceNeverFallsBack() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let old = try binary(base.appendingPathComponent("old/codex"), version: "0.143.0")
        let qualified = try binary(base.appendingPathComponent("new/codex"), version: "0.160.1")
        let detected = try await CodexInstallation.qualifiedExecutable(candidates: [old, qualified])
        XCTAssertEqual(detected, qualified)
        do { _ = try await CodexInstallation.qualifiedExecutable(preferred: old, candidates: [qualified]); XCTFail("Explicit unsupported choice must not fall back") }
        catch { XCTAssertTrue(error.localizedDescription.contains("0.143.0")) }
    }
    func testBothQualifiedVersionsAreAcceptedAndReportedExactly() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(CodexInstallation.supportedVersions, ["0.159.2", "0.160.1"])
        for version in CodexInstallation.supportedVersions {
            let installed = try binary(base.appendingPathComponent(version + "/codex"), version: version)
            let chosen = try await CodexInstallation.qualifiedExecutable(preferred: installed)
            XCTAssertEqual(chosen, installed)
            let actual = try await CodexInvestigationPolicy.version(executable: chosen)
            XCTAssertEqual(actual, version)
        }
    }
    func testVersionAllowlistRejectsNeighboursPrereleasesAndUnknownVersions() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(CodexInstallation.isSupportedVersion(nil))
        for version in ["0.143.0", "0.159.1", "0.159.3", "0.160.0", "0.160.2", "0.161.0", "0.160.1-beta.1", "0.160.1+local"] {
            XCTAssertFalse(CodexInstallation.isSupportedVersion(version), version)
            let installed = try binary(base.appendingPathComponent(version + "/codex"), version: version)
            do {
                _ = try await CodexInstallation.qualifiedExecutable(preferred: installed)
                XCTFail("Unqualified version must fail: " + version)
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("0.159.2"))
                XCTAssertTrue(error.localizedDescription.contains("0.160.1"))
            }
        }
    }
    func testMissingExplicitExecutablePreservesChoiceAndFails() async throws {
        do { _ = try await CodexInstallation.qualifiedExecutable(preferred: URL(fileURLWithPath: "/nonexistent/lens/codex")); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("plus accessible")) }
    }
    func testFailedAndMalformedVersionProbeCannotQualify() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let failed = try binary(base.appendingPathComponent("failed/codex"), version: "0.159.2", exit: 1)
        let malformed = try binary(base.appendingPathComponent("malformed/codex"), version: "0.159.2 extra")
        let version = try await CodexInvestigationLocalStatus.inspectVersion(executable: malformed)
        XCTAssertNil(version)
        do { _ = try await CodexInstallation.qualifiedExecutable(candidates: [failed, malformed]); XCTFail() } catch { }
    }
    func testVersionProbeCancelsItsOwnProcess() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let task = Task { try await CodexInvestigationLocalStatus.inspectVersion(executable: path) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError { } catch { XCTFail("Expected cancellation") }
    }
}
