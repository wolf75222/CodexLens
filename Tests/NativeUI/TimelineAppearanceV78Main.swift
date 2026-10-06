import AppKit
import Darwin
import Foundation
import LensCore

/// Source-matched production canvas in an owned AppKit window. Events are generated
/// here; no observed journal, command, account or network service is consulted.
@main struct TimelineAppearanceV78Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify(); NSApp.terminate(nil) }
            catch { fputs("Timeline appearance v78: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let argument = CommandLine.arguments.firstIndex(of: "--output"), argument + 1 < CommandLine.arguments.count else {
            throw LensError.unavailable("Missing native qualification output directory.")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
        UserDefaults.standard.setVolatileDomain(["lensLanguage": "fr", "lensControlAccent": "lens"], forName: UserDefaults.argumentDomain)
        LensL10n.language = .fr
        var checks: [[String: Any]] = [], renders: [String] = [], observations: [[String: Any]] = []
        var complete = false, stage = "generated-fixture"
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func writeReceipt(_ completed: Bool) {
            let receipt: [String: Any] = ["checks": checks, "renders": renders, "observations": observations,
                "completed": completed, "failedStage": completed ? "none" : stage,
                "allExecutedChecksPassed": completed && checks.allSatisfy { $0["passed"] as? Bool == true },
                "fixture": ["anonymous": true, "origin": "In-memory V78 deterministic fixture", "rootEvents": 1200, "agentLanes": 3],
                "scope": "Production TimelineCanvas, owned native window, local NSEvent and accessibility action dispatch. PNGs use native bitmap caching, not the production compositor.",
                "unqualified": ["No physical pointer, trackpad or VoiceOver session is qualified.",
                    "No historical before/after image or CPU, memory, latency improvement is claimed.",
                    "The append changes the in-memory projection; it is not a collector ingestion test."]]
            if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
            }
        }
        defer { if !complete { checks.append(["name": "flow-completes-after-" + stage, "passed": false]); writeReceipt(false) } }
        let sourceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        check("source-matched-production-canvas-entrypoint", sourceManifest?["entrypoint"] as? String == "TimelineAppearanceV78Main.swift"
            && sourceManifest?["copiedAppSourcesModified"] as? Bool == false)

        let epoch = Date(timeIntervalSince1970: 1_790_784_000)
        let kinds: [EventKind] = [.user, .assistant, .toolCall, .toolResult, .delegation, .wait, .error, .compaction]
        let titles = ["User message", "Assistant response", "Recorded call", "Recorded result", "Delegation", "Known wait", "Recorded error", "Compaction"]
        var events = (0..<1200).map { i -> LensEvent in
            let offset = Double(i) * 0.25
            return LensEvent(id: "root-\(i)", timestamp: epoch.addingTimeInterval(offset), endTime: epoch.addingTimeInterval(offset + 0.03),
                agentID: "alpha", kind: kinds[i % kinds.count], title: titles[i % titles.count] + " \(i)",
                source: SourceRef(path: "generated-anonymous-root.jsonl", offset: UInt64(i), line: i + 1), isError: i % 37 == 2)
        }
        events += (0..<40).map { i in LensEvent(id: "child-\(i)", timestamp: epoch.addingTimeInterval(Double(i) * 7.5), agentID: "beta",
            kind: kinds[i % kinds.count], title: titles[i % titles.count], source: SourceRef(path: "generated-anonymous-child.jsonl", offset: UInt64(i))) }
        events += (0..<12).map { i in LensEvent(id: "grandchild-\(i)", timestamp: epoch.addingTimeInterval(100 + Double(i) * 2), agentID: "gamma",
            kind: kinds[(i + 2) % kinds.count], title: titles[(i + 2) % titles.count], source: SourceRef(path: "generated-anonymous-grandchild.jsonl", offset: UInt64(i))) }
        let agents = [AgentRecord(id: "alpha", name: "Session principale"),
            AgentRecord(id: "beta", parentID: "alpha", name: "/root/reader", relation: .subagent),
            AgentRecord(id: "gamma", parentID: "beta", name: "/root/reader/checker", relation: .subagent)]
        let projection = try await Task.detached { try TimelineProjection.prepare(events: events, agents: agents) }.value
        let records = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        func geometry(_ start: Double, _ end: Double, width: Double = 1160) throws -> TimelineGeometry {
            try TimelineGeometry(window: TimelineWindow(start: epoch.addingTimeInterval(start), end: epoch.addingTimeInterval(end)),
                contentWidth: width, minimumTimeSpan: 0.001)
        }
        let overview = try geometry(0, 600), intermediate = try geometry(98, 128), detail = try geometry(99.75, 101.5)
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 1160, height: 230))
        canvas.projection = projection; canvas.geometry = overview; canvas.eventLookup = { records[$0] }
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1160, height: 230),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        var focused: ClosedRange<Date>?, selected: String?, opened: String?, listed: ClosedRange<Date>?
        canvas.onFocusRange = { focused = $0 }; canvas.onSelect = { selected = $0 }
        canvas.onOpenTab = { opened = $0 }; canvas.onRange = { listed = $0 }

        stage = "colored-overview"
        let initial = try unwrap(canvas.densityPlan(for: 0))
        check("overview-groups-dense-events-without-removing-sources", initial.totalMatches == 1200 && !initial.clusters.isEmpty && initial.details.isEmpty
            && projection.eventCount == events.count && Set(projection.orderedEventIDs) == Set(events.map(\.id)))
        check("overview-groups-retain-exact-kind-composition", exactComposition(initial, geometry: overview, events: events, agent: "alpha"))
        check("overview-group-samples-keep-original-identities", initial.clusters.allSatisfy { $0.sampleEventIDs.count <= 4
            && !$0.sampleEventIDs.isEmpty && $0.sampleEventIDs.allSatisfy { records[$0]?.agentID == "alpha" } })
        check("agent-lanes-retain-independent-counts", canvas.densityPlan(for: 1)?.totalMatches == 40 && canvas.densityPlan(for: 2)?.totalMatches == 12)
        let signature = initial.clusters.map { "\($0.id):\($0.count):\(compositionSignature($0))" }
        let firstGroup = try unwrap(initial.clusters.first)
        let groupPoint = NSPoint(x: (overview.x(for: firstGroup.window.start) + overview.x(for: firstGroup.window.end)) / 2,
            y: overview.rulerHeight + overview.barInset + overview.barHeight / 2)
        check("colored-group-remains-hit-testable", canvas.densityCluster(at: groupPoint)?.id == firstGroup.id)
        canvas.mouseUp(with: try mouse(.leftMouseUp, point: groupPoint, canvas: canvas, window: window))
        check("group-click-focuses-recorded-period", focused.map { $0.lowerBound < firstGroup.window.start && $0.upperBound > firstGroup.window.end } == true)
        let groupMenu = try unwrap(canvas.menu(for: try mouse(.rightMouseDown, point: groupPoint, canvas: canvas, window: window)))
        check("group-menu-keeps-zoom-and-list-actions", groupMenu.items.count <= 8 && groupMenu.items.first?.action != nil
            && groupMenu.items.dropFirst().first?.title == LensL10n.text("Afficher cette période dans la liste"))
        if let item = groupMenu.items.dropFirst().first, let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
        check("group-list-action-retains-exact-bin-period", listed == (firstGroup.window.start...firstGroup.window.end))
        let groupAX = canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let groupCountLabel = LensUI.count(firstGroup.count, singular: LensL10n.text("événement"), plural: LensL10n.text("événements"))
        check("group-count-remains-available-in-accessibility-label", groupAX.first?.accessibilityLabel()?.contains(groupCountLabel) == true)
        let hoverEvent = try mouse(.mouseMoved, point: groupPoint, canvas: canvas, window: window)
        canvas.mouseMoved(with: hoverEvent)
        check("group-count-remains-available-in-tooltip", canvas.toolTip?.contains(groupCountLabel) == true)
        canvas.mouseExited(with: hoverEvent)
        check("groups-expose-kind-composition-without-color-only-meaning", groupAX.contains { element in
            guard let value = element.accessibilityValue() as? String else { return false }
            return value.contains(EventKind.user.label) && value.contains(EventKind.toolCall.label) && element.accessibilityRole() == .button
        })
        focused = nil
        check("accessible-group-action-is-functional", groupAX.first?.accessibilityPerformPress() == true && focused != nil)
        try captureScale("overview", canvas: canvas, window: window, output: output, checks: &checks, renders: &renders, observations: &observations)

        stage = "separable-small-marks"
        canvas.geometry = intermediate
        let medium = try unwrap(canvas.densityPlan(for: 0))
        let expectedMedium = expectedIDs(geometry: intermediate, viewport: canvas.visibleRect.intersection(canvas.bounds), events: events, agent: "alpha")
        observeCoverage("intermediate", plan: medium, expected: expectedMedium, canvas: canvas, geometry: intermediate, observations: &observations)
        check("intermediate-scale-reveals-many-separable-individual-marks", medium.clusters.isEmpty && medium.details.count > 100)
        check("intermediate-marks-retain-every-visible-source-id", Set(medium.details.map(\.id)) == expectedMedium
            && medium.totalMatches == expectedMedium.count)
        check("intermediate-marks-are-not-overplotted", marksAreSeparated(medium.details, geometry: intermediate))
        check("intermediate-small-marks-have-mixed-types", Set(medium.details.map { $0.isError ? EventKind.error : $0.kind }).count >= 7)
        try captureScale("intermediate", canvas: canvas, window: window, output: output, checks: &checks, renders: &renders, observations: &observations)
        let mediumAX = canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        check("individual-small-marks-have-accessible-actions", mediumAX.count <= 512
            && mediumAX.contains { $0.accessibilityLabel()?.contains("User message 400") == true && $0.accessibilityRole() == .button })

        // AppKit can constrain a window to the runner's screen. Explicitly
        // exercise a clipped canvas as well; off-screen IDs are still retained
        // in the projection, but are not part of the visible drawing plan.
        let originalFrame = canvas.frame
        canvas.frame.size.width = min(620, originalFrame.width * 0.6)
        let clipped = try unwrap(canvas.densityPlan(for: 0))
        let expectedClipped = expectedIDs(geometry: intermediate, viewport: canvas.visibleRect.intersection(canvas.bounds), events: events, agent: "alpha")
        check("clipped-viewport-retains-exact-visible-ids-and-all-source-records", !expectedClipped.isEmpty
            && expectedClipped.count < expectedMedium.count && clipped.clusters.isEmpty
            && Set(clipped.details.map(\.id)) == expectedClipped && clipped.totalMatches == expectedClipped.count
            && Set(projection.orderedEventIDs) == Set(events.map(\.id)))
        observeCoverage("explicit-clipped", plan: clipped, expected: expectedClipped, canvas: canvas, geometry: intermediate, observations: &observations)
        canvas.frame = originalFrame

        stage = "individual-selection"
        canvas.geometry = detail
        let detailed = try unwrap(canvas.densityPlan(for: 0))
        let expectedDetail = expectedIDs(geometry: detail, viewport: canvas.visibleRect.intersection(canvas.bounds), events: events, agent: "alpha")
        observeCoverage("detail", plan: detailed, expected: expectedDetail, canvas: canvas, geometry: detail, observations: &observations)
        check("detail-reveals-original-event-identities", detailed.clusters.isEmpty && Set(detailed.details.map(\.id)) == expectedDetail)
        let event = try unwrap(projection.item(id: "root-400")), rect = detail.rect(for: event)
        let point = NSPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        canvas.mouseUp(with: try mouse(.leftMouseUp, point: point, canvas: canvas, window: window))
        check("small-mark-click-selects-correct-recorded-event", selected == "root-400" && canvas.selectedID == selected)
        let menu = try unwrap(canvas.menu(for: try mouse(.rightMouseDown, point: point, canvas: canvas, window: window)))
        if let item = menu.items.first(where: { $0.title == LensL10n.text("Ouvrir dans un onglet") }), let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: item)
        }
        check("small-mark-context-menu-opens-exact-event", opened == "root-400" && canvas.selectedID == "root-400")
        guard let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124) else {
            throw LensError.unavailable("Cannot construct local keyboard event.")
        }
        canvas.keyDown(with: right)
        check("keyboard-follows-original-event-order-in-agent", selected == "root-401" && canvas.selectedID == selected)
        try captureScale("detail", canvas: canvas, window: window, output: output, checks: &checks, renders: &renders, observations: &observations)

        stage = "dezoom-and-cache"
        canvas.geometry = overview
        let restored = try unwrap(canvas.densityPlan(for: 0))
        check("dezoom-restores-identical-colored-group-composition", restored.clusters.map { "\($0.id):\($0.count):\(compositionSignature($0))" } == signature
            && restored.totalMatches == initial.totalMatches && canvas.selectedID == "root-401")
        canvas.updateAccessibilitySelection()
        check("selected-event-remains-accessible-inside-colored-group", (canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []).contains {
            $0.accessibilityLabel()?.contains("Assistant response 401") == true
        })
        let q = canvas.densityQueryCount
        for _ in 0..<50 { _ = canvas.densityPlan(for: 0) }
        check("selection-and-repaint-reuse-bounded-density-cache", canvas.densityQueryCount == q && canvas.densityCacheHits >= 50
            && canvas.densityCacheBytes <= 2 * 1024 * 1024)
        let filename = "dezoom-selected-light.png"
        _ = try capture(canvas, window: window, dark: false, path: output.appendingPathComponent(filename)); renders.append(filename)
        let staleAX = canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let addition = LensEvent(id: "new-live-event", timestamp: epoch.addingTimeInterval(100.125), agentID: "alpha", kind: .toolCall,
            title: "New recorded call", source: SourceRef(path: "generated-anonymous-root.jsonl", offset: 1500))
        let appended = try await Task.detached { try TimelineProjection.prepare(events: events + [addition], agents: agents) }.value
        canvas.projection = appended
        let appendedPlan = try unwrap(canvas.densityPlan(for: 0))
        check("live-append-updates-group-counts-without-losing-selection", appendedPlan.totalMatches == 1201
            && exactComposition(appendedPlan, geometry: overview, events: events + [addition], agent: "alpha") && canvas.selectedID == "root-401")
        check("stale-accessibility-actions-reject-replaced-projection", staleAX.first?.accessibilityPerformPress() == false)
        canvas.projection = projection; canvas.frame.size.width = 620; canvas.geometry = try geometry(0, 600, width: 620)
        check("narrow-viewport-retains-all-events-and-bounded-marks", canvas.densityPlan(for: 0).map {
            $0.totalMatches == 1200 && $0.clusters.count <= 256 && $0.details.count <= projection.maxQueryItems
        } == true)
        let narrow = "overview-narrow-light.png"
        _ = try capture(canvas, window: window, dark: false, path: output.appendingPathComponent(narrow)); renders.append(narrow)

        stage = "completion"
        complete = true; writeReceipt(true)
        if checks.contains(where: { $0["passed"] as? Bool != true }) { throw LensError.unavailable("A native timeline appearance check failed; inspect its receipt.") }
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw LensError.unavailable("Required native timeline value is absent.") }; return value
    }
    private static func expectedIDs(geometry: TimelineGeometry, viewport: NSRect, events: [LensEvent], agent: String) -> Set<String> {
        let lowerX = max(geometry.labelWidth, Double(viewport.minX) + geometry.labelWidth)
        let upperX = min(geometry.contentWidth - geometry.rightInset, Double(viewport.maxX))
        guard lowerX <= upperX else { return [] }
        let lower = geometry.date(atX: lowerX, clamped: false), upper = geometry.date(atX: upperX, clamped: false)
        let padding = geometry.window.duration * geometry.minimumMarkerWidth / geometry.timeWidth
        return Set(events.filter { event in
            event.agentID == agent && event.timestamp <= upper
                && max(event.endTime ?? event.timestamp, event.timestamp.addingTimeInterval(padding)) >= lower
        }.map(\.id))
    }
    @MainActor private static func observeCoverage(_ scenario: String, plan: TimelineDensityResult, expected: Set<String>, canvas: NSView,
        geometry: TimelineGeometry, observations: inout [[String: Any]]) {
        let actual = Set(plan.details.map(\.id)), viewport = canvas.visibleRect.intersection(canvas.bounds)
        let lowerX = max(geometry.labelWidth, Double(viewport.minX) + geometry.labelWidth)
        let upperX = min(geometry.contentWidth - geometry.rightInset, Double(viewport.maxX))
        observations.append(["scenario": scenario, "method": "Exact source ID set against the actual clipped viewport",
            "frame": NSStringFromRect(canvas.frame), "bounds": NSStringFromRect(canvas.bounds), "visibleRect": NSStringFromRect(viewport),
            "logicalContentWidth": geometry.contentWidth, "timeWidth": geometry.timeWidth, "rightInset": geometry.rightInset,
            "plotXRange": [lowerX, upperX], "logicalTimeWindow": [geometry.window.start.timeIntervalSince1970, geometry.window.end.timeIntervalSince1970],
            "visibleTimeWindow": [geometry.date(atX: lowerX, clamped: false).timeIntervalSince1970, geometry.date(atX: upperX, clamped: false).timeIntervalSince1970],
            "expectedCount": expected.count, "actualDetailCount": actual.count, "totalMatches": plan.totalMatches,
            "clusterCount": plan.clusters.count,
            "missingIDs": expected.subtracting(actual).sorted(), "unexpectedIDs": actual.subtracting(expected).sorted()])
    }
    private static func exactComposition(_ plan: TimelineDensityResult, geometry: TimelineGeometry, events: [LensEvent], agent: String) -> Bool {
        let padding = geometry.window.duration * geometry.minimumMarkerWidth / geometry.timeWidth
        return plan.clusters.allSatisfy { cluster in
            let matching = events.filter { $0.agentID == agent && $0.timestamp <= cluster.window.end
                && max($0.endTime ?? $0.timestamp, $0.timestamp.addingTimeInterval(padding)) >= cluster.window.start }
            let counts = Dictionary(grouping: matching, by: { $0.isError ? EventKind.error : $0.kind }).mapValues(\.count)
            return matching.count == cluster.count && counts == cluster.kindCounts && cluster.kindCounts.values.reduce(0, +) == cluster.count
        }
    }
    private static func compositionSignature(_ cluster: TimelineDensityCluster) -> String {
        EventKind.allCases.map { "\($0.rawValue)=\(cluster.kindCounts[$0, default: 0])" }.joined(separator: ",")
    }
    private static func marksAreSeparated(_ items: [TimelineItem], geometry: TimelineGeometry) -> Bool {
        let rects = items.sorted { $0.start < $1.start }.map { geometry.rect(for: $0) }
        return zip(rects, rects.dropFirst()).allSatisfy { pair in pair.0.maxX + 0.95 <= pair.1.x }
    }
    @MainActor private static func mouse(_ type: NSEvent.EventType, point: NSPoint, canvas: NSView, window: NSWindow) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    @MainActor private static func captureScale(_ name: String, canvas: TimelineCanvas, window: NSWindow, output: URL,
        checks: inout [[String: Any]], renders: inout [String], observations: inout [[String: Any]]) throws {
        for dark in [false, true] {
            let filename = name + (dark ? "-dark.png" : "-light.png")
            let bitmap = try capture(canvas, window: window, dark: dark, path: output.appendingPathComponent(filename))
            renders.append(filename)
            let families = paletteCounts(in: bitmap, view: canvas)
            checks.append(["name": name + (dark ? "-dark" : "-light") + "-renders-several-brand-color-families", "passed": families.filter { $0.value >= 10 }.count >= 4])
            observations.append(["scenario": name, "appearance": dark ? "dark" : "light", "bitmapPixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
                "nearestPalettePixelSamples": families, "method": "Coarse RGB family presence, not an exact-pixel snapshot or contrast qualification."])
        }
    }
    @MainActor private static func capture(_ view: NSView, window: NSWindow, dark: Bool, path: URL) throws -> NSBitmapImageRep {
        let appearance = try unwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        window.appearance = appearance; view.appearance = appearance; view.layoutSubtreeIfNeeded(); view.needsDisplay = true
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try unwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        return bitmap
    }
    @MainActor private static func paletteCounts(in bitmap: NSBitmapImageRep, view: NSView) -> [String: Int] {
        let kinds: [EventKind] = [.user, .assistant, .toolCall, .wait, .error]
        // Adaptive NSColors resolve components when read. Freeze these numbers
        // inside the same appearance scope that produced the cached bitmap.
        var palette: [(String, Double, Double, Double)] = []
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            palette = kinds.compactMap { kind in
                guard let color = LensBrand.eventNSColor(kind).usingColorSpace(.sRGB) else { return nil }
                return (kind.rawValue, Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
            }
        }
        var counts: [String: Int] = [:]
        // colorAt() constructs a calibrated Generic RGB color even when the
        // cache bitmap is tagged Display P3. Preserve the bitmap's color space
        // before converting its pixel components into the palette's sRGB space.
        guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4,
              !bitmap.bitmapFormat.contains(.alphaFirst) else { return counts }
        let space = bitmap.colorSpace
        var samples = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        var components = [CGFloat](repeating: 0, count: bitmap.samplesPerPixel)
        let labelEdge = Int(Double(bitmap.pixelsWide) / view.bounds.width * 150)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: labelEdge, to: bitmap.pixelsWide, by: 2) {
                bitmap.getPixel(&samples, atX: x, y: y)
                for i in samples.indices { components[i] = CGFloat(samples[i]) / 255 }
                let tagged = components.withUnsafeBufferPointer { NSColor(colorSpace: space, components: $0.baseAddress!, count: components.count) }
                guard let pixel = tagged.usingColorSpace(.sRGB) else { continue }
                let nearest = palette.map { name, red, green, blue -> (String, Double) in
                    let dr = Double(pixel.redComponent) - red, dg = Double(pixel.greenComponent) - green, db = Double(pixel.blueComponent) - blue
                    return (name, dr * dr + dg * dg + db * db)
                }.min { $0.1 < $1.1 }
                if let nearest, nearest.1 < 0.01 { counts[nearest.0, default: 0] += 1 }
            }
        }
        return counts
    }
}
