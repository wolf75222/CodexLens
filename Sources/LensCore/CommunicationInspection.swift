import Foundation

/// Versioned, metadata-only observations. Plaintext stays in the existing recorded-content pager;
/// encrypted segments are never converted into a summary or copied into this projection.
public struct RecordedCommunicationFacts: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case spawn, message, followup, result, wait, instruction, metadata, unknown }
    public enum Stage: String, Codable, Sendable {
        case sendRequested, submissionRecorded, activityRecorded, recipientContextRecorded, requestInclusionConfirmed, instructionRecorded, metadata
    }
    public enum InstructionKind: String, Codable, Sendable { case base, direct, inherited, later, unknown }
    public enum Direction: String, Sendable { case outgoing, incoming, reported, instruction, unknown }
    public var direction: Direction {
        switch stage {
        case .sendRequested, .submissionRecorded: return .outgoing
        case .recipientContextRecorded: return .incoming
        case .activityRecorded: return .reported
        case .instructionRecorded: return .instruction
        case .metadata, .requestInclusionConfirmed: return .unknown
        }
    }
    public var evidenceStatus: Stage { stage }
    /// session_id can be shared by an entire tree; this is never a parent-thread edge.
    public var sharedSessionID: String? { parentSessionID }

    public var kind: Kind
    public var stage: Stage
    public var messageID: String?
    public var protocolID: String?
    public var callID: String?
    public var communicationID: String?
    /// Native v1 send_input returns this receipt. A result's presence alone is not acceptance.
    public var submissionReceiptID: String?
    /// Reserved for an adapter with an explicit positive runtime receipt, never absence of error.
    public var submissionAccepted: Bool?
    public var toolName: String?
    public var senderThreadID: String?
    public var senderPath: String?
    public var recipientThreadIDs: [String]
    public var recipientPaths: [String]
    /// Hook session_id is a session-tree identity, not the affected child thread identity.
    public var parentSessionID: String?
    public var affectedAgentID: String?
    public var triggerTurn: Bool?
    public var isOpaque: Bool
    public var instructionKind: InstructionKind?
    public var inheritedFromThreadID: String?
    public var originTimestamp: Date?
    public var collectedAt: Date?
    public var limitations: [String]

    public init(kind: Kind, stage: Stage, messageID: String? = nil, protocolID: String? = nil,
                callID: String? = nil, communicationID: String? = nil, submissionReceiptID: String? = nil,
                submissionAccepted: Bool? = nil, toolName: String? = nil,
                senderThreadID: String? = nil, senderPath: String? = nil,
                recipientThreadIDs: [String] = [], recipientPaths: [String] = [],
                parentSessionID: String? = nil, affectedAgentID: String? = nil,
                triggerTurn: Bool? = nil, isOpaque: Bool = false,
                instructionKind: InstructionKind? = nil, inheritedFromThreadID: String? = nil,
                originTimestamp: Date? = nil, collectedAt: Date? = nil, limitations: [String] = []) {
        self.kind = kind; self.stage = stage; self.messageID = messageID; self.protocolID = protocolID
        self.callID = callID; self.communicationID = communicationID; self.toolName = toolName
        self.submissionReceiptID = submissionReceiptID; self.submissionAccepted = submissionAccepted
        self.senderThreadID = senderThreadID; self.senderPath = senderPath
        self.recipientThreadIDs = recipientThreadIDs; self.recipientPaths = recipientPaths
        self.parentSessionID = parentSessionID; self.affectedAgentID = affectedAgentID
        self.triggerTurn = triggerTurn; self.isOpaque = isOpaque; self.instructionKind = instructionKind
        self.inheritedFromThreadID = inheritedFromThreadID; self.originTimestamp = originTimestamp
        self.collectedAt = collectedAt; self.limitations = limitations
    }

    /// The 0.159.2 durable wire forms plus explicitly supplied hook captures. This method does
    /// not claim that hooks/collab begin/end are normally persisted by that Codex release.
    public static func decode(_ root: [String: Any], event: LensEvent) -> Self? {
        let type = root["type"] as? String ?? ""
        let p = root["payload"] as? [String: Any] ?? [:]
        let timestamp = event.timestamp == .distantPast ? nil : event.timestamp
        func fact(_ kind: Kind, _ stage: Stage) -> Self {
            Self(kind: kind, stage: stage, protocolID: string(p["id"]), callID: event.callID,
                 parentSessionID: string(p["session_id"]), originTimestamp: timestamp)
        }
        if type == "inter_agent_communication_metadata" {
            var value = fact(.metadata, .metadata)
            value.triggerTurn = p["trigger_turn"] as? Bool
            value.limitations = ["Métadonnée de livraison ; son destinataire et son message doivent être liés par la structure du journal."]
            return value
        }
        if type == "inter_agent_communication" || (type == "response_item" && p["type"] as? String == "agent_message") {
            var value = fact(.message, .recipientContextRecorded)
            value.messageID = string(p["id"])
            value.senderPath = string(p["author"])
            value.recipientPaths = [string(p["recipient"])].compactMap { $0 } + ((p["other_recipients"] as? [String]) ?? []).filter { !$0.isEmpty }
            value.triggerTurn = p["trigger_turn"] as? Bool
            value.isOpaque = p["encrypted_content"] is String || (p["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "encrypted_content" } == true
            if value.triggerTurn == true { value.kind = .followup }
            value.limitations = ["Enregistré dans le contexte du destinataire ; inclusion dans une requête modèle non prouvée."]
            if value.isOpaque { value.limitations.append("Une partie du message est opaque ; son contenu ne peut pas être déduit de la mission du parent.") }
            return value
        }
        if type == "session_meta", p["base_instructions"] != nil {
            var value = fact(.instruction, .instructionRecorded)
            value.affectedAgentID = event.agentID; value.instructionKind = .base
            return value
        }
        if type == "response_item" {
            let subtype = p["type"] as? String ?? ""
            if subtype == "message" {
                let role = p["role"] as? String ?? ""
                guard role == "user" || role == "developer" || role == "system" || event.kind == .instruction else { return nil }
                var value = fact(.instruction, .instructionRecorded)
                value.affectedAgentID = event.agentID
                value.instructionKind = ["user", "developer", "system"].contains(role) ? .direct : .unknown
                return value
            }
            if subtype == "function_call" || subtype == "custom_tool_call" {
                let name = string(p["name"]) ?? event.toolName ?? ""
                guard let kind = toolKind(name) else { return nil }
                let args = dictionary(p["arguments"] ?? p["input"])
                var value = fact(kind, .sendRequested)
                value.toolName = name; value.senderThreadID = event.agentID
                value.callID = string(p["call_id"]) ?? event.callID
                let target = string(args["target"]) ?? string(args["id"]) ?? string(args["agent_id"])
                if let target {
                    if UUID(uuidString: target) != nil { value.recipientThreadIDs = [target] }
                    else { value.recipientPaths = [target] }
                }
                if kind == .spawn {
                    if let task = string(args["task_name"]) { value.recipientPaths = [task] }
                    value.instructionKind = .direct
                }
                if name.split(separator: ".").last == "send_message" { value.triggerTurn = false }
                if name.split(separator: ".").last == "send_input" { value.triggerTurn = true }
                if kind == .followup { value.triggerTurn = true }
                value.limitations = ["Demande enregistrée ; réception et inclusion dans une requête non déduites des arguments."]
                value.isOpaque = hasOpaqueMessage(payload: p)
                if value.isOpaque { value.limitations.append("Message opaque : forme chiffrée reconnue dans les arguments ; contenu et authenticité cryptographique non vérifiés. La trace brute est conservée.") }
                return value
            }
            if subtype == "function_call_output" || subtype == "custom_tool_call_output" {
                let output = dictionary(p["output"])
                let receipt = string(output["submission_id"])
                let kind = event.toolName.flatMap(toolKind)
                guard kind != nil || receipt != nil else { return nil }
                var value = fact(kind ?? .unknown, .submissionRecorded)
                value.toolName = event.toolName; value.senderThreadID = event.agentID
                value.callID = string(p["call_id"]) ?? event.callID
                value.submissionReceiptID = receipt
                if let child = string(output["agent_id"]) ?? string(output["thread_id"]) { value.recipientThreadIDs = [child] }
                value.limitations = ["Résultat d’outil enregistré ; ne prouve ni réception par le destinataire ni inclusion dans une requête."]
                return value
            }
        }
        if type == "event_msg" {
            let subtype = p["type"] as? String ?? ""
            if subtype == "sub_agent_activity" || subtype == "subagent_activity" {
                var value = fact(p["kind"] as? String == "started" ? .spawn : .message, .activityRecorded)
                value.protocolID = string(p["event_id"]); value.callID = string(p["event_id"]) ?? event.callID
                value.senderThreadID = event.agentID; value.affectedAgentID = string(p["agent_thread_id"])
                value.recipientThreadIDs = [value.affectedAgentID].compactMap { $0 }
                value.recipientPaths = [string(p["agent_path"])].compactMap { $0 }
                value.limitations = ["Activité du sous-agent rapportée à l’émetteur ; aucune réception du message ou compréhension déduite."]
                return value
            }
            if subtype == "item_completed" || subtype == "item_started", let item = p["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType == "SubAgentActivity" || itemType == "subAgentActivity" {
                    var value = fact(item["kind"] as? String == "started" ? .spawn : .message, .activityRecorded)
                    value.protocolID = string(item["id"]); value.callID = string(item["id"]) ?? event.callID
                    value.senderThreadID = event.agentID; value.affectedAgentID = string(item["agent_thread_id"] ?? item["agentThreadId"])
                    value.recipientThreadIDs = [value.affectedAgentID].compactMap { $0 }
                    value.recipientPaths = [string(item["agent_path"] ?? item["agentPath"])].compactMap { $0 }
                    value.limitations = ["Activité du sous-agent rapportée ; réception du message et inclusion modèle restent séparées."]
                    return value
                }
                if itemType == "CollabAgentToolCall" || itemType == "collabAgentToolCall" {
                    let tool = string(item["tool"]) ?? "unknown"
                    var value = fact(toolKind(tool) ?? .unknown, .activityRecorded)
                    value.toolName = tool; value.protocolID = string(item["id"]); value.callID = string(item["id"]) ?? event.callID
                    value.senderThreadID = string(item["sender_thread_id"] ?? item["senderThreadId"]) ?? event.agentID
                    value.recipientThreadIDs = (item["receiver_thread_ids"] ?? item["receiverThreadIds"]) as? [String] ?? []
                    value.limitations = ["Statut de l’appel inter-agent rapporté ; les états du destinataire ne prouvent pas l’application des instructions."]
                    return value
                }
            }
            if subtype.hasPrefix("collab_") {
                let kind: Kind = subtype.contains("spawn") ? .spawn : subtype.contains("waiting") ? .wait : .message
                var value = fact(kind, .activityRecorded)
                value.callID = string(p["call_id"]) ?? event.callID
                value.senderThreadID = string(p["sender_thread_id"]) ?? event.agentID
                value.recipientThreadIDs = [string(p["receiver_thread_id"]), string(p["new_thread_id"])].compactMap { $0 } + (p["receiver_thread_ids"] as? [String] ?? [])
                value.limitations = ["Capture d’un événement transitoire ; cette représentation n’est normalement pas persistée dans les rollouts 0.159.2."]
                return value
            }
            if subtype == "hook_started" || subtype == "hook_completed" {
                let run = p["run"] as? [String: Any] ?? [:]
                let eventName = string(run["event_name"] ?? run["eventName"]) ?? ""
                guard eventName == "SubagentStart" || eventName == "SubagentStop" else { return nil }
                var value = fact(.unknown, .activityRecorded)
                value.protocolID = string(run["id"])
                value.affectedAgentID = string(p["agent_id"])
                value.limitations = ["Capture de hook transitoire ; session_id seul n’identifie pas le thread du sous-agent."]
                return value
            }
        }
        // Captures of command-hook inputs are optional, explicit sources; no hook is installed here.
        if let hook = string(p["hook_event_name"] ?? root["hook_event_name"]), hook == "SubagentStart" || hook == "SubagentStop" {
            let input = p.isEmpty ? root : p
            var value = fact(.unknown, .activityRecorded)
            value.parentSessionID = string(input["session_id"])
            value.affectedAgentID = string(input["agent_id"])
            value.limitations = ["session_id est partagé avec la session parente ; l’activité est attribuée uniquement à agent_id quand il est enregistré."]
            return value
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }; return value
    }
    /// Codex 0.159.2 v2 routes collaboration+Some([]) as explicit plaintext.
    /// Other agent calls may carry an encrypted message without a persisted flag.
    /// Require both that namespace and a complete Fernet wire envelope, not a prefix.
    /// This recognizes a representation; it does not decrypt or authenticate it.
    public static func hasOpaqueMessage(payload: [String: Any]) -> Bool {
        guard let namespace = payload["namespace"] as? String, ["agents", "collaboration"].contains(namespace),
              let name = payload["name"] as? String, let kind = toolKind(name), [.spawn, .message, .followup].contains(kind) else { return false }
        if namespace == "collaboration", let keys = payload["encrypted_function_args"] as? [String], keys.isEmpty { return false }
        guard let message = dictionary(payload["arguments"] ?? payload["input"])["message"] as? String,
              message.utf8.count >= 100, message.utf8.count <= 2 * 1024 * 1024,
              message.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,95,61].contains($0) }),
              let bytes = Data(base64Encoded: message.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") == message,
              bytes.first == 0x80, bytes.count >= 73, (bytes.count - 57) % 16 == 0 else { return false }
        return true
    }
    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        guard let value = value as? String, let data = value.data(using: .utf8), data.count <= 2 * 1024 * 1024,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return parsed
    }
    private static func toolKind(_ raw: String) -> Kind? {
        let name = raw.split(separator: ".").last.map(String.init) ?? raw
        switch name {
        case "spawn_agent", "spawnAgent": return .spawn
        case "send_message", "sendMessage", "send_input", "sendInput": return .message
        case "followup_task", "followupTask": return .followup
        case "wait_agent", "wait", "waitAgent": return .wait
        case "resume_agent", "resumeAgent", "interrupt_agent", "interruptAgent", "close_agent", "closeAgent", "list_agents", "listAgents": return .unknown
        default: return nil
        }
    }
}

