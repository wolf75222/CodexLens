import Foundation
import SwiftUI
import AppKit
import LensCore

@main struct TimelineDensityV39Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() } catch { fputs("Timeline qualification: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
    @MainActor private static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output") else { throw CocoaError(.fileNoSuchFile) }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        LensL10n.language = .fr; UserDefaults.standard.set("lens", forKey: "lensControlAccent")
        var checks: [[String: Any]] = [], renders: [String] = [], timings: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let epoch = Date(timeIntervalSince1970: 1_790_784_000)
        func geometry(_ lo: Double, _ hi: Double, width: Double = 1040) throws -> TimelineGeometry {
            try TimelineGeometry(window: TimelineWindow(start: epoch.addingTimeInterval(lo), end: epoch.addingTimeInterval(hi)), contentWidth: width, minimumTimeSpan: 0.001)
        }
        var events: [LensEvent] = []
        for i in 0..<12_014 {
            let offset = Double(i) / 100
            events.append(LensEvent(id: "event-\(i)", timestamp: epoch.addingTimeInterval(offset), endTime: epoch.addingTimeInterval(offset + 0.008),
                agentID: "alpha", kind: i % 500 == 0 ? .error : .toolCall, title: "Recorded call \(i)", source: SourceRef(path: "anonymous.jsonl", offset: UInt64(i), line: i + 1)))
        }
        for i in 0..<29 {
            events.append(LensEvent(id: "child-\(i)", timestamp: epoch.addingTimeInterval(Double(i) / 10), agentID: "beta", kind: .assistant,
                title: "Recorded message", source: SourceRef(path: "anonymous-child.jsonl", offset: UInt64(i), line: i + 1)))
        }
        let agents = [AgentRecord(id: "alpha", name: "Session principale"), AgentRecord(id: "beta", parentID: "alpha", name: "/root/beta-reader", relation: .subagent)]
        let projection = try await Task.detached { try TimelineProjection.prepare(events: events, agents: agents) }.value
        let overview = try geometry(0, 600)
        let size = NSSize(width: 1040, height: 280)
        let current = TimelineCanvas(frame: NSRect(origin: .zero, size: size))
        current.projection = projection; current.geometry = overview
        current.eventLookup = { id in events.first { $0.id == id } }
        let before = TimelineCanvasV38Baseline(frame: current.frame)
        before.projection = projection; before.geometry = overview; before.eventLookup = current.eventLookup
        let plan = try unwrap(current.densityPlan(for: 0))
        check("dense-root-count-exact", plan.totalMatches == 12014 && projection.eventCount == 12043)
        check("overview-draws-groups-not-thousands-of-bars", !plan.clusters.isEmpty && plan.clusters.count + plan.details.count < 32)
        check("agent-lanes-stay-distinct", current.densityPlan(for: 1)?.totalMatches == 29)
        for dark in [false, true] {
            for (name, view) in [("before-overview", before as NSView), ("after-overview", current as NSView)] {
                let filename = name + (dark ? "-dark.png" : "-light.png")
                try capture(view, dark: dark, path: output.appendingPathComponent(filename)); renders.append(filename)
            }
        }
        var focused: ClosedRange<Date>?
        current.onFocusRange = { focused = $0 }
        let cluster = try unwrap(plan.clusters.first)
        let point = NSPoint(x: (overview.x(for: cluster.window.start) + overview.x(for: cluster.window.end)) / 2,
                            y: overview.rulerHeight + overview.barInset + overview.barHeight / 2)
        check("hit-testing-resolves-visible-group", current.densityCluster(at: point)?.id == cluster.id)
        let window = NSWindow(contentRect: current.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = current
        defer { window.contentView = nil; window.close() }
        let eventPoint = current.convert(point, to: nil)
        guard let click = NSEvent.mouseEvent(with: .leftMouseUp, location: eventPoint, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw CocoaError(.fileWriteUnknown) }
        current.mouseUp(with: click)
        check("native-local-click-zooms-group-period", focused.map { $0.lowerBound < cluster.window.start && $0.upperBound > cluster.window.end } == true)
        guard let right = NSEvent.mouseEvent(with: .rightMouseDown, location: eventPoint, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1) else { throw CocoaError(.fileWriteUnknown) }
        let menu = try unwrap(current.menu(for: right))
        check("group-menu-has-zoom-and-period-actions", menu.items.first?.title == "Zoomer sur ce groupe" && menu.items.dropFirst().first?.title == "Afficher cette période dans la liste")
        check("group-menu-bounds-event-samples", menu.items.count <= 8)
        var listRange: ClosedRange<Date>?
        current.onRange = { listRange = $0 }
        if let action = menu.items[1].action { _ = NSApp.sendAction(action, to: menu.items[1].target, from: menu.items[1]) }
        check("period-menu-preserves-recorded-window", listRange == (cluster.window.start...cluster.window.end))
        let ax = current.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        check("visible-groups-have-accessible-elements", !ax.isEmpty && ax.count <= 512 && ax.first?.accessibilityRole() == .button)
        focused = nil
        check("accessible-group-press-zooms", ax.first?.accessibilityPerformPress() == true && focused != nil)
        let queries = current.densityQueryCount
        for _ in 0..<25 { _ = current.densityPlan(for: 0) }
        check("viewport-cache-reuses-prepared-plan", current.densityQueryCount == queries && current.densityCacheHits >= 25 && current.densityCacheBytes < 2 * 1024 * 1024)
        current.selectedID = "event-6000"; current.updateAccessibilitySelection()
        _ = current.densityPlan(for: 0)
        check("selection-keeps-density-plan", current.densityQueryCount == queries && current.selectedID == "event-6000")
        check("grouped-selected-event-is-accessible", (current.accessibilityChildren() as? [NSAccessibilityElement] ?? []).contains { $0.accessibilityLabel()?.contains("Recorded call 6000") == true })
        current.geometry = try geometry(60, 60.03)
        let detail = try unwrap(current.densityPlan(for: 0))
        check("zoom-reveals-individual-actions", detail.clusters.isEmpty && !detail.details.isEmpty && detail.details.contains { $0.id == "event-6000" })
        check("zoom-invalidates-viewport-cache", current.densityQueryCount > queries)
        for dark in [false, true] {
            let filename = "after-detail" + (dark ? "-dark.png" : "-light.png")
            try capture(current, dark: dark, path: output.appendingPathComponent(filename)); renders.append(filename)
        }
        var selected: String?
        current.onSelect = { selected = $0 }
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124) else { throw CocoaError(.fileWriteUnknown) }
        current.keyDown(with: key)
        check("keyboard-navigates-original-event-identities", selected == "event-6001" && current.selectedID == selected)
        let extra = LensEvent(id: "new-live-event", timestamp: epoch.addingTimeInterval(60.005), agentID: "alpha", kind: .toolCall, source: SourceRef(path: "anonymous.jsonl", offset: 20000))
        let updated = try await Task.detached { try TimelineProjection.prepare(events: events + [extra], agents: agents) }.value
        let oldAX = current.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let q = current.densityQueryCount
        current.projection = updated
        let appendPlan = current.densityPlan(for: 0)
        check("live-append-invalidates-counts-without-losing-selection", current.densityQueryCount > q && appendPlan?.totalMatches == detail.totalMatches + 1 && current.selectedID == "event-6001")
        check("stale-accessibility-action-does-not-open-other-projection", oldAX.first?.accessibilityPerformPress() == false)
        current.projection = projection; current.geometry = overview; current.selectedID = nil
        let narrow = try geometry(0, 600, width: 520)
        current.frame.size.width = 520; current.geometry = narrow
        check("resize-keeps-all-counts", current.densityPlan(for: 0)?.totalMatches == 12014)
        try capture(current, dark: false, path: output.appendingPathComponent("after-narrow-light.png")); renders.append("after-narrow-light.png")
        current.frame.size = size; current.geometry = overview
        LensL10n.language = .en; current.configureAccessibility()
        check("group-actions-localized", LensL10n.text("Zoomer sur ce groupe") == "Zoom into this group" && current.accessibilityLabel() == "Event timeline by agent")
        LensL10n.language = .fr
        let stressEvents = (0..<100_000).map { i in LensEvent(id: "stress-\(i)", timestamp: epoch.addingTimeInterval(Double(i) / 100), agentID: "alpha", kind: .toolCall, source: SourceRef(path: "stress.jsonl", offset: UInt64(i))) }
        let stress = try await Task.detached { try TimelineProjection.prepare(events: stressEvents, agents: agents) }.value
        for (count, model, g) in [(12014, projection, overview), (100000, stress, try geometry(0, 1000))] {
            current.projection = model; current.geometry = g; before.projection = model; before.geometry = g
            let result = try unwrap(current.densityPlan(for: 0))
            check("stress-\(count)-all-indexed", result.totalMatches == count && result.clusters.count < 32 && result.details.count < 32)
            for (label, view) in [("build38-baseline", before as NSView), ("build39-density", current as NSView)] {
                let ms = try drawSamples(view, repetitions: 21)
                timings.append(["scenario": "overview-\(count)", "renderer": label, "samplesMs": ms, "medianMs": ms.sorted()[ms.count / 2], "p95Ms": ms.sorted()[Int(Double(ms.count - 1) * 0.95)], "method": "Same offscreen native bitmap caching, Release with symbols; first draw warmed separately; not compositor FPS."])
            }
        }
        let workspace = try await qualifyWorkspace(output: output)
        checks += workspace.checks; renders += workspace.renders
        let receipt: [String: Any] = ["checks": checks, "renders": renders, "timings": timings, "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched native timeline and ActivityView, local NSEvent invocation, anonymous sessions only, network denied by launcher. Existing exact build38 renderer used as comparison.",
            "unqualified": ["Production compositor, physical gestures and VoiceOver session require interactive inspection; component renders do not establish those results.", "Instruments capture requires the repository script's 750 MiB trace headroom; available disk is below that guard."]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    private static func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw CocoaError(.fileReadUnknown) }; return value }
    @MainActor private static func drawSamples(_ view: NSView, repetitions: Int) throws -> [Double] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return (0..<repetitions).map { _ in
            let start = ContinuousClock.now; view.cacheDisplay(in: view.bounds, to: bitmap)
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }
    }
    @MainActor private static func capture(_ view: NSView, dark: Bool, path: URL) throws {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: path)
    }
    @MainActor private static func settle(_ view: NSView) async {
        for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    }
    @MainActor private static func qualifyWorkspace(output: URL) async throws -> (checks: [[String: Any]], renders: [String]) {
        guard let i = CommandLine.arguments.firstIndex(of: "--corpus") else { throw CocoaError(.fileNoSuchFile) }
        let corpus = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any]
        guard fixture?["anonymous"] as? Bool == true, let home = fixture?["home"] as? String, let id = fixture?["rootID"] as? String else { throw CocoaError(.fileReadUnknown) }
        let store = LensStore(sourceHome: URL(fileURLWithPath: home), investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")), cacheDirectory: output.appendingPathComponent("cache"))
        store.setNavigationScope(UUID().uuidString); await store.start(); await store.open(id); await store.waitForPresentation()
        store.showSessionPicker = false; store.resetFilters(); store.browseSection(.activity); store.inspectorVisible = false; store.chatVisible = false
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, .light))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close(); store.stopObserving() }
        await settle(host); store.resetTimelineExtent(); await settle(host)
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        guard let canvas = descendants(host).compactMap({ $0 as? TimelineCanvas }).first, let selected = store.events.first?.id else { throw CocoaError(.fileReadUnknown) }
        store.navigate(.event(selected)); await settle(host); store.resetTimelineExtent(); await settle(host)
        let selection = store.selection, full = store.timelineWindow, filter = store.period
        guard let cluster = canvas.densityPlan(for: 0)?.clusters.first else { throw CocoaError(.fileReadUnknown) }
        canvas.focusCluster(cluster); await settle(host)
        let zoomed = store.timelineWindow, focusedZoom = store.timelineZoom
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        check("workspace-group-zoom-retains-shared-selection-and-filter", zoomed == full && focusedZoom > 1 && selection == store.selection && filter == store.period && canvas.selectedID == selected)
        store.goBack(); await settle(host)
        check("workspace-back-restores-full-axis", store.timelineWindow == full && store.timelineZoom == 1 && store.selection == selection)
        store.goForward(); await settle(host)
        check("workspace-forward-restores-group-axis", store.timelineWindow == zoomed && store.timelineZoom == focusedZoom && store.selection == selection)
        store.resetTimelineExtent(); await settle(host)
        let table = descendants(host).compactMap { $0 as? NSTableView }.first { $0.numberOfRows > 10000 }
        check("workspace-full-list-retains-events", table?.numberOfRows == store.events.count && store.events.count > 12000)
        if let scroll = canvas.enclosingScrollView {
            let baseline = TimelineCanvasV38Baseline(frame: canvas.frame)
            baseline.projection = canvas.projection; baseline.geometry = canvas.geometry; baseline.selectedID = canvas.selectedID; baseline.eventLookup = canvas.eventLookup
            scroll.documentView = baseline
            try capture(host, dark: false, path: output.appendingPathComponent("workspace-before-light.png"))
            scroll.documentView = canvas
        }
        try capture(host, dark: false, path: output.appendingPathComponent("workspace-after-light.png"))
        await store.investigation.flushAndStop()
        return (checks, ["workspace-before-light.png", "workspace-after-light.png"])
    }
}

