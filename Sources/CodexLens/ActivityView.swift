import SwiftUI
import AppKit
import LensCore

struct ActivityView: View {
    @EnvironmentObject var store: LensStore
    @State private var periodEditorVisible = false
    @State private var timelineGuideVisible = false
    var body: some View {
      GeometryReader { geometry in
        if store.activityMode == .chronology { chronology(width: geometry.size.width) }
        else { CommunicationSequenceView() }
      }
    }
    private func chronology(width: CGFloat) -> some View {
        VSplitView {
            if store.timelineVisible && !store.liveTimelineVisible {
                VStack(spacing: 0) {
                    (width < 620 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))) {
                        timelineHeading.frame(maxWidth: .infinity, alignment: .leading)
                        timelineControls
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    if let issue = store.timelineIssue {
                        Text(LensL10n.display(issue)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                    }
                    TimelineView(store: store)
                }.frame(minHeight: 160, idealHeight: 280)
            }
            EventListView(events: store.events, title: LensL10n.text("Événements"), showTimelineButton: true)
                .frame(minHeight: 220)
        }
        .sheet(isPresented: $periodEditorVisible) {
            TimelinePeriodEditor(initial: store.period ?? store.timelineProjection?.bounds.map { $0.start...$0.end } ?? Date()...Date()) { store.period = $0 }
        }
    }
    private var timelineHeading: some View {
        HStack {
            Text(LensL10n.text("Chronologie")).font(LensUI.paneTitle).fixedSize().accessibilityAddTraits(.isHeader)
            Group {
                if store.timelinePreparing { LensProgressIndicator(accessibilityLabel: LensL10n.text("Préparation des index temporels")).controlSize(.small).help(LensL10n.text("Préparation des index temporels hors interface")) }
                else { Color.clear.accessibilityHidden(true) }
            }.frame(width: 16, height: 16)
        }
    }
    private var timelineControls: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { log2(max(1, store.timelineZoom)) },
                                  set: { store.timelineZoom = pow(2, $0) }),
                   in: 0...log2(store.timelineZoomLimit))
                .frame(minWidth: 60, idealWidth: 100, maxWidth: 120)
                .accessibilityIdentifier("lens-timeline-zoom")
                .accessibilityLabel(LensL10n.text("Zoom temporel"))
                .accessibilityValue(Text("\(store.timelineZoom.formatted(.number.precision(.fractionLength(0...1))))×"))
                .help(LensL10n.text("Zoom temporel ; défilement horizontal pour explorer"))
            Menu {
                TimelineNavigationButtons(store: store)
                Divider()
                Button(LensL10n.text("Période…")) { periodEditorVisible = true }
                Button(LensL10n.text("Tout voir")) { store.resetTimelineExtent() }
                Button(LensL10n.text("Cadrer")) { if let id = store.selectedEvent?.id { store.focusTimelineEvent(id, zoom: true) } }.disabled(store.selectedEvent == nil)
                Divider()
                periodQuestionAction
                Divider()
                Button(LensL10n.text("Repères")) { timelineGuideVisible = true }
            } label: { LensIconMenuLabel() }
                .lensIconMenu("Actions de la chronologie", help: "Période, cadrage et affichage de la chronologie")
                .accessibilityIdentifier("lens-timeline-compact-actions")
                .popover(isPresented: $timelineGuideVisible) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LensL10n.text("Lire la chronologie")).font(.headline)
                        compactTimelineLegend
                        Divider()
                        timelineHint
                    }.font(LensUI.metadata).padding(16).frame(width: 360)
                }
        }.controlSize(.small)
    }
    private var periodQuestionAction: some View {
        Button(LensL10n.text("Ajouter la période à la question")) {
            guard let first = store.events.first else { return }
            let ids = store.events.map(\.id)
            store.investigationPreparationTask?.cancel()
            store.investigationPreparationTask = Task { await store.prepareInvestigation(for: .event(first.id), selectedPeriodEventIDs: ids) }
        }.disabled(store.period == nil || store.events.isEmpty || store.investigation.preparing || store.investigation.sending)
    }
    private var timelineHint: some View {
        Text(LensL10n.text("Groupe : cliquer pour zoomer · événement : sélectionner · double-clic : cadrer · pincement : zoomer · deux doigts : défiler · flèches : naviguer"))
            .fixedSize(horizontal: false, vertical: true)
    }
    private var compactTimelineLegend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach([EventKind.user, .assistant, .toolCall, .delegation, .compaction, .wait, .error], id: \.self) { kind in
                HStack(spacing: 3) { Circle().fill(kind.color).frame(width: 5, height: 5).accessibilityHidden(true); Text(kind.label) }
            }
        }.accessibilityElement(children: .combine).id(LensL10n.resolvedLanguage.rawValue)
    }
}

struct TimelinePeriodEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input: TimelinePeriodSelection
    var apply: (ClosedRange<Date>) -> Void
    init(initial: ClosedRange<Date>, apply: @escaping (ClosedRange<Date>) -> Void) {
        _input = State(initialValue: TimelinePeriodSelection(start: initial.lowerBound, end: initial.upperBound))
        self.apply = apply
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LensL10n.text("Choisir une période")).font(.headline)
            DatePicker(LensL10n.text("Début"), selection: $input.start, displayedComponents: [.date, .hourAndMinute])
            DatePicker(LensL10n.text("Fin"), selection: $input.end, displayedComponents: [.date, .hourAndMinute])
            Text(LensL10n.text("Fuseau horaire : {0}. Les actions chevauchant cette période restent incluses.", String(describing: TimeZone.current.identifier)))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if input.range == nil { Label(LensL10n.text("Choisissez une fin égale ou postérieure au début."), systemImage: LensSymbols.name("exclamationmark.triangle")).font(.caption) }
            HStack {
                Button(LensL10n.text("Annuler")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(LensL10n.text("Appliquer")) { if let range = input.range { apply(range); dismiss() } }
                    .disabled(input.range == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 410)
    }
}

private struct TimelineNavigationButtons: View {
    @ObservedObject var store: LensStore
    private var selectedID: String? { store.selectedEvent?.id }
    private var previousID: String? {
        guard let projection = store.timelineProjection else { return nil }
        return selectedID.flatMap { projection.previous(of: $0) } ?? (selectedID == nil ? projection.orderedEventIDs.last : nil)
    }
    private var nextID: String? {
        guard let projection = store.timelineProjection else { return nil }
        return selectedID.flatMap { projection.next(of: $0) } ?? (selectedID == nil ? projection.orderedEventIDs.first : nil)
    }
    var body: some View {
        Group {
            Button { if let id = previousID { store.navigate(.event(id)) } } label: { Label(LensL10n.text("Événement précédent"), systemImage: "chevron.left") }
                .disabled(previousID == nil).accessibilityLabel(LensL10n.text("Événement précédent"))
                .help(LensL10n.text("Sélectionner l’événement précédent"))
            Button { if let id = nextID { store.navigate(.event(id)) } } label: { Label(LensL10n.text("Événement suivant"), systemImage: "chevron.right") }
                .disabled(nextID == nil).accessibilityLabel(LensL10n.text("Événement suivant"))
                .help(LensL10n.text("Sélectionner l’événement suivant"))
        }.controlSize(.small)
    }
}

