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
        try await waitFor(host, "overview-native-controls") { identifiers(host).contains("lens-changes-files") }
        check("overview-exposes-files-environments-and-modes", Set(["lens-changes-files", "lens-changes-environments",
            "lens-changes-presentation", "lens-changes-presentation"]).isSubset(of: identifiers(host)))
        renders.append(try capture(host, output.appendingPathComponent("changes-overview-all-files-light-component-cache.png")))

        stage = "same-context-publication-during-native-selection"
        do {
            let previousID = try require(store.presentation?.id, "presentation before interleaving")
            let previousSelection = store.selection
            let betaRequest = try require(initial.changes.first {
                $0.environmentID == betaFile.environmentID && $0.kind == .requestedPatch && betaFile.traceIDs.contains($0.id)
            }, "beta requested trace")
            let betaRow = try require(projection.files.firstIndex { $0.id == betaFile.id }, "beta file row")
            let fileTables = descendants(host).compactMap { $0 as? NSTableView }.filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.numberOfRows == projection.files.count
            }
            guard fileTables.count == 1, let fileTable = fileTables.first else {
                throw LensError.unavailable("Expected one native table for the four-file anonymous overview.")
            }
            var callbackRan = false, interleavedNewGeneration = false, bindingChangedBeforeNavigation = false
            // @Published emits in willSet. Selecting the actual native file row
            // here queues navigation against the old presentation; the new one
            // is assigned synchronously before that MainActor task can resume.
            let publication = store.$presentation.dropFirst().sink { next in
                guard !callbackRan, let next, next.rootID == initial.root.id, next.id != previousID else { return }
                callbackRan = true
                interleavedNewGeneration = store.presentation?.id == previousID
                fileTable.selectRowIndexes(IndexSet(integer: betaRow), byExtendingSelection: false)
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
                "trigger": "NSTableView.selectRowIndexes inside presentation willSet publisher",
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
        check("worktree-mode-retains-selected-file-and-trace", store.changesOverviewFileID == alphaFile.id
            && store.selection == .change(alphaResult.id))
        renders.append(try capture(host, output.appendingPathComponent("changes-worktree-activity-light-component-cache.png")))

        stage = "back-reader-checkpoints"
        host.rootView = mainView(store: store, context: context)
        window.setContentSize(NSSize(width: 1520, height: 980)); try await settle(host)
        store.changesOverviewEnvironmentID = fixture.alpha.path
        store.navigate(.event(alphaRequest.eventID), newTab: true)
        check("new-tab-opens-recorded-action-with-overview-return", store.tabContentDestination == .event(alphaRequest.eventID)
            && !store.workspacePresented && store.hasWorkspaceReturn)
        store.changesPresentation = .actions; store.changesOverviewMode = .files
        store.changesOverviewEnvironmentID = fixture.beta.path; store.changesOverviewFileID = betaFile.id
        store.changesOverviewDetailMode = .currentGit; store.changesKindFilter = .requestedPatch
        store.goBack(); await store.waitForPresentation(); try await settle(host)
        check("back-restores-all-overview-checkpoint-bindings", store.workspacePresented && store.section == .changes
            && store.selection == .change(alphaResult.id) && store.changesPresentation == .overview
            && store.changesOverviewMode == .activity && store.changesOverviewEnvironmentID == fixture.alpha.path
            && store.changesOverviewFileID == alphaFile.id && store.changesOverviewDetailMode == .recorded
            && store.changesKindFilter == nil)
        store.goForward(); await store.waitForPresentation()
        check("forward-reuses-one-reader-tab", store.tabContentDestination == .event(alphaRequest.eventID)
            && store.tabs.filter { $0.destination == .event(alphaRequest.eventID) }.count == 1)
        store.showWorkspace(); await store.waitForPresentation(); try await settle(host)
        check("workspace-return-restores-overview-mode-file-and-environment", store.workspacePresented
            && store.changesOverviewMode == .activity && store.changesOverviewFileID == alphaFile.id
            && store.changesOverviewEnvironmentID == fixture.alpha.path)

        stage = "adaptive-layouts"
        store.changesOverviewMode = .files
        for (name, width, scheme) in [("narrow", 440.0, ColorScheme.light), ("medium", 720.0, .light),
                                      ("wide", 1280.0, .light), ("wide-dark", 1280.0, .dark)] {
            host.rootView = component(store: store, context: context, scheme: scheme)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 980))
            try await waitFor(host, name + "-layout") { identifiers(host).contains("lens-changes-presentation") }
            check(name + "-preserves-file-trace-and-mode", store.changesOverviewFileID == alphaFile.id
                && store.selection == .change(alphaResult.id) && store.changesOverviewMode == .files)
            let geometry = controlsGeometry(host, window: window,
                selectors: ["lens-changes-presentation", "lens-changes-current-git"])
            check(name + "-overview-controls-stay-in-window", geometry.fits)
            renders.append(try capture(host, output.appendingPathComponent("changes-" + name + "-component-cache.png")))
            observations.append(["scenario": name + "-component-layout", "width": width, "height": 980,
                "identifiers": identifiers(host).sorted(), "geometry": geometry.observation])
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
        try await waitFor(peerHost, stage) { identifiers(peerHost).contains("lens-changes-activity-graph") }
        store.changesOverviewEnvironmentID = nil; store.changesOverviewMode = .files
        store.changesKindFilter = .recordedResult
        await store.waitForPresentation(); try await settle(peerHost)
        check("two-windows-keep-independent-overview-bindings", peer.changesOverviewMode == .activity
            && peer.changesOverviewEnvironmentID == fixture.beta.path && peer.changesOverviewFileID == betaFile.id
            && peer.selection == .change(betaTrace) && peer.changesKindFilter == nil
            && store.changesOverviewMode == .files && store.changesKindFilter == .recordedResult)
        renders.append(try capture(peerHost, output.appendingPathComponent("changes-peer-worktree-activity-component-cache.png")))
        store.changesKindFilter = nil; await store.waitForPresentation()

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
