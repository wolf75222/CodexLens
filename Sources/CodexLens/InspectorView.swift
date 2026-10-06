import SwiftUI
import Observation
import AppKit
import LensCore

struct InspectorView: View {
    var heading: String? = nil
    var embedded = false
    @Environment(\.lensWindowContext) private var windowContext
    @EnvironmentObject var store: LensStore
    @State private var detailPart = "Contenu"
    @State private var detailsExpanded = false
    @State private var sourceProvenanceExpanded = false
    private var contextOnly: Bool {
        !embedded && store.selectedEvent.map { $0.id == store.centrallyPresentedEventID } == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(heading ?? LensL10n.text("Inspecteur")).font(LensUI.paneTitle).lineLimit(2)
                    .truncationMode(.middle).help(heading ?? LensL10n.text("Inspecteur"))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if store.selection != nil, !contextOnly {
                    LensActionButton(store: store, action: .investigate).buttonStyle(LensQuietButtonStyle()).controlSize(.small)
                        .help(LensL10n.text("Préparer le contexte à consulter, sans l’envoyer."))
                        .accessibilityIdentifier("lens-inspector-investigate")
                }
                Menu {
                    if contextOnly { LensActionButton(store: store, action: .investigate) }
                    LensActionButton(store: store, action: .copyLink)
                    if let event = store.selectedEvent {
                        Button(LensL10n.text("Afficher dans la timeline")) { store.showInTimeline(event.id) }
                    }
                    Divider()
                    LensActionButton(store: store, action: .chat)
                    Button(LensL10n.text("Masquer l’inspecteur")) {
                        windowContext?.focusPane(.content, afterLayout: true)
                        store.inspectorVisible = false
                    }
                } label: { LensIconMenuLabel() }
                    .lensIconMenu("Actions de l’inspecteur")
                    .accessibilityIdentifier("lens-inspector-more")
            }.padding(.horizontal, 16).padding(.vertical, 10).background(LensBrand.chrome)
            Divider()
            if let event = store.selectedEvent {
                if contextOnly {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            eventSummary(event)
                            Divider()
                            eventRelations(event)
                            DisclosureGroup(LensL10n.text("Détails"), isExpanded: $detailsExpanded) {
                                eventMetadata(event).padding(.top, 10)
                            }.font(LensUI.metadata)
                                .accessibilityIdentifier("lens-inspector-details")
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("lens-inspector-context-only")
                } else {
                VStack(alignment: .leading, spacing: 10) {
                    eventSummary(event)
                    DisclosureGroup(LensL10n.text("Détails"), isExpanded: $detailsExpanded) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                eventRelations(event)
                                eventMetadata(event)
                            }.padding(.top, 8).padding(.trailing, 4)
                        }.frame(height: 230)
                    }.font(LensUI.metadata)
                        .accessibilityIdentifier("lens-inspector-details")
                }.padding(.horizontal, 16).padding(.vertical, 12)
                    .contextMenu {
                        LensQuestionMenu(store: store, target: .event(event.id))
                        LensActionButton(store: store, action: .copyLink, target: .event(event.id))
                    }
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Picker(LensL10n.text("Données"), selection: $detailPart) {
                        ForEach(["Contenu", "Entrée", "Sortie", "Brut"], id: \.self) { Text(LensL10n.display($0)).tag($0) }.id(LensL10n.resolvedLanguage.rawValue)
                    }.labelsHidden().pickerStyle(.segmented).lensFilledControlAccent().frame(maxWidth: 460, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    if detailPart == "Brut" { Text(LensL10n.text("Événements source · secrets reconnaissables masqués")).font(LensUI.metadata).foregroundStyle(.secondary).padding(.horizontal, 10) }
                    RecordedEventText(event: event, part: detailPart == "Entrée" ? "input" : detailPart == "Sortie" ? "output" : detailPart == "Brut" ? "raw" : "content").id(event.id + detailPart)
                }.frame(minHeight: 180, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { objectMetadata }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: store.selection) { _, _ in
                detailsExpanded = false
                sourceProvenanceExpanded = false
            }
            .onChange(of: store.selectedEvent?.id, initial: true) { _, _ in
                // A new object starts at its recorded payload. Updates to the
                // same event preserve the section explicitly chosen by the reader.
                switch store.selectedEvent?.kind {
                case .toolCall, .delegation: detailPart = "Entrée"
                case .toolResult: detailPart = "Sortie"
                default: detailPart = "Contenu"
                }
            }
    }
    private func eventRelations(_ event: LensEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            metadata(LensL10n.text("Agent"), value: store.agentName(event.agentID)) { store.navigate(.agent(event.agentID), newTab: true) }
            if let env = event.environmentID {
                metadata(LensL10n.text("Environnement"), value: URL(fileURLWithPath: env).lastPathComponent) { store.navigate(.environment(env)) }
            }
            if let other = event.relatedEventID {
                metadata(LensL10n.text("Action liée"), value: LensL10n.text("Ouvrir l’appel / le résultat")) { store.navigate(.event(other), newTab: true) }
            }
            if !event.resourceIDs.isEmpty {
                Text(LensL10n.text("Ressources")).font(LensUI.metadata).foregroundStyle(.secondary)
                ForEach(event.resourceIDs, id: \.self) { id in
                    if let resource = store.snapshot?.resources.first(where: { $0.id == id }) {
                        Button { store.navigate(.resource(id)) } label: {
                            Label(LensUI.resourceTitle(resource), systemImage: LensSymbols.name("paperclip")).lineLimit(2)
                        }.buttonStyle(.borderless).help(resource.name + "\n" + resource.location)
                    }
                }
            }
        }.font(LensUI.metadata).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func eventSummary(_ event: LensEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.kind == .compaction ? LensL10n.text(event.title.nonempty ?? event.kind.label) : event.title.nonempty ?? event.kind.label)
                .font(LensUI.sectionTitle).lineLimit(3).textSelection(.enabled)
                .help(event.title.nonempty ?? event.kind.label)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.kind.label + " · " + store.agentName(event.agentID)).lineLimit(2).truncationMode(.middle)
                    .help(event.kind.label + " · " + store.agentName(event.agentID))
                Spacer(minLength: 4)
                if event.timestamp == .distantPast { Text(LensL10n.text("Horodatage non enregistré")) }
                else { Text(event.timestamp, format: .dateTime.day().month().hour().minute().second()) }
            }.font(LensUI.metadata).foregroundStyle(.secondary)
            if let env = event.environmentID {
                let path = store.snapshot?.environments.first(where: { $0.id == env })?.path ?? env
                Text(LensL10n.text("Worktree : {0}", path)).font(LensUI.metadata).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
            }
        }
    }
    private func eventMetadata(_ event: LensEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = store.selection, let objectID = store.originObjectID(for: target), let origin = store.presentation?.originInspection.selection(objectID: objectID) {
                OriginEvidenceView(selection: origin, target: target).id(objectID)
            }
            if let compaction = store.presentation?.contextInspection.compactionByEventID[event.id] { CompactionEvidenceView(compaction: compaction) }
            if let communication = store.presentation?.communicationInspection.communicationByEventID[event.id] { CommunicationEvidenceView(communication: communication) }
            if let instruction = store.presentation?.communicationInspection.instructionByEventID[event.id] { InstructionEvidenceView(instruction: instruction) }
            if let observation = store.presentation?.activityEvidence.observationsByEventID[event.id] { ActivityObservationView(observation: observation) }
            if let sample = store.presentation?.contextInspection.usageSamples.first(where: { $0.eventID == event.id }) { UsageEvidenceView(sample: sample) }
            if let tool = event.toolName { field(LensL10n.text("Outil"), tool) }
            if let call = event.callID { field(LensL10n.text("Appel"), call, monospaced: true) }
            if let turn = event.turnID { field(LensL10n.text("Tour"), turn, monospaced: true) }
            if let end = event.endTime { field(LensL10n.text("Durée enregistrée"), LensUI.duration(max(0, end.timeIntervalSince(event.timestamp)), fractionDigits: 3)) }
            if case .change(let id) = store.selection, let change = store.change(id),
               let history = store.presentation?.activityEvidence.fileHistories.first(where: { $0.environmentID == change.environmentID && $0.path == change.path }) {
                FileActivityHistoryView(history: history)
            }
            DisclosureGroup(LensL10n.text("Sources enregistrées · {0} traces", String(describing: 1 + event.supplementarySources.count)), isExpanded: $sourceProvenanceExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    field(LensL10n.text("Journal · ligne {0}", String(describing: event.source.line)), event.source.path, monospaced: true)
                    field(LensL10n.text("Position"), LensL10n.text("{0} · {1} octets", String(describing: event.source.offset), String(describing: event.source.length)))
                    ForEach(Array(event.supplementarySources.enumerated()), id: \.offset) { _, source in field(LensL10n.text("Trace complémentaire · ligne {0}", String(describing: source.line)), source.path, monospaced: true) }
                }.padding(.top, 6)
            }.font(LensUI.metadata).controlSize(.small)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var objectMetadata: some View {
        if let selection = store.selection, let snap = store.snapshot {
            switch selection {
            case .agent(let id):
                if let a = snap.agents.first(where: { $0.id == id }) {
                    Text(a.name.nonempty ?? a.id).font(.headline)
                    Text(a.accessible ? LensL10n.text("Journal accessible") : LensL10n.text("Historique du descendant inaccessible")).font(.caption).foregroundStyle(a.accessible ? Color.secondary : LensAppearance.warningText)
                    Text(a.mission.nonempty ?? LensL10n.text("Mission non disponible"))
                        .font(LensUI.readingFont(store.fontSize)).lineLimit(4).textSelection(.enabled)
                        .help(a.mission.nonempty ?? LensL10n.text("Mission non disponible"))
                    if let env = a.environmentIDs.first {
                        Text(LensL10n.text("Worktree : {0}", env)).font(LensUI.metadata).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).help(a.environmentIDs.joined(separator: "\n"))
                    }
                    Button(LensL10n.text("Filtrer son activité")) { store.showActivity(for: .agent(id)) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityLabel(LensL10n.text("Filtrer l’activité de cet agent"))
                    DisclosureGroup(LensL10n.text("Détails"), isExpanded: $detailsExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            field(LensL10n.text("Mission enregistrée"), a.mission.nonempty ?? LensL10n.text("Mission non disponible"))
                            if let origin = store.presentation?.originInspection.selection(objectID: OriginInspectionIndex.agentID(id)) { OriginEvidenceView(selection: origin, target: selection).id(id) }
                            if let eventID = a.missionEventID { metadata(LensL10n.text("Mission complète et contexte"), value: LensL10n.text("Ouvrir l’instruction / la délégation d’origine")) { store.navigate(.event(eventID), newTab: true) } }
                            AgentInstructionHistoryView(agentID: a.id)
                            field(LensL10n.text("ID de thread Codex"), a.id, monospaced: true)
                            field(LensL10n.text("Relation"), relationLabel(a.relation))
                            if let p = a.parentID { metadata(LensL10n.text("Parent confirmé"), value: store.agentName(p)) { store.navigate(.agent(p), newTab: true) } }
                            ProvenanceView(certainty: a.relation == .root || a.relation == .subagent || a.relation == .fork || a.relation == .continuation ? .confirmed : .unknown, explanation: a.evidence)
                            ForEach(a.environmentIDs, id: \.self) { env in metadata(LensL10n.text("Environnement"), value: env) { store.navigate(.environment(env)) } }
                            ForEach(a.paths, id: \.self) { field(LensL10n.text("Journal"), $0, monospaced: true) }
                        }.padding(.top, 8)
                    }.font(LensUI.metadata)
                }
            case .environment(let id):
                if let e = snap.environments.first(where: { $0.id == id }) {
                    Text(URL(fileURLWithPath: e.path).lastPathComponent.nonempty ?? e.path).font(.headline)
                    Text(LensL10n.text("Worktree : {0}", e.path)).font(LensUI.metadata).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(e.path)
                    Text(LensL10n.text("Branche enregistrée") + " · " + (e.recordedBranch ?? LensL10n.text("Inconnue")))
                        .font(LensUI.metadata).textSelection(.enabled)
                    Text(LensL10n.text("Référence enregistrée") + " · " + (e.recordedRef ?? LensL10n.text("Inconnue")))
                        .font(LensUI.metadata).textSelection(.enabled)
                    Text(availabilityLabel(.unknown)).font(LensUI.metadata).foregroundStyle(.secondary)
                    Button(LensL10n.text("Filtrer son activité")) { store.showActivity(for: .environment(id)) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityLabel(LensL10n.text("Filtrer l’activité de cet environnement"))
                    DisclosureGroup(LensL10n.text("Détails"), isExpanded: $detailsExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            EnvironmentIdentityView(environment: e, availability: .unknown)
                            field(LensL10n.text("Provenance"), e.evidence)
                            ForEach(e.agentIDs, id: \.self) { agent in metadata(LensL10n.text("Agent"), value: store.agentName(agent)) { store.navigate(.agent(agent), newTab: true) } }
                            Text(LensL10n.text("La branche et le contenu actuels sont indiqués séparément dans l’explorateur.")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.font(LensUI.metadata)
                }
            case .resource(let id):
                if let r = snap.resources.first(where: { $0.id == id }) {
                    Text(LensUI.resourceTitle(r)).font(.headline).help(r.name)
                    Text(r.location).font(LensUI.metadata.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(r.location)
                    Text(LensL10n.text("Disponibilité indexée") + " · " + availabilityLabel(r.availability))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                    if let env = r.environmentID {
                        Text(LensL10n.text("Worktree : {0}", env)).font(LensUI.metadata).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).help(env)
                    }
                    Button(LensL10n.text("Filtrer son activité")) { store.showActivity(for: .resource(id)) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityLabel(LensL10n.text("Filtrer les actions liées"))
                    DisclosureGroup(LensL10n.text("Détails"), isExpanded: $detailsExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            field(LensL10n.text("Localisation"), r.location, monospaced: true)
                            field(LensL10n.text("Rôles"), r.roles.map(\.label).joined(separator: " · "))
                            if let env = r.environmentID { metadata(LensL10n.text("Environnement"), value: env) { store.navigate(.environment(env)) } }
                            field(LensL10n.text("Provenance"), r.evidence)
                            Text(LensL10n.text("ACTIONS ET CONTEXTE")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(r.eventIDs, id: \.self) { eventID in
                                if let e = snap.events.first(where: { $0.id == eventID }) { metadata(e.kind.label, value: e.title) { store.navigate(.event(eventID), newTab: true) } }
                            }
                        }.padding(.top, 8)
                    }.font(LensUI.metadata)
                }
            case .file(let env, let path, let line, let version):
                let resources = snap.resources.filter { $0.location == path && ($0.environmentID == env || $0.environmentID == nil) }
                let indexedAvailability: Availability = resources.first.map { first in
                    resources.allSatisfy({ $0.availability == first.availability }) ? first.availability : .unknown
                } ?? .unknown
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                Text(path).font(LensUI.metadata.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
                field(LensL10n.text("Référence de lecture demandée"), version ?? LensL10n.text("Non enregistrée"), monospaced: version != nil)
                Text(LensL10n.text("Worktree : {0}", env)).font(LensUI.metadata).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(env)
                Text(LensL10n.text("Disponibilité indexée") + " · " + availabilityLabel(indexedAvailability))
                    .font(LensUI.metadata).foregroundStyle(.secondary)
                Button(LensL10n.text("Ouvrir le fichier")) {
                    store.navigate(selection, newTab: true)
                    windowContext?.focusPane(.content, afterLayout: true)
                }.buttonStyle(.bordered).controlSize(.small)
                DisclosureGroup(LensL10n.text("Détails"), isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        field(LensL10n.text("Localisation du fichier"), path, monospaced: true)
                        if let line { field(LensL10n.text("Ligne demandée"), String(line)) }
                        metadata(LensL10n.text("Environnement"), value: env) { store.navigate(.environment(env)) }
                        ForEach(resources) { r in metadata(LensL10n.text("Ressource liée"), value: r.roles.map(\.label).joined(separator: " · ")) { store.navigate(.resource(r.id)) } }
                        let changes = snap.changes.filter { $0.path == path && $0.environmentID == env }
                        ForEach(changes) { c in metadata(LensL10n.text("Modification enregistrée"), value: changeLabel(c.kind)) { store.navigate(.change(c.id)) } }
                        if resources.isEmpty && changes.isEmpty { Text(LensL10n.text("Aucune action liée enregistrée pour ce fichier dans cet environnement.")).font(.caption).foregroundStyle(.secondary) }
                        Text(LensL10n.text("La version consultée est indiquée dans l’aperçu. Une lecture locale et un instantané Git sont distincts ; la présence sur disque ne prouve aucun état historique.")).font(.caption).foregroundStyle(.secondary)
                        if version != nil { Text(LensL10n.text("La référence demandée borne la lecture locale ; elle ne désigne pas automatiquement une version Git. Une référence devenue indisponible est signalée dans l’aperçu.")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 8)
                }.font(LensUI.metadata)
            case .event, .change: EmptyView()
            case .investigation, .evidence: Text(LensL10n.text("Le contexte de cette enquête est enregistré. Les réponses du chat ne font pas partie de l’historique de session.")).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: LensSymbols.name("cursorarrow.click")).accessibilityHidden(true).font(.title2).foregroundStyle(.secondary)
            Text(LensL10n.text("Sélectionner un événement ou un objet")).font(.headline)
            Text(LensL10n.text("L’inspecteur relie les données à leur agent, leur environnement et leurs sources.")).foregroundStyle(.secondary)
        }
    }
    private func metadata(_ name: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(LensUI.metadata).foregroundStyle(.secondary)
            Button(action: action) { Text(value).font(LensUI.body).multilineTextAlignment(.leading).textSelection(.enabled) }.buttonStyle(LensQuietButtonStyle())
        }
    }
    private func field(_ name: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(LensUI.metadata).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .system(size: 11, design: .monospaced) : LensUI.readingFont(store.fontSize)).textSelection(.enabled)
        }
    }
}

struct RecordedEventText: View {
    @EnvironmentObject var store: LensStore
    let event: LensEvent
    let part: String
    @State private var text = ""
    @State private var token: String?
    @State private var ioBytes: UInt64 = 0
    @State private var sourceBytes: UInt64 = 0
    @State private var busy = false
    @State private var issue: String?
    @State private var loadedSources: Set<SourceRef> = []
    @State private var displayedBytes = 0
    @State private var readGeneration: UInt64 = 0
    @State private var readTask: Task<Void, Never>?
    @State private var copier = RecordedCopyController()
    @State private var sourceDetailsExpanded = false
    @State private var sourceStates: [SourceRef: RecordedDocumentSlice] = [:]
    @State private var markdown: ChatMarkdownDocument?
    @State private var showsOriginal = false
    @State private var bodySources: Set<SourceRef> = []
    @State private var formattingLimited = false
    private var readIdentity: RecordedEventReadIdentity { RecordedEventReadIdentity(rootID: store.snapshot?.root.id, eventID: event.id, part: part) }
    private var availableSources: Set<SourceRef> {
        let related = event.relatedEventID.flatMap { id in store.event(id) }
        return Set([event.source] + event.supplementarySources + (related.map { [$0.source] + $0.supplementarySources } ?? []))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let issue { Text(LensL10n.display(issue)).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(10) }
            if let copyIssue = copier.issue { Label(copyIssue, systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(10) }
            LensAdaptiveRow {
                HStack(spacing: 8) {
                    Menu { copyActions } label: { LensIconMenuLabel("doc.on.doc") }
                        .lensIconMenu("Options de copie")
                        .accessibilityIdentifier("lens-recorded-copy")
                    if markdown != nil {
                        Button(LensL10n.text(showsOriginal ? "Lecture" : "Texte original")) { showsOriginal.toggle() }
                            .buttonStyle(.borderless).controlSize(.small)
                    }
                    Label(LensL10n.text("Secrets masqués"), systemImage: LensSymbols.name("lock"))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                }
            } trailing: {
                if copier.busy {
                    HStack(spacing: 8) {
                        Text(LensL10n.text("{0} octets préparés", String(describing: copier.byteCount))).font(LensUI.metadata).monospacedDigit()
                        Button(LensL10n.text("Annuler la copie")) { copier.cancel() }.controlSize(.small)
                    }
                }
            }.padding(.horizontal, 8).padding(.vertical, 5)
            sourceDetails
            Divider()
            if formattingLimited { Text(LensL10n.text("Texte original affiché pour ce contenu volumineux.")).font(LensUI.metadata).foregroundStyle(.secondary).padding(10) }
            NativeTextView(text: text, monospaced: !(part == "content" && [.user, .assistant, .instruction].contains(event.kind)), fontSize: store.fontSize, codeFont: store.codeFont, recordedCopyActions: nativeCopyActions, onMagnify: { store.magnifyReading($0) }, markdown: showsOriginal ? nil : markdown)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty, token == nil, !busy, issue == nil, !sourceStates.isEmpty {
                        Text(emptyTextLabel)
                            .foregroundStyle(.secondary).padding(14).allowsHitTesting(false)
                    }
                }
            Divider()
            LensAdaptiveRow {
                HStack(spacing: 6) {
                if busy { LensProgressIndicator().controlSize(.mini) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LensL10n.text(token == nil && !busy && issue == nil && !loadedSources.isEmpty && loadedSources == availableSources ? "Lecture complète · {0} octets" : "Lecture partielle · {0} octets", String(describing: displayedBytes)))
                }.font(LensUI.metadata).monospacedDigit()
                }
            } trailing: {
                HStack(spacing: 8) {
                if !loadedSources.isEmpty, loadedSources != availableSources { Button(LensL10n.text("Nouvelles traces liées")) { startRead(first: true) }.controlSize(.small).disabled(busy) }
                if token != nil { Button(LensL10n.text("Charger la suite")) { startRead(first: false) }.controlSize(.small).disabled(busy) }
                if issue != nil { Button(LensL10n.text("Relire")) { startRead(first: true) }.controlSize(.small).disabled(busy) }
                }
            }.padding(8)
        }.task(id: readIdentity) { readGeneration &+= 1; await read(first: true, generation: readGeneration) }
            .onChange(of: store.selection) { _, _ in copier.cancel() }
            .onChange(of: store.snapshot?.root.id) { _, _ in copier.cancel() }
            .onDisappear { readTask?.cancel(); readGeneration &+= 1; busy = false; copier.cancel(showIssue: false) }
    }
    private var emptyTextLabel: String {
        if sourceStates.values.contains(where: \.fieldFound) { return LensL10n.text("Texte enregistré vide.") }
        return LensL10n.text(part == "output" ? "Aucune sortie enregistrée pour cet événement." : part == "input" ? "Aucune entrée enregistrée pour cet événement." : "Cette rubrique ne contient pas de texte.")
    }
    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { sourceDetailsExpanded.toggle() } label: {
                Label(LensL10n.text("Sources · {0}", String(sourceEntries.count)), systemImage: sourceDetailsExpanded ? "chevron.down" : "chevron.right")
            }.buttonStyle(.borderless)
                .accessibilityValue(LensL10n.text(sourceDetailsExpanded ? "Déplié" : "Replié"))
                .accessibilityIdentifier("lens-recorded-sources")
            if sourceDetailsExpanded {
            VStack(alignment: .leading, spacing: 10) {
                Text(LensL10n.text("Source : {0} octets · lectures/vérifications : {1}", String(describing: sourceBytes), String(describing: ioBytes)))
                    .font(LensUI.metadata).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                ForEach(sourceEntries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.label).font(LensUI.metadata.weight(.semibold))
                        if let state = sourceStates[entry.source], state.complete {
                            Text(sourceStateLabel(state)).font(LensUI.metadata).foregroundStyle(.secondary)
                        }
                        Text(entry.source.path).font(LensUI.metadata.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(LensL10n.text("Ligne {0} · octets {1} à {2}", String(entry.source.line), String(entry.source.offset), String(entry.source.offset + UInt64(entry.source.length))))
                            .font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 6)
            }
        }.font(LensUI.metadata).padding(.horizontal, 12).padding(.vertical, 6)
    }
    private func sourceStateLabel(_ state: RecordedDocumentSlice) -> String {
        if state.fieldFound { return LensL10n.text("Rubrique lue") }
        return LensL10n.text(part == "output" ? "Aucune sortie enregistrée dans cette trace" : part == "input" ? "Aucune entrée enregistrée dans cette trace" : "Cette rubrique n’est pas enregistrée dans cette trace")
    }
    @ViewBuilder private var copyActions: some View {
        Button(LensL10n.text("Copier le texte chargé")) { copier.copyLoaded(text, store: store) }.disabled(text.isEmpty || copier.busy)
        Button(LensL10n.text("Lire puis copier la rubrique complète")) { copier.copy(event: event, related: relatedEvent, part: part, store: store) }.disabled(copier.busy).help(LensL10n.text("Relire les traces disponibles au clic, garder leurs séparateurs et copier seulement après leur fin validée ; limite 32 Mio."))
        Divider()
        ForEach(sourceEntries) { entry in
            Menu(entry.label) {
                Text(entry.source.path)
                Button(LensL10n.text("Copier l’entrée enregistrée complète")) { copier.copy(event: event, related: relatedEvent, part: "input", source: entry.source, store: store) }
                Button(LensL10n.text("Copier la sortie enregistrée complète")) { copier.copy(event: event, related: relatedEvent, part: "output", source: entry.source, store: store) }
                Button(LensL10n.text("Copier l’événement brut complet")) { copier.copy(event: event, related: relatedEvent, part: "raw", source: entry.source, store: store) }
            }.disabled(copier.busy)
        }
    }
    private var nativeCopyActions: [RecordedNativeCopyAction] {
        var actions = [
            RecordedNativeCopyAction(title: LensL10n.text("Copier le texte chargé"), enabled: !text.isEmpty && !copier.busy) { copier.copyLoaded(text, store: store) },
            RecordedNativeCopyAction(title: LensL10n.text("Lire puis copier la rubrique complète · sources séparées"), enabled: !copier.busy) { copier.copy(event: event, related: relatedEvent, part: part, store: store) }
        ]
        for entry in sourceEntries {
            actions.append(RecordedNativeCopyAction(title: LensL10n.text("{0} · copier l’entrée complète", String(describing: entry.label)), enabled: !copier.busy) { copier.copy(event: event, related: relatedEvent, part: "input", source: entry.source, store: store) })
            actions.append(RecordedNativeCopyAction(title: LensL10n.text("{0} · copier la sortie complète", String(describing: entry.label)), enabled: !copier.busy) { copier.copy(event: event, related: relatedEvent, part: "output", source: entry.source, store: store) })
        }
        return actions
    }
    private var relatedEvent: LensEvent? { event.relatedEventID.flatMap { store.event($0) } }
    private var sourceEntries: [RecordedCopySourceEntry] { RecordedCopySourceEntry.entries(event: event, related: relatedEvent) }
    private func startRead(first: Bool) {
        guard !busy else { return }; readTask?.cancel(); readGeneration &+= 1
        let generation = readGeneration
        readTask = Task { await read(first: first, generation: generation) }
    }
    private func read(first: Bool, generation: UInt64) async {
        let identity = readIdentity
        busy = true; issue = nil
        defer { if generation == readGeneration { busy = false } }
        do {
            let page: RecordedDocumentPage
            let sources = availableSources
            if first {
                let related = event.relatedEventID.flatMap { id in store.event(id) }
                page = try await store.documentPager.begin(event: event, relatedEvent: related, part: part)
            } else if let token { page = try await store.documentPager.next(token: token) }
            else { return }
            guard !Task.isCancelled, generation == readGeneration, identity == readIdentity else { return }
            if first { text = ""; displayedBytes = 0; loadedSources = sources; sourceStates = [:]; markdown = nil; showsOriginal = false; bodySources = [] }
            for slice in page.slices {
                if !slice.text.isEmpty, !bodySources.contains(slice.source) {
                    if !text.isEmpty { text += "\n\n[" + (sourceEntries.first { $0.source == slice.source }?.label ?? LensL10n.text("Source")) + "]\n" }
                    bodySources.insert(slice.source)
                }
                text += slice.text; displayedBytes += slice.text.utf8.count
                sourceStates[slice.source] = slice
            }
            token = page.token; ioBytes = page.bytesRead; sourceBytes = page.totalSourceBytes
            let original = text
            let format = part != "raw" && bodySources.count == 1 && (original.hasPrefix("# ") || original.hasPrefix("## ") || original.hasPrefix("```"))
            formattingLimited = format && original.utf8.count > ChatMarkdownParser.maximumFormattedSourceBytes
            let parsed = format && original.utf8.count <= ChatMarkdownParser.maximumFormattedSourceBytes
                ? try await Task.detached { try ChatMarkdownParser.parse(original) }.value : nil
            guard !Task.isCancelled, generation == readGeneration, identity == readIdentity else { return }
            markdown = parsed
        } catch { if !Task.isCancelled, generation == readGeneration, identity == readIdentity { issue = error.localizedDescription } }
    }
}
/// The immutable recorded coordinates, including collector SHA, guard clipboard publication.
/// A relative path or an unchanged event ID alone cannot identify the same historical trace.
struct RecordedCopySourceVersion: Equatable, Sendable {
    let eventID: String
    let relatedEventID: String?
    let recordedRelatedID: String?
    let environmentID: String?
    let relatedEnvironmentID: String?
    let sources: [SourceRef]
    init(event: LensEvent, related: LensEvent?) {
        eventID = event.id; relatedEventID = related?.id; recordedRelatedID = event.relatedEventID
        environmentID = event.environmentID; relatedEnvironmentID = related?.environmentID
        var seen = Set<SourceRef>()
        sources = ([event.source] + event.supplementarySources + (related.map { [$0.source] + $0.supplementarySources } ?? []))
            .filter { seen.insert($0).inserted }
    }
}
struct RecordedCopySourceEntry: Identifiable {
    let source: SourceRef
    let label: String
    var id: SourceRef { source }
    static func entries(event: LensEvent, related: LensEvent?) -> [Self] {
        var seen = Set<SourceRef>(), entries: [Self] = []
        let owners: [(LensEvent?, String)] = [(event, LensL10n.text("Événement")), (related, LensL10n.text("Action liée"))]
        for (owner, prefix) in owners.compactMap({ pair -> (LensEvent, String)? in pair.0.map { ($0, pair.1) } }) {
            for (index, source) in ([owner.source] + owner.supplementarySources).enumerated() where seen.insert(source).inserted {
                entries.append(Self(source: source, label: "\(prefix) · trace \(index + 1) · ligne \(source.line)"))
            }
        }
        return entries
    }
}
enum RecordedCopyFailure: LocalizedError {
    case budget, empty, changed
    var errorDescription: String? {
        switch self {
        case .budget: return LensL10n.text("La copie complète dépasse 32 Mio. Aucun extrait n’a été copié ; la lecture progressive reste disponible.")
        case .empty: return LensL10n.text("Aucun texte pris en charge dans cette rubrique de la trace choisie, ou champ vide. Le presse-papiers est inchangé ; consultez l’événement brut.")
        case .changed: return LensL10n.text("La session, la cible ou les sources ont changé pendant la lecture. Copie annulée ; presse-papiers inchangé.")
        }
    }
}
/// The existing pager remains the only reader. No source access, JSON parsing or command execution here.
enum RecordedCopyReader {
    static let maximumBytes = 32 * 1024 * 1024
    static func read(pager: RecordedPager, event: LensEvent, related: LensEvent?, part: String, source: SourceRef?,
                     maximumBytes: Int = RecordedCopyReader.maximumBytes, progress: @Sendable (Int) async -> Void = { _ in }) async throws -> String {
        var frozen = event
        if let source { frozen.source = source; frozen.supplementarySources = [] }
        var page = try await pager.begin(event: frozen, relatedEvent: source == nil ? related : nil, part: part, decorateSources: source == nil)
        var chunks: [String] = [], byteCount = 0, lastReported = -1
        while true {
            try Task.checkCancellation()
            let nextBytes = page.text.utf8.count
            guard byteCount <= maximumBytes, nextBytes <= maximumBytes - byteCount else { throw RecordedCopyFailure.budget }
            if !page.text.isEmpty { chunks.append(page.text); byteCount += nextBytes }
            if lastReported < 0 || byteCount - lastReported >= 1024 * 1024 || page.token == nil {
                await progress(byteCount); lastReported = byteCount
            }
            guard let token = page.token else { break }
            page = try await pager.next(token: token)
        }
        try Task.checkCancellation()
        guard byteCount > 0 else { throw RecordedCopyFailure.empty }
        return chunks.joined()
    }
}
// UI readers observe only the progress/error fields they display. The task and
// cancellation identity are bookkeeping, not view dependencies.
@MainActor @Observable final class RecordedCopyController {
    private(set) var busy = false
    private(set) var byteCount = 0
    private(set) var issue: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    /// The detached reader captures one immutable actor-isolated box. Its weak
    /// references are accessed only on MainActor, without retaining a task cycle.
    @MainActor private final class WeakReferences {
        private weak var controller: RecordedCopyController?
        private weak var store: LensStore?
        private let root: String
        private let target: Destination?
        private let eventID: String
        private let version: RecordedCopySourceVersion
        private let generation: UUID
        private let singleSource: Bool
        init(controller: RecordedCopyController, store: LensStore, root: String,
             target: Destination?, eventID: String, version: RecordedCopySourceVersion,
             generation: UUID, singleSource: Bool) {
            self.controller = controller; self.store = store; self.root = root
            self.target = target; self.eventID = eventID; self.version = version
            self.generation = generation; self.singleSource = singleSource
        }
        func progress(_ count: Int) {
            guard let controller, controller.generation == generation else { return }
            controller.byteCount = count
        }
        func publish(_ text: String) {
            guard let controller, let store, controller.generation == generation else { return }
            defer { controller.busy = false; controller.task = nil }
            guard store.snapshot?.root.id == root, store.selection == target, let current = store.event(eventID),
                  RecordedCopySourceVersion(event: current, related: current.relatedEventID.flatMap { store.event($0) }) == version else {
                controller.issue = RecordedCopyFailure.changed.localizedDescription; return
            }
            store.copyLocalText(text, notice: singleSource ? LensL10n.text("Trace complète copiée · secrets reconnaissables masqués.") : LensL10n.text("Rubrique complète copiée · sources séparées, secrets reconnaissables masqués."))
        }
        func fail(_ message: String, cancelled: Bool) {
            guard let controller, controller.generation == generation else { return }
            controller.busy = false; controller.task = nil
            controller.issue = cancelled ? LensL10n.text("Copie annulée ; presse-papiers inchangé.") : message
        }
    }
    func cancel(showIssue: Bool = true) {
        let wasBusy = busy
        generation = UUID(); task?.cancel(); task = nil; busy = false
        if wasBusy && showIssue { issue = LensL10n.text("Copie annulée ; presse-papiers inchangé.") }
    }
    func copyLoaded(_ text: String, store: LensStore) {
        guard !text.isEmpty else { return }
        guard text.utf8.count <= RecordedCopyReader.maximumBytes else { issue = RecordedCopyFailure.budget.localizedDescription; return }
        issue = nil
        store.copyLocalText(text, notice: LensL10n.text("Texte chargé copié · secrets reconnaissables masqués."))
    }
    func copy(event: LensEvent, related: LensEvent?, part: String, source: SourceRef? = nil, store: LensStore) {
        cancel(showIssue: false); issue = nil
        let version = RecordedCopySourceVersion(event: event, related: related)
        guard source.map({ version.sources.contains($0) }) ?? true, let root = store.snapshot?.root.id,
              let current = store.event(event.id),
              RecordedCopySourceVersion(event: current, related: current.relatedEventID.flatMap { store.event($0) }) == version else {
            issue = RecordedCopyFailure.changed.localizedDescription; return
        }
        let pager = store.pager
        let references = WeakReferences(controller: self, store: store, root: root,
            target: store.selection, eventID: event.id, version: version,
            generation: generation, singleSource: source != nil)
        busy = true; byteCount = 0
        task = Task.detached(priority: .userInitiated) {
            do {
                let text = try await RecordedCopyReader.read(pager: pager, event: event, related: related, part: part, source: source) { count in
                    await references.progress(count)
                }
                try Task.checkCancellation()
                await references.publish(text)
            } catch {
                await references.fail(error.localizedDescription, cancelled: error is CancellationError)
            }
        }
    }
    deinit { task?.cancel() }
}
struct RecordedEventReadIdentity: Hashable {
    let rootID: String?
    let eventID: String
    let part: String
}

