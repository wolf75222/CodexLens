import Foundation
import CoreFoundation

public enum CompactionEvidencePhase: String, Codable, Sendable {
    case started, completed, checkpoint, legacyCompleted, preHook, postHook, opaqueRepresentation
}
public enum CompactionVisibility: String, Codable, Sendable {
    case readableText, opaque, mixed, unavailable, boundaryOnly
}
public enum ContextEvidenceAssociation: String, Codable, Sendable {
    case confirmed, sourceOrderCorrelation, unassociated
}
public enum UsageEvidenceKind: String, Codable, Sendable { case cumulativeSnapshot, requestRecord }
public enum UsageMeasurementSemantics: String, Codable, Sendable {
    case cumulativeAndLastRequest, providerRequest, renderedContextEstimate, unknown
}

/// Metadata only. Recorded contents remain in their original source and are read progressively.
public struct RecordedCompactionFacts: Codable, Hashable, Sendable {
    public var phase: CompactionEvidencePhase
    public var threadID: String
    public var turnID: String?
    public var itemID: String?
    public var windowID: String?
    public var responseID: String?
    public var hookRunID: String?
    public var hookSessionID: String?
    public var trigger: String?
    public var startTime: Date?
    public var endTime: Date?
    public var visibility: CompactionVisibility
    public var readableTextPresent: Bool
    public var replacementHistoryPresent: Bool
    public var replacementItemCount: Int?
    public var opaqueItemCount: Int
    public var opaqueItemIDs: [String]
    public var limits: [String]

    public init(phase: CompactionEvidencePhase, threadID: String, turnID: String? = nil,
                itemID: String? = nil, windowID: String? = nil, responseID: String? = nil,
                hookRunID: String? = nil, hookSessionID: String? = nil, trigger: String? = nil,
                startTime: Date? = nil, endTime: Date? = nil, visibility: CompactionVisibility = .boundaryOnly,
                readableTextPresent: Bool = false, replacementHistoryPresent: Bool = false,
                replacementItemCount: Int? = nil, opaqueItemCount: Int = 0, opaqueItemIDs: [String] = [],
                limits: [String] = []) {
        self.phase = phase; self.threadID = threadID; self.turnID = turnID; self.itemID = itemID
        self.windowID = windowID; self.responseID = responseID; self.hookRunID = hookRunID
        self.hookSessionID = hookSessionID; self.trigger = trigger; self.startTime = startTime
        self.endTime = endTime; self.visibility = visibility; self.readableTextPresent = readableTextPresent
        self.replacementHistoryPresent = replacementHistoryPresent; self.replacementItemCount = replacementItemCount
        self.opaqueItemCount = opaqueItemCount; self.opaqueItemIDs = opaqueItemIDs; self.limits = limits
    }

