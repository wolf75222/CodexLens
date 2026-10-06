import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import LensCore
import SwiftUI

/// Disposable source-matched store/picker checks. No production session, Codex
/// process, account lookup, inference or physical desktop input is used.
@main struct SessionCatalogPickerMain {
    private static let rootA = "aaaaaaaa-1111-4111-8111-111111111111"
    private static let rootB = "bbbbbbbb-2222-4222-8222-222222222222"
    private static let missingRoot = "cccccccc-3333-4333-8333-333333333333"
    @MainActor private static var stage = "setup"

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // A broken native tracking loop or model continuation must fail this
        // owned process rather than hang CI. This is an execution bound, not a
        // speed requirement or a claimed performance result.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("Session catalogue/picker fixture exceeded its execution bound.\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            do { try await qualify(); NSApp.terminate(nil) }
            catch { fputs("Session catalogue/picker qualification: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argumentURL("--output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let mode = argument("--scenario") ?? "full"
        guard ["full", "cli-valid", "cli-missing"].contains(mode) else { throw LensError.unavailable("Unknown scenario") }
        let manifestURL = output.appendingPathComponent("native-design-v07-source-manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        guard manifest?["entrypoint"] as? String == "SessionCatalogPickerMain.swift",
              manifest?["productionEntryPointReplaced"] as? Bool == true,
              manifest?["copiedAppSourcesModified"] as? Bool == false else {
            throw LensError.unavailable("This entrypoint requires the source-matched native wrapper manifest.")
        }
        // Match verify-design-v07.sh's disposable identity using the exact
        // argument spelling. Canonicalizing /tmp vs /private/tmp here would
        // change the hash while the wrapper's Python code hashes the raw path.
        let outputSpelling = try require(argument("--output"), "output argument")
        let outputHash = SHA256.hash(data: Data(outputSpelling.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let expectedBundleID = "fr.codexlens.designprobe.v07." + outputHash.prefix(12)
        guard Bundle.main.bundleIdentifier == expectedBundleID,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "NativeDesignV07Probe" else {
            throw LensError.unavailable("Refusing to use a production preferences domain.")
        }
        if mode == "full", argument("--session") != nil {
            throw LensError.unavailable("The full suite requires no --session. Use the explicit cli-valid/cli-missing mode.")
        }

        var checks: [[String: Any]] = [], observations: [[String: Any]] = [], renders: [[String: Any]] = []
        var stores: [LensStore] = [], pools: [SessionReaderPool] = []
        var completed = false
        defer {
            stores.forEach { $0.stopObserving() }
            if !completed {
                checks.append(["name": "flow-completes-after-" + stage, "passed": false])
                let partial: [String: Any] = ["checks": checks, "observations": observations, "renders": renders,
                    "completed": false, "allExecutedChecksPassed": false, "failedStage": stage, "scenario": mode,
                    "scope": "Interrupted source-matched disposable catalogue/picker checks.",
                    "unqualified": ["An interrupted flow is not a passing qualification. No compositor or physical input was tested."]]
                try? writeReceipt(partial, output: output)
            }
        }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func mark(_ value: String) {
            stage = value
            try? JSONSerialization.data(withJSONObject: ["stage": value, "scenario": mode], options: [.sortedKeys])
                .write(to: output.appendingPathComponent("phase.json"))
        }
        let fixture = try PickerFixture(directory: output.appendingPathComponent("isolated-fixture"),
                                        rootA: rootA, rootB: rootB, largeEventCount: 24_000)
        let preferencesName = "fr.codexlens.picker-fixture." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: preferencesName) else { throw LensError.unavailable("No fixture preferences") }
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let reading = LensReadingPreferences(defaults: preferences)

        func configureDefaults(root: String? = nil, scope: String) {
            // LensStore writes only this wrapper's private bundle domain; this
            // process-local overlay also prevents old wrapper state being read.
            var values: [String: Any] = [
                "lensLanguage": "en", "lensControlAccent": "lens", "lensReduceMotionOverride": true,
                "lensBookmarks": Data(), "lensTabsByRoot": [String: Data](),
                "lensChatByRoot": [String: String](), "LensCodexModel": "",
                "LensCodexExecutablePath": "", "LensGroupCodexInvestigations": false,
                "lensRootByWindow": root.map { [scope: $0] } ?? [String: String]()
            ]
            values["lensTabMaterial"] = "system"
            UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            LensL10n.language = .en
        }
        func makeStore(_ label: String, scope: String, restored: String? = nil) -> (LensStore, SessionReaderPool) {
            configureDefaults(root: restored, scope: scope)
            let base = output.appendingPathComponent(label)
            let pool = SessionReaderPool(investigationRegistryDirectory: base.appendingPathComponent("registry"))
            let store = LensStore(sourceHome: fixture.home,
                investigationArchive: InvestigationArchive(directory: base.appendingPathComponent("archive")),
                cacheDirectory: base.appendingPathComponent("cache"), readerPool: pool, readingPreferences: reading)
            store.setNavigationScope(scope)
            store.investigation.automaticCodexCheckEnabled = false
            stores.append(store); pools.append(pool)
            return (store, pool)
        }
        func finish(_ store: LensStore, _ pool: SessionReaderPool) async {
            store.stopObserving(); await store.investigation.flushAndStop(); await pool.quiesce()
        }
        check("source-matched-entrypoint-and-private-preferences", true)

        if mode != "full" {
            mark(mode)
            let expected = mode == "cli-valid" ? rootA : missingRoot
            guard argument("--session") == expected else {
                throw LensError.unavailable(mode + " requires --session " + expected)
            }
            let (store, pool) = makeStore(mode, scope: UUID().uuidString)
            var observedBusy = false, pickerHidden = false
            let subscription = store.$busy.dropFirst().filter { $0 }.prefix(1).sink { _ in
                observedBusy = true; pickerHidden = !store.showSessionPicker
            }
            await store.start(); subscription.cancel()
            check(mode + "-automatic-reading-hides-picker", observedBusy && pickerHidden)
            if mode == "cli-valid" {
                check("command-line-restoration-opens-exact-root", store.snapshot?.root.id == rootA && store.hasSessionReader && !store.showSessionPicker)
                let home = await store.engine.home
                check("command-line-reader-bound-to-fixture-home", sameHome(home, fixture.home))
            } else {
                check("failed-command-line-restoration-reopens-picker", store.snapshot == nil && !store.busy && store.showSessionPicker && store.error != nil)
            }
            await finish(store, pool)
        } else {
            mark("fresh-start")
            let (fresh, freshPool) = makeStore("fresh", scope: UUID().uuidString)
            check("fresh-store-starts-with-picker-and-no-reader", fresh.showSessionPicker && fresh.snapshot == nil && !fresh.hasSessionReader)
            await fresh.start()
            check("fresh-start-publishes-fixture-catalogue-with-picker", Set(fresh.catalog.map(\.id)) == Set([rootA, rootB])
                && fresh.showSessionPicker && !fresh.catalogLoading && fresh.snapshot == nil && !fresh.hasSessionReader)
            renders.append(try await renderPicker(fresh, name: "picker-fresh-catalogue", output: output))
            await finish(fresh, freshPool)

            mark("persisted-restoration")
            let (restored, restoredPool) = makeStore("restored", scope: UUID().uuidString, restored: rootA)
            var restorationBusy = false, restorationHidden = false
            let restorationSubscription = restored.$busy.dropFirst().filter { $0 }.prefix(1).sink { _ in
                restorationBusy = true; restorationHidden = !restored.showSessionPicker
            }
            await restored.start(); restorationSubscription.cancel(); await restored.waitForPresentation()
            check("persisted-restoration-hides-picker-during-reading", restorationBusy && restorationHidden)
            check("persisted-restoration-opens-exact-root", restored.snapshot?.root.id == rootA && restored.hasSessionReader && !restored.showSessionPicker && !restored.busy)
            let restoredHome = await restored.engine.home
            check("persisted-restoration-keeps-correct-reader-and-source", sameHome(restoredHome, fixture.home) && sameHome(restored.observedSourceHome, fixture.home))
            await finish(restored, restoredPool)

            mark("failed-restoration")
            let (failed, failedPool) = makeStore("failed", scope: UUID().uuidString, restored: missingRoot)
            await failed.start()
            check("failed-restoration-reopens-picker-with-specific-error", failed.snapshot == nil && !failed.hasSessionReader
                && failed.showSessionPicker && !failed.busy && failed.error?.contains(missingRoot) == true)
            renders.append(try await renderPicker(failed, name: "picker-failed-restoration", output: output))
            await finish(failed, failedPool)

            mark("explicit-choice-during-start-catalogue")
            let (startup, startupPool) = makeStore("startup-choice", scope: UUID().uuidString, restored: rootA)
            var startupAction: Task<Void, Never>?, actionDuringCatalogue = false
            let startupSubscription = startup.$catalogLoading.dropFirst().filter { $0 }.prefix(1).sink { _ in
                // A next-turn action avoids a reentrant @Published willSet
                // mutation, and runs while start awaits the catalogue actor.
                startupAction = Task { @MainActor in
                    actionDuringCatalogue = startup.catalogLoading
                    startup.perform(.openSession)
                }
            }
            await startup.start(); if let startupAction { await startupAction.value }; startupSubscription.cancel()
            check("explicit-open-command-reached-catalogue-wait", actionDuringCatalogue)
            check("explicit-choice-during-start-suppresses-persisted-restoration", startup.snapshot == nil && startup.showSessionPicker && !startup.busy && !startup.hasSessionReader)
            await finish(startup, startupPool)

            mark("cancel-and-supersede-opening")
            let scope = UUID().uuidString
            let (switching, switchingPool) = makeStore("switching", scope: scope)
            await switching.start(); await switching.open(rootA); await switching.waitForPresentation()
            guard let oldEvent = switching.events.first else { throw LensError.unavailable("Missing A event") }
            let selected = Destination.event(oldEvent.id)
            switching.navigate(selected, newTab: true)
            let oldTabs = switching.tabs.map(\.id)
            let oldHome = switching.observedSourceHome
            let sharedLease = try await switchingPool.acquire(home: fixture.home,
                cacheDirectory: output.appendingPathComponent("switching/cache"), rootID: rootB)
            var sharedFinished = false
            let sharedRead = Task { @MainActor in
                defer { sharedFinished = true }
                return try await sharedLease.reader.load()
            }
            var cancelAction: Task<Void, Never>?, openingObserved = false, oldBindingDuringOpening = false, oldBindingAfterCancel = false
            let openingSubscription = switching.$busy.dropFirst().filter { $0 }.prefix(1).sink { _ in
                cancelAction = Task { @MainActor in
                    openingObserved = switching.busy && !sharedFinished
                    oldBindingDuringOpening = switching.snapshot?.root.id == rootA && switching.selection == selected
                        && switching.tabs.map(\.id) == oldTabs && sameHome(switching.observedSourceHome, oldHome)
                    switching.perform(.openSession)
                    oldBindingAfterCancel = !switching.busy && switching.showSessionPicker
                        && switching.snapshot?.root.id == rootA && switching.selection == selected
                        && switching.tabs.map(\.id) == oldTabs && switching.error == nil
                }
            }
            let pendingOpen = Task { @MainActor in await switching.open(rootB) }
            await pendingOpen.value; if let cancelAction { await cancelAction.value }; openingSubscription.cancel()
            let sharedPublication = try await sharedRead.value; await sharedLease.release()
            check("anonymous-heavy-read-window-was-observed", openingObserved)
            check("old-root-selection-and-tabs-remain-bound-during-opening", oldBindingDuringOpening)
            check("open-command-cancels-opening-and-presents-picker", oldBindingAfterCancel)
            check("retiring-read-cannot-replace-old-root-or-selection", switching.snapshot?.root.id == rootA && switching.selection == selected && switching.tabs.map(\.id) == oldTabs)
            check("cancelling-window-does-not-consume-other-reader-publication", sharedPublication.snapshot.root.id == rootB)
            let boundHome = await switching.engine.home
            check("cancelled-opening-keeps-selected-reader", sameHome(boundHome, fixture.home) && switching.hasSessionReader)
            await switching.open(rootB)
            check("new-explicit-success-supersedes-old-root-and-picker", switching.snapshot?.root.id == rootB && !switching.busy
                && !switching.showSessionPicker && switching.selection == nil && switching.tabs.isEmpty)
            observations.append(["scenario": "cancellation", "observedPendingRead": openingObserved,
                "oldRoot": rootA, "newRoot": rootB, "oldSelection": String(describing: selected),
                "sharedReaderCompleted": sharedPublication.snapshot.root.id == rootB])
            await finish(switching, switchingPool)

            mark("ordinary-native-picker-primary")
            let (picker, pickerPool) = makeStore("native-picker", scope: UUID().uuidString)
            await picker.start()
            let mounted = mountPicker(picker)
            defer { mounted.window.contentView = nil; mounted.window.close() }
            try await settle(mounted.host)
            let search = try require(descendants(mounted.host).compactMap { $0 as? NSSearchField }.first, "native search")
            setSearch(search, text: "codex://threads/" + rootA)
            try await settle(mounted.host)
            let primary = try require(descendants(mounted.host).compactMap { $0 as? LensAccentPrimaryButton }.first, "native primary")
            check("ordinary-picker-query-enables-primary", primary.isEnabled)
            check("ordinary-picker-primary-accessible-press-dispatched", primary.accessibilityPerformPress())
            try await waitUntil("native-primary-opens") { picker.snapshot?.root.id == rootA && !picker.busy }
            check("ordinary-picker-primary-opens-exact-root", picker.snapshot?.root.id == rootA && !picker.showSessionPicker)
            picker.perform(.openSession)
            check("ordinary-open-action-retains-current-root-until-success", picker.showSessionPicker && picker.snapshot?.root.id == rootA && !picker.busy)

            observations.append(["scenario": "picker-double-click-gesture", "qualified": false,
                "reason": "The prior probe-2 prohibited/offscreen NSEvent sequence did not dispatch the SwiftUI gesture. It does not establish a production double-click defect. Physical/active-window input is a separate qualification."])
            mark("ordinary-explicit-open-API")
            // Keep the exact-root/success contract required by this changed
            // store path. Calling the public API is deliberately not counted
            // as a double-click or context-menu gesture.
            await picker.open(rootB)
            check("ordinary-explicit-open-API-replaces-root-on-success", picker.snapshot?.root.id == rootB
                && !picker.busy && !picker.showSessionPicker)
            await finish(picker, pickerPool)
        }

        mark("source-integrity-and-receipt")
        check("fixture-journals-remain-byte-identical", try fixture.unchanged())
        for pool in pools { await pool.quiesce() }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let receipt: [String: Any] = ["checks": checks, "observations": observations, "renders": renders,
            "completed": true, "failedStage": passed ? "none" : stage, "scenario": mode, "allExecutedChecksPassed": passed,
            "fixture": ["anonymous": true, "largeEvents": fixture.largeEventCount, "sourcesUnchanged": try fixture.unchanged()],
            "scope": "Source-matched LensStore startup/restoration/cancellation and owned offscreen native picker callbacks; isolated sources/cache/archive/registry/preferences. No Codex/account/network action.",
            "unqualified": ["PNG files are NSHostingView cache renders, not compositor screenshots.",
                "Double-click/context-menu gesture dispatch, physical mouse/trackpad and VoiceOver are unqualified; the failed probe-2 synthetic gesture attempt is retained separately.",
                "The full mode does not test --session; cli-valid and cli-missing are separate explicitly requested invocations.",
                "No performance/RAM improvement is asserted from a bounded completion timeout."]]
        try writeReceipt(receipt, output: output); completed = true
        guard passed else { throw LensError.unavailable("One or more catalogue/picker assertions failed; inspect receipt.") }
    }

    private static func argument(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return CommandLine.arguments[i + 1]
    }
    private static func argumentURL(_ name: String) throws -> URL {
        guard let value = argument(name), value.hasPrefix("/") else { throw LensError.unavailable("Missing absolute " + name) }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
    private static func sameHome(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + label) }; return value
    }
    private static func writeReceipt(_ value: [String: Any], output: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    @MainActor private static func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        stage = label
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw LensError.unavailable("Bounded fixture did not reach " + label) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func setSearch(_ field: NSSearchField, text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    @MainActor private static func mountPicker(_ store: LensStore) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let size = NSSize(width: 740, height: 560)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -12_000, y: -12_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        let view = AnyView(SessionPickerView().environmentObject(store).background(Color(nsColor: .windowBackgroundColor)))
        let host = NSHostingView(rootView: view); host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        return (window, host)
    }
    @MainActor private static func settle(_ host: NSView) async throws {
        for _ in 0..<10 { await Task.yield(); host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor private static func renderPicker(_ store: LensStore, name: String, output: URL) async throws -> [String: Any] {
        let mounted = mountPicker(store); defer { mounted.window.contentView = nil; mounted.window.close() }
        try await settle(mounted.host)
        guard let image = mounted.host.bitmapImageRepForCachingDisplay(in: mounted.host.bounds) else { throw LensError.unavailable("No offscreen bitmap") }
        mounted.host.cacheDisplay(in: mounted.host.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No offscreen PNG") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        return ["file": name + ".png", "width": 740, "height": 560,
                "method": "Owned offscreen NSHostingView bitmap-cache render; not a compositor screenshot"]
    }
}

private struct PickerFixture {
    let home: URL
    let largeEventCount: Int
    private let originals: [URL: String]
    init(directory: URL, rootA: String, rootB: String, largeEventCount: Int) throws {
        home = directory.appendingPathComponent("codex-home"); self.largeEventCount = largeEventCount
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var digests: [URL: String] = [:]
        for (id, count) in [(rootA, 2), (rootB, largeEventCount)] {
            let url = sessions.appendingPathComponent("rollout-" + id + ".jsonl")
            var data = Data()
            func append(_ record: [String: Any]) throws { data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10) }
            try append(["timestamp": "2026-10-05T10:00:00Z", "type": "session_meta",
                "payload": ["id": id, "cwd": directory.path, "cli_version": "0.159.2"]])
            for index in 0..<count {
                try append(["timestamp": "2026-10-05T10:00:01Z", "type": "event_msg",
                    "payload": ["type": index == 0 ? "user_message" : "agent_message",
                                "message": "Disposable fixture \(id) item \(index). " + String(repeating: "local ", count: 32)]])
            }
            try data.write(to: url); digests[url] = Self.digest(data)
        }
        originals = digests
    }
    func unchanged() throws -> Bool { try originals.allSatisfy { try Self.digest(Data(contentsOf: $0.key)) == $0.value } }
    private static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
}
