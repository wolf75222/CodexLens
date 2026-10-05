import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Source-matched SF Symbols and state qualification. The launcher replaces
/// production @main and denies network access; all session data is anonymous.
@main struct IconsV14Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let run = IconsV14Run()
        Task { @MainActor in
            do { try await run.run() } catch { run.recordFatal(error) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}

@MainActor private final class IconsV14RenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private struct SymbolsActionsFixture: View {
    @ObservedObject var store: LensStore
    let saved: Destination
    let other: Destination
    let size: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Actions de la session · fixture anonyme").font(.headline)
            Text(store.follow ? "Collecte active · suivi visuel actif" : "Collecte active · suivi visuel suspendu")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(LensAction.allCases) { action in
                        LensActionButton(store: store, action: action, target: saved)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Même action, cible distincte").font(.headline)
                    LensActionButton(store: store, action: .bookmark, target: saved)
                    LensActionButton(store: store, action: .bookmark, target: other)
                    LensQuestionMenu(store: store, target: saved)
                    Divider()
                    Text("Barre compacte : libellés accessibles fournis par les actions produit.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        LensActionButton(store: store, action: .back).labelStyle(.iconOnly)
                        LensActionButton(store: store, action: .forward).labelStyle(.iconOnly)
                        LensActionButton(store: store, action: .follow).labelStyle(.iconOnly)
                        LensActionButton(store: store, action: .bookmark, target: saved).labelStyle(.iconOnly)
                        LensActionButton(store: store, action: .inspector).labelStyle(.iconOnly)
                    }
                    Text("Le menu est fermé. Aucune action de transfert, ouverture externe ou question n’est exécutée.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: 440, alignment: .leading)
            }
            Spacer(minLength: 0)
        }.font(LensUI.readingFont(size)).padding(16)
    }
}

@MainActor private struct SymbolsAgentsFixture: View {
    let size: Double
    private var agents: [AgentRecord] {
        [.root, .subagent, .fork, .continuation, .unknown].enumerated().map { index, relation in
            AgentRecord(id: "anonymous-agent-\(index)", parentID: relation == .root ? nil : "anonymous-agent-0",
                        name: relationLabel(relation), relation: relation,
                        mission: "Mission enregistrée de fixture ; aucune causalité supplémentaire déduite.",
                        accessible: relation != .unknown)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relations enregistrées · texte et symboles").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                ForEach(agents) { agent in AgentIdentityView(agent: agent) }
            }
            Divider()
            Text("Lignes de navigation réelles · métriques système").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(agents) { agent in LensSidebarAgentButton(agent: agent, onOpen: {}) }
            }.font(LensUI.body)
            Spacer(minLength: 0)
        }.padding(16)
            .environment(\.lensComponentTypography, LensComponentTypography(body: size, caption: max(11, size - 2), code: size))
    }
}

@MainActor private struct SymbolsEvidenceFixture: View {
    let size: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fichiers, provenance et indisponibilité · fixtures").font(.headline)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 13) {
                    FileLocationView(location: LensFileIdentity(path: "/fixture/worktrees/alpha/src/Same.swift", environmentID: "/fixture/worktrees/alpha", versionLabel: "Fragment enregistré · version A"))
                    FileLocationView(location: LensFileIdentity(path: "/fixture/worktrees/beta/src/Same.swift", environmentID: "/fixture/worktrees/beta", versionLabel: "Contenu actuel · version B"))
                    Divider()
                    ForEach(["Photo.PNG", "Document.pdf", "Code.swift", "Archive.bin"], id: \.self) { path in
                        Label(path, systemImage: LensUI.fileSymbol(path)).font(LensUI.readingFont(size))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(LensProvenanceCertainty.allCases) { certainty in
                        ProvenanceView(certainty: certainty, explanation: certainty == .confirmed ? "Identifiant explicite enregistré." : certainty == .correlation ? "Association à examiner ; elle ne prouve pas une causalité." : "Les traces disponibles ne confirment aucune association.", sourceLabel: "anonymous-trace.jsonl:42")
                    }
                    Divider()
                    LensLoadStateView(state: .missing(subject: "Pièce jointe", message: "La référence est enregistrée ; les octets ne sont pas accessibles."))
                    LensLoadStateView(state: .permission(subject: "Environnement", message: "La localisation reste visible ; son contenu ne peut pas être consulté."))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }.padding(16)
            .environment(\.lensComponentTypography, LensComponentTypography(body: size, caption: max(11, size - 2), code: size))
    }
}

