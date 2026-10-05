import AppKit
import Foundation
import LensCore
import SwiftUI

/// Actual source-matched Markdown components on anonymous, immutable evidence.
/// Detached windows only: no Dock item, Codex process, authentication, inference,
/// network, clipboard write, observed file read, or operating-system input.
@main struct MarkdownV35Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Markdown v35 qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else {
            throw LensError.unavailable("Missing --output")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let cut = Date(timeIntervalSince1970: 1_759_320_000)
        let piece = EvidencePiece(id: "E001", kind: "recordedDiff", title: "Sources/Anonymous.swift",
            text: "-let title = \"old\"\n+let title = \"capturé\"\n", environmentID: "/anonymous/worktrees/alpha",
            knownVersion: "anonymous-captured-v1", capturedAt: cut)
        let capsule = try EvidenceCapsule.build(rootThreadID: "anonymous-markdown-root", collectionCut: cut,
            pieces: [piece], omissions: [], createdAt: cut)
        let address = try EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: piece.id)
        let links = [piece.id: address.url]
        let code = "let title = \"capturé — é / 東京\"\nlet longValue = \"" + String(repeating: "Unicode-é-", count: 70) + "\"\n"
        let rich = """
        # Origine du changement — Change origin

        Le **diff enregistré** contient `title`. Séparez les faits de leur *interprétation*. [E001] ouvre le diff ; [E999] n’a pas de source.

        - Instruction directe / Direct instruction
          - Contexte hérité / Inherited context
        - Correction ultérieure / Later correction

        1. Lire la version capturée / Read the captured version
        2. Revenir à la source / Return to source

        > Texte enregistré / Recorded text
        > Aucune lecture du fichier actuel / No current file read

        | Version | Disponibilité / Availability |
        | :--- | ---: |
        | Capturée / Captured | [E001] |
        | Courante / Current | Non consultée / Not read |

        ---

        [Documentation explicite / Explicit documentation](https://example.invalid/anonymous-documentation) ; [lien non sûr / unsafe link](javascript:alert(1)).

        ![Image distante non chargée / Remote image not loaded](https://example.invalid/anonymous-image.png)

        ```swift
        \(code)```
        """
        let incomplete = """
        ## Réponse progressive — Streaming response

        **Fait enregistré / Recorded fact** [E001]. La citation absente [E999] reste du texte.

        ```swift
        \(code)
        """
        let richDocument = try ChatMarkdownParser.parse(rich, evidenceLinks: links)
        let incompleteDocument = try ChatMarkdownParser.parse(incomplete, evidenceLinks: links)
        var checks: [[String: Any]] = [], renders: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }

        check("rich-source-is-unaltered", richDocument.source == rich)
        check("incomplete-source-is-unaltered", incompleteDocument.source == incomplete)
        check("known-citation-resolves-exact-frozen-piece", try address.resolve(in: capsule) == capsule.pieces[0])
        let richLinks = attributedLinks(in: richDocument)
        check("known-citation-retains-exact-evidence-url", richLinks.contains(address.url))
        check("unknown-citation-never-becomes-evidence-url", !richLinks.contains { $0.scheme == "codexlens" && $0 != address.url })
        check("unknown-citation-is-visible-unlinked-text", richDocument.blocks.contains { block in
            block.text.runs.contains { run in String(block.text[run.range].characters).contains("E999") && run.link == nil }
        })
        check("unsafe-link-never-becomes-active", richLinks.allSatisfy { ["https", "http", "codexlens"].contains($0.scheme?.lowercased() ?? "") })
        check("explicit-https-link-is-preserved", richLinks.contains(URL(string: "https://example.invalid/anonymous-documentation")!))
        check("remote-image-has-no-renderable-image-attribute", richDocument.blocks.allSatisfy { block in
            block.text.runs.allSatisfy { $0.imageURL == nil }
                && (block.table?.rows.flatMap { $0 }.allSatisfy { $0.runs.allSatisfy { $0.imageURL == nil } } ?? true)
        })
        check("remote-image-reference-retains-explicit-https-action", richLinks.contains(URL(string: "https://example.invalid/anonymous-image.png")!))
        check("rich-has-heading-and-table", richDocument.blocks.contains { if case .heading = $0.kind { return true }; return false }
            && richDocument.blocks.contains { if case .table = $0.kind { return true }; return false })
        let richCode = richDocument.blocks.filter { if case .code = $0.kind { return true }; return false }.map { String($0.text.characters) }
        let incompleteCode = incompleteDocument.blocks.filter { if case .code = $0.kind { return true }; return false }.map { String($0.text.characters) }
        check("code-retains-unicode-and-entire-long-line", richCode.contains(code))
        check("incomplete-fence-retains-code-without-fabricated-close", incompleteCode.contains { $0.contains(code) && !$0.contains("```") })

        let oversizedSource = String(repeating: "m", count: ChatMarkdownParser.maximumFormattedSourceBytes + 1)
        let oversized = try ChatMarkdownParser.parse(oversizedSource, evidenceLinks: links)
        check("oversized-formatting-fallback-preserves-complete-source", oversized.source == oversizedSource
            && oversized.fallbackReason != nil && oversized.blocks.first?.plainText == oversizedSource)
        let cache = InvestigationPresentationCache()
        let input = InvestigationPresentationInput(rootID: capsule.rootThreadID, capsuleID: capsule.id,
            capsuleDigest: capsule.digestSHA256, response: rich, question: "Anonymous fixture question", model: "fixture",
            includePayload: false, connectionMode: "codex", language: "fr")
        let prepared = try await cache.prepare(capsule: capsule, input: input)
        check("presentation-parser-executes-off-main-thread", prepared.preparedOffMainThread)
        check("presentation-markdown-keeps-source-and-exact-frozen-citation", prepared.markdownResponse?.source == rich
            && prepared.markdownResponse.map { attributedLinks(in: $0).contains(address.url) } == true)
        var englishInput = input; englishInput.language = "en"
        let preparedEnglish = try await cache.prepare(capsule: capsule, input: englishInput)
        check("presentation-cache-distinguishes-image-label-language", preparedEnglish.markdownResponse?.blocks.contains {
            $0.plainText.contains("Image reference:")
        } == true && prepared.markdownResponse?.blocks.contains { $0.plainText.contains("Référence d’image :") } == true)
        for ordinal in 1...6 {
            let variant = InvestigationPresentationInput(rootID: capsule.rootThreadID, capsuleID: capsule.id,
                capsuleDigest: capsule.digestSHA256, response: rich + "\n\nAnonymous variant \(ordinal)",
                question: "Anonymous fixture question", model: "fixture", includePayload: false, connectionMode: "codex", language: "fr")
            _ = try await cache.prepare(capsule: capsule, input: variant)
        }
        let retainedCount = await cache.retainedRepresentationCount
        let retainedBytes = await cache.estimatedRetainedBytes
        check("presentation-cache-obeys-retention-budgets", retainedCount <= 4 && retainedBytes <= 2 * 1024 * 1024)
        let cancelled = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await cache.prepare(capsule: capsule, input: input); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        check("cancelled-presentation-never-returns-cached-result", await cancelled.value)

        let callbacks = MarkdownV35Callbacks()
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            let imageLabel = language == .en ? "Image reference:" : "Référence d’image :"
            let fixtures: [(String, ChatMarkdownDocument)] = [
                ("rich", try ChatMarkdownParser.parse(rich, evidenceLinks: links, imageReferenceLabel: imageLabel)),
                ("incomplete", try ChatMarkdownParser.parse(incomplete, evidenceLinks: links, imageReferenceLabel: imageLabel))]
            for dark in [false, true] {
                for size in [NSSize(width: 320, height: 720), NSSize(width: 460, height: 900)] {
                    for fixture in fixtures {
                        let name = "markdown-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))-\(fixture.0)"
                        let view = MarkdownV35Fixture(document: fixture.1, fontSize: 13, callbacks: callbacks)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let result = try await render(AnyView(view), size: size, name: name,
                            appearance: dark ? .darkAqua : .aqua, output: output)
                        renders.append(result)
                        check(name + "-viewports-contained-horizontally", result["visibleClipViewportsContained"] as? Bool == true)
                        check(name + "-passive-display", callbacks.copyCodeCount == 0 && callbacks.openURLCount == 0)
                    }
                }
            }
        }
        // Named high-contrast NSAppearance fixtures do not alter accessibility
        // preferences. Public environment keys are observed, never overridden.
        LensL10n.language = .en
        let richEnglishDocument = try ChatMarkdownParser.parse(rich, evidenceLinks: links, imageReferenceLabel: "Image reference:")
        for dark in [false, true] {
            let name = "markdown-en-\(dark ? "dark" : "light")-320-high-contrast"
            let view = MarkdownV35Fixture(document: richEnglishDocument, fontSize: 18, callbacks: callbacks)
                .environment(\.colorScheme, dark ? .dark : .light)
            let result = try await render(AnyView(view), size: NSSize(width: 320, height: 720), name: name,
                appearance: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua, output: output)
            renders.append(result)
            check(name + "-viewports-contained-horizontally", result["visibleClipViewportsContained"] as? Bool == true)
            check(name + "-passive-display", callbacks.copyCodeCount == 0 && callbacks.openURLCount == 0)
        }

        check("connection-hint-explicit-french", InvestigationConnectionMode.codex.setupInstruction(in: .fr) == "Utilisez votre connexion Codex et choisissez un modèle.")
        check("connection-hint-explicit-english", InvestigationConnectionMode.codex.setupInstruction(in: .en) == "Use your Codex connection and choose a model.")

        let store = LensStore(sourceHome: output.appendingPathComponent("empty-home"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")),
            cacheDirectory: output.appendingPathComponent("own-cache"))
        store.investigation.capsule = capsule
        store.investigation.question = "Explique la modification capturée sans relire le fichier actuel."
        store.investigation.response = rich
        store.investigation.model = "anonymous-local-fixture"
        let originalQuestion = store.investigation.question
        let originalDigest = capsule.digestSHA256
        let savedMaterial = UserDefaults.standard.object(forKey: "lensTabMaterial")
        defer {
            if let savedMaterial { UserDefaults.standard.set(savedMaterial, forKey: "lensTabMaterial") }
            else { UserDefaults.standard.removeObject(forKey: "lensTabMaterial") }
        }
        for language in [LensL10n.Language.fr, .en] {
          for material in ["system", "opaque"] {
            UserDefaults.standard.set(material, forKey: "lensTabMaterial")
            LensL10n.language = language
            UserDefaults.standard.set(language.rawValue, forKey: "lens.language")
            let name = "markdown-chat-\(language.rawValue)-dark-320-\(material)"
            let view = InvestigationView(investigator: store.investigation)
                .environmentObject(store).environment(\.colorScheme, .dark)
            let result = try await render(AnyView(view), size: NSSize(width: 320, height: 720), name: name,
                appearance: .darkAqua, output: output)
            renders.append(result)
            check(name + "-viewports-contained-horizontally", result["visibleClipViewportsContained"] as? Bool == true)
            check(name + "-editor-contained", result["nativeTextEditorContained"] as? Bool == true)
            check(name + "-frozen-draft-and-no-send", !store.investigation.sending && store.investigation.codexChatID == nil
                && store.investigation.question == originalQuestion && store.investigation.capsule?.digestSHA256 == originalDigest)
          }
        }
        store.stopObserving(); await store.investigation.flushAndStop()
        renders += try await renderCopyV37(output: output)
        check("no-render-callbacks-ever-invoked", callbacks.copyCodeCount == 0 && callbacks.openURLCount == 0)
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual source-matched detached NSHostingView Markdown and investigation-chat bitmaps with anonymous frozen evidence. Real ScrollView viewports measured using own NSView APIs. Unicode and long code lines, nested lists, headings, quotes, table, valid/unknown citations, explicit and unsafe URLs, remote image marker, and incomplete fence. Activation prohibited, no clipboard or URL callback activation.",
            "accessibilityScope": "Named standard/high-contrast NSAppearance fixtures; actual public contrast and reduce-transparency environment values observed. System settings are not changed and read-only environment keys are not injected.",
            "unqualified": ["Production compositor capture", "Physical pointer and keyboard", "VoiceOver", "System Reduce Transparency/Increase Contrast preferences", "Network/authenticated inference, send/cancellation", "Full interaction in section/help previews", "All offscreen block frames or unrestricted HTML/CommonMark conformance"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    private static func attributedLinks(in document: ChatMarkdownDocument) -> [URL] {
        document.blocks.flatMap { block -> [URL] in
            let inline = block.text.runs.compactMap { $0.link }
            let cells = block.table?.rows.flatMap { $0 }.flatMap { $0.runs.compactMap { $0.link } } ?? []
            return inline + cells
        }
    }

    /// Native help illustrations and section previews, scoped to the anonymous corpus.
    /// No operating-system input, network, inference or observed user session.
    @MainActor private static func renderCopyV37(output: URL) async throws -> [[String: Any]] {
        guard let i = CommandLine.arguments.firstIndex(of: "--corpus"), i + 1 < CommandLine.arguments.count else { throw LensError.unavailable("Missing corpus") }
        let corpus = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let data = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any], fixture["anonymous"] as? Bool == true,
              let home = fixture["home"] as? String, let rootID = fixture["rootID"] as? String else { throw LensError.unavailable("Anonymous corpus required") }
        let current = LensStore(sourceHome: URL(fileURLWithPath: home), investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("copy-archive")), cacheDirectory: output.appendingPathComponent("copy-cache"))
        current.setNavigationScope(UUID().uuidString)
        UserDefaults.standard.set(true, forKey: LensOnboardingState.preferenceKey)
        await current.start(); await current.open(rootID); await current.waitForPresentation()
        guard let snapshot = current.snapshot, snapshot.root.id == rootID, current.error == nil,
              let call = snapshot.events.first(where: { $0.kind == .toolCall }),
              let change = snapshot.changes.first(where: { $0.path.hasSuffix("/Same.swift") && $0.kind == .requestedPatch }) else { throw LensError.unavailable("Anonymous session is incomplete") }
        let context = LensWindowContext(store: current)
        let size = NSSize(width: 1440, height: 900)
        var results: [[String: Any]] = []
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language; UserDefaults.standard.set(language.rawValue, forKey: "lens.language")
            let dark = language == .en
            let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
            UserDefaults.standard.set(dark ? "dark" : "light", forKey: "lensAppearance")
            func mainView() -> AnyView { AnyView(MainView().environmentObject(current).environment(\.lensWindowContext, context).environment(\.colorScheme, dark ? .dark : .light)) }
            current.showSessionPicker = false; current.inspectorVisible = false; current.chatVisible = false; current.resetFilters()
            results.append(try await render(AnyView(SessionPickerView().environmentObject(current).environment(\.colorScheme, dark ? .dark : .light)), size: NSSize(width: 820, height: 600), name: "help-opening-" + language.rawValue, appearance: appearance, output: output))
            current.browseSection(.activity); current.navigate(.event(call.id)); current.inspectorVisible = true
            await current.waitForPresentation()
            results.append(try await render(mainView(), size: size, name: "help-activity-" + language.rawValue, appearance: appearance, output: output))
            current.navigate(.change(change.id)); current.inspectorVisible = false
            await current.waitForPresentation()
            results.append(try await render(mainView(), size: size, name: "help-proof-" + language.rawValue, appearance: appearance, output: output))
            guard await current.prepareInvestigation(for: .change(change.id)) else { throw LensError.unavailable("Context preparation failed") }
            current.navigate(.change(change.id)); current.chatVisible = true
            current.investigation.question = language == .fr ? "Quelles instructions expliquent ce changement ? Compare les versions dans le worktree Alpha." : "Which instructions explain this change? Compare the versions in worktree Alpha."
            results.append(try await render(mainView(), size: size, name: "help-investigation-" + language.rawValue, appearance: appearance, output: output))
            current.chatVisible = false; current.inspectorVisible = false
            for section in [LensSection.agents, .calls, .environments, .resources] {
                current.browseSection(section); await current.waitForPresentation()
                results.append(try await render(mainView(), size: size, name: "copy-section-" + section.id + "-" + language.rawValue, appearance: appearance, output: output))
            }
        }
        current.stopObserving(); await current.investigation.flushAndStop()
        return results
    }

    @MainActor private static func render(_ view: AnyView, size: NSSize, name: String,
        appearance: NSAppearance.Name, output: URL) async throws -> [String: Any] {
        let observation = MarkdownV35EnvironmentObservationState()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .textBackgroundColor))
            .background(MarkdownV35EnvironmentObservation(state: observation)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<30 {
            await Task.yield(); try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        var queue = [host as NSView], index = 0, clips: [[String: Any]] = [], editorFrames: [CGRect] = []
        while index < queue.count {
            let view = queue[index]; index += 1
            if let editor = view as? NSTextView, editor.isEditable {
                let viewport = editor.enclosingScrollView?.contentView ?? editor
                editorFrames.append(host.convert(viewport.bounds, from: viewport))
            }
            if let clip = view as? NSClipView, clip.bounds.width > 1, clip.bounds.height > 1 {
                let frame = host.convert(clip.bounds, from: clip)
                // Child documents may legitimately exceed the viewport for
                // horizontal scrolling or sit below the vertical viewport.
                if frame.maxY > host.bounds.minY, frame.minY < host.bounds.maxY {
                    clips.append(["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                        "containedHorizontally": frame.minX >= -1 && frame.maxX <= host.bounds.maxX + 1])
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return ["file": name + ".png", "width": size.width, "height": size.height,
            "visibleClipViewportsContained": !clips.isEmpty && clips.allSatisfy { $0["containedHorizontally"] as? Bool == true },
            "nativeVisibleClipViewportFrames": clips,
            "nativeTextEditorContained": !editorFrames.isEmpty && editorFrames.allSatisfy {
                $0.width > 0 && $0.height >= 20 && host.bounds.insetBy(dx: -1, dy: -1).contains($0)
            },
            "nativeTextEditorViewportFrames": editorFrames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            "observedContrast": observation.contrast ?? "not-observed",
            "observedReduceTransparency": observation.reduceTransparency.map { $0 as Any } ?? NSNull(),
            "namedAppearance": appearance.rawValue,
            "method": "Own offscreen NSHostingView bitmap and visible NSClipView frames; not a production screenshot"]
    }
}

@MainActor private final class MarkdownV35Callbacks {
    var copyCodeCount = 0
    var openURLCount = 0
}

@MainActor private struct MarkdownV35Fixture: View {
    let document: ChatMarkdownDocument
    let fontSize: Double
    let callbacks: MarkdownV35Callbacks
    var body: some View {
        ScrollView {
            LensChatMarkdownView(document: document, fontSize: fontSize,
                onCopyCode: { _ in callbacks.copyCodeCount += 1 }, onOpenURL: { _ in callbacks.openURLCount += 1 })
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

@MainActor private final class MarkdownV35EnvironmentObservationState {
    var contrast: String?
    var reduceTransparency: Bool?
}

@MainActor private struct MarkdownV35EnvironmentObservation: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let state: MarkdownV35EnvironmentObservationState
    var body: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true).onAppear {
            state.contrast = contrast == .increased ? "increased" : "standard"
            state.reduceTransparency = reduceTransparency
        }
    }
}
