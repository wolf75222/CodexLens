import SwiftUI
import Combine
import LensCore

enum LensSection: String, CaseIterable, Identifiable {
    case activity = "Activité", agents = "Agents", calls = "Appels d’outils", environments = "Environnements", resources = "Ressources", changes = "Modifications", investigation = "Enquête"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .activity: return "waveform.path"; case .agents: return "person.3"; case .calls: return "wrench"; case .environments: return "folder"; case .resources: return "paperclip"; case .changes: return "plus.forwardslash.minus"; case .investigation: return "text.bubble" }
    }
}
enum Destination: Hashable, Codable {
    case event(String), agent(String), environment(String), resource(String), change(String)
    case file(environment: String, path: String, line: Int? = nil, version: String? = nil)
    case investigation(String)
    case evidence(capsule: String, piece: String)
}
enum ActivityInspectionMode: String, CaseIterable { case chronology = "Chronologie", communications = "Échanges" }
struct LensTab: Identifiable, Codable { var id = UUID(); var destination: Destination; var pinned = false }
/// Viewport metadata only. No journal content or retained native reader views.
struct LensEventListViewport: Equatable {
    var rootID: String
    var anchorID: String?
    var anchorOffset: CGFloat
    var origin: CGPoint
    var sourceHome: String? = nil
}
struct LensBookmark: Identifiable, Codable { var id = UUID(); let rootID: String; let destination: Destination; let title: String }

@MainActor final class LensStore: ObservableObject {
    @Published private(set) var sourceHome: URL
    private var selectedSourceHome: URL?
    private let cacheDirectory: URL?
    private let readerPool: SessionReaderPool
    private var catalogueLease: SessionReaderLease?
    private var selectedReaderLease: SessionReaderLease?
    var hasSessionReader: Bool { selectedReaderLease != nil }
    private var pendingReaderLease: SessionReaderLease?
    private var receivedReaderRevision: UInt64?
    private var fallbackEngine: SessionEngine?
    /// Inspectors use the selected root's engine, never an engine currently loading another root.
    var engine: SessionEngine {
        if let selectedReaderLease { return selectedReaderLease.engine }
        if let catalogueLease { return catalogueLease.engine }
        if let fallbackEngine { return fallbackEngine }
        let fresh = SessionEngine(home: sourceHome, cacheDirectory: cacheDirectory); fallbackEngine = fresh
        return fresh
    }
    let files = FileService()
    let pager = RecordedPager()
    let documentPager = RecordedDocumentPager()
    let investigation: InvestigationStore
    @Published var catalog: [SessionSummary] = []
    @Published var snapshot: SessionSnapshot? {
        didSet {
            snapshotRevision &+= 1
            if oldValue?.root.id != snapshot?.root.id {
                presentation = nil; timelineProjection = nil; timelineWindow = nil; timelineOrigin = .zero; timelineFocus = nil
                timelineZoomLimit = TimelineInteraction.zoomRange.upperBound; timelineZoom = 1
            }
            schedulePresentation(coalescingLiveUpdate: oldValue?.root.id == snapshot?.root.id)
            if !query.isEmpty { search() }
            if !agentQuery.isEmpty { searchAgents() }
        }
    }
    @Published var section: LensSection = .activity
    @Published var activityMode: ActivityInspectionMode = .chronology
    @Published var selection: Destination? {
        didSet {
            if oldValue != selection {
                selectionGeneration = UUID(); selectionTask?.cancel(); selectionTask = nil
                if case .evidence(let capsuleID, _) = selection {
                    if inspectedEvidenceCapsule?.id != capsuleID { inspectedEvidenceCapsule = nil }
                } else { inspectedEvidenceCapsule = nil }
            }
        }
    }
    @Published var tabs: [LensTab] = []
    @Published var activeTab: UUID?
    /// Explicit tab inspection is distinct from selecting a row in a collection.
    @Published private(set) var tabContentVisible = false
    var workspacePresented: Bool { !tabContentVisible && livePreview == nil }
    var workspaceSection: LensSection { workspacePresented ? section : (workspaceCheckpoint?.section ?? .activity) }
    var hasWorkspaceReturn: Bool { snapshot != nil && (!tabs.isEmpty || livePreview != nil) }
    private var workspaceCheckpoint: Checkpoint?
    private var readerCheckpoints: [UUID: Checkpoint] = [:]
    private var eventListViewports: [String: LensEventListViewport] = [:]
    @Published private(set) var eventListRestoration = 0
    func recordEventListViewport(_ value: LensEventListViewport, calls: Bool) {
        guard value.rootID == snapshot?.root.id,
              value.sourceHome == nil || value.sourceHome == observedSourceHome.standardizedFileURL.path else { return }
        eventListViewports[calls ? "calls" : "events"] = value
    }
    func eventListViewport(calls: Bool) -> LensEventListViewport? {
        let value = eventListViewports[calls ? "calls" : "events"]
        return value?.rootID == snapshot?.root.id ? value : nil
    }
    var tabContentDestination: Destination? {
        guard tabContentVisible, let selection else { return nil }
        switch selection {
        case .event where section == .activity || section == .calls: return selection
        case .agent where section == .agents: return selection
        default: return nil
        }
    }
    /// The contextual inspector must not mount a second reader for the same
    /// event. A live preview can show a different object than the selection.
    var centrallyPresentedEventID: String? {
        let destination: Destination?
        if liveTimelineVisible {
            if let livePreview { destination = livePreview }
            else if tabContentVisible, section == .activity || section == .calls, case .event = selection { destination = selection }
            else { destination = tabContentDestination }
        } else { destination = tabContentDestination }
        if case .event(let id) = destination { return id }
        return nil
    }
    @Published var query = "" { didSet { if oldValue != query { schedulePresentation() } } }
    @Published var agentQuery = "" { didSet { if oldValue != agentQuery { schedulePresentation(); searchAgents() } } }
    @Published private(set) var agentSearchMatches: Set<String>? { didSet { if oldValue != agentSearchMatches { schedulePresentation() } } }
    @Published private(set) var agentSearchPending = false
    @Published private(set) var agentSearchIssue: String?
    @Published var agentFilter: String? { didSet { if oldValue != agentFilter { schedulePresentation() } } }
    @Published var environmentFilter: String? { didSet { if oldValue != environmentFilter { schedulePresentation() } } }
    @Published var resourceFilter: String? { didSet { if oldValue != resourceFilter { schedulePresentation() } } }
    @Published var kindFilter: EventKind? { didSet { if oldValue != kindFilter { schedulePresentation() } } }
    @Published var originInstructionFilter: String? { didSet { if oldValue != originInstructionFilter { schedulePresentation() } } }
    @Published private(set) var originCodeReferences: [String: OriginCodeReference] = [:]
    func showOriginCode(_ reference: OriginCodeReference) {
        guard event(reference.eventID)?.environmentID == reference.environmentID else { return }
        originCodeReferences[reference.eventID] = reference
        if originCodeReferences.count > 24 { for key in originCodeReferences.keys.sorted() where key != reference.eventID { originCodeReferences.removeValue(forKey: key); if originCodeReferences.count <= 24 { break } } }
        inspectorVisible = true
    }
    @Published var period: ClosedRange<Date>? { didSet { if oldValue != period { schedulePresentation() } } }
    @Published var follow = true
    @Published var waitingEvents = 0
    @Published private(set) var waitingUpdates = false
    @Published private(set) var liveTimelineVisible = false
    @Published private(set) var livePreview: Destination?
    let liveClock = LensLiveClock()
    var liveState: TimelineLiveState { liveClock.state }

