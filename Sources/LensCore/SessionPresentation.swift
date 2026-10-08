import Foundation

public struct EventFilters: Equatable, Sendable {
    public var agentID: String?
    public var environmentID: String?
    public var resourceID: String?
    public var kind: EventKind?
    public var period: ClosedRange<Date>?
    public var query: String
    public var sourceMatches: Set<String>?
    public var originInstructionID: String?
    public var changeKind: ChangeKind?
    public init(agentID: String? = nil, environmentID: String? = nil, resourceID: String? = nil, kind: EventKind? = nil, period: ClosedRange<Date>? = nil, query: String = "", sourceMatches: Set<String>? = nil, originInstructionID: String? = nil, changeKind: ChangeKind? = nil) {
        self.agentID = agentID; self.environmentID = environmentID; self.resourceID = resourceID; self.kind = kind; self.period = period; self.query = query; self.sourceMatches = sourceMatches
        self.originInstructionID = originInstructionID
        self.changeKind = changeKind
    }
    public func includes(_ event: LensEvent) -> Bool {
        (agentID == nil || event.agentID == agentID) && (environmentID == nil || event.environmentID == environmentID) &&
        (resourceID == nil || event.resourceIDs.contains(resourceID!)) && (kind == nil || event.kind == kind) &&
        (period == nil || event.overlaps(period!)) &&
        (query.isEmpty || (sourceMatches?.contains(event.id) ?? (event.title + event.preview).localizedCaseInsensitiveContains(query)))
    }
}

/// A separate query for the agent graph. Recorded event matches are evidence of
/// association, not author attribution or a reason to change the activity filters.
public struct AgentFilters: Equatable, Sendable {
    public var query: String
    public var sourceMatches: Set<String>?
    public init(query: String = "", sourceMatches: Set<String>? = nil) { self.query = query; self.sourceMatches = sourceMatches }
}

public struct SessionPresentation: Sendable {
    public let id: UUID
    public let rootID: String
    public let filteredEvents: [LensEvent]
    public let filteredCalls: [LensEvent]
    /// Undated records remain in the list; they must not stretch the time axis to year one.
    public let timelineEvents: [LensEvent]
    public let callCount: Int
    public let filteredEventRowIndices: [String: Int]
    public let filteredCallRowIndices: [String: Int]
    public let eventsByID: [String: LensEvent]
    public let agentsByID: [String: AgentRecord]
    /// All recorded event IDs grouped by their recorded agent; unaffected by presentation filters.
    public let eventIDsByAgent: [String: [String]]
    public let eventCountByAgent: [String: Int]
    /// Stable flattened recorded parent graph. Search is already applied on the actor executor.
    public let agentRows: [(AgentRecord, Int)]
    public let changesByEvent: [String: [ChangeRecord]]
    public let changesByID: [String: ChangeRecord]
    /// Up to twelve recorded patches/observations, ordered by their source event's
    /// recorded timestamp. Independent of activity filters; not evidence of success.
    public let recentRecordedChanges: [ChangeRecord]
    public let resourcesByID: [String: ResourceRecord]
    public let contextInspection: ContextInspectionIndex
    public let communicationInspection: CommunicationInspectionIndex
    public let filteredCommunications: [RecordedCommunication]
    public let changesByAgent: [String: [ChangeRecord]]
    public let sequence: CommunicationSequenceProjection
    public let activityEvidence: ActivityEvidenceIndex
    public let filteredChanges: [ChangeRecord]
    public let changesOverviewIndex: ChangesOverviewIndex
    public let changesOverview: ChangesOverviewProjection
    public let originInspection: OriginInspectionIndex
    public let trends: SessionTrendProjection
}

