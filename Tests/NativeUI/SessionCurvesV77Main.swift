import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import LensCore
import SwiftUI

/// Real store/MainView checks on generated histories. Cached component PNGs
/// are not compositor captures; the append scenario publishes metadata in memory.
@main struct SessionCurvesV77Main {
    @MainActor private static var stage = "fixture-and-store-setup"
    @MainActor private static var diagnosticOutput: URL?
    @MainActor private static weak var diagnosticStore: LensStore?
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify(); NSApp.terminate(nil) }
            catch { fputs("Session curves qualification: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output"), fixture = try CurvesFixtureV77(corpus: argument("--corpus"))
        diagnosticOutput = output
        let sourceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        UserDefaults.standard.setVolatileDomain(["lensLanguage": "en", "lensReduceMotionOverride": true,
            "lensControlAccent": "lens", "lensTabMaterial": "system"], forName: UserDefaults.argumentDomain)
        LensL10n.language = .en; LensGuideCoordinator.shared.onboarding.dismiss()
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: SessionReaderPool())
        diagnosticStore = store
        store.setNavigationScope(UUID().uuidString)
        await store.start(); await store.open(fixture.rootID); await store.waitForPresentation()
        defer { store.stopObserving() }
        store.showSessionPicker = false; store.inspectorVisible = false; store.chatVisible = false
        store.browseSection(.activity); store.activityMode = .trends; store.agentFilter = fixture.rootID
        await store.waitForPresentation()
        guard let snapshot = store.snapshot, let projection = store.presentation?.trends,
              let bucket = projection.buckets.first(where: { $0.count(for: .mcpCalls) > 0 }) else {
            throw LensError.unavailable("The generated MCP history did not produce curve intervals.")
        }
        var checks: [[String: Any]] = [], renders: [String] = [], observations: [[String: Any]] = []
        var completed = false
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func writeReceipt(_ complete: Bool) {
            let receipt: [String: Any] = ["checks": checks, "renders": renders, "observations": observations,
                "completed": complete, "failedStage": complete ? "none" : stage,
                "allExecutedChecksPassed": complete && checks.allSatisfy { $0["passed"] as? Bool == true },
                "fixture": ["anonymous": true, "rootID": fixture.rootID, "observedSourcesModified": !fixture.sourcesUnchanged()],
                "scope": "Production LensStore/MainView, native AppKit window and table; source-matched component-cache renders.",
                "unqualified": ["No physical pointer/trackpad, VoiceOver, production compositor or native Quit qualification.",
                    "The append is a UI model publication, not a collector live-ingestion test. No recorded tool, authentication or network request is performed.",
                    "No CPU, memory or latency improvement is established by this harness."]]
            if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
            }
        }
        defer { if !completed { checks.append(["name": "native-flow-completes-after-" + stage, "passed": false]); writeReceipt(false) } }
        check("source-matched-curves-entrypoint", sourceManifest?["entrypoint"] as? String == "SessionCurvesV77Main.swift"
            && sourceManifest?["productionEntryPointReplaced"] as? Bool == true
            && sourceManifest?["copiedAppSourcesModified"] as? Bool == false)
        check("activity-trends-is-presented", store.workspacePresented && store.section == .activity && store.activityMode == .trends)
        check("mcp-call-count-is-three-invocations", projection.totalCounts[.mcpCalls] == 3)
        check("two-dated-mcp-invocations-are-plotted", projection.buckets.reduce(0) { $0 + $1.count(for: .mcpCalls) } == 2)
        check("undated-mcp-invocation-is-counted-without-placement", projection.unplottedCounts[.mcpCalls] == 1)
        let datedEvents = snapshot.events.filter { fixture.datedCallIDs.contains($0.callID ?? "") }
        let undatedEvents = snapshot.events.filter { $0.callID == fixture.undatedCallID }
        let plottedIDs = Set(projection.buckets.flatMap { projection.eventIDs(for: .mcpCalls, in: $0.id) })
        check("mcp-drilldown-retains-exact-call-and-result-source-ids", plottedIDs == Set(datedEvents.map(\.id)))
        check("undated-drilldown-retains-exact-source-ids", Set(projection.unplottedEventIDs(for: .mcpCalls)) == Set(undatedEvents.map(\.id)))
        check("missing-date-coverage-retains-call-and-result", Set(projection.excludedTimestampEventIDs).isSuperset(of: Set(undatedEvents.map(\.id)))
            && undatedEvents.count == 2)
        check("partial-record-coverage-is-preserved", snapshot.coverage.contains { $0.category == "ligne partielle" }
            && projection.coverage == snapshot.coverage)
        check("failed-mcp-result-remains-an-error", snapshot.events.contains { $0.callID == fixture.failedCallID && $0.isError }
            && projection.totalCounts[.errors, default: 0] > 0)
        check("known-wait-is-counted", projection.totalCounts[.waits, default: 0] > 0)
        check("requested-file-changes-are-retained", projection.totalCounts[.requestedFileChanges, default: 0] > 0)
        check("chart-storage-is-bounded-to-240-intervals", projection.buckets.count <= 240)

        store.trendMetric = .mcpCalls; store.trendCumulative = true
        store.trendSelectedDate = bucket.start; store.trendValuesVisible = true
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: MainView().environmentObject(store)
            .environment(\.lensWindowContext, context).environment(\.colorScheme, .light))
        let compactLayout = ProcessInfo.processInfo.environment["LENS_CURVES_COMPACT_LAYOUT"] == "1"
        let initialSize = compactLayout ? NSSize(width: 1024, height: 640) : NSSize(width: 1380, height: 920)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: initialSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.title = "Codex Lens — anonymous session curves qualification"
        window.contentView = host; context.attach(window); window.orderBack(nil)
        host.frame = NSRect(origin: .zero, size: initialSize)
        defer { window.contentView = nil; window.close() }
        try await waitFor(host, "native-curve-table") { valuesTable(in: host)?.numberOfRows == projection.buckets.count }
        if compactLayout { valuesTable(in: host)?.enclosingScrollView?.scrollerStyle = .legacy }
        try await settle(host)
        let selectedRow = projection.buckets.firstIndex { $0.id == bucket.id }!
        try await waitFor(host, "native-initial-table-reveal") {
            valuesTable(in: host).map { $0.selectedRow == selectedRow && rowVisible(selectedRow, in: $0) } ?? false
        }
        observations.append(["scenario": "initial-table-selection", "expectedRow": selectedRow,
            "actualRow": valuesTable(in: host)?.selectedRow ?? -1, "selectedDate": store.trendSelectedDate?.ISO8601Format() ?? "none"])
        if let table = valuesTable(in: host) {
            observations.append(["scenario": "initial-table-viewport", "visibleRect": NSStringFromRect(table.visibleRect),
                "rowRect": NSStringFromRect(table.rect(ofRow: selectedRow)), "documentBounds": NSStringFromRect(table.bounds)])
        }
        check("chart-selection-is-shared-with-native-values-table", valuesTable(in: host)?.selectedRow == selectedRow)
        if let table = valuesTable(in: host), let scroll = table.enclosingScrollView {
            check("initial-chart-selection-is-revealed-in-values-table", rowVisible(selectedRow, in: table))
        }
        if let table = valuesTable(in: host), projection.buckets.count > 1 {
            let row = selectedRow == 0 ? 1 : 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            try await settle(host)
            check("native-values-selection-updates-chart-date", store.trendSelectedDate == projection.buckets[row].start)
        }
        store.trendSelectedDate = bucket.start; try await settle(host)
        if let table = valuesTable(in: host), let scroll = table.enclosingScrollView {
            check("changed-chart-selection-is-revealed-in-values-table", table.selectedRow == selectedRow
                && rowVisible(selectedRow, in: table))
        }
        let identifiers = accessibilityIDs(host)
        observations.append(["scenario": "programmatic-accessibility-tree", "identifiers": identifiers.sorted(),
            "note": "Identifier exposure here does not qualify VoiceOver or system AX automation."])
        renders.append(try capture(host, output.appendingPathComponent("curves-light-component-cache.png")))
        store.trendCumulative = false; try await settle(host)
        renders.append(try capture(host, output.appendingPathComponent("curves-intervals-component-cache.png")))
        store.trendCumulative = true; try await settle(host)
        let appearances: [(ColorScheme, CGFloat, String)] = [(.dark, 1380, "dark"), (.light, 920, "narrow")]
        for (scheme, width, name) in appearances {
            host.rootView = MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, scheme)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 920)); try await settle(host)
            check("\(name)-window-preserves-metric-date-and-panel", store.trendMetric == .mcpCalls && store.trendCumulative
                && store.trendSelectedDate == bucket.start && store.trendValuesVisible)
            check("\(name)-native-values-table-retains-all-intervals", valuesTable(in: host)?.numberOfRows == projection.buckets.count)
            renders.append(try capture(host, output.appendingPathComponent("curves-\(name)-component-cache.png")))
        }

        stage = "interval-navigation-and-back"
        let opening = store.openingIdentity, home = store.observedSourceHome
        store.inspectTrendPeriod(bucket, rootID: fixture.rootID, sourceHome: home, openingID: opening)
        await store.waitForPresentation(); try await settle(host)
        check("selected-interval-opens-chronology-period", store.activityMode == .chronology && store.period == bucket.period
            && store.timelineWindow == bucket.period && store.timelineVisible)
        check("interval-navigation-preserves-agent-filter", store.agentFilter == fixture.rootID)
        store.goBack(); await store.waitForPresentation(); try await settle(host)
        check("back-restores-metric-cumulative-date-and-values-panel", store.activityMode == .trends && store.trendMetric == .mcpCalls
            && store.trendCumulative && store.trendSelectedDate == bucket.start && store.trendValuesVisible)
        check("back-restores-original-activity-filter-period", store.period == nil && store.agentFilter == fixture.rootID)
        if let table = valuesTable(in: host) {
            observations.append(["scenario": "back-table-viewport", "selectedRow": table.selectedRow,
                "visibleRect": NSStringFromRect(table.visibleRect), "rowRect": NSStringFromRect(table.rect(ofRow: selectedRow)),
                "documentBounds": NSStringFromRect(table.bounds)])
        }
        check("back-reveals-restored-selected-table-row", valuesTable(in: host).map {
            $0.selectedRow == selectedRow && rowVisible(selectedRow, in: $0)
        } ?? false)
        guard let event = datedEvents.first(where: { $0.kind == .toolCall }) else { throw LensError.unavailable("MCP invocation unavailable") }
        store.navigate(.event(event.id), newTab: true); try await settle(host)
        check("event-reader-opens-without-replacing-curve-workspace", store.tabContentDestination == .event(event.id) && !store.workspacePresented)
        store.showWorkspace(); await store.waitForPresentation(); try await settle(host)
        check("workspace-return-restores-curve-selection", store.workspacePresented && store.activityMode == .trends
            && store.trendSelectedDate == bucket.start && store.trendMetric == .mcpCalls && store.trendValuesVisible)
        check("reader-return-reveals-restored-selected-table-row", valuesTable(in: host).map {
            $0.selectedRow == selectedRow && rowVisible(selectedRow, in: $0)
        } ?? false)

        stage = "in-memory-model-publication"
        if let table = valuesTable(in: host), let scroll = table.enclosingScrollView {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        var appended = snapshot
        let modelID = "qa-curves-model-publication-only"
        appended.events.append(LensEvent(id: modelID, timestamp: bucket.start.addingTimeInterval(0.125), agentID: fixture.rootID,
            kind: .toolCall, title: "Anonymous in-memory model publication", toolName: "mcp__lens_fixture__lookup", callID: modelID,
            source: SourceRef(path: output.appendingPathComponent("in-memory-metadata-no-journal").path)))
        store.snapshot = appended; await store.waitForPresentation(); try await settle(host)
        check("model-publication-increases-mcp-count-once", store.presentation?.trends.totalCounts[.mcpCalls] == 4)
        check("model-publication-preserves-reading-state", store.trendMetric == .mcpCalls && store.trendCumulative
            && store.trendSelectedDate == bucket.start && store.trendValuesVisible && store.activityMode == .trends)
        check("model-publication-retains-bounded-interval-storage", (store.presentation?.trends.buckets.count ?? 241) <= 240)
        check("model-publication-preserves-manual-table-reading", valuesTable(in: host).map {
            $0.rows(in: $0.visibleRect).location == 0 && $0.selectedRow == selectedRow
        } ?? false)
        let previousWidth = store.presentation?.trends.bucketWidth
        appended.events.append(LensEvent(id: modelID + "-later", timestamp: bucket.end.addingTimeInterval(600), agentID: fixture.rootID,
            kind: .toolCall, title: "Anonymous re-binning model publication", toolName: "mcp__lens_fixture__lookup", callID: modelID + "-later",
            source: SourceRef(path: output.appendingPathComponent("in-memory-metadata-no-journal").path)))
        store.snapshot = appended; await store.waitForPresentation(); try await settle(host)
        check("rebinning-preserves-manual-reading-and-selected-date", store.presentation?.trends.bucketWidth != previousWidth
            && store.trendSelectedDate == bucket.start && valuesTable(in: host).map {
                $0.rows(in: $0.visibleRect).location == 0 && $0.selectedRow > 0
            } == true)
        observations.append(["scenario": "model-publication", "syntheticEventID": modelID,
            "collectorsLiveIngestionQualified": false, "journalsAppendedWhileObserved": false])

        stage = "source-and-root-isolation"
        store.inspectTrendPeriod(bucket, rootID: fixture.rootID, sourceHome: home, openingID: UUID())
        check("foreign-opening-period-command-is-rejected", store.activityMode == .trends && store.period == nil)
        await store.useSessionSource(fixture.alternateHome)
        var observedSourceTransition = false, previousProjectionRetired = false, transitionCommandRejected = false
        let sourceTransition = store.$snapshot.dropFirst().sink { next in
            guard next?.root.id == fixture.rootID, store.observedSourceHome == fixture.alternateHome.standardizedFileURL else { return }
            // @Published emits before snapshot.didSet. Inspect the exact reader
            // transition, before the async replacement projection can publish.
            observedSourceTransition = true
            previousProjectionRetired = store.presentation == nil && store.timelineProjection == nil
            store.inspectTrendPeriod(bucket, rootID: fixture.rootID,
                sourceHome: store.observedSourceHome, openingID: store.openingIdentity)
            transitionCommandRejected = store.activityMode == .trends && store.period == nil
        }
        await store.open(fixture.rootID); sourceTransition.cancel(); await store.waitForPresentation()
        check("same-root-reader-transition-retires-old-projections", observedSourceTransition && previousProjectionRetired)
        check("old-bucket-cannot-dispatch-during-source-transition", observedSourceTransition && transitionCommandRejected)
        store.showSessionPicker = false; store.browseSection(.activity); store.activityMode = .trends
        observations.append(["scenario": "same-thread-new-source", "actualHome": store.observedSourceHome.path,
            "expectedHome": fixture.alternateHome.standardizedFileURL.path, "date": store.trendSelectedDate?.ISO8601Format() ?? "none",
            "metric": store.trendMetric.rawValue, "cumulative": store.trendCumulative, "valuesVisible": store.trendValuesVisible,
            "error": store.error ?? "none"])
        check("same-thread-new-source-resets-curve-selection", store.observedSourceHome == fixture.alternateHome.standardizedFileURL
            && store.trendSelectedDate == nil && store.trendMetric == .toolCalls && !store.trendCumulative && !store.trendValuesVisible)
        store.inspectTrendPeriod(bucket, rootID: fixture.rootID, sourceHome: home, openingID: opening)
        check("old-source-period-command-is-rejected", store.activityMode == .trends && store.period == nil)
        await store.useSessionSource(fixture.home); await store.open(fixture.otherRootID); await store.waitForPresentation()
        store.showSessionPicker = false; store.browseSection(.activity); store.activityMode = .trends
        store.inspectTrendPeriod(bucket, rootID: fixture.rootID, sourceHome: home, openingID: store.openingIdentity)
        check("different-root-resets-selection-and-rejects-old-period", store.snapshot?.root.id == fixture.otherRootID
            && store.trendSelectedDate == nil && store.activityMode == .trends && store.period == nil)
        check("anonymous-journals-and-worktree-files-are-unchanged", fixture.sourcesUnchanged())
        writeReceipt(true); completed = true
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else {
            throw LensError.unavailable("One or more curve assertions failed; inspect the retained receipt.")
        }
    }

    private static func argument(_ name: String) throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else {
            throw LensError.unavailable("Missing " + name)
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    /// Horizontal scrolling is intentional. A revealed row must still have
    /// its entire height visible, not merely intersect the viewport.
    @MainActor private static func rowVisible(_ row: Int, in table: NSTableView) -> Bool {
        let rect = table.rect(ofRow: row), visible = table.visibleRect
        return !table.isHiddenOrHasHiddenAncestor && rect.height > 0 && visible.width > 0
            && visible.minY <= rect.minY && visible.maxY >= rect.maxY
    }
    @MainActor private static func valuesTable(in host: NSView) -> NSTableView? {
        descendants(host).compactMap { $0 as? NSTableView }.first {
            let titles = Set($0.tableColumns.map { $0.headerCell.title })
            return !$0.isHiddenOrHasHiddenAncestor && Set([LensL10n.text("Période"), LensL10n.text("Par intervalle"), LensL10n.text("Cumul")]).isSubset(of: titles)
        }
    }
    @MainActor private static func accessibilityIDs(_ host: NSView) -> Set<String> {
        var result = Set<String>(), seen = Set<ObjectIdentifier>()
        func walk(_ node: Any, depth: Int) {
            guard depth < 40, seen.count < 10_000, let element = node as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            if let id = element.accessibilityIdentifier(), !id.isEmpty { result.insert(id) }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0); return result
    }
    @MainActor private static func settle(_ host: NSView) async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor private static func waitFor(_ host: NSView, _ next: String, _ predicate: () -> Bool) async throws {
        stage = next
        for _ in 0..<500 { host.layoutSubtreeIfNeeded(); if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        if let output = diagnosticOutput {
            let tables = descendants(host).compactMap { $0 as? NSTableView }.map { table -> [String: Any] in
                let selected = (0..<table.numberOfRows).contains(table.selectedRow) ? table.rect(ofRow: table.selectedRow) : nil
                let visible = table.visibleRect, scroll = table.enclosingScrollView
                var ancestors: [[String: String]] = [], node = table.superview
                while let view = node, ancestors.count < 16 {
                    ancestors.append(["class": String(describing: type(of: view)), "frame": NSStringFromRect(view.frame),
                        "bounds": NSStringFromRect(view.bounds), "visibleRect": NSStringFromRect(view.visibleRect)])
                    node = view.superview
                }
                return ["class": String(describing: type(of: table)), "headers": table.tableColumns.map { $0.headerCell.title },
                 "rows": table.numberOfRows, "frame": NSStringFromRect(table.frame), "bounds": NSStringFromRect(table.bounds),
                 "visibleRect": NSStringFromRect(table.visibleRect), "selectedRow": table.selectedRow,
                 "selectedRowRect": selected.map(NSStringFromRect) ?? "none", "ancestors": ancestors,
                 "selectedHeightVisible": selected.map { visible.minY <= $0.minY && visible.maxY >= $0.maxY } ?? false,
                 "selectedWidthVisible": selected.map { visible.minX <= $0.minX && visible.maxX >= $0.maxX } ?? false,
                 "clipBounds": table.enclosingScrollView.map { NSStringFromRect($0.contentView.bounds) } ?? "none",
                 "documentVisibleRect": scroll.map { NSStringFromRect($0.contentView.documentVisibleRect) } ?? "none",
                 "headerFrame": table.headerView.map { NSStringFromRect($0.frame) } ?? "none",
                 "scrollerStyle": scroll?.scrollerStyle.rawValue ?? -1,
                 "contentInsets": scroll.map { "\($0.contentInsets)" } ?? "none",
                 "hidden": table.isHiddenOrHasHiddenAncestor]
            }
            let diagnostics: [String: Any] = ["stage": stage, "tables": tables,
                "selectedDate": diagnosticStore?.trendSelectedDate?.ISO8601Format() ?? "none",
                "activityMode": diagnosticStore?.activityMode.rawValue ?? "none",
                "isProjecting": diagnosticStore?.isProjecting ?? false,
                "views": descendants(host).prefix(80).map { ["class": String(describing: type(of: $0)), "frame": NSStringFromRect($0.frame), "hidden": $0.isHiddenOrHasHiddenAncestor] }]
            try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("phase.json"))
            _ = try? capture(host, output.appendingPathComponent("failed-curves-layout-component-cache.png"))
        }
        throw LensError.unavailable("Curve layout did not reach stage: " + next)
    }
    @MainActor private static func capture(_ host: NSView, _ path: URL) throws -> String {
        host.layoutSubtreeIfNeeded()
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: path); return path.lastPathComponent
    }
}

