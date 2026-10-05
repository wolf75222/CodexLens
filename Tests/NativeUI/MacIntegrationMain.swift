import AppKit
import SwiftUI
import LensCore
import QuartzCore
import Darwin

@main @MainActor struct MacIntegrationProbeApp: App {
    @NSApplicationDelegateAdaptor(LensApplicationDelegate.self) private var delegate
    init() { MacIntegrationSuite.shared.preparePreferences() }
    var body: some Scene {
        WindowGroup("Codex Lens — intégration native", id: "session", for: UUID.self) { request in
            IntegrationWindowRoot(applicationDelegate: delegate, requestID: request.wrappedValue).id(request.wrappedValue)
                .frame(minWidth: 1080, minHeight: 660)
        } defaultValue: { UUID() }
        .defaultSize(width: 1080, height: 660).windowResizability(.contentMinSize).commands { LensCommands() }
        Window("Probe — composants", id: "components") { Text("Fenêtre auxiliaire du probe") }
        Window("Probe — aide", id: "help") { Text("Fenêtre auxiliaire du probe") }
    }
}

@MainActor private struct IntegrationWindowRoot: View {
    @StateObject private var context: LensWindowContext
    @StateObject private var store: LensStore
    @SceneStorage("lensWindowIdentity") private var windowIdentity = UUID().uuidString
    @Environment(\.openWindow) private var openWindow
    let applicationDelegate: LensApplicationDelegate
    init(applicationDelegate: LensApplicationDelegate, requestID: UUID? = nil) {
        self.applicationDelegate = applicationDelegate
        let store = MacIntegrationSuite.shared.makeStore()
        _store = StateObject(wrappedValue: store)
        _context = StateObject(wrappedValue: LensWindowContext(store: store, sceneRequestID: requestID))
    }
    var body: some View {
        MainView().environmentObject(store)
            .environment(\.lensWindowContext, context)
            .focusedSceneValue(\.lensWindowStore, store)
            .focusedSceneValue(\.lensWindowContext, context)
            .focusedSceneObject(store)
            .focusedSceneObject(context)
            .background(LensWindowProbe(context: context))
            .task {
                store.setNavigationScope(windowIdentity)
                if let window = context.window { context.attach(window) }
                let action = openWindow
                LensApplicationCoordinator.shared.newWindowHandler = { requestID in action(id: "session", value: requestID) }
                await MacIntegrationSuite.shared.register(context, delegate: applicationDelegate)
            }
    }
}

private struct IntegrationCheck: Codable {
    let id: String
    let passed: Bool
    let scope: String
}

