import Foundation

public enum SessionTrendMetric: String, CaseIterable, Identifiable, Sendable {
    case activity, toolCalls, mcpCalls, requestedFileChanges, errors, waits, compactions
    public var id: String { rawValue }
}

/// These projections contain counts, not continuous measurements. Sparse
/// occurrences use stems; dense intervals use bars; a cumulative count uses steps.
public enum SessionTrendChartStyle: Sendable, Equatable { case intervalBars, eventStems, cumulativeSteps }

/// Counts refer to recorded items, not execution success, causality or productivity.
/// A bucket covers [start, end); the closed period serves the existing timeline filter.
public struct SessionTrendBucket: Identifiable, Sendable {
    public let id: String
    public let start: Date
    public let end: Date
    public let counts: [SessionTrendMetric: Int]
    public let cumulativeCounts: [SessionTrendMetric: Int]
    public func count(for metric: SessionTrendMetric) -> Int { counts[metric, default: 0] }
    public func cumulativeCount(for metric: SessionTrendMetric) -> Int { cumulativeCounts[metric, default: 0] }
    public var period: ClosedRange<Date> {
        start...Date(timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextDown)
    }
}

/// Pure metadata projection. No journal, filesystem, Git, command or credential access.
/// Plotted storage is capped at 240 buckets; source IDs remain available for drilldown.
/// A zero is an absence of matching recorded items, not proof that nothing happened.
public struct SessionTrendProjection: Sendable {
    public let buckets: [SessionTrendBucket]
    /// All matching recorded items, including those which cannot be placed in time.
    public let totalCounts: [SessionTrendMetric: Int]
    public let unplottedCounts: [SessionTrendMetric: Int]
    public let excludedTimestampEventIDs: [String]
    public let sourceEventCount: Int
    public let datedEventCount: Int
    public let coverage: [CoverageIssue]
    public let bucketWidth: TimeInterval?
    public let recordedPeriod: ClosedRange<Date>?
    public var unknownTimestampCount: Int { excludedTimestampEventIDs.count }
    public var coverageLimitCount: Int { coverage.count }
    public var recordedEventCount: Int { sourceEventCount }
    private let sourceIDs: [String: [SessionTrendMetric: [String]]]
    private let undatedIDs: [SessionTrendMetric: [String]]
    private let bucketIndices: [String: Int]
    private let activeBucketCounts: [SessionTrendMetric: Int]

    public func chartStyle(for metric: SessionTrendMetric, cumulative: Bool) -> SessionTrendChartStyle {
        if cumulative { return .cumulativeSteps }
        let active = activeBucketCounts[metric, default: 0]
        // A bounded visual-density choice, not an assessment of agent behavior.
        return active > 0 && active <= 16 && active * 4 <= buckets.count ? .eventStems : .intervalBars
    }