@MainActor private struct SymbolsCatalogueFixture: View {
    let size: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Catalogue fixe de symboles produit · résolution de l’hôte").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 12) {
                ForEach(LensSymbols.catalogue, id: \.self) { name in
                    Label(name, systemImage: LensSymbols.name(name))
                        .font(LensUI.readingFont(size)).imageScale(.medium)
                        .symbolRenderingMode(.monochrome).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }.padding(16)
    }
}

@MainActor private struct IconsV14ResourceFixture: View {
    let size: Double
    static var records: [ResourceRecord] {
        [
            ResourceRecord(id: "icon-tif-unknown", location: "/fixture/worktrees/alpha/Photo.TIF", roles: [.supplied], agentIDs: ["fixture-root"], environmentID: "/fixture/worktrees/alpha", eventIDs: ["message-image"], evidence: "Reference only; no bytes or read recorded.", availability: .unknown),
            ResourceRecord(id: "icon-pdf-missing", location: "/fixture/worktrees/alpha/report.pdf", roles: [.referenced], eventIDs: ["tool-1", "tool-2"], availability: .missing),
            ResourceRecord(id: "icon-trace", location: "trace:fixture:attachment:1", roles: [.supplied], eventIDs: ["message-attachment"], availability: .missing),
            ResourceRecord(id: "icon-external", location: "https://example.invalid/document.png", name: "Document externe", roles: [.referenced], availability: .external),
            ResourceRecord(id: "icon-code-alpha", location: "/fixture/worktrees/alpha/src/Same.swift", roles: [.recordedRead, .modified], agentIDs: ["fixture-child"], environmentID: "/fixture/worktrees/alpha", eventIDs: ["read-1", "patch-1"], availability: .accessible),
            ResourceRecord(id: "icon-code-beta", location: "/fixture/worktrees/beta/src/Same.swift", roles: [.produced], environmentID: "/fixture/worktrees/beta", eventIDs: ["write-1"], availability: .missing),
            ResourceRecord(id: "icon-directory", location: "/fixture/worktrees/alpha", name: "Environnement enregistré", roles: [.referenced], availability: .unknown),
            ResourceRecord(id: "icon-unknown", location: "reference-sans-chemin", name: "Référence de forme inconnue", roles: [.referenced], availability: .unknown)
        ]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ressources · lignes produit · fixtures anonymisées").font(.system(size: size, weight: .semibold))
            Text("Le symbole décrit la référence ou le suffixe ; rôle, disponibilité et contexte restent des textes distincts.")
                .font(.system(size: size)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.records) { resource in
                LensResourceRowLabel(resource: resource, isKnownDirectory: resource.id == "icon-directory")
                    .padding(.vertical, 9)
                Divider()
            }
            Spacer(minLength: 0)
        }.padding(16)
    }
}

