import Foundation

/// Small recorded attributes, not a reconstruction of an agent's effective instructions.
/// Prompts stay in their original event and are opened on demand.
public struct AgentMetadataField: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case role, description, model, reasoningEffort, modelProvider, taskName, forkContext, cliVersion
    }
    public enum Origin: String, Codable, Sendable { case sessionMetadata, threadMetadata, delegationRequest }
    public var kind: Kind
    public var value: String
    public var origin: Origin
    public var sourcePath: String
    public var source: SourceRef?
    public var eventID: String?
    public var isTruncated: Bool?
    public var id: String { [kind.rawValue, origin.rawValue, sourcePath, String(source?.offset ?? 0), eventID ?? ""].joined(separator: "\u{1f}") }
    public init(kind: Kind, value: String, origin: Origin, sourcePath: String, source: SourceRef? = nil, eventID: String? = nil, isTruncated: Bool? = nil) {
        self.kind = kind; self.value = value; self.origin = origin; self.sourcePath = sourcePath; self.source = source; self.eventID = eventID; self.isTruncated = isTruncated
    }
    public static func preferredRole(in fields: [Self]) -> Self? {
        for origin in [Origin.sessionMetadata, .threadMetadata, .delegationRequest] {
            if let field = fields.first(where: { $0.kind == .role && $0.origin == origin }) { return field }
        }
        return nil
    }
    public static func searchText(_ fields: [Self]) -> String { fields.map(\.value).joined(separator: "\n") }

    /// Persisted fields are allowlisted. Do not copy base/developer instructions,
    /// authentication data, arbitrary tool configuration or opaque payloads here.
    static func sessionFields(_ payload: [String: Any], source: SourceRef) -> [Self] {
        let sourceValue = payload["source"] as? [String: Any] ?? dictionary(payload["source"])
        let subagent = sourceValue["subagent"] as? [String: Any] ?? sourceValue["subAgent"] as? [String: Any] ?? [:]
        let spawn = subagent["thread_spawn"] as? [String: Any] ?? subagent["threadSpawn"] as? [String: Any] ?? [:]
        let values: [(Kind, Any?)] = [
            (.role, payload["agent_role"] ?? spawn["agent_role"] ?? spawn["agentRole"]),
            (.description, payload["agent_description"]),
            (.model, payload["model"]), (.reasoningEffort, payload["reasoning_effort"] ?? payload["model_reasoning_effort"]),
            (.modelProvider, payload["model_provider"]), (.cliVersion, payload["cli_version"])
        ]
        return fields(values, origin: .sessionMetadata, sourcePath: source.path, source: source)
    }
    static func threadFields(_ row: [String: String], path: String) -> [Self] {
        let source = dictionary(row["source"])
        let subagent = source["subagent"] as? [String: Any] ?? source["subAgent"] as? [String: Any] ?? [:]
        let spawn = subagent["thread_spawn"] as? [String: Any] ?? subagent["threadSpawn"] as? [String: Any] ?? [:]
        return fields([(.role, row["agent_role"] ?? spawn["agent_role"] as? String ?? spawn["agentRole"] as? String), (.description, row["agent_description"]), (.model, row["model"]),
                (.reasoningEffort, row["reasoning_effort"]), (.modelProvider, row["model_provider"]), (.cliVersion, row["cli_version"])],
               origin: .threadMetadata, sourcePath: path)
    }
    static func delegationFields(_ arguments: [String: Any], source: SourceRef, eventID: String) -> [Self] {
        var output = fields([(.role, arguments["agent_type"] ?? arguments["agent_role"]),
            (.description, arguments["agent_description"] ?? arguments["description"]),
            (.model, arguments["model"]), (.reasoningEffort, arguments["reasoning_effort"]), (.taskName, arguments["task_name"])],
            origin: .delegationRequest, sourcePath: source.path, source: source, eventID: eventID)
        if let fork = arguments["fork_context"] as? Bool {
            output.append(Self(kind: .forkContext, value: fork ? "true" : "false", origin: .delegationRequest,
                               sourcePath: source.path, source: source, eventID: eventID))
        } else if let turns = arguments["fork_turns"] as? String, !turns.isEmpty {
            output += fields([(.forkContext, turns)], origin: .delegationRequest, sourcePath: source.path, source: source, eventID: eventID)
        }
        return output
    }
    private static func fields(_ values: [(Kind, Any?)], origin: Origin, sourcePath: String, source: SourceRef? = nil, eventID: String? = nil) -> [Self] {
        values.compactMap { kind, raw in
            guard let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let redacted = EvidenceRedaction.redact(text), limit = kind == .description ? 4096 : 512
            let bounded = EvidenceRedaction.utf8Prefix(redacted, limit: limit)
            return Self(kind: kind, value: bounded, origin: origin, sourcePath: sourcePath, source: source, eventID: eventID, isTruncated: redacted.utf8.count > limit)
        }
    }
    private static func dictionary(_ value: Any?) -> [String: Any] {
        guard let text = value as? String, let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
