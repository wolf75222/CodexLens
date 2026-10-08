import XCTest
@testable import LensCore

final class ChangesFileTreeTests: XCTestCase {
    private let alpha = "/fixture/never-created/worktrees/alpha"
    private let beta = "/fixture/never-created/worktrees/beta"

    private struct FileFixture {
        let id: String
        let environment: String
        let path: String
    }

    private func index(_ files: [FileFixture]) -> ChangesOverviewIndex {
        let events = files.map {
            LensEvent(id: "event-" + $0.id, timestamp: Date(timeIntervalSince1970: 100), agentID: "root",
                kind: .toolCall, toolName: "apply_patch", environmentID: $0.environment,
                source: SourceRef(path: "/fixture/no-journal/root.jsonl"))
        }
        let changes = files.map {
            ChangeRecord(id: $0.id, path: $0.path, environmentID: $0.environment, agentID: "root",
                eventID: "event-" + $0.id, kind: .requestedPatch)
        }
        let snapshot = SessionSnapshot(root: SessionSummary(id: "file-tree-fixture"), events: events,
            environments: [EnvironmentRecord(path: alpha), EnvironmentRecord(path: beta)], changes: changes)
        return ChangesOverviewIndex(snapshot: snapshot,
            activity: ActivityEvidenceIndex(events: events, changes: changes, resources: []))
    }

    private func projection(_ files: [FileFixture]) -> ChangesOverviewProjection {
        index(files).projection(visibleChangeIDs: Set(files.map(\.id)))
    }

    private func fileID(environment: String, path: String) -> String {
        ChangesOverviewFileKey(environmentID: environment, path: path).id
    }

    func testGroupedDirectoriesAndFilesUseFolderFirstNaturalOrder() throws {
        let result = projection([
            FileFixture(id: "ten", environment: alpha, path: "File10.swift"),
            FileFixture(id: "two", environment: alpha, path: "File2.swift"),
            FileFixture(id: "folder-ten", environment: alpha, path: "folder10/Item.swift"),
            FileFixture(id: "folder-two", environment: alpha, path: "folder2/Item.swift"),
            FileFixture(id: "nested", environment: alpha, path: "folder2/nested/Leaf.swift"),
            FileFixture(id: "beta", environment: beta, path: "README.md")
        ])
        let tree = result.fileTree
        XCTAssertEqual(tree.roots.map(\.label), ["alpha", "beta"])
        XCTAssertEqual(tree.roots.map(\.kind), [.worktree, .worktree])
        XCTAssertEqual(tree.roots.map(\.fileCount), [5, 1])
        let root = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(root.children.map(\.label), ["folder2", "folder10", "File2.swift", "File10.swift"])
        XCTAssertEqual(root.children[0].children.map(\.label), ["nested", "Item.swift"])
        XCTAssertEqual(root.children[0].fileCount, 2)
        let leafID = fileID(environment: alpha, path: "folder2/nested/Leaf.swift")
        let ancestors = try XCTUnwrap(tree.ancestorsByFileID[leafID])
        XCTAssertEqual(ancestors.compactMap { tree.nodesByID[$0]?.label }, ["alpha", "folder2", "nested"])
        XCTAssertEqual(tree.nodesByID[leafID]?.fileID, leafID)
        XCTAssertEqual(tree.nodesByID[leafID]?.fileCount, 1)
        XCTAssertEqual(tree.nodesByID[leafID]?.children, [])
        XCTAssertTrue(tree.nodesByID.values.filter { $0.kind != .file }.allSatisfy { $0.fileID == nil })
    }

    func testSameNamesAndCaseDistinctPathsRetainExactWorktreeIdentities() throws {
        let alternateIdentity = alpha + "/."
        let result = projection([
            FileFixture(id: "alpha-upper", environment: alpha, path: "src/Same.swift"),
            FileFixture(id: "alpha-lower", environment: alpha, path: "src/same.swift"),
            FileFixture(id: "alpha-case-folder", environment: alpha, path: "Src/Same.swift"),
            FileFixture(id: "beta", environment: beta, path: "src/Same.swift"),
            FileFixture(id: "alternate", environment: alternateIdentity, path: "src/Same.swift")
        ])
        let tree = result.fileTree
        XCTAssertEqual(Set(tree.roots.map(\.environmentID)), [alpha, beta, alternateIdentity])
        let leaves = tree.nodesByID.values.filter { $0.kind == .file }
        XCTAssertEqual(leaves.count, 5)
        XCTAssertEqual(Set(leaves.map(\.id)).count, 5)
        let root = try XCTUnwrap(tree.roots.first { $0.environmentID == alpha })
        XCTAssertEqual(root.children.map(\.label), ["Src", "src"])
        XCTAssertEqual(root.children[1].children.map(\.label), ["Same.swift", "same.swift"])
        let folders = tree.nodesByID.values.filter { $0.kind == .directory && $0.label == "src" }
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(Set(folders.map(\.id)).count, 3)
    }

