import Foundation
import XCTest
@testable import LensCore

final class RecordedDiffTests: XCTestCase {
    private let provenance = DiffProvenance(environmentID: "/repo/worktree-A", eventIDs: ["call-1"], sources: [SourceRef(path: "/logs/session.jsonl", offset: 400, length: 500, line: 4, sha256: "recorded-hash")], agentID: "agent-A")
    private let patch = "*** Begin Patch\n*** Update File: src/main.swift\n@@ function main\n context\n-old\n+new\n tail\n*** End Patch"

    func testCodexPatchHasFragmentCoordinatesWithoutInventedFileLines() throws {
        let document = try RecordedDiff.parse(patch, provenance: provenance, kind: .currentGit)
        XCTAssertEqual(document.kind, .requestedPatch)
        XCTAssertEqual(document.coverage, .fragmentOnly)
        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.path, "src/main.swift")
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertNil(hunk.beforeStart)
        XCTAssertNil(hunk.afterStart)
        XCTAssertEqual(hunk.beforeCount, 3)
        XCTAssertEqual(hunk.afterCount, 3)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertTrue(hunk.lines.allSatisfy { $0.beforeLine == nil && $0.afterLine == nil })
        XCTAssertEqual(hunk.lines[1].beforeOffset, 2)
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 1), file: file).status, .unavailable)
        let local = RecordedDiff.mapFragment(range: DiffLineRange(start: 1), hunk: hunk, provenance: provenance)
        XCTAssertEqual(local.status, .mapped)
        XCTAssertEqual(local.destinations, [DiffLineRange(start: 1)])
        XCTAssertTrue(local.conditionalOnApplication)
        XCTAssertEqual(RecordedDiff.mapFragment(range: DiffLineRange(start: 2), hunk: hunk, provenance: provenance).status, .ambiguous)
    }

    func testFailedExecutionIsSeparateFromRequestedPatchAndProvenance() throws {
        var document = try RecordedDiff.parse(patch, provenance: provenance)
        document.result = RecordedDiffResult(status: .failed, message: "Patch context not found", eventIDs: ["result-1"], sources: [SourceRef(path: "/logs/session.jsonl", offset: 900)])
        XCTAssertEqual(document.kind, .requestedPatch)
        XCTAssertEqual(document.result?.status, .failed)
        XCTAssertEqual(document.coverage, .fragmentOnly)
        XCTAssertEqual(document.provenance.sources.first?.sha256, "recorded-hash")
        XCTAssertNil(document.provenance.authorEvidence)
        XCTAssertEqual(document.provenance.agentID, "agent-A")
        let restored = try JSONDecoder().decode(RecordedDiffDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored, document)
    }

    func testAddDeleteMoveAndMissingEndKeepRecordedLimits() throws {
        let text = "*** Begin Patch\n*** Add File: added.swift\n+first\n+second\n*** Delete File: removed.swift\n*** Update File: old.swift\n*** Move to: moved.swift\n@@\n-old\n+new"
        let document = try RecordedDiff.parse(text, provenance: provenance)
        XCTAssertEqual(document.files.count, 3)
        XCTAssertEqual(document.files[0].operation, .added)
        XCTAssertNil(document.files[0].oldPath)
        XCTAssertEqual(document.files[0].hunks.first?.lines.map(\.afterLine), [1, 2])
        XCTAssertEqual(document.files[1].operation, .deleted)
        XCTAssertTrue(document.files[1].hunks.isEmpty)
        XCTAssertNil(document.files[1].newPath)
        XCTAssertEqual(document.files[2].operation, .renamed)
        XCTAssertEqual(document.files[2].newPath, "moved.swift")
        XCTAssertTrue(document.issues.contains { $0.category == "incomplete" })
        let unknownMarker = try RecordedDiff.parse("*** Begin Patch\n*** Update File: file\n*** Unknown marker\n@@\n old\n*** End Patch", provenance: provenance)
        XCTAssertTrue(unknownMarker.files[0].issues.contains { $0.category == "unsupported" })
    }

    func testUnifiedLineNumbersAndReplacementAmbiguity() throws {
        let text = "--- a/src/main.swift\n+++ b/src/main.swift\n@@ -10,3 +10,4 @@ function main\n context\n-old\n+new\n+inserted\n tail\n\\ No newline at end of file\n"
        let document = try RecordedDiff.parse(text, provenance: provenance)
        let file = try XCTUnwrap(document.files.first)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertTrue(hunk.isComplete)
        XCTAssertEqual(hunk.lines[0].beforeLine, 10)
        XCTAssertEqual(hunk.lines[4].beforeLine, 12)
        XCTAssertEqual(hunk.lines[4].afterLine, 13)
        XCTAssertEqual(hunk.lines.last?.kind, .metadata)
        let kept = RecordedDiff.map(range: DiffLineRange(start: 12), file: file)
        XCTAssertEqual(kept.status, .mapped)
        XCTAssertEqual(kept.destinations, [DiffLineRange(start: 13)])
        XCTAssertFalse(kept.conditionalOnApplication)
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 11), file: file).status, .ambiguous)
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 1), file: file).status, .unavailable)
    }

    func testDeletionReverseMappingAndPartialRange() throws {
        let document = try RecordedDiff.parse("--- a/file\n+++ b/file\n@@ -10,3 +10,2 @@\n context\n-removed\n tail", provenance: provenance)
        let file = document.files[0]
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 11), file: file).status, .deleted)
        let reversed = RecordedDiff.map(range: DiffLineRange(start: 11), file: file, direction: .afterToBefore)
        XCTAssertEqual(reversed.status, .mapped)
        XCTAssertEqual(reversed.destinations, [DiffLineRange(start: 12)])
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 9, count: 2), file: file).status, .partial)
    }

    func testIncompleteAndContradictoryHunksHaveExplicitMappingFailures() throws {
        let incomplete = try RecordedDiff.parse("--- a/file\n+++ b/file\n@@ -10,3 +10,3 @@\n only", provenance: provenance)
        XCTAssertFalse(incomplete.files[0].hunks[0].isComplete)
        XCTAssertTrue(incomplete.files[0].issues.contains { $0.category == "incomplete" })
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 10), file: incomplete.files[0]).status, .unavailable)
        let overlap = try RecordedDiff.parse("--- a/file\n+++ b/file\n@@ -1 +1 @@\n same\n@@ -1 +2 @@\n same", provenance: provenance)
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 1), file: overlap.files[0]).status, .ambiguous)
    }

    func testIdenticalRelativePathsStayScopedToWorktreesAndCurrentGitHasNoAuthorProof() throws {
        let other = DiffProvenance(environmentID: "/repo/worktree-B", eventIDs: ["call-1"], agentID: "agent-A")
        let a = try RecordedDiff.parse(patch, provenance: provenance)
        let b = try RecordedDiff.parse(patch, provenance: other)
        XCTAssertNotEqual(a.files[0].id, b.files[0].id)
        let current = try RecordedDiff.parse("--- a/manual.txt\n+++ b/manual.txt\n@@ -1 +1 @@\n-old\n+manual", provenance: provenance, kind: .currentGit)
        XCTAssertEqual(current.kind, .currentGit)
        XCTAssertNil(current.provenance.authorEvidence)
        XCTAssertEqual(current.files[0].coverage, .fragmentOnly)
    }

    func testAvailableTextComparisonIsDeterministicAndLineMappingsAreBounded() throws {
        let before = "keep\nold\ntail\n", after = "keep\nnew\nextra\ntail\n"
        let a = try RecordedDiff.compare(before: before, after: after, path: "file", provenance: provenance)
        let b = try RecordedDiff.compare(before: before, after: after, path: "file", provenance: provenance)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.coverage, .completeTextsAvailable)
        XCTAssertEqual(a.kind, .observedTextComparison)
        XCTAssertEqual(a.files[0].hunks[0].lines.filter { $0.kind == .removed }.map(\.text), ["old"])
        XCTAssertEqual(a.files[0].hunks[0].lines.filter { $0.kind == .added }.map(\.text), ["new", "extra"])
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 3), file: a.files[0]).destinations, [DiffLineRange(start: 4)])
        let repeated = try RecordedDiff.compare(before: "same\nsame\n", after: "same\n", path: "file", provenance: provenance)
        XCTAssertTrue(repeated.issues.contains { $0.category == "ambiguous" })
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 1), file: repeated.files[0]).status, .ambiguous)
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 2), file: repeated.files[0]).status, .ambiguous)
        let eof = try RecordedDiff.compare(before: "same", after: "same\n", path: "file", provenance: provenance)
        XCTAssertTrue(eof.issues.contains { $0.category == "newline" })
        XCTAssertEqual(eof.files[0].hunks[0].lines.last?.kind, .metadata)
        let crlf = try RecordedDiff.compare(before: "line\r\n", after: "line\n", path: "file", provenance: provenance)
        XCTAssertEqual(crlf.files[0].hunks[0].lines.filter { $0.kind == .removed }.first?.text, "line\r")
    }

    func testPatchExtractionHandlesJSONAndDoubleQuotedToolLiteralsWithoutEvaluation() throws {
        XCTAssertEqual(try RecordedDiff.extractRecordedPatch(from: patch), patch)
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: patch, options: [.fragmentsAllowed]), as: UTF8.self)
        XCTAssertEqual(try RecordedDiff.extractRecordedPatch(from: literal), patch)
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["input": patch]), as: UTF8.self)
        XCTAssertEqual(try RecordedDiff.extractRecordedPatch(from: input), patch)
        let javascript = "const result = await tools.apply_patch(\(literal)); text(result);"
        XCTAssertEqual(try RecordedDiff.extractRecordedPatch(from: javascript), patch)
        XCTAssertNil(try RecordedDiff.extractRecordedPatch(from: "tools.apply_patch(prefix + \(literal));"))
        XCTAssertNil(try RecordedDiff.extractRecordedPatch(from: "my_apply_patch(\(literal));"))
        XCTAssertNil(try RecordedDiff.extractRecordedPatch(from: "tools.apply_patch(`\(patch)`);"))
        XCTAssertNil(try RecordedDiff.extractRecordedPatch(from: "Success. Updated file."))
        let second = patch.replacingOccurrences(of: "src/main.swift", with: "other.swift")
        let otherLiteral = String(decoding: try JSONSerialization.data(withJSONObject: second, options: [.fragmentsAllowed]), as: UTF8.self)
        do { _ = try RecordedDiff.extractRecordedPatch(from: "tools.apply_patch(\(literal)); tools.apply_patch(\(otherLiteral));"); XCTFail("Do not silently choose one patch") }
        catch RecordedDiffError.ambiguousExtraction { }
    }

    func testNativeFileChangeDiffExtractionUsesKnownPathsAndSourceShapes() throws {
        let body = "@@ -1 +1 @@\n-old\n+new\n"
        let dictionary: [String: Any] = ["payload": ["type": "item_completed", "item": ["type": "FileChange", "changes": ["b/src.swift": ["type": "update", "unified_diff": body]]]]]
        let array: [String: Any] = ["payload": ["item": ["type": "McpFileChange", "changes": [["path": "second.swift", "diff": body]]]]]
        let raw = [dictionary, array].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n\n")
        let extracted = try RecordedDiff.extractRecordedDiffs(from: raw)
        XCTAssertEqual(extracted.count, 2)
        XCTAssertEqual(try RecordedDiff.parse(extracted[0], provenance: provenance).files[0].path, "b/src.swift")
        XCTAssertEqual(try RecordedDiff.parse(extracted[1], provenance: provenance).files[0].path, "second.swift")
        let absent: [String: Any] = ["payload": ["item": ["changes": [["path": "not-captured.swift", "kind": "update"]]]]]
        XCTAssertTrue(try RecordedDiff.extractRecordedDiffs(from: String(decoding: JSONSerialization.data(withJSONObject: absent), as: UTF8.self)).isEmpty)
    }

    func testExplicitInputCellAndMappingLimitsDoNotTruncateSilently() throws {
        do { _ = try RecordedDiff.parse(String(repeating: "+", count: RecordedDiff.maximumInputBytes + 1), provenance: provenance); XCTFail("Input bound") }
        catch RecordedDiffError.limit { }
        let before = (0..<1600).map { "old-\($0)" }.joined(separator: "\n")
        let after = (0..<1600).map { "new-\($0)" }.joined(separator: "\n")
        do { _ = try RecordedDiff.compare(before: before, after: after, path: "file", provenance: provenance); XCTFail("Cell bound") }
        catch RecordedDiffError.limit { }
        let file = try RecordedDiff.parse(patch, provenance: provenance).files[0]
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: Int.max, count: 2), file: file).status, .unavailable)
        XCTAssertEqual(RecordedDiff.map(range: DiffLineRange(start: 1, count: RecordedDiff.maximumLines + 1), file: file).status, .unavailable)
    }

    func testBinaryDiffIsRecordedWithoutPretendingTextOrCompleteBytes() throws {
        let document = try RecordedDiff.parse("diff --git a/image.png b/image.png\nBinary files a/image.png and b/image.png differ", provenance: provenance)
        XCTAssertEqual(document.files[0].operation, .binary)
        XCTAssertTrue(document.files[0].hunks.isEmpty)
        XCTAssertEqual(document.coverage, .fragmentOnly)
        XCTAssertTrue(document.files[0].issues.contains { $0.category == "unsupported" })
    }

    func testUnicodeBytesUnknownQuotedPathsAndSourceIdentityRemainExact() throws {
        let unicode = try RecordedDiff.compare(before: "é\n", after: "e\u{301}\n", path: "file", provenance: provenance)
        XCTAssertEqual(unicode.files[0].hunks[0].lines.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(unicode.files[0].hunks[0].lines.filter { $0.kind == .added }.count, 1)
        let unknown = try RecordedDiff.parse("--- \"a/\\303\\251.swift\"\n+++ \"b/\\303\\251.swift\"\n@@ -1 +1 @@\n-old\n+new", provenance: provenance)
        XCTAssertEqual(unknown.files[0].operation, .unknown)
        XCTAssertNil(unknown.files[0].oldPath)
        XCTAssertTrue(unknown.files[0].issues.contains { $0.category == "unsupported" })
        let differentEvent = DiffProvenance(environmentID: provenance.environmentID, eventIDs: ["call-2"], sources: provenance.sources, agentID: "agent-A")
        XCTAssertNotEqual(try RecordedDiff.parse(patch, provenance: provenance).files[0].id, try RecordedDiff.parse(patch, provenance: differentEvent).files[0].id)
        let trailing = try RecordedDiff.parse(patch + "\n" + patch, provenance: provenance)
        XCTAssertTrue(trailing.issues.contains { $0.category == "unsupported" })
    }
}
