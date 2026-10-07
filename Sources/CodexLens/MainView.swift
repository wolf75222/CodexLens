import SwiftUI
import AppKit
import LensCore

struct MainView: View {
    @EnvironmentObject var store: LensStore
    @Environment(\.lensWindowContext) private var windowContext
    @Environment(\.openSettings) private var openSettings
    @AppStorage("lensControlAccent") private var controlAccent = "lens"
    @AppStorage("lensAppearance") private var appearance = "dark"
    @AppStorage("lens.language") private var language = "en"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("lensSidebarVisible") private var sidebarVisible = true
    @SceneStorage("lensChatVisible") private var savedChatVisible = false
    @SceneStorage("lensReadingSize") private var savedReadingSize = 0.0
    @State private var onboardingVisible = false
    @State private var onboardingChecked = false
    @FocusState private var searchFocused: Bool
    private var workspace: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack {
                    Image(systemName: LensSymbols.name("exclamationmark.triangle")).foregroundStyle(LensAppearance.warningText).accessibilityHidden(true)
                    Text(LensL10n.display(error)).textSelection(.enabled).lineLimit(3).help(LensL10n.display(error))
                        .contextMenu { Button(LensL10n.text("Copier l’erreur complète")) { store.copyLocalText(error, notice: LensL10n.text("Erreur complète copiée")) } }
                    Spacer()
                    Button { store.copyLocalText(error, notice: LensL10n.text("Erreur complète copiée")) } label: { Label(LensL10n.text("Copier l’erreur complète"), systemImage: LensSymbols.name("doc.on.doc")) }.labelStyle(.iconOnly).buttonStyle(.borderless).help(LensL10n.text("Copier l’erreur complète"))
                    Button(LensL10n.text("Fermer")) { store.error = nil }.buttonStyle(.borderless)
                }.padding(10).background(Color.orange.opacity(0.1))
            }
            NavigationSplitView(columnVisibility: columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 190, ideal: 228, max: 420)
                    .background(LensPaneKeyboardAccess(region: .navigation, context: windowContext))
            } detail: {
                // Keep the optional side panel behind our bounded AppKit host.
                // A changing chat/editor minimum must not reach NavigationPane.
                LensNativeWorkspaceSplit(panes: workspacePanes)
                    .frame(minWidth: detailMinimumWidth)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .all : .detailOnly },
                set: { sidebarVisible = $0 != .detailOnly })
    }
    private var workspacePanes: [LensNativeWorkspacePane] {
        var panes: [LensNativeWorkspacePane] = []
        panes.append(LensNativeWorkspacePane(id: "content", minimum: contentMinimumWidth, maximum: nil, content: AnyView(
                VStack(spacing: 0) {
                    tabs
                    if store.snapshot != nil || (store.section == .investigation && store.investigation.capsule != nil) {
                        if showsFilterArea { filterArea; Divider() }
                        if store.liveTimelineVisible {
                            VSplitView {
                                LensLiveTimelinePane(store: store).frame(minHeight: 190, idealHeight: 260, maxHeight: .infinity)
                                liveCenter.frame(minHeight: 180, maxHeight: .infinity)
                            }.lensStableContent()
                        } else { center.lensStableContent().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    } else { emptyState }
                    if store.snapshot != nil || store.localActionNotice != nil { Divider(); statusBar }
                }.frame(minWidth: contentMinimumWidth)
                    .background(LensPaneKeyboardAccess(region: .content, context: windowContext))
        )))
        if store.chatVisible || store.inspectorVisible {
            panes.append(LensNativeWorkspacePane(id: "auxiliary", minimum: 320, maximum: 900, content: AnyView(
                VStack(spacing: 0) {
                        LensAuxiliaryPane(store: store, windowContext: windowContext, isChat: store.chatVisible)
                    }.lensStableContent().frame(minWidth: 320, idealWidth: 430, maxWidth: 900, maxHeight: .infinity)
                        .background(LensPaneSizing(key: "auxiliary", preferredWidth: 430, context: windowContext))
                        .background(LensPaneKeyboardAccess(region: store.chatVisible ? .chat : .inspector, context: windowContext))
            )))
        }
        return panes
    }
    private var contentMinimumWidth: CGFloat {
        store.chatVisible || store.inspectorVisible ? 340 : 430
    }
    private var detailMinimumWidth: CGFloat {
        contentMinimumWidth + (store.chatVisible || store.inspectorVisible ? 321 : 0)
    }
    private var workspaceMinimumWidth: CGFloat {
        // Tell NavigationSplitView the combined minimum of its hosted panes,
        // so native tiling can shrink the sidebar before clipping the chat.
        max(900, detailMinimumWidth + (sidebarVisible ? 191 : 0))
    }
    var body: some View {
        workspace.frame(minWidth: workspaceMinimumWidth, minHeight: 600)
        .environment(\.lensReadingMagnify, store.readingMagnifier)
        .lensControlAccent(LensControlAccent(rawValue: controlAccent) ?? .lens)
        .environment(\.locale, Locale(identifier: LensL10n.resolvedLanguage == .fr ? "fr" : "en"))
        .font(LensUI.body)
        .symbolRenderingMode(.monochrome)
        .navigationTitle(store.safeWindowTitle)
        .focusedSceneValue(\.lensSidebarVisibility, $sidebarVisible)
        .focusedSceneValue(\.lensSearchAction, windowContext?.searchCurrentView)
        .onAppear {
            if savedReadingSize.isFinite, (10...24).contains(savedReadingSize) { store.fontSize = savedReadingSize }
            else { savedReadingSize = store.fontSize }
            LensL10n.language = LensL10n.Language(rawValue: language) ?? .system
            if savedChatVisible { store.showChat() }
            if !onboardingChecked {
                onboardingVisible = LensGuideCoordinator.shared.onboarding.shouldPresentAutomatically()
                onboardingChecked = true
            }
            windowContext?.sidebarVisibility = $sidebarVisible
            windowContext?.searchSession = { store.browseSection(.activity); searchFocused = true }; windowContext?.searchCurrentView = { searchCurrentView() }
        }
        .onChange(of: language) { _, value in LensL10n.language = LensL10n.Language(rawValue: value) ?? .system; store.objectWillChange.send() }
        .onChange(of: store.fontSize) { _, value in savedReadingSize = Double(LensUI.readingSize(value)) }
        .onChange(of: sidebarVisible) { _, _ in windowContext?.objectWillChange.send() }
        .onChange(of: store.chatVisible) { _, value in
            savedChatVisible = value
            if value { windowContext?.focusPane(.chat, afterLayout: true) }
        }
        // AppKit synchronizes toolbars with the same identifier as one family.
        // A child loading a session has different transient items from its idle
        // parent; that family insertion can throw while creating the window.
        // Keep customization and state local to the stable scene identity.
        .toolbar(id: windowContext?.toolbarIdentifier ?? "LensSessionToolbar-" + store.windowIdentity) { navigationToolbar; inspectionToolbar }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .sheet(item: presentation) { sheet in
            Group {
            switch sheet {
            case .onboarding:
                LensOnboardingView(onOpenSession: { store.perform(.openSession) }) {
                    LensGuideCoordinator.shared.onboarding.dismiss()
                    onboardingVisible = false
                }
            case .session: SessionPickerView()
            case .coverage: CoverageView()
            case .conversation:
                if let snapshot = store.snapshot {
                    ConversationExportView(snapshot: snapshot, onClose: { store.showConversation = false })
                }
            }
            }.lensControlAccent(LensControlAccent(rawValue: controlAccent) ?? .lens)
        }
        .lensMotionAware()
    }
    @ToolbarContentBuilder private var navigationToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "openSession", placement: .navigation) { LensActionButton(store: store, action: .openSession) }
        // NavigationSplitView supplies the native sidebar toggle. Keep the
        // same command in the menu bar without adding a second toolbar button.
        // Keep history together in a required native toolbar item. Separate
        // reorderable items can still be removed via AppKit accessibility.
        ToolbarItem(id: "navigationHistory", placement: .navigation) {
            HStack(spacing: 12) {
                LensActionButton(store: store, action: .back).labelStyle(.iconOnly)
                    .help(LensL10n.text("Précédent · ⌘["))
                    .accessibilityLabel(LensL10n.text("Précédent"))
                    .accessibilityIdentifier("lens-navigation-back")
                LensActionButton(store: store, action: .forward).labelStyle(.iconOnly)
                    .help(LensL10n.text("Suivant · ⌘]"))
                    .accessibilityLabel(LensL10n.text("Suivant"))
                    .accessibilityIdentifier("lens-navigation-forward")
            }
            .accessibilityElement(children: .contain)
            // AppKit caches hosted toolbar accessibility labels. Refresh only
            // these stateless controls when the interface language changes.
            .id("\(language):\(LensL10n.resolvedLanguage.rawValue)")
        }.customizationBehavior(.disabled)
    }
    @ToolbarContentBuilder private var inspectionToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "operation", placement: .primaryAction) {
            if store.busy {
                HStack {
                    LensProgressIndicator(accessibilityLabel: LensL10n.text("Lecture des traces de la session")).controlSize(.small)
                    if let windowContext { LensWindowOperationControls(context: windowContext) }
                }
            }
        }.customizationBehavior(.disabled)
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            LensActionButton(store: store, action: .inspector)
                .labelStyle(.iconOnly)
        }
        ToolbarItem(id: "investigate", placement: .primaryAction) { LensActionButton(store: store, action: .chat).labelStyle(.iconOnly) }
        ToolbarItem(id: "more", placement: .primaryAction) {
            Menu {
                LensActionButton(store: store, action: .chat)
                LensActionButton(store: store, action: .liveTimeline)
                LensActionButton(store: store, action: .follow)
                Divider()
                LensActionButton(store: store, action: .conversation)
                LensActionButton(store: store, action: .bookmark)
                sidebarShortcuts
                Button { store.showCoverage = true } label: { Label(LensL10n.text("Sources et limites…"), systemImage: "info.circle") }.disabled(store.snapshot == nil)
                Divider()
                SettingsLink { Label(LensL10n.text("Réglages…"), systemImage: "gearshape") }
            } label: { LensIconMenuLabel() }
                .menuIndicator(.hidden)
                .accessibilityLabel(LensL10n.text("Actions de la session"))
                .help(LensL10n.text("Chat, direct et options de la session"))
                .accessibilityIdentifier("lens-workspace-more")
        }
        ToolbarItem(id: "live", placement: .primaryAction) { LensActionButton(store: store, action: .liveTimeline) }.defaultCustomization(.hidden)
        ToolbarItem(id: "follow", placement: .primaryAction) { LensActionButton(store: store, action: .follow) }.defaultCustomization(.hidden)
    }
    // One presentation route prevents catalog/session updates from dismissing
    // the first-run guide. Closing the guide never stops session collection.
    private var presentation: Binding<LensMainSheet?> {
        Binding(get: {
            guard onboardingChecked else { return nil }
            if onboardingVisible { return .onboarding }
            if store.showCoverage { return .coverage }
            if store.showSessionPicker { return .session }
            if store.showConversation { return .conversation }
            return nil
        }, set: { value in
            guard value == nil else { return }
            if onboardingVisible {
                LensGuideCoordinator.shared.onboarding.dismiss()
                onboardingVisible = false
            } else if store.showCoverage { store.showCoverage = false }
            else if store.showSessionPicker { store.showSessionPicker = false }
            else { store.showConversation = false }
        })
    }
    private func searchCurrentView() {
        if store.section == .agents { NotificationCenter.default.post(name: .lensFocusAgentSearch, object: store) }
        else { searchFocused = true }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snap = store.snapshot {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snap.root.title.nonempty ?? LensL10n.text("Session {0}", String(snap.root.id.prefix(8))))
                        .font(.headline).lineLimit(2).truncationMode(.tail).help(snap.root.title)
                        .accessibilityAddTraits(.isHeader)
                    Text("ID · " + String(snap.root.id.prefix(8)))
                        .font(LensUI.metadata.monospaced()).foregroundStyle(.secondary)
                        .help(snap.root.id).textSelection(.enabled)
                        .contextMenu { Button(LensL10n.text("Copier l’ID de session")) { store.copyLocalText(snap.root.id, notice: LensL10n.text("ID de session copié")) } }
                }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
                List(selection: sidebarSelection) {
                    Section {
                        ForEach([LensSection.activity, .agents, .calls]) { navigationRow($0) }
                    }
                    Section(LensL10n.text("Fichiers")) {
                        ForEach([LensSection.changes, .environments, .resources]) { navigationRow($0) }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("lens-session-navigation")
                Text(LensL10n.text("Lecture seule") + (snap.coverage.isEmpty ? "" : " · " + LensUI.count(snap.coverage.count, singular: LensL10n.text("limite"), plural: LensL10n.text("limites"))))
                    .font(LensUI.metadata).foregroundStyle(.secondary).padding(14)
                    .help(LensL10n.text("Menu de la session → Sources et limites détaille les données manquantes."))
            } else {
                Text("Codex Lens").font(.headline).padding(16)
                Spacer()
            }
        }
    }
    private var sidebarSelection: Binding<LensSection?> {
        Binding(get: { store.section == .investigation ? nil : store.section }, set: { section in
            if let section { store.browseSection(section) }
        })
    }
    @ViewBuilder private var sidebarShortcuts: some View {
        if let snap = store.snapshot {
            Menu(LensL10n.text("Accès rapides")) {
                Menu(LensL10n.text("Agents")) {
                    ForEach(snap.agents.prefix(80)) { agent in
                        Button(agent.name.nonempty ?? agent.id) { store.navigate(.agent(agent.id), newTab: true) }
                    }
                    if snap.agents.count > 80 { Button(LensL10n.text("Tous les agents")) { store.browseSection(.agents) } }
                }
                Menu(LensL10n.text("Environnements")) {
                    ForEach(snap.environments.prefix(20)) { env in
                        Button(environmentLabel(path: env.path)) { store.navigate(.environment(env.id)) }
                    }
                    if snap.environments.count > 20 { Button(LensL10n.text("Tous les environnements")) { store.browseSection(.environments) } }
                }
            }
            if !store.bookmarks.filter({ $0.rootID == snap.root.id }).isEmpty {
                Menu(LensL10n.text("Signets")) {
                    ForEach(store.bookmarks.filter { $0.rootID == snap.root.id }) { bookmark in
                        Button(bookmark.title) { store.navigate(bookmark.destination, newTab: true) }
                    }
                }
            }
        }
    }
    private func navigationRow(_ section: LensSection) -> some View {
        Button { store.browseSection(section) } label: {
            Label(LensL10n.display(section.rawValue), systemImage: LensSymbols.name(section.symbol))
                .font(LensUI.body).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).tag(section)
            .accessibilityAddTraits(store.section == section ? .isSelected : [])
            .accessibilityLabel(LensL10n.display(section.rawValue))
            .accessibilityIdentifier("lens-section-" + section.rawValue)
    }
    @ViewBuilder private var tabs: some View {
      if store.hasWorkspaceReturn || (selectionNeedsOpenAction && store.selection != nil && !store.tabContentVisible) {
        HStack(spacing: 12) {
            if store.hasWorkspaceReturn {
                LensWorkspaceTabs(store: store)
            } else { Spacer(minLength: 0) }
            if !store.tabContentVisible, let target = store.selection, store.presents(target), selectionNeedsOpenAction {
                Button(LensL10n.text("Ouvrir la sélection")) { store.navigate(target, newTab: true) }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    .help(LensL10n.text("Afficher le contenu complet. Double-clic ou Retour dans la liste."))
                    .accessibilityIdentifier("lens-open-selection")
            }
        }.padding(.horizontal, 16).padding(.vertical, 4).frame(minHeight: 36)
            .background(LensBrand.chrome)
            .overlay(alignment: .bottom) { Divider() }
      }
    }
    private var selectionNeedsOpenAction: Bool {
        switch store.selection { case .event, .agent: return true; default: return false }
    }
    private var isEventSection: Bool { store.section == .activity || store.section == .calls }
    private var isObjectSearchSection: Bool { store.section == .environments || store.section == .resources || store.section == .changes }
    private var showsFilterArea: Bool { store.tabContentDestination == nil && (isEventSection || isObjectSearchSection || !preservedActivityFilters.isEmpty) }
    @ViewBuilder private var filterArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEventSection || isObjectSearchSection {
                HStack(spacing: 12) {
                    Text(LensL10n.display(store.section.rawValue)).font(.headline)
                        .lineLimit(1).truncationMode(.tail).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    queryControl(placeholder: isEventSection ? LensL10n.text("Rechercher dans la session…") : objectQueryPlaceholder,
                        scope: isEventSection ? LensL10n.text("Recherche dans les événements et traces de la session") : objectQueryScope)
                        .frame(minWidth: 160, idealWidth: 320, maxWidth: 400)
                }
                if isEventSection { activityFilterChips(includeResource: true) }
                else if store.section == .changes { activityFilterChips(includeResource: false) }
            }
            if !preservedActivityFilters.isEmpty {
                HStack(spacing: 8) {
                    Label(LensL10n.text("Filtres d’activité conservés"), systemImage: LensSymbols.name("line.3.horizontal.decrease.circle")).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(preservedActivityFilters.joined(separator: "\n"))
                        .accessibilityLabel(LensL10n.text("Filtres conservés pour l’activité, sans effet sur cette vue : ") + preservedActivityFilters.joined(separator: ". "))
                    Spacer(minLength: 4)
                    Button(LensL10n.text("Voir l’activité")) { store.browseSection(.activity) }.buttonStyle(.borderless).controlSize(.small)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func queryControl(placeholder: String, scope: String) -> some View {
        HStack(spacing: 8) {
            LensNativeSearchField(placeholder: placeholder, text: $store.query, accessibilityLabel: scope,
                focused: Binding(get: { searchFocused }, set: { searchFocused = $0 }), onChange: { store.search() })
                .frame(height: 28)
                .help(scope + LensL10n.text(". ⇧⌘F : session ; ⌘F : texte ou vue affichée."))
            if !store.query.isEmpty, store.searchMatches == nil { LensProgressIndicator().controlSize(.mini).accessibilityLabel(LensL10n.text("Recherche dans la session")) }
            if isEventSection {
                Menu {
                    Picker(LensL10n.text("Type"), selection: $store.kindFilter) {
                        Text(LensL10n.text("Tous les événements")).tag(EventKind?.none)
                        ForEach(EventKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    if store.section == .activity {
                        Divider()
                        Picker(LensL10n.text("Vue de l’activité"), selection: $store.activityMode) {
                            ForEach(ActivityInspectionMode.allCases, id: \.self) { Text(LensL10n.text($0.rawValue)).tag($0) }
                        }
                        if let index = store.presentation?.contextInspection, !index.compactions.isEmpty {
                            Button(LensL10n.text("Compactages · {0}", String(index.identifiedOperationCount))) { store.activityMode = .chronology; store.kindFilter = .compaction }
                        }
                        if !store.liveTimelineVisible {
                            Button(LensL10n.text(store.timelineVisible ? "Masquer la chronologie" : "Afficher la chronologie")) { store.timelineVisible.toggle() }
                        }
                    }
                    Divider()
                    LensActionButton(store: store, action: .clearFilters)
                } label: { Label(LensL10n.text("Vue et filtres"), systemImage: LensSymbols.name("line.3.horizontal.decrease.circle")) }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                    .help(LensL10n.text("Vue et filtres")).accessibilityLabel(LensL10n.text("Vue et filtres"))
                    .accessibilityIdentifier("lens-activity-filters")
            }
        }
    }
    private var objectQueryPlaceholder: String {
        switch store.section {
        case .environments: return LensL10n.text("Rechercher chemins, branches ou traces…")
        case .resources: return LensL10n.text("Rechercher noms, références ou traces…")
        case .changes: return LensL10n.text("Rechercher dans les modifications…")
        default: return LensL10n.text("Rechercher dans la session…")
        }
    }
    private var objectQueryScope: String {
        switch store.section {
        case .environments: return LensL10n.text("Recherche dans les chemins, les branches enregistrées et les traces des environnements")
        case .resources: return LensL10n.text("Recherche dans les noms, les références, la provenance et les traces des ressources")
        case .changes: return LensL10n.text("Rechercher un chemin ou une modification")
        default: return LensL10n.text("Rechercher les événements de la session")
        }
    }
    /// Only show removable chips whose predicate actually participates in this view.
    @ViewBuilder private func activityFilterChips(includeResource: Bool) -> some View {
        if store.agentFilter != nil || store.environmentFilter != nil || store.period != nil || (includeResource && (store.kindFilter != nil || store.resourceFilter != nil || store.originInstructionFilter != nil)) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if includeResource, let kind = store.kindFilter { filterChip(kind.label, description: LensL10n.text("Type · ") + kind.label) { store.kindFilter = nil } }
                    if let id = store.agentFilter { filterChip(store.agentName(id), description: LensL10n.text("Agent · ") + store.agentName(id) + " · " + id) { store.agentFilter = nil } }
                    if let path = store.environmentFilter { filterChip(environmentLabel(path: path), description: LensL10n.text("Environnement · ") + environmentDescription(path: path)) { store.environmentFilter = nil } }
                    if includeResource, let id = store.resourceFilter { filterChip(store.snapshot?.resources.first { $0.id == id }?.name ?? "Ressource", description: "Ressource · " + id) { store.resourceFilter = nil } }
                    if includeResource, let id = store.originInstructionFilter { filterChip(LensL10n.text("Instruction associée"), description: store.event(id)?.title ?? id) { store.originInstructionFilter = nil } }
                    if let period = store.period { filterChip(periodLabel(period), description: periodDescription(period)) { store.period = nil } }
                }.fixedSize(horizontal: true, vertical: false)
            }.scrollIndicators(.hidden)
        }
    }
    private var preservedActivityFilters: [String] {
        guard !isEventSection else { return [] }
        var result: [String] = []
        if !isObjectSearchSection, !store.query.isEmpty { result.append(LensL10n.text("Recherche dans les traces : ") + store.query) }
        if store.section != .changes {
            if let id = store.agentFilter { result.append(LensL10n.text("Agent : ") + store.agentName(id) + " · " + id) }
            if let path = store.environmentFilter { result.append(LensL10n.text("Environnement : ") + environmentDescription(path: path)) }
            if let period = store.period { result.append(periodDescription(period)) }
        }
        if let id = store.resourceFilter { result.append("Ressource : " + (store.snapshot?.resources.first { $0.id == id }?.name ?? id)) }
        if let kind = store.kindFilter { result.append(LensL10n.text("Type d’événement : ") + kind.label) }
        return result
    }
    private func filterChip(_ text: String, description: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) { Label(text, systemImage: LensSymbols.name("xmark.circle.fill")).font(LensUI.metadata) }.buttonStyle(.bordered).controlSize(.small)
            .help(LensL10n.text("Retirer le filtre « ") + description + LensL10n.text(" »")).accessibilityLabel(LensL10n.text("Retirer le filtre « ") + description + LensL10n.text(" »"))
    }
    private func environmentLabel(path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let paths = (store.snapshot?.environments ?? []).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        let basename = url.lastPathComponent.nonempty ?? url.path
        let homonyms = paths.filter { URL(fileURLWithPath: $0).lastPathComponent == url.lastPathComponent }
        guard Set(homonyms).count > 1 else { return basename }
        let components = url.pathComponents.filter { $0 != "/" }
        var depth = min(2, components.count)
        var suffix = components.suffix(depth).joined(separator: "/")
        while depth < components.count && homonyms.count(where: { URL(fileURLWithPath: $0).pathComponents.filter { $0 != "/" }.suffix(depth).joined(separator: "/") == suffix }) > 1 {
            depth += 1; suffix = components.suffix(depth).joined(separator: "/")
        }
        let branch = store.snapshot?.environments.first { $0.path == path || $0.id == path }?.recordedBranch?.nonempty
        return suffix + (branch.map { LensL10n.text(" · ") + $0 } ?? "")
    }
    private func environmentDescription(path: String) -> String {
        let environment = store.snapshot?.environments.first { $0.path == path || $0.id == path }
        let branch = environment?.recordedBranch?.nonempty
        return (environment?.path ?? path) + (branch.map { LensL10n.text(" · branche enregistrée : ") + $0 } ?? "")
    }
    private func periodLabel(_ period: ClosedRange<Date>) -> String {
        let sameDay = Calendar.current.isDate(period.lowerBound, inSameDayAs: period.upperBound)
        return period.lowerBound.lensFormatted(date: sameDay ? .omitted : .abbreviated, time: .shortened) + LensL10n.text(" – ") + period.upperBound.lensFormatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
    }
    private func periodDescription(_ period: ClosedRange<Date>) -> String {
        let zone = TimeZone.current
        let lower = period.lowerBound.lensFormatted(date: .complete, time: .standard), upper = period.upperBound.lensFormatted(date: .complete, time: .standard)
        let lowerZone = zone.abbreviation(for: period.lowerBound) ?? zone.identifier, upperZone = zone.abbreviation(for: period.upperBound) ?? zone.identifier
        return LensL10n.text("Période : ") + lower + LensL10n.text(" (") + lowerZone + LensL10n.text(") – ") + upper + LensL10n.text(" (") + upperZone + LensL10n.text(") · fuseau ") + zone.identifier
    }
    @ViewBuilder private var liveCenter: some View {
        if let target = store.livePreview { LensLivePreviewView(destination: target) }
        else { center }
    }
    @ViewBuilder private var center: some View {
        if let target = store.tabContentDestination {
            switch target {
            case .event:
                LensLivePreviewView(destination: target, temporary: false).accessibilityIdentifier("lens-event-tab-content")
            case .agent:
                InspectorView(heading: store.label(target), embedded: true).accessibilityIdentifier("lens-agent-tab-content")
            default: EmptyView()
            }
        } else { collectionCenter }
    }
    @ViewBuilder private var collectionCenter: some View {
        switch store.section {
        case .activity: ActivityView()
        case .calls: EventListView(events: store.presentation?.filteredCalls ?? [], title: LensL10n.text("Appels d’outils"), isCalls: true)
        case .agents: AgentsView()
        case .environments: EnvironmentsView()
        case .resources: ResourcesView()
        case .changes: ChangesView()
        case .investigation: InvestigationEvidenceView(investigator: store.investigation)
        }
    }
    private var emptyState: some View {
        Group {
            if store.busy {
                LensLoadingState(title: LensL10n.text("Lecture des traces de la session…"),
                    cancelTitle: LensL10n.text("Annuler l’ouverture"), onCancel: { store.cancelSessionOpening() },
                    operationID: store.openingIdentity)
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(LensL10n.text("Aucune session ouverte")).font(.title2.weight(.semibold))
                        Text(LensL10n.text("Consultez l’historique et suivez l’activité d’une session Codex."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button(LensL10n.text("Ouvrir une session…")) { store.perform(.openSession) }.lensChromeButton(prominent: true).lensFilledControlAccent()
                        Text("⌘O").font(LensUI.metadata).foregroundStyle(.secondary)
                    }
                    Button {
                        LensGuideCoordinator.shared.showHelp()
                        openSettings()
                    } label: { Label(LensL10n.text("Guide de démarrage"), systemImage: LensSymbols.name("book")) }
                        .buttonStyle(LensQuietButtonStyle())
                }.frame(maxWidth: 480, alignment: .leading).padding(30)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var statusBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { collectionStatus; Spacer(minLength: 8); presentationStatus }
            VStack(alignment: .leading, spacing: 5) {
                collectionStatus
                HStack { Spacer(minLength: 0); presentationStatus }
            }
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 7).background(Color(nsColor: .windowBackgroundColor))
    }
    private var collectionStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: LensSymbols.name(store.snapshot == nil ? "circle.dotted" : !store.hasSessionReader ? "archivebox" : store.follow ? "dot.radiowaves.left.and.right" : "pause.circle")).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(store.snapshot == nil ? LensL10n.text("Aucune session ouverte") : !store.hasSessionReader ? LensL10n.text("Archive locale · journaux indisponibles") : store.follow ? LensL10n.text("Collecte active · suivi visuel actif") : LensL10n.text("Collecte active · suivi visuel suspendu"))
            if store.waitingEvents > 0 { Button(LensL10n.text("Voir ") + LensUI.count(store.waitingEvents, singular: LensL10n.text("nouvel événement"), plural: LensL10n.text("nouveaux événements"))) { store.present() }.buttonStyle(.borderless) }
        }
    }
    @ViewBuilder private var presentationStatus: some View {
        if let notice = store.localActionNotice {
            Label(LensL10n.display(notice), systemImage: LensSymbols.name("info.circle")).lineLimit(2).help(LensL10n.display(notice)).accessibilityLabel(LensL10n.display(notice))
        } else if store.snapshot != nil {
            Text(presentationStatusLabel).foregroundStyle(.secondary)
        }
    }
    private var presentationStatusLabel: String {
        switch store.section {
        case .activity: return LensUI.count(store.events.count, singular: LensL10n.text("événement visible"), plural: LensL10n.text("événements visibles"))
        case .calls: return LensUI.count(store.presentation?.filteredCalls.count ?? 0, singular: LensL10n.text("appel visible"), plural: LensL10n.text("appels visibles"))
        case .agents: return LensUI.count(store.presentation?.agentRows.count ?? 0, singular: LensL10n.text("agent visible"), plural: LensL10n.text("agents visibles"))
        case .environments: return LensL10n.text("Environnements de la session")
        case .resources: return LensL10n.text("Bibliothèque de ressources")
        case .changes: return LensL10n.text("Traces de modification")
        case .investigation: return LensL10n.text("Enquête locale")
        }
    }

}