    func testLexicalAbsoluteAndRelativePathsShareTheProjectionLeafAndCompletePath() throws {
        let result = projection([
            FileFixture(id: "relative", environment: alpha, path: "src/./nested/../Same.swift"),
            FileFixture(id: "absolute", environment: alpha, path: alpha + "/src//Same.swift")
        ])
        let file = try XCTUnwrap(result.files.first)
        XCTAssertEqual(result.files.count, 1)
        let node = try XCTUnwrap(result.fileTree.nodesByID[file.id])
        XCTAssertEqual(node.id, file.id)
        XCTAssertEqual(node.fileID, file.id)
        XCTAssertEqual(node.path, file.path)
        XCTAssertEqual(node.path, alpha + "/src/Same.swift")
        XCTAssertEqual(node.label, "Same.swift")
        XCTAssertEqual(result.fileTree.roots[0].children.map(\.label), ["src"])
        XCTAssertEqual(result.fileTree.roots[0].fileCount, 1)
    }

    func testOutsideAndUnknownPathsHaveExplicitGroupingWithoutFalseWorktreeAncestry() throws {
        let result = projection([
            FileFixture(id: "inside", environment: alpha, path: "src/Inside.swift"),
            FileFixture(id: "absolute-outside", environment: alpha, path: "/external/Result.swift"),
            FileFixture(id: "similar-prefix", environment: alpha, path: alpha + "-other/Result.swift"),
            FileFixture(id: "relative-outside", environment: alpha, path: "../Result.swift"),
            FileFixture(id: "unknown-relative", environment: "", path: "src/Unknown.swift"),
            FileFixture(id: "unknown-parent", environment: "", path: "../Unknown.swift")
        ])
        let tree = result.fileTree
        let root = try XCTUnwrap(tree.roots.first { $0.environmentID == alpha })
        let outside = try XCTUnwrap(root.children.first { $0.kind == .outsidePaths })
        XCTAssertEqual(outside.fileCount, 3)
        XCTAssertTrue(outside.children.allSatisfy { $0.kind == .file && $0.label == $0.path })
        for leaf in outside.children {
            XCTAssertEqual(tree.ancestorsByFileID[leaf.id], [root.id, outside.id])
        }
        let unknown = try XCTUnwrap(tree.roots.first { $0.environmentID.isEmpty })
        XCTAssertEqual(unknown.children.map(\.kind), [.outsidePaths])
        XCTAssertEqual(unknown.children[0].children.map(\.path), ["../Unknown.swift", "src/Unknown.swift"])
        XCTAssertFalse(unknown.children[0].children.contains { $0.kind == .directory })
    }

    func testRootEnvironmentAndRelativeEnvironmentUseLexicalPrefixBoundaries() throws {
        let result = projection([
            FileFixture(id: "root", environment: "/", path: "/src/Root.swift"),
            FileFixture(id: "relative", environment: "worktree", path: "src/Relative.swift"),
            FileFixture(id: "relative-outside", environment: "worktree", path: "../Sibling.swift")
        ])
        let tree = result.fileTree
        let root = try XCTUnwrap(tree.roots.first { $0.environmentID == "/" })
        XCTAssertEqual(root.label, "/")
        XCTAssertEqual(root.children.map(\.label), ["src"])
        XCTAssertEqual(root.children[0].path, "/src")
        let relative = try XCTUnwrap(tree.roots.first { $0.environmentID == "worktree" })
        XCTAssertEqual(relative.children.filter { $0.kind == .directory }.map(\.path), ["worktree/src"])
        XCTAssertEqual(relative.children.first { $0.kind == .outsidePaths }?.children.first?.path, "Sibling.swift")
    }

    func testVisibleTraceMembershipIsAppliedBeforeTreeConstruction() throws {
        let files = [
            FileFixture(id: "visible", environment: alpha, path: "src/Visible.swift"),
            FileFixture(id: "same-file-hidden-trace", environment: alpha, path: "src/Visible.swift"),
            FileFixture(id: "hidden-file", environment: alpha, path: "hidden/Hidden.swift"),
            FileFixture(id: "hidden-worktree", environment: beta, path: "src/Beta.swift")
        ]
        let overview = index(files)
        let result = overview.projection(visibleChangeIDs: ["visible"])
        XCTAssertEqual(result.fileTree.roots.map(\.environmentID), [alpha])
        XCTAssertEqual(result.fileTree.roots[0].fileCount, 1)
        XCTAssertEqual(Set(result.fileTree.ancestorsByFileID.keys), Set(result.files.map(\.id)))
        XCTAssertFalse(result.fileTree.nodesByID.values.contains { $0.label == "hidden" })
        XCTAssertEqual(ChangesFileTree(groups: result.groups), result.fileTree)
        let full = overview.projection(visibleChangeIDs: Set(files.map(\.id)))
        XCTAssertEqual(result.files[0].id, full.files.first { $0.path == result.files[0].path }?.id)
    }

