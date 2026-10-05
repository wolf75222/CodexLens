import XCTest
@testable import LensCore

final class FileSearchTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("codex-lens-search-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }

    func testSameRelativePathInTwoWorktreesHasDistinctIdentity() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for worktree in [first, second] {
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            try write("manual needle\n", worktree.appendingPathComponent("same.swift"))
        }
        let search = FileSearch()
        let a = try await search.search(environment: EnvironmentRecord(path: first.path), query: "needle")
        let b = try await search.search(environment: EnvironmentRecord(path: second.path), query: "needle")
        XCTAssertEqual(a.hits.count, 1); XCTAssertEqual(b.hits.count, 1)
        XCTAssertEqual(a.hits.first?.relativePath, "same.swift")
        XCTAssertEqual(b.hits.first?.relativePath, "same.swift")
        XCTAssertNotEqual(a.hits.first?.id, b.hits.first?.id)
        XCTAssertNotEqual(a.hits.first?.path, b.hits.first?.path)
        XCTAssertNotEqual(a.hits.first?.environmentID, b.hits.first?.environmentID)
        XCTAssertTrue(a.complete && b.complete)
    }

    func testPagesKeepLineContextAndUTF16Columns() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "x", count: 254) + "NeedLe\n😀 needle\r\nlast NEEDLE"
        try write(text, root.appendingPathComponent("page.txt"))
        let result = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle", options: FileSearchOptions(pageBytes: 256))
        XCTAssertEqual(result.hits.map(\.line), [1, 2, 3])
        XCTAssertEqual(result.hits.map(\.column), [255, 4, 6])
        XCTAssertEqual(result.hits.map(\.length), [6, 6, 6])
        XCTAssertEqual(Set(result.hits.map(\.version)).count, 1)
        XCTAssertFalse(result.hits.first?.version.isEmpty ?? true)
        XCTAssertEqual(result.decodedBytes, text.utf8.count)
        XCTAssertEqual(result.searchedFiles, 1); XCTAssertTrue(result.complete)
        let sensitive = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle", options: FileSearchOptions(caseSensitive: true))
        XCTAssertEqual(sensitive.hits.map(\.line), [2])
    }

    func testExactByteBudgetAllowsLastSmallPageAndMultibyteCharacter() async throws {
        for text in ["word", "😀", "needle"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            try write(text, root.appendingPathComponent("small.txt"))
            let result = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: text, options: FileSearchOptions(maxTotalBytes: text.utf8.count))
            XCTAssertEqual(result.hits.count, 1, text)
            XCTAssertEqual(result.decodedBytes, text.utf8.count)
            XCTAssertTrue(result.complete, text)
        }
    }

    func testRestrictedNamesAndSymlinkTargetsAreNeverSearched() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", root.appendingPathComponent(".env"))
        try write("needle", root.appendingPathComponent("id_rsa"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("innocent.txt"), withDestinationURL: root.appendingPathComponent(".env"))
        try write("needle", root.appendingPathComponent("public.txt"))
        let result = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle")
        XCTAssertEqual(result.hits.map(\.relativePath), ["public.txt"])
        XCTAssertEqual(result.searchedFiles, 1)
        XCTAssertEqual(result.coverage.filter { $0.category == "restricted" }.count, 3)
        XCTAssertFalse(result.complete)
    }

    func testBinaryAndOversizeFilesReportMissingCoverage() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xff, 0, 0x41]).write(to: root.appendingPathComponent("binary.dat"))
        try write(String(repeating: "needle", count: 20), root.appendingPathComponent("large.txt"))
        try write("needle", root.appendingPathComponent("small.txt"))
        let result = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle", options: FileSearchOptions(maxFileBytes: 32))
        XCTAssertEqual(result.hits.map(\.relativePath), ["small.txt"])
        XCTAssertTrue(result.coverage.contains { $0.category == "binary" })
        XCTAssertTrue(result.coverage.contains { $0.category == "oversize" })
        XCTAssertEqual(result.searchedFiles, 1); XCTAssertFalse(result.complete)
    }

    func testLateBinaryBytesInvalidateProvisionalMatchesEvenAfterMatchLimit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var bytes = Data(("needle\n" + String(repeating: "x", count: 4096)).utf8); bytes.append(0)
        try bytes.write(to: root.appendingPathComponent("late.bin"))
        let result = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle", options: FileSearchOptions(maxMatches: 1, pageBytes: 256))
        XCTAssertTrue(result.hits.isEmpty); XCTAssertEqual(result.searchedFiles, 0)
        XCTAssertTrue(result.coverage.contains { $0.category == "binary" })
        XCTAssertFalse(result.coverage.contains { $0.category == "limit.matches" })
    }

    func testChangedFileDiscardsAllItsProvisionalHits() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("mutable.txt")
        try write("needle\n" + String(repeating: "x", count: 4096), path)
        let reader = SearchMutatingReader(path: path)
        let result = try await FileSearch(reader: reader).search(environment: EnvironmentRecord(path: root.path), query: "needle", options: FileSearchOptions(pageBytes: 256))
        XCTAssertTrue(result.hits.isEmpty); XCTAssertEqual(result.searchedFiles, 0)
        XCTAssertTrue(result.coverage.contains { $0.category == "changed" })
        XCTAssertFalse(result.complete)
    }

    func testCancellationReturnsPartialCoverageWithoutMoreReads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", root.appendingPathComponent("slow.txt"))
        let reader = SearchCancellationReader()
        let search = FileSearch(reader: reader)
        let task = Task { try await search.search(environment: EnvironmentRecord(path: root.path), query: "needle") }
        while !(await reader.hasStarted()) { await Task.yield() }
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled); XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.coverage.contains { $0.category == "cancelled" }); XCTAssertFalse(result.complete)
        let reads = await reader.readCount()
        XCTAssertEqual(reads, 1)
    }

    func testMatchFileAndByteLimitsAreExplicit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try write("needle needle", root.appendingPathComponent("a.txt"))
        try write("needle", root.appendingPathComponent("b.txt"))
        let environment = EnvironmentRecord(path: root.path)
        let matches = try await FileSearch().search(environment: environment, query: "needle", options: FileSearchOptions(maxMatches: 1))
        XCTAssertEqual(matches.hits.count, 1); XCTAssertTrue(matches.coverage.contains { $0.category == "limit.matches" })
        let files = try await FileSearch().search(environment: environment, query: "needle", options: FileSearchOptions(maxFiles: 1))
        XCTAssertEqual(files.visitedFiles, 1); XCTAssertTrue(files.coverage.contains { $0.category == "limit.files" })
        let bytes = try await FileSearch().search(environment: environment, query: "needle", options: FileSearchOptions(maxTotalBytes: 6))
        XCTAssertEqual(bytes.hits.map(\.relativePath), ["b.txt"])
        XCTAssertEqual(bytes.decodedBytes, 6); XCTAssertTrue(bytes.coverage.contains { $0.category == "limit.bytes" })
    }

    func testSymlinkDirectoryAndExplicitExclusionRemainVisibleAsCoverage() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let excluded = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try write("needle", excluded.appendingPathComponent("ignored.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        try write("needle", root.appendingPathComponent("public.txt"))
        let result = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle")
        XCTAssertEqual(result.hits.map(\.relativePath), ["public.txt"])
        XCTAssertTrue(result.coverage.contains { $0.category == "symlinkDirectory" })
        XCTAssertTrue(result.coverage.contains { $0.category == "excludedDirectory" })
        XCTAssertEqual(result.visitedDirectories, 1)
    }

    func testMissingEnvironmentAndCoverageOverflowAreExplicit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = try await FileSearch().search(environment: EnvironmentRecord(path: root.appendingPathComponent("missing").path), query: "needle")
        XCTAssertTrue(missing.hits.isEmpty); XCTAssertTrue(missing.coverage.contains { $0.category == "unavailable" })
        for name in [".env", "id_rsa", "auth.json"] { try write("needle", root.appendingPathComponent(name)) }
        let capped = try await FileSearch().search(environment: EnvironmentRecord(path: root.path), query: "needle", options: FileSearchOptions(maxCoverageIssues: 1))
        XCTAssertEqual(capped.coverage.count, 1); XCTAssertEqual(capped.coverageOmittedCount, 2)
        XCTAssertFalse(capped.complete)
    }

    func testSnippetIsBoundedAndHitIdentityTracksVersion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("long.txt")
        try write(String(repeating: "😀", count: 70) + "needle" + String(repeating: "😀", count: 70), path)
        let search = FileSearch(), environment = EnvironmentRecord(path: root.path)
        let a = try await search.search(environment: environment, query: "needle", options: FileSearchOptions(maxSnippetCharacters: 16))
        let unchanged = try await search.search(environment: environment, query: "needle", options: FileSearchOptions(maxSnippetCharacters: 16))
        XCTAssertEqual(a.hits.first?.id, unchanged.hits.first?.id)
        XCTAssertEqual(a.hits.first?.column, 141); XCTAssertTrue(a.hits.first?.snippetTruncated ?? false)
        XCTAssertLessThanOrEqual(a.hits.first?.snippet.utf16.count ?? 100, 18)
        XCTAssertTrue(a.hits.first?.snippet.contains("needle") ?? false)
        try write("needle changed", path)
        let b = try await search.search(environment: environment, query: "needle")
        XCTAssertNotEqual(a.hits.first?.id, b.hits.first?.id)
        XCTAssertNotEqual(a.hits.first?.version, b.hits.first?.version)
    }

    func testInvalidQueryAndBoundsRejectBeforeReading() async throws {
        let environment = EnvironmentRecord(path: "/no/such/environment")
        for query in ["", "two\nlines", String(repeating: "x", count: 1025)] {
            do { _ = try await FileSearch().search(environment: environment, query: query); XCTFail("query accepted") }
            catch FileSearchError.invalidQuery {} catch { XCTFail("unexpected \(error)") }
        }
        do { _ = try await FileSearch().search(environment: environment, query: "needle", options: FileSearchOptions(maxMatches: 0)); XCTFail("bounds accepted") }
        catch FileSearchError.invalidOptions {} catch { XCTFail("unexpected \(error)") }
    }
}

private actor SearchMutatingReader: FileSearchReader {
    let service = FileService(), path: URL
    var changed = false
    init(path: URL) { self.path = path }
    func children(path: String) async throws -> [FileEntry] { try await service.children(path: path) }
    func readText(path: String, offset: UInt64, limit: Int, expectedVersion: String?) async throws -> TextPage {
        let page = try await service.readText(path: path, offset: offset, limit: limit, expectedVersion: expectedVersion)
        if !changed {
            changed = true
            let handle = try FileHandle(forWritingTo: self.path); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data("changed".utf8))
        }
        return page
    }
}

private actor SearchCancellationReader: FileSearchReader {
    let service = FileService()
    var count = 0
    func hasStarted() -> Bool { count > 0 }
    func readCount() -> Int { count }
    func children(path: String) async throws -> [FileEntry] { try await service.children(path: path) }
    func readText(path: String, offset: UInt64, limit: Int, expectedVersion: String?) async throws -> TextPage {
        count += 1
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return try await service.readText(path: path, offset: offset, limit: limit, expectedVersion: expectedVersion)
    }
}
