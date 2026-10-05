import XCTest
import CryptoKit
@testable import LensCore

final class ConversationExportTests: XCTestCase {
    private var directory: URL!
    private var sources: URL!
    private var exports: URL!
    override func setUpWithError() throws {
        // The registry explicitly refuses symlink ancestors; /var and /tmp are aliases
        // on macOS, so its test-owned directory uses the physical /private/tmp spelling.
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("lens-conversation-test-" + UUID().uuidString)
        sources = directory.appendingPathComponent("observed")
        exports = directory.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func event(_ text: String, id: String, role: EventKind = .user, agent: String = "root", timestamp: Date = .distantPast) throws -> LensEvent {
        let data = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "message", "role": role == .user ? "user" : "assistant", "content": [["type": "input_text", "text": text]]]], options: [.sortedKeys, .withoutEscapingSlashes])
        let source = sources.appendingPathComponent(id + ".jsonl")
        try data.write(to: source)
        return LensEvent(id: id, timestamp: timestamp, agentID: agent, turnID: "turn-" + id, kind: role, preview: "INDEX-PREVIEW-MUST-NOT-REPLACE-TEXT",
            source: SourceRef(path: source.path, length: data.count, line: 1, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
    private func plan(_ events: [LensEvent], resources: [ResourceRecord] = [], coverage: [CoverageIssue] = []) -> ConversationExportPlan {
        ConversationExportPlan(snapshot: SessionSnapshot(root: SessionSummary(id: "root", sessionID: "session-1", title: "Anonyme", cwd: sources.path),
            agents: [AgentRecord(id: "root"), AgentRecord(id: "child", parentID: "root", relation: .subagent)], events: events,
            environments: [EnvironmentRecord(path: sources.path)], resources: resources, coverage: coverage, collectedAt: Date(timeIntervalSince1970: 1000)))
    }
    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Operation should fail", file: file, line: line) } catch { }
    }
    private func json(_ destination: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
    }
    private func legacySnapshot(includeCanonical: Bool) async throws -> SessionSnapshot {
        let rootID = "11111111-1111-4111-8111-111111111111"
        let home = directory.appendingPathComponent("legacy-fixture")
        let sessionDirectory = home.appendingPathComponent("sessions/2026/10/04")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        func record(_ type: String, _ payload: [String: Any]) -> [String: Any] {
            ["timestamp": "2026-10-04T00:00:00.000Z", "type": type, "payload": payload]
        }
        var records = [record("session_meta", ["id": rootID, "cwd": sources.path, "cli_version": "0.159.2", "history_mode": "legacy", "source": "cli"])]
        if includeCanonical {
            records.append(record("response_item", ["type": "message", "id": "user-1", "role": "user", "content": [["type": "input_text", "text": "SAME-USER-TEXT"]]]))
        }
        records.append(record("event_msg", ["type": "user_message", "message": "SAME-USER-TEXT"]))
        records.append(record("event_msg", ["type": "agent_message", "message": "LEGACY-ASSISTANT-TEXT"]))
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])); data.append(10) }
        try data.write(to: sessionDirectory.appendingPathComponent("rollout-legacy-" + rootID + ".jsonl"))
        return try await SessionEngine(home: home, cacheDirectory: directory.appendingPathComponent("legacy-cache"), investigationRegistryDirectory: directory.appendingPathComponent("isolated-registry")).open(id: rootID)
    }

    func testRootRolesOnlyPreserveOrderIDsTurnsAndAliasesWithoutDoubleText() async throws {
        var first = try event("identical message", id: "a")
        first.environmentID = sources.path
        let mirror = try event("MIRROR-TEXT-MUST-NOT-BE-APPENDED", id: "mirror")
        first.supplementarySources = [mirror.source]
        let second = try event("identical message", id: "b", role: .assistant)
        let child = try event("child message", id: "c", role: .assistant, agent: "child")
        let tool = try event("tool pseudo text", id: "d", role: .toolCall)
        let instruction = try event("instruction pseudo text", id: "e", role: .instruction)
        let exporter = ConversationExporter(plan: plan([first, second, child, tool, instruction]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.map(\.id), ["a", "b"])
        XCTAssertEqual(review.userCount, 1); XCTAssertEqual(review.assistantCount, 1)
        let a = try await exporter.message(eventID: "a"), b = try await exporter.message(eventID: "b")
        XCTAssertEqual(a.text, "identical message"); XCTAssertEqual(b.text, "identical message")
        XCTAssertEqual(a.supplementarySources, [mirror.source]); XCTAssertEqual(a.source, first.source)
        XCTAssertEqual(a.turnID, "turn-a"); XCTAssertEqual(a.threadID, "root")
        XCTAssertEqual(a.environmentID, sources.path); XCTAssertNil(b.environmentID)
        XCTAssertNil(a.previousMessageID); XCTAssertEqual(b.previousMessageID, "a")
        XCTAssertNil(a.timestamp); XCTAssertNil(review.firstTimestamp)
        await exporter.dispose()
    }

    func testLongUnicodeFullJSONAndMarkdownContainTailWithoutSilentTruncation() async throws {
        let text = String(repeating: "é👩🏽‍💻\t\\\"\n", count: 14000) + "END-OF-CAPTURE-🚀"
        let item = try event(text, id: "unicode", timestamp: Date(timeIntervalSince1970: 123))
        let exporter = ConversationExporter(plan: plan([item]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.first?.preview.count, 400)
        XCTAssertEqual(review.totalTextBytes, text.utf8.count)
        let selected = try await exporter.message(eventID: item.id)
        XCTAssertEqual(selected.text, text)
        let destination = exports.appendingPathComponent("conversation.json")
        let receipt = try await exporter.export(to: destination, format: .json)
        let document = try json(destination), messages = try XCTUnwrap(document["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["text"] as? String, text)
        XCTAssertEqual(messages.first?["timestamp"] as? Int, 123000)
        XCTAssertEqual(receipt.byteCount, try Data(contentsOf: destination).count)
        XCTAssertEqual(receipt.sha256, SHA256.hash(data: try Data(contentsOf: destination)).map { String(format: "%02x", $0) }.joined())
        let markdown = exports.appendingPathComponent("conversation.md")
        _ = try await exporter.export(to: markdown, format: .markdown)
        let readable = try String(contentsOf: markdown, encoding: .utf8)
        XCTAssertTrue(readable.contains("END-OF-CAPTURE-🚀")); XCTAssertTrue(readable.contains("\n    é👩🏽‍💻"))
        await exporter.dispose()
    }

    func testPrepareFreezesMembershipAndBytesBeforeAppendAndSourceDeletion() async throws {
        let first = try event("FROZEN-OLD-MESSAGE", id: "old")
        let exporter = ConversationExporter(plan: plan([first]))
        _ = try await exporter.prepare()
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: first.source.path))
        try writer.seekToEnd(); try writer.write(contentsOf: Data("\n{\"payload\":{\"text\":\"NEW-EVENT\"}}\n".utf8)); try writer.close()
        try FileManager.default.removeItem(atPath: first.source.path)
        let selected = try await exporter.message(eventID: first.id)
        XCTAssertEqual(selected.text, "FROZEN-OLD-MESSAGE")
        let output = exports.appendingPathComponent("frozen.json")
        _ = try await exporter.export(to: output, format: .json)
        let messages = try XCTUnwrap(try json(output)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1); XCTAssertEqual(messages.first?["text"] as? String, "FROZEN-OLD-MESSAGE")
        await exporter.dispose()
    }

    func testMissingAndDigestChangedSourcesRemainRowsWithoutPreviewSubstitution() async throws {
        let missing = try event("missing old text", id: "missing")
        let changed = try event(String(repeating: "a", count: 10000), id: "changed")
        try FileManager.default.removeItem(atPath: missing.source.path)
        let path = URL(fileURLWithPath: changed.source.path)
        var bytes = try Data(contentsOf: path)
        let location = try XCTUnwrap(bytes.firstIndex(of: 97))
        bytes[location] = 98; try bytes.write(to: path)
        let exporter = ConversationExporter(plan: plan([missing, changed]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.map(\.status), [.unavailable, .integrityFailed])
        XCTAssertEqual(review.messages.map(\.preview), ["", ""])
        XCTAssertTrue(review.messages.allSatisfy { !$0.limitations.isEmpty })
        let message = try await exporter.message(eventID: "changed")
        XCTAssertNil(message.text); XCTAssertEqual(message.byteCount, 0)
        let output = exports.appendingPathComponent("missing.json")
        _ = try await exporter.export(to: output, format: .json)
        let encoded = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(encoded.contains("\"text\":null")); XCTAssertFalse(encoded.contains("INDEX-PREVIEW"))
        await exporter.dispose()
    }

    func testKnownRedactionCoversSecretsAcrossPagesAndReferenceMetadata() async throws {
        let token = "sk-" + String(repeating: "q", count: 70000)
        let privateKey = "-----BEGIN PRIVATE KEY-----\nKEY-SECRET-MUST-NOT-SURVIVE\n-----END PRIVATE KEY-----"
        let text = "Bearer ABCDEFGHIJKL " + token + "\npassword=supersecret\n" + privateKey + "\nTAIL"
        let item = try event(text, id: "redact")
        let resource = ResourceRecord(location: "https://example.invalid/file?token=SECRETQUERY", eventIDs: [item.id], availability: .external)
        let exporter = ConversationExporter(plan: plan([item], resources: [resource]))
        _ = try await exporter.prepare()
        let message = try await exporter.message(eventID: item.id)
        let clean = try XCTUnwrap(message.text)
        XCTAssertFalse(clean.contains("ABCDEFGHIJKL")); XCTAssertFalse(clean.contains(token))
        XCTAssertFalse(clean.contains("supersecret")); XCTAssertFalse(clean.contains("KEY-SECRET-MUST-NOT-SURVIVE"))
        XCTAssertTrue(clean.hasSuffix("TAIL")); XCTAssertFalse(message.resources[0].location.contains("SECRETQUERY"))
        let output = exports.appendingPathComponent("masked.json")
        _ = try await exporter.export(to: output, format: .json)
        let encoded = try String(contentsOf: output, encoding: .utf8)
        XCTAssertFalse(encoded.contains("SECRETQUERY")); XCTAssertFalse(encoded.contains("supersecret"))
        await exporter.dispose()
    }

    func testResourceBytesNotLoadedAndUnavailableAttachmentRemainsReference() async throws {
        var item = try event("See my attachment", id: "attachment")
        let missing = sources.appendingPathComponent("not-present.pdf")
        let resource = ResourceRecord(location: missing.path, roles: [.supplied], eventIDs: [item.id], availability: .missing)
        item.resourceIDs = [resource.id]
        let exporter = ConversationExporter(plan: plan([item], resources: [resource]))
        _ = try await exporter.prepare()
        let message = try await exporter.message(eventID: item.id)
        XCTAssertEqual(message.resources.count, 1); XCTAssertEqual(message.resources[0].availability, .missing)
        XCTAssertEqual(message.resources[0].roles, [.supplied]); XCTAssertEqual(message.status, .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        await exporter.dispose()
    }

    func testRedactedResourceIDsRemainDistinctAndStable() async throws {
        let item = try event("two references", id: "resource-ids")
        let first = ResourceRecord(location: "https://example.invalid/file?token=FIRSTSECRET", eventIDs: [item.id], availability: .external)
        let second = ResourceRecord(location: "https://example.invalid/file?token=SECONDSECRET", eventIDs: [item.id], availability: .external)
        let exporter = ConversationExporter(plan: plan([item], resources: [first, second]))
        _ = try await exporter.prepare()
        let message = try await exporter.message(eventID: item.id), again = try await exporter.message(eventID: item.id)
        XCTAssertEqual(message.resources.count, 2)
        XCTAssertNotEqual(message.resources[0].id, message.resources[1].id)
        XCTAssertEqual(message.resources.map(\.id), again.resources.map(\.id))
        XCTAssertTrue(message.resources.allSatisfy { $0.id.hasPrefix("redacted-resource:") })
        let output = exports.appendingPathComponent("resource-ids.json")
        _ = try await exporter.export(to: output, format: .json)
        let json = try String(contentsOf: output, encoding: .utf8)
        XCTAssertFalse(json.contains("FIRSTSECRET")); XCTAssertFalse(json.contains("SECONDSECRET"))
        await exporter.dispose()
    }

    func testActualLegacyOnlySessionKeepsExcludedReferencesAndCoverage() async throws {
        let snapshot = try await legacySnapshot(includeCanonical: false)
        XCTAssertFalse(snapshot.events.contains { $0.kind == .user || $0.kind == .assistant })
        let exporter = ConversationExporter(plan: ConversationExportPlan(snapshot: snapshot))
        let review = try await exporter.prepare()
        XCTAssertTrue(review.messages.isEmpty)
        XCTAssertEqual(review.excludedReferences.count, 2)
        XCTAssertEqual(review.excludedReferences.map(\.source), snapshot.events.filter { $0.title.hasSuffix("· trace de contexte") }.map(\.source))
        XCTAssertTrue(review.excludedReferences.allSatisfy { $0.associatedMessageIDs.isEmpty && $0.reason.contains("non confirmée") })
        XCTAssertTrue(review.coverage.contains { $0.category == "conversation legacy" && $0.message.contains("2 trace(s)") })
        let output = exports.appendingPathComponent("legacy-only.json")
        _ = try await exporter.export(to: output, format: .json)
        let document = try json(output), encodedReview = try XCTUnwrap(document["review"] as? [String: Any])
        XCTAssertEqual((encodedReview["excludedReferences"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((document["messages"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(try String(contentsOf: output, encoding: .utf8).contains("LEGACY-ASSISTANT-TEXT"))
        await exporter.dispose()
    }

    func testActualCanonicalAndLegacyEqualTextAreNotAutomaticallyMergedOrDuplicated() async throws {
        let snapshot = try await legacySnapshot(includeCanonical: true)
        let exporter = ConversationExporter(plan: ConversationExportPlan(snapshot: snapshot))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.count, 1); XCTAssertEqual(review.excludedReferences.count, 2)
        XCTAssertTrue(review.excludedReferences.allSatisfy { $0.associatedMessageIDs.isEmpty }, "Equal text and timestamp do not prove a mirror")
        let selected = try await exporter.message(eventID: review.messages[0].id)
        XCTAssertEqual(selected.text, "SAME-USER-TEXT")
        await exporter.dispose()
    }

    func testExcludedLegacyReferenceLinksOnlyExplicitSourceAlias() async throws {
        var primary = try event("primary user text", id: "primary-alias")
        var legacy = try event("different text does not establish association", id: "legacy-alias", role: .context)
        legacy.title = "user_message · trace de contexte"
        primary.supplementarySources = [legacy.source]
        let exporter = ConversationExporter(plan: plan([primary, legacy]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.excludedReferences.count, 1)
        XCTAssertEqual(review.excludedReferences[0].associatedMessageIDs, [primary.id])
        XCTAssertTrue(review.excludedReferences[0].reason.contains("explicitement"))
        let selected = try await exporter.message(eventID: primary.id)
        XCTAssertEqual(selected.text, "primary user text")
        await exporter.dispose()
    }

    func testLexicalCuesAreUncertainUserObservationsAndCitedTextCanBeFalsePositive() async throws {
        let user = try event("Je cite le document : « corrige cette erreur ». Je préfère le bleu. Il faut conserver le fichier. Continue.", id: "cue")
        let assistant = try event("corrige ; je préfère ; il faut ; continue", id: "answer", role: .assistant)
        let exporter = ConversationExporter(plan: plan([user, assistant]))
        let review = try await exporter.prepare()
        XCTAssertEqual(Set(review.messages[0].signals.map(\.kind)), Set(ConversationSignalKind.allCases))
        XCTAssertTrue(review.messages[0].signals[0].excerpt.contains("Je cite"))
        XCTAssertTrue(review.messages[1].signals.isEmpty)
        XCTAssertTrue(review.limits.contains { $0.contains("faux positif") && $0.contains("ni effet") })
        XCTAssertFalse(review.messages[0].signals.contains { $0.excerpt.contains("inferred cause") })
        await exporter.dispose()
    }

    func testPerMessageAndTotalQuotasOmitWholePayloadWithVisibleStatus() async throws {
        let huge = try event(String(repeating: "x", count: 1000), id: "huge")
        let short = try event("short", id: "short", role: .assistant)
        let perMessage = ConversationExporter(plan: plan([huge, short]), maximumBytes: 2048, maximumMessageBytes: 512)
        let review = try await perMessage.prepare()
        XCTAssertEqual(review.messages.map(\.status), [.messageLimitExceeded, .available])
        XCTAssertEqual(review.totalTextBytes, 5)
        let omitted = try await perMessage.message(eventID: huge.id)
        XCTAssertNil(omitted.text); XCTAssertEqual(omitted.byteCount, 0)
        await perMessage.dispose()
        let storage = ConversationExporter(plan: plan([huge, short]), maximumBytes: 3, maximumMessageBytes: 2048)
        let stored = try await storage.prepare()
        XCTAssertEqual(stored.messages.map(\.status), [.storageLimitExceeded, .storageLimitExceeded])
        XCTAssertEqual(stored.totalTextBytes, 0)
        await storage.dispose()
    }

    func testNoTextFieldAndMalformedRecordAreExplicitNotSuccessfulEmptyMessage() async throws {
        let path = sources.appendingPathComponent("opaque.jsonl")
        let bytes = Data("{\"payload\":{\"encrypted_content\":\"OPAQUE-CONTENT\"}}".utf8)
        try bytes.write(to: path)
        let opaque = LensEvent(id: "opaque", agentID: "root", kind: .assistant, preview: "DO-NOT-USE", source: SourceRef(path: path.path, length: bytes.count))
        let badPath = sources.appendingPathComponent("bad.jsonl")
        let broken = Data("{\"payload\":{\"text\":\"PARTIAL".utf8)
        try broken.write(to: badPath)
        let malformed = LensEvent(id: "malformed", agentID: "root", kind: .user, source: SourceRef(path: badPath.path, length: broken.count))
        let exporter = ConversationExporter(plan: plan([opaque, malformed]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.map(\.status), [.noRecordedText, .integrityFailed])
        let m = try await exporter.message(eventID: opaque.id)
        XCTAssertNil(m.text); XCTAssertTrue(m.limitations.contains { $0.contains("Aucun champ") })
        await exporter.dispose()
    }

    func testUnknownTimestampAndRecordedCoverageRemainExplicit() async throws {
        var item = try event("message", id: "coverage")
        item.source.sha256 = nil
        let issue = CoverageIssue("partial", "Une période n’est pas observée.", source: "journal")
        let exporter = ConversationExporter(plan: plan([item], coverage: [issue]))
        let review = try await exporter.prepare()
        XCTAssertNil(review.firstTimestamp); XCTAssertNil(review.lastTimestamp); XCTAssertNil(review.messages[0].timestamp)
        XCTAssertEqual(review.collectedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(review.coverage, [issue]); XCTAssertTrue(review.messages[0].limitations.contains { $0.contains("Sans empreinte") })
        await exporter.dispose()
    }

    func testInvalidSourceRangeRemainsUnavailableAndMarkdownDoesNotOverflow() async throws {
        var item = try event("not used for invalid range", id: "bad-range")
        item.source.offset = UInt64.max
        item.source.length = 120
        let exporter = ConversationExporter(plan: plan([item]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages[0].status, .integrityFailed)
        let output = exports.appendingPathComponent("bad-range.md")
        _ = try await exporter.export(to: output, format: .markdown)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(markdown.contains("décalage \(UInt64.max), longueur 120"))
        await exporter.dispose()
    }

    func testCredentialsSourceAndSymlinkAreNotRead() async throws {
        let auth = sources.appendingPathComponent("auth.json")
        let data = Data("{\"payload\":{\"text\":\"AUTH-SECRET-MUST-NOT-BE-READ\"}}".utf8)
        try data.write(to: auth)
        let alias = sources.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: auth)
        let credential = LensEvent(id: "credential", agentID: "root", kind: .user, source: SourceRef(path: auth.path, length: data.count))
        let linked = LensEvent(id: "linked", agentID: "root", kind: .assistant, source: SourceRef(path: alias.path, length: data.count))
        let exporter = ConversationExporter(plan: plan([credential, linked]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.map(\.status), [.unavailable, .unavailable])
        XCTAssertTrue(review.messages.allSatisfy { $0.preview.isEmpty && $0.limitations.joined().contains("contenu non lu") })
        let m = try await exporter.message(eventID: "credential")
        XCTAssertNil(m.text)
        await exporter.dispose()
    }

    func testRelativeAndNULSourcePathsAreRejectedWithoutCurrentDirectoryFallback() async throws {
        let original = try event("ABSOLUTE-ONLY-CAPTURE", id: "absolute-source")
        var relative = original
        relative.id = "relative-source"
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        relative.source.path = String(repeating: "../", count: current.pathComponents.count - 1) + String(original.source.path.dropFirst())
        // The relative spelling really reaches the existing source when resolved from cwd;
        // rejecting it therefore prevents an otherwise successful but ambiguous fallback.
        XCTAssertEqual(URL(fileURLWithPath: relative.source.path).resolvingSymlinksInPath(), URL(fileURLWithPath: original.source.path).resolvingSymlinksInPath())
        var nul = original
        nul.id = "nul-source"; nul.source.path += "\0ignored.jsonl"
        let exporter = ConversationExporter(plan: plan([relative, nul]))
        let review = try await exporter.prepare()
        XCTAssertEqual(review.messages.map(\.status), [.unavailable, .unavailable])
        XCTAssertTrue(review.messages.allSatisfy { $0.preview.isEmpty && $0.limitations.joined().contains("aucune résolution") })
        let first = try await exporter.message(eventID: relative.id), second = try await exporter.message(eventID: nul.id)
        XCTAssertNil(first.text); XCTAssertNil(second.text)
        await exporter.dispose()
    }

    func testAtomicExportExistingFileRequiresExplicitReplaceAndPermissionsArePrivate() async throws {
        let item = try event("complete content", id: "atomic")
        let exporter = ConversationExporter(plan: plan([item]))
        _ = try await exporter.prepare()
        let destination = exports.appendingPathComponent("replace.json")
        try Data("SENTINEL".utf8).write(to: destination)
        await expectFailure { _ = try await exporter.export(to: destination, format: .json) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "SENTINEL")
        _ = try await exporter.export(to: destination, format: .json, replaceExisting: true)
        XCTAssertEqual(try json(destination)["schemaVersion"] as? Int, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: exports.path).contains { $0.hasSuffix(".partial") })
        await exporter.dispose()
    }

    func testSourcesWorktreesSymlinkAndHardlinkTargetsAreProtected() async throws {
        let item = try event("do not modify sources", id: "protection")
        let exporter = ConversationExporter(plan: plan([item]))
        _ = try await exporter.prepare()
        let original = try Data(contentsOf: URL(fileURLWithPath: item.source.path))
        await expectFailure { _ = try await exporter.export(to: URL(fileURLWithPath: item.source.path), format: .json, replaceExisting: true) }
        await expectFailure { _ = try await exporter.export(to: self.sources.appendingPathComponent("new-file.md"), format: .markdown) }
        let link = exports.appendingPathComponent("source-alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: item.source.path))
        await expectFailure { _ = try await exporter.export(to: link, format: .json, replaceExisting: true) }
        let linkedDirectory = exports.appendingPathComponent("worktree-link")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: sources)
        await expectFailure { _ = try await exporter.export(to: linkedDirectory.appendingPathComponent("new-file.json"), format: .json) }
        let safe = exports.appendingPathComponent("safe.json"), hard = exports.appendingPathComponent("hard.json")
        try Data("HARDLINK-SENTINEL".utf8).write(to: safe)
        try FileManager.default.linkItem(at: safe, to: hard)
        await expectFailure { _ = try await exporter.export(to: hard, format: .json, replaceExisting: true) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.source.path)), original)
        XCTAssertEqual(try String(contentsOf: safe, encoding: .utf8), "HARDLINK-SENTINEL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.appendingPathComponent("new-file.md").path))
        await exporter.dispose()
    }

    func testExactResourcePathProtectedOutsideWorktree() async throws {
        let item = try event("a reference", id: "resource")
        let attachment = exports.appendingPathComponent("supplied.md")
        try Data("SUPPLIED-SENTINEL".utf8).write(to: attachment)
        let resource = ResourceRecord(location: attachment.path, roles: [.supplied], eventIDs: [item.id], availability: .accessible)
        let exporter = ConversationExporter(plan: plan([item], resources: [resource]))
        _ = try await exporter.prepare()
        await expectFailure { _ = try await exporter.export(to: attachment, format: .markdown, replaceExisting: true) }
        XCTAssertEqual(try String(contentsOf: attachment, encoding: .utf8), "SUPPLIED-SENTINEL")
        await exporter.dispose()
    }

    func testCancellationBeforePrepareOrExportKeepsDestinationAndNoPartial() async throws {
        let item = try event(String(repeating: "x", count: 70000), id: "cancel")
        let exporter = ConversationExporter(plan: plan([item]))
        let preparation = Task { () throws -> ConversationReview in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await exporter.prepare()
        }
        await expectFailure { _ = try await preparation.value }
        _ = try await exporter.prepare()
        let destination = exports.appendingPathComponent("cancel.json")
        try Data("CANCEL-SENTINEL".utf8).write(to: destination)
        let export = Task { () throws -> ConversationExportReceipt in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await exporter.export(to: destination, format: .json, replaceExisting: true)
        }
        await expectFailure { _ = try await export.value }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "CANCEL-SENTINEL")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: exports.path).contains { $0.hasSuffix(".partial") })
        await exporter.dispose()
    }

    func testCancellationDuringStreamingExportRemovesPartialAndPreservesDestination() async throws {
        // Escaped controls keep the streaming writer active long enough to observe an actual
        // partial file. No latency threshold or speed assertion is used to claim performance.
        let item = try event(String(repeating: "\n", count: 2 * 1024 * 1024), id: "stream-cancel")
        let exporter = ConversationExporter(plan: plan([item]))
        _ = try await exporter.prepare()
        let destination = exports.appendingPathComponent("stream-cancel.json")
        try Data("STREAM-CANCEL-SENTINEL".utf8).write(to: destination)
        let export = Task { try await exporter.export(to: destination, format: .json, replaceExisting: true) }
        let outputDirectory = exports!
        let watcher = Task.detached { () -> Bool in
            for _ in 0..<1000 {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
                for name in names where name.hasPrefix(".codexlens-conversation-") && name.hasSuffix(".partial") {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: outputDirectory.appendingPathComponent(name).path)
                    if ((attrs?[.size] as? NSNumber)?.intValue ?? 0) > 64 * 1024 { export.cancel(); return true }
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return false
        }
        let observed = await watcher.value
        XCTAssertTrue(observed, "A real in-progress partial must be observed before cancellation")
        do { _ = try await export.value; XCTFail("Interrupted streaming export must not commit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "STREAM-CANCEL-SENTINEL")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: exports.path).contains { $0.hasSuffix(".partial") })
        await exporter.dispose()
    }

    func testOriginalWorktreeAliasRemainsProtectedAfterRepointing() async throws {
        let item = try event("frozen aliases", id: "alias-target")
        let second = directory.appendingPathComponent("second-worktree")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("current-worktree")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sources)
        let snapshot = SessionSnapshot(root: SessionSummary(id: "root"), events: [item], environments: [EnvironmentRecord(path: alias.path)])
        let exporter = ConversationExporter(plan: ConversationExportPlan(snapshot: snapshot))
        _ = try await exporter.prepare()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        await expectFailure { _ = try await exporter.export(to: self.sources.appendingPathComponent("old-target.json"), format: .json) }
        await expectFailure { _ = try await exporter.export(to: second.appendingPathComponent("new-target.json"), format: .json) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.appendingPathComponent("old-target.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("new-target.json").path))
        await exporter.dispose()
    }

    func testDisposeRemovesPrivateSpoolAndClosesCaptureWithoutDeletingExport() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("codexlens-conversation-") })
        let item = try event("PRIVATE-SPOOL-" + UUID().uuidString, id: "spool")
        let exporter = ConversationExporter(plan: plan([item]))
        _ = try await exporter.prepare()
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("codexlens-conversation-") })
        let created = after.subtracting(before)
        XCTAssertEqual(created.count, 1)
        if let name = created.first {
            let spool = temporary.appendingPathComponent(name)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: spool.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: spool.appendingPathComponent("0.txt").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let output = exports.appendingPathComponent("kept.json")
        _ = try await exporter.export(to: output, format: .json)
        await exporter.dispose()
        for name in created { XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(name).path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        await expectFailure { _ = try await exporter.message(eventID: item.id) }
        await expectFailure { _ = try await exporter.prepare() }
        await expectFailure { _ = try await exporter.export(to: self.exports.appendingPathComponent("closed.json"), format: .json) }
    }
}
