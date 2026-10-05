import Foundation
import SwiftUI
import AppKit
import Combine
import CryptoKit
import QuartzCore
import LensCore

/// Source-matched native qualification. Only the private anonymous copy is appended.
@main struct LiveV41Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Direct qualification: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output"), corpus = try argument("--corpus")
        let fixture = try Fixture(corpus: corpus, output: output)
        LensL10n.language = .fr
        UserDefaults.standard.set("lens", forKey: "lensControlAccent")
        var checks: [[String: Any]] = [], renders: [String] = [], timings: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
        let instant = Date()
        try fixture.append(owner: fixture.rootID, records: fixture.initialRecords(at: instant.addingTimeInterval(-10)))
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: SessionReaderPool())
        store.setNavigationScope(UUID().uuidString)
        await store.start(); await store.open(fixture.rootID); await store.waitForPresentation()
        defer { store.stopObserving() }
        store.showSessionPicker = false; store.chatVisible = false; store.inspectorVisible = false
        guard let firstCall = store.snapshot?.events.first(where: { $0.callID == "v41-initial-shell" && $0.kind == .toolCall }),
              let patch = store.snapshot?.events.first(where: { $0.callID == "v41-initial-patch" && $0.kind == .toolCall }),
              let change = store.snapshot?.changes.first(where: { $0.eventID == patch.id && $0.kind == .requestedPatch }) else {
            throw LensError.unavailable("Initial anonymous Direct fixture was not indexed.")
        }
        let historicCall = store.snapshot?.events.first { $0.kind == .toolCall && $0.id != firstCall.id } ?? firstCall
        store.navigate(.event(historicCall.id)); store.agentFilter = fixture.rootID
        await store.waitForPresentation()
        let mainSelection = store.selection, existingTab = store.activeTab
        let historicWindow = store.timelineWindow, historicOrigin = store.timelineOrigin
        store.enableLiveTimeline(at: instant)
        check("enable-direct-keeps-main-selection-tabs-and-agent-filter", store.liveTimelineVisible && store.liveState.following && store.selection == mainSelection && store.activeTab == existingTab && store.agentFilter == fixture.rootID)
        check("enable-direct-keeps-history-window-and-scroll", store.timelineWindow == historicWindow && store.timelineOrigin == historicOrigin)
        check("direct-axis-ends-at-explicit-instant", store.liveState.window?.end == instant)
        store.previewLiveEvent(firstCall.id)
        check("event-preview-keeps-direct-and-main-context", store.livePreview == .event(firstCall.id) && store.liveTimelineVisible && store.liveState.following && store.selection == .event(firstCall.id) && store.agentFilter == fixture.rootID)
        store.previewLiveChange(change.id)
        check("diff-preview-retains-recorded-change-id-and-environment", store.livePreview == .change(change.id) && store.change(change.id)?.environmentID == change.environmentID)
        let beforeTabs = store.tabs.count
        store.openLivePreviewInTab()
        check("promote-preview-opens-one-tab-and-keeps-direct", store.tabs.count == beforeTabs + 1 && store.tabs.last?.destination == .change(change.id) && store.liveTimelineVisible && store.liveState.following && store.livePreview == nil)
        let promotedCount = store.tabs.count
        store.previewLiveChange(change.id); store.openLivePreviewInTab()
        check("promoting-existing-preview-does-not-duplicate-tab", store.tabs.count == promotedCount)
        store.closeLivePreview()
        check("close-preview-keeps-live-axis", store.livePreview == nil && store.liveTimelineVisible && store.liveState.following)
        store.previewLiveEvent("absent-event-id"); store.previewLiveChange("absent-change-id")
        check("unknown-target-does-not-create-preview", store.livePreview == nil)

        // The representable has no automatic clock. Time injection is deterministic.
        await store.waitForPresentation()
        let timelineHost = NSHostingView(rootView: TimelineView(store: store, live: true))
        timelineHost.sizingOptions = []; timelineHost.frame = NSRect(x: 0, y: 0, width: 1120, height: 280)
        let timelineWindow = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1120, height: 280), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        timelineWindow.isReleasedWhenClosed = false; timelineWindow.contentView = timelineHost; timelineWindow.orderBack(nil)
        defer { timelineWindow.contentView = nil; timelineWindow.close() }
        await settle(timelineHost)
        guard let canvas = descendants(timelineHost).compactMap({ $0 as? TimelineCanvas }).first else { throw CocoaError(.fileReadUnknown) }
        check("native-direct-axis-matches-live-window", canvas.geometry?.window == store.liveState.window)
        var storePublications = 0, projectionPublications = 0
        let storeObserver = store.objectWillChange.sink { storePublications += 1 }
        let projectionObserver = store.$timelineProjection.dropFirst().sink { _ in projectionPublications += 1 }
        let fingerprint = store.timelineProjection?.fingerprintSHA256
        let start = ContinuousClock.now
        for i in 1...1000 { store.advanceLiveTimeline(at: instant.addingTimeInterval(Double(i) / 100)) }
        let elapsed = start.duration(to: .now).components
        timings.append(["scenario": "1000-injected-clock-ticks", "milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            "method": "Synchronous viewing-clock updates on MainActor; excludes collection, layout and compositor frames."])
        await settle(timelineHost)
        check("clock-and-native-layout-do-not-publish-entire-store-or-rebuild-projection", storePublications == 0 && projectionPublications == 0 && store.timelineProjection?.fingerprintSHA256 == fingerprint)
        storeObserver.cancel(); projectionObserver.cancel()
        check("native-axis-updates-with-separate-clock", canvas.geometry?.window == store.liveState.window && store.liveState.window?.end == instant.addingTimeInterval(10))
        var snapshotPublications = 0
        let snapshotObserver = store.$snapshot.dropFirst().sink { _ in snapshotPublications += 1 }
        store.pauseLiveTimeline(); store.resumeLiveTimeline(at: instant.addingTimeInterval(10))
        check("resume-without-arrivals-does-not-rebuild-session", snapshotPublications == 0)
        snapshotObserver.cancel()
        try await capture(timelineHost, dark: false, path: output.appendingPathComponent("direct-axis-light.png")); renders.append("direct-axis-light.png")
        try await capture(timelineHost, dark: true, path: output.appendingPathComponent("direct-axis-dark.png")); renders.append("direct-axis-dark.png")
        let keyboardWindow = store.liveState.window
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: timelineWindow.windowNumber, context: nil,
            characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124) {
            canvas.keyDown(with: event)
            check("keyboard-event-selection-keeps-direct-window", store.liveTimelineVisible && store.liveState.window == keyboardWindow && store.livePreview != nil)
        } else { check("keyboard-event-selection-keeps-direct-window", false) }
        let liveBeforeZoom = store.liveState.window, selectionBeforeZoom = store.selection
        canvas.adjustTimelineZoom(.increase); await settle(timelineHost)
        check("live-zoom-pauses-and-keeps-selection-and-historic-viewport", !store.follow && !store.liveState.following && (store.liveState.window?.duration ?? .infinity) < (liveBeforeZoom?.duration ?? 0) && store.selection == selectionBeforeZoom && store.timelineWindow == historicWindow && store.timelineOrigin == historicOrigin)
        canvas.adjustTimelineZoom(.reset); await settle(timelineHost)
        check("reset-live-zoom-resumes-default-window", store.follow && store.liveState.following && store.liveState.span == TimelineLiveState.defaultSpan)
        store.resumeLiveTimeline(at: instant.addingTimeInterval(10)); await settle(timelineHost)
        store.previewLiveChange(change.id)
        let previewBeforePause = store.livePreview, selectionBeforePause = store.selection
        store.pauseLiveTimeline()
        let frozenWindow = store.liveState.window, frozenIDs = store.snapshot?.events.map(\.id) ?? []
        check("pause-separates-collection-from-visible-follow", !store.liveState.following && !store.follow && store.liveTimelineVisible)
        store.advanceLiveTimeline(at: instant.addingTimeInterval(120))
        check("paused-axis-and-preview-stay-fixed", store.liveState.window == frozenWindow && store.livePreview == previewBeforePause && store.selection == selectionBeforePause)

        // A late descendant is recorded in a separate journal. No source tool runs.
        let lateChild = "66666666-6666-4666-8666-666666666666"
        try fixture.writeLateChild(id: lateChild, at: Date())
        try fixture.append(owner: fixture.rootID, records: fixture.liveRecords(at: Date().addingTimeInterval(0.4)))
        let pausedArrival = try await waitUntil { store.waitingEvents >= 3 }
        check("paused-collection-counts-new-records", pausedArrival && store.waitingEvents >= 3)
        check("paused-snapshot-selection-preview-and-axis-do-not-jump", store.snapshot?.events.map(\.id) == frozenIDs && store.selection == selectionBeforePause && store.livePreview == previewBeforePause && store.liveState.window == frozenWindow)
        let incomplete = try fixture.record(at: Date(), kind: "response_item", payload: ["type": "message", "id": "v41-partial", "role": "assistant", "content": [["type": "output_text", "text": "Completed only after a second append."]]])
        let split = incomplete.count / 2
        try fixture.appendBytes(owner: fixture.rootID, bytes: incomplete.prefix(split))
        let waitingBeforePartial = store.waitingEvents
        try await Task.sleep(for: .milliseconds(2300))
        check("unterminated-json-does-not-create-an-event", store.waitingEvents == waitingBeforePartial && store.event("v41-partial") == nil)
        try fixture.appendBytes(owner: fixture.rootID, bytes: incomplete.suffix(incomplete.count - split) + Data([10]))
        check("completed-partial-line-is-collected", try await waitUntil { store.waitingEvents > waitingBeforePartial })
        store.resumeLiveTimeline(at: instant.addingTimeInterval(30)); await store.waitForPresentation(); await settle(timelineHost)
        let resumed = store.snapshot?.events ?? []
        check("resume-publishes-all-arrivals-once", store.follow && store.liveState.following && store.waitingEvents == 0 && Set(resumed.map(\.id)).count == resumed.count && resumed.count > frozenIDs.count)
        check("late-descendant-retains-separate-parent-identity", store.snapshot?.agents.contains { $0.id == lateChild && $0.parentID == fixture.rootID && $0.relation == .subagent } == true && resumed.contains { $0.agentID == lateChild && $0.callID == "v41-child-shell" })
        check("live-call-without-output-keeps-missing-result", resumed.first { $0.callID == "v41-missing-output" && $0.kind == .toolCall }?.relatedEventID == nil && resumed.contains { $0.callID == "v41-missing-output" && $0.kind == .toolCall })
        check("resume-retains-preview-selection-and-filter", store.livePreview == previewBeforePause && store.selection == selectionBeforePause && store.agentFilter == fixture.rootID)
        check("completed-partial-record-is-present-once", resumed.filter { $0.preview.contains("Completed only after a second append.") }.count == 1)
        check("diff-preview-stays-in-correct-worktree", store.snapshot?.environments.first { $0.id == change.environmentID }.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == fixture.beta.resolvingSymlinksInPath() } == true && change.path.contains("Same.swift"))
        check("recorded-shell-and-patch-were-never-executed", !FileManager.default.fileExists(atPath: fixture.sentinel.path) && fixture.sourcesUnchanged())
        check("append-preserves-original-journal-prefix", fixture.appendedPrefixesUnchanged())

        // Render the existing main workspace with its real native split and diff preview.
        store.resetFilters(); await store.waitForPresentation()
        store.previewLiveChange(change.id); store.resumeLiveTimeline(at: Date())
        let context = LensWindowContext(store: store)
        let workspace = NSHostingView(rootView: MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, .light))
        workspace.sizingOptions = []; workspace.frame = NSRect(x: 0, y: 0, width: 1440, height: 960)
        let workspaceWindow = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 960), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        workspaceWindow.isReleasedWhenClosed = false; workspaceWindow.contentView = workspace; workspaceWindow.orderBack(nil)
        await settle(workspace)
        let runningEnd = store.liveState.window?.end
        try await Task.sleep(for: .milliseconds(1250)); await settle(workspace)
        check("mounted-workspace-clock-advances-without-new-records", runningEnd.map { (store.liveState.window?.end ?? .distantPast) > $0 } == true)
        for dark in [false, true] {
            workspace.rootView = MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, dark ? .dark : .light)
            await settle(workspace)
            let name = dark ? "direct-workspace-dark.png" : "direct-workspace-light.png"
            try await capture(workspace, dark: dark, path: output.appendingPathComponent(name)); renders.append(name)
        }
        workspace.rootView = MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, .light)
        workspace.frame.size = NSSize(width: 1000, height: 780); workspaceWindow.setContentSize(workspace.frame.size)
        await settle(workspace)
        try await capture(workspace, dark: false, path: output.appendingPathComponent("direct-workspace-narrow.png")); renders.append("direct-workspace-narrow.png")
        check("resize-keeps-direct-preview-and-shared-selection", store.liveTimelineVisible && store.livePreview == .change(change.id) && store.selection == .change(change.id))
        workspaceWindow.contentView = nil; workspaceWindow.close()
        store.pauseLiveTimeline(); let endAfterUnmount = store.liveState.window
        try await Task.sleep(for: .milliseconds(1250))
        check("unmounted-paused-clock-does-not-update", store.liveState.window == endAfterUnmount && !store.liveState.following)
        let switchInstant = Date()
        await store.open(fixture.otherRootID); await store.waitForPresentation()
        check("change-session-clears-old-preview-and-reanchors-direct", store.snapshot?.root.id == fixture.otherRootID && store.livePreview == nil && store.liveState.following && store.liveState.window.map { $0.end >= switchInstant } == true && store.snapshot?.events.contains { $0.callID == "v41-initial-patch" } == false)
        store.stopObserving(); let stoppedState = store.liveState, stoppedSnapshot = store.snapshot?.root.id
        store.enableLiveTimeline(at: Date()); store.advanceLiveTimeline(at: Date().addingTimeInterval(90))
        try await Task.sleep(for: .milliseconds(2200))
        check("closed-store-rejects-late-ticks-and-activation", store.liveState == stoppedState && store.snapshot?.root.id == stoppedSnapshot)
        check("all-original-sources-remain-unchanged-after-close", fixture.sourcesUnchanged())
        await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "renders": renders, "timings": timings,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Native source-matched Direct model/store/timeline/main workspace, anonymous copied journals, polling and local keyboard NSEvent, no observed Codex process, network denied by OS launcher.",
            "fixture": ["originalCorpus": corpus.path, "privateHome": fixture.home.path, "rootID": fixture.rootID, "appendedSourceOnly": true, "worktreesModified": false],
            "unqualified": ["Production compositor, physical gestures and VoiceOver require interactive inspection. PNG files are native offscreen component renders.", "No App Server attached to an active user session and no hooks installed.", "No latency or FPS guarantee is inferred from one injected clock timing sample."]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    private static func argument(_ name: String) throws -> URL {
        guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { throw CocoaError(.fileNoSuchFile) }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }
    @MainActor private static func waitUntil(_ predicate: () -> Bool) async throws -> Bool {
        for _ in 0..<80 { if predicate() { return true }; try await Task.sleep(for: .milliseconds(100)) }
        return predicate()
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func settle(_ view: NSView) async {
        for _ in 0..<15 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.window?.displayIfNeeded(); CATransaction.flush() }
    }
    @MainActor private static func capture(_ view: NSView, dark: Bool, path: URL) async throws {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); view.window?.appearance = view.appearance; await settle(view)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: path)
    }
}

