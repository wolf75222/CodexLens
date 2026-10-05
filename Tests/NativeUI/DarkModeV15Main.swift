import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Bounded, source-matched appearance qualification. The launcher replaces
/// production @main, denies networking and never reads a real Codex home.
@main struct DarkModeV15Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let run = DarkModeV15Run()
        Task { @MainActor in
            do { try await run.run() } catch { run.recordFatal(error) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}

@MainActor private final class DarkModeV15RenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct DarkModeV15Appearance {
    let id: String
    let name: NSAppearance.Name
    let dark: Bool
    let increased: Bool
    static let matrix = [
        DarkModeV15Appearance(id: "aqua", name: .aqua, dark: false, increased: false),
        DarkModeV15Appearance(id: "dark-aqua", name: .darkAqua, dark: true, increased: false),
        DarkModeV15Appearance(id: "high-contrast-aqua", name: .accessibilityHighContrastAqua, dark: false, increased: true),
        DarkModeV15Appearance(id: "high-contrast-dark-aqua", name: .accessibilityHighContrastDarkAqua, dark: true, increased: true)
    ]
}

@MainActor private struct DarkModeV15EvidenceFixture: View {
    let document: RecordedDiffDocument
    let errorEvent: LensEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apparence des preuves · fixtures anonymes").font(.headline)
            Text("Les couleurs ne modifient ni le résultat, ni la disponibilité, ni la provenance.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    EventIdentityView(event: errorEvent, agentLabel: "Agent fixture", completeness: .partial)
                    LensLoadStateView(state: .missing(subject: "Pièce jointe", message: "La référence est enregistrée ; ses octets ne sont pas accessibles."))
                    LensLoadStateView(state: .incomplete(subject: "Historique", message: "La période non observée reste inconnue."))
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    LensResourceRowLabel(resource: ResourceRecord(location: "/anonymous/worktrees/alpha/missing.pdf", roles: [.supplied], eventIDs: ["fixture-user"], availability: .missing))
                    LensResourceRowLabel(resource: ResourceRecord(location: "trace:fixture:attachment:1", roles: [.supplied], eventIDs: ["fixture-user"], availability: .unknown))
                    LensResourceRowLabel(resource: ResourceRecord(location: "https://example.invalid/reference", roles: [.referenced], availability: .external))
                    ProvenanceView(certainty: .unknown, explanation: "Auteur du changement non établi ; la proximité temporelle ne prouve aucune causalité.", sourceLabel: "anonymous-trace.jsonl:42")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            RecordedDiffView(document: document, initialProvenanceExpanded: false)
                .frame(minHeight: 400, maxHeight: .infinity)
        }.font(.system(size: 13)).padding(14)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private struct DarkModeV15EnvironmentObservation: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let onObserve: (ColorSchemeContrast, Bool) -> Void
    var body: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            .onAppear { onObserve(contrast, reduceTransparency) }
    }
}

