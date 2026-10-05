import AppKit
import SwiftUI
import Foundation
import LensCore

@main struct OriginV21Main {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        Task { @MainActor in
            let run = OriginV21Run()
            do { try await run.run() } catch { run.fail(error) }
            app.terminate(nil)
        }
        app.run()
    }
}

@MainActor private final class OriginV21Run {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var store: LensStore?
    private var host: NSHostingView<AnyView>?
    private var window: NSWindow?
    private func argument(_ key: String) throws -> String { guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { throw LensError.unavailable("Missing " + key) }; return CommandLine.arguments[i + 1] }
    private func require<T>(_ value: T?, _ name: String) throws -> T { guard let value else { throw LensError.unavailable("Missing " + name) }; return value }
    private func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
    private func settle() async throws { for _ in 0..<8 { await Task.yield(); try await Task.sleep(nanoseconds: 25_000_000); host?.layoutSubtreeIfNeeded() } }
    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as! [String: Any]
        let root = manifest["rootID"] as! String, child = manifest["childID"] as! String
        let cases = manifest["originCases"] as! [String: Any], grand = manifest["grandchildID"] as! String
        UserDefaults.standard.set("fr", forKey: "lens.language"); LensL10n.language = .fr; UserDefaults.standard.set("light", forKey: "lensAppearance")
        let store = LensStore(sourceHome: URL(fileURLWithPath: manifest["home"] as! String), investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")), cacheDirectory: output.appendingPathComponent("index")); self.store = store
        await store.start(); await store.open(root); await store.waitForPresentation()
        let p = try require(store.presentation, "presentation"), snapshot = try require(store.snapshot, "snapshot")
        let patch = try require(snapshot.events.first { $0.callID == cases["mainPatchCallID"] as? String && $0.kind == .toolCall }, "grandchild patch call")
        let change = try require(snapshot.changes.first { $0.kind == .recordedResult && p.eventsByID[$0.eventID]?.callID == patch.callID && $0.evidence.hasPrefix("FileChange") }, "recorded result change")
        let origin = try require(p.originInspection.selection(objectID: OriginInspectionIndex.changeID(change.id)), "origin selection")
        check("grandchild-thread-kept-despite-shared-root-session-id", patch.agentID == grand && p.agentsByID[grand]?.parentID == child)
        check("two-exact-parent-missions", origin.missionEventIDs.count == 2 && origin.missionEventIDs.compactMap { p.eventsByID[$0]?.callID }.contains("qa-origin-spawn-grand"))
        let promptIDs = snapshot.events.filter { $0.trace?.sourceIdentifiers?["payload.id"] == "qa-origin-prompt-primary" || $0.trace?.sourceIdentifiers?["payload.id"] == "qa-origin-prompt-constraint" }.map(\.id)
        check("both-user-prompts-remain-contextual-contributions", promptIDs.count == 2 && promptIDs.allSatisfy { origin.instructionEventIDs.contains($0) })
        check("forward-instruction-has-explicit-recipient-without-lifetime-attribution", promptIDs.allSatisfy { p.originInspection.selection(objectID: OriginInspectionIndex.eventID($0))?.missionTargetAgentIDs.contains(child) == true && p.originInspection.associatedChangeIDsByInstruction[$0]?.contains(change.id) != true })
        check("no-context-to-causal-promotion", origin.explanations.allSatisfy { $0.relation == .associatedContext })
        check("nearby-same-turn-reasoning-is-only-context", origin.explanations.filter { p.eventsByID[$0.eventID]?.trace?.sourceIdentifiers?["payload.id"] == cases["unrelatedNearbyReasoningID"] as? String }.allSatisfy { $0.relation == .associatedContext })
        check("opaque-explanation-recognized-without-payload", snapshot.events.contains { $0.trace?.explanation?.availability == .opaque } && origin.explanations.allSatisfy { !$0.facts.preview.contains("OPAQUE") })
        check("empty-explanation-recognized", snapshot.events.contains { $0.trace?.explanation?.availability == .empty })
        check("late-explanation-not-generation-time", origin.explanations.contains { $0.ordering.contains("après") && $0.facts.timestampBasis == .sourceRecordGenerationUnknown })
        check("fork-not-subagent", snapshot.agents.first { $0.id == cases["forkID"] as? String }?.relation == .fork)
        check("no-fork-execution-in-root-instruction-scope", promptIDs.allSatisfy { id in !(p.originInspection.associatedEventIDsByInstruction[id] ?? []).contains { p.eventsByID[$0]?.agentID == cases["forkID"] as? String } })
        check("homonymous-worktree-excluded", origin.contributionChangeIDs.compactMap { p.changesByID[$0] }.allSatisfy { $0.environmentID == change.environmentID })
        check("multiple-producers-same-file-visible", Set(origin.contributionChangeIDs.compactMap { p.changesByID[$0]?.agentID }).count >= 2)
        check("test-then-change-preserved", p.activityEvidence.tests.contains { $0.activity.callID == cases["testCallID"] as? String && !$0.subsequentChangeIDs.isEmpty })
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: AnyView(MainView().environmentObject(store).environment(\.lensWindowContext, context))); host.sizingOptions = []; self.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.title = "Codex Lens — anonymous origin qualification"; window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); self.window = window; context.attach(window)
        store.navigate(.change(change.id)); store.inspectorVisible = true; await store.waitForPresentation(); try await settle(); capture("origin-fr-light.png")
        let originalSelection = store.selection
        var updated = snapshot; updated.collectedAt = Date(); store.snapshot = updated; await store.waitForPresentation(); try await settle()
        check("publication-preserves-selected-change", store.selection == originalSelection)
        let prompt = try require(promptIDs.first, "prompt")
        store.showInstructionActivity(prompt); await store.waitForPresentation(); try await settle()
        check("instruction-filters-existing-timeline", store.section == .activity && store.originInstructionFilter == prompt && store.events.contains { $0.callID == "qa-spawn" } && !store.events.contains { $0.id == patch.id })
        store.goBack(); await store.waitForPresentation(); try await settle()
        check("back-restores-change-and-filter", store.selection == originalSelection && store.originInstructionFilter == nil)
        let expectedFrozenOrigin = try require(store.presentation?.originInspection.selection(objectID: OriginInspectionIndex.changeID(change.id)), "origin at question capture")
        let prepared = await store.prepareInvestigation(for: .change(change.id))
        check("question-prepared-without-network-or-send", prepared && !store.investigation.sending)
        let capsule = try require(store.investigation.capsule, "capsule")
        try JSONEncoder().encode(capsule).write(to: output.appendingPathComponent("prepared-capsule.json"))
        let piece = try require(capsule.pieces.first { $0.kind == "originEvidence" }, "origin evidence")
        let payloadStart = try require(piece.text.firstIndex(of: "{"), "origin JSON start")
        let frozenOrigin = try OriginEvidence.decode(Data(piece.text[payloadStart...].utf8))
        check("origin-capsule-retains-complete-reversible-graph", frozenOrigin == expectedFrozenOrigin && !capsule.omissions.contains { $0.pieceID == piece.id })
        check("origin-capsule-has-chain-and-context-separation", piece.text.contains(grand) && piece.text.contains("associatedContext") && piece.text.contains("qa-origin-spawn-grand"))
        check("diff-capsule-has-both-recorded-object-ids", capsule.pieces.contains { $0.kind == "recordedDiffDocument" && $0.text.contains(cases["mainBeforeObject"] as! String) && $0.text.contains(cases["mainAfterObject"] as! String) })
        check("frozen-capsule-excludes-current-and-opaque-content", !capsule.pieces.contains { $0.text.contains("manual current beta") || $0.text.contains("SYNTHETIC_OPAQUE_NOT_A_SUMMARY") })
        let address = try EvidenceAddress(rootID: root, capsuleID: capsule.id, pieceID: piece.id); await store.handleURL(address.url); await store.waitForPresentation(); try await settle()
        check("citation-opens-exact-frozen-origin-evidence", store.selection == .evidence(capsule: capsule.id, piece: piece.id) && store.investigation.inspectedPiece == piece.id)
        capture("origin-capsule-fr-light.png")
        UserDefaults.standard.set("en", forKey: "lens.language"); LensL10n.language = .en; UserDefaults.standard.set("dark", forKey: "lensAppearance"); host.rootView = AnyView(MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, .dark))
        window.appearance = NSAppearance(named: .darkAqua); store.navigate(.change(change.id)); window.setContentSize(NSSize(width: 1180, height: 780)); await store.waitForPresentation(); try await settle(); capture("origin-en-dark.png")
        check("origin-label-localized-en", LensL10n.text("Origine et justification") == "Origin and justification")
        check("resize-keeps-change-selection", store.selection == .change(change.id))
        // Exercise the product capsule path with an opaque mission projection.
        // This publication is simulated; the JSONL adapter is separately regression-tested.
        var opaqueSnapshot = snapshot
        if let mission = origin.missionEventIDs.first, let i = opaqueSnapshot.events.firstIndex(where: { $0.id == mission }) {
            var trace = opaqueSnapshot.events[i].trace ?? RecordedTraceFacts()
            var communication = trace.communication ?? RecordedCommunicationFacts(kind: .spawn, stage: .sendRequested)
            communication.isOpaque = true; trace.communication = communication; opaqueSnapshot.events[i].trace = trace
            store.snapshot = opaqueSnapshot; await store.waitForPresentation()
            let opaquePrepared = await store.prepareInvestigation(for: .change(change.id))
            check("opaque-mission-capsule-is-prepared-without-send", opaquePrepared && !store.investigation.sending)
            check("opaque-mission-input-is-explicitly-omitted", store.investigation.capsule?.omissions.contains { $0.reason.contains(mission + " / input") && $0.reason.contains("opaque") } == true)
        } else { check("opaque-mission-fixture-present", false) }
        store.stopObserving(); check("closing-stops-passive-observation", !store.isObserving); finish()
    }
    private func capture(_ name: String) {
        guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { check(name + "-capture", false); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { check(name + "-capture", false); return }
        do { try bytes.write(to: output.appendingPathComponent(name)); check(name + "-capture", true) } catch { check(name + "-capture", false) }
    }
    func fail(_ error: Error) { checks.append(["name": "fatal", "passed": false, "error": error.localizedDescription]); store?.stopObserving(); finish() }
    private func finish() {
        let receipt: [String: Any] = ["checks": checks, "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true }, "scope": "Source-matched native component process; product @main replaced. Actual dedicated anonymous JSONL. No model request. Snapshot publication is simulated, not an external-live-append qualification.", "unqualified": ["Physical keyboard/trackpad", "Actual inference qualified separately", "Historical full reasoning absent from provider"]]
        if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) { try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json")) }
    }
}
