import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Source-matched native host of unchanged app components. This is deliberately
/// separate from the true production @main QA bundle, and never sends inference.
@main struct V06QualificationMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let run = V06QualificationRun()
        Task { @MainActor in
            do { try await run.run() }
            catch { run.recordFatal(error) }
            if !CommandLine.arguments.contains("--linger") { app.terminate(nil) }
        }
        app.run()
    }
}

/// Only this owned render host ignores screen-size clamping. It changes neither
/// the display nor an external application's window, and captures its own view.
@MainActor private final class FixtureRenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class V06QualificationRun {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var unqualified: [String] = []
    private var receipt: [String: Any] = [:]
    private var host: NSHostingView<AnyView>?
    private var window: NSWindow?
    private var store: LensStore?
    private var context: LensWindowContext?

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let manifestData = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let fixture = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              fixture["anonymous"] as? Bool == true,
              let root = fixture["rootID"] as? String, let childID = fixture["childID"] as? String,
              let otherID = fixture["otherRootID"] as? String,
              let originalHome = fixture["home"] as? String,
              let worktrees = fixture["worktrees"] as? [String: String],
              let alpha = worktrees["alpha"], let beta = worktrees["beta"],
              let expected = fixture["expected"] as? [String: Any],
              let callIDs = expected["toolCallIDs"] as? [String: String] else { throw failure("Anonymous corpus manifest is incomplete.") }
        let runtime = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        // Copy ONLY generated fixture journals. Current files/worktrees remain the
        // same paths for before/after captures. The production QA corpus is never appended here.
        let home = runtime.appendingPathComponent("source")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: originalHome), to: home)
        let archive = InvestigationArchive(directory: runtime.appendingPathComponent("archive"))
        let current = LensStore(sourceHome: home, investigationArchive: archive,
                                cacheDirectory: runtime.appendingPathComponent("cache"))
        store = current
        let windowContext = LensWindowContext(store: current); context = windowContext
        current.setNavigationScope(UUID().uuidString)
        await current.start()
        await current.open(root)
        await current.waitForPresentation()
        current.showSessionPicker = false
        guard let snapshot = current.snapshot, snapshot.root.id == root, current.error == nil else {
            throw failure("Requested anonymous root did not open: \(current.error ?? "missing snapshot").")
        }
        receipt["scope"] = "Unchanged app/Core sources hosted by own native NSApplication; production @main is replaced. Separate production startup receipt is required."
        receipt["corpusManifestSHA256"] = digest(manifestData)
        receipt["rootID"] = root; receipt["initialEventCount"] = snapshot.events.count
        receipt["agentCount"] = snapshot.agents.count; receipt["resourceCount"] = snapshot.resources.count
        receipt["environmentCount"] = snapshot.environments.count; receipt["changeCount"] = snapshot.changes.count
        receipt["fixtureFamilyRawRecordCount"] = expected["familyRawRecordCount"]
        receipt["realCodexHomeRead"] = false; receipt["modelRequests"] = 0
        receipt["networkDeniedByLauncher"] = true
        receipt["interactionMethod"] = "Own model/AppKit component APIs; no injected OS input or computer-use clicks."
        receipt["appIsActive"] = NSApp.isActive
        check("root-and-separate-subagent", snapshot.agents.contains { $0.id == childID && $0.parentID == root && $0.relation == .subagent && $0.accessible })
        check("same-repository-root-not-attached", !snapshot.agents.contains { $0.id == otherID } && !snapshot.events.contains { $0.agentID == otherID })
        check("recorded-instruction-present", snapshot.events.contains { $0.kind == .instruction })
        guard let readAlpha = call(snapshot, callIDs["alphaRead"]), let readBeta = call(snapshot, callIDs["betaRead"]),
              let patch = call(snapshot, callIDs["patch"]), let largePatch = call(snapshot, callIDs["largePatch"]),
              let longCall = call(snapshot, callIDs["longOutput"]), let shellError = call(snapshot, callIDs["shellError"]) else {
            throw failure("A required recorded tool call is missing.")
        }
        let betaRecorded = try await current.engine.detail(for: readBeta)
        check("beta-recorded-read-is-historical", betaRecorded.output.contains("beta recorded read") && !betaRecorded.output.contains("beta current / manual fixture edit"))
        check("call-result-linked", readAlpha.relatedEventID != nil && readBeta.relatedEventID != nil)
        check("recorded-shell-error", shellError.isError || snapshot.events.contains { $0.callID == shellError.callID && $0.isError })
        check("distinct-worktree-environments", readAlpha.environmentID != readBeta.environmentID && (readAlpha.environmentID?.hasSuffix("/alpha") == true) && (readBeta.environmentID?.hasSuffix("/beta") == true))
        let alphaPath = alpha + "/src/Same.swift", betaPath = beta + "/src/Same.swift"
        let alphaCurrent = try await current.files.readText(path: alphaPath)
        let betaCurrent = try await current.files.readText(path: betaPath)
        check("same-relative-path-distinct-current-bytes", digest(Data(alphaCurrent.text.utf8)) == expected["alphaCurrentSHA256"] as? String && digest(Data(betaCurrent.text.utf8)) == expected["betaCurrentSHA256"] as? String && alphaCurrent.text != betaCurrent.text)
        if let missing = expected["missingAttachment"] as? String,
           let doc = expected["providedDocument"] as? String, let local = expected["localImage"] as? String {
            check("missing-supplied-attachment-explicit", snapshot.resources.contains { sameLocation($0.location, missing) && $0.roles.contains(.supplied) && $0.availability == .missing })
            check("provided-document-with-spaces", snapshot.resources.contains { sameLocation($0.location, doc) && $0.roles.contains(.supplied) && !$0.eventIDs.isEmpty })
            check("local-image-supplied", snapshot.resources.contains { sameLocation($0.location, local) && $0.roles.contains(.supplied) && $0.availability == .accessible })
        }
        guard let alphaEnv = snapshot.environments.first(where: { $0.path.hasSuffix("/alpha") }) else { throw failure("Alpha environment is absent.") }
        let git = try await current.files.currentDiff(environment: alphaEnv)
        check("manual-diff-remains-unattributed", git.text.contains("ManualOnly.swift") && !snapshot.changes.contains { $0.path.hasSuffix("ManualOnly.swift") })
        check("current-git-reference-explicit", !git.reference.isEmpty)
        let longRelated = snapshot.events.first { $0.id == longCall.relatedEventID }
        let pager = RecordedPager()
        var page = try await pager.begin(event: longCall, relatedEvent: longRelated, part: "output", limit: 8192)
        var fullOutput = page.text; var pages = 1
        while let token = page.token {
            guard pages < 512 else { throw failure("Recorded paging did not reach EOF.") }
            page = try await pager.next(token: token, limit: 8192); fullOutput += page.text; pages += 1
        }
        receipt["longOutputPages"] = pages; receipt["longOutputPresentedUTF8Bytes"] = fullOutput.utf8.count
        check("long-output-paged-through-final-line", pages > 1 && fullOutput.contains("anonymous output row 06499") && fullOutput.utf8.count >= (expected["longOutputUTF8Bytes"] as? Int ?? Int.max))

        current.inspectorVisible = false
        current.resetFilters(); current.section = .activity; await current.waitForPresentation()
        install(MainView().environmentObject(current), width: 900, height: 600)
        try await capturePair("01-activity-minimum")
        current.navigate(.agent(childID), newTab: true)
        current.agentFilter = childID; await current.waitForPresentation()
        check("agent-navigation-filters-own-track", current.agentFilter == childID && current.selection == .agent(childID))
        try await capturePair("02-agent", width: 1480, height: 900)
        current.resetFilters(); current.navigate(.event(longCall.id), newTab: true); current.inspectorVisible = true
        await current.waitForPresentation()
        try await capturePair("03-recorded-call", width: 1480, height: 900)
        guard let change = snapshot.changes.first(where: { $0.eventID == patch.id && $0.kind == .requestedPatch }) else { throw failure("Requested patch change is missing.") }
        current.inspectorVisible = false; current.navigate(.change(change.id), newTab: true)
        check("change-navigates-to-action-context", current.selectedEvent?.id == patch.id && current.section == .changes)
        try await capturePair("04-change", width: 1480, height: 900)
        let document = try await parseDiff(largePatch, current: current)
        receipt["largeDiffLineCount"] = document.files.flatMap(\.hunks).flatMap(\.lines).count
        check("large-recorded-patch-has-both-sides", document.files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.count == 3000 && document.files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .removed }.count == 3000)
        install(RecordedDiffView(document: document, initialProvenanceExpanded: true).environmentObject(current), width: 430, height: 320)
        try await capturePair("05-large-diff-compact", width: 430, height: 320)
        install(RecordedDiffView(document: document).id("qa-compact-default").environmentObject(current), width: 430, height: 320)
        try await capturePair("05b-large-diff-compact-default", width: 430, height: 320)
        install(MainView().environmentObject(current), width: 900, height: 600)
        current.navigate(.file(environment: readBeta.environmentID!, path: betaPath), newTab: true)
        check("file-destination-preserves-worktree", current.selection == .file(environment: readBeta.environmentID!, path: betaPath))
        try await capturePair("06-current-beta-file")
        if let missing = expected["missingAttachment"] as? String, let resource = snapshot.resources.first(where: { sameLocation($0.location, missing) }) {
            current.navigate(.resource(resource.id), newTab: true)
            check("attachment-retains-origin-context", !resource.eventIDs.isEmpty)
            try await capturePair("07-missing-resource")
        }
        if let local = expected["localImage"] as? String, let resource = snapshot.resources.first(where: { sameLocation($0.location, local) }) {
            current.navigate(.resource(resource.id), newTab: true)
            check("provided-image-retains-origin-context", !resource.eventIDs.isEmpty)
            try await capturePair("07b-provided-image")
        }
