import AppKit
import SwiftUI
import QuartzCore
import CryptoKit
import LensCore
import CSandbox

/// Measures our actual native views with synthetic records only. No Codex
/// session is opened and no sender, authentication or production preference
/// domain is used. A ready/trigger handshake permits external Instruments
/// attachment to this process before the deterministic action sequence.
@main
@MainActor
struct NativeQualityMain {
    static func main() {
        if CommandLine.arguments.contains("--install-network-sandbox") {
            guard lens_profile_deny_network() == 0 else {
                fputs("Could not install the SDK named no-network profile.\n", stderr); exit(2)
            }
            guard lens_profile_network_is_denied() != 0 else { fputs("No-network verification failed; refusing to run.\n", stderr); exit(2) }
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                let run = try NativeQualityRun()
                try await run.run()
                if !run.options.linger { application.terminate(nil) }
            } catch {
                fputs("Native quality probe failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }
}

private struct QualityOptions {
    let eventCount: Int
    let output: URL
    let emptyHome: URL
    let archive: URL
    let readyFile: URL
    let triggerFile: URL
    let sourceLabel: String
    let linger: Bool
    let runNow: Bool

    init() throws {
        let arguments = CommandLine.arguments
        func value(_ flag: String) throws -> String {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { throw qualityFailure("Missing argument \(flag).") }
            return arguments[index + 1]
        }
        guard let count = Int(try value("--event-count")), [10_000, 100_000].contains(count) else { throw qualityFailure("Event count must be 10000 or 100000.") }
        eventCount = count
        output = URL(fileURLWithPath: try value("--output")).standardizedFileURL
        emptyHome = URL(fileURLWithPath: try value("--empty-home")).standardizedFileURL
        archive = URL(fileURLWithPath: try value("--archive")).standardizedFileURL
        readyFile = URL(fileURLWithPath: try value("--ready-file")).standardizedFileURL
        triggerFile = URL(fileURLWithPath: try value("--trigger-file")).standardizedFileURL
        sourceLabel = try value("--source-label")
        linger = arguments.contains("--linger")
        runNow = arguments.contains("--run-now")
    }
}

private struct QualityCorpus: Sendable {
    let base: SessionSnapshot
    let publications: [SessionSnapshot]
    let selectedIDs: [String]
}

private enum QualityFixtureBuilder {
    static func make(count: Int) -> QualityCorpus {
        let base = LensDemoFixtures.snapshot(eventCount: count)
        let calls = base.events.filter { $0.kind == .toolCall }
        let selected = (0..<5).map { calls[min(calls.count - 1, calls.count * (2 * $0 + 1) / 10)].id }
        let template = LensDemoFixtures.snapshot(eventCount: 32).events
        var current = base
        var publications: [SessionSnapshot] = []
        for batch in 0..<5 {
            var addition: [LensEvent] = []
            for (index, original) in template.enumerated() {
                var event = original
                event.id = "quality-append-\(batch)-\(index)"
                event.timestamp = base.collectedAt.addingTimeInterval(Double(batch + 1) * 5 + Double(index) * 0.03)
                event.endTime = original.endTime == nil ? nil : event.timestamp.addingTimeInterval(0.85)
                event.turnID = "quality-turn-\(batch)-\(index % 8)"
                if original.callID != nil { event.callID = "quality-call-\(batch)-\(index % 8)" }
                if let paired = original.relatedEventID, let pairedIndex = Int(paired.replacingOccurrences(of: "fixture-event-", with: "")) {
                    event.relatedEventID = "quality-append-\(batch)-\(pairedIndex)"
                }
                addition.append(event)
            }
            current.events.append(contentsOf: addition)
            current.collectedAt = addition.last!.timestamp
            current.root.modifiedAt = current.collectedAt
            for index in current.environments.indices {
                let id = current.environments[index].id
                current.environments[index].eventIDs.append(contentsOf: addition.filter { $0.environmentID == id }.map(\.id))
            }
            for index in current.resources.indices {
                let id = current.resources[index].id
                current.resources[index].eventIDs.append(contentsOf: addition.filter { $0.resourceIDs.contains(id) }.map(\.id))
            }
            publications.append(current)
        }
        return QualityCorpus(base: base, publications: publications, selectedIDs: selected)
    }
}

@MainActor
private final class NativeQualityRun {
    let options: QualityOptions
    private let clock = ContinuousClock()
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!
    private var store: LensStore!
    private var observations: [[String: Any]] = []
    private var renders: [[String: Any]] = []

    init() throws { options = try QualityOptions() }

    func run() async throws {
        guard Bundle.main.bundleIdentifier == "fr.codexlens.qualityprobe" else { throw qualityFailure("Run the generated QualityProbe.app; its isolated preferences domain is required.") }
        guard !FileManager.default.fileExists(atPath: options.triggerFile.path) else { throw qualityFailure("The trigger already exists; choose an unused output/trigger path.") }
        for directory in [options.output, options.emptyHome, options.archive] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard try FileManager.default.contentsOfDirectory(atPath: options.emptyHome.path).isEmpty else { throw qualityFailure("The injected source home must be empty.") }
        UserDefaults.standard.removePersistentDomain(forName: "fr.codexlens.qualityprobe")
        UserDefaults.standard.set("light", forKey: "lensAppearance")
        let generationStart = clock.now
        let count = options.eventCount
        let corpus = await Task.detached(priority: .userInitiated) { QualityFixtureBuilder.make(count: count) }.value
        let generationMilliseconds = milliseconds(generationStart.duration(to: clock.now))
        store = LensStore(sourceHome: options.emptyHome, investigationArchive: InvestigationArchive(directory: options.archive))
        #if LENS_QUALITY_V03
        store.setNavigationScope(UUID().uuidString)
        #endif
        // Deliberately do not call start()/open(): no catalog, poller or real
        // Codex source can enter this profiling run.
        store.snapshot = corpus.base
        store.showSessionPicker = false
        store.inspectorVisible = false
        store.section = .activity
        store.follow = false
        await awaitPresentation()
        let openingStart = clock.now
        install()
        await settle(milliseconds: 400)
        let openingMilliseconds = milliseconds(openingStart.duration(to: clock.now))

        // Capture the same readable 10k corpus in both runs. These captures and
        // fixture preparation are outside the measured action interval.
        let readable = options.eventCount == 10_000 ? corpus.base : await Task.detached { LensDemoFixtures.snapshot(eventCount: 10_000) }.value
        store.snapshot = readable
        await awaitPresentation()
        for theme in ["light", "dark"] {
            setTheme(theme)
            await settle(milliseconds: 300)
            try capture(filename: "quality-\(theme).png", theme: theme, eventCount: readable.events.count)
        }
        setTheme("light")
        store.snapshot = corpus.base
        store.resetFilters()
        store.navigate(.event(corpus.selectedIDs[0]), record: false)
        await awaitPresentation()
        #if LENS_QUALITY_V03
        try await captureGallery()
        #endif
        await settle(milliseconds: 400)
        let ready: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier!,
            "sourceLabel": options.sourceLabel,
            "eventCount": options.eventCount,
            "readyAt": Date().ISO8601Format(),
            "triggerFile": options.triggerFile.path,
            "reportFile": options.output.appendingPathComponent("quality-report.json").path,
            "networkDeniedByOS": true,
            "actionCount": 20,
            "actionSpacingMilliseconds": 250,
            "fixturePreparationComplete": true
        ]
        try writeJSON(ready, to: options.readyFile)
        print("QUALITY_READY pid=\(ProcessInfo.processInfo.processIdentifier) events=\(options.eventCount) trigger=\(options.triggerFile.path)")
        fflush(stdout)
        if options.runNow { try Data("run\n".utf8).write(to: options.triggerFile, options: .atomic) }
        while !FileManager.default.fileExists(atPath: options.triggerFile.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        let sequenceStart = clock.now
        let measuredAt = Date()
        print("QUALITY_BEGIN at=\(measuredAt.ISO8601Format())")
        fflush(stdout)
        for cycle in 0..<5 {
            let selectedID = corpus.selectedIDs[cycle]
            let agentID = corpus.base.agents[cycle % 7 + 1].id
            await measure("select_event", cycle: cycle) { store.navigate(.event(selectedID), newTab: true) }
            guard store.selection == .event(selectedID) else { throw qualityFailure("Selection lost its event identity.") }
            await spacing()
            await measure("filter_and_agent", cycle: cycle) {
                store.navigate(.agent(agentID), newTab: true)
                store.agentFilter = agentID
            }
            guard !store.events.isEmpty, store.events.allSatisfy({ $0.agentID == agentID }) else { throw qualityFailure("Agent filter mixed owners.") }
            await spacing()
            let publication = corpus.publications[cycle]
            await measure("batch_publish_32", cycle: cycle) { store.snapshot = publication }
            guard store.snapshot?.events.count == options.eventCount + (cycle + 1) * 32,
                  store.selection == .agent(agentID) else { throw qualityFailure("Batch publication changed selection or lost records.") }
            await spacing()
            await measure("restore_filters_and_back", cycle: cycle) {
                store.resetFilters()
                store.goBack()
            }
            guard store.selection == .event(selectedID), store.events.count == publication.events.count else { throw qualityFailure("Back navigation did not restore the event and full projection.") }
            await spacing()
        }
        let sequenceMilliseconds = milliseconds(sequenceStart.duration(to: clock.now))
        let finalMeasuredEventCount = store.snapshot?.events.count ?? 0
        var functionalChecks: [String: Any] = ["compiledForVersion03": false]
        #if LENS_QUALITY_V03
        functionalChecks = try await verifyWindowAndCitationNavigation()
        #endif
        guard store.investigation.apiKey.isEmpty, !store.investigation.sending,
              try FileManager.default.contentsOfDirectory(atPath: options.emptyHome.path).isEmpty else { throw qualityFailure("The fixture-only/no-sender boundary changed.") }
        var statistics: [String: Any] = [:]
        let categories = Set(observations.compactMap { $0["action"] as? String })
        for category in categories.sorted() { statistics[category] = summary(observations.filter { $0["action"] as? String == category }.compactMap { $0["milliseconds"] as? Double }) }
        let report: [String: Any] = [
            "schemaVersion": 1, "sourceLabel": options.sourceLabel,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier!,
            "eventCount": options.eventCount,
            "finalEventCount": finalMeasuredEventCount,
            "agentCount": corpus.base.agents.count,
            "environmentCount": corpus.base.environments.count,
            "fixtureGenerationWallMilliseconds": generationMilliseconds,
            "openingAnd400msSettleWallMilliseconds": openingMilliseconds,
            "measurementStartedAt": measuredAt.ISO8601Format(),
            "measurementCompletedAt": Date().ISO8601Format(),
            "sequenceWallMillisecondsIncludingSpacing": sequenceMilliseconds,
            "measurementContract": "ContinuousClock wall: own store mutation, presentation preparation when enabled, one MainActor yield, AppKit layout/display and CATransaction.flush. Excludes fixture generation and 250ms between actions. Not compositor presentation latency, continuous scrolling or a responsiveness guarantee.",
            "statistics": statistics,
            "functionalChecks": functionalChecks,
            "presentationWaitEnabled": presentationWaitEnabled,
            "allActions": observations,
            "allActionStatistics": summary(observations.compactMap { $0["milliseconds"] as? Double }),
            "renders": renders,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "displayScale": window.backingScaleFactor,
            "buildConfiguration": "release",
            "apiKeySupplied": false, "modelRequests": 0,
            "networkDeniedByOS": true, "codexStartCalled": false,
            "sourceHomeEmptyAfterRun": true,
            "preferenceDomain": "fr.codexlens.qualityprobe",
            "verifiedActionCount": observations.count,
            "interactionMethod": "Own LensStore APIs and native view layout/display; no external UI automation",
            "percentileMethod": "Nearest rank; only five observations per category and twenty overall, no statistical assurance."
        ]
        try writeJSON(report, to: options.output.appendingPathComponent("quality-report.json"))
        print("QUALITY_COMPLETE actions=\(observations.count) report=\(options.output.appendingPathComponent("quality-report.json").path)")
        fflush(stdout)
        if options.linger { print("QUALITY_LINGER: own window remains open for profiling/observation."); fflush(stdout) }
        else { window.close() }
    }

    private func measure(_ name: String, cycle: Int, mutation: () -> Void) async {
        let start = clock.now
        mutation()
        await awaitPresentation()
        await Task.yield()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        host.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        observations.append(["action": name, "cycle": cycle, "milliseconds": milliseconds(start.duration(to: clock.now)), "eventCount": store.snapshot?.events.count ?? 0])
        try? writeJSON(["completedActions": observations.count, "actions": observations, "updatedAt": Date().ISO8601Format()], to: options.output.appendingPathComponent("quality-progress.json"))
        print("QUALITY_ACTION index=\(observations.count) name=\(name) milliseconds=\(observations.last!["milliseconds"]!)")
        fflush(stdout)
    }
    private func awaitPresentation() async {
        #if LENS_QUALITY_V03
        await store.waitForPresentation()
        #endif
    }
    private var presentationWaitEnabled: Bool {
        #if LENS_QUALITY_V03
        return true
        #else
        return false
        #endif
    }
    private func spacing() async { try? await Task.sleep(nanoseconds: 250_000_000) }
    private func install() {
        host = NSHostingView(rootView: AnyView(MainView().environmentObject(store).background(Color(nsColor: .windowBackgroundColor))))
        host.frame = NSRect(x: 0, y: 0, width: 1500, height: 900)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Lens — anonymised quality probe"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: false)
    }
    private func setTheme(_ theme: String) {
        UserDefaults.standard.set(theme, forKey: "lensAppearance")
        window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    }
    private func settle(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        CATransaction.flush()
    }
    private func capture(filename: String, theme: String, eventCount: Int) throws {
        try capture(view: host, filename: filename, theme: theme, eventCount: eventCount)
    }
    private func capture(view: NSView, filename: String, theme: String, eventCount: Int) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw qualityFailure("Native bitmap allocation failed.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw qualityFailure("Native bitmap encoding failed.") }
        try data.write(to: options.output.appendingPathComponent(filename), options: .atomic)
        renders.append(["filename": filename, "theme": theme, "eventCount": eventCount, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    }
    #if LENS_QUALITY_V03
    private func captureGallery() async throws {
        let fixture = LensDemoFixtures.snapshot(eventCount: 24)
        let gallery = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        gallery.isReleasedWhenClosed = false
        gallery.title = "Codex Lens — component gallery, synthetic fixtures"
        let cases: [(LensGallerySection, String, Bool, CGFloat)] = [(.identities, "light", false, 1200), (.differences, "dark", false, 1200), (.selection, "light", true, 800)]
        for (index, entry) in cases.enumerated() {
            let (section, theme, enlarged, width) = entry
            let view = NSHostingView(rootView: AnyView(ComponentGalleryView(snapshot: fixture, initialSection: section, enlargedText: enlarged).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(theme == "dark" ? .dark : .light)))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
            gallery.contentView = view
            gallery.setContentSize(view.frame.size)
            gallery.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            gallery.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
            try capture(view: view, filename: "gallery-\(index + 1)-\(section.rawValue)-\(theme).png", theme: theme, eventCount: 24)
        }
        gallery.close()
        window.makeKeyAndOrderFront(nil)
    }

    private func verifyWindowAndCitationNavigation() async throws -> [String: Any] {
        let small = LensDemoFixtures.snapshot(eventCount: 24)
        let scopeA = UUID().uuidString, scopeB = UUID().uuidString
        store.setNavigationScope(scopeA)
        store.snapshot = small
        store.resetFilters()
        await awaitPresentation()
        let peer = LensStore(sourceHome: options.emptyHome, investigationArchive: InvestigationArchive(directory: options.archive.appendingPathComponent("peer-window")))
        peer.setNavigationScope(scopeB)
        peer.snapshot = small; peer.showSessionPicker = false; peer.inspectorVisible = false
        await peer.waitForPresentation()
        let peerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        peerWindow.isReleasedWhenClosed = false
        let peerHost = NSHostingView(rootView: AnyView(MainView().environmentObject(peer).background(Color(nsColor: .windowBackgroundColor))))
        peerWindow.title = "Codex Lens — second synthetic navigation scope"
        peerWindow.contentView = peerHost
        peerWindow.orderFront(nil)
        peer.navigate(.event("fixture-event-16"), record: false)
        peer.agentFilter = small.agents[2].id
        peer.timelineZoom = 2
        peer.timelineOrigin = CGPoint(x: 42, y: 21)
        await peer.waitForPresentation()
        let peerSelection = peer.selection, peerFilter = peer.agentFilter, peerZoom = peer.timelineZoom, peerOrigin = peer.timelineOrigin

        store.agentFilter = small.agents[1].id
        store.timelineZoom = 3.5
        store.timelineOrigin = CGPoint(x: 111, y: 37)
        let firstWindow = LensDemoFixtures.epoch...LensDemoFixtures.epoch.addingTimeInterval(30)
        store.timelineWindow = firstWindow
        store.navigate(.event("fixture-event-9"), record: false)
        store.navigate(.agent(small.agents[2].id), newTab: true)
        store.agentFilter = small.agents[2].id
        store.timelineZoom = 6
        store.timelineOrigin = CGPoint(x: 211, y: 73)
        let secondWindow = LensDemoFixtures.epoch.addingTimeInterval(1)...LensDemoFixtures.epoch.addingTimeInterval(20)
        store.timelineWindow = secondWindow
        store.goBack()
        await awaitPresentation()
        guard store.selection == .event("fixture-event-9"), store.agentFilter == small.agents[1].id,
              store.timelineZoom == 3.5, store.timelineOrigin == CGPoint(x: 111, y: 37), store.timelineWindow == firstWindow else { throw qualityFailure("Back did not restore filter, zoom, origin and time window.") }
        store.goForward()
        await awaitPresentation()
        guard store.selection == .agent(small.agents[2].id), store.agentFilter == small.agents[2].id,
              store.timelineZoom == 6, store.timelineOrigin == CGPoint(x: 211, y: 73), store.timelineWindow == secondWindow else { throw qualityFailure("Forward did not restore its own checkpoint.") }
        guard peer.selection == peerSelection, peer.agentFilter == peerFilter, peer.timelineZoom == peerZoom, peer.timelineOrigin == peerOrigin else { throw qualityFailure("One window changed the other window's navigation state.") }
        let saved = UserDefaults.standard.dictionary(forKey: "lensTabsByRoot") ?? [:]
        guard scopeA != scopeB, saved[scopeA + "|" + small.root.id] != nil, saved[scopeB + "|" + small.root.id] != nil else { throw qualityFailure("Window persistence scopes collided.") }
        peerWindow.close()

        // Native component key handling, not keyboard injection into macOS.
        store.goBack()
        store.resetTimelineExtent()
        await awaitPresentation()
        await settle(milliseconds: 120)
        var keyboardVerified = false
        if let canvas = descendants(host).compactMap({ $0 as? TimelineCanvas }).first,
           let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124) {
            canvas.keyDown(with: key)
            keyboardVerified = store.selection == .event("fixture-event-17")
        }
        guard keyboardVerified else { throw qualityFailure("The timeline component right-arrow action did not select the next filtered event.") }

        let currentPath = options.output.appendingPathComponent("synthetic-current-file.swift")
        let frozenText = "let sample = 41\nlet fixtureOnly = true\n"
        try Data((String(repeating: "\n", count: 41) + frozenText).utf8).write(to: currentPath, options: .atomic)
        let initialFile = try await store.files.readText(path: currentPath.path)
        let location = EvidenceLocation(environmentID: small.environments[0].id, path: currentPath.path, versionKind: .capturedCurrent, version: initialFile.version, side: .unified, coordinates: .absolute, firstLine: 42, lastLine: 43)
        let piece = EvidencePiece(id: "E001", kind: "capturedCurrentCode", title: "Synthetic captured selection, lines 42–43", text: frozenText, environmentID: small.environments[0].id, knownVersion: initialFile.version, capturedAt: LensDemoFixtures.epoch, location: location)
        try store.investigation.append([piece], rootID: small.root.id, cut: small.collectedAt)
        guard let capsule = store.investigation.capsule else { throw qualityFailure("Synthetic citation capsule was not created.") }
        let bytes = try capsule.transmissionJSON()
        let digest = capsule.digestSHA256
        let address = try EvidenceAddress(rootID: small.root.id, capsuleID: capsule.id, pieceID: "E001")
        guard try EvidenceAddress(url: address.url) == address else { throw qualityFailure("Stable evidence URL did not round-trip.") }
        try Data("let sample = 99\n// CURRENT FILE MUST NOT SUBSTITUTE THE CAPTURE\n".utf8).write(to: currentPath, options: .atomic)
        var newer = small
        newer.events.removeAll { $0.id == "fixture-event-9" }
        newer.collectedAt = small.collectedAt.addingTimeInterval(10)
        store.snapshot = newer
        await awaitPresentation()
        await store.openEvidence(address)
        await settle(milliseconds: 180)
        try await awaitDocumentIndex(text: frozenText)
        guard store.selection == .evidence(capsule: capsule.id, piece: "E001"), store.investigation.inspectedPiece == "E001",
              let resolvedCapsule = store.investigation.capsule, try resolvedCapsule.transmissionJSON() == bytes,
              resolvedCapsule.digestSHA256 == digest, try address.resolve(in: resolvedCapsule).location == location,
              descendants(host).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == frozenText }) else { throw qualityFailure("Citation did not open exact captured text/coordinates after the snapshot and file changed.") }
        try capture(filename: "quality-frozen-citation.png", theme: "light", eventCount: newer.events.count)
        let beforeSelection = store.selection, beforePiece = store.investigation.inspectedPiece
        let invalid = try EvidenceAddress(rootID: small.root.id, capsuleID: capsule.id, pieceID: "E999")
        await store.openEvidence(invalid)
        guard store.error != nil, store.selection == beforeSelection, store.investigation.inspectedPiece == beforePiece,
              descendants(host).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == frozenText }) else { throw qualityFailure("An unavailable citation changed selection or substituted the current file.") }
        store.error = nil
        return ["compiledForVersion03": true, "distinctWindowScopes": true, "scopePreferencesSeparated": true,
                "backRestoresFiltersZoomOriginPeriod": true, "forwardRestoresOwnCheckpoint": true, "peerWindowUnchanged": true,
                "timelineNativeRightArrow": true, "citationURLRoundTrip": true, "frozenCitationAfterSourceChanges": true,
                "citationCoordinatesExact": true, "nativeCitationReaderIndexed": true, "invalidCitationPreservesSelectionAndFrozenText": true,
                "fixtureModelResponseUsed": false, "realModelResponseQualified": false]
    }
    private func awaitDocumentIndex(text: String) async throws {
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            if let document = descendants(host).compactMap({ $0 as? CodeDocumentHost }).first(where: { document in
                descendants(document).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == text })
            }), !descendants(document).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("Indexation…") }) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw qualityFailure("The native citation reader did not finish its line index within three seconds.")
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    #endif
    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
    }
    private func summary(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["count": 0] }
        let median = sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        return ["count": sorted.count, "minimum": sorted[0], "p50": median, "p95": sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "maximum": sorted.last!, "mean": sorted.reduce(0, +) / Double(sorted.count)]
    }
    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
}
private func qualityFailure(_ message: String) -> NSError { NSError(domain: "CodexLensNativeQuality", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
