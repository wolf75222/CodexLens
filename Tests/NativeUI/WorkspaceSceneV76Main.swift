import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import LensCore
import SwiftUI

/// Runs the actual production window wrapper and command hierarchy in SwiftUI scenes.
@main struct WorkspaceSceneV76Main: App {
    @NSApplicationDelegateAdaptor(LensApplicationDelegate.self) private var delegate
    @StateObject private var driver: WorkspaceSceneDriverV76
    init() {
        do {
            let fixture = try WorkspaceSceneFixtureV76()
            for (name, value) in ["LENS_CODEX_HOME": fixture.home.path, "CODEX_HOME": fixture.home.path,
                                  "LENS_CACHE_DIRECTORY": fixture.output.appendingPathComponent("cache").path,
                                  "LENS_ARCHIVE_DIRECTORY": fixture.output.appendingPathComponent("archive").path] {
                setenv(name, value, 1)
            }
            UserDefaults.standard.setVolatileDomain(["lens.language": "en", "lensAppearance": "light",
                LensOnboardingState.preferenceKey: true], forName: UserDefaults.argumentDomain)
            LensGuideCoordinator.shared.onboarding.dismiss()
            _driver = StateObject(wrappedValue: WorkspaceSceneDriverV76(fixture: fixture))
        } catch { fputs("Scene fixture setup: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
    }
    var body: some Scene {
        WindowGroup("Codex Lens", id: "session", for: UUID.self) { request in
            LensWindowRoot(requestID: request.wrappedValue).id(request.wrappedValue)
                .environment(\.locale, Locale(identifier: "en")).environment(\.lensReduceMotionOverride, true)
                .frame(minWidth: 900, minHeight: 600)
                .task { await driver.runOnce() }
        } defaultValue: { UUID() }
        .defaultSize(width: 1480, height: 900).windowResizability(.contentMinSize)
        .commands { LensCommands() }
        Settings { LensSettingsView() }
    }
}

@MainActor private final class WorkspaceSceneDriverV76: ObservableObject {
    private let fixture: WorkspaceSceneFixtureV76
    private let initialPID = getpid()
    private var started = false
    private var stage = "bootstrap"
    private var checks: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    private var renders: [String] = []
    private var unqualified = ["Programmatic own-window scene checks and bitmap-cache PNGs are not physical input, VoiceOver or compositor qualification.",
                              "No personal session, authentication request or AI inference is performed. No performance claim is made."]
    init(fixture: WorkspaceSceneFixtureV76) { self.fixture = fixture }
    func runOnce() async {
        guard !started else { return }; started = true
        do {
            try await qualify()
            let owned = contexts, windows = owned.compactMap(\.window)
            stage = "own-production-scenes-shutdown"; try writePhase()
            await LensApplicationCoordinator.shared.prepareToQuit()
            check("own-production-scene-stores-stop-before-exit", owned.count == 2 && owned.allSatisfy { !$0.store.isObserving })
            for window in windows { window.close() }
            check("own-production-scene-windows-unregister-on-close", windows.count == 2 && windows.allSatisfy {
                LensApplicationCoordinator.shared.context(for: $0) == nil
            })
            try writeReceipt(completed: true)
            guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else {
                throw LensError.unavailable("A real-scene assertion failed; inspect scene receipt.")
            }
            NSApp.terminate(nil)
        } catch {
            check("scene-flow-completes-after-" + stage, false)
            try? writeReceipt(completed: false)
            fputs("Real-scene qualification failed at \(stage): \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }
    private func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    private var contexts: [LensWindowContext] {
        NSApp.windows.compactMap { LensApplicationCoordinator.shared.context(for: $0) }
            .filter { $0.window != nil && $0.store.isObserving }
    }
    private func wait(_ name: String, _ predicate: () -> Bool) async throws {
        stage = name; try writePhase()
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LensError.unavailable("Scene condition did not become available: " + name)
    }
    private func qualify() async throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.output.appendingPathComponent("native-design-v07-source-manifest.json"))) as? [String: Any]
        let files = manifest?["files"] as? [String: Any]
        check("real-production-window-wrapper-is-copied", manifest?["entrypoint"] as? String == "WorkspaceSceneV76Main.swift"
            && files?["Sources/CodexLens/LensWindowRoot.swift"] != nil && manifest?["copiedAppSourcesModified"] as? Bool == false)
        try await wait("first-production-scene-registered") { self.contexts.count == 1 }
        guard let parent = contexts.first, let parentWindow = parent.window else { throw LensError.unavailable("First scene missing") }
        check("initial-scene-is-bound-to-anonymous-source", parent.store.sourceHome.standardizedFileURL == fixture.home.standardizedFileURL)
        await parent.store.open(fixture.rootID); await parent.store.waitForPresentation()
        parent.store.showSessionPicker = false; parent.store.inspectorVisible = false; parent.store.chatVisible = false
        guard let event = parent.store.snapshot?.events.first(where: { $0.kind == .user }),
              let secondEvent = parent.store.snapshot?.events.first(where: { $0.kind == .assistant }) else {
            throw LensError.unavailable("Anonymous messages unavailable")
        }
        let target = Destination.event(event.id), other = Destination.event(secondEvent.id)
        parent.store.navigate(target); parent.store.timelineFocus = nil
        parent.store.timelineZoom = 19.6; parent.store.timelineOrigin = CGPoint(x: 1000, y: 0)
        parent.store.timelineReset &+= 1
        parent.store.navigate(target, newTab: true)
        try await wait("parent-toolbar-ready") { (parentWindow.toolbar?.items.count ?? 0) >= 3 }
        parentWindow.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000)
        let parentState = signature(parent.store)
        let parentToolbar = try toolbarID(parentWindow)
        check("parent-reader-retains-requested-timeline-place", parent.store.timelineZoom == 19.6 && parent.store.timelineOrigin == CGPoint(x: 1000, y: 0))
        check("source-window-registration-matches-displayed-root", LensApplicationCoordinator.shared.context(for: parentWindow) === parent
            && parent.store.snapshot?.root.id == fixture.rootID && parent.store.hasSessionReader)
        stage = "actual-swiftui-open-window"; try writePhase()
        let requested = LensApplicationCoordinator.shared.openInNewWindow(destination: target, from: parent.store)
        check("actual-scene-open-request-accepted", requested)
        try await wait("second-scene-selects-captured-message") {
            self.contexts.count == 2 && self.contexts.contains {
                $0 !== parent && $0.store.snapshot?.root.id == self.fixture.rootID && $0.store.tabContentDestination == target && !$0.store.busy
            }
        }
        guard let child = contexts.first(where: { $0 !== parent }), let childWindow = child.window else {
            throw LensError.unavailable("Second scene missing")
        }
        try await wait("second-toolbar-ready") { (childWindow.toolbar?.items.count ?? 0) >= 3 }
        childWindow.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000)
        let childToolbar = try toolbarID(childWindow)
        check("two-actual-window-scenes-survive-in-original-process", getpid() == initialPID && contexts.count == 2 && parentWindow !== childWindow)
        check("scene-toolbars-have-distinct-identifiers", parentToolbar != childToolbar)
        check("actual-toolbar-identifiers-match-registered-contexts", parentToolbar == parent.toolbarIdentifier && childToolbar == child.toolbarIdentifier)
        check("history-command-group-exists-in-both-scene-toolbars", [parentWindow, childWindow].allSatisfy {
            $0.toolbar?.items.contains { $0.itemIdentifier.rawValue.contains("navigationHistory") } == true
        })
        check("opening-child-preserves-parent-reader-and-workspace", signature(parent.store) == parentState)
        check("actual-child-opens-captured-target", child.store.tabContentDestination == target && child.store.hasSessionReader
            && child.store.observedSourceHome.standardizedFileURL == fixture.home.standardizedFileURL)
        check("actual-window-scenes-share-passive-reader-engine", parent.store.engine === child.store.engine)
        observations.append(windowRecord(parent, name: "parent-after-child-open"))
        observations.append(windowRecord(child, name: "child-after-open"))
        renders.append(try capture(parentWindow, name: "component-cache-real-scene-parent.png"))
        renders.append(try capture(childWindow, name: "component-cache-real-scene-child.png"))

        var childBusy: [Bool] = []
        let childObserver = child.store.$busy.sink { childBusy.append($0) }
        let parentBeforeReload = signature(parent.store)
        stage = "child-real-root-reload"; try writePhase()
        await child.store.open(fixture.rootID); await child.store.waitForPresentation()
        child.store.navigate(other, newTab: true)
        try await wait("child-reload-toolbar-idle") { !child.store.busy && childWindow.toolbar != nil }
        check("child-real-loading-transition-observed", childBusy.contains(true) && childBusy.last == false)
        check("child-reload-does-not-change-toolbar-family-id", try toolbarID(childWindow) == childToolbar)
        check("child-reload-preserves-other-scene-state", signature(parent.store) == parentBeforeReload && parentWindow.isVisible)
        check("child-loading-survives-in-same-process", getpid() == initialPID && contexts.count == 2)
        withExtendedLifetime(childObserver) {}

        var parentBusy: [Bool] = []
        let parentObserver = parent.store.$busy.sink { parentBusy.append($0) }
        let childBeforeParentLoad = signature(child.store)
        stage = "parent-reload-while-child-reader-stays"; try writePhase()
        await parent.store.open(fixture.rootID); await parent.store.waitForPresentation()
        try await wait("parent-reload-toolbar-idle") { !parent.store.busy && parentWindow.toolbar != nil }
        check("parent-real-loading-transition-observed", parentBusy.contains(true) && parentBusy.last == false)
        check("parent-reload-keeps-its-toolbar-id", try toolbarID(parentWindow) == parentToolbar)
        check("parent-reload-keeps-child-reader-and-state", signature(child.store) == childBeforeParentLoad && childWindow.isVisible)
        check("repeated-actual-window-toolbar-transitions-do-not-terminate-process", getpid() == initialPID && contexts.count == 2)
        withExtendedLifetime(parentObserver) {}
        observations.append(windowRecord(parent, name: "parent-after-reload"))
        observations.append(windowRecord(child, name: "child-after-parent-reload"))

        if let key = NSApp.keyWindow, let keyContext = LensApplicationCoordinator.shared.context(for: key) {
            check("real-key-window-command-context-resolves", contexts.contains { $0 === keyContext }
                && keyContext.store.canPerform(.openInNewWindow) && keyContext.store.canPerform(.conversation))
        } else { unqualified.append("No registered key document window was available; key-window menu routing was not qualified.") }
        check("fixture-inputs-are-unchanged", fixture.unchanged())
    }
    private func toolbarID(_ window: NSWindow) throws -> String {
        guard let identifier = window.toolbar?.identifier, !identifier.isEmpty else { throw LensError.unavailable("Toolbar identifier missing") }
        return identifier
    }
    private func signature(_ store: LensStore) -> [String] {
        [String(describing: store.selection), store.section.rawValue, store.query, String(describing: store.agentFilter),
         String(describing: store.kindFilter), String(describing: store.period), String(store.timelineZoom),
         NSStringFromPoint(store.timelineOrigin), String(describing: store.livePreview), String(store.workspacePresented)]
            + store.tabs.map { "\($0.id.uuidString)|\($0.destination)|\($0.pinned)" }
    }
    private func windowRecord(_ context: LensWindowContext, name: String) -> [String: Any] {
        ["scenario": name, "pid": Int(initialPID), "windowNumber": context.window?.windowNumber ?? -1,
         "windowScope": context.store.windowIdentity, "rootID": context.store.snapshot?.root.id ?? "none",
         "selection": String(describing: context.store.selection), "busy": context.store.busy,
         "toolbarID": context.window?.toolbar?.identifier ?? "none",
         "toolbarItems": context.window?.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []]
    }
    private func capture(_ window: NSWindow, name: String) throws -> String {
        guard let view = window.contentView else { throw LensError.unavailable("Scene content missing") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try bytes.write(to: fixture.output.appendingPathComponent(name)); return name
    }
    private func writePhase() throws {
        try JSONSerialization.data(withJSONObject: ["stage": stage, "pid": Int(initialPID), "registeredScenes": contexts.map { windowRecord($0, name: "current") }],
            options: [.prettyPrinted, .sortedKeys]).write(to: fixture.output.appendingPathComponent("scene-phase.json"), options: .atomic)
    }
    private func writeReceipt(completed: Bool) throws {
        let value: [String: Any] = ["checks": checks, "observations": observations, "renders": renders,
            "completed": completed, "stage": stage, "pid": Int(initialPID),
            "allExecutedChecksPassed": completed && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual production LensWindowRoot and LensCommands in two SwiftUI WindowGroup UUID scenes, real openWindow environment/coordinator handler, own registered AppKit toolbar identities and root reloads on anonymous histories.",
            "unqualified": unqualified]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.output.appendingPathComponent("native-design-v07-receipt.json"), options: .atomic)
    }
}

