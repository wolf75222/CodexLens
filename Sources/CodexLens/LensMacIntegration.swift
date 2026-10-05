import SwiftUI
import AppKit
import LensCore
import UniformTypeIdentifiers
import Combine

enum LensCommandScope { case global, window, selection }
enum LensGlobalAction: String, CaseIterable, Identifiable {
    case newWindow, openSession
    var id: String { rawValue }
    var scope: LensCommandScope { .global }
    var title: String { self == .newWindow ? LensL10n.text("Nouvelle fenêtre") : LensL10n.text("Ouvrir une session…") }
    @MainActor func perform(focusedStore: LensStore? = nil, newWindow: (() -> Void)? = nil) {
        switch self {
        case .newWindow: if let newWindow { newWindow() } else { LensApplicationCoordinator.shared.newWindow() }
        case .openSession:
            if let focusedStore, focusedStore.isObserving { focusedStore.perform(.openSession) }
            else if let newWindow { newWindow() }
            else { LensApplicationCoordinator.shared.openSession() }
        }
    }
}

/// A command retains its original window/root/selection across asynchronous work.
/// Focus changes never retarget a prepared command.
@MainActor struct LensCommandTarget {
    weak var context: LensWindowContext?
    let action: LensAction
    let windowID: String
    let rootID: String?
    let destination: Destination?
    var id: String { action.id }
    var title: String { guard let context else { return action.rawValue }; return action.title(in: context.store, target: destination) }
    var checked: Bool? {
        guard let context else { return nil }
        switch action {
        case .liveTimeline: return context.store.liveTimelineVisible
        case .follow: return context.store.follow
        case .inspector: return context.store.inspectorVisible && !context.store.chatVisible
        case .chat: return context.store.chatVisible
        case .bookmark: return context.store.bookmarks.contains { $0.rootID == rootID && $0.destination == destination }
        default: return nil
        }
    }
    var isValid: Bool {
        guard let context, context.store.isObserving, context.store.windowIdentity == windowID,
              context.store.snapshot?.root.id == rootID else { return false }
        return context.store.canPerform(action, target: destination) && !context.operationBusy
    }
    func execute() {
        guard isValid, let context else { return }
        switch action {
        case .chat:
            if context.store.chatVisible, let window = context.window,
               context.paneKeyboard.activeRegion(in: window) == .chat {
                context.focusPane(.content, afterLayout: true)
            }
            context.store.perform(action, target: destination)
        case .inspector:
            if context.store.inspectorVisible, let window = context.window,
               context.paneKeyboard.activeRegion(in: window) == .inspector {
                context.focusPane(.content, afterLayout: true)
            }
            context.store.perform(action, target: destination)
            if context.store.inspectorVisible, !context.store.chatVisible { context.focusPane(.inspector, afterLayout: true) }
        case .revealInFinder: context.reveal(self)
        case .exportInvestigation: context.exportArchive(self)
        case .importArchive: context.importArchive(self)
        default: context.store.perform(action, target: destination)
        }
    }
}