private final class Fixture {
    let home: URL, rootID: String, otherRootID: String, alpha: URL, beta: URL, sentinel: URL
    private var paths: [String: URL] = [:], originalHashes: [URL: String] = [:], initialPrefixes: [URL: Data] = [:]
    init(corpus: URL, output: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any]
        guard json?["anonymous"] as? Bool == true, let root = json?["rootID"] as? String, let other = json?["otherRootID"] as? String,
              let originals = json?["rollouts"] as? [String: [String: Any]], let worktrees = json?["worktrees"] as? [String: String] else { throw CocoaError(.fileReadUnknown) }
        rootID = root; otherRootID = other; home = output.appendingPathComponent("anonymous-live-home")
        alpha = URL(fileURLWithPath: worktrees["alpha"] ?? ""); beta = URL(fileURLWithPath: worktrees["beta"] ?? "")
        sentinel = output.appendingPathComponent("command-must-not-run")
        guard corpus.path.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: home.path),
              alpha.resolvingSymlinksInPath().path.hasPrefix(corpus.resolvingSymlinksInPath().path + "/"),
              beta.resolvingSymlinksInPath().path.hasPrefix(corpus.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
        let directory = home.appendingPathComponent("sessions/2026/10/04")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (id, entry) in originals {
            guard let recorded = entry["path"] as? String else { throw CocoaError(.fileReadUnknown) }
            let source = URL(fileURLWithPath: recorded)
            guard source.resolvingSymlinksInPath().path.hasPrefix(corpus.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let bytes = try Data(contentsOf: source), target = directory.appendingPathComponent(source.lastPathComponent)
            try bytes.write(to: target); paths[id] = target; initialPrefixes[target] = bytes; originalHashes[source] = Self.digest(bytes)
        }
        for tree in [alpha, beta] {
            for path in ["src/Same.swift", "src/Origin.swift"] {
                let url = tree.appendingPathComponent(path)
                if let bytes = try? Data(contentsOf: url) { originalHashes[url] = Self.digest(bytes) }
            }
        }
    }
    func record(at: Date, kind: String, payload: [String: Any]) throws -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: at), "type": kind, "payload": payload], options: [.sortedKeys])
    }
    func append(owner: String, records: [Data]) throws {
        var data = Data(); for record in records { data.append(record); data.append(10) }; try appendBytes(owner: owner, bytes: data)
    }
    func appendBytes(owner: String, bytes: Data) throws {
        guard let path = paths[owner], path.path.hasPrefix(home.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    func initialRecords(at date: Date) throws -> [Data] {
        let patch = "*** Begin Patch\n*** Update File: \(beta.path)/src/Same.swift\n@@\n-static let label = \"before\"\n+static let label = \"recorded live patch\"\n*** End Patch"
        return try [
            record(at: date, kind: "turn_context", payload: ["turn_id": "v41-live", "cwd": beta.path]),
            record(at: date.addingTimeInterval(0.1), kind: "response_item", payload: ["type": "function_call", "call_id": "v41-initial-shell", "name": "exec_command", "namespace": "functions", "arguments": "{\"cmd\":\"touch \(sentinel.path)\",\"workdir\":\"\(beta.path)\"}"]),
            record(at: date.addingTimeInterval(0.2), kind: "response_item", payload: ["type": "function_call_output", "call_id": "v41-initial-shell", "output": "Recorded fixture output; no command executed."]),
            record(at: date.addingTimeInterval(0.3), kind: "response_item", payload: ["type": "custom_tool_call", "call_id": "v41-initial-patch", "name": "apply_patch", "input": patch]),
            record(at: date.addingTimeInterval(0.4), kind: "response_item", payload: ["type": "custom_tool_call_output", "call_id": "v41-initial-patch", "output": "Success. Updated the following files:\nM \(beta.path)/src/Same.swift"])
        ]
    }
    func liveRecords(at date: Date) throws -> [Data] {
        return try [
            record(at: date, kind: "response_item", payload: ["type": "message", "id": "v41-late-message", "role": "assistant", "content": [["type": "output_text", "text": "A new anonymous event while the visible timeline is paused."]]]),
            record(at: date.addingTimeInterval(0.1), kind: "response_item", payload: ["type": "function_call", "call_id": "v41-missing-output", "name": "exec_command", "namespace": "functions", "arguments": "{\"cmd\":\"cat src/Same.swift\",\"workdir\":\"\(alpha.path)\"}"])
        ]
    }
    func writeLateChild(id: String, at date: Date) throws {
        let path = home.appendingPathComponent("sessions/2026/10/04/rollout-v41-\(id).jsonl")
        paths[id] = path; try Data().write(to: path); initialPrefixes[path] = Data()
        let meta: [String: Any] = ["id": id, "session_id": rootID, "parent_thread_id": rootID, "agent_path": "/root/live-child", "cwd": beta.path, "cli_version": "0.159.2",
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": rootID, "depth": 1, "agent_path": "/root/live-child"]]]]
        try append(owner: id, records: [record(at: date, kind: "session_meta", payload: meta),
            record(at: date.addingTimeInterval(0.1), kind: "response_item", payload: ["type": "message", "id": "v41-child-mission", "role": "user", "content": [["type": "input_text", "text": "Read Beta without changing files."]]]),
            record(at: date.addingTimeInterval(0.2), kind: "response_item", payload: ["type": "function_call", "call_id": "v41-child-shell", "name": "exec_command", "namespace": "functions", "arguments": "{\"cmd\":\"cat src/Same.swift\",\"workdir\":\"\(beta.path)\"}"]),
            record(at: date.addingTimeInterval(0.3), kind: "response_item", payload: ["type": "function_call_output", "call_id": "v41-child-shell", "output": "Recorded descendant result."])])
    }
    func sourcesUnchanged() -> Bool { originalHashes.allSatisfy { (url, hash) in (try? Data(contentsOf: url)).map(Self.digest) == hash } }
    func appendedPrefixesUnchanged() -> Bool { initialPrefixes.allSatisfy { (url, bytes) in (try? Data(contentsOf: url).prefix(bytes.count)) == bytes } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
