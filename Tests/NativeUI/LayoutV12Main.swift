import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Anonymous native component qualification. Production @main is replaced;
/// neither OS input nor model inference is simulated.
@main struct LayoutV12Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let run = DesignPrinciplesRun()
        Task { @MainActor in
            do { try await run.run() } catch { run.recordFatal(error) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}

@MainActor private final class DesignRenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class DesignPrinciplesRun {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var receipt: [String: Any] = [:]
    private var host: NSHostingView<AnyView>?
    private var window: NSWindow?
    private var store: LensStore?
    private var context: LensWindowContext?

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let data = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              fixture["anonymous"] as? Bool == true,
              let root = fixture["rootID"] as? String, let child = fixture["childID"] as? String,
              let originalHome = fixture["home"] as? String,
              let worktrees = fixture["worktrees"] as? [String: String], let beta = worktrees["beta"],
              let expected = fixture["expected"] as? [String: Any],
              let callIDs = expected["toolCallIDs"] as? [String: String] else { throw failure("Incomplete anonymous fixture manifest.") }
        let runtime = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let home = runtime.appendingPathComponent("source")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: originalHome), to: home)
        let current = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: runtime.appendingPathComponent("archive")), cacheDirectory: runtime.appendingPathComponent("cache"))
        store = current; context = LensWindowContext(store: current)
        current.setNavigationScope(UUID().uuidString)
        await current.start(); await current.open(root); await current.waitForPresentation()
        current.showSessionPicker = false; current.inspectorVisible = false; current.resetFilters()
        guard let snapshot = current.snapshot, snapshot.root.id == root, current.error == nil,
              let betaCall = snapshot.events.first(where: { $0.callID == callIDs["betaRead"] && $0.kind == .toolCall }),
              let betaEnvironment = betaCall.environmentID else { throw failure("Anonymous session did not open fully.") }
        receipt["startedAt"] = Date().ISO8601Format()
        receipt["scope"] = "Unchanged production app/Core components hosted by own native NSApplication; production @main is replaced. Not the production executable or compositor capture."
#if V07
        receipt["variant"] = "v07"
#else
        receipt["variant"] = "baseline-v06"
