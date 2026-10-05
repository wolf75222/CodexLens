import XCTest
@testable import LensCore

final class ActivityEvidenceInspectionTests: XCTestCase {
    private func event(_ id: String, time: Double = 100, kind: EventKind = .toolCall, tool: String? = "exec_command",
                       call: String? = nil, environment: String? = "/fixture/worktree", agent: String = "root",
                       root: [String: Any]) -> LensEvent {
        var value = LensEvent(id: id, timestamp: Date(timeIntervalSince1970: time), agentID: agent, kind: kind,
                              toolName: tool, callID: call, environmentID: environment,
                              source: SourceRef(path: "/fixture/\(agent).jsonl", offset: UInt64(time), length: 1, line: Int(time)))
        value.trace = RecordedTraceFacts(toolObservation: RecordedToolObservationFacts.decode(root, event: value))
        return value
    }
    private func call(_ id: String, command: String, callID: String, time: Double = 100,
                      environment: String? = "/fixture/worktree", agent: String = "root") -> LensEvent {
        event(id, time: time, call: callID, environment: environment, agent: agent,
              root: ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command",
                                                           "call_id": callID, "arguments": ["cmd": command, "workdir": environment ?? ""]]])
    }
    private func result(_ id: String, callID: String, output: Any, time: Double = 101,
                        environment: String? = "/fixture/worktree", agent: String = "root") -> LensEvent {
        event(id, time: time, kind: .toolResult, call: callID, environment: environment, agent: agent,
              root: ["type": "response_item", "payload": ["type": "function_call_output", "call_id": callID, "output": output]])
    }
    private func edit(_ id: String, callID: String, agent: String, environment: String = "/fixture/worktree",
                      start: Double?, end: Double?, time: Double = 102) -> LensEvent {
        var item: [String: Any] = ["type": "FileChange", "id": callID, "status": "completed"]
        if let start { item["started_at_ms"] = start * 1_000 }
        if let end { item["completed_at_ms"] = end * 1_000 }
        return event(id, time: time, kind: .toolResult, tool: "apply_patch", call: callID, environment: environment, agent: agent,
                     root: ["type": "event_msg", "payload": ["type": "item_completed", "item": item]])
    }
    private func change(_ id: String, event: LensEvent, path: String = "/fixture/worktree/A.swift", kind: ChangeKind = .recordedResult) -> ChangeRecord {
        ChangeRecord(id: id, path: path, environmentID: event.environmentID ?? "", agentID: event.agentID, eventID: event.id, kind: kind)
    }

    func testTruncatedCommandCaptureAndToolResultRemainDistinct() throws {
        let invocation = call("call", command: "swift test", callID: "test")
        let completion = result("result", callID: "test", output: ["stdout": "test output", "stderr": "", "exit_code": 0, "truncated": true])
        let facts = try XCTUnwrap(completion.trace?.toolObservation)
        XCTAssertEqual(facts.outputs.map(\.kind), [.toolResult, .commandCapture, .commandCapture])
        XCTAssertTrue(facts.outputs.filter { $0.kind == .commandCapture }.allSatisfy(\.isExplicitlyTruncated))
        let index = ActivityEvidenceIndex(events: [invocation, completion], changes: [], resources: [])
        XCTAssertEqual(index.tests.count, 1)
        XCTAssertEqual(index.tests[0].outcome, .succeeded)
        XCTAssertTrue(index.tests[0].activity.limitations.contains { $0.contains("completeness") && $0.contains("model request") })
    }

    func testTextTruncationAndExitMarkerAreRecordedWithoutInventingCapture() throws {
        let value = result("result", callID: "test", output: "Process exited with code 7\nWarning: truncated output (original character count: 9000)\npartial")
        let facts = try XCTUnwrap(value.trace?.toolObservation)
        XCTAssertEqual(facts.exitCode, 7)
        XCTAssertEqual(facts.outputs.count, 1)
        XCTAssertEqual(facts.outputs[0].kind, .toolResult)
        XCTAssertTrue(facts.outputs[0].isExplicitlyTruncated)
    }

    func testOutputTextAloneDoesNotEstablishTestSuccess() {
        let index = ActivityEvidenceIndex(events: [call("call", command: "pytest -q", callID: "test"),
                                                   result("result", callID: "test", output: "All tests passed")], changes: [], resources: [])
        XCTAssertEqual(index.tests.count, 1)
        XCTAssertEqual(index.tests[0].outcome, .unknown)
        XCTAssertTrue(index.tests[0].activity.outputs.allSatisfy { !$0.isExplicitlyTruncated })
        XCTAssertTrue(index.tests[0].activity.limitations.contains { $0.contains("completeness") })
    }

    func testCanonicalFingerprintRepeatsOnlyInSameRecordedEnvironment() throws {
        let first = event("first", call: "a", root: ["payload": ["type": "function_call", "name": "exec_command", "arguments": #"{"cmd":"pytest -q","workdir":"/fixture/worktree"}"#]])
        let second = event("second", call: "b", root: ["payload": ["type": "function_call", "name": "exec_command", "arguments": ["workdir": "/fixture/worktree", "cmd": "pytest -q"]]])
        let other = event("other", call: "c", environment: "/fixture/other", root: ["payload": ["type": "function_call", "name": "exec_command", "arguments": ["cmd": "pytest -q", "workdir": "/fixture/worktree"]]])
        XCTAssertEqual(first.trace?.toolObservation?.callFingerprint, second.trace?.toolObservation?.callFingerprint)
        XCTAssertNotEqual(first.trace?.toolObservation?.callFingerprint, other.trace?.toolObservation?.callFingerprint)
        let index = ActivityEvidenceIndex(events: [first, second, other], changes: [], resources: [])
        XCTAssertEqual(index.repeatedCallGroups.count, 1)
        XCTAssertEqual(Set(index.repeatedCallGroups[0].eventIDs), ["first", "second"])
        XCTAssertTrue(index.repeatedCallGroups[0].limitations.contains { $0.contains("no reason") })
        XCTAssertTrue(index.tests.isEmpty)
    }

    func testRecognizesOnlyLiteralExecutableTestCommands() {
        let commands = ["swift test --filter Evidence", "env -u PYTHONPATH python3 -m pytest -q", "ctest --output-on-failure",
                        "xcodebuild -scheme Lens test", "rtk proxy cargo test", "go test ./...", "npm test"]
        for (offset, command) in commands.enumerated() {
            XCTAssertNotNil(call("call-\(offset)", command: command, callID: "id-\(offset)").trace?.toolObservation?.explicitTestCommand, command)
        }
        for command in ["echo 'swift test'", "printf '%s' pytest", "pytest --collect-only", "ctest -N", "swift test list",
                        "cargo test -- --list", "cat test.py", "echo x # pytest\necho done", "false && swift test", "swift test || true", "swift test && echo done"] {
            XCTAssertNil(call("call", command: command, callID: "test").trace?.toolObservation?.explicitTestCommand, command)
        }
    }

    func testUnlinkedResultsAndOtherAgentCallIDsDoNotConfirmExecution() {
        let invocation = call("call", command: "swift test", callID: "same")
        let other = result("other", callID: "same", output: ["exit_code": 0], agent: "child")
        let unlinked = result("unlinked", callID: "different", output: ["exit_code": 0])
        let index = ActivityEvidenceIndex(events: [invocation, other, unlinked], changes: [], resources: [])
        XCTAssertTrue(index.tests.isEmpty)
        XCTAssertNotEqual(index.observationsByEventID["call"]?.id, index.observationsByEventID["other"]?.id)
    }

    func testCompletedCommandCarriesExplicitIntervalAndExecutionEvidence() throws {
        let value = event("completed", call: "cmd", root: ["payload": ["type": "item_completed", "started_at_ms": 100_000,
                                                                       "completed_at_ms": 104_000,
                                                                       "item": ["type": "CommandExecution", "id": "cmd", "command": ["/bin/zsh", "-lc", "swift test"],
                                                                                "formatted_output": "output", "exit_code": 0, "status": "completed"]]])
        let index = ActivityEvidenceIndex(events: [value], changes: [], resources: [])
        let test = try XCTUnwrap(index.tests.first)
        XCTAssertEqual(test.activity.recordedStartTime, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(test.activity.recordedEndTime, Date(timeIntervalSince1970: 104))
        XCTAssertEqual(test.activity.outputs.map(\.kind), [.commandCapture])
        XCTAssertEqual(test.outcome, .succeeded)
    }

    func testRequestedPatchAndResultAreOneFileActivity() throws {
        let request = event("request", tool: "apply_patch", call: "patch", root: ["payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "patch", "input": "*** patch ***"]])
        let completion = edit("result", callID: "patch", agent: "root", start: 100, end: 103)
        let index = ActivityEvidenceIndex(events: [request, completion],
            changes: [change("request-change", event: request, kind: .requestedPatch), change("result-change", event: completion)], resources: [])
        let history = try XCTUnwrap(index.fileHistories.first)
        XCTAssertEqual(history.activities.count, 1)
        XCTAssertEqual(Set(history.activities[0].changeIDs), ["request-change", "result-change"])
        XCTAssertEqual(Set(history.activities[0].eventIDs), ["request", "result"])
        XCTAssertTrue(history.overlappingRecordedIntervals.isEmpty)
    }

    func testOverlapRequiresIntervalsSamePathAndEnvironment() throws {
        let a = edit("a", callID: "a", agent: "alpha", start: 100, end: 105)
        let b = edit("b", callID: "b", agent: "beta", start: 103, end: 106)
        let near = edit("near", callID: "near", agent: "gamma", start: nil, end: nil, time: 104)
        let other = edit("other", callID: "other", agent: "delta", environment: "/fixture/other-worktree", start: 101, end: 104)
        let otherPath = edit("otherPath", callID: "otherPath", agent: "epsilon", start: 101, end: 104)
        let changes = [change("ca", event: a), change("cb", event: b), change("cn", event: near),
                       change("co", event: other), change("cp", event: otherPath, path: "/fixture/worktree/B.swift")]
        let index = ActivityEvidenceIndex(events: [a, b, near, other, otherPath], changes: changes, resources: [])
        let history = try XCTUnwrap(index.fileHistories.first { $0.environmentID == "/fixture/worktree" && $0.path.hasSuffix("A.swift") })
        XCTAssertEqual(history.overlappingRecordedIntervals.count, 1)
        XCTAssertEqual(history.overlappingRecordedIntervals[0].startTime, Date(timeIntervalSince1970: 103))
        XCTAssertEqual(history.overlappingRecordedIntervals[0].endTime, Date(timeIntervalSince1970: 105))
        XCTAssertEqual(index.fileHistories.flatMap(\.overlappingRecordedIntervals).count, 1)
    }

    func testCompletionTimeAloneDoesNotInventAnInterval() throws {
        let value = edit("only-end", callID: "patch", agent: "root", start: nil, end: 105)
        let index = ActivityEvidenceIndex(events: [value], changes: [change("change", event: value)], resources: [])
        let activity = try XCTUnwrap(index.observationsByEventID[value.id])
        XCTAssertNil(activity.recordedStartTime)
        XCTAssertEqual(activity.recordedEndTime, Date(timeIntervalSince1970: 105))
        XCTAssertTrue(index.fileHistories[0].overlappingRecordedIntervals.isEmpty)
    }

    func testTestFollowedByChangeReportsObservationWithoutCoverageOrCause() throws {
        let invocation = call("call", command: "swift test", callID: "test", time: 100)
        let completion = result("result", callID: "test", output: ["exit_code": 0], time: 101)
        let later = edit("edit", callID: "patch", agent: "child", start: 102, end: 103, time: 103)
        let other = edit("other", callID: "other-patch", agent: "child", environment: "/fixture/other-worktree", start: 104, end: 105, time: 105)
        let index = ActivityEvidenceIndex(events: [invocation, completion, later, other],
                                          changes: [change("later", event: later), change("other", event: other)], resources: [])
        let test = try XCTUnwrap(index.tests.first)
        XCTAssertEqual(test.subsequentChangeIDs, ["later"])
        XCTAssertEqual(test.outcome, .succeeded)
        XCTAssertTrue(test.limitations.contains { $0.contains("invalidation, causality or coverage") })
    }

    func testResourceReadLinksRecordedVersionAndNeverCurrentAvailability() throws {
        let read = event("read", tool: "read_file", call: "read-id", root: ["payload": ["type": "function_call", "name": "read_file",
            "arguments": ["path": "A.swift", "source_version_id": "recorded-version"]]])
        let resource = ResourceRecord(location: "/fixture/worktree/A.swift", roles: [.recordedRead], environmentID: "/fixture/worktree",
                                      eventIDs: [read.id], availability: .accessible)
        let index = ActivityEvidenceIndex(events: [read], changes: [], resources: [resource])
        let observation = try XCTUnwrap(index.fileHistories.first?.reads.first)
        XCTAssertEqual(observation.recordedVersions.map(\.identifier), ["recorded-version"])
        XCTAssertEqual(observation.recordedVersions.first?.sourceRef, read.source)
        XCTAssertEqual(observation.sourceRefs, [read.source])
        XCTAssertTrue(observation.limitations.contains { $0.contains("not verified") })
        var withoutVersion = read
        withoutVersion.trace?.toolObservation?.recordedReads = []
        let unavailable = ActivityEvidenceIndex(events: [withoutVersion], changes: [], resources: [resource]).fileHistories[0].reads[0]
        XCTAssertTrue(unavailable.recordedVersions.isEmpty)
        XCTAssertTrue(unavailable.limitations.contains { $0.contains("not identified") })
    }

    func testConflictingExitAndStatusRemainConflicting() throws {
        let values = [call("call", command: "ctest", callID: "test"), result("result", callID: "test", output: ["exit_code": 1, "status": "passed"])]
        let index = ActivityEvidenceIndex(events: values, changes: [], resources: [])
        XCTAssertEqual(index.tests.first?.outcome, .conflicting)
        let facts = try XCTUnwrap(values[1].trace?.toolObservation)
        XCTAssertEqual(try JSONDecoder().decode(RecordedToolObservationFacts.self, from: JSONEncoder().encode(facts)), facts)
    }

    func testCompletedStatusWithoutExitCodeDoesNotCertifyPassingTests() {
        let values = [call("call", command: "swift test", callID: "test"), result("result", callID: "test", output: ["status": "completed"])]
        let index = ActivityEvidenceIndex(events: values, changes: [], resources: [])
        XCTAssertEqual(index.tests.first?.outcome, .unknown)
        XCTAssertTrue(index.tests.first?.activity.limitations.contains { $0.contains("not a passing") } == true)
    }

    func testCommandShapedArgumentsOfReadToolDoNotEstablishTestExecution() {
        let value = event("read", tool: "read_file", call: "read", root: ["payload": ["type": "function_call", "name": "read_file", "arguments": ["cmd": "swift test"]]])
        XCTAssertNil(value.trace?.toolObservation?.explicitTestCommand)
    }

    func testUnknownEnvironmentAndAmbiguousCallNeverBecomeRepeatedOrQualifiedTests() {
        let unknown = [call("a", command: "pytest", callID: "a", environment: nil), call("b", command: "pytest", callID: "b", environment: nil)]
        XCTAssertTrue(ActivityEvidenceIndex(events: unknown, changes: [], resources: []).repeatedCallGroups.isEmpty)
        let conflicting = [call("a", command: "pytest", callID: "same"), call("b", command: "ctest", callID: "same"),
                           result("result", callID: "same", output: ["exit_code": 0])]
        let index = ActivityEvidenceIndex(events: conflicting, changes: [], resources: [])
        XCTAssertTrue(index.tests.isEmpty)
        XCTAssertNil(index.observationsByEventID["a"]?.callFingerprint)
    }

    func testBooleanIsNotAnExitCodeOrRecordedTime() throws {
        let value = event("completed", call: "cmd", root: ["payload": ["type": "item_completed", "started_at_ms": true,
                                                                       "completed_at_ms": false, "item": ["type": "CommandExecution", "command": "swift test", "exit_code": false]]])
        let facts = try XCTUnwrap(value.trace?.toolObservation)
        XCTAssertNil(facts.exitCode)
        XCTAssertNil(facts.recordedStartTime)
        XCTAssertNil(facts.recordedEndTime)
    }

    func testPersistedCommandPreviewsRedactSecretsWhileFingerprintUsesOriginal() throws {
        let command = "pytest --header 'Authorization: Bearer abcdefghijklmnop123' --api_key='private-api-value' --password=\"two secret words\" --endpoint='https://alice:private-password@example.invalid?token=query-secret' --credential=sk-testabcdefghijklmnop"
        let value = call("call", command: command, callID: "test")
        let facts = try XCTUnwrap(value.trace?.toolObservation)
        XCTAssertNotNil(facts.explicitTestCommand)
        XCTAssertEqual(facts.commandUTF8Bytes, command.utf8.count)
        XCTAssertFalse(facts.commandIsPartial)
        let encoded = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        for secret in ["abcdefghijklmnop123", "private-api-value", "two secret words", "private-password", "query-secret", "sk-testabcdefghijklmnop"] {
            XCTAssertFalse(encoded.contains(secret), secret)
        }
        let different = call("other", command: command.replacingOccurrences(of: "private-api-value", with: "different-api-value"), callID: "other")
        XCTAssertEqual(facts.command, different.trace?.toolObservation?.command)
        XCTAssertNotEqual(facts.callFingerprint, different.trace?.toolObservation?.callFingerprint)
    }

    func testHugeUnicodeCommandIsBoundedAndRemainsAnExplicitTestObservation() throws {
        let command = "swift test --filter " + String(repeating: "🧪", count: 8_000)
        let value = call("call", command: command, callID: "test")
        let facts = try XCTUnwrap(value.trace?.toolObservation)
        XCTAssertEqual(facts.commandUTF8Bytes, command.utf8.count)
        XCTAssertTrue(facts.commandIsPartial)
        XCTAssertLessThanOrEqual(facts.command?.utf8.count ?? 0, 12 * 1_024)
        XCTAssertLessThanOrEqual(facts.explicitTestCommand?.utf8.count ?? 0, 12 * 1_024)
        XCTAssertNotNil(facts.explicitTestCommand)
        let completion = result("result", callID: "test", output: ["exit_code": 0])
        let index = ActivityEvidenceIndex(events: [value, completion], changes: [], resources: [])
        let activity = try XCTUnwrap(index.tests.first?.activity)
        XCTAssertTrue(activity.commandIsPartial)
        XCTAssertEqual(activity.commandUTF8Bytes, command.utf8.count)
        XCTAssertTrue(activity.limitations.contains { $0.contains("12 KiB") && $0.contains("partial") })
    }

    func testTruncationMarkerDoesNotPersistCapturedOutputText() throws {
        let value = result("result", callID: "tool", output: "Warning: truncated output Bearer private-marker-token\napi_key=private-body-value")
        let facts = try XCTUnwrap(value.trace?.toolObservation)
        let encoded = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-marker-token"))
        XCTAssertFalse(encoded.contains("private-body-value"))
        XCTAssertTrue(facts.outputs.first?.isExplicitlyTruncated == true)
    }
}
