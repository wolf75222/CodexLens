import Foundation
import XCTest
@testable import LensCore

/// All observations below are invented metadata. No personal session or hook is exercised.
final class CommunicationInspectionTests: XCTestCase {
    private var syntheticEnvelope: String {
        var bytes = Data(repeating: 0, count: 73); bytes[0] = 0x80
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    private func opaqueCall(_ namespace: String = "agents", message: String? = nil) -> [String: Any] {
        ["type": "function_call", "name": "spawn_agent", "namespace": namespace, "call_id": "synthetic-opaque", "arguments": ["task_name": "worker", "message": message ?? syntheticEnvelope]]
    }
    func testNamespacedEncryptedMissionWithoutFlagIsOpaqueAndContainsNoPayloadInProjection() throws {
        let call = opaqueCall()
        let value = try XCTUnwrap(RecordedCommunicationFacts.decode(["type": "response_item", "payload": call], event: event("spawn")))
        XCTAssertTrue(value.isOpaque)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains(syntheticEnvelope))
        let model = CommunicationInspectionIndex(events: [try decoded(["type": "response_item", "payload": call], event: event("spawn"))], agents: agents)
        XCTAssertEqual(model.instructionByEventID["spawn"]?.kind, .unknown)
        XCTAssertTrue(model.instructionByEventID["spawn"]?.limitations.contains { $0.contains("opaque") } == true)
    }
    func testExplicitCollaborationPlaintextWinsOverEnvelopeShape() {
        var call = opaqueCall("collaboration"); call["encrypted_function_args"] = [String]()
        XCTAssertFalse(RecordedCommunicationFacts.hasOpaqueMessage(payload: call))
    }
    func testLegacyAndOrdinaryTextAreNotMaskedByCiphertextHeuristic() {
        var legacy = opaqueCall(); legacy.removeValue(forKey: "namespace")
        XCTAssertFalse(RecordedCommunicationFacts.hasOpaqueMessage(payload: legacy))
        XCTAssertFalse(RecordedCommunicationFacts.hasOpaqueMessage(payload: opaqueCall(message: "gAAAA is a literal prefix in my task.")))
        XCTAssertFalse(RecordedCommunicationFacts.hasOpaqueMessage(payload: opaqueCall(message: syntheticEnvelope + " explanatory text")))
    }
    func testInvalidEnvelopeVersionAndBlockLengthAreNotOpaque() {
        var bytes = Data(repeating: 0, count: 73)
        XCTAssertFalse(RecordedCommunicationFacts.hasOpaqueMessage(payload: opaqueCall(message: bytes.base64EncodedString())))
        bytes[0] = 0x80; bytes.append(0)
        XCTAssertFalse(RecordedCommunicationFacts.hasOpaqueMessage(payload: opaqueCall(message: bytes.base64EncodedString())))
    }
    private let parent = "11111111-1111-4111-8111-111111111111"
    private let child = "33333333-3333-4333-8333-333333333333"

    private func event(_ id: String, owner: String? = nil, line: Int = 1, kind: EventKind = .delegation,
                       facts: RecordedCommunicationFacts? = nil, related: String? = nil) -> LensEvent {
        LensEvent(id: id, timestamp: Date(timeIntervalSince1970: 1_000 + Double(line)), agentID: owner ?? parent,
            kind: kind, title: id, relatedEventID: related,
            source: SourceRef(path: "/fixture/" + (owner ?? parent) + ".jsonl", offset: UInt64(line * 100), length: 99, line: line),
            trace: facts.map { RecordedTraceFacts(communication: $0) })
    }
    private var agents: [AgentRecord] {
        [AgentRecord(id: parent, name: "/root", missionEventID: "root-instruction"),
         AgentRecord(id: child, parentID: parent, name: "/root/worker", relation: .subagent, missionEventID: "spawn")]
    }
    private func decoded(_ root: [String: Any], event value: LensEvent) throws -> LensEvent {
        var result = value
        result.trace = RecordedTraceFacts(communication: try XCTUnwrap(RecordedCommunicationFacts.decode(root, event: value)))
        return result
    }
    private func message(_ id: String = "amsg-one", opaque: Bool = false) -> [String: Any] {
        ["type": "response_item", "payload": ["type": "agent_message", "id": id,
            "author": "/root", "recipient": "/root/worker",
            "content": opaque ? [["type": "input_text", "text": "Visible header"], ["type": "encrypted_content", "encrypted_content": "synthetic-encrypted-payload"]] : [["type": "input_text", "text": "Inspect synthetic diff."]]]]
    }