#if V06
        try await preparationRaces(current: current, root: root, event: longCall, recorded: betaRecorded.output)
#endif
        current.navigate(.event(readBeta.id))
        await current.prepareInvestigation(for: .event(readBeta.id))
        guard let frozen = current.investigation.capsule else { throw failure("Capsule preparation failed: \(current.investigation.issue ?? "no capsule").") }
        let frozenData = try frozen.transmissionJSON()
        check("capsule-root-and-recorded-context", frozen.rootThreadID == root && frozen.pieces.contains { $0.eventID == readBeta.id } && frozen.pieces.contains { $0.kind == "collectionManifest" })
        let piece = frozen.pieces.first { $0.eventID == readBeta.id }!
        let fixtureAnswer = "Réponse fixture, jamais produite par un modèle : le contenu lu appartient au worktree beta [\(piece.id)]. Citation volontairement inconnue [E999999]."
        current.investigation.response = fixtureAnswer
        let validated = frozen.validateCitations(in: fixtureAnswer)
        check("known-and-unknown-citations-explicit", validated.validIDs.contains(piece.id) && validated.invalidIDs == ["E999999"])
        let address = try EvidenceAddress(rootID: root, capsuleID: frozen.id, pieceID: piece.id)
        await current.openEvidence(address)
        check("citation-opens-frozen-piece", current.investigation.inspectedPiece == piece.id && current.selection == .evidence(capsule: frozen.id, piece: piece.id))
        try await capturePair("08-frozen-evidence", width: 1480, height: 900)
        await current.investigation.flushAndStop()
        check("capsule-archive-roundtrip", try await current.investigation.archive.load(id: current.investigation.recordID ?? "")?.capsule.digestSHA256 == frozen.digestSHA256)

        // Own fixture append proves collection continues while visual follow is
        // paused; it never writes a repository or real Codex journal.
        current.navigate(.event(readBeta.id)); current.follow = false
        let selected = current.selection, beforeCount = current.snapshot!.events.count
        let rootRollout = try ownRollout(home: home, id: root)
        let appended = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-01T15:00:00.000Z", "type": "response_item", "payload": ["type": "message", "id": "qa-native-live-append", "role": "assistant", "content": [["type": "output_text", "text": "Événement direct anonyme après coupe ; aucune opération exécutée."]]]], options: [.sortedKeys]) + Data([10])
        let writer = try FileHandle(forWritingTo: rootRollout); try writer.seekToEnd(); try writer.write(contentsOf: appended); try writer.close()
        let deadline = Date().addingTimeInterval(8)
        while current.waitingEvents == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        check("paused-visual-collects-new-events", current.waitingEvents > 0 && current.snapshot?.events.count == beforeCount && current.selection == selected)
        let afterAppendCapsule = try current.investigation.capsule?.transmissionJSON()
        check("live-append-does-not-mutate-capsule", current.investigation.capsule?.digestSHA256 == frozen.digestSHA256 && afterAppendCapsule == frozenData)
        current.toggleFollow(); await current.waitForPresentation()
        check("return-to-present-publishes-collected-event", current.snapshot?.events.count == beforeCount + 1)
        let oldTask = Task { await current.open(root) }
        await Task.yield(); await current.open(otherID); await oldTask.value; await current.waitForPresentation()
        check("rapid-root-change-keeps-latest-root", current.snapshot?.root.id == otherID && current.snapshot?.agents.allSatisfy { $0.id == otherID } == true)
