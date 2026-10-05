import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import CryptoKit
import QuartzCore
import LensCore

/// Source-matched native tab-strip qualification, using only anonymous local data.
/// Own-process AX frames qualify layout; cached PNGs do not qualify compositor glass.
@main struct TabsV59Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Tab qualification: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output"), corpus = try argument("--corpus")
        let fixture = try TabsFixture(corpus: corpus, output: output)
        // Argument-domain overrides apply only to this probe process. In particular,
        // do not write NSGlobalDomain or change the person's scrollbar preference.
        UserDefaults.standard.setVolatileDomain([
            "AppleShowScrollBars": "Always", "lensControlAccent": "lens",
            "lensTabMaterial": "system", "lensReduceMotionOverride": true
        ], forName: UserDefaults.argumentDomain)
        var checks: [[String: Any]] = [], layouts: [[String: Any]] = [], renders: [String] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        check("always-visible-scrollbars-are-process-local", UserDefaults.standard.string(forKey: "AppleShowScrollBars") == "Always")

        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: SessionReaderPool())
        store.setNavigationScope(UUID().uuidString)
        await store.start(); await store.open(fixture.rootID); await store.waitForPresentation()
        defer { store.stopObserving() }
        store.showSessionPicker = false; store.chatVisible = false; store.inspectorVisible = false
        guard store.snapshot?.root.id == fixture.rootID,
              let environment = store.snapshot?.environments.first(where: { $0.path == fixture.alpha.path }) ?? store.snapshot?.environments.first else {
            throw LensError.unavailable("The anonymous tab fixture was not indexed.")
        }
        // These deliberately long navigation labels are synthetic destinations in
        // the anonymous environment. The tab strip never opens their file contents.
        for index in 1...7 {
            let path = fixture.alpha.appendingPathComponent("src/VeryLongNavigationDestinationForResponsiveWorkspaceTabs-\(index).swift").path
            store.navigate(.file(environment: environment.id, path: path, line: nil, version: nil), newTab: true)
        }
        guard let active = store.tabs.last else { throw CocoaError(.fileReadUnknown) }
        store.pinTab(active.id)
        store.enableLiveTimeline(at: Date())
        let frozenTabs = tabSignature(store), frozenSelection = store.selection, frozenActive = store.activeTab
        let frozenWindow = store.liveState.window
        check("seven-long-tabs-have-stable-destinations", store.tabs.count == 7 && store.tabs.map(\.id).count == Set(store.tabs.map(\.id)).count)
        check("pinned-active-tab-and-live-are-established", store.tabs.last?.pinned == true && store.activeTab == active.id && store.liveTimelineVisible && store.liveState.following)

        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                for size in [13.0, 20.0] {
                    let controller = NSHostingController(rootView: TabsProbeHeader(store: store, dark: dark, textSize: size))
                    controller.sizingOptions = []
                    let host = controller.view
                    let identifier = "v59-tabs-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size))"
                    let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 430, height: 90), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.setAccessibilityIdentifier(identifier)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentViewController = controller; window.setContentSize(NSSize(width: 430, height: 90)); window.orderBack(nil)
                    for width in [430.0, 720.0, 430.0] {
                        window.setContentSize(NSSize(width: width, height: 90)); host.frame.size = NSSize(width: width, height: 90)
                        await settle(host)
                        let cycle = layouts.count, suffix = "\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size))-\(Int(width))-\(cycle)"
                        let activeID = "lens-tab-" + active.id.uuidString
                        let required: Set<String> = [activeID, "lens-tab-close-" + active.id.uuidString, "lens-tabs-live", "lens-tab-overflow"]
                        let layout = accessibilityFrames(host, requiredIDs: required)
                        let controls = layout.frames.filter { isTabControl($0.key) }
                        let bounds = contentScreenBounds(host)
                        check("tab-strip-keeps-requested-native-width-" + suffix, abs(host.bounds.width - width) < 0.01)
                        check("no-scroll-view-or-scroller-with-always-scrollbars-" + suffix, descendants(host).allSatisfy { !($0 is NSScrollView) && !($0 is NSScroller) })
                        check("active-tab-and-close-remain-visible-" + suffix, layout.diagnostics.isEmpty && required.allSatisfy { layout.frames[$0].map { contains(bounds, $0) } == true })
                        check("exactly-one-reachable-native-overflow-menu-" + suffix, layout.identifierCounts["lens-tab-overflow"] == 1 && layout.roles["lens-tab-overflow"] == kAXMenuButtonRole)
                        let orderedFrames = controls.sorted { $0.key < $1.key }.map(\.value)
                        check("all-visible-tab-controls-fit-and-do-not-overlap-" + suffix,
                              !orderedFrames.isEmpty && orderedFrames.allSatisfy { contains(bounds, $0) }
                              && orderedFrames.enumerated().allSatisfy { i, frame in orderedFrames.dropFirst(i + 1).allSatisfy { frame.intersection($0).isEmpty } })
                        // sizingOptions=[] deliberately disables intrinsic AppKit
                        // sizing. Ask SwiftUI for its content size at this width.
                        let height = controller.sizeThatFits(in: NSSize(width: width, height: 1000)).height
                        if size == 13 {
                            check("default-tab-header-height-at-most-50-points-" + suffix, height.isFinite && height > 0 && height <= 50)
                        }
                        check("resizing-does-not-mutate-tabs-selection-or-live-" + suffix,
                              tabSignature(store) == frozenTabs && store.selection == frozenSelection && store.activeTab == frozenActive
                              && store.liveTimelineVisible && store.liveState.following && store.liveState.window == frozenWindow)
                        layouts.append(layout.receipt(scenario: suffix, width: width, textSize: size, fittingHeight: height, contentBounds: bounds))
                        // Save a small sample, never label it a real production screenshot.
                        if width == 720 && size == 13 {
                            let name = "component-cache-tabs-\(language.rawValue)-\(dark ? "dark" : "light").png"
                            try capture(host, path: output.appendingPathComponent(name)); renders.append(name)
                        }
                    }
                    window.contentViewController = nil; window.contentView = nil; window.close()
                }
            }
        }

        // Select and close through the actual native buttons, not equivalent store
        // mutations. The first nonactive tab is visible in the full-width row.
        LensL10n.language = .fr
        let controller = NSHostingController(rootView: TabsProbeHeader(store: store, dark: false, textSize: 13))
        controller.sizingOptions = []
        let host = controller.view
        // Both long tabs must be visible for the direct button-action checks.
        // At 430/720 the component may correctly keep only the active one.
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1200, height: 90), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.setAccessibilityIdentifier("v59-tabs-native-actions")
        window.contentViewController = controller; window.setContentSize(NSSize(width: 1200, height: 90)); window.orderBack(nil)
        await settle(host)
        guard let first = store.tabs.first else { throw CocoaError(.fileReadUnknown) }
        let firstID = "lens-tab-" + first.id.uuidString
        let firstLayout = accessibilityFrames(host, requiredIDs: [firstID, "lens-tab-overflow", "lens-tabs-live"])
        let selectedByPress = press(firstID, in: firstLayout)
        await settle(host)
        check("native-tab-button-selects-exact-destination-and-keeps-live", selectedByPress && store.activeTab == first.id && store.selection == first.destination && store.isTabPresented(first) && store.liveTimelineVisible && store.liveState.following)
        let countBeforePin = store.tabs.count
        store.pinTab(first.id)
        check("pin-command-keeps-selection-tab-count-and-live", store.tabs.first?.pinned == true && store.tabs.count == countBeforePin && store.activeTab == first.id && store.selection == first.destination && store.liveTimelineVisible && store.liveState.following)
        store.pinTab(first.id)
        check("unpin-command-is-reversible", store.tabs.first?.pinned == false && store.tabs.count == countBeforePin && store.activeTab == first.id)
        await settle(host)
        let closeID = "lens-tab-close-" + first.id.uuidString
        let closeLayout = accessibilityFrames(host, requiredIDs: [closeID, "lens-tab-overflow", "lens-tabs-live"])
        let closedByPress = press(closeID, in: closeLayout)
        await settle(host)
        check("native-close-button-removes-exact-tab-and-keeps-live", closedByPress && store.tabs.count == countBeforePin - 1 && !store.tabs.contains { $0.id == first.id } && store.liveTimelineVisible && store.liveState.following)
        check("closing-active-tab-restores-an-existing-destination", store.activeTab == active.id && store.selection == active.destination && store.tabs.last?.pinned == true)
        let afterClose = tabSignature(store)
        let liveLayout = accessibilityFrames(host, requiredIDs: ["lens-tabs-live", "lens-tab-overflow"])
        let livePressed = press("lens-tabs-live", in: liveLayout)
        await settle(host)
        check("native-live-button-restores-list-without-closing-tabs", livePressed && store.selection == nil && store.section == .activity && tabSignature(store) == afterClose && store.liveTimelineVisible && store.liveState.following)
        window.contentViewController = nil; window.contentView = nil; window.close()
        check("original-journals-and-worktree-files-are-unchanged", fixture.sourcesUnchanged())
        store.stopObserving(); await store.investigation.flushAndStop()

        try JSONSerialization.data(withJSONObject: layouts, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("tab-control-layouts.json"))
        let receipt: [String: Any] = [
            "checks": checks, "renders": renders,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Native source-matched LensWorkspaceTabs; anonymous copied journals; own-process AX frames and button AXPress; 430/720-point resize; French/English, light/dark, 13/20-point inherited font; private process-only Always scrollbar override.",
            "fixture": ["originalCorpus": corpus.path, "privateHome": fixture.home.path, "rootID": fixture.rootID, "observedFilesModified": false, "syntheticLongFileDestinationsNotOpened": true],
            "unqualified": ["Cached PNGs are offscreen component-cache renders, can omit native SwiftUI labels or glass composition, and do not qualify production appearance. Real compositor screenshots are separate.", "Physical mouse/trackpad gestures, VoiceOver narration, and opening the overflow/context menu require interactive inspection. Pin/unpin use the existing store command; selection, close and return to Live use own-process native AXPress.", "No user session, auth file, Codex process, App Server or network is accessed. No performance claim is derived from this focused layout probe."]
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    private static func argument(_ name: String) throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw CocoaError(.fileNoSuchFile) }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    @MainActor private static func tabSignature(_ store: LensStore) -> [String] {
        store.tabs.map { "\($0.id.uuidString)|\($0.destination)|\($0.pinned)" }
    }
    private static func isTabControl(_ id: String) -> Bool { id.hasPrefix("lens-tab-") || id == "lens-tabs-live" }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func contains(_ container: NSRect, _ frame: NSRect) -> Bool {
        !frame.isEmpty && frame.minX >= container.minX - 0.5 && frame.maxX <= container.maxX + 0.5
        && frame.minY >= container.minY - 0.5 && frame.maxY <= container.maxY + 0.5
    }
    @MainActor private static func contentScreenBounds(_ host: NSView) -> NSRect {
        guard let window = host.window else { return .zero }
        let screen = window.convertToScreen(host.convert(host.bounds, to: nil))
        let primaryMaxY = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: screen.minX, y: primaryMaxY - screen.maxY, width: screen.width, height: screen.height)
    }
    private struct ControlLayoutSnapshot {
        var frames: [String: NSRect] = [:], roles: [String: String] = [:], elements: [String: AXUIElement] = [:]
        var identifierCounts: [String: Int] = [:], diagnostics: [String] = [], coverageNotes: [String] = [], requiredIDs: [String] = []
        var windowMatchCount = 0, visitedCount = 0
        func receipt(scenario: String, width: Double, textSize: Double, fittingHeight: Double, contentBounds: NSRect) -> [String: Any] {
            ["scenario": scenario, "width": width, "textSize": textSize, "fittingHeight": fittingHeight,
             "contentBounds": NSStringFromRect(contentBounds), "frames": frames.mapValues { NSStringFromRect($0) }, "roles": roles,
             "identifierCounts": identifierCounts, "diagnostics": diagnostics, "coverageNotes": coverageNotes,
             "requiredControlIDs": requiredIDs, "windowMatchCount": windowMatchCount, "visitedElementCount": visitedCount,
             "method": "Documented own-PID AXUIElement API, exact test-window identifier, typed screen-coordinate AXPosition/AXSize. Missing or duplicate required controls fail."]
        }
    }
    @MainActor private static func accessibilityFrames(_ host: NSView, requiredIDs: Set<String>) -> ControlLayoutSnapshot {
        var result = ControlLayoutSnapshot(); result.requiredIDs = requiredIDs.sorted()
        guard let windowID = host.window?.accessibilityIdentifier(), !windowID.isEmpty else {
            result.diagnostics.append("Host has no identified test window."); return result
        }
        func value(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
            var result: CFTypeRef?; let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result); return (error, result)
        }
        let (windowError, windowsValue) = value(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute)
        guard windowError == .success, let windows = windowsValue as? [AXUIElement] else {
            result.diagnostics.append("Own-process AXWindows unavailable: \(windowError.rawValue)."); return result
        }
        let matches = windows.filter { value($0, kAXIdentifierAttribute).1 as? String == windowID }; result.windowMatchCount = matches.count
        guard matches.count == 1, let window = matches.first else {
            result.diagnostics.append("Expected one identified AX window, found \(matches.count)."); return result
        }
        var seen: [CFHashCode: [AXUIElement]] = [:], duplicateIDs: Set<String> = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 40, result.visitedCount < 20_000 else { result.diagnostics.append("AX traversal exceeded depth/node bounds."); return }
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            seen[hash, default: []].append(element); result.visitedCount += 1
            if let id = value(element, kAXIdentifierAttribute).1 as? String, !id.isEmpty, id != windowID {
                result.identifierCounts[id, default: 0] += 1
                if isTabControl(id) || requiredIDs.contains(id) {
                    if result.roles[id] != nil {
                        duplicateIDs.insert(id); result.frames.removeValue(forKey: id); result.elements.removeValue(forKey: id)
                        result.diagnostics.append("Multiple reachable tab controls share identifier \(id).")
                    } else {
                        result.roles[id] = value(element, kAXRoleAttribute).1 as? String ?? "role unavailable"
                        let (positionError, positionValue) = value(element, kAXPositionAttribute), (sizeError, sizeValue) = value(element, kAXSizeAttribute)
                        var point = CGPoint.zero, size = CGSize.zero
                        if positionError == .success, sizeError == .success, let positionValue, let sizeValue,
                           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
                           AXValueGetValue(positionValue as! AXValue, .cgPoint, &point), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                           point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, !duplicateIDs.contains(id) {
                            result.frames[id] = NSRect(origin: point, size: size); result.elements[id] = element
                        } else { result.diagnostics.append("Unavailable/invalid frame for \(id): position \(positionError.rawValue), size \(sizeError.rawValue).") }
                    }
                } else if result.identifierCounts[id] == 2 {
                    result.coverageNotes.append("Unrelated AX identifier repeated: \(id). This does not qualify it as a unique control.")
                }
            }
            let (childrenError, childrenValue) = value(element, kAXChildrenAttribute)
            if childrenError == .success { for child in childrenValue as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) } }
            else if childrenError != .attributeUnsupported && childrenError != .noValue {
                let id = value(element, kAXIdentifierAttribute).1 as? String, role = value(element, kAXRoleAttribute).1 as? String ?? "role unavailable"
                if let id, isTabControl(id) || requiredIDs.contains(id) { result.diagnostics.append("Tab control \(id) has unavailable AXChildren: \(childrenError.rawValue).") }
                else { result.coverageNotes.append("AXChildren unavailable for unrelated node \(id ?? role): \(childrenError.rawValue). Its descendants are not covered; required missing controls still fail.") }
            }
        }
        walk(window, depth: 0)
        for id in requiredIDs.sorted() where result.frames[id] == nil { result.diagnostics.append("Required control has no unique valid frame: \(id).") }
        return result
    }
    @MainActor private static func press(_ id: String, in snapshot: ControlLayoutSnapshot) -> Bool {
        guard snapshot.diagnostics.isEmpty, let element = snapshot.elements[id] else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    @MainActor private static func settle(_ view: NSView) async {
        for _ in 0..<15 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.window?.displayIfNeeded(); CATransaction.flush() }
    }
    @MainActor private static func capture(_ view: NSView, path: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try bytes.write(to: path)
    }
}