struct PagedTextView: View {
    let text: String
    let identity: String
    @State private var visibleLength = 65536
    @State private var count = 0
    var body: some View {
        VStack(spacing: 0) {
            if text.isEmpty { Text(LensL10n.text("Aucune donnée enregistrée dans cette rubrique.")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { NativeTextView(text: String(text.prefix(visibleLength)), monospaced: true) }
            Divider()
            HStack {
                Text(LensL10n.text("{0} / {1} caractères", String(describing: min(count, visibleLength)), String(describing: count))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if visibleLength < count { Button(LensL10n.text("Charger la suite")) { visibleLength += 65536 }.controlSize(.small) }
            }.padding(8)
        }.onAppear { count = text.count }
            .onChange(of: identity) { _, _ in visibleLength = 65536; count = text.count }
            .onChange(of: text) { _, _ in count = text.count }
    }
}
struct NativeTextView: NSViewRepresentable {
    @Environment(\.lensAccent) private var accent
    var text: String
    var monospaced = true
    var fontSize: Double = LensUI.defaultReadingSize
    var codeFont: LensCodeFont = .system
    var recordedCopyActions: [RecordedNativeCopyAction] = []
    var onMagnify: ((CGFloat) -> Void)? = nil
    var markdown: ChatMarkdownDocument? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var formattedSource: String?
        var formattedSize: Double?
        var formattedCodeFont: LensCodeFont?
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = RecordedCopyTextView(); view.recordedCopyActions = recordedCopyActions; view.isEditable = false; view.isSelectable = true; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true; view.usesFindPanel = false; view.isRichText = false
        view.textContainerInset = NSSize(width: 10, height: 10); view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.font = monospaced ? codeFont.nativeFont(size: fontSize) : NSFont.systemFont(ofSize: LensUI.readingSize(fontSize))
        view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor; scroll.documentView = view
        view.string = text
        accent.applyTextSelection(to: view)
        applyMarkdown(to: view, coordinator: context.coordinator)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        accent.applyTextSelection(to: view)
        (view as? RecordedCopyTextView)?.recordedCopyActions = recordedCopyActions
        (view as? RecordedCopyTextView)?.onMagnify = onMagnify
        let selected = view.selectedRanges, origin = scroll.contentView.bounds.origin
        if markdown != nil {
            applyMarkdown(to: view, coordinator: context.coordinator)
            let length = (view.string as NSString).length
            view.selectedRanges = selected.map { value in
                let range = value.rangeValue, start = min(range.location, length)
                return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
            }
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        let wasFormatted = context.coordinator.formattedSource != nil
        context.coordinator.formattedSource = nil
        let size = LensUI.readingSize(fontSize)
        let font = monospaced ? codeFont.nativeFont(size: fontSize) : NSFont.systemFont(ofSize: size)
        let changedFont = view.font != font || wasFormatted, changedText = view.string != text || wasFormatted
        if changedFont { view.font = font }
        if changedText {
            let previous = view.string as NSString, incoming = text as NSString
            if incoming.length >= previous.length, incoming.compare(view.string, options: .literal, range: NSRange(location: 0, length: previous.length)) == .orderedSame {
                view.textStorage?.append(NSAttributedString(string: incoming.substring(from: previous.length), attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            } else { view.string = text }
        }
        if changedFont || changedText {
            let length = (view.string as NSString).length
            view.selectedRanges = selected.map { value -> NSValue in
                let range = value.rangeValue, location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func applyMarkdown(to view: NSTextView, coordinator: Coordinator) {
        guard let markdown else { return }
        guard coordinator.formattedSource != markdown.source || coordinator.formattedSize != fontSize || coordinator.formattedCodeFont != codeFont else { return }
        view.textStorage?.setAttributedString(RecordedMarkdownTypography.render(markdown, fontSize: fontSize, codeFont: codeFont))
        coordinator.formattedSource = markdown.source; coordinator.formattedSize = fontSize; coordinator.formattedCodeFont = codeFont
    }
}
struct RecordedNativeCopyAction {
    let title: String
    let enabled: Bool
    let action: () -> Void
}
@MainActor private final class RecordedCopyMenuCommand: NSObject {
    let command: RecordedNativeCopyAction
    init(_ command: RecordedNativeCopyAction) { self.command = command }
}
/// Extend the actual NSTextView menu while preserving native selection, Copy and Find.
/// Each NSMenuItem owns the action captured when that menu opened, never a mutable row index.
@MainActor private final class RecordedCopyTextView: NSTextView {
    var recordedCopyActions: [RecordedNativeCopyAction] = []
    var onMagnify: ((CGFloat) -> Void)?
    override func magnify(with event: NSEvent) { if let onMagnify { onMagnify(event.magnification) } else { super.magnify(with: event) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let additionID = NSUserInterfaceItemIdentifier("recordedCopyMenuAddition")
        for item in menu.items where item.identifier == additionID { menu.removeItem(item) }
        guard !recordedCopyActions.isEmpty else { return menu }
        let separator = NSMenuItem.separator(); separator.identifier = additionID; menu.addItem(separator)
        for command in recordedCopyActions {
            let item = NSMenuItem(title: command.title, action: #selector(copyRecordedText(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = RecordedCopyMenuCommand(command); item.isEnabled = command.enabled; item.identifier = additionID
            menu.addItem(item)
        }
        return menu
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyRecordedText(_:)), let menuItem = item as? NSMenuItem,
           let box = menuItem.representedObject as? RecordedCopyMenuCommand { return box.command.enabled }
        return super.validateUserInterfaceItem(item)
    }
    @objc private func copyRecordedText(_ item: NSMenuItem) {
        guard let box = item.representedObject as? RecordedCopyMenuCommand, box.command.enabled else { return }
        box.command.action()
    }
}
func relationLabel(_ relation: RelationKind) -> String {
    switch relation { case .root: return LensL10n.text("Session racine"); case .subagent: return LensL10n.text("Sous-agent"); case .fork: return LensL10n.text("Fork de conversation"); case .continuation: return LensL10n.text("Reprise de conversation"); case .unknown: return LensL10n.text("Relation inconnue") }
}
func changeLabel(_ kind: ChangeKind) -> String {
    switch kind { case .requestedPatch: return LensL10n.text("Patch demandé"); case .recordedResult: return LensL10n.text("Résultat enregistré"); case .observedChange: return LensL10n.text("Changement observé dans la trace") }
}
func availabilityLabel(_ value: Availability) -> String {
    switch value { case .accessible: return LensL10n.text("Accessible localement"); case .missing: return LensL10n.text("Fichier absent"); case .external: return LensL10n.text("Référence externe"); case .unknown: return LensL10n.text("Disponibilité du contenu inconnue") }
}