public struct RecordedCommunication: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: RecordedCommunicationFacts.Kind
    public var timestamp: Date?
    public var collectedAt: Date?
    public var eventIDs: [String]
    public var sourceRefs: [SourceRef]
    public var senderAgentID: String?
    public var senderPath: String?
    public var recipientAgentIDs: [String]
    public var recipientPaths: [String]
    public var parentSessionIDs: [String]
    public var sentEventIDs: [String]
    public var toolResultEventIDs: [String]
    /// Only explicit acceptance evidence; a missing value is not a failed submission.
    public var submissionEventIDs: [String]
    public var recipientContextEventIDs: [String]
    public var modelInclusionEventIDs: [String]
    /// Receipt is scoped to the owner of each journal. Other declared recipients stay unobserved.
    public var recipientContextEventIDsByAgent: [String: [String]]
    public var modelInclusionEventIDsByAgent: [String: [String]]
    public var originEventIDs: [String]
    public var missionEventIDs: [String]
    public var parentAgentIDs: [String]
    public var triggerTurn: Bool?
    public var isOpaque: Bool
    public var limitations: [String]
}

public struct RecordedInstruction: Identifiable, Codable, Hashable, Sendable {
    public var id: String { eventID }
    public var eventID: String
    public var agentID: String
    public var kind: RecordedCommunicationFacts.InstructionKind
    public var inheritedFromThreadID: String?
    public var parentAgentID: String?
    public var missionEventID: String?
    public var sourceRefs: [SourceRef]
    public var limitations: [String]
}