@MainActor private final class MacIntegrationSuite {
    static let shared = MacIntegrationSuite()
    let output: URL
    let sourceHome: URL
    let cacheDirectory: URL
    let archiveDirectory: URL
    private let linger: Bool
    private var nextStoreOrdinal = 0
    private var dockFixtureIDs: [String] = []
    private var contexts: [LensWindowContext] = []
    private var checks: [IntegrationCheck] = []
    private var observations: [String: String] = [:]
    private var unqualified: [String: String] = [:]
    private weak var delegate: LensApplicationDelegate?
    private var started = false
    private var registered = Set<ObjectIdentifier>()
    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ key: String, fallback: String) -> String {
            guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return fallback }
            return arguments[i + 1]
        }
        output = URL(fileURLWithPath: value("--output", fallback: "/private/tmp/CodexLens-macos-integration"))
        sourceHome = URL(fileURLWithPath: value("--empty-home", fallback: output.appendingPathComponent("runtime/source").path))
        cacheDirectory = URL(fileURLWithPath: value("--cache", fallback: output.appendingPathComponent("runtime/cache").path))
        archiveDirectory = URL(fileURLWithPath: value("--archive", fallback: output.appendingPathComponent("runtime/archive").path))
        linger = arguments.contains("--linger")
    }
    func preparePreferences() {
        UserDefaults.standard.removePersistentDomain(forName: "fr.codexlens.macosintegrationprobe")
    }
    func makeStore() -> LensStore {
        nextStoreOrdinal += 1
        let name = "window-\(nextStoreOrdinal)"
        for id in dockFixtureIDs { try! writeDockRollout(id, home: sourceHome.appendingPathComponent(name)) }
        let store = LensStore(sourceHome: sourceHome.appendingPathComponent(name),
                              investigationArchive: InvestigationArchive(directory: archiveDirectory.appendingPathComponent(name)),
                              cacheDirectory: cacheDirectory.appendingPathComponent(name))
        store.setNavigationScope(UUID().uuidString)
        return store
    }
    func register(_ context: LensWindowContext, delegate: LensApplicationDelegate) async {
        let identity = ObjectIdentifier(context)
        guard registered.insert(identity).inserted else { return }
        self.delegate = delegate
        let ordinal = registered.count - 1 // Reserve before suspension; two real scenes may load concurrently.
        await context.store.start()
        if ordinal < 2 {
            context.store.snapshot = fixture(rootID: ordinal == 0 ? "aaaaaaa1-0000-4000-8000-000000000001" : "bbbbbbb2-0000-4000-8000-000000000002")
            context.store.showSessionPicker = false
            await context.store.waitForPresentation()
        }
        contexts.append(context)
        LensApplicationCoordinator.shared.acceptPendingSession(in: context)
        if !started {
            started = true
            Task { await run() }
        }
    }
    private func fixture(rootID: String) -> SessionSnapshot {
        let original = LensDemoFixtures.snapshot(eventCount: 24)
        let encoder = JSONEncoder()
        let text = String(data: try! encoder.encode(original), encoding: .utf8)!
            .replacingOccurrences(of: original.root.id, with: rootID)
        return try! JSONDecoder().decode(SessionSnapshot.self, from: Data(text.utf8))
    }
    private func diagnoseFocus(_ context: LensWindowContext, prefix: String) {
        observations[prefix+".windowClass"] = context.window.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        observations[prefix+".contentViewClass"] = context.window?.contentView.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        observations[prefix+".appIsActive"] = String(NSApp.isActive)
        observations[prefix+".activationPolicy"] = String(NSApp.activationPolicy().rawValue)
        observations[prefix+".keyWindowPresent"] = String(NSApp.keyWindow != nil)
        observations[prefix+".mainWindowPresent"] = String(NSApp.mainWindow != nil)
        observations[prefix+".windowIsKey"] = String(context.window?.isKeyWindow == true)
        observations[prefix+".windowCanBecomeKey"] = String(context.window?.canBecomeKey == true)
        observations[prefix+".windowVisible"] = String(context.window?.isVisible == true)
        observations[prefix+".resolvedKeyContext"] = String(LensApplicationCoordinator.shared.context(for: NSApp.keyWindow) === context)
        observations[prefix+".inspectorMenuCount"] = String(allItems(NSApp.mainMenu).filter { $0.title.contains("l’inspecteur") }.count)
        observations[prefix+".inspectorMenuEnabled"] = String(inspectorItem()?.isEnabled == true)
    }
    private func skip(_ id: String, reason: String) { unqualified[id] = reason; print("UNQUALIFIED \(id) \(reason)"); fflush(stdout) }
    private func record(_ id: String, _ passed: Bool, _ scope: String) {
        checks.append(IntegrationCheck(id: id, passed: passed, scope: scope))
        print("CHECK \(id) \(passed ? "PASS" : "FAIL")"); fflush(stdout)
    }
    private func settle(_ context: LensWindowContext? = nil) async {
        if let context { await context.store.waitForPresentation() }
        try? await Task.sleep(nanoseconds: 180_000_000)
        for window in NSApp.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        CATransaction.flush()
        updateMenus(NSApp.mainMenu)
    }
    private func wait(_ predicate: () -> Bool, milliseconds: Int = 3000) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        while !predicate() && ContinuousClock.now < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return predicate()
    }
    private func updateMenus(_ menu: NSMenu?) {
        guard let menu else { return }
        // SwiftUI lazily supplies validation when AppKit asks to open a menu.
        // Exercise that public lifecycle before inspecting or dispatching its
        // items. Merely calling update() can leave an unopened item disabled.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items { updateMenus(item.submenu) }
    }
    private func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
    }
    private func activate(_ context: LensWindowContext) async {
        NSApp.unhide(nil)
        context.window?.deminiaturize(nil)
        context.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true) // Same ordinary own-app activation sequence as production coordinator.show; no unlock or system setting.
        context.window?.makeFirstResponder(context.window?.contentView)
        await settle(context)
    }
    private func trigger(_ item: NSMenuItem?) -> Bool {
        guard let item, item.isEnabled, let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item)); return true
    }
    private func closeItem() -> NSMenuItem? {
        allItems(NSApp.mainMenu).first { $0.keyEquivalent.lowercased() == "w" && $0.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == .command }
    }
    private func inspectorItem() -> NSMenuItem? {
        allItems(NSApp.mainMenu).first { $0.title.contains("l’inspecteur") }
    }
    private func menuBarChecks(_ a: LensWindowContext, _ b: LensWindowContext) async {
        let selectedLanguage = LensL10n.language
        LensL10n.language = .en
        record("menu-english-catalogue-in-bundle", LensL10n.catalogueEntryCount > 100 && LensL10n.text("Nouvelle fenêtre") == "New Window" && LensL10n.text("Ouvrir une session récente") == "Open Recent Session" && LensL10n.text("Fermer la fenêtre et ses onglets") == "Close Window and Tabs" && LensL10n.text("Onglet précédent") == "Previous Tab", "Real schemaVersion-1 bundled catalogue, not a dictionary fixture; newly added menu entries must be inside translations")
        LensL10n.language = selectedLanguage
        await activate(a)
        delegate?.reconcileNativeTabCommands()
        let items = allItems(NSApp.mainMenu)
        let top = NSApp.mainMenu?.items ?? []
        let navigation = top.first { $0.title == LensL10n.text("Navigation") }
        let investigation = top.first { $0.title == LensL10n.text("Enquête") }
        let help = items.first { $0.title == LensL10n.text("Aide Codex Lens") }
        record("menu-order-app-specific-before-window-help", top.count == 8 && top.firstIndex(where: { $0 === navigation }) == 4 && top.firstIndex(where: { $0 === investigation }) == 5 && top.last?.submenu === help?.menu,
               "Actual AppKit menu order, native File/Edit/View/Window; no development top-level menu")
        let find = items.first { $0.title == LensL10n.text("Rechercher") && $0.submenu != nil }
        record("menu-find-submenu-and-shortcuts", find?.submenu?.items.filter { ["f", "g"].contains($0.keyEquivalent) }.count == 4 && find?.menu === top[2].submenu,
               "Find, next, previous and session search are grouped in native Edit")
        record("menu-native-copy-remains-unique", items.filter { $0.action == NSSelectorFromString("copy:") }.count == 1 && items.filter { $0.title == LensL10n.text("Copier le lien interne") }.first?.menu === top[2].submenu,
               "Native responder-chain Copy remains separate from evidence-link copy")
        let forbidden = Set(["showHelp:", "toggleTabBar:", "toggleTabOverview:", "selectNextTab:", "selectPreviousTab:", "moveTabToNewWindow:", "mergeAllWindows:"])
        record("menu-no-empty-help-or-second-tab-system", !items.contains { $0.action.map { forbidden.contains(NSStringFromSelector($0)) } == true } && a.window?.tabbingMode == .disallowed,
               "No absent HelpBook command or unrelated NSWindow tabs; real Lens tabs remain")
        let nativeWindowSelectors = ["performMiniaturize:", "performZoom:", "arrangeInFront:", "toggleFullScreen:"]
        let missingWindowSelectors = nativeWindowSelectors.filter { selector in !items.contains { $0.action == NSSelectorFromString(selector) } }
        observations["v24.nativeWindowSelectorsMissingAtProbeStage"] = missingWindowSelectors.joined(separator: ",")
        if missingWindowSelectors.isEmpty {
            record("menu-native-window-management-preserved", true, "Native Window sizing/front order and View fullscreen selectors found in actual main menu")
        } else {
            skip("menu-native-window-management-preserved", reason: "Direct AppKit menu preparation in this standalone probe has not exposed \(missingWindowSelectors.joined(separator: ", ")). Inspect the production menus with CUA; no synthetic replacement is accepted.")
        }
        let development = items.first { $0.title == LensL10n.text("Développement") }
        record("menu-development-in-help", development?.menu === help?.menu, "Existing component gallery remains discoverable in Help")

        let originalTabs = a.store.tabs, originalActive = a.store.activeTab, originalSelection = a.store.selection
        let otherSelection = b.store.selection
        a.store.navigate(.event(a.store.snapshot!.events[0].id), newTab: true)
        a.store.pinTab(a.store.activeTab!)
        a.store.navigate(.event(a.store.snapshot!.events[1].id), newTab: true)
        let before = a.store.activeTab, tabIDs = a.store.tabs.map(\.id)
        a.cycleTab(forward: true)
        record("menu-tab-cycle-wraps-without-replacing-pinned-tab", a.store.activeTab == tabIDs.first && a.store.tabs.map(\.id) == tabIDs && b.store.selection == otherSelection,
               "Evidence tab IDs, pinned tab and unrelated window preserved")
        a.cycleTab(forward: false)
        record("menu-tab-cycle-back-restores-selection", a.store.activeTab == before && a.store.selection == a.store.tabs.last?.destination, "Reverse cycle returns to the exact evidence destination")
        await settle(a); delegate?.reconcileNativeTabCommands()
        record("menu-close-tab-title", NSApp.keyWindow !== a.window || closeItem()?.title == LensL10n.text("Fermer l’onglet"), "Native Close reconciles its title with the actual active Lens tab")
        if NSApp.keyWindow === a.window {
            let previous = allItems(NSApp.mainMenu).first { $0.title == LensL10n.text("Onglet précédent") }
            observations["v24.tabMenuBefore"] = "enabled=\(previous?.isEnabled.description ?? "missing") canCycle=\(a.canCycleTabs) tabs=\(a.store.tabs.count) active=\(a.store.activeTab?.uuidString ?? "nil") expected=\(tabIDs.first?.uuidString ?? "nil")"
            let dispatched = trigger(previous); await settle(a)
            observations["v24.tabMenuAfter"] = "dispatched=\(dispatched) active=\(a.store.activeTab?.uuidString ?? "nil") otherSelectionChanged=\(b.store.selection != otherSelection)"
            record("menu-previous-tab-dispatch", dispatched && a.store.activeTab == tabIDs.first && b.store.selection == otherSelection, "Actual NSMenu performActionForItem, not a synthesized key event")
        } else { skip("menu-previous-tab-dispatch", reason: "OS did not grant the probe a key window; explicit cycle tested separately") }
        a.store.tabs = originalTabs; a.store.activeTab = originalActive; a.store.selection = originalSelection

        let coordinator = LensApplicationCoordinator.shared
        coordinator.clearRecents()
        let id1 = "12345678-0000-4000-8000-000000000001", id2 = "12345678-0000-4000-8000-000000000002"
        coordinator.remember(SessionSummary(id: id1, title: "Title\nwith controls"))
        coordinator.remember(SessionSummary(id: id2, title: "Title\nwith controls"))
        record("menu-recents-identity-and-readable-label", coordinator.recentIDs == [id2, id1] && coordinator.recentTitle(for: id1).contains(id1) && !coordinator.recentTitle(for: id1).contains("\n"),
               "Most recent first; colliding short UUIDs disambiguated; control characters removed only from presentation")
        coordinator.remember(SessionSummary(id: id2, title: "Updated title"))
        record("menu-recent-title-updates-same-id", coordinator.recentIDs.count == 2 && coordinator.recentTitle(for: id2).hasPrefix("Updated title"), "Same session title can update without duplicate recent entry")
        for n in 3...15 { coordinator.remember(SessionSummary(id: String(format: "12345678-0000-4000-8000-%012d", n), title: String(repeating: "x", count: 300))) }
        record("menu-recents-budget", coordinator.recentIDs.count == 12 && coordinator.recentTitles.count == 12 && coordinator.recentTitles.values.allSatisfy { $0.count <= 96 }, "12 cached display titles of at most 96 characters; no disk indexing while opening menus")
        coordinator.clearRecents()
        record("menu-clear-recents-keeps-session-data", coordinator.recentIDs.isEmpty && coordinator.recentTitles.isEmpty && a.store.snapshot != nil && b.store.snapshot != nil, "Clearing recent references does not delete a session or evidence")
    }
    private func writeDockRollout(_ id: String, ordinal: Int) throws {
        try writeDockRollout(id, home: sourceHome.appendingPathComponent("window-\(ordinal)"))
    }
    private func writeDockRollout(_ id: String, home: URL) throws {
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let stamp = "2026-10-03T14:00:00Z"
        let rows: [[String: Any]] = [
            ["timestamp": stamp, "type": "session_meta", "payload": ["id": id, "cwd": "/fixture/unavailable/dock", "source": "cli", "cli_version": "0.159.2"]],
            ["timestamp": stamp, "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Anonymous Dock routing fixture \(id)"]]]]
        ]
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
        try bytes.write(to: sessions.appendingPathComponent("rollout-\(id).jsonl"))
    }
    private func dockRoutingChecks(_ a: LensWindowContext, _ b: LensWindowContext, delegate: LensApplicationDelegate) async throws {
        let coordinator = LensApplicationCoordinator.shared
        guard let rootA = a.store.snapshot?.root, let rootB = b.store.snapshot?.root else { return }
        coordinator.remember(rootA); coordinator.remember(rootB)
        for n in 10...15 { coordinator.remember(SessionSummary(id: String(format: "abcdefab-0000-4000-8000-%012d", n), title: "Anonymous recent \(n)")) }
        let bounded = delegate.applicationDockMenu(NSApp)!
        let targets = bounded.items.compactMap { $0.target as? LensDockSessionAction }
        record("dock-five-recents-in-exact-order", targets.map(\.sessionID) == Array(coordinator.recentIDs.prefix(5)) && bounded.items.filter(\.isSeparatorItem).count == 1,
               "Two global commands, separator and five exact cached IDs; no duplicated native window list or I/O")
        record("dock-no-shortcuts-or-destructive-items", bounded.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.keyEquivalent.isEmpty } && bounded.items.count == 8,
               "High-value opening actions only; all are also available through production File menu")
        let language = LensL10n.language
        LensL10n.language = .fr
        let french = delegate.applicationDockMenu(NSApp)!
        LensL10n.language = .en
        let english = delegate.applicationDockMenu(NSApp)!
        record("dock-global-labels-fr-en", french.items.prefix(2).map(\.title) == ["Nouvelle fenêtre", "Ouvrir une session…"] && english.items.prefix(2).map(\.title) == ["New Window", "Open Session…"],
               "Actual production Dock builder with the bundled English catalogue")
        LensL10n.language = language
        coordinator.remember(rootA)
        let dock = delegate.applicationDockMenu(NSApp)!
        guard let item = dock.items.first(where: { ($0.target as? LensDockSessionAction)?.sessionID == rootA.id }) else {
            record("dock-recent-target-present", false, "Missing immutable session target"); return
        }
        a.store.navigate(.event(a.store.snapshot!.events[0].id), newTab: true)
        let tabIDs = a.store.tabs.map(\.id), selected = a.store.selection, otherSelected = b.store.selection
        await activate(b)
        let count = contexts.count
        // AppKit documents that the Dock can dispatch with from:nil. Testing
        // NSMenu.performAction alone would conceal the former sender-ID defect.
        let dispatched = NSApp.sendAction(item.action!, to: item.target, from: nil)
        await settle(a)
        record("dock-nil-sender-opens-exact-existing-root", dispatched && contexts.count == count && a.store.snapshot?.root.id == rootA.id && b.store.snapshot?.root.id == rootB.id && !a.store.showSessionPicker,
               "Documented nil-sender dispatch restores the matching real window, without reloading a different session")
        record("dock-existing-root-preserves-both-selections", a.store.tabs.map(\.id) == tabIDs && a.store.selection == selected && b.store.selection == otherSelected,
               "Exact tab IDs, selected event and other window selection retained")
        a.window?.miniaturize(nil)
        let minimized = await wait { a.window?.isMiniaturized == true }
        NSApp.hide(nil)
        let hidden = await wait { NSApp.isHidden }
        let restored = NSApp.sendAction(item.action!, to: item.target, from: nil)
        let visible = await wait { !NSApp.isHidden && a.window?.isMiniaturized == false && a.window?.isVisible == true }
        observations["dock.restore"] = "minimized=\(minimized) hidden=\(hidden) dispatched=\(restored) visible=\(visible) contexts=\(contexts.count)/\(count)"
        record("dock-restores-hidden-minimized-window", minimized && hidden && restored && visible && contexts.count == count,
               "Own NSApplication hide and real NSWindow miniaturize/deminiaturize; no unrelated app control")
        coordinator.remember(SessionSummary(id: rootA.id.uppercased(), title: "Same identity uppercase"))
        let alias = delegate.applicationDockMenu(NSApp)!.items.first { ($0.target as? LensDockSessionAction)?.sessionID == rootA.id.uppercased() }
        let aliasOpened = NSApp.sendAction(alias?.action ?? NSSelectorFromString("invalid:"), to: alias?.target, from: nil)
        await settle(a)
        record("dock-root-identity-case-does-not-duplicate-window", aliasOpened && contexts.count == count && a.store.selection == selected,
               "UUID identity matching for a root already open, not an ambiguous short title")
        let ids = ["ddddddd8-0000-4000-8000-000000000008", "eeeeeee9-0000-4000-8000-000000000009"]
        // Both future source homes contain both roots: registration order is
        // irrelevant, but each queued command must survive rapid dispatch.
        for ordinal in (nextStoreOrdinal + 1)...(nextStoreOrdinal + 2) { for id in ids { try writeDockRollout(id, ordinal: ordinal) } }
        dockFixtureIDs = ids
        for id in ids { coordinator.remember(SessionSummary(id: id, title: "Anonymous pending \(id.prefix(8))")) }
        let pendingMenu = delegate.applicationDockMenu(NSApp)!
        for id in ids {
            let pendingItem = pendingMenu.items.first { ($0.target as? LensDockSessionAction)?.sessionID == id }!
            _ = NSApp.sendAction(pendingItem.action!, to: pendingItem.target, from: nil)
            _ = NSApp.sendAction(pendingItem.action!, to: pendingItem.target, from: nil)
        }
        let loaded = await wait({ self.contexts.count == count + 2 && Set(self.contexts.dropFirst(count).compactMap { $0.store.snapshot?.root.id }) == Set(ids) }, milliseconds: 6000)
        observations["dock.rapid"] = "loaded=\(loaded) contexts=\(contexts.count)/\(count + 2) roots=\(self.contexts.dropFirst(count).map { $0.store.snapshot?.root.id ?? "nil" }) errors=\(self.contexts.dropFirst(count).map { $0.store.error ?? "none" })"
        observations["dock.rapid.windows"] = NSApp.windows.filter { $0.styleMask.contains(.closable) }.map { "\($0.windowNumber):\($0.title):\(String(describing: coordinator.context(for: $0)?.sceneRequestID)):\(String(describing: coordinator.context(for: $0)?.store.observedSourceHome))" }.joined(separator: " | ")
        record("dock-rapid-recents-keep-two-exact-requests", loaded,
               "Two different recent IDs dispatched twice before yielding; two actual new scenes load dedicated local JSONL, no overwritten pending request")
        record("dock-new-recents-preserve-existing-windows", a.store.snapshot?.root.id == rootA.id && b.store.snapshot?.root.id == rootB.id && a.store.selection == selected && b.store.selection == otherSelected,
               "Unopened recent roots create windows instead of replacing either observed root")
        let opened = Array(contexts.dropFirst(count))
        for context in opened { coordinator.closeWindow(context.window) }
        let stopped = await wait { opened.allSatisfy { $0.window == nil && !$0.store.isObserving } }
        record("dock-recent-window-close-stops-readers", stopped, "Actual production close notifications after recent-session loading")
        dockFixtureIDs = []
        await activate(a)
    }
    private func dockNoWindowRecentCheck(delegate: LensApplicationDelegate) async throws {
        let id = "fffffff9-0000-4000-8000-000000000019"
        try writeDockRollout(id, ordinal: nextStoreOrdinal + 1)
        dockFixtureIDs = [id]
        let coordinator = LensApplicationCoordinator.shared
        coordinator.remember(SessionSummary(id: id, title: "Anonymous recent without windows"))
        let menu = delegate.applicationDockMenu(NSApp)!
        let item = menu.items.first { ($0.target as? LensDockSessionAction)?.sessionID == id }!
        let before = contexts.count
        let dispatched = NSApp.sendAction(item.action!, to: item.target, from: nil)
        let loaded = await wait({ self.contexts.count == before + 1 && self.contexts.last?.store.snapshot?.root.id == id }, milliseconds: 6000)
        record("dock-recent-with-no-window-loads-requested-root", dispatched && loaded,
               "Real new SwiftUI scene, exact dedicated JSONL root, no latest-session fallback")
        if let context = contexts.last, loaded {
            coordinator.closeWindow(context.window)
            let stopped = await wait { context.window == nil && !context.store.isObserving }
            record("dock-no-window-recent-cleanup", stopped, "Own temporary scene closed and reader stopped")
        }
        dockFixtureIDs = []
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func nativeEdit(in context: LensWindowContext) async {
        if let snapshot = context.store.snapshot, let environment = snapshot.environments.first {
            await context.store.prepareInvestigation(for: .environment(environment.id))
        }
        context.store.section = .investigation
        await activate(context)
        let text = context.window?.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor } }
        guard let text else {
            observations["nativeInvestigationEditor"] = "Not available in this host; no substitute control or fake edit result."
            skip("native-question-editor-actions", reason: "Real investigation editor not instantiated in host")
            return
        }
        record("question-editor-native", true, "Real editable NSTextView inside the investigation component")
        context.window?.makeFirstResponder(text)
        text.selectAll(nil)
        text.insertText("question native anonymisée", replacementRange: text.selectedRange())
        await settle(context)
        let dispatched = NSApp.sendAction(NSSelectorFromString("selectAll:"), to: text, from: nil)
        record("native-select-all-responder", dispatched && text.selectedRange().length == (text.string as NSString).length && !text.string.isEmpty,
               "NSApp explicit real-editor target; does not qualify keyboard/key-window routing; no clipboard access")
        observations["nativeQuestionBindingUpdated"] = String(context.store.investigation.question.contains("question native anonymisée"))
        observations["nativeUndoManagerAvailable"] = String(text.undoManager?.canUndo == true)
        if let manager = text.undoManager, manager.canUndo {
            let inserted = text.string
            let undoItem = allItems(NSApp.mainMenu).first { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == .command }
            let active = NSApp.keyWindow === context.window
            let undo = active ? (undoItem.map { NSApp.sendAction($0.action ?? NSSelectorFromString("invalid:"), to: $0.target, from: $0) } ?? false) : NSApp.sendAction(NSSelectorFromString("undo"), to: manager, from: nil)
            await settle(context)
            record("native-undo-responder", undo && text.string != inserted, "Native real-editor undo manager; key routing only when actual key window exists")
            let redoItem = allItems(NSApp.mainMenu).first { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == [.command,.shift] }
            let redo = active ? (redoItem.map { NSApp.sendAction($0.action ?? NSSelectorFromString("invalid:"), to: $0.target, from: $0) } ?? false) : NSApp.sendAction(NSSelectorFromString("redo"), to: manager, from: nil)
            if !active { skip("native-undo-redo-key-routing", reason: "No key window; explicit native UndoManager target only") }
            await settle(context)
            record("native-redo-responder", redo && text.string == inserted, "Native real-editor redo manager; explicit target when inactive")
        } else { observations["nativeUndoRedo"] = "Not qualified: native editor did not expose an undoable insertion."; skip("native-undo-redo", reason: "Real editor has no undoable insertion") }
        let copyItems = allItems(NSApp.mainMenu).filter { $0.keyEquivalent == "c" && $0.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == .command }
        record("native-copy-menu-preserved", !copyItems.isEmpty, "Standard Command-C menu retained; clipboard content neither read nor copied")
    }
    private func capture(_ context: LensWindowContext, filename: String) throws {
        guard let view = context.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent(filename)) }
    }
    private func windowKeyboardChecks(_ a: LensWindowContext, _ b: LensWindowContext) async throws {
        guard let window = a.window else { record("keyboard-window-present", false, "No actual window"); return }
        await activate(a)
        let selection = a.store.selection, tabs = a.store.tabs, active = a.store.activeTab
        let peerSelection = b.store.selection, originalFrame = window.frame
        let inspector = a.store.inspectorVisible, sidebar = a.sidebarVisibility?.wrappedValue
        a.store.navigate(.event(a.store.snapshot!.events[0].id))
        a.store.inspectorVisible = true; a.sidebarVisibility?.wrappedValue = true
        await settle(a)
        let eventSelection = a.store.selection, eventTabs = a.store.tabs.map(\.id)
        let mounted = await wait { LensPaneRegion.allCases.allSatisfy { a.paneKeyboard.isAvailable($0, in: window) } }
        record("panes-native-handles-registered", mounted, "Three real arranged NSSplitView panes after native layout")
        for region in LensPaneRegion.allCases {
            a.focusPane(region); await settle(a)
            record("keyboard-focus-" + region.rawValue, a.paneKeyboard.activeRegion(in: window) == region,
                   "Actual NSWindow first responder belongs to the requested native pane")
        }
        a.focusPane(.navigation); await settle(a)
        let navigationWidth = a.paneKeyboard.view(for: .navigation)?.frame.width ?? 0
        a.resizeActivePane(by: 24); await settle(a)
        let enlargedWidth = a.paneKeyboard.view(for: .navigation)?.frame.width ?? 0
        record("keyboard-enlarges-navigation-native-divider", enlargedWidth > navigationWidth + 1, "Real split divider moves; no content scale change")
        a.resizeActivePane(by: -24); await settle(a)
        record("keyboard-restores-navigation-width", abs((a.paneKeyboard.view(for: .navigation)?.frame.width ?? 0) - navigationWidth) < 2, "Same native divider returns to its initial position")
        a.focusPane(.inspector); await settle(a)
        let inspectorWidth = a.paneKeyboard.view(for: .inspector)?.frame.width ?? 0
        a.resizeActivePane(by: 24); await settle(a)
        record("keyboard-enlarges-trailing-inspector", (a.paneKeyboard.view(for: .inspector)?.frame.width ?? 0) > inspectorWidth + 1, "Trailing pane uses the preceding divider with reversed delta")
        a.capture(.inspector).execute(); await settle(a)
        record("hide-focused-inspector-returns-focus-to-content", !a.store.inspectorVisible && a.paneKeyboard.activeRegion(in: window) == .content, "Existing hide action returns focus before removing the inspector")
        a.focusPane(.inspector); await settle(a)
        record("keyboard-reveals-and-focuses-hidden-inspector", a.store.inspectorVisible && a.paneKeyboard.activeRegion(in: window) == .inspector, "Hidden pane mounts and focuses without changing evidence")
        a.focusPane(.navigation); await settle(a); a.toggleSidebar(); await settle(a)
        observations["v27.hiddenNavigationResponder"] = window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        observations["v27.hiddenNavigationPanes"] = LensPaneRegion.allCases.map { r in "\(r.rawValue):available=\(a.paneKeyboard.isAvailable(r, in: window)):window=\(a.paneKeyboard.view(for: r)?.window === window):hidden=\(a.paneKeyboard.view(for: r)?.isHiddenOrHasHiddenAncestor == true)" }.joined(separator: " | ")
        record("hide-focused-navigation-returns-focus-to-content", a.sidebarVisibility?.wrappedValue == false && a.paneKeyboard.activeRegion(in: window) == .content, "Hiding navigation leaves a working content responder")
        a.focusPane(.navigation); await settle(a)
        record("keyboard-reveals-and-focuses-hidden-navigation", a.sidebarVisibility?.wrappedValue == true && a.paneKeyboard.activeRegion(in: window) == .navigation, "Per-window navigation visibility binding is restored")
        record("pane-commands-preserve-evidence-and-peer", a.store.selection == eventSelection && a.store.tabs.map(\.id) == eventTabs && b.store.selection == peerSelection, "Focus and widths never navigate or retarget the second window")
        window.setFrame(NSRect(x: originalFrame.minX + 16, y: originalFrame.minY + 16, width: originalFrame.width + 120, height: originalFrame.height + 40), display: true)
        await settle(a)
        record("native-window-can-move-and-resize", abs(window.frame.width - originalFrame.width - 120) < 2 && abs(window.frame.minX - originalFrame.minX - 16) < 2 && window.styleMask.contains(.resizable), "Actual NSWindow frame change, no custom window dragging or fixed frame")
        window.performMiniaturize(nil)
        let minimized = await wait { window.isMiniaturized }
        record("native-window-can-minimize", minimized, "AppKit miniaturization; other scene stays open")
        window.deminiaturize(nil); await activate(a)
        record("native-window-restores-same-context", !window.isMiniaturized && a.store.selection == eventSelection && a.store.tabs.map(\.id) == eventTabs && b.window != nil, "Restoration preserves this exact session and evidence tabs")
        updateMenus(NSApp.mainMenu)
        let menuItems = allItems(NSApp.mainMenu)
        observations["v27.shortcutItems"] = menuItems.filter { !$0.keyEquivalent.isEmpty }.map { "\($0.title):\($0.keyEquivalent):\($0.keyEquivalentModifierMask.rawValue)" }.joined(separator: " | ")
        let modifiers: NSEvent.ModifierFlags = [.command, .option]
        let focusItems = menuItems.filter { LensPaneRegion.allCases.map(\.title).contains($0.title) && !$0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == modifiers }
        record("pane-focus-shortcuts-unique", focusItems.count == 3 && focusItems.allSatisfy(\.isEnabled), "Exactly one Command-Option-1/2/3 in the real main menu")
        let sectionItems = menuItems.filter { LensSection.allCases.map { LensL10n.display($0.rawValue) }.contains($0.title) && !$0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == .command }
        record("section-shortcuts-unique", sectionItems.count == 7, "Seven native Command-number shortcuts, one per existing view")
        if NSApp.keyWindow === window, let agentsItem = sectionItems.first(where: { $0.title == LensL10n.display(LensSection.agents.rawValue) }), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: agentsItem.keyEquivalent, charactersIgnoringModifiers: agentsItem.keyEquivalent, isARepeat: false, keyCode: 19) {
            let routed = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            await settle(a)
            record("native-command-2-opens-agents", routed && a.store.section == .agents && b.store.selection == peerSelection, "Actual main-menu key-equivalent dispatch, no raw keyboard/global monitor override")
        } else { skip("native-command-2-opens-agents", reason: "No actual key window for key equivalent dispatch") }
        record("pane-resize-invalid-input-rejected", !a.paneKeyboard.resizeActive(by: .nan, in: window) && !a.paneKeyboard.resizeActive(by: 24, in: nil), "Non-finite input and absent window are rejected")
        window.setFrame(originalFrame, display: true)
        a.store.tabs = tabs; a.store.activeTab = active; a.store.selection = selection
        a.store.inspectorVisible = inspector; a.sidebarVisibility?.wrappedValue = sidebar ?? true
        await settle(a)
        try capture(a, filename: "window-keyboard-native.png")
    }
    private func macPersonalizationChecks(_ context: LensWindowContext) async throws {
        await activate(context)
        if let toolbar = context.window?.toolbar {
            observations["v26.toolbarIdentifiers"] = toolbar.items.map { $0.itemIdentifier.rawValue }.joined(separator: ",")
            record("toolbar-native-customization-enabled", toolbar.allowsUserCustomization, "Actual production SwiftUI toolbar in a native window")
            record("toolbar-native-autosave-enabled", toolbar.autosavesConfiguration, "Native toolbar configuration persistence, no custom palette")
            let savedSelection = context.store.selection, savedTabs = context.store.tabs.map(\.id)
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue.contains("investigate") }) {
                let identifier = toolbar.items[index].itemIdentifier
                toolbar.removeItem(at: index); await settle(context)
                record("toolbar-item-can-be-removed-without-losing-context", !toolbar.items.contains { $0.itemIdentifier == identifier } && context.store.selection == savedSelection && context.store.tabs.map(\.id) == savedTabs, "Native toolbar removal keeps selection and evidence tabs")
                toolbar.insertItem(withItemIdentifier: identifier, at: min(index, toolbar.items.count)); await settle(context)
                record("toolbar-item-can-be-restored", toolbar.items.contains { $0.itemIdentifier == identifier }, "Native reinsertion with the exact stable identifier")
            } else { record("toolbar-item-can-be-removed-without-losing-context", false, "Expected stable investigate identifier absent") }
        } else { record("toolbar-native-customization-enabled", false, "No native toolbar attached") }
        let nativeItems = allItems(NSApp.mainMenu)
        let customize = nativeItems.first { $0.title == LensL10n.text("Personnaliser la barre d’outils…") }
        let hide = nativeItems.first { $0.title == LensL10n.text("Masquer la barre d’outils") }
        record("toolbar-customization-available-in-view-menu", customize?.isEnabled == true && hide?.isEnabled == true, "Actual native View menu, validated for the exact focused window")
        let visibility = context.window?.toolbar?.isVisible
        let hidden = trigger(hide); await settle(context)
        record("toolbar-hide-menu-uses-native-window", hidden && context.window?.toolbar?.isVisible == false, "Native window toolbar visibility changes; content remains mounted")
        let show = allItems(NSApp.mainMenu).first { $0.title == LensL10n.text("Afficher la barre d’outils") }
        let shown = trigger(show); await settle(context)
        record("toolbar-show-menu-restores-native-window", shown && context.window?.toolbar?.isVisible == visibility, "View title follows native visibility and restores the toolbar")
        record("new-personalization-labels-use-explicit-language", LensControlAccent.slate.title(in: .en) == "Slate Blue" && LensControlAccent.sage.title(in: .fr) == "Vert sauge" && LensCodeFont.system.title(in: .en) == "System Monospaced", "Labels use the new language binding even before root callbacks complete")
        let suite = "fr.codexlens.mac-font-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("uninstalled-font", forKey: "lens.reading.codeFont")
        let prefs = LensReadingPreferences(defaults: defaults)
        record("code-font-invalid-preference-falls-back", prefs.configuration.codeFont == .system, "Unknown stored family never becomes a missing-font reader")
        let home = output.appendingPathComponent("runtime/font-check")
        let one = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: home.appendingPathComponent("one")), readingPreferences: prefs)
        let two = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: home.appendingPathComponent("two")), readingPreferences: prefs)
        one.fontSize = 18; two.fontSize = 12
        prefs.setCodeFont(.menlo)
        record("code-font-updates-windows-without-resetting-zoom", one.codeFont == .menlo && two.codeFont == .menlo && one.fontSize == 18 && two.fontSize == 12, "Explicit family preference updates stores while retaining window-local sizes")
        record("code-font-preference-survives-new-instance", LensReadingPreferences(defaults: defaults).configuration.codeFont == .menlo, "Fresh preferences instance reads the persisted family")
        let host = CodeDocumentHost(frame: NSRect(x: 0, y: 0, width: 700, height: 240))
        let text = (1...300).map { "let value\($0) = \"anonymous\"" }.joined(separator: "\n")
        func install(_ family: LensCodeFont) {
            host.install(text: text, path: "anonymous.swift", versionLabel: "captured-test-v1", requestedLine: nil, fontSize: 14, codeFont: family, onSelection: nil, onLineNavigate: nil)
            host.layoutSubtreeIfNeeded()
        }
        install(.system)
        guard let editor = descendants(host).compactMap({ $0 as? NSTextView }).first else { throw NSError(domain: "LensMacFont", code: 1) }
        let selected = NSRange(location: 7, length: 21)
        editor.setSelectedRange(selected)
        for family in [LensCodeFont.menlo, .monaco, .system] {
            install(family)
            record("code-font-\(family.rawValue)-uses-native-font-and-keeps-bytes", editor.font == family.nativeFont(size: 14) && editor.string == text && editor.selectedRange() == selected && !editor.isEditable, "Existing AppKit reader; exact text and UTF-16 selection unchanged")
            let attribute = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            record("code-font-\(family.rawValue)-updates-attributed-text", attribute == editor.font, "All loaded text uses the chosen native font, including after syntax attributes")
        }
        host.cancelAnalysis(); one.stopObserving(); two.stopObserving()
        prefs.reset()
        record("code-font-reset-persists-system-default", LensReadingPreferences(defaults: defaults).configuration.codeFont == .system, "Reset includes family and persisted value")
    }

    private func run() async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let firstReady = await wait { self.contexts.first?.window != nil }
            record("first-real-window", firstReady, "SwiftUI WindowGroup plus production LensWindowProbe")
            guard firstReady else { try finish(); return }
            LensApplicationCoordinator.shared.newWindow()
            let twoReady = await wait { self.contexts.count >= 2 && self.contexts[1].window != nil }
            record("second-real-window", twoReady, "Production new-window coordinator executes SwiftUI openWindow")
            guard twoReady, let delegate else { try finish(); return }
            let a = contexts[0], b = contexts[1]
            observations["firstWindow.scope"] = a.store.windowIdentity
            observations["secondWindow.scope"] = b.store.windowIdentity
            observations["firstWindow.root"] = a.store.snapshot?.root.id ?? "nil"
            observations["secondWindow.root"] = b.store.snapshot?.root.id ?? "nil"
            record("window-store-identities-distinct", a.store !== b.store && a.store.windowIdentity != b.store.windowIdentity && a.store.snapshot?.root.id != b.store.snapshot?.root.id, "Two actual scenes, stores, scopes and synthetic sessions")
            await activate(a)
            diagnoseFocus(a, prefix: "firstWindow")
            if NSApp.keyWindow === a.window { record("coordinator-resolves-key-window", LensApplicationCoordinator.shared.context(for: NSApp.keyWindow) === a, "Real AppKit key window lookup") }
            else { skip("coordinator-resolves-key-window", reason: "OS did not grant a key window; no last-store fallback") }
            delegate.reconcileNativeTabCommands()
            let plainW = allItems(NSApp.mainMenu).filter { $0.keyEquivalent.lowercased() == "w" && $0.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == .command }
            record("unique-native-command-w", plainW.count == 1 && plainW.first?.title == LensL10n.text("Fermer la fenêtre"), "Actual SwiftUI native main menu, not a constructed menu fixture")
            await menuBarChecks(a, b)
            try await macPersonalizationChecks(a)
            try await windowKeyboardChecks(a, b)
            try await dockRoutingChecks(a, b, delegate: delegate)
            a.store.inspectorVisible = true; b.store.inspectorVisible = true
            await settle(a)
            if NSApp.keyWindow === a.window {
                let toggleA = trigger(inspectorItem()); await settle(a)
                record("main-menu-targets-a", toggleA && !a.store.inspectorVisible && b.store.inspectorVisible, "Actual menu dispatch operates only on the exact native key-window store")
                record("main-menu-inspector-title-updates-a", inspectorItem()?.title == LensAction.inspector.title(in: a.store), "Actual native menu title follows changed inspector state in first window")
            } else { skip("main-menu-targets-a", reason: "No key window/focused scene granted by OS") }
            a.store.inspectorVisible = true
            a.capture(.inspector).execute()
            record("explicit-inspector-target-a", !a.store.inspectorVisible && b.store.inspectorVisible, "Explicit production LensCommandTarget, independent of OS key-window routing")
            await activate(b)
            diagnoseFocus(b, prefix: "secondWindow")
            if NSApp.keyWindow === b.window {
                let toggleB = trigger(inspectorItem()); await settle(b)
                record("main-menu-targets-b", toggleB && !b.store.inspectorVisible && !a.store.inspectorVisible, "Native key-window switch operates only on second store")
                record("main-menu-inspector-title-updates-b", inspectorItem()?.title == LensAction.inspector.title(in: b.store), "Actual native menu title follows second window state")
            } else { skip("main-menu-targets-b", reason: "No key window/focused scene granted by OS") }
            b.store.inspectorVisible = true; b.capture(.inspector).execute()
            record("explicit-inspector-target-b", !b.store.inspectorVisible && !a.store.inspectorVisible, "Explicit command operates on second store only")

            await activate(a)
            let environmentA = a.store.snapshot!.environments[0].id
            let environmentB = a.store.snapshot!.environments[1].id
            a.store.investigation.clear(); a.store.navigate(.environment(environmentA))
            let prepared = a.capture(.investigate)
            record("captured-target-valid", prepared.isValid && prepared.destination == .environment(environmentA), "Production captured window/root/destination")
            prepared.execute()
            a.store.navigate(.environment(environmentB))
            b.window?.makeKeyAndOrderFront(nil)
            let preparedDone = await wait { a.store.investigation.capsule?.pieces.contains { $0.kind == "environmentMetadata" } == true }
            record("async-investigation-keeps-captured-target", preparedDone && a.store.investigation.capsule?.pieces.first(where: { $0.kind == "environmentMetadata" })?.environmentID == environmentA && b.store.investigation.capsule == nil, "Actual asynchronous LensAction.investigate; no send/model request")
            a.store.investigation.clear()
            a.store.navigate(.environment(environmentA))
            let stale = a.capture(.investigate)
            stale.execute()
            a.store.snapshot = fixture(rootID: "ccccccc3-0000-4000-8000-000000000003")
            await settle(a)
            record("async-investigation-rejects-new-root", !stale.isValid && a.store.investigation.capsule == nil, "Session changes before Task executes; no current-session substitution")
            a.store.snapshot = fixture(rootID: "aaaaaaa1-0000-4000-8000-000000000001")
            await settle(a)
            a.store.navigate(.environment(environmentA))
            let reveal = a.capture(.revealInFinder)
            record("missing-fixture-path-confirmed", !FileManager.default.fileExists(atPath: environmentA), "Precondition prevents launching Finder or touching another application")
            if !FileManager.default.fileExists(atPath: environmentA) {
                a.store.error = nil; reveal.execute(); a.store.navigate(.environment(environmentB))
                let busy = a.operationBusy
                let blocked = !a.capture(.inspector).isValid
                let completed = await wait { !a.operationBusy }
                record("busy-command-unavailable", busy && blocked, "Real native asynchronous operation state")
                record("async-reveal-keeps-environment", completed && a.store.error?.contains(environmentA) == true && a.store.error?.contains(environmentB) != true, "Failed location lookup uses captured environment; Finder is not launched")
                a.store.error = nil
                await settle(a)
            }
            try await cancelledRecordDoesNotPublish()
            try await restoreArchiveOnlyAfterRestart()
            try await fractionalDraftKeepsOriginalRecord()
            try await importedOpeningGuards()
            await nativeEdit(in: a)
            await cancelledOperationPreservesNewPanel(in: a)
            await activate(a)
            try capture(a, filename: "window-a-native.png")
            try capture(b, filename: "window-b-native.png")
            a.store.navigate(.event(a.store.snapshot!.events[0].id)); a.store.navigate(.event(a.store.snapshot!.events[1].id), newTab: true)
            await settle(a)
            let countA = a.store.tabs.count, countB = b.store.tabs.count
            if NSApp.keyWindow === a.window {
                let closedTab = trigger(closeItem()); await settle(a)
                record("command-w-closes-active-tab-only", closedTab && a.store.tabs.count == countA - 1 && b.store.tabs.count == countB && a.window != nil, "Actual routed native File/Close command")
            } else {
                skip("command-w-closes-active-tab-only", reason: "No key window; native Cmd-W execution unqualified")
                a.closeTabOrWindow(); await settle(a)
                record("explicit-context-closes-active-tab", a.store.tabs.count == countA - 1 && b.store.tabs.count == countB && a.window != nil, "Production context method, no simulated Cmd-W")
            }
            while let id = a.store.activeTab { a.store.closeTab(id) }
            await settle(a)
            let closeCapsule = a.store.investigation.capsule
            a.store.investigation.editQuestion("last closed-window draft anonymous")
            if NSApp.keyWindow === a.window {
                let closedWindow = trigger(closeItem())
                let windowStopped = await wait { a.window == nil && !a.store.isObserving }
                record("command-w-empty-tabs-closes-window", closedWindow && windowStopped && b.window != nil, "Native command closes its window when no active tab remains")
            } else {
                skip("command-w-empty-tabs-closes-window", reason: "No key window; explicit context close qualified separately")
                a.closeTabOrWindow()
                let stopped = await wait { a.window == nil && !a.store.isObserving }
                record("explicit-context-empty-tabs-closes-window", stopped && b.window != nil, "Actual NSWindow close lifecycle via explicit context")
            }
            record("closed-context-target-rejected", !a.capture(.inspector).isValid, "Stopped lifetime cannot perform stale commands")
            b.window?.performClose(nil)
            let allClosed = await wait { b.window == nil && !b.store.isObserving }
            record("red-close-stops-other-window", allClosed, "Actual NSWindow.performClose emits production lifecycle cleanup")
            await LensApplicationCoordinator.shared.prepareToQuit()
            let closedRecords = try await a.store.investigation.archive.list()
            var closedDraft: InvestigationRecord?
            for summary in closedRecords { if let loaded = try await a.store.investigation.archive.load(id: summary.id), loaded.question == "last closed-window draft anonymous" { closedDraft = loaded; break } }
            let sameClosedEvidence = closeCapsule.map { closedDraft?.capsule.representsSameFrozenContent(as: $0) == true } ?? false
            record("closed-window-draft-flush-awaited-on-quit", sameClosedEvidence, "Real last-window close followed immediately by actual prepareToQuit; latest private draft is preserved with frozen evidence. No model request")
            record("app-stays-running-after-last-window", !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "Production delegate contract")
            let beforeDock = contexts.count
            let dock = delegate.applicationDockMenu(NSApp)
            record("dock-menu-native-actions", dock?.items.contains(where: { $0.action == NSSelectorFromString("newWindow:") }) == true && dock?.items.contains(where: { $0.action == NSSelectorFromString("openSession:") }) == true, "Actual production delegate menu; macOS system Dock merge not inspected")
            let dockNew = dock?.items.first { $0.action == NSSelectorFromString("newWindow:") }
            let dockDispatched = NSApp.sendAction(dockNew?.action ?? NSSelectorFromString("invalid:"), to: dockNew?.target, from: dockNew)
            let emptyOpened = await wait { self.contexts.count > beforeDock && self.contexts.last?.window != nil }
            record("dock-opens-real-empty-window", dockDispatched && emptyOpened && contexts.last?.store.snapshot == nil && contexts.last?.store.showSessionPicker == true, "Real third SwiftUI window after all previous windows closed")
            if let empty = contexts.last, emptyOpened {
                await activate(empty)
                record("empty-window-actions-disabled", !empty.capture(.follow).isValid && !empty.capture(.bookmark).isValid && !empty.capture(.exportInvestigation).isValid, "Availability derived from empty data, not static controls")
                record("empty-window-open-session-enabled", empty.capture(.openSession).isValid, "Empty scene remains usable")
                try capture(empty, filename: "empty-window-native.png")
                let beforeReopen = contexts.count
                _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
                await settle(empty)
                diagnoseFocus(empty, prefix: "emptyWindow")
                record("reopen-reuses-existing-context", contexts.count == beforeReopen && LensApplicationCoordinator.shared.context(for: empty.window) === empty, "Production reopen callback does not create a second scene")
                if NSApp.keyWindow === empty.window || NSApp.keyWindow?.sheetParent === empty.window {
                    record("reopen-focuses-existing-window", true, "Actual key window or picker sheet")
                } else { skip("reopen-focuses-existing-window", reason: "OS did not grant key-window activation") }
                let emptyRecentID = "abababa9-0000-4000-8000-000000000029"
                try writeDockRollout(emptyRecentID, home: empty.store.observedSourceHome)
                LensApplicationCoordinator.shared.remember(SessionSummary(id: emptyRecentID, title: "Anonymous recent into empty window"))
                let emptyMenu = delegate.applicationDockMenu(NSApp)!
                let emptyItem = emptyMenu.items.first { ($0.target as? LensDockSessionAction)?.sessionID == emptyRecentID }!
                let beforeReuse = contexts.count
                let emptyDispatch = NSApp.sendAction(emptyItem.action!, to: emptyItem.target, from: nil)
                let reused = await wait({ empty.store.snapshot?.root.id == emptyRecentID && !empty.store.showSessionPicker }, milliseconds: 6000)
                record("dock-recent-reuses-empty-window", emptyDispatch && reused && contexts.count == beforeReuse,
                       "Exact generated JSONL loads into the existing empty scene; no duplicate window")
                empty.store.showSessionPicker = true
                await settle(empty)
                // CUA may request a reopen while inspecting a no-window app.
                // Verify the production close-all action without that external
                // inspection, using two real owned SwiftUI scenes and stores.
                let beforeSecond = contexts.count
                LensApplicationCoordinator.shared.newWindow()
                let anotherOpened = await wait { self.contexts.count > beforeSecond && self.contexts.last?.window != nil }
                record("close-all-second-real-window", anotherOpened, "Production newWindow handler creates another real SwiftUI scene")
                if let other = contexts.last, anotherOpened {
                    await activate(empty)
                    let closeAll = allItems(NSApp.mainMenu).first { $0.title == LensL10n.text("Fermer toutes les fenêtres") }
                    let dispatched = trigger(closeAll)
                    let stopped = await wait { empty.window == nil && other.window == nil && !empty.store.isObserving && !other.store.isObserving }
                    record("close-all-menu-stops-both-window-contexts", dispatched && stopped, "Real NSMenu action and close notifications for both owned scenes; no external CUA reopen")
                    record("close-all-no-visible-session-window", !NSApp.windows.contains { $0.styleMask.contains(.closable) && ($0.isVisible || $0.isMiniaturized) }, "AppKit window list after close-all, before any reopen request")
                }
            }
            try await dockNoWindowRecentCheck(delegate: delegate)
            try finish()
        } catch {
            observations["error"] = error.localizedDescription
            record("harness-error", false, error.localizedDescription)
            try? finish()
        }
    }
    private func cancelledRecordDoesNotPublish() async throws {
        let archive = InvestigationArchive(directory: archiveDirectory.appendingPathComponent("cancellation-regression"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try EvidenceCapsule.build(rootThreadID: "aaaaaaa1-0000-4000-8000-000000000001", collectionCut: date, pieces: [EvidencePiece(id: "E001", kind: "fixture", title: "Ancienne archive", text: "old archived evidence", capturedAt: date)], createdAt: date)
        let current = try EvidenceCapsule.build(rootThreadID: "bbbbbbb2-0000-4000-8000-000000000002", collectionCut: date, pieces: [EvidencePiece(id: "E001", kind: "fixture", title: "Capsule courante", text: "current evidence stays", capturedAt: date)], createdAt: date)
        let saved = try await archive.save(capsule: old, question: "old archived question")
        let store = InvestigationStore(archive: archive)
        store.capsule = current; store.question = "current question"; store.response = "current response"
        let task = Task { await store.openRecord(saved.record.id) }
        task.cancel(); await task.value
        record("cancelled-open-record-does-not-publish", store.capsule == current && store.question == "current question" && store.response == "current response" && store.issue == nil, "Actual openRecord method, cancellation before its Task starts; no UI claim")
        let control = InvestigationStore(archive: archive)
        await control.openRecord(saved.record.id)
        record("uncancelled-open-record-control", control.capsule == old && control.question == "old archived question", "Same real archive record is accessible without cancellation")
    }
    private func restoreArchiveOnlyAfterRestart() async throws {
        let rootID = "ddddddd4-0000-4000-8000-000000000004"
        let date = Date(timeIntervalSince1970: 1_690_000_000)
        let originArchive = InvestigationArchive(directory: archiveDirectory.appendingPathComponent("restoration-origin"))
        let localArchive = InvestigationArchive(directory: archiveDirectory.appendingPathComponent("restoration-import"))
        let capsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: date, pieces: [EvidencePiece(id: "E001", kind: "fixture", title: "Octets importés anonymisés", text: "frozen imported evidence", capturedAt: date)], createdAt: date)
        let saved = try await originArchive.save(capsule: capsule, question: "question importée", inferenceIDs: ["fixture-inference"])
        let answered = try await originArchive.updateResponse(id: saved.record.id, response: "réponse archivée de fixture", inferenceIDs: ["fixture-response"])
        let originTransfer = LensArchiveTransfer(archive: originArchive, protectedSourceRoots: [sourceHome], codexDirectories: [sourceHome])
        let envelope = try await originTransfer.freeze(record: answered.record)
        let localTransfer = LensArchiveTransfer(archive: localArchive, protectedSourceRoots: [sourceHome], codexDirectories: [sourceHome])
        let imported = try await localTransfer.import(envelope: envelope)
        guard let historical = try await originArchive.load(id: answered.record.id) else { throw LensError.unavailable("Fixture d’archive historique absente") }
        record("archive-import-local-id-and-metadata", imported.record.id != answered.record.id && imported.sourceRecordID == answered.record.id && imported.record.capsule == capsule && imported.record.createdAt == historical.createdAt && imported.record.updatedAt == historical.updatedAt && imported.record.inferenceIDs == answered.record.inferenceIDs && imported.record.response == answered.record.response, "Real transfer import: new local record ID, frozen evidence and historical record metadata preserved")
        let scope = UUID().uuidString
        let store = LensStore(sourceHome: sourceHome.appendingPathComponent("restoration-empty"), investigationArchive: localArchive, cacheDirectory: cacheDirectory.appendingPathComponent("restoration"))
        store.setNavigationScope(scope)
        await store.start()
        store.showArchiveOnlyRoot(rootID)
        await store.investigation.loadArchive(rootID: rootID)
        await store.investigation.openRecord(imported.record.id)
        store.navigate(.investigation(imported.record.id), newTab: true)
        await store.waitForPresentation()
        store.stopObserving()
        store.investigation.clear()
        await store.start()
        await store.waitForPresentation()
        let restored = store.snapshot
        record("archive-only-same-window-restart", store.windowIdentity == scope && store.isObserving && restored?.root.id == rootID && store.selection == .investigation(imported.record.id) && store.investigation.recordID == imported.record.id && store.investigation.capsule == capsule && store.investigation.question == "question importée" && store.investigation.response == "réponse archivée de fixture" && store.error == nil, "Actual stop/start and scoped persisted tab restore using empty source home; capsule bytes only")
        record("archive-only-no-fabricated-session-data", restored?.events.isEmpty == true && restored?.agents.isEmpty == true && restored?.environments.isEmpty == true && restored?.resources.isEmpty == true && restored?.changes.isEmpty == true && restored?.root.modifiedAt == .distantPast && restored?.coverage.contains(where: { $0.category == "archive-only" }) == true, "Imported capsule creates no historical activity, agents, environments, resources, changes, or session timestamps")
        let peer = LensStore(sourceHome: sourceHome.appendingPathComponent("restoration-peer-empty"), investigationArchive: localArchive, cacheDirectory: cacheDirectory.appendingPathComponent("restoration-peer"))
        peer.setNavigationScope(UUID().uuidString)
        await peer.start()
        record("archive-only-restore-window-scope-isolated", peer.snapshot == nil && peer.selection == nil && peer.investigation.capsule == nil, "Different window UUID does not restore first window's archive-only root/tab")
        store.stopObserving(); peer.stopObserving()
    }
    private func fractionalDraftKeepsOriginalRecord() async throws {
        let archive = InvestigationArchive(directory: archiveDirectory.appendingPathComponent("fractional-draft-regression"))
        let date = Date(timeIntervalSince1970: 1_690_000_000.123456)
        let capsule = try EvidenceCapsule.build(rootThreadID: "eeeeeee5-0000-4000-8000-000000000005", collectionCut: date, pieces: [EvidencePiece(id: "E001", kind: "fixture", title: "Date sous-milliseconde", text: "anonymous frozen draft", capturedAt: date)], createdAt: date)
        let saved = try await archive.save(capsule: capsule, question: "draft initial", inferenceIDs: ["fixture-draft-origin"])
        guard let initial = try await archive.load(id: saved.record.id) else { throw LensError.unavailable("Brouillon de fixture absent") }
        record("fractional-date-roundtrip-precondition", initial.capsule != capsule && initial.capsule.id == capsule.id && initial.capsule.digestSHA256 == capsule.digestSHA256, "Actual archive JSON rounds dates to milliseconds; raw RAM equality differs while frozen ID/digest remain identical")
        let store = InvestigationStore(archive: archive)
        store.capsule = capsule; store.recordID = initial.id; store.question = initial.question
        var allPublished = true
        for index in 1...3 {
            let question = "draft edited \(index)"
            store.editQuestion(question)
            let deadline = ContinuousClock.now + .milliseconds(3000)
            var published = false
            while ContinuousClock.now < deadline {
                if let record = try await archive.load(id: initial.id), record.question == question, store.recordID == initial.id { published = true; break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            allPublished = allPublished && published
        }
        record("fractional-draft-three-edits-stable-id", allPublished && store.recordID == initial.id && store.issue == nil, "Actual debounced InvestigationStore.editQuestion writes three drafts to the same real archive record; bounded 3s each, no model request")
        store.editQuestion("draft final flush")
        await store.flushAndStop()
        let listed = try await archive.list()
        let final = try await archive.load(id: initial.id)
        record("fractional-draft-flush-no-duplicate", listed.count == 1 && listed.first?.id == initial.id && final?.question == "draft final flush" && final?.createdAt == initial.createdAt && final?.inferenceIDs == initial.inferenceIDs && final?.capsule == initial.capsule && store.issue == nil, "Immediate actual flush cancels debounce and preserves local record ID, historical creation date, inference IDs and frozen capsule; exactly one archive record")
    }
    private func cancelledOperationPreservesNewPanel(in context: LensWindowContext) async {
        guard let environment = context.store.snapshot?.environments.first, context.store.investigation.capsule != nil else {
            record("operation-race-fixture-precondition", false, "A real prepared metadata capsule and unavailable synthetic environment are required"); return
        }
        context.store.selection = .environment(environment.id)
        let previous = context.capture(.revealInFinder)
        previous.execute()
        context.cancelOperation()
        let replacement = context.capture(.exportInvestigation)
        record("operation-race-new-export-target-valid", replacement.isValid, "Cancelled prior lookup permits captured export target for the same own window/root")
        replacement.execute()
        let panelAttached = await wait { context.window?.attachedSheet is NSSavePanel }
        try? await Task.sleep(nanoseconds: 500_000_000)
        record("cancelled-operation-keeps-new-panel-busy", panelAttached && context.operationBusy && context.window?.attachedSheet is NSSavePanel, "Actual own NSSavePanel is attached; busy remains true after immediate cancel/replacement plus 500ms native run-loop processing. No panel confirmation or file export")
        context.cancelOperation()
        let panelGone = await wait { context.window?.attachedSheet == nil }
        record("new-panel-cancel-cleanup", panelGone && !context.operationBusy, "Public context.cancelOperation cancels the actual own save sheet; no OS click")
        context.store.error = nil
        await settle(context)
    }
    private func importedOpeningGuards() async throws {
        let importedRoot = "ffffffa6-0000-4000-8000-000000000006"
        let otherRoot = "ffffffb7-0000-4000-8000-000000000007"
        let home = sourceHome.appendingPathComponent("import-race-generated")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let timestamp = "2026-10-02T14:00:00Z"
        var bytes = Data()
        func append(_ object: [String: Any]) throws { bytes.append(try JSONSerialization.data(withJSONObject: object)); bytes.append(10) }
        try append(["timestamp": timestamp, "type": "session_meta", "payload": ["id": importedRoot, "cwd": "/fixture/unavailable/import-race", "source": "cli", "cli_version": "0.159.2"]])
        for index in 0..<12000 { try append(["timestamp": timestamp, "type": "response_item", "payload": ["type": "message", "id": "fixture-message-\(index)", "role": "assistant", "content": [["type": "output_text", "text": "anonymous generated event \(index)"]]]]) }
        try bytes.write(to: sessions.appendingPathComponent("rollout-\(importedRoot).jsonl"))
        let store = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: archiveDirectory.appendingPathComponent("import-race")), cacheDirectory: cacheDirectory.appendingPathComponent("import-race"))
        store.setNavigationScope(UUID().uuidString)
        await store.start()
        let pending = Task { await store.openImportedRoot(importedRoot) }
        let began = await wait { store.busy }
        record("imported-open-race-started", began, "Actual generated rollout reader enters busy state before a competing opening; no mocked engine")
        await store.open(otherRoot)
        let superseded = await pending.value
        record("imported-open-superseded-token-nil", began && superseded == nil && store.snapshot?.root.id != importedRoot, "A newer actual session opening invalidates imported-root token and prevents stale snapshot publication")
        let unavailable = await store.openImportedRoot(otherRoot)
        record("imported-open-unavailable-token-valid", unavailable.map { store.acceptsImportedOpening($0) } == true && store.error != nil, "Real missing rollout yields a valid opening token for explicit archive-only fallback; no invented session history")
        store.showArchiveOnlyRoot(otherRoot)
        let displayed = store.openingIdentity
        record("imported-archive-placeholder-exact-root", store.acceptsImportedOpening(displayed, rootID: otherRoot) && store.snapshot?.events.isEmpty == true && store.snapshot?.agents.isEmpty == true && store.snapshot?.environments.isEmpty == true, "Explicit archive-only placeholder bumps generation and preserves only exact imported root ID")
        await store.open(importedRoot)
        await store.waitForPresentation()
        record("imported-token-rejected-after-other-open", !store.acceptsImportedOpening(displayed, rootID: otherRoot) && store.snapshot?.root.id == importedRoot, "New real rollout opening rejects previous archive-only token")
        store.stopObserving()
        record("imported-token-rejected-after-close", !store.acceptsImportedOpening(store.openingIdentity), "Stopped lifecycle rejects current token")
    }
    private func finish() throws {
        let failed = checks.filter { !$0.passed }.map(\.id)
        let report: [String: Any] = [
            "schemaVersion": 1, "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "checks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(checks)),
            "failedCheckIDs": failed, "allExecutedChecksPassed": failed.isEmpty,
            "unqualifiedCheckReasons": unqualified, "completeNativeIntegrationQualified": failed.isEmpty && unqualified.isEmpty,
            "qualificationStatus": failed.isEmpty ? (unqualified.isEmpty ? "complete" : "partial") : "failed",
            "observations": observations, "pid": ProcessInfo.processInfo.processIdentifier,
            "hostOS": ProcessInfo.processInfo.operatingSystemVersionString, "minimumDeploymentTarget": "14.0",
            "networkDeniedByOS": true, "modelRequests": 0, "authRead": false, "realCodexSessionRead": false,
            "clipboardContentRead": false, "systemKeyInjection": false, "CUAClickQualified": false,
            "voiceOverQualified": false, "systemDockMergeQualified": false,
            "scope": "Own SwiftUI App WindowGroup, production LensCommands/delegate/context; synthetic snapshots and private source/cache/archive. Not production binary or CUA interaction."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("macos-integration-receipt.json"))
        print("MACOS_INTEGRATION_FINISHED \(failed.isEmpty ? (unqualified.isEmpty ? "PASS" : "PARTIAL") : "FAIL") \(checks.count) checks")
        fflush(stdout)
        if !linger { NSApp.terminate(nil) }
    }
}