@MainActor final class LensWindowContext: ObservableObject {
    let paneKeyboard = LensPaneKeyboardController()
    private var paneFocusTask: Task<Void, Never>?
    var paneWidths: [String: CGFloat] = [:]
    var paneHeights: [String: CGFloat] = [:]
    var recordedVersionPresentations: [String: FileVersionPresentation] = [:]
    let store: LensStore
    let sceneRequestID: UUID?
    weak var window: NSWindow?
    @Published private(set) var operationBusy = false
    private var operation: Task<Void, Never>?
    private var operationIdentity = UUID()
    private var panel: NSSavePanel?
    private var observers: [NSObjectProtocol] = []
    private var gestureMonitor: Any?
    private var attachedIdentity: String?
    init(store: LensStore, sceneRequestID: UUID? = nil) { self.store = store; self.sceneRequestID = sceneRequestID }
    func capture(_ action: LensAction, destination: Destination? = nil) -> LensCommandTarget {
        LensCommandTarget(context: self, action: action, windowID: store.windowIdentity,
                          rootID: store.snapshot?.root.id, destination: destination ?? store.selection)
    }
    func attach(_ window: NSWindow) {
        guard self.window !== window || attachedIdentity != store.windowIdentity else { return }
        detachObservers(); self.window = window
        attachedIdentity = store.windowIdentity
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Lens already owns evidence tabs and their history. A second native
        // NSWindow tab strip would expose two unrelated meanings of “tab”.
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("Lens-" + store.windowIdentity)
        LensApplicationCoordinator.shared.register(self)
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .keyDown]) { [weak self, weak window] event in
            guard let self, let window, event.window === window, !self.hasMarkedText else { return event }
            if event.type == .keyDown { return self.handleZoomShortcut(event) ? nil : event }
            guard abs(event.deltaX) > abs(event.deltaY), event.deltaX != 0 else { return event }
            if event.deltaX > 0, self.store.canGoBack { self.store.goBack(); return nil }
            if event.deltaX < 0, self.store.canGoForward { self.store.goForward(); return nil }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notice in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notice.name == NSWindow.willCloseNotification { self.close() }
                    else { LensApplicationCoordinator.shared.activated(self) }
                }
            })
        }
    }
    func detachObservers() { if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor); self.gestureMonitor = nil }; for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll() }
    func close() {
        paneFocusTask?.cancel(); paneFocusTask = nil
        cancelOperation(); searchSession = nil; searchCurrentView = nil; sidebarVisibility = nil; store.stopObserving()
        let investigation = store.investigation
        LensApplicationCoordinator.shared.flushClosedInvestigation(investigation)
        LensApplicationCoordinator.shared.unregister(self); detachObservers(); window = nil
    }
    func cancelOperation() {
        operationIdentity = UUID()
        operation?.cancel(); panel?.cancel(nil); operation = nil; panel = nil; operationBusy = false
    }
    private func beginOperation() -> UUID {
        let identity = UUID(); operationIdentity = identity; operationBusy = true
        return identity
    }
    private func finishOperation(_ identity: UUID) {
        guard identity == operationIdentity else { return }
        operationBusy = false; operation = nil; panel = nil
    }
    private func acceptsOperation(_ identity: UUID, target: LensCommandTarget, checkRoot: Bool = true) -> Bool {
        identity == operationIdentity && !Task.isCancelled && store.isObserving && store.windowIdentity == target.windowID &&
        (!checkRoot || store.snapshot?.root.id == target.rootID)
    }
    func closeTabOrWindow() {
        if let id = store.activeTab { store.closeTab(id) } else { window?.performClose(nil) }
    }
    var canCycleTabs: Bool { store.isObserving && !operationBusy && store.tabs.count > 1 }
    func cycleTab(forward: Bool) {
        guard canCycleTabs else { return }
        let tabs = store.tabs
        let index = store.activeTab.flatMap { id in tabs.firstIndex { $0.id == id } }
        let next = forward ? ((index ?? -1) + 1) % tabs.count : ((index ?? 0) + tabs.count - 1) % tabs.count
        store.selectTab(tabs[next])
    }
    func find(_ action: NSTextFinder.Action) {
        guard let window else { return }
        if action == .showFindInterface, store.tabContentDestination != nil,
           (window.firstResponder as? NSTextView)?.isFieldEditor != false,
           let pane = paneKeyboard.view(for: .content) {
            var queue = [pane], index = 0
            while index < queue.count {
                let view = queue[index]; index += 1
                guard !view.isHiddenOrHasHiddenAncestor else { continue }
                if let text = view as? NSTextView, !text.isFieldEditor, text.isSelectable,
                   window.makeFirstResponder(text) { break }
                queue.append(contentsOf: view.subviews)
            }
        }
        if let text = window.firstResponder as? NSTextView, !text.isFieldEditor {
            let item = NSMenuItem(); item.tag = action.rawValue
            text.performTextFinderAction(item)
        } else if action == .showFindInterface { searchCurrentView?() }
        else if !store.query.isEmpty, !store.events.isEmpty {
            let events = store.events
            let current = store.selectedEvent.flatMap { selected in events.firstIndex { $0.id == selected.id } }
            let index = action == .previousMatch ? ((current ?? 0) + events.count - 1) % events.count : ((current ?? -1) + 1) % events.count
            store.navigate(.event(events[index].id))
        }
    }
    var canFindNext: Bool { (window?.firstResponder as? NSTextView).map { !$0.isFieldEditor } == true || (!store.query.isEmpty && !store.events.isEmpty) }
    var searchCurrentView: (() -> Void)?
    var searchSession: (() -> Void)?
    var sidebarVisibility: Binding<Bool>?
    func toggleSidebar() {
        if sidebarVisibility?.wrappedValue == true, let window,
           paneKeyboard.activeRegion(in: window) == .navigation { focusPane(.content, afterLayout: true) }
        sidebarVisibility?.wrappedValue.toggle(); objectWillChange.send()
    }
    var canFocusPanes: Bool { store.isObserving && !operationBusy && window != nil && window?.attachedSheet == nil }
    func focusPane(_ region: LensPaneRegion, afterLayout: Bool = false) {
        guard canFocusPanes, let window else { return }
        paneFocusTask?.cancel()
        if region == .navigation, sidebarVisibility?.wrappedValue != true { sidebarVisibility?.wrappedValue = true }
        if region == .inspector, !store.inspectorVisible || store.chatVisible { store.inspectorVisible = true }
        if region == .chat, !store.chatVisible { store.showChat() }
        // Native focus changes command availability, not the content environment.
        // Publishing this window context also rebuilds the hosting root while
        // AppKit is measuring its nested split views. Refresh the menus only.
        if !afterLayout, paneKeyboard.focus(region, in: window) { LensApplicationCoordinator.shared.objectWillChange.send(); return }
        // A hidden pane needs one layout pass to remount. Cancel this request
        // on another request, window closure or a switch to a different window.
        paneFocusTask = Task { @MainActor [weak self, weak window] in
            if afterLayout { try? await Task.sleep(for: .milliseconds(30)) }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled, let self, let window, self.window === window,
                      NSApp.keyWindow === window, self.canFocusPanes else { return }
                if self.paneKeyboard.focus(region, in: window) { LensApplicationCoordinator.shared.objectWillChange.send(); return }
            }
        }
    }
    var canResizeActivePane: Bool {
        canFocusPanes && window.flatMap { paneKeyboard.activeRegion(in: $0) } != nil
    }
    func resizeActivePane(by delta: CGFloat) {
        guard canFocusPanes else { return }
        paneKeyboard.resizeActive(by: delta, in: window)
    }
    var hasMarkedText: Bool { (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true }

    func reveal(_ target: LensCommandTarget) {
        guard let path = store.finderLocation(for: target.destination) else { return }
        let identity = beginOperation()
        operation = Task { [weak self] in
            let available = await Task.detached(priority: .userInitiated) { () -> Bool in
                let fm = FileManager.default
                var directory: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &directory) && fm.isReadableFile(atPath: path)
            }.value
            guard let self else { return }; defer { self.finishOperation(identity) }
            guard self.acceptsOperation(identity, target: target) else { return }
            if available { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            else { self.store.error = LensL10n.text("Emplacement actuel indisponible : {0}. La référence historique est conservée ; aucun autre worktree n’est substitué.", String(describing: path)) }
        }
    }
    private func transfer() -> LensArchiveTransfer {
        let roots = store.snapshot?.environments.map { URL(fileURLWithPath: $0.path) } ?? []
        return LensArchiveTransfer(archive: store.investigation.archive, protectedSourceRoots: roots, codexDirectories: [store.observedSourceHome])
    }
    func exportArchive(_ target: LensCommandTarget) {
        guard let window, let capsule = store.investigation.capsule else { return }
        // Copy values now, before the panel is opened or the draft can change.
        let question = store.investigation.question, response = store.investigation.response
        let recordID = store.investigation.recordID, transfer = transfer()
        let identity = beginOperation()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finishOperation(identity) }
            do {
                let persisted: InvestigationRecord?
                if let recordID { persisted = try? await self.store.investigation.archive.load(id: recordID) } else { persisted = nil }
                let frozen: LensArchiveEnvelope
                if let persisted, persisted.capsule.representsSameFrozenContent(as: capsule), persisted.question == question, persisted.response == response {
                    frozen = try await transfer.freeze(record: persisted)
                } else { frozen = try await transfer.freeze(capsule: capsule, question: question, response: response, recordID: recordID) }
                try Task.checkCancellation()
                guard self.acceptsOperation(identity, target: target) else { return }
                let panel = NSSavePanel(); self.panel = panel
                panel.allowedContentTypes = [.lensInvestigation]; panel.canCreateDirectories = true
                panel.nameFieldStringValue = "Enquete-" + String(capsule.rootThreadID.prefix(8)) + ".codexlens"
                panel.title = LensL10n.text("Exporter l’enquête")
                panel.message = LensL10n.text("Session {0} · {1} éléments, question et réponse affichés. L’archive peut contenir du code et des conversations. Les fichiers actuels ne sont pas joints.", String(describing: capsule.rootThreadID), String(describing: capsule.pieces.count))
                let result = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
                guard result == .OK, let destination = panel.url else { return }
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation()
                guard self.acceptsOperation(identity, target: target) else { return }
                _ = try await transfer.export(envelope: frozen, to: destination, replaceExisting: true)
                guard self.acceptsOperation(identity, target: target) else { return }
                self.store.investigation.notice = LensL10n.text("Enquête exportée : {0}", String(describing: destination.path))
            } catch is CancellationError { }
            catch { if self.acceptsOperation(identity, target: target) { self.store.error = error.localizedDescription } }
        }
    }
    func importArchive(_ target: LensCommandTarget) {
        guard let window else { return }
        let transfer = transfer()
        let panel = NSOpenPanel(); self.panel = panel
        panel.allowedContentTypes = [.lensInvestigation, .json]; panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.title = LensL10n.text("Importer une archive d’enquête")
        panel.message = LensL10n.text("Archive Lens version 1. L’import crée une enquête distincte sans reprendre la session Codex.")
        let identity = beginOperation()
        operation = Task { [weak self] in
            guard let self else { return }; defer { self.finishOperation(identity) }
            guard self.acceptsOperation(identity, target: target) else { return }
            let result = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            guard result == .OK, let source = panel.url else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                try Task.checkCancellation()
                let frozen = try await transfer.inspectImport(from: source)
                try Task.checkCancellation()
                guard self.acceptsOperation(identity, target: target) else { return }
                let result = try await transfer.import(envelope: frozen)
                guard self.acceptsOperation(identity, target: target) else { return }
                let root = result.record.capsule.rootThreadID
                // The imported evidence can be explored even when original logs disappeared.
                guard var opening = await self.store.openImportedRoot(root), self.acceptsOperation(identity, target: target, checkRoot: false), self.store.acceptsImportedOpening(opening) else { return }
                if self.store.snapshot?.root.id != root { self.store.showArchiveOnlyRoot(root); self.store.error = nil }
                opening = self.store.openingIdentity
                await self.store.investigation.loadArchive(rootID: root)
                guard self.acceptsOperation(identity, target: target, checkRoot: false), self.store.acceptsImportedOpening(opening, rootID: root) else { return }
                await self.store.investigation.openRecord(result.record.id)
                guard self.acceptsOperation(identity, target: target, checkRoot: false), self.store.acceptsImportedOpening(opening, rootID: root) else { return }
                self.store.navigate(.investigation(result.record.id), newTab: true)
                self.store.investigation.notice = LensL10n.text("Archive importée. Les chemins référencés ne sont pas ouverts automatiquement.")
            } catch is CancellationError { }
            catch { if self.acceptsOperation(identity, target: target) { self.store.error = error.localizedDescription } }
        }
    }
}

