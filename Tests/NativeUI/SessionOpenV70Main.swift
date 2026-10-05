import AppKit
import Combine
import Foundation
import LensCore
import SwiftUI

/// Own synthetic sources only. No Codex process, account query or observed session.
@main struct SessionOpenV70Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() } catch { fputs("Session opening qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
    @MainActor private static func qualify() async throws {
        guard let i = CommandLine.arguments.firstIndex(of: "--output"), i + 1 < CommandLine.arguments.count else { throw LensError.unavailable("Missing output") }
        let output = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let a = output.appendingPathComponent("fixture-a"), b = output.appendingPathComponent("fixture-b")
        let idA = "aaaaaaaa-1111-4111-8111-111111111111", idB = "bbbbbbbb-2222-4222-8222-222222222222"
        func fixture(_ home: URL, id: String, message: String) throws -> URL {
            let sessions = home.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let records: [[String: Any]] = [
                ["timestamp": "2026-10-05T10:00:00Z", "type": "session_meta", "payload": ["id": id, "cwd": home.path, "cli_version": "0.159.2"]],
                ["timestamp": "2026-10-05T10:00:01Z", "type": "event_msg", "payload": ["type": "user_message", "message": message]]]
            let file = sessions.appendingPathComponent("rollout-" + id + ".jsonl")
            try records.reduce(into: Data()) { data, record in data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }.write(to: file)
            return file
        }
        let fileA = try fixture(a, id: idA, message: "Synthetic source A"), fileB = try fixture(b, id: idB, message: "Synthetic source B")
        let originalA = try Data(contentsOf: fileA), originalB = try Data(contentsOf: fileB)
        let store = LensStore(sourceHome: a, investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")), cacheDirectory: output.appendingPathComponent("own-cache"), readerPool: SessionReaderPool())
        store.investigation.automaticCodexCheckEnabled = false
        var checks: [[String: Any]] = [], renders: [[String: Any]] = []
        func sameHome(_ lhs: URL, _ rhs: URL) -> Bool { lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path }
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        await store.open("codex://threads/" + idA)
        check("Deep link opens the named thread in source A", store.snapshot?.root.id == idA && sameHome(store.observedSourceHome, a))
        await store.waitForPresentation()
        if let event = store.snapshot?.events.first { store.navigate(.event(event.id), newTab: true) }
        let baseline = store.snapshot!, baselineCount = store.presentation?.filteredEvents.count ?? 0
        var counts: [Int] = []
        let subscription = store.$presentation.dropFirst().compactMap { $0?.filteredEvents.count }.sink { counts.append($0) }
        for step in 1...4 {
            var next = baseline
            for number in 1...step {
                next.events.append(LensEvent(id: "live-\(number)", timestamp: Date(timeIntervalSince1970: Double(number)), agentID: idA,
                    kind: .assistant, title: "Synthetic live update", source: SourceRef(path: fileA.path, offset: UInt64(number), length: 1, line: number)))
            }
            store.snapshot = next
        }
        await store.waitForPresentation()
        subscription.cancel()
        check("Live burst publishes first usable projection then newest snapshot", counts.first == baselineCount + 1 && counts.last == baselineCount + 4 && counts.count == 2)
        var pending = baseline
        pending.events.append(LensEvent(id: "filtered-live", timestamp: .distantPast, agentID: idA, kind: .assistant,
            title: "Latest synthetic selection", source: SourceRef(path: fileA.path, offset: 42, length: 1, line: 42)))
        store.snapshot = baseline; store.snapshot = pending; store.kindFilter = .assistant
        await store.waitForPresentation()
        check("User filter supersedes pending live projection", store.presentation?.filteredEvents.map(\.id) == ["filtered-live"])
        store.kindFilter = nil; await store.waitForPresentation()
        let savedSelection = store.selection, savedTabs = store.tabs.map(\.id)
        store.busy = true; await store.useSessionSource(b)
        check("Source cannot change during an opening", sameHome(store.sourceHome, a))
        store.busy = false; await store.useSessionSource(b)
        let originalReaderHome = await store.engine.home
        check("Changing picker source keeps observed root and reader", sameHome(store.sourceHome, b) && sameHome(store.observedSourceHome, a) && sameHome(originalReaderHome, a) && store.snapshot?.root.id == idA)
        check("Changing picker source preserves selection and tabs", store.selection == savedSelection && store.tabs.map(\.id) == savedTabs)
        check("Catalog belongs to new source only", store.catalog.map(\.id) == [idB])
        await store.open("codex://threads/cccccccc-3333-4333-8333-333333333333")
        check("Failed opening preserves old source and selection", store.snapshot?.root.id == idA && sameHome(store.observedSourceHome, a) && store.selection == savedSelection && store.error?.contains(b.standardizedFileURL.path) == true && !store.busy)
        LensL10n.language = .en
        let missingNotice = store.error!
        check("Specific missing-session notice outranks generic session label", LensL10n.display(missingNotice).contains("was not found in"))
        let englishNotice = LensL10n.display(missingNotice)
        LensL10n.language = .fr
        check("Stored notice translates back without changing identifiers", LensL10n.display(englishNotice) == missingNotice)
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                let name = "session-picker-\(language.rawValue)-\(dark ? "dark" : "light")"
                renders.append(try await render(AnyView(SessionPickerView().environmentObject(store)), name: name, dark: dark, output: output))
            }
        }
        await store.handleURL(URL(string: "codex://threads/" + idB.uppercased() + "?view=review")!)
        let nextReaderHome = await store.engine.home
        check("URL handler opens source B and clears previous failure", store.snapshot?.root.id == idB && sameHome(store.observedSourceHome, b) && sameHome(nextReaderHome, b) && store.error == nil)
        let initialCount = store.snapshot?.events.count ?? 0
        var suffix = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-05T10:00:02Z", "type": "event_msg", "payload": ["type": "agent_message", "message": "New synthetic event"]]); suffix.append(10)
        let writer = try FileHandle(forWritingTo: fileB); try writer.seekToEnd(); try writer.write(contentsOf: suffix); try writer.close()
        let update = try await store.engine.refresh()
        check("Existing open source follows appended events", (update?.events.count ?? 0) > initialCount && update?.root.id == idB)
        check("Consultation never rewrites source files", try Data(contentsOf: fileA) == originalA && Data(contentsOf: fileB) == originalB + suffix)
        LensL10n.language = .en
        check("Source and deep-link instructions localized", LensL10n.text("Mes sessions Codex") == "My Codex sessions" && LensL10n.text("Recherche, ID ou lien de session") == "Session search, ID or link")
        store.stopObserving(); await store.useSessionSource(a)
        check("Closed store ignores later source switches", sameHome(store.sourceHome, b) && store.snapshot == nil && !store.hasSessionReader)
        await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "renders": renders, "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched store transitions and offscreen native picker renders on own synthetic sources; no credentials, inference or observed-session writes.",
            "unqualified": ["Production GUI interaction", "Full VoiceOver", "Authenticated inference"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    @MainActor private static func render(_ view: AnyView, name: String, dark: Bool, output: URL) async throws -> [String: Any] {
        let size = NSSize(width: 740, height: 560)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<25 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        return ["file": name + ".png", "width": size.width, "height": size.height, "method": "Own offscreen native component, not a production screenshot"]
    }
}