    func testTreeAndContainerIdentitiesAreStableAcrossReorderingAndAddedTraces() {
        let files = [
            FileFixture(id: "a", environment: alpha, path: "src/File10.swift"),
            FileFixture(id: "b", environment: alpha, path: "src/File2.swift"),
            FileFixture(id: "c", environment: beta, path: "src/File2.swift"),
            FileFixture(id: "d", environment: alpha, path: "/external/Result.swift")
        ]
        let first = projection(files).fileTree
        XCTAssertEqual(first, projection(Array(files.reversed())).fileTree)
        let streamed = projection(files + [FileFixture(id: "new-trace", environment: alpha,
            path: alpha + "/src/File2.swift")]).fileTree
        XCTAssertEqual(first, streamed, "An additional trace must not invent another leaf or change its navigation identity")
    }

    func testEmptyAndFullyFilteredProjectionsHaveEmptyTrees() {
        let empty = projection([]).fileTree
        XCTAssertTrue(empty.roots.isEmpty)
        XCTAssertTrue(empty.nodesByID.isEmpty)
        XCTAssertTrue(empty.ancestorsByFileID.isEmpty)
        let filtered = index([FileFixture(id: "hidden", environment: alpha, path: "src/File.swift")])
            .projection(visibleChangeIDs: []).fileTree
        XCTAssertEqual(empty, filtered)
    }

    func testNavigationFilterMatchesFilenamesPathsFoldersAndWorktrees() throws {
        let source = projection([
            FileFixture(id: "alpha-file", environment: alpha, path: "src/Shared.swift"),
            FileFixture(id: "alpha-doc", environment: alpha, path: "docs/Guide.md"),
            FileFixture(id: "beta-file", environment: beta, path: "src/Shared.swift")
        ]).fileTree
        let filenames = source.filtered(matching: "  SHARED.swift\n")
        XCTAssertEqual(filenames.roots.map(\.fileCount), [1, 1])
        XCTAssertEqual(Set(filenames.ancestorsByFileID.keys), [
            fileID(environment: alpha, path: "src/Shared.swift"),
            fileID(environment: beta, path: "src/Shared.swift")
        ])
        let path = source.filtered(matching: "alpha/src")
        XCTAssertEqual(path.roots.map(\.environmentID), [alpha])
        XCTAssertEqual(path.roots[0].fileCount, 1)
        XCTAssertEqual(source.filtered(matching: "docs").roots[0].children.map(\.label), ["docs"])
        let worktree = source.filtered(matching: "beta")
        XCTAssertEqual(worktree.roots.map(\.environmentID), [beta])
        XCTAssertEqual(worktree.roots[0].fileCount, 1)
        for (fileID, ancestors) in filenames.ancestorsByFileID {
            XCTAssertNotNil(filenames.nodesByID[fileID])
            XCTAssertTrue(ancestors.allSatisfy { filenames.nodesByID[$0] != nil })
            XCTAssertEqual(ancestors, source.ancestorsByFileID[fileID])
            XCTAssertEqual(filenames.nodesByID[fileID]?.path, source.nodesByID[fileID]?.path)
        }
    }

    func testClearingNavigationFilterRestoresSourceAndFilteringDoesNotMutateIt() {
        let source = projection([
            FileFixture(id: "one", environment: alpha, path: "src/One.swift"),
            FileFixture(id: "two", environment: alpha, path: "docs/Two.md")
        ]).fileTree
        let original = source
        let filtered = source.filtered(matching: "One.swift")
        XCTAssertEqual(filtered.roots[0].fileCount, 1)
        XCTAssertEqual(source, original)
        XCTAssertEqual(source.roots[0].fileCount, 2)
        XCTAssertEqual(source.filtered(matching: ""), source)
        XCTAssertEqual(source.filtered(matching: " \n\t "), source)
        let absent = source.filtered(matching: "unrecorded-filename")
        XCTAssertTrue(absent.roots.isEmpty)
        XCTAssertTrue(absent.nodesByID.isEmpty)
        XCTAssertTrue(absent.ancestorsByFileID.isEmpty)
    }

    func testVeryDeepPathsCompactDirectoriesWhilePreservingLeafIdentityAndFullPath() throws {
        let directory = (0..<4_096).map { "d\($0)" }.joined(separator: "/")
        let result = projection([
            FileFixture(id: "deep-one", environment: alpha, path: directory + "/One.swift"),
            FileFixture(id: "deep-two", environment: alpha, path: directory + "/Two.swift")
        ])
        let tree = result.fileTree
        XCTAssertEqual(tree.nodesByID.count, 67, "One worktree, 64 bounded folders and two leaves")
        XCTAssertEqual(tree.roots[0].fileCount, 2)
        for file in result.files {
            let leaf = try XCTUnwrap(tree.nodesByID[file.id])
            XCTAssertEqual(leaf.fileID, file.id)
            XCTAssertEqual(leaf.path, file.path)
            let ancestors = try XCTUnwrap(tree.ancestorsByFileID[file.id])
            XCTAssertEqual(ancestors.count, 65)
            let compact = try XCTUnwrap(ancestors.last.flatMap { tree.nodesByID[$0] })
            XCTAssertTrue(compact.label.hasPrefix("d63/d64/"))
            XCTAssertTrue(compact.label.hasSuffix("/d4095"))
            XCTAssertEqual(compact.path, alpha + "/" + directory)
            XCTAssertEqual(compact.children.map(\.label), ["One.swift", "Two.swift"])
        }
    }
}
