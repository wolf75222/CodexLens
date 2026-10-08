import Foundation
import CryptoKit

public struct TimelineWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public init(start: Date, end: Date) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite else { throw LensError.corrupt("Fenêtre temporelle non finie.") }
        self.start = min(start, end); self.end = max(start, end)
        guard duration.isFinite else { throw LensError.corrupt("Étendue temporelle non finie.") }
    }
}
public struct TimelineBuildBudget: Sendable, Equatable {
    public let maxEvents: Int
    public let maxAgents: Int
    public let maxQueryItems: Int
    public let maxRetentionBytes: Int
    // Preparation keeps compact interval indexes, not event bodies. This is independent
    // of the bounded drawing query and of the optional 64 MiB retained preparation cache.
    public init(maxEvents: Int = 500_000, maxAgents: Int = 10_000, maxQueryItems: Int = 10_000, maxRetentionBytes: Int = 64 * 1024 * 1024) { self.maxEvents = maxEvents; self.maxAgents = maxAgents; self.maxQueryItems = maxQueryItems; self.maxRetentionBytes = maxRetentionBytes }
}
public struct TimelineLane: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let agentIsCatalogued: Bool
    public let accessible: Bool?
    public let eventCount: Int
}
public struct TimelineItem: Sendable, Identifiable, Equatable {
    public var id: String { eventID }
    public let eventID: String
    public let agentID: String
    public let laneIndex: Int
    public let lanePosition: Int
    public let start: Date
    /// Exact recorded value, including an invalid earlier end when the source has one.
    public let recordedEnd: Date?
    public let kind: EventKind
    public let isError: Bool
    public var effectiveKind: EventKind { isError ? .error : kind }
    public var effectiveEnd: Date { recordedEnd.map { max(start, $0) } ?? start }
    public var recordedDuration: TimeInterval? { guard let end = recordedEnd, end >= start else { return nil }; return end.timeIntervalSince(start) }
    public var hasInvalidRecordedDuration: Bool { recordedEnd.map { $0 < start } ?? false }
    public func overlap(with window: TimelineWindow) -> TimelineOverlap? {
        guard effectiveEnd >= window.start, start <= window.end else { return nil }
        return TimelineOverlap(visibleStart: max(start, window.start), visibleEnd: min(effectiveEnd, window.end), startsBeforeWindow: start < window.start, endsAfterWindow: effectiveEnd > window.end)
    }
}
public struct TimelineOverlap: Sendable, Equatable {
    public let visibleStart: Date
    public let visibleEnd: Date
    public let startsBeforeWindow: Bool
    public let endsAfterWindow: Bool
}
public struct TimelineVisibleResult: Sendable {
    public let items: [TimelineItem]
    public let totalMatches: Int
    public let limitApplied: Int
    public let visitedNodes: Int
    public var omittedCount: Int { totalMatches - items.count }
    public var isComplete: Bool { omittedCount == 0 }
}
public struct TimelineDensityResult: Sendable {
    public let details: [TimelineItem]
    public let clusters: [TimelineDensityCluster]
    /// Unique items intersecting the full visible range, not the sum of cluster counts.
    public let totalMatches: Int
    public let visitedNodes: Int
}
public struct TimelineDensityCluster: Sendable, Identifiable {
    public let id: String
    public let laneIndex: Int
    /// Display bin bounds; marker padding is used for counting, not added to this period.
    public let window: TimelineWindow
    /// A long interval may intersect several bins. This count is exact for this bin.
    public let count: Int
    public let errorCount: Int
    public let compactionCount: Int
    /// Exact display-type composition of all intersecting items. Failed items
    /// contribute to .error, matching individual marks; samples are not used.
    public let kindCounts: [EventKind: Int]
    /// A bounded, deterministic sample in the projection's temporal order.
    public let sampleEventIDs: [String]
}
public struct TimelineHitResult: Sendable {
    /// Ranked by distance to recorded start, then stable temporal order; never a causal inference.
    public let eventIDs: [String]
    public let totalHits: Int?
    public let uninspectedCandidates: Int
    public var isComplete: Bool { uninspectedCandidates == 0 }
    public var requiresDisambiguation: Bool { eventIDs.count > 1 || !isComplete }
}
public struct TimelineRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public func contains(x pointX: Double, y pointY: Double, tolerance: Double = 0) -> Bool { pointX >= x - tolerance && pointX <= maxX + tolerance && pointY >= y - tolerance && pointY <= maxY + tolerance }
}

