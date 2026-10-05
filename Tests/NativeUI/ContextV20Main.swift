import AppKit
import SwiftUI
import Foundation
import CryptoKit
import LensCore

/// Owned native component test process; production @main is replaced by the existing verifier.
@main struct ContextV20Main {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        Task { @MainActor in
            let run = ContextV20Run()
            do { try await run.run() } catch { run.fail(error) }
            app.terminate(nil)
        }
        app.run()
    }
}

@MainActor private final class ContextV20Run {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var store: LensStore?
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private func argument(_ key: String) throws -> String {
        guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { throw LensError.unavailable("Missing " + key) }
        return CommandLine.arguments[i + 1]
    }
    private func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    private func settle() async throws { for _ in 0..<8 { await Task.yield(); try await Task.sleep(nanoseconds: 25_000_000); host?.layoutSubtreeIfNeeded() } }
    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as! [String: Any]
        let root = manifest["rootID"] as! String, child = manifest["childID"] as! String
        let home = URL(fileURLWithPath: manifest["home"] as! String)
        UserDefaults.standard.set("fr", forKey: "lens.language")
        UserDefaults.standard.set("light", forKey: "lensAppearance")
        let store = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")), cacheDirectory: output.appendingPathComponent("index")); self.store = store
        await store.start(); await store.open(root); await store.waitForPresentation()
        let presentation = try require(store.presentation, "projection")
        check("actual-jsonl-three-identified-compactions", presentation.contextInspection.identifiedOperationCount == 3)
        check("actual-jsonl-child-compaction-keeps-child-thread", presentation.contextInspection.compactions.contains { $0.threadID == child && $0.isCountedOperation })
        check("provider-response-mirror-counted-once", presentation.contextInspection.usageSamples.filter { $0.facts.responseID == "qa-provider-response" }.count == 1)
        check("rendered-estimate-is-distinct", presentation.contextInspection.usageSamples.contains { $0.semantics == .renderedContextEstimate })
        check("no-automatic-request-inclusion", presentation.communicationInspection.communications.allSatisfy { $0.modelInclusionEventIDs.isEmpty })
        let compaction = try require(presentation.contextInspection.compactions.first { $0.threadID == root && $0.startTime != nil }, "root compaction")
        store.inspectorVisible = false
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: AnyView(MainView().environmentObject(store).environment(\.lensWindowContext, context))); host.sizingOptions = []; self.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Lens — anonymous context qualification"; window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        context.attach(window); try await settle()
        store.navigate(.event(compaction.eventID)); await store.waitForPresentation(); try await settle()
        store.inspectorVisible = true; try await settle()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        if let canvas = descendants(host).compactMap({ $0 as? TimelineCanvas }).first,
           let geometry = canvas.geometry, let item = canvas.projection?.item(id: compaction.eventID) {
            let x = geometry.x(for: item.start), visible = canvas.visibleRect
            check("opening-inspector-keeps-selected-timeline-marker-visible", x >= Double(visible.minX) + geometry.labelWidth && x <= Double(visible.maxX))
        } else { check("opening-inspector-keeps-selected-timeline-marker-visible", false) }
        check("compaction-uses-shared-selected-event", store.selectedEvent?.id == compaction.eventID)
        capture("compaction-fr-light.png")
        let prepared = await store.prepareInvestigation(for: .event(compaction.eventID))
        check("compaction-question-preparation-succeeds-without-send", prepared && !store.investigation.sending)
        check("compaction-capsule-includes-indexed-facts", store.investigation.capsule?.pieces.contains { $0.kind == "compactionEvidence" } == true)
        check("opaque-bytes-excluded-from-readable-capsule", store.investigation.capsule?.pieces.allSatisfy { !$0.text.contains("SYNTHETIC_OPAQUE_NOT_A_SUMMARY") } == true)
        try await settle(); capture("compaction-capsule-fr-light.png")
        let communication = try require(presentation.communicationInspection.communications.first { !$0.recipientContextEventIDs.isEmpty && !$0.isOpaque }, "recipient communication")
        let messageID = try require(communication.eventIDs.first, "message event")
        store.navigate(.event(messageID)); store.activityMode = .communications; store.kindFilter = nil; await store.waitForPresentation(); try await settle()
        check("sequence-reuses-activity-section", store.section == .activity && store.activityMode == .communications)
        check("sequence-routes-open-shared-identifiers", store.presentation?.sequence.routes.contains { $0.eventID == messageID } == true)
        capture("sequence-fr-light.png")
        let selected = store.selection
        var streamed = try require(store.snapshot, "snapshot")
        streamed.events.append(LensEvent(id: "native-publication-only", timestamp: Date(), agentID: root, kind: .assistant, title: "Synthetic UI publication", source: SourceRef(path: "/fixture/not-read")))
        store.snapshot = streamed; await store.waitForPresentation(); try await settle()
        check("publication-keeps-sequence-selection", store.selection == selected && store.activityMode == .communications)
        store.showInTimeline(messageID); await store.waitForPresentation(); try await settle()
        check("cross-view-link-restores-timeline-and-selection", store.activityMode == .chronology && store.selectedEvent?.id == messageID)
        store.goBack(); await store.waitForPresentation()
        check("back-restores-sequence-window-state", store.activityMode == .communications && store.selectedEvent?.id == messageID)
        let change = try require(store.snapshot?.changes.first { store.event($0.eventID)?.callID == "qa-child-context-diff" }, "child diff")
        store.navigate(.change(change.id)); await store.waitForPresentation(); try await settle()
        check("diff-keeps-child-and-exact-beta-worktree", store.selectedEvent?.agentID == child && change.environmentID.hasSuffix("/worktrees/beta"))
        capture("child-diff-fr-light.png")
        check("file-change-history-shares-selected-action", store.presentation?.activityEvidence.fileHistories.contains { $0.environmentID == change.environmentID && $0.activities.contains { $0.eventIDs.contains(change.eventID) } } == true)
        check("recorded-test-followed-by-change-visible", store.presentation?.activityEvidence.tests.contains { $0.activity.callID == "qa-context-test" && !$0.subsequentChangeIDs.isEmpty } == true)
        let questionPrepared = await store.prepareInvestigation(for: .change(change.id))
        check("diff-question-preparation-without-network", questionPrepared && !store.investigation.sending)
        let capsule = try require(store.investigation.capsule, "capsule")
        let piece = try require(capsule.pieces.first { $0.eventID == change.eventID && $0.kind == "recordedDiffDocument" }, "diff evidence")
        check("diff-capsule-keeps-recorded-lines-and-worktree", piece.text.contains("child recorded version") && piece.text.contains("before action") && piece.environmentID == change.environmentID && !piece.text.contains("manual current"))
        let address = try EvidenceAddress(rootID: root, capsuleID: capsule.id, pieceID: piece.id)
        await store.openEvidence(address); try await settle()
        check("citation-opens-exact-frozen-piece", store.selection == .evidence(capsule: capsule.id, piece: piece.id) && store.investigation.inspectedPiece == piece.id)
        capture("citation-fr-light.png")
        store.navigate(.event(compaction.eventID)); store.activityMode = .chronology; store.kindFilter = .compaction; await store.waitForPresentation()
        UserDefaults.standard.set("en", forKey: "lens.language"); UserDefaults.standard.set("dark", forKey: "lensAppearance")
        window.appearance = NSAppearance(named: .darkAqua); try await settle(); capture("compaction-en-dark.png")
        check("new-localized-labels-en", LensL10n.text("Contexte et compactage") == "Context and compaction")
        window.setContentSize(NSSize(width: 1120, height: 720)); try await settle(); capture("compact-resize-en-dark.png")
        check("resize-keeps-selection", store.selectedEvent?.id == compaction.eventID)
        store.stopObserving(); check("closing-stops-observation", !store.isObserving)
        finish()
    }
    private func require<T>(_ value: T?, _ name: String) throws -> T { guard let value else { throw LensError.unavailable("Missing " + name) }; return value }
    private func capture(_ name: String) {
        guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { check(name + "-capture", false); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { check(name + "-capture", false); return }
        do { try bytes.write(to: output.appendingPathComponent(name)); check(name + "-capture", true) } catch { check(name + "-capture", false) }
    }
    func fail(_ error: Error) { checks.append(["name": "fatal", "passed": false, "error": error.localizedDescription]); store?.stopObserving(); finish() }
    private func finish() {
        let receipt: [String: Any] = ["checks": checks, "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched native AppKit/SwiftUI component process; product @main replaced. Actual anonymous JSONL; frozen capsule/citation path without a model request. UI publication simulated by a new snapshot, not claimed as passive runtime collection.",
            "unqualified": ["Physical keyboard/trackpad", "Real inference is qualified separately in the production QA process", "Exact before-context from enhanced rollout-trace"]]
        if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) { try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json")) }
    }
}
