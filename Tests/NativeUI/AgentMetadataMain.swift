import AppKit
import ApplicationServices
import CSQLite
import Combine
import CryptoKit
import Darwin
import Foundation
import LensCore
import SwiftUI

/// Source-matched owned fixtures and native accessibility/button callbacks.
/// No production account, global configuration, compositor or physical input.
@main struct AgentMetadataMain {
    @MainActor private static var stage = "setup"
    @MainActor private static var diagnosticOutput: URL?
    @MainActor private static weak var diagnosticStore: LensStore?
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("Agent metadata probe exceeded its execution bound.\n", stderr); Darwin.exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            do { try await qualify(); NSApp.terminate(nil) }
            catch { fputs("Agent metadata qualification: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let outputText = argument("--output"), outputText.hasPrefix("/") else { throw LensError.unavailable("Missing absolute --output") }
        let output = URL(fileURLWithPath: outputText, isDirectory: true)
        diagnosticOutput = output
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        guard manifest?["entrypoint"] as? String == "AgentMetadataMain.swift",
              manifest?["productionEntryPointReplaced"] as? Bool == true,
              manifest?["copiedAppSourcesModified"] as? Bool == false else { throw LensError.unavailable("Source-matched wrapper required") }
        let hash = SHA256.hash(data: Data(outputText.utf8)).map { String(format: "%02x", $0) }.joined()
        guard Bundle.main.bundleIdentifier == "fr.codexlens.designprobe.v07." + hash.prefix(12),
              Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "NativeDesignV07Probe" else {
            throw LensError.unavailable("Refusing production preferences")
        }
        var checks: [[String: Any]] = [], observations: [[String: Any]] = [], renders: [[String: Any]] = []
        var completed = false
        defer {
            if !completed {
                checks.append(["name": "flow-completes-after-" + stage, "passed": false])
                try? receipt(["checks": checks, "observations": observations, "renders": renders,
                    "completed": false, "failedStage": stage, "allExecutedChecksPassed": false,
                    "scope": "Interrupted owned native agent-metadata probe; no physical input or account request."], output: output)
            }
        }
        func mark(_ name: String) {
            stage = name
            try? JSONSerialization.data(withJSONObject: ["stage": name], options: [.sortedKeys])
                .write(to: output.appendingPathComponent("phase.json"))
        }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        configureLanguage(.en)
        let fixture = try MetadataUIFixture(base: output.appendingPathComponent("metadata-fixture"))
        let suite = "fr.codexlens.metadata-fixture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw LensError.unavailable("Fixture defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = LensReadingPreferences(defaults: defaults)
        let pool = SessionReaderPool(investigationRegistryDirectory: output.appendingPathComponent("registry"))
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: pool, readingPreferences: reading)
        diagnosticStore = store
        store.setNavigationScope(UUID().uuidString)
        store.investigation.automaticCodexCheckEnabled = false
        defer { store.stopObserving() }
        mark("load-owned-fixture")
        await store.start(); await store.open(MetadataUIFixture.root); await store.waitForPresentation()
        let explorer = try require(store.snapshot?.agents.first { $0.id == MetadataUIFixture.explorer }, "explorer record")
        let custom = try require(store.snapshot?.agents.first { $0.id == MetadataUIFixture.root }, "custom record")
        let opaque = try require(store.snapshot?.agents.first { $0.id == MetadataUIFixture.opaque }, "opaque record")
        let requested = try require((explorer.metadata ?? []).first { $0.kind == .role && $0.origin == .delegationRequest }, "linked requested role")
        let delegation = try require(requested.eventID.flatMap(store.event), "delegation source")
        let instruction = try require(store.events.first { $0.agentID == opaque.id && $0.kind == .instruction && $0.source.line == 1 }, "owned base instruction")
        check("parsed-recorded-role-wins-requested-conflict", AgentMetadataField.preferredRole(in: explorer.metadata ?? [])?.value == "explorer" && requested.value == "worker")
        check("database-model-and-effort-have-thread-origin", (explorer.metadata ?? []).contains { $0.kind == .model && $0.origin == .threadMetadata && $0.value == "configured-model" }
            && (explorer.metadata ?? []).contains { $0.kind == .reasoningEffort && $0.origin == .threadMetadata && $0.value == "medium" })
        check("custom-role-and-missing-description-remain-distinct", AgentMetadataField.preferredRole(in: custom.metadata ?? [])?.value == "local-auditor"
            && !(custom.metadata ?? []).contains { $0.kind == .description })
        check("nickname-does-not-invent-role-or-description", AgentMetadataField.preferredRole(in: opaque.metadata ?? []) == nil
            && !(opaque.metadata ?? []).contains { $0.kind == .description })
        check("bounded-description-excerpt-flag-is-retained", (explorer.metadata ?? []).contains { $0.kind == .description && $0.isTruncated == true })
        check("full-base-content-not-copied-into-metadata", !AgentMetadataField.searchText(opaque.metadata ?? []).contains(MetadataUIFixture.baseMarker))
        check("configuration-trap-not-agent-metadata", !(store.snapshot?.agents ?? []).contains { AgentMetadataField.searchText($0.metadata ?? []).contains(MetadataUIFixture.configTrap) })

        mark("inspector-request-and-repetition")
        store.browseSection(.agents)
        store.navigate(.agent(explorer.id))
        let inspector = mount(AnyView(InspectorView().environmentObject(store)), width: 390, height: 950, dark: true)
        defer { unmount(inspector.window) }
        try await settle(inspector.host)
        store.showAgentMetadata(explorer.id)
        try await wait("metadata-request-expands") { strings(inspector.host).contains(LensL10n.text("Informations sur l’agent")) }
        let firstRequest = store.agentMetadataRequest?.id
        check("metadata-request-target-and-inspector-match", store.agentMetadataRequest?.agentID == explorer.id
            && store.selection == .agent(explorer.id) && store.inspectorVisible)
        try press(inspector.host, label: LensL10n.text("Détails"))
        try await settle(inspector.host)
        let collapsed = !strings(inspector.host).contains(LensL10n.text("Informations sur l’agent"))
        store.showAgentMetadata(explorer.id)
        try await wait("repeated-request-expands") { strings(inspector.host).contains(LensL10n.text("Informations sur l’agent")) }
        check("repeated-request-new-UUID-reexpands-details", collapsed && firstRequest != store.agentMetadataRequest?.id)
        let inspectorText = strings(inspector.host).joined(separator: "\n")
        check("inspector-distinguishes-request-and-recorded-values", inspectorText.contains("explorer") && inspectorText.contains("worker")
            && inspectorText.contains(LensL10n.text("Demandé")) && inspectorText.contains("configured-model"))
        check("inspector-excerpt-and-configured-latest-note", inspectorText.contains(LensL10n.text("Extrait"))
            && inspectorText.contains(LensL10n.text("Le modèle et l’effort du thread indiquent sa dernière configuration enregistrée. Le détail de chaque requête peut manquer.")))

        mark("source-message-native-action")
        try press(inspector.host, label: LensL10n.text("Messages source")); try await settle(inspector.host)
        let beforeSourceTabs = store.tabs.map(\.id), home = store.observedSourceHome
        try press(inspector.host, identifier: "lens-agent-metadata-source", label: LensL10n.display(delegation.title))
        try await wait("source-reader-opens") { store.tabContentDestination == .event(delegation.id) }
        check("source-action-opens-exact-event-new-tab", store.selection == .event(delegation.id)
            && store.tabs.contains { $0.destination == .event(delegation.id) } && beforeSourceTabs.allSatisfy { id in store.tabs.contains { $0.id == id } })
        check("source-action-retains-observed-root-home-and-workspace", store.snapshot?.root.id == MetadataUIFixture.root
            && sameHome(home, store.observedSourceHome) && !store.workspacePresented)
        store.goBack()
        check("source-back-restores-agent-workspace", store.section == .agents && store.selection == .agent(explorer.id) && store.workspacePresented)

        mark("original-base-instruction-on-demand")
        store.showAgentMetadata(opaque.id)
        try await wait("opaque-agent-information") { store.selection == .agent(opaque.id) && strings(inspector.host).contains(LensL10n.text("Informations sur l’agent")) }
        let opaqueText = strings(inspector.host).joined(separator: "\n")
        check("missing-role-and-description-are-explicit", opaqueText.contains(LensL10n.text("Rôle")) && opaqueText.contains(LensL10n.text("Description"))
            && opaqueText.contains(LensL10n.text("Non enregistré")))
        try press(inspector.host, identifier: "lens-agent-base-instructions")
        try await wait("base-reader-opens") { store.tabContentDestination == .event(instruction.id) }
        let detail = try await store.engine.sourceDetail(for: instruction)
        check("base-action-exact-original-event-and-source", store.selection == .event(instruction.id)
            && instruction.agentID == opaque.id && instruction.source.path == fixture.opaquePath.path
            && detail.raw.contains(MetadataUIFixture.baseMarker) && detail.raw.contains(MetadataUIFixture.opaqueBaseBlob))
        check("opening-base-does-not-assign-opaque-content-to-description", !(store.snapshot?.agents.first { $0.id == opaque.id }?.metadata ?? []).contains { $0.kind == .description })
        store.goBack()
        check("base-back-restores-agent-home-and-workspace", store.selection == .agent(opaque.id) && store.workspacePresented && sameHome(store.observedSourceHome, fixture.home))

        mark("stale-header-metadata-link")
        var staleAgent = opaque
        let staleSource = SourceRef(path: instruction.source.path, offset: instruction.source.offset,
            length: instruction.source.length, line: instruction.source.line, sha256: String(repeating: "0", count: 64))
        staleAgent.metadata = [AgentMetadataField(kind: .role, value: "old-header-role", origin: .sessionMetadata,
            sourcePath: staleSource.path, source: staleSource)]
        let stale = mount(AnyView(AgentMetadataView(agent: staleAgent).environmentObject(store)), width: 390, height: 650, dark: true)
        try await settle(stale.host)
        check("changed-header-hash-does-not-link-newer-instruction", !strings(stale.host).contains(LensL10n.text("Messages source"))
            && !accessibilityRecords(stale.host).contains { $0["identifier"] == "lens-agent-metadata-source" })
        unmount(stale.window)

        mark("agents-information-control")
        let agents = mount(AnyView(AgentsView().environmentObject(store)), width: 690, height: 600, dark: true)
        defer { unmount(agents.window) }
        try await settle(agents.host)
        let agentObjects = accessibilityRecords(agents.host)
        let informationLabels = agentObjects.filter { $0["identifier"] == "lens-agent-information" }.compactMap { $0["label"] ?? $0["title"] }
        check("agents-info-controls-are-named-and-role-recorded", informationLabels.contains(LensL10n.text("Informations sur l’agent {0}", explorer.name.nonempty ?? explorer.id))
            && strings(agents.host).joined(separator: "\n").contains(LensL10n.text("Rôle enregistré : {0}", "explorer")))
        let requestBeforeButton = store.agentMetadataRequest?.id
        try press(agents.host, identifier: "lens-agent-information", label: LensL10n.text("Informations sur l’agent {0}", custom.name.nonempty ?? custom.id))
        try await wait("row-information-target") { store.agentMetadataRequest?.agentID == custom.id }
        check("native-row-info-action-targets-custom-agent", store.selection == .agent(custom.id) && store.agentMetadataRequest?.id != requestBeforeButton)

        mark("language-theme-and-width-renders")
        for language in [LensL10n.Language.en, .fr] {
            configureLanguage(language)
            for dark in [false, true] {
                for narrow in [false, true] {
                    let width: CGFloat = narrow ? 300 : 390
                    store.fontSize = narrow ? 22 : 13
                    store.showAgentMetadata(explorer.id)
                    let view = AnyView(InspectorView().environmentObject(store).id(language.rawValue + String(dark) + String(narrow)))
                    let sample = mount(view, width: width, height: 950, dark: dark)
                    try await settle(sample.host)
                    let text = strings(sample.host).joined(separator: "\n")
                    let name = "agent-info-\(language.rawValue)-\(dark ? "dark" : "light")-\(narrow ? "narrow-large-font" : "regular")"
                    check(name + "-metadata-and-origin-labels", text.contains(LensL10n.text("Informations sur l’agent")) && text.contains(LensL10n.text("Demandé")))
                    check(name + "-native-buttons-fit-width", buttonsFit(sample.host))
                    renders.append(try capture(sample.host, name: name, width: width, output: output))
                    observations.append(["scenario": name, "fontSize": store.fontSize, "visibleNativeButtons": descendants(sample.host).compactMap { $0 as? NSButton }.count])
                    unmount(sample.window)
                }
            }
        }
        configureLanguage(.en); store.fontSize = 13
        check("sources-and-fixture-database-remain-unchanged", try fixture.unchanged())
        store.stopObserving(); await store.investigation.flushAndStop(); await pool.quiesce()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try receipt(["checks": checks, "observations": observations, "renders": renders, "completed": true,
            "failedStage": passed ? "none" : stage, "allExecutedChecksPassed": passed,
            "fixture": ["anonymous": true, "home": fixture.home.path, "root": MetadataUIFixture.root, "sourcesUnchanged": try fixture.unchanged()],
            "scope": "Actual LensStore and AgentMetadataView/InspectorView/AgentsView on own recorded headers, SQLite fields and explicitly linked delegation data; public owned accessibility/button actions and offscreen cache renders.",
            "unqualified": ["No production compositor, physical clicks, hover, keyboard focus or VoiceOver qualification.",
                "Button-width checks and saved bitmaps cover the listed widths/fonts; they are not an exhaustive text-overflow or accessibility-contrast audit.",
                "Opaque instruction content stays opaque; the probe checks exact raw source retention, not decryption or model execution.",
                "No user configuration/hook/authentication/model request or broad performance claim."]], output: output)
        completed = true
        guard passed else { throw LensError.unavailable("Agent metadata checks failed; inspect receipt") }
    }

