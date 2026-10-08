import SwiftUI
import LensCore

private struct ChangesDeferredSelectionDiagnosticKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable ([String: String]) -> Void)? = nil
}
extension EnvironmentValues {
    /// Native fixture diagnostics are opt-in; production records no selection data.
    var lensChangesDeferredSelectionDiagnostic: (@MainActor @Sendable ([String: String]) -> Void)? {
        get { self[ChangesDeferredSelectionDiagnosticKey.self] }
        set { self[ChangesDeferredSelectionDiagnosticKey.self] = newValue }
    }
}

enum ChangesOverviewMode: String, Codable, CaseIterable {
    case files, activity
}

enum ChangesOverviewDetailMode: String, Codable {
    case recorded, currentGit
}

/// Presentation state belongs to the window's navigation checkpoint. Source
/// grouping and operation identities come from the immutable core projection.
struct ChangesOverviewView: View {
    @EnvironmentObject private var store: LensStore
    @Environment(\.lensAccent) private var accent
    @Environment(\.lensWindowContext) private var windowContext
    @Environment(\.lensChangesDeferredSelectionDiagnostic) private var selectionDiagnostic
    let projection: ChangesOverviewProjection
    @Binding var environmentID: String?
    @Binding var fileID: String?
    @Binding var mode: ChangesOverviewMode
    @Binding var detailMode: ChangesOverviewDetailMode
    var showsModeControls = true
    @State private var identityExpanded = false
    @State private var selectedGraphBin: GraphBin?
    @State private var graphInfoVisible = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionGeneration = UUID()
    @State private var pendingSelection: PendingSelection?

    private enum EnvironmentSelection: Hashable {
        case all, environment(String)
    }
    private enum PendingSelection: Equatable {
        case environment(EnvironmentSelection), file(String), activity(String), trace(String)
    }
    private struct ActivityLane: Identifiable {
        let group: ChangesOverviewEnvironment
        let activities: [ChangesOverviewActivity]
        let bins: [GraphBin]
        var id: String { group.id }
    }
    private struct GraphBin: Identifiable {
        let id: String
        let environmentID: String
        let timestamp: Date
        let activities: [ChangesOverviewActivity]
    }
    private var selectedChange: ChangeRecord? {
        guard case .change(let id) = store.selection else { return nil }
        return store.change(id)
    }
    /// Scoped arrays and lookup tables are assembled once for a body render,
    /// then reused by lists, headers, selectors and graph points.
    private struct Scope {
        let groups: [ChangesOverviewEnvironment]
        let groupsByID: [String: ChangesOverviewEnvironment]
        let files: [ChangesOverviewFile]
        let filesByID: [String: ChangesOverviewFile]
        let selectedFile: ChangesOverviewFile?
        let selectedEnvironment: ChangesOverviewEnvironment?
        let selectedChange: ChangeRecord?
        let selectedActivity: ChangesOverviewActivity?
        let lanes: [ActivityLane]
        let activitiesByID: [String: ChangesOverviewActivity]
        let selectedGraphActivityID: String?
        let selectedFileTraceIDs: Set<String>
        let visibleTraceIDs: Set<String>
        let operationCount: Int
        let firstGraphTimestamp: Date?
        let lastGraphTimestamp: Date?
        let unknownDateOperationCount: Int

