import Foundation

public enum OriginLinkNature: String, Codable, Sendable {
    case explicit, declaredMotive, associatedContext, lensInterpretation, notEstablished
    public var label: String {
        switch self {
        case .explicit: return "Lien explicite"
        case .declaredMotive: return "Motif déclaré"
        case .associatedContext: return "Contexte associé · causalité non établie"
        case .lensInterpretation: return "Interprétation de Lens"
        case .notEstablished: return "Lien non établi"
        }
    }
}
public enum OriginObjectKind: String, Codable, Sendable { case instruction, execution, explanation, agent, change, verification, resource }
public struct OriginObject: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sourceID: String
    public let kind: OriginObjectKind
    public let title: String
    public let agentID: String?
    public let turnID: String?
    public let callID: String?
    public let sourceIdentifiers: [String: String]
    public let environmentID: String?
    public let timestamp: Date?
    public let timestampBasis: String
    public let collectedAt: Date
    public let sources: [SourceRef]
    public let availability: String
}
public struct OriginLink: Identifiable, Codable, Hashable, Sendable {
    public var id: String { from + "\u{1f}" + to + "\u{1f}" + relation }
    public let from: String
    public let to: String
    public let relation: String
    public let nature: OriginLinkNature
    public let sources: [SourceRef]
}
// Hash the existing fields instead of allocating and normalizing a concatenated
// public navigation ID for every link during indexing. The first recorded link
// still wins; public IDs and serialized references are unchanged.
private struct OriginLinkKey: Hashable {
    let from: String
    let to: String
    let relation: String
}

public struct OriginExplanation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { eventID + "\u{1f}" + contextActionEventID }
    public let eventID: String
    public let contextActionEventID: String
    public let relation: OriginLinkNature
    public let ordering: String
    public let facts: RecordedExplanationFacts
}
public struct OriginVerification: Codable, Hashable, Sendable, Identifiable {
    public var id: String { eventIDs.joined(separator: "\u{1f}") }
    public let eventIDs: [String]
    public let relation: OriginLinkNature
    public let ordering: String
    public let subsequentChangeIDs: [String]
    /// Optional for decoding capsules saved before this bounded projection existed.
    public let omittedSubsequentChangeCount: Int?
    public let changeScope: String?
    public let versionCoverage: String
}
public struct OriginSelection: Codable, Hashable, Sendable {
    public let object: OriginObject
    public let links: [OriginLink]
    public let objects: [OriginObject]
    public let missionEventIDs: [String]
    public let delegationEventIDs: [String]
    public let missionTargetAgentIDs: [String]
    public let instructionEventIDs: [String]
    public let explanations: [OriginExplanation]
    public let contributionChangeIDs: [String]
    public let verifications: [OriginVerification]
    public var verificationEventIDs: [String] { verifications.flatMap(\.eventIDs) }
    public let missing: [String]
    public let omittedLinkCount: Int
    public let omittedExplanationCount: Int
    /// Bound explicit/contextual references, not an unbounded transitive graph.
    public var evidenceEventIDs: [String] {
        var seen = Set<String>()
        let selected = object.kind == .agent || object.kind == .change ? [] : [object.sourceID]
        let executions = objects.filter { $0.kind == .execution }.map(\.sourceID)
        return (selected + executions + missionEventIDs + instructionEventIDs + explanations.map(\.eventID) + verificationEventIDs).filter { seen.insert($0).inserted }
    }
}

