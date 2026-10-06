import SwiftUI
import AppKit
import LensCore

/// This clock invalidates only the live ruler/canvas, never the whole session store.
@MainActor final class LensLiveClock: ObservableObject {
    @Published private(set) var state = TimelineLiveState()
    func resume(at date: Date) { state.resume(at: date) }
    func pause() { state.pause() }
    func reset() { state.reset() }
    func restore(_ value: TimelineLiveState) { state = value }
    func advance(at date: Date) {
        var next = state; next.tick(at: date)
        if next != state { state = next }
    }
    func setSpan(_ value: TimeInterval, at date: Date) { state.setSpan(value, at: date) }
    func inspect(_ window: TimelineWindow) { state.inspect(window: window) }
    func run() async {
        while !Task.isCancelled, state.following {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard !Task.isCancelled, state.following else { return }
            advance(at: Date())
        }
    }
}

struct LensLiveTimelinePane: View {
    @ObservedObject var store: LensStore
    @ObservedObject private var clock: LensLiveClock
    init(store: LensStore) { self.store = store; clock = store.liveClock }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LensAdaptiveRow { heading } trailing: { controls }
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            TimelineView(store: store, live: true)
                .accessibilityIdentifier("lens-live-timeline")
            LensAdaptiveRow {
                Text(LensL10n.text("Horloge locale · journaux vérifiés toutes les 2 s")).lineLimit(1)
                    .help(LensL10n.text("La ligne du présent suit l’horloge du Mac. Seules les actions enregistrées dans les journaux sont affichées ; le direct ne prouve pas qu’un agent est actif."))
            } trailing: {
              HStack(spacing: 12) {
                Button(LensL10n.text("Liste")) { store.showLiveEventList() }.buttonStyle(LensQuietButtonStyle()).fixedSize().accessibilityIdentifier("lens-live-list")
                if let id = store.timelineProjection?.orderedEventIDs.last {
                    Button(LensL10n.text("Dernier événement")) { store.previewLiveEvent(id) }
                        .buttonStyle(LensQuietButtonStyle()).fixedSize()
                        .help(LensL10n.text("Ouvrir un aperçu sans suspendre le direct")).accessibilityIdentifier("lens-live-latest-event")
                }
                Menu {
                    Button(LensL10n.text("Ouvrir le dernier diff")) { store.previewLatestLiveChange() }
                    Divider()
                    ForEach(store.presentation?.recentRecordedChanges ?? []) { change in
                        Button { store.previewLiveChange(change.id) } label: {
                            Text(URL(fileURLWithPath: change.path).lastPathComponent + " · " + URL(fileURLWithPath: change.environmentID).lastPathComponent + " · " + changeLabel(change.kind))
                        }.help(change.path + "\n" + change.environmentID)
                    }
                } label: { Label(LensL10n.text("Diffs récents"), systemImage: LensSymbols.name("plus.forwardslash.minus")) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(store.presentation?.recentRecordedChanges.isEmpty != false)
                    .accessibilityIdentifier("lens-live-recent-diffs")
                    .help(LensL10n.text("Les derniers patches et diffs enregistrés. Le fichier actuel reste distinct."))
              }.fixedSize(horizontal: true, vertical: true)
            }.font(LensUI.metadata).controlSize(.small).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5)
            if store.period != nil {
                HStack {
                    Label(LensL10n.text("Une période filtre la timeline"), systemImage: LensSymbols.name("line.3.horizontal.decrease.circle"))
                    Spacer()
                    Button(LensL10n.text("Retirer la période")) { store.period = nil }
                }.font(LensUI.metadata).controlSize(.small).padding(.horizontal, 12).padding(.bottom, 5)
            }
        }.lensStableContent()
            .task(id: (store.snapshot?.root.id ?? "") + (store.follow ? "/follow" : "/paused")) {
                guard store.liveTimelineVisible, store.follow else { return }
                await clock.run()
            }
    }
    private var heading: some View {
        HStack(spacing: 7) {
            Label(LensL10n.text(store.follow ? "Direct" : "Lecture en pause"), systemImage: LensSymbols.name(store.follow ? "dot.radiowaves.left.and.right" : "pause.circle"))
                .font(LensUI.header)
            if store.waitingEvents > 0 {
                Text(LensL10n.text("+{0} événements", String(store.waitingEvents))).font(LensUI.metadata).monospacedDigit()
            }
            if store.waitingUpdates, store.waitingEvents == 0 {
                Text(LensL10n.text("Mises à jour disponibles")).font(LensUI.metadata)
            }
            if store.timelinePreparing { LensProgressIndicator().controlSize(.small) }
        }.accessibilityElement(children: .combine)
    }
    private var controls: some View {
        LensNavigationEffectGroup {
        HStack(spacing: 8) {
            Picker(LensL10n.text("Durée"), selection: Binding(get: { clock.state.span }, set: { store.setLiveSpan($0) })) {
                ForEach(TimelineLiveState.suggestedSpans, id: \.self) { span in Text(durationLabel(span)).tag(span) }
                if !TimelineLiveState.suggestedSpans.contains(clock.state.span) { Text(durationLabel(clock.state.span)).tag(clock.state.span) }
            }.frame(width: 145).accessibilityIdentifier("lens-live-span")
            Button {
                if store.follow { store.pauseLiveTimeline() } else { store.resumeLiveTimeline() }
            } label: { Label(LensL10n.text(store.follow ? "Pause" : "Revenir au direct"), systemImage: LensSymbols.name(store.follow ? "pause.fill" : "play.fill")) }
                .lensChromeButton()
                .help(LensL10n.text("Suspend la lecture, jamais la collecte. Majuscule-Commande-L reprend le suivi."))
                .fixedSize().accessibilityIdentifier("lens-live-follow")
            Button { store.disableLiveTimeline() } label: { Image(systemName: LensSymbols.name("xmark")) }
                .lensChromeButton()
                .accessibilityLabel(LensL10n.text("Masquer le direct")).help(LensL10n.text("Masquer le direct"))
        }.controlSize(.small).fixedSize(horizontal: true, vertical: true)
        }
    }
    private func durationLabel(_ span: TimeInterval) -> String {
        span >= 60 ? LensL10n.text("{0} min", (span / 60).formatted(.number.precision(.fractionLength(0...1)))) : LensL10n.text("{0} s", span.formatted(.number.precision(.fractionLength(0...1))))
    }
}