#endif
        receipt["corpusManifestSHA256"] = digest(data)
        receipt["rootID"] = root; receipt["events"] = snapshot.events.count; receipt["agents"] = snapshot.agents.count
        receipt["resources"] = snapshot.resources.count; receipt["environments"] = snapshot.environments.count
        receipt["realCodexHomeRead"] = false; receipt["modelRequests"] = 0; receipt["networkDeniedByLauncher"] = true
        receipt["interactionMethod"] = "Own model and native component APIs only; no OS input, no accessibility clicks, no system state changes."
        check("anonymous-root-and-separate-child", snapshot.agents.contains { $0.id == child && $0.parentID == root })
        current.section = .activity
        installMain(current, enlarged: false)
        try await capturePair("01-main-900x600", requested: NSSize(width: 900, height: 600), fontSize: 12, enlarged: false)
        installMain(current, enlarged: true)
        try await capturePair("02-main-enlarged-900x600", requested: NSSize(width: 900, height: 600), fontSize: 18, enlarged: true)
        current.navigate(.file(environment: betaEnvironment, path: beta + "/src/Same.swift"), newTab: true)
        check("file-keeps-beta-worktree", current.selection == .file(environment: betaEnvironment, path: beta + "/src/Same.swift"))
        installMain(current, enlarged: false)
        try await capturePair("03-file-900x600", requested: NSSize(width: 900, height: 600), fontSize: 12, enlarged: false)
        installMain(current, enlarged: true)
        try await capturePair("04-file-enlarged-900x600", requested: NSSize(width: 900, height: 600), fontSize: 18, enlarged: true)
        current.fontSize = 12
        current.navigate(.event(betaCall.id)); _ = await current.prepareInvestigation(for: .event(betaCall.id))
        guard let frozen = current.investigation.capsule,
              let piece = frozen.pieces.first(where: { $0.eventID == betaCall.id }) else { throw failure("Real fixture evidence preparation did not produce a capsule.") }
        check("captured-call-source-present", piece.sourceRefs.contains(betaCall.source) && piece.environmentID == betaEnvironment)
        let frozenBytes = try frozen.transmissionJSON()
        current.investigation.editQuestion("Question fixture locale : dans quel worktree cette lecture est-elle enregistrée ?")
        let answer = "Réponse fixture explicite, sans appel de modèle : lecture du worktree beta [\(piece.id)]. Référence inconnue [E999999]."
        current.investigation.response = answer
        let input = InvestigationPresentationInput(rootID: root, capsuleID: frozen.id, capsuleDigest: frozen.digestSHA256, response: answer, question: current.investigation.question, model: "fixture-model-not-sent", includePayload: true)
        let prepared = try await InvestigationPresentationCache.shared.prepare(capsule: frozen, input: input)
        check("payload-prepared-off-main", prepared.preparedOffMainThread)
        guard let payload = prepared.payload, let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw failure("Prepared request is not readable JSON.") }
        check("payload-tool-less-no-storage", prepared.payloadIsRequest && (object["tools"] as? [Any])?.isEmpty == true && object["tool_choice"] as? String == "none" && object["store"] as? Bool == false)
        check("payload-without-authentication", object["api_key"] == nil && object["authorization"] == nil && current.investigation.apiKey.isEmpty && current.investigation.model.isEmpty)
        check("valid-and-unknown-citations-distinct", prepared.citations.validIDs.contains(piece.id) && prepared.citations.invalidIDs == ["E999999"])
        let address = try EvidenceAddress(rootID: root, capsuleID: frozen.id, pieceID: piece.id)
        await current.openEvidence(address)
        check("citation-selects-frozen-proof", current.investigation.inspectedPiece == piece.id && current.selection == .evidence(capsule: frozen.id, piece: piece.id))
        check("question-and-citation-do-not-mutate-capsule", try current.investigation.capsule?.transmissionJSON() == frozenBytes && current.investigation.capsule?.digestSHA256 == frozen.digestSHA256)
        installMain(current, enlarged: false)
        try await capturePair("05-chat-900x600", requested: NSSize(width: 900, height: 600), fontSize: 12, enlarged: false)
        installMain(current, enlarged: true)
        try await capturePair("06-chat-enlarged-900x600", requested: NSSize(width: 900, height: 600), fontSize: 18, enlarged: true)
        // The payload control is tested independently through its actual actor.
        // Opening collapsed controls requires a production initializer, never a
        // copied or patched View. v07 additions are inserted after its API freeze.
        try await qualifyV07(current: current, frozen: frozen, piece: piece)
        try await qualifyCompactChat(current: current, frozen: frozen, piece: piece)
        receipt["appIsActive"] = NSApp.isActive
        receipt["keyWindowIsOwnedHost"] = NSApp.keyWindow === window
        receipt["fontQualification"] = "store.fontSize 12→18 affects app code/table readers; dynamicTypeSize accessibility2 is supplied to the own host. Fixed-font controls are not claimed to scale."
        receipt["unqualified"] = ["Physical keyboard, menu routing, VoiceOver, IME, clipboard, fullscreen and resize gestures were not exercised.", "Own NSHostingView bitmaps do not qualify production application startup, compositor latency or CUA interaction.", "Response and model ID are explicit local fixtures; no inference or authentication was used."]
        current.stopObserving(); await current.investigation.flushAndStop()
        receipt["finishedAt"] = Date().ISO8601Format()
        try saveReceipt()
    }

    private func qualifyCompactChat(current: LensStore, frozen: EvidenceCapsule, piece: EvidencePiece) async throws {
        current.resetFilters(); current.inspectorVisible = true
        await current.openEvidence(try EvidenceAddress(rootID: frozen.rootThreadID, capsuleID: frozen.id, pieceID: piece.id))
        current.investigation.editQuestion("Question locale de test : vérifier la preuve Beta sans envoi.")
        let original = try current.investigation.capsule!.transmissionJSON()
        var observations: [[String: Any]] = []
        for size in [12.0, 18.0, 24.0] {
            current.fontSize = size
            install(MainView().environmentObject(current), width: 900, height: 600)
            try await capturePair("10-chat-inspector-font-\(Int(size))", requested: NSSize(width: 900, height: 600), fontSize: size, enlarged: size > 12)
            let readers = allViews(host!).compactMap { $0 as? NSTextView }.filter { !$0.isEditable && $0.string == piece.text }
            let viewport = readers.first?.enclosingScrollView?.contentView.bounds.height ?? 0
            check("compact-font-\(Int(size))-proof-reader-visible", readers.count == 1 && viewport >= 60)
            check("compact-font-\(Int(size))-frozen-bytes-preserved", try current.investigation.capsule!.transmissionJSON() == original)
            check("compact-font-\(Int(size))-selected-piece-preserved", current.investigation.inspectedPiece == piece.id && current.selection == .evidence(capsule: frozen.id, piece: piece.id))
            observations.append(["fontSize": size, "proofViewportHeight": viewport, "readOnlyReaderCount": readers.count,
                                 "hostWidth": host!.bounds.width, "hostHeight": host!.bounds.height])
        }
        current.investigation.sending = true // explicit local UI fixture; no request or key
        try await capturePair("11-chat-stop-inspector", requested: NSSize(width: 900, height: 600), fontSize: 24, enlarged: true)
        check("local-sending-fixture-keeps-frozen-context", try current.investigation.capsule!.transmissionJSON() == original)
        current.investigation.cancel()
        check("cancel-fixture-keeps-question-and-capsule", try current.investigation.capsule!.transmissionJSON() == original && current.investigation.question.contains("Question locale de test"))
        current.investigation.sending = false // no send task exists in this rendering fixture
        receipt["compactChatObservations"] = observations
        receipt["configurationSheetInteractionQualified"] = false
        receipt["requestCancellationQualified"] = false
        receipt["variant"] = "v12-layout"
    }
    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func qualifyV07(current: LensStore, frozen: EvidenceCapsule, piece: EvidencePiece) async throws {
#if V07
        let scopePeriod = frozen.collectionCut.addingTimeInterval(-3600)...frozen.collectionCut
        current.query = "activity-fixture-query"; current.kindFilter = .toolCall; current.period = scopePeriod
        current.agentQuery = "beta"; current.section = .agents
        let agentClearAvailable = current.canPerform(.clearFilters)
        current.perform(.clearFilters)
        check("clear-agent-search-keeps-activity-query-type-period", agentClearAvailable && current.agentQuery.isEmpty && current.query == "activity-fixture-query" && current.kindFilter == .toolCall && current.period == scopePeriod)
        current.agentQuery = "beta"; current.section = .activity
        let activityClearAvailable = current.canPerform(.clearFilters)
        current.perform(.clearFilters)
        check("clear-activity-filters-keeps-agent-search", activityClearAvailable && current.query.isEmpty && current.kindFilter == nil && current.period == nil && current.agentQuery == "beta")
        current.agentQuery = ""; current.section = .investigation
        await current.waitForPresentation()
        let live = current.investigation
        let selectedBefore = live.inspectedPiece
        live.removePiece(piece.id)
        check("removal-offers-visible-undo", live.canUndoEvidenceRemoval && live.evidenceRemovalNotice?.contains(piece.id) == true && live.capsule?.pieces.contains(where: { $0.id == piece.id }) == false)
        installMain(current, enlarged: false)
        try await capturePair("07-proof-removed-900x600", requested: NSSize(width: 900, height: 600), fontSize: 12, enlarged: false)
        live.undoEvidenceRemoval()
        check("undo-restores-exact-captured-bytes-and-selection", try live.capsule?.transmissionJSON() == frozen.transmissionJSON() && live.capsule?.digestSHA256 == frozen.digestSHA256 && live.inspectedPiece == selectedBefore && !live.canUndoEvidenceRemoval)
        installMain(current, enlarged: false)
        try await capturePair("08-proof-restored-900x600", requested: NSSize(width: 900, height: 600), fontSize: 12, enlarged: false)

        // Independent real InvestigationStore methods qualify checkpoint guards,
        // without manufacturing OS actions or touching supplied/current files.
        let test = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("runtime/undo-archive")))
        await test.loadArchive(rootID: frozen.rootThreadID)
        let originalQuestion = "Question fixture originale, sans modèle"
        let originalAnswer = "Réponse fixture à restaurer [\(piece.id)]"
        let saved = try await test.archive.save(capsule: frozen, question: originalQuestion)
        _ = try await test.archive.updateResponse(id: saved.record.id, response: originalAnswer)
        await test.openRecord(saved.record.id)
        test.inspectedPiece = piece.id; test.reviewed = true
        let prior = try test.capsule!.transmissionJSON()
        test.removePiece("E_DOES_NOT_EXIST")
        check("unknown-proof-is-no-op", try test.capsule?.transmissionJSON() == prior && !test.canUndoEvidenceRemoval)
        test.preparing = true; test.removePiece(piece.id)
        check("preparing-blocks-removal", try test.capsule?.transmissionJSON() == prior && !test.canUndoEvidenceRemoval)
        test.preparing = false; test.sending = true; test.removePiece(piece.id)
        check("sending-blocks-removal", try test.capsule?.transmissionJSON() == prior && !test.canUndoEvidenceRemoval)
        test.sending = false; test.removePiece(piece.id)
        let removed = try test.capsule!.transmissionJSON()
        test.preparing = true; test.undoEvidenceRemoval()
        check("preparing-blocks-undo", try test.capsule?.transmissionJSON() == removed && !test.canUndoEvidenceRemoval)
        test.preparing = false; test.sending = true; test.undoEvidenceRemoval()
        check("sending-blocks-undo", try test.capsule?.transmissionJSON() == removed && !test.canUndoEvidenceRemoval)
        test.sending = false; test.undoEvidenceRemoval()
        check("same-question-restores-answer-archive-and-review", try test.capsule?.transmissionJSON() == prior && test.response == originalAnswer && test.recordID == saved.record.id && test.reviewed && test.inspectedPiece == piece.id)
        test.removePiece(piece.id); test.editQuestion("Question fixture éditée après retrait")
        test.undoEvidenceRemoval()
        check("undo-preserves-later-question-without-stale-answer", try test.capsule?.transmissionJSON() == prior && test.question == "Question fixture éditée après retrait" && test.response == nil && test.recordID == nil && !test.reviewed)
        test.removePiece(piece.id)
        let replacement = try EvidenceCapsule.build(rootThreadID: frozen.rootThreadID, collectionCut: frozen.collectionCut, pieces: frozen.pieces)
        test.capsule = replacement; test.undoEvidenceRemoval()
        check("same-root-replacement-invalidates-checkpoint", !test.canUndoEvidenceRemoval && test.capsule?.id == replacement.id && test.evidenceRemovalNotice == nil)
        test.capsule = frozen; test.removePiece(piece.id)
        let editedID = test.capsule!.id
        let sameIDReplacement = try EvidenceCapsule.build(rootThreadID: frozen.rootThreadID, collectionCut: frozen.collectionCut, pieces: [EvidencePiece(id: "E001", kind: "replacementFixture", title: "Même ID, octets différents", text: "Le checkpoint précédent ne doit pas restaurer cette autre capsule.")], id: editedID)
        test.capsule = sameIDReplacement; test.undoEvidenceRemoval()
        check("same-id-new-digest-invalidates-checkpoint", !test.canUndoEvidenceRemoval && test.capsule?.digestSHA256 == sameIDReplacement.digestSHA256 && test.evidenceRemovalNotice == nil)
        test.capsule = frozen; test.removePiece(piece.id)
        try test.append([EvidencePiece(id: "E_NEW", kind: "fixtureAddition", title: "Preuve ajoutée anonymisée", text: "Autre choix, sans fichier ni inférence.")], rootID: frozen.rootThreadID, cut: frozen.collectionCut)
        let appendedID = test.capsule?.id; test.undoEvidenceRemoval()
        check("append-invalidates-checkpoint", !test.canUndoEvidenceRemoval && test.capsule?.id == appendedID && test.capsule?.pieces.contains(where: { $0.kind == "fixtureAddition" }) == true)
        test.capsule = frozen; test.removePiece(piece.id); test.clear(); test.undoEvidenceRemoval()
        check("clear-invalidates-checkpoint", test.capsule == nil && !test.canUndoEvidenceRemoval)
        test.capsule = frozen; test.removePiece(piece.id); await test.openRecord(saved.record.id)
        check("archive-opening-invalidates-checkpoint", !test.canUndoEvidenceRemoval && test.recordID == saved.record.id)
        test.removePiece(piece.id); await test.loadArchive(rootID: "99999999-9999-4999-8999-999999999999"); test.undoEvidenceRemoval()
        check("root-switch-invalidates-checkpoint", test.capsule == nil && !test.canUndoEvidenceRemoval)
        await test.loadArchive(rootID: frozen.rootThreadID); test.capsule = frozen; test.removePiece(piece.id)
        await test.flushAndStop(); test.undoEvidenceRemoval()
        check("stop-invalidates-checkpoint", !test.canUndoEvidenceRemoval && test.capsule?.pieces.contains(where: { $0.id == piece.id }) == false)
        let largeText = String(repeating: "anonyme 🌿\n", count: 10000)
        let large = try EvidenceCapsule.build(rootThreadID: frozen.rootThreadID, collectionCut: frozen.collectionCut,
            pieces: [EvidencePiece(id: "E001", kind: "largeFixture", title: "Grande preuve capturée", text: largeText, knownVersion: "fixture-sha-large-v1"), EvidencePiece(id: "E002", kind: "smallFixture", title: "Petite preuve à retirer", text: "Petite preuve anonyme")],
            maxBytes: 512 * 1024, pieceMaxBytes: 384 * 1024)
        test.capsule = large; test.removePiece("E002")
        check("removal-preserves-large-remaining-proof-and-budget", largeText.utf8.count > 64 * 1024 && test.capsule?.pieces.first?.text == largeText && test.capsule?.pieces.first?.knownVersion == "fixture-sha-large-v1" && test.capsule?.maxEncodedBytes == large.maxEncodedBytes && test.capsule?.omissions.count == large.omissions.count + 1)
        test.undoEvidenceRemoval()
        check("large-proof-undo-restores-exact-json-and-sha", try test.capsule?.transmissionJSON() == large.transmissionJSON() && test.capsule?.digestSHA256 == large.digestSHA256)
        await test.flushAndStop()
        let newQuestionStore = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("runtime/new-question-archive")))
        await newQuestionStore.loadArchive(rootID: frozen.rootThreadID)
        newQuestionStore.capsule = frozen
        let immediateQuestion = "Brouillon fixture immédiat : texte complet avant les 600 ms.\nDeuxième ligne anonyme."
        newQuestionStore.editQuestion(immediateQuestion)
        // No debounce delay: invoke the real New Question method immediately.
        await newQuestionStore.beginNewQuestion()
        let newRecords = try await newQuestionStore.archive.list()
        let immediateRecord = try await newQuestionStore.archive.load(id: newRecords.first?.id ?? "")
        check("new-question-immediately-persists-latest-draft", immediateRecord?.question == immediateQuestion && immediateRecord?.capsule.digestSHA256 == frozen.digestSHA256 && newQuestionStore.capsule == nil && newQuestionStore.question.isEmpty && newQuestionStore.records.contains(where: { $0.id == immediateRecord?.id }))
        await newQuestionStore.flushAndStop()
        let blockingFile = output.appendingPathComponent("runtime/blocked-archive-parent")
        try Data("Own fixture file; cannot contain a directory.".utf8).write(to: blockingFile)
        let failedStore = InvestigationStore(archive: InvestigationArchive(directory: blockingFile.appendingPathComponent("archive")))
        failedStore.capsule = frozen
        failedStore.editQuestion(immediateQuestion)
        await failedStore.beginNewQuestion()
        check("new-question-write-failure-preserves-draft", failedStore.question == immediateQuestion && failedStore.capsule?.digestSHA256 == frozen.digestSHA256 && failedStore.issue?.contains("brouillon reste ouvert") == true && !failedStore.preparing)
        await failedStore.flushAndStop()
        let range = Date(timeIntervalSince1970: 1790863200)...Date(timeIntervalSince1970: 1790864100)
        install(TimelinePeriodEditor(initial: range, apply: { _ in }).environmentObject(current), width: 500, height: 260)
        try await capturePair("09-timeline-period-editor", requested: NSSize(width: 500, height: 260), fontSize: 12, enlarged: false)
        receipt["periodEditorQualification"] = "Real native date-picker component rendered in initial state; no OS keyboard/action routing is inferred."
        receipt["undoQualification"] = "Actual InvestigationStore remove/undo/append/clear/archive/root/stop APIs. Exact captured JSON and SHA restored; fixture answer and local record restored only for unchanged question. Sending/preparing are local guard states, no send request executed."