private final class CurvesFixtureV77 {
    let home: URL, alternateHome: URL, rootID: String, otherRootID: String
    let datedCallIDs: Set<String>, undatedCallID: String, failedCallID: String
    private var hashes: [URL: String] = [:]
    init(corpus: URL) throws {
        let manager = FileManager.default, root = corpus.resolvingSymlinksInPath().path
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard root.hasPrefix(temporary), manager.fileExists(atPath: corpus.appendingPathComponent("ANONYMOUS_FIXTURE").path),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any],
              manifest["anonymous"] as? Bool == true, let id = manifest["rootID"] as? String,
              let other = manifest["otherRootID"] as? String, let home = manifest["home"] as? String,
              let cases = manifest["curvesCases"] as? [String: Any], let alternate = cases["alternateHome"] as? String,
              let dated = cases["datedMCPCallIDs"] as? [String], let undated = cases["undatedMCPCallID"] as? String,
              let failed = cases["failedMCPCallID"] as? String, let alternateLog = cases["alternateRootRollout"] as? String,
              let trees = manifest["worktrees"] as? [String: String], let rollouts = manifest["rollouts"] as? [String: [String: Any]] else {
            throw LensError.unavailable("An anonymous v77 curve corpus is required.")
        }
        self.home = URL(fileURLWithPath: home); alternateHome = URL(fileURLWithPath: alternate)
        rootID = id; otherRootID = other; datedCallIDs = Set(dated); undatedCallID = undated; failedCallID = failed
        let paths = rollouts.values.compactMap { $0["path"] as? String } + [alternateLog]
            + trees.values.flatMap { tree in ["src/Same.swift", "src/Origin.swift", "src/Partial.swift"].map { tree + "/" + $0 } }
        guard [self.home, alternateHome].allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(root + "/") }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        for record in rollouts.values {
            guard let path = record["path"] as? String, let expected = record["sha256"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root + "/"),
                  Self.digest(try Data(contentsOf: URL(fileURLWithPath: path))) == expected else {
                throw LensError.unavailable("Anonymous journal no longer matches its generated manifest.")
            }
        }
        for path in paths {
            let source = URL(fileURLWithPath: path)
            // Deleted-worktree fixtures deliberately have no file to inspect.
            // Foundation does not canonicalize their missing suffix as it does
            // existing /private/tmp aliases. Guard every file we actually read.
            guard manager.fileExists(atPath: source.path) else { continue }
            guard source.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            hashes[source] = Self.digest(try Data(contentsOf: source))
        }
        guard hashes[URL(fileURLWithPath: alternateLog)] == cases["alternateRootSHA256"] as? String else {
            throw LensError.unavailable("Alternative source no longer matches its generated manifest.")
        }
    }
    func sourcesUnchanged() -> Bool { hashes.allSatisfy { source, expected in (try? Data(contentsOf: source)).map { Self.digest($0) == expected } ?? false } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