/// Pure projection of an already indexed revision. Building or opening a sequence never reads
/// journals, files or another App Server process. Missing phases stay missing.
public struct CommunicationInspectionIndex: Sendable {
    public let communications: [RecordedCommunication]
    public let communicationByEventID: [String: RecordedCommunication]
    public let instructions: [RecordedInstruction]
    public let instructionByEventID: [String: RecordedInstruction]
    public let collectionLimitations: [String]
    public let unassociatedMetadataEventIDs: [String]

    public init(events: [LensEvent], agents: [AgentRecord]) {
        var generalLimitations = [
            "Codex 0.159.2 ne persiste normalement ni les hooks ni les débuts/fins collab_* dans ses rollouts. Leur absence ne prouve pas l’absence d’opération.",
            "Une réception ou un contexte enregistré ne prouve pas la compréhension, l’application ou l’inclusion dans une requête modèle."
        ]
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agentsByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: [String: [String]] = [:]
        var agentsByMissionEventID: [String: [String]] = [:]
        for agent in agents where agent.name.hasPrefix("/") { paths[agent.name, default: []].append(agent.id) }
        for agent in agents {
            if let mission = agent.missionEventID { agentsByMissionEventID[mission, default: []].append(agent.id) }
        }
        func resolve(_ path: String?) -> String? {
            guard let path else { return nil }
            if agentsByID[path] != nil { return path }
            let matches = paths[path] ?? []
            return matches.count == 1 ? matches[0] : nil
        }
        var factsByID: [String: RecordedCommunicationFacts] = [:]
        for event in events {
            if var facts = event.trace?.communication {
                facts.collectedAt = facts.collectedAt ?? event.trace?.collectedAt
                facts.originTimestamp = facts.originTimestamp ?? event.trace?.recordedAt
                factsByID[event.id] = facts
            } else if event.kind == .instruction || event.kind == .user {
                factsByID[event.id] = RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded,
                    affectedAgentID: event.agentID, instructionKind: event.kind == .user ? .direct : .unknown,
                    originTimestamp: event.timestamp == .distantPast ? nil : event.timestamp,
                    collectedAt: event.trace?.collectedAt)
            }
        }
        // Native output does not normally carry success on the durable wire. Resolve a receipt
        // through the confirmed owner/call link, even when toolName was unknown during parsing.
        for event in events {
            guard var facts = factsByID[event.id], facts.stage == .submissionRecorded, facts.kind == .unknown else { continue }
            guard let callID = event.relatedEventID, let call = eventsByID[callID], call.agentID == event.agentID,
                  let callFacts = factsByID[callID], callFacts.stage == .sendRequested else {
                factsByID.removeValue(forKey: event.id); continue
            }
            facts.kind = callFacts.kind; facts.toolName = callFacts.toolName
            factsByID[event.id] = facts
        }
        func acceptedSubmission(_ result: LensEvent, callFacts: RecordedCommunicationFacts?) -> Bool {
            guard !result.isError, let facts = factsByID[result.id] else { return false }
            if facts.submissionAccepted == true { return true }
            let name = facts.toolName ?? callFacts?.toolName ?? ""
            return name.split(separator: ".").last == "send_input" && facts.submissionReceiptID != nil
        }

