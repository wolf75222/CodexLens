import Foundation
import XCTest
@testable import LensCore

final class LensUninstallPolicyTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let applications: URL
        let app: URL
        let executable: URL
        var policy: LensUninstallPolicy { LensUninstallPolicy(homeDirectory: home, systemApplicationsDirectory: applications) }
        var library: URL { home.appendingPathComponent("Library") }
    }

    private func fixture(userInstallation: Bool = false, identifier: String = LensUninstallPolicy.bundleIdentifier, dirty: Bool = false) throws -> Fixture {
        // /var (the user's temporaryDirectory) is itself a macOS symlink;
        // policy deliberately refuses symlink ancestors. Use its real path.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LensUninstall-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let applications = root.appendingPathComponent("Applications")
        let selected = userInstallation ? home.appendingPathComponent("Applications") : applications
        let app = selected.appendingPathComponent("Codex Lens.app")
        let executable = app.appendingPathComponent("Contents/MacOS/CodexLens")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("fixture executable; never launched".utf8).write(to: executable)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "CodexLens"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "dirty": dirty, "sourceCommit": String(repeating: "a", count: 40)])
            .write(to: app.appendingPathComponent("Contents/Resources/BuildInfo.json"))
        return Fixture(root: root, home: home, applications: applications, app: app, executable: executable)
    }

    private func review(_ f: Fixture, cleanup: Bool = false) throws -> LensUninstallPlan {
        try f.policy.review(applicationURL: f.app, runningExecutableURL: f.executable, removeLocalData: cleanup)
    }
    private func assertError(_ expected: LensUninstallPolicyError, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? LensUninstallPolicyError, expected, file: file, line: line)
        }
    }
    private func directory(_ path: String, in f: Fixture) throws -> URL {
        let result = f.library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try Data("owned fixture data".utf8).write(to: result.appendingPathComponent("keep.txt"))
        return result
    }

    func testDefaultPlanRecyclesOnlyRunningInstalledAppAndDoesNotMutate() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let support = try directory("Application Support/CodexLens/Investigations", in: f)
        let before = try Data(contentsOf: f.executable)
        let plan = try review(f)
        XCTAssertEqual(plan.urlsToRecycle.map(\.path), [f.app.path])
        XCTAssertFalse(plan.resetPreferences)
        XCTAssertEqual(plan.localDataURLs.count, 4)
        XCTAssertEqual(try Data(contentsOf: f.executable), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("keep.txt").path))
    }

    func testUserApplicationsInstallationAndRenamedAppAreSupported() throws {
        let f = try fixture(userInstallation: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let renamed = f.app.deletingLastPathComponent().appendingPathComponent("Lens renamed.app")
        try FileManager.default.moveItem(at: f.app, to: renamed)
        let plan = try f.policy.review(applicationURL: renamed, runningExecutableURL: renamed.appendingPathComponent("Contents/MacOS/CodexLens"))
        XCTAssertEqual(plan.urlsToRecycle.map(\.path), [renamed.path])
    }

    func testExplicitCleanupIncludesOnlyFourOwnedDefaultLocations() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let support = try directory("Application Support/CodexLens", in: f)
        let indexCache = try directory("Caches/CodexLens", in: f)
        let domainCache = try directory("Caches/fr.codexlens.inspector", in: f)
        let preferences = f.library.appendingPathComponent("Preferences/fr.codexlens.inspector.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned preferences fixture".utf8).write(to: preferences)
        let codex = f.home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("not an authentication secret; test sentinel".utf8).write(to: codex.appendingPathComponent("auth.json"))
        let custom = try directory("Custom Lens Data", in: f)
        let observed = try directory("observed repository", in: f)
        let exported = try directory("Exports", in: f)
        let plan = try review(f, cleanup: true)
        XCTAssertEqual(Set(plan.urlsToRecycle.map(\.path)), Set([f.app, support, indexCache, domainCache, preferences].map(\.path)))
        XCTAssertTrue(plan.resetPreferences)
        for kept in [codex.appendingPathComponent("auth.json"), custom.appendingPathComponent("keep.txt"), observed.appendingPathComponent("keep.txt"), exported.appendingPathComponent("keep.txt")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
            XCTAssertFalse(plan.urlsToRecycle.contains(kept))
        }
        XCTAssertEqual(try Data(contentsOf: preferences), Data("owned preferences fixture".utf8))
    }

    func testMissingOwnedDataIsSkippedWithoutCreatingDirectories() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = try review(f, cleanup: true)
        XCTAssertEqual(plan.urlsToRecycle.map(\.path), [f.app.path]); XCTAssertTrue(plan.resetPreferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.library.path))
    }

    func testQABundleIdentityIsProtected() throws {
        let f = try fixture(identifier: "fr.codexlens.inspector.qa.123"); defer { try? FileManager.default.removeItem(at: f.root) }
        assertError(.unsupportedApplication) { _ = try review(f, cleanup: true) }
    }

    func testDirtyDevelopmentBuildIsProtected() throws {
        let f = try fixture(dirty: true); defer { try? FileManager.default.removeItem(at: f.root) }
        assertError(.unverifiedBuild) { _ = try review(f) }
    }

    func testMissingOrMalformedBuildReceiptDoesNotEnableUninstall() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let receipt = f.app.appendingPathComponent("Contents/Resources/BuildInfo.json")
        try FileManager.default.removeItem(at: receipt)
        assertError(.unverifiedBuild) { _ = try review(f) }
        try Data("{}".utf8).write(to: receipt)
        assertError(.unverifiedBuild) { _ = try review(f) }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "dirty": 0, "sourceCommit": String(repeating: "a", count: 40)]).write(to: receipt)
        assertError(.unverifiedBuild) { _ = try review(f) }
        try Data(repeating: 32, count: 65 * 1024).write(to: receipt)
        assertError(.unverifiedBuild) { _ = try review(f) }
    }

    func testSourceCheckoutDiskImageAndNestedApplicationsAreProtected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for container in ["source/dist", "Volumes/Codex Lens", "Applications/nested"] {
            let app = f.root.appendingPathComponent(container + "/Codex Lens.app")
            assertError(.outsideApplications) {
                _ = try f.policy.review(applicationURL: app, runningExecutableURL: app.appendingPathComponent("Contents/MacOS/CodexLens"))
            }
        }
    }

    func testDifferentRunningExecutableCannotSelectAnotherInstallation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        assertError(.unsupportedApplication) {
            _ = try f.policy.review(applicationURL: f.app, runningExecutableURL: f.root.appendingPathComponent("another/Contents/MacOS/CodexLens"))
        }
    }

    func testApplicationSymlinkIsRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let actual = f.root.appendingPathComponent("source.app")
        try FileManager.default.moveItem(at: f.app, to: actual)
        try FileManager.default.createSymbolicLink(at: f.app, withDestinationURL: actual)
        assertError(.unsafePath(f.app.path)) { _ = try review(f) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: actual.path))
    }

    func testApplicationsAncestorSymlinkIsRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let actual = f.root.appendingPathComponent("actual Applications")
        try FileManager.default.moveItem(at: f.applications, to: actual)
        try FileManager.default.createSymbolicLink(at: f.applications, withDestinationURL: actual)
        assertError(.unsafePath(f.applications.path)) { _ = try review(f) }
    }

    func testMetadataAndExecutableSymlinksAreRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let info = f.app.appendingPathComponent("Contents/Info.plist")
        let actualInfo = f.root.appendingPathComponent("Info.plist")
        try FileManager.default.moveItem(at: info, to: actualInfo)
        try FileManager.default.createSymbolicLink(at: info, withDestinationURL: actualInfo)
        assertError(.unsafePath(info.path)) { _ = try review(f) }
        try FileManager.default.removeItem(at: info)
        try FileManager.default.moveItem(at: actualInfo, to: info)
        let actualExecutable = f.root.appendingPathComponent("executable")
        try FileManager.default.moveItem(at: f.executable, to: actualExecutable)
        try FileManager.default.createSymbolicLink(at: f.executable, withDestinationURL: actualExecutable)
        assertError(.unsafePath(f.executable.path)) { _ = try review(f) }
    }

    func testOptionalDataSymlinkIsPreservedByDefaultAndRefusedForCleanup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let external = try directory("external archive", in: f)
        let support = f.library.appendingPathComponent("Application Support/CodexLens")
        try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: external)
        XCTAssertEqual(try review(f).urlsToRecycle.map(\.path), [f.app.path])
        assertError(.unsafePath(support.path)) { _ = try review(f, cleanup: true) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("keep.txt").path))
    }

    func testDataAncestorSymlinkAndWrongObjectTypeAreRefused() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let external = try directory("external Library", in: f)
        let caches = f.library.appendingPathComponent("Caches")
        try FileManager.default.createSymbolicLink(at: caches, withDestinationURL: external)
        assertError(.unsafePath(caches.path)) { _ = try review(f, cleanup: true) }
        try FileManager.default.removeItem(at: caches)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let badDirectory = caches.appendingPathComponent("CodexLens")
        try Data("a file cannot act as an owned directory".utf8).write(to: badDirectory)
        assertError(.unsafePath(badDirectory.path)) { _ = try review(f, cleanup: true) }
    }

    func testExecutionRecheckRejectsNewSymlinkAfterReview() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = try review(f, cleanup: true)
        let external = try directory("external archive", in: f)
        let support = f.library.appendingPathComponent("Application Support/CodexLens")
        try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: external)
        assertError(.unsafePath(support.path)) { _ = try f.policy.validateForExecution(plan) }
    }

    func testExecutionRecheckRejectsReplacedAppIdentity() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = try review(f)
        let previous = f.root.appendingPathComponent("previous.app")
        try FileManager.default.moveItem(at: f.app, to: previous)
        try FileManager.default.copyItem(at: previous, to: f.app)
        assertError(.changedApplication) { _ = try f.policy.validateForExecution(plan) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
    }

    func testCustomStorageInsideDefaultRootPreservesWholeRoot() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let custom = try directory("Application Support/CodexLens/custom archive", in: f)
        let cache = try directory("Caches/CodexLens", in: f)
        let policy = LensUninstallPolicy(homeDirectory: f.home, systemApplicationsDirectory: f.applications, preservedStorageURLs: [custom])
        let plan = try policy.review(applicationURL: f.app, runningExecutableURL: f.executable, removeLocalData: true)
        let support = f.library.appendingPathComponent("Application Support/CodexLens")
        XCTAssertEqual(plan.preservedLocalDataURLs.map(\.path), [support.path])
        XCTAssertEqual(Set(plan.urlsToRecycle.map(\.path)), Set([f.app.path, cache.path]))
        XCTAssertEqual(try policy.validateForExecution(plan).urlsToRecycle.map(\.path), plan.urlsToRecycle.map(\.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent("keep.txt").path))
    }

    func testPreservedPreferenceLocationDoesNotDisableOtherExplicitCleanup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let support = try directory("Application Support/CodexLens", in: f)
        let preferences = f.library.appendingPathComponent("Preferences/fr.codexlens.inspector.plist")
        let policy = LensUninstallPolicy(homeDirectory: f.home, systemApplicationsDirectory: f.applications, preservedStorageURLs: [preferences])
        let plan = try policy.review(applicationURL: f.app, runningExecutableURL: f.executable, removeLocalData: true)
        XCTAssertFalse(plan.resetPreferences)
        XCTAssertEqual(plan.preservedLocalDataURLs.map(\.path), [preferences.path])
        XCTAssertEqual(Set(try policy.validateForExecution(plan).urlsToRecycle.map(\.path)), Set([f.app.path, support.path]))
    }

    func testCustomStorageSymlinkAliasPreservesItsTargetAndMissingDescendants() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let custom = try directory("Application Support/CodexLens/custom archive", in: f)
        let alias = f.home.appendingPathComponent("custom archive alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: custom)
        let support = f.library.appendingPathComponent("Application Support/CodexLens")
        for location in [alias, alias.appendingPathComponent("not-created-yet/nested")] {
            let policy = LensUninstallPolicy(homeDirectory: f.home, systemApplicationsDirectory: f.applications, preservedStorageURLs: [location])
            let plan = try policy.review(applicationURL: f.app, runningExecutableURL: f.executable, removeLocalData: true)
            XCTAssertEqual(plan.preservedLocalDataURLs.map(\.path), [support.path])
            XCTAssertEqual(plan.urlsToRecycle.map(\.path), [f.app.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent("keep.txt").path))
        }
    }
}
