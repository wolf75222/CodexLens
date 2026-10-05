import AppKit
import SwiftUI
import LensCore
import CryptoKit

/// Owned native window, anonymous corpus, no global events or model requests.
@main struct TimelineZoomV60Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await qualify() } catch { fputs("Zoom v60: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
    @MainActor private static func qualify() async throws {
        func argument(_ key: String) throws -> String {
            guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { throw CocoaError(.fileReadUnknown) }
            return CommandLine.arguments[i + 1]
        }
        let output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any]
        guard manifest?["anonymous"] as? Bool == true, let home = manifest?["home"] as? String, let rootID = manifest?["rootID"] as? String else { throw CocoaError(.fileReadUnknown) }
        let sourceHome = URL(fileURLWithPath: home)
        let beforeHashes = try hashes(sourceHome)
        var checks: [[String: Any]] = [], stages: [[String: Any]] = [], renders: [String] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let store = LensStore(sourceHome: sourceHome, investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")), cacheDirectory: output.appendingPathComponent("cache"))
        store.setNavigationScope(UUID().uuidString)
        await store.start(); await store.open(rootID); await store.waitForPresentation()
        store.showSessionPicker = false; store.resetFilters(); store.browseSection(.activity)
        store.inspectorVisible = false; store.chatVisible = false
        LensL10n.language = .fr
        let host = NSHostingView(rootView: MainView().environmentObject(store))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Codex Lens — anonymous zoom qualification"; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close(); store.stopObserving() }
        await settle(host); store.resetTimelineExtent(); await settle(host)
        guard let canvas = descendants(host).compactMap({ $0 as? TimelineCanvas }).first,
              let scroll = canvas.enclosingScrollView, let projection = store.timelineProjection,
              let fullGeometry = canvas.geometry, let selected = store.events.first?.id else { throw CocoaError(.fileReadUnknown) }
        store.navigate(.event(selected)); await settle(host)
        store.resetTimelineExtent(); await settle(host)
        let originalSelection = store.selection, originalPeriod = store.period
        let initial = try unwrap(canvas.densityPlan(for: 0))
        let signature = initial.clusters.map { "\($0.id):\($0.count)" }
        check("dense-corpus-has-overview-groups-and-full-list", !initial.clusters.isEmpty && projection.eventCount > 12_000 && store.events.count > 12_000)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await settle(host)
            let name = dark ? "overview-dark.png" : "overview-light.png"
            try capture(host, path: output.appendingPathComponent(name)); renders.append(name)
        }
        for cycle in 0..<3 {
            var depth = 0
            while depth < 8, let clusters = canvas.densityPlan(for: 0)?.clusters, !clusters.isEmpty {
                let group = clusters[depth == 0 ? clusters.count / 2 : 0]
                let queries = canvas.densityQueryCount
                canvas.focusCluster(group); await settle(host)
                depth += 1
                let plan = try unwrap(canvas.densityPlan(for: 0))
                stages.append(["cycle": cycle, "depth": depth, "zoom": store.timelineZoom,
                               "clusters": plan.clusters.count, "details": plan.details.count,
                               "matches": plan.totalMatches, "cacheBytes": canvas.densityCacheBytes])
                check("cycle-\(cycle)-depth-\(depth)-focus-preserves-global-axis", canvas.geometry?.window == fullGeometry.window && store.timelineWindow == (fullGeometry.window.start...fullGeometry.window.end))
                check("cycle-\(cycle)-depth-\(depth)-can-dezoom", store.timelineZoom > 1 && canvas.canAdjustTimelineZoom(.decrease))
                check("cycle-\(cycle)-depth-\(depth)-density-cache-invalidates", canvas.densityQueryCount > queries && canvas.densityCacheBytes <= 2 * 1024 * 1024)
                check("cycle-\(cycle)-depth-\(depth)-selection-and-filter-stay", store.selection == originalSelection && canvas.selectedID == selected && store.period == originalPeriod)
                if plan.clusters.isEmpty { break }
            }
            let detail = try unwrap(canvas.densityPlan(for: 0))
            check("cycle-\(cycle)-groups-progressively-reveal-details", depth > 1 && detail.clusters.isEmpty && !detail.details.isEmpty)
            let detailIDs = detail.details.map(\.id)
            let detailZoom = store.timelineZoom
            if cycle == 0 {
                let name = "focused-light.png"; window.appearance = NSAppearance(named: .aqua); await settle(host)
                try capture(host, path: output.appendingPathComponent(name)); renders.append(name)
                store.goBack(); await settle(host)
                check("back-restores-previous-scale-without-changing-selection", store.timelineZoom < detailZoom && store.selection == originalSelection)
                store.goForward(); await settle(host)
                check("forward-restores-details-limit-and-origin", store.timelineZoom == detailZoom && canvas.densityPlan(for: 0)?.details.map(\.id) == detailIDs)
            }
            // The same handler is used by zoom commands and keyboard routing.
            var steps = 0
            while canvas.canAdjustTimelineZoom(.decrease), steps < 160 {
                canvas.adjustTimelineZoom(.decrease); steps += 1
            }
            await settle(host)
            let restored = try unwrap(canvas.densityPlan(for: 0))
            check("cycle-\(cycle)-dezoom-reforms-identical-groups", store.timelineZoom == 1 && restored.clusters.map { "\($0.id):\($0.count)" } == signature && restored.totalMatches == initial.totalMatches)
            check("cycle-\(cycle)-dezoom-preserves-all-events", store.timelineProjection?.eventCount == projection.eventCount && store.selection == originalSelection)
        }
        // Slider binding updates use the same original extent and invalidate density.
        let group = try unwrap(canvas.densityPlan(for: 0)?.clusters.first)
        canvas.focusCluster(group); await settle(host)
        store.timelineZoom = 1; await settle(host)
        check("slider-to-minimum-restores-overview-groups", canvas.densityPlan(for: 0)?.clusters.map { "\($0.id):\($0.count)" } == signature)
        canvas.focusCluster(group); await settle(host)
        _ = canvas.onZoomStep?(1 / store.timelineZoom); await settle(host)
        check("pinch-shared-handler-restores-overview-groups", store.timelineZoom == 1 && canvas.densityPlan(for: 0)?.clusters.map { "\($0.id):\($0.count)" } == signature)
        let q = canvas.densityQueryCount
        for _ in 0..<50 { _ = canvas.densityPlan(for: 0) }
        check("stable-viewport-reuses-density-plan", canvas.densityQueryCount == q)
        window.setContentSize(NSSize(width: 1000, height: 700)); await settle(host)
        check("resize-retains-global-axis-selection-and-grouping", canvas.geometry?.window == fullGeometry.window && store.selection == originalSelection && canvas.densityPlan(for: 0)?.clusters.isEmpty == false)
        store.focusTimelineEvent(selected, zoom: true); await settle(host)
        check("single-event-focus-remains-dezoomable", store.timelineZoom > 1 && canvas.canAdjustTimelineZoom(.decrease))
        store.resetTimelineExtent(); await settle(host)
        check("overview-reset-keeps-selection-and-restores-standard-limit", store.timelineZoom == 1 && store.timelineZoomLimit == 80 && store.selection == originalSelection)
        // Paused live inspection uses a viewing period, separate from the clock
        // preference. A sub-10-second group must allow finer zoom, then regroup.
        store.enableLiveTimeline(at: fullGeometry.window.end)
        store.inspectLiveWindow(fullGeometry.window); await settle(host)
        guard let liveCanvas = descendants(host).compactMap({ $0 as? TimelineCanvas }).first,
              let liveClusters = liveCanvas.densityPlan(for: 0)?.clusters, !liveClusters.isEmpty else { throw CocoaError(.fileReadUnknown) }
        liveCanvas.focusCluster(liveClusters[liveClusters.count / 2]); await settle(host)
        for _ in 0..<4 where (store.liveState.window?.duration ?? 0) >= 10 {
            guard let groups = liveCanvas.densityPlan(for: 0)?.clusters, !groups.isEmpty else { break }
            liveCanvas.focusCluster(groups[groups.count / 2]); await settle(host)
        }
        let focusedLiveSpan = try unwrap(store.liveState.window).duration
        check("live-group-focus-pauses-only-visual-following", !store.liveState.following && store.selection == originalSelection)
        check("live-group-finer-than-clock-preference", focusedLiveSpan < 10 && focusedLiveSpan > 0.001)
        check("live-fine-group-allows-further-zoom", liveCanvas.canAdjustTimelineZoom(.increase))
        _ = liveCanvas.onZoomStep?(2); await settle(host)
        check("live-zoom-in-refines-instead-of-jumping-to-ten-seconds", abs((store.liveState.window?.duration ?? 0) - focusedLiveSpan / 2) < 0.00001)
        let spanBeforeOut = try unwrap(store.liveState.window).duration
        _ = liveCanvas.onZoomStep?(0.5); await settle(host)
        check("live-dezoom-expands-the-inspected-period", abs((store.liveState.window?.duration ?? 0) - spanBeforeOut * 2) < 0.00001)
        _ = liveCanvas.onZoomStep?(focusedLiveSpan / fullGeometry.window.duration); await settle(host)
        check("live-dezoom-reforms-groups", liveCanvas.densityPlan(for: 0)?.clusters.isEmpty == false && store.selection == originalSelection)
        check("live-inspection-keeps-indexed-events", store.timelineProjection?.eventCount == projection.eventCount)
        store.disableLiveTimeline(); await settle(host)
        guard let publicationCanvas = descendants(host).compactMap({ $0 as? TimelineCanvas }).first else { throw CocoaError(.fileReadUnknown) }
        let allCount = store.events.count
        var append = try unwrap(store.snapshot)
        let newDate = fullGeometry.window.start.addingTimeInterval(fullGeometry.window.duration / 2)
        append.events.append(LensEvent(id: "v60-injected-event", timestamp: newDate, agentID: rootID, kind: .assistant, title: "Anonymous append", source: SourceRef(path: "anonymous-memory-only.jsonl")))
        store.snapshot = append; await store.waitForPresentation(); await settle(host)
        check("incremental-publication-keeps-selection-and-refreshes-count", store.events.count == allCount + 1 && store.selection == originalSelection && publicationCanvas.densityPlan(for: 0)?.totalMatches == initial.totalMatches + 1)
        let other = SessionSnapshot(root: SessionSummary(id: "v60-other-root", title: "Other anonymous root"), events: [LensEvent(id: "v60-other", timestamp: newDate, agentID: "v60-other-root", kind: .user, source: SourceRef(path: "anonymous-memory-only.jsonl"))])
        store.snapshot = other; await store.waitForPresentation(); await settle(host)
        check("root-switch-clears-focused-zoom-limit", store.timelineZoom == 1 && store.timelineZoomLimit == 80 && publicationCanvas.projection?.eventCount == 1)
        check("source-journals-unchanged", try hashes(sourceHome) == beforeHashes)
        store.stopObserving(); await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "stages": stages, "renders": renders,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched owned native MainView, TimelineCanvas and Coordinator; anonymous read-only corpus; OS network deny by launcher.",
            "unqualified": ["Component-cache PNGs are not compositor screenshots. Physical pinch/keyboard event delivery and VoiceOver are not qualified by direct handler calls.", "No new Instruments measurement or FPS/speedup claim; density cache budget and invalidation are checked."]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    private static func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw CocoaError(.fileReadUnknown) }; return value }
    private static func hashes(_ directory: URL) throws -> [String: String] {
        guard let paths = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { throw CocoaError(.fileReadUnknown) }
        var result: [String: String] = [:]
        for case let path as URL in paths where path.pathExtension == "jsonl" {
            result[path.path] = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) async {
        for _ in 0..<10 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    }
    @MainActor private static func capture(_ view: NSView, path: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: path)
    }
}
