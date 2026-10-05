import SwiftUI
import LensCore

struct CompactionEvidenceView: View {
    @EnvironmentObject var store: LensStore
    let compaction: RecordedCompaction
    @State private var comparison = false
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(LensL10n.text("Contexte et compactage"), systemImage: LensSymbols.name("arrow.down.forward.and.arrow.up.backward")).font(.headline)
            Text(LensL10n.text(compaction.visibility.label)).font(LensUI.body)
            Text(LensL10n.text("Non retrouvé dans le texte visible ne signifie pas oublié.")).font(LensUI.metadata).foregroundStyle(.secondary)
            inspectionField("Déclenchement enregistré", compaction.trigger.map { $0 == "manual" ? LensL10n.text("Manuel") : LensL10n.text("Automatique") } ?? LensL10n.text("Inconnu"))
            inspectionField("Début de l’opération", compaction.startTime?.ISO8601Format() ?? LensL10n.text("Non enregistré"))
            inspectionField("Fin de l’opération", compaction.endTime?.ISO8601Format() ?? LensL10n.text("Non enregistrée"))
            if let duration = compaction.duration { inspectionField("Durée enregistrée", LensUI.duration(duration, fractionDigits: 3)) }
            ProvenanceView(certainty: compaction.association == .confirmed ? .confirmed : compaction.association == .sourceOrderCorrelation ? .correlation : .unknown,
                           explanation: LensL10n.text(compaction.association == .confirmed ? "Identifiants enregistrés communs." : compaction.association == .sourceOrderCorrelation ? "Association par ordre dans une borne unique du même journal." : "Aucune opération unique ne peut être associée à cette trace."))
            HStack {
                Button(LensL10n.text("Ajouter à la question")) { store.perform(.investigate, target: .event(compaction.eventID)) }
                    .disabled(!store.canPerform(.investigate, target: .event(compaction.eventID)))
                Button(LensL10n.text("Comparer")) { comparison.toggle() }
            }.controlSize(.small)
            DisclosureGroup(LensL10n.text("Avant / après : données disponibles"), isExpanded: $comparison) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LensL10n.text("Contexte intégral avant : non établi par cet adaptateur de journaux.")).font(LensUI.metadata)
                    if let before = compaction.beforeUsage { UsageEvidenceView(sample: before, heading: "Mesure précédente") }
                    else { Text(LensL10n.text("Mesure précédente : non enregistrée")).font(LensUI.metadata) }
                    Text(LensL10n.text("Après : seuls les textes conservés accessibles sont lisibles dans Contenu ; la partie opaque reste opaque.")).font(LensUI.metadata)
                    if let after = compaction.afterUsage { UsageEvidenceView(sample: after, heading: "Mesure suivante") }
                    else { Text(LensL10n.text("Mesure suivante : non enregistrée")).font(LensUI.metadata) }
                    Text(LensL10n.text("Ces mesures ne constituent pas deux bornes comparables : aucun taux de compression n’est calculé.")).font(LensUI.metadata).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }
            if !compaction.firstFollowingActionIDs.isEmpty {
                Text(LensL10n.text("Première action suivante · ordre du journal, sans causalité déduite")).font(LensUI.metadata).foregroundStyle(.secondary)
                ForEach(compaction.firstFollowingActionIDs, id: \.self) { id in InspectionEventLink(eventID: id) }
            }
            DisclosureGroup(LensL10n.text("Identifiants, sources et limites"), isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 7) {
                    inspectionField("Thread producteur", compaction.threadID)
                    ForEach(compaction.operationIDs, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    ForEach(compaction.eventIDs, id: \.self) { id in InspectionEventLink(eventID: id) }
                    ForEach(Array(compaction.limits.enumerated()), id: \.offset) { _, limit in Text(LensL10n.display(limit)).font(LensUI.metadata).foregroundStyle(.secondary) }
                }.padding(.top, 5)
            }
        }.padding(.vertical, 8)
    }
}

