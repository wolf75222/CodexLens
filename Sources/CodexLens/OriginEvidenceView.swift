import SwiftUI
import LensCore

extension LensStore {
    func originObjectID(for target: Destination?) -> String? {
        switch target {
        case .event(let id): return OriginInspectionIndex.eventID(id)
        case .change(let id): return OriginInspectionIndex.changeID(id)
        case .agent(let id): return OriginInspectionIndex.agentID(id)
        default: return nil
        }
    }
}

/// A navigation surface over the same evidence IDs. No automatic AI analysis.
struct OriginEvidenceView: View {
    @EnvironmentObject var store: LensStore
    let selection: OriginSelection
    let target: Destination
    @State private var explanationsExpanded = false
    @State private var linksExpanded = false
    @State private var contributionsExpanded = false
    @State private var verificationExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(LensL10n.text("Origine et justification"), systemImage: LensSymbols.name("link")).font(.headline)
            if let agent = selection.object.agentID {
                Button { store.navigate(.agent(agent), newTab: true) } label: {
                    Label(LensL10n.text("Producteur de la trace · {0}", store.agentName(agent)), systemImage: LensSymbols.name("person.crop.circle"))
                }.buttonStyle(.borderless)
            }
            if selection.object.kind == .change, let change = store.change(selection.object.sourceID) {
                InspectionEventLink(eventID: change.eventID, title: "Action enregistrée de cette modification")
                Text(LensL10n.text("Worktree : {0}", change.environmentID)).font(LensUI.metadata).textSelection(.enabled)
                Text(LensL10n.text(change.kind == .requestedPatch ? "Patch demandé · application et effets à vérifier séparément" : change.kind == .recordedResult ? "Résultat enregistré · auteur de chaque ligne non déduit" : "Changement observé · attribution distincte de l’observation")).font(LensUI.metadata).foregroundStyle(.secondary)
            }
            let eventID = store.change(selection.object.sourceID)?.eventID ?? selection.object.sourceID
            if let code = store.originCodeReferences[eventID], code.environmentID == selection.object.environmentID,
               store.change(selection.object.sourceID).map({ code.belongs(to: $0) }) ?? true {
                Text(LensL10n.text("Référence du fragment sélectionné")).font(.caption.weight(.semibold))
                Text(code.path).font(.caption.monospaced()).textSelection(.enabled)
                Text(LensL10n.text("Avant : {0} · Après : {1}", code.beforeVersion ?? LensL10n.text("inconnue"), code.afterVersion ?? LensL10n.text("inconnue"))).font(.caption.monospaced()).textSelection(.enabled)
                Text(LensL10n.text("Lignes enregistrées : {0} → {1}", code.beforeLine.map(String.init) ?? code.beforeFragmentOffset.map { "·\($0)" } ?? LensL10n.text("non enregistrée"), code.afterLine.map(String.init) ?? code.afterFragmentOffset.map { "·\($0)" } ?? LensL10n.text("non enregistrée"))).font(LensUI.metadata)
                Text(LensL10n.text("· = position locale du fragment ; aucune ligne courante substituée")).font(LensUI.metadata).foregroundStyle(.secondary)
            }
            if let turn = selection.object.turnID { Text(LensL10n.text("Tour enregistré : {0}", turn)).font(.caption.monospaced()).textSelection(.enabled) }
            if !selection.missionEventIDs.isEmpty {
                Text(LensL10n.text("Missions et délégations parentes")).font(.caption.weight(.semibold))
                ForEach(selection.missionEventIDs, id: \.self) { id in
                    InspectionEventLink(eventID: id, title: LensL10n.text("Délégation par {0}", store.agentName(store.event(id)?.agentID ?? "")))
                        .accessibilityIdentifier("origin-parent-mission-" + id)
                    if selection.objects.first(where: { $0.id == OriginInspectionIndex.eventID(id) })?.availability == "opaque" {
                        Text(LensL10n.text("Mission opaque · contenu non déchiffré ; trace brute disponible")).font(LensUI.metadata).foregroundStyle(.secondary)
                    }
                }
            }
            if selection.object.kind == .agent {
                Button(LensL10n.text("Voir l’activité enregistrée de cet agent")) { store.showOriginAgentActivity(selection.object.sourceID) }.buttonStyle(.borderless)
            }
            if !selection.delegationEventIDs.isEmpty {
                Text(LensL10n.text("Délégations dans le contexte sélectionné")).font(.caption.weight(.semibold))
                ForEach(selection.delegationEventIDs, id: \.self) { id in InspectionEventLink(eventID: id) }
                ForEach(selection.missionTargetAgentIDs, id: \.self) { id in
                    Button { store.navigate(.agent(id), newTab: true) } label: { Label(LensL10n.text("Destinataire · {0}", store.agentName(id)), systemImage: LensSymbols.name("person.crop.circle")) }.buttonStyle(.borderless)
                }
            }
            if !selection.instructionEventIDs.isEmpty {
                Text(LensL10n.text("Demandes du même thread et tour · contexte associé")).font(.caption.weight(.semibold))
                ForEach(selection.instructionEventIDs, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 3) {
                        InspectionEventLink(eventID: id)
                        Button(LensL10n.text("Filtrer les actions associées")) { store.showInstructionActivity(id) }.buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
            if store.presentation?.originInspection.associatedEventIDsByInstruction[selection.object.sourceID] != nil {
                Button(LensL10n.text("Filtrer les actions associées")) { store.showInstructionActivity(selection.object.sourceID) }.buttonStyle(.borderless)
            }
            if let event = store.event(selection.object.sourceID), let facts = event.trace?.explanation {
                ExplanationFactsView(facts: facts)
            }
            DisclosureGroup(LensL10n.text("Explications enregistrées · {0}", String(selection.explanations.count)), isExpanded: $explanationsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(selection.explanations) { value in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(LensL10n.text(value.relation.label)).font(.caption.weight(.semibold))
                            Text(LensL10n.text(value.ordering)).font(LensUI.metadata).foregroundStyle(.secondary)
                            Text(LensL10n.text("Contexte de l’action : {0}", store.event(value.contextActionEventID)?.title ?? value.contextActionEventID)).font(LensUI.metadata)
                            ExplanationFactsView(facts: value.facts)
                            InspectionEventLink(eventID: value.eventID, title: "Lire l’explication originale")
                        }
                    }
                    if selection.omittedExplanationCount > 0 {
                        Text(LensL10n.text("Explications supplémentaires non affichées : {0} · consulter le tour dans Activité", String(selection.omittedExplanationCount))).font(LensUI.metadata).foregroundStyle(.secondary)
                    }
                }.padding(.top, 5)
            }
            if !selection.contributionChangeIDs.isEmpty {
                DisclosureGroup(LensL10n.text(selection.object.kind == .change ? "Contributions au même fichier et worktree" : "Modifications associées à l’instruction"), isExpanded: $contributionsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LensL10n.text("Succession enregistrée ; filiation d’un bloc et effets partiels non déduits.")).font(LensUI.metadata).foregroundStyle(.secondary)
                        ForEach(selection.contributionChangeIDs, id: \.self) { id in
                            if let c = store.change(id) {
                                Button { store.navigate(.change(id), newTab: true) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.path).font(.caption.monospaced()).lineLimit(2)
                                        Text("\(store.agentName(c.agentID)) · \(LensL10n.text(c.kind == .requestedPatch ? "Patch demandé" : c.kind == .recordedResult ? "Résultat enregistré" : "Changement observé"))").font(LensUI.metadata)
                                        Text(c.environmentID).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }.padding(.top, 5)
                }
            }
            if !selection.verificationEventIDs.isEmpty {
                DisclosureGroup(LensL10n.text("Vérifications enregistrées de cet environnement"), isExpanded: $verificationExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LensL10n.text("Même environnement ; couverture de cette modification et causalité non établies.")).font(LensUI.metadata).foregroundStyle(.secondary)
                        ForEach(selection.verifications) { value in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LensL10n.text(value.relation.label)).font(LensUI.metadata)
                                Text(LensL10n.text(value.ordering)).font(LensUI.metadata)
                                Text(LensL10n.text(value.versionCoverage)).font(LensUI.metadata).foregroundStyle(.secondary)
                                ForEach(value.eventIDs, id: \.self) { id in InspectionEventLink(eventID: id) }
                                if let scope = value.changeScope { Text(LensL10n.text(scope)).font(LensUI.metadata).foregroundStyle(.secondary) }
                                if !value.subsequentChangeIDs.isEmpty || (value.omittedSubsequentChangeCount ?? 0) > 0 {
                                    Text(LensL10n.text("Modifications enregistrées après ce test : {0}", String(value.subsequentChangeIDs.count + (value.omittedSubsequentChangeCount ?? 0)))).font(LensUI.metadata)
                                }
                                if let omitted = value.omittedSubsequentChangeCount, omitted > 0 {
                                    Text(LensL10n.text("Références supplémentaires : {0} · ouvrir le test pour l’observation complète", String(omitted))).font(LensUI.metadata).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(.top, 5)
                }
            }
            ForEach(Array(selection.missing.enumerated()), id: \.offset) { _, text in Text(LensL10n.display(text)).font(LensUI.metadata).foregroundStyle(.secondary) }
            DisclosureGroup(LensL10n.text("Relations et sources · {0}", String(selection.links.count)), isExpanded: $linksExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(LensL10n.text("Les horaires sont ceux des enregistrements ou notifications ; l’instant de décision n’est pas établi.")).font(LensUI.metadata)
                    ForEach(selection.links) { link in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LensL10n.text(link.relation)).font(.caption.weight(.semibold))
                            Text(LensL10n.text(link.nature.label)).font(LensUI.metadata).foregroundStyle(.secondary)
                            ForEach(Array(link.sources.prefix(2).enumerated()), id: \.offset) { _, source in
                                Text("\(URL(fileURLWithPath: source.path).lastPathComponent) · \(source.line) · \(source.offset)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    if selection.omittedLinkCount > 0 { Text(LensL10n.text("Relations supplémentaires non affichées : {0}", String(selection.omittedLinkCount))).font(LensUI.metadata) }
                }.padding(.top, 5)
            }
            Menu(LensL10n.text("Préparer une question")) {
                Button(LensL10n.text("Ajouter à la question")) { store.prepareQuestion(for: target) }
                Button(LensQuestionIntent.explainChange.title) { store.prepareQuestion(for: target, intent: .explainChange) }
                Button(LensQuestionIntent.traceOrigin.title) { store.prepareQuestion(for: target, intent: .traceOrigin) }
                Button(LensQuestionIntent.compareInstruction.title) { store.prepareQuestion(for: target, intent: .compareInstruction) }
                Button(LensQuestionIntent.verifyJustification.title) { store.prepareQuestion(for: target, intent: .verifyJustification) }
            }.disabled(!store.canPerform(.investigate, target: target)).controlSize(.small)
        }.padding(.vertical, 8)
        .contextMenu {
            LensQuestionMenu(store: store, target: target)
            LensActionButton(store: store, action: .copyLink, target: target)
        }
    }
}

