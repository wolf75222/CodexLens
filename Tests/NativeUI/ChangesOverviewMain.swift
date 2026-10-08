import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import LensCore
import QuartzCore
import SwiftUI

/// Production views and navigation on disposable anonymous journals/worktrees.
/// Images use offscreen NSHostingView bitmap caches, not compositor screenshots.
@main struct ChangesOverviewMain {
    @MainActor private static var stage = "anonymous-fixture"
    @MainActor private static var diagnosticOutput: URL?
    @MainActor private static weak var diagnosticStore: LensStore?
    @MainActor private static var selectionDiagnostics: [[String: String]] = []

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify(); NSApp.terminate(nil) }
            catch { fputs("Changes overview qualification: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output")
        diagnosticOutput = output
        let fixture = try ChangesOverviewFixture(output: output)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        UserDefaults.standard.setVolatileDomain(["lensLanguage": "en", "lensReduceMotionOverride": true,
            "lensControlAccent": "lens", "lensTabMaterial": "system"], forName: UserDefaults.argumentDomain)
        LensL10n.language = .en
        LensGuideCoordinator.shared.onboarding.dismiss()
        var checks: [[String: Any]] = [], observations: [[String: Any]] = [], renders: [String] = []
        var completed = false
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func receipt(_ complete: Bool) {
            let value: [String: Any] = [
                "checks": checks, "observations": observations, "renders": renders, "completed": complete,
                "deferredSelectionDiagnostics": selectionDiagnostics,
                "allExecutedChecksPassed": complete && checks.allSatisfy { $0["passed"] as? Bool == true },
                "failedStage": complete ? "none" : stage,
                "fixture": ["anonymous": true, "rootID": fixture.rootID,
                    "ownGitSetup": true, "observedSourcesModified": !fixture.sourcesUnchanged()],
                "captureMethod": "Offscreen AppKit NSHostingView cacheDisplay bitmap PNGs; no production compositor capture.",
                "scope": "Production ChangesView/MainView and LensStore, exact recorded-source diff parsing, own disposable Git worktrees, native AX exposure/actions and per-window navigation state.",
                "unqualified": [
                    "Programmatic store and AppKit checks do not qualify physical clicks, trackpad gestures, VoiceOver or the production compositor.",
                    "The dense scenario publishes anonymous metadata in memory; it is not a live collector-ingestion test.",
                    "The selection interleaving publishes cloned same-root metadata in memory; it does not qualify collector I/O.",
                    "A bounded number of graph marks is not a CPU, memory or latency improvement measurement.",
                    "Recorded trace timestamps, worktree labels and explicit agent-parent links establish no Git ancestry, creation date, authorship or net historical patch."
                ]
            ]
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
            }
        }
        defer {
            if !completed { checks.append(["name": "native-flow-completes-after-" + stage, "passed": false]); receipt(false) }
        }
        check("source-matched-overview-entrypoint", manifest?["entrypoint"] as? String == "ChangesOverviewMain.swift"
            && manifest?["productionEntryPointReplaced"] as? Bool == true
            && manifest?["copiedAppSourcesModified"] as? Bool == false)

        let pool = SessionReaderPool()
        let store = makeStore(fixture: fixture, output: output, name: "main", pool: pool)
        diagnosticStore = store
        await store.start(); await store.open(fixture.rootID); await store.waitForPresentation()
        defer { store.stopObserving() }
        store.showSessionPicker = false; store.inspectorVisible = false; store.chatVisible = false; store.follow = false
        store.browseSection(.changes); store.changesPresentation = .overview
        guard let initial = store.snapshot, let projection = store.presentation?.changesOverview,
              let alphaFile = projection.files.first(where: { $0.environmentID == fixture.alpha.path && $0.path.hasSuffix("/src/Same.swift") }),
              let betaFile = projection.files.first(where: { $0.environmentID == fixture.beta.path && $0.path.hasSuffix("/src/Same.swift") }),
              let alphaRequest = initial.changes.first(where: { $0.kind == .requestedPatch && store.event($0.eventID)?.callID == "alpha-patch" }),
              let alphaResult = initial.changes.first(where: { $0.kind == .recordedResult && store.event($0.eventID)?.callID == "alpha-patch" }),
              let noDiffResult = initial.changes.first(where: { $0.kind == .recordedResult && store.event($0.eventID)?.callID == "no-diff-patch" }) else {
            throw LensError.unavailable("Anonymous source fixture did not yield its recorded changes.")
        }
        check("overview-keeps-two-worktrees-and-four-files", projection.groups.count == 2 && projection.files.count == 4)
        check("request-result-are-one-operation", projection.activityCount == 4 && alphaFile.activityCount == 1 && alphaFile.traceIDs.count == 2)
        check("same-path-in-two-worktrees-keeps-two-file-identities", alphaFile.relativePath == betaFile.relativePath
            && alphaFile.id != betaFile.id && alphaFile.environmentID != betaFile.environmentID)
        check("known-and-unknown-recorded-branches-stay-distinct",
            projection.groups.first(where: { $0.id == fixture.alpha.path })?.environment.recordedBranch == "fixture/alpha"
            && projection.groups.first(where: { $0.id == fixture.beta.path })?.environment.recordedBranch == nil)
        check("undated-trace-is-retained-without-invented-date", projection.unknownTimestampCount == 1
            && projection.groups.flatMap(\.activities).filter { $0.firstTimestamp == nil }.count == 1)
        check("explicit-agent-parent-retained-without-worktree-lineage",
            initial.agents.first(where: { $0.id == fixture.childID })?.parentID == fixture.rootID)
        observations.append(["scenario": "initial-recorded-projection",
            "groups": projection.groups.map { group in
                ["environmentID": group.id, "branch": group.environment.recordedBranch ?? "<unknown>",
                 "fileCount": group.files.count, "activityCount": group.activityCount,
                 "files": group.files.map { ["id": $0.id, "path": $0.path, "relativePath": $0.relativePath,
                     "environmentID": $0.environmentID, "traceIDs": $0.traceIDs] as [String: Any] }] as [String: Any]
            }])

        stage = "recorded-source-diffs"
        let requested = try await documents(change: alphaRequest, store: store)
        let recorded = try await documents(change: alphaResult, store: store)
        check("requested-diff-keeps-proposed-bytes", diffText(requested).contains("proposedAlpha")
            && !diffText(requested).contains("recordedAlpha") && !diffText(requested).contains("currentAlpha"))
        check("result-diff-keeps-distinct-recorded-bytes", diffText(recorded).contains("recordedAlpha")
            && !diffText(recorded).contains("proposedAlpha") && !diffText(recorded).contains("currentAlpha"))
        check("success-result-without-diff-does-not-substitute-request", try await documents(change: noDiffResult, store: store).isEmpty)

        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: component(store: store, context: context, scheme: .light))
        let window = makeWindow(host: host, context: context, width: 1280, height: 920, x: -7000)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        renders.append(try capture(host, output.appendingPathComponent("changes-overview-mounted-component-cache.png")))
        try await waitFor(host, "overview-native-controls") { fileTree(in: host) != nil }
        check("overview-exposes-file-tree-environments-and-modes", Set(["lens-changes-files", "lens-changes-file-tree",
            "lens-changes-environments", "lens-changes-presentation", "lens-changes-tree-toggle",
            "lens-changes-tree-reveal"]).isSubset(of: identifiers(host)))
        let initialTree = try require(fileTree(in: host), "native changed-file tree")
        let alphaNode = try require(projection.fileTree.nodesByID.values.first { $0.fileID == alphaFile.id }, "alpha tree leaf")
        let betaNode = try require(projection.fileTree.nodesByID.values.first { $0.fileID == betaFile.id }, "beta tree leaf")
        let alphaTreeItem = try treeItem(alphaNode.id, tree: projection.fileTree, outline: initialTree)
        let betaTreeItem = try treeItem(betaNode.id, tree: projection.fileTree, outline: initialTree)
        check("native-tree-keeps-same-path-leaves-under-distinct-worktree-objects",
            alphaTreeItem !== betaTreeItem && alphaNode.environmentID == fixture.alpha.path
            && betaNode.environmentID == fixture.beta.path
            && projection.fileTree.ancestorsByFileID[alphaFile.id]?.first
                != projection.fileTree.ancestorsByFileID[betaFile.id]?.first)
        check("wide-layout-places-resizable-file-tree-right-of-reading-pane", treeLayout(in: host).right)
        renders.append(try capture(host, output.appendingPathComponent("changes-overview-all-files-light-component-cache.png")))

        stage = "same-context-publication-during-native-selection"
        do {
            let previousID = try require(store.presentation?.id, "presentation before interleaving")
            let previousSelection = store.selection
            let betaRequest = try require(initial.changes.first {
                $0.environmentID == betaFile.environmentID && $0.kind == .requestedPatch && betaFile.traceIDs.contains($0.id)
            }, "beta requested trace")
            let fileTable = try require(fileTree(in: host), "native tree before deferred selection")
            try expandAncestors(of: betaFile.id, tree: projection.fileTree, outline: fileTable)
            let betaItem = try treeItem(betaNode.id, tree: projection.fileTree, outline: fileTable)
            guard fileTable.row(forItem: betaItem) >= 0 else {
                throw LensError.unavailable("Beta leaf was not revealed by native folder disclosure.")
            }
            var callbackRan = false, interleavedNewGeneration = false, bindingChangedBeforeNavigation = false
            // @Published emits in willSet. Selecting the actual native file row
            // here queues navigation against the old presentation; the new one
            // is assigned synchronously before that MainActor task can resume.
            let publication = store.$presentation.dropFirst().sink { next in
                guard !callbackRan, let next, next.rootID == initial.root.id, next.id != previousID else { return }
                callbackRan = true
                interleavedNewGeneration = store.presentation?.id == previousID
                fileTable.selectRowIndexes(IndexSet(integer: fileTable.row(forItem: betaItem)), byExtendingSelection: false)
                bindingChangedBeforeNavigation = store.changesOverviewFileID == betaFile.id
                    && store.selection == previousSelection
            }
            defer { publication.cancel() }
            var refreshed = initial
            refreshed.collectedAt = initial.collectedAt.addingTimeInterval(1)
            store.snapshot = refreshed
            await store.waitForPresentation()
            check("native-file-selection-interleaves-same-context-publication", callbackRan
                && interleavedNewGeneration && bindingChangedBeforeNavigation
                && store.presentation?.id != previousID)
            try await waitFor(host, "same-context-publication-preserves-file-navigation") {
                store.selection == .change(betaRequest.id) && store.changesOverviewFileID == betaFile.id
                    && identifiers(host).contains("lens-change-open-action")
            }
            check("same-context-publication-keeps-native-file-and-trace-aligned",
                store.selection == .change(betaRequest.id) && store.changesOverviewFileID == betaFile.id
                && store.changesOverviewDetailMode == .recorded && identifiers(host).contains("lens-change-open-action"))
            check("interleaving-keeps-root-source-and-filter-context",
                store.snapshot?.root.id == initial.root.id && store.observedSourceHome == fixture.home
                && store.query.isEmpty && store.agentFilter == nil && store.environmentFilter == nil
                && store.changesKindFilter == nil && store.changesOverviewEnvironmentID == nil)
            observations.append(["scenario": "same-context-publication-during-native-selection",
                "trigger": "NSOutlineView.selectRowIndexes for the identified file object inside presentation willSet publisher",
                "oldPresentationID": previousID.uuidString,
                "newPresentationID": store.presentation?.id.uuidString ?? "<missing>",
                "selectedFileID": betaFile.id, "selectedTraceID": betaRequest.id,
                "collectorIOQualified": false])
        }

        stage = "file-trace-native-diff"
        store.changesOverviewFileID = alphaFile.id
        store.navigate(.change(alphaRequest.id))
        try await waitFor(host, stage) { identifiers(host).contains("lens-diff-line-columns") }
        check("selected-file-exposes-operation-trace-and-recorded-diff", Set(["lens-change-operation-picker",
            "lens-change-trace-picker", "lens-diff-line-columns", "lens-change-open-action"]).isSubset(of: identifiers(host)))
        check("programmatic-file-trace-route-retains-linked-selection", store.selection == .change(alphaRequest.id)
            && store.changesOverviewFileID == alphaFile.id && store.changesOverviewDetailMode == .recorded)
        renders.append(try capture(host, output.appendingPathComponent("changes-recorded-request-light-component-cache.png")))
        store.navigate(.change(alphaResult.id))
        try await waitFor(host, "recorded-result-native-diff") { identifiers(host).contains("lens-diff-line-columns") }
        check("recorded-result-route-remains-separate", store.selection == .change(alphaResult.id)
            && store.changesOverviewFileID == alphaFile.id)
        renders.append(try capture(host, output.appendingPathComponent("changes-recorded-result-light-component-cache.png")))

        stage = "native-tree-navigation-and-retained-reading"
        let nativeTree = try require(fileTree(in: host), "native tree with recorded alpha diff")
        let alphaFolderID = try require(projection.fileTree.ancestorsByFileID[alphaFile.id]?.last, "alpha parent folder identity")
        let betaRootID = try require(projection.fileTree.ancestorsByFileID[betaFile.id]?.first, "beta worktree root identity")
        let alphaFolder = try treeItem(alphaFolderID, tree: projection.fileTree, outline: nativeTree)
        let alphaLeaf = try treeItem(alphaNode.id, tree: projection.fileTree, outline: nativeTree)
        try await waitFor(host, "programmatic-trace-reveals-identified-native-tree-leaf") {
            (nativeTree.item(atRow: nativeTree.selectedRow) as? NSObject) === alphaLeaf
        }
        select(alphaFolder, in: nativeTree)
        check("native-folder-selection-keeps-current-recorded-file-and-diff", store.changesOverviewFileID == alphaFile.id
            && store.selection == .change(alphaResult.id) && identifiers(host).contains("lens-diff-line-columns"))
        try arrow(.left, in: nativeTree); try await settle(host)
        check("native-left-arrow-collapses-folder-without-clearing-diff", !nativeTree.isItemExpanded(alphaFolder)
            && nativeTree.row(forItem: alphaLeaf) < 0 && !store.changesFileTreeState.expandedIDs.contains(alphaFolderID)
            && store.changesOverviewFileID == alphaFile.id && store.selection == .change(alphaResult.id)
            && identifiers(host).contains("lens-diff-line-columns"))
        let betaRoot = try treeItem(betaRootID, tree: projection.fileTree, outline: nativeTree)
        select(betaRoot, in: nativeTree)
        if nativeTree.isItemExpanded(betaRoot) { try arrow(.left, in: nativeTree) }
        select(alphaFolder, in: nativeTree); try await settle(host)
        let collapsedState = store.changesFileTreeState.expandedIDs
        check("native-tree-toggle-hides-navigation-without-closing-diff", press("lens-changes-tree-toggle", in: host))
        try await waitFor(host, "native-tree-hidden") { fileTree(in: host) == nil }
        check("hidden-tree-preserves-selected-file-and-recorded-reading", !store.changesFileTreeVisible
            && store.changesOverviewFileID == alphaFile.id && store.selection == .change(alphaResult.id)
            && identifiers(host).contains("lens-diff-line-columns"))
        check("native-tree-toggle-restores-navigation", press("lens-changes-tree-toggle", in: host))
        try await waitFor(host, "native-tree-restored") { fileTree(in: host) != nil }
        let restoredTree = try require(fileTree(in: host), "restored native file tree")
        let restoredFolder = try treeItem(alphaFolderID, tree: projection.fileTree, outline: restoredTree)
        check("hide-show-restores-collapsed-folder-and-native-folder-selection",
            store.changesFileTreeState.expandedIDs == collapsedState && !restoredTree.isItemExpanded(restoredFolder)
            && (restoredTree.item(atRow: restoredTree.selectedRow) as? NSObject) === restoredFolder)

        stage = "local-tree-filter-retains-diff"
        let filterQuery = "NoDiff.swift"
        let filteredTree = projection.fileTree.filtered(matching: filterQuery)
        store.changesFileTreeQuery = filterQuery
        try await waitFor(host, stage) {
            fileTree(in: host).map { nativeItemCount(in: $0) == filteredTree.nodesByID.count } == true
        }
        check("local-file-filter-removes-current-leaf-without-changing-session-query-or-diff",
            !filteredTree.nodesByID.values.contains { $0.fileID == alphaFile.id }
            && store.query.isEmpty && store.changesOverviewFileID == alphaFile.id
            && store.selection == .change(alphaResult.id) && identifiers(host).contains("lens-diff-line-columns"))
        store.changesFileTreeQuery = ""
        try await waitFor(host, "local-tree-filter-removed") {
            fileTree(in: host).map { nativeItemCount(in: $0) == projection.fileTree.nodesByID.count } == true
        }
        let refreshedTree = try require(fileTree(in: host), "tree after removing local filter")
        let refreshedFolder = try treeItem(alphaFolderID, tree: projection.fileTree, outline: refreshedTree)
        let retainedAlphaObject = try treeItem(alphaNode.id, tree: projection.fileTree, outline: refreshedTree)
        check("removing-local-filter-restores-files-and-collapsed-navigation", !refreshedTree.isItemExpanded(refreshedFolder)
            && store.changesFileTreeState.expandedIDs == collapsedState && store.selection == .change(alphaResult.id))

        stage = "tree-state-through-live-model-publication"
        var liveTreeSnapshot = initial
        let liveID = "anonymous-tree-added-operation"
        liveTreeSnapshot.collectedAt = initial.collectedAt.addingTimeInterval(2)
        liveTreeSnapshot.events.append(LensEvent(id: liveID, timestamp: ChangesOverviewFixture.epoch.addingTimeInterval(15),
            agentID: fixture.childID, kind: .toolCall, title: "Anonymous tree publication", toolName: "apply_patch",
            callID: liveID, environmentID: fixture.beta.path, source: SourceRef(path: "/fixture/in-memory-metadata-no-journal")))
        liveTreeSnapshot.changes.append(ChangeRecord(id: liveID + "-trace", path: fixture.beta.path + "/src/Added.swift",
            environmentID: fixture.beta.path, agentID: fixture.childID, eventID: liveID, kind: .requestedPatch))
        store.snapshot = liveTreeSnapshot; await store.waitForPresentation()
        let liveTree = try require(store.presentation?.changesOverview.fileTree, "refreshed tree projection")
        try await waitFor(host, stage) { nativeItemCount(in: refreshedTree) == liveTree.nodesByID.count }
        let publishedFolder = try treeItem(alphaFolderID, tree: liveTree, outline: refreshedTree)
        let publishedAlpha = try treeItem(alphaNode.id, tree: liveTree, outline: refreshedTree)
        let publishedBetaRoot = try treeItem(betaRootID, tree: liveTree, outline: refreshedTree)
        check("live-tree-refresh-preserves-item-identity-collapsed-folders-and-selected-diff",
            publishedAlpha === retainedAlphaObject && publishedFolder === refreshedFolder
            && !refreshedTree.isItemExpanded(publishedFolder) && !refreshedTree.isItemExpanded(publishedBetaRoot)
            && (refreshedTree.item(atRow: refreshedTree.selectedRow) as? NSObject) === publishedFolder
            && store.changesFileTreeState.expandedIDs == collapsedState
            && store.changesOverviewFileID == alphaFile.id && store.selection == .change(alphaResult.id)
            && identifiers(host).contains("lens-diff-line-columns"))
        check("native-reveal-action-is-available-after-live-refresh", press("lens-changes-tree-reveal", in: host))
        try await waitFor(host, "native-reveal-expands-and-selects-current-file") {
            refreshedTree.isItemExpanded(publishedFolder)
                && (refreshedTree.item(atRow: refreshedTree.selectedRow) as? NSObject) === publishedAlpha
        }
        check("reveal-expands-only-selected-worktree-and-keeps-recorded-diff",
            projection.fileTree.ancestorsByFileID[alphaFile.id]?.allSatisfy {
                store.changesFileTreeState.expandedIDs.contains($0)
            } == true && !refreshedTree.isItemExpanded(publishedBetaRoot)
            && store.selection == .change(alphaResult.id) && identifiers(host).contains("lens-diff-line-columns"))
        observations.append(["scenario": "native-tree-navigation-and-live-publication",
            "folderAction": "NSOutlineView left/right keyboard events and identified object selection",
            "addedMetadataFileCount": 1, "collectorIOQualified": false,
            "selectedFileID": alphaFile.id, "selectedTraceID": alphaResult.id,
            "expandedNodeIDs": store.changesFileTreeState.expandedIDs.sorted()])
        renders.append(try capture(host, output.appendingPathComponent("changes-file-tree-revealed-component-cache.png")))
        store.snapshot = initial; await store.waitForPresentation()
        try await waitFor(host, "tree-fixture-baseline-restored") {
            fileTree(in: host).map { nativeItemCount(in: $0) == projection.fileTree.nodesByID.count } == true
        }

        stage = "filtered-selection"
        store.changesKindFilter = .requestedPatch
        await store.waitForPresentation(); try await settle(host)
        check("filter-applies-before-overview-counts", store.presentation?.changesOverview.kinds == [.requestedPatch]
            && store.presentation?.changesOverview.traceIDs.contains(alphaResult.id) == false)
        check("filtered-selected-result-remains-readable", store.selection == .change(alphaResult.id)
            && identifiers(host).contains("lens-change-open-action"))
        check("filtered-selected-trace-exposes-retained-reading-notice",
            identifiers(host).contains("lens-changes-selected-trace-filtered"))
        renders.append(try capture(host, output.appendingPathComponent("changes-filtered-selection-component-cache.png")))
        store.changesKindFilter = nil
        await store.waitForPresentation()

        stage = "explicit-current-git"
        let alphaEnvironment = try require(initial.environments.first { $0.id == fixture.alpha.path }, "alpha environment")
        let current = try await store.files.currentDiff(environment: alphaEnvironment, relativePath: nil)
        let currentDocument = try RecordedDiff.parse(current.text,
            provenance: DiffProvenance(environmentID: alphaEnvironment.id), kind: .currentGit)
        check("global-current-diff-includes-two-files", Set(currentDocument.files.map(\.path)) == ["src/Same.swift", "src/Second.swift"])
        check("current-diff-bytes-stay-separate-from-recorded-patches", current.text.contains("currentAlpha")
            && current.text.contains("currentSecond") && !current.text.contains("proposedAlpha") && !current.text.contains("recordedAlpha"))
        store.changesOverviewEnvironmentID = fixture.alpha.path
        try await settle(host)
        check("current-git-entry-is-an-explicit-native-action", press("lens-changes-current-git", in: host))
        try await waitFor(host, "current-git-read-control") { identifiers(host).contains("lens-current-diff-read") }
        check("current-git-view-keeps-read-action", store.changesOverviewDetailMode == .currentGit
            && identifiers(host).contains("lens-current-diff-options"))
        check("current-git-view-does-not-read-before-explicit-action",
            !identifiers(host).contains("lens-diff-line-columns"))
        check("current-git-read-dispatches-only-own-fixture", press("lens-current-diff-read", in: host))
        try await waitFor(host, "current-git-global-native-diff") { identifiers(host).contains("lens-diff-line-columns") }
        renders.append(try capture(host, output.appendingPathComponent("changes-current-git-global-component-cache.png")))
        store.changesOverviewDetailMode = .recorded

        stage = "worktree-activity"
        store.changesOverviewEnvironmentID = nil; store.changesOverviewMode = .activity
        try await waitFor(host, stage) { identifiers(host).contains("lens-changes-activity-graph") }
        check("worktree-activity-mode-exposes-graph-and-complete-list", Set(["lens-changes-activity-graph",
            "lens-changes-activity-list"]).isSubset(of: identifiers(host)))
        check("worktree-activity-retains-right-file-tree-and-left-reading-pane",
            identifiers(host).contains("lens-changes-reading-pane") && treeLayout(in: host).right && treeLayout(in: host).fits)
        check("worktree-mode-retains-selected-file-and-trace", store.changesOverviewFileID == alphaFile.id
            && store.selection == .change(alphaResult.id))
        renders.append(try capture(host, output.appendingPathComponent("changes-worktree-activity-light-component-cache.png")))

        stage = "back-reader-checkpoints"
        host.rootView = mainView(store: store, context: context)
        window.setContentSize(NSSize(width: 1520, height: 980)); try await settle(host)
        store.changesOverviewEnvironmentID = fixture.alpha.path
        store.changesFileTreeQuery = "Same.swift"; store.changesFileTreeVisible = false
        try await settle(host)
        let checkpointExpansion = store.changesFileTreeState.expandedIDs
        store.navigate(.event(alphaRequest.eventID), newTab: true)
        check("new-tab-opens-recorded-action-with-overview-return", store.tabContentDestination == .event(alphaRequest.eventID)
            && !store.workspacePresented && store.hasWorkspaceReturn)
        store.changesPresentation = .actions; store.changesOverviewMode = .files
        store.changesOverviewEnvironmentID = fixture.beta.path; store.changesOverviewFileID = betaFile.id
        store.changesOverviewDetailMode = .currentGit; store.changesKindFilter = .requestedPatch
        store.changesFileTreeQuery = "NoDiff.swift"; store.changesFileTreeVisible = true
        let temporaryTreeState = ChangesFileTreeViewState()
        store.changesFileTreeState = temporaryTreeState
        store.goBack(); await store.waitForPresentation(); try await settle(host)
        check("back-restores-all-overview-checkpoint-bindings", store.workspacePresented && store.section == .changes
            && store.selection == .change(alphaResult.id) && store.changesPresentation == .overview
            && store.changesOverviewMode == .activity && store.changesOverviewEnvironmentID == fixture.alpha.path
            && store.changesOverviewFileID == alphaFile.id && store.changesOverviewDetailMode == .recorded
            && store.changesKindFilter == nil)
        check("back-restores-tree-filter-visibility-and-copied-expansion-checkpoint",
            store.changesFileTreeQuery == "Same.swift" && !store.changesFileTreeVisible
            && store.changesFileTreeState !== temporaryTreeState
            && store.changesFileTreeState.expandedIDs == checkpointExpansion)
        store.goForward(); await store.waitForPresentation()
        check("forward-reuses-one-reader-tab", store.tabContentDestination == .event(alphaRequest.eventID)
            && store.tabs.filter { $0.destination == .event(alphaRequest.eventID) }.count == 1)
        store.showWorkspace(); await store.waitForPresentation(); try await settle(host)
        check("workspace-return-restores-overview-mode-file-and-environment", store.workspacePresented
            && store.changesOverviewMode == .activity && store.changesOverviewFileID == alphaFile.id
            && store.changesOverviewEnvironmentID == fixture.alpha.path)
        check("workspace-return-restores-tree-reading-context", store.changesFileTreeQuery == "Same.swift"
            && !store.changesFileTreeVisible && store.changesFileTreeState.expandedIDs == checkpointExpansion)

        stage = "adaptive-layouts"
        store.changesOverviewMode = .files; store.changesFileTreeQuery = ""; store.changesFileTreeVisible = true
        for (name, width, scheme) in [("narrow", 440.0, ColorScheme.light), ("medium", 720.0, .light),
                                      ("wide", 1280.0, .light), ("wide-dark", 1280.0, .dark)] {
            host.rootView = component(store: store, context: context, scheme: scheme)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 980))
            try await waitFor(host, name + "-layout") {
                identifiers(host).contains("lens-changes-presentation") && fileTree(in: host) != nil
            }
            check(name + "-preserves-file-trace-and-mode", store.changesOverviewFileID == alphaFile.id
                && store.selection == .change(alphaResult.id) && store.changesOverviewMode == .files)
            let geometry = controlsGeometry(host, window: window,
                selectors: ["lens-changes-presentation", "lens-changes-current-git", "lens-changes-tree-toggle"])
            check(name + "-overview-controls-stay-in-window", geometry.fits)
            let layout = treeLayout(in: host)
            check(name + "-file-tree-stays-visible-in-window", layout.fits)
            check(name + "-file-tree-uses-right-or-bottom-native-split", width >= 560 ? layout.right : layout.below)
            renders.append(try capture(host, output.appendingPathComponent("changes-" + name + "-component-cache.png")))
            observations.append(["scenario": name + "-component-layout", "width": width, "height": 980,
                "identifiers": identifiers(host).sorted(), "geometry": geometry.observation,
                "fileTreeLayout": layout.observation])
        }

        stage = "two-window-state"
        let peer = makeStore(fixture: fixture, output: output, name: "peer", pool: pool)
        await peer.start(); await peer.open(fixture.rootID); await peer.waitForPresentation()
        defer { peer.stopObserving() }
        peer.showSessionPicker = false; peer.inspectorVisible = false; peer.chatVisible = false; peer.follow = false
        peer.browseSection(.changes); peer.changesOverviewMode = .activity
        peer.changesOverviewEnvironmentID = fixture.beta.path; peer.changesOverviewFileID = betaFile.id
        let betaTrace = try require(betaFile.traceIDs.first(where: { peer.change($0)?.kind == .requestedPatch }), "beta requested trace")
        peer.navigate(.change(betaTrace))
        let peerContext = LensWindowContext(store: peer)
        let peerHost = NSHostingView(rootView: component(store: peer, context: peerContext, scheme: .light))
        let peerWindow = makeWindow(host: peerHost, context: peerContext, width: 1100, height: 900, x: -9000)
        defer { peerWindow.contentView = nil; peerWindow.close() }
        let peerOverview = try require(peer.presentation?.changesOverview, "peer-window overview projection")
        let peerProjection = ChangesFileTree(groups: peerOverview.groups.filter { $0.id == fixture.beta.path })
        try await waitFor(peerHost, stage) {
            identifiers(peerHost).contains("lens-changes-activity-graph")
                && fileTree(in: peerHost).map { nativeItemCount(in: $0) == peerProjection.nodesByID.count } == true
        }
        let peerTree = try require(fileTree(in: peerHost), "peer-window native file tree")
        let peerFolderID = try require(peerProjection.ancestorsByFileID[betaFile.id]?.last, "peer beta parent folder")
        let peerFolder = try treeItem(peerFolderID, tree: peerProjection, outline: peerTree)
        let peerLeaf = try treeItem(betaNode.id, tree: peerProjection, outline: peerTree)
        let peerExpansion = peer.changesFileTreeState.expandedIDs
        store.changesOverviewEnvironmentID = nil; store.changesOverviewMode = .files
        store.changesKindFilter = .recordedResult
        store.changesFileTreeQuery = "NoDiff.swift"; store.changesFileTreeVisible = false
        await store.waitForPresentation(); try await settle(peerHost)
        check("two-windows-keep-independent-overview-bindings", peer.changesOverviewMode == .activity
            && peer.changesOverviewEnvironmentID == fixture.beta.path && peer.changesOverviewFileID == betaFile.id
            && peer.selection == .change(betaTrace) && peer.changesKindFilter == nil
            && store.changesOverviewMode == .files && store.changesKindFilter == .recordedResult)
        check("two-windows-keep-independent-tree-filter-visibility-and-expansion", peer.changesFileTreeVisible
            && peer.changesFileTreeQuery.isEmpty && peer.changesFileTreeState !== store.changesFileTreeState
            && peer.changesFileTreeState.expandedIDs == peerExpansion
            && (peerTree.item(atRow: peerTree.selectedRow) as? NSObject) === peerLeaf
            && !store.changesFileTreeVisible && store.changesFileTreeQuery == "NoDiff.swift")
        select(peerFolder, in: peerTree); try arrow(.left, in: peerTree); try await settle(peerHost)
        var peerRefreshed = try require(peer.snapshot, "peer snapshot before independent publication")
        peerRefreshed.collectedAt = peerRefreshed.collectedAt.addingTimeInterval(3)
        let peerPresentationID = peer.presentation?.id
        peer.snapshot = peerRefreshed; await peer.waitForPresentation(); try await settle(peerHost)
        check("peer-window-refresh-keeps-native-collapsed-folder-and-selected-diff",
            peer.presentation?.id != peerPresentationID && !peerTree.isItemExpanded(peerFolder)
            && (peerTree.item(atRow: peerTree.selectedRow) as? NSObject) === peerFolder
            && peer.changesOverviewFileID == betaFile.id && peer.selection == .change(betaTrace)
            && identifiers(peerHost).contains("lens-diff-line-columns"))
        check("peer-window-can-reveal-selection-independently", press("lens-changes-tree-reveal", in: peerHost))
        try await waitFor(peerHost, "peer-native-selected-file-reveal") {
            peerTree.isItemExpanded(peerFolder) && (peerTree.item(atRow: peerTree.selectedRow) as? NSObject) === peerLeaf
        }
        check("peer-reveal-does-not-change-other-window-tree-context", !store.changesFileTreeVisible
            && store.changesFileTreeQuery == "NoDiff.swift" && store.changesOverviewFileID == alphaFile.id
            && store.selection == .change(alphaResult.id))
        renders.append(try capture(peerHost, output.appendingPathComponent("changes-peer-worktree-activity-component-cache.png")))
        store.changesKindFilter = nil; store.changesFileTreeQuery = ""; store.changesFileTreeVisible = true
        await store.waitForPresentation()

        stage = "dense-graph-model-publication"
        let denseCount = 1200
        var dense = initial
        for index in 0..<denseCount {
            let environment = index.isMultiple(of: 2) ? fixture.alpha.path : fixture.beta.path
            let agent = index.isMultiple(of: 2) ? fixture.rootID : fixture.childID
            let id = "anonymous-dense-operation-" + String(index)
            let event = LensEvent(id: id, timestamp: ChangesOverviewFixture.epoch.addingTimeInterval(Double(index) + 20),
                agentID: agent, kind: .toolCall, title: "Anonymous in-memory operation", toolName: "apply_patch",
                callID: id, environmentID: environment, source: SourceRef(path: "/fixture/in-memory-metadata-no-journal"))
            dense.events.append(event)
            dense.changes.append(ChangeRecord(id: id + "-trace", path: environment + "/src/Dense.swift",
                environmentID: environment, agentID: agent, eventID: id, kind: .requestedPatch))
        }
        store.snapshot = dense; await store.waitForPresentation()
        store.changesOverviewEnvironmentID = nil; store.changesOverviewFileID = nil; store.changesOverviewMode = .activity
        host.rootView = component(store: store, context: context, scheme: .light)
        window.setContentSize(NSSize(width: 1280, height: 980))
        try await waitFor(host, stage) { identifiers(host).contains("lens-changes-graph-bin") }
        let bins = buttonCount("lens-changes-graph-bin", in: host)
        let lanes = store.presentation?.changesOverview.groups.count ?? 0
        check("dense-projection-retains-every-operation", store.presentation?.changesOverview.activityCount == denseCount + projection.activityCount
            && store.presentation?.changesOverview.traceIDs.count == denseCount + projection.traceIDs.count)
        check("dense-graph-mark-count-is-bounded-per-lane", bins > 0 && bins <= 160 * lanes)
        check("dense-operations-remain-accessible-in-list", identifiers(host).contains("lens-changes-activity-list"))
        observations.append(["scenario": "dense-in-memory-model-publication", "addedOperationCount": denseCount,
            "retainedOperationCount": store.presentation?.changesOverview.activityCount ?? 0, "graphButtonCount": bins,
            "laneCount": lanes, "maximumGraphMarksPerLane": 160,
            "note": "Actual accessible graph buttons counted; underlying operations retained. This is no timing or memory claim."])
        renders.append(try capture(host, output.appendingPathComponent("changes-dense-worktree-activity-component-cache.png")))
        check("peer-window-is-not-replaced-by-dense-publication", peer.presentation?.changesOverview.activityCount == projection.activityCount
            && peer.changesOverviewFileID == betaFile.id && peer.selection == .change(betaTrace))

        stage = "source-integrity"
        check("anonymous-journals-and-current-worktree-files-remain-unchanged", fixture.sourcesUnchanged())
        await peer.investigation.flushAndStop(); await store.investigation.flushAndStop()
        receipt(true); completed = true
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else {
            throw LensError.unavailable("One or more changes-overview checks failed; inspect the retained receipt.")
        }
    }

    @MainActor private static func makeStore(fixture: ChangesOverviewFixture, output: URL, name: String, pool: SessionReaderPool) -> LensStore {
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent(name + "-archive")),
            cacheDirectory: output.appendingPathComponent(name + "-cache"), readerPool: pool)
        store.setNavigationScope(UUID().uuidString)
        return store
    }
    @MainActor private static func component(store: LensStore, context: LensWindowContext, scheme: ColorScheme) -> AnyView {
        AnyView(ChangesView().environmentObject(store).environment(\.lensWindowContext, context)
            .environment(\.lensChangesDeferredSelectionDiagnostic, { values in
                selectionDiagnostics.append(values)
                if selectionDiagnostics.count > 64 { selectionDiagnostics.removeFirst() }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en")))
    }
    @MainActor private static func mainView(store: LensStore, context: LensWindowContext) -> AnyView {
        AnyView(MainView().environmentObject(store).environment(\.lensWindowContext, context)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en")))
    }
    @MainActor private static func makeWindow(host: NSView, context: LensWindowContext, width: CGFloat, height: CGFloat, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: -6000, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Codex Lens — anonymous changes fixture"
        window.appearance = NSAppearance(named: .aqua)
        window.setAccessibilityIdentifier("ChangesOverview-" + UUID().uuidString)
        (host as? NSHostingView<AnyView>)?.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        context.attach(window); window.orderBack(nil)
        return window
    }
    @MainActor private static func documents(change: ChangeRecord, store: LensStore) async throws -> [RecordedDiffDocument] {
        let event = try require(store.event(change.eventID), "recorded source event")
        let selected = try RecordedChangeEvidence.select(change: change, event: event,
            related: event.relatedEventID.flatMap { store.event($0) })
        return try RecordedChangeEvidence.documents(change: change, selection: selected,
            detail: await store.engine.sourceDetail(for: event))
    }
    private static func diffText(_ documents: [RecordedDiffDocument]) -> String {
        documents.flatMap(\.files).flatMap(\.hunks).flatMap(\.lines).map(\.text).joined(separator: "\n")
    }
    @MainActor private static func elements(_ host: NSView) -> [NSAccessibilityProtocol] {
        var result: [NSAccessibilityProtocol] = [], seen = Set<ObjectIdentifier>()
        func walk(_ node: Any, depth: Int) {
            guard depth < 45, seen.count < 30_000, let element = node as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        // An ignored hosting root can have no AX children while its native
        // descendants own the SwiftUI accessibility containers.
        for view in descendants(host) where !view.isHiddenOrHasHiddenAncestor { walk(view, depth: 0) }
        return result
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor private static func fileTree(in host: NSView) -> NSOutlineView? {
        let matches = descendants(host).compactMap { $0 as? NSOutlineView }.filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityIdentifier() == "lens-changes-file-tree"
        }
        return matches.count == 1 ? matches.first : nil
    }
    /// Resolve opaque native objects against the prepared node hierarchy. Row
    /// numbers are only queried after resolving identity, so disclosure changes
    /// cannot accidentally select the next worktree's same-named file.
    @MainActor private static func treeItem(_ id: String, tree: ChangesFileTree, outline: NSOutlineView) throws -> NSObject {
        let source = try require(outline.dataSource, "native tree data source")
        func find(_ nodes: [ChangesFileTreeNode], parent: NSObject?) throws -> NSObject? {
            let count = source.outlineView?(outline, numberOfChildrenOfItem: parent) ?? 0
            guard count == nodes.count else { throw LensError.unavailable("Native hierarchy does not match the prepared changed-file nodes.") }
            for (index, node) in nodes.enumerated() {
                let object = try require(source.outlineView?(outline, child: index, ofItem: parent) as? NSObject,
                                         "native object for changed-file node " + node.id)
                if node.id == id { return object }
                if let result = try find(node.children, parent: object) { return result }
            }
            return nil
        }
        return try require(find(tree.roots, parent: nil), "native changed-file node " + id)
    }
    @MainActor private static func nativeItemCount(in outline: NSOutlineView) -> Int {
        guard let source = outline.dataSource else { return 0 }
        var total = 0
        func count(_ parent: Any?, depth: Int) {
            guard depth < 70, total < 100_000 else { return }
            let children = source.outlineView?(outline, numberOfChildrenOfItem: parent) ?? 0
            for index in 0..<children {
                guard let object = source.outlineView?(outline, child: index, ofItem: parent) else { continue }
                total += 1; count(object, depth: depth + 1)
            }
        }
        count(nil, depth: 0)
        return total
    }
    @MainActor private static func select(_ item: NSObject, in outline: NSOutlineView) {
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }
    private enum TreeArrow: Equatable { case left, right }
    @MainActor private static func arrow(_ direction: TreeArrow, in outline: NSOutlineView) throws {
        let characters = direction == .left ? "\u{f702}" : "\u{f703}"
        let code: UInt16 = direction == .left ? 123 : 124
        let event = try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: outline.window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code),
            "native folder disclosure key event")
        outline.keyDown(event)
    }
    @MainActor private static func expandAncestors(of fileID: String, tree: ChangesFileTree, outline: NSOutlineView) throws {
        let ancestors = try require(tree.ancestorsByFileID[fileID], "tree ancestors for selected file")
        for id in ancestors {
            let item = try treeItem(id, tree: tree, outline: outline)
            guard outline.row(forItem: item) >= 0 else { throw LensError.unavailable("Native ancestor is not visible before disclosure.") }
            select(item, in: outline)
            if !outline.isItemExpanded(item) { try arrow(.right, in: outline) }
        }
    }
    private struct TreeLayout {
        let right: Bool, below: Bool, fits: Bool
        let observation: [String: Any]
    }
    @MainActor private static func treeLayout(in host: NSView) -> TreeLayout {
        guard let tree = fileTree(in: host) else {
            return TreeLayout(right: false, below: false, fits: false, observation: ["nativeTreeFound": false])
        }
        var parent: NSView? = tree.superview
        while let current = parent {
            if let split = current as? NSSplitView, split.subviews.count == 2,
               let first = split.subviews.first, let last = split.subviews.last,
               descendants(last).contains(where: { $0 === tree }) {
                let reading = host.convert(first.bounds, from: first)
                let navigation = host.convert(last.bounds, from: last)
                let visible = host.bounds.intersection(host.visibleRect)
                let fits = !visible.isNull && navigation.width > 0 && navigation.height > 0
                    && navigation.minX >= visible.minX - 2 && navigation.maxX <= visible.maxX + 2
                    && navigation.minY >= visible.minY - 2 && navigation.maxY <= visible.maxY + 2
                let right = split.isVertical && navigation.minX >= reading.maxX - 2
                let below = !split.isVertical && (host.isFlipped
                    ? navigation.minY >= reading.maxY - 2 : navigation.maxY <= reading.minY + 2)
                return TreeLayout(right: right, below: below, fits: fits, observation: [
                    "nativeTreeFound": true, "nativeResizableSplit": true, "splitIsVertical": split.isVertical,
                    "readingPaneFrame": NSStringFromRect(reading), "treePaneFrame": NSStringFromRect(navigation),
                    "hostVisibleRect": NSStringFromRect(visible), "treeIsRight": right, "treeIsBelow": below,
                    "treeFitsVisibleContent": fits])
            }
            parent = current.superview
        }
        return TreeLayout(right: false, below: false, fits: false, observation: ["nativeTreeFound": true, "nativeResizableSplit": false])
    }
    private static func axValue(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return (error, value)
    }
    @MainActor private static func ownAXNodes(_ host: NSView) -> (nodes: [AXUIElement], diagnostics: [String]) {
        guard let window = host.window, window.accessibilityIdentifier().hasPrefix("ChangesOverview-") else {
            return ([], ["No identified owned probe window"])
        }
        // Query only this probe PID and the exact window identity. This neither
        // activates another app nor requests accessibility permission.
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 0.5)
        let windows = axValue(application, kAXWindowsAttribute)
        guard windows.0 == .success, let peers = windows.1 as? [AXUIElement] else {
            return ([], ["Own-process AXWindows unavailable: \(windows.0.rawValue)"])
        }
        let matches = peers.filter { axValue($0, kAXIdentifierAttribute).1 as? String == window.accessibilityIdentifier() }
        guard matches.count == 1, let match = matches.first else {
            return ([], ["Expected one identified owned window; found \(matches.count)"])
        }
        var result: [AXUIElement] = [], seen: [CFHashCode: [AXUIElement]] = [:]
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < 45, result.count < 30_000 else { return }
            let hash = CFHash(node)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
            seen[hash, default: []].append(node); result.append(node)
            for child in axValue(node, kAXChildrenAttribute).1 as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(match, depth: 0)
        return (result, ["Own-process public AX nodes visited: \(result.count)"])
    }
    @MainActor private static func identifiers(_ host: NSView) -> Set<String> {
        Set(elements(host).compactMap { $0.accessibilityIdentifier() }.filter { !$0.isEmpty })
            .union(ownAXNodes(host).nodes.compactMap { axValue($0, kAXIdentifierAttribute).1 as? String })
    }
    @MainActor private static func press(_ selector: String, in host: NSView) -> Bool {
        for node in elements(host) where node.accessibilityIdentifier() == selector {
            if let button = node as? NSButton, button.isEnabled { button.performClick(nil); return true }
            if node.accessibilityPerformPress() { return true }
        }
        for node in ownAXNodes(host).nodes where axValue(node, kAXIdentifierAttribute).1 as? String == selector {
            if AXUIElementPerformAction(node, kAXPressAction as CFString) == .success { return true }
        }
        return false
    }
    @MainActor private static func buttonCount(_ selector: String, in host: NSView) -> Int {
        let native = elements(host).filter { $0.accessibilityIdentifier() == selector && $0.accessibilityRole() == .button }.count
        if native > 0 { return native }
        return ownAXNodes(host).nodes.filter {
            axValue($0, kAXIdentifierAttribute).1 as? String == selector && axValue($0, kAXRoleAttribute).1 as? String == kAXButtonRole
        }.count
    }
    private struct ControlGeometry {
        let fits: Bool
        let observation: [String: Any]
    }
    private static let interactiveRoles: Set<String> = ["AXButton", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXSwitch"]

    @MainActor private static func controlsGeometry(_ host: NSView, window: NSWindow, selectors: [String]) -> ControlGeometry {
        let nativeNodes = elements(host), publicTree = ownAXNodes(host)
        let publicWindowFrame = publicTree.nodes.first.flatMap(axFrame)
        let contentInHost = host.convert(window.contentLayoutRect, from: nil)
        let visibleContent = host.bounds.intersection(contentInHost)
        let windowSizeMatches = publicWindowFrame.map {
            abs($0.width - window.frame.width) <= 2 && abs($0.height - window.frame.height) <= 2
        } ?? false
        func inHost(_ screen: CGRect) -> CGRect { host.convert(window.convertFromScreen(screen), from: nil) }
        func publicInHost(_ frame: CGRect) -> CGRect? {
            // Public AX uses a top-left screen origin; AppKit uses a bottom-left
            // one. Anchor both to this exact own window rather than assume a
            // monitor arrangement or mix frames from those coordinate systems.
            guard windowSizeMatches, let base = publicWindowFrame else { return nil }
            let screen = CGRect(x: window.frame.minX + frame.minX - base.minX,
                y: window.frame.maxY - (frame.minY - base.minY) - frame.height,
                width: frame.width, height: frame.height)
            return inHost(screen)
        }
        func fits(_ frame: CGRect?) -> Bool {
            guard let frame, !visibleContent.isNull, frame.width > 0, frame.height > 0,
                  [frame.minX, frame.maxX, frame.minY, frame.maxY].allSatisfy(\.isFinite) else { return false }
            return frame.minX >= visibleContent.minX - 2 && frame.maxX <= visibleContent.maxX + 2
                && frame.minY >= visibleContent.minY - 2 && frame.maxY <= visibleContent.maxY + 2
        }
        func nativeRecord(_ node: NSAccessibilityProtocol) -> [String: Any] {
            let frame = node.accessibilityFrame()
            return ["role": node.accessibilityRole()?.rawValue ?? "<unknown>", "identifier": node.accessibilityIdentifier(),
                "label": node.accessibilityLabel() ?? node.accessibilityTitle() ?? "",
                "screenFrameAppKit": NSStringFromRect(frame), "hostFrame": NSStringFromRect(inHost(frame)),
                "fitsVisibleContent": fits(inHost(frame))]
        }
        func publicRecord(_ node: AXUIElement) -> [String: Any] {
            let frame = axFrame(node), local = frame.flatMap(publicInHost)
            return ["role": axValue(node, kAXRoleAttribute).1 as? String ?? "<unknown>",
                "identifier": axValue(node, kAXIdentifierAttribute).1 as? String ?? "",
                "label": axValue(node, kAXTitleAttribute).1 as? String ?? axValue(node, kAXDescriptionAttribute).1 as? String ?? "",
                "screenFramePublicAX": frame.map(NSStringFromRect) ?? "<unavailable>",
                "hostFrame": local.map(NSStringFromRect) ?? "<unavailable>", "fitsVisibleContent": fits(local)]
        }
        var records: [[String: Any]] = [], passed = true
        for selector in selectors {
            let nativeRoots = nativeNodes.filter { $0.accessibilityIdentifier() == selector }
            let publicRoots = publicTree.nodes.filter { axValue($0, kAXIdentifierAttribute).1 as? String == selector }
            var nativeTargets: [NSAccessibilityProtocol] = [], nativeSeen = Set<ObjectIdentifier>()
            func visitNative(_ node: NSAccessibilityProtocol, depth: Int) {
                guard depth < 20, nativeSeen.count < 200,
                      nativeSeen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
                if Self.interactiveRoles.contains(node.accessibilityRole()?.rawValue ?? "") { nativeTargets.append(node) }
                for child in node.accessibilityChildren() ?? [] {
                    if let element = child as? NSAccessibilityProtocol { visitNative(element, depth: depth + 1) }
                }
            }
            for root in nativeRoots { visitNative(root, depth: 0) }
            var publicTargets: [AXUIElement] = [], publicSeen: [CFHashCode: [AXUIElement]] = [:]
            func visitPublic(_ node: AXUIElement, depth: Int) {
                guard depth < 20, publicTargets.count < 200 else { return }
                let hash = CFHash(node)
                guard !(publicSeen[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
                publicSeen[hash, default: []].append(node)
                if Self.interactiveRoles.contains(axValue(node, kAXRoleAttribute).1 as? String ?? "") { publicTargets.append(node) }
                for child in axValue(node, kAXChildrenAttribute).1 as? [AXUIElement] ?? [] { visitPublic(child, depth: depth + 1) }
            }
            for root in publicRoots { visitPublic(root, depth: 0) }
            // The three-way segmented picker is a semantic group, sometimes
            // reported with a zero frame. Check every real interactive segment,
            // with all three required, rather than declare the group itself a button.
            let minimumTargets = selector == "lens-changes-presentation" ? 3 : 1
            let usePublic = !publicRoots.isEmpty
            let selectorPassed = usePublic
                ? windowSizeMatches && publicTargets.count >= minimumTargets && publicTargets.allSatisfy { fits(axFrame($0).flatMap(publicInHost)) }
                : nativeTargets.count >= minimumTargets && nativeTargets.allSatisfy { fits(inHost($0.accessibilityFrame())) }
            passed = passed && selectorPassed
            records.append(["selector": selector, "passed": selectorPassed, "checkedProvider": usePublic ? "public-own-process-AX" : "NSAccessibilityProtocol",
                "minimumInteractiveTargets": minimumTargets, "nativeCandidates": nativeRoots.map(nativeRecord),
                "nativeInteractiveTargets": nativeTargets.map(nativeRecord), "publicCandidates": publicRoots.map(publicRecord),
                "publicInteractiveTargets": publicTargets.map(publicRecord)])
        }
        let value: [String: Any] = ["windowFrameAppKit": NSStringFromRect(window.frame),
            "windowContentLayoutRect": NSStringFromRect(window.contentLayoutRect),
            "windowContentScreenRect": NSStringFromRect(window.contentRect(forFrameRect: window.frame)),
            "contentInHost": NSStringFromRect(contentInHost), "visibleContentInHost": NSStringFromRect(visibleContent),
            "hostFrame": NSStringFromRect(host.frame), "hostBounds": NSStringFromRect(host.bounds),
            "hostVisibleRect": NSStringFromRect(host.visibleRect), "windowFramePublicAX": publicWindowFrame.map(NSStringFromRect) ?? "<unavailable>",
            "publicWindowSizeMatchesAppKit": windowSizeMatches, "publicAXDiagnostics": publicTree.diagnostics, "controls": records]
        return ControlGeometry(fits: passed, observation: value)
    }
    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute).1, CFGetTypeID(position) == AXValueGetTypeID(),
              let size = axValue(element, kAXSizeAttribute).1, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    @MainActor private static func draw(_ host: NSView) {
        if let window = host.window, window.contentView === host {
            // NSWindow can constrain a requested size to an attached display.
            // Mount and capture the real content size, never force a taller cache
            // surface whose header lies above the actual visible window.
            let actual = window.contentRect(forFrameRect: window.frame).size
            if host.frame.size != actual { host.setFrameSize(actual) }
        }
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        host.needsDisplay = true; host.displayIfNeeded(); host.window?.displayIfNeeded()
        CATransaction.flush()
    }
    @MainActor private static func settle(_ host: NSView) async throws {
        for _ in 0..<10 { await Task.yield(); draw(host); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor private static func waitFor(_ host: NSView, _ next: String, _ predicate: () -> Bool) async throws {
        stage = next
        for _ in 0..<250 {
            await Task.yield(); draw(host)
            if predicate() { try await settle(host); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        retainFailureDiagnostics(host, reason: "Native view did not reach " + next)
        throw LensError.unavailable("Native view did not reach " + next + "; identifiers: " + identifiers(host).sorted().joined(separator: ", "))
    }
    @MainActor private static func retainFailureDiagnostics(_ host: NSView, reason: String) {
        guard let output = diagnosticOutput else { return }
        draw(host)
        let publicAX = ownAXNodes(host)
        var value: [String: Any] = ["stage": stage, "reason": reason, "hostBounds": NSStringFromRect(host.bounds),
            "nativeDescendantCount": descendants(host).count, "nativeAXCount": elements(host).count,
            "publicAXCount": publicAX.nodes.count, "publicAXDiagnostics": publicAX.diagnostics,
            "identifiers": identifiers(host).sorted()]
        if let window = host.window {
            value["window"] = ["identifier": window.accessibilityIdentifier(), "visible": window.isVisible,
                "frame": NSStringFromRect(window.frame), "windowNumber": window.windowNumber]
        }
        if let store = diagnosticStore {
            value["store"] = ["section": store.section.rawValue, "overviewMode": store.changesOverviewMode.rawValue,
                "projectionReady": store.presentation != nil, "isProjecting": store.isProjecting,
                "environmentIDs": store.snapshot?.environments.map(\.id) ?? [],
                "changes": store.snapshot?.changes.map { ["id": $0.id, "path": $0.path, "environmentID": $0.environmentID] } ?? []] as [String: Any]
        }
        if let name = try? capture(host, output.appendingPathComponent("changes-failed-" + stage + "-component-cache.png")) { value["render"] = name }
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("phase.json"))
        }
    }
    @MainActor private static func capture(_ host: NSView, _ path: URL) throws -> String {
        draw(host)
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: path)
        return path.lastPathComponent
    }
    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + name) }
        return value
    }
    private static func argument(_ name: String) throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else {
            throw LensError.unavailable("Missing " + name)
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
}

private final class ChangesOverviewFixture {
    static let epoch = Date(timeIntervalSince1970: 1_767_268_800)
    let rootID = "11111111-1111-4111-8111-111111111111"
    let childID = "22222222-2222-4222-8222-222222222222"
    let home: URL, alpha: URL, beta: URL
    private var hashes: [URL: String] = [:]

    init(output: URL) throws {
        // Use the same Foundation-normalized spelling as recorded path resolution
        // before serializing cwd. Never rewrite identities after source ingestion.
        let base = output.standardizedFileURL.appendingPathComponent("anonymous-changes-fixture", isDirectory: true).standardizedFileURL
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let outputPath = output.resolvingSymlinksInPath().standardizedFileURL.path
        guard outputPath.hasPrefix(temporaryRoot + "/"), !FileManager.default.fileExists(atPath: base.path) else {
            throw LensError.unavailable("Use a new private temporary native output directory.")
        }
        home = base.appendingPathComponent("codex-home", isDirectory: true).standardizedFileURL
        alpha = base.appendingPathComponent("worktrees/alpha", isDirectory: true).standardizedFileURL
        beta = base.appendingPathComponent("worktrees/beta", isDirectory: true).standardizedFileURL
        let repository = base.appendingPathComponent("repository", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: repository, withIntermediateDirectories: true)
        try manager.createDirectory(at: alpha.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try git(["init", "--initial-branch=fixture/main"], at: repository)
        try manager.createDirectory(at: repository.appendingPathComponent("src"), withIntermediateDirectories: true)
        for (file, text) in [("Same.swift", "let value = oldValue\n"), ("Second.swift", "let second = oldSecond\n"),
                             ("NoDiff.swift", "let unchanged = original\n"), ("Undated.swift", "let undated = old\n")] {
            try Data(text.utf8).write(to: repository.appendingPathComponent("src/" + file))
        }
        _ = try git(["add", "--", "src"], at: repository)
        _ = try git(["commit", "-m", "Anonymous native fixture baseline"], at: repository)
        let recordedRef = try git(["rev-parse", "--verify", "HEAD"], at: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(["worktree", "add", "-b", "fixture/alpha", alpha.path, recordedRef], at: repository)
        _ = try git(["worktree", "add", "-b", "fixture/beta", beta.path, recordedRef], at: repository)
        try Data("let value = currentAlpha\n".utf8).write(to: alpha.appendingPathComponent("src/Same.swift"))
        try Data("let second = currentSecond\n".utf8).write(to: alpha.appendingPathComponent("src/Second.swift"))
        try Data("let value = currentBeta\n".utf8).write(to: beta.appendingPathComponent("src/Same.swift"))
        let sessions = home.appendingPathComponent("sessions/2026/01/01", isDirectory: true)
        try manager.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rootLog = sessions.appendingPathComponent("rollout-anonymous-alpha.jsonl")
        let childLog = sessions.appendingPathComponent("rollout-anonymous-beta.jsonl")
        let patch = "*** Begin Patch\n*** Update File: src/Same.swift\n@@\n-let value = oldValue\n+let value = proposedAlpha\n*** End Patch\n"
        let recorded = "--- a/src/Same.swift\n+++ b/src/Same.swift\n@@ -1 +1 @@\n-let value = oldValue\n+let value = recordedAlpha\n"
        try write([
            record("session_meta", ["id": rootID, "cwd": alpha.path, "agent_nickname": "Alpha agent",
                "git": ["branch": "fixture/alpha", "commit_hash": recordedRef]], at: 0),
            record("response_item", ["type": "function_call", "name": "spawn_agent", "call_id": "fixture-spawn",
                "arguments": ["task_name": "beta_inspection", "message": "Inspect the anonymous beta fixture."]], at: 1),
            record("response_item", ["type": "function_call_output", "call_id": "fixture-spawn", "output": ["agent_id": childID]], at: 2),
            record("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "alpha-patch", "input": patch], at: 3),
            record("response_item", ["type": "custom_tool_call_output", "call_id": "alpha-patch", "output": recorded], at: 5),
            record("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "no-diff-patch",
                "input": "*** Begin Patch\n*** Update File: src/NoDiff.swift\n@@\n-let unchanged = original\n+let unchanged = proposed\n*** End Patch\n"], at: 8),
            record("response_item", ["type": "custom_tool_call_output", "call_id": "no-diff-patch",
                "output": "Success. Updated the following files:\nM src/NoDiff.swift"], at: 9),
            record("event_msg", ["type": "item_completed", "item": ["id": "undated-patch", "type": "FileChange",
                "status": "completed", "changes": [["path": "src/Undated.swift", "diff": "@@ -1 +1 @@\n-old\n+undated recorded\n"]]]], at: nil)
        ], to: rootLog)
        try write([
            record("session_meta", ["id": childID, "cwd": beta.path, "agent_nickname": "Beta agent", "parent_thread_id": rootID], at: 2),
            record("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "beta-patch",
                "input": patch.replacingOccurrences(of: "proposedAlpha", with: "proposedBeta")], at: 6),
            record("response_item", ["type": "custom_tool_call_output", "call_id": "beta-patch",
                "output": "Success. Updated the following files:\nM src/Same.swift"], at: 7)
        ], to: childLog)
        for source in [rootLog, childLog] + [alpha, beta].flatMap({ tree in
            ["Same.swift", "Second.swift", "NoDiff.swift", "Undated.swift"].map { tree.appendingPathComponent("src/" + $0) }
        }) { hashes[source] = Self.digest(try Data(contentsOf: source)) }
        try JSONSerialization.data(withJSONObject: ["anonymous": true, "rootID": rootID, "childID": childID,
            "worktrees": [alpha.path, beta.path], "recordedCommit": recordedRef,
            "sources": hashes.map { ["path": $0.key.path, "sha256": $0.value] }], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("changes-overview-fixture-manifest.json"))
    }
    func sourcesUnchanged() -> Bool {
        hashes.allSatisfy { source, expected in (try? Data(contentsOf: source)).map { Self.digest($0) == expected } ?? false }
    }
    private func record(_ type: String, _ payload: [String: Any], at offset: Double?) -> [String: Any] {
        var value: [String: Any] = ["type": type, "payload": payload]
        if let offset { value["timestamp"] = ISO8601DateFormatter().string(from: Self.epoch.addingTimeInterval(offset)) }
        return value
    }
    private func write(_ records: [[String: Any]], to path: URL) throws {
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10) }
        try data.write(to: path)
    }
    private func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat",
            "GIT_AUTHOR_NAME": "Lens Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Lens Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LensError.unavailable("Own fixture Git setup failed: " + String(decoding: bytes, as: UTF8.self)) }
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