/// Passive, pure projection. Same turn proves context membership, never a causal motive.
/// No journal/file access, current content substitution, name resolution or model call.
public struct OriginInspectionIndex: Sendable {
    public let objectsByID: [String: OriginObject]
    public let links: [OriginLink]
    public let associatedEventIDsByInstruction: [String: Set<String>]
    public let associatedChangeIDsByInstruction: [String: [String]]
    public let truncatedInstructionScopes: Set<String>
    // Adjacency owns row indices, not additional copies of every link value.
    // Appending rows in graph order preserves traversal and selection ordering.
    private let outgoing: [String: [Int]]
    private let incoming: [String: [Int]]
    private let events: [String: LensEvent]
    private let agents: [String: AgentRecord]
    private let changes: [String: ChangeRecord]
    private let instructions: [String: RecordedInstruction]
    private let contextsByTurn: [String: [String]]
    private let explanationsByTurn: [String: [LensEvent]]
    private let changesByFile: [String: [String]]
    private let testsByEnvironment: [String: [String]]
    private let testByEventID: [String: RecordedTestObservation]
    private let missionTargetsByEventID: [String: [String]]
    private let collectionCut: Date
    public static func eventID(_ id: String) -> String { "event:" + id }
    public static func agentID(_ id: String) -> String { "agent:" + id }
    public static func changeID(_ id: String) -> String { "change:" + id }
    private static func turnKey(_ agent: String, _ turn: String) -> String { agent + "\u{0}" + turn }
    private static func fileKey(_ environment: String, _ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : (environment as NSString).appendingPathComponent(path)
        return environment + "\u{0}" + URL(fileURLWithPath: absolute).standardizedFileURL.path
    }
    public func changeIDs(environment: String, path: String) -> [String] { changesByFile[Self.fileKey(environment, path)] ?? [] }

