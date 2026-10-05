import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Real native components in an owned, anonymous process. The launcher replaces
/// the product entrypoint and denies networking. No account/status method runs.
@main struct VersionsV18Main {
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

private struct NativeVersionFixture: Sendable {
    let directory: URL
    let currentFile: URL
    let environment: EnvironmentRecord
    let file: RecordedFileDiff
    let reconstructable: RecordedFileDiff
    let largeFile: RecordedFileDiff
    let before: String
    let after: String
    let reconstructed: String
    let manualCurrent: String
    let largeText: String
    let commit: String
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
        receipt["entrypoint"] = "VersionsV18Main.swift"
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
        try await qualifyZoom(fixture.snapshot)
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
        try await qualifyFileVersions()
        receipt["unqualified"] = [
            "Own NSHostingView bitmap caching is a native component render, not a compositor screenshot or qualification of production startup.",
            "Locally constructed mouse/key events exercise component handlers; physical trackpad pinch, momentum, keyboard routing, Cmd shortcuts and OS event delivery are not qualified.",
            "Code magnification exercises the installed callback and reconfiguration on the same actual view, not the physical NSEvent magnify delivery path.",
            "Split resizing uses NSSplitView.setPosition and window geometry; physical divider dragging and every possible small-screen layout are not qualified.",
            "Sidebar hide/restore is unavailable in this standalone NSHostingView: SceneStorage has no WindowGroup scene. It is excluded from passed checks; separate production @main evidence is listed independently.",
            "Language and appearance choices are fixture-local. System accessibility preferences, VoiceOver, Increase Contrast, Reduce Transparency and real system language changes are not exercised.",
            "Request previews are produced without connecting an account or sending. ChatGPT eligibility, Codex login, OAuth, model availability, billing and remote responses remain unqualified by this probe.",
            "Version fixtures prove cited blob bytes/reconstruction, not event-time worktree state, authorship or action application. Missing IDs stay unavailable; no hooks are installed.",
            "Version reading restoration replaces an owned RecordedChangeView with a placeholder then remounts it and exercises native popup target/action. The production Back command path remains a separate GUI qualification.",
            "Version latency samples are local cold-process-cache/warm-process-cache probes, not a before/after 0.17 app performance comparison. Filesystem caches are not flushed; CPU, allocations and hangs are not measured here.",
            "No performance gain, physical display calibration, Intel execution or macOS 14 runtime qualification is claimed."
        ]
        receipt["finishedAt"] = Date().ISO8601Format()
        await cleanUp()
        try saveReceipt()
    }