        init(projection: ChangesOverviewProjection, environmentID: String?, fileID: String?, change: ChangeRecord?) {
            let groupLookup = Dictionary(uniqueKeysWithValues: projection.groups.map { ($0.id, $0) })
            let scopedGroups = projection.groups.filter { environmentID == nil || $0.id == environmentID }
            let scopedFiles = scopedGroups.flatMap(\.files)
            let fileLookup = Dictionary(uniqueKeysWithValues: scopedFiles.map { ($0.id, $0) })
            let file = fileID.flatMap { fileLookup[$0] }
            groupsByID = groupLookup; groups = scopedGroups
            files = scopedFiles; filesByID = fileLookup
            selectedFile = file
            selectedEnvironment = (file?.environmentID ?? environmentID).flatMap { groupLookup[$0] }
            selectedChange = change
            selectedActivity = change.flatMap { selected in file?.activities.first { $0.traceIDs.contains(selected.id) } }
            let activities = scopedGroups.flatMap(\.activities)
            activitiesByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
            selectedGraphActivityID = change.flatMap { selected in activities.first { $0.traceIDs.contains(selected.id) }?.id }
            selectedFileTraceIDs = Set(file?.traceIDs ?? [])
            visibleTraceIDs = Set(scopedGroups.flatMap(\.traceIDs))
            operationCount = scopedGroups.reduce(0) { $0 + $1.activityCount }
            let timestamps = activities.compactMap(\.firstTimestamp)
            let first = timestamps.min(), last = timestamps.max()
            firstGraphTimestamp = first; lastGraphTimestamp = last
            unknownDateOperationCount = activities.filter { $0.unknownTimestampCount > 0 }.count
            lanes = scopedGroups.map { group in
                var bins: [Int: [ChangesOverviewActivity]] = [:]
                if let first, let last {
                    let interval = last.timeIntervalSince(first)
                    for activity in group.activities {
                        guard let date = activity.firstTimestamp else { continue }
                        let fraction = interval > 0 ? date.timeIntervalSince(first) / interval : 0
                        let bin = min(159, max(0, Int(floor(fraction * 160))))
                        bins[bin, default: []].append(activity)
                    }
                }
                let marks = bins.keys.sorted().compactMap { index -> GraphBin? in
                    guard let members = bins[index], let date = members.compactMap(\.firstTimestamp).min() else { return nil }
                    return GraphBin(id: group.id + "/" + String(index), environmentID: group.id, timestamp: date, activities: members)
                }
                return ActivityLane(group: group, activities: group.activities, bins: marks)
            }
        }
    }