private struct TabsProbeHeader: View {
    @ObservedObject var store: LensStore
    let dark: Bool
    let textSize: Double
    var body: some View {
        LensWorkspaceTabs(store: store)
            .font(.system(size: textSize))
            .padding(.horizontal, 16).padding(.vertical, 4).frame(minHeight: 36)
            .background(LensBrand.chrome)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private final class TabsFixture {
    let home: URL, rootID: String, alpha: URL
    private var originalHashes: [URL: String] = [:]
    init(corpus: URL, output: URL) throws {
        let resolvedCorpus = corpus.resolvingSymlinksInPath(), resolvedOutput = output.resolvingSymlinksInPath()
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard resolvedCorpus.path.hasPrefix(privateTemporaryRoot), resolvedOutput.path.hasPrefix(privateTemporaryRoot),
              FileManager.default.fileExists(atPath: corpus.appendingPathComponent("ANONYMOUS_FIXTURE").path) else { throw CocoaError(.fileReadNoPermission) }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any]
        guard json?["anonymous"] as? Bool == true, let root = json?["rootID"] as? String,
              let originals = json?["rollouts"] as? [String: [String: Any]], let trees = json?["worktrees"] as? [String: String],
              let alphaPath = trees["alpha"], let betaPath = trees["beta"] else { throw CocoaError(.fileReadUnknown) }
        rootID = root; alpha = URL(fileURLWithPath: alphaPath); home = output.appendingPathComponent("anonymous-tabs-home")
        guard !FileManager.default.fileExists(atPath: home.path),
              [alphaPath, betaPath].allSatisfy({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(resolvedCorpus.path + "/") }) else { throw CocoaError(.fileReadNoPermission) }
        let directory = home.appendingPathComponent("sessions/2026/10/04")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copiedNames: Set<String> = []
        for entry in originals.values {
            guard let recorded = entry["path"] as? String else { throw CocoaError(.fileReadUnknown) }
            let source = URL(fileURLWithPath: recorded)
            guard source.resolvingSymlinksInPath().path.hasPrefix(resolvedCorpus.path + "/"), copiedNames.insert(source.lastPathComponent).inserted else { throw CocoaError(.fileReadNoPermission) }
            let bytes = try Data(contentsOf: source); originalHashes[source] = Self.digest(bytes)
            try bytes.write(to: directory.appendingPathComponent(source.lastPathComponent))
        }
        for path in [alphaPath, betaPath] {
            for relative in ["src/Same.swift", "src/Origin.swift"] {
                let file = URL(fileURLWithPath: path).appendingPathComponent(relative)
                if let bytes = try? Data(contentsOf: file) { originalHashes[file] = Self.digest(bytes) }
            }
        }
    }
    func sourcesUnchanged() -> Bool { originalHashes.allSatisfy { (url, hash) in (try? Data(contentsOf: url)).map(Self.digest) == hash } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