    func testDurableInterAgentCommunicationPreservesEndpointsWithoutClaimingModelInclusion() throws {
        let root: [String: Any] = ["type": "inter_agent_communication", "payload": ["id": "legacy-message",
            "author": "/root", "recipient": "/root/worker", "other_recipients": [],
            "content": "Synthetic instruction", "trigger_turn": false]]
        let value = try decoded(root, event: event("received", owner: child))
        let facts = try XCTUnwrap(value.trace?.communication)
        XCTAssertEqual(facts.senderPath, "/root")
        XCTAssertEqual(facts.recipientPaths, ["/root/worker"])
        XCTAssertEqual(facts.stage, .recipientContextRecorded)
        XCTAssertEqual(facts.triggerTurn, false)
        let index = CommunicationInspectionIndex(events: [value], agents: agents)
        let communication = try XCTUnwrap(index.communications.first)
        XCTAssertEqual(communication.senderAgentID, parent)
        XCTAssertEqual(communication.recipientAgentIDs, [child])
        XCTAssertEqual(communication.recipientContextEventIDs, ["received"])
        XCTAssertTrue(communication.modelInclusionEventIDs.isEmpty)
        XCTAssertTrue(communication.limitations.contains { $0.contains("non confirmée") })
    }

    func testAgentMessageAuthorIsUsedAndOpaquePayloadIsNeverCopiedIntoFacts() throws {
        let value = try decoded(message(opaque: true), event: event("opaque", owner: child))
        let facts = try XCTUnwrap(value.trace?.communication)
        XCTAssertEqual(facts.messageID, "amsg-one")
        XCTAssertEqual(facts.senderPath, "/root")
        XCTAssertTrue(facts.isOpaque)
        let encoded = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-encrypted-payload"))
        XCTAssertFalse(encoded.contains("Inspect synthetic diff"))
        let communication = try XCTUnwrap(CommunicationInspectionIndex(events: [value], agents: agents).communications.first)
        XCTAssertTrue(communication.isOpaque)
        XCTAssertTrue(communication.limitations.contains { $0.contains("opaque") })
    }

    func testMetadataPairsOnlyTheImmediatelyFollowingPhysicalRecipientRecord() throws {
        let boundary = try decoded(["type": "inter_agent_communication_metadata", "payload": ["trigger_turn": true]], event: event("boundary", owner: child, line: 7))
        let value = try decoded(message(), event: event("received", owner: child, line: 8))
        let index = CommunicationInspectionIndex(events: [value, boundary], agents: agents)
        XCTAssertEqual(index.communications.count, 1)
        let communication = try XCTUnwrap(index.communicationByEventID["boundary"])
        XCTAssertEqual(communication.triggerTurn, true)
        XCTAssertEqual(communication.kind, .followup)
        XCTAssertEqual(Set(communication.eventIDs), ["boundary", "received"])
        XCTAssertEqual(communication.sourceRefs.count, 2)
        XCTAssertEqual(communication.recipientContextEventIDs, ["received"])
        XCTAssertTrue(communication.modelInclusionEventIDs.isEmpty)

        let distant = try decoded(message(), event: event("distant", owner: child, line: 10))
        let gap = CommunicationInspectionIndex(events: [boundary, distant], agents: agents)
        XCTAssertNil(gap.communicationByEventID["boundary"])
        XCTAssertNil(gap.communicationByEventID["distant"]?.triggerTurn)
        XCTAssertEqual(gap.unassociatedMetadataEventIDs, ["boundary"])
    }

    func testSendWithoutReceptionRemainsARequestDespiteARecordedToolResult() throws {
        let call = try decoded(["type": "response_item", "payload": ["type": "function_call", "name": "send_message",
            "call_id": "send-one", "arguments": "{\"target\":\"/root/worker\",\"message\":\"Read synthetic diff.\"}"]], event: event("sent", related: "result"))
        let result = event("result", line: 2, kind: .toolResult, related: "sent")
        let index = CommunicationInspectionIndex(events: [call, result], agents: agents)
        let communication = try XCTUnwrap(index.communications.first)
        XCTAssertEqual(communication.sentEventIDs, ["sent"])
        XCTAssertEqual(communication.toolResultEventIDs, ["result"])
        XCTAssertTrue(communication.submissionEventIDs.isEmpty)
        XCTAssertTrue(communication.recipientContextEventIDs.isEmpty)
        XCTAssertTrue(communication.modelInclusionEventIDs.isEmpty)
        XCTAssertEqual(communication.triggerTurn, false)
        XCTAssertEqual(communication.recipientAgentIDs, [child])
        XCTAssertEqual(index.communicationByEventID["result"]?.id, communication.id)
        XCTAssertTrue(communication.limitations.contains { $0.contains("Réception") })
    }