/// Pure drawing coordinates. Padding changes only the display axis, never a recorded duration.
public struct TimelineGeometry: Sendable {
    public let window: TimelineWindow
    public let contentWidth: Double
    public let labelWidth: Double
    public let rightInset: Double
    public let rulerHeight: Double
    public let laneHeight: Double
    public let barHeight: Double
    public let barInset: Double
    public let minimumMarkerWidth: Double
    public let minimumTimeSpan: Double
    public let minimumSpanPaddingApplied: Bool
    public var timeWidth: Double { contentWidth - labelWidth - rightInset }
    public init(window: TimelineWindow, contentWidth: Double, labelWidth: Double = 145, rightInset: Double = 20, rulerHeight: Double = 46, laneHeight: Double = 46, barHeight: Double = 20, barInset: Double = 12, minimumMarkerWidth: Double = 5, minimumTimeSpan: Double = 1) throws {
        let values = [contentWidth, labelWidth, rightInset, rulerHeight, laneHeight, barHeight, barInset, minimumMarkerWidth, minimumTimeSpan]
        guard values.allSatisfy(\.isFinite), contentWidth > labelWidth + rightInset, labelWidth >= 0, rightInset >= 0, rulerHeight >= 0, laneHeight > 0, barHeight > 0, barInset >= 0, barInset + barHeight <= laneHeight, minimumMarkerWidth > 0, minimumTimeSpan > 0 else { throw LensError.unsupported("Géométrie de chronologie invalide.") }
        self.window = try TimelineWindow(start: window.start, end: window.start.addingTimeInterval(max(window.duration, minimumTimeSpan)))
        self.minimumTimeSpan = minimumTimeSpan
        self.minimumSpanPaddingApplied = window.duration < minimumTimeSpan
        self.contentWidth = contentWidth; self.labelWidth = labelWidth; self.rightInset = rightInset; self.rulerHeight = rulerHeight; self.laneHeight = laneHeight; self.barHeight = barHeight; self.barInset = barInset; self.minimumMarkerWidth = minimumMarkerWidth
    }
    public func x(for date: Date) -> Double { labelWidth + date.timeIntervalSince(window.start) / window.duration * timeWidth }
    public func date(atX x: Double, clamped: Bool = true) -> Date {
        let ratio = (x - labelWidth) / timeWidth
        return window.start.addingTimeInterval((clamped ? min(1, max(0, ratio)) : ratio) * window.duration)
    }
    public func lane(atY y: Double) -> Int? { guard y.isFinite, y >= rulerHeight, (y - rulerHeight) / laneHeight < Double(Int.max) else { return nil }; return Int(floor((y - rulerHeight) / laneHeight)) }
    public func rect(for item: TimelineItem) -> TimelineRect { let start = x(for: item.start); return TimelineRect(x: start, y: rulerHeight + Double(item.laneIndex) * laneHeight + barInset, width: max(minimumMarkerWidth, x(for: item.effectiveEnd) - start), height: barHeight) }
    public func window(forXRange range: ClosedRange<Double>, includingMarkerPadding: Bool = true) throws -> TimelineWindow {
        try TimelineWindow(start: date(atX: range.lowerBound - (includingMarkerPadding ? minimumMarkerWidth : 0), clamped: false), end: date(atX: range.upperBound, clamped: false))
    }
}

/// Immutable, prepared off the UI thread. Geometry/window queries never sort source events.
public struct TimelineProjection: Sendable {
    public let lanes: [TimelineLane]
    public let bounds: TimelineWindow?
    public let fingerprintSHA256: String
    public let invalidDurationEventIDs: [String]
    public let maxQueryItems: Int
    public let orderedEventIDs: [String]
    private let items: [TimelineItem]
    private let indexByID: [String: Int]
    private let laneIndexes: [TimelineLaneIndex]
    public var eventCount: Int { items.count }

    public static func prepare(events: [LensEvent], agents: [AgentRecord], budget: TimelineBuildBudget = TimelineBuildBudget(), progress: OperationProgressHandler? = nil) throws -> TimelineProjection {
        try prepare(events: events, agents: agents, budget: budget, reporter: progress.map { OperationProgressReporter($0) }, stepCount: 5)
    }