extension LensStore {
    /// Lexical paths keep two same-named worktree files distinct. Finder is explicitly CURRENT.
    func finderLocation(for destination: Destination?) -> String? {
        guard let snapshot, let destination else { return nil }
        switch destination {
        case .environment(let id): return snapshot.environments.first { $0.id == id }?.path
        case .file(let environment, let path, _, _):
            guard snapshot.environments.contains(where: { $0.id == environment }) else { return nil }
            return path.hasPrefix("/") ? path : URL(fileURLWithPath: environment).appendingPathComponent(path).standardizedFileURL.path
        case .change(let id):
            guard let change = change(id), snapshot.environments.contains(where: { $0.id == change.environmentID }) else { return nil }
            return change.path.hasPrefix("/") ? change.path : URL(fileURLWithPath: change.environmentID).appendingPathComponent(change.path).standardizedFileURL.path
        case .resource(let id): return snapshot.resources.first { $0.id == id && $0.location.hasPrefix("/") }?.location
        default: return nil
        }
    }
    var safeWindowTitle: String {
        guard let snapshot else { return LensL10n.text("Codex Lens — Ouvrir une session") }
        let project = snapshot.environments.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? LensL10n.text("Session")
        return LensL10n.text("Codex Lens — {0} · {1}", String(describing: snapshot.root.id.prefix(8)), String(describing: project))
    }
}

