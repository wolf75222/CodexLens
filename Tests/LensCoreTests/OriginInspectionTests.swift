import XCTest
@testable import LensCore

final class OriginInspectionTests: XCTestCase {
    private func event(_ id: String, agent: String = "root", turn: String? = "r", kind: EventKind = .toolCall, offset: UInt64 = 0, call: String? = nil, related: String? = nil, facts: RecordedExplanationFacts? = nil) -> LensEvent {
        LensEvent(id: id, timestamp: Date(timeIntervalSince1970: Double(offset)), agentID: agent, turnID: turn, kind: kind, title: id, callID: call, environmentID: "/beta", relatedEventID: related,
            source: SourceRef(path: "/fixtures/\(agent).jsonl", offset: offset, length: 100, line: Int(offset) + 1), trace: facts.map { RecordedTraceFacts(explanation: $0) })
    }
    private func index(_ snapshot: SessionSnapshot) -> OriginInspectionIndex {
        OriginInspectionIndex(snapshot: snapshot, communication: CommunicationInspectionIndex(events: snapshot.events, agents: snapshot.agents),
            activity: ActivityEvidenceIndex(events: snapshot.events, changes: snapshot.changes, resources: snapshot.resources))
    }
    private func chain() -> SessionSnapshot {
        let reasoning = RecordedExplanationFacts(kind: .reasoningSummary, availability: .available, threadID: "grand", turnID: "g", preview: "Une explication exposée, pas une cause démontrée")
        let nodes = [event("p1", kind: .user), event("p2", kind: .user), event("s1", call: "spawn1"),
            event("s2", agent: "child", turn: "c", call: "spawn2"),
            event("summary", agent: "grand", turn: "g", kind: .context, offset: 20, facts: reasoning),
            event("patch", agent: "grand", turn: "g", offset: 30, call: "patch-call", related: "result"),
            event("result", agent: "grand", turn: "g", kind: .toolResult, offset: 31, call: "patch-call", related: "patch")]
        return SessionSnapshot(root: SessionSummary(id: "root"), agents: [AgentRecord(id: "root"),
            AgentRecord(id: "child", parentID: "root", relation: .subagent, missionEventID: "s1"),
            AgentRecord(id: "grand", parentID: "child", relation: .subagent, missionEventID: "s2")], events: nodes,
            changes: [ChangeRecord(id: "change", path: "/beta/src/A.swift", environmentID: "/beta", agentID: "grand", eventID: "patch", kind: .requestedPatch)], collectedAt: Date(timeIntervalSince1970: 100))
    }
    func testThreeGenerationsAndBothDirectionsWithMultipleContextPrompts() throws {
        let model = index(chain()), selected = try XCTUnwrap(model.selection(objectID: OriginInspectionIndex.changeID("change")))
        XCTAssertEqual(selected.missionEventIDs, ["s2", "s1"])
        XCTAssertEqual(Set(selected.instructionEventIDs), ["p1", "p2"])
        XCTAssertFalse(model.associatedEventIDsByInstruction["p1"]?.contains("patch") == true)
        XCTAssertEqual(model.selection(objectID: OriginInspectionIndex.eventID("p1"))?.missionTargetAgentIDs, ["child"])
        XCTAssertEqual(model.selection(objectID: OriginInspectionIndex.eventID("s2"))?.missionTargetAgentIDs, ["grand"])
        XCTAssertFalse(model.associatedEventIDsByInstruction["p2"]?.contains("result") == true)
        XCTAssertEqual(model.associatedChangeIDsByInstruction["p1"], [])
        XCTAssertTrue(selected.links.contains { $0.relation.contains("Appel et résultat") && $0.nature == .explicit })
        XCTAssertTrue(selected.links.filter { $0.from == OriginInspectionIndex.eventID("p1") }.allSatisfy { $0.nature == .associatedContext })
    }
    func testDuplicateCallResultLinkKeepsFirstSourcesAndStableNavigationID() throws {
        let snapshot = chain(), model = index(snapshot)
        let from = OriginInspectionIndex.eventID("patch"), to = OriginInspectionIndex.eventID("result")
        let links = model.links.filter { $0.from == from && $0.to == to && $0.nature == .explicit }
        XCTAssertEqual(links.count, 1)
        let link = try XCTUnwrap(links.first)
        XCTAssertEqual(link.id, from + "\u{1f}" + to + "\u{1f}" + link.relation)
        XCTAssertEqual(link.sources, [snapshot.events[5].source, snapshot.events[6].source])
        XCTAssertEqual(try JSONDecoder().decode(OriginLink.self, from: JSONEncoder().encode(link)), link)
    }