private final class WorkspaceSceneFixtureV76 {
    let home: URL, output: URL, rootID: String
    private var hashes: [URL: String] = [:]
    init() throws {
        func argument(_ name: String) throws -> URL {
            guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw LensError.unavailable("Missing " + name) }
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        let corpus = try argument("--corpus"); output = try argument("--output")
        let root = corpus.resolvingSymlinksInPath().path
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard root.hasPrefix(temporary), output.resolvingSymlinksInPath().path.hasPrefix(temporary),
              FileManager.default.fileExists(atPath: corpus.appendingPathComponent("ANONYMOUS_FIXTURE").path),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any],
              manifest["anonymous"] as? Bool == true, let id = manifest["rootID"] as? String, let path = manifest["home"] as? String,
              let rollouts = manifest["rollouts"] as? [String: [String: Any]] else { throw LensError.unavailable("Anonymous scene corpus required") }
        rootID = id; home = URL(fileURLWithPath: path)
        guard home.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
        for record in rollouts.values {
            guard let path = record["path"] as? String else { throw CocoaError(.fileReadUnknown) }
            let file = URL(fileURLWithPath: path)
            guard file.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            hashes[file] = Self.digest(try Data(contentsOf: file))
        }
        for path in (manifest["worktrees"] as? [String: String] ?? [:]).values {
            let directory = URL(fileURLWithPath: path)
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            let file = directory.appendingPathComponent("src/Same.swift")
            if FileManager.default.fileExists(atPath: file.path) {
                guard file.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
                hashes[file] = Self.digest(try Data(contentsOf: file))
            }
        }
    }
    func unchanged() -> Bool { hashes.allSatisfy { url, hash in (try? Data(contentsOf: url)).map { Self.digest($0) == hash } ?? false } }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