@MainActor final class TimelineCanvasV38Baseline: NSView, LensTimelineZoomTarget {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var projection: TimelineProjection?
    var geometry: TimelineGeometry?
    var selectedID: String?
    var eventLookup: ((String) -> LensEvent?)?
    var onSelect: ((String) -> Void)?
    var onFocus: ((String) -> Void)?
    var onZoomStep: ((Double) -> Void)?
    var onZoomCommand: ((LensZoomAction) -> Void)?
    var canZoomCommand: ((LensZoomAction) -> Bool)?
    func canAdjustTimelineZoom(_ action: LensZoomAction) -> Bool { canZoomCommand?(action) == true }
    func adjustTimelineZoom(_ action: LensZoomAction) { if canAdjustTimelineZoom(action) { onZoomCommand?(action) } }
    var onRange: ((ClosedRange<Date>) -> Void)?
    var onInvestigate: ((String) -> Void)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var tracking: NSTrackingArea?
    private var hoverID: String?
    private let renderLimit = 4000
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configureAccessibility() }
    required init?(coder: NSCoder) { super.init(coder: coder); configureAccessibility() }
    private var accessibilityLanguage: String?
    func configureAccessibility() {
        let language = LensL10n.resolvedLanguage.rawValue
        guard accessibilityLanguage != language else { return }
        accessibilityLanguage = language
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(LensL10n.text("Chronologie des événements par agent"))
        setAccessibilityHelp(LensL10n.text("Utiliser les flèches pour sélectionner un événement, Début et Fin pour les extrémités. La liste détaillée donne accès à tous les événements et à leur contexte."))
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: LensL10n.text("Événement précédent"), handler: { [weak self] in self?.moveSelection(step: -1) ?? false }),
            NSAccessibilityCustomAction(name: LensL10n.text("Événement suivant"), handler: { [weak self] in self?.moveSelection(step: 1) ?? false }),
            NSAccessibilityCustomAction(name: LensL10n.text("Agrandir la chronologie"), handler: { [weak self] in self?.adjustTimelineZoom(.increase); return self?.onZoomCommand != nil }),
            NSAccessibilityCustomAction(name: LensL10n.text("Réduire la chronologie"), handler: { [weak self] in self?.adjustTimelineZoom(.decrease); return self?.onZoomCommand != nil }),
            NSAccessibilityCustomAction(name: LensL10n.text("Cadrer l’événement sélectionné"), handler: { [weak self] in
                guard let self, let id = self.selectedID else { return false }; self.onFocus?(id); return self.onFocus != nil
            })
        ])
    }
    func updateAccessibilitySelection() {
        if let selectedID, let event = eventLookup?(selectedID) {
            setAccessibilityValue(LensL10n.text("{0} · {1}", String(describing: event.title), String(describing: event.timestamp.lensFormatted(date: .abbreviated, time: .standard))))
        } else { setAccessibilityValue(LensL10n.text("Aucun événement sélectionné")) }
    }
    private func color(_ item: TimelineItem) -> NSColor {
        LensBrand.eventNSColor(item.isError ? .error : item.kind)
    }
    private func nativeRect(_ item: TimelineItem, geometry: TimelineGeometry) -> NSRect {
        let rect = geometry.rect(for: item)
        return NSRect(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.intersection(bounds).fill()
        guard let projection, let geometry else {
            (LensL10n.text("Préparation de la chronologie…") as NSString).draw(at: NSPoint(x: 16, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { return }
        let labelWidth = CGFloat(geometry.labelWidth), rulerHeight = CGFloat(geometry.rulerHeight), laneHeight = CGFloat(geometry.laneHeight)
        let plot = NSRect(x: visible.minX + labelWidth, y: visible.minY, width: max(0, visible.width - labelWidth), height: visible.height)
        guard plot.width > 0, let queryWindow = try? geometry.window(forXRange: Double(plot.minX)...Double(plot.maxX)) else { return }
        drawRuler(geometry: geometry, visible: visible, plot: plot, dirtyRect: dirtyRect)
        let firstLane = max(0, Int(floor((visible.minY - rulerHeight) / laneHeight)))
        let lastLane = min(projection.lanes.count - 1, Int(floor((visible.maxY - rulerHeight) / laneHeight)))
        guard firstLane <= lastLane else { return }
        var remaining = renderLimit
        for laneIndex in firstLane...lastLane {
            let lane = projection.lanes[laneIndex]
            let row = NSRect(x: visible.minX, y: rulerHeight + CGFloat(laneIndex) * laneHeight, width: visible.width, height: laneHeight)
            guard row.intersects(dirtyRect) else { continue }
            if laneIndex % 2 == 0 { NSColor.alternatingContentBackgroundColors[0].withAlphaComponent(0.25).setFill(); row.fill() }
            let result = projection.visible(lane: laneIndex, window: queryWindow, limit: min(1500, remaining))
            remaining -= result.items.count
            let plotClip = plot.intersection(row).intersection(dirtyRect).intersection(bounds)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: plotClip).addClip()
            for item in result.items { draw(item, geometry: geometry, clip: plotClip) }
            var omitted = result.omittedCount
            if let selectedID, let selected = projection.item(id: selectedID), selected.laneIndex == laneIndex,
               selected.overlap(with: queryWindow) != nil, !result.items.contains(where: { $0.id == selectedID }) {
                draw(selected, geometry: geometry, clip: plotClip); omitted = max(0, omitted - 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            if omitted > 0 {
                let message = LensL10n.text("+{0} événements · liste complète ci-dessous", String(describing: omitted))
                (message as NSString).draw(in: NSRect(x: plot.minX + 8, y: row.maxY - 15, width: max(0, plot.width - 16), height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            }
            NSColor.windowBackgroundColor.setFill(); NSRect(x: visible.minX, y: row.minY, width: labelWidth - 5, height: laneHeight).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (lane.name as NSString).draw(in: NSRect(x: visible.minX + 12, y: row.minY + 10, width: labelWidth - 22, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            let status = !lane.agentIsCatalogued ? LensL10n.text("Identité non cataloguée") : (lane.accessible == false ? LensL10n.text("Historique inaccessible") : LensL10n.text("{0} événements", String(describing: lane.eventCount)))
            (status as NSString).draw(in: NSRect(x: visible.minX + 12, y: row.minY + 27, width: labelWidth - 22, height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            NSColor.separatorColor.setFill(); NSRect(x: visible.minX, y: row.maxY - 1, width: visible.width, height: 0.5).fill()
        }
        if let a = dragStart, let b = dragCurrent {
            LensControlAccent.current.nsColor.withAlphaComponent(0.14).setFill()
            NSRect(x: min(a.x, b.x), y: rulerHeight, width: abs(b.x - a.x), height: max(0, bounds.height - rulerHeight)).intersection(plot).fill()
        }
    }
    private func draw(_ item: TimelineItem, geometry: TimelineGeometry, clip: NSRect) {
        // Clip before constructing a path: a years-long recorded interval can extend far outside the viewport.
        let rect = nativeRect(item, geometry: geometry).intersection(clip)
        guard !rect.isEmpty else { return }
        color(item).withAlphaComponent(item.id == selectedID ? 1 : 0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        if item.id != selectedID {
            (item.id == hoverID ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            outline.lineWidth = item.id == hoverID ? 1.25 : 0.75; outline.stroke()
        }
        if item.id == selectedID {
            LensControlAccent.current.nsColor.setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1.5; outline.stroke()
        }
    }
    private func drawRuler(geometry: TimelineGeometry, visible: NSRect, plot: NSRect, dirtyRect: NSRect) {
        let ticks = max(4, Int(geometry.timeWidth / 130))
        let first = max(0, Int(floor((Double(plot.minX) - geometry.labelWidth) / geometry.timeWidth * Double(ticks))))
        let last = min(ticks, Int(ceil((Double(plot.maxX) - geometry.labelWidth) / geometry.timeWidth * Double(ticks))))
        guard first <= last else { return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: plot.intersection(dirtyRect)).addClip()
        for index in first...last {
            let x = CGFloat(geometry.labelWidth + Double(index) / Double(ticks) * geometry.timeWidth)
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 36)); line.line(to: NSPoint(x: x, y: bounds.maxY)); line.stroke()
            let date = geometry.window.start.addingTimeInterval(Double(index) / Double(ticks) * geometry.window.duration)
            let label = geometry.window.duration / Double(ticks) < 1
                ? date.formatted(.dateTime.locale(Locale(identifier: LensL10n.resolvedLanguage.rawValue)).hour().minute().second().secondFraction(.fractional(3)))
                : date.lensFormatted(date: geometry.window.duration > 86400 ? .abbreviated : .omitted, time: .standard)
            (label as NSString)
                .draw(at: NSPoint(x: x + 3, y: 14), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil); dragCurrent = nil
    }
    override func magnify(with event: NSEvent) {
        if let scroll = enclosingScrollView as? TimelineScrollView {
            scroll.magnify(with: event)
        } else { super.magnify(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let geometry, start.y < CGFloat(geometry.rulerHeight) || event.modifierFlags.contains(.option) else { return }
        dragCurrent = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = dragStart, let end = dragCurrent, abs(end.x - start.x) > 4, let geometry {
            let lo = geometry.date(atX: Double(min(start.x, end.x))), hi = geometry.date(atX: Double(max(start.x, end.x)))
            onRange?(lo...hi)
        } else { select(at: point, zoom: event.clickCount >= 2) }
        dragStart = nil; dragCurrent = nil; needsDisplay = true
    }
    private func hits(at point: NSPoint, limit: Int = 128) -> TimelineHitResult? {
        guard let projection, let geometry, point.x >= visibleRect.minX + CGFloat(geometry.labelWidth) else { return nil }
        return projection.hitTest(x: Double(point.x), y: Double(point.y), geometry: geometry, limit: limit)
    }
    private func select(at point: NSPoint, zoom: Bool = false) {
        guard let hits = hits(at: point), !hits.eventIDs.isEmpty else { return }
        if !hits.requiresDisambiguation, let id = hits.eventIDs.first { selectEvent(id, zoom: zoom); return }
        let menu = selectionMenu(hits, zoom: zoom)
        menu.popUp(positioning: nil, at: point, in: self)
    }
    private func selectEvent(_ id: String, zoom: Bool = false) {
        // Immediate local feedback precedes the shared navigation publication.
        selectedID = id; updateAccessibilitySelection(); needsDisplay = true
        onSelect?(id)
        if zoom { onFocus?(id) }
    }
    private func selectionMenu(_ hits: TimelineHitResult, zoom: Bool = false) -> NSMenu {
        let menu = NSMenu(title: LensL10n.text("Événements superposés"))
        for id in hits.eventIDs {
            let event = eventLookup?(id)
            let label = event.map { "\($0.timestamp.lensFormatted(date: .omitted, time: .standard)) · \($0.title)" } ?? id
            let item = NSMenuItem(title: String(label.prefix(180)), action: zoom ? #selector(focusMenuItem(_:)) : #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; menu.addItem(item)
        }
        if hits.uninspectedCandidates > 0 {
            menu.addItem(.separator())
            let omitted = NSMenuItem(title: LensL10n.text("{0} autres candidats ; utiliser la liste détaillée", String(describing: hits.uninspectedCandidates)), action: nil, keyEquivalent: "")
            omitted.isEnabled = false; menu.addItem(omitted)
        }
        return menu
    }
    @objc private func selectMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { selectEvent(id) } }
    @objc private func focusMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { selectEvent(id, zoom: true) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hits = hits(at: point), !hits.eventIDs.isEmpty else { return nil }
        if hits.requiresDisambiguation { return selectionMenu(hits) }
        guard let id = hits.eventIDs.first else { return nil }
        let menu = NSMenu()
        let select = NSMenuItem(title: LensL10n.text("Voir le contexte de l’événement"), action: #selector(selectMenuItem(_:)), keyEquivalent: "")
        select.target = self; select.representedObject = id; menu.addItem(select)
        let focus = NSMenuItem(title: LensL10n.text("Cadrer cet événement"), action: #selector(focusMenuItem(_:)), keyEquivalent: "")
        focus.target = self; focus.representedObject = id; menu.addItem(focus)
        let investigate = NSMenuItem(title: LensL10n.text("Préparer une question contextualisée"), action: #selector(investigateMenuItem(_:)), keyEquivalent: "")
        investigate.target = self; investigate.representedObject = id; menu.addItem(investigate)
        return menu
    }
    @objc private func investigateMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onInvestigate?(id) } }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers {
        case "\u{f702}", "\u{f700}": _ = moveSelection(step: -1, sameAgent: event.modifierFlags.contains(.option))
        case "\u{f703}", "\u{f701}": _ = moveSelection(step: 1, sameAgent: event.modifierFlags.contains(.option))
        case "\u{f729}": if let id = projection?.orderedEventIDs.first { onSelect?(id); reveal(id) }
        case "\u{f72b}": if let id = projection?.orderedEventIDs.last { onSelect?(id); reveal(id) }
        case "+", "=": adjustTimelineZoom(.increase)
        case "-": adjustTimelineZoom(.decrease)
        case "\r": if let id = selectedID { onFocus?(id) }
        case "\u{1b}": dragStart = nil; dragCurrent = nil; needsDisplay = true
        default: super.keyDown(with: event)
        }
    }
    @discardableResult private func moveSelection(step: Int, sameAgent: Bool = false) -> Bool {
        guard let projection else { return false }
        let target: String?
        if let selectedID, let item = projection.item(id: selectedID) {
            let agent = sameAgent ? item.agentID : nil
            target = step < 0 ? projection.previous(of: selectedID, inAgent: agent) : projection.next(of: selectedID, inAgent: agent)
        } else { target = step < 0 ? projection.orderedEventIDs.last : projection.orderedEventIDs.first }
        guard let target else { return false }
        selectEvent(target); reveal(target); return true
    }
    func reveal(_ id: String, centered: Bool = false) {
        guard let item = projection?.item(id: id), let geometry, let scroll = enclosingScrollView else { return }
        let rect = nativeRect(item, geometry: geometry), visible = scroll.contentView.bounds
        var origin = visible.origin
        let labelWidth = CGFloat(geometry.labelWidth)
        if centered { origin.x = rect.midX - (visible.width + labelWidth) / 2 }
        else if rect.minX < visible.minX + labelWidth { origin.x = max(0, rect.minX - labelWidth - 8) }
        else if rect.minX > visible.maxX - 12 { origin.x = max(0, rect.minX - visible.width + 24) }
        if rect.minY < visible.minY + 8 { origin.y = max(0, rect.minY - 8) }
        else if rect.maxY > visible.maxY - 8 { origin.y = rect.maxY - visible.height + 8 }
        origin.x = min(origin.x, max(0, bounds.width - visible.width)); origin.y = min(origin.y, max(0, bounds.height - visible.height))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hits(at: point, limit: 4)
        let nextHover = hits?.requiresDisambiguation == false ? hits?.eventIDs.first : nil
        if nextHover != hoverID {
            let old = hoverID; hoverID = nextHover
            if let geometry {
                for id in [old, nextHover].compactMap({ $0 }) {
                    if let item = projection?.item(id: id) { setNeedsDisplay(nativeRect(item, geometry: geometry).insetBy(dx: -2, dy: -2)) }
                }
            }
        }
        guard let hits, let id = hits.eventIDs.first, let record = eventLookup?(id) else { toolTip = nil; return }
        let ambiguity = hits.requiresDisambiguation ? LensL10n.text("\nPlusieurs événements se superposent ; cliquer pour choisir.") : ""
        toolTip = record.title + " · " + record.timestamp.lensFormatted(date: .abbreviated, time: .standard) + "\n" + String(record.preview.prefix(1800)) + ambiguity
    }
    override func mouseExited(with event: NSEvent) {
        if let id = hoverID, let item = projection?.item(id: id), let geometry {
            setNeedsDisplay(nativeRect(item, geometry: geometry).insetBy(dx: -2, dy: -2))
        }
        hoverID = nil; toolTip = nil
    }
}
