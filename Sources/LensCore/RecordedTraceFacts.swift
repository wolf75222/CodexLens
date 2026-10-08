import Foundation

/// Recorded metadata with value semantics and copy-on-write storage.
/// Absent payloads occupy only reference slots in the shared state. Present
/// payloads are immutable shared values, so unrelated metadata updates do not
/// copy them. No fields are discarded; Codable retains its original wire shape.
public struct RecordedTraceFacts: Codable, Hashable, Sendable {
    private final class Payload<T: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
        let value: T
        init(_ value: T) { self.value = value }
        init(from decoder: Decoder) throws { value = try T(from: decoder) }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
        static func == (lhs: Payload, rhs: Payload) -> Bool { lhs.value == rhs.value }
        func hash(into hasher: inout Hasher) { hasher.combine(value) }
    }
    private struct Value: Codable, Hashable, Sendable {
        var compaction: Payload<RecordedCompactionFacts>?
        var usage: Payload<RecordedUsageFacts>?
        var communication: Payload<RecordedCommunicationFacts>?
        var toolObservation: Payload<RecordedToolObservationFacts>?
        var explanation: Payload<RecordedExplanationFacts>?
        var recordedAt: Date?
        var collectedAt: Date?
        var sourceIdentifiers: [String: String]?
    }
    // The reference never escapes this value. Every setter obtains a unique
    // storage first; independent Sendable copies may safely mutate concurrently.
    private final class Storage: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private var storage: Storage
    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(storage.value) }
    }
    public var compaction: RecordedCompactionFacts? {
        get { storage.value.compaction?.value }
        set {
            guard storage.value.compaction?.value != newValue else { return }
            makeUnique(); storage.value.compaction = newValue.map(Payload.init)
        }
    }
    public var usage: RecordedUsageFacts? {
        get { storage.value.usage?.value }
        set {
            guard storage.value.usage?.value != newValue else { return }
            makeUnique(); storage.value.usage = newValue.map(Payload.init)
        }
    }
    public var communication: RecordedCommunicationFacts? {
        get { storage.value.communication?.value }
        set {
            guard storage.value.communication?.value != newValue else { return }
            makeUnique(); storage.value.communication = newValue.map(Payload.init)
        }
    }
    public var toolObservation: RecordedToolObservationFacts? {
        get { storage.value.toolObservation?.value }
        set {
            guard storage.value.toolObservation?.value != newValue else { return }
            makeUnique(); storage.value.toolObservation = newValue.map(Payload.init)
        }
    }
    public var explanation: RecordedExplanationFacts? {
        get { storage.value.explanation?.value }
        set {
            guard storage.value.explanation?.value != newValue else { return }
            makeUnique(); storage.value.explanation = newValue.map(Payload.init)
        }
    }
    public var recordedAt: Date? {
        get { storage.value.recordedAt }
        set {
            guard storage.value.recordedAt != newValue else { return }
            makeUnique(); storage.value.recordedAt = newValue
        }
    }
    public var collectedAt: Date? {
        get { storage.value.collectedAt }
        set {
            guard storage.value.collectedAt != newValue else { return }
            makeUnique(); storage.value.collectedAt = newValue
        }
    }
    public var sourceIdentifiers: [String: String]? {
        get { storage.value.sourceIdentifiers }
        set {
            guard storage.value.sourceIdentifiers != newValue else { return }
            makeUnique(); storage.value.sourceIdentifiers = newValue
        }
    }
    public init(compaction: RecordedCompactionFacts? = nil, usage: RecordedUsageFacts? = nil, communication: RecordedCommunicationFacts? = nil, toolObservation: RecordedToolObservationFacts? = nil, explanation: RecordedExplanationFacts? = nil, recordedAt: Date? = nil, collectedAt: Date? = nil, sourceIdentifiers: [String: String]? = nil) {
        storage = Storage(Value(compaction: compaction.map(Payload.init), usage: usage.map(Payload.init),
            communication: communication.map(Payload.init), toolObservation: toolObservation.map(Payload.init),
            explanation: explanation.map(Payload.init), recordedAt: recordedAt, collectedAt: collectedAt, sourceIdentifiers: sourceIdentifiers))
    }
    public init(from decoder: Decoder) throws { storage = Storage(try Value(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage.value) }
    public static func decode(_ root: [String: Any], event: LensEvent) -> Self? {
        let compaction = RecordedCompactionFacts.decode(root, event: event)
        let usage = RecordedUsageFacts.decode(root, event: event)
        let communication = RecordedCommunicationFacts.decode(root, event: event)
        let observation = RecordedToolObservationFacts.decode(root, event: event)
        let explanation = RecordedExplanationFacts.decode(root, event: event)
        let payload = root["payload"] as? [String: Any] ?? root["params"] as? [String: Any] ?? root
        var identifiers: [String: String] = [:]
        let keys = ["id", "call_id", "callId", "thread_id", "threadId", "turn_id", "turnId", "session_id", "sessionId", "parent_thread_id", "parentThreadId", "response_id", "root_turn_id"]
        for (prefix, object) in [("payload", payload), ("payload.item", payload["item"] as? [String: Any] ?? [:])] {
            for key in keys { if let value = object[key] as? String, value.utf8.count <= 1024 { identifiers[prefix + "." + key] = value } }
        }
        guard compaction != nil || usage != nil || communication != nil || observation != nil || explanation != nil || !identifiers.isEmpty else { return nil }
        return Self(compaction: compaction, usage: usage, communication: communication, toolObservation: observation, explanation: explanation, recordedAt: event.timestamp == .distantPast ? nil : event.timestamp, collectedAt: Date(), sourceIdentifiers: identifiers.isEmpty ? nil : identifiers)
    }
}