/// Temporary inspection uses the existing call and diff readers and shared identities.
struct LensLivePreviewView: View {
    @EnvironmentObject var store: LensStore
    let destination: Destination
    var temporary = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LensAdaptiveRow { heading } trailing: { actions }
                .padding(.horizontal, 16).padding(.vertical, 10)
            if let environment = previewEvent?.environmentID {
                Text(environment).font(LensUI.metadata.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(environment)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            if case .change(let id) = destination, let change = store.change(id) {
                RecordedChangeView(change: change).id(change.id)
            } else if case .event(let id) = destination, let event = store.event(id) {
                if !store.liveChanges(for: id).isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            Text(LensL10n.text("Diffs enregistrés")).font(LensUI.metadata).foregroundStyle(.secondary)
                            ForEach(store.liveChanges(for: id)) { change in
                                Button(URL(fileURLWithPath: change.path).lastPathComponent + " · " + changeLabel(change.kind)) { openRelated(.change(change.id)) }
                                    .help(change.path + "\n" + change.environmentID)
                            }
                        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    Divider()
                }
                LiveEventTextTabs(event: event).id(event.id)
            } else {
                LensCollectionEmptyState(title: LensL10n.text("Élément indisponible"), detail: LensL10n.text("Cet élément n’est plus présent dans les données de la session ouverte."), symbol: "doc.questionmark")
            }
        }.lensStableContent()
    }
    private func openRelated(_ target: Destination) {
        if temporary && store.liveTimelineVisible {
            switch target {
            case .event(let id): store.previewLiveEvent(id)
            case .change(let id): store.previewLiveChange(id)
            default: store.navigate(target, newTab: true)
            }
        } else { store.navigate(target, newTab: true) }
    }
    private var title: some View {
        Label(store.label(destination), systemImage: LensSymbols.name(temporary ? "eye" : "doc.text"))
            .font(LensUI.header).lineLimit(1).truncationMode(.middle).help(store.label(destination))
    }
    private var previewEvent: LensEvent? {
        if case .event(let id) = destination { return store.event(id) }
        return nil
    }
    @ViewBuilder private var heading: some View {
        if let event = previewEvent {
            VStack(alignment: .leading, spacing: 4) {
                if temporary { title }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { agentHeading(event); timestamp(event) }
                    VStack(alignment: .leading, spacing: 4) { agentHeading(event); timestamp(event) }
                }
            }
        } else { title }
    }
    private func agentHeading(_ event: LensEvent) -> some View {
        Text(store.agentName(event.agentID)).font(LensUI.body.weight(.semibold)).lineLimit(1)
            .help(store.agentName(event.agentID)).accessibilityAddTraits(.isHeader)
    }
    private func timestamp(_ event: LensEvent) -> some View {
        Text(event.timestamp == .distantPast ? LensL10n.text("Horodatage non enregistré") : event.timestamp.lensFormatted(date: .abbreviated, time: .standard))
            .font(LensUI.metadata).foregroundStyle(.secondary).fixedSize()
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if temporary {
                Button(LensL10n.text("Ouvrir dans un onglet")) { store.openLivePreviewInTab() }
                    .fixedSize().accessibilityIdentifier("lens-live-preview-tab")
            }
            if previewEvent != nil {
                Menu {
                    Button(LensL10n.text("Provenance")) { store.perform(.provenance, target: destination) }
                    LensQuestionMenu(store: store, target: destination)
                    if let related = previewEvent?.relatedEventID {
                        Button(LensL10n.text("Ouvrir l’appel / le résultat")) { openRelated(.event(related)) }
                    }
                } label: { LensIconMenuLabel() }
                    .lensIconMenu("Actions de l’aperçu")
                    .accessibilityIdentifier("lens-live-preview-more")
            }
            Button { if store.liveTimelineVisible { store.showLiveEventList() } else { store.browseSection(store.section) } } label: { Image(systemName: LensSymbols.name("xmark")) }
                .buttonStyle(LensQuietButtonStyle())
                .help(LensL10n.text("Fermer l’aperçu et retrouver la liste")).accessibilityLabel(LensL10n.text("Fermer l’aperçu et retrouver la liste"))
        }.controlSize(.small).fixedSize(horizontal: true, vertical: true)
    }
}

private struct LiveEventTextTabs: View {
    @EnvironmentObject var store: LensStore
    let event: LensEvent
    @State private var part = "content"
    init(event: LensEvent) {
        self.event = event
        let initial: String
        switch event.kind {
        case .toolCall, .delegation: initial = "input"
        case .toolResult: initial = "output"
        default: initial = "content"
        }
        _part = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(LensL10n.text("Données"), selection: $part) {
                Text(LensL10n.text("Contenu")).tag("content")
                Text(LensL10n.text("Entrée")).tag("input")
                Text(LensL10n.text("Sortie")).tag("output")
                Text(LensL10n.text("Brut")).tag("raw")
            }.labelsHidden().pickerStyle(.segmented).lensFilledControlAccent().frame(maxWidth: 460, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            RecordedEventText(event: event, part: part).id(event.id + part)
        }
    }
}
