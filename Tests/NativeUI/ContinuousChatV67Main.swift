import AppKit
import Foundation
import LensCore
import SwiftUI

/// Native chat variants on frozen anonymous evidence. No visible window, Dock
/// item, Codex process, credential query, network request or observed source.
@main struct ContinuousChatV67Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Continuous chat v67 qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else {
            throw LensError.unavailable("Missing --output")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var checks: [[String: Any]] = [], renders: [[String: Any]] = []
        for symbol in ["square.and.pencil", "arrow.down", "arrow.up", "stop.fill"] {
            checks.append(["name": "chat-symbol-" + symbol, "passed": LensSymbols.name(symbol) == symbol
                && NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil])
        }
        let fresh = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("fresh-chat-archive")))
        await fresh.loadArchive(rootID: "anonymous-fresh-chat")
        let freshDigest = fresh.capsule?.digestSHA256
        fresh.ensureChatContext(rootID: "anonymous-fresh-chat")
        fresh.editChatQuestion("Bonjour, je voudrais discuter.")
        checks.append(["name": "fresh-chat-allows-writing-without-selection-or-send", "passed":
            fresh.capsule?.pieces.isEmpty == true && fresh.capsule?.digestSHA256 == freshDigest
            && fresh.question == "Bonjour, je voudrais discuter." && !fresh.sending && fresh.codexChatID == nil])
        await fresh.beginNewChat()
        checks.append(["name": "new-chat-retains-draft-and-needs-no-selection", "passed":
            fresh.capsule?.pieces.isEmpty == true && fresh.question.isEmpty && fresh.codexChatID == nil
            && fresh.records.contains(where: { $0.questionPreview.contains("Bonjour") }) && !fresh.sending])
        fresh.ensureChatContext(rootID: "wrong-root")
        checks.append(["name": "chat-context-does-not-switch-observed-session", "passed": fresh.capsule?.rootThreadID == "anonymous-fresh-chat"])
        await fresh.flushAndStop()

        let input = LensChatInputTextView()
        input.isEditable = true; input.canSubmit = true
        var submissions = 0
        input.submit = { submissions += 1 }
        func key(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        input.keyDown(with: key()); input.keyDown(with: key(.command))
        checks.append(["name": "native-editor-return-and-command-return-submit", "passed": submissions == 2])
        input.canSubmit = false; input.keyDown(with: key())
        checks.append(["name": "native-editor-disabled-send-does-not-submit", "passed": submissions == 2])
        checks.append(["name": "native-editor-shift-option-and-composition-preserve-input", "passed":
            !LensChatInputTextView.isSubmitKey(key(.shift), composing: false)
            && !LensChatInputTextView.isSubmitKey(key(.option), composing: false)
            && !LensChatInputTextView.isSubmitKey(key(), composing: true)])
        let cut = Date(timeIntervalSince1970: 1_759_320_000)
        let pieces = (1...12).map { ordinal in
            EvidencePiece(id: String(format: "E%03d", ordinal), kind: "recordedDiff",
                title: "Sources/AnonymousVeryLongInvestigationFile\(ordinal).swift",
                text: "Recorded fixture patch; not an actual current file.\n-old\n+new",
                environmentID: "/anonymous/worktrees/alpha", knownVersion: "fixture-captured-version-\(ordinal)", capturedAt: cut)
        }
        let capsule = try EvidenceCapsule.build(rootThreadID: "anonymous-sidechat-root", collectionCut: cut,
            pieces: pieces, omissions: [EvidenceOmission(reason: "Anonymous missing historical bytes; current state not substituted.")], createdAt: cut)
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-home"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")),
            cacheDirectory: output.appendingPathComponent("own-cache"))
        let completed = try await store.investigation.archive.save(capsule: capsule,
            question: "Quel libellé change dans ce diff ?", codexChatID: "66666666-6666-4666-8666-666666666666")
        let answer = """
        ## Ce qui change
        Le patch remplace `old` par `new`. [E001]

        ```swift
        let label = "new"
        ```

        La version complète du fichier n’est pas incluse dans cet extrait.
        """
        _ = try await store.investigation.archive.updateResponse(id: completed.record.id, response: answer)
        await store.investigation.openRecord(completed.record.id)
        try store.investigation.append([EvidencePiece(id: "E001", kind: "recordedCall", title: "Next attachment", text: "Anonymous next context")], rootID: capsule.rootThreadID, cut: cut)
        checks.append(["name": "attach-after-answer-opens-followup-in-same-chat", "passed":
            !store.investigation.responseComplete && store.investigation.response == nil && store.investigation.question.isEmpty
            && store.investigation.codexChatID == "66666666-6666-4666-8666-666666666666" && !store.investigation.sending])
        await store.investigation.openRecord(completed.record.id)
        store.investigation.removePiece("E001")
        checks.append(["name": "remove-after-answer-does-not-disable-next-message", "passed": !store.investigation.responseComplete && store.investigation.question.isEmpty])
        store.investigation.undoEvidenceRemoval()
        checks.append(["name": "undo-removal-restores-exact-completed-exchange", "passed": store.investigation.responseComplete
            && store.investigation.response == answer && store.investigation.recordID == completed.record.id
            && store.investigation.capsule?.digestSHA256 == capsule.digestSHA256])
        await store.investigation.openRecord(completed.record.id)
        store.investigation.editChatQuestion("")
        checks.append(["name": "empty-edit-keeps-completed-exchange", "passed": store.investigation.responseComplete
            && store.investigation.question == completed.record.question && store.investigation.recordID == completed.record.id])
        store.investigation.editChatQuestion("Et dans le deuxième worktree ?")
        checks.append(["name": "typing-followup-keeps-chat-and-frozen-context-without-send", "passed":
            !store.investigation.sending && !store.investigation.responseComplete && store.investigation.response == nil
            && store.investigation.question == "Et dans le deuxième worktree ?"
            && store.investigation.codexChatID == "66666666-6666-4666-8666-666666666666"
            && store.investigation.capsule?.digestSHA256 == capsule.digestSHA256])
        try await Task.sleep(for: .milliseconds(750))
        let original = try await store.investigation.archive.load(id: completed.record.id)
        checks.append(["name": "followup-never-overwrites-answered-archive", "passed":
            original?.question == completed.record.question && original?.response == answer])
        let draftID = store.investigation.recordID
        checks.append(["name": "followup-saves-distinct-local-draft", "passed": draftID != nil && draftID != completed.record.id
            && store.investigation.isCurrentDraftSaved])
        let records = try await store.investigation.archive.list()
        let selection = InvestigationTranscriptSelection(rootID: capsule.rootThreadID,
            chatID: "66666666-6666-4666-8666-666666666666", currentRecordID: draftID,
            currentCreatedAt: records.first { $0.id == draftID }?.createdAt, recordIDs: records.map(\.id), language: "fr")
        let history = try await InvestigationTranscriptReader.shared.read(archive: store.investigation.archive,
            selection: selection, offset: 0, retainedBytes: 0)
        checks.append(["name": "followup-retains-previous-exchange-and-citation-target", "passed":
            history.exchanges.count == 1 && history.exchanges.first?.question == completed.record.question
            && history.exchanges.first?.validCitationIDs.contains("E001") == true])
        let unrelatedID = "77777777-7777-4777-8777-777777777777"
        for ordinal in 0..<13 {
            let other = try await store.investigation.archive.save(capsule: capsule, question: "Other chat \(ordinal)", codexChatID: unrelatedID)
            _ = try await store.investigation.archive.updateResponse(id: other.record.id, response: "Anonymous unrelated response.")
        }
        let mixed = try await store.investigation.archive.list()
        let routedIDs = InvestigationView.transcriptRecordIDs(mixed, chatID: "66666666-6666-4666-8666-666666666666")
        checks.append(["name": "unrelated-chats-do-not-hide-first-history-page", "passed": routedIDs == [completed.record.id]])
        await store.investigation.openRecord(completed.record.id)
        store.investigation.sending = true
        store.investigation.editChatQuestion("Should not replace active answer")
        checks.append(["name": "typing-is-ignored-while-sending", "passed": store.investigation.question == completed.record.question
            && store.investigation.responseComplete])
        store.investigation.sending = false
        let unlinked = try await store.investigation.archive.save(capsule: capsule, question: completed.record.question)
        _ = try await store.investigation.archive.updateResponse(id: unlinked.record.id, response: answer)
        await store.investigation.openRecord(unlinked.record.id)
        store.investigation.editChatQuestion("Must not silently-switch-API-chat")
        checks.append(["name": "completed-unlinked-chat-is-not-silently-reused", "passed":
            store.investigation.question == completed.record.question && store.investigation.responseComplete])
        await store.investigation.openRecord(completed.record.id)
        store.investigation.capsule = capsule
        store.investigation.connectionMode = .api // RAM fixture only; never selected by the production UI.
        store.investigation.apiKey = "fixture-only-never-sent"
        store.investigation.model = String(repeating: "anonymous-very-long-model-name-", count: 4)

        let originalQuestion = store.investigation.question
        let originalDigest = capsule.digestSHA256
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                for size in [NSSize(width: 320, height: 520), NSSize(width: 460, height: 760)] {
                    store.fontSize = size.width == 320 ? 20 : 13
                    for expanded in [false, true] {
                        let name = "sidechat-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))-\(expanded ? "expanded" : "compact")"
                        let view = InvestigationView(investigator: store.investigation,
                            initiallyExpandedEvidence: expanded)
                            .environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
                        let result = try await render(AnyView(view), size: size, name: name, dark: dark, output: output)
                        renders.append(result)
                        checks.append(["name": name + "-editor-contained", "passed": result["editorContained"] as? Bool == true])
                        checks.append(["name": name + "-no-send-or-context-change", "passed": !store.investigation.sending
                            && store.investigation.codexChatID == "66666666-6666-4666-8666-666666666666" && store.investigation.question == originalQuestion
                            && store.investigation.capsule?.digestSHA256 == originalDigest])
                    }
                }
            }
        }
        // Exercise the real AppKit workspace host without the SwiftUI Scene
        // toolbar. Full MainView detached-window probes hit toolbar-family
        // assertions on this SDK; the actual root is checked via production CUA.
        store.fontSize = 13
        LensL10n.language = .en
        for size in [NSSize(width: 661, height: 780), NSSize(width: 1243, height: 900)] {
            let name = "native-workspace-chat-\(Int(size.width))"
            let workspace = LensNativeWorkspaceSplit(panes: [
                LensNativeWorkspacePane(id: "content", minimum: 340, maximum: nil,
                    content: AnyView(Text("Anonymous central content").frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity))),
                LensNativeWorkspacePane(id: "auxiliary", minimum: 320, maximum: 900,
                    content: AnyView(InvestigationView(investigator: store.investigation).environmentObject(store)
                        .frame(minWidth: 320, maxWidth: 900, maxHeight: .infinity)))
            ])
            let result = try await render(AnyView(workspace), size: size,
                name: name, dark: false, output: output)
            renders.append(result)
            checks.append(["name": name + "-editor-contained", "passed": result["editorContained"] as? Bool == true])
            checks.append(["name": name + "-both-panes-contained", "passed": result["workspacePanesContained"] as? Bool == true])
            checks.append(["name": name + "-retains-chat-context", "passed": store.investigation.question == originalQuestion
                && store.investigation.capsule?.digestSHA256 == originalDigest])
        }
        let emptyStore = LensStore(sourceHome: output.appendingPathComponent("empty-chat-home"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("empty-chat-archive")),
            cacheDirectory: output.appendingPathComponent("empty-chat-cache"))
        await emptyStore.investigation.loadArchive(rootID: "anonymous-empty-conversation")
        emptyStore.investigation.editChatQuestion("Bonjour, discutons de cette session.\nPuis-je ajouter un diff ensuite ?")
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                let name = "empty-chat-\(language.rawValue)-\(dark ? "dark" : "light")"
                let result = try await render(AnyView(InvestigationView(investigator: emptyStore.investigation).environmentObject(emptyStore)),
                    size: NSSize(width: 320, height: 520), name: name, dark: dark, output: output)
                renders.append(result)
                checks.append(["name": name + "-editor-contained", "passed": result["editorContained"] as? Bool == true])
                checks.append(["name": name + "-keeps-unattached-draft-without-send", "passed":
                    emptyStore.investigation.question.contains("Bonjour") && emptyStore.investigation.capsule?.pieces.isEmpty == true
                    && !emptyStore.investigation.sending && emptyStore.investigation.codexChatID == nil])
            }
        }
        emptyStore.stopObserving(); await emptyStore.investigation.flushAndStop()
        // Produce an anonymous archive through the production archive API for
        // the genuine production-binary inspection. No inference is performed.
        let corpusURL = URL(fileURLWithPath: CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--corpus")! + 1])
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL.appendingPathComponent("corpus-manifest.json"))) as! [String: Any]
        let rootID = corpus["rootID"] as! String
        let qa = InvestigationArchive(directory: output.appendingPathComponent("production-chat-fixture"))
        let qaCapsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: cut, pieces: pieces, createdAt: cut)
        let first = try await qa.save(capsule: qaCapsule, question: "Quel libellé change dans ce diff ?",
            codexChatID: "66666666-6666-4666-8666-666666666666")
        _ = try await qa.updateResponse(id: first.record.id, response: answer)
        let second = try await qa.save(capsule: qaCapsule, question: "Peut-on connaître le contenu complet avant cette action ?",
            codexChatID: "66666666-6666-4666-8666-666666666666")
        _ = try await qa.updateResponse(id: second.record.id, response: "Seul le fragment du patch est disponible. Le fichier complet avant l’action n’a pas été enregistré. [E002]\n\n- Le chemin appartient au worktree Alpha.\n- Le contenu courant ne remplace pas cette version.")
        try Data("Anonymous local archive; no model inference.\n".utf8).write(to: output.appendingPathComponent("ANONYMOUS_CHAT_FIXTURE"))
        store.stopObserving(); await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual source-matched detached NSHostingView chat bitmaps and native editable text-view frames, with synthetic local response, twelve frozen evidence pieces, long model label, and expanded disclosures. Activation prohibited; no visible window or Dock item; no inference or credentials.",
            "unqualified": ["Production compositor capture", "Physical pointer and keyboard", "VoiceOver", "Send/cancellation or authenticated inference"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    @MainActor private static func render(_ view: AnyView, size: NSSize, name: String, dark: Bool, output: URL) async throws -> [String: Any] {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .textBackgroundColor)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<25 {
            await Task.yield(); try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        var queue = [host as NSView], index = 0, editorFrames: [CGRect] = [], paneFrames: [CGRect] = []
        while index < queue.count {
            let view = queue[index]; index += 1
            if view is NSHostingView<LensNativeWorkspaceSplit.PaneRoot> {
                paneFrames.append(host.convert(view.bounds, from: view))
            }
            if let editor = view as? NSTextView, editor.isEditable {
                // Document height can grow while editing. The enclosing clip
                // view is the actual readable/interactive editor viewport.
                let viewport: NSView
                if let clip = editor.enclosingScrollView?.contentView { viewport = clip }
                else { viewport = editor }
                editorFrames.append(host.convert(viewport.bounds, from: viewport))
            }
            queue.append(contentsOf: view.subviews)
        }
        let contained = !editorFrames.isEmpty && editorFrames.allSatisfy {
            $0.width > 0 && $0.height >= 20 && host.bounds.insetBy(dx: -1, dy: -1).contains($0)
        }
        return ["file": name + ".png", "width": size.width, "height": size.height,
            "editorContained": contained,
            "workspacePanesContained": paneFrames.count == 2 && paneFrames.allSatisfy {
                $0.width >= 319 && $0.height > 0 && host.bounds.insetBy(dx: -1, dy: -1).contains($0)
            },
            "nativeWorkspacePaneFrames": paneFrames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            "nativeEditorViewportFrames": editorFrames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            "method": "Own offscreen NSHostingView bitmap and native NSTextView viewport; not a production screenshot"]
    }
}
