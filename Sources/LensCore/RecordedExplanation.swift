import Foundation

/// What the provider or agent actually exposed. None of these kinds denotes an exhaustive
/// transcript of private model reasoning, or proof that a particular action followed it.
public enum RecordedExplanationKind: String, Codable, Sendable {
    case reasoningSummary, exposedReasoning, agentMessage, plan
}
public enum RecordedExplanationAvailability: String, Codable, Sendable {
    case available, empty, opaque, unavailable
}
public enum RecordedExplanationTimestampBasis: String, Codable, Sendable {
    case sourceRecordGenerationUnknown, notificationReceivedGenerationUnknown, unavailable
}

/// A bounded, redacted index of original explanatory text. Its full, progressively loaded
/// source remains the event's SourceRef; ciphertext is never copied into this model.
/// Version 0.159.2 carries no explicit explanation-to-action identifier: neighbouring text
/// and references written in prose must remain contextual associations, not causal links.
public struct RecordedExplanationFacts: Codable, Hashable, Sendable {
    public var kind: RecordedExplanationKind
    public var availability: RecordedExplanationAvailability
    public var threadID: String
    public var turnID: String?
    public var itemID: String?
    public var preview: String
    public var previewTruncated: Bool
    public var encryptedContentPresent: Bool
    public var summaryAvailability: RecordedExplanationAvailability?
    public var exposedReasoningAvailability: RecordedExplanationAvailability?
    public var exposedReasoningPreview: String?
    public var timestampBasis: RecordedExplanationTimestampBasis
    public var phase: String
    public var explicitRelatedItemIDs: [String]
    /// An update_plan explanation is explicitly scoped to that requested plan update,
    /// never to the patch or command mentioned by its prose.
    public var declaredForCallID: String?
    public var limits: [String]

    public init(kind: RecordedExplanationKind, availability: RecordedExplanationAvailability,
                threadID: String, turnID: String? = nil, itemID: String? = nil, preview: String = "",
                previewTruncated: Bool = false, encryptedContentPresent: Bool = false,
                summaryAvailability: RecordedExplanationAvailability? = nil,
                exposedReasoningAvailability: RecordedExplanationAvailability? = nil,
                exposedReasoningPreview: String? = nil,
                timestampBasis: RecordedExplanationTimestampBasis = .sourceRecordGenerationUnknown,
                phase: String = "recorded", explicitRelatedItemIDs: [String] = [], declaredForCallID: String? = nil, limits: [String] = []) {
        self.kind = kind; self.availability = availability; self.threadID = threadID; self.turnID = turnID
        self.itemID = itemID; self.preview = preview; self.previewTruncated = previewTruncated
        self.encryptedContentPresent = encryptedContentPresent; self.summaryAvailability = summaryAvailability
        self.exposedReasoningAvailability = exposedReasoningAvailability; self.exposedReasoningPreview = exposedReasoningPreview
        self.timestampBasis = timestampBasis; self.phase = phase; self.explicitRelatedItemIDs = explicitRelatedItemIDs
        self.declaredForCallID = declaredForCallID; self.limits = limits
    }