struct UsageEvidenceView: View {
    let sample: RecordedUsageSample
    var heading: String = "Mesure de tokens"
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LensL10n.text(heading)).font(.caption.weight(.semibold))
            Text(LensL10n.text(sample.semantics.label)).font(LensUI.metadata)
            if let total = sample.facts.cumulative?.total { Text(LensL10n.text("Consommation cumulée : {0} tokens", String(total))).font(.caption.monospacedDigit()) }
            if let value = sample.facts.request?.total { Text(LensL10n.text("Cette requête : {0} tokens", String(value))).font(.caption.monospacedDigit()) }
            if let value = sample.facts.last?.total { Text(LensL10n.text(sample.semantics == .renderedContextEstimate ? "Estimation du contexte : {0} tokens" : "Dernière mesure : {0} tokens", String(value))).font(.caption.monospacedDigit()) }
            if let capacity = sample.facts.modelContextWindow { Text(LensL10n.text("Capacité annoncée du modèle : {0} tokens", String(capacity))).font(LensUI.metadata).foregroundStyle(.secondary) }
            InspectionEventLink(eventID: sample.eventID)
        }
    }
}

struct CommunicationEvidenceView: View {
    @EnvironmentObject var store: LensStore
    let communication: RecordedCommunication
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(LensL10n.text("Échange inter-agent"), systemImage: LensSymbols.name("arrow.left.arrow.right")).font(.headline)
            inspectionField("Émetteur", communication.senderAgentID.map(store.agentName) ?? communication.senderPath ?? LensL10n.text("Inconnu"))
            inspectionField("Destinataires", store.communicationRecipientNames(communication).joined(separator: ", ").nonempty ?? LensL10n.text("Inconnus"))
            CommunicationStagesView(communication: communication)
            if communication.isOpaque { Text(LensL10n.text("Message partiellement ou entièrement opaque ; aucun contenu déduit.")).font(LensUI.metadata) }
            Text(LensL10n.text("Ces états ne prouvent ni compréhension ni application.")).font(LensUI.metadata).foregroundStyle(.secondary)
            if let trigger = communication.triggerTurn { inspectionField("Relance demandée", LensL10n.text(trigger ? "Oui" : "Non · message en file")) }
            if let id = communication.eventIDs.first {
                HStack {
                    Button(LensL10n.text("Ajouter à la question")) { store.perform(.investigate, target: .event(id)) }
                    Button(LensL10n.text("Comparer")) { advanced.toggle() }
                }.controlSize(.small)
            }
            ForEach(communication.originEventIDs, id: \.self) { id in InspectionEventLink(eventID: id, title: "Retrouver l’origine") }
            if communication.originEventIDs.isEmpty { Text(LensL10n.text("Envoi d’origine non retrouvé dans les données visibles.")).font(LensUI.metadata).foregroundStyle(.secondary) }
            ForEach(communication.missionEventIDs, id: \.self) { id in
                let owner = store.presentation?.communicationInspection.instructionByEventID[id]?.agentID ?? store.event(id)?.agentID
                InspectionEventLink(eventID: id, title: LensL10n.text("Mission et instruction d’origine · {0}", owner.map(store.agentName) ?? LensL10n.text("Inconnu")))
            }
            ForEach(communication.recipientAgentIDs, id: \.self) { id in
                Button { store.navigate(.agent(id), newTab: true) } label: { Label(store.agentName(id), systemImage: LensSymbols.name("person.crop.circle")) }.buttonStyle(.borderless)
                if !(store.presentation?.changesByAgent[id] ?? []).isEmpty {
                    Button(LensL10n.text("Modifications enregistrées de cet agent")) { store.agentFilter = id; store.section = .changes }.buttonStyle(.borderless)
                }
            }
            DisclosureGroup(LensL10n.text("Traces, identifiants et maillons manquants"), isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(communication.id).font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(communication.recipientAgentIDs, id: \.self) { id in
                        Text(store.agentName(id) + " · " + LensL10n.text(communication.recipientContextEventIDsByAgent[id]?.isEmpty == false ? "Contexte enregistré" : "Réception non prouvée")).font(LensUI.metadata)
                    }
                    ForEach(communication.eventIDs, id: \.self) { InspectionEventLink(eventID: $0) }
                    ForEach(Array(communication.limitations.enumerated()), id: \.offset) { _, limit in Text(LensL10n.display(limit)).font(LensUI.metadata).foregroundStyle(.secondary) }
                }.padding(.top, 5)
            }
        }.padding(.vertical, 8)
    }
}

struct CommunicationStagesView: View {
    let communication: RecordedCommunication
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            stage("Envoi demandé", known: !communication.sentEventIDs.isEmpty)
            stage("Résultat d’outil enregistré", known: !communication.toolResultEventIDs.isEmpty)
            stage("Soumission acceptée", known: !communication.submissionEventIDs.isEmpty)
            stage("Au moins un contexte destinataire enregistré", known: !communication.recipientContextEventIDs.isEmpty)
            stage("Inclusion dans une requête confirmée", known: !communication.modelInclusionEventIDs.isEmpty)
        }.font(LensUI.metadata).accessibilityElement(children: .combine)
    }
    private func stage(_ title: String, known: Bool) -> some View {
        Label(LensL10n.text(title) + " · " + LensL10n.text(known ? "Trace présente" : "Non prouvé"), systemImage: LensSymbols.name(known ? "checkmark.circle" : "questionmark.circle")).foregroundStyle(known ? Color.primary : Color.secondary)
    }
}

