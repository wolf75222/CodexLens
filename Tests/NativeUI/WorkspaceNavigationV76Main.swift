import AppKit
import CryptoKit
import Darwin
import Foundation
import LensCore
import SwiftUI

/// Programmatic production-store and AppKit remount checks on disposable histories.
/// No observed command, authentication request, or inference is performed.
@main struct WorkspaceNavigationV76Main {
    @MainActor private static var stage = "fixture-and-store-setup"
    @MainActor private static var lastDiagnostics: [String: Any] = [:]
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify(); NSApp.terminate(nil) }
            catch {
                fputs("Workspace navigation qualification: \(error)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output"), corpus = try argument("--corpus")
        let fixture = try WorkspaceFixtureV76(corpus: corpus)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        UserDefaults.standard.setVolatileDomain([
            "lensLanguage": "en", "lensReduceMotionOverride": true,
            "lensControlAccent": "lens", "lensTabMaterial": "system"
        ], forName: UserDefaults.argumentDomain)
        LensL10n.language = .en
        LensGuideCoordinator.shared.onboarding.dismiss()
        let pool = SessionReaderPool(), cache = output.appendingPathComponent("cache")
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: cache, readerPool: pool)
        store.setNavigationScope(UUID().uuidString)
        await store.start(); await store.open(fixture.rootID); await store.waitForPresentation()
        defer { store.stopObserving() }
        store.showSessionPicker = false; store.inspectorVisible = false; store.chatVisible = false
        store.browseSection(.activity); store.timelineVisible = true
        store.agentFilter = fixture.rootID; store.kindFilter = .assistant
        await store.waitForPresentation()
        guard store.events.count > 150 else {
            throw LensError.unavailable("Workspace qualification needs an anonymous corpus with more than 150 main-agent assistant events.")
        }
        let original = store.events[3], other = store.events[6], third = store.events[9]
        let a = Destination.event(original.id), b = Destination.event(other.id), c = Destination.event(third.id)
        var checks: [[String: Any]] = [], observations: [[String: Any]] = [], renders: [String] = []
        var completed = false
        defer {
            if !completed {
                checks.append(["name": "native-flow-completes-after-" + stage, "passed": false])
                let partial: [String: Any] = ["checks": checks, "observations": observations, "renders": renders,
                    "allExecutedChecksPassed": false, "completed": false, "failedStage": stage,
                    "diagnostics": lastDiagnostics,
                    "scope": "Partial source-matched native workspace checks; a harness/layout failure interrupted later scenarios.",
                    "unqualified": ["An interrupted flow is not a passed qualification. Programmatic AppKit/cache renders do not qualify production compositor or physical gestures."]]
                if let bytes = try? JSONSerialization.data(withJSONObject: partial, options: [.prettyPrinted, .sortedKeys]) {
                    try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
                }
            }
        }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        check("source-matched-workspace-entrypoint", manifest?["entrypoint"] as? String == "WorkspaceNavigationV76Main.swift"
            && manifest?["productionEntryPointReplaced"] as? Bool == true
            && manifest?["copiedAppSourcesModified"] as? Bool == false)
        try await waitUntil(store: store, stage: "initial-timeline-projection") { store.timelineProjection != nil }

        // Exercise the pre-layout notification ordering without relying on
        // one WindowServer's timing when remounting the SwiftUI hierarchy.
        let pendingScroll = TimelineScrollView(frame: .zero)
        pendingScroll.documentView = TimelineCanvas(frame: .zero)
        let pendingCoordinator = TimelineView.Coordinator()
        pendingCoordinator.attach(pendingScroll, store: store)
        store.timelineZoom = 19.6; store.timelineOrigin = CGPoint(x: 1600, y: 0)
        pendingCoordinator.configure(store: store)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: pendingScroll.contentView)
        check("pre-layout-notification-cannot-overwrite-saved-timeline-origin", store.timelineOrigin.x == 1600)
        pendingScroll.setFrameSize(NSSize(width: 1000, height: 180))
        pendingCoordinator.configure(store: store)
        store.timelineOrigin = CGPoint(x: 1200, y: 0); store.timelineReset &+= 1
        pendingScroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: pendingScroll.contentView)
        check("pending-restoration-notification-cannot-overwrite-saved-timeline-origin", store.timelineOrigin.x == 1200)
        pendingCoordinator.configure(store: store)
        check("pending-restoration-applies-saved-origin-to-native-clip", abs(pendingScroll.contentView.bounds.origin.x - 1200) < 1)
        pendingScroll.contentView.scroll(to: CGPoint(x: 1300, y: 0))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: pendingScroll.contentView)
        check("configured-user-scroll-updates-timeline-origin", abs(store.timelineOrigin.x - 1300) < 1)
        pendingCoordinator.detach()

        for style: NSScroller.Style in [.overlay, .legacy] {
            let label = style == .legacy ? "legacy" : "overlay"
            func makeScroll(width: CGFloat) -> TimelineScrollView {
                let scroll = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 180))
                scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
                scroll.scrollerStyle = style; scroll.documentView = TimelineCanvas(frame: .zero)
                return scroll
            }
            func settleScroll(_ scroll: NSScrollView) async throws {
                var previousSize: NSSize?, stableLayouts = 0
                for _ in 0..<500 {
                    // AppKit can deliver the initial preferred-style update
                    // after construction. Apply this fixture's requested mode
                    // and wait for its actual style AND geometry, rather than
                    // taking a baseline after a fixed number of sleeps.
                    if scroll.scrollerStyle != style { scroll.scrollerStyle = style; stableLayouts = 0 }
                    scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
                    let size = scroll.contentSize
                    let geometry = (scroll.documentView as? TimelineCanvas)?.geometry
                    let coherent = scroll.scrollerStyle == style && geometry.map {
                        abs($0.contentWidth - Double(max(500, size.width)) * store.timelineZoom) < 0.001
                    } == true && distance(scroll.contentView.bounds.origin, store.timelineOrigin) < 0.001
                    stableLayouts = coherent && previousSize == size ? stableLayouts + 1 : 0
                    if stableLayouts >= 8 { return }
                    previousSize = size
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                throw LensError.unavailable("Scroller fixture did not reach coherent " + label + " layout")
            }
            var scroll = makeScroll(width: 1000), coordinator = TimelineView.Coordinator()
            store.timelineOrigin = CGPoint(x: 1600, y: 0); store.timelinePosition = nil; store.timelineReset &+= 1
            coordinator.attach(scroll, store: store); coordinator.configure(store: store)
            try await settleScroll(scroll)
            let expectedOrigin = store.timelineOrigin
            let expectedMidpoint = try require(store.timelinePosition?.midpoint, "qualified timeline midpoint")
            check("timeline-uses-requested-scroller-style-" + label, scroll.scrollerStyle == style)
            observations.append(["scenario": "baseline-remount-" + label, "origin": NSStringFromPoint(expectedOrigin),
                "clipSize": NSStringFromSize(scroll.contentSize),
                "geometryWidth": (scroll.documentView as? TimelineCanvas)?.geometry?.contentWidth ?? 0,
                "requestedScrollerStyle": label, "actualScrollerStyle": scroll.scrollerStyle == .legacy ? "legacy" : "overlay"])
            for iteration in 1...5 {
                coordinator.detach()
                // A new reader first lays out wider, then gains a scroller or
                // settles its split pane. Returning to the same final width
                // must never compound a new interpretation of saved pixels.
                scroll = makeScroll(width: 1017); coordinator = TimelineView.Coordinator()
                coordinator.attach(scroll, store: store); coordinator.configure(store: store)
                try await settleScroll(scroll)
                scroll.setFrameSize(NSSize(width: 1000, height: 180))
                try await settleScroll(scroll)
                check("repeated-remount-retains-time-place-" + label + "-" + String(iteration),
                    distance(store.timelineOrigin, expectedOrigin) < 1
                    && distance(scroll.contentView.bounds.origin, expectedOrigin) < 1
                    && abs((store.timelinePosition?.midpoint ?? .distantPast).timeIntervalSince(expectedMidpoint)) < 0.000001)
            }
            observations.append(["scenario": "repeated-remount-" + label, "expectedOrigin": NSStringFromPoint(expectedOrigin),
                "actualOrigin": NSStringFromPoint(store.timelineOrigin), "clipSize": NSStringFromSize(scroll.contentSize),
                "geometryWidth": (scroll.documentView as? TimelineCanvas)?.geometry?.contentWidth ?? 0,
                "requestedScrollerStyle": label, "actualScrollerStyle": scroll.scrollerStyle == .legacy ? "legacy" : "overlay",
                "remounts": 5])
            let geometryBeforeZoom = try require((scroll.documentView as? TimelineCanvas)?.geometry, "pre-zoom geometry")
            let focalX: CGFloat = 220
            let focalDate = geometryBeforeZoom.date(atX: Double(store.timelineOrigin.x + focalX), clamped: false)
            let zoomApplied = coordinator.changeZoom(factor: 1.1, focalViewportX: focalX)
            let geometryAfterZoom = try require((scroll.documentView as? TimelineCanvas)?.geometry, "post-zoom geometry")
            let zoomedOrigin = store.timelineOrigin
            for _ in 0..<5 { coordinator.configure(store: store) }
            check("noncentral-anchored-zoom-does-not-jump-on-reconfigure-" + label, zoomApplied
                && distance(store.timelineOrigin, zoomedOrigin) < 1
                && abs(CGFloat(geometryAfterZoom.x(for: focalDate)) - zoomedOrigin.x - focalX) < 1)
            let canvas = try require(scroll.documentView as? TimelineCanvas, "timeline canvas for edge focus")
            for (edge, id) in [("first", store.timelineProjection?.orderedEventIDs.first),
                               ("last", store.timelineProjection?.orderedEventIDs.last)] {
                canvas.reveal(try require(id, "edge event"), centered: true)
                let origin = scroll.contentView.bounds.origin
                check("centered-edge-event-stays-inside-timeline-" + label + "-" + edge,
                    origin.x >= 0 && origin.y >= 0
                    && origin.x <= max(0, canvas.bounds.width - scroll.contentView.bounds.width)
                    && origin.y <= max(0, canvas.bounds.height - scroll.contentView.bounds.height))
            }
            coordinator.detach()
            store.timelineZoom = 19.6
        }

        store.navigate(a)
        check("ordinary-collection-selection-creates-no-reader", store.tabs.isEmpty && store.workspacePresented
            && store.selection == a && store.tabContentDestination == nil)
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: MainView().environmentObject(store)
            .environment(\.lensWindowContext, context).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1380, height: 920),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Codex Lens — anonymous workspace qualification"
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1380, height: 920)
        context.attach(window); window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        try await waitFor(host, store: store, stage: "initial-activity-table") { eventTable(in: host)?.numberOfRows == store.events.count }
        store.timelineFocus = nil; store.timelineZoom = 19.6
        store.timelineOrigin = CGPoint(x: 1600, y: 0); store.timelineReset &+= 1
        try await settle(host)
        guard let table = eventTable(in: host), let scroll = table.enclosingScrollView else {
            throw LensError.unavailable("The production Activity table was not materialized.")
        }
        let row = min(120, table.numberOfRows - 2)
        let point = CGPoint(x: 0, y: table.rect(ofRow: row).minY + 7)
        scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        let baseline = try viewport(in: host, store: store)
        let timelineOrigin = store.timelineOrigin, timelineZoom = store.timelineZoom
        func timelineGeometry(_ scenario: String) -> Bool {
            guard let timeline = descendants(host).compactMap({ $0 as? TimelineScrollView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
                  let canvas = timeline.documentView as? TimelineCanvas else { return false }
            let clip = timeline.contentView, visible = canvas.visibleRect.intersection(canvas.bounds)
            let actualLeft = canvas.convert(visible.origin, to: timeline)
            let expectedLeft = clip.convert(clip.bounds.origin, to: timeline)
            let laneLabel = canvas.convert(NSPoint(x: visible.minX + 12, y: visible.minY), to: host)
            let expectedLabel = clip.convert(NSPoint(x: clip.bounds.minX + 12, y: clip.bounds.minY), to: host)
            observations.append(["scenario": scenario, "method": "Native coordinate conversions before cacheDisplay",
                "scrollFrame": NSStringFromRect(timeline.frame), "scrollBounds": NSStringFromRect(timeline.bounds),
                "clipFrame": NSStringFromRect(clip.frame), "clipBounds": NSStringFromRect(clip.bounds),
                "canvasFrame": NSStringFromRect(canvas.frame), "canvasBounds": NSStringFromRect(canvas.bounds),
                "canvasVisibleRect": NSStringFromRect(visible), "visibleLeftInScroll": NSStringFromPoint(actualLeft),
                "clipLeftInScroll": NSStringFromPoint(expectedLeft), "laneLabelInHost": NSStringFromPoint(laneLabel),
                "expectedLaneLabelInHost": NSStringFromPoint(expectedLabel), "scrollInHost": NSStringFromRect(timeline.convert(timeline.bounds, to: host)),
                "parentBounds": NSStringFromRect(timeline.superview?.bounds ?? .zero)])
            return !visible.isEmpty && abs(actualLeft.x - expectedLeft.x) < 1
                && abs(visible.width - clip.bounds.width) < 1 && abs(laneLabel.x - expectedLabel.x) < 1
        }
        check("initial-timeline-render-covers-native-viewport", timelineGeometry("before-reader-rendered-geometry"))
        func temporalReceipt(_ scenario: String) -> [String: Any] {
            var result: [String: Any] = ["scenario": scenario, "expectedZoom": timelineZoom, "actualZoom": store.timelineZoom,
             "expectedOrigin": NSStringFromPoint(timelineOrigin), "actualOrigin": NSStringFromPoint(store.timelineOrigin)]
            if let scroll = descendants(host).compactMap({ $0 as? TimelineScrollView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) {
                result["clipSize"] = NSStringFromSize(scroll.contentSize)
                result["scrollerStyle"] = scroll.scrollerStyle == .legacy ? "legacy" : "overlay"
                result["geometryWidth"] = (scroll.documentView as? TimelineCanvas)?.geometry?.contentWidth
            }
            return result
        }
        check("native-list-is-scrolled-away-from-selected-message", baseline.origin.y > 1000
            && baseline.anchorID != original.id && store.selection == a)
        check("native-list-publishes-lightweight-anchor", store.eventListViewport(calls: false).map {
            $0.anchorID == baseline.anchorID && abs($0.anchorOffset - baseline.offset) < 1
        } == true)
        let retainedListViewport = store.eventListViewport(calls: false)
        store.recordEventListViewport(LensEventListViewport(rootID: "anonymous-other-root", anchorID: "unrelated",
            anchorOffset: 0, origin: CGPoint(x: 900_000, y: 900_000)), calls: false)
        check("foreign-root-viewport-cannot-replace-browsing-place", store.eventListViewport(calls: false) == retainedListViewport)
        store.recordEventListViewport(LensEventListViewport(rootID: fixture.rootID, anchorID: "unrelated",
            anchorOffset: 0, origin: CGPoint(x: 900_000, y: 900_000), sourceHome: "/anonymous/other-source"), calls: false)
        check("foreign-source-viewport-cannot-replace-browsing-place", store.eventListViewport(calls: false) == retainedListViewport)
        check("temporal-viewport-is-not-default-before-opening", abs(timelineZoom - 19.6) < 0.001
            && timelineOrigin.x > 100)
        observations.append(baseline.receipt("before-reader"))
        observations.append(temporalReceipt("before-reader-temporal"))
        let baselineCount = store.events.count
        renders.append(try capture(host, path: output.appendingPathComponent("component-cache-workspace-before-reader.png")))

        store.navigate(a, newTab: true)
        try await waitFor(host, store: store, stage: "same-target-reader-opens") { store.tabContentDestination == a && eventTable(in: host) == nil }
        let aTab = try require(store.tabs.first { $0.destination == a }, "same-target reader tab")
        check("same-target-open-preserves-one-explicit-reader", store.tabs.count == 1
            && store.activeTab == aTab.id && !store.workspacePresented && store.hasWorkspaceReturn
            && store.workspaceSection == .activity && store.canGoBack)
        store.goBack()
        try await waitFor(host, store: store, stage: "back-remounts-activity") { store.workspacePresented && eventTable(in: host) != nil }
        try await settle(host)
        check("same-target-back-restores-browsing-selection-and-filters", store.selection == a
            && store.agentFilter == fixture.rootID && store.kindFilter == .assistant
            && store.workspaceSection == .activity && !store.isTabPresented(aTab))
        check("back-restores-native-list-anchor-and-offset", try viewport(in: host, store: store).matches(baseline))
        check("back-restores-time-zoom-and-pan", abs(store.timelineZoom - timelineZoom) < 0.001
            && distance(store.timelineOrigin, timelineOrigin) < 1)
        check("back-timeline-render-covers-native-viewport-without-left-gap", timelineGeometry("after-back-rendered-geometry"))
        observations.append(try viewport(in: host, store: store).receipt("after-back"))
        observations.append(temporalReceipt("after-back-temporal"))
        renders.append(try capture(host, path: output.appendingPathComponent("component-cache-workspace-after-back.png")))
        store.goForward()
        try await waitFor(host, store: store, stage: "forward-restores-reader") { store.tabContentDestination == a }
        check("forward-reopens-same-reader-without-duplicate", store.tabs.count == 1
            && store.activeTab == aTab.id && store.isTabPresented(aTab))
        store.showWorkspace()
        try await waitFor(host, store: store, stage: "workspace-button-remounts-activity") { store.workspacePresented && eventTable(in: host) != nil }
        try await settle(host)
        let returnedViewport = try viewport(in: host, store: store)
        check("workspace-return-restores-native-list-place", store.selection == a
            && returnedViewport.matches(baseline))
        check("workspace-return-restores-time-place", abs(store.timelineZoom - timelineZoom) < 0.001
            && distance(store.timelineOrigin, timelineOrigin) < 1)
        check("workspace-return-timeline-render-covers-native-viewport-without-left-gap", timelineGeometry("after-workspace-return-rendered-geometry"))
        observations.append(temporalReceipt("after-workspace-return-temporal"))
        for route in ["workspace", "back"] {
            store.navigate(a, newTab: true)
            store.kindFilter = .toolCall
            store.query = "anonymous-workspace-qualification-with-no-matching-event"
            await store.waitForPresentation()
            check("reader-filter-projection-is-different-before-" + route, store.events.isEmpty
                && store.kindFilter == .toolCall && !store.query.isEmpty)
            if route == "workspace" { store.showWorkspace() } else { store.goBack() }
            try await waitFor(host, store: store, stage: "changed-filter-projection-" + route) {
                store.workspacePresented && store.query.isEmpty && store.kindFilter == .assistant
                    && store.events.count == baselineCount && eventTable(in: host)?.numberOfRows == baselineCount
            }
            try await settle(host)
            let returned = try viewport(in: host, store: store)
            check("changed-reader-filters-restore-original-workspace-filters-" + route,
                store.agentFilter == fixture.rootID && store.kindFilter == .assistant && store.query.isEmpty && store.selection == a)
            check("changed-reader-filters-retain-native-list-anchor-after-projection-" + route, returned.matches(baseline))
            check("changed-reader-filters-retain-time-zoom-and-pan-" + route,
                abs(store.timelineZoom - timelineZoom) < 0.001 && distance(store.timelineOrigin, timelineOrigin) < 1)
            observations.append(returned.receipt("after-filter-projection-" + route))
            observations.append(temporalReceipt("after-filter-projection-temporal-" + route))
        }
        check("keyboard-tab-cycle-enabled-with-one-reader", context.canCycleTabs)
        context.cycleTab(forward: true)
        check("keyboard-tab-cycle-enters-single-reader", store.tabContentDestination == a && store.activeTab == aTab.id)
        context.cycleTab(forward: true)
        check("keyboard-tab-cycle-returns-to-workspace", store.workspacePresented && store.selection == a)

        store.navigate(b, newTab: true)
        let bTab = try require(store.tabs.first { $0.destination == b }, "second reader")
        let immutableReaders = signature(store)
        store.showWorkspace(); store.navigate(c)
        await store.waitForPresentation(); try await settle(host)
        check("ordinary-selection-does-not-create-or-overwrite-readers", store.workspacePresented
            && store.selection == c && signature(store) == immutableReaders && store.tabs.count == 2)
        check("ordinary-selection-does-not-mark-a-reader-selected", store.tabs.allSatisfy { !store.isTabPresented($0) })
        store.selectTab(aTab)
        check("select-exact-reader-retains-other-destinations", store.selection == a
            && store.activeTab == aTab.id && store.tabContentDestination == a && signature(store) == immutableReaders)
        store.closeTab(bTab.id)
        check("closing-inactive-reader-leaves-active-reader", store.tabs.count == 1
            && store.activeTab == aTab.id && store.tabContentDestination == a)
        context.closeTabOrWindow()
        try await waitFor(host, store: store, stage: "last-reader-close-remounts-activity") { store.workspacePresented && eventTable(in: host) != nil }
        check("closing-last-reader-restores-latest-workspace-selection", store.tabs.isEmpty
            && store.activeTab == nil && store.selection == c && store.agentFilter == fixture.rootID
            && store.kindFilter == .assistant)
        check("close-command-on-presented-reader-keeps-session-window", store.isObserving && window.isVisible)
        store.navigate(a, newTab: true); store.navigate(b, newTab: true)
        let active = try require(store.tabs.first { $0.id == store.activeTab }, "active close-order tab")
        store.closeTab(active.id)
        check("closing-active-reader-selects-a-surviving-reader", store.tabs.count == 1
            && store.tabs.contains { $0.id == store.activeTab && $0.destination == store.selection }
            && !store.workspacePresented)
        store.closeTab(try require(store.activeTab, "last active reader"))
        check("second-last-close-does-not-clear-browsing-selection", store.workspacePresented && store.selection == c)

        if let agent = store.snapshot?.agents.first(where: { $0.id != fixture.rootID }) {
            store.browseSection(.agents); store.navigate(.agent(agent.id))
            check("ordinary-agent-selection-creates-no-reader", store.workspacePresented && store.tabs.isEmpty)
            store.navigate(.agent(agent.id), newTab: true)
            check("explicit-agent-reader-retains-agent-workspace", store.tabContentDestination == .agent(agent.id)
                && store.workspaceSection == .agents && store.hasWorkspaceReturn)
            store.showWorkspace()
            check("agent-workspace-return-preserves-selected-agent", store.workspacePresented
                && store.section == .agents && store.selection == .agent(agent.id))
            for id in store.tabs.map(\.id) { store.closeTab(id) }
        } else { check("anonymous-corpus-has-descendant-agent", false) }

        if let first = fixture.worktrees["alpha"], let second = fixture.worktrees["beta"] {
            let one = Destination.file(environment: first, path: first + "/src/Same.swift")
            let two = Destination.file(environment: second, path: second + "/src/Same.swift")
            store.navigate(one, newTab: true); store.navigate(two, newTab: true)
            check("same-relative-file-in-two-worktrees-keeps-distinct-readers", store.tabs.count == 2
                && store.tabs.contains { $0.destination == one } && store.tabs.contains { $0.destination == two })
            for id in store.tabs.map(\.id) { store.closeTab(id) }
        } else { check("anonymous-corpus-has-two-worktrees", false) }

        store.browseSection(.activity); store.navigate(a)
        let inspected = try TimelineWindow(start: original.timestamp.addingTimeInterval(-30),
                                           end: original.timestamp.addingTimeInterval(30))
        store.enableLiveTimeline(at: original.timestamp); store.setLiveSpan(60, at: original.timestamp)
        store.inspectLiveWindow(inspected)
        let pausedLive = store.liveState
        store.navigate(a, newTab: true)
        let previewOriginTab = try require(store.tabs.first { $0.destination == a }, "live-preview origin reader")
        let beforePreview = signature(store)
        store.previewLiveEvent(other.id)
        check("live-preview-over-reader-keeps-original-reader-destination", store.livePreview == b
            && store.selection == b && signature(store) == beforePreview)
        context.closeTabOrWindow()
        check("close-preview-command-returns-to-origin-reader", store.livePreview == nil
            && store.selection == a && store.activeTab == previewOriginTab.id
            && store.tabContentDestination == a && !store.workspacePresented && signature(store) == beforePreview)
        store.previewLiveEvent(other.id); store.showWorkspace(); store.selectTab(previewOriginTab)
        check("preview-selection-does-not-poison-reader-checkpoint", store.selection == a
            && store.tabContentDestination == a && store.livePreview == nil && signature(store) == beforePreview)
        store.previewLiveEvent(other.id); store.closeTab(previewOriginTab.id)
        check("closing-background-reader-keeps-live-preview", store.tabs.isEmpty && store.livePreview == b
            && store.selection == b && store.liveTimelineVisible)
        store.closeLivePreview()
        check("closing-preview-with-deleted-origin-returns-workspace-without-reopening-tab", store.workspacePresented
            && store.livePreview == nil && store.tabs.isEmpty && store.selection == a)
        store.navigate(a, newTab: true); store.showWorkspace()
        check("reader-return-keeps-paused-live-window-and-follow-state", store.liveTimelineVisible
            && !store.follow && store.liveState == pausedLive && !store.liveState.following)
        for id in store.tabs.map(\.id) { store.closeTab(id) }
        store.disableLiveTimeline()

        let coordinator = LensApplicationCoordinator.shared
        let previousWindowHandler = coordinator.newWindowHandler
        var requestedWindow: UUID?
        coordinator.newWindowHandler = { requestedWindow = $0 }
        defer { coordinator.newWindowHandler = previousWindowHandler }
        let sourceSelection = store.selection, sourceTabs = signature(store), sourceFilters = (store.agentFilter, store.kindFilter)
        let requested = coordinator.openInNewWindow(destination: b, from: store)
        let requestID = try require(requestedWindow, "captured window request")
        let seed = try require(coordinator.pendingWindowSeed(for: requestID), "captured window seed")
        check("new-window-request-captures-clicked-destination-and-source", requested && seed.destination == b
            && seed.rootID == fixture.rootID && seed.sourceHome.standardizedFileURL == fixture.home.standardizedFileURL
            && seed.sourceWindowID == store.windowIdentity)
        check("new-window-request-keeps-source-workspace-unchanged", store.selection == sourceSelection
            && signature(store) == sourceTabs && store.agentFilter == sourceFilters.0 && store.kindFilter == sourceFilters.1)
        let peer = LensStore(sourceHome: seed.sourceHome, investigationArchive: seed.investigationArchive,
            cacheDirectory: seed.cacheDirectory, readerPool: seed.readerPool)
        peer.setNavigationScope(UUID().uuidString)
        let peerContext = LensWindowContext(store: peer, sceneRequestID: requestID)
        defer { withExtendedLifetime(peerContext) {} }
        await peer.start()
        coordinator.acceptPendingSession(in: peerContext)
        try await waitUntil(store: peer, stage: "coordinator-seed-acceptance") { peer.snapshot?.root.id == fixture.rootID && peer.tabContentDestination == b && !peer.busy }
        defer { peer.stopObserving() }
        peer.showSessionPicker = false; peer.chatVisible = false; peer.inspectorVisible = false
        let peerSelection = peer.selection, peerScope = peer.windowIdentity
        check("actual-coordinator-acceptance-opens-the-captured-message", peerSelection == b
            && peer.tabContentDestination == b && peer.tabs.count == 1
            && (coordinator.pendingWindowSeed(for: requestID).map { _ in false } ?? true))
        check("new-window-keeps-captured-reader-pool", seed.readerPool === store.windowReaderPool
            && peer.windowReaderPool === store.windowReaderPool)
        check("new-window-has-independent-window-scope", peerScope != store.windowIdentity)
        check("new-window-has-exact-independent-selection", peerSelection == b)
        check("new-window-stores-share-source-engine", peer.engine === store.engine)
        check("two-window-stores-share-only-source-reader", peer.engine === store.engine
            && peerScope != store.windowIdentity && peerSelection == b)
        observations.append(["scenario": "new-window-reader-keys", "sharedPool": peer.windowReaderPool === store.windowReaderPool,
            "sharedEngine": peer.engine === store.engine, "sourceScope": store.windowIdentity, "peerScope": peerScope,
            "sourceHome": store.observedSourceHome.path, "peerHome": peer.observedSourceHome.path,
            "sourceCache": store.windowCacheDirectory?.path ?? "default", "seedCache": seed.cacheDirectory?.path ?? "default",
            "peerCache": peer.windowCacheDirectory?.path ?? "default", "peerSelection": String(describing: peerSelection)])
        let peerTabs = signature(peer), peerZoom = peer.timelineZoom
        store.navigate(a, newTab: true)
        check("first-window-navigation-does-not-change-peer-reader", peer.selection == peerSelection
            && peer.tabContentDestination == b && signature(peer) == peerTabs && peer.timelineZoom == peerZoom)
        store.stopObserving()
        let detail = try await peer.engine.detail(for: other)
        check("closing-one-store-leaves-peer-source-read-valid", peer.isObserving && peer.hasSessionReader
            && peer.selection == peerSelection && !detail.raw.isEmpty)
        peer.stopObserving(); await peer.investigation.flushAndStop(); await store.investigation.flushAndStop()
        check("anonymous-journals-and-worktree-files-are-unchanged", fixture.sourcesUnchanged())

        let receipt: [String: Any] = [
            "checks": checks, "observations": observations,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "renders": renders,
            "scope": "Actual production LensStore/MainView in one accessory AppKit window, anonymous local histories, native NSTableView/NSClipView viewport before reader and after remount, model history/close/agent/worktree/live checks, actual new-window coordinator seed acceptance and two stores sharing a SessionReaderPool. No source writes or AI calls.",
            "fixture": ["anonymous": true, "rootID": fixture.rootID, "observedSourcesModified": false],
            "unqualified": ["Programmatic AppKit checks do not qualify physical clicks, trackpad gestures, VoiceOver or the production compositor. Saved PNGs are NSHostingView bitmap-cache renders, not production compositor screenshots.", "New-window seed acceptance uses the actual coordinator with a captured window-handler callback; actual SwiftUI scene launch is tested separately, without another Dock instance here.", "No restart-persistent scroll restoration, complete reader text-selection retention, broad performance or RAM improvement is established by this harness."]
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        completed = true
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else {
            throw LensError.unavailable("One or more workspace assertions failed; inspect the retained receipt.")
        }
    }

    private static func argument(_ name: String) throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else {
            throw LensError.unavailable("Missing " + name)
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + name) }; return value
    }
    @MainActor private static func signature(_ store: LensStore) -> [String] {
        store.tabs.map { "\($0.id.uuidString)|\($0.destination)|\($0.pinned)" }
    }
    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        max(abs(first.x - second.x), abs(first.y - second.y))
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor private static func eventTable(in host: NSView) -> NSTableView? {
        descendants(host).compactMap { $0 as? NSTableView }.first {
            !($0 is NSOutlineView) && !$0.isHiddenOrHasHiddenAncestor
                && $0.tableColumns.contains { $0.identifier.rawValue == "event" }
        }
    }
    @MainActor private static func capture(_ host: NSView, path: URL) throws -> String {
        host.layoutSubtreeIfNeeded()
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: path)
        return path.lastPathComponent
    }
    @MainActor private static func settle(_ host: NSView) async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor private static func waitFor(_ host: NSView, store: LensStore, stage: String, _ predicate: () -> Bool) async throws {
        self.stage = stage
        for _ in 0..<500 {
            host.layoutSubtreeIfNeeded()
            if predicate() { lastDiagnostics = diagnostics(host, store: store); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        lastDiagnostics = diagnostics(host, store: store)
        throw LensError.unavailable("Workspace layout did not reach stage: " + stage)
    }
    @MainActor private static func waitUntil(store: LensStore, stage: String, _ predicate: () -> Bool) async throws {
        self.stage = stage
        for _ in 0..<500 {
            if predicate() { lastDiagnostics = diagnostics(nil, store: store); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        lastDiagnostics = diagnostics(nil, store: store)
        throw LensError.unavailable("New-window coordinator did not reach stage: " + stage)
    }
    @MainActor private static func diagnostics(_ host: NSView?, store: LensStore) -> [String: Any] {
        let views = host.map(descendants) ?? []
        return ["stage": stage, "rootID": store.snapshot?.root.id ?? "missing",
            "presentationRootID": store.presentation?.rootID ?? "missing", "section": store.section.rawValue,
            "selection": String(describing: store.selection), "workspacePresented": store.workspacePresented,
            "tabContent": String(describing: store.tabContentDestination), "activeTab": store.activeTab?.uuidString ?? "none",
            "events": store.events.count, "query": store.query, "kindFilter": String(describing: store.kindFilter),
            "timelineZoom": store.timelineZoom, "timelineOrigin": NSStringFromPoint(store.timelineOrigin),
            "timelineReset": store.timelineReset,
            "tables": views.compactMap { $0 as? NSTableView }.map { table in
                ["class": String(describing: type(of: table)), "columns": table.tableColumns.map { $0.identifier.rawValue },
                 "rows": table.numberOfRows, "frame": NSStringFromRect(table.frame),
                 "hidden": table.isHiddenOrHasHiddenAncestor, "clipOrigin": NSStringFromPoint(table.enclosingScrollView?.contentView.bounds.origin ?? .zero)] as [String: Any]
            },
            "hierarchy": views.prefix(64).map { view in
                ["class": String(describing: type(of: view)), "frame": NSStringFromRect(view.frame),
                 "hidden": view.isHiddenOrHasHiddenAncestor] as [String: Any]
            }]
    }
    private struct ViewportV76 {
        let anchorID: String
        let offset: CGFloat
        let origin: CGPoint
        func matches(_ other: Self) -> Bool { anchorID == other.anchorID && abs(offset - other.offset) < 1 }
        func receipt(_ scenario: String) -> [String: Any] {
            ["scenario": scenario, "anchorID": anchorID, "offset": Double(offset),
             "originX": Double(origin.x), "originY": Double(origin.y)]
        }
    }
    @MainActor private static func viewport(in host: NSView, store: LensStore) throws -> ViewportV76 {
        guard let table = eventTable(in: host), let scroll = table.enclosingScrollView else {
            throw LensError.unavailable("Activity list is not displayed")
        }
        let origin = scroll.contentView.bounds.origin
        let row = table.row(at: NSPoint(x: 2, y: origin.y + 1))
        guard store.events.indices.contains(row) else { throw LensError.unavailable("Activity viewport has no event anchor") }
        return ViewportV76(anchorID: store.events[row].id, offset: origin.y - table.rect(ofRow: row).minY, origin: origin)
    }
}

private final class WorkspaceFixtureV76 {
    let home: URL, rootID: String
    let worktrees: [String: String]
    private var hashes: [URL: String] = [:]
    init(corpus: URL) throws {
        let manager = FileManager.default, root = corpus.resolvingSymlinksInPath().path
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard root.hasPrefix(temporaryRoot), manager.fileExists(atPath: corpus.appendingPathComponent("ANONYMOUS_FIXTURE").path),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any],
              manifest["anonymous"] as? Bool == true, let id = manifest["rootID"] as? String,
              let home = manifest["home"] as? String, let trees = manifest["worktrees"] as? [String: String],
              let rollouts = manifest["rollouts"] as? [String: [String: Any]] else {
            throw LensError.unavailable("An anonymous local corpus is required")
        }
        self.home = URL(fileURLWithPath: home); rootID = id; worktrees = trees
        guard self.home.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
        for record in rollouts.values {
            guard let path = record["path"] as? String else { throw CocoaError(.fileReadUnknown) }
            let source = URL(fileURLWithPath: path)
            guard source.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            hashes[source] = Self.digest(try Data(contentsOf: source))
        }
        for path in trees.values {
            let directory = URL(fileURLWithPath: path)
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            for name in ["src/Same.swift", "src/Origin.swift"] {
                let source = directory.appendingPathComponent(name)
                if manager.fileExists(atPath: source.path) { hashes[source] = Self.digest(try Data(contentsOf: source)) }
            }
        }
    }
    func sourcesUnchanged() -> Bool {
        hashes.allSatisfy { source, expected in (try? Data(contentsOf: source)).map { Self.digest($0) == expected } ?? false }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