@MainActor private final class IconsV14Run {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var receipt: [String: Any] = [:]
    private var resourceAccessibility: [[String: Any]] = []
    private var accessibilityLimits: [String] = []
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private var store: LensStore?

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let corpusData = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let fixture = try JSONSerialization.jsonObject(with: corpusData) as? [String: Any],
              fixture["anonymous"] as? Bool == true, let root = fixture["rootID"] as? String,
              let originalHome = fixture["home"] as? String else { throw failure("Explicit anonymous corpus required.") }
        receipt["startedAt"] = Date().ISO8601Format()
        receipt["entrypoint"] = "IconsV14Main.swift"
        receipt["scope"] = "Source-matched production SF Symbols resolver, resource rows, file kinds, business components and LensAction implementations in own NSApplication; production @main replaced."
        receipt["corpusManifestSHA256"] = digest(corpusData)
        receipt["networkDeniedByLauncher"] = true
        receipt["realCodexHomeRead"] = false
        receipt["modelRequests"] = 0
        receipt["credentialAccess"] = false
        receipt["interactionMethod"] = "Own NSImage, NSHostingView and LensStore APIs; no OS input, clipboard, external app or system preference mutations. Probe bookmark preferences belong to its unique bundle identifier."
        try qualifyCatalogue()
        qualifyPureSemantics()
        try qualifyResourceSemantics()
        let runtime = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let home = runtime.appendingPathComponent("source")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: originalHome), to: home)
        let current = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: runtime.appendingPathComponent("archive")), cacheDirectory: runtime.appendingPathComponent("cache"))
        store = current
        current.setNavigationScope(UUID().uuidString)
        await current.start(); await current.open(root); await current.waitForPresentation()
        guard let snapshot = current.snapshot, snapshot.root.id == root, current.error == nil,
              let selectedEvent = snapshot.events.first(where: { $0.kind == .toolCall }),
              let otherEvent = snapshot.events.first(where: { $0.kind == .user }) else { throw failure("Anonymous session could not supply two distinct targets.") }
        let saved = Destination.event(selectedEvent.id), other = Destination.event(otherEvent.id)
        current.navigate(saved); current.bookmarks = []
        qualifyActions(current, saved: saved, other: other)
        current.follow = true
        for size in [13.0, 18.0] {
            try await capture("actions-following", size: size, dimensions: NSSize(width: 1080, height: 740)) {
                SymbolsActionsFixture(store: current, saved: saved, other: other, size: size)
            }
        }
        current.perform(.follow)
        check("follow-command-pauses-visual-follow", !current.follow && current.hasSessionReader && current.canPerform(.follow))
        for size in [13.0, 18.0] {
            try await capture("actions-paused", size: size, dimensions: NSSize(width: 1080, height: 740)) {
                SymbolsActionsFixture(store: current, saved: saved, other: other, size: size)
            }
            try await capture("agents", size: size, dimensions: NSSize(width: 1080, height: 850)) { SymbolsAgentsFixture(size: size) }
            try await capture("evidence", size: size, dimensions: NSSize(width: 1120, height: 900)) { SymbolsEvidenceFixture(size: size) }
            try await capture("catalogue", size: size, dimensions: NSSize(width: 1220, height: 1160)) { SymbolsCatalogueFixture(size: size) }
        }
        for size in [13.0, 18.0] {
            for width in [700.0, 1120.0] {
                try await capture("resource-rows-" + String(Int(width)), size: size, dimensions: NSSize(width: width, height: 980)) {
                    IconsV14ResourceFixture(size: size)
                }
            }
        }
        current.perform(.follow)
        check("follow-command-returns-to-present", current.follow && LensAction.follow.symbol(in: current) == LensSymbols.name("pause.circle"))
        check("symbol-inspection-preserves-session-events", current.snapshot?.events == snapshot.events)
        check("symbol-inspection-does-not-prepare-or-send-question", current.investigation.capsule == nil && (current.investigation.response ?? "").isEmpty && !current.investigation.sending && !current.investigation.preparing)
        receipt["rootID"] = root
        receipt["events"] = snapshot.events.count
        receipt["resourceFixtureRecords"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(IconsV14ResourceFixture.records))
        receipt["resourceRowQualification"] = "Product LensResourceRowLabel is rendered unchanged at 700 and 1120 points, light/dark. Parent fixture font 13/18 points does not imply fixed product row font scales. Glyphs identify reference/format only; no existence, read, MIME validation, attribution or remote fetch is inferred."
        receipt["resourceAccessibilityObservations"] = resourceAccessibility
        receipt["unqualified"] = [
            "Host NSImage resolution and local Apple catalogue metadata do not constitute execution on macOS 14 or Intel.",
            "CoreGlyphs name_availability.plist is undocumented local audit evidence, not a dependency or runtime API of the product.",
            "Own NSHostingView bitmaps are native component renders, not compositor screenshots or a production @main launch.",
            "Physical keyboard, focus/hover gestures, expanded menus, VoiceOver announcements, contrast perception and actual production startup require separate verification.",
            "No inference, performance gains, complete HIG compliance or recorded provenance beyond the anonymous fixture are asserted.",
            "Resource row native public accessibility getters are inspected only when SwiftUI materializes their tree; absence is reported, not treated as VoiceOver qualification."
        ] + accessibilityLimits
        current.stopObserving(); await current.investigation.flushAndStop()
        window?.close()
        receipt["finishedAt"] = Date().ISO8601Format()
        try saveReceipt()
    }

    private func qualifyCatalogue() throws {
        check("fixed-catalogue-is-nonempty-unique", !LensSymbols.catalogue.isEmpty && Set(LensSymbols.catalogue).count == LensSymbols.catalogue.count)
        let metadataURL = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        let data = try Data(contentsOf: metadataURL)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let symbols = dictionary["symbols"] as? [String: String], let releases = dictionary["year_to_release"] as? [String: [String: String]] else { throw failure("Local Apple symbol metadata format changed.") }
        var inventory: [[String: Any]] = []
        for name in LensSymbols.catalogue {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Fixture : " + name)
            let resolved = LensSymbols.name(name)
            let release = symbols[name]
            let minimum = release.flatMap { releases[$0]?["macOS"] }
            let resolvedMinimum = symbols[resolved].flatMap { releases[$0]?["macOS"] }
            let targetCompatible = minimum.map { $0.compare("14.0", options: .numeric) != .orderedDescending } ?? false
            check("catalogue-host-symbol-" + name, image != nil)
            check("catalogue-local-metadata-target14-" + name, targetCompatible)
            check("catalogue-resolution-nonempty-available-" + name, !resolved.isEmpty && NSImage(systemSymbolName: resolved, accessibilityDescription: nil) != nil)
            inventory.append(["requested": name, "resolved": resolved, "hostAvailable": image != nil,
                              "localMetadataRelease": release ?? "unknown", "localMetadataMinimumMacOS": minimum ?? "unknown",
                              "resolvedLocalMetadataMinimumMacOS": resolvedMinimum ?? "unknown", "metadataSuggestsTarget14Compatibility": targetCompatible])
        }
        receipt["symbolInventory"] = inventory
        receipt["localAppleAvailabilityMetadata"] = ["path": metadataURL.path, "bytes": data.count, "sha256": digest(data),
                                                     "method": "Read symbols/year_to_release from host CoreGlyphs bundle; undocumented local evidence only.",
                                                     "documentedVerificationMethod": "Apple SF Symbols app > View > Inspectors > Show Info Sidebar, on a developer installation; not performed because this app is absent.",
                                                     "documentedMethodURL": "https://developer.apple.com/documentation/uikit/configuring-and-displaying-symbol-images-in-your-ui"]
        let sourceManifestData = try Data(contentsOf: output.appendingPathComponent("native-design-v07-source-manifest.json"))
        guard let sourceManifest = try JSONSerialization.jsonObject(with: sourceManifestData) as? [String: Any],
              let sourceRoot = sourceManifest["sourceRoot"] as? String else { throw failure("Native source manifest missing.") }
        let sourceDirectory = URL(fileURLWithPath: sourceRoot).appendingPathComponent("Sources/CodexLens")
        let patterns = [#"(?:systemName|systemImage|systemSymbolName)\s*:\s*"([^"]*)""#, #"LensSymbols\.name\(\s*"([^"]*)""#]
        var literals = Set<String>(), emptyOrigins: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "swift" }) {
            let text = try String(contentsOf: file, encoding: .utf8), range = NSRange(text.startIndex..<text.endIndex, in: text)
            for pattern in patterns {
                for result in try NSRegularExpression(pattern: pattern).matches(in: text, range: range) {
                    guard let valueRange = Range(result.range(at: 1), in: text) else { continue }
                    let name = String(text[valueRange]); literals.insert(name)
                    if name.isEmpty { emptyOrigins.append(file.lastPathComponent) }
                }
            }
        }
        check("source-has-no-empty-symbol-literal", emptyOrigins.isEmpty)
        check("source-explicit-symbol-literals-belong-to-fixed-catalogue", literals.allSatisfy { LensSymbols.catalogue.contains($0) })
        receipt["explicitSymbolLiterals"] = literals.sorted()
        let componentSource = try String(contentsOf: sourceDirectory.appendingPathComponent("LensComponents.swift"), encoding: .utf8)
        let eventProducer = try inventoryPrivateFlatProducer(componentSource, signature: "static func symbol(_ value: EventKind)")
        for kind in EventKind.allCases {
            let name = eventProducer[kind.rawValue] ?? ""
            check("private-event-source-symbol-" + kind.rawValue, LensSymbols.catalogue.contains(name) && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
        let relationProducer = try inventoryPrivateFlatProducer(componentSource, signature: "static func relation(_ value: RelationKind)")
        for relation in [RelationKind.root, .subagent, .fork, .continuation, .unknown] {
            check("private-agent-source-relation-text-" + relation.rawValue, relationProducer[relation.rawValue] == relationLabel(relation))
        }
        receipt["privateEventProducerSourceInventory"] = eventProducer
        receipt["privateRelationProducerSourceInventory"] = relationProducer
        receipt["sourceInventoryMethod"] = "Regex over source-matched app sources for explicit systemName/systemImage/systemSymbolName and LensSymbols.name literals. Private EventKind/relation producers are inspected as flat source switches; their visibility is unchanged. Public computed producers additionally exercised below. This is a bounded source contract, not a Swift parser or execution of private functions."
    }

    private func qualifyPureSemantics() {
        check("resolver-primary-available", LensSymbols.resolvedName("folder", available: { $0 == "folder" }) == "folder")
        check("resolver-specific-fallback", LensSymbols.resolvedName("folder.badge.questionmark", available: { $0 == "folder" }) == "folder")
        check("resolver-unknown-keeps-conservative-fallback", LensSymbols.resolvedName("untrusted.raw.trace.tool", available: { _ in true }) == "questionmark.circle")
        check("resolver-all-unavailable-is-nonempty", LensSymbols.resolvedName("folder", available: { _ in false }) == "questionmark.circle")
        let relations: [(RelationKind, String)] = [(.root, "person.crop.circle"), (.subagent, "arrow.turn.down.right"), (.fork, "arrow.triangle.branch"), (.continuation, "arrow.clockwise"), (.unknown, "questionmark.circle")]
        for (relation, expected) in relations {
            check("agent-relation-symbol-" + relation.rawValue, LensSymbols.agent(relation) == LensSymbols.name(expected))
        }
        check("agent-relation-symbols-distinct-on-host", Set(relations.map { LensSymbols.agent($0.0) }).count == relations.count)
        for (path, directory, expected) in [("Photo.PNG", false, "photo"), ("Document.pdf", false, "doc.richtext"), ("Code.swift", false, "doc.text"), ("Archive.bin", false, "doc"), ("/fixture/directory.swift", true, "folder")] {
            check("file-symbol-" + path, LensUI.fileSymbol(path, isDirectory: directory) == LensSymbols.name(expected))
        }
        let computed = LensDataCompleteness.allCases.map(\.symbol) + LensProvenanceCertainty.allCases.map(\.symbol) + LensGallerySection.allCases.map(\.symbol) + LensSection.allCases.map(\.symbol) + LensAction.allCases.map(\.symbol)
        for (index, name) in computed.enumerated() {
            check("computed-symbol-registered-and-available-\(index)-" + name, LensSymbols.catalogue.contains(name) && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
        let alpha = LensFileIdentity(path: "/fixture/alpha/Same.swift", environmentID: "/fixture/alpha", versionLabel: "Version enregistrée A")
        let beta = LensFileIdentity(path: "/fixture/beta/Same.swift", environmentID: "/fixture/beta", versionLabel: "Version enregistrée A")
        var next = alpha; next.versionLabel = "Version enregistrée B"
        check("file-identity-keeps-worktree-and-version", alpha.id != beta.id && alpha.id != next.id && alpha.relativePath == beta.relativePath)
        check("provenance-certainty-text-and-symbol-remain-distinct", Set(LensProvenanceCertainty.allCases.map(\.label)).count == 3 && Set(LensProvenanceCertainty.allCases.map(\.symbol)).count == 3)
        check("missing-resource-retains-text", LensLoadState.missing(subject: "Pièce jointe", message: "Octets indisponibles").message == "Octets indisponibles")
    }

    private func qualifyResourceSemantics() throws {
        let fileCases: [(String, Bool, String)] = [
            ("Photo.tif", false, "photo"), ("Photo.TIF", false, "photo"), ("Photo.TIFF", false, "photo"),
            ("Photo.PNG", false, "photo"), ("Document.PDF", false, "doc.richtext"),
            ("Same.swift", false, "doc.text"), ("Archive.bin", false, "doc"),
            ("/fixture/folder.png", true, "folder")
        ]
        for (index, value) in fileCases.enumerated() {
            check("resource-file-format-\(index)-" + value.0, LensUI.fileSymbol(value.0, isDirectory: value.1) == value.2)
        }
        let references: [(String, Bool, String)] = [
            ("/fixture/Photo.TIF", false, "photo"), ("file:///fixture/Photo%20original.TIF", false, "photo"),
            ("file://localhost/fixture/report.pdf", false, "doc.richtext"),
            ("trace:fixture:attachment:1", false, "paperclip"), ("trace:fixture:attachment:1.png", true, "paperclip"),
            ("https://example.invalid/image.png", false, "link"), ("https://example.invalid/image.png", true, "link"),
            ("file://remote-host/fixture/image.png", false, "link"), ("s3://fixture/bucket/code.swift", false, "link"),
            ("reference-sans-chemin", false, "doc"), ("Photo.TIF", false, "doc"),
            ("/fixture/folder.png", true, "folder"), ("/fixture/folder.png", false, "photo")
        ]
        let available: [Availability] = [.accessible, .missing, .external, .unknown]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (index, value) in references.enumerated() {
            for status in available {
                let record = ResourceRecord(id: "reference-\(index)", location: value.0, roles: [.supplied, .recordedRead, .produced], agentIDs: ["fixture-root"], environmentID: "/fixture/alpha", eventIDs: ["fixture-message"], evidence: "Recorded explanation preserved", availability: status)
                let encoded = try encoder.encode(record)
                for _ in 0..<128 { _ = LensUI.resourceSymbol(record, isKnownDirectory: value.1) }
                check("resource-reference-form-\(index)-" + status.rawValue, LensUI.resourceSymbol(record, isKnownDirectory: value.1) == value.2)
                check("resource-record-preserved-\(index)-" + status.rawValue, try encoder.encode(record) == encoded && JSONDecoder().decode(ResourceRecord.self, from: encoded) == record)
            }
        }
        for role in ResourceRole.allCases {
            for status in available {
                let record = ResourceRecord(location: "/fixture/Photo.TIF", roles: [role], availability: status)
                check("resource-role-is-not-file-type-" + role.rawValue + "-" + status.rawValue, LensUI.resourceSymbol(record) == "photo")
            }
        }
        let alpha = IconsV14ResourceFixture.records[4], beta = IconsV14ResourceFixture.records[5]
        check("resource-homonym-worktrees-remain-distinct", alpha.id != beta.id && alpha.location != beta.location && alpha.environmentID != beta.environmentID && alpha.name == beta.name)
        for (directory, link, label) in [(false, false, "Fichier"), (true, false, "Dossier"), (false, true, "Lien symbolique"), (true, true, "Lien symbolique vers un dossier")] {
            check("native-file-kind-directory-\(directory)-link-\(link)", LensUI.fileItemKind(isDirectory: directory, isSymbolicLink: link) == label)
        }
        let manifestData = try Data(contentsOf: output.appendingPathComponent("native-design-v07-source-manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        let source = URL(fileURLWithPath: manifest["sourceRoot"] as! String).appendingPathComponent("Sources/CodexLens")
        let lens = try String(contentsOf: source.appendingPathComponent("LensUI.swift"), encoding: .utf8)
        let symbolBody = try sourceBody(lens, signature: "static func resourceSymbol(")
        let forbidden = ["FileManager", "Data(contentsOf:", "URLSession", "URLRequest", "NSWorkspace", "execute", "Process(", "availability =", "roles ="]
        check("resource-symbol-source-has-no-file-or-network-or-model-write-operation", !forbidden.contains(where: symbolBody.contains))
        let rows = try String(contentsOf: source.appendingPathComponent("ObjectViews.swift"), encoding: .utf8)
        let rowBody = try sourceBody(rows, signature: "struct LensResourceRowLabel:")
        check("resource-row-glyph-source-hidden-from-accessibility", rowBody.contains(".accessibilityHidden(true)"))
        check("resource-row-retains-role-availability-context-text", rowBody.contains("resource.roles.map") && rowBody.contains("availabilityLabel(resource.availability)") && rowBody.contains("resource.eventIDs.count"))
        receipt["resourceSourceContracts"] = ["symbolBody": symbolBody, "rowBodySHA256": digest(Data(rowBody.utf8)), "method": "Bounded source-matched brace extraction; not whole-program static analysis or I/O counters."]
    }

    private func sourceBody(_ source: String, signature: String) throws -> String {
        guard let prefix = source.range(of: signature), let opening = source[prefix.upperBound...].firstIndex(of: "{") else { throw failure("Missing source producer: " + signature) }
        var depth = 0
        for index in source[opening...].indices {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { return String(source[opening...index]) } }
        }
        throw failure("Unbalanced source producer: " + signature)
    }

    private func qualifyResourceAccessibility(_ native: NSView, id: String) {
        var strings: [String] = [], imageLabels: [String] = [], nodeCount = 0
        func walk(_ node: Any, depth: Int = 0) {
            guard depth < 40, let element = node as? any NSAccessibilityProtocol else { return }
            nodeCount += 1
            let label = element.accessibilityLabel() ?? "", title = element.accessibilityTitle() ?? "", value = element.accessibilityValue() as? String ?? ""
            strings += [label, title, value].filter { !$0.isEmpty }
            if element.accessibilityRole() == .image { imageLabels.append(label) }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(native)
        let joined = strings.joined(separator: " | ")
        let hasText = joined.contains("Photo.TIF") || joined.contains("Pièce jointe embarquée")
        resourceAccessibility.append(["id": id, "nodeCount": nodeCount, "strings": strings, "imageLabels": imageLabels, "swiftUIResourceTextObserved": hasText])
        if hasText {
            check(id + "-accessibility-retains-missing-availability", joined.contains("Fichier absent"))
            check(id + "-accessibility-retains-supplied-role", joined.contains("Fourni"))
            check(id + "-accessibility-retains-recorded-read-role", joined.contains("Lecture enregistrée"))
            check(id + "-accessibility-retains-context-count", joined.contains("lien") && joined.contains("contexte"))
            check(id + "-accessibility-glyph-is-decorative", imageLabels.isEmpty)
        } else {
            accessibilityLimits.append(id + ": public own NSHostingView getters did not materialize resource text; AX text/decoration contracts unqualified by runtime tree.")
        }
    }

    private func qualifyActions(_ current: LensStore, saved: Destination, other: Destination) {
        current.follow = true
        check("follow-active-symbol-and-title", LensAction.follow.symbol(in: current) == LensSymbols.name("pause.circle") && LensAction.follow.title(in: current) == "Suspendre le suivi visuel")
        current.follow = false
        check("follow-paused-symbol-and-title", LensAction.follow.symbol(in: current) == LensSymbols.name("play.circle") && LensAction.follow.title(in: current) == "Revenir au présent")
        check("bookmark-absent-target-symbol-and-title", LensAction.bookmark.symbol(in: current, target: saved) == LensSymbols.name("bookmark") && LensAction.bookmark.title(in: current, target: saved) == "Ajouter un signet")
        current.perform(.bookmark, target: saved)
        check("bookmark-command-updates-symbol-and-title", LensAction.bookmark.symbol(in: current, target: saved) == LensSymbols.name("bookmark.fill") && LensAction.bookmark.title(in: current, target: saved) == "Retirer le signet")
        check("bookmark-other-target-remains-unselected", LensAction.bookmark.symbol(in: current, target: other) == LensSymbols.name("bookmark") && LensAction.bookmark.title(in: current, target: other) == "Ajouter un signet")
        current.bookmarks.append(LensBookmark(rootID: "another-anonymous-root", destination: other, title: "Foreign root"))
        check("bookmark-does-not-cross-root", LensAction.bookmark.symbol(in: current, target: other) == LensSymbols.name("bookmark"))
        current.perform(.bookmark, target: saved)
        check("bookmark-removal-updates-symbol-and-title", LensAction.bookmark.symbol(in: current, target: saved) == LensSymbols.name("bookmark") && LensAction.bookmark.title(in: current, target: saved) == "Ajouter un signet")
        current.perform(.bookmark, target: saved)
        if let environment = current.snapshot?.environments.first {
            let versionA = Destination.file(environment: environment.id, path: environment.path + "/src/Same.swift", version: "recorded:A")
            let versionB = Destination.file(environment: environment.id, path: environment.path + "/src/Same.swift", version: "recorded:B")
            current.perform(.bookmark, target: versionA)
            check("bookmark-does-not-cross-file-version", LensAction.bookmark.symbol(in: current, target: versionA) == LensSymbols.name("bookmark.fill") && LensAction.bookmark.symbol(in: current, target: versionB) == LensSymbols.name("bookmark"))
        } else { check("bookmark-file-version-fixture-available", false) }
        current.follow = true
    }

    private func capture<V: View>(_ scene: String, size: Double, dimensions: NSSize, content: () -> V) async throws {
        if window == nil {
            let owned = IconsV14RenderWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: dimensions), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            owned.isReleasedWhenClosed = false; owned.title = "Codex Lens — symbols qualification (anonymous)"
            window = owned
        }
        guard let window else { throw failure("Own window unavailable.") }
        for theme in ["light", "dark"] {
            let dark = theme == "dark"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(dimensions)
            let root = AnyView(content().symbolRenderingMode(.monochrome).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
            let native = NSHostingView(rootView: root)
            native.sizingOptions = []; native.frame = NSRect(origin: .zero, size: dimensions)
            host = native; window.contentView = native
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(nanoseconds: 300_000_000)
            native.layoutSubtreeIfNeeded(); native.displayIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            guard let bitmap = native.bitmapImageRepForCachingDisplay(in: native.bounds) else { throw failure("No own native bitmap.") }
            native.cacheDisplay(in: native.bounds, to: bitmap)
            if scene.hasPrefix("resource-rows-") { qualifyResourceAccessibility(native, id: scene + "-" + String(Int(size)) + "-" + theme) }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("No native PNG data.") }
            let filename = "icons-\(scene)-\(Int(size))-\(theme).png"
            try png.write(to: output.appendingPathComponent(filename))
            check("render-nonempty-" + filename, bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && png.count > 4096)
            renders.append(["filename": filename, "scene": scene, "requestedFontSize": size, "theme": theme,
                            "logicalWidth": native.bounds.width, "logicalHeight": native.bounds.height,
                            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "bytes": png.count, "sha256": digest(png),
                            "anonymous": true, "method": "Own NSHostingView bitmap cache, not compositor screenshot"])
        }
    }

    private func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
    private func inventoryPrivateFlatProducer(_ source: String, signature: String) throws -> [String: String] {
        let native = source as NSString
        let signatureRange = native.range(of: signature)
        guard signatureRange.location != NSNotFound else { throw failure("Private source producer absent: " + signature) }
        let line = native.substring(with: native.lineRange(for: signatureRange))
        let pattern = #"case\s+([^:]+):\s+return\s+"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var result: [String: String] = [:]
        for match in regex.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) {
            guard let casesRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else { continue }
            for key in line[casesRange].split(separator: ",") {
                result[key.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")] = String(line[valueRange])
            }
        }
        guard !result.isEmpty else { throw failure("Private source producer format changed: " + signature) }
        return result
    }
    private func saveReceipt() throws {
        receipt["checks"] = checks; receipt["renders"] = renders
        receipt["allExecutedChecksPassed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        receipt["failedCheckIDs"] = checks.filter { $0["passed"] as? Bool == false }.compactMap { $0["id"] as? String }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"), options: .atomic)
    }
    func recordFatal(_ error: Error) {
        checks.append(["id": "fatal", "passed": false, "message": error.localizedDescription])
        store?.stopObserving(); window?.close()
        receipt["finishedAt"] = Date().ISO8601Format()
        try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw failure("Missing " + name) }
        return CommandLine.arguments[index + 1]
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensSymbolsProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