@MainActor private final class DarkModeV15Run {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    private var receipt: [String: Any] = [:]
    private var windows: [NSWindow] = []
    private var stores: [LensStore] = []
    private var investigationStores: [InvestigationStore] = []
    private let baseTime = Date(timeIntervalSince1970: 1_790_863_200)

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let data = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any], manifest["anonymous"] as? Bool == true else {
            throw failure("Corpus must be explicitly anonymous.")
        }
        receipt["startedAt"] = Date().ISO8601Format()
        receipt["scope"] = "Actual product CodeDocumentHost/NSTextView, event NSTableView cells and SwiftUI evidence/diff components in an own NSApplication. Production @main is replaced."
        receipt["entrypoint"] = "DarkModeV15Main.swift"
        receipt["corpusManifestSHA256"] = digest(data)
        receipt["fixtureSource"] = "Deterministic generated code, events, resources and diff. Anonymous corpus manifest read only; session traces are not loaded."
        receipt["networkDeniedByLauncher"] = true
        receipt["realCodexHomeRead"] = false
        receipt["modelRequests"] = 0
        receipt["credentialAccess"] = false
        receipt["systemPreferencesChanged"] = false
        receipt["interactionMethod"] = "Own NSWindow/NSHostingView/NSTextView/NSTableView APIs; no OS input, clipboard or accessibility automation."
        try await qualifyCode()
        try qualifyTextPalette()
        try await qualifySwatches()
        try await qualifyEvidence()
        try await qualifyDraftSaveStates()
        receipt["unqualified"] = [
            "NSHostingView bitmap cache is a native component render, not a compositor screenshot, CUA observation or production startup qualification.",
            "NSAppearance and the public writable colorScheme are set on fixture views only. System Dark Mode, accessibility settings and automatic day/night changes are not changed or exercised.",
            "The public SwiftUI colorSchemeContrast and accessibilityReduceTransparency are read-only in SDK 26.5. This probe observes their actual values but does not inject their underscored writable keys; reduced transparency and actual system Increase Contrast preferences are not exercised.",
            "Contrast ratios are calculated from actual AppKit text attributes resolved in the named appearance, against the editor background. Anti-aliased glyph pixels and every screen in the application are not a comprehensive WCAG or HIG certification.",
            "High-contrast NSAppearance variants may resolve some palette colors identically to ordinary variants on this host. This local appearance fixture is not equivalent to changing macOS accessibility preferences.",
            "VoiceOver, physical keyboard, hover/focus delivery, color-vision simulation, Intel and macOS 14 runtime are not exercised.",
            "Performance, genuine active sessions, provenance reconstruction, model responses and privacy outside this isolated fixture process are outside this bounded probe."
        ]
        receipt["finishedAt"] = Date().ISO8601Format()
        await cleanUp()
        try saveReceipt()
    }

    private func qualifyCode() async throws {
        let first = "let sample = \"enregistré 🧭\" + 42 // commentaire exact café e\u{301}\r\n"
        let text = first + (1...360).map { "let valeur\($0) = \($0) // Contexte enregistré\r\n" }.joined()
        let host = CodeDocumentHost(frame: NSRect(x: 0, y: 0, width: 940, height: 580))
        let window = makeWindow(size: host.bounds.size, title: "Code · appearance qualification (anonymous)")
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.install(text: text, path: "/anonymous/worktrees/alpha/src/Appearance.swift", versionLabel: "Fragment enregistré · fixture-sha-v1", requestedLine: nil,
                     onSelection: nil, onLineNavigate: nil)
        try await settle(host)
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let editor = scroll.documentView as? NSTextView else { throw failure("Actual code reader unavailable.") }
        for _ in 0..<40 {
            if descendants(host).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("Swift") && !$0.stringValue.contains("Indexation") }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check("code-analysis-completed", descendants(host).compactMap({ $0 as? NSTextField }).contains { $0.stringValue.contains("Swift") && !$0.stringValue.contains("Indexation") })
        check("code-readonly-selectable", !editor.isEditable && editor.isSelectable)
        let textNative = text as NSString
        let chosen = textNative.range(of: "enregistré 🧭")
        guard chosen.location != NSNotFound else { throw failure("Selection fixture unavailable.") }
        editor.setSelectedRange(chosen)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 410))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        check("code-nonzero-viewport-established", origin.y > 100)
        let samples = [("keyword", "let"), ("plain-identifier", "sample"), ("string", "enregistré"), ("number", "42"), ("comment", "commentaire")]
        var colorVectors: [String: [String: [Double]]] = [:]
        for appearance in DarkModeV15Appearance.matrix {
            guard let named = NSAppearance(named: appearance.name) else { throw failure("Appearance unavailable: " + appearance.id) }
            window.appearance = named
            try await settle(host)
            check("code-\(appearance.id)-effective-appearance", host.effectiveAppearance.name == named.name)
            check("code-\(appearance.id)-same-editor", scroll.documentView === editor)
            check("code-\(appearance.id)-text-preserved", Data(editor.string.utf8) == Data(text.utf8))
            check("code-\(appearance.id)-selection-preserved", editor.selectedRange() == chosen)
            check("code-\(appearance.id)-viewport-preserved", near(scroll.contentView.bounds.origin, origin))
            guard let storage = editor.textStorage else { throw failure("Text storage unavailable.") }
            let background = try resolved(editor.backgroundColor, appearance: host.effectiveAppearance)
            var resolvedSamples: [[String: Any]] = []
            var vectors: [String: [Double]] = [:]
            for sample in samples {
                let range = textNative.range(of: sample.1)
                guard range.location != NSNotFound, let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor else { throw failure("Actual text color missing: " + sample.0) }
                let foreground = try resolved(color, appearance: host.effectiveAppearance)
                let ratio = contrast(foreground, background)
                vectors[sample.0] = rgba(foreground)
                check("code-\(appearance.id)-\(sample.0)-contrast-at-least-4.5", ratio >= 4.5)
                resolvedSamples.append(["kind": sample.0, "utf16Location": range.location, "foregroundSRGBA": rgba(foreground), "backgroundSRGBA": rgba(background), "contrastRatio": ratio,
                                        "effectiveForegroundSRGBA": composite(rgba(foreground), over: rgba(background)), "contrastMethod": "Foreground alpha composited over opaque sRGB background, then relative luminance",
                                        "source": "Actual NSTextStorage .foregroundColor and NSTextView.backgroundColor, resolved under named NSAppearance"])
            }
            colorVectors[appearance.id] = vectors
            observations.append(["kind": "code", "appearance": appearance.id, "requestedAppearanceName": appearance.name.rawValue, "resolvedNamedAppearance": named.name.rawValue, "effectiveAppearance": host.effectiveAppearance.name.rawValue,
                                 "textSHA256": digest(Data(editor.string.utf8)), "selectionUTF16": [chosen.location, chosen.length],
                                 "viewport": [scroll.contentView.bounds.origin.x, scroll.contentView.bounds.origin.y], "samples": resolvedSamples])
            try capture(host, filename: "dark-code-\(appearance.id).png", scenario: "CodeDocumentHost unchanged during appearance switch", appearance: appearance.id)
        }
        if let light = colorVectors["aqua"], let dark = colorVectors["dark-aqua"] {
            check("code-token-colors-adapt-on-existing-host", samples.allSatisfy { sample in
                guard let a = light[sample.0], let b = dark[sample.0] else { return false }
                return !vectorNear(a, b)
            })
        } else { check("code-token-colors-adapt-on-existing-host", false) }
        host.cancelAnalysis()
        window.close()
    }

    private func qualifySwatches() async throws {
        let store = makeStore("swatch")
        let kinds: [EventKind] = [.user, .assistant, .toolCall, .delegation, .wait, .error, .context]
        let events = kinds.enumerated().map { index, kind in
            LensEvent(id: "fixture-event-\(index)", timestamp: baseTime.addingTimeInterval(Double(index)), agentID: "fixture-agent", kind: kind,
                      title: "Événement \(kind.rawValue)", preview: "Résultat enregistré · fixture sans appel exécuté.", environmentID: "/anonymous/worktrees/alpha", source: SourceRef(path: "anonymous-trace.jsonl", line: index + 1), isError: kind == .error)
        }
        let host = NSHostingView(rootView: EventListView(events: events, title: "Couleurs des événements · fixtures anonymes").environmentObject(store))
        host.sizingOptions = []
        let window = makeWindow(size: NSSize(width: 1000, height: 900), title: "Event swatches · appearance qualification (anonymous)")
        window.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 1000, height: 900)); window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first else { throw failure("Actual event table unavailable.") }
        check("swatch-table-has-all-fixture-events", table.numberOfRows == events.count)
        var swatches: [NSView] = []
        for row in events.indices {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
                  let swatch = cell.subviews.first(where: { $0 is LensEventSwatch }) else { throw failure("Actual swatch missing at row \(row).") }
            swatches.append(swatch)
        }
        var colors: [String: [[Double]]] = [:]
        for appearance in DarkModeV15Appearance.matrix {
            guard let named = NSAppearance(named: appearance.name) else { throw failure("Appearance unavailable.") }
            window.appearance = named
            try await settle(host)
            check("swatches-\(appearance.id)-effective-appearance", host.effectiveAppearance.name == named.name)
            var rowColors: [[Double]] = []
            for (index, swatch) in swatches.enumerated() {
                guard let bitmap = swatch.bitmapImageRepForCachingDisplay(in: swatch.bounds) else { throw failure("Actual swatch bitmap unavailable.") }
                swatch.cacheDisplay(in: swatch.bounds, to: bitmap)
                guard let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) else { throw failure("Actual swatch center pixel unavailable.") }
                // colorAt returns a generic calibrated color even when the
                // bitmap holds this display's Color LCD ICC profile. Preserve
                // that actual bitmap profile before converting its RGB samples.
                guard bitmap.colorSpace.numberOfColorComponents == 3 else { throw failure("Actual swatch bitmap is not RGB.") }
                var samples = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent]
                let sampleCount = samples.count
                let correctlyTagged = NSColor(colorSpace: bitmap.colorSpace, components: &samples, count: sampleCount)
                guard let actual = correctlyTagged.usingColorSpace(.sRGB) else { throw failure("Bitmap-profile sample cannot convert to sRGB.") }
                let expected = try resolved(expectedSwatch(events[index]), appearance: swatch.effectiveAppearance)
                let expectedProfile = try resolved(expectedSwatch(events[index]), appearance: swatch.effectiveAppearance, colorSpace: bitmap.colorSpace)
                guard bitmap.bitsPerSample == 8 else { throw failure("Quantization contract requires the observed native 8-bit bitmap.") }
                let quantizationTolerance = 0.5 / 255.0
                let profileSamples = samples.map { Double($0) }
                let maximumProfileError = zip(profileSamples, rgba(expectedProfile)).map { abs($0.0 - $0.1) }.max() ?? .infinity
                let maximumSRGBError = zip(rgba(actual), rgba(expected)).map { abs($0.0 - $0.1) }.max() ?? .infinity
                check("swatch-\(appearance.id)-\(events[index].kind.rawValue)-matches-resolved-semantic-color", maximumProfileError <= quantizationTolerance)
                guard let currentCell = table.view(atColumn: 0, row: index, makeIfNecessary: false) else { throw failure("Visible event cell disappeared.") }
                check("swatch-\(appearance.id)-\(events[index].kind.rawValue)-same-native-view", currentCell.subviews.contains { $0 === swatch })
                rowColors.append(rgba(actual))
                observations.append(["kind": "swatch", "appearance": appearance.id, "eventKind": events[index].kind.rawValue,
                                     "actualCenterPixelSRGBA": rgba(actual), "expectedResolvedSRGBA": rgba(expected), "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                                     "requestedAppearanceName": appearance.name.rawValue, "resolvedNamedAppearance": named.name.rawValue, "effectiveAppearance": swatch.effectiveAppearance.name.rawValue,
                                     "bitmapColorSpace": bitmap.colorSpace.localizedName ?? "unavailable", "legacyColorAtSpace": pixel.colorSpace.localizedName ?? "unavailable", "sampleComponentsBeforeICCConversion": samples.map { Double($0) },
                                     "expectedBitmapProfileRGBA": rgba(expectedProfile), "comparisonToleranceInBitmapProfile": quantizationTolerance, "maximumBitmapProfileComponentError": maximumProfileError, "maximumSRGBComponentError": maximumSRGBError, "bitsPerSample": bitmap.bitsPerSample,
                                     "source": "Actual existing event-cell LensEventSwatch bitmap center samples compared with semantic NSColor resolved in the effective appearance and SAME bitmap ICC profile, tolerance half an 8-bit code point. sRGB conversion/maximum error retained as observation; nonlinear ICC conversion near zero is not the pixel quantization metric."])
            }
            colors[appearance.id] = rowColors
            try capture(host, filename: "dark-events-\(appearance.id).png", scenario: "Existing native event swatches without reconfiguration", appearance: appearance.id)
        }
        if let light = colors["aqua"], let dark = colors["dark-aqua"] {
            check("swatches-adapt-without-event-reconfiguration", zip(light, dark).contains { !vectorNear($0.0, $0.1) })
        } else { check("swatches-adapt-without-event-reconfiguration", false) }
        check("swatch-fixture-events-not-mutated", events.map(\.id) == kinds.indices.map { "fixture-event-\($0)" })
        window.close()
    }

    private func qualifyTextPalette() throws {
        let colors = [("keyword", LensAppearance.codeKeyword), ("string", LensAppearance.codeString), ("number", LensAppearance.codeNumber),
                      ("comment", LensAppearance.codeComment), ("warning", LensAppearance.warning), ("error", LensAppearance.error)]
        let backgrounds = [("text", NSColor.textBackgroundColor), ("window", NSColor.windowBackgroundColor), ("control", NSColor.controlBackgroundColor)]
        for appearance in DarkModeV15Appearance.matrix {
            guard let named = NSAppearance(named: appearance.name) else { throw failure("Appearance unavailable.") }
            for color in colors {
                for background in backgrounds {
                    let foreground = try resolved(color.1, appearance: named), surface = try resolved(background.1, appearance: named)
                    let ratio = contrast(foreground, surface)
                    check("palette-\(appearance.id)-\(color.0)-on-\(background.0)-contrast-at-least-4.5", ratio >= 4.5)
                    observations.append(["kind": "product-text-palette", "appearance": appearance.id, "role": color.0, "background": background.0,
                                         "foregroundSRGBA": rgba(foreground), "backgroundSRGBA": rgba(surface), "contrastRatio": ratio,
                                         "effectiveForegroundSRGBA": composite(rgba(foreground), over: rgba(surface)), "contrastMethod": "Foreground alpha composited over opaque sRGB background, then relative luminance", "resolvedNamedAppearance": named.name.rawValue,
                                         "source": "Actual product LensAppearance NSColor primitive resolved under named NSAppearance; not a measurement of SwiftUI anti-aliased text pixels"])
                }
            }
        }
    }

    private func qualifyEvidence() async throws {
        let store = makeStore("evidence")
        let patch = """
        --- a/src/Appearance.swift
        +++ b/src/Appearance.swift
        @@ -1,3 +1,3 @@
         // Contexte enregistré
        -let ancien = 1
        +let nouveau = 2
         // Fin du fragment
        @@ -20,2 +20,2 @@
        -let ancienPartiel = 3
        +let nouveauPartiel = 4
        """
        let provenance = DiffProvenance(environmentID: "/anonymous/worktrees/alpha", eventIDs: ["fixture-patch"], sources: [SourceRef(path: "anonymous-trace.jsonl", line: 42)], agentID: "fixture-agent", beforeReference: "Fragment avant · fixture-v1", afterReference: "Fragment après · fixture-v2")
        let document = try RecordedDiff.parse(patch, provenance: provenance)
        let event = LensEvent(id: "fixture-error", timestamp: baseTime, agentID: "fixture-agent", kind: .toolResult,
                              title: "Lecture impossible", preview: "Le fichier a disparu ; le résultat conserve cette limite enregistrée.", toolName: "read", source: SourceRef(path: "anonymous-trace.jsonl", line: 43), isError: true)
        check("diff-fixture-has-visible-added-and-removed-signs", document.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.kind == .added } && document.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.kind == .removed })
        check("diff-fixture-preserves-incomplete-hunk", document.files.flatMap(\.hunks).contains { !$0.isComplete })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(document)
        for appearance in DarkModeV15Appearance.matrix {
                var observedContrast: ColorSchemeContrast?
                var observedReduceTransparency: Bool?
                let root = AnyView(DarkModeV15EvidenceFixture(document: document, errorEvent: event).environmentObject(store)
                    .background(DarkModeV15EnvironmentObservation { contrast, reduceTransparency in
                        observedContrast = contrast; observedReduceTransparency = reduceTransparency
                    })
                    .environment(\.colorScheme, appearance.dark ? .dark : .light))
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                let window = makeWindow(size: NSSize(width: 1120, height: 1080), title: "Evidence · appearance qualification (anonymous)")
                window.appearance = NSAppearance(named: appearance.name)
                host.frame = NSRect(origin: .zero, size: NSSize(width: 1120, height: 1080)); window.contentView = host
                window.makeKeyAndOrderFront(nil)
                try await settle(host)
                let observed = observedContrast == .increased ? "increased" : observedContrast == .standard ? "standard" : "unobserved"
                try capture(host, filename: "dark-evidence-\(appearance.id).png", scenario: "Actual warning/resource/diff components; only native NSAppearance and public colorScheme are fixture-local", appearance: appearance.id, additional: ["requestedNativeHighContrastAppearance": appearance.increased, "publicSwiftUIContrastObserved": observed, "publicReduceTransparencyObserved": observedReduceTransparency.map { $0 ? "true" : "false" } ?? "unobserved", "systemAccessibilityPreferencesModified": false])
                check("evidence-\(appearance.id)-public-environment-values-observed", observedContrast != nil && observedReduceTransparency != nil)
                check("evidence-\(appearance.id)-diff-bytes-preserved", try encoder.encode(document) == encoded)
                check("evidence-\(appearance.id)-no-question-or-transfer", store.investigation.capsule == nil && !store.investigation.preparing && !store.investigation.sending)
                window.close()
        }
        receipt["evidenceDocumentSHA256"] = digest(encoded)
        receipt["evidenceWorktree"] = document.provenance.environmentID
        receipt["evidenceReferences"] = [document.provenance.beforeReference ?? "", document.provenance.afterReference ?? ""]
    }

    private func expectedSwatch(_ event: LensEvent) -> NSColor {
        if event.isError { return .systemRed }
        switch event.kind {
        case .user: return .systemPurple
        case .assistant: return .systemBlue
        case .toolCall, .toolResult: return .systemTeal
        case .delegation: return .systemIndigo
        case .wait: return .systemOrange
        case .error: return .systemRed
        default: return .secondaryLabelColor
        }
    }

    /// Regression for the actual archive write/status contract. Each directory
    /// is owned by this probe. No send() call or mocked archive result is used.
    private func qualifyDraftSaveStates() async throws {
        let rootID = "33333333-3333-4333-8333-333333333333"
        let capsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: baseTime,
            pieces: [EvidencePiece(id: "E001", kind: "fixture", title: "Preuve locale anonyme", text: "Contenu capturé de fixture ; aucune source actuelle consultée.", knownVersion: "fixture-sha-v1")])
        let q1 = "Question Q1 enregistrée de fixture."
        let q2 = "Question Q2 modifiée de fixture."

        func make(_ name: String) -> InvestigationStore {
            let store = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("runtime/draft-" + name)))
            investigationStores.append(store); return store
        }
        let success = make("success")
        await success.loadArchive(rootID: rootID)
        success.capsule = capsule; success.editQuestion(q1)
        check("draft-q1-pending-before-first-write", success.draftSaveState == .pending && !success.isCurrentDraftSaved && success.recordID == nil)
        try await waitFor { success.isCurrentDraftSaved }
        guard let firstID = success.recordID, let first = try await success.archive.load(id: firstID) else { throw failure("Q1 archive write unavailable.") }
        check("draft-q1-saved-only-after-real-write", first.question == q1 && first.capsule.digestSHA256 == capsule.digestSHA256 && success.isCurrentDraftSaved && success.draftSaveState == .idle && success.draftSaveLabel == "Question et preuves sauvegardées localement")
        success.editQuestion(q2)
        let duringDebounce = try await success.archive.load(id: firstID)
        check("draft-q2-immediately-invalidates-q1-saved-status", success.question == q2 && success.recordID == firstID && !success.isCurrentDraftSaved && success.draftSaveState == .pending && success.draftSaveLabel == "Modifications en attente de sauvegarde locale")
        check("draft-q2-pending-retains-actual-q1-archive", duringDebounce?.question == q1)
        try await waitFor { success.isCurrentDraftSaved }
        let second = try await success.archive.load(id: firstID)
        check("draft-q2-saved-after-persisting-exact-question", success.recordID == firstID && second?.question == q2 && second?.capsule.digestSHA256 == capsule.digestSHA256 && success.draftSaveLabel == "Question et preuves sauvegardées localement")
        observations.append(["kind": "draft-archive-status", "scenario": "successful-debounce", "recordID": firstID,
                             "q1SHA256": digest(Data(q1.utf8)), "q2SHA256": digest(Data(q2.utf8)), "persistedQuestionSHA256": digest(Data((second?.question ?? "").utf8)), "capsuleDigest": capsule.digestSHA256])

        let failed = make("failure")
        await failed.loadArchive(rootID: rootID)
        failed.capsule = capsule; failed.editQuestion(q1)
        try await waitFor { failed.isCurrentDraftSaved }
        guard let failedID = failed.recordID else { throw failure("Failure scenario initial record unavailable.") }
        let originalDirectory = output.appendingPathComponent("runtime/draft-failure")
        let backupDirectory = output.appendingPathComponent("runtime/draft-failure-retained-q1")
        try FileManager.default.moveItem(at: originalDirectory, to: backupDirectory)
        try Data("Own fixture file blocks the private archive directory.".utf8).write(to: originalDirectory)
        failed.editQuestion(q2)
        check("draft-write-failure-starts-pending-with-old-id", failed.recordID == failedID && !failed.isCurrentDraftSaved && failed.draftSaveState == .pending)
        try await waitFor { failed.draftSaveState == .failed }
        let backupArchive = InvestigationArchive(directory: backupDirectory)
        let retainedQ1 = try await backupArchive.load(id: failedID)
        check("draft-write-failure-does-not-certify-old-record", failed.question == q2 && failed.recordID == failedID && failed.capsule?.digestSHA256 == capsule.digestSHA256 && !failed.isCurrentDraftSaved && failed.draftSaveState == .failed && failed.draftSaveLabel == "Brouillon non sauvegardé · consultez l’erreur" && !(failed.issue ?? "").isEmpty)
        check("draft-write-failure-retains-real-q1-and-current-q2", retainedQ1?.question == q1 && failed.question == q2)
        observations.append(["kind": "draft-archive-status", "scenario": "actual-directory-blocker", "recordID": failedID,
                             "retainedArchiveQuestionSHA256": digest(Data((retainedQ1?.question ?? "").utf8)), "currentQuestionSHA256": digest(Data(failed.question.utf8)),
                             "saved": failed.isCurrentDraftSaved, "label": failed.draftSaveLabel, "capsuleDigest": failed.capsule?.digestSHA256 ?? ""])
        // Restore only our fixture path, preserving the retained record before
        // normal cleanup flushes Q2. No observed source or system path is touched.
        try FileManager.default.removeItem(at: originalDirectory)
        try FileManager.default.moveItem(at: backupDirectory, to: originalDirectory)

        let stale = make("selection")
        await stale.loadArchive(rootID: rootID)
        stale.capsule = capsule; stale.editQuestion(q1)
        try await waitFor { stale.isCurrentDraftSaved }
        guard let previousID = stale.recordID else { throw failure("Selection scenario initial record unavailable.") }
        let otherCapsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: baseTime.addingTimeInterval(10),
            pieces: [EvidencePiece(id: "E002", kind: "fixture", title: "Autre enquête locale", text: "Autre contenu capturé anonyme.", knownVersion: "fixture-sha-v2")])
        let otherQuestion = "Question de l’autre enquête."
        let other = try await stale.archive.save(capsule: otherCapsule, question: otherQuestion)
        stale.editQuestion(q2)
        await stale.openRecord(other.record.id)
        try await Task.sleep(nanoseconds: 850_000_000)
        let unchangedPrevious = try await stale.archive.load(id: previousID)
        let countAfterSelection = try await stale.archive.list().count
        check("draft-selection-before-debounce-ignores-old-status", stale.recordID == other.record.id && stale.question == otherQuestion && stale.capsule?.digestSHA256 == otherCapsule.digestSHA256 && stale.isCurrentDraftSaved)
        check("draft-selection-before-debounce-keeps-old-persisted-q1", unchangedPrevious?.question == q1 && countAfterSelection == 2)
        stale.editQuestion("Modification annulée par le changement de session.")
        await stale.loadArchive(rootID: "44444444-4444-4444-8444-444444444444")
        try await Task.sleep(nanoseconds: 850_000_000)
        let unchangedOther = try await stale.archive.load(id: other.record.id)
        let countAfterSession = try await stale.archive.list().count
        check("draft-session-before-debounce-ignores-old-results", stale.capsule == nil && stale.recordID == nil && stale.question.isEmpty && stale.records.isEmpty && !stale.isCurrentDraftSaved && stale.draftSaveState == .idle)
        check("draft-session-before-debounce-retains-previous-archive", unchangedOther?.question == otherQuestion && countAfterSession == 2)

        let redacted = make("redacted")
        await redacted.loadArchive(rootID: rootID)
        redacted.capsule = capsule
        let syntheticMarker = "sk-FIXTUREONLY_0123456789"
        let syntheticQuestion = "Question avec marqueur secret factice : " + syntheticMarker
        redacted.editQuestion(syntheticQuestion)
        try await waitFor { redacted.isCurrentDraftSaved }
        guard let redactedID = redacted.recordID, let record = try await redacted.archive.load(id: redactedID) else { throw failure("Redaction scenario archive unavailable.") }
        let storedData = try Data(contentsOf: output.appendingPathComponent("runtime/draft-redacted/" + redactedID + ".json"))
        check("draft-redacted-write-status-names-real-transformation", redacted.question == syntheticQuestion && redacted.isCurrentDraftSaved && record.question.contains("[secret masqué]") && !record.question.contains(syntheticMarker) && redacted.draftSaveLabel == "Question expurgée et preuves sauvegardées localement")
        check("draft-redacted-archive-has-no-unredacted-marker", !String(decoding: storedData, as: UTF8.self).contains(syntheticMarker))
        observations.append(["kind": "draft-archive-status", "scenario": "synthetic-redaction", "recordID": redactedID,
                             "storedQuestion": record.question, "label": redacted.draftSaveLabel, "archiveSHA256": digest(storedData), "syntheticMarkerOnly": true])
        check("draft-status-qualification-has-no-response-or-request", [success, failed, stale, redacted].allSatisfy { !$0.sending && !$0.preparing && $0.response == nil && $0.apiKey.isEmpty })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw failure("Timed out waiting for actual private archive status transition.")
    }
    private func makeStore(_ name: String) -> LensStore {
        let root = output.appendingPathComponent("runtime/" + name)
        let store = LensStore(sourceHome: root.appendingPathComponent("empty-source"), investigationArchive: InvestigationArchive(directory: root.appendingPathComponent("archive")), cacheDirectory: root.appendingPathComponent("cache"))
        stores.append(store); return store
    }
    private func makeWindow(size: NSSize, title: String) -> NSWindow {
        let window = DarkModeV15RenderWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = title; windows.append(window); return window
    }
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(nanoseconds: 220_000_000)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.window?.displayIfNeeded(); CATransaction.flush()
    }
    private func capture(_ view: NSView, filename: String, scenario: String, appearance: String, additional: [String: Any] = [:]) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Own native bitmap unavailable.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Own native PNG unavailable.") }
        try png.write(to: output.appendingPathComponent(filename))
        check("render-nonempty-" + filename, png.count > 4096 && bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        var item: [String: Any] = ["filename": filename, "scenario": scenario, "appearance": appearance, "logicalWidth": view.bounds.width, "logicalHeight": view.bounds.height,
                                   "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "bytes": png.count, "sha256": digest(png), "anonymous": true,
                                   "method": "Own native NSView/NSHostingView bitmap cache, not a compositor screenshot"]
        additional.forEach { item[$0.key] = $0.value }; renders.append(item)
    }
    private func resolved(_ color: NSColor, appearance: NSAppearance, colorSpace: NSColorSpace = .sRGB) throws -> NSColor {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(colorSpace) }
        guard let result else { throw failure("Color cannot resolve to the requested color space.") }; return result
    }
    private func rgba(_ color: NSColor) -> [Double] { [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)] }
    private func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        let f = rgba(foreground), b = rgba(background), a = f[3]
        let effective = (0..<3).map { f[$0] * a + b[$0] * (1 - a) }
        func luminance(_ channels: [Double]) -> Double {
            let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let first = luminance(effective), second = luminance(Array(b.prefix(3)))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
    private func composite(_ foreground: [Double], over background: [Double]) -> [Double] {
        (0..<3).map { foreground[$0] * foreground[3] + background[$0] * (1 - foreground[3]) } + [1]
    }
    private func vectorNear(_ a: [Double], _ b: [Double], tolerance: Double = 0.003) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0.0 - $0.1) <= tolerance } }
    private func near(_ a: NSPoint, _ b: NSPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
    private func saveReceipt() throws {
        receipt["checks"] = checks; receipt["renders"] = renders; receipt["observations"] = observations
        receipt["allExecutedChecksPassed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        receipt["failedCheckIDs"] = checks.filter { $0["passed"] as? Bool == false }.compactMap { $0["id"] as? String }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"), options: .atomic)
    }
    private func cleanUp() async {
        for store in investigationStores { await store.flushAndStop() }
        for store in stores { store.stopObserving(); await store.investigation.flushAndStop() }
        for window in windows { window.close() }
    }
    func recordFatal(_ error: Error) {
        checks.append(["id": "fatal", "passed": false, "message": error.localizedDescription])
        for store in stores { store.stopObserving() }
        for window in windows { window.close() }
        receipt["finishedAt"] = Date().ISO8601Format(); try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { throw failure("Missing " + name) }
        return CommandLine.arguments[i + 1]
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ message: String) -> NSError { NSError(domain: "CodexLensDarkModeV15Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
