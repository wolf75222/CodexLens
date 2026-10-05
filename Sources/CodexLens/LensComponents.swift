import AppKit
import SwiftUI
import LensCore

/// Small immutable typography contract, also used by the development gallery.
struct LensComponentTypography: Equatable {
    var body: CGFloat = 13
    var caption: CGFloat = 11
    var code: CGFloat = 13
    static let standard = LensComponentTypography()
    static let enlarged = LensComponentTypography(body: 16, caption: 14, code: 14)
}
private struct LensComponentTypographyKey: EnvironmentKey { static let defaultValue = LensComponentTypography.standard }
extension EnvironmentValues {
    var lensComponentTypography: LensComponentTypography {
        get { self[LensComponentTypographyKey.self] }
        set { self[LensComponentTypographyKey.self] = newValue }
    }
}

enum LensDataCompleteness: String, CaseIterable, Identifiable { case complete, partial, unknown
    var id: String { rawValue }
    var label: String { switch self { case .complete: return LensL10n.text("Contenu complet"); case .partial: return LensL10n.text("Contenu partiel"); case .unknown: return LensL10n.text("Contenu complet non confirmé") } }
    var symbol: String { switch self { case .complete: return "doc.text"; case .partial: return "doc.badge.ellipsis"; case .unknown: return "questionmark.circle" } }
}
enum LensProvenanceCertainty: String, CaseIterable, Identifiable { case confirmed, correlation, unknown
    var id: String { rawValue }
    var label: String { switch self { case .confirmed: return LensL10n.text("Lien enregistré"); case .correlation: return LensL10n.text("Lien possible"); case .unknown: return LensL10n.text("Lien inconnu") } }
    var symbol: String { switch self { case .confirmed: return "link"; case .correlation: return "arrow.triangle.branch"; case .unknown: return "questionmark.circle" } }
}
enum LensCitationState: String, CaseIterable, Identifiable { case validated, expired, unknown
    var id: String { rawValue }
    var label: String { switch self { case .validated: return LensL10n.text("Source retrouvée"); case .expired: return LensL10n.text("Source indisponible"); case .unknown: return LensL10n.text("Citation inconnue") } }
}