    fileprivate static func prepare(events: [LensEvent], agents: [AgentRecord], budget: TimelineBuildBudget, reporter: OperationProgressReporter?, stepCount: Int) throws -> TimelineProjection {
        let span = LensSignposts.begin("TimelineProjection"); defer { span.end() }
        guard budget.maxEvents >= 0, budget.maxAgents >= 0, budget.maxQueryItems > 0, budget.maxRetentionBytes >= 0, events.count <= budget.maxEvents else { throw LensError.unsupported("Budget de préparation de chronologie dépassé ou invalide (\(events.count) événements, limite \(budget.maxEvents)).") }
        try Task.checkCancellation()
        let eventUnit: OperationProgress.Unit = events.isEmpty ? .steps : .events
        let eventTotal = Int64(max(1, events.count))
        reporter?.send(OperationProgress(stage: .preparingTimeline, total: eventTotal, unit: eventUnit, detail: "timeline.validate", step: 1, stepCount: stepCount))
        var agentIDs = Set<String>(), laneAgents: [(id: String, name: String, known: Bool, accessible: Bool?)] = []
        for agent in agents { guard agentIDs.insert(agent.id).inserted else { throw LensError.corrupt("Agent dupliqué dans la chronologie : \(agent.id).") }; laneAgents.append((agent.id, agent.name.isEmpty ? agent.id : agent.name, true, agent.accessible)) }
        var eventIDs = Set<String>(), missingAgentIDs = Set<String>()
        for (offset, event) in events.enumerated() {
            if offset % 4096 == 0 {
                try Task.checkCancellation()
                reporter?.send(OperationProgress(stage: .preparingTimeline, completed: Int64(offset), total: eventTotal, unit: .events, detail: "timeline.validate", step: 1, stepCount: stepCount))
            }
            guard eventIDs.insert(event.id).inserted else { throw LensError.corrupt("Identifiant d'événement dupliqué : \(event.id).") }
            guard event.timestamp.timeIntervalSince1970.isFinite, event.endTime?.timeIntervalSince1970.isFinite != false else { throw LensError.corrupt("Horodatage non fini pour \(event.id).") }
            if !agentIDs.contains(event.agentID) { missingAgentIDs.insert(event.agentID) }
        }
        for id in missingAgentIDs.sorted() { laneAgents.append((id, "Agent non catalogué · \(id)", false, nil)) }
        guard laneAgents.count <= budget.maxAgents else { throw LensError.unsupported("Budget de pistes dépassé (\(laneAgents.count), limite \(budget.maxAgents)).") }
        let laneByID = Dictionary(uniqueKeysWithValues: laneAgents.enumerated().map { ($0.element.id, $0.offset) })
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .preparingTimeline, completed: eventTotal, total: eventTotal, unit: eventUnit, detail: "timeline.validate", step: 1, stepCount: stepCount))
        reporter?.send(OperationProgress(stage: .preparingTimeline, total: 1, detail: "timeline.sort", step: 2, stepCount: stepCount))
        try Task.checkCancellation()
        let ordered = events.indices.sorted { a, b in
            let first = events[a], second = events[b]
            if first.timestamp != second.timestamp { return first.timestamp < second.timestamp }
            if first.agentID != second.agentID { return first.agentID < second.agentID }
            if first.source.path != second.source.path { return first.source.path < second.source.path }
            if first.source.offset != second.source.offset { return first.source.offset < second.source.offset }
            if first.source.line != second.source.line { return first.source.line < second.source.line }
            return first.id < second.id
        }
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .preparingTimeline, completed: 1, total: 1, detail: "timeline.sort", step: 2, stepCount: stepCount))
        reporter?.send(OperationProgress(stage: .preparingTimeline, total: eventTotal, unit: eventUnit, detail: "timeline.build", step: 3, stepCount: stepCount))
        var built: [TimelineItem] = []; built.reserveCapacity(events.count)
        var byID: [String: Int] = [:]; byID.reserveCapacity(events.count)
        var perLane = Array(repeating: [Int](), count: laneAgents.count)
        var invalid: [String] = []
        var first: Date?, last: Date?
        for sourceIndex in ordered {
            if built.count % 4096 == 0 {
                try Task.checkCancellation()
                reporter?.send(OperationProgress(stage: .preparingTimeline, completed: Int64(built.count), total: eventTotal, unit: .events, detail: "timeline.build", step: 3, stepCount: stepCount))
            }
            let event = events[sourceIndex], lane = laneByID[event.agentID]!
            let item = TimelineItem(eventID: event.id, agentID: event.agentID, laneIndex: lane, lanePosition: perLane[lane].count, start: event.timestamp, recordedEnd: event.endTime, kind: event.kind, isError: event.isError)
            byID[event.id] = built.count; perLane[lane].append(built.count); built.append(item)
            if item.hasInvalidRecordedDuration { invalid.append(item.id) }
            first = first.map { min($0, item.start) } ?? item.start
            last = last.map { max($0, item.effectiveEnd) } ?? item.effectiveEnd
        }
        let lanes = laneAgents.enumerated().map { TimelineLane(id: $0.element.id, name: $0.element.name, agentIsCatalogued: $0.element.known, accessible: $0.element.accessible, eventCount: perLane[$0.offset].count) }
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .preparingTimeline, completed: eventTotal, total: eventTotal, unit: eventUnit, detail: "timeline.build", step: 3, stepCount: stepCount))
        let laneTotal = Int64(max(1, perLane.count))
        reporter?.send(OperationProgress(stage: .preparingTimeline, total: laneTotal, detail: "timeline.lanes", step: 4, stepCount: stepCount))
        var indexes: [TimelineLaneIndex] = []; indexes.reserveCapacity(perLane.count)
        for lane in perLane {
            try Task.checkCancellation()
            reporter?.send(OperationProgress(stage: .preparingTimeline, completed: Int64(indexes.count), total: laneTotal, detail: "timeline.lanes", step: 4, stepCount: stepCount))
            indexes.append(try TimelineLaneIndex(globalIndices: lane, items: built))
        }
        let bounds = try first.flatMap { lo in try last.map { try TimelineWindow(start: lo, end: $0) } }
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .preparingTimeline, completed: laneTotal, total: laneTotal, detail: "timeline.lanes", step: 4, stepCount: stepCount))
        reporter?.send(OperationProgress(stage: .preparingTimeline, total: eventTotal, unit: eventUnit, detail: "timeline.fingerprint", step: 5, stepCount: stepCount))
        var hasher = SHA256()
        func add(_ string: String) { var length = UInt64(string.utf8.count).bigEndian; hasher.update(data: Data(bytes: &length, count: 8)); hasher.update(data: Data(string.utf8)) }
        func addNumber(_ value: Double) { var bits = value.bitPattern.bigEndian; hasher.update(data: Data(bytes: &bits, count: 8)) }
        for lane in lanes { add(lane.id); add(lane.name); add(lane.agentIsCatalogued ? "known" : "missing"); add(lane.accessible.map { $0 ? "accessible" : "unavailable" } ?? "unknown") }
        for (offset, item) in built.enumerated() {
            if offset.isMultiple(of: 4096) {
                try Task.checkCancellation()
                reporter?.send(OperationProgress(stage: .preparingTimeline, completed: Int64(offset), total: eventTotal, unit: .events, detail: "timeline.fingerprint", step: 5, stepCount: stepCount))
            }
            add(item.id); add(item.agentID); addNumber(item.start.timeIntervalSince1970); add(item.recordedEnd == nil ? "no-end" : "end"); if let end = item.recordedEnd { addNumber(end.timeIntervalSince1970) }; add(item.kind.rawValue); add(item.isError ? "error" : "no-error")
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let result = TimelineProjection(lanes: lanes, bounds: bounds, fingerprintSHA256: fingerprint, invalidDurationEventIDs: invalid, maxQueryItems: budget.maxQueryItems, orderedEventIDs: built.map(\.eventID), items: built, indexByID: byID, laneIndexes: indexes)
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .preparingTimeline, completed: eventTotal, total: eventTotal, unit: eventUnit, detail: "timeline.fingerprint", step: 5, stepCount: stepCount))
        return result
    }

    public func item(id: String) -> TimelineItem? { indexByID[id].map { items[$0] } }
    public func previous(of id: String, inAgent agentID: String? = nil) -> String? { neighbor(of: id, step: -1, inAgent: agentID) }
    public func next(of id: String, inAgent agentID: String? = nil) -> String? { neighbor(of: id, step: 1, inAgent: agentID) }
    private func neighbor(of id: String, step: Int, inAgent agentID: String?) -> String? {
        guard let index = indexByID[id] else { return nil }
        if let agentID {
            let item = items[index]; guard item.agentID == agentID else { return nil }
            let lane = laneIndexes[item.laneIndex], position = item.lanePosition + step
            guard lane.globalIndices.indices.contains(position) else { return nil }
            return items[lane.globalIndices[position]].id
        }
        let target = index + step
        return items.indices.contains(target) ? items[target].id : nil
    }
    public func visible(lane: Int, window: TimelineWindow, limit: Int = 2000) -> TimelineVisibleResult {
        let applied = max(0, min(limit, maxQueryItems))
        guard laneIndexes.indices.contains(lane) else { return TimelineVisibleResult(items: [], totalMatches: 0, limitApplied: applied, visitedNodes: 0) }
        return laneIndexes[lane].visible(window: window, limit: applied, items: items)
    }
    /// Scale-dependent representation from the prepared interval index. No source events are
    /// read, parsed or sorted here. Counts include the minimum display width of markers.
    /// Counts use sorted start/end indexes. Marker-padding fringes, bounded samples
    /// and readable-mark overlap checks are reflected in `visitedNodes`.
    public func density(lane: Int, geometry: TimelineGeometry, xRange: ClosedRange<Double>, bucketWidth: Double = 32, detailLimit: Int = 12, maximumBuckets: Int = 256) -> TimelineDensityResult {
        let empty = TimelineDensityResult(details: [], clusters: [], totalMatches: 0, visitedNodes: 0)
        guard laneIndexes.indices.contains(lane), xRange.lowerBound.isFinite,
              xRange.upperBound.isFinite, bucketWidth.isFinite, bucketWidth > 0,
              maximumBuckets > 0 else { return empty }
        let lowerX = max(geometry.labelWidth, xRange.lowerBound)
        let upperX = min(geometry.contentWidth - geometry.rightInset, xRange.upperBound)
        guard lowerX <= upperX,
              let fullWindow = try? geometry.window(forXRange: lowerX...upperX, includingMarkerPadding: false) else { return empty }
        let laneIndex = laneIndexes[lane]
        // Algebraically equivalent to max(recorded width, minimum marker width) in rect(for:).
        // Infinite padding for an extreme but valid marker width is meaningful: it spans the axis.
        let markerPadding = geometry.window.duration * (geometry.minimumMarkerWidth / geometry.timeWidth)
        let total = laneIndex.densityMatches(window: fullWindow, markerPadding: markerPadding, limit: 0, items: items, includeKinds: false)
        guard total.count > 0 else { return TimelineDensityResult(details: [], clusters: [], totalMatches: 0, visitedNodes: total.visitedNodes) }
        let width = upperX - lowerX
        let bucketCap = min(256, maximumBuckets)
        let requestedBuckets = ceil(min(Double(bucketCap), width / max(bucketWidth, geometry.minimumMarkerWidth)))
        let bucketCount = max(1, Int(requestedBuckets))
        let appliedDetailLimit = max(0, min(detailLimit, maxQueryItems))
        let sampleLimit = min(4, maxQueryItems)
        let queryLimit = max(appliedDetailLimit, sampleLimit)
        var details: [TimelineItem] = [], clusters: [TimelineDensityCluster] = []
        var detailIDs = Set<String>(), visited = total.visitedNodes
        var isolated: [String: Bool] = [:]
        clusters.reserveCapacity(bucketCount)
        for bucket in 0..<bucketCount {
            let lo = lowerX + width * (Double(bucket) / Double(bucketCount))
            let hi = bucket == bucketCount - 1 ? upperX : lowerX + width * (Double(bucket + 1) / Double(bucketCount))
            guard let window = try? geometry.window(forXRange: lo...hi, includingMarkerPadding: false) else { continue }
            let result = laneIndex.densityMatches(window: window, markerPadding: markerPadding, limit: queryLimit,
                                                  items: items, detailThreshold: appliedDetailLimit)
            visited += result.visitedNodes
            guard result.count > 0 else { continue }
            if result.count <= appliedDetailLimit {
                // A bin can contain several distinct marks. Its count alone
                // must not replace readable details with a uniform block.
                var separable = true
                for item in result.items {
                    if let cached = isolated[item.id] { if !cached { separable = false; break }; continue }
                    let rect = geometry.rect(for: item)
                    // Subpixel tolerance avoids treating an exact one-pixel
                    // gap as an intersection after date/coordinate round trips.
                    let probeLo = max(lowerX, rect.x - 0.9999), probeHi = min(upperX, rect.maxX + 0.9999)
                    guard probeLo.isFinite, probeHi.isFinite, probeLo <= probeHi else { separable = false; break }
                    let range = probeLo...probeHi
                    guard let probeWindow = try? geometry.window(forXRange: range, includingMarkerPadding: false) else { separable = false; break }
                    let neighbors = laneIndex.densityMatches(window: probeWindow, markerPadding: markerPadding,
                        limit: min(2, maxQueryItems), items: items, includeKinds: false)
                    visited += neighbors.visitedNodes
                    let containsItem = neighbors.items.contains { $0.id == item.id }
                    let separate = containsItem && (neighbors.count == 1 || (neighbors.count == 2 && neighbors.items.count == 2 && neighbors.items.allSatisfy { other in
                        guard other.id != item.id else { return true }
                        let otherRect = geometry.rect(for: other)
                        return otherRect.maxX + 1 <= rect.x || rect.maxX + 1 <= otherRect.x
                    }))
                    isolated[item.id] = separate
                    if !separate { separable = false; break }
                }
                let additional = result.items.filter { !detailIDs.contains($0.id) }
                if separable, details.count + additional.count <= maxQueryItems {
                    for item in additional { detailIDs.insert(item.id); details.append(item) }
                    continue
                }
            }
            // Hitting the detail budget changes representation; it never drops items/counts.
            let startBits = String(window.start.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            let endBits = String(window.end.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            let clusterID = "density:\(lanes[lane].id.utf8.count):\(lanes[lane].id):\(startBits):\(endBits)"
            clusters.append(TimelineDensityCluster(id: clusterID, laneIndex: lane, window: window,
                count: result.count, errorCount: result.errorCount, compactionCount: result.compactionCount,
                kindCounts: result.kindCounts,
                sampleEventIDs: Array(result.items.prefix(sampleLimit).map(\.id))))
        }
        return TimelineDensityResult(details: details, clusters: clusters, totalMatches: total.count, visitedNodes: visited)
    }
    public func hitTest(x: Double, y: Double, geometry: TimelineGeometry, tolerance: Double = 4, limit: Int = 128) -> TimelineHitResult {
        guard x.isFinite, y.isFinite, tolerance.isFinite, tolerance >= 0, !lanes.isEmpty,
              let window = try? geometry.window(forXRange: (x - tolerance)...(x + tolerance)) else { return TimelineHitResult(eventIDs: [], totalHits: 0, uninspectedCandidates: 0) }
        let firstLane = max(0, geometry.lane(atY: max(geometry.rulerHeight, y - tolerance)) ?? 0)
        let lastLane = min(lanes.count - 1, geometry.lane(atY: y + tolerance) ?? -1)
        guard firstLane <= lastLane else { return TimelineHitResult(eventIDs: [], totalHits: 0, uninspectedCandidates: 0) }
        var hits: [(item: TimelineItem, distance: Double)] = [], omitted = 0
        let applied = max(0, min(limit, maxQueryItems))
        for lane in firstLane...lastLane {
            let result = visible(lane: lane, window: window, limit: max(0, applied - hits.count))
            omitted += result.omittedCount
            for item in result.items where geometry.rect(for: item).contains(x: x, y: y, tolerance: tolerance) { hits.append((item, abs(geometry.x(for: item.start) - x))) }
        }
        hits.sort { $0.distance == $1.distance ? indexByID[$0.item.id]! < indexByID[$1.item.id]! : $0.distance < $1.distance }
        return TimelineHitResult(eventIDs: hits.map { $0.item.id }, totalHits: omitted == 0 ? hits.count : nil, uninspectedCandidates: omitted)
    }
}

/// Call this actor from the UI when the filtered data changes, never from draw/body.
public actor TimelineModel {
    private var cached: TimelineProjection?
    private var cachedEvents: [TimelineEventInput] = []
    private var cachedAgents: [TimelineAgentInput] = []
    private var cachedBudget: TimelineBuildBudget?
    internal private(set) var completedPreparations = 0
    internal private(set) var retainedBytesEstimate = 0
    public init() {}
    public func prepare(events: [LensEvent], agents: [AgentRecord], budget: TimelineBuildBudget = TimelineBuildBudget(), progress: OperationProgressHandler? = nil) throws -> TimelineProjection {
        try Task.checkCancellation()
        let reporter = progress.map { OperationProgressReporter($0) }
        if let cached, cachedBudget == budget, cachedEvents.count == events.count, cachedAgents.count == agents.count {
            let eventUnit: OperationProgress.Unit = events.isEmpty ? .steps : .events
            let eventTotal = Int64(max(1, events.count))
            // Whether this is the entire path is only known after comparing
            // the recorded inputs. Do not promise a one-step reuse up front.
            reporter?.send(OperationProgress(stage: .preparingTimeline, total: eventTotal, unit: eventUnit, detail: "timeline.cache"))
            var equal = true
            for (offset, event) in events.enumerated() {
                if offset.isMultiple(of: 4096) {
                    try Task.checkCancellation()
                    reporter?.send(OperationProgress(stage: .preparingTimeline, completed: Int64(offset), total: eventTotal, unit: .events, detail: "timeline.cache"))
                }
                if cachedEvents[offset] != TimelineEventInput(event) { equal = false; break }
            }
            if equal {
                for (offset, agent) in agents.enumerated() where cachedAgents[offset] != TimelineAgentInput(agent) { equal = false; break }
            }
            if equal {
                try Task.checkCancellation()
                reporter?.send(OperationProgress(stage: .preparingTimeline, completed: eventTotal, total: eventTotal, unit: eventUnit, detail: "timeline.cache", step: 1, stepCount: 1))
                return cached
            }
        }
        let result = try TimelineProjection.prepare(events: events, agents: agents, budget: budget, reporter: reporter, stepCount: 6)
        try Task.checkCancellation()
        reporter?.send(OperationProgress(stage: .preparingTimeline, total: 1, detail: "timeline.retention", step: 6, stepCount: 6))
        try Task.checkCancellation()
        let estimate = try retentionEstimate(events: events, agents: agents, stopAfter: max(0, budget.maxRetentionBytes))
        if budget.maxRetentionBytes > 0, estimate <= budget.maxRetentionBytes {
            let eventInputs = events.map(TimelineEventInput.init)
            let agentInputs = agents.map(TimelineAgentInput.init)
            try Task.checkCancellation()
            cachedEvents = eventInputs; cachedAgents = agentInputs
            cachedBudget = budget; cached = result; retainedBytesEstimate = estimate
        } else {
            try Task.checkCancellation()
            invalidateCache()
        }
        completedPreparations += 1
        reporter?.send(OperationProgress(stage: .preparingTimeline, completed: 1, total: 1, detail: "timeline.retention", step: 6, stepCount: 6))
        return result
    }
    /// Retain at most one preparation, bounded by its build budget. A closed window can release it explicitly.
    public func invalidateCache() { cached = nil; cachedEvents = []; cachedAgents = []; cachedBudget = nil; retainedBytesEstimate = 0 }
    private func retentionEstimate(events: [LensEvent], agents: [AgentRecord], stopAfter: Int) throws -> Int {
        // Deliberately count shared string storage more than once and allow room for dictionary buckets,
        // array capacity, event/input structs, interval bounds and count indexes. No JSON or source content is decoded.
        var total = 4096
        func add(_ bytes: Int, copies: Int = 1) -> Bool {
            let multiplied = bytes.multipliedReportingOverflow(by: copies)
            let sum = total.addingReportingOverflow(multiplied.partialValue)
            if multiplied.overflow || sum.overflow { total = Int.max; return false }
            total = sum.partialValue; return total <= stopAfter
        }
        for (offset, event) in events.enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard add(480), add(event.id.utf8.count, copies: 4), add(event.agentID.utf8.count, copies: 3), add(event.source.path.utf8.count, copies: 2) else { return total }
        }
        for agent in agents {
            guard add(1024), add(agent.id.utf8.count, copies: 4), add(agent.name.utf8.count, copies: 4) else { return total }
        }
        return total
    }
}

