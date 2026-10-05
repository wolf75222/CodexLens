import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Real native components in an owned, anonymous process. The launcher replaces
/// the product entrypoint and denies networking. No account/status method runs.
@main struct InteractionsV16Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let run = InteractionsV16Run()
        Task { @MainActor in
            do { try await run.run() } catch { run.recordFatal(error) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}

@MainActor private final class InteractionRenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class SearchFixtureState: ObservableObject {
    @Published var query = "alpha"
    @Published var focused = false
    var changes = 0
    var submits = 0
}

@MainActor private struct InteractionSearchFixture: View {
    @ObservedObject var state: SearchFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LensNativeSearchField(placeholder: LensL10n.text("Rechercher dans la session"), text: $state.query,
                                  focused: $state.focused, onChange: { state.changes += 1 }, onSubmit: { state.submits += 1 })
                .frame(height: 28)
            Text("Anonymous native search fixture").font(.caption)
        }.padding(12).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private final class InteractionsV16Run {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    private var receipt: [String: Any] = [:]
    private var windows: [NSWindow] = []
    private var stores: [LensStore] = []
    private var mainHost: NSHostingView<AnyView>?
    private var mainWindow: NSWindow?
    private var mainContext: LensWindowContext?
    private let epoch = Date(timeIntervalSince1970: 1_790_863_200)
    private let rootID = "11111111-1111-4111-8111-111111111111"
    private let childID = "33333333-3333-4333-8333-333333333333"

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let manifestData = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["anonymous"] as? Bool == true else { throw failure("Corpus must explicitly be anonymous.") }
        try FileManager.default.createDirectory(at: output.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        receipt["startedAt"] = Date().ISO8601Format()
        receipt["entrypoint"] = "InteractionsV16Main.swift"
        receipt["scope"] = "Actual app components in own native NSApplication; product @main replaced; anonymous deterministic fixture only."
        receipt["corpusManifestSHA256"] = digest(manifestData)
        receipt["realCodexHomeRead"] = false
        receipt["readerStarted"] = false
        receipt["networkDeniedByLauncher"] = true
        receipt["modelRequests"] = 0
        receipt["credentialAccess"] = false
        receipt["accountStatusMethodsInvoked"] = false
        receipt["systemPreferencesChanged"] = false
        receipt["clipboardAccess"] = false
        receipt["globalInputInjected"] = false
        receipt["interactionMethod"] = "Direct owned AppKit/delegate APIs and locally constructed mouse/key NSEvents, never posted to OS input; magnification callback on actual code view."
        setLanguage(.fr)
        try qualifyLocalization()
        try await qualifySearch()
        try qualifyPalette()
        let fixture = try makeSessionFixture()
        let store = makeStore("main")
        store.snapshot = fixture.snapshot; store.showSessionPicker = false; store.inspectorVisible = true
        await store.waitForPresentation()
        check("fixture-projection-ready", store.presentation != nil && store.timelineProjection?.eventCount == fixture.snapshot.events.count && !store.timelinePreparing)
        installMain(store, width: 1440, height: 780)
        guard let host = mainHost, let window = mainWindow else { throw failure("Native main host missing.") }
        try await settle(host)
        guard let initialSplit = mainSplit(in: host), let initialNavigation = initialSplit.arrangedSubviews.first,
              let initialInspector = initialSplit.arrangedSubviews.last else { throw failure("Native initial three-pane split unavailable.") }
        check("main-initial-navigation-width-is-228-points", abs(initialNavigation.bounds.width - 228) <= 2)
        check("main-initial-inspector-width-is-340-points", abs(initialInspector.bounds.width - 340) <= 2)
        observations.append(["kind": "initial-pane-proportions", "navigationWidth": initialNavigation.bounds.width,
                             "inspectorWidth": initialInspector.bounds.width, "tolerancePoints": 2, "method": "Actual arranged pane bounds, not requested frame values"])
        try await qualifyTimeline(store, host: host)
        try await qualifyMainThemesAndLanguages(store, host: host, window: window, events: fixture.snapshot.events)
        try await qualifyNativeSplitsAndFile(store, host: host, window: window, path: fixture.file.path, environment: fixture.environment.id, text: fixture.code)
        try await qualifyCodeMagnification()
        try await qualifyFrozenRequest(store, text: fixture.code, path: fixture.file.path, environment: fixture.environment.id)
        try await qualifyRootReplacement(store, host: host)
        receipt["unqualified"] = [
            "Own NSHostingView bitmap caching is a native component render, not a compositor screenshot or qualification of production startup.",
            "Locally constructed mouse/key events exercise component handlers; physical trackpad pinch, momentum, keyboard routing, Cmd shortcuts and OS event delivery are not qualified.",
            "Code magnification exercises the installed callback and reconfiguration on the same actual view, not the physical NSEvent magnify delivery path.",
            "Split resizing uses NSSplitView.setPosition and window geometry; physical divider dragging and every possible small-screen layout are not qualified.",
            "Sidebar hide/restore is unavailable in this standalone NSHostingView: SceneStorage has no WindowGroup scene. It is excluded from passed checks; separate production @main evidence is listed independently.",
            "Language and appearance choices are fixture-local. System accessibility preferences, VoiceOver, Increase Contrast, Reduce Transparency and real system language changes are not exercised.",
            "Request previews are produced without connecting an account or sending. ChatGPT eligibility, Codex login, OAuth, model availability, billing and remote responses remain unqualified by this probe.",
            "No performance gain, physical display calibration, Intel execution or macOS 14 runtime qualification is claimed."
        ]
        receipt["finishedAt"] = Date().ISO8601Format()
        await cleanUp()
        try saveReceipt()
    }

    private func qualifyLocalization() throws {
        check("localization-bundle-resource-exists", Bundle.main.url(forResource: "en", withExtension: "json", subdirectory: "Localizations") != nil)
        check("localization-catalogue-loaded", LensL10n.catalogueEntryCount > 100)
        setLanguage(.fr)
        check("localization-fr-exact-ui", LensL10n.text("Rechercher dans la session") == "Rechercher dans la session")
        setLanguage(.en)
        check("localization-en-exact-ui", LensL10n.text("Rechercher dans la session") == "Search session")
        check("localization-en-parameter-values-preserved", LensL10n.text("Source : {0} octets · lectures/vérifications : {1}", "17", "2") == "Source: 17 bytes · reads/verifications: 2")
        check("localization-known-ui-runtime-parameters", LensL10n.display("Source : 17 octets · lectures/vérifications : 2") == "Source: 17 bytes · reads/verifications: 2")
        check("localization-unknown-source-not-rewritten", LensL10n.display("let source = \"éà 🧭 original\";") == "let source = \"éà 🧭 original\";")
        setLanguage(.fr)
    }

    private func qualifySearch() async throws {
        let state = SearchFixtureState()
        let host = NSHostingView(rootView: InteractionSearchFixture(state: state)); host.sizingOptions = []
        let window = makeWindow(size: NSSize(width: 570, height: 130), title: "Native search · anonymous")
        host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size); window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        guard let field = descendants(host).compactMap({ $0 as? NSSearchField }).first,
              let cell = field.cell as? NSSearchFieldCell else { throw failure("Actual native search field/cell unavailable.") }
        check("search-has-native-search-icon", cell.searchButtonCell != nil && cell.searchButtonRect(forBounds: field.bounds).width > 0)
        check("search-has-native-clear-affordance", cell.cancelButtonCell != nil && cell.cancelButtonRect(forBounds: field.bounds).width > 0)
        check("search-recents-not-persisted", field.maximumRecents == 0 && field.recentsAutosaveName == nil && field.recentSearches.isEmpty)
        check("search-binding-to-native-initial", field.stringValue == state.query)
        field.stringValue = "βeta recorded"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        check("search-native-delegate-updates-binding", state.query == "βeta recorded" && state.changes == 1)
        check("search-change-does-not-submit", state.submits == 0)
        state.query = "alpha binding update"
        try await settle(host)
        check("search-binding-update-retains-native-control", descendants(host).contains { $0 === field } && field.stringValue == state.query)
        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        check("search-clear-delegate-synchronizes-empty-query", state.query.isEmpty && state.changes == 2 && state.submits == 0)
        state.query = "native cancel action"
        try await settle(host)
        // NSSearchField's cancel cell empties the control and invokes its action,
        // without necessarily issuing controlTextDidChange. Exercise that real
        // NSControl target/action path, independently of the delegate above.
        field.stringValue = ""
        let clearDispatched = field.sendAction(field.action, to: field.target)
        check("search-native-clear-target-action-synchronizes-binding", clearDispatched && state.query.isEmpty && state.changes == 3)
        check("search-native-clear-target-action-does-not-submit", state.submits == 0)
        let repeatedClearDispatched = field.sendAction(field.action, to: field.target)
        check("search-repeated-clear-target-action-does-not-duplicate-change", repeatedClearDispatched && state.changes == 3 && state.submits == 0)
        state.focused = true
        try await settle(host)
        check("search-programmatic-window-focus", field.currentEditor() != nil)
        state.focused = false; window.makeFirstResponder(nil)
        window.close()
    }

    private func qualifyPalette() throws {
        for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { throw failure("Native appearance unavailable.") }
            for (surface, color) in [("window", NSColor.windowBackgroundColor), ("text", NSColor.textBackgroundColor), ("control", NSColor.controlBackgroundColor)] {
                let foreground = try resolved(LensBrand.inkNSColor, appearance: appearance)
                let background = try resolved(color, appearance: appearance)
                let ratio = contrast(foreground, background)
                check("brand-ink-\(theme)-\(surface)-contrast-at-least-4.5", ratio >= 4.5)
                observations.append(["kind": "brand-ink-contrast", "theme": theme, "surface": surface,
                                     "foregroundSRGBA": rgba(foreground), "backgroundSRGBA": rgba(background), "contrastRatio": ratio,
                                     "method": "Actual named-appearance NSColors, sRGB, alpha composed"])
            }
        }
    }

    private func makeSessionFixture() throws -> (snapshot: SessionSnapshot, environment: EnvironmentRecord, file: URL, code: String) {
        let environmentPath = output.appendingPathComponent("runtime/worktrees/alpha", isDirectory: true)
        let sourceDir = environmentPath.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let file = sourceDir.appendingPathComponent("Investigation.swift")
        let code = "// Original anonymous fixture · éà 🧭\nlet recorded = \"Activité\" + 42\n" + (1...160).map { "let line\($0) = \($0) // recorded context\n" }.joined()
        try Data(code.utf8).write(to: file, options: .atomic)
        let events = (0..<28).map { index in
            let kind: EventKind = index % 7 == 0 ? .user : index % 7 == 1 ? .delegation : index % 7 == 2 ? .wait : index % 7 == 3 ? .error : .toolCall
            return LensEvent(id: "anonymous-event-\(index)", timestamp: epoch.addingTimeInterval(Double(index * 30)),
                             endTime: kind == .toolCall ? epoch.addingTimeInterval(Double(index * 30) + 1) : nil,
                             agentID: index % 2 == 0 ? rootID : childID, kind: kind,
                             title: index == 12 ? "Activité" : "Recorded event \(index)",
                             preview: index == 12 ? "Enquête séparée" : "Original recorded evidence · éà 🧭 · \(index)",
                             toolName: kind == .toolCall ? "recorded_read" : nil,
                             callID: kind == .toolCall ? "anonymous-call-\(index)" : nil,
                             environmentID: environmentPath.path,
                             source: SourceRef(path: output.appendingPathComponent("runtime/not-a-journal.jsonl").path, offset: UInt64(index)), isError: kind == .error)
        }
        let environment = EnvironmentRecord(path: environmentPath.path, repositoryPath: environmentPath.path,
                                            recordedBranch: "anonymous/alpha", agentIDs: [rootID, childID], eventIDs: events.map(\.id), evidence: "Anonymous environment fixture")
        let snapshot = SessionSnapshot(root: SessionSummary(id: rootID, title: "Anonymous session · alpha", cwd: environmentPath.path),
            agents: [AgentRecord(id: rootID, name: "Alpha", mission: "Inspect recorded evidence"),
                     AgentRecord(id: childID, parentID: rootID, name: "Beta", relation: .subagent, mission: "Read original fixture", environmentIDs: [environment.id])],
            events: events, environments: [environment], collectedAt: epoch.addingTimeInterval(900))
        return (snapshot, environment, file, code)
    }

    private func qualifyTimeline(_ store: LensStore, host: NSView) async throws {
        guard let table = eventTable(in: host), let canvas = timelineCanvas(in: host), let scroll = canvas.enclosingScrollView else { throw failure("Actual ActivityView table/timeline unavailable.") }
        check("activity-native-table-and-indexed-canvas", table.numberOfRows == 28 && canvas.projection?.eventCount == 28)
        let selected = "anonymous-event-12"
        store.navigate(.event(selected))
        try await settle(host)
        guard let item = canvas.projection?.item(id: selected), let geometry = canvas.geometry else { throw failure("Selected timeline item unavailable.") }
        check("cross-view-navigation-selects-list-and-timeline", table.selectedRow == 12 && canvas.selectedID == selected && store.selectedEvent?.id == selected)
        check("cross-view-navigation-reveals-timeline-item", itemVisible(item, geometry: geometry, scroll: scroll))
        check("cross-view-navigation-reveals-table-row", table.rect(ofRow: 12).intersects(table.visibleRect))
        check("fine-marker-navigation-uses-bounded-zoom", store.timelineZoom >= 1 && store.timelineZoom <= 8)

        let nextID = "anonymous-event-13"
        guard let next = canvas.projection?.item(id: nextID), let window = canvas.window else { throw failure("Adjacent timeline item/window unavailable.") }
        let rect = geometry.rect(for: next)
        let point = NSPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        check("timeline-local-click-fixture-is-visible-and-unambiguous", canvas.visibleRect.contains(point) && canvas.projection?.hitTest(x: Double(point.x), y: Double(point.y), geometry: geometry).eventIDs == [nextID])
        try click(canvas, point: point, window: window, count: 1)
        try await settle(host)
        check("timeline-native-click-updates-store-list-inspection-target", store.selectedEvent?.id == nextID && canvas.selectedID == nextID && table.selectedRow == 13)

        table.selectRowIndexes(IndexSet(integer: 17), byExtendingSelection: false)
        try await settle(host)
        check("native-list-selection-updates-shared-timeline-target", store.selectedEvent?.id == "anonymous-event-17" && canvas.selectedID == "anonymous-event-17")

        let token = store.timelineFocus?.token
        scroll.contentView.scroll(to: NSPoint(x: min(500, max(0, canvas.bounds.width - scroll.contentSize.width)), y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        let panned = scroll.contentView.bounds.origin
        let listOrigin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let zoom = store.timelineZoom, selectedBeforeAppend = store.selection, axisBeforeAppend = store.timelineWindow
        guard var append = store.snapshot else { throw failure("Fixture snapshot unavailable.") }
        append.events.append(LensEvent(id: "anonymous-new-live-event", timestamp: epoch.addingTimeInterval(1200), agentID: rootID, kind: .assistant, title: "New recorded fixture event", preview: "New bytes do not move the reader", source: SourceRef(path: "/anonymous/unread-new-event.jsonl")))
        store.snapshot = append
        await store.waitForPresentation(); try await settle(host)
        check("live-publication-keeps-focus-intent-selection-and-zoom", store.timelineFocus?.token == token && store.selection == selectedBeforeAppend && canvas.selectedID == "anonymous-event-17" && store.timelineZoom == zoom)
        check("live-publication-keeps-user-pan-and-axis", near(scroll.contentView.bounds.origin, panned) && store.timelineWindow == axisBeforeAppend)
        check("live-publication-keeps-list-reading-position", near(table.enclosingScrollView?.contentView.bounds.origin ?? .zero, listOrigin))
        check("live-publication-preserves-all-events", table.numberOfRows == 29 && canvas.projection?.eventCount == 29)

        let filters = (store.agentFilter, store.environmentFilter, store.period)
        store.focusTimelineEvent("anonymous-event-17", zoom: true)
        try await settle(host)
        guard let focused = canvas.projection?.item(id: "anonymous-event-17"), let bounds = canvas.projection?.bounds,
              let expected = TimelineInteraction.focusWindow(for: focused, within: bounds), let focusedGeometry = canvas.geometry else { throw failure("Explicit focus unavailable.") }
        check("explicit-focus-request-consumed-with-known-window", store.timelineWindow == (bounds.start...bounds.end) && store.timelineZoom > 1 && focusedGeometry.window == bounds)
        check("explicit-focus-keeps-filters", store.agentFilter == filters.0 && store.environmentFilter == filters.1 && store.period == filters.2)
        check("explicit-focus-keeps-selected-event-visible", canvas.selectedID == "anonymous-event-17" && itemVisible(focused, geometry: focusedGeometry, scroll: scroll))
        let focusTokenBeforeDoubleClick = store.timelineFocus?.token
        let focusedRect = focusedGeometry.rect(for: focused)
        try click(canvas, point: NSPoint(x: focusedRect.x + focusedRect.width / 2, y: focusedRect.y + focusedRect.height / 2), window: window, count: 2)
        try await settle(host)
        check("timeline-local-double-click-publishes-and-consumes-zoom-focus", store.timelineFocus?.zoomToEvent == true && store.timelineFocus?.token != focusTokenBeforeDoubleClick && store.timelineWindow == (bounds.start...bounds.end) && store.timelineZoom > 1 && canvas.selectedID == focused.id)
        let beforeKeyboard = store.timelineZoom
        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24) {
            canvas.keyDown(with: key)
        } else { throw failure("Local key event unavailable.") }
        check("timeline-local-plus-key-uses-shared-zoom", store.timelineZoom > beforeKeyboard)
        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            canvas.keyDown(with: key)
        } else { throw failure("Local Return event unavailable.") }
        try await settle(host)
        check("timeline-local-return-frames-current-selection", store.timelineZoom > 1 && store.timelineWindow == (bounds.start...bounds.end) && store.selectedEvent?.id == focused.id)
        store.focusTimelineEvent(focused.id, zoom: true)
        await Task.yield()
        store.resetTimelineExtent()
        try await settle(host)
        check("timeline-reset-cancels-pending-focus-and-keeps-all-bounds", store.timelineFocus == nil && store.timelineZoom == 1 && store.timelineWindow == (bounds.start...bounds.end) && near(scroll.contentView.bounds.origin, .zero) && store.selectedEvent?.id == focused.id)
        observations.append(["kind": "timeline-interactions", "eventCountAfterAppend": 29, "selectedID": canvas.selectedID ?? "", "pannedViewport": [panned.x, panned.y], "explicitFocusDuration": expected.duration, "localMouseClickCount": 1, "eventsPostedToOS": false])
        store.resetTimelineExtent(); store.navigate(.event("anonymous-event-12"))
        try await settle(host)
    }

    private func qualifyMainThemesAndLanguages(_ store: LensStore, host: NSView, window: NSWindow, events: [LensEvent]) async throws {
        guard let originalTable = eventTable(in: host), let tableScroll = originalTable.enclosingScrollView else { throw failure("Actual event table before language update unavailable.") }
        let originalRow = originalTable.selectedRow, originalOrigin = tableScroll.contentView.bounds.origin
        for language in [LensL10n.Language.fr, .en] {
            setLanguage(language); store.objectWillChange.send()
            for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                UserDefaults.standard.set(theme, forKey: "lensAppearance"); window.appearance = NSAppearance(named: name)
                try await settle(host)
                guard let table = eventTable(in: host), let canvas = timelineCanvas(in: host),
                      let cell = table.view(atColumn: 0, row: 12, makeIfNecessary: true),
                      let swatch = descendants(cell).compactMap({ $0 as? LensEventSwatch }).first else { throw failure("Actual themed event cell unavailable.") }
                let fields = descendants(cell).compactMap { $0 as? NSTextField }
                let expectedKind = language == .fr ? "Appel" : "Call"
                let expectedDate = events[12].timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: language.rawValue)))
                check("locale-\(language.rawValue)-\(theme)-visible-native-event-kind-and-date-update", fields.contains { $0.stringValue == expectedKind } && fields.contains { $0.stringValue == expectedDate })
                check("locale-\(language.rawValue)-\(theme)-same-table-row-and-reading-position", table === originalTable && table.selectedRow == originalRow && near(tableScroll.contentView.bounds.origin, originalOrigin))
                check("locale-\(language.rawValue)-\(theme)-recorded-title-and-preview-stay-verbatim", fields.contains { $0.stringValue == "Activité" } && fields.contains { $0.stringValue == "Enquête séparée" })
                check("brand-\(language.rawValue)-\(theme)-pastel-is-swatch-not-text", swatch.tint.isEqual(LensBrand.eventNSColor(events[12].kind)) && fields.allSatisfy { field in
                    guard let color = field.textColor else { return true }
                    return !color.isEqual(LensBrand.eventNSColor(events[12].kind))
                })
                check("locale-\(language.rawValue)-\(theme)-native-timeline-accessibility-label", canvas.accessibilityLabel() == (language == .fr ? "Chronologie des événements par agent" : "Event timeline by agent"))
                if let field = descendants(host).compactMap({ $0 as? NSSearchField }).first {
                    check("locale-\(language.rawValue)-\(theme)-native-search-placeholder", field.placeholderString == (language == .fr ? "Rechercher dans les traces enregistrées…" : "Search recorded traces…"))
                } else { throw failure("Actual main native search unavailable.") }
                check("theme-\(language.rawValue)-\(theme)-selection-preserved", store.selectedEvent?.id == "anonymous-event-12" && table.selectedRow == 12 && canvas.selectedID == "anonymous-event-12")
                observations.append(["kind": "live-native-event-language-update", "language": language.rawValue, "theme": theme,
                                     "expectedKind": expectedKind, "expectedDate": expectedDate, "visibleStrings": fields.map(\.stringValue),
                                     "tableOrigin": [tableScroll.contentView.bounds.origin.x, tableScroll.contentView.bounds.origin.y], "selectedRow": table.selectedRow])
                try capture(host, filename: "interactions-main-\(language.rawValue)-\(theme).png", scenario: "MainView ActivityView native search, timeline/list selection and adjustable inspectors", language: language.rawValue, theme: theme)
            }
        }
    }

    private func qualifyNativeSplitsAndFile(_ store: LensStore, host: NSView, window: NSWindow, path: String, environment: String, text: String) async throws {
        setLanguage(.fr); UserDefaults.standard.set("light", forKey: "lensAppearance"); window.appearance = NSAppearance(named: .aqua)
        store.navigate(.file(environment: environment, path: path)); try await settle(host)
        try await waitFor { descendants(host).compactMap({ $0 as? CodeReadOnlyTextView }).contains { $0.string == text } }
        guard let document = descendants(host).compactMap({ $0 as? CodeDocumentHost }).first,
              let editor = descendants(document).compactMap({ $0 as? CodeReadOnlyTextView }).first,
              let scroll = editor.enclosingScrollView else { throw failure("Actual current-file code reader unavailable.") }
        try await waitFor { descendants(document).compactMap({ $0 as? NSTextField }).contains { $0.stringValue.contains("Swift") && !$0.stringValue.contains("Indexation") && !$0.stringValue.contains("Indexing") } }
        check("file-reader-analysis-finishes-before-baseline", descendants(document).compactMap({ $0 as? NSTextField }).contains { $0.stringValue.contains("Swift") && !$0.stringValue.contains("Indexation") && !$0.stringValue.contains("Indexing") })
        let selected = (text as NSString).range(of: "éà 🧭")
        guard selected.location != NSNotFound else { throw failure("Unicode file selection unavailable.") }
        editor.setSelectedRange(selected)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        // Keep AppKit's native negative X reserved for the line ruler. X = 0
        // would establish a clipped artificial baseline at the document start.
        let baselineBounds = scroll.contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: scroll.contentView.bounds.minX, y: 120), size: scroll.contentView.bounds.size))
        scroll.contentView.scroll(to: baselineBounds.origin); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        let viewport = scroll.contentView.bounds.origin
        var viewportStages = [codeViewportObservation("baseline", editor: editor, document: document, scroll: scroll)]
        let metadataBefore = descendants(document).compactMap({ $0 as? NSTextField }).map(\.stringValue)
        let nativeSplits = descendants(host).compactMap { $0 as? NSSplitView }
        check("main-has-real-native-resizable-splits", !nativeSplits.isEmpty)
        guard let split = mainSplit(in: host), let context = mainContext else { throw failure("Actual navigation/content/inspector NSSplitView or context unavailable.") }
        let widthsBefore = split.arrangedSubviews.map { $0.frame.width }
        let firstDivider = split.arrangedSubviews[0].frame.maxX
        split.setPosition(firstDivider + (widthsBefore[0] >= 420 ? -60 : 60), ofDividerAt: 0)
        try await settle(host)
        viewportStages.append(codeViewportObservation("navigation-divider", editor: editor, document: document, scroll: scroll))
        let widthsAfter = split.arrangedSubviews.map { $0.frame.width }
        check("main-native-divider-redistributes-pane-widths", widthsAfter.count == widthsBefore.count && zip(widthsBefore, widthsAfter).contains { abs($0.0 - $0.1) >= 10 })
        let inspectorBefore = split.arrangedSubviews.last!.bounds.width
        let inspectorTarget: CGFloat = inspectorBefore >= 320 ? 280 : 360
        split.setPosition(split.bounds.width - inspectorTarget - split.dividerThickness, ofDividerAt: split.arrangedSubviews.count - 2)
        try await settle(host)
        viewportStages.append(codeViewportObservation("inspector-divider", editor: editor, document: document, scroll: scroll))
        let draggedNavigation = split.arrangedSubviews.first!.bounds.width
        let draggedInspector = split.arrangedSubviews.last!.bounds.width
        check("main-inspector-native-divider-redistributes-width", abs(draggedInspector - inspectorBefore) >= 10)
        check("main-context-remembers-real-dragged-pane-widths", abs((context.paneWidths["navigation"] ?? -1) - draggedNavigation) <= 2 && abs((context.paneWidths["inspector"] ?? -1) - draggedInspector) <= 2)
        guard context.sidebarVisibility != nil else { throw failure("Actual sidebar visibility binding unavailable.") }
        let sidebarBefore = context.sidebarVisibility?.wrappedValue
        let paneCountBeforeHide = split.arrangedSubviews.count
        context.toggleSidebar(); try await settle(host)
        viewportStages.append(codeViewportObservation("sidebar-hide-attempt", editor: editor, document: document, scroll: scroll))
        let sidebarAfterHide = context.sidebarVisibility?.wrappedValue
        let paneCountAfterHide = split.arrangedSubviews.count
        let rememberedNavigationAfterHide = context.paneWidths["navigation"]
        context.toggleSidebar(); try await settle(host)
        viewportStages.append(codeViewportObservation("sidebar-restore-attempt", editor: editor, document: document, scroll: scroll))
        let sidebarAfterRestore = context.sidebarVisibility?.wrappedValue
        guard mainSplit(in: host) != nil else { throw failure("Native split unavailable after restoring sidebar.") }
        receipt["excludedFromPassed"] = [["scenario": "main-sidebar-hide-restore", "status": "unavailable-in-standalone-host",
                                          "reason": "SceneStorage binding outside a WindowGroup remains true; no sidebar hide occurred in this process.",
                                          "bindingBefore": sidebarBefore.map { $0 ? "true" : "false" } ?? "unavailable",
                                          "bindingAfterHide": sidebarAfterHide.map { $0 ? "true" : "false" } ?? "unavailable",
                                          "paneCountBefore": paneCountBeforeHide, "paneCountAfter": paneCountAfterHide]]
        let productionEvidencePaths = ["/private/tmp/CodexLens-v16-cua/11-sidebar-hidden.ax.txt",
                                       "/private/tmp/CodexLens-v16-cua/12-sidebar-restored.ax.txt",
                                       "/private/tmp/CodexLens-v16-cua/16-resized-panes.ax.txt"]
        receipt["externalProductionEvidence"] = productionEvidencePaths.map { path -> [String: Any] in
            var reference: [String: Any] = ["path": path,
                                           "scope": "Separate production @main CUA observation, source UUID60604116; not counted among standalone passed checks",
                                           "reportedBy": "Parent integration run"]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                reference["available"] = true; reference["sha256"] = digest(data)
            } else {
                reference["available"] = false; reference["reason"] = "External production evidence unavailable on this machine."
            }
            return reference
        }
        store.inspectorVisible = false; try await settle(host)
        viewportStages.append(codeViewportObservation("inspector-hidden", editor: editor, document: document, scroll: scroll))
        check("main-inspector-hides-without-forgetting-dragged-width", abs((context.paneWidths["inspector"] ?? -1) - draggedInspector) <= 2)
        store.inspectorVisible = true; try await settle(host)
        viewportStages.append(codeViewportObservation("inspector-restored", editor: editor, document: document, scroll: scroll))
        guard let restoredInspectorSplit = mainSplit(in: host) else { throw failure("Native split unavailable after restoring inspector.") }
        let restoredNavigationWidth = restoredInspectorSplit.arrangedSubviews.first!.bounds.width
        let restoredInspectorWidth = restoredInspectorSplit.arrangedSubviews.last!.bounds.width
        check("main-inspector-restore-keeps-native-dragged-width", abs(restoredInspectorWidth - draggedInspector) <= 2)
        check("main-restored-pane-widths-remain-within-product-limits", (190...480).contains(restoredNavigationWidth) && (240...900).contains(restoredInspectorWidth))
        let changed = "// MANUAL FIXTURE CHANGE AFTER THE RECORDED READ\nlet now = \"v2 must not silently replace loaded v1\"\n"
        try Data(changed.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        window.setContentSize(NSSize(width: 1090, height: 780)); try await settle(host)
        viewportStages.append(codeViewportObservation("window-narrowed", editor: editor, document: document, scroll: scroll))
        let metadataAfterResize = descendants(document).compactMap({ $0 as? NSTextField }).map(\.stringValue)
        let viewportAfterResize = scroll.contentView.bounds.origin
        let expectedViewportAfterResize = scroll.contentView.constrainBoundsRect(NSRect(origin: viewport, size: scroll.contentView.bounds.size)).origin
        let selectionAfterResize = editor.selectedRange()
        check("file-resize-retains-native-code-instance", descendants(host).contains { $0 === document } && descendants(document).contains { $0 === editor })
        check("file-resize-does-not-silently-reread-manual-change", editor.string == text && !editor.string.contains("v2 must not"))
        check("file-resize-keeps-version-metadata-and-selection", metadataAfterResize == metadataBefore && selectionAfterResize == selected)
        check("file-pane-and-window-resize-keeps-semantic-reading-anchor", viewportStages.allSatisfy { sameCodeReadingAnchor(viewportStages[0], $0) })
        store.inspectorVisible = false; try await settle(host)
        let narrowInspectorHidden = codeViewportObservation("narrow-inspector-hidden", editor: editor, document: document, scroll: scroll)
        viewportStages.append(narrowInspectorHidden)
        check("file-inspector-toggle-keeps-loaded-version", descendants(host).contains { $0 === document } && editor.string == text && editor.selectedRange() == selected)
        check("file-narrow-inspector-toggle-keeps-semantic-reading-anchor", sameCodeReadingAnchor(viewportStages[0], narrowInspectorHidden))
        store.inspectorVisible = true; window.setContentSize(NSSize(width: 1440, height: 780)); try await settle(host)
        let restoredReading = codeViewportObservation("window-restored", editor: editor, document: document, scroll: scroll)
        viewportStages.append(restoredReading)
        check("file-restored-layout-keeps-existing-version", descendants(host).contains { $0 === document } && editor.string == text)
        check("file-restored-window-and-inspector-keep-semantic-reading-anchor", sameCodeReadingAnchor(viewportStages[0], restoredReading))
        try capture(host, filename: "interactions-file-fr-light.png", scenario: "Loaded v1 remains exact after own source file changed to v2 and native panes resized", language: "fr", theme: "light")
        setLanguage(.en); UserDefaults.standard.set("dark", forKey: "lensAppearance"); window.appearance = NSAppearance(named: .darkAqua); store.objectWillChange.send()
        try await settle(host)
        check("file-locale-and-theme-retain-text-selection-and-native-editor", descendants(host).contains { $0 === document } && editor.string == text && editor.selectedRange() == selected)
        try capture(host, filename: "interactions-file-en-dark.png", scenario: "Same loaded code and exact environment across language/appearance change", language: "en", theme: "dark")
        observations.append(["kind": "native-splits-loaded-file", "path": path, "environment": environment, "widthsBefore": widthsBefore, "widthsAfter": widthsAfter,
                             "draggedNavigationWidth": draggedNavigation, "draggedInspectorWidth": draggedInspector,
                             "restoredNavigationWidth": restoredNavigationWidth, "restoredInspectorWidth": restoredInspectorWidth,
                             "sidebarBindingBefore": sidebarBefore.map { $0 ? "true" : "false" } ?? "unavailable",
                             "sidebarBindingAfterHide": sidebarAfterHide.map { $0 ? "true" : "false" } ?? "unavailable",
                             "sidebarBindingAfterRestore": sidebarAfterRestore.map { $0 ? "true" : "false" } ?? "unavailable",
                             "nativePaneCountBeforeHide": paneCountBeforeHide, "nativePaneCountAfterHide": paneCountAfterHide,
                             "navigationWidthRememberedWhileHidden": rememberedNavigationAfterHide ?? -1,
                             "viewportStages": viewportStages,
                             "viewportBeforeResize": [viewport.x, viewport.y], "viewportAfterResize": [viewportAfterResize.x, viewportAfterResize.y],
                             "expectedViewportAfterNativeConstraint": [expectedViewportAfterResize.x, expectedViewportAfterResize.y],
                             "selectionAfterResizeUTF16": [selectionAfterResize.location, selectionAfterResize.length],
                             "loadedV1SHA256": digest(Data(text.utf8)), "currentOwnFixtureV2SHA256": digest(Data(changed.utf8)), "selectedUTF16": [selected.location, selected.length],
                             "versionMetadataBefore": metadataBefore, "versionMetadataAfterResize": metadataAfterResize,
                             "method": "Own fixture content changed deliberately; retained loaded bytes/metadata/instance observed, no invented read counter; same visible UTF16/line plus fragment-relative offset preserved through native reflow, raw Y may change"])
    }

    /// Observe the document's visible range as well as the raw clip origin.
    /// A raw coordinate change alone cannot distinguish native frame adjustment
    /// from a change to the text the user was reading.
    private func codeViewportObservation(_ stage: String, editor: NSTextView, document: NSView, scroll: NSScrollView) -> [String: Any] {
        func rectValues(_ rect: NSRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
        var result: [String: Any] = ["stage": stage,
                                    "clipBounds": rectValues(scroll.contentView.bounds),
                                    "clipFrame": rectValues(scroll.contentView.frame),
                                    "documentVisibleRect": rectValues(scroll.documentVisibleRect),
                                    "editorVisibleRect": rectValues(editor.visibleRect),
                                    "editorFrame": rectValues(editor.frame),
                                    "editorBounds": rectValues(editor.bounds),
                                    "scrollFrame": rectValues(scroll.frame),
                                    "hostFrame": rectValues(document.frame),
                                    "editorFlipped": editor.isFlipped,
                                    "clipFlipped": scroll.contentView.isFlipped,
                                    "hostFlipped": document.isFlipped,
                                    "textContainerOrigin": [editor.textContainerOrigin.x, editor.textContainerOrigin.y]]
        if let manager = editor.layoutManager, let container = editor.textContainer {
            let origin = editor.textContainerOrigin
            let visible = scroll.documentVisibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
            if glyphs.location < manager.numberOfGlyphs {
                let character = manager.characterIndexForGlyph(at: glyphs.location)
                let prefix = (editor.string as NSString).substring(to: character)
                result["firstVisibleUTF16"] = character
                result["firstVisibleLine"] = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                result["visibleGlyphRange"] = [glyphs.location, glyphs.length]
                let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                result["firstVisibleFragment"] = rectValues(fragment)
                result["firstVisibleFragmentOffset"] = scroll.contentView.bounds.minY - origin.y - fragment.minY
            }
        }
        return result
    }

    private func sameCodeReadingAnchor(_ before: [String: Any], _ after: [String: Any]) -> Bool {
        guard let characterBefore = before["firstVisibleUTF16"] as? Int,
              let characterAfter = after["firstVisibleUTF16"] as? Int,
              let lineBefore = before["firstVisibleLine"] as? Int,
              let lineAfter = after["firstVisibleLine"] as? Int,
              let offsetBefore = before["firstVisibleFragmentOffset"] as? CGFloat,
              let offsetAfter = after["firstVisibleFragmentOffset"] as? CGFloat else { return false }
        return characterBefore == characterAfter && lineBefore == lineAfter && abs(offsetBefore - offsetAfter) <= 1
    }

    private func qualifyCodeMagnification() async throws {
        let text = "let exact = \"enregistré 🧭\" + 42 // café e\u{301}\r\n" + (1...180).map { "let valeur\($0) = \($0) // contexte\r\n" }.joined()
        let host = CodeDocumentHost(frame: NSRect(x: 0, y: 0, width: 920, height: 560))
        let window = makeWindow(size: host.bounds.size, title: "Code magnification · anonymous")
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        var fontSize = 13.0, calls = 0
        func install() {
            host.install(text: text, path: "/anonymous/alpha/src/Exact.swift", versionLabel: "Recorded fixture-v1", requestedLine: nil,
                         fontSize: fontSize, onSelection: nil, onLineNavigate: nil, onMagnify: { delta in
                calls += 1; fontSize = Double(LensUI.readingSize(fontSize * (1 + Double(delta)))); install()
            })
        }
        install(); try await settle(host)
        guard let editor = descendants(host).compactMap({ $0 as? CodeReadOnlyTextView }).first,
              let scroll = editor.enclosingScrollView else { throw failure("Actual magnification code view unavailable.") }
        try await waitFor { descendants(host).compactMap({ $0 as? NSTextField }).contains { $0.stringValue.contains("Swift") && !$0.stringValue.contains("Indexation") && !$0.stringValue.contains("Indexing") } }
        check("code-analysis-finishes-before-magnification-baseline", descendants(host).compactMap({ $0 as? NSTextField }).contains { $0.stringValue.contains("Swift") && !$0.stringValue.contains("Indexation") && !$0.stringValue.contains("Indexing") })
        let selected = (text as NSString).range(of: "enregistré 🧭")
        guard selected.location != NSNotFound else { throw failure("Actual Unicode code fixture missing.") }
        editor.setSelectedRange(selected)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        let baselineBounds = scroll.contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: scroll.contentView.bounds.minX, y: 280), size: scroll.contentView.bounds.size))
        scroll.contentView.scroll(to: baselineBounds.origin); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        let origin = scroll.contentView.bounds.origin, oldFont = editor.font?.pointSize ?? 0
        check("code-magnification-callback-is-installed-on-real-editor", editor.onMagnify != nil)
        editor.onMagnify?(0.15); try await settle(host)
        let afterOrigin = scroll.contentView.bounds.origin
        let expectedOrigin = scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentView.bounds.size)).origin
        let afterSelection = editor.selectedRange()
        check("code-magnification-callback-changes-real-font", calls == 1 && (editor.font?.pointSize ?? 0) > oldFont)
        check("code-magnification-retains-real-editor-and-exact-bytes", descendants(host).contains { $0 === editor } && Data(editor.string.utf8) == Data(text.utf8))
        check("code-magnification-retains-utf16-selection-and-viewport", afterSelection == selected && abs(afterOrigin.y - origin.y) <= 1 && near(afterOrigin, expectedOrigin))
        observations.append(["kind": "code-magnification", "method": "Installed actual CodeReadOnlyTextView.onMagnify callback invoked directly", "physicalTrackpadQualified": false,
                             "oldFontSize": oldFont, "newFontSize": editor.font?.pointSize ?? 0, "textSHA256": digest(Data(editor.string.utf8)),
                             "selectionUTF16": [selected.location, selected.length], "selectionAfterUTF16": [afterSelection.location, afterSelection.length],
                             "viewportBefore": [origin.x, origin.y], "viewport": [afterOrigin.x, afterOrigin.y],
                             "expectedViewportAfterNativeConstraint": [expectedOrigin.x, expectedOrigin.y],
                             "horizontalComparison": "Native NSClipView constraints include the ruler; the fixture establishes an unscrolled native left edge, not X=0", "verticalTolerancePoints": 1])
        host.cancelAnalysis(); window.close()
    }

    private func qualifyFrozenRequest(_ store: LensStore, text: String, path: String, environment: String) async throws {
        let version = "fixture-sha-" + digest(Data(text.utf8))
        let piece = EvidencePiece(id: "E001", kind: "capturedCurrentCode", title: "Captured anonymous v1", text: text,
                                  environmentID: environment, knownVersion: version,
                                  location: EvidenceLocation(environmentID: environment, path: path, versionKind: .capturedCurrent, version: version, firstLine: 1))
        let capsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: epoch.addingTimeInterval(900), pieces: [piece])
        let capturedBytes = try capsule.transmissionJSON()
        store.investigation.capsule = capsule; store.investigation.question = "Pourquoi cette version précise ?"
        store.investigation.model = "fixture-model"; store.investigation.connectionMode = .chatgpt
        let preview = InvestigationPresentationCache()
        let input = InvestigationPresentationInput(rootID: rootID, capsuleID: capsule.id, capsuleDigest: capsule.digestSHA256, response: nil,
                                                  question: store.investigation.question, model: store.investigation.model, includePayload: true, connectionMode: "chatgpt", language: "en")
        let prepared = try await preview.prepare(capsule: capsule, input: input)
        guard let payload = prepared.payload, let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw failure("Actual request preview unavailable.") }
        check("request-preview-is-frozen-valid-request-with-no-tools", prepared.payloadIsRequest && prepared.payloadIssue == nil && object["store"] as? Bool == false && (object["tools"] as? [Any])?.isEmpty == true && object["tool_choice"] as? String == "none")
        check("request-preview-language-only-affects-instructions", (object["instructions"] as? String)?.contains("Answer in English") == true && payload.contains("Pourquoi cette version précise") && payload.contains("Original anonymous fixture"))
        let afterBytes = try capsule.transmissionJSON()
        check("request-preview-preserves-captured-version-after-source-change", payload.contains("fixture-sha-" + digest(Data(text.utf8))) && !payload.contains("v2 must not silently") && afterBytes == capturedBytes)
        check("request-preview-preparation-is-off-main-thread", prepared.preparedOffMainThread)
        check("request-preview-does-not-connect-send-or-gather-credentials", !store.investigation.connecting && !store.investigation.sending && store.investigation.chatGPTAccount == nil && store.investigation.chatGPTModels.isEmpty && store.investigation.apiKey.isEmpty && store.investigation.response == nil)
        observations.append(["kind": "frozen-request-preview", "capsuleID": capsule.id, "digestSHA256": capsule.digestSHA256, "requestSHA256": digest(Data(payload.utf8)), "requestBytes": payload.utf8.count,
                             "sourceBytesVersion": "captured v1", "currentOwnFixtureVersion": "v2", "model": "fixture-model", "modelValidatedRemotely": false, "networkRequests": 0])
    }

    private func qualifyRootReplacement(_ store: LensStore, host: NSView) async throws {
        store.section = .activity; store.navigate(.event("anonymous-event-17")); store.focusTimelineEvent("anonymous-event-17", zoom: true)
        let other = "99999999-9999-4999-8999-999999999999"
        store.snapshot = SessionSnapshot(root: SessionSummary(id: other, title: "Other anonymous session"), agents: [AgentRecord(id: other, name: "Other")],
            events: [LensEvent(id: "other-event", timestamp: epoch.addingTimeInterval(7000), agentID: other, kind: .assistant, title: "Other root evidence", source: SourceRef(path: "/anonymous/other.jsonl"))])
        await store.waitForPresentation(); try await settle(host)
        check("root-switch-clears-previous-focus-intent", store.timelineFocus == nil && store.selectedEvent == nil)
        check("root-switch-does-not-apply-old-focus-window", store.timelineWindow?.lowerBound == epoch.addingTimeInterval(7000) && timelineCanvas(in: host)?.projection?.orderedEventIDs == ["other-event"])
    }

    private func setLanguage(_ value: LensL10n.Language) {
        UserDefaults.standard.set(value.rawValue, forKey: "lens.language"); LensL10n.language = value
    }
    private func makeStore(_ name: String) -> LensStore {
        let runtime = output.appendingPathComponent("runtime/" + name)
        let store = LensStore(sourceHome: runtime.appendingPathComponent("empty-codex-home"),
                              investigationArchive: InvestigationArchive(directory: runtime.appendingPathComponent("archive")), cacheDirectory: runtime.appendingPathComponent("cache"))
        stores.append(store); return store
    }
    private func installMain(_ store: LensStore, width: CGFloat, height: CGFloat) {
        let context = LensWindowContext(store: store); mainContext = context
        let host = NSHostingView(rootView: AnyView(MainView().environmentObject(store).environment(\.lensWindowContext, context).background(Color(nsColor: .windowBackgroundColor))))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = makeWindow(size: host.frame.size, title: "Codex Lens interactions · anonymous")
        window.contentView = host; window.backgroundColor = .windowBackgroundColor; context.attach(window)
        window.makeKeyAndOrderFront(nil); mainHost = host; mainWindow = window
    }
    private func makeWindow(size: NSSize, title: String) -> NSWindow {
        let window = InteractionRenderWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = title; windows.append(window); return window
    }
    private func eventTable(in host: NSView) -> NSTableView? {
        descendants(host).compactMap({ $0 as? NSTableView }).first { $0.tableColumns.count == 1 && $0.tableColumns[0].identifier.rawValue == "event" }
    }
    private func mainSplit(in host: NSView) -> NSSplitView? {
        descendants(host).compactMap({ $0 as? NSSplitView }).first { $0.isVertical && $0.arrangedSubviews.count >= 3 }
    }
    private func timelineCanvas(in host: NSView) -> TimelineCanvas? { descendants(host).compactMap({ $0 as? TimelineCanvas }).first }
    private func itemVisible(_ item: TimelineItem, geometry: TimelineGeometry, scroll: NSScrollView) -> Bool {
        let rect = geometry.rect(for: item), visible = scroll.contentView.bounds
        let plot = NSRect(x: visible.minX + geometry.labelWidth, y: visible.minY, width: max(0, visible.width - geometry.labelWidth), height: visible.height)
        return plot.intersects(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }
    private func click(_ view: NSView, point: NSPoint, window: NSWindow, count: Int) throws {
        let location = view.convert(point, to: nil), timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: timestamp,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: timestamp + 0.01,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0) else { throw failure("Local owned mouse event unavailable.") }
        view.mouseDown(with: down); view.mouseUp(with: up)
    }
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.window?.displayIfNeeded(); CATransaction.flush()
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<80 { if condition() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw failure("Timed out waiting for native fixture content.")
    }
    private func capture(_ view: NSView, filename: String, scenario: String, language: String, theme: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Native bitmap allocation failed.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw failure("Native PNG encoding failed.") }
        try bytes.write(to: output.appendingPathComponent(filename))
        check("render-nonempty-" + filename, bytes.count > 4096 && bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        renders.append(["filename": filename, "scenario": scenario, "language": language, "theme": theme, "bytes": bytes.count, "sha256": digest(bytes),
                        "logicalWidth": view.bounds.width, "logicalHeight": view.bounds.height, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                        "anonymous": true, "method": "Own native view bitmap caching; not compositor screenshot"])
    }
    private func resolved(_ color: NSColor, appearance: NSAppearance) throws -> NSColor {
        var result: NSColor?; appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        guard let result else { throw failure("Native color resolution failed.") }; return result
    }
    private func rgba(_ color: NSColor) -> [Double] { [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)] }
    private func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        let f = rgba(foreground), b = rgba(background), effective = (0..<3).map { f[$0] * f[3] + b[$0] * (1 - f[3]) }
        func luminance(_ values: [Double]) -> Double {
            let linear = values.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let x = luminance(effective), y = luminance(Array(b.prefix(3))); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private func near(_ a: NSPoint, _ b: NSPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
    private func saveReceipt() throws {
        receipt["checks"] = checks; receipt["renders"] = renders; receipt["observations"] = observations
        receipt["allExecutedChecksPassed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        receipt["failedCheckIDs"] = checks.filter { $0["passed"] as? Bool == false }.compactMap { $0["id"] as? String }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"), options: .atomic)
    }
    private func cleanUp() async {
        for store in stores { store.stopObserving(); await store.investigation.flushAndStop() }
        for window in windows { window.close() }
    }
    func recordFatal(_ error: Error) {
        checks.append(["id": "fatal", "passed": false, "message": error.localizedDescription])
        for store in stores { store.stopObserving() }; for window in windows { window.close() }
        receipt["finishedAt"] = Date().ISO8601Format(); try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw failure("Missing " + name) }
        return CommandLine.arguments[index + 1]
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensInteractionsV16", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