#if V06
        for (name, passed) in nativeFileActionLogicChecks() { check("file-action-" + name, passed) }
#endif
        if NSApp.isActive, window?.isKeyWindow == true, window?.styleMask.contains(.resizable) == true {
            unqualified.append("Fullscreen transition was not triggered: this bounded pass preserves the before/after rendering conditions; no CUA gesture has been qualified.")
        } else {
            unqualified.append("OS focus/activation is unavailable; physical keyboard, context-menu gestures, fullscreen, and VoiceOver are unqualified. No lock/display state was changed.")
        }
        unqualified.append("Bitmap caching of own NSHostingView proves native component rendering, not compositor latency or interactive acceptance of the production application.")
        unqualified.append("The investigation answer is an explicit fixture; no API key or model inference was supplied.")
        current.stopObserving(); await current.investigation.flushAndStop()
        receipt["finishedAt"] = Date().ISO8601Format()
        try saveReceipt()
    }

    private func call(_ snapshot: SessionSnapshot, _ callID: String?) -> LensEvent? {
        snapshot.events.first { $0.callID == callID && ($0.kind == .toolCall || $0.kind == .delegation || $0.kind == .wait) }
    }
#if V06
    private func preparationRaces(current: LensStore, root: String, event: LensEvent, recorded: String) async throws {
        let source = EvidencePiece(id: "E001", kind: "recordedFixtureRead", title: "Ancienne sélection QA", text: recorded, eventID: event.id, sourceRefs: [event.source])
        let base = try EvidenceCapsule.build(rootThreadID: root, collectionCut: Date(), pieces: [source])
        current.investigation.capsule = base
        var completed = false
        let clearing = Task { @MainActor in let result = await current.prepareInvestigation(for: .event(event.id)); completed = true; return result }
        let deadline = Date().addingTimeInterval(1)
        while !current.investigation.preparing && !completed && Date() < deadline { await Task.yield() }
        if current.investigation.preparing && !completed {
            current.investigation.clear()
            let result = await clearing.value
            check("clear-during-preparation-does-not-republish", !result && current.investigation.capsule == nil)
        } else {
            _ = await clearing.value
            unqualified.append("Clear/preparation overlap was too short to establish on this run; no race PASS is inferred.")
            current.investigation.clear()
        }
        let replacement = try EvidenceCapsule.build(rootThreadID: root, collectionCut: Date(), pieces: [EvidencePiece(id: "E001", kind: "recordedFixtureRead", title: "Autre archive QA, même racine", text: "Autre choix local anonyme ; aucune inférence.")])
        let archiveRecord = try await current.investigation.archive.save(capsule: replacement, question: "Question fixture non envoyée")
        current.investigation.capsule = base
        completed = false
        let changing = Task { @MainActor in let result = await current.prepareInvestigation(for: .event(event.id)); completed = true; return result }
        let secondDeadline = Date().addingTimeInterval(1)
        while !current.investigation.preparing && !completed && Date() < secondDeadline { await Task.yield() }
        if current.investigation.preparing && !completed {
            await current.investigation.openRecord(archiveRecord.record.id)
            let result = await changing.value
            check("same-root-archive-change-invalidates-preparation", !result && current.investigation.capsule?.digestSHA256 == replacement.digestSHA256 && current.investigation.recordID == archiveRecord.record.id)
        } else {
            _ = await changing.value
            unqualified.append("Archive/preparation overlap was too short to establish on this run; no race PASS is inferred.")
        }
        current.investigation.clear(); current.investigation.capsule = base
        let cancelled = Task { @MainActor in await current.prepareInvestigation(for: .event(event.id)) }
        cancelled.cancel()
        let cancelResult = await cancelled.value
        check("cancelled-preparation-preserves-selected-capsule", !cancelResult && current.investigation.capsule?.digestSHA256 == base.digestSHA256)
        current.investigation.clear()
    }