struct LensFileIdentity: Hashable, Identifiable {
    var path: String
    var environmentID: String
    var versionLabel: String
    var observedAt: Date?
    var id: String { environmentID + "\u{0}" + path + "\u{0}" + versionLabel }
    var relativePath: String {
        let prefix = environmentID.hasSuffix("/") ? environmentID : environmentID + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

struct LensEvidenceReference: Hashable, Identifiable {
    var id: String
    var title: String
    var knownVersion: String?
    var capturedAt: Date?
    var address: EvidenceAddress?
    var location: EvidenceLocation?
    var stableID: String { address.map { $0.rootID + "/" + $0.capsuleID + "/" + $0.pieceID } ?? id }
    init(id: String, title: String, knownVersion: String? = nil, capturedAt: Date? = nil, address: EvidenceAddress? = nil, location: EvidenceLocation? = nil) {
        self.id = id; self.title = title; self.knownVersion = knownVersion; self.capturedAt = capturedAt
        self.address = address; self.location = location
    }
    init(piece: EvidencePiece, address: EvidenceAddress? = nil) { self.init(id: piece.id, title: piece.title, knownVersion: piece.knownVersion, capturedAt: piece.capturedAt, address: address, location: piece.location) }
}

struct LensSelectionSummary: Hashable {
    var title: String
    var sourceIDs: [String]
    var estimatedBytes: Int
    var versionLabel: String
    var capturedAt: Date?
}

struct EventIdentityView: View {
    var event: LensEvent
    var agentLabel: String? = nil
    var completeness: LensDataCompleteness = .unknown
    var onSelect: ((LensEvent) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        LensOptionalAction(action: onSelect.map { callback in { callback(event) } }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Label(event.title.isEmpty ? LensComponentText.kind(event.kind) : event.title, systemImage: LensSymbols.name(LensComponentText.symbol(event.kind))).font(.system(size: type.body, weight: .medium))
                    Spacer(minLength: 8)
                    if event.isError { Label(LensL10n.text("Erreur enregistrée"), systemImage: LensSymbols.name("exclamationmark.circle")).foregroundStyle(LensAppearance.errorText).font(.system(size: type.caption)) }
                }
                Text(event.preview).font(.system(size: type.body)).textSelection(.enabled)
                LensMetadataLine(title: LensL10n.text("Agent"), value: agentLabel.map { $0 + LensL10n.text(" · ") + event.agentID } ?? event.agentID, monospaced: true)
                LensMetadataLine(title: LensL10n.text("Événement"), value: event.id, monospaced: true)
                HStack(spacing: 12) {
                    Label(LensComponentText.time(event.timestamp), systemImage: LensSymbols.name("clock"))
                    Label(completeness.label, systemImage: LensSymbols.name(completeness.symbol))
                }.font(.system(size: type.caption)).foregroundStyle(.secondary)
                if let environment = event.environmentID { LensMetadataLine(title: LensL10n.text("Environnement"), value: environment, monospaced: true) }
            }.padding(.vertical, 4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("event-identity-" + event.id)
    }
}

struct AgentIdentityView: View {
    var agent: AgentRecord
    var onSelect: ((AgentRecord) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        LensOptionalAction(action: onSelect.map { callback in { callback(agent) } }) {
            VStack(alignment: .leading, spacing: 5) {
                Label(agent.name.isEmpty ? agent.id : agent.name, systemImage: LensSymbols.name(LensSymbols.agent(agent.relation))).font(.system(size: type.body, weight: .medium))
                LensMetadataLine(title: LensL10n.text("Identité"), value: agent.id, monospaced: true)
                LensMetadataLine(title: LensL10n.text("Relation"), value: LensComponentText.relation(agent.relation))
                LensMetadataLine(title: LensL10n.text("Parent"), value: agent.parentID ?? LensL10n.text("Non enregistré"), monospaced: agent.parentID != nil)
                Text(agent.mission.isEmpty ? LensL10n.text("Mission non enregistrée.") : agent.mission).font(.system(size: type.body)).textSelection(.enabled)
                if !agent.accessible { Label(LensL10n.text("Historique inaccessible"), systemImage: LensSymbols.name("doc.questionmark")).font(.system(size: type.caption)).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("agent-identity-" + agent.id)
    }
}

struct EnvironmentIdentityView: View {
    var environment: EnvironmentRecord
    var availability: Availability = .unknown
    var onSelect: ((EnvironmentRecord) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        LensOptionalAction(action: onSelect.map { callback in { callback(environment) } }) {
            VStack(alignment: .leading, spacing: 5) {
                Label(environment.repositoryPath == nil ? LensL10n.text("Répertoire") : LensL10n.text("Dépôt et worktree"), systemImage: LensSymbols.name("folder")).font(.system(size: type.body, weight: .medium))
                LensMetadataLine(title: LensL10n.text("Dépôt"), value: environment.repositoryPath ?? LensL10n.text("Dépôt Git non enregistré"), monospaced: environment.repositoryPath != nil)
                LensMetadataLine(title: LensL10n.text("Environnement"), value: environment.path, monospaced: true)
                LensMetadataLine(title: LensL10n.text("Branche enregistrée"), value: environment.recordedBranch ?? LensL10n.text("Inconnue"), monospaced: true)
                LensMetadataLine(title: LensL10n.text("Référence enregistrée"), value: environment.recordedRef ?? LensL10n.text("Inconnue"), monospaced: true)
                Label(LensComponentText.availability(availability), systemImage: LensSymbols.name(availability == .missing ? "folder.badge.questionmark" : "info.circle")).font(.system(size: type.caption)).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("environment-identity-" + environment.id)
    }
}

struct FileLocationView: View {
    var location: LensFileIdentity
    var onOpen: ((LensFileIdentity) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LensOptionalAction(action: onOpen.map { callback in { callback(location) } }) {
                Label(location.relativePath, systemImage: LensSymbols.name(LensUI.fileSymbol(location.path))).font(.system(size: type.body, weight: .medium)).textSelection(.enabled)
            }
            LensMetadataLine(title: LensL10n.text("Chemin complet"), value: location.path, monospaced: true)
            LensMetadataLine(title: LensL10n.text("Environnement"), value: location.environmentID.isEmpty ? LensL10n.text("Non enregistré") : location.environmentID, monospaced: true)
            LensMetadataLine(title: LensL10n.text("Version"), value: location.versionLabel)
            LensMetadataLine(title: LensL10n.text("Date enregistrée"), value: location.observedAt.map(LensComponentText.time) ?? LensL10n.text("Non enregistré"))
        }.padding(.vertical, 4).accessibilityElement(children: .contain).accessibilityIdentifier("file-location-" + location.id)
    }
}

struct ProvenanceView: View {
    var certainty: LensProvenanceCertainty
    var explanation: String
    var sourceLabel: String? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(certainty.label, systemImage: LensSymbols.name(certainty.symbol)).font(.system(size: type.body, weight: .medium))
            Text(explanation).font(.system(size: type.body)).textSelection(.enabled)
            if let sourceLabel { LensMetadataLine(title: LensL10n.text("Source"), value: sourceLabel, monospaced: true) }
        }.padding(.vertical, 4).accessibilityElement(children: .combine).accessibilityIdentifier("provenance-" + certainty.id)
    }
}

struct DiffBlockHeader: View {
    var kind: RecordedDiffKind
    var provenance: DiffProvenance
    var filePath: String? = nil
    var onOpenEvent: ((String) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(LensComponentText.diffKind(kind), systemImage: LensSymbols.name("arrow.left.arrow.right")).font(.system(size: type.body, weight: .medium))
            if let filePath { LensMetadataLine(title: LensL10n.text("Fichier"), value: filePath, monospaced: true) }
            LensMetadataLine(title: LensL10n.text("Environnement"), value: provenance.environmentID, monospaced: true)
            LensMetadataLine(title: LensL10n.text("Avant"), value: provenance.beforeReference ?? LensL10n.text("Référence non enregistrée"), monospaced: true)
            LensMetadataLine(title: LensL10n.text("Après"), value: provenance.afterReference ?? LensL10n.text("Référence non enregistrée"), monospaced: true)
            if let agent = provenance.agentID { LensMetadataLine(title: LensL10n.text("Agent observateur"), value: agent, monospaced: true) }
            Text(provenance.authorEvidence ?? LensL10n.text("Cette trace ne permet pas d’identifier l’auteur de ces changements.")).font(.system(size: type.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            if let eventID = provenance.eventIDs.first, let onOpenEvent {
                Button(LensL10n.text("Ouvrir l’événement associé")) { onOpenEvent(eventID) }.buttonStyle(.link).font(.system(size: type.caption))
            }
        }.padding(.vertical, 4).accessibilityElement(children: .contain)
    }
}

/// The host supplies an index-validated state; a printed citation is never validated here.
struct EvidenceLinkView: View {
    var reference: LensEvidenceReference
    var state: LensCitationState
    var explanation: String? = nil
    var onOpen: ((LensEvidenceReference) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state == .validated, let onOpen {
                Button { onOpen(reference) } label: { Label(reference.id + LensL10n.text(" · ") + reference.title, systemImage: LensSymbols.name("link")) }.buttonStyle(.link).font(.system(size: type.body))
            } else { Label(reference.id + LensL10n.text(" · ") + reference.title, systemImage: LensSymbols.name(state == .expired ? "clock.badge.exclamationmark" : "questionmark.circle")).font(.system(size: type.body)) }
            Text(state.label).font(.system(size: type.caption)).foregroundStyle(.secondary)
            if let explanation { Text(explanation).font(.system(size: type.caption)).textSelection(.enabled) }
            if let version = reference.knownVersion { LensMetadataLine(title: LensL10n.text("Version citée"), value: version, monospaced: true) }
            if let time = reference.capturedAt { LensMetadataLine(title: LensL10n.text("Date de capture"), value: LensComponentText.time(time)) }
            if let location = reference.location {
                LensMetadataLine(title: LensL10n.text("Environnement cité"), value: location.environmentID, monospaced: true)
                LensMetadataLine(title: LensL10n.text("Fichier cité"), value: location.path, monospaced: true)
                LensMetadataLine(title: LensL10n.text("Version"), value: LensComponentText.versionKind(location.versionKind))
                LensMetadataLine(title: LensL10n.text("Coordonnées"), value: location.coordinates == .fragment ? LensL10n.text("Positions dans le fragment") : LensL10n.text("Lignes absolues"))
            }
        }.padding(.vertical, 4).accessibilityElement(children: .contain).accessibilityIdentifier("evidence-link-" + reference.stableID)
    }
}

/// Preparation only: a host may open a local draft; this component has no transport.
struct SelectionQuestionPill: View {
    var selection: LensSelectionSummary
    var onPrepare: ((LensSelectionSummary) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { onPrepare?(selection) } label: { Label(LensL10n.text("Préparer une question sur la sélection"), systemImage: LensSymbols.name("text.bubble")) }
                .buttonStyle(.bordered).controlSize(.small).disabled(selection.sourceIDs.isEmpty || onPrepare == nil)
                .help(LensL10n.text("Ajoute la sélection au brouillon sans l’envoyer."))
            Text(selection.title).font(.system(size: type.body)).textSelection(.enabled)
            Text(LensL10n.text("{0} · {1} octets estimés · {2}", String(describing: LensUI.count(selection.sourceIDs.count, singular: "source", plural: "sources")), String(describing: max(0, selection.estimatedBytes)), String(describing: selection.versionLabel))).font(.system(size: type.caption)).foregroundStyle(.secondary)
            if let time = selection.capturedAt { LensMetadataLine(title: LensL10n.text("Date de capture"), value: LensComponentText.time(time)) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("selection-question-pill")
    }
}

enum LensLoadAction: String, CaseIterable { case cancel, retry, chooseSource, resetFilters, showCoverage
    var title: String { switch self { case .cancel: return LensL10n.text("Annuler"); case .retry: return LensL10n.text("Réessayer"); case .chooseSource: return LensL10n.text("Choisir une source"); case .resetFilters: return LensL10n.text("Effacer les filtres"); case .showCoverage: return LensL10n.text("Voir les limites des traces") } }
}
enum LensLoadState: Equatable {
    case loading(subject: String)
    case empty(subject: String, message: String)
    case missing(subject: String, message: String)
    case permission(subject: String, message: String)
    case error(subject: String, message: String)
    case cancelled(subject: String)
    case incomplete(subject: String, message: String)
    var title: String { switch self { case .loading(let subject): return LensL10n.text("Chargement de ") + subject; case .empty(let subject, _): return subject; case .missing(let subject, _): return subject + LensL10n.text(" introuvable"); case .permission(let subject, _): return LensL10n.text("Accès non autorisé : ") + subject; case .error(let subject, _): return LensL10n.text("Échec : ") + subject; case .cancelled(let subject): return LensL10n.text("Chargement annulé : ") + subject; case .incomplete(let subject, _): return subject + LensL10n.text(" partiel") } }
    var message: String { switch self { case .loading: return LensL10n.text("Lecture en cours. Les données déjà chargées restent disponibles."); case .empty(_, let text), .missing(_, let text), .permission(_, let text), .error(_, let text), .incomplete(_, let text): return text; case .cancelled: return LensL10n.text("La lecture est arrêtée.") } }
    var symbol: String { switch self { case .loading: return "arrow.triangle.2.circlepath"; case .empty: return "line.3.horizontal.decrease.circle"; case .missing: return "doc.questionmark"; case .permission: return "lock"; case .error: return "exclamationmark.circle"; case .cancelled: return "stop.circle"; case .incomplete: return "doc.badge.ellipsis" } }
    var action: LensLoadAction { switch self { case .loading: return .cancel; case .empty: return .resetFilters; case .missing, .permission: return .chooseSource; case .error, .cancelled: return .retry; case .incomplete: return .showCoverage } }
}

struct LensLoadStateView: View {
    var state: LensLoadState
    var retainedCount: Int = 0
    var onAction: ((LensLoadAction) -> Void)? = nil
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if case .loading = state { LensProgressIndicator().controlSize(.small).accessibilityLabel(state.title) }
            else { Image(systemName: LensSymbols.name(state.symbol)).font(.system(size: type.body)).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title).font(.system(size: type.body, weight: .medium))
                Text(LensL10n.display(state.message)).font(.system(size: type.body)).foregroundStyle(.secondary).textSelection(.enabled)
                if retainedCount > 0 { Text(LensL10n.text("{0} éléments déjà chargés.", String(describing: retainedCount))).font(.system(size: type.caption)).foregroundStyle(.secondary) }
                if let onAction { Button(state.action.title) { onAction(state.action) }.controlSize(.small) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5).accessibilityElement(children: .contain)
    }
}

private struct LensOptionalAction<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content
    var body: some View { if let action { Button(action: action, label: content).buttonStyle(.plain) } else { content() } }
}
private struct LensMetadataLine: View {
    var title: String
    var value: String
    var monospaced = false
    @Environment(\.lensComponentTypography) private var type
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + LensL10n.text(" :")).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .system(size: type.code, design: .monospaced) : .system(size: type.caption)).textSelection(.enabled)
        }.font(.system(size: type.caption)).accessibilityElement(children: .combine)
    }
}
private enum LensComponentText {
    static func versionKind(_ value: EvidenceLocation.VersionKind) -> String { switch value { case .capturedCurrent: return LensL10n.text("Texte capturé à l’instant observé"); case .verifiedGitBlob: return LensL10n.text("Contenu Git vérifié"); case .verifiedReconstruction: return LensL10n.text("Reconstruction vérifiée par empreinte"); case .recordedFragment: return LensL10n.text("Fragment enregistré") } }
    static func time(_ date: Date) -> String { date == .distantPast ? LensL10n.text("Horodatage inconnu") : date.lensFormatted(date: .abbreviated, time: .standard) }
    static func availability(_ value: Availability) -> String { switch value { case .accessible: return LensL10n.text("Accessible localement"); case .missing: return LensL10n.text("Emplacement introuvable ou inaccessible"); case .external: return LensL10n.text("Ressource externe ; aucune lecture automatique"); case .unknown: return LensL10n.text("Disponibilité du contenu inconnue") } }
    static func relation(_ value: RelationKind) -> String { switch value { case .root: return LensL10n.text("Session racine"); case .subagent: return LensL10n.text("Sous-agent"); case .fork: return LensL10n.text("Fork de conversation"); case .continuation: return LensL10n.text("Reprise de conversation"); case .unknown: return LensL10n.text("Relation inconnue") } }
    static func diffKind(_ value: RecordedDiffKind) -> String { switch value { case .requestedPatch: return LensL10n.text("Patch demandé"); case .recordedDiff: return LensL10n.text("Diff enregistré"); case .observedTextComparison: return LensL10n.text("Comparaison de textes observés"); case .currentGit: return LensL10n.text("Diff Git actuel") } }
    static func kind(_ value: EventKind) -> String { switch value { case .user: return LensL10n.text("Message utilisateur"); case .assistant: return LensL10n.text("Réponse enregistrée"); case .instruction: return LensL10n.text("Instruction"); case .toolCall: return LensL10n.text("Appel d’outil"); case .toolResult: return LensL10n.text("Résultat d’outil"); case .delegation: return LensL10n.text("Délégation"); case .wait: return LensL10n.text("Attente"); case .error: return LensL10n.text("Erreur"); case .lifecycle: return LensL10n.text("Cycle de vie"); case .context: return LensL10n.text("Contexte"); case .compaction: return LensL10n.text("Compactage"); case .unknown: return LensL10n.text("Événement inconnu") } }
    static func symbol(_ value: EventKind) -> String { switch value { case .user, .assistant: return "text.bubble"; case .instruction: return "text.alignleft"; case .toolCall: return "wrench"; case .toolResult: return "doc.text"; case .delegation: return "person.2"; case .wait: return "hourglass"; case .error: return "exclamationmark.circle"; case .lifecycle: return "circle.dotted"; case .context: return "doc.on.doc"; case .compaction: return "arrow.down.forward.and.arrow.up.backward"; case .unknown: return "questionmark.circle" } }
}