    var body: some View {
        let scope = Scope(projection: projection, environmentID: environmentID, fileID: fileID, change: selectedChange)
        return GeometryReader { geometry in
            let wide = geometry.size.width >= 850
            let horizontal = geometry.size.width >= 560
            VStack(spacing: 0) {
                overviewHeader(scope, wide: wide, horizontal: horizontal)
                Divider()
                HSplitView {
                    if wide {
                        environmentSidebar(scope).frame(minWidth: 150, idealWidth: 180, maxWidth: 300)
                            .background(LensPaneSizing(key: "changes-environments", preferredWidth: 180, context: windowContext))
                    }
                    if horizontal {
                        HSplitView {
                            browser(scope).frame(minWidth: 200, idealWidth: 270, maxWidth: mode == .activity ? 580 : 440)
                                .background(LensPaneSizing(key: "changes-files", preferredWidth: 270, context: windowContext))
                            detailPane(scope).frame(minWidth: 280, idealWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VSplitView {
                            browser(scope).frame(minHeight: 100, idealHeight: 220, maxHeight: .infinity)
                                .background(LensPaneSizing(key: "changes-files-vertical", preferredWidth: 220, context: windowContext, isVertical: false))
                            detailPane(scope).frame(minHeight: 180, idealHeight: 380, maxHeight: .infinity)
                        }
                    }
                }
            }.accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lens-changes-overview")
        .task(id: selectedChange?.id) { synchronizeSelectedChange() }
        .popover(item: $selectedGraphBin) { bin in graphBinOperations(bin) }
        .onDisappear { cancelDeferredSelection() }
    }

    @ViewBuilder private func browser(_ scope: Scope) -> some View {
        if mode == .files { fileList(scope) }
        else { activityBrowser(scope) }
    }

    private func overviewHeader(_ scope: Scope, wide: Bool, horizontal: Bool) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Text(fileOperationCount(files: scope.files.count, operations: scope.operationCount))
                    .font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(1)
                    .help(LensL10n.text("Une opération peut toucher plusieurs fichiers. Ses traces restent distinctes."))
                Spacer(minLength: 4)
                if horizontal && showsModeControls { modePicker(segmented: true) }
                currentGitButton(scope)
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("lens-changes-overview-main-controls")
            if !wide {
                HStack(spacing: 8) {
                    environmentPicker
                    if !horizontal && showsModeControls { modePicker(segmented: false) }
                    if let group = scope.selectedEnvironment {
                        Menu { recordedIdentity(group) } label: { LensIconMenuLabel("info.circle") }
                            .lensIconMenu("Identité enregistrée")
                    }
                }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier("lens-changes-overview-compact-controls")
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lens-changes-overview-header")
    }

    @ViewBuilder private func modePicker(segmented: Bool) -> some View {
        let picker = Picker(LensL10n.text("Présentation des modifications"), selection: $mode) {
            Text(LensL10n.text("Fichiers")).tag(ChangesOverviewMode.files)
            Text(LensL10n.text("Activité des worktrees")).tag(ChangesOverviewMode.activity)
        }.labelsHidden()
        if segmented {
            picker.pickerStyle(.segmented).frame(width: 230)
                .accessibilityIdentifier("lens-changes-overview-mode")
        } else {
            picker.pickerStyle(.menu).frame(maxWidth: .infinity)
                .accessibilityIdentifier("lens-changes-overview-mode")
        }
    }

    private func currentGitButton(_ scope: Scope) -> some View {
        Button(LensL10n.text(detailMode == .currentGit ? "Traces enregistrées" : "Diff Git actuel")) {
            detailMode = detailMode == .currentGit ? .recorded : .currentGit
        }.buttonStyle(LensQuietButtonStyle()).controlSize(.small)
            .disabled(detailMode != .currentGit && (scope.selectedEnvironment == nil || scope.selectedEnvironment?.id.isEmpty == true))
            .help(LensL10n.text("Consulter le diff Git actuel de l’environnement sélectionné."))
            .accessibilityLabel(LensL10n.text(detailMode == .currentGit ? "Traces enregistrées" : "Diff Git actuel"))
            .accessibilityIdentifier("lens-changes-current-git")
    }

    private var environmentPicker: some View {
        Picker(LensL10n.text("Environnements"), selection: Binding<EnvironmentSelection>(
            get: { environmentID.map(EnvironmentSelection.environment) ?? .all },
            set: { selectEnvironment($0) })) {
            Text(LensL10n.text("Tous les environnements")).tag(EnvironmentSelection.all)
            ForEach(projection.groups) { group in
                Text(environmentName(group)).tag(EnvironmentSelection.environment(group.id)).help(group.environment.path)
            }
        }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
            .accessibilityIdentifier("lens-changes-environments")
    }

    private func environmentSidebar(_ scope: Scope) -> some View {
        VStack(spacing: 0) {
            paneHeading("Environnements")
            List(selection: environmentSelection) {
                Label(LensL10n.text("Tous les environnements"), systemImage: LensSymbols.name("square.grid.2x2"))
                    .font(LensUI.metadata).tag(EnvironmentSelection.all)
                ForEach(projection.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(environmentName(group), systemImage: LensSymbols.name("folder"))
                            .font(LensUI.metadata.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(fileOperationCount(files: group.files.count, operations: group.activityCount))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(EnvironmentSelection.environment(group.id))
                        .help(group.environment.path)
                }
            }.listStyle(.sidebar).accessibilityIdentifier("lens-changes-environments")
            if let group = scope.selectedEnvironment {
                Divider()
                DisclosureGroup(LensL10n.text("Identité enregistrée"), isExpanded: $identityExpanded) {
                    VStack(alignment: .leading, spacing: 6) { recordedIdentity(group) }
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
                }.font(LensUI.metadata).padding(10)
            }
        }
    }

    private var environmentSelection: Binding<EnvironmentSelection?> {
        Binding(get: { environmentID.map(EnvironmentSelection.environment) ?? .all }, set: { value in
            if let value { selectEnvironment(value) }
        })
    }

    @ViewBuilder private func recordedIdentity(_ group: ChangesOverviewEnvironment) -> some View {
        Text(group.environment.path).font(.caption.monospaced()).textSelection(.enabled)
        Text(group.environment.recordedBranch.map { LensL10n.text("Branche enregistrée : ") + $0 } ?? LensL10n.text("Branche historique inconnue"))
        if let ref = group.environment.recordedRef {
            Text(LensL10n.text("Référence enregistrée : {0}", ref)).font(.caption.monospaced())
        }
        if group.isSynthetic { Text(LensL10n.text("Chemin cité par une trace ; identité du dépôt non établie.")) }
    }

    private func fileList(_ scope: Scope) -> some View {
        VStack(spacing: 0) {
            paneHeading("Fichiers enregistrés")
            ScrollViewReader { proxy in
                List(selection: Binding<String?>(get: { fileID }, set: { id in
                    guard let id, let file = scope.filesByID[id] else { return }
                    selectFile(file)
                })) {
                    ForEach(scope.files) { file in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent).font(LensUI.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            }
                            Text(file.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            if environmentID == nil, let group = scope.groupsByID[file.environmentID] {
                                Text(environmentName(group)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Text(LensL10n.text("{0} · {1}",
                                LensUI.count(file.activityCount, singular: "opération", plural: "opérations"),
                                LensUI.count(file.traceIDs.count, singular: "trace", plural: "traces")))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(file.id).id(file.id).help(file.path)
                            .contextMenu {
                                Button(LensL10n.text("Ouvrir le fichier actuel")) {
                                    store.navigate(.file(environment: file.environmentID, path: file.path), newTab: true)
                                }
                            }
                    }
                }.listStyle(.plain).accessibilityIdentifier("lens-changes-files")
                    .overlay {
                        if scope.files.isEmpty {
                            LensCollectionEmptyState(title: LensL10n.text("Aucune modification correspondante"),
                                detail: LensL10n.text("Vérifiez la nature de la trace, la recherche et les filtres d’agent, d’environnement ou de période. Ces filtres restent conservés."), symbol: "doc.text")
                        }
                    }
                    .task(id: fileID) {
                        await Task.yield()
                        guard !Task.isCancelled, let fileID else { return }
                        proxy.scrollTo(fileID, anchor: .center)
                    }
            }
        }
    }

    private func activityBrowser(_ scope: Scope) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(LensL10n.text("Activité enregistrée")).font(LensUI.paneTitle)
                Button { graphInfoVisible = true } label: {
                    Image(systemName: LensSymbols.name("info.circle"))
                }.buttonStyle(LensQuietButtonStyle()).controlSize(.small)
                    .accessibilityLabel(LensL10n.text("Informations sur le graphe d’activité"))
                    .help(LensL10n.text("Informations sur le graphe d’activité"))
                    .accessibilityIdentifier("lens-changes-graph-info")
                    .popover(isPresented: $graphInfoVisible) { graphInformation }
                Spacer(minLength: 4)
                if scope.selectedFile != nil {
                    Button(LensL10n.text("Tous les fichiers")) { fileID = nil }
                        .buttonStyle(LensQuietButtonStyle()).controlSize(.small)
                }
            }.padding(10)
            VSplitView {
                activityGraph(scope).frame(minHeight: 100, idealHeight: 230, maxHeight: .infinity)
                activityList(scope).frame(minHeight: 70, idealHeight: 230, maxHeight: .infinity)
            }
        }
    }

    private var graphInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LensL10n.text("Informations sur le graphe d’activité")).font(LensUI.paneTitle)
            Text(LensL10n.text("Chaque ligne représente un environnement. Les points regroupent les premières traces datées des opérations proches."))
            Text(LensL10n.text("Les points groupés affichent le nombre d’opérations et donnent accès à chacune."))
            Text(LensL10n.text("Les branches sont celles des traces. Aucune filiation Git ni date de création des worktrees n’est établie."))
        }.font(LensUI.metadata).padding(14).frame(width: 330)
    }

