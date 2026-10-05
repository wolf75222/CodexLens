import AppKit
import SwiftUI
import LensCore
import CryptoKit

/// Source-matched integration tests and offscreen native renders. No real account or session.
@main struct ConversationV32Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Conversation qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor static func qualify() async throws {
        guard let argument = CommandLine.arguments.firstIndex(of: "--output"), argument + 1 < CommandLine.arguments.count else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) throws {
            checks.append(["name": name, "passed": passed])
            guard passed else { throw LensError.corrupt("Failed: " + name) }
        }
        let journal = output.appendingPathComponent("anonymous-session.jsonl")
        let rootID = "11111111-1111-4111-8111-111111111111"
        let texts = ["Je souhaite inspecter le diff dans le bon worktree. Préserve les sources.",
                     "Je vais relier le diff à son appel et à sa provenance enregistrée.",
                     "Corrige plutôt la navigation. Je préfère un chat latéral, sans modifier les fichiers."]
        var bytes = Data(), events: [LensEvent] = []
        for (index, text) in texts.enumerated() {
            let role = index == 1 ? "assistant" : "user"
            let object: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": role,
                "content": [["type": "input_text", "text": text]]]]
            let line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            events.append(LensEvent(id: "message-\(index)", timestamp: Date(timeIntervalSince1970: 1_790_850_000 + Double(index)),
                agentID: rootID, turnID: "turn-\(index)", kind: role == "user" ? .user : .assistant,
                environmentID: "/anonymous/worktrees/alpha", source: SourceRef(path: journal.path, offset: UInt64(bytes.count), length: line.count,
                    line: index + 1, sha256: SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined())))
            bytes.append(line); bytes.append(10)
        }
        try bytes.write(to: journal)
        events.append(LensEvent(id: "missing", agentID: rootID, kind: .user, preview: "must never replace missing text",
            source: SourceRef(path: output.appendingPathComponent("missing.jsonl").path, length: 10)))
        events.append(LensEvent(id: "child", agentID: "child-thread", kind: .assistant, source: events[1].source))
        let root = SessionSummary(id: rootID, title: "Navigation et provenance · session anonymisée", paths: [journal.path])
        let snapshot = SessionSnapshot(root: root, agents: [], events: events, environments: [], resources: [], changes: [], coverage: [], collectedAt: Date())
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-source-home"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")), cacheDirectory: output.appendingPathComponent("own-cache"))
        store.snapshot = snapshot
        var searchRequests = 0
        let findWindow = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        findWindow.isReleasedWhenClosed = false
        let sheetSearch = LensFindCommandTarget(window: findWindow, context: nil, search: { searchRequests += 1 })
        sheetSearch.perform(.showFindInterface)
        try check("Sheet Find targets its own preview search", sheetSearch.canFind && !sheetSearch.canFindNext && searchRequests == 1)
        let findText = ConversationFindProbe(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        findText.isEditable = false; findText.isSelectable = true
        findWindow.contentView = findText; findWindow.makeFirstResponder(findText)
        sheetSearch.perform(.nextMatch)
        try check("Sheet next match targets its own native text", sheetSearch.canFindNext && findText.actions == [NSTextFinder.Action.nextMatch.rawValue] && searchRequests == 1)
        let absentSearch = LensFindCommandTarget(window: findWindow, context: nil, search: nil)
        absentSearch.perform(.showFindInterface)
        try check("Unrelated windows do not inherit conversation Find", !absentSearch.canFind && !absentSearch.canFindNext && findText.actions.count == 1)
        findWindow.contentView = nil; findWindow.close()
        let controller = ConversationExportController(snapshot: snapshot)
        controller.prepare()
        try await wait { controller.review != nil && !controller.isLoadingMessage && !controller.isFiltering }
        try check("Index constructed off main thread", controller.planPreparedOffMainThread == true)
        try check("Review root user and assistant only", controller.review?.messages.count == 4 && controller.review?.assistantCount == 1)
        controller.apply(filter: .orientation, query: "")
        try await wait { !controller.isFiltering }
        try check("Local orientation filter retains original IDs", controller.visibleMessages.map(\.id) == ["message-0", "message-2"])
        controller.apply(filter: .all, query: "absent")
        controller.apply(filter: .user, query: "chat")
        try await wait { !controller.isFiltering }
        try check("Obsolete filter does not publish", controller.visibleMessages.map(\.id) == ["message-2"])
        controller.selectedID = "message-2"; controller.loadMessage("message-2")
        try await wait { !controller.isLoadingMessage }
        guard let message = controller.selectedMessage else { throw LensError.corrupt("No selected message") }
        try check("Selected text and worktree recorded", message.text == texts[2] && message.environmentID == "/anonymous/worktrees/alpha")
        let exporter = ConversationExporter(plan: ConversationExportPlan(snapshot: snapshot))
        _ = try await exporter.prepare()
        try Data("later data that must not replace frozen text".utf8).write(to: journal)
        _ = try await exporter.export(to: output.appendingPathComponent("anonymous-conversation.json"), format: .json)
        _ = try await exporter.export(to: output.appendingPathComponent("anonymous-conversation.md"), format: .markdown)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("anonymous-conversation.json"))) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        try check("Frozen export survives source rewrite", messages[2]["text"] as? String == texts[2])
        try check("Missing source stays explicit null", messages[3]["text"] is NSNull && messages[3]["status"] as? String == "unavailable")
        store.investigation.question = "Quel changement de direction est enregistré ?"
        let draft = store.investigation.question
        let added = await store.addConversationEvidence(message: message, rootID: rootID, cut: snapshot.collectedAt)
        try check("Frozen evidence added without sending or losing draft", added && store.investigation.question == draft && !store.investigation.sending && store.chatVisible)
        guard let capsule = store.investigation.capsule, let piece = capsule.pieces.first else { throw LensError.corrupt("No capsule") }
        try check("Evidence uses captured message after rewrite", piece.text.contains(texts[2]) && piece.environmentID == message.environmentID)
        let address = try EvidenceAddress(rootID: rootID, capsuleID: capsule.id, pieceID: piece.id)
        await store.openEvidence(address)
        try check("Citation opens immutable proof", store.displayedEvidenceCapsule?.id == capsule.id && store.displayedEvidencePieceID == piece.id)
        var other = snapshot; other.root.id = "other-root"; store.snapshot = other
        let rejected = await store.addConversationEvidence(message: message, rootID: rootID, cut: snapshot.collectedAt)
        try check("Changed session cannot receive stale proof", !rejected && store.investigation.capsule?.id == capsule.id)
        store.snapshot = snapshot
        let cancelled = Task { await store.addConversationEvidence(message: message, rootID: rootID, cut: snapshot.collectedAt) }
        cancelled.cancel()
        try check("Cancelled addition cannot mutate capsule", await cancelled.value == false)
        store.snapshot = snapshot
        controller.close()
        controller.prepare(); controller.apply(filter: .all, query: "")
        try check("Closed controller cannot restart reads", !controller.isPreparing && !controller.isFiltering)
        // Restore only our anonymous fixture for four actual native component renders.
        try bytes.write(to: journal)
        var renders: [[String: Any]] = []
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                let size = NSSize(width: language == .en ? 780 : 1020, height: 720)
                let host = NSHostingView(rootView: ConversationExportView(snapshot: snapshot, onClose: {}).environmentObject(store)
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size); window.contentView = host
                for _ in 0..<25 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
                let filename = "conversation-\(language.rawValue)-\(dark ? "dark" : "light").png"
                try png.write(to: output.appendingPathComponent(filename)); renders.append(["file": filename, "method": "Own native NSHostingView bitmap, not production screenshot", "width": size.width, "height": size.height])
                window.contentView = nil; window.close()
            }
        }
        await exporter.dispose(); store.stopObserving(); await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "allExecutedChecksPassed": true, "renders": renders,
            "unqualified": ["Physical keyboard and Save panel interaction: Mac locked", "Production compositor screenshots", "Performance improvement, full disk, power-loss durability", "Model request or automatic semantic analysis"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw LensError.unavailable("Qualification wait exceeded 5 seconds")
    }
}

@MainActor private final class ConversationFindProbe: NSTextView {
    var actions: [Int] = []
    override func performTextFinderAction(_ sender: Any?) {
        if let item = sender as? NSMenuItem { actions.append(item.tag) }
    }
}