struct EventListView: View {
    @EnvironmentObject var store: LensStore
    var events: [LensEvent]
    var title: String
    var showTimelineButton = false
    var isCalls = false
    var body: some View {
        VStack(spacing: 0) {
            if !isCalls {
            HStack {
                Text(title).font(LensUI.paneTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(LensL10n.text("{0}", String(describing: events.count))).font(LensUI.metadata).foregroundStyle(.secondary).monospacedDigit()
                if store.isProjecting { LensProgressIndicator(accessibilityLabel: LensL10n.text("Préparation de la liste des événements")).controlSize(.small) }
                if showTimelineButton, !store.timelineVisible, !store.liveTimelineVisible {
                    Button(LensL10n.text("Afficher la chronologie")) { store.timelineVisible = true }.controlSize(.small)
                }
            }.padding(.horizontal, 16).padding(.vertical, 9).background(LensBrand.chrome)
            Divider()
            } else if store.isProjecting {
                LensProgressIndicator(accessibilityLabel: LensL10n.text("Préparation de la liste des événements"))
                    .controlSize(.small).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if events.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EventTableView(store: store, events: events, title: title, isCalls: isCalls)
            }
        }
    }
    private var emptyKind: RecordedListEmptyState {
        .resolve(isPreparing: store.busy || store.isProjecting || (store.hasSessionReader && !store.query.isEmpty && store.searchMatches == nil),
            sourcesAvailable: store.hasSessionReader, recordedEventCount: store.snapshot?.events.count ?? 0,
            recordedCallCount: store.presentation?.callCount ?? (store.snapshot?.events.contains(where: { $0.kind == .toolCall }) == true ? 1 : 0), callsOnly: isCalls, hasCoverageIssues: !(store.snapshot?.coverage.isEmpty ?? true))
    }
    private var emptyState: some View {
        Group {
            if emptyKind == .preparing { LensLoadingState(title: LensL10n.text("Préparation de la sélection…")) }
            else {
                VStack(alignment: .leading, spacing: 12) {
                    LensSectionHeader(title: emptyTitle, detail: emptyExplanation,
                        symbol: emptyKind == .sourcesUnavailable ? "doc.questionmark" : "magnifyingglass")
                    if emptyKind == .noMatches {
                        LensActionButton(store: store, action: .clearFilters).labelStyle(.titleAndIcon).buttonStyle(.borderedProminent).lensFilledControlAccent()
                    } else {
                        Button(LensL10n.text("Voir les limites des traces")) { store.showCoverage = true }.buttonStyle(.bordered)
                    }
                }.frame(maxWidth: 420, alignment: .leading).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
    private var emptyTitle: String {
        switch emptyKind {
        case .preparing: return LensL10n.text("Préparation de la sélection")
        case .sourcesUnavailable: return LensL10n.text("Journaux indisponibles")
        case .noRecordedEvents: return LensL10n.text("Aucun événement enregistré")
        case .noRecordedCalls: return LensL10n.text("Aucun appel enregistré")
        case .noMatches: return isCalls ? LensL10n.text("Aucun appel pour ces filtres") : LensL10n.text("Aucun événement pour ces filtres")
        }
    }
    private var emptyExplanation: String {
        switch emptyKind {
        case .preparing: return ""
        case .sourcesUnavailable: return LensL10n.text("Sources indisponibles. Consultez les limites des traces ou le contexte enregistré dans l’enquête. L’activité non enregistrée reste inconnue.")
        case .noRecordedEvents(let partial), .noRecordedCalls(let partial):
            return partial ? LensL10n.text("Aucun élément de ce type dans les données chargées. Consultez les limites des traces avant de conclure.") : LensL10n.text("Aucun élément de ce type dans les données chargées. L’activité non enregistrée reste inconnue.")
        case .noMatches: return LensL10n.text("Aucune trace chargée ne correspond à ces filtres. Réinitialisez les filtres pour retrouver les autres événements.")
        }
    }
}

/// Native view-based table: only visible rows create reusable cells. The actor supplies both data and row lookup.
private struct EventTableView: NSViewRepresentable {
    @ObservedObject var store: LensStore
    @AppStorage("lensControlAccent") private var controlAccent = "lens"
    let events: [LensEvent]
    let title: String
    let isCalls: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EventListScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let table = EventNativeTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("event"))
        column.resizingMask = .autoresizingMask; column.minWidth = 240
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = .zero; table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.autoresizingMask = [.width]
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openRecordedEvent(_:))
        table.setAccessibilityLabel(title)
        scroll.documentView = table
        context.coordinator.table = table; context.coordinator.scroll = scroll
        context.coordinator.attachViewportTracking()
        context.coordinator.updateAccent(LensControlAccent(rawValue: controlAccent) ?? .lens)
        table.menuProvider = { [weak coordinator = context.coordinator] in coordinator?.menu(for: $0) }
        table.onReselect = { [weak coordinator = context.coordinator] in coordinator?.revealReselectedRow($0) }
        table.onOpenRow = { [weak coordinator = context.coordinator] in coordinator?.openRow($0) }
        table.toolTip = LensL10n.text("Double-clic ou Retour pour ouvrir l’événement sélectionné.")
        context.coordinator.update(store: store, events: events, isCalls: isCalls, title: title)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.updateAccent(LensControlAccent(rawValue: controlAccent) ?? .lens)
        context.coordinator.update(store: store, events: events, isCalls: isCalls, title: title)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detachViewportTracking()
        coordinator.cancelPendingSelection()
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil; coordinator.table?.menuProvider = nil
        coordinator.table?.target = nil; coordinator.table?.doubleAction = nil; coordinator.table?.onReselect = nil; coordinator.table?.onOpenRow = nil
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: EventNativeTableView?
        weak var scroll: NSScrollView?
        private weak var store: LensStore?
        private var rows: [LensEvent] = []
        private var rowByID: [String: Int] = [:]
        private var version: UUID?
        private var rootID: String?
        private var sourceHome: String?
        private var calls = false
        private var fontSize = 12.0
        private var codeFont: LensCodeFont = .system
        private var accent: LensControlAccent = .lens
        func updateAccent(_ value: LensControlAccent) {
            guard accent != value else { return }
            accent = value
            table?.enumerateAvailableRowViews { row, _ in (row as? LensTableSelectionRowView)?.accent = value }
        }
        private var language = LensL10n.resolvedLanguage.rawValue
        private var selectedID: String?
        private var suppressSelection = false
        private var restorationRevision: Int?
        private var pendingViewport: LensEventListViewport?
        private var applyingViewport = false
        func attachViewportTracking() {
            guard let scroll else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            (scroll as? EventListScrollView)?.onLayout = { [weak self] in self?.restoreViewportIfReady() }
        }
        func detachViewportTracking() {
            recordViewport()
            NotificationCenter.default.removeObserver(self)
            (scroll as? EventListScrollView)?.onLayout = nil
            pendingViewport = nil
        }
        @objc private func viewportChanged() { recordViewport() }
        private func recordViewport() {
            guard !applyingViewport, pendingViewport == nil, !suppressSelection,
                  let scroll, let table, let rootID, let store,
                  scroll.contentSize.height > 1, !rows.isEmpty else { return }
            let origin = scroll.contentView.bounds.origin
            let row = table.row(at: NSPoint(x: 2, y: origin.y + 1))
            guard rows.indices.contains(row) else { return }
            store.recordEventListViewport(LensEventListViewport(rootID: rootID, anchorID: rows[row].id,
                anchorOffset: origin.y - table.rect(ofRow: row).minY, origin: origin, sourceHome: sourceHome), calls: calls)
        }
        private func restoreViewportIfReady() {
            guard !applyingViewport, let saved = pendingViewport, let scroll, let table,
                  scroll.contentSize.width > 1, scroll.contentSize.height > 1,
                  table.bounds.height > 0 else { return }
            applyingViewport = true
            var origin = saved.origin
            if let id = saved.anchorID, let row = rowByID[id] { origin.y = table.rect(ofRow: row).minY + saved.anchorOffset }
            origin.y = min(max(0, origin.y), max(0, table.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
            pendingViewport = nil; applyingViewport = false
            recordViewport()
        }
        private var selectionTask: Task<Void, Never>?
        private var pendingSelection: (rootID: String?, eventID: String, previousSelection: Destination?)?
        private let cellID = NSUserInterfaceItemIdentifier("recordedEventCell")
        func cancelPendingSelection() { selectionTask?.cancel(); selectionTask = nil; pendingSelection = nil }

        func update(store: LensStore, events: [LensEvent], isCalls: Bool, title: String) {
            guard let table, let scroll else { return }
            self.store = store
            let nextVersion = store.presentation?.id, nextRoot = store.presentation?.rootID
            let nextFontSize = min(24, max(10, store.fontSize))
            let nextSourceHome = store.observedSourceHome.standardizedFileURL.path
            let rootChanged = rootID != nextRoot || sourceHome != nextSourceHome
            let dataChanged = version != nextVersion || rootChanged || calls != isCalls || rows.count != events.count
            let fontChanged = fontSize != nextFontSize || codeFont != store.codeFont
            let nextLanguage = LensL10n.resolvedLanguage.rawValue
            let languageChanged = language != nextLanguage
            let nextRowsByID = isCalls ? (store.presentation?.filteredCallRowIndices ?? [:]) : (store.presentation?.filteredEventRowIndices ?? [:])
            if let pending = pendingSelection,
               pending.rootID != nextRoot || pending.rootID != store.snapshot?.root.id || nextRowsByID[pending.eventID] == nil ||
               (store.selection != pending.previousSelection && store.selection != .event(pending.eventID)) {
                cancelPendingSelection()
            }
            // A SwiftUI update may arrive before the deferred delegate callback.
            // Keep the user's pending selection if it still belongs to these rows.
            let nextSelectedID = pendingSelection?.eventID ?? store.selectedEvent?.id
            let selectionChanged = selectedID != nextSelectedID
            let restoring = restorationRevision != store.eventListRestoration
            if restoring || rootChanged { pendingViewport = store.eventListViewport(calls: isCalls) }
            restorationRevision = store.eventListRestoration
            var origin = scroll.contentView.bounds.origin
            var anchorID: String?, anchorOffset: CGFloat = 0
            if dataChanged || fontChanged || languageChanged, !rootChanged, !rows.isEmpty {
                let row = table.row(at: NSPoint(x: 2, y: origin.y + 1))
                if rows.indices.contains(row) { anchorID = rows[row].id; anchorOffset = origin.y - table.rect(ofRow: row).minY }
            }
            table.setAccessibilityLabel(title)
            if dataChanged || fontChanged || languageChanged {
                suppressSelection = true
                rows = events // Copy-on-write values, never a scan or a new UI-side index.
                rowByID = nextRowsByID
                version = nextVersion; rootID = nextRoot; sourceHome = nextSourceHome; calls = isCalls; fontSize = nextFontSize; codeFont = store.codeFont; language = nextLanguage
                table.rowHeight = fontSize >= 18 ? CGFloat(fontSize + 6) * 5.5 : max(84, CGFloat(fontSize + 4) * 5)
                table.reloadData()
                applySelection(nextSelectedID, reveal: false)
                if rootChanged { origin = .zero }
                else if let anchorID, let row = rowByID[anchorID] { origin.y = table.rect(ofRow: row).minY + anchorOffset }
                origin.y = min(max(0, origin.y), max(0, table.bounds.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
                // An explicit cross-view selection takes precedence over a live
                // viewport anchor; an unchanged selection never jumps the reader.
                if selectionChanged && pendingViewport == nil && !restoring { applySelection(nextSelectedID, reveal: true) }
                suppressSelection = false
            } else if selectedID != nextSelectedID {
                suppressSelection = true; applySelection(nextSelectedID, reveal: pendingViewport == nil && !restoring); suppressSelection = false
            }
            selectedID = nextSelectedID
            restoreViewportIfReady()
            recordViewport()
        }
        private func applySelection(_ id: String?, reveal: Bool) {
            guard let table else { return }
            if let id, let row = rowByID[id], rows.indices.contains(row) {
                if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                if reveal { table.scrollRowToVisible(row) }
            } else if table.selectedRow != -1 { table.deselectAll(nil) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = LensTableSelectionRowView(frame: .zero)
            view.accent = accent
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? EventTableCell ?? EventTableCell(frame: .zero)
            cell.identifier = cellID
            let event = rows[row]
            cell.configure(event: event, agentLabel: store?.agentName(event.agentID) ?? event.agentID, fontSize: fontSize, codeFont: codeFont)
            return cell
        }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].title : nil
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let table, rows.indices.contains(table.selectedRow), let store else { return }
            let id = rows[table.selectedRow].id
            selectedID = id
            // SwiftUI can reconfigure/reload the table when navigation publishes.
            // Finish AppKit's selection callback before publishing that change.
            cancelPendingSelection()
            let expectedRoot = rootID
            let previousSelection = store.selection
            pendingSelection = (expectedRoot, id, previousSelection)
            selectionTask = Task { @MainActor [weak self, weak store] in
                await Task.yield()
                guard !Task.isCancelled, let self, let store,
                       self.pendingSelection?.rootID == expectedRoot, self.pendingSelection?.eventID == id else { return }
                self.pendingSelection = nil; self.selectionTask = nil
                guard self.rootID == expectedRoot, store.snapshot?.root.id == expectedRoot,
                      self.selectedID == id, self.rowByID[id] != nil,
                      store.selection == previousSelection || store.selection == .event(id) else { return }
                if store.selectedEvent?.id != id { store.navigate(.event(id)) }
            }
        }
        func revealReselectedRow(_ row: Int) {
            guard rows.indices.contains(row), let store, store.selectedEvent?.id == rows[row].id else { return }
            // Clicking an already selected row is still an explicit reveal intent.
            store.focusTimelineEvent(rows[row].id)
        }
        @objc func openRecordedEvent(_ sender: NSTableView) { openRow(sender.clickedRow) }
        func openRow(_ row: Int) {
            guard rows.indices.contains(row), let store else { return }
            let id = rows[row].id
            cancelPendingSelection()
            // A double-click can finish before the deferred selection delegate.
            // Preserve the row actually selected by AppKit as the workspace anchor.
            if store.selection != .event(id) { store.navigate(.event(id)) }
            store.navigate(.event(id), newTab: true)
        }
        func menu(for row: Int) -> NSMenu? {
            guard rows.indices.contains(row), let store else { return nil }
            let event = rows[row], menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, command: String, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = ["command": command, "id": event.id, "root": store.snapshot?.root.id ?? "", "source": store.observedSourceHome.standardizedFileURL.path]
                item.isEnabled = enabled; menu.addItem(item)
            }
            add(LensAction.investigate.title(in: store), command: "investigate", enabled: store.canPerform(.investigate, target: .event(event.id)))
            if event.isError { add(LensL10n.text("Expliquer cette erreur"), command: "explainError", enabled: store.canPerform(.investigate, target: .event(event.id))) }
            add(LensL10n.text("Ouvrir dans un onglet"), command: "tab")
            if let context = LensApplicationCoordinator.shared.context(for: scroll?.window) {
                let item = NSMenuItem(title: LensAction.openInNewWindow.title(in: store), action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = context.capture(.openInNewWindow, destination: .event(event.id))
                item.isEnabled = store.canPerform(.openInNewWindow, target: .event(event.id)); menu.addItem(item)
            }
            add(LensL10n.text("Afficher dans la chronologie"), command: "timeline")
            add(LensL10n.text("Voir l’agent"), command: "agent")
            if event.environmentID != nil { add(LensL10n.text("Voir l’environnement"), command: "environment") }
            menu.addItem(.separator())
            add(LensL10n.text("Copier l’ID de l’événement"), command: "copyID")
            add(LensL10n.text("Copier le lien interne"), command: "copyLink")
            return menu
        }
        @objc private func menuAction(_ item: NSMenuItem) {
            if let command = item.representedObject as? LensCommandTarget { command.execute(); return }
            guard let payload = item.representedObject as? [String: String], let id = payload["id"], let store,
                  payload["root"] == store.snapshot?.root.id, payload["source"] == store.observedSourceHome.standardizedFileURL.path,
                  let event = store.event(id) else { return }
            switch payload["command"] {
            case "investigate": store.perform(.investigate, target: .event(id))
            case "explainError": store.prepareQuestion(for: .event(id), intent: .explainError)
            case "copyID": store.copyLocalText(id, notice: LensL10n.text("ID de l’événement copié"))
            case "copyLink": store.perform(.copyLink, target: .event(id))
            case "tab": store.navigate(.event(id), newTab: true)
            case "timeline": store.showInTimeline(id)
            case "agent": store.navigate(.agent(event.agentID), newTab: true)
            case "environment": if let environment = event.environmentID { store.navigate(.environment(environment)) }
            default: break
            }
        }
    }
}

@MainActor private final class EventListScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

@MainActor private final class EventNativeTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    var onReselect: ((Int) -> Void)?
    var onOpenRow: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point), wasSelected = clicked >= 0 && clicked == selectedRow
        super.mouseDown(with: event)
        if event.clickCount == 1, wasSelected, selectedRow == clicked { onReselect?(clicked) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(row(at: point))
    }
    override func keyDown(with event: NSEvent) {
        let character = event.charactersIgnoringModifiers
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty, character == "\r" || character == "\u{3}" {
            if selectedRow >= 0 { onOpenRow?(selectedRow) }
        } else if !event.modifierFlags.contains(.command), character == "\u{f729}" || character == "\u{f72b}" {
            guard numberOfRows > 0 else { return }
            let row = character == "\u{f729}" ? 0 : numberOfRows - 1
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); scrollRowToVisible(row)
        } else { super.keyDown(with: event) }
    }
}

/// Draw the semantic color in the current view appearance. CALayer's CGColor
/// would retain a resolved color when an existing row changes appearance.
@MainActor final class LensEventSwatch: NSView {
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor private final class EventTableCell: NSTableCellView {
    override var isFlipped: Bool { true }
    private let timeField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let kindField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let agentField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(wrappingLabelWithString: "")
    private let environmentField = NSTextField(labelWithString: "")
    private let swatch = LensEventSwatch()
    private var baseFontSize = 12.0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for field in [timeField, dateField, kindField, titleField, agentField, previewField, environmentField] {
            field.isSelectable = false; field.lineBreakMode = .byTruncatingTail
            field.setAccessibilityElement(false); addSubview(field)
        }
        previewField.maximumNumberOfLines = 2
        swatch.setAccessibilityElement(false); addSubview(swatch)
        setAccessibilityElement(true); setAccessibilityRole(.cell)
    }
    required init?(coder: NSCoder) { return nil }
    func configure(event: LensEvent, agentLabel: String, fontSize: Double, codeFont: LensCodeFont = .system) {
        baseFontSize = fontSize
        timeField.stringValue = event.timestamp.lensFormatted(date: .omitted, time: .standard)
        dateField.stringValue = event.timestamp.lensFormatted(date: .abbreviated, time: .omitted)
        kindField.stringValue = event.kind.label
        titleField.stringValue = event.title.nonempty ?? event.kind.label
        var identity = agentLabel
        if let end = event.endTime, end >= event.timestamp { identity += " · " + LensUI.duration(end.timeIntervalSince(event.timestamp)) }
        else if event.endTime != nil { identity += LensL10n.text(" · durée incohérente") }
        agentField.stringValue = identity
        previewField.stringValue = event.preview
        environmentField.stringValue = event.environmentID ?? ""
        timeField.font = .monospacedDigitSystemFont(ofSize: CGFloat(max(10, fontSize - 1)), weight: .regular)
        dateField.font = .systemFont(ofSize: CGFloat(max(10, fontSize - 3)))
        kindField.font = .systemFont(ofSize: CGFloat(max(10, fontSize - 3)), weight: .medium)
        titleField.font = .systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        agentField.font = .systemFont(ofSize: CGFloat(max(10, fontSize - 2)))
        previewField.font = event.toolName == nil ? .systemFont(ofSize: CGFloat(fontSize)) : codeFont.nativeFont(size: fontSize)
        environmentField.font = .monospacedSystemFont(ofSize: CGFloat(max(10, fontSize - 3)), weight: .regular)
        dateField.textColor = .secondaryLabelColor; kindField.textColor = .secondaryLabelColor
        agentField.textColor = .secondaryLabelColor; previewField.textColor = .secondaryLabelColor; environmentField.textColor = .secondaryLabelColor
        swatch.tint = LensBrand.eventNSColor(event.isError ? .error : event.kind)
        toolTip = event.title + "\n" + event.preview
        setAccessibilityLabel(LensL10n.text("{0}, {1}, {2}, {3}, agent {4}, {5}", String(describing: timeField.stringValue), String(describing: dateField.stringValue), String(describing: event.kind.label), String(describing: titleField.stringValue), String(describing: identity), String(describing: event.preview)) + (event.environmentID.map { LensL10n.text(", environnement {0}", String(describing: $0)) } ?? ""))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let font = CGFloat(baseFontSize), titleHeight = font + 7, metadataHeight = max(14, font - 1)
        // Reserve a complete 12-hour clock as well as the localized value.
        // English adds AM/PM; an eight-character estimate clipped that suffix.
        let clockWidth = max(("11:59:59 PM" as NSString).size(withAttributes: [.font: timeField.font!]).width,
                             (timeField.stringValue as NSString).size(withAttributes: [.font: timeField.font!]).width)
        let dateWidth = (dateField.stringValue as NSString).size(withAttributes: [.font: dateField.font!]).width
        let timeWidth = max(68, ceil(max(clockWidth, dateWidth)) + 4)
        let textX = timeWidth + 26, textWidth = max(0, bounds.width - textX - 12)
        let stacked = baseFontSize >= 18
        let agentWidth = min(200, max(100, textWidth * 0.30))
        timeField.frame = NSRect(x: 10, y: 8, width: timeWidth, height: titleHeight)
        dateField.frame = NSRect(x: 10, y: 8 + titleHeight, width: timeWidth, height: metadataHeight)
        kindField.frame = NSRect(x: 10, y: bounds.height - metadataHeight - 10, width: timeWidth, height: metadataHeight)
        swatch.frame = NSRect(x: timeWidth + 14, y: 10, width: 3, height: max(0, bounds.height - 20))
        titleField.frame = NSRect(x: textX, y: 6, width: stacked ? textWidth : max(0, textWidth - agentWidth - 10), height: titleHeight)
        agentField.frame = NSRect(x: stacked ? textX : bounds.width - agentWidth - 12,
                                  y: stacked ? titleHeight + 7 : 8, width: stacked ? textWidth : agentWidth, height: titleHeight)
        let previewY = titleHeight + 9 + (stacked ? titleHeight + 2 : 0)
        previewField.frame = NSRect(x: textX, y: previewY, width: textWidth, height: max(0, bounds.height - previewY - metadataHeight - 9))
        environmentField.frame = NSRect(x: textX, y: bounds.height - metadataHeight - 5, width: textWidth, height: metadataHeight)
    }
}

struct EventRow: View {
    let event: LensEvent
    let agentLabel: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 11, design: .monospaced))
                Text(event.timestamp, format: .dateTime.day().month()).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(width: 63, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(event.isError ? .red : event.kind.color).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.kind == .compaction ? LensL10n.text(event.title.nonempty ?? event.kind.label) : event.title.nonempty ?? event.kind.label).font(LensUI.header).lineLimit(1)
                    Spacer()
                    Text(agentLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let end = event.endTime, end >= event.timestamp {
                        Text(LensUI.duration(end.timeIntervalSince(event.timestamp)))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    } else if event.endTime != nil {
                        Text(LensL10n.text("Durée incohérente enregistrée")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(event.preview).font(.system(size: 13, design: event.toolName == nil ? .default : .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
                if let environment = event.environmentID, event.toolName != nil {
                    Text(environment).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct TimelineView: NSViewRepresentable {
    @ObservedObject var store: LensStore
    @ObservedObject private var clock: LensLiveClock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lensReduceMotionOverride) private var reduceMotionOverride
    let live: Bool
    init(store: LensStore, live: Bool = false) { self.store = store; clock = store.liveClock; self.live = live }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = TimelineCanvas(frame: .zero)
        context.coordinator.attach(scroll, store: store)
        context.coordinator.configure(store: store, live: live, animateLive: !(reduceMotionOverride ?? reduceMotion))
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.configure(store: store, live: live, animateLive: !(reduceMotionOverride ?? reduceMotion)) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject {
        private weak var scroll: TimelineScrollView?
        private weak var store: LensStore?
        private var isConfiguring = false
        private var live = false
        private var animateLive = false
        private var liveOrigin = CGPoint.zero
        private var previousReset: Int?
        private var previousZoom: Double?
        private var previousViewport: NSSize?
        private var axisRange: ClosedRange<Date>?
        private var rootID: String?
        private var processedFocus: UUID?
        private var pendingFocus: UUID?
        private var focusTask: Task<Void, Never>?
        private var zoomAnchor: (date: Date, viewportX: CGFloat)?
        func attach(_ scroll: TimelineScrollView, store: LensStore) {
            self.scroll = scroll; self.store = store
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            scroll.onLayout = { [weak self] in self?.resize() }
            scroll.onMagnify = { [weak self] event in self?.magnify(event) ?? false }
            scroll.onPan = { [weak self] event in self?.panLive(event) ?? false }
        }
        func detach() {
            NotificationCenter.default.removeObserver(self)
            focusTask?.cancel(); focusTask = nil; pendingFocus = nil
            scroll?.onLayout = nil; scroll?.onMagnify = nil; scroll?.onPan = nil
            if let canvas = scroll?.documentView as? TimelineCanvas {
                canvas.stopLiveAnimation()
                canvas.onSelect = nil; canvas.onFocus = nil; canvas.onZoomStep = nil
                canvas.onFocusRange = nil; canvas.onOpenTab = nil; canvas.changesLookup = nil; canvas.onChangeSelect = nil
                canvas.onZoomCommand = nil; canvas.canZoomCommand = nil
                canvas.onRange = nil; canvas.onInvestigate = nil; canvas.eventLookup = nil
            }
        }
        private func resize() { if let store, !isConfiguring { configure(store: store, live: live) } }
        @objc private func boundsChanged() {
            // AppKit emits bounds notifications while a reader is remounted,
            // before configure can apply the restored origin. Those layout
            // notifications are not user scrolling and must not replace it.
            guard !isConfiguring, let scroll, let store,
                  previousViewport != nil, rootID == store.snapshot?.root.id,
                  previousReset == store.timelineReset else { return }
            if live { liveOrigin = scroll.contentView.bounds.origin }
            else { store.timelineOrigin = scroll.contentView.bounds.origin }
            scroll.documentView?.needsDisplay = true
        }
        func configure(store: LensStore, live: Bool = false, animateLive: Bool? = nil) {
            guard !isConfiguring, let scroll, let canvas = scroll.documentView as? TimelineCanvas else { return }
            isConfiguring = true; defer { isConfiguring = false }
            self.store = store; self.live = live
            if let animateLive { self.animateLive = animateLive }
            // A remounted reader starts at zero size. Do not clamp the saved
            // timeline origin or infer a zoom anchor until its viewport exists.
            guard scroll.contentSize.width > 1, scroll.contentSize.height > 1 else { return }
            let rootChanged = rootID != store.snapshot?.root.id
            if rootChanged {
                liveOrigin = .zero
                rootID = store.snapshot?.root.id; processedFocus = nil
                focusTask?.cancel(); focusTask = nil; pendingFocus = nil; zoomAnchor = nil
            }
            let viewport = NSSize(width: max(1, scroll.contentSize.width), height: max(120, scroll.contentSize.height))
            let baseWidth = max(live ? 300 : 500, viewport.width)
            let zoom = live ? 1 : min(store.timelineZoomLimit, max(1, store.timelineZoom))
            let resetChanged = previousReset != store.timelineReset
            let extent = live ? store.liveState.window.map { $0.start...$0.end } : (store.timelineWindow ?? store.timelineProjection?.bounds.map { $0.start...$0.end })
            let extentChanged = axisRange != extent
            let scaleChanged = previousZoom != zoom || previousViewport?.width != viewport.width
            let oldOrigin = scroll.contentView.bounds.origin
            let temporalMidpoint = (CGFloat(canvas.geometry?.labelWidth ?? 145) + viewport.width) / 2
            let previousTemporalMidpoint = (CGFloat(canvas.geometry?.labelWidth ?? 145) + (previousViewport?.width ?? viewport.width)) / 2
            let anchor = live ? nil : (zoomAnchor ?? ((!resetChanged && !extentChanged && scaleChanged)
                ? canvas.geometry.map { (date: $0.date(atX: Double(oldOrigin.x + previousTemporalMidpoint), clamped: false), viewportX: temporalMidpoint) } : nil))
            zoomAnchor = nil
            canvas.projection = store.timelineProjection
            canvas.selectedID = store.selectedEvent?.id
            canvas.eventLookup = { [weak store] in store?.event($0) }
            canvas.liveNow = live && store.liveState.following ? store.liveState.window?.end : nil
            canvas.onSelect = { [weak store] id in
                if live { store?.previewLiveEvent(id) } else { store?.navigate(.event(id)) }
            }
            canvas.onFocus = { [weak store] id in
                if live { store?.focusLiveEvent(id) } else { store?.focusTimelineEvent(id, zoom: true) }
            }
            canvas.onFocusRange = { [weak store, weak self] range in
                if live, let window = try? TimelineWindow(start: range.lowerBound, end: range.upperBound) { store?.inspectLiveWindow(window) }
                else if let width = self?.scroll?.contentSize.width {
                    store?.focusTimelinePeriod(range, viewportWidth: Double(width), baseContentWidth: Double(max(500, width)))
                    if let store { self?.configure(store: store) }
                }
            }
            canvas.onOpenTab = { [weak store] in store?.navigate(.event($0), newTab: true) }
            canvas.changesLookup = { [weak store] in store?.liveChanges(for: $0) ?? [] }
            canvas.onChangeSelect = { [weak store] id in
                if live { store?.previewLiveChange(id) } else { store?.navigate(.change(id), newTab: true) }
            }
            canvas.onZoomStep = { [weak self] factor in self?.changeZoom(factor: factor) }
            canvas.onZoomCommand = { [weak self, weak store] action in
                guard let self, let store else { return }
                let factor = 1 + store.readingPreferences.configuration.timelineStep
                switch action {
                case .increase: self.changeZoom(factor: factor)
                case .decrease: self.changeZoom(factor: 1 / factor)
                case .reset:
                    if self.live { store.setLiveSpan(TimelineLiveState.defaultSpan); store.resumeLiveTimeline() }
                    else { self.changeZoom(factor: 1 / store.timelineZoom) }
                }
            }
            canvas.canZoomCommand = { [weak store] action in
                guard let store else { return false }
                if live {
                    switch action {
                    case .increase: return (store.liveState.window?.duration ?? store.liveState.span) > 0.001
                    case .decrease: return (store.liveState.window?.duration ?? store.liveState.span) < TimelineLiveState.spanRange.upperBound
                    case .reset: return !store.follow || store.liveState.span != TimelineLiveState.defaultSpan
                    }
                }
                switch action {
                case .increase: return store.timelineZoom < store.timelineZoomLimit
                case .decrease: return store.timelineZoom > TimelineInteraction.zoomRange.lowerBound
                case .reset: return store.timelineZoom != TimelineInteraction.zoomRange.lowerBound
                }
            }
            canvas.onRange = { [weak store] range in
                if live, let window = try? TimelineWindow(start: range.lowerBound, end: range.upperBound) { store?.inspectLiveWindow(window) }
                else { store?.period = range }
            }
            canvas.onInvestigate = { [weak store] in store?.perform(.investigate, target: .event($0)) }
            canvas.canInvestigate = { [weak store] in store?.canPerform(.investigate, target: .event($0)) == true }
            let width = baseWidth * zoom
            let height = max(viewport.height, CGFloat(max(1, store.timelineProjection?.lanes.count ?? 0)) * 46 + 46)
            let nextGeometry = extent.flatMap { range -> TimelineGeometry? in
                guard let window = try? TimelineWindow(start: range.lowerBound, end: range.upperBound) else { return nil }
                return try? TimelineGeometry(window: window, contentWidth: Double(width), minimumTimeSpan: 0.001)
            }
            canvas.updateGeometry(nextGeometry, animateLive: live && store.liveState.following && self.animateLive && !rootChanged && !scaleChanged && !resetChanged)
            let size = NSSize(width: width, height: height)
            if canvas.frame.size != size { canvas.setFrameSize(size) }
            // Reset uses the store's saved origin; Tout voir already stores zero, while history restores its own origin.
            var origin = live ? liveOrigin : store.timelineOrigin
            if let anchor, let geometry = canvas.geometry { origin.x = CGFloat(geometry.x(for: anchor.date)) - anchor.viewportX }
            origin.x = min(max(0, origin.x), max(0, width - scroll.contentSize.width))
            origin.y = min(max(0, origin.y), max(0, height - scroll.contentSize.height))
            if scroll.contentView.bounds.origin != origin { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
            if live { liveOrigin = origin } else { store.timelineOrigin = origin }
            previousReset = store.timelineReset; previousZoom = zoom; previousViewport = viewport; axisRange = extent
            canvas.configureAccessibility()
            canvas.updateAccessibilitySelection()
            canvas.needsDisplay = true
            if !live { scheduleFocus(store.timelineFocus) }
        }
        private func panLive(_ event: NSEvent) -> Bool {
            guard live, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  event.scrollingDeltaX.isFinite, let store, let window = store.liveState.window,
                  let geometry = (scroll?.documentView as? TimelineCanvas)?.geometry else { return false }
            let shift = -Double(event.scrollingDeltaX) * window.duration / geometry.timeWidth
            guard let next = try? TimelineWindow(start: window.start.addingTimeInterval(shift), end: window.end.addingTimeInterval(shift)) else { return false }
            store.inspectLiveWindow(next)
            configure(store: store, live: true)
            return true
        }
        private func magnify(_ event: NSEvent) -> Bool {
            guard event.magnification.isFinite, let scroll,
                  store?.readingPreferences.configuration.pinchEnabled == true else { return false }
            let point = scroll.contentView.convert(event.locationInWindow, from: nil)
            return changeZoom(factor: max(0.05, 1 + Double(event.magnification)),
                              focalViewportX: point.x - scroll.contentView.bounds.minX)
        }
        @discardableResult private func changeZoom(factor: Double, focalViewportX: CGFloat? = nil) -> Bool {
            guard factor.isFinite, factor > 0, let scroll, let store,
                  let geometry = (scroll.documentView as? TimelineCanvas)?.geometry else { return false }
            let width = scroll.contentSize.width
            let focal = focalViewportX ?? (CGFloat(geometry.labelWidth) + width) / 2
            if live {
                let ratio = min(1, max(0, (Double(focal) - geometry.labelWidth) / geometry.timeWidth))
                let anchor = geometry.date(atX: Double(focal))
                // An inspected group can be shorter than the following clock's
                // 10-second preference. Zooming in must keep refining it.
                let span = min(TimelineLiveState.spanRange.upperBound, max(0.001, geometry.window.duration / factor))
                guard let window = try? TimelineWindow(start: anchor.addingTimeInterval(-span * ratio), end: anchor.addingTimeInterval(span * (1 - ratio))) else { return false }
                store.pauseLiveTimeline(); store.setLiveSpan(span); store.inspectLiveWindow(window)
                configure(store: store, live: true)
                return true
            }
            guard let placement = TimelineInteraction.anchoredZoom(geometry: geometry,
                baseContentWidth: Double(max(500, width)), viewportWidth: Double(width),
                originX: Double(scroll.contentView.bounds.minX), focalViewportX: Double(focal),
                targetZoom: store.timelineZoom * factor, maximumZoom: store.timelineZoomLimit) else { return false }
            guard placement.zoom != store.timelineZoom else { return true }
            zoomAnchor = (placement.anchorDate, CGFloat(placement.anchorViewportX))
            store.timelineZoom = placement.zoom
            configure(store: store)
            return true
        }
        private func scheduleFocus(_ request: TimelineFocusRequest?) {
            guard let request, request.token != processedFocus else {
                if request == nil { focusTask?.cancel(); focusTask = nil; pendingFocus = nil }
                return
            }
            guard let store else { return }
            guard pendingFocus != request.token else { return }
            focusTask?.cancel(); pendingFocus = request.token
            let expectedRoot = rootID
            // NSViewRepresentable updates must not synchronously publish new SwiftUI state.
            focusTask = Task { @MainActor [weak self, weak store] in
                await Task.yield()
                guard !Task.isCancelled, let self, let store,
                      self.rootID == expectedRoot, store.snapshot?.root.id == expectedRoot,
                      store.timelineFocus?.token == request.token,
                      let canvas = self.scroll?.documentView as? TimelineCanvas else { return }
                self.pendingFocus = nil; self.focusTask = nil
                guard let item = store.timelineProjection?.item(id: request.eventID) else {
                    if store.timelineProjection != nil, !store.timelinePreparing { self.processedFocus = request.token }
                    return
                }
                self.processedFocus = request.token
                if request.zoomToEvent, let bounds = store.timelineProjection?.bounds,
                   let window = TimelineInteraction.focusWindow(for: item, within: bounds) {
                    let width = self.scroll?.contentSize.width ?? 500
                    store.focusTimelinePeriod(window.start...window.end, viewportWidth: Double(width),
                        baseContentWidth: Double(max(500, width)), recordHistory: false)
                } else if let geometry = canvas.geometry,
                          geometry.x(for: item.effectiveEnd) - geometry.x(for: item.start) < 3,
                          store.timelineZoom < 8 {
                    // Make a fine marker easier to find without jumping to an isolated point.
                    let width = self.scroll?.contentSize.width ?? 500
                    self.zoomAnchor = (item.start, (CGFloat(geometry.labelWidth) + width) / 2)
                    store.timelineZoom = 8
                }
                self.configure(store: store)
                // A navigation request centers its selection. Later viewport resizing can
                // preserve that date, rather than losing an event against the old right edge.
                canvas.reveal(request.eventID, centered: true)
                if let scroll = self.scroll { store.timelineOrigin = scroll.contentView.bounds.origin }
            }
        }
    }
}

@MainActor final class TimelineScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onMagnify: ((NSEvent) -> Bool)?
    var onPan: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) { if onPan?(event) != true { super.scrollWheel(with: event) } }
    override func layout() { super.layout(); onLayout?() }
    override func magnify(with event: NSEvent) {
        if onMagnify?(event) != true { super.magnify(with: event) }
    }
}

@MainActor final class TimelineCanvas: NSView, LensTimelineZoomTarget {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var projection: TimelineProjection?
    var geometry: TimelineGeometry?
    private var liveTransition: TimelineLiveTransition?
    private var livePlanGeometry: TimelineGeometry?
    private var liveProgress = 1.0
    private var liveTimer: Timer?
    private var liveAnimationStart = 0.0
    private(set) var liveAnimationFrameCount = 0
    var liveAnimationIsRunning: Bool { liveTimer != nil }
    /// Logical geometry changes immediately. Only this native view interpolates its display.
    var displayGeometry: TimelineGeometry? {
        guard let geometry, let liveTransition else { return geometry }
        return geometry.withWindow(liveTransition.window(at: liveProgress)) ?? geometry
    }
    func updateGeometry(_ next: TimelineGeometry?, animateLive: Bool) {
        let displayed = displayGeometry
        let sameTarget = next?.window == geometry?.window && next?.contentWidth == geometry?.contentWidth
        geometry = next
        if sameTarget && animateLive { return }
        stopLiveAnimation()
        guard animateLive, window != nil, let displayed, let next,
              displayed.contentWidth == next.contentWidth,
              let transition = TimelineLiveTransition(source: displayed.window, target: next.window),
              let plan = next.withWindow(transition.queryWindow) else { needsDisplay = true; return }
        liveTransition = transition; livePlanGeometry = plan; liveProgress = 0
        liveAnimationStart = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            // This timer is installed only on the main run loop, including menu tracking.
            MainActor.assumeIsolated { self?.advanceLiveAnimation() }
        }
        liveTimer = timer; RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }
    private func advanceLiveAnimation() {
        guard window != nil else { stopLiveAnimation(); return }
        liveProgress = min(1, (ProcessInfo.processInfo.systemUptime - liveAnimationStart) / 0.32)
        liveAnimationFrameCount &+= 1; accessibleDensityKey = nil; needsDisplay = true
        if liveProgress >= 1 { stopLiveAnimation(); updateAccessibilitySelection() }
    }
    func stopLiveAnimation() {
        liveTimer?.invalidate(); liveTimer = nil
        liveTransition = nil; livePlanGeometry = nil; liveProgress = 1
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLiveAnimation() }
    }
    deinit { liveTimer?.invalidate() }
    var selectedID: String?
    var liveNow: Date?
    var onOpenTab: ((String) -> Void)?
    var changesLookup: ((String) -> [ChangeRecord])?
    var onChangeSelect: ((String) -> Void)?
    var eventLookup: ((String) -> LensEvent?)?
    var onSelect: ((String) -> Void)?
    var onFocus: ((String) -> Void)?
    var onFocusRange: ((ClosedRange<Date>) -> Void)?
    var onZoomStep: ((Double) -> Void)?
    var onZoomCommand: ((LensZoomAction) -> Void)?
    var canZoomCommand: ((LensZoomAction) -> Bool)?
    func canAdjustTimelineZoom(_ action: LensZoomAction) -> Bool { canZoomCommand?(action) == true }
    func adjustTimelineZoom(_ action: LensZoomAction) { if canAdjustTimelineZoom(action) { onZoomCommand?(action) } }
    var onRange: ((ClosedRange<Date>) -> Void)?
    var onInvestigate: ((String) -> Void)?
    var canInvestigate: ((String) -> Bool)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var tracking: NSTrackingArea?
    private var hoverID: String?
    private var hoverClusterID: String?
    private struct DensityKey: Equatable {
        let fingerprint: String
        let window: TimelineWindow
        let width: Double
        let labelWidth: Double
        let rightInset: Double
        let markerWidth: Double
        let minX: Double
        let maxX: Double
    }
    private var densityKey: DensityKey?
    private var accessibleDensityKey: DensityKey?
    private var accessibleDensityLanguage: String?
    private var accessibleDensityRect = NSRect.zero
    private var densityElements: [TimelineDensityAccessibilityElement] = []
    private var densityPlans: [Int: TimelineDensityResult] = [:]
    private(set) var densityCacheBytes = 0
    private(set) var densityQueryCount = 0
    private(set) var densityCacheHits = 0
    private let densityCacheBudget = 2 * 1024 * 1024
    /// Only the current viewport, at most 24 lanes / 2 MiB. No source contents.
    func densityPlan(for lane: Int) -> TimelineDensityResult? {
        guard let projection, let geometry = livePlanGeometry ?? geometry else { return nil }
        let visible = visibleRect.intersection(bounds)
        let minX = Double(visible.minX) + geometry.labelWidth, maxX = Double(visible.maxX)
        guard minX < maxX else { return nil }
        let key = DensityKey(fingerprint: projection.fingerprintSHA256, window: geometry.window,
            width: geometry.contentWidth, labelWidth: geometry.labelWidth, rightInset: geometry.rightInset,
            markerWidth: geometry.minimumMarkerWidth, minX: minX, maxX: maxX)
        if key != densityKey { densityKey = key; densityPlans = [:]; densityCacheBytes = 0 }
        if let cached = densityPlans[lane] { densityCacheHits &+= 1; return cached }
        let span = LensSignposts.begin("TimelineDensity"); defer { span.end() }
        let plan = projection.density(lane: lane, geometry: geometry, xRange: minX...maxX)
        densityQueryCount &+= 1
        var estimate = 128 + plan.details.count * 192 + plan.clusters.count * 192
        for item in plan.details { estimate += item.id.utf8.count + item.agentID.utf8.count }
        for cluster in plan.clusters { estimate += cluster.id.utf8.count + cluster.sampleEventIDs.reduce(0) { $0 + $1.utf8.count + 24 } }
        if estimate <= densityCacheBudget {
            if densityPlans.count >= 24 || densityCacheBytes + estimate > densityCacheBudget { densityPlans = [:]; densityCacheBytes = 0 }
            densityPlans[lane] = plan; densityCacheBytes += estimate
        }
        return plan
    }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configureAccessibility() }
    required init?(coder: NSCoder) { super.init(coder: coder); configureAccessibility() }
    private var accessibilityLanguage: String?
    func configureAccessibility() {
        let language = LensL10n.resolvedLanguage.rawValue
        guard accessibilityLanguage != language else { return }
        accessibilityLanguage = language
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(LensL10n.text("Chronologie des événements par agent"))
        setAccessibilityHelp(LensL10n.text("Utiliser les flèches pour sélectionner un événement, Début et Fin pour les extrémités. La liste détaillée donne accès à tous les événements et à leur contexte."))
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: LensL10n.text("Événement précédent"), handler: { [weak self] in self?.moveSelection(step: -1) ?? false }),
            NSAccessibilityCustomAction(name: LensL10n.text("Événement suivant"), handler: { [weak self] in self?.moveSelection(step: 1) ?? false }),
            NSAccessibilityCustomAction(name: LensL10n.text("Agrandir la chronologie"), handler: { [weak self] in guard let self, self.canAdjustTimelineZoom(.increase), self.onZoomCommand != nil else { return false }; self.adjustTimelineZoom(.increase); return true }),
            NSAccessibilityCustomAction(name: LensL10n.text("Réduire la chronologie"), handler: { [weak self] in guard let self, self.canAdjustTimelineZoom(.decrease), self.onZoomCommand != nil else { return false }; self.adjustTimelineZoom(.decrease); return true }),
            NSAccessibilityCustomAction(name: LensL10n.text("Cadrer l’événement sélectionné"), handler: { [weak self] in
                guard let self, let id = self.selectedID else { return false }; self.onFocus?(id); return self.onFocus != nil
            })
        ])
    }
    override func accessibilityChildren() -> [Any]? {
        guard let projection, let geometry = displayGeometry else { densityElements = []; return [] }
        let visible = visibleRect.intersection(bounds)
        let first = max(0, Int(floor((visible.minY - geometry.rulerHeight) / geometry.laneHeight)))
        let last = min(projection.lanes.count - 1, Int(floor((visible.maxY - geometry.rulerHeight) / geometry.laneHeight)))
        guard first <= last, densityPlan(for: first) != nil else { densityElements = []; return [] }
        let language = LensL10n.resolvedLanguage.rawValue
        if accessibleDensityKey != densityKey || accessibleDensityLanguage != language || accessibleDensityRect != visible {
            accessibleDensityKey = densityKey; accessibleDensityLanguage = language; accessibleDensityRect = visible; densityElements = []
            let fingerprint = projection.fingerprintSHA256
            for lane in first...last {
                guard let plan = densityPlan(for: lane) else { continue }
                for cluster in plan.clusters where densityElements.count < 512 {
                    let element = TimelineDensityAccessibilityElement()
                    element.setAccessibilityRole(.button); element.setAccessibilityParent(self); element.setAccessibilityEnabled(true)
                    element.setAccessibilityLabel(projection.lanes[lane].name + " · " + LensUI.count(cluster.count, singular: LensL10n.text("événement"), plural: LensL10n.text("événements"))
                        + " · " + cluster.window.start.lensFormatted(date: .omitted, time: .standard)
                        + " – " + cluster.window.end.lensFormatted(date: .omitted, time: .standard))
                    element.setAccessibilityHelp(LensL10n.text("Zoomer sur ce groupe"))
                    element.localFrame = clusterRect(cluster, geometry: geometry)
                    element.onPress = { [weak self] in
                        guard let self, self.projection?.fingerprintSHA256 == fingerprint,
                              let current = self.densityPlan(for: lane)?.clusters.first(where: { $0.id == cluster.id }) else { return false }
                        self.focusCluster(current); return self.onFocusRange != nil
                    }
                    densityElements.append(element)
                }
                var accessibleItems = plan.details
                if let selectedID, let selected = projection.item(id: selectedID), selected.laneIndex == lane,
                   nativeRect(selected, geometry: geometry).intersects(visible), !accessibleItems.contains(where: { $0.id == selectedID }) {
                    accessibleItems.insert(selected, at: 0)
                }
                for item in accessibleItems where densityElements.count < 512 {
                    let element = TimelineDensityAccessibilityElement()
                    element.setAccessibilityRole(.button); element.setAccessibilityParent(self); element.setAccessibilityEnabled(true)
                    element.setAccessibilityLabel(projection.lanes[lane].name + " · " + (eventLookup?(item.id)?.title ?? item.id)
                        + " · " + item.start.lensFormatted(date: .omitted, time: .standard))
                    element.setAccessibilityHelp(LensL10n.text("Voir le contexte de l’événement"))
                    element.localFrame = nativeRect(item, geometry: geometry)
                    element.onPress = { [weak self] in
                        guard let self, self.projection?.fingerprintSHA256 == fingerprint else { return false }
                        self.selectEvent(item.id); return self.onSelect != nil
                    }
                    densityElements.append(element)
                }
                if densityElements.count == 512 { break }
            }
        }
        for element in densityElements {
            let local = element.localFrame.intersection(visible)
            element.setAccessibilityFrame(window?.convertToScreen(convert(local, to: nil)) ?? local)
        }
        return densityElements
    }
    func updateAccessibilitySelection() {
        accessibleDensityKey = nil
        if let selectedID, let event = eventLookup?(selectedID) {
            setAccessibilityValue(LensL10n.text("{0} · {1}", String(describing: event.title), String(describing: event.timestamp.lensFormatted(date: .abbreviated, time: .standard))))
        } else { setAccessibilityValue(LensL10n.text("Aucun événement sélectionné")) }
    }
    private func color(_ item: TimelineItem) -> NSColor {
        LensBrand.eventNSColor(item.isError ? .error : item.kind)
    }
    private func nativeRect(_ item: TimelineItem, geometry: TimelineGeometry) -> NSRect {
        let rect = geometry.rect(for: item)
        return NSRect(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.intersection(bounds).fill()
        guard let projection, let geometry = displayGeometry else {
            (LensL10n.text("Préparation de la chronologie…") as NSString).draw(at: NSPoint(x: 16, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { return }
        let labelWidth = CGFloat(geometry.labelWidth), rulerHeight = CGFloat(geometry.rulerHeight), laneHeight = CGFloat(geometry.laneHeight)
        let plot = NSRect(x: visible.minX + labelWidth, y: visible.minY, width: max(0, visible.width - labelWidth), height: visible.height)
        guard plot.width > 0, let queryWindow = try? geometry.window(forXRange: Double(plot.minX)...Double(plot.maxX)) else { return }
        drawRuler(geometry: geometry, visible: visible, plot: plot, dirtyRect: dirtyRect)
        let firstLane = max(0, Int(floor((visible.minY - rulerHeight) / laneHeight)))
        let lastLane = min(projection.lanes.count - 1, Int(floor((visible.maxY - rulerHeight) / laneHeight)))
        guard firstLane <= lastLane else { return }
        for laneIndex in firstLane...lastLane {
            let lane = projection.lanes[laneIndex]
            let row = NSRect(x: visible.minX, y: rulerHeight + CGFloat(laneIndex) * laneHeight, width: visible.width, height: laneHeight)
            guard row.intersects(dirtyRect) else { continue }
            if laneIndex % 2 == 0 { NSColor.alternatingContentBackgroundColors[0].withAlphaComponent(0.25).setFill(); row.fill() }
            guard let result = densityPlan(for: laneIndex) else { continue }
            let plotClip = plot.intersection(row).intersection(dirtyRect).intersection(bounds)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: plotClip).addClip()
            for cluster in result.clusters { draw(cluster, geometry: geometry, clip: plotClip) }
            for item in result.details { draw(item, geometry: geometry, clip: plotClip) }
            if let selectedID, let selected = projection.item(id: selectedID), selected.laneIndex == laneIndex,
               selected.overlap(with: queryWindow) != nil, !result.details.contains(where: { $0.id == selectedID }) {
                drawSelection(selected, geometry: geometry, clip: plotClip)
            }
            NSGraphicsContext.restoreGraphicsState()
            if !result.clusters.isEmpty {
                let message = LensL10n.text("Groupes · cliquer pour zoomer")
                (message as NSString).draw(in: NSRect(x: plot.minX + 8, y: row.maxY - 15, width: max(0, plot.width - 16), height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            }
            NSColor.windowBackgroundColor.setFill(); NSRect(x: visible.minX, y: row.minY, width: labelWidth - 5, height: laneHeight).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (lane.name as NSString).draw(in: NSRect(x: visible.minX + 12, y: row.minY + 10, width: labelWidth - 22, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            let status = !lane.agentIsCatalogued ? LensL10n.text("Identité non cataloguée") : (lane.accessible == false ? LensL10n.text("Historique inaccessible") : LensUI.count(lane.eventCount, singular: LensL10n.text("événement"), plural: LensL10n.text("événements")))
            (status as NSString).draw(in: NSRect(x: visible.minX + 12, y: row.minY + 27, width: labelWidth - 22, height: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            NSColor.separatorColor.setFill(); NSRect(x: visible.minX, y: row.maxY - 1, width: visible.width, height: 0.5).fill()
        }
        if let liveNow {
            let x = CGFloat(geometry.x(for: liveNow))
            if x >= plot.minX, x <= plot.maxX {
                LensControlAccent.current.nsColor.withAlphaComponent(0.6).setStroke()
                let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: rulerHeight)); line.line(to: NSPoint(x: x, y: visible.maxY)); line.lineWidth = 1; line.stroke()
            }
        }
        if let a = dragStart, let b = dragCurrent {
            LensControlAccent.current.nsColor.withAlphaComponent(0.14).setFill()
            NSRect(x: min(a.x, b.x), y: rulerHeight, width: abs(b.x - a.x), height: max(0, bounds.height - rulerHeight)).intersection(plot).fill()
        }
    }
    private func clusterRect(_ cluster: TimelineDensityCluster, geometry: TimelineGeometry) -> NSRect {
        let x = geometry.x(for: cluster.window.start), end = geometry.x(for: cluster.window.end)
        let height = min(geometry.barHeight, 8 + log2(Double(cluster.count) + 1) * 2)
        return NSRect(x: x + 1.5, y: geometry.rulerHeight + Double(cluster.laneIndex) * geometry.laneHeight + geometry.barInset + geometry.barHeight - height,
                      width: max(1, end - x - 3), height: height)
    }
    private func draw(_ cluster: TimelineDensityCluster, geometry: TimelineGeometry, clip: NSRect) {
        let rect = clusterRect(cluster, geometry: geometry).intersection(clip)
        guard !rect.isEmpty else { return }
        LensControlAccent.current.nsColor.withAlphaComponent(hoverClusterID == cluster.id ? 0.25 : 0.15).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        if rect.width >= 24 {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (String(cluster.count) as NSString).draw(in: NSRect(x: rect.minX + 1, y: rect.midY - 6, width: rect.width - 2, height: 13),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        }
        if cluster.errorCount > 0 {
            ("!" as NSString).draw(at: NSPoint(x: rect.minX + 1, y: rect.minY - 1),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: LensAppearance.error])
        }
        if hoverClusterID == cluster.id {
            LensControlAccent.current.nsColor.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).stroke()
        }
    }
    private func drawSelection(_ item: TimelineItem, geometry: TimelineGeometry, clip: NSRect) {
        let rect = nativeRect(item, geometry: geometry).intersection(clip)
        guard !rect.isEmpty else { return }
        LensControlAccent.current.nsColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
        outline.lineWidth = 2; outline.stroke()
    }
    private func draw(_ item: TimelineItem, geometry: TimelineGeometry, clip: NSRect) {
        // Clip before constructing a path: a years-long recorded interval can extend far outside the viewport.
        let rect = nativeRect(item, geometry: geometry).intersection(clip)
        guard !rect.isEmpty else { return }
        color(item).withAlphaComponent(item.id == selectedID ? 1 : 0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        if item.id == hoverID && item.id != selectedID {
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.25; outline.stroke()
        }
        if item.id == selectedID {
            LensControlAccent.current.nsColor.setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1.5; outline.stroke()
        }
    }
    private func drawRuler(geometry: TimelineGeometry, visible: NSRect, plot: NSRect, dirtyRect: NSRect) {
        let ticks = max(4, Int(geometry.timeWidth / 130))
        let first = max(0, Int(floor((Double(plot.minX) - geometry.labelWidth) / geometry.timeWidth * Double(ticks))))
        let last = min(ticks, Int(ceil((Double(plot.maxX) - geometry.labelWidth) / geometry.timeWidth * Double(ticks))))
        guard first <= last else { return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: plot.intersection(dirtyRect)).addClip()
        for index in first...last {
            let x = CGFloat(geometry.labelWidth + Double(index) / Double(ticks) * geometry.timeWidth)
            NSColor.separatorColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.8 : 0.3).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: 36)); line.line(to: NSPoint(x: x, y: bounds.maxY)); line.lineWidth = 0.5; line.stroke()
            let date = geometry.window.start.addingTimeInterval(Double(index) / Double(ticks) * geometry.window.duration)
            let label = geometry.window.duration / Double(ticks) < 1
                ? date.formatted(.dateTime.locale(Locale(identifier: LensL10n.resolvedLanguage.rawValue)).hour().minute().second().secondFraction(.fractional(3)))
                : date.lensFormatted(date: geometry.window.duration > 86400 ? .abbreviated : .omitted, time: .standard)
            (label as NSString)
                .draw(at: NSPoint(x: x + 3, y: 14), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil); dragCurrent = nil
    }
    override func magnify(with event: NSEvent) {
        if let scroll = enclosingScrollView as? TimelineScrollView {
            scroll.magnify(with: event)
        } else { super.magnify(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let geometry = displayGeometry, start.y < CGFloat(geometry.rulerHeight) || event.modifierFlags.contains(.option) else { return }
        dragCurrent = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = dragStart, let end = dragCurrent, abs(end.x - start.x) > 4, let geometry = displayGeometry {
            let lo = geometry.date(atX: Double(min(start.x, end.x))), hi = geometry.date(atX: Double(max(start.x, end.x)))
            onRange?(lo...hi)
        } else { select(at: point, zoom: event.clickCount >= 2) }
        dragStart = nil; dragCurrent = nil; needsDisplay = true
    }
    private func hits(at point: NSPoint, limit: Int = 128) -> TimelineHitResult? {
        guard let projection, let geometry = displayGeometry, point.x >= visibleRect.minX + CGFloat(geometry.labelWidth) else { return nil }
        return projection.hitTest(x: Double(point.x), y: Double(point.y), geometry: geometry, limit: limit)
    }
    private func select(at point: NSPoint, zoom: Bool = false) {
        if let cluster = densityCluster(at: point) { focusCluster(cluster); return }
        guard let hits = hits(at: point), !hits.eventIDs.isEmpty else { return }
        if !hits.requiresDisambiguation, let id = hits.eventIDs.first { selectEvent(id, zoom: zoom); return }
        let menu = selectionMenu(hits, zoom: zoom)
        menu.popUp(positioning: nil, at: point, in: self)
    }
    func densityCluster(at point: NSPoint) -> TimelineDensityCluster? {
        guard let geometry = displayGeometry, let lane = geometry.lane(atY: Double(point.y)),
              point.x >= visibleRect.minX + CGFloat(geometry.labelWidth), let plan = densityPlan(for: lane) else { return nil }
        // Keep the selected marker directly accessible even inside a group.
        if let id = selectedID, let item = projection?.item(id: id), item.laneIndex == lane {
            let rect = nativeRect(item, geometry: geometry)
            if rect.width <= 12, rect.insetBy(dx: -1, dy: -1).contains(point) { return nil }
        }
        return plan.clusters.first { clusterRect($0, geometry: geometry).insetBy(dx: 0, dy: -3).contains(point) }
    }
    func focusCluster(_ cluster: TimelineDensityCluster) {
        guard let geometry = displayGeometry else { return }
        let padding = max(geometry.minimumMarkerWidth / geometry.timeWidth * geometry.window.duration, cluster.window.duration * 0.08)
        onFocusRange?(cluster.window.start.addingTimeInterval(-padding)...cluster.window.end.addingTimeInterval(padding))
    }
    private func clusterMenu(_ cluster: TimelineDensityCluster) -> NSMenu {
        let menu = NSMenu(title: LensUI.count(cluster.count, singular: LensL10n.text("événement"), plural: LensL10n.text("événements")))
        let zoom = NSMenuItem(title: LensL10n.text("Zoomer sur ce groupe"), action: #selector(focusClusterMenuItem(_:)), keyEquivalent: "")
        zoom.target = self; zoom.representedObject = cluster; menu.addItem(zoom)
        let period = NSMenuItem(title: LensL10n.text("Afficher cette période dans la liste"), action: #selector(filterClusterMenuItem(_:)), keyEquivalent: "")
        period.target = self; period.representedObject = cluster; menu.addItem(period)
        menu.addItem(.separator())
        let title = NSMenuItem(title: LensL10n.text("Quelques événements du groupe"), action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        for id in cluster.sampleEventIDs {
            let event = eventLookup?(id)
            let label = event.map { "\($0.timestamp.lensFormatted(date: .omitted, time: .standard)) · \($0.title)" } ?? id
            let item = NSMenuItem(title: String(label.prefix(180)), action: #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; menu.addItem(item)
        }
        return menu
    }
    @objc private func focusClusterMenuItem(_ sender: NSMenuItem) { if let cluster = sender.representedObject as? TimelineDensityCluster { focusCluster(cluster) } }
    @objc private func filterClusterMenuItem(_ sender: NSMenuItem) {
        if let cluster = sender.representedObject as? TimelineDensityCluster { onRange?(cluster.window.start...cluster.window.end) }
    }
    private func selectEvent(_ id: String, zoom: Bool = false) {
        // Immediate local feedback precedes the shared navigation publication.
        selectedID = id; updateAccessibilitySelection(); needsDisplay = true
        onSelect?(id)
        if zoom { onFocus?(id) }
    }
    private func selectionMenu(_ hits: TimelineHitResult, zoom: Bool = false) -> NSMenu {
        let menu = NSMenu(title: LensL10n.text("Événements superposés"))
        for id in hits.eventIDs {
            let event = eventLookup?(id)
            let label = event.map { "\($0.timestamp.lensFormatted(date: .omitted, time: .standard)) · \($0.title)" } ?? id
            let item = NSMenuItem(title: String(label.prefix(180)), action: zoom ? #selector(focusMenuItem(_:)) : #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; menu.addItem(item)
        }
        if hits.uninspectedCandidates > 0 {
            menu.addItem(.separator())
            let omitted = NSMenuItem(title: LensL10n.text("{0} autres candidats ; utiliser la liste détaillée", String(describing: hits.uninspectedCandidates)), action: nil, keyEquivalent: "")
            omitted.isEnabled = false; menu.addItem(omitted)
        }
        return menu
    }
    @objc private func selectMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { selectEvent(id) } }
    @objc private func focusMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { selectEvent(id, zoom: true) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let cluster = densityCluster(at: point) { return clusterMenu(cluster) }
        guard let hits = hits(at: point), !hits.eventIDs.isEmpty else { return nil }
        if hits.requiresDisambiguation { return selectionMenu(hits) }
        guard let id = hits.eventIDs.first else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        let select = NSMenuItem(title: LensL10n.text("Voir le contexte de l’événement"), action: #selector(selectMenuItem(_:)), keyEquivalent: "")
        select.target = self; select.representedObject = id; menu.addItem(select)
        if let context = LensApplicationCoordinator.shared.context(for: window) {
            for action in [LensAction.openInNewTab, .openInNewWindow] {
                let item = NSMenuItem(title: action.title(in: context.store), action: #selector(openCapturedCommand(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = context.capture(action, destination: .event(id))
                item.isEnabled = context.store.canPerform(action, target: .event(id)); menu.addItem(item)
            }
        } else {
            let tab = NSMenuItem(title: LensL10n.text("Ouvrir dans un onglet"), action: #selector(openTabMenuItem(_:)), keyEquivalent: "")
            tab.target = self; tab.representedObject = id; menu.addItem(tab)
        }
        for change in changesLookup?(id) ?? [] {
            let diff = NSMenuItem(title: LensL10n.text("Aperçu du diff : {0}", URL(fileURLWithPath: change.path).lastPathComponent), action: #selector(changeMenuItem(_:)), keyEquivalent: "")
            diff.target = self; diff.representedObject = change.id; diff.toolTip = change.environmentID + "\n" + change.path; menu.addItem(diff)
        }
        let focus = NSMenuItem(title: LensL10n.text("Cadrer cet événement"), action: #selector(focusMenuItem(_:)), keyEquivalent: "")
        focus.target = self; focus.representedObject = id; menu.addItem(focus)
        let investigate = NSMenuItem(title: LensL10n.text("Préparer une question contextualisée"), action: #selector(investigateMenuItem(_:)), keyEquivalent: "")
        investigate.target = self; investigate.representedObject = id; investigate.isEnabled = canInvestigate?(id) == true; menu.addItem(investigate)
        return menu
    }
    @objc private func openTabMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onOpenTab?(id) } }
    @objc private func openCapturedCommand(_ sender: NSMenuItem) { (sender.representedObject as? LensCommandTarget)?.execute() }
    @objc private func changeMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onChangeSelect?(id) } }
    @objc private func investigateMenuItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, canInvestigate?(id) == true { onInvestigate?(id) } }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "\r", let id = selectedID { onOpenTab?(id); return }
        guard !event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers {
        case "\u{f702}", "\u{f700}": _ = moveSelection(step: -1, sameAgent: event.modifierFlags.contains(.option))
        case "\u{f703}", "\u{f701}": _ = moveSelection(step: 1, sameAgent: event.modifierFlags.contains(.option))
        case "\u{f729}": if let id = projection?.orderedEventIDs.first { onSelect?(id); reveal(id) }
        case "\u{f72b}": if let id = projection?.orderedEventIDs.last { onSelect?(id); reveal(id) }
        case "+", "=": adjustTimelineZoom(.increase)
        case "-": adjustTimelineZoom(.decrease)
        case "\r": if let id = selectedID { onFocus?(id) }
        case "\u{1b}": dragStart = nil; dragCurrent = nil; needsDisplay = true
        default: super.keyDown(with: event)
        }
    }
    @discardableResult private func moveSelection(step: Int, sameAgent: Bool = false) -> Bool {
        guard let projection else { return false }
        let target: String?
        if let selectedID, let item = projection.item(id: selectedID) {
            let agent = sameAgent ? item.agentID : nil
            target = step < 0 ? projection.previous(of: selectedID, inAgent: agent) : projection.next(of: selectedID, inAgent: agent)
        } else { target = step < 0 ? projection.orderedEventIDs.last : projection.orderedEventIDs.first }
        guard let target else { return false }
        selectEvent(target); reveal(target); return true
    }
    func reveal(_ id: String, centered: Bool = false) {
        guard let item = projection?.item(id: id), let geometry = displayGeometry, let scroll = enclosingScrollView else { return }
        let rect = nativeRect(item, geometry: geometry), visible = scroll.contentView.bounds
        var origin = visible.origin
        let labelWidth = CGFloat(geometry.labelWidth)
        if centered { origin.x = rect.midX - (visible.width + labelWidth) / 2 }
        else if rect.minX < visible.minX + labelWidth { origin.x = max(0, rect.minX - labelWidth - 8) }
        else if rect.minX > visible.maxX - 12 { origin.x = max(0, rect.minX - visible.width + 24) }
        if rect.minY < visible.minY + 8 { origin.y = max(0, rect.minY - 8) }
        else if rect.maxY > visible.maxY - 8 { origin.y = rect.maxY - visible.height + 8 }
        origin.x = min(origin.x, max(0, bounds.width - visible.width)); origin.y = min(origin.y, max(0, bounds.height - visible.height))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cluster = densityCluster(at: point) {
            if hoverClusterID != cluster.id || hoverID != nil { hoverClusterID = cluster.id; hoverID = nil; needsDisplay = true }
            toolTip = LensL10n.text("{0} événements dans ce groupe · cliquer pour zoomer", String(cluster.count))
                + "\n" + cluster.window.start.lensFormatted(date: .omitted, time: .standard) + " – " + cluster.window.end.lensFormatted(date: .omitted, time: .standard)
                + "\n" + LensL10n.text("{0} erreurs · {1} compactages", String(cluster.errorCount), String(cluster.compactionCount))
                + "\n" + LensL10n.text("Un intervalle long peut apparaître dans plusieurs groupes. Les marqueurs proches des limites sont inclus.")
            return
        }
        if hoverClusterID != nil { hoverClusterID = nil; needsDisplay = true }
        let hits = hits(at: point, limit: 4)
        let nextHover = hits?.requiresDisambiguation == false ? hits?.eventIDs.first : nil
        if nextHover != hoverID {
            let old = hoverID; hoverID = nextHover
            if let geometry = displayGeometry {
                for id in [old, nextHover].compactMap({ $0 }) {
                    if let item = projection?.item(id: id) { setNeedsDisplay(nativeRect(item, geometry: geometry).insetBy(dx: -2, dy: -2)) }
                }
            }
        }
        guard let hits, let id = hits.eventIDs.first, let record = eventLookup?(id) else { toolTip = nil; return }
        let ambiguity = hits.requiresDisambiguation ? LensL10n.text("\nPlusieurs événements se superposent ; cliquer pour choisir.") : ""
        toolTip = record.title + " · " + record.timestamp.lensFormatted(date: .abbreviated, time: .standard) + "\n" + String(record.preview.prefix(1800)) + ambiguity
    }
    override func mouseExited(with event: NSEvent) {
        if hoverClusterID != nil { hoverClusterID = nil; needsDisplay = true }
        if let id = hoverID, let item = projection?.item(id: id), let geometry = displayGeometry {
            setNeedsDisplay(nativeRect(item, geometry: geometry).insetBy(dx: -2, dy: -2))
        }
        hoverID = nil; toolTip = nil
    }
}

@MainActor private final class TimelineDensityAccessibilityElement: NSAccessibilityElement {
    var localFrame = NSRect.zero
    var onPress: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { onPress?() ?? false }
}

private extension TimelineGeometry {
    func withWindow(_ window: TimelineWindow) -> TimelineGeometry? {
        try? TimelineGeometry(window: window, contentWidth: contentWidth, labelWidth: labelWidth,
            rightInset: rightInset, rulerHeight: rulerHeight, laneHeight: laneHeight,
            barHeight: barHeight, barInset: barInset, minimumMarkerWidth: minimumMarkerWidth,
            minimumTimeSpan: minimumTimeSpan)
    }
}
