import SwiftUI
import AppKit
import PDFKit
import LensCore

/// Native List selection and mouse actions use the same evidence identity.
/// Deselection while rows stream/filter does not erase the current evidence.
private extension LensStore {
    func objectListSelection(in section: LensSection) -> Binding<String?> {
        Binding(get: {
            switch (section, self.selection) {
            case (.agents, .agent(let id)), (.environments, .environment(let id)),
                 (.resources, .resource(let id)), (.changes, .change(let id)): return id
            default: return nil
            }
        }, set: { id in
            guard let id else { return }
            let destination: Destination
            switch section {
            case .agents: destination = .agent(id)
            case .environments: destination = .environment(id)
            case .resources: destination = .resource(id)
            case .changes: destination = .change(id)
            default: return
            }
            if self.selection != destination { self.navigate(destination) }
        })
    }
}

struct AgentsView: View {
    @Environment(\.lensAccent) private var accent
    @EnvironmentObject var store: LensStore
    @State private var searchFocused = false
    @FocusState private var listFocused: Bool
    private var tree: [(AgentRecord, Int)] { store.presentation?.agentRows ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LensNativeSearchField(placeholder: LensL10n.text("Rechercher identité, mission ou traces…"), text: $store.agentQuery,
                        accessibilityLabel: LensL10n.text("Recherche indépendante dans les agents de la session"), focused: $searchFocused)
                        .frame(height: 28)
                        .help(LensL10n.text("Identité, mission, environnements et traces enregistrées de chaque agent.") + "\n" + LensL10n.text("Relations issues des métadonnées et délégations. Un dépôt commun ne suffit pas à relier deux sessions."))
                    if store.agentSearchPending { LensProgressIndicator().controlSize(.mini).accessibilityLabel(LensL10n.text("Recherche dans les traces des agents")) }
                }
                if let issue = store.agentSearchIssue {
                    HStack(alignment: .top, spacing: 8) {
                        Label(LensL10n.text("Recherche dans les traces incomplète : ") + issue, systemImage: LensSymbols.name("exclamationmark.triangle")).foregroundStyle(.secondary).lineLimit(2).help(issue)
                        Button(LensL10n.text("Réessayer")) { store.searchAgents() }.buttonStyle(LensQuietButtonStyle())
                    }.font(.caption)
                } else if !store.agentQuery.isEmpty {
                    Text(store.agentSearchPending ? LensL10n.text("Recherche dans les traces enregistrées…") : LensL10n.text("Identité, mission, chemins et traces associés · {0} agents correspondants", String(describing: tree.count))).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
            List(tree, id: \.0.id, selection: store.objectListSelection(in: .agents)) { agent, depth in
                HStack(alignment: .top, spacing: 6) {
                    Button { store.navigate(.agent(agent.id)); listFocused = true } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: LensSymbols.agent(agent.relation)).font(.system(size: 13, weight: .medium)).foregroundStyle(agent.accessible ? accent.color : LensAppearance.warningText).frame(width: 20, height: 18).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(agent.name.nonempty ?? String(agent.id.prefix(8))).font(LensUI.body.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(agent.name.nonempty ?? agent.id)
                                    Spacer(minLength: 6)
                                    LensSelectionMark(selected: store.selection == .agent(agent.id))
                                }
                                HStack(spacing: 8) {
                                    Text(relationLabel(agent.relation)).lineLimit(1)
                                    AgentRoleCaption(agent: agent)
                                    Spacer(minLength: 6)
                                    Text(LensUI.count(store.presentation?.eventCountByAgent[agent.id] ?? 0, singular: "événement", plural: "événements")).monospacedDigit().lineLimit(1)
                                }.font(LensUI.metadata).foregroundStyle(.secondary)
                                Text(agent.mission.nonempty ?? LensL10n.text("Mission non enregistrée")).font(LensUI.readingFont(store.fontSize)).lineLimit(3).foregroundStyle(.secondary)
                                Text(agent.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(agent.id)
                                if !agent.accessible { Label(LensL10n.text("Historique inaccessible"), systemImage: LensSymbols.name("doc.questionmark")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { store.navigate(.agent(agent.id), newTab: true) })
                        .help(LensL10n.text("Double-clic ou Retour pour ouvrir l’agent sélectionné."))
                        .accessibilityAddTraits(store.selection == .agent(agent.id) ? .isSelected : [])
                        Button { store.showAgentMetadata(agent.id) } label: {
                            Image(systemName: LensSymbols.name("info.circle")).frame(width: 24, height: 24)
                        }.buttonStyle(.borderless).padding(.top, 7)
                            .help(LensL10n.text("Informations sur l’agent"))
                            .accessibilityLabel(LensL10n.text("Informations sur l’agent {0}", agent.name.nonempty ?? agent.id))
                            .accessibilityIdentifier("lens-agent-information")
                }.padding(.leading, CGFloat(depth) * 20).tag(agent.id)
                    .listRowBackground(store.selection == .agent(agent.id) ? accent.selectionColor : .clear)
                    .contextMenu {
                        Button(LensL10n.text("Informations sur l’agent")) { store.showAgentMetadata(agent.id) }
                        LensActionButton(store: store, action: .investigate, target: .agent(agent.id))
                        Button(LensL10n.text("Ouvrir dans un onglet")) { store.navigate(.agent(agent.id), newTab: true) }
                        Button(LensL10n.text("Filtrer son activité")) { store.showActivity(for: .agent(agent.id)) }
                    }
            }.listStyle(.plain)
                .focusable()
                .focused($listFocused)
                .onChange(of: store.selection) { _, selection in
                    if case .agent = selection, !searchFocused { listFocused = true }
                }
                .onKeyPress(.return) {
                    guard case .agent(let id) = store.selection else { return .ignored }
                    store.navigate(.agent(id), newTab: true); return .handled
                }
                .overlay {
                    if tree.isEmpty {
                        if store.agentSearchPending || store.isProjecting {
                            LensCollectionEmptyState(title: LensL10n.text("Recherche dans les agents…"), detail: LensL10n.text("Les résultats apparaîtront ici. La sélection reste conservée."), symbol: "magnifyingglass")
                        } else {
                            let hasAgents = !(store.snapshot?.agents.isEmpty ?? true)
                            LensCollectionEmptyState(title: LensL10n.text(hasAgents ? "Aucun agent correspondant" : "Aucun agent enregistré"),
                                detail: LensL10n.text(hasAgents ? "Essayez une autre identité, mission ou trace." : "Les données disponibles ne contiennent aucun agent associé. Consultez la couverture des traces."), symbol: "person.3",
                                onClear: hasAgents && !store.agentQuery.isEmpty ? { store.agentQuery = "" } : nil)
                        }
                    }
                }
        }.onReceive(NotificationCenter.default.publisher(for: .lensFocusAgentSearch)) { note in
            if (note.object as? LensStore) === store { searchFocused = true }
        }
    }
}