    private func activityGraph(_ scope: Scope) -> some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let file = scope.selectedFile {
                    Text(LensL10n.text("Points en évidence : {0}", file.relativePath))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(file.path)
                }
                if let first = scope.firstGraphTimestamp, let last = scope.lastGraphTimestamp {
                    ForEach(scope.lanes) { lane in
                        graphLane(lane, scope: scope, first: first, last: last)
                    }
                    HStack {
                        Text(first, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                        Spacer()
                        Text(last, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(LensL10n.text("Aucun horodatage connu pour ces opérations.")).font(LensUI.metadata).foregroundStyle(.secondary)
                }
                if scope.unknownDateOperationCount > 0 {
                    Text(LensL10n.text("Traces sans date : {0}. Les opérations restent accessibles dans la liste.",
                        LensUI.count(scope.unknownDateOperationCount, singular: "opération", plural: "opérations")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
        }.accessibilityIdentifier("lens-changes-activity-graph")
    }

    private func graphLane(_ lane: ActivityLane, scope: Scope, first: Date, last: Date) -> some View {
        let selectedTraceID = scope.selectedChange?.id
        let fileTraceIDs = scope.selectedFileTraceIDs
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(environmentName(lane.group)).font(LensUI.metadata.weight(.medium))
                Text(lane.group.environment.recordedBranch ?? LensL10n.text("Branche historique inconnue")).font(.caption).foregroundStyle(.secondary)
            }.lineLimit(1).truncationMode(.middle).frame(width: 135, alignment: .leading)
                .help(lane.group.environment.path + "\n" + (lane.group.environment.recordedBranch ?? LensL10n.text("Branche historique inconnue")))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(height: 1).accessibilityHidden(true)
                    ForEach(lane.bins) { bin in
                            let selected = selectedTraceID.map { id in bin.activities.contains { $0.traceIDs.contains(id) } } ?? false
                            let belongsToFile = bin.activities.contains { activity in activity.traceIDs.contains { fileTraceIDs.contains($0) } }
                            Button {
                                if bin.activities.count == 1, let activity = bin.activities.first { selectActivity(activity) }
                                else { selectedGraphBin = bin }
                            } label: {
                                if bin.activities.count > 1 {
                                    Text(formattedNumber(bin.activities.count)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                                        .minimumScaleFactor(0.5).frame(width: 22, height: 22)
                                        .background { Circle().fill(selected || belongsToFile ? accent.color.opacity(0.2) : Color.secondary.opacity(0.15)) }
                                        .overlay { Circle().stroke(selected ? Color.primary : Color.secondary, lineWidth: selected ? 1.5 : 0.5) }
                                        .frame(width: 24, height: 30).contentShape(Rectangle())
                                } else {
                                Circle().fill(selected || belongsToFile ? accent.color : Color.secondary)
                                    .frame(width: selected ? 11 : belongsToFile ? 9 : 7, height: selected ? 11 : belongsToFile ? 9 : 7)
                                    .overlay { if selected { Circle().stroke(Color.primary, lineWidth: 1) } }
                                    .frame(width: 24, height: 30).contentShape(Rectangle())
                                }
                            }.buttonStyle(.plain)
                                .position(x: graphPosition(bin.timestamp, first: first, last: last, width: geometry.size.width), y: geometry.size.height / 2)
                                .help(graphBinLabel(bin))
                                .accessibilityLabel(LensL10n.text("{0} · {1}", environmentName(lane.group), graphBinLabel(bin)))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("lens-changes-graph-bin")
                    }
                }.frame(maxHeight: .infinity)
            }.frame(height: 42)
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("lens-changes-graph-lane")
    }

    private func activityList(_ scope: Scope) -> some View {
        return List(selection: Binding<String?>(get: {
            if case .activity(let id) = pendingSelection { return id }
            return scope.selectedGraphActivityID
        }, set: { id in
            if let id, let activity = scope.activitiesByID[id] { selectActivity(activity) }
        })) {
            ForEach(scope.lanes) { lane in
                Section(environmentName(lane.group)) {
                    ForEach(lane.activities) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activityLabel(activity)).font(LensUI.metadata).lineLimit(2)
                            Text(activity.kinds.map(changeLabel).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 4).tag(activity.id)
                    }
                }
            }
        }.listStyle(.plain).accessibilityLabel(LensL10n.text("Liste des opérations enregistrées"))
            .accessibilityIdentifier("lens-changes-activity-list")
    }