    func testErrorResultNeverConfirmsSubmissionEvenWithAnExplicitReceipt() throws {
        let call = try decoded(["type": "response_item", "payload": ["type": "function_call", "name": "send_input",
            "call_id": "send-failed", "arguments": ["target": child, "message": "Synthetic question"]]], event: event("sent", related: "failed-result"))
        var result = try decoded(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "send-failed", "output": "{\"submission_id\":\"invented-receipt\"}"]], event: event("failed-result", line: 2, kind: .toolResult, related: "sent"))
        result.isError = true
        result.trace?.communication?.submissionAccepted = true
        let communication = try XCTUnwrap(CommunicationInspectionIndex(events: [call, result], agents: agents).communications.first)
        XCTAssertEqual(communication.toolResultEventIDs, ["failed-result"])
        XCTAssertTrue(communication.submissionEventIDs.isEmpty)
        XCTAssertTrue(communication.recipientContextEventIDs.isEmpty)
        XCTAssertTrue(communication.limitations.contains { $0.contains("en erreur") })
    }

    func testNativeSendInputReceiptResolvesBeforeToolNameWasAvailableToDecoder() throws {
        let call = try decoded(["type": "response_item", "payload": ["type": "function_call", "name": "send_input",
            "call_id": "send-accepted", "arguments": ["target": child, "message": "Synthetic question"]]], event: event("sent", related: "accepted-result"))
        let result = try decoded(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "send-accepted", "output": "{\"submission_id\":\"recorded-native-receipt\"}"]], event: event("accepted-result", line: 2, kind: .toolResult, related: "sent"))
        XCTAssertNil(result.trace?.communication?.toolName)
        let communication = try XCTUnwrap(CommunicationInspectionIndex(events: [call, result], agents: agents).communications.first)
        XCTAssertEqual(communication.toolResultEventIDs, ["accepted-result"])
        XCTAssertEqual(communication.submissionEventIDs, ["accepted-result"])
        XCTAssertTrue(communication.recipientContextEventIDs.isEmpty)
        XCTAssertTrue(communication.modelInclusionEventIDs.isEmpty)
    }

    func testHookParentSessionNeverBecomesChildThreadOrSender() throws {
        let capture: [String: Any] = ["type": "hook_observation", "payload": ["hook_event_name": "SubagentStop", "session_id": parent, "agent_id": child]]
        let value = try decoded(capture, event: event("hook", owner: parent))
        let facts = try XCTUnwrap(value.trace?.communication)
        XCTAssertEqual(facts.parentSessionID, parent)
        XCTAssertEqual(facts.affectedAgentID, child)
        let communication = try XCTUnwrap(CommunicationInspectionIndex(events: [value], agents: agents).communications.first)
        XCTAssertNil(communication.senderAgentID)
        XCTAssertEqual(communication.recipientAgentIDs, [child])
        XCTAssertEqual(communication.parentSessionIDs, [parent])

        let incomplete = try decoded(["type": "hook_observation", "payload": ["hook_event_name": "SubagentStop", "session_id": parent]], event: event("unknown-hook"))
        let unknown = try XCTUnwrap(CommunicationInspectionIndex(events: [incomplete], agents: agents).communications.first)
        XCTAssertTrue(unknown.recipientAgentIDs.isEmpty)
        XCTAssertNil(unknown.senderAgentID)
    }

    func testDuplicatedProtocolMessageKeepsSourcesAndOneSequenceEntry() throws {
        let one = try decoded(message(), event: event("one", owner: child, line: 1))
        let two = try decoded(message(), event: event("two", owner: child, line: 2))
        let index = CommunicationInspectionIndex(events: [one, two, one], agents: agents)
        XCTAssertEqual(index.communications.count, 1)
        let communication = try XCTUnwrap(index.communications.first)
        XCTAssertEqual(Set(communication.eventIDs), ["one", "two"])
        XCTAssertEqual(communication.sourceRefs.count, 2)
        XCTAssertEqual(communication.recipientContextEventIDs.count, 2)
        XCTAssertTrue(communication.modelInclusionEventIDs.isEmpty)
        XCTAssertEqual(CommunicationInspectionIndex(events: [one, two], agents: agents).communications.first?.id, communication.id)
    }

    func testOtherRecipientsDoNotInheritTheObservedOwnersReceipt() throws {
        let sibling = "44444444-4444-4444-8444-444444444444"
        let participants = agents + [AgentRecord(id: sibling, parentID: parent, name: "/root/sibling", relation: .subagent)]
        let legacy: [String: Any] = ["type": "inter_agent_communication", "payload": ["id": "broadcast",
            "author": "/root", "recipient": "/root/worker", "other_recipients": ["/root/sibling"],
            "content": "Synthetic broadcast", "trigger_turn": false]]
        let one = try decoded(legacy, event: event("legacy", owner: child, line: 1))
        let modern = try decoded(message("broadcast"), event: event("modern", owner: child, line: 2))
        let index = CommunicationInspectionIndex(events: [one, modern], agents: participants)
        XCTAssertEqual(index.communications.count, 1)
        let communication = try XCTUnwrap(index.communications.first)
        XCTAssertEqual(Set(communication.recipientAgentIDs), [child, sibling])
        XCTAssertEqual(communication.recipientContextEventIDsByAgent[child], ["legacy", "modern"])
        XCTAssertNil(communication.recipientContextEventIDsByAgent[sibling])
        XCTAssertTrue(communication.modelInclusionEventIDsByAgent.isEmpty)
    }

    func testSameProtocolIDInDifferentAgentHistoriesDoesNotMerge() throws {
        let one = try decoded(message(), event: event("one", owner: child))
        let two = try decoded(message(), event: event("two", owner: parent))
        let index = CommunicationInspectionIndex(events: [one, two], agents: agents)
        XCTAssertEqual(index.communications.count, 2)
        XCTAssertNotEqual(index.communicationByEventID["one"]?.id, index.communicationByEventID["two"]?.id)
        XCTAssertTrue(index.communicationByEventID["two"]?.limitations.contains { $0.contains("contradictoire") } == true)
    }

    func testInstructionOriginsAreExplicitAndASecondPromptIsNotAutomaticallyACorrection() throws {
        let direct = try decoded(["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "Synthetic direct instruction"]]]], event: event("direct", owner: child, kind: .instruction))
        let inherited = event("inherited", owner: child, line: 2, kind: .instruction,
            facts: RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded, affectedAgentID: child,
                instructionKind: .inherited, inheritedFromThreadID: parent))
        let unknown = event("unknown", owner: child, line: 3, kind: .instruction,
            facts: RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded, instructionKind: .unknown))
        let next = try decoded(["type": "response_item", "payload": ["type": "message", "role": "user", "content": []]], event: event("later-prompt", owner: child, line: 4, kind: .user))
        let index = CommunicationInspectionIndex(events: [direct, inherited, unknown, next], agents: agents)
        XCTAssertTrue(index.communications.isEmpty)
        XCTAssertEqual(index.instructionByEventID["direct"]?.kind, .direct)
        XCTAssertEqual(index.instructionByEventID["inherited"]?.kind, .inherited)
        XCTAssertEqual(index.instructionByEventID["inherited"]?.inheritedFromThreadID, parent)
        XCTAssertEqual(index.instructionByEventID["unknown"]?.kind, .unknown)
        XCTAssertEqual(index.instructionByEventID["later-prompt"]?.kind, .direct)
        XCTAssertEqual(index.instructionByEventID["direct"]?.parentAgentID, parent)
        XCTAssertEqual(index.instructionByEventID["direct"]?.missionEventID, "spawn")
    }

    func testNativeActivitiesResolveHiddenSpawnMetadataAndKeepMissionOrigin() throws {
        let spawn = try decoded(["type": "response_item", "payload": ["type": "function_call", "call_id": "call-spawn", "name": "spawn_agent", "arguments": ["task_name": "worker", "message": "Synthetic task"]]], event: event("spawn"))
        let activity = try decoded(["type": "event_msg", "payload": ["type": "sub_agent_activity", "event_id": "call-spawn", "agent_thread_id": child, "agent_path": "/root/worker", "kind": "started"]], event: event("activity", line: 2))
        let index = CommunicationInspectionIndex(events: [spawn, activity], agents: agents)
        XCTAssertEqual(index.communications.count, 1)
        let communication = try XCTUnwrap(index.communications.first)
        XCTAssertEqual(communication.recipientAgentIDs, [child])
        XCTAssertTrue(communication.missionEventIDs.contains("spawn"))
        XCTAssertTrue(communication.parentAgentIDs.contains(parent))
        XCTAssertEqual(communication.originEventIDs, ["spawn"])
        XCTAssertTrue(communication.recipientContextEventIDs.isEmpty)
        XCTAssertEqual(index.instructionByEventID["spawn"]?.agentID, child)
    }

    func testSpawnUsesConfirmedMissionEventIdentityWithoutResolvingAShortTaskName() throws {
        let spawn = try decoded(["type": "response_item", "payload": ["type": "function_call", "call_id": "short-task", "name": "spawn_agent", "arguments": ["task_name": "worker", "message": "Same mission text"]]], event: event("spawn"))
        let unrelated = "44444444-4444-4444-8444-444444444444"
        let participants = [AgentRecord(id: parent, name: "Session principale"),
            AgentRecord(id: child, parentID: parent, name: "/root/confirmed-worker", relation: .subagent, mission: "Same mission text", missionEventID: "spawn"),
            AgentRecord(id: unrelated, parentID: parent, name: "/root/worker", relation: .subagent, mission: "Same mission text", missionEventID: "another-spawn")]
        let index = CommunicationInspectionIndex(events: [spawn], agents: participants)
        let communication = try XCTUnwrap(index.communications.first)
        XCTAssertEqual(communication.senderAgentID, parent, "The source owner is explicit for the recorded outgoing call")
        XCTAssertEqual(communication.recipientAgentIDs, [child])
        XCTAssertFalse(communication.recipientAgentIDs.contains(unrelated), "Matching task-name suffixes or mission text cannot establish identity")
        XCTAssertEqual(communication.recipientPaths, ["worker"], "Preserve the actual requested path separately from the confirmed child ID")
        XCTAssertTrue(communication.missionEventIDs.contains("spawn"))
        XCTAssertTrue(communication.parentAgentIDs.contains(parent))
        XCTAssertTrue(communication.recipientContextEventIDs.isEmpty)
    }

    func testRootAuthorPathStaysUnknownWithoutAnExplicitRecordedIdentity() throws {
        let value = try decoded(message(), event: event("received", owner: child))
        let participants = [AgentRecord(id: parent, name: "Session principale"),
            AgentRecord(id: child, parentID: parent, name: "/root/worker", relation: .subagent)]
        let communication = try XCTUnwrap(CommunicationInspectionIndex(events: [value], agents: participants).communications.first)
        XCTAssertEqual(communication.senderPath, "/root")
        XCTAssertNil(communication.senderAgentID, "An unresolved /root path must not be guessed from the agent tree")
        XCTAssertEqual(communication.recipientAgentIDs, [child])
        XCTAssertEqual(communication.recipientContextEventIDs, ["received"])
        XCTAssertTrue(communication.sentEventIDs.isEmpty)
        XCTAssertTrue(communication.modelInclusionEventIDs.isEmpty)
    }

    func testOnlyAnExplicitEvidenceStageCanConfirmRequestInclusion() throws {
        let value = try decoded(message(), event: event("received", owner: child))
        XCTAssertTrue(CommunicationInspectionIndex(events: [value], agents: agents).communications[0].modelInclusionEventIDs.isEmpty)
        let inclusion = event("dedicated-request-snapshot", owner: child,
            facts: RecordedCommunicationFacts(kind: .message, stage: .requestInclusionConfirmed, messageID: "amsg-one",
                senderPath: "/root", recipientPaths: ["/root/worker"]))
        let index = CommunicationInspectionIndex(events: [value, inclusion], agents: agents)
        XCTAssertEqual(index.communications.count, 1)
        XCTAssertEqual(index.communications[0].modelInclusionEventIDs, ["dedicated-request-snapshot"])
        XCTAssertEqual(index.communications[0].recipientContextEventIDs, ["received"])
    }

    func testGeneralCoverageReportsTransientHooksWithoutClaimingTheyDidNotRun() {
        let index = CommunicationInspectionIndex(events: [], agents: [])
        XCTAssertTrue(index.collectionLimitations.contains { $0.contains("hooks") && $0.contains("absence d’opération") })
        XCTAssertTrue(index.communications.isEmpty)
    }
}