struct EnvironmentsView: View {
    @EnvironmentObject var store: LensStore
    @State private var showProjectSearch = false
    @State private var treeVisible = true
    @State private var showCompactTree = false
    private var selectedEnvironment: EnvironmentRecord? {
        guard let snap = store.snapshot else { return nil }
        switch store.selection {
        case .environment(let id): return snap.environments.first { $0.id == id }
        case .file(let env, _, _, _): return snap.environments.first { $0.id == env } ?? EnvironmentRecord(path: env)
        default: return nil
        }
    }
    private var filePath: String? { if case .file(_, let path, _, _) = store.selection { return path }; return nil }
    private var fileLine: Int? { if case .file(_, _, let line, _) = store.selection { return line }; return nil }
    private var fileVersion: String? { if case .file(_, _, _, let version) = store.selection { return version }; return nil }
    private var environments: [EnvironmentRecord] {
        (store.snapshot?.environments ?? []).filter { store.matches($0.path + ($0.recordedBranch ?? ""), eventIDs: $0.eventIDs) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let env = selectedEnvironment {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        EnvironmentHeader(environment: env)
                        HStack {
                            Button {
                                if geometry.size.width < 600 { showCompactTree = true } else { treeVisible.toggle() }
                            } label: { Label(LensL10n.text("Arborescence"), systemImage: LensSymbols.name("sidebar.left")) }
                                .help(geometry.size.width < 600 ? LensL10n.text("Explorer les fichiers de ce worktree") : treeVisible ? LensL10n.text("Masquer l’arborescence") : LensL10n.text("Afficher l’arborescence"))
                                .accessibilityValue(geometry.size.width < 600 ? LensL10n.text("Dans un panneau temporaire") : treeVisible ? LensL10n.text("Visible") : LensL10n.text("Masquée"))
                                .popover(isPresented: $showCompactTree, arrowEdge: .leading) { FileTreeView(environment: env).frame(width: 300, height: 420) }
                            Button { showProjectSearch = true } label: { Label(LensL10n.text("Rechercher"), systemImage: LensSymbols.name("magnifyingglass")) }.help(LensL10n.text("Rechercher dans les fichiers de ce worktree"))
                            Spacer()
                        }.buttonStyle(LensQuietButtonStyle()).controlSize(.small).padding(.horizontal, 14).padding(.bottom, 10)
                        // Keep the document in the same structural slot when the secondary
                        // tree is hidden: resizing must not recapture the current file.
                        HSplitView {
                            if treeVisible && geometry.size.width >= 600 { FileTreeView(environment: env).frame(minWidth: 180, idealWidth: 245, maxWidth: 450) }
                            fileBrowserContent(environment: env).frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .onChange(of: filePath) { _, _ in showCompactTree = false }
                .sheet(isPresented: $showProjectSearch) { EnvironmentSearchView(environment: env, fontSize: store.fontSize, codeFont: store.codeFont, onOpenHit: { hit in showProjectSearch = false; store.navigate(.file(environment: hit.environmentID, path: hit.path, line: hit.line, version: hit.version), newTab: true) }, onClose: { showProjectSearch = false }) }
            } else {
                List(environments, selection: store.objectListSelection(in: .environments)) { env in
                    Button { store.navigate(.environment(env.id)) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(URL(fileURLWithPath: env.path).lastPathComponent.nonempty ?? env.path, systemImage: LensSymbols.name("folder")).font(LensUI.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            Text(env.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(env.path)
                            HStack(spacing: 8) {
                                Text(env.recordedBranch.map { LensL10n.text("Branche enregistrée : ") + $0 } ?? LensL10n.text("Branche historique inconnue")).lineLimit(1).truncationMode(.middle).help(env.recordedBranch ?? LensL10n.text("Branche historique inconnue"))
                                Spacer(minLength: 6)
                                Text(LensL10n.text("{0} agents · {1} actions", String(describing: env.agentIDs.count), String(describing: env.eventIDs.count))).monospacedDigit().lineLimit(1)
                            }.font(LensUI.metadata).foregroundStyle(.secondary)
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain).tag(env.id)
                }.listStyle(.plain)
                    .help(LensL10n.text("Répertoires utilisés par les agents. Les chemins supprimés restent dans l’historique."))
                    .overlay {
                        if environments.isEmpty {
                            let hasEnvironments = !(store.snapshot?.environments.isEmpty ?? true)
                            LensCollectionEmptyState(title: LensL10n.text(hasEnvironments ? "Aucun environnement correspondant" : "Aucun environnement enregistré"),
                                detail: LensL10n.text(hasEnvironments ? "Essayez un autre chemin ou nom de branche." : "Les traces disponibles ne donnent aucun répertoire. Aucun environnement n’est déduit."), symbol: "folder",
                                onClear: hasEnvironments && !store.query.isEmpty ? { store.query = "" } : nil)
                        }
                    }
            }
        }
    }
    @ViewBuilder private func fileBrowserContent(environment env: EnvironmentRecord) -> some View {
        if let path = filePath {
            FilePreviewView(path: path, environmentID: env.id, requestedLine: fileLine, expectedVersion: fileVersion).id(env.id + path + (fileVersion ?? ""))
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text(LensL10n.text("Choisir un fichier pour lire son contenu actuel et retrouver les actions enregistrées.")).font(LensUI.metadata).foregroundStyle(.secondary)
                CurrentDiffView(environment: env).id(env.id).frame(maxHeight: .infinity)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
struct EnvironmentHeader: View {
    @EnvironmentObject var store: LensStore
    let environment: EnvironmentRecord
    @State private var inspection: EnvironmentInspection?
    @State private var issue: String?
    @State private var identityExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(URL(fileURLWithPath: environment.path).lastPathComponent.nonempty ?? environment.path, systemImage: LensSymbols.name("folder")).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(environment.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).help(environment.path)
                        .contextMenu { NativeFilePathActions(path: environment.path, isDirectory: true, onIssue: { issue = $0 }) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { store.selection = nil } label: { Image(systemName: LensSymbols.name("square.grid.2x2")) }.buttonStyle(LensQuietButtonStyle()).help(LensL10n.text("Tous les environnements")).accessibilityLabel(LensL10n.text("Afficher tous les environnements"))
            }
            if let i = inspection {
                HStack(spacing: 12) {
                    Text(i.exists ? LensL10n.text("Répertoire actuel présent") : LensL10n.text("Répertoire actuel introuvable")).foregroundStyle(i.exists ? Color.secondary : LensAppearance.warningText)
                    if let branch = i.branch { Text(LensL10n.text("Branche actuelle : ") + branch).textSelection(.enabled) }
                    if let sha = i.head { Text(String(sha.prefix(12))).monospaced().textSelection(.enabled) }
                }.font(LensUI.metadata).fixedSize(horizontal: false, vertical: true)
                if let worktree = i.worktreePath, worktree != environment.path {
                    Text(LensL10n.text("Worktree : {0}", worktree)).font(LensUI.metadata.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                DisclosureGroup(LensL10n.text("Identité Git"), isExpanded: $identityExpanded) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let repo = i.repositoryPath { Text(LensL10n.text("Dépôt : {0}", repo)).textSelection(.enabled) }
                        Text(LensL10n.text("Environnement enregistré : {0}", environment.id)).textSelection(.enabled)
                        Text(LensL10n.text("Constat actuel distinct des métadonnées historiques enregistrées.")).foregroundStyle(.secondary)
                    }.font(LensUI.metadata.monospaced()).fixedSize(horizontal: false, vertical: true)
                }.font(LensUI.metadata).controlSize(.small)
            }
            if let issue { Text(LensL10n.display(issue)).font(.caption).foregroundStyle(LensAppearance.warningText).textSelection(.enabled) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
            .task(id: environment.id) {
                inspection = nil; issue = nil
                do { inspection = try await store.files.inspect(environment: environment) } catch { issue = error.localizedDescription }
            }
    }
}
struct FileTreeView: View {
    @EnvironmentObject var store: LensStore
    let environment: EnvironmentRecord
    @State private var rootPath = ""
    @State private var entries: [FileEntry] = []
    @State private var issue: String?
    @State private var loading = false
    @State private var loadedIdentity: FileTreeReadIdentity?
    @State private var readGeneration = UUID()
    @State private var refreshTask: Task<Void, Never>?
    private var readIdentity: FileTreeReadIdentity { FileTreeReadIdentity(rootID: store.snapshot?.root.id, environmentID: environment.id, path: environment.path) }
    private var initialLoading: Bool { (loading || loadedIdentity != readIdentity) && (entries.isEmpty || loadedIdentity != readIdentity) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(LensL10n.text("Arborescence actuelle")).font(LensUI.metadata.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { refreshTask?.cancel(); refreshTask = Task { await load() } } label: { Image(systemName: LensSymbols.name("arrow.clockwise")) }.buttonStyle(LensQuietButtonStyle()).help(LensL10n.text("Actualiser l’arborescence actuelle de ce worktree")).accessibilityLabel(LensL10n.text("Actualiser l’arborescence actuelle")).disabled(loading) }.padding(10)
            if loading && !initialLoading { LensProgressIndicator(LensL10n.text("Actualisation…")).controlSize(.small).frame(maxWidth: .infinity).padding(10) }
            if let issue, loadedIdentity == readIdentity { Text(LensL10n.display(issue)).font(.caption).foregroundStyle(LensAppearance.warningText).padding(10) }
            if issue != nil, !entries.isEmpty, loadedIdentity == readIdentity { Text(LensL10n.text("L’arborescence précédemment chargée reste disponible.")).font(LensUI.metadata).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(loadedIdentity == readIdentity ? entries : []) { entry in FileTreeRow(entry: entry, environmentID: environment.id, worktreeRoot: rootPath, depth: 0) }
                }.padding(6)
            }
            .overlay {
                if initialLoading {
                    LensLoadingState(title: LensL10n.text("Lecture de l’arborescence…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.task(id: readIdentity) { await load() }
            .onDisappear { refreshTask?.cancel(); refreshTask = nil; readGeneration = UUID(); loading = false }
    }
    private func load() async {
        let identity = readIdentity, generation = UUID()
        readGeneration = generation
        if loadedIdentity != identity { entries = []; rootPath = ""; loadedIdentity = identity }
        loading = true; issue = nil
        do {
            let i = try await store.files.inspect(environment: environment)
            guard accepts(identity, generation: generation) else { return }
            let path = i.worktreePath ?? environment.path
            let updated = try await store.files.children(path: path)
            guard accepts(identity, generation: generation) else { return }
            rootPath = path; entries = updated
        } catch {
            guard accepts(identity, generation: generation) else { return }
            issue = error.localizedDescription
        }
        if accepts(identity, generation: generation) { loading = false }
    }
    private func accepts(_ identity: FileTreeReadIdentity, generation: UUID) -> Bool {
        !Task.isCancelled && readGeneration == generation && loadedIdentity == identity && readIdentity == identity
    }
}
struct FileTreeReadIdentity: Hashable {
    let rootID: String?
    let environmentID: String
    let path: String
}
enum FileTreeSelection {
    static func matches(_ selection: Destination?, environmentID: String, path: String) -> Bool {
        guard case .file(let selectedEnvironment, let selectedPath, _, _) = selection else { return false }
        return selectedEnvironment == environmentID && selectedPath == path
    }
}
struct FileTreeRow: View {
    @Environment(\.lensAccent) private var accent
    @EnvironmentObject var store: LensStore
    let entry: FileEntry
    let environmentID: String
    var worktreeRoot: String? = nil
    let depth: Int
    @State private var expanded = false
    @State private var children: [FileEntry] = []
    @State private var issue: String?
    private var isSelected: Bool { FileTreeSelection.matches(store.selection, environmentID: environmentID, path: entry.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if entry.isDirectory {
                    expanded.toggle()
                    if expanded, children.isEmpty { Task { do { children = try await store.files.children(path: entry.id) } catch { issue = error.localizedDescription } } }
                } else { store.navigate(.file(environment: environmentID, path: entry.id)) }
            } label: {
                HStack(spacing: 5) {
                    Group {
                        if entry.isDirectory { Image(systemName: LensSymbols.name(expanded ? "chevron.down" : "chevron.right")).imageScale(.small) }
                        else { Color.clear }
                    }.frame(width: 10).accessibilityHidden(true)
                    Image(systemName: LensSymbols.name(entry.isSymbolicLink ? "link" : LensUI.fileSymbol(entry.id, isDirectory: entry.isDirectory))).foregroundStyle(entry.isDirectory ? accent.color : .secondary).accessibilityHidden(true)
                    Text(entry.name).font(LensUI.body.weight(isSelected ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    LensSelectionMark(selected: isSelected)
                    if entry.isRestricted { Image(systemName: LensSymbols.name("lock")).imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true) }
                }.padding(.leading, CGFloat(depth) * 13).padding(.vertical, 4).padding(.horizontal, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(entry.isRestricted)
                .accessibilityLabel(LensUI.fileItemKind(isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink) + LensL10n.text(" · ") + entry.name)
                .accessibilityValue(entry.isRestricted ? LensL10n.text("Accès non autorisé") : entry.isDirectory ? (expanded ? LensL10n.text("Développé") : LensL10n.text("Réduit")) : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(entry.id + (entry.isRestricted ? LensL10n.text(" · accès non autorisé") : ""))
                .background(isSelected ? accent.selectionColor : .clear)
                .contextMenu { NativeFilePathActions(path: entry.id, worktreeRoot: worktreeRoot, isDirectory: entry.isDirectory, restricted: entry.isRestricted, onIssue: { issue = $0 }) }
            if let issue { Text(LensL10n.display(issue)).font(.caption).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(.leading, CGFloat(depth + 1) * 13) }
            if expanded {
                ForEach(children) { child in AnyView(FileTreeRow(entry: child, environmentID: environmentID, worktreeRoot: worktreeRoot, depth: depth + 1)) }
            }
        }
    }
}

struct ResourcesView: View {
    @Environment(\.lensAccent) private var accent
    @EnvironmentObject var store: LensStore
    @State private var role: ResourceRole?
    @State private var showRecovery = false
    @State private var recovered: ResourceRecoveryCandidate?
    private var resources: [ResourceRecord] { (store.snapshot?.resources ?? []).filter { (role == nil || $0.roles.contains(role!)) && store.matches($0.name + $0.location + $0.evidence, eventIDs: $0.eventIDs) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var chosen: ResourceRecord? { if case .resource(let id) = store.selection { return store.snapshot?.resources.first { $0.id == id } }; return nil }
    var body: some View {
        let directories = knownDirectoryPaths
        let filteredResources = resources
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(LensUI.count(filteredResources.count, singular: "ressource", plural: "ressources")).font(LensUI.metadata).foregroundStyle(.secondary)
                    if let role { Text(role.label).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 8)
                    Menu { resourceRolePicker } label: { LensIconMenuLabel("line.3.horizontal.decrease") }
                        .lensIconMenu("Filtrer les ressources par rôle dans la session")
                        .accessibilityIdentifier("lens-resource-filters")
                }.padding(.horizontal, 14).padding(.vertical, 8)
                List(filteredResources, selection: store.objectListSelection(in: .resources)) { resource in
                    Button { store.navigate(.resource(resource.id)) } label: {
                        LensResourceRowLabel(resource: resource, isKnownDirectory: directories.contains(NativeFileLocation.localPath(resource.location) ?? ""), isSelected: store.selection == .resource(resource.id))
                            .padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).tag(resource.id).listRowBackground(store.selection == .resource(resource.id) ? accent.selectionColor : .clear)
                        .accessibilityAddTraits(store.selection == .resource(resource.id) ? .isSelected : [])
                        .contextMenu {
                            if let path = NativeFileLocation.localPath(resource.location) { NativeFilePathActions(path: path, isDirectory: directories.contains(path)) }
                            else { Button(LensL10n.text("Copier la référence enregistrée")) { store.copyLocalText(resource.location, notice: LensL10n.text("Référence de ressource copiée")) } }
                            if let event = store.snapshot?.events.first(where: { resource.eventIDs.contains($0.id) }) { Button(LensL10n.text("Voir le contexte associé")) { store.navigate(.event(event.id), newTab: true) } }
                        }
                }.listStyle(.plain)
                    .overlay {
                        if filteredResources.isEmpty {
                            let hasResources = !(store.snapshot?.resources.isEmpty ?? true)
                            LensCollectionEmptyState(title: LensL10n.text(hasResources ? "Aucune ressource correspondante" : "Aucune ressource enregistrée"),
                                detail: LensL10n.text(hasResources ? "Essayez un autre rôle ou une autre recherche." : "Aucune ressource n’a été retrouvée dans les données disponibles. Cela ne prouve pas qu’aucun fichier n’a été utilisé."), symbol: "paperclip",
                                onClear: hasResources && (role != nil || !store.query.isEmpty) ? { role = nil; store.query = "" } : nil)
                        }
                    }
            }.frame(minHeight: 200)
            if let r = chosen {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        Label(recovered == nil ? LensL10n.text("Ressource enregistrée") : LensL10n.text("Version locale retrouvée"), systemImage: "paperclip")
                            .font(LensUI.metadata.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 8)
                        Button(LensL10n.text("Retrouver un fichier…")) { showRecovery = true }
                            .help(LensL10n.text("Chercher dans les dossiers choisis ou sélectionner un fichier ; aucune version historique n’est déduite de son nom"))
                        if recovered != nil {
                            Menu { Button(LensL10n.text("Référence d’origine")) { recovered = nil } } label: { LensIconMenuLabel() }
                                .lensIconMenu("Actions de la ressource retrouvée")
                        }
                    }.buttonStyle(LensQuietButtonStyle()).controlSize(.small).padding(10)
                    Divider()
                    if let recovered, recovered.resourceID == r.id { RecoveredResourcePreview(candidate: recovered, original: r) }
                    else {
                if let path = NativeFileLocation.localPath(r.location) { FilePreviewView(path: path, environmentID: r.environmentID ?? "").id(r.id).frame(minHeight: 250) }
                else if r.location.hasPrefix("trace:") { EmbeddedPreviewView(resource: r).id(r.id).frame(minHeight: 230) }
                else { Text(LensL10n.text("Référence enregistrée : {0}\nLe contenu n’est pas disponible localement. Consultez les messages ou appels associés dans l’inspecteur, lorsqu’ils sont enregistrés.", String(describing: r.location))).font(LensUI.body).textSelection(.enabled).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading) }
                    }
                }.frame(minHeight: 340, maxHeight: .infinity)
                .sheet(isPresented: $showRecovery) {
                    ResourceRecoveryView(resource: r,
                        roots: ResourceRecoveryRoots.suggested(resource: r, snapshot: store.snapshot,
                            attachmentDirectories: [store.observedSourceHome.appendingPathComponent("attachments").path])) { candidate in
                        guard chosen?.id == candidate.resourceID else { return }; recovered = candidate
                    }
                }
            }
        }.onChange(of: chosen?.id) { _, _ in recovered = nil; showRecovery = false }
    }

    private var resourceRolePicker: some View {
        Picker(LensL10n.text("Rôle dans la session"), selection: $role) {
            Text(LensL10n.text("Tous les rôles")).tag(ResourceRole?.none)
            ForEach(ResourceRole.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }.pickerStyle(.inline).controlSize(.small).accessibilityLabel(LensL10n.text("Filtrer les ressources par rôle dans la session"))
    }

    private var knownDirectoryPaths: Set<String> {
        Set((store.snapshot?.environments ?? []).flatMap { environment in
            [environment.path, environment.repositoryPath].compactMap { $0 }.compactMap(NativeFileLocation.localPath)
        })
    }
}

/// The resource glyph describes its reference form or suggested file format.
/// Roles, availability and context remain separate recorded text.
struct LensResourceRowLabel: View {
    let resource: ResourceRecord
    var isKnownDirectory = false
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: LensSymbols.name(LensUI.resourceSymbol(resource, isKnownDirectory: isKnownDirectory)))
                .font(.system(size: 12, weight: .semibold)).frame(width: 20)
                .foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(LensUI.resourceTitle(resource)).font(LensUI.body.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(resource.name)
                    Spacer(minLength: 6)
                    LensSelectionMark(selected: isSelected)
                }
                Text(resource.location).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(resource.location)
                Text(resource.roles.map(\.label).joined(separator: " · ")).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(availabilityLabel(resource.availability))
                    Spacer(minLength: 6)
                    Text(LensUI.count(resource.eventIDs.count, singular: "lien vers le contexte", plural: "liens vers le contexte")).monospacedDigit()
                }.font(LensUI.metadata).foregroundStyle(resource.availability == .missing ? LensAppearance.warningText : .secondary)
            }
        }
    }
}

struct EmbeddedPreviewView: View {
    @EnvironmentObject var store: LensStore
    let resource: ResourceRecord
    @State private var image: EvidenceImagePreview?
    @State private var issue: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LensSectionHeader(title: LensL10n.text("Pièce jointe enregistrée dans l’événement d’origine"), symbol: "photo").padding(.horizontal, 14).padding(.top, 12)
            if let image { EvidenceImageView(preview: image, label: LensL10n.text("Pièce jointe enregistrée dans l’événement d’origine")) }
            else if loading { LensLoadingState(title: LensL10n.text("Lecture des octets enregistrés…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Text(LensL10n.display(issue ?? LensL10n.text("Octets indisponibles"))).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }.task(id: resource.id) {
            image = nil; issue = nil; loading = true
            do {
                guard let event = store.snapshot?.events.first(where: { resource.eventIDs.contains($0.id) }) else { throw LensError.unavailable(LensL10n.text("Événement d’origine indisponible")) }
                let detail = try await store.engine.detail(for: event)
                let worker = Task.detached(priority: .userInitiated) {
                    let bytes = try EmbeddedResource.decodeImage(resource: resource, detail: detail)
                    return try EvidenceImagePreview(data: bytes)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; image = result
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
            loading = false
        }
    }
}

struct FilePreviewView: View {
    @EnvironmentObject var store: LensStore
    let path: String
    let environmentID: String
    var requestedLine: Int? = nil
    var expectedVersion: String? = nil
    @State private var text = ""
    @State private var next: UInt64?
    @State private var total: UInt64 = 0
    @State private var version: String?
    @State private var issue: String?
    @State private var image: EvidenceImagePreview?
    @State private var pdf: PDFDocument?
    @State private var busy = false
    @State private var observedAt: Date?
    @State private var historical: HistoricalText?
    @State private var showingHistorical = false
    @State private var historyIssue: String?
    @State private var codeSelection = ""
    @State private var selectionLine = 1
    @State private var readGeneration: UInt64 = 0
    @State private var reloadTask: Task<Void, Never>?
    @State private var readContext: FilePreviewReadIdentity?
    private var readIdentity: FilePreviewReadIdentity {
        FilePreviewReadIdentity(rootID: store.snapshot?.root.id, environmentID: environmentID, path: path, expectedVersion: expectedVersion)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(path)
                        Text(previewStateLabel).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(2)
                            .help(recordedReadIdentifier ?? previewStateLabel)
                            .contextMenu {
                                if let identifier = recordedReadIdentifier {
                                    Button(showingHistorical ? LensL10n.text("Copier l’identifiant du blob Git") : LensL10n.text("Copier l’identifiant de la lecture")) {
                                        store.copyLocalText(identifier, notice: showingHistorical ? LensL10n.text("Identifiant du blob Git copié") : LensL10n.text("Identifiant de la lecture enregistré copié"))
                                    }
                                }
                            }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { copyLoadedText() } label: { Image(systemName: LensSymbols.name("doc.on.doc")) }.buttonStyle(LensQuietButtonStyle()).help(loadedCopyLabel).accessibilityLabel(loadedCopyLabel).disabled(!hasCopyableText)
                    NativeFileActionsMenu(path: path, environmentID: environmentID, line: showingHistorical || codeSelection.isEmpty ? nil : selectionLine).labelStyle(.iconOnly).id(readGeneration)
                    Button { startRead(reset: true) } label: { Image(systemName: LensSymbols.name("arrow.clockwise")) }.buttonStyle(LensQuietButtonStyle()).help(LensL10n.text("Relire le fichier actuel")).accessibilityLabel(LensL10n.text("Relire le fichier actuel")).disabled(busy)
                }
                HStack {
                    if historical != nil { Button(showingHistorical ? LensL10n.text("Lecture locale") : LensL10n.text("Instantané Git")) { codeSelection = ""; showingHistorical.toggle() } }
                    if !codeSelection.isEmpty { Button { store.addCodeEvidence(text: codeSelection, path: path, environmentID: environmentID, version: showingHistorical ? (historical?.blobID ?? "inconnue") : (version ?? "inconnue"), line: selectionLine, historical: showingHistorical) } label: { Label(LensL10n.text("Sur la sélection…"), systemImage: LensSymbols.name("text.bubble")) }.labelStyle(.iconOnly).help(LensL10n.text("Demander à l’IA sur la sélection chargée")).accessibilityLabel(LensL10n.text("Demander à l’IA sur la sélection chargée")) }
                    Spacer()
                    if !environmentID.isEmpty { Button { store.navigate(.file(environment: environmentID, path: path), newTab: true) } label: { Image(systemName: LensSymbols.name("plus.square.on.square")) }.help(LensL10n.text("Ouvrir ce fichier dans un onglet")).accessibilityLabel(LensL10n.text("Ouvrir ce fichier dans un onglet")) }
                }
            }.controlSize(.small).padding(12).fixedSize(horizontal: false, vertical: true)
            Text(LensL10n.text("{0}\nEnvironnement enregistré : {1}", String(describing: path), String(describing: environmentID.nonempty ?? LensL10n.text("non identifié")))).font(.system(size: 11, design: .monospaced)).lineLimit(3).truncationMode(.middle).help(path + "\n" + environmentID).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            if showingHistorical, let h = historical {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LensL10n.text("Commit {0} · blob {1}", String(describing: h.reference), String(describing: h.blobID))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(LensL10n.text("Version commitée à la référence enregistrée. L’état non commité au moment de l’événement reste inconnu.")).font(LensUI.metadata).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
            } else if hasCopyableText || image != nil || pdf != nil {
                Text(LensL10n.text("Un aperçu disponible montre le contenu lu à la date affichée. Consultez les traces disponibles pour le contexte historique.")).font(LensUI.metadata).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let historyIssue { Text(LensL10n.text("Instantané Git indisponible : ") + historyIssue).font(LensUI.metadata).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5).textSelection(.enabled) }
            if let issue, !text.isEmpty || image != nil || pdf != nil {
                Label(LensL10n.text("Nouvelle lecture indisponible : ") + issue, systemImage: LensSymbols.name("exclamationmark.triangle")).font(.caption).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(10)
            }
            if showingHistorical, let h = historical { CodeDocumentView(text: h.text, path: path, versionLabel: previewStateLabel, fontSize: store.fontSize, codeFont: store.codeFont, onSelection: { range, selected in selectCode(range, selected, in: h.text) }, onInvestigateSelection: { range, selected in askCode(range, selected, content: h.text, version: h.blobID, historical: true) }, onCopyText: codeCopyCallback(historical: true, partial: false), loadedTextCopyLabel: LensL10n.text("Copier le texte de l’instantané Git")) }
            else if let issue, text.isEmpty && image == nil && pdf == nil {
                ScrollView { VStack(alignment: .leading, spacing: 10) {
                    Label(LensL10n.text("Contenu indisponible"), systemImage: LensSymbols.name("exclamationmark.triangle")).font(.headline).foregroundStyle(LensAppearance.warningText)
                    Text(LensL10n.display(issue)).textSelection(.enabled)
                    Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if expectedVersion != nil { Button(LensL10n.text("Ouvrir le contenu actuel sans la référence de recherche")) { store.navigate(.file(environment: environmentID, path: path, line: requestedLine), newTab: true) } }
                }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading) }
            } else if let image {
                EvidenceImageView(preview: image, label: LensL10n.text("Aperçu local actuel de ") + URL(fileURLWithPath: path).lastPathComponent)
            } else if let pdf { PDFPreview(document: pdf) }
            else { CodeDocumentView(text: text, path: path, versionLabel: previewStateLabel, fontSize: store.fontSize, codeFont: store.codeFont, scrollToLine: requestedLine, onSelection: { range, selected in selectCode(range, selected, in: text) }, onInvestigateSelection: { range, selected in askCode(range, selected, content: text, version: version ?? "inconnue", historical: false) }, onCopyText: codeCopyCallback(historical: false, partial: next != nil), loadedTextCopyLabel: loadedCopyLabel, onCopyFileLine: { line in if let location = NativeFileLocation(path: path, line: line).fileLine { store.copyLocalText(location, notice: LensL10n.text("Chemin et ligne de la lecture locale copiés")) } }) }
            HStack {
                if busy { LensProgressIndicator().controlSize(.mini) }
                if showingHistorical, let h = historical { Text(LensL10n.text("Instantané Git · {0} octets", String(describing: h.text.utf8.count))).font(.caption).foregroundStyle(.secondary) }
                else if image != nil || pdf != nil { Text(LensL10n.text("Aperçu local actuel")).font(.caption).foregroundStyle(.secondary) }
                else { Text(LensL10n.text("{0} / {1} octets chargés", String(describing: text.utf8.count), String(describing: total)) + (next == nil ? "" : LensL10n.text(" · partiel"))).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !showingHistorical, next != nil { Button(LensL10n.text("Charger la suite")) { startRead(reset: false) }.buttonStyle(LensQuietButtonStyle()).controlSize(.small).disabled(busy) }
            }.padding(8)
        }.task(id: readIdentity) {
            let identity = readIdentity, generation = beginRead(readIdentity)
            await load(reset: true, identity: identity, generation: generation)
            guard isCurrent(identity, generation: generation) else { return }
            await loadHistory(identity: identity, generation: generation)
        }.onDisappear { invalidateRead() }
    }
    private var previewStateLabel: String {
        if showingHistorical { return LensL10n.text("Instantané Git vérifié") }
        if let observedAt { return (issue == nil ? LensL10n.text("Lecture capturée · ") : LensL10n.text("Lecture conservée · ")) + observedAt.lensFormatted(date: .abbreviated, time: .standard) }
        return issue == nil ? LensL10n.text("Lecture du fichier actuel…") : LensL10n.text("Contenu actuel indisponible")
    }
    private var recordedReadIdentifier: String? { showingHistorical ? historical?.blobID : version }
    private var hasCopyableText: Bool { showingHistorical ? historical != nil : observedAt != nil && image == nil && pdf == nil }
    private var loadedCopyLabel: String { showingHistorical ? LensL10n.text("Copier le texte de l’instantané Git") : next == nil ? LensL10n.text("Copier le texte chargé") : LensL10n.text("Copier le texte chargé (partiel)") }
    private func codeCopyCallback(historical: Bool, partial: Bool) -> (String, CodeTextCopyScope) -> Void {
        let source = historical ? LensL10n.text("de l’instantané Git") : partial ? LensL10n.text("de la lecture locale partielle") : LensL10n.text("de la lecture locale")
        return { copied, scope in
            let subject: String
            switch scope { case .selection: subject = "Sélection"; case .loadedText: subject = partial ? LensL10n.text("Texte chargé (partiel)") : LensL10n.text("Texte chargé") }
            store.copyLocalText(copied, notice: subject + " " + source + (scope == .selection ? LensL10n.text(" copiée") : LensL10n.text(" copié")))
        }
    }
    private func copyLoadedText() {
        guard hasCopyableText else { return }
        codeCopyCallback(historical: showingHistorical, partial: !showingHistorical && next != nil)(showingHistorical ? historical!.text : text, .loadedText)
    }
    private func selectCode(_ range: NSRange, _ selected: String, in content: String) {
        codeSelection = selected
        selectionLine = NativeFileLocation.lineNumber(in: content, atUTF16Offset: range.location) ?? 1
    }
    private func askCode(_ range: NSRange, _ selected: String, content: String, version: String, historical: Bool) {
        guard !selected.isEmpty else { return }
        selectCode(range, selected, in: content)
        store.addCodeEvidence(text: selected, path: path, environmentID: environmentID, version: version, line: selectionLine, historical: historical)
    }
    private func beginRead(_ identity: FilePreviewReadIdentity) -> UInt64 {
        reloadTask?.cancel(); readGeneration &+= 1; busy = true; issue = nil
        if readContext != identity {
            readContext = identity; text = ""; next = nil; total = 0; version = nil; image = nil; pdf = nil
            historical = nil; historyIssue = nil; showingHistorical = false; codeSelection = ""; observedAt = nil
        }
        return readGeneration
    }
    private func invalidateRead() { reloadTask?.cancel(); readGeneration &+= 1; busy = false }
    private func isCurrent(_ identity: FilePreviewReadIdentity, generation: UInt64) -> Bool {
        !Task.isCancelled && generation == readGeneration && identity == readIdentity
    }
    private func startRead(reset: Bool) {
        guard !busy else { return }
        let identity = readIdentity, generation = beginRead(readIdentity)
        reloadTask = Task {
            await load(reset: reset, identity: identity, generation: generation)
            if reset, isCurrent(identity, generation: generation) { await loadHistory(identity: identity, generation: generation) }
        }
    }
    private func load(reset: Bool, identity: FilePreviewReadIdentity, generation: UInt64) async {
        let span = LensSignposts.begin("FilePreviewLoad"); defer { span.end(); if generation == readGeneration { busy = false } }
        do {
            let ext = URL(fileURLWithPath: identity.path).pathExtension.lowercased()
            if reset, ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "pdf"].contains(ext) {
                let url = try await store.files.previewURL(path: identity.path)
                guard isCurrent(identity, generation: generation) else { return }
                if ext == "pdf" {
                    let document = await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
                    guard isCurrent(identity, generation: generation) else { return }; guard let document else { throw LensError.unavailable("PDF illisible") }
                    pdf = document; image = nil
                } else {
                    let bitmap = try await EvidenceImagePreview.load(url: url)
                    guard isCurrent(identity, generation: generation) else { return }
                    image = bitmap; pdf = nil
                }
                text = ""; next = nil; total = 0; version = nil; observedAt = Date(); codeSelection = ""
            } else {
                let offset = reset ? 0 : next ?? 0, expected = reset ? identity.expectedVersion : version
                let page = try await store.files.readText(path: identity.path, offset: offset, expectedVersion: expected)
                guard isCurrent(identity, generation: generation) else { return }
                var loadedText = (reset ? "" : text) + page.text
                var loadedNext = page.nextOffset, loadedVersion = page.version, loadedAt = page.observedAt
                var loadedBytes = loadedText.utf8.count
                if reset, let requestedLine {
                    var loadedLines = loadedText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    while loadedLines < requestedLine, let offset = loadedNext, loadedBytes < 2 * 1024 * 1024 {
                        try Task.checkCancellation()
                        let more = try await store.files.readText(path: identity.path, offset: offset, expectedVersion: loadedVersion)
                        guard isCurrent(identity, generation: generation) else { return }
                        loadedLines += more.text.count(where: { $0 == "\n" })
                        loadedBytes += more.text.utf8.count
                        loadedText += more.text; loadedNext = more.nextOffset; loadedVersion = more.version; loadedAt = more.observedAt
                    }
                }
                guard isCurrent(identity, generation: generation) else { return }
                if reset, version != loadedVersion || text != loadedText { codeSelection = "" }
                text = loadedText; next = loadedNext; total = page.totalBytes; version = loadedVersion; observedAt = loadedAt; image = nil; pdf = nil
            }
        } catch { if isCurrent(identity, generation: generation) { issue = error.localizedDescription } }
    }
    private func loadHistory(identity: FilePreviewReadIdentity, generation: UInt64) async {
        guard isCurrent(identity, generation: generation), let env = store.snapshot?.environments.first(where: { $0.id == identity.environmentID }), let ref = env.recordedRef else { return }
        do {
            let inspection = try await store.files.inspect(environment: env)
            guard isCurrent(identity, generation: generation), let root = inspection.worktreePath, identity.path.hasPrefix(root + "/") else { return }
            let relative = String(identity.path.dropFirst(root.count + 1))
            let h = try await store.files.historicalText(environment: env, relativePath: relative, reference: ref)
            guard isCurrent(identity, generation: generation) else { return }; historical = h; historyIssue = nil
        } catch { if isCurrent(identity, generation: generation) { historyIssue = error.localizedDescription } }
    }
}
struct FilePreviewReadIdentity: Hashable {
    let rootID: String?
    let environmentID: String
    let path: String
    let expectedVersion: String?
}
struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = document; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

struct ChangesView: View {
    @Environment(\.lensAccent) private var accent
    @EnvironmentObject var store: LensStore
    @Environment(\.lensWindowContext) private var windowContext
    @State private var kind: ChangeKind?
    private var changes: [ChangeRecord] {
        (store.snapshot?.changes ?? []).filter { c in
            (kind == nil || c.kind == kind) && (store.agentFilter == nil || c.agentID == store.agentFilter) && (store.environmentFilter == nil || c.environmentID == store.environmentFilter) && store.matches(c.path + c.evidence, eventIDs: [c.eventID]) && (store.period == nil || store.event(c.eventID).map { $0.overlaps(store.period!) } == true)
        }
    }
    var body: some View {
        let filtered = changes
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(LensUI.count(filtered.count, singular: "modification", plural: "modifications")).font(LensUI.metadata).foregroundStyle(.secondary)
                if let kind { Text(changeLabel(kind)).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Menu {
                    Picker(LensL10n.text("Nature de la trace"), selection: $kind) {
                        Text(LensL10n.text("Toutes les traces")).tag(ChangeKind?.none)
                        Text(LensL10n.text("Patch demandé")).tag(Optional(ChangeKind.requestedPatch))
                        Text(LensL10n.text("Résultat enregistré")).tag(Optional(ChangeKind.recordedResult))
                        Text(LensL10n.text("Changement observé")).tag(Optional(ChangeKind.observedChange))
                    }.pickerStyle(.inline)
                } label: { LensIconMenuLabel("line.3.horizontal.decrease") }
                    .lensIconMenu("Filtrer les modifications par type")
                    .accessibilityIdentifier("lens-change-filters")
            }.padding(.horizontal, 14).padding(.vertical, 8)
                .help(LensL10n.text("Patchs demandés, résultats des appels et changements observés. Consultez le diff Git actuel dans chaque environnement."))
            if store.period != nil, store.isProjecting {
                HStack { LensProgressIndicator().controlSize(.small); Text(LensL10n.text("Préparation des correspondances avec la période sélectionnée…")).font(LensUI.metadata).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 14).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
            if case .change(let id) = store.selection, let change = store.snapshot?.changes.first(where: { $0.id == id }) {
                if !filtered.contains(where: { $0.id == id }) {
                    Label(LensL10n.text("Cette modification ne correspond pas aux filtres de la liste."), systemImage: LensSymbols.name("line.3.horizontal.decrease"))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                }
                VSplitView {
                    changeList(filtered).frame(minHeight: 80, idealHeight: 160, maxHeight: .infinity)
                        .background(LensPaneSizing(key: "changes-list", preferredWidth: 170, context: windowContext, isVertical: false))
                    RecordedChangeView(change: change).id(change.id).frame(minHeight: 320, idealHeight: 420, maxHeight: .infinity)
                }
            } else { changeList(filtered).frame(maxHeight: .infinity) }
        }
    }
    private func changeList(_ records: [ChangeRecord]) -> some View {
        ScrollViewReader { proxy in
        List(records, selection: store.objectListSelection(in: .changes)) { change in
            Button { store.navigate(.change(change.id)) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(URL(fileURLWithPath: change.path).lastPathComponent.nonempty ?? change.path).font(LensUI.body.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(change.path)
                        Spacer(minLength: 6)
                        LensSelectionMark(selected: store.selection == .change(change.id))
                        Text(changeLabel(change.kind)).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(change.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(change.path)
                    Text(LensL10n.text("{0} · {1}", String(describing: store.agentName(change.agentID)), String(describing: change.environmentID))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(change.evidence).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).id(change.id).tag(change.id).listRowBackground(store.selection == .change(change.id) ? accent.selectionColor : .clear)
                .accessibilityAddTraits(store.selection == .change(change.id) ? .isSelected : [])
                .contextMenu {
                    Button(LensL10n.text("Voir l’action et son contexte")) { store.navigate(.event(change.eventID), newTab: true) }
                    LensActionButton(store: store, action: .investigate, target: .change(change.id))
                    Button(LensL10n.text("Ouvrir le fichier actuel dans cet environnement")) { store.navigate(.file(environment: change.environmentID, path: change.path)) }
                }
        }.listStyle(.plain)
            .overlay {
                if records.isEmpty {
                    let hasChanges = !(store.snapshot?.changes.isEmpty ?? true)
                    LensCollectionEmptyState(title: LensL10n.text(hasChanges ? "Aucune modification correspondante" : "Aucune modification enregistrée"),
                        detail: LensL10n.text(hasChanges ? "Vérifiez la nature de la trace, la recherche et les filtres d’agent, d’environnement ou de période. Ces filtres restent conservés." : "Les données disponibles ne contiennent aucune trace de modification. Le diff Git actuel reste distinct et accessible dans chaque environnement."), symbol: "plus.forwardslash.minus",
                        onClear: hasChanges && (kind != nil || !store.query.isEmpty) ? { kind = nil; store.query = "" } : nil)
                }
            }
            .task(id: store.selection) {
                // The list remounts when the detail split first appears. Wait for
                // its explicit row identities before revealing the selected action.
                await Task.yield()
                guard !Task.isCancelled else { return }
                revealSelection(proxy, records: records)
            }
        }
    }
    private func revealSelection(_ proxy: ScrollViewProxy, records: [ChangeRecord]) {
        if case .change(let id) = store.selection, records.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
    }

}
struct CurrentDiffView: View {
    @EnvironmentObject var store: LensStore
    let environment: EnvironmentRecord
    @State private var diff: CurrentDiff?
    @State private var issue: String?
    @State private var staged = false
    @State private var loading = false
    @State private var parsed: RecordedDiffPresentation?
    @State private var loadGeneration: UInt64 = 0
    @State private var loadTask: Task<Void, Never>?
    @State private var loadedIdentity: CurrentDiffReadIdentity?
    private var readIdentity: CurrentDiffReadIdentity { CurrentDiffReadIdentity(rootID: store.snapshot?.root.id, environmentID: environment.id, staged: staged) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if parsed == nil { Text(LensL10n.text("Diff Git actuel")).font(LensUI.metadata.weight(.semibold)) }
                Spacer(minLength: 8)
                Button(LensL10n.text("Lire le diff")) { startLoad() }.buttonStyle(LensQuietButtonStyle()).controlSize(.small).disabled(loading)
                Menu {
                    Toggle(LensL10n.text("Index Git"), isOn: $staged)
                        .help(LensL10n.text("Comparer les changements préparés pour commit. Choisissez Lire le diff pour charger cette comparaison."))
                } label: { LensIconMenuLabel() }
                    .lensIconMenu("Options du diff Git actuel")
                    .accessibilityIdentifier("lens-current-diff-options")
            }
            if staged, loadedIdentity != readIdentity { Text(LensL10n.text("Index Git")).font(LensUI.metadata).foregroundStyle(.secondary) }
            if parsed == nil { Text(LensL10n.text("Constat actuel du worktree, sans attribution automatique à Codex.")).font(LensUI.metadata).foregroundStyle(.secondary) }
            if loading { LensProgressIndicator().controlSize(.small) }
            if let issue { Text(LensL10n.display(issue)).font(.caption).foregroundStyle(LensAppearance.warningText).textSelection(.enabled) }
            if let diff {
                if let loadedIdentity {
                    Label(loadedIdentity.staged ? LensL10n.text("Diff chargé : index Git") : LensL10n.text("Diff chargé : fichiers de travail"), systemImage: LensSymbols.name("doc.text")).font(.caption)
                    if loadedIdentity != readIdentity { Text(LensL10n.text("Les paramètres ont changé. Lire le diff pour actualiser ; la comparaison précédente reste affichée.")).font(.caption).foregroundStyle(.secondary) }
                }
                if parsed == nil { Text(diff.reference).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                Text(diff.observedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                if !diff.excludedPaths.isEmpty { Text(LensL10n.text("{0} fichiers d’authentification exclus", String(describing: diff.excludedPaths.count))).font(.caption).foregroundStyle(.secondary) }
                if let parsed { RecordedDiffView(document: parsed.document).id(parsed.identity).frame(minHeight: 300) }
                else { PagedTextView(text: diff.text.nonempty ?? LensL10n.text("Aucune différence observée pour cette référence."), identity: environment.id + staged.description).frame(minHeight: 170) }
            }
        }.onChange(of: readIdentity) { _, _ in invalidateLoad() }.onDisappear { invalidateLoad() }
    }
    private func invalidateLoad() { loadTask?.cancel(); loadGeneration &+= 1; loading = false }
    private func startLoad() {
        guard !loading else { return }
        invalidateLoad(); loading = true; issue = nil
        let generation = loadGeneration, identity = readIdentity, capturedEnvironment = environment
        loadTask = Task { await load(environment: capturedEnvironment, identity: identity, generation: generation) }
    }
    private func isCurrent(_ identity: CurrentDiffReadIdentity, generation: UInt64) -> Bool { !Task.isCancelled && generation == loadGeneration && identity == readIdentity }
    private func load(environment: EnvironmentRecord, identity: CurrentDiffReadIdentity, generation: UInt64) async {
        let span = LensSignposts.begin("CurrentDiffLoad"); defer { span.end(); if generation == loadGeneration { loading = false } }
        do {
            let current = try await store.files.currentDiff(environment: environment, staged: identity.staged)
            guard isCurrent(identity, generation: generation) else { return }
            var document: RecordedDiffPresentation?, parseIssue: String?
            if !current.text.isEmpty {
                let provenance = DiffProvenance(environmentID: identity.environmentID, beforeReference: current.reference)
                do {
                    document = try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let parsed = try RecordedDiff.parse(current.text, provenance: provenance, kind: .currentGit)
                        return try RecordedDiffPresentation(document: parsed)
                    }.value
                } catch { parseIssue = LensL10n.text("Présentation du diff indisponible : ") + error.localizedDescription + " Le texte exact reste accessible." }
            }
            guard isCurrent(identity, generation: generation) else { return }
            diff = current; parsed = document; issue = parseIssue; loadedIdentity = identity
        } catch { if isCurrent(identity, generation: generation) { issue = error.localizedDescription } }
    }
}
struct CurrentDiffReadIdentity: Hashable {
    let rootID: String?
    let environmentID: String
    let staged: Bool
}
@ViewBuilder func paneHeader(_ title: String, subtitle: String, showsTitle: Bool = true) -> some View {
    if showsTitle {
        LensSectionHeader(title: title, detail: subtitle).padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
    } else {
        Text(subtitle).font(LensUI.metadata).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
    }
}