struct InstructionEvidenceView: View {
    @EnvironmentObject var store: LensStore
    let instruction: RecordedInstruction
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(LensL10n.text(instruction.kind.label), systemImage: LensSymbols.name("text.alignleft")).font(.caption.weight(.semibold))
            if let parent = instruction.inheritedFromThreadID ?? instruction.parentAgentID {
                Button { store.navigate(.agent(parent), newTab: true) } label: { Text(LensL10n.text("Parent : {0}", store.agentName(parent))) }.buttonStyle(.borderless)
            }
            Text(LensL10n.text("Instruction enregistrée ; son application n’est pas déduite.")).font(LensUI.metadata).foregroundStyle(.secondary)
            ForEach(Array(instruction.limitations.enumerated()), id: \.offset) { _, limit in Text(LensL10n.display(limit)).font(LensUI.metadata).foregroundStyle(.secondary) }
        }
    }
}

struct AgentInstructionHistoryView: View {
    @EnvironmentObject var store: LensStore
    let agentID: String
    var body: some View {
        DisclosureGroup(LensL10n.text("Instructions et contexte enregistrés")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach((store.presentation?.communicationInspection.instructions ?? []).filter { $0.agentID == agentID }) { instruction in
                    InspectionEventLink(eventID: instruction.eventID, title: instruction.kind.label)
                }
                Text(LensL10n.text("Les instructions absentes ou opaques ne sont pas reconstituées.")).font(LensUI.metadata).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }.font(LensUI.metadata)
    }
}

struct InspectionEventLink: View {
    @EnvironmentObject var store: LensStore
    let eventID: String
    var title: String? = nil
    var body: some View {
        if let event = store.event(eventID) {
            Button { store.showInTimeline(eventID); store.inspectorVisible = true } label: {
                Label(title.map { LensL10n.text($0) } ?? LensL10n.display(event.title), systemImage: LensSymbols.name("link")).multilineTextAlignment(.leading)
            }.buttonStyle(.borderless).font(LensUI.metadata)
        } else { Label(LensL10n.text("Événement lié indisponible"), systemImage: LensSymbols.name("doc.questionmark")).font(LensUI.metadata) }
    }
}

private func inspectionField(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(LensL10n.text(label)).font(LensUI.metadata).foregroundStyle(.secondary)
        Text(value).font(LensUI.body).textSelection(.enabled)
    }
}
private extension CompactionVisibility {
    var label: String { switch self {
    case .readableText: return "Texte conservé accessible"
    case .opaque: return "Représentation compacte opaque"
    case .mixed: return "Texte conservé et représentation opaque"
    case .unavailable: return "Contenu après compactage indisponible"
    case .boundaryOnly: return "Borne enregistrée · contenu non disponible"
    } }
}
private extension UsageMeasurementSemantics {
    var label: String { switch self {
    case .cumulativeAndLastRequest: return "Consommation cumulée et dernière requête"
    case .providerRequest: return "Consommation de la requête identifiée"
    case .renderedContextEstimate: return "Estimation du contexte après compactage"
    case .unknown: return "Sémantique de la mesure non confirmée"
    } }
}
private extension RecordedCommunicationFacts.InstructionKind {
    var label: String { switch self {
    case .base: return "Instructions de base enregistrées"
    case .direct: return "Instruction directe enregistrée"
    case .inherited: return "Contexte hérité enregistré"
    case .later: return "Correction ultérieure explicitement enregistrée"
    case .unknown: return "Origine de l’instruction inconnue"
    } }
}

// The confirmed spawn mission already identifies its child; the original task alias
// remains in trace facts and arguments rather than becoming a second endpoint.
extension LensStore {
    func communicationRecipientNames(_ communication: RecordedCommunication) -> [String] {
        let names = communication.recipientAgentIDs.map(agentName)
        let paths = communication.kind == .spawn && communication.recipientAgentIDs.count == 1 ? [] : communication.recipientPaths
        return Array(NSOrderedSet(array: names + paths)).compactMap { $0 as? String }
    }
}