        // The format explicitly writes a metadata boundary immediately before the delivered
        // response_item. Pair physical adjacency, never timestamps or similar plaintext.
        var sourcePositions: [String: [Int: String]] = [:]
        for event in events where event.source.line > 0 {
            sourcePositions[event.agentID + "\u{0}" + event.source.path, default: [:]][event.source.line] = event.id
        }
        var metadataForMessage: [String: [String]] = [:]
        for event in events {
            guard let metadata = factsByID[event.id], metadata.stage == .metadata,
                  let nextID = sourcePositions[event.agentID + "\u{0}" + event.source.path]?[event.source.line + 1],
                  var message = factsByID[nextID], message.stage == .recipientContextRecorded else { continue }
            if message.triggerTurn == nil {
                message.triggerTurn = metadata.triggerTurn
                if metadata.triggerTurn == true { message.kind = .followup }
                factsByID[nextID] = message
            } else if let trigger = metadata.triggerTurn, message.triggerTurn != trigger {
                message.limitations.append("Les sources de livraison enregistrent des modes de relance contradictoires.")
                factsByID[nextID] = message
            }
            metadataForMessage[nextID, default: []].append(event.id)
        }
        let associatedMetadata = Set(metadataForMessage.values.flatMap { $0 })
        unassociatedMetadataEventIDs = unique(events.filter { factsByID[$0.id]?.stage == .metadata && !associatedMetadata.contains($0.id) }.map(\.id))
        if !unassociatedMetadataEventIDs.isEmpty { generalLimitations.append("Métadonnées de livraison sans message adjacent accessible : \(unassociatedMetadataEventIDs.count). Aucun destinataire ni déclenchement déduit.") }
        collectionLimitations = generalLimitations

