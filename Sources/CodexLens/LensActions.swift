import SwiftUI
import AppKit
import LensCore

enum LensAction: String, CaseIterable, Identifiable {
    case openSession, back, forward, follow, liveTimeline, clearFilters, copyLink, inspector, chat, investigate, bookmark, largerText, smallerText
    case provenance, revealInFinder, exportInvestigation, importArchive, conversation, openInNewTab, openInNewWindow
    var id: String { rawValue }
    var scope: LensCommandScope {
        switch self {
        case .copyLink, .investigate, .bookmark, .provenance, .revealInFinder, .openInNewTab, .openInNewWindow: return .selection
        default: return .window
        }
    }
    @MainActor func title(in store: LensStore, target: Destination? = nil) -> String {
        switch self {
        case .openSession: return LensL10n.text("Ouvrir une session…")
        case .back: return LensL10n.text("Précédent")
        case .forward: return LensL10n.text("Suivant")
        case .liveTimeline: return store.liveTimelineVisible ? LensL10n.text("Masquer le direct") : LensL10n.text("Afficher le direct")
        case .follow: return store.follow ? LensL10n.text("Suspendre le suivi visuel") : LensL10n.text("Revenir au présent")
        case .clearFilters: return store.section == .agents ? LensL10n.text("Effacer la recherche des agents") : LensL10n.text("Réinitialiser les filtres d’activité")
        case .copyLink: return LensL10n.text("Copier le lien interne")
        case .inspector: return store.inspectorVisible && !store.chatVisible ? LensL10n.text("Masquer l’inspecteur") : LensL10n.text("Afficher l’inspecteur")
        case .chat: return store.chatVisible ? LensL10n.text("Masquer le chat d’enquête") : LensL10n.text("Afficher le chat d’enquête")
        case .investigate: return LensL10n.text("Demander à l’IA…")
        case .bookmark:
            let selected = target ?? store.selection
            return store.bookmarks.contains { $0.rootID == store.snapshot?.root.id && $0.destination == selected } ? LensL10n.text("Retirer le signet") : LensL10n.text("Ajouter un signet")
        case .largerText: return LensL10n.text("Agrandir le texte")
        case .smallerText: return LensL10n.text("Réduire le texte")
        case .provenance: return LensL10n.text("Afficher la provenance")
        case .revealInFinder: return LensL10n.text("Afficher l’emplacement actuel dans le Finder")
        case .exportInvestigation: return LensL10n.text("Exporter l’enquête…")
        case .importArchive: return LensL10n.text("Importer une archive d’enquête…")
        case .conversation: return LensL10n.text("Conversation et orientations…")
        case .openInNewTab: return LensL10n.text("Ouvrir dans un onglet")
        case .openInNewWindow: return LensL10n.text("Ouvrir dans une nouvelle fenêtre")
        }
    }
    @MainActor func symbol(in store: LensStore, target: Destination? = nil) -> String {
        if self == .follow { return LensSymbols.name(store.follow ? "pause.circle" : "play.circle") }
        if self == .bookmark {
            let selected = target ?? store.selection
            let saved = store.bookmarks.contains { $0.rootID == store.snapshot?.root.id && $0.destination == selected }
            return LensSymbols.name(saved ? "bookmark.fill" : "bookmark")
        }
        return LensSymbols.name(symbol)
    }
    var symbol: String {
        switch self {
        case .openSession: return "rectangle.stack"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .liveTimeline: return "dot.radiowaves.left.and.right"
        case .follow: return "pause.circle"
        case .clearFilters: return "line.3.horizontal.decrease.circle"
        case .copyLink: return "link"
        case .inspector: return "sidebar.right"
        case .chat: return "text.bubble"
        case .investigate: return "text.bubble"
        case .bookmark: return "bookmark"
        case .largerText: return "textformat.size.larger"
        case .smallerText: return "textformat.size.smaller"
        case .provenance: return "link"
        case .revealInFinder: return "folder"
        case .exportInvestigation: return "square.and.arrow.up"
        case .importArchive: return "square.and.arrow.down"
        case .conversation: return "bubble.left.and.bubble.right"
        case .openInNewTab: return "plus.rectangle.on.rectangle"
        case .openInNewWindow: return "macwindow"
        }
    }
}
extension LensStore {
    func canPerform(_ action: LensAction, target: Destination? = nil) -> Bool {
        guard !LensApplicationCoordinator.shared.maintenanceInProgress else { return false }
        if action.scope == .selection, !knownCommandDestination(target ?? selection) { return false }
        switch action {
        case .back: return canGoBack
        case .forward: return canGoForward
        case .liveTimeline: return snapshot != nil && hasSessionReader
        case .follow: return snapshot != nil && hasSessionReader
        case .clearFilters: return section == .agents ? !agentQuery.isEmpty : !query.isEmpty || agentFilter != nil || environmentFilter != nil || resourceFilter != nil || kindFilter != nil || period != nil || originInstructionFilter != nil
        case .copyLink: return deepLink(for: target) != nil
        case .investigate: return (target ?? selection) != nil && !investigation.sending && !investigation.preparing
        case .bookmark, .provenance: return (target ?? selection) != nil && snapshot != nil
        case .revealInFinder: return finderLocation(for: target ?? selection) != nil
        case .exportInvestigation: return investigation.capsule != nil && !investigation.preparing && !investigation.sending
        case .conversation: return snapshot != nil && !showSessionPicker && !showConversation
        case .openInNewWindow:
            return isObserving && hasSessionReader && snapshot != nil && observedSourceHome.isFileURL
                && deepLink(for: target ?? selection) != nil
                && LensApplicationCoordinator.shared.newWindowHandler != nil
        case .largerText: return fontSize < 24
        case .smallerText: return fontSize > 10
        default: return true
        }
    }
    private func knownCommandDestination(_ destination: Destination?) -> Bool {
        guard let destination, let snapshot else { return false }
        switch destination {
        case .event(let id): return event(id) != nil
        case .change(let id): return change(id) != nil
        case .agent(let id): return presentation?.agentsByID[id] != nil
        case .environment(let id), .file(let id, _, _, _): return snapshot.environments.contains { $0.id == id }
        case .resource(let id): return snapshot.resources.contains { $0.id == id }
        case .investigation: return true
        case .evidence(let id, let piece): return [inspectedEvidenceCapsule, investigation.capsule].compactMap { $0 }.contains { $0.rootThreadID == snapshot.root.id && $0.id == id && $0.pieces.contains { $0.id == piece } }
        }
    }
    func perform(_ action: LensAction, target: Destination? = nil) {
        guard canPerform(action, target: target) else { return }
        switch action {
        case .openSession: showConversation = false; showSessionPicker = true
        case .back: goBack()
        case .forward: goForward()
        case .liveTimeline: if liveTimelineVisible { disableLiveTimeline() } else { enableLiveTimeline() }
        case .follow: if follow { toggleFollow() } else { present() }
        case .clearFilters: if section == .agents { agentQuery = "" } else { resetFilters() }
        case .copyLink: if let url = deepLink(for: target) { copyLocalText(url.absoluteString, notice: LensL10n.text("Lien interne copié")) }
        case .inspector: if chatVisible { inspectorVisible = true } else { inspectorVisible.toggle() }
        case .chat: toggleChat()
        case .investigate:
            prepareQuestion(for: target ?? selection)
        case .bookmark: bookmarkSelection(for: target)
        case .largerText: fontSize = min(24, fontSize + readingPreferences.configuration.textStep)
        case .smallerText: fontSize = max(10, fontSize - readingPreferences.configuration.textStep)
        case .provenance: if let target = target ?? selection { navigate(target) }; inspectorVisible = true
        case .revealInFinder, .exportInvestigation, .importArchive: break // Native window operations use LensCommandTarget.
        case .conversation: showConversation = true
        case .openInNewTab: if let destination = target ?? selection { navigate(destination, newTab: true) }
        case .openInNewWindow:
            if let destination = target ?? selection {
                LensApplicationCoordinator.shared.openInNewWindow(destination: destination, from: self)
            }
        }
    }
}
struct LensActionButton: View {
    @ObservedObject var store: LensStore
    let action: LensAction
    var target: Destination? = nil
    @Environment(\.lensWindowContext) private var context
    var body: some View {
        Group {
            if let context { LensWindowActionButton(store: store, context: context, action: action, target: target) }
            else { Button { store.perform(action, target: target) } label: { Label(action.title(in: store, target: target), systemImage: LensSymbols.name(action.symbol(in: store, target: target))) }.disabled(!store.canPerform(action, target: target)) }
        }
            .symbolRenderingMode(.monochrome)
            .help(action == .follow && !store.hasSessionReader ? LensL10n.text("Le suivi nécessite des journaux accessibles. Une archive ne contient que l’historique.") : action == .investigate ? LensL10n.text("Ajoute la sélection au brouillon du chat sans l’envoyer.") : action.title(in: store, target: target))
    }
}
private struct LensWindowActionButton: View {
    @ObservedObject var store: LensStore
    @ObservedObject var context: LensWindowContext
    let action: LensAction
    let target: Destination?
    var body: some View {
        // Explicit row/menu targets retain the window, root and source that
        // supplied them. Toolbar commands continue to use the current selection.
        let prepared = target != nil && action.scope == .selection ? context.capture(action, destination: target) : nil
        Button { (prepared ?? context.capture(action, destination: target)).execute() } label: { Label(action.title(in: store, target: target), systemImage: LensSymbols.name(action.symbol(in: store, target: target))) }
            .disabled(!store.canPerform(action, target: target) || context.operationBusy)
    }
}
private struct LensWindowStoreKey: FocusedValueKey { typealias Value = LensStore }
private struct LensSidebarVisibilityKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct LensSearchActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var lensWindowStore: LensStore? { get { self[LensWindowStoreKey.self] } set { self[LensWindowStoreKey.self] = newValue } }
    var lensSidebarVisibility: Binding<Bool>? { get { self[LensSidebarVisibilityKey.self] } set { self[LensSidebarVisibilityKey.self] = newValue } }
    var lensSearchAction: (() -> Void)? { get { self[LensSearchActionKey.self] } set { self[LensSearchActionKey.self] = newValue } }
}
/// A sheet owns its search and text responder; it must never search the session behind it.
@MainActor struct LensFindCommandTarget {
    let window: NSWindow?
    let context: LensWindowContext?
    let search: (() -> Void)?
    private var text: NSTextView? {
        guard context == nil, search != nil, let text = window?.firstResponder as? NSTextView,
              !text.isFieldEditor else { return nil }
        return text
    }
    var canFind: Bool { context != nil || search != nil }
    var canFindNext: Bool { context?.canFindNext ?? (text != nil) }
    func perform(_ action: NSTextFinder.Action) {
        if let context { context.find(action) }
        else if let text {
            let item = NSMenuItem(); item.tag = action.rawValue
            text.performTextFinderAction(item)
        } else if action == .showFindInterface { search?() }
    }
}

