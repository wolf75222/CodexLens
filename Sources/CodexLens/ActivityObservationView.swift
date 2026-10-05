import SwiftUI
import LensCore

struct ActivityObservationView: View {
    @EnvironmentObject var store: LensStore
    let observation: RecordedActivityObservation
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(LensL10n.text("Sorties, tests et observations"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(observation.outputs.enumerated()), id: \.offset) { _, output in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(LensL10n.text(output.kind == .commandCapture ? "Capture de commande enregistrée" : "Résultat d’outil enregistré"), systemImage: LensSymbols.name("doc.text"))
                        Text(output.fieldPath).font(.caption.monospaced()).textSelection(.enabled)
                        Text(LensL10n.text("{0} octets enregistrés · {1}", String(output.utf8Count), LensL10n.text(output.isExplicitlyTruncated ? "troncature explicitement indiquée" : "complétude non prouvée"))).foregroundStyle(.secondary)
                    }.font(LensUI.metadata)
                }
                Text(LensL10n.text("La présence d’une sortie ne prouve pas son inclusion dans une requête modèle. Ouvrez Sortie ou Brut pour consulter les données progressivement.")).font(LensUI.metadata).foregroundStyle(.secondary)
                if let test = store.presentation?.activityEvidence.tests.first(where: { $0.activity.id == observation.id }) {
                    Label(LensL10n.text("Commande de test avec trace d’exécution"), systemImage: LensSymbols.name("testtube.2")).font(.caption.weight(.semibold))
                    Text(test.activity.explicitTestCommand ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    Text(LensL10n.text("Résultat enregistré : {0}", LensL10n.text(test.outcome.label))).font(LensUI.metadata)
                    Text(LensL10n.text("Modifications suivantes du même environnement · observation, couverture du test non déduite")).font(LensUI.metadata).foregroundStyle(.secondary)
                    ForEach(test.subsequentChangeIDs.prefix(12), id: \.self) { id in
                        if let change = store.change(id) { Button(change.path) { store.navigate(.change(id)) }.buttonStyle(.borderless).font(LensUI.metadata) }
                    }
                    if test.subsequentChangeIDs.count > 12 { Text(LensL10n.text("{0} autres changements restent consultables dans Modifications.", String(test.subsequentChangeIDs.count - 12))).font(LensUI.metadata) }
                }
                if let group = store.presentation?.activityEvidence.repeatedCallGroups.first(where: { !$0.eventIDs.allSatisfy { !observation.eventIDs.contains($0) } }) {
                    Text(LensL10n.text("{0} appels avec les mêmes arguments et environnement · répétition observée, cause inconnue", String(group.observationIDs.count))).font(LensUI.metadata)
                    ForEach(group.eventIDs.prefix(8), id: \.self) { InspectionEventLink(eventID: $0) }
                    if group.eventIDs.count > 8 { Text(LensL10n.text("Autres appels accessibles par recherche et filtres de la timeline.")).font(LensUI.metadata) }
                }
                ForEach(observation.recordedReads, id: \.identifier) { read in
                    Text(LensL10n.text("Version déclarée dans la trace : {0}", read.identifier)).font(.caption.monospaced()).textSelection(.enabled)
                }
                ForEach(Array(observation.limitations.enumerated()), id: \.offset) { _, limit in Text(LensL10n.display(limit)).font(LensUI.metadata).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        }.font(LensUI.metadata)
    }
}

struct FileActivityHistoryView: View {
    @EnvironmentObject var store: LensStore
    let history: RecordedFileHistory
    @State private var visibleCount = 12
    var body: some View {
        DisclosureGroup(LensL10n.text("Lectures et succession des modifications du fichier")) {
            LazyVStack(alignment: .leading, spacing: 7) {
                Text(history.environmentID).font(.caption.monospaced()).textSelection(.enabled)
                Text(history.path).font(.caption.monospaced()).textSelection(.enabled)
                ForEach(history.activities.prefix(visibleCount)) { activity in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.agentName(activity.agentID)).font(.caption.weight(.semibold))
                        Text(LensL10n.text(activity.isRequestOnly ? "Patch demandé · résultat non déduit" : "Action et résultat enregistrés")).font(LensUI.metadata)
                        ForEach(activity.changeIDs, id: \.self) { id in
                            if let change = store.change(id) { Button { store.navigate(.change(id)) } label: { Label(changeLabel(change.kind), systemImage: LensSymbols.name("plus.forwardslash.minus")) }.buttonStyle(.borderless).font(LensUI.metadata) }
                        }
                    }
                }
                if history.activities.count > visibleCount {
                    Button(LensL10n.text("Charger 12 actions supplémentaires · {0} restantes", String(history.activities.count - visibleCount))) { visibleCount += 12 }.controlSize(.small)
                }
                ForEach(history.reads.prefix(12)) { read in
                    ForEach(read.eventIDs, id: \.self) { InspectionEventLink(eventID: $0, title: "Lecture enregistrée") }
                    Text(LensL10n.text(read.recordedVersions.isEmpty ? "Version intégrale lue non identifiée" : "Référence de version enregistrée ; vérification des octets requise")).font(LensUI.metadata).foregroundStyle(.secondary)
                }
                if history.reads.count > 12 { Text(LensL10n.text("Autres lectures accessibles dans la ressource et sa timeline.")).font(LensUI.metadata) }
                Text(LensL10n.text("{0} chevauchements d’intervalles enregistrés · concurrence des octets non déduite", String(history.overlappingRecordedIntervals.count))).font(LensUI.metadata)
                ForEach(Array(history.limitations.enumerated()), id: \.offset) { _, limit in Text(LensL10n.display(limit)).font(LensUI.metadata).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        }.font(LensUI.metadata)
    }
}

private extension RecordedActivityOutcome {
    var label: String { switch self {
    case .succeeded: return "Succès explicitement enregistré"
    case .failed: return "Échec explicitement enregistré"
    case .unknown: return "Résultat non confirmé"
    case .conflicting: return "Résultats contradictoires"
    } }
}