    private func qualifyZoom(_ snapshot: SessionSnapshot) async throws {
        let suite = "fr.codexlens.zoom-probe." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw failure("Private settings suite unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LensReadingPreferences(defaults: defaults)
        check("zoom-defaults-are-native-reading-defaults", preferences.configuration == LensReadingConfiguration())
        preferences.setDefaultSize(17); preferences.setTextStep(2); preferences.setTimelineStep(0.5)
        preferences.setTimelineShortcuts(false); preferences.setPinchEnabled(false)
        let restored = LensReadingPreferences(defaults: defaults)
        check("zoom-all-settings-survive-new-instance", restored.configuration == preferences.configuration)
        preferences.setDefaultSize(.nan); preferences.setTextStep(.infinity); preferences.setTimelineStep(-100)
        check("zoom-invalid-values-bounded", preferences.configuration.defaultSize == 13 && preferences.configuration.textStep == 1 && preferences.configuration.timelineStep == 0.05)
        preferences.setDefaultSize(500); preferences.setTextStep(100); preferences.setTimelineStep(500)
        check("zoom-upper-bounds", preferences.configuration.defaultSize == 24 && preferences.configuration.textStep == 4 && preferences.configuration.timelineStep == 1)
        preferences.reset()
        check("zoom-reset-persists-all-defaults", LensReadingPreferences(defaults: defaults).configuration == LensReadingConfiguration())
        let base = output.appendingPathComponent("runtime/zoom", isDirectory: true)
        let archive = InvestigationArchive(directory: base.appendingPathComponent("investigations"))
        let store = LensStore(sourceHome: base, investigationArchive: archive, cacheDirectory: base.appendingPathComponent("cache"), readingPreferences: preferences)
        let second = LensStore(sourceHome: base, investigationArchive: archive, cacheDirectory: base.appendingPathComponent("cache2"), readingPreferences: preferences)
        store.fontSize = 15
        check("zoom-reading-current-size-is-window-local", second.fontSize == 13)
        preferences.setDefaultSize(16)
        check("zoom-default-setting-updates-open-windows", store.fontSize == 16 && second.fontSize == 16)
        preferences.setTextStep(2)
        store.perform(.largerText)
        check("zoom-custom-text-step", store.fontSize == 18 && second.fontSize == 16)
        preferences.setPinchEnabled(false); store.magnifyReading(0.25)
        check("zoom-disabled-pinch-keeps-reading-size", store.fontSize == 18)
        preferences.setPinchEnabled(true); store.magnifyReading(0.25)
        check("zoom-enabled-pinch-adjusts-reading-size", store.fontSize == 22.5)
        store.fontSize = 24; store.perform(.largerText)
        check("zoom-text-upper-bound", store.fontSize == 24 && !store.canPerform(.largerText))
        store.fontSize = 10; store.perform(.smallerText)
        check("zoom-text-lower-bound", store.fontSize == 10 && !store.canPerform(.smallerText))
        store.fontSize = 16
        store.snapshot = snapshot; await store.waitForPresentation()
        let window = makeWindow(size: NSSize(width: 860, height: 300), title: "Native zoom routing · anonymous")
        let scroll = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 860, height: 300))
        let canvas = TimelineCanvas(frame: .zero); scroll.documentView = canvas
        let coordinator = TimelineView.Coordinator()
        coordinator.attach(scroll, store: store)
        window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        coordinator.configure(store: store)
        let context = LensWindowContext(store: store); context.attach(window)
        check("zoom-does-not-require-a-running-session-reader", !store.isObserving && context.canAdjustZoom(.increase))
        defer { coordinator.detach(); context.close(); second.stopObserving(); window.close() }
        try await settle(scroll)
        window.makeFirstResponder(canvas)
        preferences.setTimelineStep(0.5)
        let selectedID = snapshot.events[12].id
        store.navigate(.event(selectedID)); store.timelineZoom = 2
        coordinator.configure(store: store)
        store.timelineOrigin = NSPoint(x: 80, y: 0); coordinator.configure(store: store)
        let oldOrigin = scroll.contentView.bounds.minX
        let oldGeometry = canvas.geometry!
        let focal = (CGFloat(oldGeometry.labelWidth) + scroll.contentSize.width) / 2
        let oldDate = oldGeometry.date(atX: Double(oldOrigin + focal), clamped: false)
        func key(_ characters: String, modifiers: NSEvent.ModifierFlags = .command, target: NSWindow? = nil) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: (target ?? window).windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0) else { throw failure("Owned native key unavailable") }
            return event
        }
        check("zoom-command-plus-routes-focused-timeline", context.handleZoomShortcut(try key("+")) && store.timelineZoom == 3 && store.fontSize == 16)
        let newDate = canvas.geometry!.date(atX: Double(scroll.contentView.bounds.minX + focal), clamped: false)
        check("zoom-timeline-keeps-temporal-midpoint", abs(newDate.timeIntervalSince(oldDate)) < 0.001)
        check("zoom-timeline-keeps-selection", store.selectedEvent?.id == selectedID)
        check("zoom-command-minus-inverts-custom-step", context.handleZoomShortcut(try key("-")) && abs(store.timelineZoom - 2) < 0.00001)
        check("zoom-command-equals-alias", context.handleZoomShortcut(try key("=")) && store.timelineZoom == 3)
        check("zoom-command-zero-resets-timeline", context.handleZoomShortcut(try key("0")) && store.timelineZoom == 1 && store.fontSize == 16)
        preferences.setTimelineShortcuts(false)
        check("zoom-text-only-setting-overrides-timeline-focus", context.handleZoomShortcut(try key("+")) && store.fontSize == 18 && store.timelineZoom == 1)
        preferences.setTimelineShortcuts(true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let holder = NSView(frame: scroll.frame); holder.addSubview(field); window.contentView = holder
        window.makeFirstResponder(field)
        check("zoom-search-field-does-not-retarget-visible-timeline", context.handleZoomShortcut(try key("=")) && store.fontSize == 20 && store.timelineZoom == 1)
        check("zoom-command-zero-resets-to-configured-reading-default", context.handleZoomShortcut(try key("0")) && store.fontSize == 16)
        check("zoom-plain-typing-is-not-consumed", !context.handleZoomShortcut(try key("+", modifiers: [])) && store.fontSize == 16)
        check("zoom-control-modifier-is-not-consumed", !context.handleZoomShortcut(try key("+", modifiers: [.command, .control])))
        check("zoom-option-modifier-is-not-consumed", !context.handleZoomShortcut(try key("+", modifiers: [.command, .option])))
        check("zoom-unrelated-command-is-not-consumed", !context.handleZoomShortcut(try key("f")))
        let otherWindow = makeWindow(size: NSSize(width: 200, height: 100), title: "Other owned window")
        check("zoom-other-window-event-is-not-consumed", !context.handleZoomShortcut(try key("+", target: otherWindow)))
        otherWindow.close()
        let host = CodeDocumentHost(frame: NSRect(x: 0, y: 0, width: 680, height: 300))
        window.contentView = host
        let text = (1...220).map { "let exact\($0) = \"éà 🧭 code\($0)\" // recorded line\n" }.joined()
        func install() { host.install(text: text, path: "/anonymous/zoom/Exact.swift", versionLabel: "Recorded fixture-v1", requestedLine: nil, fontSize: store.fontSize, onSelection: nil, onLineNavigate: nil) }
        install(); try await settle(host)
        guard let editor = descendants(host).compactMap({ $0 as? CodeReadOnlyTextView }).first,
              let codeScroll = editor.enclosingScrollView else { throw failure("Zoom code reader missing") }
        window.makeFirstResponder(editor)
        let selection = (text as NSString).range(of: "éà 🧭 code1")
        editor.setSelectedRange(selection)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        codeScroll.contentView.scroll(to: NSPoint(x: 0, y: 400)); codeScroll.reflectScrolledClipView(codeScroll.contentView)
        try await settle(host)
        let before = codeViewportObservation("before-shortcut", editor: editor, document: host, scroll: codeScroll)
        check("zoom-command-plus-routes-real-reader", context.handleZoomShortcut(try key("+")) && store.fontSize == 18)
        install(); try await settle(host)
        let after = codeViewportObservation("after-shortcut", editor: editor, document: host, scroll: codeScroll)
        check("zoom-font-change-preserves-reading-anchor", sameCodeReadingAnchor(before, after))
        check("zoom-font-change-preserves-version-bytes-and-selection", editor.string == text && editor.selectedRange() == selection && (editor.accessibilityHelp() ?? "").contains("Recorded fixture-v1"))
        check("zoom-new-labels-translate-in-english", { setLanguage(.en); return LensL10n.text("Zoom et raccourcis") == "Zoom and shortcuts" }())
        setLanguage(.fr)
        observations.append(["kind": "zoom-v17", "settingsSuiteIsolated": true, "realUserDefaultsTouched": false, "commands": ["⌘+", "⌘=", "⌘−", "⌘0"],
            "beforeFontAnchor": before, "afterFontAnchor": after, "physicalKeyboardOrTrackpadInjected": false])
        context.close()
        let closedSize = store.fontSize
        check("zoom-closed-window-rejects-command", !context.handleZoomShortcut(try key("+")) && store.fontSize == closedSize)
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
        check("explicit-focus-request-consumed-with-known-window", store.timelineWindow == (expected.start...expected.end) && store.timelineZoom == 1 && focusedGeometry.window == expected)
        check("explicit-focus-keeps-filters", store.agentFilter == filters.0 && store.environmentFilter == filters.1 && store.period == filters.2)
        check("explicit-focus-keeps-selected-event-visible", canvas.selectedID == "anonymous-event-17" && itemVisible(focused, geometry: focusedGeometry, scroll: scroll))
        let focusTokenBeforeDoubleClick = store.timelineFocus?.token
        let focusedRect = focusedGeometry.rect(for: focused)
        try click(canvas, point: NSPoint(x: focusedRect.x + focusedRect.width / 2, y: focusedRect.y + focusedRect.height / 2), window: window, count: 2)
        try await settle(host)
        check("timeline-local-double-click-publishes-and-consumes-zoom-focus", store.timelineFocus?.zoomToEvent == true && store.timelineFocus?.token != focusTokenBeforeDoubleClick && store.timelineWindow == (expected.start...expected.end) && canvas.selectedID == focused.id)
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
        check("timeline-local-return-frames-current-selection", store.timelineZoom == 1 && store.timelineWindow == (expected.start...expected.end) && store.selectedEvent?.id == focused.id)
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
        let beforeAnchor = codeViewportObservation("before-font-zoom", editor: editor, document: host, scroll: scroll)
        check("code-magnification-callback-is-installed-on-real-editor", editor.onMagnify != nil)
        editor.onMagnify?(0.15); try await settle(host)
        let afterOrigin = scroll.contentView.bounds.origin
        let afterAnchor = codeViewportObservation("after-font-zoom", editor: editor, document: host, scroll: scroll)
        let afterSelection = editor.selectedRange()
        check("code-magnification-callback-changes-real-font", calls == 1 && (editor.font?.pointSize ?? 0) > oldFont)
        check("code-magnification-retains-real-editor-and-exact-bytes", descendants(host).contains { $0 === editor } && Data(editor.string.utf8) == Data(text.utf8))
        check("code-magnification-retains-utf16-selection-and-viewport", afterSelection == selected && sameCodeReadingAnchor(beforeAnchor, afterAnchor))
        observations.append(["kind": "code-magnification", "method": "Installed actual CodeReadOnlyTextView.onMagnify callback invoked directly", "physicalTrackpadQualified": false,
                             "oldFontSize": oldFont, "newFontSize": editor.font?.pointSize ?? 0, "textSHA256": digest(Data(editor.string.utf8)),
                             "selectionUTF16": [selected.location, selected.length], "selectionAfterUTF16": [afterSelection.location, afterSelection.length],
                             "viewportBefore": [origin.x, origin.y], "viewport": [afterOrigin.x, afterOrigin.y],
                             "readingAnchorBefore": beforeAnchor, "readingAnchorAfter": afterAnchor,
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

    private func qualifyFileVersions() async throws {
        let directory = output.appendingPathComponent("runtime/verified-versions")
        let fixture = try await Task.detached(priority: .utility) {
            try Self.makeVersionFixture(at: directory)
        }.value
        let files = FileService()
        let inspection = FileVersionInspection()
        check("versions-full-index-parser-keeps-two-distinct-blob-identities", fixture.file.beforeBlobID == RecordedFileVersion.objectID(text: fixture.before)
              && fixture.file.afterBlobID == RecordedFileVersion.objectID(text: fixture.after) && fixture.file.beforeBlobID != fixture.file.afterBlobID)
        await inspection.load(file: fixture.file, environment: fixture.environment, mode: .before, files: files)
        check("versions-before-model-loads-original-verified-blob", inspection.version?.text == fixture.before && inspection.version?.objectID == fixture.file.beforeBlobID
              && inspection.version?.kind == .gitBlob && inspection.issue == nil && !inspection.loading)
        await inspection.load(file: fixture.file, environment: fixture.environment, mode: .after, files: files)
        check("versions-after-model-loads-cited-bytes-despite-manual-current-file", inspection.version?.text == fixture.after && inspection.version?.objectID == fixture.file.afterBlobID
              && inspection.version?.text != fixture.manualCurrent && inspection.issue == nil)
        let comparisonStart = DispatchTime.now().uptimeNanoseconds
        await inspection.load(file: fixture.file, environment: fixture.environment, mode: .comparison, files: files)
        let comparisonMS = milliseconds(since: comparisonStart)
        let comparison = inspection.comparison?.document
        let comparisonLines = comparison?.files.flatMap { $0.hunks.flatMap(\.lines) } ?? []
        check("versions-comparison-uses-both-cited-versions-and-absolute-coordinates", comparison?.coverage == .completeTextsAvailable
              && comparison?.provenance.beforeReference == fixture.file.beforeBlobID && comparison?.provenance.afterReference == fixture.file.afterBlobID
              && comparisonLines.contains { $0.kind == .removed && $0.text.contains("before action") }
              && comparisonLines.contains { $0.kind == .added && $0.text.contains("after action") }
              && !comparisonLines.contains { $0.text.contains("manual current") })
        await inspection.load(file: fixture.file, environment: fixture.environment, mode: .gitReference, files: files)
        check("versions-environment-commit-remains-separate-baseline", inspection.version?.text == fixture.before && inspection.version?.baseObjectID == fixture.commit)
        await inspection.load(file: fixture.reconstructable, environment: fixture.environment, mode: .after, files: files)
        check("versions-missing-target-object-reconstructed-from-verified-base", inspection.version?.text == fixture.reconstructed
              && inspection.version?.kind == .reconstructed && inspection.version?.objectID == fixture.reconstructable.afterBlobID
              && inspection.version?.baseObjectID == fixture.reconstructable.beforeBlobID && inspection.issue == nil)
        let reconstructionStart = DispatchTime.now().uptimeNanoseconds
        let exactReconstruction = try await Task.detached(priority: .utility) {
            try RecordedFileVersion.reconstruct(file: fixture.reconstructable, base: fixture.before, side: .after)
        }.value
        let reconstructionMS = milliseconds(since: reconstructionStart)
        check("versions-pure-reconstruction-target-digest-matches", exactReconstruction.text == fixture.reconstructed
              && exactReconstruction.objectID == RecordedFileVersion.objectID(text: fixture.reconstructed))
        let beforeWrongScope = await files.blobCacheStatistics()
        await inspection.load(file: fixture.file, environment: EnvironmentRecord(path: directory.appendingPathComponent("wrong-worktree").path, repositoryPath: directory.path), mode: .before, files: files)
        let afterWrongScope = await files.blobCacheStatistics()
        check("versions-wrong-source-environment-refused-before-blob-lookup", inspection.version == nil && inspection.comparison == nil && inspection.issue != nil
              && beforeWrongScope.loads == afterWrongScope.loads && beforeWrongScope.hits == afterWrongScope.hits)
        var missing = fixture.file; missing.beforeBlobID = nil; missing.afterBlobID = nil
        await inspection.load(file: missing, environment: fixture.environment, mode: .after, files: files)
        check("versions-no-full-identities-clears-previous-version-and-keeps-explicit-issue", inspection.version == nil && inspection.comparison == nil && inspection.issue != nil && !inspection.loading)

        let cancellationFiles = FileService()
        let cancellable = FileVersionInspection()
        let cancelledLoad = Task { @MainActor in await cancellable.load(file: fixture.largeFile, environment: fixture.environment, mode: .before, files: cancellationFiles) }
        var observedLoading = false
        for _ in 0..<200 {
            if await cancellationFiles.blobCacheStatistics().readers > 0, cancellable.loading { observedLoading = true; break }
            await Task.yield()
        }
        cancellable.cancel(); cancelledLoad.cancel(); await cancelledLoad.value
        check("versions-cancelled-inspection-does-not-publish-old-bytes-or-error", observedLoading && !cancellable.loading
              && cancellable.version == nil && cancellable.comparison == nil && cancellable.issue == nil)
        let supersededLoad = Task { @MainActor in await cancellable.load(file: fixture.largeFile, environment: fixture.environment, mode: .before, files: cancellationFiles) }
        for _ in 0..<200 {
            if await cancellationFiles.blobCacheStatistics().readers > 0, cancellable.loading { break }
            await Task.yield()
        }
        await cancellable.load(file: fixture.file, environment: fixture.environment, mode: .after, files: cancellationFiles)
        await supersededLoad.value
        check("versions-new-inspection-is-not-replaced-by-superseded-large-result", cancellable.version?.text == fixture.after
              && cancellable.version?.objectID == fixture.file.afterBlobID && cancellable.comparison == nil && cancellable.issue == nil && !cancellable.loading)
        for _ in 0..<40 {
            if await cancellationFiles.blobCacheStatistics().inFlight == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check("versions-completed-or-cancelled-requests-leave-no-in-flight-entry", await cancellationFiles.blobCacheStatistics().inFlight == 0)

        let benchmarkFiles = FileService()
        let initialCache = await benchmarkFiles.blobCacheStatistics()
        let coldStart = DispatchTime.now().uptimeNanoseconds
        let cold = try await benchmarkFiles.recordedBlob(environment: fixture.environment, recordedPath: "src/Large.swift", objectID: fixture.largeFile.beforeBlobID!)
        let coldMS = milliseconds(since: coldStart)
        let coldCache = await benchmarkFiles.blobCacheStatistics()
        var warmMS: [Double] = []
        var warmExact = true
        for _ in 0..<10 {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = try await benchmarkFiles.recordedBlob(environment: fixture.environment, recordedPath: "src/Large.swift", objectID: fixture.largeFile.beforeBlobID!)
            warmMS.append(milliseconds(since: start)); warmExact = warmExact && value.text == fixture.largeText && value.objectID == fixture.largeFile.beforeBlobID
        }
        let warmCache = await benchmarkFiles.blobCacheStatistics()
        check("versions-large-cold-and-ten-warm-reads-return-identical-verified-bytes", cold.text == fixture.largeText && warmExact && warmMS.count == 10)
        check("versions-large-cache-statistics-are-one-load-ten-hits-within-budget", initialCache.entries == 0 && coldCache.loads == 1
              && warmCache.loads == 1 && warmCache.hits == 10 && warmCache.entries == 1 && warmCache.bytes == fixture.largeText.utf8.count
              && warmCache.bytes <= FileService.blobCacheBudget && warmCache.inFlight == 0)
        observations.append(["kind": "verified-file-version-latencies", "dataset": "anonymous UTF-8 Git blob; 40000 lines; no large SwiftUI diff render",
                             "largeUTF8Bytes": fixture.largeText.utf8.count, "largeLines": 40_000, "coldRecordedBlobMilliseconds": coldMS,
                             "warmRecordedBlobMilliseconds": warmMS, "smallComparisonMilliseconds": comparisonMS, "smallReconstructionMilliseconds": reconstructionMS,
                             "smallBeforeUTF8Bytes": fixture.before.utf8.count, "smallAfterUTF8Bytes": fixture.after.utf8.count,
                             "initialCache": cacheObservation(initialCache), "afterColdCache": cacheObservation(coldCache), "afterWarmCache": cacheObservation(warmCache),
                             "clock": "DispatchTime monotonic; awaited component call including scheduling and verification",
                             "coldMeaning": "fresh FileService process cache; filesystem cache not flushed", "beforeAfterGlobalGainClaimed": false])

        let store = makeStore("versions-native")
        let event = LensEvent(id: "anonymous-version-call", timestamp: epoch, agentID: rootID, kind: .toolCall, title: "Recorded anonymous patch", toolName: "apply_patch",
                              callID: "anonymous-version-call", environmentID: fixture.environment.id, source: fixture.file.provenance.sources[0])
        store.snapshot = SessionSnapshot(root: SessionSummary(id: rootID, title: "Anonymous cited file versions", cwd: fixture.environment.id),
                                         agents: [AgentRecord(id: rootID, name: "Anonymous version agent")], events: [event], environments: [fixture.environment],
                                         collectedAt: epoch)
        store.showSessionPicker = false; await store.waitForPresentation()
        for language in [LensL10n.Language.fr, .en] {
            setLanguage(language)
            for (theme, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                var cases: [(String, RecordedFileDiff, FileVersionPresentation, String?)] = [
                    ("after", fixture.file, .after, fixture.after), ("missing", missing, .after, nil)
                ]
                if language == .fr && theme == "light" { cases += [("before", fixture.file, .before, fixture.before), ("comparison", fixture.file, .comparison, nil)] }
                if language == .en && theme == "dark" { cases += [("reconstruction", fixture.reconstructable, .after, fixture.reconstructed), ("comparison", fixture.file, .comparison, nil)] }
                for (name, file, mode, expectedText) in cases {
                    let host = NSHostingView(rootView: AnyView(RecordedFileVersionsView(file: file, identity: "anonymous-" + name, mode: mode).environmentObject(store)
                        .environment(\.locale, Locale(identifier: language.rawValue)).background(Color(nsColor: .windowBackgroundColor))))
                    host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1020, height: 700)
                    let window = makeWindow(size: host.bounds.size, title: "Cited versions · anonymous")
                    window.appearance = NSAppearance(named: appearanceName); window.contentView = host; window.makeKeyAndOrderFront(nil)
                    try await settle(host)
                    if let expectedText {
                        try await waitFor { descendants(host).compactMap({ $0 as? CodeReadOnlyTextView }).contains { $0.string == expectedText } }
                        guard let editor = descendants(host).compactMap({ $0 as? CodeReadOnlyTextView }).first(where: { $0.string == expectedText }),
                              let scroll = editor.enclosingScrollView else { throw failure("Native cited-version reader unavailable.") }
                        let selectedText = name == "reconstruction" ? "reconstructed target" : mode == .before ? "before action" : "after action"
                        let expectedObject = mode == .before ? file.beforeBlobID : file.afterBlobID
                        let selection = (expectedText as NSString).range(of: selectedText)
                        editor.setSelectedRange(selection)
                        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
                        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: scroll.contentView.bounds.minX, y: 120), size: scroll.contentView.bounds.size)).origin)
                        scroll.reflectScrolledClipView(scroll.contentView); try await settle(host)
                        check("versions-native-reader-selectable-readonly-scrollable-" + name + "-" + language.rawValue + "-" + theme, !editor.isEditable && editor.isSelectable
                              && editor.selectedRange() == selection && editor.string == expectedText && scroll.contentView.bounds.minY > 0 && editor.bounds.height > scroll.contentView.bounds.height)
                        let capsuleBeforeSelection = store.investigation.capsule
                        let inspectedBeforeSelection = store.investigation.inspectedPiece
                        editor.onInvestigateSelection?(selection, selectedText)
                        guard let capsule = store.investigation.capsule, let inspectedID = store.investigation.inspectedPiece,
                              let piece = capsule.pieces.first(where: { $0.id == inspectedID }) else { throw failure("Native version selection did not identify its retained requested evidence.") }
                        let address = try EvidenceAddress(rootID: rootID, capsuleID: capsule.id, pieceID: piece.id)
                        let roundTrip = try EvidenceAddress(url: address.url)
                        let resolved = try roundTrip.resolve(in: capsule)
                        let expectedSide: EvidenceLocation.Side = mode == .before ? .before : .after
                        let expectedKind: EvidenceLocation.VersionKind = name == "reconstruction" ? .verifiedReconstruction : .verifiedGitBlob
                        let citationConditions: [String: Bool] = [
                            "capsuleDigestVerified": try capsule.verifyDigest(),
                            "addressRoundTripMatches": roundTrip == address,
                            "knownVersionMatches": resolved.knownVersion == expectedObject,
                            "locationVersionMatches": resolved.location?.version == expectedObject,
                            "locationSideMatches": resolved.location?.side == expectedSide,
                            "locationEnvironmentMatches": resolved.location?.environmentID == fixture.environment.id,
                            "locationVersionKindMatches": resolved.location?.versionKind == expectedKind,
                            "selectedTextRetained": resolved.text.contains(selectedText),
                            "manualCurrentNotSubstituted": !resolved.text.contains("manual current")
                        ]
                        let lastPieceDiagnostic: Any = try capsule.pieces.last.map { try diagnosticJSON($0) } ?? NSNull()
                        observations.append([
                            "kind": "version-citation-diagnostic", "case": name, "language": language.rawValue, "theme": theme,
                            "conditions": citationConditions, "expectedObjectID": expectedObject ?? "", "expectedSide": expectedSide.rawValue,
                            "expectedVersionKind": expectedKind.rawValue, "expectedEnvironmentID": fixture.environment.id,
                            "selectedText": selectedText, "selectedUTF16Range": [selection.location, selection.length],
                            "address": address.url.absoluteString, "addressResolvedPiece": try diagnosticJSON(resolved),
                            "requestedPieceUsedByAssertion": try diagnosticJSON(piece), "lastPieceForDiagnosticOnly": lastPieceDiagnostic,
                            "capsule": try diagnosticJSON(capsule),
                            "capsuleBeforeSelectionID": capsuleBeforeSelection?.id ?? "none",
                            "capsuleBeforeSelectionDigest": capsuleBeforeSelection?.digestSHA256 ?? "none",
                            "capsuleBeforeSelectionPieceCount": capsuleBeforeSelection?.pieces.count ?? 0,
                            "inspectedPieceBeforeSelection": inspectedBeforeSelection ?? "none",
                            "inspectedPieceAfterSelection": store.investigation.inspectedPiece ?? "none",
                            "capsuleIDChangedByCallback": capsuleBeforeSelection?.id != capsule.id,
                            "assertionSelectionMethod": "capsule.pieces.first where id == investigation.inspectedPiece; requested retained proof"
                        ])
                        check("versions-native-selection-citation-preserves-object-side-and-environment-" + name + "-" + language.rawValue + "-" + theme,
                              citationConditions.values.allSatisfy { $0 })
                        check("versions-context-question-prepared-without-send-" + name + "-" + language.rawValue + "-" + theme, !store.investigation.sending
                              && !store.investigation.connecting && store.investigation.response == nil && store.investigation.chatGPTAccount == nil)
                    } else if mode == .comparison {
                        try await settle(host)
                    } else {
                        // The model's unavailable state was checked above. This render verifies the actual empty/error component layout.
                        try await settle(host)
                        check("versions-native-missing-does-not-substitute-current-reader-" + language.rawValue + "-" + theme,
                              descendants(host).compactMap({ $0 as? CodeReadOnlyTextView }).isEmpty)
                    }
                    try capture(host, filename: "versions-\(name)-\(language.rawValue)-\(theme).png", scenario: "RecordedFileVersionsView · " + name + " · actual verified Git version or explicit unavailable state", language: language.rawValue, theme: theme)
                    window.close()
                }
            }
        }
        setLanguage(.fr)
        let originalBytes = try Data(contentsOf: fixture.currentFile)
        check("versions-qualification-never-rewrites-current-manual-file", String(data: originalBytes, encoding: .utf8) == fixture.manualCurrent)
        observations.append(["kind": "verified-version-provenance", "beforeBlob": fixture.file.beforeBlobID!, "afterBlob": fixture.file.afterBlobID!,
                             "reconstructedBlob": fixture.reconstructable.afterBlobID!, "baseCommit": fixture.commit,
                             "manualCurrentSHA256": digest(originalBytes), "currentFileComparedAsHistorical": false,
                             "citationMethod": "Actual CodeReadOnlyTextView selection callback -> RecordedFileVersionsView -> immutable capsule -> EvidenceAddress resolution",
                             "realCodexHomeRead": false, "hooksInstalled": false, "networkRequests": 0])
        try qualifyVersionEvidenceDeduplication(fixture)
        try await qualifyVersionReadingRemount(fixture)
        try await qualifyHorizontalPaneRemount()
    }

    private func qualifyVersionReadingRemount(_ fixture: NativeVersionFixture) async throws {
        setLanguage(.fr)
        let store = makeStore("version-reading-remount")
        let event = LensEvent(id: "anonymous-version-call", timestamp: epoch, agentID: rootID, kind: .toolCall,
                              title: "Anonymous recorded version remount", toolName: "apply_patch", environmentID: fixture.environment.id,
                              source: fixture.file.provenance.sources[0])
        let change = ChangeRecord(id: "anonymous-version-change", path: fixture.currentFile.path, environmentID: fixture.environment.id,
                                  agentID: rootID, eventID: event.id, kind: .requestedPatch)
        let snapshot = SessionSnapshot(root: SessionSummary(id: rootID, title: "Anonymous reading remount", cwd: fixture.environment.id),
                                       agents: [AgentRecord(id: rootID, name: "Anonymous version agent")], events: [event], environments: [fixture.environment],
                                       changes: [change], collectedAt: epoch)
        store.snapshot = snapshot; store.showSessionPicker = false; await store.waitForPresentation()
        let key = rootID + "/" + change.id
        let context = LensWindowContext(store: store)
        context.recordedVersionPresentations[key] = .after
        func changeRoot(_ store: LensStore, _ context: LensWindowContext) -> AnyView {
            AnyView(RecordedChangeView(change: change, initialContextExpanded: true).id(UUID())
                .environmentObject(store).environment(\.lensWindowContext, context)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        func versionPicker(_ host: NSView) -> NSPopUpButton? {
            descendants(host).compactMap { $0 as? NSPopUpButton }.first {
                let titles = Set($0.itemTitles)
                return ["Patch", "Avant", "Après", "Comparer"].allSatisfy { titles.contains(LensL10n.text($0)) }
            }
        }
        func containsVersion(_ host: NSView, _ text: String) -> Bool {
            descendants(host).compactMap { $0 as? CodeReadOnlyTextView }.contains { $0.string == text && !$0.isEditable }
        }
        func readingDiagnostic(_ host: NSView, _ context: LensWindowContext, stage: String) -> [String: Any] {
            let picker = versionPicker(host)
            return ["kind": "version-reading-remount-diagnostic", "stage": stage, "key": key,
                    "rememberedMode": context.recordedVersionPresentations[key]?.rawValue ?? "none",
                    "pickerTitle": picker?.titleOfSelectedItem ?? "none", "pickerEnabled": picker?.isEnabled ?? false,
                    "pickerAction": picker?.action.map(NSStringFromSelector) ?? "none",
                    "pickerTargetType": picker?.target.map { String(describing: type(of: $0)) } ?? "none",
                    "menuItems": picker?.itemArray.map { item in
                        ["title": item.title, "enabled": item.isEnabled, "action": item.action.map(NSStringFromSelector) ?? "none",
                         "targetType": item.target.map { String(describing: type(of: $0)) } ?? "none"] as [String: Any]
                    } ?? [],
                    "beforeBytesDisplayed": containsVersion(host, fixture.before), "afterBytesDisplayed": containsVersion(host, fixture.after),
                    "readerUTF8Lengths": descendants(host).compactMap { $0 as? CodeReadOnlyTextView }.map { $0.string.utf8.count }]
        }
        func selectVersion(_ picker: NSPopUpButton, title: String) -> Bool {
            guard let item = picker.item(withTitle: LensL10n.text(title)), item.isEnabled, let menu = item.menu else { return false }
            let index = menu.index(of: item)
            guard index >= 0 else { return false }
            // SwiftUI's popup routes selection through the menu item's action.
            // NSPopUpButton.selectItem + sendAction does not execute this path.
            menu.performActionForItem(at: index)
            return true
        }
        func waitForReading(_ host: NSView, _ context: LensWindowContext, mode: FileVersionPresentation, text: String, stage: String) async throws {
            observations.append(readingDiagnostic(host, context, stage: stage + "-before-wait"))
            do { try await waitFor { context.recordedVersionPresentations[key] == mode && containsVersion(host, text) } }
            catch {
                observations.append(readingDiagnostic(host, context, stage: stage + "-timeout"))
                throw failure("Timed out waiting for RecordedChangeView at " + stage + "; retained native menu/reading diagnostics.")
            }
        }
        let host = NSHostingView(rootView: changeRoot(store, context)); host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 820)
        let window = makeWindow(size: host.bounds.size, title: "Version reading remount · anonymous")
        window.contentView = host; context.attach(window); window.makeKeyAndOrderFront(nil)
        try await waitForReading(host, context, mode: .after, text: fixture.after, stage: "initial-after-mount"); try await settle(host)
        check("versions-recorded-change-restores-window-after-mode-on-mount", context.recordedVersionPresentations[key] == .after
              && versionPicker(host)?.titleOfSelectedItem == LensL10n.text("Après") && containsVersion(host, fixture.after))
        for (mode, title, text) in [(FileVersionPresentation.before, "Avant", fixture.before), (.after, "Après", fixture.after)] {
            guard let picker = versionPicker(host) else { throw failure("Actual RecordedChangeView native version picker unavailable.") }
            let actionDispatched = selectVersion(picker, title: title)
            try await waitForReading(host, context, mode: mode, text: text, stage: "native-menu-select-" + mode.rawValue)
            check("versions-recorded-change-native-picker-saves-window-mode-" + mode.rawValue, actionDispatched && context.recordedVersionPresentations[key] == mode)
            host.rootView = AnyView(Text("Anonymous proof destination")); try await settle(host)
            check("versions-recorded-change-unmounted-before-return-" + mode.rawValue, descendants(host).compactMap { $0 as? CodeReadOnlyTextView }.isEmpty)
            host.rootView = changeRoot(store, context)
            try await waitForReading(host, context, mode: mode, text: text, stage: "remount-" + mode.rawValue); try await settle(host)
            check("versions-recorded-change-remount-preserves-" + mode.rawValue, context.recordedVersionPresentations[key] == mode
                  && versionPicker(host)?.titleOfSelectedItem == LensL10n.text(title) && containsVersion(host, text))
            observations.append(["kind": "version-reading-remount", "key": key, "mode": mode.rawValue,
                                 "rememberedMode": context.recordedVersionPresentations[key]?.rawValue ?? "none",
                                 "selectedPickerTitle": versionPicker(host)?.titleOfSelectedItem ?? "none", "restoredBytesMatch": containsVersion(host, text),
                                 "method": "Actual RecordedChangeView popup NSMenu.performActionForItem, unmount then fresh view identity in same LensWindowContext"])
        }
        let secondStore = makeStore("version-reading-second-window")
        secondStore.snapshot = snapshot; secondStore.showSessionPicker = false; await secondStore.waitForPresentation()
        let secondContext = LensWindowContext(store: secondStore)
        let secondHost = NSHostingView(rootView: changeRoot(secondStore, secondContext)); secondHost.sizingOptions = []
        secondHost.frame = host.frame
        let secondWindow = makeWindow(size: secondHost.bounds.size, title: "Separate version reading · anonymous")
        secondWindow.contentView = secondHost; secondContext.attach(secondWindow); secondWindow.makeKeyAndOrderFront(nil)
        try await waitFor { versionPicker(secondHost)?.isEnabled == true }; try await settle(secondHost)
        check("versions-reading-second-window-does-not-inherit-first-mode", versionPicker(secondHost)?.titleOfSelectedItem == LensL10n.text("Patch")
              && secondContext.recordedVersionPresentations[key] == nil && context.recordedVersionPresentations[key] == .after)
        guard let secondPicker = versionPicker(secondHost) else { throw failure("Second owned window version picker unavailable.") }
        let secondAction = selectVersion(secondPicker, title: "Avant")
        try await waitForReading(secondHost, secondContext, mode: .before, text: fixture.before, stage: "second-window-native-menu-before")
        secondHost.rootView = AnyView(Text("Anonymous second proof destination")); try await settle(secondHost)
        secondHost.rootView = changeRoot(secondStore, secondContext)
        try await waitForReading(secondHost, secondContext, mode: .before, text: fixture.before, stage: "second-window-remount-before"); try await settle(secondHost)
        check("versions-reading-two-windows-restore-distinct-before-after-modes", secondAction
              && secondContext.recordedVersionPresentations[key] == .before && context.recordedVersionPresentations[key] == .after
              && containsVersion(secondHost, fixture.before) && containsVersion(host, fixture.after))
        observations.append(["kind": "version-reading-window-isolation", "key": key,
                             "firstMode": context.recordedVersionPresentations[key]?.rawValue ?? "none",
                             "secondMode": secondContext.recordedVersionPresentations[key]?.rawValue ?? "none",
                             "sameRootAndChange": true, "differentContextInstances": context !== secondContext,
                             "firstHistoricalBytesMatch": containsVersion(host, fixture.after), "secondHistoricalBytesMatch": containsVersion(secondHost, fixture.before)])
        secondWindow.close(); window.close()
    }

    private func qualifyHorizontalPaneRemount() async throws {
        let store = makeStore("horizontal-pane-remount"), key = "recorded-change-content"
        let context = LensWindowContext(store: store); context.paneWidths[key] = 333
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 860, height: 600)); split.isVertical = false; split.dividerStyle = .thin
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 170))
        let second = NSView(frame: NSRect(x: 0, y: 171, width: 860, height: 429))
        split.addArrangedSubview(first); split.addArrangedSubview(second)
        func probe(preferred: CGFloat) -> LensPaneSizing.Probe {
            let view = LensPaneSizing.Probe(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            view.key = key; view.preferredWidth = preferred; view.context = context; view.isVertical = false
            return view
        }
        let initialProbe = probe(preferred: 170); first.addSubview(initialProbe)
        let window = makeWindow(size: split.bounds.size, title: "Horizontal split remount · anonymous")
        window.contentView = split; context.attach(window); window.makeKeyAndOrderFront(nil)
        initialProbe.scheduleInstallation(); try await settle(split)
        try await waitFor { abs(first.bounds.height - 170) <= 2 && context.paneHeights[key] != nil }
        check("versions-horizontal-pane-probe-uses-preferred-height", abs(first.bounds.height - 170) <= 2 && context.paneWidths[key] == 333)
        split.setPosition(244, ofDividerAt: 0); try await settle(split)
        try await waitFor { abs((context.paneHeights[key] ?? 0) - first.bounds.height) <= 2 }
        let remembered = context.paneHeights[key] ?? 0
        check("versions-horizontal-pane-probe-remembers-user-height", abs(remembered - 244) <= 2 && context.paneWidths[key] == 333)
        initialProbe.dispose(); initialProbe.removeFromSuperview()
        split.setPosition(113, ofDividerAt: 0); try await settle(split)
        let replacementProbe = probe(preferred: 77); first.addSubview(replacementProbe); replacementProbe.scheduleInstallation()
        try await settle(split); try await waitFor { abs(first.bounds.height - remembered) <= 2 }
        check("versions-horizontal-pane-probe-remount-restores-height-over-new-default", abs(first.bounds.height - remembered) <= 2
              && abs(first.bounds.height - 77) > 20 && context.paneWidths[key] == 333)
        observations.append(["kind": "horizontal-pane-height-remount", "key": key, "firstPreferredHeight": 170,
                             "userRequestedHeight": 244, "rememberedHeight": remembered, "replacementPreferredHeight": 77,
                             "actualRestoredPaneHeight": first.bounds.height, "restoredContextHeight": context.paneHeights[key] ?? 0,
                             "separateWidthValue": context.paneWidths[key] ?? 0, "tolerancePoints": 2,
                             "method": "Actual LensPaneSizing.Probe inside horizontal NSSplitView; native setPosition, disposal then fresh probe"])
        replacementProbe.dispose(); window.close()
    }

    private func qualifyVersionEvidenceDeduplication(_ fixture: NativeVersionFixture) throws {
        let store = makeStore("version-evidence-deduplication")
        let investigation = store.investigation
        let a = EvidencePiece(id: "E001", kind: "verifiedHistoricalCode", title: "src/Version.swift:3", text: "before action",
                              eventID: "anonymous-version-call", agentID: rootID, environmentID: fixture.environment.id,
                              sourceRefs: fixture.file.provenance.sources, knownVersion: fixture.file.beforeBlobID, capturedAt: epoch,
                              location: EvidenceLocation(environmentID: fixture.environment.id, path: "src/Version.swift", versionKind: .verifiedGitBlob,
                                                         version: fixture.file.beforeBlobID, side: .before, firstLine: 3, lastLine: 3))
        let b = EvidencePiece(id: "E001", kind: "verifiedHistoricalCode", title: "src/Version.swift:3", text: "after action",
                              eventID: "anonymous-version-call", agentID: rootID, environmentID: fixture.environment.id,
                              sourceRefs: fixture.file.provenance.sources, knownVersion: fixture.file.afterBlobID, capturedAt: epoch,
                              location: EvidenceLocation(environmentID: fixture.environment.id, path: "src/Version.swift", versionKind: .verifiedGitBlob,
                                                         version: fixture.file.afterBlobID, side: .after, firstLine: 3, lastLine: 3))
        try investigation.append([a], rootID: rootID, cut: epoch)
        let firstAID = investigation.inspectedPiece
        try investigation.append([b], rootID: rootID, cut: epoch)
        let bID = investigation.inspectedPiece
        try investigation.append([a], rootID: rootID, cut: epoch)
        guard let deduplicated = investigation.capsule else { throw failure("Deduplicated evidence fixture produced no capsule.") }
        check("versions-evidence-append-a-b-a-retains-two-and-focuses-requested-a", deduplicated.pieces.count == 2
              && firstAID == "E001" && bID == "E002" && investigation.inspectedPiece == firstAID
              && deduplicated.pieces.first(where: { $0.id == investigation.inspectedPiece })?.knownVersion == fixture.file.beforeBlobID)
        observations.append(["kind": "version-evidence-deduplication", "sequence": "A, B, A", "firstAID": firstAID ?? "none", "bID": bID ?? "none",
                             "inspectedPieceAfterRepeatedA": investigation.inspectedPiece ?? "none", "capsule": try diagnosticJSON(deduplicated)])
        func originVariant(agentID: String, sources: [SourceRef], coverage: [CoverageIssue]) -> EvidencePiece {
            EvidencePiece(id: "E001", kind: a.kind, title: a.title, text: a.text, eventID: a.eventID, agentID: agentID,
                          environmentID: a.environmentID, sourceRefs: sources, knownVersion: a.knownVersion, capturedAt: a.capturedAt,
                          coverage: coverage, location: a.location)
        }
        try investigation.append([originVariant(agentID: childID, sources: a.sourceRefs, coverage: a.coverage)], rootID: rootID, cut: epoch)
        check("versions-evidence-distinct-agent-is-not-deduplicated", investigation.capsule?.pieces.count == 3
              && investigation.capsule?.pieces.first(where: { $0.id == investigation.inspectedPiece })?.agentID == childID)
        try investigation.append([originVariant(agentID: rootID, sources: fixture.reconstructable.provenance.sources, coverage: a.coverage)], rootID: rootID, cut: epoch)
        check("versions-evidence-distinct-source-is-not-deduplicated", investigation.capsule?.pieces.count == 4
              && investigation.capsule?.pieces.first(where: { $0.id == investigation.inspectedPiece })?.sourceRefs == fixture.reconstructable.provenance.sources)
        let partialCoverage = [CoverageIssue("anonymous-fixture", "Explicit recorded coverage differs", source: fixture.file.provenance.sources[0].path)]
        try investigation.append([originVariant(agentID: rootID, sources: a.sourceRefs, coverage: partialCoverage)], rootID: rootID, cut: epoch)
        check("versions-evidence-distinct-coverage-is-not-deduplicated", investigation.capsule?.pieces.count == 5
              && investigation.capsule?.pieces.first(where: { $0.id == investigation.inspectedPiece })?.coverage == partialCoverage)
        if let distinctOrigins = investigation.capsule {
            observations.append(["kind": "version-evidence-distinct-provenance", "dimensions": ["agentID", "sourceRefs", "coverage"],
                                 "expectedPieceCount": 5, "actualPieceCount": distinctOrigins.pieces.count,
                                 "inspectedPiece": investigation.inspectedPiece ?? "none", "capsule": try diagnosticJSON(distinctOrigins)])
        }
        let countBeforeOmission = investigation.capsule?.pieces.count ?? 0
        let previousInspected = investigation.inspectedPiece
        let tooLarge = EvidencePiece(id: "E001", kind: "verifiedHistoricalCode", title: String(repeating: "Anonymous oversized metadata ", count: 3000), text: "Requested proof must be omitted explicitly",
                                     eventID: "anonymous-omitted-proof", environmentID: fixture.environment.id, capturedAt: epoch)
        try investigation.append([tooLarge], rootID: rootID, cut: epoch)
        guard let omitted = investigation.capsule else { throw failure("Omission fixture produced no capsule.") }
        let omittedID = String(format: "E%03d", countBeforeOmission + 1)
        check("versions-evidence-omitted-request-does-not-select-a-different-retained-piece", omitted.pieces.count == countBeforeOmission
              && !omitted.pieces.contains(where: { $0.id == omittedID }) && investigation.inspectedPiece == nil && investigation.notice != nil
              && omitted.omissions.contains(where: { $0.pieceID == omittedID && $0.retainedUTF8Bytes == 0 }) && previousInspected != nil)
        check("versions-evidence-append-regressions-never-connect-or-send", !investigation.sending && !investigation.connecting && investigation.response == nil
              && investigation.chatGPTAccount == nil && investigation.apiKey.isEmpty)
        observations.append(["kind": "version-evidence-omission", "requestedID": omittedID, "previousInspectedID": previousInspected ?? "none",
                             "inspectedPieceAfterOmission": investigation.inspectedPiece ?? "none", "notice": investigation.notice ?? "none",
                             "proposedTitleUTF8Bytes": tooLarge.title.utf8.count, "capsule": try diagnosticJSON(omitted), "networkRequests": 0])
    }

    private func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private func diagnosticJSON<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private func cacheObservation(_ value: (entries: Int, bytes: Int, hits: Int, loads: Int, inFlight: Int, readers: Int)) -> [String: Int] {
        ["entries": value.entries, "bytes": value.bytes, "hits": value.hits, "loads": value.loads, "inFlight": value.inFlight, "readers": value.readers]
    }

    nonisolated private static func makeVersionFixture(at directory: URL) throws -> NativeVersionFixture {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        _ = try fixtureGit(["init", "-q"], at: directory)
        _ = try fixtureGit(["config", "user.name", "Anonymous Lens fixture"], at: directory)
        _ = try fixtureGit(["config", "user.email", "anonymous@example.invalid"], at: directory)
        let current = directory.appendingPathComponent("src/Version.swift")
        let before = "// Anonymous recorded file version\nstruct Version {\n    static let label = \"before action\"\n" + (0..<240).map { "    // Stable context line \($0) · éà 🧭" }.joined(separator: "\n") + "\n}\n"
        let after = before.replacingOccurrences(of: "before action", with: "after action")
        let reconstructed = before.replacingOccurrences(of: "before action", with: "reconstructed target")
        try Data(before.utf8).write(to: current)
        _ = try fixtureGit(["add", "--", "src/Version.swift"], at: directory)
        _ = try fixtureGit(["commit", "-qm", "Anonymous baseline"], at: directory)
        let commit = try fixtureGit(["rev-parse", "HEAD"], at: directory).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data(after.utf8).write(to: current)
        let patch = try fixtureGit(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--full-index", "--", "src/Version.swift"], at: directory).text
        let afterID = try fixtureGit(["hash-object", "-w", "--stdin"], at: directory, input: Data(after.utf8)).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = directory.appendingPathComponent("recorded-full-index.patch")
        let patchBytes = Data(patch.utf8); try patchBytes.write(to: sourceURL)
        let patchHash = SHA256.hash(data: patchBytes).map { String(format: "%02x", $0) }.joined()
        let provenance = DiffProvenance(environmentID: directory.path, eventIDs: ["anonymous-version-call"], sources: [SourceRef(path: sourceURL.path, length: patchBytes.count, line: 1, sha256: patchHash)], agentID: "11111111-1111-4111-8111-111111111111")
        let parsed = try RecordedDiff.parse(patch, provenance: provenance, kind: .requestedPatch)
        guard let file = parsed.files.first, file.afterBlobID == afterID else { throw NSError(domain: "LensNativeVersions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Full-index fixture diff was not parsed."]) }
        let futureID = RecordedFileVersion.objectID(text: reconstructed)
        let futurePatch = patch.replacingOccurrences(of: afterID, with: futureID).replacingOccurrences(of: "+    static let label = \"after action\"", with: "+    static let label = \"reconstructed target\"")
        let futureSourceURL = directory.appendingPathComponent("recorded-reconstruction.patch")
        let futureBytes = Data(futurePatch.utf8); try futureBytes.write(to: futureSourceURL)
        let futureHash = SHA256.hash(data: futureBytes).map { String(format: "%02x", $0) }.joined()
        let futureProvenance = DiffProvenance(environmentID: directory.path, eventIDs: ["anonymous-reconstruction-call"], sources: [SourceRef(path: futureSourceURL.path, length: futureBytes.count, line: 1, sha256: futureHash)], agentID: provenance.agentID)
        guard let reconstructable = try RecordedDiff.parse(futurePatch, provenance: futureProvenance, kind: .requestedPatch).files.first else { throw NSError(domain: "LensNativeVersions", code: 2) }
        guard try fixtureGit(["cat-file", "-e", futureID], at: directory, allowFailure: true).status != 0 else { throw NSError(domain: "LensNativeVersions", code: 3, userInfo: [NSLocalizedDescriptionKey: "Reconstruction target must be absent from the fixture object store."]) }
        let manual = "// manual current bytes deliberately outside both cited versions\nlet unrelated = 999\n"
        try Data(manual.utf8).write(to: current)
        let largeText = (0..<40_000).map { String(format: "// Anonymous line %05d · stable version payload 0123456789", $0) }.joined(separator: "\n") + "\n"
        let largeID = try fixtureGit(["hash-object", "-w", "--stdin"], at: directory, input: Data(largeText.utf8)).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = String(largeText.split(separator: "\n")[0])
        let largePatch = "diff --git a/src/Large.swift b/src/Large.swift\nindex \(largeID)..\(largeID) 100644\n--- a/src/Large.swift\n+++ b/src/Large.swift\n@@ -1 +1 @@\n \(firstLine)\n"
        let largeSourceURL = directory.appendingPathComponent("recorded-large.patch")
        let largeBytes = Data(largePatch.utf8); try largeBytes.write(to: largeSourceURL)
        let largeHash = SHA256.hash(data: largeBytes).map { String(format: "%02x", $0) }.joined()
        let largeProvenance = DiffProvenance(environmentID: directory.path, eventIDs: ["anonymous-large-call"], sources: [SourceRef(path: largeSourceURL.path, length: largeBytes.count, line: 1, sha256: largeHash)], agentID: provenance.agentID)
        guard let largeFile = try RecordedDiff.parse(largePatch, provenance: largeProvenance, kind: .recordedDiff).files.first else { throw NSError(domain: "LensNativeVersions", code: 4) }
        return NativeVersionFixture(directory: directory, currentFile: current, environment: EnvironmentRecord(path: directory.path, repositoryPath: directory.path, recordedRef: commit),
                                    file: file, reconstructable: reconstructable, largeFile: largeFile, before: before, after: after, reconstructed: reconstructed,
                                    manualCurrent: manual, largeText: largeText, commit: commit)
    }

    nonisolated private static func fixtureGit(_ args: [String], at directory: URL, input: Data? = nil, allowFailure: Bool = false) throws -> (text: String, status: Int32) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null"] + args
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"]
        let stdout = Pipe(); process.standardOutput = stdout; process.standardError = stdout
        let stdin = Pipe(); process.standardInput = stdin
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard bytes.count <= 65_536, allowFailure || process.terminationStatus == 0 else { throw NSError(domain: "LensNativeVersionsGit", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Owned anonymous Git fixture command failed: " + String(decoding: bytes.prefix(4096), as: UTF8.self)]) }
        return (String(decoding: bytes, as: UTF8.self), process.terminationStatus)
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