    public init(snapshot: SessionSnapshot, communication: CommunicationInspectionIndex, activity: ActivityEvidenceIndex) {
        let events = Dictionary(snapshot.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.init(snapshot: snapshot, communication: communication, activity: activity, resolvedEvents: events)
    }

    /// The presentation's immutable lookup comes from this same snapshot. For
    /// unique IDs, Dictionary value assignment shares its copy-on-write storage.
    /// Duplicate IDs retain the public initializer's first-record semantics;
    /// the presentation lookup independently preserves its existing last record.
    init(snapshot: SessionSnapshot, communication: CommunicationInspectionIndex, activity: ActivityEvidenceIndex,
         sharedEventsByID: [String: LensEvent]) {
        if sharedEventsByID.count == snapshot.events.count {
            self.init(snapshot: snapshot, communication: communication, activity: activity, resolvedEvents: sharedEventsByID)
        } else {
            self.init(snapshot: snapshot, communication: communication, activity: activity)
        }
    }

    private init(snapshot: SessionSnapshot, communication: CommunicationInspectionIndex, activity: ActivityEvidenceIndex,
                 resolvedEvents: [String: LensEvent]) {
        collectionCut = snapshot.collectedAt
        let live = snapshot.events.filter { $0.trace?.communication?.instructionKind != .inherited }
        let events = resolvedEvents; self.events = events
        let agents = Dictionary(snapshot.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); self.agents = agents
        let changes = Dictionary(snapshot.changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); self.changes = changes
        let instructions = communication.instructionByEventID; self.instructions = instructions
        var nodes: [String: OriginObject] = [:], relations: [OriginLink] = []
        var turns: [String: [String]] = [:], explanatory: [String: [LensEvent]] = [:]
        var recordedLinks = Set<OriginLinkKey>()
        func add(_ from: String, _ to: String, _ relation: String, _ nature: OriginLinkNature, _ sources: [SourceRef]) {
            guard nodes[from] != nil, nodes[to] != nil, from != to,
                  recordedLinks.insert(OriginLinkKey(from: from, to: to, relation: relation)).inserted else { return }
            relations.append(OriginLink(from: from, to: to, relation: relation, nature: nature, sources: sources))
        }
        for e in snapshot.events {
            let kind: OriginObjectKind = instructions[e.id] != nil || e.kind == .user ? .instruction : e.trace?.explanation != nil ? .explanation : .execution
            let id = Self.eventID(e.id)
            nodes[id] = OriginObject(id: id, sourceID: e.id, kind: kind, title: e.title, agentID: e.agentID, turnID: e.turnID, callID: e.callID, sourceIdentifiers: e.trace?.sourceIdentifiers ?? [:], environmentID: e.environmentID,
                timestamp: e.timestamp == .distantPast ? nil : e.timestamp, timestampBasis: Self.timeBasis(e), collectedAt: e.trace?.collectedAt ?? snapshot.collectedAt,
                sources: [e.source] + e.supplementarySources, availability: e.trace?.communication?.isOpaque == true ? "opaque" : e.trace?.explanation?.availability.rawValue ?? "recorded")
        }
        for a in snapshot.agents {
            let id = Self.agentID(a.id)
            nodes[id] = OriginObject(id: id, sourceID: a.id, kind: .agent, title: a.name, agentID: a.id, turnID: nil, callID: nil, sourceIdentifiers: [:], environmentID: nil,
                timestamp: nil, timestampBasis: "unavailable", collectedAt: snapshot.collectedAt, sources: a.relationSources ?? [], availability: a.accessible ? "recorded" : "unavailable")
        }
        var files: [String: [String]] = [:]
        for c in snapshot.changes {
            let e = events[c.eventID], id = Self.changeID(c.id)
            nodes[id] = OriginObject(id: id, sourceID: c.id, kind: .change, title: c.path, agentID: c.agentID, turnID: e?.turnID, callID: e?.callID, sourceIdentifiers: e?.trace?.sourceIdentifiers ?? [:], environmentID: c.environmentID,
                timestamp: e.flatMap { $0.timestamp == .distantPast ? nil : $0.timestamp }, timestampBasis: e.map(Self.timeBasis) ?? "unavailable", collectedAt: snapshot.collectedAt,
                sources: e.map { [$0.source] + $0.supplementarySources } ?? [], availability: c.kind.rawValue)
            add(Self.eventID(c.eventID), id, "Source enregistrée du changement", .explicit, e.map { [$0.source] } ?? [])
            files[Self.fileKey(c.environmentID, c.path), default: []].append(c.id)
        }
        changesByFile = files
        var missionTargets: [String: [String]] = [:]
        for a in snapshot.agents {
            if let parent = a.parentID {
                add(Self.agentID(parent), Self.agentID(a.id), a.relation == .subagent ? "Parent de sous-agent enregistré" : a.relation == .fork ? "Fork enregistré · pas une délégation" : "Relation de thread enregistrée", .explicit, a.relationSources ?? [])
            }
            // A fork's copied history is not a delegated mission or a new execution.
            if a.relation == .subagent, let mission = a.missionEventID {
                add(Self.eventID(mission), Self.agentID(a.id), "Mission transmise à cet agent", .explicit, events[mission].map { [$0.source] } ?? [])
                missionTargets[mission, default: []].append(a.id)
            }
        }
        missionTargetsByEventID = missionTargets
        for e in live {
            add(Self.agentID(e.agentID), Self.eventID(e.id), "Producteur enregistré de l’événement", .explicit, [e.source])
            if let facts = e.trace?.explanation, facts.declaredForCallID != nil, facts.declaredForCallID == e.callID {
                let id = "motive:" + e.id
                nodes[id] = OriginObject(id: id, sourceID: e.id, kind: .explanation, title: "Motif déclaré pour cet appel", agentID: e.agentID, turnID: e.turnID, callID: e.callID, sourceIdentifiers: e.trace?.sourceIdentifiers ?? [:], environmentID: e.environmentID,
                    timestamp: e.timestamp == .distantPast ? nil : e.timestamp, timestampBasis: Self.timeBasis(e), collectedAt: e.trace?.collectedAt ?? snapshot.collectedAt, sources: [e.source], availability: facts.availability.rawValue)
                add(id, Self.eventID(e.id), "Champ explanation documenté de cet appel update_plan", .declaredMotive, [e.source])
            }
            if let related = e.relatedEventID, let other = events[related], other.agentID == e.agentID, e.callID == other.callID, e.callID != nil {
                let from = e.kind == .toolResult ? related : e.id, to = e.kind == .toolResult ? e.id : related
                add(Self.eventID(from), Self.eventID(to), "Appel et résultat · identifiant commun", .explicit, [e.source, other.source])
            }
            if let turn = e.turnID {
                let key = Self.turnKey(e.agentID, turn)
                if nodes[Self.eventID(e.id)]?.kind == .instruction { turns[key, default: []].append(e.id) }
                if e.trace?.explanation != nil { explanatory[key, default: []].append(e) }
            }
        }
        contextsByTurn = turns; explanationsByTurn = explanatory
        // Bounded contextual relations. An instruction's scope is never inferred from nearest time.
        for e in live {
            guard let turn = e.turnID else { continue }
            for instruction in (turns[Self.turnKey(e.agentID, turn)] ?? []).prefix(32) {
                add(Self.eventID(instruction), Self.eventID(e.id), "Même thread et tour enregistrés", .associatedContext, [events[instruction]!.source, e.source])
            }
        }
        var tests: [String: [String]] = [:]
        var testEvents: [String: RecordedTestObservation] = [:]
        for test in activity.tests {
            let ids = test.activity.eventIDs
            if let env = ids.compactMap({ events[$0]?.environmentID }).first {
                tests[env, default: []] += ids
                for id in ids { testEvents[id] = test }
            }
        }
        testsByEnvironment = tests
        testByEventID = testEvents
        objectsByID = nodes; links = relations
        var allOut: [String: [Int]] = [:], allIn: [String: [Int]] = [:]
        for row in relations.indices {
            let link = relations[row]
            allOut[link.from, default: []].append(row)
            allIn[link.to, default: []].append(row)
        }
        outgoing = allOut; incoming = allIn
        // The exact thread/turn scope ends at an agent identity. A mission is a navigation
        // link, never a licence to attribute that agent's lifetime or descendants to a prompt.
        var scoped: [String: Set<String>] = [:]
        var truncated = Set<String>()
        for instruction in communication.instructions where instruction.kind != .inherited {
            var seen: Set<String> = [Self.eventID(instruction.eventID)], queue = Array(seen), cursor = 0
            while cursor < queue.count {
                let id = queue[cursor]; cursor += 1
                for row in allOut[id] ?? [] {
                    let link = relations[row]
                    guard queue.count < 4096 else { truncated.insert(instruction.eventID); break }
                    guard nodes[link.to]?.kind != .agent else { continue }
                    if seen.insert(link.to).inserted { queue.append(link.to) }
                }
                if queue.count >= 4096, cursor < queue.count { truncated.insert(instruction.eventID); break }
            }
            scoped[instruction.eventID] = Set(queue.compactMap { id in id.hasPrefix("event:") ? String(id.dropFirst(6)) : nil })
        }
        associatedEventIDsByInstruction = scoped
        truncatedInstructionScopes = truncated
        let byEvent = Dictionary(grouping: snapshot.changes, by: \.eventID)
        associatedChangeIDsByInstruction = scoped.mapValues { ids in ids.sorted().flatMap { (byEvent[$0] ?? []).map(\.id) } }
    }

    private static func timeBasis(_ event: LensEvent) -> String {
        event.trace?.explanation?.timestampBasis.rawValue ?? (event.timestamp == .distantPast ? "unavailable" : "recordedEventTimingGenerationUnknown")
    }

    public func selection(objectID: String, maximumLinks: Int = 64) -> OriginSelection? {
        guard let object = objectsByID[objectID] else { return nil }
        let change = object.kind == .change ? changes[object.sourceID] : nil
        let selectedEvent = events[change?.eventID ?? object.sourceID]
        let owner = agents[object.agentID ?? ""]
        var missionIDs: [String] = [], seenAgents = Set<String>(), missing: [String] = []
        var cursor = owner
        if change != nil, selectedEvent == nil { missing.append("Événement source du changement inaccessible.") }
        if let change, change.kind != .requestedPatch, let event = selectedEvent, event.kind != .toolCall,
           event.relatedEventID.flatMap({ events[$0] })?.kind != .toolCall { missing.append("Appel responsable non identifié ; le producteur de la trace ne prouve pas l’auteur de chaque effet.") }
        while let a = cursor, seenAgents.insert(a.id).inserted, seenAgents.count <= 16 {
            if a.relation == .subagent {
                if let id = a.missionEventID, events[id] != nil { missionIDs.append(id) }
                else { missing.append("Mission de « \(a.name) » non retrouvée dans les données visibles.") }
            } else if a.relation == .fork || a.relation == .continuation {
                missing.append("Historique forké ou repris : cette relation n’établit pas une nouvelle délégation.")
                break
            }
            if let parent = a.parentID {
                guard let p = agents[parent] else { missing.append("Parent enregistré inaccessible : \(parent)"); break }
                cursor = p
            } else { cursor = nil }
        }
        var instructionIDs: [String] = []
        for id in ([selectedEvent?.id].compactMap { $0 } + missionIDs) {
            guard let e = events[id], let turn = e.turnID else { continue }
            instructionIDs += contextsByTurn[Self.turnKey(e.agentID, turn)] ?? []
        }
        var seenInstructions = Set<String>(); instructionIDs = instructionIDs.filter { seenInstructions.insert($0).inserted }
        if instructionIDs.count > 32 { missing.append("Trente-deux instructions associées au plus sont affichées ; aucune origine unique n’est déduite.") }
        if missionIDs.isEmpty && instructionIDs.isEmpty { missing.append("Origine instructionnelle non établie ; aucune demande déduite de l’ordre temporel.") }
        var explanations: [OriginExplanation] = []
        var omittedExplanations = 0
        for action in [selectedEvent].compactMap({ $0 }) + missionIDs.compactMap({ events[$0] }) {
            if let facts = action.trace?.explanation, facts.declaredForCallID != nil, facts.declaredForCallID == action.callID {
                explanations.append(OriginExplanation(eventID: action.id, contextActionEventID: action.id, relation: .declaredMotive, ordering: "Motif déclaré pour cet appel uniquement", facts: facts))
            }
            guard let turn = action.turnID else { continue }
            let pool = explanationsByTurn[Self.turnKey(action.agentID, turn)] ?? []
            let maximum = min(8, max(0, 32 - explanations.count))
            omittedExplanations += max(0, pool.count - (action.trace?.explanation == nil ? 0 : 1) - maximum)
            for e in pool.lazy.filter({ $0.id != action.id }).prefix(maximum) {
                guard let facts = e.trace?.explanation else { continue }
                let order = e.source.path == action.source.path && e.source.offset != action.source.offset ? (e.source.offset < action.source.offset ? "Enregistrée avant l’action dans ce journal" : "Déclaration enregistrée après l’action dans ce journal") : "Ordre relatif non établi"
                explanations.append(OriginExplanation(eventID: e.id, contextActionEventID: action.id, relation: .associatedContext, ordering: order, facts: facts))
            }
        }
        if explanations.isEmpty { missing.append("Aucune explication associable par thread et tour enregistré ; présence ailleurs non exclue.") }
        var relevant = Set([object.id] + (selectedEvent.map { [Self.eventID($0.id), Self.agentID($0.agentID)] } ?? []))
        for id in missionIDs + instructionIDs + explanations.map(\.eventID) { relevant.insert(Self.eventID(id)) }
        for id in seenAgents { relevant.insert(Self.agentID(id)) }
        if let selectedEvent, objectsByID["motive:" + selectedEvent.id] != nil { relevant.insert("motive:" + selectedEvent.id) }
        if let action = selectedEvent, let related = action.relatedEventID, let counterpart = events[related], action.callID != nil, action.callID == counterpart.callID, action.agentID == counterpart.agentID { relevant.insert(Self.eventID(related)) }
        let fileChanges = change.map { changesByFile[Self.fileKey($0.environmentID, $0.path)] ?? [] } ?? associatedChangeIDsByInstruction[object.sourceID] ?? []
        let scope = associatedEventIDsByInstruction[object.sourceID] ?? []
        let delegations = Array(Set(([selectedEvent?.id].compactMap { $0 } + scope.filter { missionTargetsByEventID[$0] != nil })).filter { missionTargetsByEventID[$0] != nil }).sorted().prefix(32)
        let targets = Array(Set(delegations.flatMap { missionTargetsByEventID[$0] ?? [] })).sorted()
        for id in delegations { relevant.insert(Self.eventID(id)) }
        for id in targets { relevant.insert(Self.agentID(id)) }
        if !targets.isEmpty { missing.append("Une mission identifie son destinataire ; son activité ultérieure n’est pas automatiquement attribuée à cette instruction.") }
        if seenAgents.contains(where: { agents[$0]?.parentID != nil && (agents[$0]?.relationSources ?? []).isEmpty }) { missing.append("Source détaillée de parenté non disponible pour certains liens ; consulter la provenance de l’agent.") }
        if truncatedInstructionScopes.contains(object.sourceID) { missing.append("Périmètre borné à 4096 objets ; actions supplémentaires non affichées, chaîne non exhaustive.") }
        if fileChanges.count > 32 { missing.append("Trente-deux modifications au plus sont affichées ; les autres restent dans Modifications.") }
        for id in fileChanges.prefix(32) { relevant.insert(Self.changeID(id)) }
        // Incoming degree is bounded by recorded contexts. Do not enumerate all an agent's activity in SwiftUI.
        var candidates = relevant.sorted().flatMap { incoming[$0] ?? [] }
        var seenLinks = Set<String>(); candidates = candidates.filter { seenLinks.insert(links[$0].id).inserted }
        // Only chosen objects, selected call/result, mission chain and its same-turn contexts.
        candidates = candidates.filter { relevant.contains(links[$0].from) && relevant.contains(links[$0].to) }
        let retained = candidates.prefix(max(0, maximumLinks)).map { links[$0] }
        let nodeIDs = relevant.union(retained.flatMap { [$0.from, $0.to] })
        let testIDs = selectedEvent?.environmentID.flatMap { testsByEnvironment[$0] } ?? []
        var seenTests = Set<String>()
        let tests = testIDs.compactMap { testByEventID[$0] }.filter { seenTests.insert($0.id).inserted }.sorted {
            let a = $0.activity.eventIDs.compactMap { events[$0]?.timestamp }.first ?? .distantPast
            let b = $1.activity.eventIDs.compactMap { events[$0]?.timestamp }.first ?? .distantPast
            return (a, $0.id) < (b, $1.id)
        }
        let selectedFileChangeIDs = change.map { _ in Set(fileChanges) }
        let verifications = tests.prefix(16).map { test -> OriginVerification in
            let e = test.activity.eventIDs.compactMap { events[$0] }.first
            let ordering: String
            if let e, let selectedEvent, e.source.path == selectedEvent.source.path {
                ordering = e.source.offset < selectedEvent.source.offset ? "Test enregistré avant cette action" : e.source.offset > selectedEvent.source.offset ? "Test enregistré après cette action" : "Même enregistrement"
            } else { ordering = "Ordre relatif non établi" }
            // The complete observation stays in ActivityEvidenceIndex. A selection must not
            // copy an environment's entire future history into every test and chat capsule.
            let scoped = selectedFileChangeIDs.map { ids in test.subsequentChangeIDs.filter { ids.contains($0) } } ?? test.subsequentChangeIDs
            return OriginVerification(eventIDs: test.activity.eventIDs, relation: .associatedContext, ordering: ordering,
                subsequentChangeIDs: Array(scoped.prefix(32)), omittedSubsequentChangeCount: max(0, scoped.count - 32),
                changeScope: change == nil ? "Périmètre : cet environnement" : "Périmètre : ce fichier dans cet environnement",
                versionCoverage: "Version testée et couverture de cette modification non établies")
        }
        if verifications.contains(where: { ($0.omittedSubsequentChangeCount ?? 0) > 0 }) { missing.append("Trente-deux références aux modifications suivantes au plus par test ; observations complètes dans Activité.") }
        if tests.count > 16 { missing.append("Seize observations de test au plus sont affichées ; les autres restent dans Activité.") }
        return OriginSelection(object: object, links: retained, objects: nodeIDs.sorted().compactMap { objectsByID[$0] }, missionEventIDs: missionIDs,
            delegationEventIDs: Array(delegations), missionTargetAgentIDs: targets,
            instructionEventIDs: Array(instructionIDs.prefix(32)), explanations: explanations, contributionChangeIDs: Array(fileChanges.prefix(32)),
            verifications: verifications, missing: missing, omittedLinkCount: max(0, candidates.count - retained.count), omittedExplanationCount: omittedExplanations)
    }
}
