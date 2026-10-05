import Foundation

/// Native sequence rendering consumes this bounded metadata projection; it never rereads a journal.
public struct CommunicationSequenceProjection: Sendable {
    public struct Lane: Identifiable, Sendable { public var id: String; public var name: String }
    public struct Route: Identifiable, Sendable {
        public var id: String { communication.id }
        public var communication: RecordedCommunication
        public var eventID: String
        public var senderLane: Int
        public var recipientLanes: [Int]
    }
    public let lanes: [Lane]
    public let routes: [Route]
    public let omittedAgentCount: Int
    public init(communications: [RecordedCommunication], agents: [AgentRecord], maximumLanes: Int = 32) {
        let known = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let participants = Set(communications.flatMap { [$0.senderAgentID].compactMap { $0 } + $0.recipientAgentIDs }).sorted()
        let included = Array(participants.prefix(max(1, min(64, maximumLanes))))
        var lanes = included.map { id in
            let name = known[id]?.name ?? ""
            return Lane(id: id, name: name.isEmpty ? String(id.prefix(8)) : name)
        }
        let unknown = lanes.count
        lanes.append(Lane(id: "lens:unresolved-participant", name: "Identité non résolue"))
        let positions = Dictionary(included.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        self.lanes = lanes; omittedAgentCount = max(0, participants.count - included.count)
        self.routes = communications.compactMap { communication in
            guard let event = communication.eventIDs.first else { return nil }
            let recipients = Array(Set(communication.recipientAgentIDs.map { positions[$0] ?? unknown })).sorted()
            return Route(communication: communication, eventID: event,
                         senderLane: communication.senderAgentID.flatMap { positions[$0] } ?? unknown,
                         recipientLanes: recipients.isEmpty ? [unknown] : recipients)
        }
    }
}
