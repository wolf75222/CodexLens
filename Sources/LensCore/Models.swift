import Foundation

public enum RelationKind: String, Codable, Sendable { case root, subagent, fork, continuation, unknown }
public enum EventKind: String, Codable, CaseIterable, Sendable {
    case user, assistant, instruction, toolCall, toolResult, delegation, wait, error, lifecycle, context, compaction, unknown
}
public enum ResourceRole: String, Codable, CaseIterable, Sendable { case supplied, referenced, recordedRead, modified, produced }
public enum Availability: String, Codable, Sendable { case accessible, missing, external, unknown }
public enum ChangeKind: String, Codable, Sendable { case requestedPatch, recordedResult, observedChange }

public struct SourceRef: Codable, Hashable, Sendable {
    public var path: String
    public var offset: UInt64
    public var length: Int
    public var line: Int
    public var sha256: String?
    public init(path: String, offset: UInt64 = 0, length: Int = 0, line: Int = 0, sha256: String? = nil) {
        self.path = path; self.offset = offset; self.length = length; self.line = line; self.sha256 = sha256
    }
}
public struct SessionSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var paths: [String]
    public var modifiedAt: Date
    public var cliVersion: String
    public var parentID: String?
    public var relation: RelationKind
    public var agentName: String
    public var evidence: String
    public var agentMetadata: [AgentMetadataField]?
    public init(id: String, sessionID: String? = nil, title: String = "", cwd: String = "", paths: [String] = [], modifiedAt: Date = .distantPast, cliVersion: String = "", parentID: String? = nil, relation: RelationKind = .root, agentName: String = "", evidence: String = "", agentMetadata: [AgentMetadataField]? = nil) {
        self.id = id; self.sessionID = sessionID ?? id; self.title = title; self.cwd = cwd; self.paths = paths; self.modifiedAt = modifiedAt; self.cliVersion = cliVersion; self.parentID = parentID; self.relation = relation; self.agentName = agentName; self.evidence = evidence; self.agentMetadata = agentMetadata
    }
}
public struct AgentRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var parentID: String?
    public var name: String
    public var relation: RelationKind
    public var mission: String
    public var missionEventID: String?
    public var evidence: String
    public var paths: [String]
    public var environmentIDs: [String]
    public var accessible: Bool
    public var relationSources: [SourceRef]?
    public var metadata: [AgentMetadataField]?
    public init(id: String, parentID: String? = nil, name: String = "", relation: RelationKind = .root, mission: String = "", missionEventID: String? = nil, evidence: String = "", paths: [String] = [], environmentIDs: [String] = [], accessible: Bool = true, relationSources: [SourceRef]? = nil, metadata: [AgentMetadataField]? = nil) {
        self.id = id; self.parentID = parentID; self.name = name; self.relation = relation; self.mission = mission; self.missionEventID = missionEventID; self.evidence = evidence; self.paths = paths; self.environmentIDs = environmentIDs; self.accessible = accessible; self.metadata = metadata
        self.relationSources = relationSources
    }
}
public struct LensEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var timestamp: Date
    public var endTime: Date?
    public var agentID: String
    public var turnID: String?
    public var kind: EventKind
    public var title: String
    public var preview: String
    public var toolName: String?
    public var callID: String?
    public var environmentID: String?
    public var resourceIDs: [String]
    public var relatedEventID: String?
    public var source: SourceRef
    public var supplementarySources: [SourceRef]
    public var isError: Bool
    /// Versioned, passive facts extracted once during incremental indexing. Payloads remain in their source journal.
    public var trace: RecordedTraceFacts?
    public init(id: String, timestamp: Date = .distantPast, endTime: Date? = nil, agentID: String, turnID: String? = nil, kind: EventKind = .unknown, title: String = "", preview: String = "", toolName: String? = nil, callID: String? = nil, environmentID: String? = nil, resourceIDs: [String] = [], relatedEventID: String? = nil, source: SourceRef, supplementarySources: [SourceRef] = [], isError: Bool = false, trace: RecordedTraceFacts? = nil) {
        self.id = id; self.timestamp = timestamp; self.endTime = endTime; self.agentID = agentID; self.turnID = turnID; self.kind = kind; self.title = title; self.preview = preview; self.toolName = toolName; self.callID = callID; self.environmentID = environmentID; self.resourceIDs = resourceIDs; self.relatedEventID = relatedEventID; self.source = source; self.supplementarySources = supplementarySources; self.isError = isError; self.trace = trace
    }
}
public struct EnvironmentRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var repositoryPath: String?
    public var recordedBranch: String?
    public var recordedRef: String?
    public var agentIDs: [String]
    public var eventIDs: [String]
    public var evidence: String
    public init(path: String, repositoryPath: String? = nil, recordedBranch: String? = nil, recordedRef: String? = nil, agentIDs: [String] = [], eventIDs: [String] = [], evidence: String = "") {
        self.path = path; self.repositoryPath = repositoryPath; self.recordedBranch = recordedBranch; self.recordedRef = recordedRef; self.agentIDs = agentIDs; self.eventIDs = eventIDs; self.evidence = evidence
    }
}
public struct ResourceRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var location: String
    public var name: String
    public var roles: [ResourceRole]
    public var agentIDs: [String]
    public var environmentID: String?
    public var eventIDs: [String]
    public var evidence: String
    public var availability: Availability
    public init(id: String? = nil, location: String, name: String = "", roles: [ResourceRole] = [.referenced], agentIDs: [String] = [], environmentID: String? = nil, eventIDs: [String] = [], evidence: String = "", availability: Availability = .unknown) {
        self.id = id ?? location; self.location = location; self.name = name.isEmpty ? URL(fileURLWithPath: location).lastPathComponent : name; self.roles = roles; self.agentIDs = agentIDs; self.environmentID = environmentID; self.eventIDs = eventIDs; self.evidence = evidence; self.availability = availability
    }
}
public struct ChangeRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var path: String
    public var environmentID: String
    public var agentID: String
    public var eventID: String
    public var kind: ChangeKind
    public var evidence: String
    public init(id: String, path: String, environmentID: String, agentID: String, eventID: String, kind: ChangeKind, evidence: String = "") {
        self.id = id; self.path = path; self.environmentID = environmentID; self.agentID = agentID; self.eventID = eventID; self.kind = kind; self.evidence = evidence
    }
}
public struct CoverageIssue: Identifiable, Codable, Hashable, Sendable {
    public var id: String { category + source + message }
    public var category: String
    public var message: String
    public var source: String
    public init(_ category: String, _ message: String, source: String = "") { self.category = category; self.message = message; self.source = source }
}
public struct SessionSnapshot: Codable, Sendable {
    public var root: SessionSummary
    public var agents: [AgentRecord]
    public var events: [LensEvent]
    public var environments: [EnvironmentRecord]
    public var resources: [ResourceRecord]
    public var changes: [ChangeRecord]
    public var coverage: [CoverageIssue]
    public var collectedAt: Date
    public init(root: SessionSummary, agents: [AgentRecord] = [], events: [LensEvent] = [], environments: [EnvironmentRecord] = [], resources: [ResourceRecord] = [], changes: [ChangeRecord] = [], coverage: [CoverageIssue] = [], collectedAt: Date = Date()) {
        self.root = root; self.agents = agents; self.events = events; self.environments = environments; self.resources = resources; self.changes = changes; self.coverage = coverage; self.collectedAt = collectedAt
    }
}
public struct EventDetail: Sendable {
    public var content: String
    public var arguments: String
    public var output: String
    public var raw: String
    public init(content: String = "", arguments: String = "", output: String = "", raw: String = "") {
        self.content = content; self.arguments = arguments; self.output = output; self.raw = raw
    }
}
public enum LensError: LocalizedError {
    case unavailable(String), unsupported(String), corrupt(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let s), .unsupported(let s), .corrupt(let s): return s }
    }
}