    func enableLiveTimeline(at date: Date = Date()) {
        guard !isStopped, snapshot != nil else { return }
        liveTimelineVisible = true
        if !follow { publishCollectedUpdates() }
        follow = true; liveClock.resume(at: date)
    }
    func disableLiveTimeline() {
        liveClock.pause(); liveTimelineVisible = false
        if let target = livePreview { navigate(target, newTab: true) }
    }
    func pauseLiveTimeline() {
        guard !isStopped else { return }
        follow = false; liveClock.pause()
    }
    func resumeLiveTimeline(at date: Date = Date()) {
        guard !isStopped, snapshot != nil else { return }
        publishCollectedUpdates(); follow = true
        liveClock.resume(at: date)
    }
    private func publishCollectedUpdates() {
        if waitingUpdates, let latest { snapshot = latest }
        waitingEvents = 0; waitingUpdates = false
    }
    func advanceLiveTimeline(at date: Date) {
        guard !isStopped, liveTimelineVisible, follow else { return }
        liveClock.advance(at: date)
    }
    func setLiveSpan(_ value: TimeInterval, at date: Date = Date()) {
        let window = liveState.window
        liveClock.setSpan(value, at: date)
        if !follow, let end = window?.end,
           let next = try? TimelineWindow(start: end.addingTimeInterval(-liveState.span), end: end) { liveClock.inspect(next) }
    }
    func inspectLiveWindow(_ window: TimelineWindow) {
        pauseLiveTimeline(); liveClock.inspect(window)
    }
    func focusLiveEvent(_ id: String) {
        guard let item = timelineProjection?.item(id: id), let bounds = timelineProjection?.bounds,
              let window = TimelineInteraction.focusWindow(for: item, within: bounds) else { return }
        inspectLiveWindow(window)
    }
    func previewLiveEvent(_ id: String) {
        guard !isStopped, event(id) != nil else { return }
        setLivePreview(.event(id))
    }
    func previewLiveChange(_ id: String) {
        guard !isStopped, change(id) != nil else { return }
        setLivePreview(.change(id))
    }
    func previewLatestLiveChange() {
        guard let change = presentation?.recentRecordedChanges.first else { return }
        previewLiveChange(change.id)
    }
    private func setLivePreview(_ target: Destination) {
        if livePreview == nil {
            retainCurrentWorkspace()
            previewOrigin = PreviewOrigin(checkpoint(selection))
        }
        if selection != target || livePreview != target {
            back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        }
        selection = target; livePreview = target
    }
    func closeLivePreview() {
        guard livePreview != nil else { return }
        back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        if let saved = previewOrigin?.checkpoint ?? workspaceCheckpoint { restore(saved) }
        else { livePreview = nil; previewOrigin = nil }
    }
    func showLiveEventList() {
        if !workspacePresented || section != .activity {
            back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        }
        retainCurrentWorkspace()
        if let saved = workspaceCheckpoint { restore(saved) }
        livePreview = nil; tabContentVisible = false; section = .activity; activityMode = .chronology
        persistTabs()
    }
    func openLivePreviewInTab() {
        guard let target = livePreview else { return }
        navigate(target, newTab: true)
    }
    func liveChanges(for eventID: String) -> [ChangeRecord] { presentation?.changesByEvent[eventID] ?? [] }

