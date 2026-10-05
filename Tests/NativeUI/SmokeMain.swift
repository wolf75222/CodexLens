import AppKit
import SwiftUI
import CryptoKit
import LensCore

/// Own-application verification host. It compiles the real UI files in this
/// module, exercises their model/component APIs, and never sends an enquiry.
/// Captured pixels and temporary private archives are inspection evidence only.
@main
@MainActor
struct NativeSmokeMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(CommandLine.arguments.contains("--linger") ? .regular : .accessory)
        Task { @MainActor in
            do {
                try await NativeSmokeRun().run()
                if !CommandLine.arguments.contains("--linger") { application.terminate(nil) }
            } catch {
                // Avoid printing recorded messages or underlying tool output.
                fputs("Native smoke failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }
}

@MainActor
private final class NativeSmokeRun {
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!
    private var receipt: [String: Any] = [:]

    func run() async throws {
        let rootID = try argument("--session")
        let project = URL(fileURLWithPath: try argument("--project")).standardizedFileURL
        let output = URL(fileURLWithPath: try argument("--output")).standardizedFileURL
        let archiveURL = URL(fileURLWithPath: try argument("--archive")).standardizedFileURL
        let sourceHome = URL(fileURLWithPath: try argument("--source-home"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let archive = InvestigationArchive(directory: archiveURL)
        let store = LensStore(sourceHome: sourceHome, investigationArchive: archive)
        guard await store.investigation.archive.directory.path == archiveURL.resolvingSymlinksInPath().path else { throw failure("Investigation archive injection was not honored.") }
        UserDefaults.standard.set("light", forKey: "lensAppearance")
        await store.start()
        await store.waitForPresentation()
        guard store.error == nil, let snapshot = store.snapshot, snapshot.root.id == rootID else { throw failure("The requested real session did not open.") }
        guard snapshot.agents.contains(where: { $0.parentID != nil }) else { throw failure("The real session has no accessible descendant to inspect.") }
        store.showSessionPicker = false
        store.inspectorVisible = false
        store.resetFilters()
        await store.waitForPresentation()
        receipt["sessionID"] = rootID
        receipt["initialEvents"] = snapshot.events.count
        receipt["initialAgents"] = snapshot.agents.count
        receipt["initialEnvironments"] = snapshot.environments.count
        receipt["initialResources"] = snapshot.resources.count
        receipt["openedAt"] = Date().ISO8601Format()
        receipt["interactionMethod"] = "Own model and AppKit component APIs; no computer-use clicks"
        receipt["apiKeySupplied"] = false
        receipt["modelRequests"] = 0
        receipt["networkDeniedByOS"] = true

        let (change, document) = try await chooseRealChange(snapshot: snapshot, project: project, store: store)
        let hunks = document.files.flatMap(\.hunks)
        let lines = hunks.flatMap(\.lines)
        guard !hunks.isEmpty, lines.contains(where: { $0.kind == .added || $0.kind == .removed }) else { throw failure("The selected real diff has no recorded changed lines.") }
        receipt["changeEventID"] = change.eventID
        receipt["changeAgentID"] = change.agentID
        receipt["selectedChangeFilename"] = URL(fileURLWithPath: change.path).lastPathComponent
        receipt["environmentPathSHA256"] = digest(Data(change.environmentID.utf8))
        receipt["diffHunks"] = hunks.count
        receipt["diffAddedLines"] = lines.filter { $0.kind == .added }.count
        receipt["diffRemovedLines"] = lines.filter { $0.kind == .removed }.count
        receipt["diffCoverage"] = document.coverage.rawValue

        store.navigate(.change(change.id), newTab: true)
        guard store.section == .changes, store.selectedEvent?.id == change.eventID else { throw failure("Change navigation lost its recorded event context.") }
        store.query = URL(fileURLWithPath: change.path).lastPathComponent
        install(MainView().environmentObject(store))
        await settle(milliseconds: 1800)
        try capture(output: output, filename: "01-recorded-diff.png")

        // A separately recorded descendant is selected, not merely the owner
        // of a root-agent patch. History still restores the original change.
        guard let child = snapshot.agents.first(where: { agent in
            agent.parentID != nil && agent.accessible && !agent.paths.isEmpty && snapshot.events.contains(where: { $0.agentID == agent.id })
        }) else { throw failure("No recorded descendant was available for navigation.") }
        store.resetFilters()
        await store.waitForPresentation()
        store.navigate(.agent(child.id), newTab: true)
        guard store.section == .agents, store.selection == .agent(child.id) else { throw failure("Agent navigation selected a different object.") }
        store.goBack()
        guard store.selection == .change(change.id) else { throw failure("Back navigation did not restore the change.") }
        store.goForward()
        guard store.selection == .agent(child.id) else { throw failure("Forward navigation did not restore the agent.") }
        store.agentFilter = child.id
        await store.waitForPresentation()
        guard !store.events.isEmpty, store.events.allSatisfy({ $0.agentID == child.id }) else { throw failure("Agent filtering mixed recorded owners.") }
        store.resetFilters()
        await store.waitForPresentation()
        receipt["agentNavigationAndHistory"] = true
        receipt["agentFiltering"] = true
        store.period = snapshot.events.first!.timestamp...snapshot.events.first!.timestamp.addingTimeInterval(1)
        store.follow = false
        store.perform(.follow)
        await store.waitForPresentation()
        guard store.follow, store.period == nil else { throw failure("Returning to the present kept a historical period filter.") }
        receipt["returnToPresentClearsHistoricalPeriod"] = true
        receipt["navigatedDescendantID"] = child.id
        receipt["descendantParentID"] = child.parentID
        receipt["descendantRelation"] = child.relation.rawValue
        receipt["descendantJournalCount"] = child.paths.count

        await store.prepareInvestigation(for: .change(change.id))
        guard store.investigation.issue == nil, let eventCapsule = store.investigation.capsule,
              eventCapsule.pieces.contains(where: { $0.eventID == change.eventID }),
              try eventCapsule.verifyDigest() else { throw failure("Preparing the selected real change did not produce a verified event capsule.") }
        receipt["recordedEventCapsulePieces"] = eventCapsule.pieces.count

        // The current reader uses the selected worktree and is labelled current.
        store.navigate(.file(environment: change.environmentID, path: change.path), newTab: true)
        guard store.section == .environments, store.selection == .file(environment: change.environmentID, path: change.path) else { throw failure("File navigation lost the environment identity.") }
        await settle(milliseconds: 1800)
        guard let nativeCode = descendants(host).compactMap({ $0 as? CodeDocumentHost }).first,
              let editor = descendants(nativeCode).compactMap({ $0 as? NSTextView }).first,
              !editor.string.isEmpty, !editor.isEditable, editor.isSelectable else { throw failure("The real code reader is absent, empty or editable.") }
        guard editor.accessibilityHelp()?.contains(change.path) == true else { throw failure("The code reader did not retain its absolute file identity.") }
        let selection = NSRange(location: 0, length: min(160, (editor.string as NSString).length))
        editor.setSelectedRange(selection)
        nativeCode.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: editor))
        guard editor.selectedRange() == selection else { throw failure("The native selection was not retained.") }
        // Reinstalling identical data must not replace the native text selection.
        let observed = try await store.files.readText(path: change.path)
        nativeCode.install(text: editor.string, path: change.path, versionLabel: "Actuel · " + observed.version, requestedLine: nil,
                           onSelection: nil, onLineNavigate: nil,
                           onInvestigateSelection: { range, text in
                               store.addCodeEvidence(text: text, path: change.path, environmentID: change.environmentID,
                                                     version: observed.version, line: 1, historical: false)
                           })
        guard editor.selectedRange() == selection else { throw failure("A same-document update reset the AppKit selection.") }
        await settle(milliseconds: 350)
        try capture(output: output, filename: "02-current-code-selection.png")
        guard editor.tryToPerform(NSSelectorFromString("investigateSelection:"), with: nil) else { throw failure("The code component's own selection action was unavailable.") }
        guard store.investigation.capsule?.pieces.contains(where: { $0.kind == "capturedCurrentCode" }) == true else { throw failure("The native selection action did not add current-code provenance.") }
        receipt["codeReadOnly"] = true
        receipt["codeSelectionPreserved"] = true
        receipt["selectionAddedThroughComponentAction"] = true
        receipt["currentFileVersion"] = observed.version
        receipt["currentTextSHA256"] = digest(Data(editor.string.utf8))

        store.investigation.editQuestion("Quels faits sont établis par le patch enregistré et l’extrait courant sélectionné ?")
        guard let frozen = store.investigation.capsule, try frozen.verifyDigest() else { throw failure("The frozen enquiry capsule is invalid.") }
        let frozenDigest = frozen.digestSHA256
        let frozenBytes = try frozen.transmissionJSON()
        let cutEventIDs = Set(store.snapshot?.events.map(\.id) ?? [])
        receipt["capsulePieces"] = frozen.pieces.count
        receipt["capsuleOmissions"] = frozen.omissions.count
        receipt["capsuleBytes"] = frozenBytes.count
        receipt["capsuleSHA256"] = frozenDigest
        receipt["capsuleCut"] = frozen.collectionCut.ISO8601Format()
        receipt["capsuleExcludedFromAutocollection"] = frozen.excludedFromAutocollection
        receipt["sourceRefCount"] = frozen.pieces.reduce(0) { $0 + $1.sourceRefs.count }
        print("Native capsule frozen: \(frozen.pieces.count) pieces, \(frozenBytes.count) bytes; waiting for persisted real activity.")
        fflush(stdout)
        store.investigation.inspectedPiece = frozen.pieces.first(where: { $0.kind == "capturedCurrentCode" })?.id
        await settle(milliseconds: 1300)
        try capture(output: output, filename: "03-frozen-investigation.png")

        let deadline = Date().addingTimeInterval(24)
        while Date() < deadline, Set(store.snapshot?.events.map(\.id) ?? []).subtracting(cutEventIDs).isEmpty {
            await settle(milliseconds: 500)
        }
        guard let advanced = store.snapshot else { throw failure("The live view lost its snapshot.") }
        let newlyObserved = Set(advanced.events.map(\.id)).subtracting(cutEventIDs).count
        guard newlyObserved > 0 else { throw failure("No new persisted event was observed during the bounded live check; advancement is unqualified.") }
        guard store.investigation.capsule?.digestSHA256 == frozenDigest,
              try store.investigation.capsule?.transmissionJSON() == frozenBytes else { throw failure("Live collection changed the prepared capsule.") }
        receipt["newEventsAfterFreeze"] = newlyObserved
        receipt["finalEvents"] = advanced.events.count
        receipt["finalAgents"] = advanced.agents.count
        receipt["liveSnapshotAdvanced"] = true
        receipt["frozenCapsuleUnchanged"] = true

        guard let recordID = store.investigation.recordID,
              let record = try await archive.load(id: recordID),
              record.capsule.digestSHA256 == frozenDigest,
              try record.capsule.transmissionJSON() == frozenBytes else { throw failure("The actual draft archive did not preserve the frozen capsule.") }
        let exclusions = try await archive.collectionExclusions()
        guard exclusions.investigationIDs.contains(recordID), exclusions.inferenceIDs.isEmpty,
              store.investigation.apiKey.isEmpty, !store.investigation.sending else { throw failure("Archive exclusions or the no-inference boundary failed.") }
        receipt["archiveDraftRoundTrip"] = true
        receipt["archiveExcluded"] = true
        receipt["archiveInferenceIDs"] = exclusions.inferenceIDs.count
        receipt["completedAt"] = Date().ISO8601Format()
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: output.appendingPathComponent("native-smoke-receipt.json"), options: .atomic)
        print("Native smoke passed: 3 AppKit renders; \(newlyObserved) real new events; unchanged capsule \(frozenDigest).")
        if CommandLine.arguments.contains("--linger") {
            // Leave our own real window available for independent CUA observation.
            store.navigate(.file(environment: change.environmentID, path: change.path), newTab: true)
            await settle(milliseconds: 1500)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: false)
            print("Native verification window remains open for observation; close this process to finish.")
            fflush(stdout)
        } else { window.close() }
    }

    private func chooseRealChange(snapshot: SessionSnapshot, project: URL, store: LensStore) async throws -> (ChangeRecord, RecordedDiffDocument) {
        let preferred = ["InvestigationClient.swift", "LensStore.swift", "MainView.swift", "CodeDocumentView.swift"]
        let candidates = snapshot.changes.filter { $0.kind == .requestedPatch && $0.path.contains(project.path + "/") && FileManager.default.fileExists(atPath: $0.path) }
            .sorted { (preferred.firstIndex(of: URL(fileURLWithPath: $0.path).lastPathComponent) ?? 100) < (preferred.firstIndex(of: URL(fileURLWithPath: $1.path).lastPathComponent) ?? 100) }
        for change in candidates.prefix(80) {
            guard let event = snapshot.events.first(where: { $0.id == change.eventID }), event.source.length <= RecordedDiff.maximumInputBytes else { continue }
            guard let detail = try? await store.engine.detail(for: event) else { continue }
            let provenance = DiffProvenance(environmentID: change.environmentID, eventIDs: [event.id], sources: [event.source] + event.supplementarySources, agentID: event.agentID)
            for value in [detail.arguments, detail.output, detail.raw] {
                guard let patches = try? RecordedDiff.extractRecordedDiffs(from: value) else { continue }
                for patch in patches {
                    guard var document = try? RecordedDiff.parse(patch, provenance: provenance, kind: .requestedPatch) else { continue }
                    document.files = document.files.filter { file in
                        let path = file.path.hasPrefix("/") ? file.path : (change.environmentID as NSString).appendingPathComponent(file.path)
                        return (path as NSString).standardizingPath == (change.path as NSString).standardizingPath
                    }
                    if document.files.flatMap(\.hunks).contains(where: { !$0.lines.isEmpty }) { return (change, document) }
                }
            }
        }
        throw failure("No accessible recorded patch for a real Lens project file was parseable.")
    }

    private func install<V: View>(_ root: V) {
        // MainView intentionally inherits its window background. A cached view
        // bitmap otherwise preserves transparent areas, which image viewers
        // can display as black. Render the same native window color explicitly.
        host = NSHostingView(rootView: AnyView(root.background(Color(nsColor: .windowBackgroundColor))))
        host.frame = NSRect(x: 0, y: 0, width: 1640, height: 1040)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Lens — native verification host"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.makeKeyAndOrderFront(nil)
    }

    private func settle(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        host?.layoutSubtreeIfNeeded()
        host?.displayIfNeeded()
    }

    private func capture(output: URL, filename: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("AppKit could not allocate the native rendering bitmap.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), bitmap.pixelsWide > 1000, bitmap.pixelsHigh > 500 else { throw failure("The native rendering bitmap is invalid or too small.") }
        try data.write(to: output.appendingPathComponent(filename), options: .atomic)
        var images = receipt["renders"] as? [[String: Any]] ?? []
        images.append(["filename": filename, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "bytes": data.count, "sha256": digest(data)])
        receipt["renders"] = images
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func argument(_ key: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.count > index + 1 else { throw failure("Missing required harness argument: \(key).") }
        return CommandLine.arguments[index + 1]
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensNativeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
