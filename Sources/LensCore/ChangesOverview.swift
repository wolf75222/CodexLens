import Foundation

/// A lexical file identity retains the exact recorded environment, including an unknown one.
/// Normalization never consults the filesystem or follows symlinks.
public struct ChangesOverviewFileKey: Hashable, Sendable {
    public let environmentID: String
    public let path: String
    public var id: String { overviewIdentity("file", [environmentID, path]) }

    public init(environmentID: String, path: String) {
        self.environmentID = environmentID
        let joined = path.hasPrefix("/") || environmentID.isEmpty
            ? path : environmentID + "/" + path
        self.path = lexicalOverviewPath(joined)
    }
}

/// Counts and dates describe only retained recorded traces, never net modifications or execution.
public struct ChangesOverviewSummary: Hashable, Sendable {
    public let traceIDs: [String]
    public let kinds: [ChangeKind]
    public let eventIDs: [String]
    public let agentIDs: [String]
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let unknownTimestampCount: Int
    public var changeIDs: [String] { traceIDs }

    fileprivate init(traces: [OverviewTrace]) {
        traceIDs = Set(traces.map { $0.change.id }).sorted()
        kinds = Set(traces.map { $0.change.kind }).sorted { $0.rawValue < $1.rawValue }
        eventIDs = Set(traces.map { $0.change.eventID }).sorted()
        agentIDs = Set(traces.map { $0.change.agentID }).sorted()
        let dates = traces.compactMap(\.timestamp)
        firstTimestamp = dates.min()
        lastTimestamp = dates.max()
        unknownTimestampCount = Set(traces.filter { $0.timestamp == nil }.map { $0.change.eventID }).count
    }
}

public protocol ChangesOverviewSummarized {
    var summary: ChangesOverviewSummary { get }
}

public extension ChangesOverviewSummarized {
    var traceIDs: [String] { summary.traceIDs }
    var changeIDs: [String] { summary.changeIDs }
    var kinds: [ChangeKind] { summary.kinds }
    var eventIDs: [String] { summary.eventIDs }
    var agentIDs: [String] { summary.agentIDs }
    var firstTimestamp: Date? { summary.firstTimestamp }
    var lastTimestamp: Date? { summary.lastTimestamp }
    var unknownTimestampCount: Int { summary.unknownTimestampCount }
}

/// One canonically linked recorded activity. Its dates are trace timestamps, not a duration.
public struct ChangesOverviewActivity: Identifiable, Hashable, Sendable, ChangesOverviewSummarized {
    public let id: String
    public let canonicalActivityID: String
    public let summary: ChangesOverviewSummary

    fileprivate init(traces: [OverviewTrace]) {
        id = traces[0].activityID
        canonicalActivityID = traces[0].canonicalActivityID
        summary = ChangesOverviewSummary(traces: traces)
    }
}

public struct ChangesOverviewFile: Identifiable, Hashable, Sendable, ChangesOverviewSummarized {
    public let key: ChangesOverviewFileKey
    public var id: String { key.id }
    public var environmentID: String { key.environmentID }
    public var path: String { key.path }
    public var relativePath: String {
        let environment = lexicalOverviewPath(environmentID)
        guard !environment.isEmpty, path.hasPrefix(environment == "/" ? "/" : environment + "/") else { return path }
        return String(path.dropFirst(environment == "/" ? 1 : environment.count + 1))
    }
    public let activities: [ChangesOverviewActivity]
    public var activityCount: Int { activities.count }
    public let summary: ChangesOverviewSummary

    fileprivate init(key: ChangesOverviewFileKey, traces: [OverviewTrace]) {
        self.key = key
        activities = overviewActivities(traces)
        summary = ChangesOverviewSummary(traces: traces)
    }
}

public struct ChangesOverviewEnvironment: Identifiable, Hashable, Sendable, ChangesOverviewSummarized {
    public var id: String { environment.id }
    public let environment: EnvironmentRecord
    public let isSynthetic: Bool
    public let files: [ChangesOverviewFile]
    /// Unique across this environment's files, suitable for recorded worktree activity lanes.
    public let activities: [ChangesOverviewActivity]
    public var activityCount: Int { activities.count }
    public let summary: ChangesOverviewSummary

    fileprivate init(environment: EnvironmentRecord, isSynthetic: Bool, files: [ChangesOverviewFile], traces: [OverviewTrace]) {
        self.environment = environment
        self.isSynthetic = isSynthetic
        self.files = files
        activities = overviewActivities(traces)
        summary = ChangesOverviewSummary(traces: traces)
    }
}

public struct ChangesOverviewProjection: Hashable, Sendable, ChangesOverviewSummarized {
    public let groups: [ChangesOverviewEnvironment]
    /// Stored navigation derived from these exact filtered groups, prepared with the projection.
    public let fileTree: ChangesFileTree
    public var files: [ChangesOverviewFile] { groups.flatMap(\.files) }
    /// An activity touching multiple files is counted once.
    public let activityCount: Int
    public let summary: ChangesOverviewSummary

    fileprivate init(groups: [ChangesOverviewEnvironment], traces: [OverviewTrace]) {
        self.groups = groups
        fileTree = ChangesFileTree(groups: groups)
        activityCount = Set(traces.map(\.activityID)).count
        summary = ChangesOverviewSummary(traces: traces)
    }
}

/// Pure, immutable index over the session and its existing evidence identities.
/// Reading a projection performs no source reads, Git inspection, diff parsing or execution.
public struct ChangesOverviewIndex: Sendable {
    public let groups: [ChangesOverviewEnvironment]
    private let indexedFiles: [OverviewIndexedFile]
    private let environments: [String: EnvironmentRecord]

