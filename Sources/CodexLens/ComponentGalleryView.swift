import AppKit
import SwiftUI
import LensCore

enum LensGallerySection: String, CaseIterable, Identifiable {
    case identities, activity, provenance, differences, selection, states
    var id: String { rawValue }
    var title: String { switch self { case .identities: return LensL10n.text("Identités et lieux"); case .activity: return LensL10n.text("Activité et timeline"); case .provenance: return LensL10n.text("Provenance et citations"); case .differences: return LensL10n.text("Diffs et références"); case .selection: return LensL10n.text("Sélection et question"); case .states: return LensL10n.text("Chargement et limites") } }
    var symbol: String { switch self { case .identities: return "person.crop.circle"; case .activity: return "clock"; case .provenance: return "link"; case .differences: return "arrow.left.arrow.right"; case .selection: return "text.bubble"; case .states: return "exclamationmark.circle" } }
}
private enum GalleryAppearance: String, CaseIterable, Identifiable { case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return LensL10n.text("Système"); case .light: return LensL10n.text("Clair"); case .dark: return LensL10n.text("Sombre") } }
    var scheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}
private enum GalleryTextSize: String, CaseIterable, Identifiable { case standard, enlarged
    var id: String { rawValue }
    var title: String { self == .standard ? LensL10n.text("Standard") : LensL10n.text("Agrandie") }
    var metrics: LensComponentTypography { self == .standard ? .standard : .enlarged }
}
private enum GalleryReview {
    case event(LensEvent), agent(AgentRecord), environment(EnvironmentRecord), file(LensFileIdentity)
    case evidence(LensEvidenceReference), question(LensSelectionSummary), action(LensLoadAction)
    var title: String { switch self { case .event(let value): return value.title; case .agent(let value): return value.name; case .environment(let value): return value.path; case .file(let value): return value.relativePath; case .evidence(let value): return value.id + LensL10n.text(" · ") + value.title; case .question(let value): return value.title; case .action(let value): return LensL10n.text("Action : ") + value.title } }
}

/// Development-only projections of the same typed model objects as the application.
/// No source is opened, no client/store is constructed and no transport is available here.
struct ComponentGalleryView: View {
    let snapshot: SessionSnapshot
    @State private var section: LensGallerySection?
    @State private var appearance = GalleryAppearance.system
    @State private var textSize: GalleryTextSize
    @State private var review: GalleryReview?
    @State private var reviewPresented = false
    @State private var windowWidth: CGFloat = 0
    @State private var timelineZoom = 1.0