    func testOpaqueMissionRetainsParentLinkWithoutClaimingReadableInstructions() throws {
        var snapshot = chain()
        let i = try XCTUnwrap(snapshot.events.firstIndex { $0.id == "s2" })
        snapshot.events[i].trace = RecordedTraceFacts(communication: RecordedCommunicationFacts(kind: .spawn, stage: .sendRequested, isOpaque: true))
        let selection = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.changeID("change")))
        XCTAssertTrue(selection.missionEventIDs.contains("s2"))
        XCTAssertEqual(selection.objects.first { $0.id == OriginInspectionIndex.eventID("s2") }?.availability, "opaque")
        let text = try OriginEvidence.piece(selection: selection, collectionCut: snapshot.collectedAt).text
        let start = try XCTUnwrap(text.firstIndex(of: "{"))
        let decoded = try OriginEvidence.decode(Data(text[start...].utf8))
        XCTAssertEqual(decoded, selection)
    }
    func testNearbyReasoningDifferentTurnIsNotJustificationAndLateTextIsNotDecisionTime() throws {
        var snapshot = chain()
        let facts = RecordedExplanationFacts(kind: .reasoningSummary, availability: .available, threadID: "grand", turnID: "other", preview: "Le voisin temporel")
        snapshot.events.append(event("nearby", agent: "grand", turn: "other", kind: .context, offset: 29, facts: facts))
        snapshot.events.append(event("late", agent: "grand", turn: "g", kind: .assistant, offset: 70, facts: RecordedExplanationFacts(kind: .agentMessage, availability: .available, threadID: "grand", turnID: "g", preview: "Déclaration ultérieure")))
        let selected = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.changeID("change")))
        XCTAssertFalse(selected.explanations.contains { $0.eventID == "nearby" })
        XCTAssertEqual(selected.explanations.first { $0.eventID == "late" }?.ordering, "Déclaration enregistrée après l’action dans ce journal")
        XCTAssertTrue(selected.explanations.allSatisfy { $0.relation == .associatedContext })
    }
    func testForkAndInheritedHistoryAreNotNewExecutionsOrDelegations() throws {
        var snapshot = chain()
        snapshot.agents.append(AgentRecord(id: "fork", parentID: "root", relation: .fork))
        var inherited = event("copied", agent: "grand", turn: "g", kind: .instruction)
        inherited.trace = RecordedTraceFacts(communication: RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded, affectedAgentID: "grand", instructionKind: .inherited, inheritedFromThreadID: "child"))
        snapshot.events += [inherited, event("fork-action", agent: "fork")]
        let model = index(snapshot)
        XCTAssertFalse(model.associatedEventIDsByInstruction["p1"]?.contains("copied") == true)
        XCTAssertFalse(model.associatedEventIDsByInstruction["p1"]?.contains("fork-action") == true)
        let fork = try XCTUnwrap(model.selection(objectID: OriginInspectionIndex.agentID("fork")))
        XCTAssertTrue(fork.missionEventIDs.isEmpty)
        XCTAssertTrue(fork.missing.contains { $0.contains("forké") })
    }
    func testFileContributionsKeepWorktreesSeparateAndMultipleAgents() throws {
        var snapshot = chain()
        snapshot.changes += [ChangeRecord(id: "second", path: "/beta/src/A.swift", environmentID: "/beta", agentID: "child", eventID: "s2", kind: .recordedResult),
            ChangeRecord(id: "alpha", path: "/alpha/src/A.swift", environmentID: "/alpha", agentID: "root", eventID: "s1", kind: .recordedResult)]
        let model = index(snapshot), selected = try XCTUnwrap(model.selection(objectID: OriginInspectionIndex.changeID("change")))
        XCTAssertEqual(Set(selected.contributionChangeIDs), ["change", "second"])
        XCTAssertEqual(model.changeIDs(environment: "/alpha", path: "src/A.swift"), ["alpha"])
    }
    private func snapshotWithFollowingChanges(_ count: Int) -> SessionSnapshot {
        var snapshot = chain()
        var test = event("test", kind: .toolResult, offset: 1, call: "test-call")
        test.trace = RecordedTraceFacts(toolObservation: RecordedToolObservationFacts(toolName: "exec_command", callID: "test-call", environmentID: "/beta",
            command: "swift test", explicitTestCommand: "swift test", exitCode: 0, status: "completed", executionEvidence: [.completedItem], recordedEndTime: test.timestamp))
        snapshot.events.append(test)
        for i in 0..<count {
            let id = "following-\(i)"
            snapshot.events.append(event(id, kind: .toolResult, offset: UInt64(100 + i)))
            snapshot.changes.append(ChangeRecord(id: id, path: "/beta/src/A.swift", environmentID: "/beta", agentID: "root", eventID: id, kind: .recordedResult))
        }
        return snapshot
    }
    func testOriginBoundsRepeatedTestReferencesWithoutDroppingActivityHistory() throws {
        let snapshot = snapshotWithFollowingChanges(1000)
        let activity = ActivityEvidenceIndex(events: snapshot.events, changes: snapshot.changes, resources: snapshot.resources)
        XCTAssertEqual(activity.tests.first?.subsequentChangeIDs.count, 1000)
        let selected = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.eventID("patch")))
        let verification = try XCTUnwrap(selected.verifications.first)
        XCTAssertEqual(verification.subsequentChangeIDs.count, 32)
        XCTAssertEqual(verification.omittedSubsequentChangeCount, 968)
        XCTAssertEqual(verification.changeScope, "Périmètre : cet environnement")
        XCTAssertTrue(selected.missing.contains { $0.contains("observations complètes") })
        XCTAssertLessThan(try JSONEncoder().encode(selected).count, 64 * 1024)
    }
    func testTestFollowingChangesUseSelectedFileAndEnvironmentWithoutClaimingCoverage() throws {
        var snapshot = snapshotWithFollowingChanges(2)
        snapshot.events += [event("other-file", kind: .toolResult, offset: 200), event("other-worktree", kind: .toolResult, offset: 201)]
        snapshot.changes += [ChangeRecord(id: "other-file", path: "/beta/src/B.swift", environmentID: "/beta", agentID: "root", eventID: "other-file", kind: .recordedResult),
            ChangeRecord(id: "other-worktree", path: "/alpha/src/A.swift", environmentID: "/alpha", agentID: "root", eventID: "other-worktree", kind: .recordedResult)]
        let activity = ActivityEvidenceIndex(events: snapshot.events, changes: snapshot.changes, resources: snapshot.resources)
        XCTAssertEqual(activity.tests.first?.subsequentChangeIDs.count, 3)
        let selected = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.changeID("change")))
        let verification = try XCTUnwrap(selected.verifications.first)
        XCTAssertEqual(Set(verification.subsequentChangeIDs), ["following-0", "following-1"])
        XCTAssertEqual(verification.omittedSubsequentChangeCount, 0)
        XCTAssertEqual(verification.changeScope, "Périmètre : ce fichier dans cet environnement")
        XCTAssertTrue(verification.versionCoverage.contains("non établies"))
    }
    func testOldFrozenVerificationDecodesWithoutNewScopeFields() throws {
        let old = Data(#"{"eventIDs":["test"],"relation":"associatedContext","ordering":"Ordre relatif non établi","subsequentChangeIDs":["change"],"versionCoverage":"inconnue"}"#.utf8)
        let decoded = try JSONDecoder().decode(OriginVerification.self, from: old)
        XCTAssertNil(decoded.omittedSubsequentChangeCount)
        XCTAssertNil(decoded.changeScope)
        XCTAssertEqual(decoded.subsequentChangeIDs, ["change"])
    }
    func testMissingTurnDoesNotAttachFirstOrLastUserPrompt() throws {
        var snapshot = chain(); snapshot.events[snapshot.events.firstIndex { $0.id == "patch" }!].turnID = nil
        let selected = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.eventID("patch")))
        XCTAssertFalse(selected.explanations.contains { $0.eventID == "summary" })
        // Ancestor mission contexts stay labelled; no direct user-prompt -> patch causal edge.
        XCTAssertFalse(selected.links.contains { $0.to == OriginInspectionIndex.eventID("patch") && $0.from == OriginInspectionIndex.eventID("p1") })
    }
    func testCrossAgentCallIDDoesNotJoinResults() throws {
        var snapshot = chain(); snapshot.events[snapshot.events.firstIndex { $0.id == "result" }!].agentID = "child"
        let selected = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.changeID("change")))
        XCTAssertFalse(selected.links.contains { $0.relation.contains("Appel et résultat") })
    }
    func testFailedPatchAndSeparateObservedEffectRemainSeparate() throws {
        var snapshot = chain(); snapshot.events.append(event("partial", agent: "grand", turn: "g", kind: .toolResult, offset: 50))
        snapshot.changes.append(ChangeRecord(id: "partial-change", path: "/beta/src/A.swift", environmentID: "/beta", agentID: "grand", eventID: "partial", kind: .recordedResult))
        let model = index(snapshot), observed = try XCTUnwrap(model.selection(objectID: OriginInspectionIndex.changeID("partial-change")))
        XCTAssertTrue(observed.missing.contains { $0.contains("responsable non identifié") })
        XCTAssertFalse(observed.links.contains { $0.from == OriginInspectionIndex.eventID("patch") && $0.to == OriginInspectionIndex.eventID("partial") })
    }
    func testDeclaredPlanMotiveHasExactCallScope() throws {
        var snapshot = chain()
        let facts = RecordedExplanationFacts(kind: .plan, availability: .available, threadID: "grand", turnID: "g", preview: "Motif du plan", declaredForCallID: "plan-call")
        snapshot.events.append(event("plan", agent: "grand", turn: "g", offset: 25, call: "plan-call", facts: facts))
        let model = index(snapshot), plan = try XCTUnwrap(model.selection(objectID: OriginInspectionIndex.eventID("plan"))), patch = try XCTUnwrap(model.selection(objectID: OriginInspectionIndex.changeID("change")))
        XCTAssertTrue(plan.links.contains { $0.nature == .declaredMotive })
        XCTAssertFalse(patch.links.contains { $0.nature == .declaredMotive })
        XCTAssertEqual(patch.explanations.first { $0.eventID == "plan" }?.relation, .associatedContext)
    }
    func testFrozenEvidenceIsHistoricalAndBudgetIsExplicit() throws {
        let selected = try XCTUnwrap(index(chain()).selection(objectID: OriginInspectionIndex.changeID("change")))
        let piece = try OriginEvidence.piece(selection: selected, collectionCut: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(piece.kind, "originEvidence")
        XCTAssertTrue(piece.text.contains("associatedContext"))
        XCTAssertTrue(piece.text.contains("patch-call"), "The frozen source call identifier must be retained")
        XCTAssertThrowsError(try OriginEvidence.piece(selection: selected, collectionCut: .distantPast, maximumBytes: 1))
        XCTAssertEqual(piece.capturedAt, Date(timeIntervalSince1970: 100))
    }
    func testRecordedCodeReferenceKeepsBothVersionsAndSelectedSide() throws {
        let patch = "diff --git a/src/A.swift b/src/A.swift\nindex aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100644\n--- a/src/A.swift\n+++ b/src/A.swift\n@@ -2 +2 @@\n-old\n+new\n"
        let document = try RecordedDiff.parse(patch, provenance: DiffProvenance(environmentID: "/beta", eventIDs: ["patch"]), kind: .recordedDiff)
        let file = try XCTUnwrap(document.files.first), hunk = try XCTUnwrap(file.hunks.first), line = try XCTUnwrap(hunk.lines.first { $0.kind == .removed })
        let reference = try XCTUnwrap(OriginCodeReference(document: document, file: file, hunk: hunk, line: line)), piece = try reference.evidence(capturedAt: .distantPast)
        XCTAssertEqual(reference.beforeVersion, String(repeating: "a", count: 40)); XCTAssertEqual(reference.afterVersion, String(repeating: "b", count: 40))
        XCTAssertEqual(piece.location?.side, .before); XCTAssertEqual(piece.location?.version, reference.beforeVersion)
        XCTAssertEqual(piece.location?.firstLine, 2)
        XCTAssertFalse(reference.belongs(to: ChangeRecord(id: "wrong", path: "/alpha/src/A.swift", environmentID: "/alpha", agentID: "grand", eventID: "patch", kind: .requestedPatch)))
    }
    func testScopedFilterReusesIndexAndExcludesUnrelatedAgent() async throws {
        let snapshot = chain(), builder = SessionPresentationBuilder()
        let first = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters())
        let scoped = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(originInstructionID: "p1"))
        XCTAssertEqual(first.originInspection.objectsByID.count, scoped.originInspection.objectsByID.count)
        XCTAssertTrue(scoped.filteredEvents.contains { $0.id == "s1" })
        XCTAssertFalse(scoped.filteredEvents.contains { $0.id == "patch" })
    }
    func testLaterIndependentDescendantIsNotAttributedToOldInstruction() throws {
        var snapshot = chain()
        snapshot.events += [event("later-prompt", agent: "child", turn: "later", kind: .user), event("later-spawn", agent: "child", turn: "later", call: "later-spawn")]
        snapshot.agents.append(AgentRecord(id: "independent", parentID: "child", relation: .subagent, missionEventID: "later-spawn"))
        snapshot.events.append(event("independent-change", agent: "independent", turn: "independent"))
        let model = index(snapshot)
        XCTAssertFalse(model.associatedEventIDsByInstruction["p1"]?.contains("independent-change") == true)
        XCTAssertEqual(model.selection(objectID: OriginInspectionIndex.eventID("later-prompt"))?.missionTargetAgentIDs, ["independent"])
    }
    func testScopeLimitExactlyReachedRemainsExplicit() throws {
        var snapshot = chain()
        snapshot.events += (0..<4095).map { event("bulk-\($0)") }
        let model = index(snapshot)
        XCTAssertTrue(model.truncatedInstructionScopes.contains("p1"))
        XCTAssertLessThanOrEqual(model.associatedEventIDsByInstruction["p1"]?.count ?? 0, 4096)
    }
    func testAmbiguousProducerAndContextSideAreNeverChosenArbitrarily() throws {
        let text = "diff --git a/a b/a\nindex aaaaaaa..bbbbbbb 100644\n--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n context\n-old\n+new\n"
        let document = try RecordedDiff.parse(text, provenance: DiffProvenance(environmentID: "/beta", eventIDs: ["a", "b"]), kind: .recordedDiff)
        let file = try XCTUnwrap(document.files.first), hunk = try XCTUnwrap(file.hunks.first), line = try XCTUnwrap(hunk.lines.first { $0.kind == .context })
        XCTAssertNil(OriginCodeReference(document: document, file: file, hunk: hunk, line: line))
        let before = try XCTUnwrap(OriginCodeReference(document: document, file: file, hunk: hunk, line: line, eventID: "b", side: .before))
        XCTAssertEqual(try before.evidence(capturedAt: .distantPast).location?.side, .before)
        XCTAssertEqual(try before.evidence(capturedAt: .distantPast).location?.version, "aaaaaaa")
        let unified = try XCTUnwrap(OriginCodeReference(document: document, file: file, hunk: hunk, line: line, eventID: "b"))
        XCTAssertNil(try unified.evidence(capturedAt: .distantPast).location?.version)
        XCTAssertEqual(unified.eventID, "b")
    }

    func testMacTemporaryPathSpellingDoesNotLoseCodeWithinRecordedEnvironment() throws {
        let text = "diff --git a/src/A.swift b/src/A.swift\n--- a/src/A.swift\n+++ b/src/A.swift\n@@ -1 +1 @@\n-old\n+new\n"
        let environment = "/private/tmp/origin-test-worktree"
        let document = try RecordedDiff.parse(text, provenance: DiffProvenance(environmentID: environment, eventIDs: ["patch"]), kind: .recordedDiff)
        let file = try XCTUnwrap(document.files.first), hunk = try XCTUnwrap(file.hunks.first), line = try XCTUnwrap(hunk.lines.first { $0.kind == .added })
        let reference = try XCTUnwrap(OriginCodeReference(document: document, file: file, hunk: hunk, line: line))
        let path = URL(fileURLWithPath: environment).appendingPathComponent("src/A.swift").standardizedFileURL.path
        let change = ChangeRecord(id: "change", path: path, environmentID: environment, agentID: "grand", eventID: "patch", kind: .recordedResult)
        XCTAssertTrue(reference.belongs(to: change))
        var snapshot = chain(); snapshot.changes = [change]
        XCTAssertEqual(index(snapshot).changeIDs(environment: environment, path: "src/A.swift"), ["change"])
        XCTAssertTrue(index(snapshot).changeIDs(environment: "/private/tmp/other-worktree", path: "src/A.swift").isEmpty)
    }

    func testMissionInstructionInSameTurnRemainsNavigableWithoutAgentFanout() throws {
        var snapshot = chain()
        let i = snapshot.events.firstIndex { $0.id == "s1" }!
        snapshot.events[i].trace = RecordedTraceFacts(communication: RecordedCommunicationFacts(kind: .instruction, stage: .instructionRecorded, instructionKind: .direct))
        let model = index(snapshot)
        XCTAssertTrue(model.associatedEventIDsByInstruction["p1"]?.contains("s1") == true)
        XCTAssertEqual(model.selection(objectID: OriginInspectionIndex.eventID("p1"))?.missionTargetAgentIDs, ["child"])
        XCTAssertFalse(model.associatedEventIDsByInstruction["p1"]?.contains("patch") == true)
    }
    func testSharedReferenceEnvelopeRestoresAllIdentitySourceAndTimingFields() throws {
        var snapshot = chain(); snapshot.collectedAt = Date(timeIntervalSince1970: 100.123456)
        let selected = try XCTUnwrap(index(snapshot).selection(objectID: OriginInspectionIndex.changeID("change")))
        let encoded = try OriginEvidence.encode(selected)
        XCTAssertEqual(try OriginEvidence.decode(encoded), selected)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("sourceTable"))
    }

}