struct SessionPickerView: View {
    @EnvironmentObject var store: LensStore
    @State private var text = ""
    @State private var showDescendants = false
    @State private var selectedSessionID: String?
    @FocusState private var searchFocused: Bool
    var choices: [SessionSummary] {
        let query = SessionPickerTarget.sessionID(from: text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.catalog.filter { (showDescendants || $0.relation == .root || $0.relation == .fork) && (query.isEmpty || ($0.id + " " + $0.title + " " + $0.cwd).localizedStandardContains(query)) }
    }
    private var openingID: String? {
        SessionPickerTarget.resolve(text: text, selectedID: selectedSessionID, visibleIDs: choices.map(\.id))
    }
    private func openSelection() {
        guard let id = openingID, !store.busy else { return }
        Task { await store.open(id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LensL10n.text("Sessions")).font(.title2)
            HStack(spacing: 8) {
                LensNativeSearchField(placeholder: LensL10n.text("Rechercher, coller un ID ou un lien Codex…"), text: $text, focused: Binding(get: { searchFocused }, set: { searchFocused = $0 }), onSubmit: { openSelection() }).frame(height: 28)
                    .onChange(of: text) { _, _ in selectedSessionID = nil }
                    .accessibilityLabel(LensL10n.text("Recherche, ID ou lien de session"))
                Button { Task { await store.refreshCatalog() } } label: {
                    Image(systemName: LensSymbols.name("arrow.clockwise"))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(store.catalogLoading)
                .help(LensL10n.text("Actualiser"))
                .accessibilityLabel(LensL10n.text("Actualiser"))
                .accessibilityIdentifier("lens-session-refresh")
            }
            HStack {
                Toggle(LensL10n.text("Inclure les sous-agents et reprises"), isOn: $showDescendants).help(LensL10n.text("Ajouter les historiques descendants au catalogue ; cela ne change pas leurs liens enregistrés"))
                if store.catalogLoading { LensProgressIndicator(LensL10n.text("Actualisation…")).controlSize(.mini) }
                Spacer()
            }.font(.caption)
            HStack(spacing: 8) {
                Image(systemName: LensSymbols.name("folder")).accessibilityHidden(true)
                Text(store.sourceHome.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(store.sourceHome.path).accessibilityLabel(LensL10n.text("Dossier des sessions : {0}", store.sourceHome.path))
                Spacer(minLength: 4)
                if store.sourceHome.standardizedFileURL != store.personalSessionHome.standardizedFileURL {
                    Button(LensL10n.text("Mes sessions Codex")) {
                        Task { await store.useSessionSource(store.personalSessionHome) }
                    }.disabled(store.busy || store.catalogLoading)
                        .help(LensL10n.text("Consulter les sessions de {0}, sans modifier la session ouverte.", store.personalSessionHome.path))
                        .accessibilityIdentifier("lens-session-personal-source")
                }
            }.font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("lens-session-source")
            if let error = store.error { Label(LensL10n.display(error), systemImage: LensSymbols.name("exclamationmark.triangle")).foregroundStyle(LensAppearance.errorText).textSelection(.enabled) }
            List(choices, selection: $selectedSessionID) { session in
                Button {
                    selectedSessionID = session.id
                    searchFocused = false
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(session.title.nonempty ?? session.agentName.nonempty ?? LensL10n.text("Session sans titre")).font(.headline).lineLimit(1); Spacer(); Text(session.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                        Text(session.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).tag(session.id).accessibilityHidden(store.busy)
                    .help((session.title.nonempty ?? LensL10n.text("Session sans titre")) + "\n" + session.id + "\n" + session.cwd)
                    // A native button makes single-click and accessibility
                    // activation explicit; double-click observes it without
                    // consuming that selection action.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        guard !store.busy else { return }
                        Task { await store.open(session.id) }
                    })
                    .contextMenu {
                        Button(LensL10n.text("Ouvrir cette session")) { Task { await store.open(session.id) } }.disabled(store.busy)
                        Button(LensL10n.text("Copier l’ID")) { store.copyLocalText(session.id, notice: LensL10n.text("ID de session copié")) }
                        Button(LensL10n.text("Copier le répertoire initial")) { store.copyLocalText(session.cwd, notice: LensL10n.text("Répertoire initial copié")) }.disabled(session.cwd.isEmpty)
                    }
            }
            .scrollContentBackground(.hidden)
            // Retain the native list's selection/scroll state while opening,
            // but let the sheet's surface show through behind the loader.
            .opacity(store.busy ? 0 : 1)
            .accessibilityHidden(store.busy)
            .disabled(store.busy)
            .overlay {
                if store.busy {
                    LensLoadingState(title: LensL10n.text("Lecture des traces…"),
                        cancelTitle: LensL10n.text("Annuler l’ouverture"), onCancel: { store.cancelSessionOpening() },
                        operationID: store.openingIdentity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if choices.isEmpty {
                    if store.catalogLoading { LensLoadingState(title: LensL10n.text("Recherche des sessions locales…")) }
                    else { Text(store.catalog.isEmpty ? LensL10n.text("Aucune session locale accessible. Collez un ID complet ou actualisez la liste.") : LensL10n.text("Aucune session ne correspond. Essayez un autre terme ou collez un ID complet.")).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24).allowsHitTesting(false) }
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button(LensL10n.text("Fermer")) { store.showSessionPicker = false }
                    .keyboardShortcut(.cancelAction)
                LensNativePrimaryButton(title: LensL10n.text("Ouvrir la session"), isDefault: true) { openSelection() }
                    .disabled(openingID == nil || store.busy)
                    .help(LensL10n.text("Collez un ID ou un lien codex://threads/…, sélectionnez une session ou affinez la recherche."))
            }
        }.padding(22).frame(minWidth: 620, idealWidth: 740, minHeight: 470, idealHeight: 540)
            .onAppear { searchFocused = true }
            .onChange(of: store.sourceHome) { _, _ in selectedSessionID = nil }
    }
}

struct CoverageView: View {
    @EnvironmentObject var store: LensStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(LensL10n.text("Limites des traces")).font(.title2); Spacer(); Button(LensL10n.text("Fermer")) { store.showCoverage = false }.keyboardShortcut(.cancelAction) }
            Text(LensL10n.text("Ce qui n’est pas enregistré reste inconnu. Les fichiers actuels sont lus aujourd’hui ; l’historique conserve les événements d’origine.")).foregroundStyle(.secondary)
            List(store.snapshot?.coverage ?? []) { issue in
                VStack(alignment: .leading, spacing: 7) {
                    Text(issue.category).font(.headline)
                    Text(LensL10n.display(issue.message)).textSelection(.enabled)
                    if !issue.source.isEmpty {
                        Text(issue.source).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if issue.source.hasPrefix("/"), issue.source.hasSuffix(".jsonl") {
                            Button(LensL10n.text("Examiner le journal source actuel")) {
                                store.navigate(.file(environment: URL(fileURLWithPath: issue.source).deletingLastPathComponent().path, path: issue.source), newTab: true)
                                store.showCoverage = false
                            }.controlSize(.small)
                        }
                    }
                }.padding(.vertical, 5)
            }
            Text(LensL10n.text("Lecture des journaux locaux · sans installation de hooks ni reprise de session")).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(minWidth: 620, idealWidth: 740, minHeight: 470, idealHeight: 540)
    }
}

/// Keep the relation and availability together in every sidebar agent row.
struct LensSidebarAgentButton: View {
    let agent: AgentRecord
    let onOpen: () -> Void
    private var name: String { agent.name.nonempty ?? String(agent.id.prefix(8)) }
    private var tint: Color { agent.accessible ? .secondary : .orange }
    private var indentation: CGFloat { agent.parentID == nil ? 0 : 8 }
    private var hint: String { name + LensL10n.text(" · ") + agent.id + LensL10n.text(" · ") + relationLabel(agent.relation) }
    private var accessibleTitle: String { name + LensL10n.text(" · ") + relationLabel(agent.relation) }
    private var availability: String { agent.accessible ? "" : LensL10n.text("Historique inaccessible") }
    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).lineLimit(1)
            if !agent.accessible { Text(LensL10n.text("Historique inaccessible")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var content: some View {
        HStack(spacing: 6) {
            Image(systemName: LensSymbols.agent(agent.relation)).foregroundStyle(tint).accessibilityHidden(true)
            titles
        }.padding(.leading, indentation)
    }
    var body: some View {
        Button(action: onOpen) { content }.buttonStyle(.plain)
            .help(hint).accessibilityLabel(accessibleTitle).accessibilityValue(availability)
    }
}

private enum LensMainSheet: String, Identifiable {
    case onboarding, session, coverage, conversation
    var id: String { rawValue }
}