    @Published var busy = false
    @Published var error: String?
    @Published var showSessionPicker = true
    @Published var showCoverage = false
    @Published var showConversation = false
    @Published var inspectorVisible = false {
        didSet { if inspectorVisible { chatVisible = false } }
    }
    @Published var chatVisible = false
    @Published var evidenceJSONVisible = false
    @Published private(set) var inspectedEvidenceCapsule: EvidenceCapsule?
    private var restoredChatRecordID: String?
    func showChat() { guard !isStopped else { return }; chatVisible = true }
    func toggleChat() { guard !isStopped else { return }; chatVisible.toggle() }
    func showEvidenceJSON() {
        guard let capsule = investigation.capsule, let piece = capsule.pieces.first else { return }
        navigate(.evidence(capsule: capsule.id, piece: piece.id), newTab: true)
        evidenceJSONVisible = true
    }
    private func rememberChat(_ recordID: String) {
        guard let rootID = snapshot?.root.id else { return }
        var saved = UserDefaults.standard.dictionary(forKey: "lensChatByRoot") as? [String: String] ?? [:]
        let key = navigationScope + "|" + rootID
        saved[key] = recordID
        if saved.count > 16 { for old in saved.keys.sorted() where old != key { saved.removeValue(forKey: old); if saved.count <= 16 { break } } }
        UserDefaults.standard.set(saved, forKey: "lensChatByRoot")
    }
    private func restoreChat(rootID: String, lifecycle: UUID, opening: UUID) async {
        guard let recordID = restoredChatRecordID, !Task.isCancelled, !isStopped,
              lifecycle == lifecycleGeneration, opening == openGeneration, snapshot?.root.id == rootID else { return }
        restoredChatRecordID = nil
        await investigation.openRecord(recordID)
        guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, opening == openGeneration,
              snapshot?.root.id == rootID, investigation.capsule?.rootThreadID == rootID, investigation.issue == nil else { return }
        rememberChat(recordID); showChat()
    }
    var displayedEvidenceCapsule: EvidenceCapsule? {
        if case .evidence(let capsuleID, _) = selection {
            if inspectedEvidenceCapsule?.id == capsuleID { return inspectedEvidenceCapsule }
            return investigation.capsule?.id == capsuleID ? investigation.capsule : nil
        }
        return investigation.capsule
    }
    var displayedEvidencePieceID: String? {
        if case .evidence(_, let pieceID) = selection { return pieceID }
        return investigation.inspectedPiece
    }
    @Published private(set) var catalogLoading = false
    @Published private(set) var localActionNotice: String?
    private var localNoticeTask: Task<Void, Never>?
    var investigationPreparationTask: Task<Void, Never>?
    @Published var timelineVisible = true
    @Published var searchMatches: Set<String>? { didSet { if oldValue != searchMatches { schedulePresentation() } } }
    @Published private(set) var codeFont: LensCodeFont = .system
    @Published var fontSize: Double = LensUI.defaultReadingSize
    let readingPreferences: LensReadingPreferences
    private var readingDefaultSize: Double = LensUI.defaultReadingSize
    private var readingPreferencesSubscription: AnyCancellable?
    @Published var bookmarks: [LensBookmark] = []
    private var latest: SessionSnapshot?
    private struct Checkpoint {
        let destination: Destination?
        let filters: EventFilters
        let agentFilters: AgentFilters
        let section: LensSection
        let activityMode: ActivityInspectionMode
        let timelineWindow: ClosedRange<Date>?
        let timelineZoom: Double
        let timelineZoomLimit: Double
        let timelineOrigin: CGPoint
        let livePreview: Destination?
        let previewOrigin: PreviewOrigin?
        let activeTab: UUID?
        let activeTabDestination: Destination?
        let tabContentVisible: Bool
        let timelineVisible: Bool
        let liveTimelineVisible: Bool
        let follow: Bool
        let liveState: TimelineLiveState
        let listViewports: [String: LensEventListViewport]
    }
    /// Immutable metadata for the reader/collection covered by a temporary preview.
    private final class PreviewOrigin {
        let checkpoint: Checkpoint
        init(_ checkpoint: Checkpoint) { self.checkpoint = checkpoint }
    }
    private var previewOrigin: PreviewOrigin?
    private var back: [Checkpoint] = []
    private var forward: [Checkpoint] = []
    private var navigationScope = UUID().uuidString
    var windowIdentity: String { navigationScope }
    var observedSourceHome: URL { selectedSourceHome ?? sourceHome }
    var windowReaderPool: SessionReaderPool { readerPool }
    var windowCacheDirectory: URL? { cacheDirectory }
    var personalSessionHome: URL { CodexSourceLocation.personalHome() }
    var isObserving: Bool { started && !isStopped }
    private static let sharedArchive = InvestigationArchive(directory: ProcessInfo.processInfo.environment["LENS_ARCHIVE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    private let presentationBuilder = SessionPresentationBuilder()
    private let timelineBuilder = TimelineModel()
    private var projectionTask: Task<Void, Never>?
    private var projectionGeneration = UUID()
    private var projectionReaderID: UUID?
    private var projectionNeedsRefresh = false
    private var snapshotRevision = 0
    private var lifecycleGeneration = UUID()
    private var searchGeneration = UUID()
    private var agentSearchGeneration = UUID()
    private var agentSearchTask: Task<Void, Never>?
    private var isStopped = false
    private var returnToPresentTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var loadTask: Task<SessionReaderUpdate, Error>?
    private var catalogTask: Task<[SessionSummary], Error>?
    private var catalogGeneration = UUID()
    @Published private(set) var presentation: SessionPresentation?
    @Published private(set) var timelineProjection: TimelineProjection?
    @Published private(set) var isProjecting = false
    @Published private(set) var timelinePreparing = false
    @Published private(set) var timelineIssue: String?
    @Published var timelineFocus: TimelineFocusRequest?
    @Published var timelineZoom = 1.0
    @Published private(set) var timelineZoomLimit = TimelineInteraction.zoomRange.upperBound
    var timelineWindow: ClosedRange<Date>?
    var timelineOrigin = CGPoint.zero
    @Published var timelineReset = 0

    func focusTimelineEvent(_ id: String, zoom: Bool = false) {
        guard !isStopped, event(id) != nil else { return }
        timelineFocus = TimelineFocusRequest(eventID: id, zoomToEvent: zoom)
    }
    func focusTimelinePeriod(_ range: ClosedRange<Date>, viewportWidth: Double, baseContentWidth: Double,
                             recordHistory: Bool = true) {
        guard !isStopped, let bounds = timelineProjection?.bounds,
              range.lowerBound.timeIntervalSince1970.isFinite, range.upperBound.timeIntervalSince1970.isFinite else { return }
        let lo = max(bounds.start, range.lowerBound), hi = min(bounds.end, range.upperBound)
        guard lo <= hi, let window = try? TimelineWindow(start: lo, end: hi),
              let placement = TimelineInteraction.focusPlacement(window: window, within: bounds,
                  baseContentWidth: baseContentWidth, viewportWidth: viewportWidth) else { return }
        if recordHistory {
            back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
            timelineFocus = nil
        }
        timelineWindow = bounds.start...bounds.end
        timelineZoomLimit = min(TimelineInteraction.maximumFocusZoom, max(timelineZoomLimit, placement.zoom * 4))
        timelineZoom = placement.zoom
        timelineOrigin.x = placement.originX; timelineReset &+= 1
    }
    // Environment callbacks keep one identity for this window, even when a
    // layout pass reevaluates a view while its split panes are being measured.
    lazy var readingMagnifier: (CGFloat) -> Void = { [weak self] delta in self?.magnifyReading(delta) }
    func magnifyReading(_ delta: CGFloat) {
        guard delta.isFinite, readingPreferences.configuration.pinchEnabled else { return }
        fontSize = Double(LensUI.readingSize(fontSize * max(0.5, min(2, 1 + Double(delta)))))
    }
    func showInTimeline(_ id: String) {
        guard let selected = event(id) else { return }
        let canonical = presentation?.contextInspection.compactionByEventID[id]?.eventID ?? id
        back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        retainCurrentWorkspace()
        if !workspacePresented, let saved = workspaceCheckpoint { restore(saved) }
        navigate(.event(canonical), record: false, updateTabs: false); tabContentVisible = false; section = .activity; activityMode = .chronology; timelineVisible = true
        // Explicit reveal may remove only conflicting filters. Streaming never changes them.
        if let filter = agentFilter, filter != selected.agentID { agentFilter = nil }
        if let filter = environmentFilter, filter != selected.environmentID { environmentFilter = nil }
        if let filter = resourceFilter, !selected.resourceIDs.contains(filter) { resourceFilter = nil }
        if let filter = kindFilter, filter != selected.kind { kindFilter = nil }
        if let filter = originInstructionFilter, presentation?.originInspection.associatedEventIDsByInstruction[filter]?.contains(id) != true { originInstructionFilter = nil }
        if let period, !selected.overlaps(period) { self.period = nil }
        if !query.isEmpty, !(searchMatches?.contains(id) ?? (selected.title + selected.preview).localizedCaseInsensitiveContains(query)) { query = ""; searchMatches = nil }
        focusTimelineEvent(canonical, zoom: true)
        persistTabs()
    }
    func setNavigationScope(_ value: String) { guard !started, UUID(uuidString: value) != nil else { return }; navigationScope = value }
    private var currentFilters: EventFilters { EventFilters(agentID: agentFilter, environmentID: environmentFilter, resourceID: resourceFilter, kind: kindFilter, period: period, query: query, sourceMatches: searchMatches, originInstructionID: originInstructionFilter) }
    private func checkpoint(_ destination: Destination?) -> Checkpoint { Checkpoint(destination: destination, filters: currentFilters, agentFilters: AgentFilters(query: agentQuery, sourceMatches: agentSearchMatches), section: section, activityMode: activityMode, timelineWindow: timelineWindow, timelineZoom: timelineZoom, timelineZoomLimit: timelineZoomLimit, timelineOrigin: timelineOrigin, livePreview: livePreview, previewOrigin: previewOrigin, activeTab: activeTab, activeTabDestination: tabs.first(where: { $0.id == activeTab })?.destination, tabContentVisible: tabContentVisible, timelineVisible: timelineVisible, liveTimelineVisible: liveTimelineVisible, follow: follow, liveState: liveState, listViewports: eventListViewports) }
    private func restore(_ entry: Checkpoint) {
        timelineFocus = nil
        activeTab = tabs.contains(where: { $0.id == entry.activeTab }) ? entry.activeTab : nil
        if entry.tabContentVisible, let i = tabs.firstIndex(where: { $0.id == activeTab }), let destination = entry.activeTabDestination { tabs[i].destination = destination }
        if let destination = entry.destination { navigate(destination, record: false, updateTabs: false) }
        else { selection = nil }
        query = entry.filters.query; agentFilter = entry.filters.agentID; environmentFilter = entry.filters.environmentID
        resourceFilter = entry.filters.resourceID; kindFilter = entry.filters.kind; period = entry.filters.period; searchMatches = entry.filters.sourceMatches
        originInstructionFilter = entry.filters.originInstructionID
        agentQuery = entry.agentFilters.query; agentSearchMatches = entry.agentFilters.sourceMatches
        section = entry.section; activityMode = entry.activityMode; timelineWindow = entry.timelineWindow; timelineZoomLimit = entry.timelineZoomLimit; timelineZoom = entry.timelineZoom; timelineOrigin = entry.timelineOrigin; timelineReset &+= 1; livePreview = entry.livePreview; tabContentVisible = entry.tabContentVisible
        timelineVisible = entry.timelineVisible; liveTimelineVisible = entry.liveTimelineVisible
        follow = entry.follow; liveClock.restore(entry.liveState)
        previewOrigin = entry.livePreview == nil ? nil : entry.previewOrigin
        eventListViewports = entry.listViewports; eventListRestoration &+= 1
        if tabContentVisible, livePreview == nil, activeTab == nil, let target = selection {
            if let tab = tabs.first(where: { $0.destination == target }) { activeTab = tab.id }
            else { let tab = LensTab(destination: target); tabs.append(tab); activeTab = tab.id }
        }
        persistTabs()
    }
    private func retainCurrentWorkspace() {
        if workspacePresented { workspaceCheckpoint = checkpoint(selection) }
        else if livePreview == nil, tabContentVisible, let id = activeTab,
                tabs.first(where: { $0.id == id })?.destination == selection { readerCheckpoints[id] = checkpoint(selection) }
    }
    /// Return to the collection that opened the readers, including its selection and viewport.
    func showWorkspace() {
        guard !isStopped, !workspacePresented, let saved = workspaceCheckpoint else { return }
        back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        retainCurrentWorkspace()
        restore(saved)
    }
    func applyWindowSeedDestination(_ target: Destination, evidenceCapsule: EvidenceCapsule?) {
        guard !isStopped, let rootID = snapshot?.root.id else { return }
        if case .evidence(let capsuleID, let pieceID) = target {
            guard let capsule = evidenceCapsule, capsule.id == capsuleID, capsule.rootThreadID == rootID,
                  capsule.pieces.contains(where: { $0.id == pieceID }) else { error = LensL10n.text("Source indisponible dans cette session."); return }
            inspectedEvidenceCapsule = capsule
        }
        guard targetBelongsToCurrentRoot(target) else { error = LensL10n.text("Source indisponible dans cette session."); return }
        navigate(target, newTab: true)
    }
    private var projectionPublicationSequence: UInt64 = 0
    private func schedulePresentation(coalescingLiveUpdate: Bool = false) {
        // Live snapshots must not repeatedly cancel the first usable projection.
        // Keep only the newest snapshot in the store; finish the current generation,
        // then prepare that snapshot. User filter/source changes still supersede it.
        if coalescingLiveUpdate, projectionTask != nil, !isStopped, snapshot != nil,
           projectionReaderID == selectedReaderLease?.id {
            projectionNeedsRefresh = true
            return
        }
        projectionNeedsRefresh = false
        projectionReaderID = selectedReaderLease?.id
        projectionTask?.cancel(); let generation = UUID(); projectionGeneration = generation
        projectionPublicationSequence &+= 1
        let publicationSequence = projectionPublicationSequence
        guard !isStopped, let snapshot else { presentation = nil; timelineProjection = nil; isProjecting = false; timelinePreparing = false; return }
        let filters = currentFilters, agentFilters = AgentFilters(query: agentQuery, sourceMatches: agentSearchMatches), revision = snapshotRevision, lifecycle = lifecycleGeneration
        let presentationBuilder = self.presentationBuilder, timelineBuilder = self.timelineBuilder
        if !isProjecting { isProjecting = true }; if !timelinePreparing { timelinePreparing = true }
        projectionTask = Task { [weak self] in
            defer {
                if let self, self.acceptsProjection(generation, lifecycle: lifecycle) {
                    self.projectionTask = nil
                    if self.projectionNeedsRefresh { self.schedulePresentation() }
                }
            }
            do {
                let next = try await presentationBuilder.prepare(snapshot: snapshot, revision: revision, filters: filters, agentFilters: agentFilters)
                guard !Task.isCancelled, self?.acceptsProjection(generation, lifecycle: lifecycle) == true else { return }
                let publishSpan = LensSignposts.begin("PresentationPublish")
                self?.presentation = next; self?.isProjecting = false
                publishSpan.end()
                await presentationBuilder.didPublish(next, sequence: publicationSequence)
                guard !Task.isCancelled, self?.acceptsProjection(generation, lifecycle: lifecycle) == true else { return }
                let timeline = try await timelineBuilder.prepare(events: next.filteredEvents, agents: snapshot.agents)
                guard !Task.isCancelled, self?.acceptsProjection(generation, lifecycle: lifecycle) == true else { return }
                self?.timelineProjection = timeline; self?.timelineIssue = nil; self?.timelinePreparing = false
                if self?.timelineWindow == nil, let bounds = timeline.bounds { self?.timelineWindow = bounds.start...bounds.end }
            } catch is CancellationError { }
            catch {
                guard self?.acceptsProjection(generation, lifecycle: lifecycle) == true else { return }
                self?.isProjecting = false; self?.timelinePreparing = false; self?.timelineIssue = error.localizedDescription
            }
        }
    }
    private func acceptsProjection(_ generation: UUID, lifecycle: UUID) -> Bool {
        !isStopped && lifecycle == lifecycleGeneration && generation == projectionGeneration
    }
    /// Stops work owned by this window. Source data remains untouched and the same scene can start again.
    func cancelOutstandingWork() {
        localNoticeTask?.cancel(); localNoticeTask = nil; localActionNotice = nil
        investigationPreparationTask?.cancel(); investigationPreparationTask = nil
        openGeneration = UUID(); searchGeneration = UUID(); projectionGeneration = UUID(); catalogGeneration = UUID()
        loadTask?.cancel(); loadTask = nil; catalogTask?.cancel(); catalogTask = nil
        if let pendingReaderLease { releaseReader(pendingReaderLease); self.pendingReaderLease = nil }
        searchTask?.cancel(); searchTask = nil
        agentSearchGeneration = UUID(); agentSearchTask?.cancel(); agentSearchTask = nil; agentSearchPending = false
        projectionTask?.cancel(); projectionTask = nil; projectionNeedsRefresh = false; projectionReaderID = nil
        returnToPresentTask?.cancel(); returnToPresentTask = nil
        selectionGeneration = UUID(); selectionTask?.cancel(); selectionTask = nil
        busy = false; catalogLoading = false; isProjecting = false; timelinePreparing = false
    }
    func stopObserving() {
        persistWindowRoot(); persistTabs()
        liveClock.reset(); livePreview = nil; liveTimelineVisible = false
        isStopped = true; started = false; lifecycleGeneration = UUID()
        cancelOutstandingWork(); pollTask?.cancel(); pollTask = nil
        if let selectedReaderLease { releaseReader(selectedReaderLease); self.selectedReaderLease = nil }
        if let catalogueLease { releaseReader(catalogueLease); self.catalogueLease = nil }
        receivedReaderRevision = nil; selectedSourceHome = nil; fallbackEngine = nil; latest = nil; snapshot = nil
        presentation = nil; timelineProjection = nil; selection = nil; tabs = []; activeTab = nil; tabContentVisible = false; searchMatches = nil; agentSearchMatches = nil; agentSearchIssue = nil
        let presentationBuilder = self.presentationBuilder, timelineBuilder = self.timelineBuilder
        Task { await presentationBuilder.invalidateCache(); await timelineBuilder.invalidateCache() }
    }
    /// An imported capsule identifies a root, but supplies no session history or environment facts.
    func showArchiveOnlyRoot(_ value: String) {
        let rootID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStopped, !rootID.isEmpty else { return }
        persistWindowRoot(); persistTabs(); cancelOutstandingWork()
        if let selectedReaderLease { releaseReader(selectedReaderLease); self.selectedReaderLease = nil }
        receivedReaderRevision = nil; selectedSourceHome = nil; fallbackEngine = nil; latest = nil
        selection = nil; tabs = []; activeTab = nil; tabContentVisible = false; back = []; forward = []; resetFilters(); agentQuery = ""; follow = false; waitingEvents = 0; waitingUpdates = false
        let evidence = "ID de racine référencé par une archive d’enquête importée. Les journaux locaux ne sont pas accessibles ; dates, agents et environnements inconnus."
        liveClock.reset(); livePreview = nil; liveTimelineVisible = false
        snapshot = SessionSnapshot(root: SessionSummary(id: rootID, title: "Session d’archive — historique indisponible", modifiedAt: .distantPast, relation: .root, evidence: evidence),
            coverage: [CoverageIssue("archive-only", "Journaux indisponibles : activité, agents, environnements et dates de session inconnus. Seul le contexte enregistré dans l’archive est consultable.")])
        showSessionPicker = false; section = .investigation; persistWindowRoot()
    }
    private func releaseReader(_ lease: SessionReaderLease) { Task { await lease.release() } }
    func waitForPresentation() async {
        while isProjecting || timelinePreparing { try? await Task.sleep(nanoseconds: 10_000_000); if Task.isCancelled || isStopped { return } }
    }
    func resetTimelineExtent() {
        timelineFocus = nil
        if let bounds = timelineProjection?.bounds { timelineWindow = bounds.start...bounds.end }
        timelineZoomLimit = TimelineInteraction.zoomRange.upperBound
        timelineZoom = 1; timelineOrigin = .zero; timelineReset &+= 1
    }
    func event(_ id: String) -> LensEvent? { presentation?.eventsByID[id] }
    func change(_ id: String) -> ChangeRecord? { presentation?.changesByID[id] }
    deinit { pollTask?.cancel(); searchTask?.cancel(); agentSearchTask?.cancel(); projectionTask?.cancel(); returnToPresentTask?.cancel(); selectionTask?.cancel(); loadTask?.cancel(); catalogTask?.cancel(); localNoticeTask?.cancel(); investigationPreparationTask?.cancel() }
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var openGeneration = UUID()
    var openingIdentity: UUID { openGeneration }
    private var started = false

    init(sourceHome: URL? = nil, investigationArchive: InvestigationArchive? = nil, cacheDirectory: URL? = nil, readerPool: SessionReaderPool = .shared, readingPreferences: LensReadingPreferences? = nil) {
        self.readingPreferences = readingPreferences ?? .shared
        self.sourceHome = sourceHome ?? CodexSourceLocation.observationHome()
        self.cacheDirectory = cacheDirectory ?? ProcessInfo.processInfo.environment["LENS_CACHE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }; self.readerPool = readerPool
        investigation = InvestigationStore(archive: investigationArchive ?? Self.sharedArchive)
        readingDefaultSize = self.readingPreferences.configuration.defaultSize
        fontSize = readingDefaultSize
        codeFont = self.readingPreferences.configuration.codeFont
        readingPreferencesSubscription = self.readingPreferences.$configuration.dropFirst().sink { [weak self] value in
            guard let self else { return }
            if self.codeFont != value.codeFont { self.codeFont = value.codeFont }
            if value.defaultSize != self.readingDefaultSize {
                self.readingDefaultSize = value.defaultSize
                self.fontSize = value.defaultSize
            }
        }
        if let data = UserDefaults.standard.data(forKey: "lensBookmarks"), data.count <= 256 * 1024 { bookmarks = (try? JSONDecoder().decode([LensBookmark].self, from: data)) ?? [] }
    }
    func start() async {
        guard !started else { return }; started = true; isStopped = false; lifecycleGeneration = UUID()
        let lifecycle = lifecycleGeneration
        await refreshCatalog()
        guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration else { return }
        if let index = CommandLine.arguments.firstIndex(of: "--session"), CommandLine.arguments.count > index + 1 {
            await open(CommandLine.arguments[index + 1])
        } else if let id = (UserDefaults.standard.dictionary(forKey: "lensRootByWindow") as? [String: String])?[navigationScope] {
            let restorationOpening = UUID()
            await open(id, generation: restorationOpening)
            if snapshot?.root.id != id { await restoreArchivedRoot(id, lifecycle: lifecycle, opening: restorationOpening) }
        }
        guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce(lifecycle: lifecycle)
            }
        }
    }
    /// Only window restoration may use this fallback; arbitrary session IDs never become synthetic history.
    private func restoreArchivedRoot(_ rootID: String, lifecycle: UUID, opening: UUID) async {
        guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: opening), snapshot?.root.id != rootID else { return }
        var expectedOpening = opening
        do {
            let archived = try await investigation.archive.list().filter { $0.rootThreadID == rootID }
            guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: opening), snapshot?.root.id != rootID,
                  let first = archived.first else { return }
            showArchiveOnlyRoot(rootID); error = nil
            let archiveOpening = openGeneration; expectedOpening = archiveOpening
            await investigation.loadArchive(rootID: rootID)
            guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: archiveOpening), snapshot?.root.id == rootID else { return }
            restoreTabs(rootID: rootID)
            await restoreChat(rootID: rootID, lifecycle: lifecycle, opening: archiveOpening)
            guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: archiveOpening), snapshot?.root.id == rootID else { return }
            if tabs.isEmpty {
                if investigation.capsule != nil { showChat(); return }
                await investigation.openRecord(first.id)
                guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: archiveOpening), snapshot?.root.id == rootID, tabs.isEmpty else { return }
                investigation.notice = LensL10n.text("Aucun onglet enregistré pour cette fenêtre : la première enquête locale disponible a été ouverte.")
                navigate(.investigation(first.id), newTab: true)
                return
            }
            guard let target = selection else { return }
            let selectionRevision = selectionGeneration
            switch target {
            case .investigation(let id):
                guard let record = archived.first(where: { $0.id == id || $0.capsuleID == id }) else {
                    investigation.notice = LensL10n.text("L’enquête de l’onglet enregistré n’est plus disponible dans l’archive locale.")
                    return
                }
                await investigation.openRecord(record.id)
                guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: archiveOpening), snapshot?.root.id == rootID,
                      selectionGeneration == selectionRevision, selection == target else { return }
            case .evidence(let capsuleID, let pieceID):
                guard let record = archived.first(where: { $0.capsuleID == capsuleID }) else {
                    investigation.notice = LensL10n.text("Le contexte de cet onglet n’est plus disponible dans l’archive locale.")
                    return
                }
                selectionTask?.cancel(); selectionTask = nil
                await investigation.openRecord(record.id)
                guard acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: archiveOpening), snapshot?.root.id == rootID,
                      selectionGeneration == selectionRevision, selection == target else { return }
                guard let capsule = investigation.capsule else { return }
                let address = try EvidenceAddress(rootID: rootID, capsuleID: capsuleID, pieceID: pieceID)
                _ = try address.resolve(in: capsule); investigation.inspectedPiece = pieceID
            default: break // Preserve an existing historical tab; do not substitute another archive for it.
            }
        } catch {
            if acceptsArchiveRestore(rootID: rootID, lifecycle: lifecycle, opening: expectedOpening), snapshot?.root.id == rootID {
                investigation.issue = LensL10n.text("Restauration de l’enquête locale impossible : ") + error.localizedDescription
            }
        }
    }
    private func acceptsArchiveRestore(rootID: String, lifecycle: UUID, opening: UUID) -> Bool {
        !Task.isCancelled && !isStopped && lifecycle == lifecycleGeneration && opening == openGeneration
    }
    private func pollOnce(lifecycle: UUID) async {
        guard !isStopped, !busy, lifecycle == lifecycleGeneration, let rootID = snapshot?.root.id, let lease = selectedReaderLease else { return }
        let opening = openGeneration
        do {
            let publication = try await lease.reader.refresh()
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, opening == openGeneration,
                  selectedReaderLease?.id == lease.id, snapshot?.root.id == rootID, publication.snapshot.root.id == rootID else { return }
            guard receivedReaderRevision != publication.revision else { return }
            receivedReaderRevision = publication.revision
            let next = publication.snapshot
            latest = next
            if follow { snapshot = next; waitingUpdates = false }
            else {
                waitingUpdates = true
                let count = max(0, next.events.count - (snapshot?.events.count ?? 0))
                if waitingEvents != count { waitingEvents = count }
            }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, opening == openGeneration, snapshot?.root.id == rootID { self.error = error.localizedDescription }
        }
    }
    func refreshCatalog() async {
        guard !isStopped else { return }
        let lifecycle = lifecycleGeneration, generation = UUID()
        catalogTask?.cancel(); catalogGeneration = generation
        catalogLoading = true
        defer { if generation == catalogGeneration { catalogLoading = false } }
        do {
            if catalogueLease == nil {
                let lease = try await readerPool.acquire(home: sourceHome, cacheDirectory: cacheDirectory)
                guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == catalogGeneration else { await lease.release(); return }
                catalogueLease = lease; fallbackEngine = nil
            }
            guard let lease = catalogueLease else { return }
            let task = Task { try await lease.reader.catalog() }; catalogTask = task
            let next = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == catalogGeneration else { return }
            catalog = next
        } catch is CancellationError { }
        catch { if !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == catalogGeneration { self.error = error.localizedDescription } }
        if generation == catalogGeneration { catalogTask = nil }
    }
    /// Change the picker source explicitly. The currently observed reader and its
    /// versions remain bound to their old source until a new opening succeeds.
    func useSessionSource(_ home: URL) async {
        guard !isStopped, !busy, home.isFileURL, home.path.hasPrefix("/") else { return }
        let next = home.standardizedFileURL
        guard next != sourceHome.standardizedFileURL else { return }
        catalogTask?.cancel(); catalogTask = nil; catalogGeneration = UUID()
        if let catalogueLease { releaseReader(catalogueLease); self.catalogueLease = nil }
        sourceHome = next; catalog = []; error = nil; fallbackEngine = nil
        await refreshCatalog()
    }
    func open(_ id: String) async { await open(id, generation: UUID()) }
    func cancelSessionOpening() {
        openGeneration = UUID(); loadTask?.cancel(); loadTask = nil
        if let pendingReaderLease { releaseReader(pendingReaderLease); self.pendingReaderLease = nil }
        busy = false; error = nil
        if !query.isEmpty, searchMatches == nil { search() }
        if !agentQuery.isEmpty, agentSearchMatches == nil { searchAgents() }
    }
    /// A missing history may still have an imported archive; an interrupted opening may not.
    func openImportedRoot(_ id: String) async -> UUID? {
        guard !Task.isCancelled, !isStopped else { return nil }
        let generation = UUID(), lifecycle = lifecycleGeneration
        await open(id, generation: generation)
        guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration else { return nil }
        return generation
    }
    func acceptsImportedOpening(_ token: UUID, rootID: String? = nil) -> Bool {
        !Task.isCancelled && !isStopped && token == openGeneration && (rootID == nil || snapshot?.root.id == rootID)
    }
    private func open(_ id: String, generation: UUID) async {
        let id = SessionPickerTarget.sessionID(from: id) ?? id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !isStopped else { return }
        investigationPreparationTask?.cancel(); investigationPreparationTask = nil
        let lifecycle = lifecycleGeneration, previousRoot = snapshot?.root.id, openingHome = sourceHome; openGeneration = generation
        searchGeneration = UUID(); searchTask?.cancel(); returnToPresentTask?.cancel()
        agentSearchGeneration = UUID(); agentSearchTask?.cancel(); agentSearchTask = nil; agentSearchPending = false
        busy = true; error = nil
        loadTask?.cancel()
        if let pendingReaderLease { releaseReader(pendingReaderLease); self.pendingReaderLease = nil }
        var candidate: SessionReaderLease?
        defer {
            if let candidate {
                if pendingReaderLease?.id == candidate.id { pendingReaderLease = nil }
                releaseReader(candidate)
            }
            if !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration {
                busy = false; loadTask = nil
                if snapshot?.root.id == previousRoot, !query.isEmpty, searchMatches == nil { search() }
                if snapshot?.root.id == previousRoot, !agentQuery.isEmpty, agentSearchMatches == nil { searchAgents() }
            }
        }
        do {
            if catalog.isEmpty { await refreshCatalog() }
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration else { return }
            let matchingRoots = catalog.filter { SessionPickerTarget.sameIdentity($0.sessionID, id) && $0.parentID == nil && $0.relation == .root }
            let resolvedID = catalog.first(where: { SessionPickerTarget.sameIdentity($0.id, id) })?.id ?? (matchingRoots.count == 1 ? matchingRoots[0].id : id)
            let lease = try await readerPool.acquire(home: openingHome, cacheDirectory: cacheDirectory, rootID: resolvedID)
            candidate = lease
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration else { await lease.release(); return }
            pendingReaderLease = lease
            let task = Task { try await lease.reader.load() }; loadTask = task
            let publication = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration else { return }
            if let previousRoot = snapshot?.root.id, previousRoot != publication.snapshot.root.id {
                await investigation.flushAndStop()
                guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration else { return }
            }
            persistWindowRoot(); persistTabs()
            if let selectedReaderLease { releaseReader(selectedReaderLease) }
            selectedReaderLease = lease; selectedSourceHome = openingHome; pendingReaderLease = nil; candidate = nil; fallbackEngine = nil
            receivedReaderRevision = publication.revision
            let next = publication.snapshot
            loadTask = nil
            snapshot = next; latest = next; selection = nil; tabs = []; activeTab = nil; tabContentVisible = false; back = []; forward = []
            workspaceCheckpoint = nil; readerCheckpoints = [:]; eventListViewports = [:]; eventListRestoration &+= 1
            timelineWindow = nil; timelineZoom = 1; timelineZoomLimit = TimelineInteraction.zoomRange.upperBound; timelineOrigin = .zero; timelineFocus = nil; timelineReset &+= 1
            livePreview = nil; previewOrigin = nil; liveClock.reset()
            resetFilters(); originCodeReferences = [:]; agentQuery = ""; follow = true; waitingEvents = 0; waitingUpdates = false; section = .activity
            if liveTimelineVisible { liveClock.resume(at: Date()) }
            showSessionPicker = false
            persistWindowRoot()
            restoreTabs(rootID: next.root.id)
            await investigation.loadArchive(rootID: next.root.id)
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration, snapshot?.root.id == next.root.id else { return }
            await restoreChat(rootID: next.root.id, lifecycle: lifecycle, opening: generation)
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration, snapshot?.root.id == next.root.id else { return }
            if case .investigation(let recordID) = selection { await investigation.openRecord(recordID) }
            if case .evidence(let capsuleID, let pieceID) = selection,
               let address = try? EvidenceAddress(rootID: next.root.id, capsuleID: capsuleID, pieceID: pieceID) { await openEvidence(address) }
        } catch is CancellationError { }
        catch { if !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == openGeneration { self.error = error.localizedDescription } }
    }
    func toggleFollow() {
        follow.toggle()
        if !follow { liveClock.pause() }
        if follow {
            if liveTimelineVisible { liveClock.resume(at: Date()) }
            publishCollectedUpdates()
            scheduleReturnToPresent()
        }
    }
    private func scheduleReturnToPresent() {
        returnToPresentTask?.cancel()
        let lifecycle = lifecycleGeneration, rootID = snapshot?.root.id
        returnToPresentTask = Task { [weak self] in
            await self?.waitForPresentation()
            guard !Task.isCancelled, self?.isStopped == false, self?.lifecycleGeneration == lifecycle,
                  self?.snapshot?.root.id == rootID, self?.follow == true else { return }
            self?.resetTimelineExtent()
        }
    }
    func present() {
        if liveTimelineVisible { resumeLiveTimeline(); return }
        if !follow { toggleFollow() }; period = nil; scheduleReturnToPresent()
    }
    func resetFilters() { query = ""; searchMatches = nil; agentFilter = nil; environmentFilter = nil; resourceFilter = nil; kindFilter = nil; period = nil; originInstructionFilter = nil }
    func showInstructionActivity(_ id: String) {
        guard presentation?.originInspection.associatedEventIDsByInstruction[id] != nil, event(id) != nil else { return }
        if let current = selection { back.append(checkpoint(current)); if back.count > 64 { back.removeFirst() }; forward = [] }
        navigate(.event(id), record: false); resetFilters(); originInstructionFilter = id
        tabContentVisible = false; section = .activity; activityMode = .chronology; inspectorVisible = true
    }
    func showOriginAgentActivity(_ id: String) {
        guard presentation?.agentsByID[id] != nil else { return }
        if let current = selection { back.append(checkpoint(current)); if back.count > 64 { back.removeFirst() }; forward = [] }
        navigate(.agent(id), record: false); resetFilters(); agentFilter = id
        tabContentVisible = false; section = .activity; activityMode = .chronology; inspectorVisible = true
    }
    var events: [LensEvent] { presentation?.filteredEvents ?? [] }
    func search() {
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        if searchMatches != nil { searchMatches = nil }
        let needle = query
        guard !isStopped, !busy, !needle.isEmpty, let snap = snapshot else { return }
        let lifecycle = lifecycleGeneration, revision = snapshotRevision, engine = self.engine
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, self?.acceptsSearch(generation, lifecycle: lifecycle, rootID: snap.root.id, revision: revision, query: needle) == true else { return }
                let matches = try await engine.matchingEventIDs(query: needle, snapshot: snap)
                guard !Task.isCancelled, self?.acceptsSearch(generation, lifecycle: lifecycle, rootID: snap.root.id, revision: revision, query: needle) == true else { return }
                self?.searchMatches = matches
            } catch is CancellationError { }
            catch {
                if self?.acceptsSearch(generation, lifecycle: lifecycle, rootID: snap.root.id, revision: revision, query: needle) == true { self?.error = error.localizedDescription }
            }
        }
    }
    private func acceptsSearch(_ generation: UUID, lifecycle: UUID, rootID: String, revision: Int, query: String) -> Bool {
        !isStopped && lifecycle == lifecycleGeneration && generation == searchGeneration && snapshot?.root.id == rootID && snapshotRevision == revision && self.query == query
    }
    /// Searches recorded sources for this agent query without changing the session
    /// query, type, selected period, or activity/call filters in this window.
    func searchAgents() {
        agentSearchTask?.cancel(); let generation = UUID(); agentSearchGeneration = generation
        agentSearchMatches = nil; agentSearchIssue = nil; agentSearchPending = false
        let needle = agentQuery
        guard !isStopped, !busy, !needle.isEmpty, let snap = snapshot else { return }
        let lifecycle = lifecycleGeneration, opening = openGeneration, revision = snapshotRevision, engine = self.engine
        agentSearchPending = true
        agentSearchTask = Task { [weak self] in
            defer {
                if self?.acceptsAgentSearch(generation, lifecycle: lifecycle, opening: opening, rootID: snap.root.id, revision: revision, query: needle) == true {
                    self?.agentSearchPending = false; self?.agentSearchTask = nil
                }
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, self?.acceptsAgentSearch(generation, lifecycle: lifecycle, opening: opening, rootID: snap.root.id, revision: revision, query: needle) == true else { return }
                let matches = try await engine.matchingEventIDs(query: needle, snapshot: snap)
                guard !Task.isCancelled, self?.acceptsAgentSearch(generation, lifecycle: lifecycle, opening: opening, rootID: snap.root.id, revision: revision, query: needle) == true else { return }
                self?.agentSearchMatches = matches
            } catch is CancellationError { }
            catch {
                if self?.acceptsAgentSearch(generation, lifecycle: lifecycle, opening: opening, rootID: snap.root.id, revision: revision, query: needle) == true { self?.agentSearchIssue = error.localizedDescription }
            }
        }
    }
    private func acceptsAgentSearch(_ generation: UUID, lifecycle: UUID, opening: UUID, rootID: String, revision: Int, query: String) -> Bool {
        !isStopped && lifecycle == lifecycleGeneration && opening == openGeneration && generation == agentSearchGeneration && snapshot?.root.id == rootID && snapshotRevision == revision && agentQuery == query
    }
    /// Browsing retains the inspected object and records changes of view.
    func browseSection(_ value: LensSection) {
        if value == .investigation {
            if let capsule = investigation.capsule { rememberChat(capsule.id) }
            showChat(); return
        }
        guard !isStopped, value != section || tabContentVisible || livePreview != nil else { return }
        back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        retainCurrentWorkspace()
        if !workspacePresented, let saved = workspaceCheckpoint { restore(saved) }
        livePreview = nil; tabContentVisible = false; section = value; persistTabs()
    }
    /// Follow an object's activity without losing the pre-navigation filters or
    /// leaving a reading tab over the filtered collection.
    func showActivity(for target: Destination) {
        guard !isStopped, targetBelongsToCurrentRoot(target) else { return }
        switch target { case .agent, .environment, .resource: break; default: return }
        back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        retainCurrentWorkspace()
        if !workspacePresented, let saved = workspaceCheckpoint { restore(saved) }
        switch target {
        case .agent(let id): agentFilter = id
        case .environment(let id): environmentFilter = id
        case .resource(let id): resourceFilter = id
        default: break
        }
        livePreview = nil; tabContentVisible = false; section = .activity; activityMode = .chronology
        persistTabs()
    }
    func presents(_ target: Destination) -> Bool {
        if liveTimelineVisible, livePreview == target { return true }
        switch target {
        case .event: return section == .activity || section == .calls
        case .agent: return section == .agents
        case .environment, .file: return section == .environments
        case .resource: return section == .resources
        case .change: return section == .changes
        case .investigation: return chatVisible
        case .evidence: return section == .investigation
        }
    }
    func isTabPresented(_ tab: LensTab) -> Bool {
        guard tab.id == activeTab && selection == tab.destination && presents(tab.destination) else { return false }
        return tabContentVisible
    }
    func navigate(_ target: Destination, newTab: Bool = false, record: Bool = true, updateTabs: Bool = true) {
        guard !isStopped else { return }
        // Chat is a window-local panel, not a replacement for the file/timeline
        // being inspected. Existing callers and deep links share this route.
        if case .investigation(let id) = target { rememberChat(id); showChat(); return }
        evidenceJSONVisible = false
        if record, selection != target || !presents(target) || (newTab && !tabContentVisible) { back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = [] }
        if record { retainCurrentWorkspace() }
        let openingReader = newTab || tabContentVisible
        livePreview = nil; previewOrigin = nil
        if newTab { tabContentVisible = true }
        selection = target
        if updateTabs && openingReader {
            // Every route reuses an existing destination, including links back
            // to the timeline. Replacing a different tab would duplicate it.
            if let existing = tabs.first(where: { $0.destination == target }) { activeTab = existing.id }
            else if !newTab, let i = tabs.firstIndex(where: { $0.id == activeTab }), !tabs[i].pinned { tabs[i].destination = target; readerCheckpoints.removeValue(forKey: tabs[i].id) }
            else { let tab = LensTab(destination: target); tabs.append(tab); activeTab = tab.id }
        }
        switch target {
        case .event: if section != .calls { section = .activity }
        case .agent: section = .agents
        case .environment, .file: section = .environments
        case .resource: section = .resources
        case .change: section = .changes
        case .investigation, .evidence: section = .investigation
        }
        if record, !openingReader, let event = selectedEvent { focusTimelineEvent(event.id, zoom: event.kind == .compaction) }
        persistTabs()
        if case .evidence(let capsuleID, let pieceID) = target, displayedEvidenceCapsule == nil, let rootID = snapshot?.root.id {
            selectionTask?.cancel()
            let generation = selectionGeneration, lifecycle = lifecycleGeneration
            selectionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let address = try EvidenceAddress(rootID: rootID, capsuleID: capsuleID, pieceID: pieceID)
                    let capsule = try await self.resolveEvidenceCapsule(address)
                    guard !Task.isCancelled, self.acceptsSelection(generation, lifecycle: lifecycle, rootID: rootID, target: target) else { return }
                    _ = try address.resolve(in: capsule); self.inspectedEvidenceCapsule = capsule
                } catch { if !Task.isCancelled, self.acceptsSelection(generation, lifecycle: lifecycle, rootID: rootID, target: target) { self.error = error.localizedDescription } }
            }
        }
    }
    func copyLocalText(_ text: String, notice: String) {
        guard !isStopped else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { error = LensL10n.text("Le texte n’a pas pu être copié."); return }
        showLocalNotice(notice)
    }
    func showLocalNotice(_ notice: String) {
        localNoticeTask?.cancel(); localActionNotice = notice
        if let window = NSApp.keyWindow, LensApplicationCoordinator.shared.context(for: window)?.store === self {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: notice, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        localNoticeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }; self?.localActionNotice = nil
        }
    }
    func selectTab(_ tab: LensTab) {
        guard !isStopped, let existing = tabs.first(where: { $0.id == tab.id }) else { return }
        if activeTab != existing.id || selection != existing.destination || !tabContentVisible || !presents(existing.destination) {
            back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = []
        }
        retainCurrentWorkspace()
        if let saved = readerCheckpoints[existing.id], saved.destination == existing.destination { restore(saved) }
        else { activeTab = existing.id; navigate(existing.destination, newTab: true, record: false, updateTabs: false) }
    }
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingPresentedReader = livePreview == nil && activeTab == id && tabContentVisible
        if closingPresentedReader { back.append(checkpoint(selection)); if back.count > 64 { back.removeFirst() }; forward = [] }
        tabs.remove(at: index); readerCheckpoints.removeValue(forKey: id)
        if livePreview != nil, previewOrigin?.checkpoint.activeTab == id {
            previewOrigin = workspaceCheckpoint.map(PreviewOrigin.init)
        }
        if activeTab == id {
            activeTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            if closingPresentedReader {
                if let tab = tabs.first(where: { $0.id == activeTab }) {
                    if let saved = readerCheckpoints[tab.id] { restore(saved) }
                    else { navigate(tab.destination, newTab: true, record: false, updateTabs: false) }
                } else if let saved = workspaceCheckpoint { restore(saved) }
                else { tabContentVisible = false }
            }
        }
        persistTabs()
    }
    func pinTab(_ id: UUID) { if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].pinned.toggle(); persistTabs() } }
    private func acceptsSelection(_ generation: UUID, lifecycle: UUID, rootID: String, target: Destination) -> Bool {
        !isStopped && lifecycle == lifecycleGeneration && generation == selectionGeneration && snapshot?.root.id == rootID && selection == target
    }
    func bookmarkSelection(for target: Destination? = nil) {
        guard let root = snapshot?.root.id, let destination = target ?? selection, targetBelongsToCurrentRoot(destination) else { return }
        if let i = bookmarks.firstIndex(where: { $0.rootID == root && $0.destination == destination }) { bookmarks.remove(at: i) }
        else { bookmarks.append(LensBookmark(rootID: root, destination: destination, title: label(destination))); if bookmarks.count > 64 { bookmarks.removeFirst() } }
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: "lensBookmarks")
    }
    private func persistWindowRoot() {
        guard let rootID = snapshot?.root.id else { return }
        var roots = UserDefaults.standard.dictionary(forKey: "lensRootByWindow") as? [String: String] ?? [:]
        roots[navigationScope] = rootID
        if roots.count > 32 { for key in roots.keys.sorted() where key != navigationScope { roots.removeValue(forKey: key); if roots.count <= 32 { break } } }
        UserDefaults.standard.set(roots, forKey: "lensRootByWindow")
    }
    private struct WindowTabs: Codable { let tabs: [LensTab]; let activeTab: UUID?; var tabContentVisible: Bool? = nil }
    private func persistTabs() {
        guard let rootID = snapshot?.root.id else { return }
        var saved = UserDefaults.standard.dictionary(forKey: "lensTabsByRoot") as? [String: Data] ?? [:]
        let storageKey = navigationScope + "|" + observedSourceHome.standardizedFileURL.path + "|" + rootID
        let retained = Array(tabs.suffix(24))
        saved[storageKey] = try? JSONEncoder().encode(WindowTabs(tabs: retained, activeTab: retained.contains(where: { $0.id == activeTab }) ? activeTab : retained.last?.id, tabContentVisible: tabContentVisible))
        if saved.count > 16 { for key in saved.keys.sorted() where key != storageKey { saved.removeValue(forKey: key); if saved.count <= 16 { break } } }
        UserDefaults.standard.set(saved, forKey: "lensTabsByRoot")
    }
    private func restoreTabs(rootID: String) {
        restoredChatRecordID = (UserDefaults.standard.dictionary(forKey: "lensChatByRoot") as? [String: String])?[navigationScope + "|" + rootID]
        if restoredChatRecordID != nil { showChat() }
        let savedTabs = UserDefaults.standard.dictionary(forKey: "lensTabsByRoot") as? [String: Data]
        let qualifiedKey = navigationScope + "|" + observedSourceHome.standardizedFileURL.path + "|" + rootID
        // Legacy entries have no source identity. Only migrate the default local source.
        let legacyData = observedSourceHome.standardizedFileURL == CodexSourceLocation.observationHome().standardizedFileURL ? savedTabs?[navigationScope + "|" + rootID] : nil
        guard let data = savedTabs?[qualifiedKey] ?? legacyData, data.count <= 256 * 1024 else { return }
        let saved: WindowTabs
        if let current = try? JSONDecoder().decode(WindowTabs.self, from: data) { saved = current }
        else if let legacy = try? JSONDecoder().decode([LensTab].self, from: data) { saved = WindowTabs(tabs: legacy, activeTab: legacy.last?.id) }
        else { return }
        let retained = Array(saved.tabs.suffix(24))
        let active = retained.first(where: { $0.id == saved.activeTab })
        if case .investigation(let id) = active?.destination { restoredChatRecordID = id; showChat() }
        // Migrate legacy chat tabs without discarding ordinary pinned tabs.
        tabs = retained.filter { if case .investigation = $0.destination { return false }; return true }
        activeTab = tabs.contains(where: { $0.id == saved.activeTab }) ? saved.activeTab : tabs.last?.id
        workspaceCheckpoint = checkpoint(selection)
        tabContentVisible = saved.tabContentVisible ?? false
        if let target = tabs.first(where: { $0.id == activeTab })?.destination { navigate(target, record: false, updateTabs: false) }
    }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    func goBack() {
        guard let target = back.popLast() else { return }
        retainCurrentWorkspace()
        forward.append(checkpoint(selection)); restore(target)
    }
    func goForward() {
        guard let target = forward.popLast() else { return }
        retainCurrentWorkspace()
        back.append(checkpoint(selection)); restore(target)
    }
    var selectedEvent: LensEvent? {
        guard snapshot != nil, let selection else { return nil }
        if case .event(let id) = selection { return event(id) }
        if case .change(let id) = selection, let c = change(id) { return event(c.eventID) }
        return nil
    }
    func agentName(_ id: String) -> String { presentation?.agentsByID[id]?.name.nonempty ?? String(id.prefix(8)) }
    func matches(_ text: String, eventIDs: [String]) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query) || eventIDs.contains { searchMatches?.contains($0) == true }
    }
    func label(_ destination: Destination) -> String {
        guard let snap = snapshot else { return LensL10n.text("Sélection") }
        switch destination {
        case .event(let id): return event(id).map { $0.kind == .compaction ? LensL10n.text($0.title) : $0.title } ?? LensL10n.text("Événement")
        case .agent(let id): return agentName(id)
        case .environment(let id): return URL(fileURLWithPath: id).lastPathComponent
        case .file(_, let path, _, _): return URL(fileURLWithPath: path).lastPathComponent
        case .resource(let id): return snap.resources.first { $0.id == id }.map(LensUI.resourceTitle) ?? LensL10n.text("Ressource")
        case .change(let id): return snap.changes.first { $0.id == id }.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? LensL10n.text("Modification")
        case .investigation: return LensL10n.text("Enquête")
        case .evidence(_, let piece): return LensL10n.text("Élément ") + piece
        }
    }
    private func targetBelongsToCurrentRoot(_ target: Destination) -> Bool {
        guard !isStopped, let snap = snapshot else { return false }
        switch target {
        case .event(let id): return presentation?.rootID == snap.root.id && presentation?.eventsByID[id] != nil
        case .agent(let id): return snap.agents.contains { $0.id == id }
        case .environment(let id): return snap.environments.contains { $0.id == id }
        case .file(let environment, let path, _, _): return !path.isEmpty && snap.environments.contains { $0.id == environment }
        case .resource(let id): return presentation?.rootID == snap.root.id && presentation?.resourcesByID[id] != nil
        case .change(let id): return presentation?.rootID == snap.root.id && presentation?.changesByID[id] != nil
        case .investigation(let id):
            if let capsule = investigation.capsule, capsule.rootThreadID == snap.root.id, id == investigation.recordID || id == capsule.id { return true }
            return investigation.records.contains { $0.id == id && $0.rootThreadID == snap.root.id }
        case .evidence(let capsuleID, let pieceID):
            if let capsule = inspectedEvidenceCapsule, capsule.id == capsuleID, capsule.rootThreadID == snap.root.id { return capsule.pieces.contains { $0.id == pieceID } }
            if let capsule = investigation.capsule, capsule.id == capsuleID, capsule.rootThreadID == snap.root.id { return capsule.pieces.contains { $0.id == pieceID } }
            return !pieceID.isEmpty && investigation.records.contains { $0.capsuleID == capsuleID && $0.rootThreadID == snap.root.id }
        }
    }
    func deepLink(for target: Destination? = nil) -> URL? {
        guard let snap = snapshot, let destination = target ?? selection, targetBelongsToCurrentRoot(destination) else { return nil }
        if case .evidence(let capsule, let piece) = destination { return try? EvidenceAddress(rootID: snap.root.id, capsuleID: capsule, pieceID: piece).url }
        var c = URLComponents(); c.scheme = "codexlens"; c.host = "session"; c.path = "/" + snap.root.id
        let type: String; let id: String; var env: String?; var line: Int?; var version: String?
        switch destination {
        case .event(let s): type = "event"; id = s
        case .agent(let s): type = "agent"; id = s
        case .environment(let s): type = "environment"; id = s
        case .resource(let s): type = "resource"; id = s
        case .change(let s): type = "change"; id = s
        case .file(let e, let p, let l, let v): type = "file"; id = p; env = e; line = l; version = v
        case .investigation(let s): type = "investigation"; id = s
        case .evidence: return nil
        }
        c.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "id", value: id)]
        if let env { c.queryItems?.append(URLQueryItem(name: "environment", value: env)) }
        if let line { c.queryItems?.append(URLQueryItem(name: "line", value: String(line))) }
        if let version { c.queryItems?.append(URLQueryItem(name: "version", value: version)) }; return c.url
    }
    private func resolveEvidenceCapsule(_ address: EvidenceAddress) async throws -> EvidenceCapsule {
        if let capsule = investigation.capsule, capsule.id == address.capsuleID { return capsule }
        if let capsule = inspectedEvidenceCapsule, capsule.id == address.capsuleID { return capsule }
        let records = try await investigation.archive.list()
        guard let summary = records.first(where: { $0.capsuleID == address.capsuleID && $0.rootThreadID == address.rootID }),
              let record = try await investigation.archive.load(id: summary.id) else { throw LensError.unavailable("Contenu archivé indisponible.") }
        return record.capsule
    }
    func reuseChatSource(_ address: EvidenceAddress) async {
        guard isObserving, snapshot?.root.id == address.rootID, !investigation.sending, !investigation.preparing else { return }
        let opening = openingIdentity, generation = investigation.evidenceContextGeneration
        do {
            let capsule = try await resolveEvidenceCapsule(address)
            let piece = try await Task.detached(priority: .userInitiated) { try address.resolve(in: capsule) }.value
            guard !Task.isCancelled, isObserving, openingIdentity == opening, snapshot?.root.id == address.rootID,
                  investigation.evidenceContextGeneration == generation, !investigation.sending, !investigation.preparing else { return }
            try investigation.append([piece], rootID: address.rootID, cut: max(capsule.collectionCut, investigation.capsule?.collectionCut ?? capsule.collectionCut),
                omissions: capsule.omissions.filter { $0.pieceID == nil || $0.pieceID == address.pieceID })
            investigation.notice = LensL10n.text("Version jointe à la prochaine question ; aucun envoi.")
        } catch {
            if !Task.isCancelled, openingIdentity == opening, investigation.evidenceContextGeneration == generation {
                investigation.issue = error.localizedDescription
            }
        }
    }
    func openEvidence(_ address: EvidenceAddress) async {
        guard !isStopped, snapshot?.root.id == address.rootID else { return }
        let lifecycle = lifecycleGeneration, generation = selectionGeneration
        do {
            let capsule = try await resolveEvidenceCapsule(address)
            guard !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == selectionGeneration, snapshot?.root.id == address.rootID else { return }
            _ = try address.resolve(in: capsule)
            inspectedEvidenceCapsule = capsule
            navigate(.evidence(capsule: address.capsuleID, piece: address.pieceID), newTab: true)
        } catch { if !Task.isCancelled, !isStopped, lifecycle == lifecycleGeneration, generation == selectionGeneration, snapshot?.root.id == address.rootID { self.error = error.localizedDescription } }
    }
    func handleURL(_ url: URL) async {
        if let id = SessionPickerTarget.sessionID(from: url.absoluteString), url.scheme?.lowercased() == "codex" {
            if snapshot?.root.id != id { await open(id) }
            return
        }
        guard !isStopped, url.scheme == "codexlens", url.host == "session", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if c.queryItems?.first(where: { $0.name == "type" })?.value == "evidence" {
            guard let address = try? EvidenceAddress(url: url) else { error = "Lien de citation invalide."; return }
            if snapshot?.root.id != address.rootID { await open(address.rootID) }
            guard !Task.isCancelled, !isStopped, snapshot?.root.id == address.rootID else { return }
            await openEvidence(address)
            return
        }
        let root = String(url.path.dropFirst())
        if snapshot?.root.id != root { await open(root) }
        guard !Task.isCancelled, !isStopped, snapshot?.root.id == root else { return }
        let args = Dictionary(c.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { _, b in b })
        guard let id = args["id"] else { return }
        switch args["type"] {
        case "event": navigate(.event(id), newTab: true)
        case "agent": navigate(.agent(id), newTab: true)
        case "environment": navigate(.environment(id), newTab: true)
        case "resource": navigate(.resource(id), newTab: true)
        case "change": navigate(.change(id), newTab: true)
        case "file": navigate(.file(environment: args["environment"] ?? "", path: id, line: args["line"].flatMap(Int.init).flatMap { $0 > 0 && $0 <= 10_000_000 ? $0 : nil }, version: args["version"]), newTab: true)
        case "investigation": navigate(.investigation(id), newTab: true); await investigation.openRecord(id)
        default: break
        }
    }
}
extension String { var nonempty: String? { isEmpty ? nil : self } }
extension EventKind {
    var label: String {
        switch self { case .user: return LensL10n.text("Utilisateur"); case .assistant: return LensL10n.text("Réponse"); case .instruction: return LensL10n.text("Instruction"); case .toolCall: return LensL10n.text("Appel"); case .toolResult: return LensL10n.text("Résultat"); case .delegation: return LensL10n.text("Délégation"); case .wait: return LensL10n.text("Attente"); case .error: return LensL10n.text("Erreur"); case .lifecycle: return LensL10n.text("Cycle"); case .context: return LensL10n.text("Contexte"); case .compaction: return LensL10n.text("Compactage"); case .unknown: return LensL10n.text("Trace brute") }
    }
    var color: Color { Color(nsColor: LensBrand.eventNSColor(self)) }
}
extension ResourceRole {
    var label: String {
        switch self { case .supplied: return LensL10n.text("Fourni"); case .referenced: return LensL10n.text("Référencé"); case .recordedRead: return LensL10n.text("Lecture enregistrée"); case .modified: return LensL10n.text("Modifié"); case .produced: return LensL10n.text("Produit") }
    }
}