private struct LensContextEnvironmentKey: EnvironmentKey { static let defaultValue: LensWindowContext? = nil }
private struct LensContextFocusKey: FocusedValueKey { typealias Value = LensWindowContext }
extension EnvironmentValues { var lensWindowContext: LensWindowContext? { get { self[LensContextEnvironmentKey.self] } set { self[LensContextEnvironmentKey.self] = newValue } } }
extension FocusedValues { var lensWindowContext: LensWindowContext? { get { self[LensContextFocusKey.self] } set { self[LensContextFocusKey.self] = newValue } } }
extension UTType { static let lensInvestigation = UTType(exportedAs: "fr.codexlens.investigation", conformingTo: .json) }
struct LensWindowOperationControls: View {
    @ObservedObject var context: LensWindowContext
    var body: some View {
        if context.operationBusy { LensProgressIndicator(accessibilityLabel: LensL10n.text("Opération locale en cours")).controlSize(.small); Button(LensL10n.text("Annuler l’opération")) { context.cancelOperation() } }
    }
}

struct LensWindowProbe: NSViewRepresentable {
    let context: LensWindowContext
    func makeNSView(context: Context) -> View { let view = View(); view.owner = self.context; return view }
    func updateNSView(_ view: View, context: Context) { view.owner = self.context; if let window = view.window { self.context.attach(window) } }
    final class View: NSView {
        weak var owner: LensWindowContext?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { owner?.attach(window) } }
    }
}

