import AppKit
import Foundation
import LensCore
import SwiftUI

/// Native chat variants on frozen anonymous evidence. No visible window, Dock
/// item, Codex process, credential query, network request or observed source.
@main struct ChatCodeV69Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Context chat v68 qualification failed: \(error)\n", stderr) }
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
        fresh.automaticCodexCheckEnabled = false
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
        store.investigation.automaticCodexCheckEnabled = false
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
        emptyStore.investigation.automaticCodexCheckEnabled = false
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
        let context = try ChatContextOverview(capsule: capsule)
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                let sourcesView = LensChatSourcesView(sources: Array(context.sources.prefix(3)),
                    title: LensL10n.text("Sources citées · {0}", "3"), canReuse: true, initiallyExpanded: true,
                    onOpen: { _ in }, onReuse: { _ in })
                let sourceRender = try await render(AnyView(sourcesView.padding(16)), size: NSSize(width: 320, height: 520),
                    name: "sources-\(language.rawValue)-\(dark ? "dark" : "light")", dark: dark, output: output)
                renders.append(sourceRender)
                checks.append(["name": "source-render-\(language.rawValue)-\(dark)", "passed": sourceRender["width"] as? CGFloat == 320])
            }
        }
        LensL10n.language = .fr
        let requests = ContextProbeCounter()
        let auto = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("auto-archive")), statusProvider: { _ in
            await requests.increment()
            throw LensError.unavailable("Anonymous connection fixture")
        })
        auto.ensureChatContext(rootID: "anonymous-auto-check")
        auto.editChatQuestion("Mon brouillon")
        let digest = auto.capsule?.digestSHA256
        await auto.refreshConnection(); await auto.refreshConnection()
        let countAfterAppear = await requests.value
        checks.append(["name": "automatic-metadata-check-once-and-retains-draft", "passed": countAfterAppear == 1 && auto.question == "Mon brouillon" && auto.capsule?.digestSHA256 == digest && !auto.sending])
        auto.useLocalCodex()
        for _ in 0..<30 where auto.connecting { try await Task.sleep(for: .milliseconds(10)) }
        let countAfterRetry = await requests.value
        checks.append(["name": "explicit-connection-retry-without-message", "passed": countAfterRetry == 2 && !auto.connecting && !auto.sending && auto.question == "Mon brouillon"])
        await auto.flushAndStop()
        await store.investigation.openRecord(completed.record.id)
        let beforePrompt = store.investigation.capsule?.digestSHA256
        store.investigation.prepareChatPrompt(.instructions)
        checks.append(["name": "suggestion-prepares-followup-without-send", "passed": store.investigation.question == LensChatPrompt.instructions.question && !store.investigation.responseComplete && !store.investigation.sending && store.investigation.capsule?.digestSHA256 == beforePrompt])
        store.investigation.editChatQuestion("Ma correction")
        store.investigation.prepareChatPrompt(.missing)
        checks.append(["name": "suggestion-preserves-existing-draft", "passed": store.investigation.question.hasPrefix("Ma correction\n\n") && !store.investigation.sending])
        checks.append(["name": "history-source-links-retain-exact-question-version", "passed": history.exchanges.first?.context.sources.first?.address.capsuleID == capsule.id && history.exchanges.first?.citedSources.first?.address.pieceID == "E001"])
        checks.append(["name": "application-open-target-is-enclosing-bundle", "passed": CodexLocalConnectionView.applicationURL(executable: "/Applications/Codex.app/Contents/Resources/codex")?.path == "/Applications/Codex.app" && CodexLocalConnectionView.applicationURL(executable: "/opt/homebrew/bin/codex") == nil])
        if let corpusIndex = CommandLine.arguments.firstIndex(of: "--corpus"), corpusIndex + 1 < CommandLine.arguments.count {
            let corpus = URL(fileURLWithPath: CommandLine.arguments[corpusIndex + 1])
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as! [String: Any]
            let rootID = manifest["rootID"] as! String
            let linked = LensStore(sourceHome: URL(fileURLWithPath: manifest["home"] as! String),
                investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("reuse-source-archive")),
                cacheDirectory: output.appendingPathComponent("reuse-source-cache"))
            linked.investigation.automaticCodexCheckEnabled = false
            await linked.start()
            await linked.open(rootID)
            let alpha = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: cut, pieces: [EvidencePiece(id: "E001", kind: "verifiedHistoricalCode", title: "src/Same.swift", text: "frozen alpha", environmentID: "/anonymous/alpha", knownVersion: "alpha-old", location: EvidenceLocation(environmentID: "/anonymous/alpha", path: "src/Same.swift", versionKind: .verifiedGitBlob, version: "alpha-old"))])
            let beta = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: cut, pieces: [EvidencePiece(id: "E001", kind: "recordedPatch", title: "src/Same.swift", text: "frozen beta patch", environmentID: "/anonymous/beta", location: EvidenceLocation(environmentID: "/anonymous/beta", path: "src/Same.swift", versionKind: .recordedFragment))])
            let savedAlpha = try await linked.investigation.archive.save(capsule: alpha, question: "Archived alpha")
            _ = try await linked.investigation.archive.save(capsule: beta, question: "Archived beta")
            let alphaAddress = try EvidenceAddress(rootID: rootID, capsuleID: alpha.id, pieceID: "E001")
            let betaAddress = try EvidenceAddress(rootID: rootID, capsuleID: beta.id, pieceID: "E001")
            await linked.reuseChatSource(alphaAddress); await linked.reuseChatSource(betaAddress)
            let attached = linked.investigation.capsule?.pieces ?? []
            checks.append(["name": "reuse-archived-source-keeps-distinct-worktree-versions-without-send", "passed":
                attached.count == 2 && attached.map(\.text) == ["frozen alpha", "frozen beta patch"]
                && attached.map(\.environmentID) == ["/anonymous/alpha", "/anonymous/beta"]
                && attached[0].knownVersion == "alpha-old" && attached[1].knownVersion == nil && !linked.investigation.sending])
            let unchanged = try await linked.investigation.archive.load(id: savedAlpha.record.id)
            checks.append(["name": "reuse-does-not-overwrite-answered-source-context", "passed": unchanged?.capsule.digestSHA256 == alpha.digestSHA256])
            await linked.openEvidence(alphaAddress)
            checks.append(["name": "source-opens-exact-archived-capsule-in-main-navigation", "passed": linked.inspectedEvidenceCapsule?.id == alpha.id && linked.selection == .evidence(capsule: alpha.id, piece: "E001")])
            let currentDigest = linked.investigation.capsule?.digestSHA256
            let wrongRoot = try EvidenceAddress(rootID: "wrong-root", capsuleID: beta.id, pieceID: "E001")
            await linked.reuseChatSource(wrongRoot)
            checks.append(["name": "source-reuse-rejects-another-observed-session", "passed": linked.investigation.capsule?.digestSHA256 == currentDigest])
            linked.stopObserving(); await linked.investigation.flushAndStop()
        }
        await store.investigation.flushAndStop()
        LensL10n.language = .en
        checks.append(["name": "new-context-controls-are-localized", "passed": LensL10n.text("Contexte envoyé · {0}", "2") == "Sent context · 2" && LensL10n.text("Détecter automatiquement") == "Detect automatically"])
        var codeCopies = 0, messageCopies = 0, sourceOpens = 0
        let snippet = try ChatMarkdownParser.parse("```swift\nlet label = \"new\"\n```", evidenceLinks: [:])
        let snippetSources = Array(try ChatContextOverview(capsule: capsule).sources.prefix(1))
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                for width: CGFloat in [320, 460] {
                    let name = "code-short-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width))"
                    let codeView = LensChatMarkdownView(document: snippet, fontSize: 13,
                        onCopyCode: { _ in codeCopies += 1 }, onOpenURL: { _ in sourceOpens += 1 },
                        speaker: "Codex", onCopyMessage: { _ in messageCopies += 1 }, sources: snippetSources)
                    let result = try await render(AnyView(codeView.padding(12)), size: NSSize(width: width, height: 240), name: name, dark: dark, output: output)
                    renders.append(result)
                    let left = result["codeInkLeft"] as? Double
                    checks.append(["name": name + "-left-aligned-by-rendered-glyphs", "passed": left.map { $0 >= 35 && $0 <= 60 } == true])
                    checks.append(["name": name + "-message-toggle-is-not-visible", "passed": !(result["accessibilityIdentifiers"] as? [String] ?? []).contains("lens-chat-markdown-source-toggle")])
                }
            }
        }
        let longCode = try ChatMarkdownParser.parse("```swift\n" + String(repeating: "let longValue = \"", count: 60) + "end\"\n\n" + String(repeating: "print(longValue)\n", count: 80) + "```")
        renders.append(try await render(AnyView(LensChatMarkdownView(document: longCode, fontSize: 13,
            onCopyCode: { _ in codeCopies += 1 }, onOpenURL: { _ in sourceOpens += 1 }).padding(12)),
            size: NSSize(width: 320, height: 500), name: "code-long-fr-light-320", dark: false, output: output))
        checks.append(["name": "code-rendering-does-not-copy-or-open-a-source", "passed": codeCopies == 0 && messageCopies == 0 && sourceOpens == 0])
        checks.append(["name": "code-gutter-prepared-on-model-and-not-copied", "passed": snippet.blocks.first?.codeLineNumbers == "1\n2" && snippet.blocks.first?.plainText == "let label = \"new\"\n"])
        let menuHost = LensChatMessageMenuHost()
        menuHost.document = snippet; menuHost.sources = snippetSources
        var copiedCode = "", toggleCount = 0, openedSource: URL?, copiedMessage = 0
        menuHost.onCopyCode = { copiedCode = $0 }; menuHost.onToggleSource = { toggleCount += 1 }
        menuHost.onOpenURL = { openedSource = $0 }; menuHost.onCopyMessage = { copiedMessage += 1 }
        let frozenMenu = menuHost.makeMenu()
        menuHost.document = try ChatMarkdownParser.parse("```swift\nchanged after menu opening\n```")
        menuHost.sources = []
        for item in frozenMenu.items {
            if item.identifier?.rawValue == "lens-chat-copy-code" { menuHost.invoke(item) }
            if item.identifier?.rawValue == "lens-chat-markdown-source-toggle" { menuHost.invoke(item) }
            if item.identifier?.rawValue == "lens-chat-copy-message" { menuHost.invoke(item) }
            if let source = item.submenu?.items.first { menuHost.invoke(source) }
        }
        checks.append(["name": "native-menu-commands-keep-original-text-and-source-after-streaming", "passed": copiedCode == "let label = \"new\"\n" && openedSource == snippetSources.first?.address.url && toggleCount == 1 && copiedMessage == 1])
        let left = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let secondary = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let controlClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        checks.append(["name": "native-menu-intercepts-only-secondary-and-control-click", "passed": !LensChatMessageMenuHost.isSecondaryClick(left) && LensChatMessageMenuHost.isSecondaryClick(secondary) && LensChatMessageMenuHost.isSecondaryClick(controlClick) && menuHost.hitTest(.zero) == nil])
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
        var identifiers = Set<String>(), visited = Set<ObjectIdentifier>(), codeTextFrames: [[String: Double]] = []
        let hostFrame = host.accessibilityFrame()
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, visited.count < 10_000, let element = object as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            if let id = element.accessibilityIdentifier() {
                identifiers.insert(id)
                if id.hasPrefix("lens-chat-code-text-") {
                    let f = element.accessibilityFrame()
                    codeTextFrames.append(["x": Double(f.minX - hostFrame.minX), "y": Double(f.minY - hostFrame.minY), "width": Double(f.width), "height": Double(f.height)])
                }
            }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        for view in queue { walk(view, depth: 0) }
        return ["file": name + ".png", "width": size.width, "height": size.height,
            "codeInkLeft": (name.hasPrefix("code-short-") ? codeInkLeft(bitmap, width: size.width, dark: dark).map { $0 as Any } : nil) ?? NSNull(),
            "codeTextFrames": codeTextFrames, "accessibilityIdentifiers": identifiers.sorted(),
            "editorContained": contained,
            "workspacePanesContained": paneFrames.count == 2 && paneFrames.allSatisfy {
                $0.width >= 319 && $0.height > 0 && host.bounds.insetBy(dx: -1, dy: -1).contains($0)
            },
            "nativeWorkspacePaneFrames": paneFrames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            "nativeEditorViewportFrames": editorFrames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            "method": "Own offscreen NSHostingView bitmap and native NSTextView viewport; not a production screenshot"]
    }
    /// Inspect our own rendered bitmap, not screen pixels. Detached windows do
    /// not expose SwiftUI AX text frames reliably. Ignore transparent pixels,
    /// gutter digits and the code header; locate the code's first text row by
    /// its glyphs inside the central scan band, then measure its left edge.
    private static func codeInkLeft(_ bitmap: NSBitmapImageRep, width: CGFloat, dark: Bool) -> Double? {
        let scale = Double(bitmap.pixelsWide) / Double(width)
        func ink(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { return false }
            let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            return dark ? luminance > 0.8 : luminance < 0.35
        }
        let scanStart = Int(60 * scale), scanEnd = min(bitmap.pixelsWide, Int(210 * scale))
        var bestRow = 0, bestCount = 0
        for y in 0..<bitmap.pixelsHigh {
            let count = (scanStart..<scanEnd).reduce(0) { $0 + (ink($1, y) ? 1 : 0) }
            if count > bestCount { bestCount = count; bestRow = y }
        }
        guard bestCount > 8 else { return nil }
        for x in Int(35 * scale)..<bitmap.pixelsWide where ink(x, bestRow) { return Double(x) / scale }
        return nil
    }
}

private actor ContextProbeCounter { var value = 0; func increment() { value += 1 } }