struct LensCommands: Commands {
    @AppStorage("lens.language") private var language = "en"
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var application = LensApplicationCoordinator.shared
    @State private var updater = LensUpdateController.shared
    @FocusedValue(\.lensSearchAction) private var focusedSearch
    private var context: LensWindowContext? { application.context(for: NSApp.keyWindow) }
    private var store: LensStore? { context?.store }
    private var findTarget: LensFindCommandTarget { LensFindCommandTarget(window: NSApp.keyWindow, context: context, search: focusedSearch) }
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(LensL10n.text("À propos de Codex Lens")) {
                NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Codex Lens", .credits: NSAttributedString(string: LensL10n.text("Inspection locale des sessions Codex. Sources en lecture seule.\nLes enquêtes restent distinctes des traces observées."))])
            }
            Button(LensL10n.text("Rechercher des mises à jour…")) { updater.check() }
                .disabled(!updater.canCheck || application.maintenanceInProgress)
        }
        CommandGroup(replacing: .newItem) {
            Button(LensGlobalAction.newWindow.title) { LensGlobalAction.newWindow.perform(newWindow: { openWindow(id: "session", value: UUID()) }) }.keyboardShortcut("n").disabled(application.maintenanceInProgress)
            Button(LensGlobalAction.openSession.title) { LensGlobalAction.openSession.perform(focusedStore: store, newWindow: { openWindow(id: "session", value: UUID()) }) }.keyboardShortcut("o").disabled(application.maintenanceInProgress)
            command(.openInNewWindow)
            Menu(LensL10n.text("Ouvrir une session récente")) {
                if application.recentIDs.isEmpty { Button(LensL10n.text("Aucune session récente")) {}.disabled(true) }
                ForEach(application.recentIDs, id: \.self) { id in
                    Button(application.recentTitle(for: id)) { if let store { Task { await store.open(id) } } else { application.openSession(id) } }
                        .help(id).accessibilityLabel(application.recentTitle(for: id) + " · " + id)
                }
                Divider(); Button(LensL10n.text("Effacer le menu")) { application.clearRecents() }.disabled(application.recentIDs.isEmpty)
            }.disabled(application.maintenanceInProgress)
        }
        // Apple's saveItem group owns Close as well as document saves. Lens
        // owns no editable source document, so supply its real tab/window
        // operations here instead of retargeting SwiftUI's generated item.
        CommandGroup(replacing: .saveItem) {
            Button(context?.store.activeTab != nil ? LensL10n.text("Fermer l’onglet") : LensL10n.text("Fermer la fenêtre")) {
                if let context { context.closeTabOrWindow() } else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w").disabled(NSApp.keyWindow == nil)
            Button(LensL10n.text("Fermer la fenêtre et ses onglets")) { application.closeWindow(NSApp.keyWindow) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(NSApp.keyWindow == nil)
            Button(LensL10n.text("Fermer toutes les fenêtres")) {
                application.closeAllWindows()
            }.keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(!NSApp.windows.contains { $0.styleMask.contains(.closable) && ($0.isVisible || $0.isMiniaturized) })
        }
        CommandGroup(after: .importExport) {
            Divider()
            command(.importArchive)
            command(.exportInvestigation)
            command(.conversation).keyboardShortcut("e", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Divider()
            command(.copyLink).keyboardShortcut("c", modifiers: [.command, .shift])
            Menu(LensL10n.text("Rechercher")) {
                Button(LensL10n.text("Rechercher…")) { findTarget.perform(.showFindInterface) }.keyboardShortcut("f").disabled(!findTarget.canFind)
                Button(LensL10n.text("Rechercher le suivant")) { findTarget.perform(.nextMatch) }.keyboardShortcut("g").disabled(!findTarget.canFindNext)
                Button(LensL10n.text("Rechercher le précédent")) { findTarget.perform(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!findTarget.canFindNext)
                Divider()
                Button(LensL10n.text("Rechercher dans la session…")) { context?.searchSession?() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(store?.snapshot == nil)
            }
        }
        CommandGroup(after: .sidebar) {
            Button(context?.window?.toolbar?.isVisible == false ? LensL10n.text("Afficher la barre d’outils") : LensL10n.text("Masquer la barre d’outils")) {
                context?.window?.toggleToolbarShown(nil)
                context?.objectWillChange.send()
            }.keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(context?.window?.toolbar == nil || context?.operationBusy == true || context?.window?.toolbar?.customizationPaletteIsRunning == true)
            Button(LensL10n.text("Personnaliser la barre d’outils…")) { context?.window?.runToolbarCustomizationPalette(nil) }
                .disabled(context?.window?.toolbar?.allowsUserCustomization != true || context?.operationBusy == true || context?.window?.attachedSheet != nil || context?.window?.toolbar?.customizationPaletteIsRunning == true)
            Divider()
            Button(context?.sidebarVisibility?.wrappedValue == false ? LensL10n.text("Afficher la navigation") : LensL10n.text("Masquer la navigation")) { context?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control]).disabled(context?.sidebarVisibility == nil)
            command(.inspector).keyboardShortcut("i", modifiers: [.command, .option])
            command(.chat).keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            Button(LensL10n.text("Élargir le panneau actif")) { context?.resizeActivePane(by: 24) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(context?.canResizeActivePane != true)
            Button(LensL10n.text("Réduire le panneau actif")) { context?.resizeActivePane(by: -24) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(context?.canResizeActivePane != true)
            Divider()
            zoomCommand(.increase, title: "Zoom avant").keyboardShortcut("+", modifiers: [.command])
            zoomCommand(.decrease, title: "Zoom arrière").keyboardShortcut("-", modifiers: [.command])
            zoomCommand(.reset, title: "Réinitialiser le zoom").keyboardShortcut("0", modifiers: [.command])
        }
        CommandMenu(LensL10n.text("Navigation")) {
            command(.back).keyboardShortcut("[")
            command(.forward).keyboardShortcut("]")
            Divider()
            Menu(LensL10n.text("Aller à")) {
                ForEach(LensSection.allCases) { section in
                    Toggle(isOn: Binding(get: { section == .investigation ? store?.chatVisible == true : store?.section == section }, set: { selected in if selected { store?.browseSection(section) } })) {
                        Label(section == .investigation ? LensL10n.text("Chat d’enquête") : LensL10n.display(section.rawValue), systemImage: LensSymbols.name(section.symbol))
                    }.keyboardShortcut(KeyEquivalent(Character(String((LensSection.allCases.firstIndex(of: section) ?? 0) + 1))))
                        .disabled(store?.snapshot == nil || context?.operationBusy == true)
                }
            }
            Menu(LensL10n.text("Placer le focus")) {
                ForEach(LensPaneRegion.allCases, id: \.self) { region in
                    Button(region.title) { context?.focusPane(region) }
                        .keyboardShortcut(KeyEquivalent(Character(String((LensPaneRegion.allCases.firstIndex(of: region) ?? 0) + 1))), modifiers: [.command, .option])
                        .disabled(context?.canFocusPanes != true)
                }
            }
            command(.liveTimeline).keyboardShortcut("l", modifiers: [.command, .option])
            command(.follow).keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            command(.clearFilters).keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu(LensL10n.text("Enquête")) {
            command(.investigate).keyboardShortcut("e", modifiers: [.command, .shift])
            command(.bookmark).keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            command(.provenance)
            command(.revealInFinder)
        }
        CommandGroup(before: .windowArrangement) {
            Button(LensL10n.text("Onglet précédent")) { context?.cycleTab(forward: false) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(context?.canCycleTabs != true)
            Button(LensL10n.text("Onglet suivant")) { context?.cycleTab(forward: true) }
                .keyboardShortcut(.tab, modifiers: [.control]).disabled(context?.canCycleTabs != true)
            Menu(LensL10n.text("Onglets de la fenêtre")) {
                if let store, store.hasWorkspaceReturn {
                    Toggle(LensL10n.display(store.workspaceSection.rawValue), isOn: Binding(get: { store.workspacePresented }, set: { selected in if selected { store.showWorkspace() } }))
                        .disabled(context?.operationBusy == true)
                }
                if store?.tabs.isEmpty != false { Button(LensL10n.text("Aucun onglet ouvert")) {}.disabled(true) }
                ForEach(store?.tabs ?? []) { tab in
                    Toggle(store?.label(tab.destination) ?? "", isOn: Binding(get: { store?.isTabPresented(tab) == true }, set: { selected in if selected { store?.selectTab(tab) } }))
                        .disabled(context?.operationBusy == true)
                }
            }.disabled(context == nil)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button(LensL10n.text("Aide Codex Lens")) { LensGuideCoordinator.shared.showHelp(); openSettings() }
            Button(LensL10n.text("Revoir les premiers pas")) { LensGuideCoordinator.shared.showHelp(replay: true); openSettings() }
            Divider()
            Menu(LensL10n.text("Développement")) {
                Button(LensL10n.text("Galerie des composants")) { openWindow(id: "components") }
            }
        }
    }
    private func command(_ action: LensAction) -> some View {
        Button(store.map { action.title(in: $0) } ?? fallbackTitle(action)) { context?.capture(action).execute() }.disabled(store?.canPerform(action) != true || context?.operationBusy == true)
    }
    private func zoomCommand(_ action: LensZoomAction, title: String) -> some View {
        // The responder is resolved at execution, including a focus change while
        // the menu is open. Boundaries are enforced by the same action handler.
        Button(LensL10n.text(title)) { context?.adjustZoom(action) }.disabled(context == nil || context?.operationBusy == true)
    }
    private func fallbackTitle(_ action: LensAction) -> String {
        switch action {
        case .openInNewTab: return LensL10n.text("Ouvrir dans un onglet")
        case .openSession: return LensL10n.text("Ouvrir une session…")
        case .back: return LensL10n.text("Précédent")
        case .forward: return LensL10n.text("Suivant")
        case .liveTimeline: return LensL10n.text("Afficher le direct")
        case .follow: return LensL10n.text("Suspendre le suivi visuel")
        case .clearFilters: return LensL10n.text("Réinitialiser les filtres")
        case .copyLink: return LensL10n.text("Copier le lien interne")
        case .inspector: return LensL10n.text("Afficher l’inspecteur")
        case .chat: return LensL10n.text("Afficher le chat d’enquête")
        case .investigate: return LensL10n.text("Demander à l’IA…")
        case .bookmark: return LensL10n.text("Ajouter ou retirer un signet")
        case .largerText: return LensL10n.text("Agrandir le texte")
        case .smallerText: return LensL10n.text("Réduire le texte")
        case .provenance: return LensL10n.text("Afficher la provenance")
        case .revealInFinder: return LensL10n.text("Afficher l’emplacement actuel dans le Finder")
        case .exportInvestigation: return LensL10n.text("Exporter l’enquête…")
        case .importArchive: return LensL10n.text("Importer une archive d’enquête…")
        case .conversation: return LensL10n.text("Conversation et orientations…")
        case .openInNewWindow: return LensL10n.text("Ouvrir dans une nouvelle fenêtre")
        }
    }
}