    /// Section and text-size inputs intentionally seed per-window development state once.
    init(snapshot: SessionSnapshot = LensDemoFixtures.snapshot(), initialSection: LensGallerySection = .identities, enlargedText: Bool = false) {
        self.snapshot = snapshot
        _section = State(initialValue: initialSection)
        _textSize = State(initialValue: enlargedText ? .enlarged : .standard)
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                List(selection: $section) {
                    ForEach(LensGallerySection.allCases) { item in Label(item.title, systemImage: LensSymbols.name(item.symbol)).tag(item) }
                }.listStyle(.sidebar).navigationTitle(LensL10n.text("Composants"))
                    .navigationSplitViewColumnWidth(min: 150, ideal: 205, max: 245)
            } detail: {
                VStack(alignment: .leading, spacing: 0) {
                    galleryNotice
                    Divider()
                    content
                    Divider()
                    Text(review.map { LensL10n.text("Sélection : ") + $0.title } ?? LensL10n.text("Aucune sélection."))
                        .font(.system(size: textSize.metrics.caption)).foregroundStyle(.secondary).padding(9).textSelection(.enabled)
                }.background(Color(nsColor: .windowBackgroundColor))
            }
            .inspector(isPresented: $reviewPresented) { reviewPane.inspectorColumnWidth(min: 240, ideal: 315, max: 410) }
            .lensMotionAware()
            .onChange(of: geometry.size.width, initial: true) { _, width in
                windowWidth = width
                if width < 920 { reviewPresented = false }
            }
        }
        .environment(\.lensComponentTypography, textSize.metrics)
        .symbolRenderingMode(.monochrome)
        .preferredColorScheme(appearance.scheme)
        .navigationTitle(LensL10n.text("Codex Lens · galerie de développement"))
        .toolbar {
            ToolbarItemGroup {
                Picker(LensL10n.text("Apparence"), selection: $appearance) { ForEach(GalleryAppearance.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                Picker(LensL10n.text("Taille du texte"), selection: $textSize) { ForEach(GalleryTextSize.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                Button { reviewPresented.toggle() } label: { Label(LensL10n.text("Inspecteur"), systemImage: LensSymbols.name("sidebar.right")) }
                    .help(LensL10n.text("Afficher ou masquer l’inspecteur"))
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .accessibilityIdentifier("component-gallery")
    }

    private var galleryNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(LensL10n.text("Données de démonstration"), systemImage: LensSymbols.name("hammer")).font(.system(size: textSize.metrics.body, weight: .semibold))
            Text(LensL10n.text("Exemples anonymisés avec des chemins fictifs. La galerie ne consulte aucune session. Les commandes de copie utilisent le presse-papiers."))
                .font(.system(size: textSize.metrics.caption)).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(12)
    }

    @ViewBuilder private var content: some View {
        switch section ?? .identities {
        case .identities: identities
        case .activity: activity
        case .provenance: provenance
        case .differences: differences
        case .selection: selectionExamples
        case .states: states
        }
    }

    private var identities: some View {
        List {
            Section(LensL10n.text("Événement et agent")) {
                if let event = snapshot.events.first(where: { $0.kind == .toolCall }) {
                    EventIdentityView(event: event, agentLabel: snapshot.agents.first(where: { $0.id == event.agentID })?.name, completeness: .partial) { select(.event($0)) }
                }
                ForEach(snapshot.agents) { agent in AgentIdentityView(agent: agent) { select(.agent($0)) } }
            }
            Section(LensL10n.text("Dépôt et worktrees distincts")) {
                ForEach(snapshot.environments) { environment in EnvironmentIdentityView(environment: environment, availability: .unknown) { select(.environment($0)) } }
            }
            Section(LensL10n.text("Même nom, worktrees distincts")) {
                ForEach(fileIdentities) { location in FileLocationView(location: location) { select(.file($0)) } }
            }
            Section(LensL10n.text("Types de ressources et disponibilité")) {
                LensResourceRowLabel(resource: ResourceRecord(location: "/fixture/Photo.TIF", roles: [.supplied], availability: .unknown))
                LensResourceRowLabel(resource: ResourceRecord(location: "/fixture/rapport.pdf", roles: [.referenced], availability: .missing))
                LensResourceRowLabel(resource: ResourceRecord(location: "trace:fixture:attachment:1", roles: [.supplied], availability: .missing))
                LensResourceRowLabel(resource: ResourceRecord(location: "https://example.invalid/document", roles: [.referenced], availability: .external))
                Text(LensL10n.text("Le symbole indique le type de ressource ; le texte précise sa disponibilité et son origine."))
                    .font(LensUI.metadata).foregroundStyle(.secondary)
            }
        }.listStyle(.inset)
    }

    private var activity: some View {
        List {
            Section(LensL10n.text("Pistes d’agents · au plus 32 événements")) {
                HStack {
                    Text(LensL10n.text("Zoom temporel")).font(.system(size: textSize.metrics.caption))
                    Slider(value: $timelineZoom, in: 1...3).frame(maxWidth: 200).accessibilityLabel(LensL10n.text("Zoom de la timeline de démonstration"))
                }
                GalleryTimeline(events: Array(snapshot.events.prefix(32)), agents: snapshot.agents, zoom: timelineZoom) { select(.event($0)) }
                    .frame(height: 315)
            }
            Section(LensL10n.text("Ordre et contexte")) {
                ForEach(snapshot.events.prefix(32)) { event in EventIdentityView(event: event, completeness: event.kind == .toolResult ? .partial : .unknown) { select(.event($0)) } }
            }
        }.listStyle(.inset)
    }

    private var provenance: some View {
        List {
            Section(LensL10n.text("Origine des données")) {
                ProvenanceView(certainty: .confirmed, explanation: LensL10n.text("Le même call_id relie cet appel à son résultat."), sourceLabel: "fixture-call-0-0")
                ProvenanceView(certainty: .correlation, explanation: LensL10n.text("Ces actions sont proches dans le temps, sans lien enregistré."))
                ProvenanceView(certainty: .unknown, explanation: LensL10n.text("L’auteur du diff actuel et le contenu de la pièce jointe sont inconnus."))
            }
            Section(LensL10n.text("État des citations")) {
                if let piece = LensDemoFixtures.evidencePieces().first {
                    EvidenceLinkView(reference: LensEvidenceReference(piece: piece), state: .validated, explanation: LensL10n.text("Source de démonstration.")) { select(.evidence($0)) }
                }
                EvidenceLinkView(reference: LensEvidenceReference(id: "E002", title: LensL10n.text("Version indisponible"), knownVersion: "fixture-ref-after"), state: .expired, explanation: LensL10n.text("Le lien est conservé ; la version citée est indisponible."))
                EvidenceLinkView(reference: LensEvidenceReference(id: "E999", title: "Identifiant absent de la sélection"), state: .unknown, explanation: LensL10n.text("Cette citation ne correspond à aucun élément du contexte envoyé."))
            }
        }.listStyle(.inset)
    }

    private var differences: some View {
        List {
            Section(LensL10n.text("Type de diff, versions et environnement")) {
                DiffBlockHeader(kind: .requestedPatch, provenance: demoDiffProvenance, filePath: fileIdentities.first?.path) { eventID in
                    if let event = snapshot.events.first(where: { $0.id == eventID }) { select(.event(event)) }
                }
                ProvenanceView(certainty: .unknown, explanation: LensL10n.text("Ce fragment vient du patch demandé. Son application et le contenu actuel du worktree sont inconnus."))
            }
            Section(LensL10n.text("Exemple de diff et numéros de lignes")) {
                ForEach(LensDemoFixtures.diffLines()) { line in GalleryDiffLine(line: line) }
            }
            Section(LensL10n.text("Diff Git actuel")) {
                DiffBlockHeader(kind: .currentGit, provenance: DiffProvenance(environmentID: LensDemoFixtures.worktreePaths[1], beforeReference: "fixture-HEAD", afterReference: "Contenu de travail illustré"))
            }
        }.listStyle(.inset)
    }

    private var selectionExamples: some View {
        List {
            Section(LensL10n.text("Contexte sélectionné")) {
                ForEach(fileIdentities) { location in FileLocationView(location: location) { select(.file($0)) } }
                SelectionQuestionPill(selection: demoSelection) { select(.question($0)) }
                Text(LensL10n.text("Préparer la question affiche les données de cet exemple. Rien n’est envoyé.")).font(.system(size: textSize.metrics.caption)).foregroundStyle(.secondary)
            }
            Section(LensL10n.text("Aucun élément sélectionné")) {
                SelectionQuestionPill(selection: LensSelectionSummary(title: LensL10n.text("Sélection vide"), sourceIDs: [], estimatedBytes: 0, versionLabel: LensL10n.text("Version non sélectionnée"), capturedAt: nil))
            }
            Section(LensL10n.text("Markdown du chat")) {
                LensChatMarkdownGalleryPreview(fontSize: textSize.metrics.body)
            }
        }.listStyle(.inset)
    }

    private var states: some View {
        List {
            Section(LensL10n.text("Chargement et erreurs")) {
                ForEach(GalleryLoadExample.examples) { example in
                    LensLoadStateView(state: example.state, retainedCount: example.retainsData ? snapshot.events.count : 0) { select(.action($0)) }
                }
            }
        }.listStyle(.inset)
    }

    private var reviewPane: some View {
        List {
            Section(LensL10n.text("Sélection")) {
                if let review {
                    switch review {
                    case .event(let event): EventIdentityView(event: event)
                    case .agent(let agent): AgentIdentityView(agent: agent)
                    case .environment(let environment): EnvironmentIdentityView(environment: environment)
                    case .file(let file): FileLocationView(location: file)
                    case .evidence(let evidence): EvidenceLinkView(reference: evidence, state: .validated)
                    case .question(let selection):
                        SelectionQuestionPill(selection: selection)
                        Text(LensL10n.text("Exemple de brouillon. Rien n’est envoyé.")).foregroundStyle(.secondary)
                    case .action(let action):
                        Text(action.title).font(.headline)
                        Text(LensL10n.text("Action sélectionnée dans la galerie.")).foregroundStyle(.secondary)
                    }
                    Button(LensL10n.text("Effacer la sélection")) { self.review = nil }
                } else { LensLoadStateView(state: .empty(subject: LensL10n.text("Aucune sélection"), message: LensL10n.text("Sélectionnez un élément pour afficher ses détails."))) }
            }
        }.listStyle(.inset)
    }

    private var fileIdentities: [LensFileIdentity] {
        snapshot.environments.map { LensFileIdentity(path: $0.path + "/Sources/Example.swift", environmentID: $0.id, versionLabel: "Version de démonstration : " + ($0.recordedRef ?? "inconnue"), observedAt: snapshot.collectedAt) }
    }
    private var demoDiffProvenance: DiffProvenance {
        DiffProvenance(environmentID: LensDemoFixtures.worktreePaths[0], eventIDs: ["fixture-event-8"], agentID: LensDemoFixtures.rootID,
                       beforeReference: "fixture-ref-before", afterReference: "Version demandée ; octets non observés")
    }
    private var demoSelection: LensSelectionSummary {
        LensSelectionSummary(title: LensL10n.text("Deux éléments sélectionnés"), sourceIDs: LensDemoFixtures.evidencePieces().map(\.id),
                             estimatedBytes: LensDemoFixtures.evidencePieces().reduce(0) { $0 + $1.text.utf8.count },
                             versionLabel: LensL10n.text("Versions de démonstration"), capturedAt: LensDemoFixtures.epoch)
    }
    private func select(_ value: GalleryReview) { review = value; if windowWidth >= 920 { reviewPresented = true } }
}

private struct GalleryLoadExample: Identifiable {
    let id: String
    let state: LensLoadState
    let retainsData: Bool
    static let examples = [
        GalleryLoadExample(id: "loading", state: .loading(subject: LensL10n.text("l’historique")), retainsData: true),
        GalleryLoadExample(id: "empty", state: .empty(subject: LensL10n.text("Filtre sans résultat"), message: LensL10n.text("Aucun événement dans cette période.")), retainsData: false),
        GalleryLoadExample(id: "missing", state: .missing(subject: LensL10n.text("Pièce jointe"), message: LensL10n.text("Référence enregistrée, contenu indisponible.")), retainsData: false),
        GalleryLoadExample(id: "permission", state: .permission(subject: LensL10n.text("Répertoire"), message: LensL10n.text("Autorisez l’accès au répertoire pour le consulter.")), retainsData: true),
        GalleryLoadExample(id: "error", state: .error(subject: LensL10n.text("Décodage de l’événement"), message: LensL10n.text("Ligne JSON incomplète. Les événements déjà chargés restent disponibles.")), retainsData: true),
        GalleryLoadExample(id: "cancelled", state: .cancelled(subject: LensL10n.text("la lecture")), retainsData: true),
        GalleryLoadExample(id: "incomplete", state: .incomplete(subject: LensL10n.text("Historique"), message: LensL10n.text("L’historique d’un sous-agent et la fin d’une sortie manquent.")), retainsData: true)
    ]
}

private struct GalleryDiffLine: View {
    var line: RecordedDiffLine
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.beforeLine.map(String.init) ?? LensL10n.text("—")).frame(width: 32, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.afterLine.map(String.init) ?? LensL10n.text("—")).frame(width: 32, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.kind == .added ? LensL10n.text("+") : line.kind == .removed ? LensL10n.text("−") : " ").foregroundStyle(line.kind == .removed ? Color.red : line.kind == .added ? Color.green : Color.secondary)
            Text(line.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(.system(size: type.code, design: .monospaced)).accessibilityElement(children: .combine)
            .accessibilityLabel(LensL10n.text("{0}, avant {1}, après {2}, {3}", String(describing: line.kind.rawValue), String(describing: line.beforeLine.map(String.init) ?? LensL10n.text("inconnu")), String(describing: line.afterLine.map(String.init) ?? LensL10n.text("inconnu")), String(describing: line.text)))
    }
}

private struct GalleryTimeline: View {
    var events: [LensEvent]
    var agents: [AgentRecord]
    var zoom: Double
    var onSelect: (LensEvent) -> Void
    @Environment(\.lensComponentTypography) private var type
    private var start: Date { events.first?.timestamp ?? LensDemoFixtures.epoch }
    private var duration: Double { max(3, (events.last?.timestamp ?? start).timeIntervalSince(start) + 1) }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(agents) { agent in
                    GridRow {
                        Text(agent.name).font(.system(size: type.caption)).frame(width: 145, alignment: .leading)
                        ZStack(alignment: .leading) {
                            ForEach(events.filter { $0.agentID == agent.id }) { event in
                                GalleryTimelineMark(event: event, agentLabel: agent.name, start: start, zoom: zoom, onSelect: onSelect)
                            }
                        }.frame(width: CGFloat(duration * 145 * zoom + 30), height: 28, alignment: .leading)
                    }
                }
            }.padding(.vertical, 8)
        }.accessibilityIdentifier("gallery-timeline")
    }
}