        var records: [String: RecordedCommunication] = [:]
        var instructionRecords: [RecordedInstruction] = []
        var instructionIDs = Set<String>()
        for event in events {
            guard let facts = factsByID[event.id] else { continue }
            if facts.kind == .instruction || facts.stage == .instructionRecorded {
                guard instructionIDs.insert(event.id).inserted else { continue }
                let affected = facts.affectedAgentID ?? event.agentID
                let agent = agentsByID[affected]
                var limits = facts.limitations
                let kind = facts.instructionKind ?? .unknown
                if kind == .inherited && facts.inheritedFromThreadID == nil { limits.append("Instruction héritée indiquée, mais source d’héritage non enregistrée.") }
                if kind == .unknown { limits.append("Origine et portée de cette instruction non établies dans les données visibles.") }
                instructionRecords.append(RecordedInstruction(eventID: event.id, agentID: affected, kind: kind,
                    inheritedFromThreadID: facts.inheritedFromThreadID, parentAgentID: agent?.parentID,
                    missionEventID: agent?.missionEventID, sourceRefs: unique([event.source] + event.supplementarySources), limitations: unique(limits)))
                continue
            }
            if facts.stage == .metadata { continue }
            let sender = facts.senderThreadID ?? resolve(facts.senderPath) ?? (facts.stage == .sendRequested || facts.stage == .submissionRecorded ? event.agentID : nil)
            var recipients = facts.recipientThreadIDs + facts.recipientPaths.compactMap(resolve)
            // A recorded mission link supplies the child identity even when task_name is short
            // or redacted. Never resolve that short name by a suffix or a matching mission text.
            if facts.kind == .spawn { recipients += agentsByMissionEventID[event.id] ?? [] }
            if let child = facts.affectedAgentID { recipients.append(child) }
            var limits = facts.limitations
            if facts.stage == .recipientContextRecorded {
                if recipients.isEmpty || recipients.contains(event.agentID) { recipients.append(event.agentID) }
                else { limits.append("Le destinataire déclaré diffère du propriétaire du journal ; association conservée comme contradictoire.") }
            }
            recipients = unique(recipients)
            // A recorded call id is scoped to its owner. Message identity also keeps endpoints,
            // preventing unrelated agents with the same protocol id from being merged.
            let key: String
            if let call = facts.callID { key = "communication:" + event.agentID + ":call:" + call }
            else if let message = facts.communicationID ?? facts.messageID ?? facts.protocolID {
                key = "communication:" + event.agentID + ":message:" + message + ":" + (facts.senderPath ?? sender ?? "?") + ":" + (facts.recipientPaths.first ?? recipients.first ?? "?")
            } else { key = "communication:" + event.id }
            var record = records[key] ?? RecordedCommunication(id: key, kind: facts.kind,
                timestamp: facts.originTimestamp, collectedAt: facts.collectedAt, eventIDs: [], sourceRefs: [],
                senderAgentID: sender, senderPath: facts.senderPath, recipientAgentIDs: [], recipientPaths: [],
                parentSessionIDs: [], sentEventIDs: [], toolResultEventIDs: [], submissionEventIDs: [], recipientContextEventIDs: [],
                modelInclusionEventIDs: [], recipientContextEventIDsByAgent: [:], modelInclusionEventIDsByAgent: [:], originEventIDs: [], missionEventIDs: [], parentAgentIDs: [],
                triggerTurn: facts.triggerTurn, isOpaque: false, limitations: [])
            if record.kind == .unknown { record.kind = facts.kind }
            record.eventIDs.append(event.id); record.sourceRefs += [event.source] + event.supplementarySources
            for metadataID in metadataForMessage[event.id] ?? [] {
                record.eventIDs.append(metadataID)
                if let metadata = eventsByID[metadataID] { record.sourceRefs += [metadata.source] + metadata.supplementarySources }
            }
            if let sender, let previous = record.senderAgentID, sender != previous {
                limits.append("Des sources partageant l’ID d’appel indiquent des émetteurs différents.")
            } else { record.senderAgentID = sender ?? record.senderAgentID }
            record.senderPath = record.senderPath ?? facts.senderPath
            if !record.recipientAgentIDs.isEmpty && !facts.recipientThreadIDs.isEmpty && Set(record.recipientAgentIDs).isDisjoint(with: facts.recipientThreadIDs) {
                limits.append("Des sources partageant l’ID d’appel indiquent des destinataires différents ; aucun destinataire unique déduit.")
            }
            record.recipientAgentIDs += recipients; record.recipientPaths += facts.recipientPaths
            if let parentSession = facts.parentSessionID { record.parentSessionIDs.append(parentSession) }
            if let old = record.triggerTurn, let new = facts.triggerTurn, old != new { limits.append("Modes de relance contradictoires ; aucun mode unique déduit."); record.triggerTurn = nil }
            else { record.triggerTurn = facts.triggerTurn ?? record.triggerTurn }
            record.isOpaque = record.isOpaque || facts.isOpaque
            switch facts.stage {
            case .sendRequested: record.sentEventIDs.append(event.id); record.originEventIDs.append(event.id)
            case .submissionRecorded:
                record.toolResultEventIDs.append(event.id)
                if acceptedSubmission(event, callFacts: nil) { record.submissionEventIDs.append(event.id) }
                if event.isError { limits.append("Résultat d’outil en erreur ; aucune soumission acceptée n’est déduite.") }
            case .recipientContextRecorded:
                record.recipientContextEventIDs.append(event.id)
                record.recipientContextEventIDsByAgent[event.agentID, default: []].append(event.id)
                if recipients.contains(where: { $0 != event.agentID }) { limits.append("Seul le contexte du propriétaire de ce journal est observé ; les autres destinataires sont référencés sans réception confirmée.") }
            case .requestInclusionConfirmed:
                record.modelInclusionEventIDs.append(event.id)
                record.modelInclusionEventIDsByAgent[event.agentID, default: []].append(event.id)
            default: break
            }
            // Existing confirmed call/result links do not depend on output preview text.
            if facts.stage == .sendRequested, let resultID = event.relatedEventID, let result = eventsByID[resultID], result.kind == .toolResult, result.agentID == event.agentID {
                record.toolResultEventIDs.append(resultID); record.eventIDs.append(resultID)
                if acceptedSubmission(result, callFacts: facts) { record.submissionEventIDs.append(resultID) }
                if result.isError { record.limitations.append("Résultat d’outil en erreur ; aucune soumission acceptée n’est déduite.") }
                record.sourceRefs += [result.source] + result.supplementarySources
            }
            if let time = facts.originTimestamp { record.timestamp = min(record.timestamp ?? time, time) }
            if let collected = facts.collectedAt { record.collectedAt = max(record.collectedAt ?? collected, collected) }
            record.limitations += limits
            for agentID in unique(recipients + [sender, facts.affectedAgentID].compactMap { $0 }) {
                if let agent = agentsByID[agentID] {
                    if let mission = agent.missionEventID { record.missionEventIDs.append(mission) }
                    if let parent = agent.parentID { record.parentAgentIDs.append(parent) }
                }
            }
            records[key] = record
        }
        var final = records.values.map { original -> RecordedCommunication in
            var value = original
            value.eventIDs = unique(value.eventIDs); value.sourceRefs = unique(value.sourceRefs)
            value.recipientAgentIDs = unique(value.recipientAgentIDs); value.recipientPaths = unique(value.recipientPaths)
            value.parentSessionIDs = unique(value.parentSessionIDs); value.sentEventIDs = unique(value.sentEventIDs)
            value.toolResultEventIDs = unique(value.toolResultEventIDs)
            value.submissionEventIDs = unique(value.submissionEventIDs); value.recipientContextEventIDs = unique(value.recipientContextEventIDs)
            value.modelInclusionEventIDs = unique(value.modelInclusionEventIDs); value.originEventIDs = unique(value.originEventIDs)
            value.recipientContextEventIDsByAgent = value.recipientContextEventIDsByAgent.mapValues(unique)
            value.modelInclusionEventIDsByAgent = value.modelInclusionEventIDsByAgent.mapValues(unique)
            value.missionEventIDs = unique(value.missionEventIDs); value.parentAgentIDs = unique(value.parentAgentIDs)
            if value.recipientContextEventIDs.isEmpty { value.limitations.append("Réception dans le contexte du destinataire non observée dans les données visibles.") }
            if value.modelInclusionEventIDs.isEmpty { value.limitations.append("Inclusion dans une requête modèle non confirmée.") }
            if !value.toolResultEventIDs.isEmpty && value.submissionEventIDs.isEmpty { value.limitations.append("Résultat enregistré. Acceptation de la soumission non enregistrée.") }
            for mission in value.missionEventIDs where eventsByID[mission] == nil { value.limitations.append("Mission liée mais événement d’origine indisponible : " + mission) }
            value.limitations = unique(value.limitations)
            return value
        }
        final.sort { ($0.timestamp ?? .distantPast, $0.id) < ($1.timestamp ?? .distantPast, $1.id) }
        communications = final
        var byEvent: [String: RecordedCommunication] = [:]
        for communication in final { for id in communication.eventIDs { byEvent[id] = communication } }
        communicationByEventID = byEvent
        // AgentRecord.missionEventID is an existing recorded relation, not a temporal guess.
        // Expose delegated missions alongside user/developer/base instruction history.
        for agent in agents {
            guard let missionID = agent.missionEventID, !instructionIDs.contains(missionID),
                  let mission = eventsByID[missionID], let facts = factsByID[missionID],
                  facts.kind == .spawn || facts.kind == .message || facts.kind == .followup else { continue }
            instructionIDs.insert(missionID)
            let kind: RecordedCommunicationFacts.InstructionKind = facts.isOpaque ? .unknown : .direct
            let limits = facts.isOpaque ? ["Mission liée par un identifiant enregistré ; contenu partiellement opaque, instruction complète indisponible."] : []
            instructionRecords.append(RecordedInstruction(eventID: missionID, agentID: agent.id, kind: kind,
                inheritedFromThreadID: nil, parentAgentID: agent.parentID, missionEventID: missionID,
                sourceRefs: unique([mission.source] + mission.supplementarySources), limitations: limits))
        }
        instructionRecords.sort {
            let lhs = eventsByID[$0.eventID]?.timestamp ?? .distantPast
            let rhs = eventsByID[$1.eventID]?.timestamp ?? .distantPast
            return (lhs, $0.eventID) < (rhs, $1.eventID)
        }
        instructions = instructionRecords
        instructionByEventID = Dictionary(instructionRecords.map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private func unique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>(); return values.filter { seen.insert($0).inserted }
}