    private static func argument(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return CommandLine.arguments[i + 1]
    }
    @MainActor private static func configureLanguage(_ language: LensL10n.Language) {
        UserDefaults.standard.setVolatileDomain([
            "lensLanguage": language.rawValue, "lensControlAccent": "lens", "lensReduceMotionOverride": true,
            "lensRootByWindow": [String: String](), "lensTabsByRoot": [String: Data](), "lensChatByRoot": [String: String](),
            "lensBookmarks": Data(), "LensCodexModel": "", "LensCodexExecutablePath": ""
        ], forName: UserDefaults.argumentDomain)
        LensL10n.language = language
    }
    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + label) }; return value
    }
    private static func sameHome(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path }
    private static func receipt(_ value: [String: Any], output: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func accessibilityObjects(_ root: NSView) -> [NSAccessibilityProtocol] {
        var result: [NSAccessibilityProtocol] = [], seen: Set<ObjectIdentifier> = []
        func visit(_ object: Any, _ depth: Int) {
            guard depth < 40, result.count < 10_000, let element = object as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child, depth + 1) }
        }
        for view in descendants(root) where !view.isHiddenOrHasHiddenAncestor { visit(view, 0) }
        return result
    }
    @MainActor private static func strings(_ root: NSView) -> [String] {
        var result: Set<String> = []
        for element in accessibilityObjects(root) {
            for value in [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap({ $0 }) where !value.isEmpty { result.insert(value) }
        }
        for view in descendants(root) {
            if let text = view as? NSTextField, !text.stringValue.isEmpty { result.insert(text.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { result.insert(button.title) }
        }
        for element in ownAXNodes(root).nodes {
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let value = axValue(element, key).1 as? String, !value.isEmpty { result.insert(value) }
            }
        }
        return result.sorted()
    }
    @MainActor private static func press(_ root: NSView, identifier: String? = nil, label: String? = nil) throws {
        let candidates = accessibilityObjects(root).filter { element in
            (identifier == nil || element.accessibilityIdentifier() == identifier)
                && (label == nil || [element.accessibilityLabel(), element.accessibilityTitle()].compactMap { $0 }.contains(label!))
        }
        for element in candidates {
            if let button = element as? NSButton, button.isEnabled { button.performClick(nil); return }
            if element.accessibilityPerformPress() { return }
        }
        let axCandidates = ownAXNodes(root).nodes.filter { element in
            (identifier == nil || axValue(element, kAXIdentifierAttribute).1 as? String == identifier)
                && (label == nil || [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .compactMap { axValue(element, $0).1 as? String }.contains(label!))
        }
        for element in axCandidates {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        }
        retainFailureDiagnostics(reason: "Owned native action unavailable: " + (identifier ?? label ?? "unnamed"))
        throw LensError.unavailable("Owned native action unavailable: " + (identifier ?? label ?? "unnamed"))
    }
    @MainActor private static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        stage = label
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                retainFailureDiagnostics(reason: "Bounded native fixture did not reach " + label)
                throw LensError.unavailable("Bounded native fixture did not reach " + label)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    @MainActor private static func settle(_ host: NSView) async throws {
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor private static func mount(_ view: AnyView, width: CGFloat, height: CGFloat, dark: Bool) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let size = NSSize(width: width, height: height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -12_000, y: -12_000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setAccessibilityIdentifier("AgentMetadata-" + UUID().uuidString)
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        // Register only this prohibited-activation probe's own offscreen window
        // for public self-process AX. This never raises/activates the app.
        window.orderBack(nil)
        return (window, host)
    }
    @MainActor private static func unmount(_ window: NSWindow) {
        window.orderOut(nil); window.contentView = nil; window.close()
    }
    private static func axValue(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return (error, value)
    }
    @MainActor private static func ownAXNodes(_ root: NSView) -> (nodes: [AXUIElement], diagnostics: [String]) {
        guard let window = root.window, window.accessibilityIdentifier().hasPrefix("AgentMetadata-") else {
            return ([], ["Root has no identified owned window"])
        }
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 0.5)
        let windows = axValue(application, kAXWindowsAttribute)
        guard windows.0 == .success, let peers = windows.1 as? [AXUIElement] else {
            return ([], ["Own-process AXWindows unavailable: \(windows.0.rawValue)"])
        }
        let matches = peers.filter { axValue($0, kAXIdentifierAttribute).1 as? String == window.accessibilityIdentifier() }
        guard matches.count == 1, let match = matches.first else {
            return ([], ["Expected one identified own window; found \(matches.count)"])
        }
        var nodes: [AXUIElement] = [], seen: [CFHashCode: [AXUIElement]] = [:]
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 40, nodes.count < 10_000 else { return }
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            seen[hash, default: []].append(element); nodes.append(element)
            for child in axValue(element, kAXChildrenAttribute).1 as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(match, depth: 0)
        return (nodes, ["Own-process public AX nodes visited: \(nodes.count)"])
    }
    @MainActor private static func accessibilityRecords(_ root: NSView) -> [[String: String]] {
        var records = accessibilityObjects(root).map { element -> [String: String] in
            var record: [String: String] = ["method": "NSAccessibilityProtocol"]
            if let label = element.accessibilityLabel() { record["label"] = label }
            if let title = element.accessibilityTitle() { record["title"] = title }
            record["identifier"] = element.accessibilityIdentifier()
            if let value = element.accessibilityValue() as? String { record["value"] = value }
            return record
        }
        records += ownAXNodes(root).nodes.map { element -> [String: String] in
            var record: [String: String] = ["method": "Public self-process AX"]
            for (key, name) in [(kAXIdentifierAttribute, "identifier"), (kAXDescriptionAttribute, "label"),
                                (kAXTitleAttribute, "title"), (kAXValueAttribute, "value"), (kAXRoleAttribute, "role")] {
                if let value = axValue(element, key).1 as? String { record[name] = value }
            }
            return record
        }
        return records
    }
    @MainActor private static func retainFailureDiagnostics(reason: String) {
        guard let output = diagnosticOutput else { return }
        var windows: [[String: Any]] = []
        for (index, window) in NSApp.windows.filter({ $0.accessibilityIdentifier().hasPrefix("AgentMetadata-") }).enumerated() {
            guard let host = window.contentView else { continue }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            var observation: [String: Any] = ["identifier": window.accessibilityIdentifier(),
                "visible": window.isVisible, "windowNumber": window.windowNumber,
                "strings": strings(host), "accessibility": accessibilityRecords(host),
                "accessibilityDiagnostics": ownAXNodes(host).diagnostics]
            if let capture = try? capture(host, name: "failure-" + stage + "-" + String(index), width: host.bounds.width, output: output) {
                observation["render"] = capture
            }
            windows.append(observation)
        }
        var state: [String: Any] = ["stage": stage, "reason": reason, "windows": windows,
            "pid": getpid(), "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unavailable",
            "scope": "Only this identified prohibited-activation probe's own offscreen windows and fixture store; not compositor or physical input."]
        if let store = diagnosticStore {
            state["store"] = ["selection": String(describing: store.selection),
                "metadataRequestAgent": store.agentMetadataRequest?.agentID ?? "nil",
                "metadataRequestID": store.agentMetadataRequest?.id.uuidString ?? "nil",
                "inspectorVisible": store.inspectorVisible,
                "workspacePresented": store.workspacePresented,
                "root": store.snapshot?.root.id ?? "nil", "section": String(describing: store.section)]
        }
        try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("failure-" + stage + "-diagnostics.json"))
    }
    @MainActor private static func buttonsFit(_ host: NSView) -> Bool {
        let buttons = descendants(host).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        guard !buttons.isEmpty else { return false }
        return buttons.allSatisfy {
            let rect = $0.convert($0.bounds, to: host)
            return rect.minX >= -1 && rect.maxX <= host.bounds.width + 1
        }
    }
    @MainActor private static func capture(_ host: NSView, name: String, width: CGFloat, output: URL) throws -> [String: Any] {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No offscreen bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No offscreen PNG") }
        try bytes.write(to: output.appendingPathComponent(name + ".png"))
        return ["file": name + ".png", "width": width, "height": host.bounds.height, "method": "Owned NSHostingView cache render, not compositor screenshot"]
    }
}

private struct MetadataUIFixture {
    static let root = "11111111-1111-4111-8111-111111111111"
    static let explorer = "22222222-2222-4222-8222-222222222222"
    static let opaque = "33333333-3333-4333-8333-333333333333"
    static let baseMarker = "FULL_BASE_INSTRUCTION_FROM_OWN_SOURCE"
    static let opaqueBaseBlob = "OPAQUE_BASE_BLOB_DO_NOT_DECRYPT"
    static let configTrap = "CONFIG_TRAP_MUST_NOT_BECOME_AGENT_ROLE"
    let home: URL, opaquePath: URL
    private let originals: [URL: String]
    init(base: URL) throws {
        home = base.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        func event(_ type: String, _ payload: [String: Any]) -> [String: Any] { ["timestamp": "2026-10-01T14:00:00Z", "type": type, "payload": payload] }
        func call(_ id: String, _ arguments: [String: Any]) -> [String: Any] { event("response_item", ["type": "function_call", "name": "spawn_agent", "namespace": "agents", "call_id": id, "arguments": arguments]) }
        func result(_ id: String, child: String) -> [String: Any] { event("response_item", ["type": "function_call_output", "call_id": id, "output": "{\"agent_id\":\"\(child)\"}"]) }
        var wire = Data(repeating: 0, count: 89); wire[0] = 0x80
        let encryptedMission = wire.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let entries: [(String, [String: Any], [[String: Any]])] = [
            (Self.root, ["agent_role": "local-auditor", "agent_nickname": "Main fixture"], [
                call("linked-worker", ["agent_type": "worker", "model": "requested-model", "reasoning_effort": "low", "message": "Read the fixture only", "fork_context": true]),
                result("linked-worker", child: Self.explorer),
                call("opaque-mission", ["task_name": "explorer", "message": encryptedMission]), result("opaque-mission", child: Self.opaque)]),
            (Self.explorer, ["agent_role": "explorer", "agent_nickname": "Header explorer",
                "agent_description": "Recorded bounded description " + String(repeating: "fixture ", count: 1000),
                "parent_thread_id": Self.root, "base_instructions": ["text": "Explorer base instruction"]], []),
            (Self.opaque, ["agent_nickname": "explorer", "parent_thread_id": Self.root,
                "base_instructions": ["text": Self.baseMarker + String(repeating: " original instruction ", count: 200),
                                      "encrypted_content": Self.opaqueBaseBlob]], [])
        ]
        var paths: [String: URL] = [:]
        for (id, extras, records) in entries {
            var header: [String: Any] = ["id": id, "cwd": base.path, "cli_version": "0.160.0", "source": "cli", "history_mode": "legacy"]
            header.merge(extras) { _, new in new }
            let path = home.appendingPathComponent("sessions/rollout-" + id + ".jsonl")
            var data = Data()
            for record in [event("session_meta", header)] + records { data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10) }
            try data.write(to: path); paths[id] = path
        }
        opaquePath = paths[Self.opaque]!
        let dbPath = home.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let connection else { throw LensError.unavailable("Own SQLite fixture unavailable") }
        func sql(_ value: String) throws {
            guard sqlite3_exec(connection, value, nil, nil, nil) == SQLITE_OK else { throw LensError.unavailable(String(cString: sqlite3_errmsg(connection))) }
        }
        do {
            try sql("CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,cwd TEXT,title TEXT,updated_at INTEGER,model TEXT,reasoning_effort TEXT,model_provider TEXT);")
            for (id, _, _) in entries {
                func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
                try sql("INSERT INTO threads VALUES(\(quote(id)),\(quote(paths[id]!.path)),\(quote(base.path)),'Owned fixture',1,\(id == Self.explorer ? "'configured-model'" : "NULL"),\(id == Self.explorer ? "'medium'" : "NULL"),'fixture-provider');")
            }
            sqlite3_close(connection)
        } catch { sqlite3_close(connection); throw error }
        let trap = home.appendingPathComponent("config.toml")
        try Data(("agent_role = \"" + Self.configTrap + "\"\n").utf8).write(to: trap)
        var files = Array(paths.values); files += [dbPath, trap]
        originals = try Dictionary(uniqueKeysWithValues: files.map { ($0, Self.digest(try Data(contentsOf: $0))) })
    }
    func unchanged() throws -> Bool { try originals.allSatisfy { try Self.digest(Data(contentsOf: $0.key)) == $0.value } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
