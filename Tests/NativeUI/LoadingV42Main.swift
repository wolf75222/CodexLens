import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Observation
import SwiftUI
import QuartzCore
import LensCore

/// Native layout regression and a visible fixture using the product views.
/// No Codex process, model request, real journal or global preference is used.
@main struct LoadingV42Main {
    @MainActor private static var diagnosticOutput: URL?
    @MainActor private static weak var diagnosticWindow: NSWindow?
    @MainActor private static var stage = "setup"
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(CommandLine.arguments.contains("--linger") ? .accessory : .prohibited)
        if !CommandLine.arguments.contains("--linger") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                fputs("Loading fixture exceeded its execution bound.\n", stderr); Darwin.exit(EXIT_FAILURE)
            }
        }
        Task { @MainActor in
            do {
                try await qualify()
                if !CommandLine.arguments.contains("--linger") { NSApp.terminate(nil) }
            } catch {
                fputs("Loading qualification: \(error)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.count > index + 1 else {
            throw LensError.unavailable("Missing private output directory")
        }
        let outputText = CommandLine.arguments[index + 1]
        guard outputText.hasPrefix("/") else { throw LensError.unavailable("Absolute private output required") }
        let output = URL(fileURLWithPath: outputText)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        let hash = SHA256.hash(data: Data(outputText.utf8)).map { String(format: "%02x", $0) }.joined()
        guard manifest?["entrypoint"] as? String == "LoadingV42Main.swift",
              manifest?["productionEntryPointReplaced"] as? Bool == true,
              manifest?["copiedAppSourcesModified"] as? Bool == false,
              Bundle.main.bundleIdentifier == "fr.codexlens.designprobe.v07." + hash.prefix(12),
              Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "NativeDesignV07Probe" else {
            throw LensError.unavailable("Source-matched disposable wrapper required; refusing production preferences")
        }
        diagnosticOutput = output
        UserDefaults.standard.setVolatileDomain(["lens.language": "fr", "lensReduceMotionOverride": false,
            "lensRootByWindow": [String: String](), "lensTabsByRoot": [String: Data](), "lensChatByRoot": [String: String]()], forName: UserDefaults.argumentDomain)
        LensL10n.language = .fr
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-source"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: SessionReaderPool(investigationRegistryDirectory: output.appendingPathComponent("registry")))
        store.investigation.automaticCodexCheckEnabled = false
        defer { if !CommandLine.arguments.contains("--linger") { store.stopObserving() } }
        store.catalog = [SessionSummary(id: "11111111-1111-4111-8111-111111111111", title: "Session Alpha", cwd: "/anonymous/worktrees/alpha", modifiedAt: Date())]
        let originalCatalog = store.catalog
        var checks: [[String: Any]] = [], observations: [[String: Any]] = [], renders: [[String: Any]] = []
        var completed = false
        defer { if !completed {
            try? JSONSerialization.data(withJSONObject: ["checks": checks, "observations": observations, "renders": renders,
                "completed": false, "failedStage": stage, "allExecutedChecksPassed": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        } }
        func check(_ id: String, _ passed: Bool) {
            checks.append(["id": id, "name": id, "passed": passed])
            if !passed, let window = diagnosticWindow { saveAXDiagnostics(window, name: id, reason: "Decisive assertion failed") }
        }
        let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 740, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("LoadingV42-owned-" + UUID().uuidString)
        diagnosticWindow = window
        defer { if !CommandLine.arguments.contains("--linger") { window.orderOut(nil); window.contentView = nil; window.close() } }
        window.title = "Codex Lens — chargement (données de test)"
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: 540))
        window.orderBack(nil)
        _ = try await waitForOwnAX(window, name: "owned-window-registered") { !$0.isEmpty }
        for dark in [false, true] {
            for width in [620.0, 1040.0] {
                store.busy = true
                let host = NSHostingView(rootView: SessionPickerView().environmentObject(store).environment(\.lensReduceMotionOverride, false))
                host.sizingOptions = []
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: width, height: 540))
                window.orderBack(nil)
                await settle(host)
                let indicators = descendants(host).compactMap { $0 as? NSProgressIndicator }
                let id = "picker-\(dark ? "dark" : "light")-\(Int(width))"
                check(id + "-single-native-spinner", indicators.count == 1)
                if let spinner = indicators.first {
                    let rect = spinner.convert(spinner.bounds, to: host)
                    let offset = abs(rect.midX - host.bounds.midX)
                    check(id + "-spinner-centred", offset <= 2 && rect.width > 0 && rect.height > 0)
                    observations.append(["id": id, "nativeStyle": spinner.style == .bar ? "bar" : "spinner", "spinnerFrame": NSStringFromRect(rect), "contentBounds": NSStringFromRect(host.bounds), "horizontalOffsetPoints": offset])
                } else { check(id + "-spinner-centred", false) }
            }
        }
        store.cancelSessionOpening()
        check("cancel-preserves-catalog", !store.busy && store.catalog == originalCatalog)
        for width in [260.0, 620.0] {
            let host = NSHostingView(rootView: LensLoadingState(title: "Recherche de la version dans le dépôt associé…").frame(maxHeight: .infinity).environment(\.lensReduceMotionOverride, false))
            host.sizingOptions = []
            window.contentView = host; window.setContentSize(NSSize(width: width, height: 260))
            await settle(host)
            let spinner = descendants(host).compactMap { $0 as? NSProgressIndicator }.first
            let rect = spinner.map { $0.convert($0.bounds, to: host) }
            check("long-title-\(Int(width))-spinner-centred", rect.map { abs($0.midX - host.bounds.midX) <= 2 } ?? false)
        }
        let reduced = NSHostingView(rootView: LensLoadingState(title: "Lecture des traces…", longRunningDelay: .seconds(10)).frame(maxHeight: .infinity).environment(\.lensReduceMotionOverride, true))
        reduced.sizingOptions = []; window.contentView = reduced
        await settle(reduced)
        check("reduced-motion-no-animated-spinner", descendants(reduced).allSatisfy { !($0 is NSProgressIndicator) })
        // Direct fixtures control the delay without altering a reader/model or
        // deriving a completion fraction from elapsed time.
        for dark in [false, true] { for width in [260.0, 620.0] {
            let immediate = LoadingLifecycleState(delay: .zero, title: "Chargement prolongé de test")
            let host = NSHostingView(rootView: ControlledLoadingFixture(state: immediate))
            host.sizingOptions = []; window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 260)); window.orderBack(nil)
            await settle(host)
            try await wait("immediate-native-bar") { descendants(host).contains { $0 is LensLoadingBarIndicator } }
            let bar = try require(descendants(host).compactMap { $0 as? LensLoadingBarIndicator }.first, "native long bar")
            let rect = bar.convert(bar.bounds, to: host), id = "long-bar-\(dark ? "dark" : "light")-\(Int(width))"
            check(id + "-thin-bounded-centred", abs(rect.midX - host.bounds.midX) <= 2 && rect.width > 0 && rect.width <= 240.5 && abs(rect.height - 12) <= 0.5)
            check(id + "-native-indeterminate-animation-configured", bar.style == .bar && bar.isIndeterminate && bar.isDisplayedWhenStopped && bar.animationEnabled)
            let accessibleBar: ([AXUIElement]) -> Bool = { nodes in nodes.contains {
                attribute($0, kAXIdentifierAttribute) as? String == "lens-progress-long-running"
                    && attribute($0, kAXDescriptionAttribute) as? String == "Chargement prolongé de test"
                    && attribute($0, kAXValueAttribute) as? String == "En cours"
            } }
            let nodes = try await waitForOwnAX(window, name: id + "-accessible-title-and-in-progress-value", accessibleBar)
            check(id + "-accessible-title-and-in-progress-value", accessibleBar(nodes))
            observations.append(["id": id, "barFrame": NSStringFromRect(rect), "contentBounds": NSStringFromRect(host.bounds),
                "style": "NSProgressIndicator.bar", "indeterminate": bar.isIndeterminate, "animationEnabled": bar.animationEnabled])
            renders.append(try capture(host, name: id, output: output))
            immediate.visible = false
            try await wait("immediate-loader-dismantled") { !descendants(host).contains { $0 is LensLoadingBarIndicator } && !bar.animationEnabled }
            check(id + "-dismantle-stops-owned-animation", !bar.animationEnabled)
            window.contentView = nil
        } }

        let state = LoadingLifecycleState(delay: .seconds(1))
        let transition = NSHostingView(rootView: ControlledLoadingFixture(state: state))
        transition.sizingOptions = []; window.contentView = transition
        window.appearance = NSAppearance(named: .darkAqua); window.setContentSize(NSSize(width: 620, height: 260)); window.orderBack(nil)
        await settle(transition)
        check("controlled-delay-starts-with-spinner", descendants(transition).contains { ($0 as? NSProgressIndicator)?.style == .spinning }
            && !descendants(transition).contains { $0 is LensLoadingBarIndicator })
        let titleBefore = try await frame(window, label: state.title, role: kAXStaticTextRole)
        let cancelBefore = try await frame(window, label: state.cancelTitle, role: kAXButtonRole)
        renders.append(try capture(transition, name: "controlled-early-spinner", output: output))
        try await wait("controlled-delayed-bar") { descendants(transition).contains { $0 is LensLoadingBarIndicator } }
        await settle(transition)
        let stableBar = try require(descendants(transition).compactMap { $0 as? LensLoadingBarIndicator }.first, "transition bar")
        let titleAfter = try await frame(window, label: state.title, role: kAXStaticTextRole)
        let cancelAfter = try await frame(window, label: state.cancelTitle, role: kAXButtonRole)
        check("delayed-transition-keeps-title-and-cancel-positions", sameFrame(titleBefore, titleAfter) && sameFrame(cancelBefore, cancelAfter))
        observations.append(["id": "controlled-delayed-transition", "titleBefore": NSStringFromRect(titleBefore), "titleAfter": NSStringFromRect(titleAfter),
            "cancelBefore": NSStringFromRect(cancelBefore), "cancelAfter": NSStringFromRect(cancelAfter), "delay": "1 second controlled fixture"])
        renders.append(try capture(transition, name: "controlled-delayed-bar", output: output))
        state.layoutRevision += 1; await settle(transition)
        check("unrelated-render-update-retains-native-bar-and-animation-configuration", descendants(transition).contains { $0 === stableBar } && stableBar.animationEnabled)
        state.reducedMotion = true
        try await wait("reduced-long-bar-stopped") { !stableBar.animationEnabled }
        check("reduced-motion-keeps-indeterminate-visible-bar-stationary", descendants(transition).contains { $0 === stableBar }
            && stableBar.style == .bar && stableBar.isIndeterminate && stableBar.isDisplayedWhenStopped && !stableBar.animationEnabled)
        renders.append(try capture(transition, name: "controlled-reduced-motion-bar", output: output))
        state.reducedMotion = false
        try await wait("long-bar-animation-restored") { stableBar.animationEnabled }
        state.operationID = UUID()
        try await wait("same-title-new-operation-resets-spinner") {
            !descendants(transition).contains { $0 is LensLoadingBarIndicator }
                && descendants(transition).contains { ($0 as? NSProgressIndicator)?.style == .spinning } && !stableBar.animationEnabled
        }
        check("same-title-new-operation-starts-early-without-old-bar", descendants(transition).contains { ($0 as? NSProgressIndicator)?.style == .spinning } && !stableBar.animationEnabled)
        try await wait("new-operation-delayed-bar") { descendants(transition).contains { $0 is LensLoadingBarIndicator } }
        try await press(window, label: state.cancelTitle)
        try await wait("accessible-cancel-hides-loader") { state.cancelCount == 1 && !state.visible && !descendants(transition).contains { $0 is NSProgressIndicator } }
        check("long-loading-accessible-cancel-dispatches-once", state.cancelCount == 1 && !state.visible)

        // Disappear before the default1.5s delay, remain absent beyond that
        // deadline, then reopen the same conditional leaf with an early state.
        state.delay = .milliseconds(1500); state.visible = true
        await settle(transition)
        check("reopened-loader-starts-early", !descendants(transition).contains { $0 is LensLoadingBarIndicator })
        state.visible = false; await settle(transition)
        try await Task.sleep(for: .milliseconds(1600))
        check("disappeared-loader-does-not-mount-a-late-bar", !descendants(transition).contains { $0 is NSProgressIndicator })
        state.visible = true; await settle(transition)
        check("after-cancelled-delay-reopened-loader-has-fresh-spinner", descendants(transition).contains { ($0 as? NSProgressIndicator)?.style == .spinning }
            && !descendants(transition).contains { $0 is LensLoadingBarIndicator })
        state.visible = false; await settle(transition)

        // Measured fractions are injected into the product component; engine
        // measurements and shared-reader cancellation have separate Core tests.
        state.delay = .seconds(10); state.reducedMotion = false
        state.progress = .init(stage: .readingMetadata, completed: 25, total: 100)
        state.visible = true; await settle(transition)
        let measuredBar = try require(descendants(transition).compactMap { $0 as? LensLoadingBarIndicator }.first, "measured bar")
        check("measured-progress-visible-without-delay", !measuredBar.isIndeterminate && abs(measuredBar.doubleValue - 0.25) < 0.001 && !measuredBar.animationEnabled)
        renders.append(try capture(transition, name: "measured-catalog-quarter", output: output))
        state.progress = .init(stage: .readingMetadata, completed: 75, total: 100)
        await settle(transition)
        check("measured-progress-follows-work-keeps-control", descendants(transition).contains { $0 === measuredBar } && abs(measuredBar.doubleValue - 0.75) < 0.001)
        state.reducedMotion = true
        state.progress = .init(stage: .readingHistory, completed: 524288, total: 1048576, fileName: "fixture-history.jsonl")
        await settle(transition)
        let historyBar = try require(descendants(transition).compactMap { $0 as? LensLoadingBarIndicator }.first, "history bar")
        check("stage-change-resets-native-fill", historyBar !== measuredBar)
        check("reduce-motion-retains-measured-value", !historyBar.isIndeterminate && abs(historyBar.doubleValue - 0.5) < 0.001 && !historyBar.animationEnabled)
        renders.append(try capture(transition, name: "measured-history-half-reduced-motion", output: output))
        state.showsOpeningSteps = true
        state.progress = .init(stage: .readingHistory, completed: 25, total: 50, fileName: "second-history.jsonl",
            history: .init(completedBytes: 150, totalBytes: 200, completedFiles: 1, totalFiles: 3, currentFile: 2))
        await settle(transition)
        let globalBar = try require(descendants(transition).compactMap { $0 as? LensLoadingBarIndicator }.first, "aggregate history bar")
        check("history-bar-follows-global-bytes-instead-of-file-fraction", abs(globalBar.doubleValue - 0.75) < 0.001 && !globalBar.isIndeterminate)
        check("opening-phases-remain-distinct-from-history-percentage", state.progress?.openingStep == 2)
        renders.append(try capture(transition, name: "aggregate-history-three-quarters", output: output))
        state.progress = .init(stage: .readingHistory, completed: 10, total: 20, fileName: "third-history.jsonl",
            history: .init(completedBytes: 160, totalBytes: 200, completedFiles: 2, totalFiles: 3, currentFile: 3))
        await settle(transition)
        check("changing-file-keeps-global-bar-and-advances-total", descendants(transition).contains { $0 === globalBar } && abs(globalBar.doubleValue - 0.8) < 0.001)
        state.progress = .init(stage: .readingHistory, completed: 10, total: 20, fileName: "third-history.jsonl",
            history: .init(completedBytes: 160, totalBytes: 400, completedFiles: 2, totalFiles: 4, currentFile: 3))
        await settle(transition)
        let expandedBar = try require(descendants(transition).compactMap { $0 as? LensLoadingBarIndicator }.first, "expanded history plan")
        check("new-file-plan-resets-retained-fill-to-measured-global-fraction", expandedBar !== globalBar && abs(expandedBar.doubleValue - 0.4) < 0.001)
        state.showsOpeningSteps = false
        state.progress = .init(stage: .savingIndex)
        state.delay = .zero
        await settle(transition)
        let unknownBar = try require(descendants(transition).compactMap { $0 as? LensLoadingBarIndicator }.first, "unknown stage bar")
        check("unknown-stage-clears-measured-fraction", unknownBar.isIndeterminate && !unknownBar.animationEnabled)
        let cancelsBefore = state.cancelCount
        try await press(window, label: state.cancelTitle)
        try await wait("measured-cancel-hides-loader") { !state.visible }
        check("measured-progress-cancel-remains-accessible", state.cancelCount == cancelsBefore + 1 && !state.visible)

        let receipt: [String: Any] = ["checks": checks, "observations": observations, "renders": renders, "completed": true,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual product SessionPickerView and loading component in a native fixture; production @main replaced.",
            "realCodexHomeRead": false, "modelRequests": 0,
            "unqualified": ["VoiceOver and physical mouse/trackpad input", "Offscreen cache PNGs are not application compositor screenshots or Liquid Glass qualification",
                "animationEnabled inspects the product-owned native configuration; no frame-rate or animation restart timing is measured"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        completed = true
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else { throw LensError.unavailable("Loading assertions failed; inspect receipt") }
        if CommandLine.arguments.contains("--linger") {
            store.busy = true
            let host = NSHostingView(rootView: LoadingReviewFixture(store: store, window: window))
            host.sizingOptions = []; window.contentView = host
            window.setContentSize(NSSize(width: 740, height: 590))
            window.setFrameOrigin(NSPoint(x: 120, y: 120))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor private static func settle(_ view: NSView) async {
        for _ in 0..<10 { await Task.yield(); try? await Task.sleep(nanoseconds: 20_000_000) }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private static func wait(_ name: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LensError.unavailable("Bounded loading fixture did not reach " + name) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + label) }; return value
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }; return value
    }
    @MainActor private static func ownAXSnapshot(_ window: NSWindow) -> (nodes: [AXUIElement], diagnostics: [String]) {
        let application = AXUIElementCreateApplication(getpid()); AXUIElementSetMessagingTimeout(application, 0.5)
        var rawWindows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
        guard error == .success, let peers = rawWindows as? [AXUIElement] else {
            return ([], ["Own-process AXWindows unavailable: \(error.rawValue)"])
        }
        let windows = peers.filter { attribute($0, kAXIdentifierAttribute) as? String == window.accessibilityIdentifier() }
        guard windows.count == 1, let own = windows.first else {
            return ([], ["Expected one identified own window; found \(windows.count), own-process windows: \(peers.count)"])
        }
        var nodes: [AXUIElement] = [], seen: [CFHashCode: [AXUIElement]] = [:]
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 40, nodes.count < 5000 else { return }
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            seen[hash, default: []].append(element); nodes.append(element)
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(own, depth: 0)
        return (nodes, ["Own-process public AX nodes visited: \(nodes.count)"])
    }
    @MainActor private static func waitForOwnAX(_ window: NSWindow, name: String, _ predicate: ([AXUIElement]) -> Bool) async throws -> [AXUIElement] {
        stage = name
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let snapshot = ownAXSnapshot(window)
            if predicate(snapshot.nodes) { return snapshot.nodes }
            guard ContinuousClock.now < deadline else {
                saveAXDiagnostics(window, name: name, reason: "Own-window AX did not publish required exact nodes within the bound")
                throw LensError.unavailable("Bounded owned AX did not reach " + name)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    @MainActor private static func saveAXDiagnostics(_ window: NSWindow, name: String, reason: String) {
        guard let output = diagnosticOutput else { return }
        let snapshot = ownAXSnapshot(window)
        let nodes = snapshot.nodes.map { node -> [String: String] in
            var values: [String: String] = [:]
            for key in [kAXRoleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                if let value = attribute(node, key) as? String { values[key] = value }
                else if let number = attribute(node, key) as? NSNumber { values[key] = number.stringValue }
            }
            return values
        }
        var native: [[String: Any]] = []
        if let host = window.contentView {
            for indicator in descendants(host).compactMap({ $0 as? NSProgressIndicator }) {
                native.append(["class": String(describing: type(of: indicator)), "frame": NSStringFromRect(indicator.convert(indicator.bounds, to: host)),
                    "style": indicator.style == .bar ? "bar" : "spinning", "indeterminate": indicator.isIndeterminate,
                    "animationEnabled": (indicator as? LensLoadingBarIndicator).map { $0.animationEnabled as Any } ?? NSNull()])
            }
            _ = try? capture(host, name: "failure-" + name, output: output)
        }
        let value: [String: Any] = ["stage": name, "reason": reason, "pid": getpid(),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unavailable", "windowIdentifier": window.accessibilityIdentifier() ?? "unavailable",
            "windowNumber": window.windowNumber, "windowVisible": window.isVisible, "windowFrame": NSStringFromRect(window.frame),
            "accessibilityDiagnostics": snapshot.diagnostics, "accessibilityNodes": nodes, "nativeIndicators": native,
            "scope": "Only this exact disposable process/window; no screen/input, unlock, permissions request or production app inspection. PNG is offscreen cache only."]
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("failure-" + name + "-AX.json"))
    }
    @MainActor private static func matching(_ nodes: [AXUIElement], label: String, role: String) -> [AXUIElement] {
        nodes.filter { element in
            attribute(element, kAXRoleAttribute) as? String == role
                && [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap { attribute(element, $0) as? String }.contains(label)
        }
    }
    @MainActor private static func frame(_ window: NSWindow, label: String, role: String) async throws -> NSRect {
        let current = try await waitForOwnAX(window, name: "frame-" + role + "-" + label) { matching($0, label: label, role: role).count == 1 }
        let nodes = matching(current, label: label, role: role)
        guard nodes.count == 1, let node = nodes.first,
              let position = attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
            saveAXDiagnostics(window, name: stage, reason: "Unique owned AX frame unavailable for " + label)
            throw LensError.unavailable("Unique owned AX frame unavailable for " + label)
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
            saveAXDiagnostics(window, name: stage, reason: "Invalid owned AX frame for " + label)
            throw LensError.unavailable("Invalid owned AX frame for " + label)
        }
        return NSRect(origin: point, size: dimensions)
    }
    @MainActor private static func press(_ window: NSWindow, label: String) async throws {
        let current = try await waitForOwnAX(window, name: "press-" + label) { matching($0, label: label, role: kAXButtonRole).count == 1 }
        let nodes = matching(current, label: label, role: kAXButtonRole)
        guard nodes.count == 1, let node = nodes.first, AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else {
            saveAXDiagnostics(window, name: stage, reason: "Owned accessible cancellation unavailable")
            throw LensError.unavailable("Owned accessible cancellation unavailable")
        }
    }
    private static func sameFrame(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }
    @MainActor private static func capture(_ host: NSView, name: String, output: URL) throws -> [String: Any] {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No loading bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No loading PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        return ["file": name + ".png", "width": host.bounds.width, "height": host.bounds.height,
            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "method": "Owned NSHostingView offscreen cache render; not compositor"]
    }

}

@MainActor private struct LoadingReviewFixture: View {
    @ObservedObject var store: LensStore
    let window: NSWindow
    @State private var dark = true
    @State private var reduced = false
    @State private var english = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Données de test").font(.caption).foregroundStyle(.secondary)
                Button("Chargement") { store.busy = true }
                Menu("Affichage") {
                    Toggle("Sombre", isOn: $dark)
                    Toggle("Mouvement réduit", isOn: $reduced)
                    Toggle("English", isOn: $english)
                    Button("Étroit") { window.setContentSize(NSSize(width: 620, height: 590)) }
                    Button("Large") { window.setContentSize(NSSize(width: 1040, height: 680)) }
                }
                Spacer()
                Button("Terminer") { store.stopObserving(); NSApp.terminate(nil) }
            }.controlSize(.small).padding(8)
            Divider()
            SessionPickerView().environmentObject(store)
        }
        .environment(\.lensReduceMotionOverride, reduced)
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { window.appearance = NSAppearance(named: .darkAqua) }
        .onChange(of: dark) { _, value in window.appearance = NSAppearance(named: value ? .darkAqua : .aqua) }
        .onChange(of: english) { _, value in LensL10n.language = value ? .en : .fr }
    }
}

@MainActor @Observable private final class LoadingLifecycleState {
    var visible = true
    var reducedMotion = false
    var operationID = UUID()
    var progress: SessionLoadingProgress?
    var showsOpeningSteps = false
    var layoutRevision = 0
    var cancelCount = 0
    var delay: Duration
    let title: String, cancelTitle: String
    init(delay: Duration, title: String = "Chargement de la fixture", cancelTitle: String = "Annuler la tâche de test") {
        self.delay = delay; self.title = title; self.cancelTitle = cancelTitle
    }
}
@MainActor private struct ControlledLoadingFixture: View {
    let state: LoadingLifecycleState
    var body: some View {
        Group {
            if state.visible {
                LensLoadingState(title: state.title, cancelTitle: state.cancelTitle,
                    onCancel: { state.cancelCount += 1; state.visible = false },
                    longRunningDelay: state.delay, operationID: state.operationID, progress: state.progress, showsOpeningSteps: state.showsOpeningSteps)
                    .padding(.horizontal, CGFloat(state.layoutRevision % 2))
            } else { Color.clear }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.lensReduceMotionOverride, state.reducedMotion)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