#else
        receipt["undoQualification"] = "Baseline v06 has no undo API; unavailable is preserved."
#endif
    }
    private func installMain(_ current: LensStore, enlarged: Bool) {
        current.fontSize = enlarged ? 18 : 12
        install(MainView().environmentObject(current).environment(\.dynamicTypeSize, enlarged ? .accessibility2 : .large), width: 900, height: 600)
    }
    private func install<V: View>(_ root: V, width: CGFloat, height: CGFloat) {
        if window == nil {
            window = DesignRenderWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window!.isReleasedWhenClosed = false; window!.title = "Codex Lens — anonymous design qualification"
        }
        let view = AnyView(root.environment(\.lensWindowContext, context).background(Color(nsColor: .windowBackgroundColor)))
        if let host { host.rootView = view } else { host = NSHostingView(rootView: view); host!.sizingOptions = []; window!.contentView = host }
        host!.frame = NSRect(x: 0, y: 0, width: width, height: height); window!.setContentSize(NSSize(width: width, height: height))
        context?.attach(window!); window!.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func capturePair(_ name: String, requested: NSSize, fontSize: Double, enlarged: Bool) async throws {
        for theme in ["light", "dark"] {
            UserDefaults.standard.set(theme, forKey: "lensAppearance")
            window?.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
            try await Task.sleep(nanoseconds: 500_000_000)
            host!.layoutSubtreeIfNeeded(); host!.displayIfNeeded(); window!.displayIfNeeded(); CATransaction.flush()
            guard let bitmap = host!.bitmapImageRepForCachingDisplay(in: host!.bounds) else { throw failure("No native bitmap.") }
            host!.cacheDisplay(in: host!.bounds, to: bitmap)
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw failure("No native PNG.") }
            let filename = name + "-" + theme + ".png"; try bytes.write(to: output.appendingPathComponent(filename))
            renders.append(["filename": filename, "requestedWidth": requested.width, "requestedHeight": requested.height,
                            "logicalWidth": host!.bounds.width, "logicalHeight": host!.bounds.height,
                            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "fontSize": fontSize,
                            "dynamicTypeAccessibility2": enlarged, "theme": theme, "bytes": bytes.count, "sha256": digest(bytes), "anonymous": true])
        }
    }
    private func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
    private func saveReceipt() throws {
        receipt["checks"] = checks; receipt["renders"] = renders
        receipt["allExecutedChecksPassed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        receipt["failedCheckIDs"] = checks.filter { $0["passed"] as? Bool == false }.compactMap { $0["id"] as? String }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"), options: .atomic)
    }
    func recordFatal(_ error: Error) {
        checks.append(["id": "fatal", "passed": false, "message": error.localizedDescription]); store?.stopObserving(); try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { throw failure("Missing " + name) }; return CommandLine.arguments[i + 1]
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensDesignV07", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