    private func graphBinOperations(_ bin: GraphBin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(graphBinLabel(bin)).font(LensUI.paneTitle).padding(.horizontal, 12).padding(.top, 12)
            List(selection: Binding<String?>(get: {
                if case .activity(let id) = pendingSelection { return id }
                guard let change = selectedChange else { return nil }
                return bin.activities.first { $0.traceIDs.contains(change.id) }?.id
            }, set: { id in
                guard let activity = bin.activities.first(where: { $0.id == id }) else { return }
                selectActivity(activity, dismissGraphBin: true)
            })) {
                ForEach(bin.activities) { activity in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activityLabel(activity)).font(LensUI.metadata)
                        Text(activity.kinds.map(changeLabel).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(activity.id)
                }
            }.listStyle(.plain)
        }.frame(width: 340, height: min(420, CGFloat(bin.activities.count) * 62 + 55))
            .accessibilityIdentifier("lens-changes-graph-operations")
    }

    private func graphBinLabel(_ bin: GraphBin) -> String {
        if bin.activities.count == 1, let activity = bin.activities.first { return activityLabel(activity) }
        return LensL10n.text("{0} opérations regroupées", formattedNumber(bin.activities.count))
    }

    @ViewBuilder private func detailPane(_ scope: Scope) -> some View {
        if detailMode == .currentGit, let group = scope.selectedEnvironment {
            VStack(alignment: .leading, spacing: 8) {
                Text(environmentName(group)).font(LensUI.paneTitle)
                Text(group.environment.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                CurrentDiffView(environment: group.environment).id(group.id).frame(maxHeight: .infinity)
            }.padding(12)
        } else if let file = scope.selectedFile {
            VStack(alignment: .leading, spacing: 0) {
                Text(file.relativePath).font(LensUI.paneTitle.monospaced()).lineLimit(2).truncationMode(.middle).help(file.path)
                    .padding(.horizontal, 12).padding(.top, 10)
                activitySelectors(file, scope: scope).padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                if let change = scope.selectedChange,
                   ChangesOverviewFileKey(environmentID: change.environmentID, path: change.path) == file.key {
                    if !file.traceIDs.contains(change.id) { filteredSelectionNotice }
                    RecordedChangeView(change: change).id(change.id).frame(maxHeight: .infinity)
                } else {
                    LensCollectionEmptyState(title: LensL10n.text("Choisir une opération"),
                        detail: LensL10n.text("Sélectionnez une opération pour lire ses traces et son diff enregistré."), symbol: "clock")
                }
            }
        } else if let change = scope.selectedChange {
            VStack(alignment: .leading, spacing: 0) {
                if !scope.visibleTraceIDs.contains(change.id) {
                    filteredSelectionNotice
                }
                RecordedChangeView(change: change).id(change.id).frame(maxHeight: .infinity)
            }
        } else {
            LensCollectionEmptyState(title: LensL10n.text(mode == .files ? "Choisir un fichier" : "Choisir une opération"),
                detail: LensL10n.text("Les fichiers restent associés à leur environnement. Sélectionnez une trace pour lire son diff enregistré."), symbol: "doc.text")
        }
    }

    private var filteredSelectionNotice: some View {
        Label(LensL10n.text("Cette modification ne correspond pas aux filtres de la liste."), systemImage: LensSymbols.name("line.3.horizontal.decrease"))
            .font(LensUI.metadata).foregroundStyle(.secondary).padding(12)
            .accessibilityIdentifier("lens-changes-selected-trace-filtered")
    }

    private func activitySelectors(_ file: ChangesOverviewFile, scope: Scope) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(LensL10n.text("Opération enregistrée"), selection: Binding<String?>(get: {
                if case .activity(let id) = pendingSelection, file.activities.contains(where: { $0.id == id }) { return id }
                return scope.selectedActivity?.id
            }, set: { id in
                if let activity = file.activities.first(where: { $0.id == id }) { selectActivity(activity) }
            })) {
                if scope.selectedActivity == nil { Text(LensL10n.text("Choisir une opération")).tag(String?.none) }
                ForEach(file.activities) { activity in Text(activityLabel(activity)).tag(Optional(activity.id)) }
            }.labelsHidden().accessibilityIdentifier("lens-change-operation-picker")
            if let activity = scope.selectedActivity {
                let traces = activity.traceIDs.compactMap { store.change($0) }
                if traces.count > 1 {
                    Picker(LensL10n.text("Trace de l’opération"), selection: Binding<String>(get: {
                        if case .trace(let id) = pendingSelection { return id }
                        return selectedChange?.id ?? ""
                    }, set: { id in
                        selectTrace(id)
                    })) {
                        ForEach(traces) { trace in Text(changeLabel(trace.kind)).tag(trace.id) }
                    }.labelsHidden().accessibilityIdentifier("lens-change-trace-picker")
                } else if let trace = traces.first {
                    Text(changeLabel(trace.kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.controlSize(.small)
    }

    private func paneHeading(_ title: String) -> some View {
        Text(LensL10n.text(title)).font(LensUI.paneTitle).frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
    private func fileOperationCount(files: Int, operations: Int) -> String {
        LensL10n.text("{0} · {1}", LensUI.count(files, singular: "fichier", plural: "fichiers"),
            LensUI.count(operations, singular: "opération", plural: "opérations"))
    }
    private func formattedNumber(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: LensL10n.resolvedLanguage == .fr ? "fr" : "en")))
    }
    private func environmentName(_ group: ChangesOverviewEnvironment) -> String {
        if group.id.isEmpty { return LensL10n.text("Environnement non précisé") }
        return URL(fileURLWithPath: group.environment.path).lastPathComponent.nonempty ?? group.environment.path
    }
    private func activityLabel(_ activity: ChangesOverviewActivity) -> String {
        let date = activity.firstTimestamp.map { $0.lensFormatted(date: .abbreviated, time: .standard) } ?? LensL10n.text("Date inconnue")
        let agents = activity.agentIDs.map { store.agentName($0) }.joined(separator: ", ")
        return agents.isEmpty ? date : LensL10n.text("{0} · {1}", date, agents)
    }
    private func graphPosition(_ timestamp: Date, first: Date, last: Date, width: CGFloat) -> CGFloat {
        let interval = last.timeIntervalSince(first)
        let fraction = interval > 0 ? timestamp.timeIntervalSince(first) / interval : 0.5
        return 12 + CGFloat(min(1, max(0, fraction))) * max(0, width - 24)
    }
    private func preferredTrace(_ activity: ChangesOverviewActivity) -> String? {
        if let selectedChange, activity.traceIDs.contains(selectedChange.id) { return selectedChange.id }
        // The requested patch is a directly inspectable recorded diff; the result
        // remains separately available through the trace selector.
        return activity.traceIDs.first { store.change($0)?.kind == .requestedPatch }
            ?? activity.traceIDs.first { store.change($0) != nil }
    }
    private func selectEnvironment(_ value: EnvironmentSelection) {
        guard pendingSelection != .environment(value) else { return }
        switch value {
        case .all: environmentID = nil
        case .environment(let id): environmentID = id
        }
        deferSelection(.environment(value), targetEnvironmentID: environmentID) {
            if let environmentID, let fileID,
               store.presentation?.changesOverview.files.contains(where: { $0.id == fileID && $0.environmentID == environmentID }) != true {
                self.fileID = nil
            }
            detailMode = .recorded
        }
    }
    private func selectFile(_ file: ChangesOverviewFile) {
        guard pendingSelection != .file(file.id) else { return }
        let retainsChange = selectedChange.map { file.traceIDs.contains($0.id) } ?? false
        let traceID = retainsChange ? nil : file.activities.first.flatMap(preferredTrace)
        // Write the native list's own binding immediately. Mutations affecting
        // readers and other tables run after NSTableView's delegate returns.
        fileID = file.id
        deferSelection(.file(file.id), targetFile: file.key, targetChange: traceID.flatMap { store.change($0) }) {
            if let traceID { store.navigate(.change(traceID)) }
            detailMode = .recorded
        }
    }
    private func selectActivity(_ activity: ChangesOverviewActivity, dismissGraphBin: Bool = false) {
        guard pendingSelection != .activity(activity.id), let traceID = preferredTrace(activity), let change = store.change(traceID) else { return }
        deferSelection(.activity(activity.id), targetFile: ChangesOverviewFileKey(environmentID: change.environmentID, path: change.path), targetChange: change) {
            store.navigate(.change(traceID)); detailMode = .recorded
            synchronizeSelectedChange()
            if dismissGraphBin { selectedGraphBin = nil }
        }
    }
    private func selectTrace(_ id: String) {
        guard pendingSelection != .trace(id), let change = store.change(id) else { return }
        deferSelection(.trace(id), targetFile: ChangesOverviewFileKey(environmentID: change.environmentID, path: change.path), targetChange: change) {
            store.navigate(.change(id)); detailMode = .recorded
        }
    }

    private var selectionFilterIdentity: [String?] {
        [store.query, store.agentFilter, store.environmentFilter, store.resourceFilter,
         store.kindFilter?.rawValue, store.changesKindFilter?.rawValue, store.originInstructionFilter]
    }
    private func cancelDeferredSelection() {
        if selectionTask != nil { reportSelection("cancelled-on-disappear") }
        selectionTask?.cancel(); selectionTask = nil
        selectionGeneration = UUID(); pendingSelection = nil
    }
    private func deferSelection(_ pending: PendingSelection, targetEnvironmentID: String? = nil,
                                targetFile: ChangesOverviewFileKey? = nil, targetChange: ChangeRecord? = nil,
                                operation: @escaping @MainActor () -> Void) {
        selectionTask?.cancel()
        let generation = UUID(); selectionGeneration = generation; pendingSelection = pending
        let home = store.sourceHome.standardizedFileURL
        let observedHome = store.observedSourceHome.standardizedFileURL
        let rootID = store.snapshot?.root.id
        let storeIdentity = ObjectIdentifier(store), windowIdentity = windowContext.map(ObjectIdentifier.init)
        let expectedSelection = store.selection
        // A Binding read within a native table/publisher update may still be
        // the rendered value. Validate the explicit requested binding value.
        let expectedEnvironmentID: String?
        if case .environment(let value) = pending {
            switch value {
            case .all: expectedEnvironmentID = nil
            case .environment(let id): expectedEnvironmentID = id
            }
        } else { expectedEnvironmentID = environmentID }
        let expectedFileID: String?
        if case .file(let id) = pending { expectedFileID = id }
        else { expectedFileID = fileID }
        let expectedSection = store.section, expectedPresentation = store.changesPresentation
        let expectedMode = mode, expectedDetailMode = detailMode
        let filters = selectionFilterIdentity, period = store.period
        reportSelection("queued")
        selectionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { reportSelection("task-cancelled"); return }
            guard selectionGeneration == generation else { reportSelection("generation-replaced"); return }
            defer {
                if selectionGeneration == generation { pendingSelection = nil; selectionTask = nil }
            }
            // Live publication may replace the projection during the yield.
            // Keep the context guards and validate the target in that fresh
            // projection instead of requiring an unchanged presentation UUID.
            let checks: [String: Bool] = [
                "store": ObjectIdentifier(store) == storeIdentity,
                "window": windowContext.map(ObjectIdentifier.init) == windowIdentity,
                "source": store.sourceHome.standardizedFileURL == home,
                "observedSource": store.observedSourceHome.standardizedFileURL == observedHome,
                "root": store.snapshot?.root.id == rootID,
                "selection": store.selection == expectedSelection,
                "environment": environmentID == expectedEnvironmentID,
                "file": fileID == expectedFileID,
                "section": store.section == expectedSection,
                "presentationMode": store.changesPresentation == expectedPresentation,
                "overviewMode": mode == expectedMode, "detailMode": detailMode == expectedDetailMode,
                "filters": selectionFilterIdentity == filters, "period": store.period == period
            ]
            guard checks.values.allSatisfy({ $0 }), let current = store.presentation?.changesOverview else {
                reportSelection("context-rejected", checks: checks); return
            }
            if let targetEnvironmentID, !current.groups.contains(where: { $0.id == targetEnvironmentID }) {
                reportSelection("environment-target-missing"); return
            }
            if let targetFile, !current.files.contains(where: { $0.key == targetFile }) {
                reportSelection("file-target-missing"); return
            }
            if let targetChange {
                guard store.change(targetChange.id) == targetChange, current.traceIDs.contains(targetChange.id) else {
                    reportSelection("trace-target-missing"); return
                }
            }
            if case .activity(let id) = pending {
                guard current.groups.contains(where: { $0.activities.contains(where: { $0.id == id }) }) else {
                    reportSelection("activity-target-missing"); return
                }
            }
            reportSelection("accepted")
            operation()
        }
    }
    private func reportSelection(_ phase: String, checks: [String: Bool] = [:]) {
        guard let selectionDiagnostic else { return }
        var values = checks.mapValues { $0 ? "pass" : "fail" }
        values["phase"] = phase
        selectionDiagnostic(values)
    }
    private func synchronizeSelectedChange() {
        guard let change = selectedChange,
              let file = projection.files.first(where: { $0.traceIDs.contains(change.id) }) else { return }
        if environmentID != nil, environmentID != file.environmentID { environmentID = file.environmentID }
        fileID = file.id
    }
}