/// One builder per window. Filter changes reuse indexes; all preparation is on
/// the actor executor, never in SwiftUI body or in a row's selected-state lookup.
public actor SessionPresentationBuilder {
    private var revision: Int?
    private var indexed: SessionPresentation?
    private var agentSearchText: [String: String] = [:]
    private var lastPrepared: SessionPresentation?
    private var lastFilters: EventFilters?
    private var lastAgentFilters: AgentFilters?
    // One shared reference to the published generation, not a history cache.
    // Its dictionaries must survive until the UI has replaced that generation,
    // so their final destruction occurs on this actor instead of the UI thread.
    private var published: SessionPresentation?
    private var publishedSequence: UInt64?
    internal var publishedPresentationID: UUID? { published?.id }
    public init() {}
    public func invalidateCache() { revision = nil; indexed = nil; agentSearchText = [:]; lastPrepared = nil; lastFilters = nil; lastAgentFilters = nil; published = nil; publishedSequence = nil }
    /// Acknowledge only after assignment on the UI. At most one published index
    /// is retained; out-of-order acknowledgements cannot retain an older index.
    public func didPublish(_ presentation: SessionPresentation, sequence: UInt64) {
        guard !Task.isCancelled, publishedSequence.map({ sequence > $0 }) ?? true else { return }
        let span = LensSignposts.begin("PresentationRetire"); defer { span.end() }
        published = presentation; publishedSequence = sequence
    }
    public func prepare(snapshot: SessionSnapshot, revision: Int, filters: EventFilters, agentFilters: AgentFilters? = nil, progress: OperationProgressHandler? = nil) throws -> SessionPresentation {
        // Actor tasks do not have a per-run-loop autorelease boundary. Index
        // preparation parses recorded arguments and creates Foundation lookup
        // objects; keep those temporaries out of the published generation.
        try autoreleasepool {
            try prepareIndex(snapshot: snapshot, revision: revision, filters: filters, agentFilters: agentFilters, progress: progress)
        }
    }
    private func prepareIndex(snapshot: SessionSnapshot, revision: Int, filters: EventFilters, agentFilters: AgentFilters?, progress: OperationProgressHandler?) throws -> SessionPresentation {
        let span = LensSignposts.begin("SessionPresentation"); defer { span.end() }
        try Task.checkCancellation()
        let reporter = progress.map { OperationProgressReporter($0) }
        // nil keeps the original API's shared query semantics for existing consumers.
        let agentFilters = agentFilters ?? AgentFilters(query: filters.query, sourceMatches: filters.sourceMatches)
        if self.revision == revision, lastPrepared?.rootID == snapshot.root.id, lastFilters == filters, lastAgentFilters == agentFilters, let lastPrepared {
            reporter?.send(OperationProgress(stage: .filteringEvents, completed: 1, total: 1, detail: "presentation.reuse", step: 1, stepCount: 1))
            return lastPrepared
        }
        // Agent-tree search does not change the event scope. Reuse its curves,
        // rather than aggregating the same metadata for each graph query.
        let cachedTrends = self.revision == revision && lastPrepared?.rootID == snapshot.root.id && lastFilters == filters
            ? lastPrepared?.trends : nil
        let rebuildsIndex = self.revision != revision || indexed?.rootID != snapshot.root.id
        let filterStep = rebuildsIndex ? 6 : 1
        let stepCount = filterStep + (cachedTrends == nil ? 1 : 0)
        // Empty event collections still have a preparation task; do not invent
        // a phantom event or expose an unknown denominator for that task.
        let eventUnit: OperationProgress.Unit = snapshot.events.isEmpty ? .steps : .events
        let eventTotal = Int64(max(1, snapshot.events.count))
        if rebuildsIndex {
            reporter?.send(OperationProgress(stage: .indexingEvents, total: eventTotal, unit: eventUnit, step: 1, stepCount: stepCount))
            var events: [String: LensEvent] = [:]
            var eventIDsByAgent: [String: [String]] = [:]
            var eventCountByAgent: [String: Int] = [:]
            var callCount = 0
            events.reserveCapacity(snapshot.events.count)
            for (i, event) in snapshot.events.enumerated() {
                if i.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                    reporter?.send(OperationProgress(stage: .indexingEvents, completed: Int64(i), total: eventTotal, unit: .events, step: 1, stepCount: stepCount))
                }
                events[event.id] = event
                eventIDsByAgent[event.agentID, default: []].append(event.id)
                if event.trace?.communication?.instructionKind != .inherited { eventCountByAgent[event.agentID, default: 0] += 1 }
                if event.toolName != nil && event.kind != .toolResult { callCount += 1 }
            }
            let agentsByID = Dictionary(snapshot.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let agentRows = try flattenedAgents(snapshot.agents, agentsByID: agentsByID)
            var searchText: [String: String] = [:]
            for (agent, _) in agentRows {
                searchText[agent.id] = ([agent.name, agent.id, agent.mission, AgentMetadataField.searchText(agent.metadata ?? [])] + agent.environmentIDs + agent.paths).joined(separator: "\n")
            }
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .indexingEvents, completed: eventTotal, total: eventTotal, unit: eventUnit, step: 1, stepCount: stepCount))
            reporter?.send(OperationProgress(stage: .inspectingContext, total: 1, step: 2, stepCount: stepCount))
            try Task.checkCancellation()
            let contextInspection = { let span = LensSignposts.begin("ContextInspectionIndex"); defer { span.end() }; return ContextInspectionIndex(events: snapshot.events) }()
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .inspectingContext, completed: 1, total: 1, step: 2, stepCount: stepCount))
            reporter?.send(OperationProgress(stage: .inspectingCommunications, total: 1, step: 3, stepCount: stepCount))
            try Task.checkCancellation()
            let communicationInspection = { let span = LensSignposts.begin("CommunicationInspectionIndex"); defer { span.end() }; return CommunicationInspectionIndex(events: snapshot.events, agents: snapshot.agents) }()
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .inspectingCommunications, completed: 1, total: 1, step: 3, stepCount: stepCount))
            reporter?.send(OperationProgress(stage: .indexingChanges, total: 3, step: 4, stepCount: stepCount))
            try Task.checkCancellation()
            let activityEvidence = { let span = LensSignposts.begin("ActivityEvidenceIndex"); defer { span.end() }; return ActivityEvidenceIndex(events: snapshot.events, changes: snapshot.changes, resources: snapshot.resources) }()
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .indexingChanges, completed: 1, total: 3, step: 4, stepCount: stepCount))
            let changesOverview = ChangesOverviewIndex(snapshot: snapshot, activity: activityEvidence)
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .indexingChanges, completed: 2, total: 3, step: 4, stepCount: stepCount))
            let changesByID = Dictionary(snapshot.changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let recentRecordedChanges = try recentChanges(changesByID: changesByID, eventsByID: events)
            let changesByEvent = Dictionary(grouping: snapshot.changes, by: \.eventID)
            let resourcesByID = Dictionary(snapshot.resources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let changesByAgent = Dictionary(grouping: snapshot.changes, by: \.agentID)
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .indexingChanges, completed: 3, total: 3, step: 4, stepCount: stepCount))
            reporter?.send(OperationProgress(stage: .inspectingOrigin, total: 1, step: 5, stepCount: stepCount))
            try Task.checkCancellation()
            let originInspection = { let span = LensSignposts.begin("OriginInspectionIndex"); defer { span.end() }; return OriginInspectionIndex(snapshot: snapshot, communication: communicationInspection, activity: activityEvidence, sharedEventsByID: events) }()
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .inspectingOrigin, completed: 1, total: 1, step: 5, stepCount: stepCount))
            let preparedIndex = SessionPresentation(id: UUID(), rootID: snapshot.root.id, filteredEvents: [], filteredCalls: [], timelineEvents: [], callCount: callCount, filteredEventRowIndices: [:], filteredCallRowIndices: [:], eventsByID: events,
                agentsByID: agentsByID, eventIDsByAgent: eventIDsByAgent, eventCountByAgent: eventCountByAgent, agentRows: agentRows,
                changesByEvent: changesByEvent,
                changesByID: changesByID, recentRecordedChanges: recentRecordedChanges,
                resourcesByID: resourcesByID,
                contextInspection: contextInspection,
                communicationInspection: communicationInspection, filteredCommunications: [],
                changesByAgent: changesByAgent,
                sequence: CommunicationSequenceProjection(communications: [], agents: snapshot.agents),
                activityEvidence: activityEvidence,
                filteredChanges: [], changesOverviewIndex: changesOverview, changesOverview: changesOverview.projection(visibleChangeIDs: []),
                originInspection: originInspection,
                trends: try SessionTrendProjection(events: [], coverage: snapshot.coverage))
            try Task.checkCancellation()
            indexed = preparedIndex; agentSearchText = searchText
            self.revision = revision
        }
        let index = indexed!
        reporter?.send(OperationProgress(stage: .filteringEvents, total: eventTotal, unit: eventUnit, detail: "presentation.events", step: filterStep, stepCount: stepCount))
        var filtered: [LensEvent] = []; filtered.reserveCapacity(snapshot.events.count)
        for (i, event) in snapshot.events.enumerated() {
            if i.isMultiple(of: 1024) {
                try Task.checkCancellation()
                reporter?.send(OperationProgress(stage: .filteringEvents, completed: Int64(i), total: eventTotal, unit: .events, detail: "presentation.events", step: filterStep, stepCount: stepCount))
            }
            if event.trace?.communication?.instructionKind == .inherited { continue }
            // Mirrored records remain reachable through eventsByID and their recorded sources.
            var visible = event
            if let compaction = index.contextInspection.compactionByEventID[event.id] {
                guard compaction.eventID == event.id else { continue }
                visible.title = compaction.isCountedOperation ? "Compactage enregistré" : "Trace de compactage non associée"
                if let start = compaction.startTime { visible.timestamp = start; visible.endTime = compaction.endTime }
            }
            let scoped = filters.originInstructionID.map { index.originInspection.associatedEventIDsByInstruction[$0]?.contains(event.id) == true } ?? true
            if scoped && filters.includes(visible) { filtered.append(visible) }
        }
        let calls = filtered.filter { $0.toolName != nil && $0.kind != .toolResult }
        let eventRows = Dictionary(filtered.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let callRows = Dictionary(calls.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var sourceMatchedAgents = Set<String>()
        if !agentFilters.query.isEmpty, let matches = agentFilters.sourceMatches {
            for (offset, id) in matches.enumerated() {
                if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
                if let agentID = index.eventsByID[id]?.agentID { sourceMatchedAgents.insert(agentID) }
            }
        }
        let agentRows = index.agentRows.filter { agent, _ in
            agentFilters.query.isEmpty || sourceMatchedAgents.contains(agent.id) || (agentSearchText[agent.id]?.localizedCaseInsensitiveContains(agentFilters.query) == true)
        }
        let visibleIDs = Set(filtered.map(\.id))
        let communications = index.communicationInspection.communications.filter { !$0.eventIDs.allSatisfy { !visibleIDs.contains($0) } }
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .filteringEvents, completed: eventTotal, total: eventTotal, unit: eventUnit, detail: "presentation.events", step: filterStep, stepCount: stepCount))
        reporter?.send(OperationProgress(stage: .filteringEvents, total: 1, detail: "presentation.relatedFilters", step: filterStep, stepCount: stepCount))
        var changeIDs = Set<String>()
        var visitedChangeIDs = Set<String>()
        var filteredChanges: [ChangeRecord] = []
        for (offset, change) in snapshot.changes.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard visitedChangeIDs.insert(change.id).inserted else { continue }
            guard filters.changeKind == nil || filters.changeKind == change.kind,
                  filters.agentID == nil || filters.agentID == change.agentID,
                  filters.environmentID == nil || filters.environmentID == change.environmentID,
                  filters.query.isEmpty || (change.path + change.evidence).localizedStandardContains(filters.query) || filters.sourceMatches?.contains(change.eventID) == true,
                  filters.period == nil || index.eventsByID[change.eventID].map({ $0.overlaps(filters.period!) }) == true else { continue }
            changeIDs.insert(change.id); filteredChanges.append(change)
        }
        let changesOverview = index.changesOverviewIndex.projection(visibleChangeIDs: changeIDs)
        let trends: SessionTrendProjection
        if let cachedTrends { trends = cachedTrends }
        else {
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .filteringEvents, completed: 1, total: 1, detail: "presentation.relatedFilters", step: filterStep, stepCount: stepCount))
            reporter?.send(OperationProgress(stage: .preparingTrends, total: 1, step: stepCount, stepCount: stepCount))
            try Task.checkCancellation()
            let span = LensSignposts.begin("SessionTrends"); defer { span.end() }
            trends = try SessionTrendProjection(events: filtered, changesByEvent: index.changesByEvent,
                contextInspection: index.contextInspection, coverage: snapshot.coverage)
        }
        let unplottable = Set(trends.excludedTimestampEventIDs)
        let timelineEvents = unplottable.isEmpty ? filtered : filtered.filter { !unplottable.contains($0.id) }
        let result = SessionPresentation(id: UUID(), rootID: index.rootID, filteredEvents: filtered, filteredCalls: calls, timelineEvents: timelineEvents, callCount: index.callCount, filteredEventRowIndices: eventRows, filteredCallRowIndices: callRows, eventsByID: index.eventsByID, agentsByID: index.agentsByID, eventIDsByAgent: index.eventIDsByAgent, eventCountByAgent: index.eventCountByAgent, agentRows: agentRows, changesByEvent: index.changesByEvent, changesByID: index.changesByID, recentRecordedChanges: index.recentRecordedChanges, resourcesByID: index.resourcesByID, contextInspection: index.contextInspection, communicationInspection: index.communicationInspection, filteredCommunications: communications, changesByAgent: index.changesByAgent, sequence: CommunicationSequenceProjection(communications: communications, agents: snapshot.agents), activityEvidence: index.activityEvidence, filteredChanges: filteredChanges, changesOverviewIndex: index.changesOverviewIndex, changesOverview: changesOverview, originInspection: index.originInspection, trends: trends)
        try Task.checkCancellation()
        lastFilters = filters; lastAgentFilters = agentFilters; lastPrepared = result
        if cachedTrends == nil {
            reporter?.send(OperationProgress(stage: .preparingTrends, completed: 1, total: 1, step: stepCount, stepCount: stepCount))
        } else {
            reporter?.send(OperationProgress(stage: .filteringEvents, completed: 1, total: 1, detail: "presentation.relatedFilters", step: filterStep, stepCount: stepCount))
        }
        return result
    }

    /// Bounded top-K selection: O(n * 12) comparisons and at most twelve ranks.
    /// Canonical dictionary values preserve the same first-record deduplication
    /// as changesByID. Missing/unknown timestamps follow all dated changes.
    private func recentChanges(changesByID: [String: ChangeRecord], eventsByID: [String: LensEvent]) throws -> [ChangeRecord] {
        let limit = 12
        var ranked: [(change: ChangeRecord, timestamp: Date?)] = []
        ranked.reserveCapacity(limit)
        for (offset, change) in changesByID.values.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard change.kind == .requestedPatch || change.kind == .observedChange else { continue }
            let recordedDate = eventsByID[change.eventID]?.timestamp
            let timestamp: Date? = recordedDate.flatMap { $0 != .distantPast && $0.timeIntervalSince1970.isFinite ? $0 : nil }
            let insertion = ranked.firstIndex { existing in
                switch (timestamp, existing.timestamp) {
                case let (candidate?, previous?) where candidate != previous: return candidate > previous
                case (_?, nil): return true
                case (nil, _?): return false
                default: return change.id < existing.change.id
                }
            } ?? ranked.count
            guard insertion < limit else { continue }
            if ranked.count == limit { ranked.removeLast() }
            ranked.insert((change, timestamp), at: insertion)
        }
        return ranked.map(\.change)
    }

    /// Keep recorded parent IDs and relations exactly; cycle entry points are displayed once, without inventing a parent.
    private func flattenedAgents(_ agents: [AgentRecord], agentsByID: [String: AgentRecord]) throws -> [(AgentRecord, Int)] {
        var children: [String: [AgentRecord]] = [:], unique: [AgentRecord] = []
        var registered = Set<String>()
        for (offset, agent) in agents.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard registered.insert(agent.id).inserted else { continue }
            unique.append(agent)
            if let parent = agent.parentID, agentsByID[parent] != nil { children[parent, default: []].append(agent) }
        }
        for parent in Array(children.keys) {
            children[parent]?.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        }
        let roots = unique.filter { $0.parentID == nil || agentsByID[$0.parentID!] == nil }
        var rows: [(AgentRecord, Int)] = [], visited = Set<String>()
        rows.reserveCapacity(unique.count)
        for entry in roots + unique {
            guard !visited.contains(entry.id) else { continue }
            var stack: [(AgentRecord, Int)] = [(entry, 0)]
            while let (agent, depth) = stack.popLast() {
                if rows.count.isMultiple(of: 1024) { try Task.checkCancellation() }
                guard visited.insert(agent.id).inserted else { continue }
                rows.append((agent, depth))
                for child in (children[agent.id] ?? []).reversed() where !visited.contains(child.id) {
                    stack.append((child, depth + 1))
                }
            }
        }
        return rows
    }
}