#endif
    private func parseDiff(_ event: LensEvent, current: LensStore) async throws -> RecordedDiffDocument {
        let detail = try await current.engine.detail(for: event)
        let provenance = DiffProvenance(environmentID: event.environmentID ?? "unknown", eventIDs: [event.id], sources: [event.source] + event.supplementarySources, agentID: event.agentID)
        for text in [detail.arguments, detail.raw] {
            for patch in (try? RecordedDiff.extractRecordedDiffs(from: text)) ?? [] {
                if let parsed = try? RecordedDiff.parse(patch, provenance: provenance, kind: .requestedPatch) { return parsed }
            }
        }
        throw failure("Recorded patch did not parse.")
    }
    private func ownRollout(home: URL, id: String) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil),
              let path = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.hasSuffix(id + ".jsonl") }) else { throw failure("Own root rollout unavailable.") }
        return path
    }
    private func install<V: View>(_ root: V, width: CGFloat, height: CGFloat) {
        if window == nil {
            window = FixtureRenderWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window!.isReleasedWhenClosed = false; window!.title = "Codex Lens — anonymous native qualification"
        }
        let view = AnyView(root.environment(\.lensWindowContext, context).background(Color(nsColor: .windowBackgroundColor)))
        if let host { host.rootView = view } else { host = NSHostingView(rootView: view); host!.sizingOptions = []; window!.contentView = host }
        host!.frame = NSRect(x: 0, y: 0, width: width, height: height); window!.setContentSize(NSSize(width: width, height: height))
        window!.backgroundColor = .windowBackgroundColor
        context?.attach(window!); window!.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func capturePair(_ name: String, width: CGFloat? = nil, height: CGFloat? = nil) async throws {
        if let width, let height { host!.frame.size = NSSize(width: width, height: height); window!.setContentSize(host!.frame.size) }
        for theme in ["light", "dark"] {
            UserDefaults.standard.set(theme, forKey: "lensAppearance")
            window?.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
            try await Task.sleep(nanoseconds: 400_000_000)
            host!.layoutSubtreeIfNeeded(); host!.displayIfNeeded(); window!.displayIfNeeded()
            CATransaction.flush()
            guard let bitmap = host!.bitmapImageRepForCachingDisplay(in: host!.bounds) else { throw failure("Bitmap allocation failed.") }
            host!.cacheDisplay(in: host!.bounds, to: bitmap)
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw failure("Native PNG encoding failed.") }
            let filename = name + "-" + theme + ".png"
            try bytes.write(to: output.appendingPathComponent(filename))
            renders.append(["filename": filename, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                            "logicalWidth": host!.bounds.width, "logicalHeight": host!.bounds.height,
                            "theme": theme, "bytes": bytes.count, "sha256": digest(bytes), "anonymous": true])
        }
    }
    private func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
    private func sameLocation(_ a: String, _ b: String) -> Bool {
        guard a.hasPrefix("/"), b.hasPrefix("/") else { return a == b }
        return URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private func saveReceipt() throws {
        receipt["checks"] = checks; receipt["renders"] = renders; receipt["unqualified"] = unqualified
        receipt["allExecutedChecksPassed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        receipt["failedCheckIDs"] = checks.filter { $0["passed"] as? Bool == false }.compactMap { $0["id"] as? String }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("native-v06-receipt.json"), options: .atomic)
    }
    func recordFatal(_ error: Error) {
        checks.append(["id": "fatal", "passed": false, "message": error.localizedDescription])
        store?.stopObserving(); try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw failure("Missing " + name) }
        return CommandLine.arguments[index + 1]
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensNativeV06", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