    /// Chart marks at interval ends still address their half-open source bucket.
    /// Clamp plot-edge gestures to available intervals, including the zero origin.
    public func selectionDate(at date: Date, cumulative: Bool) -> Date? {
        guard let first = buckets.first, let last = buckets.last, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let value = cumulative ? Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextDown) : date
        return max(first.start, min(last.period.upperBound, value))
    }

    public func eventIDs(for metric: SessionTrendMetric, in bucketID: String) -> [String] {
        sourceIDs[bucketID]?[metric] ?? []
    }
    public func unplottedEventIDs(for metric: SessionTrendMetric) -> [String] { undatedIDs[metric] ?? [] }
    public func bucket(id: String) -> SessionTrendBucket? { bucketIndices[id].map { buckets[$0] } }
    public func bucket(containing date: Date) -> SessionTrendBucket? {
        guard let width = bucketWidth, Self.valid(date) != nil else { return nil }
        return bucket(id: Self.bucketID(index: Self.index(date, width: width), width: width))
    }

    /// Input is the current filtered metadata, including recorded descendants.
    /// The existing context index determines compaction identity and mirror removal.
    /// Counts are placed at recorded timestamps; overlapping-duration filters may
    /// include an invocation which started before the filter's selected period.
    public init(events: [LensEvent], changesByEvent: [String: [ChangeRecord]] = [:],
                contextInspection: ContextInspectionIndex? = nil, coverage: [CoverageIssue] = [],
                maxBucketCount: Int = 240) throws {
        try Task.checkCancellation()
        var unique: [LensEvent] = [], seenIDs = Set<String>()
        unique.reserveCapacity(events.count)
        for (offset, event) in events.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard seenIDs.insert(event.id).inserted,
                  event.trace?.communication?.instructionKind != .inherited else { continue }
            if let compaction = contextInspection?.compactionByEventID[event.id] {
                guard compaction.eventID == event.id else { continue }
                var canonical = event
                if let start = compaction.startTime { canonical.timestamp = start }
                unique.append(canonical)
            } else { unique.append(event) }
        }
        self.coverage = coverage
        sourceEventCount = unique.count
        var datesByID: [String: Date] = [:], excluded: [String] = []
        var lower: Date?, upper: Date?
        datesByID.reserveCapacity(unique.count)
        for (offset, event) in unique.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            if let date = Self.valid(event.timestamp) {
                datesByID[event.id] = date
                lower = lower.map { min($0, date) } ?? date
                upper = upper.map { max($0, date) } ?? date
            } else { excluded.append(event.id) }
        }
        excludedTimestampEventIDs = excluded.sorted()
        datedEventCount = datesByID.count
        var contributions: [Contribution] = []
        contributions.reserveCapacity(unique.count)
        var groups: [CallKey: [LensEvent]] = [:], callKeyByEvent: [String: CallKey] = [:]
        for event in unique {
            let facts = event.trace?.toolObservation
            if Self.isInvocation(event) || event.kind == .toolResult || event.kind == .error,
               let call = Self.nonempty(facts?.callID ?? event.callID) {
                callKeyByEvent[event.id] = CallKey(agent: event.agentID, call: call)
            } else if Self.isInvocation(event) { callKeyByEvent[event.id] = CallKey(agent: event.agentID, call: "", eventID: event.id) }
        }
        var changes = Set<ChangeKey>(), requestedCounts: [RequestOwner: Int] = [:]
        var requestedSources: [RequestOwner: Set<String>] = [:], standaloneRequests: [RequestOwner: LensEvent] = [:]
        for (offset, event) in unique.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            let compaction = contextInspection?.compactionByEventID[event.id]
            contributions.append(Contribution(metric: .activity, event: event, ids: compaction?.eventIDs ?? [event.id]))
            if compaction?.isCountedOperation == true {
                contributions.append(Contribution(metric: .compactions, event: event, ids: compaction?.eventIDs ?? [event.id]))
            }
            let direct = callKeyByEvent[event.id]
            // An explicit link may associate a result without a copied call ID.
            let linked = event.relatedEventID.flatMap { callKeyByEvent[$0] }.flatMap { $0.agent == event.agentID ? $0 : nil }
            let key = direct ?? linked
            if let key { groups[key, default: []].append(event) }
            else {
                if Self.isError(event) { contributions.append(Contribution(metric: .errors, date: Self.errorDate(event), ids: [event.id])) }
                if event.kind == .wait { contributions.append(Contribution(metric: .waits, event: event)) }
            }
            let owner = key.map(RequestOwner.call) ?? .event(event.id)
            for change in changesByEvent[event.id] ?? [] where change.kind == .requestedPatch && change.eventID == event.id {
                requestedSources[owner, default: []].insert(event.id)
                if key == nil { standaloneRequests[owner] = event }
                if changes.insert(ChangeKey(owner: owner, environment: change.environmentID, path: change.path)).inserted {
                    requestedCounts[owner, default: 0] += 1
                }
            }
        }
        for (offset, entry) in groups.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            let key = entry.key, group = entry.value
            let ids = group.map(\.id).sorted()
            let invocations = group.filter(Self.isInvocation)
            let invocation = Self.first(invocations)
            if let invocation {
                contributions.append(Contribution(metric: .toolCalls, event: invocation, ids: ids))
                if invocations.contains(where: { Self.isMCP($0.toolName ?? $0.trace?.toolObservation?.toolName) }) {
                    contributions.append(Contribution(metric: .mcpCalls, event: invocation, ids: ids))
                }
            }
            if let error = Self.firstError(group) { contributions.append(Contribution(metric: .errors, date: Self.errorDate(error), ids: ids)) }
            if let wait = Self.first(group.filter { $0.kind == .wait }) { contributions.append(Contribution(metric: .waits, event: wait, ids: ids)) }
            if let count = requestedCounts[.call(key)], let anchor = invocation ?? Self.first(group) {
                contributions.append(Contribution(metric: .requestedFileChanges, event: anchor, amount: count,
                                                  ids: Array(Set(ids).union(requestedSources[.call(key)] ?? []))))
            }
        }
        for (owner, event) in standaloneRequests {
            contributions.append(Contribution(metric: .requestedFileChanges, event: event, amount: requestedCounts[owner, default: 0],
                                              ids: Array(requestedSources[owner] ?? [])))
        }
        // Completed items can carry a start timestamp while their failure is
        // recorded at the end. Include those explicit metric dates in the range.
        for (offset, contribution) in contributions.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            if let date = contribution.date {
                lower = lower.map { min($0, date) } ?? date
                upper = upper.map { max($0, date) } ?? date
            }
        }
        recordedPeriod = lower.flatMap { start in upper.map { start...$0 } }
        // UTC bins straddling the epoch need at least two intervals.
        let limit = min(240, max(2, maxBucketCount))
        let width = lower.flatMap { start in upper.map { Self.width(from: start, through: $0, limit: limit) } }
        bucketWidth = width
        var counts: [Int64: [SessionTrendMetric: Int]] = [:]
        var ids: [Int64: [SessionTrendMetric: Set<String>]] = [:]
        var totals: [SessionTrendMetric: Int] = [:], unplotted: [SessionTrendMetric: Int] = [:]
        var undated: [SessionTrendMetric: Set<String>] = [:]
        for (offset, contribution) in contributions.enumerated() {
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
            totals[contribution.metric, default: 0] += contribution.amount
            guard let date = contribution.date, let width else {
                unplotted[contribution.metric, default: 0] += contribution.amount
                undated[contribution.metric, default: []].formUnion(contribution.ids)
                continue
            }
            let index = Self.index(date, width: width)
            counts[index, default: [:]][contribution.metric, default: 0] += contribution.amount
            ids[index, default: [:]][contribution.metric, default: []].formUnion(contribution.ids)
        }
        totalCounts = totals; unplottedCounts = unplotted
        undatedIDs = undated.mapValues { Self.ordered($0, dates: datesByID) }
        var result: [SessionTrendBucket] = [], byID: [String: [SessionTrendMetric: [String]]] = [:]
        var indices: [String: Int] = [:], cumulative: [SessionTrendMetric: Int] = [:], active: [SessionTrendMetric: Int] = [:]
        if let lower, let upper, let width {
            let first = Self.index(lower, width: width), last = Self.index(upper, width: width)
            for index in first...last {
                let values = counts[index] ?? [:]
                for metric in SessionTrendMetric.allCases {
                    cumulative[metric, default: 0] += values[metric, default: 0]
                    if values[metric, default: 0] > 0 { active[metric, default: 0] += 1 }
                }
                let id = Self.bucketID(index: index, width: width)
                indices[id] = result.count
                result.append(SessionTrendBucket(id: id, start: Date(timeIntervalSince1970: Double(index) * width),
                                                 end: Date(timeIntervalSince1970: Double(index + 1) * width),
                                                 counts: values, cumulativeCounts: cumulative))
                byID[id] = ids[index]?.mapValues { Self.ordered($0, dates: datesByID) } ?? [:]
            }
        }
        buckets = result; sourceIDs = byID; bucketIndices = indices
        activeBucketCounts = active
    }

    private struct CallKey: Hashable { var agent: String; var call: String; var eventID: String? = nil }
    private enum RequestOwner: Hashable { case call(CallKey), event(String) }
    private struct ChangeKey: Hashable { var owner: RequestOwner; var environment: String; var path: String }
    private struct Contribution {
        var metric: SessionTrendMetric; var date: Date?; var amount: Int; var ids: [String]
        init(metric: SessionTrendMetric, event: LensEvent, amount: Int = 1, ids: [String]? = nil) {
            self.metric = metric; date = SessionTrendProjection.valid(event.timestamp)
            self.amount = amount; self.ids = ids ?? [event.id]
        }
        init(metric: SessionTrendMetric, date: Date?, amount: Int = 1, ids: [String]) {
            self.metric = metric; self.date = date; self.amount = amount; self.ids = ids
        }
    }
    private static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    private static func isInvocation(_ event: LensEvent) -> Bool {
        event.kind == .toolCall || ((event.kind == .delegation || event.kind == .wait) && nonempty(event.toolName ?? event.trace?.toolObservation?.toolName) != nil)
    }
    private static func isError(_ event: LensEvent) -> Bool {
        let facts = event.trace?.toolObservation
        return event.isError || event.kind == .error || facts?.exitCode.map { $0 != 0 } == true
            || facts?.status.map { ["failed", "error", "rejected", "declined"].contains($0.lowercased()) } == true
    }
    private static func errorDate(_ event: LensEvent) -> Date? {
        // An output/error record already has the output's own recorded time.
        if event.kind == .toolResult || event.kind == .error { return valid(event.timestamp) }
        if let end = event.trace?.toolObservation?.recordedEndTime ?? event.endTime { return valid(end) }
        // A completed item without an end boundary cannot establish when its
        // failure happened; its timestamp may only be started_at_ms.
        if event.trace?.toolObservation?.executionEvidence.contains(.completedItem) == true { return nil }
        return valid(event.timestamp)
    }
    private static func firstError(_ events: [LensEvent]) -> LensEvent? {
        let errors = events.filter(isError)
        let explicit = errors.filter { $0.kind == .toolResult || $0.kind == .error }
        return (explicit.isEmpty ? errors : explicit).min { left, right in
            let lhs = errorDate(left), rhs = errorDate(right)
            if let lhs, let rhs, lhs != rhs { return lhs < rhs }
            if (lhs != nil) != (rhs != nil) { return lhs != nil }
            return left.id < right.id
        }
    }
    private static func isMCP(_ name: String?) -> Bool {
        guard let name, name.hasPrefix("mcp__") else { return false }
        let parts = name.components(separatedBy: "__")
        return parts.count >= 3 && parts[0] == "mcp" && !parts[1].isEmpty && parts.dropFirst(2).allSatisfy { !$0.isEmpty }
    }
    private static func first(_ events: [LensEvent]) -> LensEvent? {
        events.min { left, right in
            let lhs = valid(left.timestamp), rhs = valid(right.timestamp)
            if let lhs, let rhs, lhs != rhs { return lhs < rhs }
            if (lhs != nil) != (rhs != nil) { return lhs != nil }
            return left.id < right.id
        }
    }
    private static func ordered(_ ids: Set<String>, dates: [String: Date]) -> [String] {
        ids.sorted { left, right in
            let lhs = dates[left], rhs = dates[right]
            if let lhs, let rhs, lhs != rhs { return lhs < rhs }
            if (lhs != nil) != (rhs != nil) { return lhs != nil }
            return left < right
        }
    }
    /// Reject missing sentinel dates, non-finite values and dates outside the
    /// supported Gregorian display range. They remain counted and drillable.
    private static func valid(_ date: Date) -> Date? {
        let value = date.timeIntervalSince1970
        return date != .distantPast && value.isFinite && (-62_135_596_800...253_402_300_799).contains(value) ? date : nil
    }
    private static func index(_ date: Date, width: TimeInterval) -> Int64 { Int64(floor(date.timeIntervalSince1970 / width)) }
    private static func bucketID(index: Int64, width: TimeInterval) -> String { "utc:\(Int64(width)):\(index)" }
    private static func width(from lower: Date, through upper: Date, limit: Int) -> TimeInterval {
        // Integer UTC-aligned widths remain stable when an append fits the same
        // resolution. Unlike min-date anchoring, old bucket IDs do not drift.
        let familiar: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 21_600, 43_200, 86_400, 172_800, 604_800, 1_209_600, 2_592_000, 7_776_000, 31_536_000]
        func fits(_ width: TimeInterval) -> Bool { index(upper, width: width) - index(lower, width: width) + 1 <= Int64(limit) }
        for width in familiar where fits(width) { return width }
        var width = familiar.last!
        while !fits(width) { width *= 2 }
        return width
    }
}