    public static func decode(_ root: [String: Any], event: LensEvent) -> Self? {
        let payload = root["payload"] as? [String: Any] ?? root["params"] as? [String: Any] ?? root
        let rootType = normalized(root["type"] as? String ?? root["method"] as? String)
        let payloadType = normalized(payload["type"] as? String)
        let item = payload["item"] as? [String: Any]
        let itemType = normalized(item?["type"] as? String)
        let thread = string(payload, "thread_id", "threadId") ?? event.agentID
        let turn = string(payload, "turn_id", "turnId") ?? event.turnID
        let basis: RecordedExplanationTimestampBasis = event.timestamp == .distantPast ? .unavailable
            : root["method"] != nil ? .notificationReceivedGenerationUnknown : .sourceRecordGenerationUnknown
        let phase = (payloadType == "itemstarted" || rootType == "item/started") ? "started"
            : (payloadType == "itemcompleted" || rootType == "item/completed") ? "completed" : "recorded"
        let nativeItem = item != nil && ["itemstarted", "itemcompleted"].contains(payloadType)
            || item != nil && ["item/started", "item/completed"].contains(rootType)

        if rootType == "responseitem", payloadType == "reasoning" {
            return reasoning(payload, native: false, thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if nativeItem, itemType == "reasoning", let item {
            return reasoning(item, native: true, thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if rootType == "eventmsg", ["agentreasoning", "agentreasoningrawcontent"].contains(payloadType) {
            let raw = payloadType == "agentreasoningrawcontent"
            return plain(kind: raw ? .exposedReasoning : .reasoningSummary, object: payload,
                         fields: ["text"], thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if nativeItem, itemType == "agentmessage", let item {
            if item["content"] != nil {
                return message(item, native: true, thread: thread, turn: turn, basis: basis, phase: phase)
            }
            return plain(kind: .agentMessage, object: item, fields: ["text"], thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if rootType == "eventmsg", payloadType == "agentmessage" {
            return plain(kind: .agentMessage, object: payload, fields: ["message"], thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if rootType == "responseitem", payloadType == "message", payload["role"] as? String == "assistant" {
            return message(payload, thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if rootType == "responseitem", payloadType == "agentmessage" {
            return message(payload, thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if nativeItem, itemType == "plan", let item {
            return plain(kind: .plan, object: item, fields: ["text"], thread: thread, turn: turn, basis: basis, phase: phase)
        }
        if (rootType == "eventmsg" && payloadType == "planupdate") || rootType == "thread/plan/updated" {
            return plan(payload, thread: thread, turn: turn, itemID: string(payload, "item_id", "itemId"), basis: basis, phase: phase)
        }
        if rootType == "responseitem", payloadType == "functioncall", isUpdatePlan(payload["name"] as? String) {
            // Parse only an exact literal JSON argument object; never evaluate orchestration code.
            let args: [String: Any]
            if let value = payload["arguments"] as? [String: Any] { args = value }
            else if let value = payload["arguments"] as? String, let bytes = value.data(using: .utf8),
                    let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { args = value }
            else { args = [:] }
            var facts = plan(args, thread: thread, turn: turn, itemID: string(payload, "id", "call_id"), basis: basis, phase: "requested")
            if let explanation = args["explanation"] as? String, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                facts.declaredForCallID = string(payload, "call_id")
            }
            return facts
        }
        return nil
    }

    private static func reasoning(_ object: [String: Any], native: Bool, thread: String, turn: String?,
                                  basis: RecordedExplanationTimestampBasis, phase: String) -> Self {
        // Durable TurnItem::Reasoning uses summary_text/raw_content; its app-server
        // projection ThreadItem::Reasoning uses summary/content. These are distinct
        // verified representations of the same fields, not a guessed newer schema.
        let summaryKey = native && object["summary_text"] != nil ? "summary_text" : "summary"
        let exposedKey = native && object["raw_content"] != nil ? "raw_content" : "content"
        let summary = texts(object[summaryKey], native: native, permittedTypes: ["summary_text"])
        let exposed = texts(object[exposedKey], native: native, permittedTypes: ["reasoning_text", "text"])
        let opaque = encrypted(object)
        let summaryState = availability(summary, fieldPresent: object[summaryKey] != nil && !(object[summaryKey] is NSNull))
        let exposedState = availability(exposed, fieldPresent: object[exposedKey] != nil && !(object[exposedKey] is NSNull))
        let isSummary = summaryState == .available || exposedState != .available
        let selected = isSummary ? summary : exposed
        let selectedState = isSummary ? summaryState : exposedState
        let bounded = boundedPreview(selected)
        var limits = commonLimits(basis)
        limits.append("Recorded summaries and exposed reasoning are not an exhaustive transcript of private thought.")
        if opaque { limits.append("Encrypted reasoning is opaque; no readable explanation is reconstructed from it.") }
        if bounded.truncated { limits.append("Only a bounded preview is indexed; load the original recorded source for the remaining text.") }
        return Self(kind: isSummary ? .reasoningSummary : .exposedReasoning,
                    availability: selectedState == .available ? .available : opaque ? .opaque : selectedState,
                    threadID: thread, turnID: turn, itemID: string(object, "id"), preview: bounded.text,
                    previewTruncated: bounded.truncated, encryptedContentPresent: opaque,
                    summaryAvailability: summaryState, exposedReasoningAvailability: exposedState,
                    exposedReasoningPreview: exposedState == .available ? boundedPreview(exposed).text : nil,
                    timestampBasis: basis, phase: phase, limits: limits)
    }
    private static func message(_ object: [String: Any], native: Bool = false, thread: String, turn: String?,
                                basis: RecordedExplanationTimestampBasis, phase: String) -> Self {
        let parts = texts(object["content"], native: false, permittedTypes: native ? ["Text", "text"] : ["input_text", "output_text", "text"])
        let bounded = boundedPreview(parts), opaque = encrypted(object)
        let state = availability(parts, fieldPresent: object["content"] != nil)
        var limits = commonLimits(basis)
        if opaque { limits.append("Part of this agent message is opaque; only exposed text is indexed.") }
        if bounded.truncated { limits.append("Only a bounded preview is indexed; the remaining text stays in the recorded source.") }
        return Self(kind: .agentMessage, availability: state == .available ? .available : opaque ? .opaque : state,
                    threadID: thread, turnID: turn, itemID: string(object, "id"), preview: bounded.text,
                    previewTruncated: bounded.truncated, encryptedContentPresent: opaque, timestampBasis: basis, phase: phase, limits: limits)
    }
    private static func plain(kind: RecordedExplanationKind, object: [String: Any], fields: [String],
                              thread: String, turn: String?, basis: RecordedExplanationTimestampBasis, phase: String) -> Self {
        let value = fields.compactMap { object[$0] as? String }
        let bounded = boundedPreview(value)
        var limits = commonLimits(basis)
        if kind == .reasoningSummary || kind == .exposedReasoning {
            limits.append("Recorded summaries and exposed reasoning are not an exhaustive transcript of private thought.")
        }
        if bounded.truncated { limits.append("Only a bounded preview is indexed; load the original recorded source for the remaining text.") }
        return Self(kind: kind, availability: availability(value, fieldPresent: fields.contains { object[$0] != nil }),
                    threadID: thread, turnID: turn, itemID: string(object, "id", "item_id", "itemId"), preview: bounded.text,
                    previewTruncated: bounded.truncated, timestampBasis: basis, phase: phase, limits: limits)
    }
    private static func plan(_ object: [String: Any], thread: String, turn: String?, itemID: String?,
                             basis: RecordedExplanationTimestampBasis, phase: String) -> Self {
        var originalText = (object["explanation"] as? String).map { [$0] } ?? []
        if let steps = object["plan"] as? [[String: Any]] { originalText += steps.compactMap { $0["step"] as? String } }
        let bounded = boundedPreview(originalText)
        var limits = commonLimits(basis)
        limits.append("A plan is a recorded proposal or declaration, not proof that its steps were executed.")
        if bounded.truncated { limits.append("Only a bounded preview is indexed; structured steps remain in the recorded source.") }
        return Self(kind: .plan, availability: availability(originalText, fieldPresent: object["explanation"] != nil || object["plan"] != nil),
                    threadID: thread, turnID: turn, itemID: itemID, preview: bounded.text, previewTruncated: bounded.truncated,
                    timestampBasis: basis, phase: phase, limits: limits)
    }
    private static func commonLimits(_ basis: RecordedExplanationTimestampBasis) -> [String] {
        var values = ["No explicit explanation-to-action relation is present in the verified 0.159.2 schema; prose references do not establish one."]
        if basis != .unavailable { values.append("This is the source record or notification receipt time; generation and decision times are unknown.") }
        else { values.append("No source timestamp is available; generation and decision times are unknown.") }
        return values
    }
    private static func availability(_ values: [String], fieldPresent: Bool) -> RecordedExplanationAvailability {
        values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? .available : fieldPresent ? .empty : .unavailable
    }
    private static func texts(_ value: Any?, native: Bool, permittedTypes: Set<String>) -> [String] {
        if native, let values = value as? [String] { return values }
        if let values = value as? [[String: Any]] {
            return values.compactMap { part in
                guard let type = part["type"] as? String, permittedTypes.contains(type) else { return nil }
                return part["text"] as? String
            }
        }
        return []
    }
    private static func encrypted(_ object: [String: Any]) -> Bool {
        if let value = object["encrypted_content"] as? String, !value.isEmpty { return true }
        return (object["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "encrypted_content" } == true
    }
    private static func boundedPreview(_ values: [String]) -> (text: String, truncated: Bool) {
        let maximum = 1200
        var text = "", truncated = false
        for (position, value) in values.enumerated() {
            guard text.count < maximum else { truncated = true; break }
            if position > 0 && !text.isEmpty { text.append("\n") }
            let remaining = maximum - text.count
            guard remaining > 0 else { truncated = true; break }
            let prefix = String(value.prefix(remaining + 1))
            if prefix.count > remaining { truncated = true }
            text.append(contentsOf: prefix.prefix(remaining))
            if truncated { break }
        }
        // Apply the same secret families as the event preview, only to bounded text.
        for (pattern, replacement) in secretPatterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        if text.count > maximum { text = String(text.prefix(maximum)); truncated = true }
        return (text, truncated)
    }
    private static let secretPatterns: [(NSRegularExpression, String)] = [
        (#"(?i)(\"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|client_secret|creator_user_id|creator_account_id)\"\s*:\s*\")[^\"]*(\")"#, "$1[secret masked]$2"),
        (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/-]{12,}"#, "$1[secret masked]"),
        (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[secret masked]")
    ].compactMap { pattern, replacement in (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) } }
    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        keys.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }
    private static func normalized(_ text: String?) -> String { (text ?? "").lowercased().replacingOccurrences(of: "_", with: "") }
    private static func isUpdatePlan(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == "update_plan" || name.hasSuffix(".update_plan") || name.hasSuffix("__update_plan")
    }
}