    public init(snapshot: SessionSnapshot, activity: ActivityEvidenceIndex) {
        let events = Dictionary(snapshot.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let descriptors = Dictionary(snapshot.environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var canonicalByTrace: [OverviewTraceKey: String] = [:]
        for history in activity.fileHistories {
            let key = ChangesOverviewFileKey(environmentID: history.environmentID, path: history.path)
            for observation in history.activities {
                for changeID in observation.changeIDs {
                    let traceKey = OverviewTraceKey(changeID: changeID, file: key)
                    if canonicalByTrace[traceKey] == nil { canonicalByTrace[traceKey] = observation.id }
                }
            }
        }
        var seenChanges = Set<String>()
        var tracesByFile: [ChangesOverviewFileKey: [OverviewTrace]] = [:]
        for change in snapshot.changes where seenChanges.insert(change.id).inserted {
            let key = ChangesOverviewFileKey(environmentID: change.environmentID, path: change.path)
            let canonical = canonicalByTrace[OverviewTraceKey(changeID: change.id, file: key)]
                ?? activity.observationsByEventID[change.eventID].flatMap { observation in
                    observation.environmentID == change.environmentID && observation.agentID == change.agentID ? observation.id : nil
                }
                ?? "event:" + change.eventID
            let trace = OverviewTrace(change: change,
                activityID: overviewIdentity("activity", [change.environmentID, change.agentID, canonical]),
                canonicalActivityID: canonical, timestamp: knownOverviewTimestamp(events[change.eventID]?.timestamp))
            tracesByFile[key, default: []].append(trace)
        }
        let files = tracesByFile.keys.sorted {
            ($0.environmentID, $0.path) < ($1.environmentID, $1.path)
        }.map { OverviewIndexedFile(key: $0, traces: tracesByFile[$0]!.sorted { $0.change.id < $1.change.id }) }
        indexedFiles = files
        environments = descriptors
        groups = Self.project(files: files, environments: descriptors, visibleChangeIDs: nil).groups
    }

    /// Membership is applied to individual traces before dates, kinds and unique activities are aggregated.
    public func projection(visibleChangeIDs: Set<String>) -> ChangesOverviewProjection {
        Self.project(files: indexedFiles, environments: environments, visibleChangeIDs: visibleChangeIDs)
    }

    private static func project(files: [OverviewIndexedFile], environments: [String: EnvironmentRecord],
                                visibleChangeIDs: Set<String>?) -> ChangesOverviewProjection {
        var filesByEnvironment: [String: [ChangesOverviewFile]] = [:]
        var tracesByEnvironment: [String: [OverviewTrace]] = [:]
        var allTraces: [OverviewTrace] = []
        for file in files {
            let traces = visibleChangeIDs.map { visible in file.traces.filter { visible.contains($0.change.id) } } ?? file.traces
            guard !traces.isEmpty else { continue }
            filesByEnvironment[file.key.environmentID, default: []].append(ChangesOverviewFile(key: file.key, traces: traces))
            tracesByEnvironment[file.key.environmentID, default: []].append(contentsOf: traces)
            allTraces.append(contentsOf: traces)
        }
        let groups = filesByEnvironment.keys.sorted().map { id in
            let traces = tracesByEnvironment[id]!
            let descriptor = environments[id] ?? EnvironmentRecord(path: id,
                agentIDs: Set(traces.map { $0.change.agentID }).sorted(), eventIDs: Set(traces.map { $0.change.eventID }).sorted(),
                evidence: id.isEmpty ? "Environment identity not recorded; retained change traces only."
                    : "Environment descriptor unavailable; exact identity retained from change traces.")
            return ChangesOverviewEnvironment(environment: descriptor, isSynthetic: environments[id] == nil,
                files: filesByEnvironment[id]!, traces: traces)
        }
        return ChangesOverviewProjection(groups: groups, traces: allTraces)
    }
}

private struct OverviewTraceKey: Hashable {
    let changeID: String
    let file: ChangesOverviewFileKey
}
fileprivate struct OverviewTrace: Sendable {
    let change: ChangeRecord
    let activityID: String
    let canonicalActivityID: String
    let timestamp: Date?
}
private struct OverviewIndexedFile: Sendable {
    let key: ChangesOverviewFileKey
    let traces: [OverviewTrace]
}

private func overviewActivities(_ traces: [OverviewTrace]) -> [ChangesOverviewActivity] {
    let grouped = Dictionary(grouping: traces, by: \.activityID)
    return grouped.keys.sorted().map { ChangesOverviewActivity(traces: grouped[$0]!) }.sorted {
        switch ($0.firstTimestamp, $1.firstTimestamp) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return $0.id < $1.id
        }
    }
}

private func knownOverviewTimestamp(_ value: Date?) -> Date? {
    value.flatMap { $0 != .distantPast && $0.timeIntervalSince1970.isFinite ? $0 : nil }
}
private func overviewIdentity(_ kind: String, _ fields: [String]) -> String {
    "changes-" + kind + ":" + fields.map { String($0.utf8.count) + ":" + $0 }.joined()
}
private func lexicalOverviewPath(_ value: String) -> String {
    let absolute = value.hasPrefix("/")
    var components: [Substring] = []
    for component in value.split(separator: "/") {
        if component == "." { continue }
        if component == ".." {
            if let last = components.last, last != ".." { components.removeLast() }
            else if !absolute { components.append(component) }
        } else { components.append(component) }
    }
    return (absolute ? "/" : "") + components.joined(separator: "/")
}