private struct TimelineEventInput: Equatable, Sendable {
    let id: String, agentID: String, sourcePath: String
    let timestamp: Date, endTime: Date?
    let kind: EventKind
    let isError: Bool
    let sourceOffset: UInt64
    let sourceLine: Int
    init(_ event: LensEvent) {
        id = event.id; agentID = event.agentID; timestamp = event.timestamp; endTime = event.endTime
        kind = event.kind; isError = event.isError; sourcePath = event.source.path; sourceOffset = event.source.offset; sourceLine = event.source.line
    }
}
private struct TimelineAgentInput: Equatable, Sendable {
    let id: String, name: String
    let accessible: Bool
    init(_ agent: AgentRecord) { id = agent.id; name = agent.name; accessible = agent.accessible }
}

private struct TimelineLaneIndex: Sendable {
    let globalIndices: [Int]
    let starts: [Double]
    let base: Int
    let maximumEnds: [Double]
    let minimumEnds: [Double]
    let errorPrefixCounts: [Int]
    let compactionPrefixCounts: [Int]
    let sortedEnds: [Double]
    let endErrorPrefixCounts: [Int]
    let endCompactionPrefixCounts: [Int]
    // Each event occupies one start rank and one end value across all kinds,
    // not a full-size prefix vector for every EventKind.
    let kindStartPositions: [EventKind: [Int]]
    let kindSortedEnds: [EventKind: [Double]]
    init(globalIndices: [Int], items: [TimelineItem]) throws {
        self.globalIndices = globalIndices
        self.starts = globalIndices.map { items[$0].start.timeIntervalSince1970 }
        var base = 1; while base < globalIndices.count { base *= 2 }; self.base = base
        var maxima = Array(repeating: -Double.infinity, count: base * 2), minima = Array(repeating: Double.infinity, count: base * 2)
        var errors = [Int](repeating: 0, count: globalIndices.count + 1), compactions = errors
        var kindPositions: [EventKind: [Int]] = [:]
        for (offset, index) in globalIndices.enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            let item = items[index], end = item.effectiveEnd.timeIntervalSince1970
            maxima[base + offset] = end; minima[base + offset] = end
            errors[offset + 1] = errors[offset] + (item.isError || item.kind == .error ? 1 : 0)
            compactions[offset + 1] = compactions[offset] + (item.kind == .compaction ? 1 : 0)
            kindPositions[item.effectiveKind, default: []].append(offset)
        }
        if base > 1 { for node in stride(from: base - 1, through: 1, by: -1) { if node.isMultiple(of: 4096) { try Task.checkCancellation() }; maxima[node] = max(maxima[node * 2], maxima[node * 2 + 1]); minima[node] = min(minima[node * 2], minima[node * 2 + 1]) } }
        self.maximumEnds = maxima; self.minimumEnds = minima
        self.errorPrefixCounts = errors; self.compactionPrefixCounts = compactions
        // Prepare the second ordering here, never during a viewport query or drawing.
        var comparisons = 0
        let endOrder = try globalIndices.indices.sorted { first, second in
            comparisons += 1
            if comparisons.isMultiple(of: 4096) { try Task.checkCancellation() }
            let firstEnd = maxima[base + first], secondEnd = maxima[base + second]
            return firstEnd == secondEnd ? first < second : firstEnd < secondEnd
        }
        try Task.checkCancellation()
        var ends: [Double] = [], endErrors = [Int](repeating: 0, count: globalIndices.count + 1), endCompactions = endErrors
        var kindEnds: [EventKind: [Double]] = [:]
        ends.reserveCapacity(globalIndices.count)
        for (position, localIndex) in endOrder.enumerated() {
            if position.isMultiple(of: 4096) { try Task.checkCancellation() }
            ends.append(maxima[base + localIndex])
            endErrors[position + 1] = endErrors[position] + errors[localIndex + 1] - errors[localIndex]
            endCompactions[position + 1] = endCompactions[position] + compactions[localIndex + 1] - compactions[localIndex]
            kindEnds[items[globalIndices[localIndex]].effectiveKind, default: []].append(maxima[base + localIndex])
        }
        self.sortedEnds = ends; self.endErrorPrefixCounts = endErrors; self.endCompactionPrefixCounts = endCompactions
        self.kindStartPositions = kindPositions; self.kindSortedEnds = kindEnds
    }
    func visible(window: TimelineWindow, limit: Int, items: [TimelineItem]) -> TimelineVisibleResult {
        let result = matches(window: window, markerPadding: 0, limit: limit, items: items)
        return TimelineVisibleResult(items: result.items, totalMatches: result.count, limitApplied: limit, visitedNodes: result.visitedNodes)
    }
    private func prefixCount<T: Comparable>(_ values: [T], before target: T, visited: inout Int) -> Int {
        guard let first = values.first, let last = values.last else { return 0 }
        visited += 1; if first >= target { return 0 }
        visited += 1; if last < target { return values.count }
        var lo = 0, hi = values.count
        while lo < hi {
            visited += 1
            let middle = lo + (hi - lo) / 2
            if values[middle] < target { lo = middle + 1 } else { hi = middle }
        }
        return lo
    }
    private func composition(startLimit: Int, removingEndsBefore lower: Double?, visited: inout Int) -> [EventKind: Int] {
        var counts: [EventKind: Int] = [:]
        for (kind, positions) in kindStartPositions {
            let began = prefixCount(positions, before: startLimit, visited: &visited)
            let ended = lower.map { prefixCount(kindSortedEnds[kind] ?? [], before: $0, visited: &visited) } ?? 0
            if began > ended { counts[kind] = began - ended }
        }
        return counts
    }
    private func addComposition(_ range: Range<Int>, to counts: inout [EventKind: Int], visited: inout Int) {
        for (kind, positions) in kindStartPositions {
            let count = prefixCount(positions, before: range.upperBound, visited: &visited)
                - prefixCount(positions, before: range.lowerBound, visited: &visited)
            if count > 0 { counts[kind, default: 0] += count }
        }
    }
    func densityMatches(window: TimelineWindow, markerPadding: Double, limit: Int, items: [TimelineItem],
                        detailThreshold: Int? = nil, includeKinds: Bool = true) -> TimelineLaneMatches {
        guard !globalIndices.isEmpty else { return TimelineLaneMatches(items: [], count: 0, errorCount: 0, compactionCount: 0, visitedNodes: 0) }
        let lower = window.start.timeIntervalSince1970, upper = window.end.timeIntervalSince1970
        var visited = 0
        func boundary(_ values: [Double], _ target: Double, includingEqual: Bool) -> Int {
            var lo = 0, hi = values.count
            while lo < hi {
                visited += 1
                let middle = lo + (hi - lo) / 2
                if values[middle] < target || (includingEqual && values[middle] == target) { lo = middle + 1 }
                else { hi = middle }
            }
            return lo
        }
        let startLimit = boundary(starts, upper, includingEqual: true)
        guard startLimit > 0 else { return TimelineLaneMatches(items: [], count: 0, errorCount: 0, compactionCount: 0, visitedNodes: visited) }
        if startLimit == globalIndices.count,
           max(maximumEnds[1], starts[startLimit - 1] + markerPadding) < lower {
            // The viewport is past all intervals and their visible marker widths.
            // Empty trailing bins need no end/fringe searches or sample traversal.
            return TimelineLaneMatches(items: [], count: 0, errorCount: 0, compactionCount: 0, visitedNodes: visited)
        }
        var count: Int, errorCount: Int, compactionCount: Int
        var kindCounts: [EventKind: Int] = [:]
        if starts[0] + markerPadding >= lower {
            // Every candidate reaches this bin through its minimum marker width.
            count = startLimit; errorCount = errorPrefixCounts[startLimit]; compactionCount = compactionPrefixCounts[startLimit]
            if includeKinds { kindCounts = composition(startLimit: startLimit, removingEndsBefore: nil, visited: &visited) }
        } else {
            // Effective ends are never earlier than starts. Therefore every end < lower
            // also has start <= upper and may be subtracted without an intersection scan.
            let endLimit = boundary(sortedEnds, lower, includingEqual: false)
            count = startLimit - endLimit
            errorCount = errorPrefixCounts[startLimit] - endErrorPrefixCounts[endLimit]
            compactionCount = compactionPrefixCounts[startLimit] - endCompactionPrefixCounts[endLimit]
            if includeKinds { kindCounts = composition(startLimit: startLimit, removingEndsBefore: lower, visited: &visited) }
            if markerPadding > 0 {
                let fringeStart = boundary(starts, lower - markerPadding, includingEqual: false)
                let fringeEnd = min(startLimit, boundary(starts, lower, includingEqual: false))
                // Restore the markers whose recorded interval ended before this bin but
                // whose minimum display width still intersects it. Only this start fringe
                // needs a two-bound tree query; interval counts outside it are logarithmic.
                func restoreMarkers(_ node: Int, _ lo: Int, _ hi: Int) {
                    visited += 1
                    guard lo < globalIndices.count, lo < fringeEnd, hi > fringeStart,
                          minimumEnds[node] < lower else { return }
                    let actualHi = min(hi, globalIndices.count)
                    if fringeStart <= lo, actualHi <= fringeEnd, maximumEnds[node] < lower {
                        count += actualHi - lo
                        errorCount += errorPrefixCounts[actualHi] - errorPrefixCounts[lo]
                        compactionCount += compactionPrefixCounts[actualHi] - compactionPrefixCounts[lo]
                        if includeKinds { addComposition(lo..<actualHi, to: &kindCounts, visited: &visited) }
                        return
                    }
                    if hi - lo == 1 {
                        count += 1; errorCount += errorPrefixCounts[actualHi] - errorPrefixCounts[lo]
                        compactionCount += compactionPrefixCounts[actualHi] - compactionPrefixCounts[lo]
                        if includeKinds { addComposition(lo..<actualHi, to: &kindCounts, visited: &visited) }
                        return
                    }
                    let middle = lo + (hi - lo) / 2
                    restoreMarkers(node * 2, lo, middle); restoreMarkers(node * 2 + 1, middle, hi)
                }
                if fringeStart < fringeEnd { restoreMarkers(1, 0, base) }
            }
        }
        let collectionLimit = detailThreshold.map { count > $0 ? min(limit, 4) : limit } ?? limit
        var selected: [TimelineItem] = []
        selected.reserveCapacity(min(collectionLimit, count))
        // Collection is independent of counting and stops as soon as the bounded sample
        // is complete, including for alternating very long intervals and point events.
        func collect(_ node: Int, _ lo: Int, _ hi: Int) {
            guard selected.count < collectionLimit else { return }
            visited += 1
            guard lo < globalIndices.count else { return }
            let actualHi = min(hi, globalIndices.count)
            guard starts[lo] <= upper,
                  max(maximumEnds[node], starts[actualHi - 1] + markerPadding) >= lower else { return }
            if starts[actualHi - 1] <= upper,
               max(minimumEnds[node], starts[lo] + markerPadding) >= lower {
                let retained = min(actualHi - lo, collectionLimit - selected.count)
                for local in lo..<(lo + retained) { selected.append(items[globalIndices[local]]) }
                return
            }
            if hi - lo == 1 { selected.append(items[globalIndices[lo]]); return }
            let middle = lo + (hi - lo) / 2
            collect(node * 2, lo, middle); collect(node * 2 + 1, middle, hi)
        }
        if count > 0, collectionLimit > 0 { collect(1, 0, base) }
        return TimelineLaneMatches(items: selected, count: count, errorCount: errorCount, compactionCount: compactionCount, visitedNodes: visited, kindCounts: kindCounts)
    }
    func matches(window: TimelineWindow, markerPadding: Double, limit: Int, items: [TimelineItem]) -> TimelineLaneMatches {
        var selected: [TimelineItem] = [], count = 0, errorCount = 0, compactionCount = 0, visited = 0
        selected.reserveCapacity(min(limit, globalIndices.count))
        let lower = window.start.timeIntervalSince1970, upper = window.end.timeIntervalSince1970
        func include(_ lo: Int, _ hi: Int) {
            count += hi - lo
            errorCount += errorPrefixCounts[hi] - errorPrefixCounts[lo]
            compactionCount += compactionPrefixCounts[hi] - compactionPrefixCounts[lo]
            let retained = min(hi - lo, max(0, limit - selected.count))
            if retained > 0 { for local in lo..<(lo + retained) { selected.append(items[globalIndices[local]]) } }
        }
        func visit(_ node: Int, _ lo: Int, _ hi: Int) {
            visited += 1
            guard lo < globalIndices.count else { return }
            let actualHi = min(hi, globalIndices.count)
            guard starts[lo] <= upper,
                  max(maximumEnds[node], starts[actualHi - 1] + markerPadding) >= lower else { return }
            if starts[actualHi - 1] <= upper,
               max(minimumEnds[node], starts[lo] + markerPadding) >= lower {
                include(lo, actualHi)
                return
            }
            if hi - lo == 1 { include(lo, actualHi); return }
            let middle = lo + (hi - lo) / 2
            visit(node * 2, lo, middle); visit(node * 2 + 1, middle, hi)
        }
        if !globalIndices.isEmpty { visit(1, 0, base) }
        return TimelineLaneMatches(items: selected, count: count, errorCount: errorCount, compactionCount: compactionCount, visitedNodes: visited)
    }
}
private struct TimelineLaneMatches {
    let items: [TimelineItem]
    let count: Int
    let errorCount: Int
    let compactionCount: Int
    let visitedNodes: Int
    let kindCounts: [EventKind: Int]
    init(items: [TimelineItem], count: Int, errorCount: Int, compactionCount: Int, visitedNodes: Int,
         kindCounts: [EventKind: Int] = [:]) {
        self.items = items; self.count = count; self.errorCount = errorCount
        self.compactionCount = compactionCount; self.visitedNodes = visitedNodes; self.kindCounts = kindCounts
    }
}