    public static func decode(_ root: [String: Any], event: LensEvent) -> Self? {
        let payload = root["payload"] as? [String: Any] ?? root["params"] as? [String: Any] ?? root
        let rootType = ContextFields.normalized(root["type"] as? String ?? root["method"] as? String)
        let payloadType = ContextFields.normalized(payload["type"] as? String)
        let item = payload["item"] as? [String: Any] ?? [:]
        let itemType = ContextFields.normalized(item["type"] as? String)
        let run = payload["run"] as? [String: Any] ?? [:]
        let hookName = ContextFields.normalized(ContextFields.string(payload, "hook_event_name", "hookEventName")
            ?? ContextFields.string(run, "event_name", "eventName"))
        let explicitThread = ContextFields.string(payload, "thread_id", "threadId")
        let hookAgent = ContextFields.string(payload, "agent_id", "agentId")
        let thread = explicitThread ?? hookAgent ?? event.agentID
        let turn = ContextFields.string(payload, "turn_id", "turnId") ?? event.turnID
        let trigger = ContextFields.string(payload, "trigger").flatMap { ["manual", "auto"].contains($0) ? $0 : nil }
        if hookName == "precompact" || hookName == "postcompact" {
            return Self(phase: hookName == "precompact" ? .preHook : .postHook, threadID: thread, turnID: turn,
                        hookRunID: ContextFields.string(run, "id"),
                        hookSessionID: ContextFields.string(payload, "session_id", "sessionId"), trigger: trigger,
                        limits: ["Hook execution is boundary evidence, not another installed compaction."])
        }
        if rootType == "compacted" {
            let history = payload["replacement_history"] as? [[String: Any]]
            let opaque = (history ?? []).filter { ContextFields.isOpaqueCompaction($0) }
            let hasText = !(payload["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (history ?? []).contains { ContextFields.hasReadableMessage($0) }
            var limits: [String] = []
            if history == nil { limits.append("Replacement history is unavailable; current files are not historical context.") }
            if let metadata = payload["replacement_history_metadata"] as? [Any], let history, metadata.count != history.count {
                limits.append("Replacement history and metadata counts differ; the checkpoint is incomplete.")
            }
            if opaque.count > 0 { limits.append("Encrypted compaction content is opaque; absence from readable text does not prove forgetting.") }
            if !hasText && opaque.isEmpty { limits.append("No readable or opaque retained content is available in this checkpoint.") }
            return Self(phase: .checkpoint, threadID: thread, turnID: turn,
                        windowID: ContextFields.string(payload, "window_id", "windowId"),
                        responseID: ContextFields.string(payload, "compaction_response_id", "compactionResponseId"),
                        trigger: trigger, visibility: hasText ? (opaque.isEmpty ? .readableText : .mixed) : (opaque.isEmpty ? .unavailable : .opaque),
                        readableTextPresent: hasText, replacementHistoryPresent: history != nil,
                        replacementItemCount: history?.count, opaqueItemCount: opaque.count,
                        opaqueItemIDs: opaque.compactMap { ContextFields.string($0, "id") }, limits: limits)
        }
        if itemType == "contextcompaction" {
            let phase: CompactionEvidencePhase?
            if payloadType == "itemstarted" || rootType == "item/started" { phase = .started }
            else if payloadType == "itemcompleted" || rootType == "item/completed" { phase = .completed }
            else { phase = nil }
            guard let phase else { return nil }
            return Self(phase: phase, threadID: thread, turnID: turn, itemID: ContextFields.string(item, "id"),
                        startTime: ContextFields.date(payload, "started_at_ms", "startedAtMs"),
                        endTime: ContextFields.date(payload, "completed_at_ms", "completedAtMs"))
        }
        if payloadType == "contextcompacted" || rootType == "thread/compacted" {
            return Self(phase: .legacyCompleted, threadID: thread, turnID: turn,
                        limits: ["Legacy compaction notification has no durable operation identifier."])
        }
        if rootType == "responseitem", ContextFields.isCompactionType(payloadType) {
            let opaque = ContextFields.isOpaqueCompaction(payload)
            return Self(phase: .opaqueRepresentation, threadID: thread, turnID: turn,
                        visibility: opaque ? .opaque : .unavailable, opaqueItemCount: opaque ? 1 : 0,
                        opaqueItemIDs: ContextFields.string(payload, "id").map { [$0] } ?? [],
                        limits: ["A carried compaction representation does not prove a new compaction operation."])
        }
        return nil
    }
}

public struct RecordedTokenCounts: Codable, Hashable, Sendable {
    public var input: Int64?
    public var cachedInput: Int64?
    public var cacheWriteInput: Int64?
    public var output: Int64?
    public var reasoningOutput: Int64?
    public var total: Int64?
    public init(input: Int64? = nil, cachedInput: Int64? = nil, cacheWriteInput: Int64? = nil,
                output: Int64? = nil, reasoningOutput: Int64? = nil, total: Int64? = nil) {
        self.input = input; self.cachedInput = cachedInput; self.cacheWriteInput = cacheWriteInput
        self.output = output; self.reasoningOutput = reasoningOutput; self.total = total
    }
    public var isRenderedEstimateCandidate: Bool {
        input == 0 && cachedInput == 0 && output == 0 && reasoningOutput == 0
            && (cacheWriteInput == nil || cacheWriteInput == 0) && (total ?? 0) > 0
    }
    fileprivate static func decode(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any] else { return nil }
        let result = Self(input: ContextFields.number(object, "input_tokens", "inputTokens"),
                          cachedInput: ContextFields.number(object, "cached_input_tokens", "cachedInputTokens"),
                          cacheWriteInput: ContextFields.number(object, "cache_write_input_tokens", "cacheWriteInputTokens"),
                          output: ContextFields.number(object, "output_tokens", "outputTokens"),
                          reasoningOutput: ContextFields.number(object, "reasoning_output_tokens", "reasoningOutputTokens"),
                          total: ContextFields.number(object, "total_tokens", "totalTokens"))
        return [result.input, result.cachedInput, result.cacheWriteInput, result.output, result.reasoningOutput, result.total].contains { $0 != nil } ? result : nil
    }
}

public struct RecordedUsageFacts: Codable, Hashable, Sendable {
    public var kind: UsageEvidenceKind
    public var threadID: String
    public var turnID: String?
    public var responseID: String?
    public var cumulative: RecordedTokenCounts?
    public var last: RecordedTokenCounts?
    public var request: RecordedTokenCounts?
    public var modelContextWindow: Int64?
    public init(kind: UsageEvidenceKind, threadID: String, turnID: String? = nil, responseID: String? = nil,
                cumulative: RecordedTokenCounts? = nil, last: RecordedTokenCounts? = nil,
                request: RecordedTokenCounts? = nil, modelContextWindow: Int64? = nil) {
        self.kind = kind; self.threadID = threadID; self.turnID = turnID; self.responseID = responseID
        self.cumulative = cumulative; self.last = last; self.request = request; self.modelContextWindow = modelContextWindow
    }
    public static func decode(_ root: [String: Any], event: LensEvent) -> Self? {
        let payload = root["payload"] as? [String: Any] ?? root["params"] as? [String: Any] ?? root
        let rootType = ContextFields.normalized(root["type"] as? String ?? root["method"] as? String)
        let type = ContextFields.normalized(payload["type"] as? String)
        let thread = ContextFields.string(payload, "thread_id", "threadId") ?? event.agentID
        let turn = ContextFields.string(payload, "turn_id", "turnId") ?? event.turnID
        // The copied latest_token_usage_record in a compacted checkpoint is deliberately ignored.
        if rootType == "tokenusagerecord" {
            guard let request = RecordedTokenCounts.decode(payload["usage"]) else { return nil }
            return Self(kind: .requestRecord, threadID: thread, turnID: turn,
                        responseID: ContextFields.string(payload, "response_id", "responseId"),
                        cumulative: RecordedTokenCounts.decode(payload["thread_token_usage"]), request: request)
        }
        guard type == "tokencount" || rootType == "thread/tokenusage/updated" else { return nil }
        let info = payload["info"] as? [String: Any] ?? payload["tokenUsage"] as? [String: Any] ?? [:]
        let total = RecordedTokenCounts.decode(info["total_token_usage"] ?? info["total"])
        let last = RecordedTokenCounts.decode(info["last_token_usage"] ?? info["last"])
        guard total != nil || last != nil else { return nil }
        return Self(kind: .cumulativeSnapshot, threadID: thread, turnID: turn, cumulative: total, last: last,
                    modelContextWindow: ContextFields.number(info, "model_context_window", "modelContextWindow"))
    }
}

public struct RecordedUsageSample: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var eventID: String
    public var threadID: String
    public var turnID: String?
    public var timestamp: Date
    public var sourceRefs: [SourceRef]
    public var facts: RecordedUsageFacts
    public var semantics: UsageMeasurementSemantics
    public var limits: [String]
}