struct ExplanationFactsView: View {
    let facts: RecordedExplanationFacts
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LensL10n.text(kindLabel)).font(.caption.weight(.semibold))
            switch facts.availability {
            case .available:
                Text(facts.preview).font(LensUI.body).textSelection(.enabled)
                if facts.previewTruncated { Text(LensL10n.text("Aperçu borné · le texte original s’ouvre progressivement")).font(LensUI.metadata).foregroundStyle(.secondary) }
            case .empty: Text(LensL10n.text("Champ présent mais vide · aucune explication ajoutée"))
            case .opaque: Text(LensL10n.text("Représentation opaque · contenu non interprété"))
            case .unavailable: Text(LensL10n.text("Contenu non disponible · production et collecte inconnues"))
            }
            if facts.kind == .reasoningSummary { Text(LensL10n.text("Résumé exposé · pas une transcription exhaustive de pensée")).font(LensUI.metadata).foregroundStyle(.secondary) }
            Text(LensL10n.text("Horodatage d’enregistrement · génération non établie")).font(LensUI.metadata).foregroundStyle(.secondary)
        }
    }
    private var kindLabel: String {
        switch facts.kind {
        case .reasoningSummary: return "Résumé de raisonnement exposé"
        case .exposedReasoning: return "Texte de raisonnement exposé"
        case .agentMessage: return "Message enregistré de l’agent"
        case .plan: return "Plan enregistré"
        }
    }
}
