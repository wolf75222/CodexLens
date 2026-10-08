import SwiftUI
import LensCore

struct CommunicationSequenceView: View {
    @EnvironmentObject var store: LensStore
    private var sequence: CommunicationSequenceProjection? { store.presentation?.sequence }
    private var selectedRow: Binding<String?> {
        Binding(get: {
            guard let id = store.selectedEvent?.id else { return nil }
            return store.presentation?.communicationInspection.communicationByEventID[id]?.eventIDs.first
        }, set: { id in
            guard let id, store.event(id) != nil else { return }
            if store.selectedEvent?.id != id { store.navigate(.event(id)) }
            store.inspectorVisible = true
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(LensL10n.text("Séquence des échanges enregistrés")).font(.headline)
                Spacer()
                Text(LensL10n.text("{0} échanges visibles", String(sequence?.routes.count ?? 0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.top, 12)
            Text(LensL10n.text("Envoi, contexte du destinataire et inclusion dans une requête sont indiqués séparément. Les flèches relient les événements enregistrés.")).font(LensUI.metadata).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
            if let sequence, !sequence.routes.isEmpty {
                if sequence.omittedAgentCount > 0 { Text(LensL10n.text("{0} identités regroupées dans la piste non résolue ; détails conservés dans l’inspecteur.", String(sequence.omittedAgentCount))).font(.caption).padding(.horizontal, 14) }
                GeometryReader { geometry in
                    let contentWidth = max(geometry.size.width, 94 + CGFloat(sequence.lanes.count) * 164)
                    ScrollView(.horizontal) {
                        List(selection: selectedRow) {
                            CommunicationLaneHeader(lanes: sequence.lanes)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden).tag("lens:sequence-header")
                            ForEach(sequence.routes) { route in
                                CommunicationSequenceRow(route: route, laneCount: sequence.lanes.count)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                    .tag(route.eventID).id(route.eventID)
                                    .contextMenu {
                                        Button(LensL10n.text("Ajouter à la question")) { store.perform(.investigate, target: .event(route.eventID)) }
                                        Button(LensL10n.text("Afficher dans la timeline")) { store.showInTimeline(route.eventID) }
                                        LensActionButton(store: store, action: .copyLink, target: .event(route.eventID))
                                    }
                                    .onTapGesture(count: 2) { store.showInTimeline(route.eventID) }
                            }
                        }.listStyle(.plain).frame(width: contentWidth, height: geometry.size.height)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Label(LensL10n.text("Aucun échange dans cette sélection"), systemImage: LensSymbols.name("arrow.left.arrow.right")).font(.headline)
                    Text(LensL10n.text("Modifiez les filtres pour explorer les autres traces. Une absence de réception enregistrée ne prouve pas un message perdu.")).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            DisclosureGroup(LensL10n.text("Couverture de la séquence")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((store.presentation?.communicationInspection.collectionLimitations ?? []).enumerated()), id: \.offset) { _, text in Text(LensL10n.display(text)).font(LensUI.metadata).foregroundStyle(.secondary) }
                }.padding(.top, 4)
            }.font(LensUI.metadata).padding(12)
        }
    }
}

private struct CommunicationLaneHeader: View {
    @EnvironmentObject var store: LensStore
    let lanes: [CommunicationSequenceProjection.Lane]
    var body: some View {
        HStack(spacing: 0) {
            Text(LensL10n.text("Trace")).font(.caption).foregroundStyle(.secondary).frame(width: 94)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(lanes) { lane in
                        Button {
                            if store.presentation?.agentsByID[lane.id] != nil { store.navigate(.agent(lane.id)); store.inspectorVisible = true }
                        } label: { Text(LensL10n.display(lane.name)).font(.caption.weight(.semibold)).lineLimit(2).frame(width: geometry.size.width / CGFloat(max(1, lanes.count)), height: 40) }
                        .buttonStyle(.plain).disabled(store.presentation?.agentsByID[lane.id] == nil)
                    }
                }
            }.frame(height: 40)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CommunicationSequenceRow: View {
    @Environment(\.lensAccent) private var accent
    @EnvironmentObject var store: LensStore
    let route: CommunicationSequenceProjection.Route
    let laneCount: Int
    private var communication: RecordedCommunication { route.communication }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    if let time = communication.timestamp { Text(time, format: .dateTime.hour().minute().second()).monospacedDigit() }
                    Text(LensL10n.text(communication.kind == .followup ? "Relance" : communication.kind == .spawn ? "Délégation" : communication.kind == .wait ? "Attente" : "Message")).foregroundStyle(.secondary)
                }.font(.caption).frame(width: 94, alignment: .leading)
                GeometryReader { geometry in
                    let width = geometry.size.width / CGFloat(max(1, laneCount))
                    let sender = (CGFloat(route.senderLane) + 0.5) * width
                    Path { path in
                        for lane in 0..<laneCount { let x = (CGFloat(lane) + 0.5) * width; path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 42)) }
                    }.stroke(Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Path { path in
                        for lane in route.recipientLanes {
                            let target = (CGFloat(lane) + 0.5) * width
                            if abs(target - sender) < 1 {
                                path.move(to: CGPoint(x: sender, y: 10)); path.addLine(to: CGPoint(x: sender + 20, y: 10)); path.addLine(to: CGPoint(x: sender + 20, y: 30)); path.addLine(to: CGPoint(x: sender, y: 30))
                            } else {
                                path.move(to: CGPoint(x: sender, y: 20)); path.addLine(to: CGPoint(x: target, y: 20))
                                let direction: CGFloat = target > sender ? -1 : 1
                                path.move(to: CGPoint(x: target + direction * 7, y: 15)); path.addLine(to: CGPoint(x: target, y: 20)); path.addLine(to: CGPoint(x: target + direction * 7, y: 25))
                            }
                        }
                    }.stroke(accent.color, lineWidth: 1.5)
                    Circle().fill(accent.color).frame(width: 7, height: 7).position(x: sender, y: 20)
                }.frame(height: 42).accessibilityHidden(true).allowsHitTesting(false)
            }
            HStack(spacing: 8) {
                Text(communication.senderAgentID.map(store.agentName) ?? communication.senderPath ?? LensL10n.text("Émetteur inconnu"))
                Image(systemName: LensSymbols.name("arrow.right")).accessibilityHidden(true)
                Text(store.communicationRecipientNames(communication).joined(separator: ", ").nonempty ?? LensL10n.text("Destinataire inconnu"))
                Spacer()
                Label(LensL10n.text(!communication.modelInclusionEventIDs.isEmpty ? "Inclusion confirmée" : !communication.recipientContextEventIDs.isEmpty ? "Contexte enregistré" : "Réception non prouvée"), systemImage: LensSymbols.name(!communication.recipientContextEventIDs.isEmpty ? "checkmark.circle" : "questionmark.circle"))
            }.font(LensUI.metadata).lineLimit(1)
            if let event = store.event(route.eventID) { Text(event.preview).font(LensUI.readingFont(store.fontSize)).lineLimit(2).foregroundStyle(.secondary) }
        }.padding(.vertical, 7).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