public struct RecordedCompaction: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var threadID: String
    public var turnID: String?
    public var eventID: String
    public var eventIDs: [String]
    public var sourceRefs: [SourceRef]
    public var operationIDs: [String]
    public var startTime: Date?
    public var endTime: Date?
    public var trigger: String?
    public var visibility: CompactionVisibility
    public var association: ContextEvidenceAssociation
    public var isInstalled: Bool
    public var isCountedOperation: Bool
    public var limits: [String]
    public var beforeUsage: RecordedUsageSample?
    public var afterUsage: RecordedUsageSample?
    public var firstFollowingActionIDs: [String]
    public var duration: TimeInterval? {
        guard let startTime, let endTime, endTime >= startTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
}

/// Pure projection over indexed events. No file reads, current-file substitution, or hook installation.
public struct ContextInspectionIndex: Sendable {
    public var compactions: [RecordedCompaction]
    public var usageSamples: [RecordedUsageSample]
    public var compactionByEventID: [String: RecordedCompaction]
    public var installedCompactionCount: Int { compactions.filter(\.isInstalled).count }
    public var identifiedOperationCount: Int { compactions.filter(\.isCountedOperation).count }

    public init(events: [LensEvent]) {
        // Most sessions have no captured context metrics or compaction evidence.
        // Their empty index does not require sorting/copying the full history.
        guard events.contains(where: { $0.trace?.compaction != nil || $0.trace?.usage != nil }) else {
            compactions = []; usageSamples = []; compactionByEventID = [:]
            return
        }
        let timelineEvents = events
        // A producer's source order is evidence even when clocks are missing or inconsistent.
        // Different source files are never bracket-correlated merely by their timestamps.
        // Sort small offsets, not LensEvent values with all recorded metadata.
        // Retain original offsets as the tie-breaker, exactly as before.
        let sourceOrder = events.indices.sorted {
            let left = (events[$0].source.path, events[$0].source.offset, events[$0].source.line)
            let right = (events[$1].source.path, events[$1].source.offset, events[$1].source.line)
            return left == right ? $0 < $1 : left < right
        }
        let entries = sourceOrder.enumerated().compactMap { index, offset -> Entry? in
            let event = events[offset]
            guard let facts = event.trace?.compaction else { return nil }
            return Entry(index: index, event: event, facts: facts)
        }
        var groups: [Group] = []
        var strongKeys: [String: Int] = [:]
        var pending: [Entry] = []
        for entry in entries {
            let keys = entry.strongKeys
            guard !keys.isEmpty, entry.facts.phase != .opaqueRepresentation else { pending.append(entry); continue }
            if let existing = keys.compactMap({ strongKeys[$0] }).first {
                groups[existing].entries.append(entry)
                for key in keys { strongKeys[key] = existing }
            } else {
                let next = groups.count
                groups.append(Group(entries: [entry], association: .confirmed))
                for key in keys { strongKeys[key] = next }
            }
        }
        // Checkpoints and lifecycle items have distinct IDs. A unique same-source bracket is only correlation.
        var absorbed = Set<Int>()
        for checkpointGroup in groups.indices {
            guard groups[checkpointGroup].entries.contains(where: { $0.facts.phase == .checkpoint }),
                  !groups[checkpointGroup].entries.contains(where: { $0.facts.phase == .started || $0.facts.phase == .completed }) else { continue }
            let marker = groups[checkpointGroup].entries.first { $0.facts.phase == .checkpoint }!
            let candidates = groups.indices.filter { candidate in
                candidate != checkpointGroup && !absorbed.contains(candidate)
                    && groups[candidate].containsInUniqueBracket(marker)
            }
            if candidates.count == 1, let target = candidates.first,
               !groups[target].entries.contains(where: { $0.facts.phase == .checkpoint }) {
                groups[target].entries.append(contentsOf: groups[checkpointGroup].entries)
                groups[target].association = .sourceOrderCorrelation
                absorbed.insert(checkpointGroup)
            } else if candidates.count > 1 {
                groups[checkpointGroup].association = .unassociated
                groups[checkpointGroup].ambiguousMirror = true
            }
        }
        groups = groups.enumerated().filter { !absorbed.contains($0.offset) }.map(\.element)
        for entry in pending {
            let exactOpaque = entry.facts.opaqueItemIDs.isEmpty ? [] : groups.indices.filter { candidate in
                groups[candidate].entries.contains { evidence in
                    evidence.facts.threadID == entry.facts.threadID
                        && !Set(evidence.facts.opaqueItemIDs).isDisjoint(with: entry.facts.opaqueItemIDs)
                        && evidence.facts.phase == .checkpoint
                }
            }
            var candidates = exactOpaque.isEmpty ? groups.indices.filter { groups[$0].containsInUniqueBracket(entry) } : exactOpaque
            if candidates.isEmpty, [.preHook, .postHook, .legacyCompleted].contains(entry.facts.phase) {
                let nearest = groups.indices.compactMap { candidate -> (Int, Int)? in
                    guard let distance = groups[candidate].adjacentBoundaryDistance(entry) else { return nil }
                    if entry.facts.phase != .preHook {
                        let boundary = entry.index - distance
                        let crossedStart = entries.contains { $0.facts.threadID == entry.facts.threadID
                            && $0.event.source.path == entry.event.source.path && $0.facts.phase == .started
                            && $0.index > boundary && $0.index < entry.index }
                        if crossedStart { return nil }
                    }
                    return (candidate, distance)
                }
                if let distance = nearest.map(\.1).min() { candidates = nearest.filter { $0.1 == distance }.map(\.0) }
            }
            if candidates.count == 1, let target = candidates.first {
                groups[target].entries.append(entry)
                if exactOpaque.isEmpty { groups[target].association = .sourceOrderCorrelation }
            } else if let existing = groups.indices.first(where: { groups[$0].isSameUnassociatedHook(entry) }) {
                groups[existing].entries.append(entry)
            } else {
                groups.append(Group(entries: [entry], association: .unassociated))
            }
        }

        var usage: [RecordedUsageSample] = []
        var usagePositions: [String: Int] = [:]
        var requestIDs: [String: Int] = [:]
        for (index, offset) in sourceOrder.enumerated() {
            let event = events[offset]
            guard let facts = event.trace?.usage else { continue }
            let key = facts.kind == .requestRecord ? facts.responseID.map { "\(facts.threadID):response:\($0)" } : nil
            if let key, let existing = requestIDs[key] {
                if usage[existing].facts != facts {
                    usage[existing].limits.append("Conflicting usage for the same response identifier; no additional charge inferred.")
                }
                for source in [event.source] + event.supplementarySources where !usage[existing].sourceRefs.contains(source) {
                    usage[existing].sourceRefs.append(source)
                }
                continue
            }
            var semantics: UsageMeasurementSemantics = facts.kind == .requestRecord ? .providerRequest : .cumulativeAndLastRequest
            var limits = ["Cumulative snapshots must not be summed; usage is not a measure of remembered content."]
            if facts.last?.isRenderedEstimateCandidate == true {
                let matchingBrackets = groups.filter { $0.isAfterCheckpointBeforeCompletion(event: event, index: index, threadID: facts.threadID) }
                if matchingBrackets.count == 1 { semantics = .renderedContextEstimate }
                else { semantics = .unknown; limits.append("Zero-component last usage is not confirmed as a rendered-context estimate.") }
            }
            let id = key ?? "usage:\(event.id)"
            if let key { requestIDs[key] = usage.count }
            usagePositions[id] = index
            usage.append(RecordedUsageSample(id: id, eventID: event.id, threadID: facts.threadID, turnID: facts.turnID,
                                              timestamp: event.timestamp, sourceRefs: [event.source] + event.supplementarySources,
                                              facts: facts, semantics: semantics, limits: limits))
        }
        usageSamples = usage
        // Index exact source-order neighbors once. Repeated scans of all events
        // for every compaction made long active histories expensive to present.
        var usageNeighbors: [SourceThreadKey: [NeighborPosition]] = [:]
        for (sampleIndex, sample) in usage.enumerated() {
            guard let position = usagePositions[sample.id] else { continue }
            for path in Set(sample.sourceRefs.map(\.path)) {
                usageNeighbors[SourceThreadKey(thread: sample.threadID, path: path), default: []]
                    .append(NeighborPosition(position: position, index: sampleIndex))
            }
        }
        var actionNeighbors: [SourceThreadKey: [NeighborPosition]] = [:]
        for (position, offset) in sourceOrder.enumerated() {
            let event = events[offset]
            guard event.trace?.compaction == nil, event.trace?.usage == nil,
                  [.user, .assistant, .toolCall, .toolResult, .delegation, .wait, .instruction].contains(event.kind) else { continue }
            actionNeighbors[SourceThreadKey(thread: event.agentID, path: event.source.path), default: []]
                .append(NeighborPosition(position: position, index: offset))
        }
        func boundary(_ entries: [NeighborPosition], position: Int, afterEqual: Bool) -> Int {
            var lower = 0, upper = entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if entries[middle].position < position || (afterEqual && entries[middle].position == position) { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }
        compactions = groups.map { group in
            let sorted = group.entries.sorted { $0.index < $1.index }
            let canonical = sorted.first { $0.facts.phase == .checkpoint } ?? sorted.first { $0.facts.phase == .completed } ?? sorted[0]
            let operationEntries = sorted.filter { [.started, .completed, .checkpoint].contains($0.facts.phase) }
            let boundaryEntries = operationEntries.isEmpty ? sorted.filter { $0.facts.phase == .legacyCompleted } : operationEntries
            let first = boundaryEntries.first?.index ?? sorted[0].index
            let last = boundaryEntries.last?.index ?? sorted.last!.index
            let starts = sorted.compactMap { $0.facts.startTime }
            let ends = sorted.compactMap { $0.facts.endTime }
            let checkpoint = sorted.first { $0.facts.phase == .checkpoint }
            let isOperation = sorted.contains { [.checkpoint, .started, .completed].contains($0.facts.phase) }
            let ids = Array(Set(sorted.flatMap(\.strongKeys))).sorted()
            let stableID = ids.first ?? "compaction:\(canonical.facts.threadID):event:\(canonical.event.id)"
            var limits = Array(Set(sorted.flatMap { $0.facts.limits })).sorted()
            if starts.isEmpty { limits.append("Operation start is unavailable; duration is unknown.") }
            if ends.isEmpty { limits.append("Operation completion time is unavailable; duration is unknown.") }
            if checkpoint == nil { limits.append("Installed replacement history is not recorded in the available checkpoint evidence.") }
            if let start = starts.min(), let end = ends.max(), end < start { limits.append("Recorded completion precedes start; duration is unknown.") }
            let triggers = Set(sorted.compactMap { $0.facts.trigger })
            if triggers.count > 1 { limits.append("Compaction trigger sources disagree; trigger remains unknown.") }
            if group.association == .sourceOrderCorrelation { limits.append("Source-order association is a correlation, not an exact shared identifier.") }
            if group.association == .unassociated { limits.append("This evidence cannot be linked to a unique operation; boundary and carried representations are not additional counted compactions.") }
            let key = SourceThreadKey(thread: canonical.facts.threadID, path: canonical.event.source.path)
            let measures = usageNeighbors[key] ?? []
            let beforeOffset = boundary(measures, position: first, afterEqual: false) - 1
            let afterOffset = boundary(measures, position: checkpoint?.index ?? last, afterEqual: true)
            let before = beforeOffset >= 0 ? usage[measures[beforeOffset].index] : nil
            let after = afterOffset < measures.count ? usage[measures[afterOffset].index] : nil
            let actions = actionNeighbors[key] ?? []
            let actionOffset = boundary(actions, position: last, afterEqual: true)
            let following = actionOffset < actions.count ? [events[actions[actionOffset].index].id] : []
            return RecordedCompaction(id: stableID, threadID: canonical.facts.threadID, turnID: canonical.facts.turnID,
                                      eventID: canonical.event.id, eventIDs: sorted.map { $0.event.id },
                                      sourceRefs: Array(Set(sorted.flatMap { [$0.event.source] + $0.event.supplementarySources })).sorted { ($0.path, $0.offset) < ($1.path, $1.offset) },
                                      operationIDs: ids, startTime: starts.min(), endTime: ends.max(),
                                      trigger: triggers.count == 1 ? triggers.first : nil,
                                      visibility: checkpoint?.facts.visibility ?? sorted.first { $0.facts.visibility != .boundaryOnly }?.facts.visibility ?? .boundaryOnly,
                                      association: group.association, isInstalled: checkpoint != nil,
                                      isCountedOperation: isOperation && !group.ambiguousMirror, limits: limits, beforeUsage: before, afterUsage: after,
                                      firstFollowingActionIDs: following)
        }
        let order = Dictionary(timelineEvents.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        compactions.sort { (order[$0.eventID] ?? Int.max) < (order[$1.eventID] ?? Int.max) }
        compactionByEventID = [:]
        for compaction in compactions { for id in compaction.eventIDs { compactionByEventID[id] = compaction } }
    }

    private struct SourceThreadKey: Hashable { let thread: String; let path: String }
    private struct NeighborPosition { let position: Int; let index: Int }

    private struct Entry {
        var index: Int
        var event: LensEvent
        var facts: RecordedCompactionFacts
        var strongKeys: [String] {
            let prefix = "compaction:\(facts.threadID):"
            var keys: [String] = []
            if let id = facts.itemID { keys.append(prefix + "item:" + id) }
            if let id = facts.windowID { keys.append(prefix + "window:" + id) }
            if let id = facts.responseID { keys.append(prefix + "response:" + id) }
            return keys
        }
    }
    private struct Group {
        var entries: [Entry]
        var association: ContextEvidenceAssociation
        var ambiguousMirror = false
        func containsInUniqueBracket(_ entry: Entry) -> Bool {
            let same = entries.filter { $0.facts.threadID == entry.facts.threadID && $0.event.source.path == entry.event.source.path
                && ($0.facts.turnID == nil || entry.facts.turnID == nil || $0.facts.turnID == entry.facts.turnID) }
            guard let start = same.filter({ $0.facts.phase == .started }).min(by: { $0.index < $1.index }),
                  let end = same.filter({ $0.facts.phase == .completed }).max(by: { $0.index < $1.index }) else { return false }
            // Hook boundaries lie outside the item interval; without an exact ID they remain unassociated.
            return entry.index > start.index && entry.index < end.index
        }
        func isSameUnassociatedHook(_ entry: Entry) -> Bool {
            guard let runID = entry.facts.hookRunID else { return false }
            return entries.contains { $0.facts.threadID == entry.facts.threadID && $0.facts.hookRunID == runID }
        }
        func adjacentBoundaryDistance(_ entry: Entry) -> Int? {
            let same = entries.filter { $0.facts.threadID == entry.facts.threadID && $0.event.source.path == entry.event.source.path
                && $0.facts.turnID != nil && $0.facts.turnID == entry.facts.turnID }
            if entry.facts.phase == .preHook {
                guard let next = same.filter({ $0.facts.phase == .started && $0.index > entry.index }).min(by: { $0.index < $1.index }) else { return nil }
                return next.index - entry.index
            }
            guard let previous = same.filter({ $0.facts.phase == .completed && $0.index < entry.index }).max(by: { $0.index < $1.index }) else { return nil }
            // A next operation already started: a legacy/post-hook record cannot be assigned backwards across it.
            if same.contains(where: { $0.facts.phase == .started && $0.index > previous.index && $0.index < entry.index }) { return nil }
            return entry.index - previous.index
        }
        func isAfterCheckpointBeforeCompletion(event: LensEvent, index: Int, threadID: String) -> Bool {
            let same = entries.filter { $0.facts.threadID == threadID && $0.event.source.path == event.source.path }
            guard let marker = same.last(where: { $0.facts.phase == .checkpoint }),
                  let completed = same.last(where: { $0.facts.phase == .completed }) else { return false }
            return index > marker.index && index < completed.index
        }
    }
}

private enum ContextFields {
    static func normalized(_ text: String?) -> String { (text ?? "").lowercased().replacingOccurrences(of: "_", with: "") }
    static func string(_ object: [String: Any], _ keys: String...) -> String? {
        keys.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }
    static func number(_ object: [String: Any], _ keys: String...) -> Int64? {
        for key in keys {
            guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 0, n.doubleValue < Double(Int64.max) else { continue }
            return n.int64Value
        }
        return nil
    }
    static func date(_ object: [String: Any], _ keys: String...) -> Date? {
        for key in keys { if let value = number(object, key), value > 0 { return Date(timeIntervalSince1970: Double(value) / 1000) } }
        return nil
    }
    static func isCompactionType(_ type: String) -> Bool { ["compaction", "compactionsummary", "contextcompaction"].contains(type) }
    static func isOpaqueCompaction(_ object: [String: Any]) -> Bool {
        isCompactionType(normalized(object["type"] as? String)) && !(object["encrypted_content"] as? String ?? "").isEmpty
    }
    static func hasReadableMessage(_ object: [String: Any]) -> Bool {
        guard normalized(object["type"] as? String) == "message", let content = object["content"] as? [[String: Any]] else { return false }
        return content.contains { !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