private struct GalleryTimelineMark: View {
    var event: LensEvent
    var agentLabel: String
    var start: Date
    var zoom: Double
    var onSelect: (LensEvent) -> Void
    private var width: CGFloat { CGFloat(max(24.0, (event.endTime?.timeIntervalSince(event.timestamp) ?? 0.12) * 145.0 * zoom)) }
    private var offset: CGFloat { CGFloat(event.timestamp.timeIntervalSince(start) * 145.0 * zoom) }
    private var symbol: String {
        if event.kind == .toolCall { return "wrench" }
        if event.kind == .toolResult { return "doc.text" }
        return event.isError ? "exclamationmark.circle" : "text.bubble"
    }
    var body: some View {
        Button { onSelect(event) } label: { Image(systemName: LensSymbols.name(symbol)) }
            .buttonStyle(.bordered).controlSize(.small).frame(width: width).offset(x: offset)
            .help(event.title + LensL10n.text(" · ") + event.id)
            .accessibilityLabel(event.title + LensL10n.text(", agent ") + agentLabel)
    }
}

#if DEBUG
#Preview("Galerie — clair") { ComponentGalleryView().preferredColorScheme(.light).frame(width: 1080, height: 760) }
#Preview("Galerie — sombre, texte agrandi") { ComponentGalleryView(initialSection: .provenance, enlargedText: true).preferredColorScheme(.dark).frame(width: 1080, height: 760) }
#endif