@MainActor final class LensApplicationCoordinator: ObservableObject {
    static let shared = LensApplicationCoordinator()
    var newWindowHandler: ((UUID) -> Void)?
    private final class Entry { weak var context: LensWindowContext?; init(_ context: LensWindowContext) { self.context = context } }
    private var windows: [Entry] = []
    private var closingFlushes: [UUID: Task<Void, Never>] = [:]
    private weak var commandOwner: LensWindowContext?
    private var commandSubscriptions: Set<AnyCancellable> = []
    private var focusObservers: [NSObjectProtocol] = []
    private init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCommandFocus() }
            })
        }
    }
    @Published private(set) var recentIDs = (UserDefaults.standard.stringArray(forKey: "lensRecentSessionIDs") ?? []).filter { UUID(uuidString: $0) != nil }.prefix(12).map { $0 }
    @Published private(set) var recentTitles = UserDefaults.standard.dictionary(forKey: "lensRecentSessionTitles") as? [String: String] ?? [:]
    func register(_ context: LensWindowContext) {
        windows.removeAll { $0.context == nil || $0.context === context }; windows.append(Entry(context))
        // The NSView probe can attach while SwiftUI is updating its view tree.
        Task { [weak self] in self?.refreshCommandFocus() }
    }
    func unregister(_ context: LensWindowContext) {
        windows.removeAll { $0.context == nil || $0.context === context }
        openingRecentSessions[ObjectIdentifier(context)] = nil
        if let requestID = context.sceneRequestID { pendingSessionIDs[requestID] = nil }
        refreshCommandFocus()
    }
    func activated(_ context: LensWindowContext) { register(context) }
    func context(for window: NSWindow?) -> LensWindowContext? { windows.compactMap(\.context).first { $0.window === window && window != nil } }
    /// AppKit's key window is authoritative, including auxiliary windows and no-window state.
    /// Only the focused window forwards state to the small command hierarchy.
    private func refreshCommandFocus() {
        let next = context(for: NSApp.keyWindow)
        if commandOwner !== next {
            commandSubscriptions.removeAll(); commandOwner = next
            if let next {
                let publishers = [next.objectWillChange, next.store.objectWillChange, next.store.investigation.objectWillChange]
                for publisher in publishers {
                    publisher.sink { [weak self] _ in
                        MainActor.assumeIsolated { self?.objectWillChange.send() }
                    }.store(in: &commandSubscriptions)
                }
            }
        }
        objectWillChange.send()
    }
    func remember(_ id: String) {
        guard UUID(uuidString: id) != nil, recentIDs.first != id else { return }
        recentIDs = [id] + recentIDs.filter { $0 != id }; recentIDs = Array(recentIDs.prefix(12))
        UserDefaults.standard.set(recentIDs, forKey: "lensRecentSessionIDs")
        pruneRecentTitles()
    }
    func remember(_ summary: SessionSummary) {
        guard UUID(uuidString: summary.id) != nil else { return }
        remember(summary.id)
        let title = summary.title.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(title.prefix(96))
        if recentTitles[summary.id] != (bounded.isEmpty ? nil : bounded) {
            recentTitles[summary.id] = bounded.isEmpty ? nil : bounded
            pruneRecentTitles()
        }
    }
    func recentTitle(for id: String) -> String {
        let short = String(id.prefix(8))
        let identifier = recentIDs.count(where: { $0.hasPrefix(short) }) > 1 ? id : short
        if let title = recentTitles[id], !title.isEmpty, title != "Session " + short { return title + " · " + identifier }
        return LensL10n.text("Session {0}", identifier)
    }
    private func pruneRecentTitles() {
        recentTitles = recentTitles.filter { recentIDs.contains($0.key) }
        UserDefaults.standard.set(recentTitles, forKey: "lensRecentSessionTitles")
    }
    func clearRecents() {
        recentIDs = []; recentTitles = [:]
        UserDefaults.standard.removeObject(forKey: "lensRecentSessionIDs")
        UserDefaults.standard.removeObject(forKey: "lensRecentSessionTitles")
    }
    func newWindow(requestID: UUID = UUID()) {
        NSApp.unhide(nil)
        newWindowHandler?(requestID)
        NSApp.activate(ignoringOtherApps: true)
    }
    func closeWindow(_ candidate: NSWindow?) {
        guard let window = candidate?.sheetParent ?? candidate else { return }
        let context = context(for: window)
        context?.cancelOperation()
        context?.store.showSessionPicker = false
        if let sheet = window.attachedSheet {
            // performClose refuses a parent with an attached modal sheet.
            // Cancel only its own picker/operation, let SwiftUI detach it, and
            // retain the ordinary close notifications and draft flush path.
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
            Task { @MainActor in
                await Task.yield()
                window.performClose(nil)
            }
        } else { window.performClose(nil) }
    }
    func closeAllWindows() {
        // Snapshot before sending close notifications, which unregister their
        // contexts. Include minimized windows; leave the process in the Dock.
        let closing = NSApp.windows.filter { $0.sheetParent == nil && $0.styleMask.contains(.closable) && ($0.isVisible || $0.isMiniaturized) }
        for window in closing { closeWindow(window) }
    }
    func openSession(_ id: String? = nil) {
        let available = windows.compactMap(\.context).filter { $0.window != nil && $0.store.isObserving }
        if let id {
            guard let identity = UUID(uuidString: id) else { return }
            // Opening a recent session is document navigation: reuse its own
            // window without reloading, replacing tabs, or moving another root.
            if let existing = available.last(where: {
                if let reserved = recentOpeningID(in: $0) { return UUID(uuidString: reserved) == identity }
                return !$0.store.busy && UUID(uuidString: $0.store.snapshot?.root.id ?? "") == identity
            }) {
                show(existing)
            } else if pendingSessionIDs.values.contains(where: { UUID(uuidString: $0) == identity }) {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if let empty = available.last(where: { $0.store.snapshot == nil && !$0.store.busy && recentOpeningID(in: $0) == nil }) {
                show(empty)
                loadRecentSession(id, in: empty)
            } else {
                let requestID = UUID()
                pendingSessionIDs[requestID] = id
                newWindow(requestID: requestID)
            }
        } else if let context = available.last {
            show(context)
            context.store.perform(.openSession)
        } else { newWindow() }
    }
    // Each scene binds its pending ID before the async store start completes.
    // A just-attached scene is reserved even while its snapshot is still nil.
    private var pendingSessionIDs: [UUID: String] = [:]
    private var openingRecentSessions: [ObjectIdentifier: String] = [:]
    private func recentOpeningID(in context: LensWindowContext) -> String? {
        openingRecentSessions[ObjectIdentifier(context)] ?? context.sceneRequestID.flatMap { pendingSessionIDs[$0] }
    }
    private func loadRecentSession(_ id: String, in context: LensWindowContext) {
        let identity = ObjectIdentifier(context)
        openingRecentSessions[identity] = id
        Task { [weak self, weak context] in
            guard let context else { self?.openingRecentSessions[identity] = nil; return }
            await context.store.open(id)
            if self?.openingRecentSessions[identity] == id { self?.openingRecentSessions[identity] = nil }
        }
    }
    func acceptPendingSession(in context: LensWindowContext) {
        guard let requestID = context.sceneRequestID, let id = pendingSessionIDs.removeValue(forKey: requestID) else { return }
        if context.store.isObserving {
            context.store.showSessionPicker = false
            loadRecentSession(id, in: context)
            show(context)
        }
    }
    func reopen() { if let context = windows.compactMap(\.context).last { show(context) } else { newWindow() } }
    private func show(_ context: LensWindowContext) { NSApp.unhide(nil); context.window?.deminiaturize(nil); context.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func recoverVisibleFrames() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let primary = screens.first else { return }
        for context in windows.compactMap(\.context) {
            guard let window = context.window, !window.styleMask.contains(.fullScreen), !screens.contains(where: {
                let titlebar = CGRect(x: window.frame.minX, y: window.frame.maxY - 28, width: window.frame.width, height: 28)
                let intersection = $0.intersection(titlebar)
                return !intersection.isNull && intersection.width >= min(120, titlebar.width) && intersection.height >= 20
            }) else { continue }
            var frame = window.frame; frame.size.width = min(frame.width, primary.width); frame.size.height = min(frame.height, primary.height)
            frame.origin = CGPoint(x: primary.midX - frame.width / 2, y: primary.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
    }
    func flushClosedInvestigation(_ investigation: InvestigationStore) {
        let identity = UUID()
        closingFlushes[identity] = Task { [weak self] in
            await investigation.flushAndStop()
            self?.closingFlushes[identity] = nil
        }
    }
    func prepareToQuit() async {
        for context in windows.compactMap(\.context) {
            context.cancelOperation(); context.store.stopObserving()
            flushClosedInvestigation(context.store.investigation)
        }
        let pending = Array(closingFlushes.values)
        for flush in pending { await flush.value }
    }
}

/// Dock dispatch can use a nil sender. Its target, rather than a menu item's
/// representedObject, must retain the exact session identity (AppKit contract).
@MainActor final class LensDockSessionAction: NSObject {
    let sessionID: String
    init(sessionID: String) { self.sessionID = sessionID }
    @objc func openSession(_ sender: Any?) { LensApplicationCoordinator.shared.openSession(sessionID) }
}

@MainActor final class LensApplicationDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []
    private var gestureMonitor: Any?
    // NSMenuItem does not own its target. Keep this displayed Dock menu's five
    // immutable targets alive until macOS requests a replacement menu.
    private var dockSessionActions: [LensDockSessionAction] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        LensAppIconController.shared.start()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reconcileNativeTabCommands() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { LensApplicationCoordinator.shared.recoverVisibleFrames() } })
    }
    /// Lens owns its evidence tabs. Remove only the unrelated NSWindow tab
    /// commands supplied dynamically by AppKit; all other native items remain.
    func reconcileNativeTabCommands() {
        guard let menu = NSApp.mainMenu else { return }
        let windowTabActions = Set(["toggleTabBar:", "toggleTabOverview:", "selectPreviousTab:", "selectNextTab:", "moveTabToNewWindow:", "mergeAllWindows:"])
        for top in menu.items {
            for item in top.submenu?.items ?? [] {
                if let action = item.action, windowTabActions.contains(NSStringFromSelector(action)) { top.submenu?.removeItem(item) }
            }
        }
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let new = NSMenuItem(title: LensGlobalAction.newWindow.title, action: #selector(newWindow(_:)), keyEquivalent: ""); new.target = self; menu.addItem(new)
        let open = NSMenuItem(title: LensGlobalAction.openSession.title, action: #selector(openSession(_:)), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let ids = LensApplicationCoordinator.shared.recentIDs.prefix(5)
        dockSessionActions = ids.map { LensDockSessionAction(sessionID: $0) }
        if !dockSessionActions.isEmpty {
            menu.addItem(.separator())
            for target in dockSessionActions {
                let item = NSMenuItem(title: LensApplicationCoordinator.shared.recentTitle(for: target.sessionID), action: #selector(LensDockSessionAction.openSession(_:)), keyEquivalent: "")
                item.toolTip = target.sessionID
                item.target = target
                menu.addItem(item)
            }
        }
        return menu // System Dock items remain managed by macOS. No I/O here.
    }
    @objc func newWindow(_ sender: Any?) { LensGlobalAction.newWindow.perform() }
    @objc func openSession(_ sender: NSMenuItem?) { if let id = sender?.representedObject as? String { LensApplicationCoordinator.shared.openSession(id) } else { LensGlobalAction.openSession.perform() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { LensApplicationCoordinator.shared.reopen(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }; terminationPending = true
        Task { await LensApplicationCoordinator.shared.prepareToQuit(); finishTermination(sender) }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); finishTermination(sender) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { LensAppIconController.shared.stop() }
    private func finishTermination(_ sender: NSApplication) { guard terminationPending else { return }; terminationPending = false; sender.reply(toApplicationShouldTerminate: true) }
}
