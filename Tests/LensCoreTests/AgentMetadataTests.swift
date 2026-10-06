import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import LensCore

/// Invented journals and databases only. Requested settings are not runtime confirmation.
final class AgentMetadataTests: XCTestCase {
    func testSessionFieldsDecodeAllowlistedTypesAndTopLevelRoleWinsNestedRole() throws {
        let source = SourceRef(path: "/invented/rollout.jsonl", length: 321, line: 1, sha256: String(repeating: "a", count: 64))
        let fields = AgentMetadataField.sessionFields([
            "agent_role": "worker", "agent_description": "Inspect the recorded changes", "model": "recorded-model",
            "model_reasoning_effort": "high", "model_provider": "openai", "cli_version": "0.160.0",
            "source": ["subagent": ["thread_spawn": ["agent_role": "explorer"]]],
            "task_name": "not-a-session-field", "fork_context": true, "instructions": "must not become metadata",
            "base_instructions": ["text": "also not metadata"], "developer_instructions": "not metadata"
        ], source: source)
        XCTAssertEqual(Set(fields.map(\.kind)), [.role, .description, .model, .reasoningEffort, .modelProvider, .cliVersion])
        XCTAssertEqual(value(.role, fields), "worker")
        XCTAssertEqual(value(.reasoningEffort, fields), "high")
        XCTAssertTrue(fields.allSatisfy { $0.origin == .sessionMetadata && $0.source == source && $0.sourcePath == source.path && $0.eventID == nil })
        let invalid = AgentMetadataField.sessionFields(["agent_role": 7, "model": ["name": "not text"], "model_provider": true, "agent_description": " \n ", "cli_version": NSNull()], source: source)
        XCTAssertTrue(invalid.isEmpty, "Unknown shapes must not be presented as recorded string attributes")
    }

    func testNestedNativeAndPersistedRoleAliasesKeepSourceOwnership() throws {
        let source = SourceRef(path: "/invented/native.jsonl", length: 100, line: 1)
        let native: [String: Any] = ["subAgent": ["threadSpawn": ["agentRole": "explorer", "description": "not an agent description"]]]
        let nativeFields = AgentMetadataField.sessionFields(["source": native], source: source)
        XCTAssertEqual(value(.role, nativeFields), "explorer")
        XCTAssertNil(value(.description, nativeFields))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: native), as: UTF8.self)
        let persisted = AgentMetadataField.threadFields(["source": encoded], path: "/invented/state_5.sqlite")
        XCTAssertEqual(value(.role, persisted), "explorer")
        XCTAssertEqual(persisted.first?.origin, .threadMetadata)
        XCTAssertNil(persisted.first?.source, "A SQLite row is not a fabricated JSONL source range")
        XCTAssertEqual(value(.role, AgentMetadataField.threadFields(["source": encoded, "agent_role": "worker"], path: "/invented/state_5.sqlite")), "worker")
    }

    func testDelegationSettingsStayRequestedAndForkFormsDoNotInventEffectiveContext() {
        let source = SourceRef(path: "/invented/parent.jsonl", offset: 512, length: 150, line: 3)
        let fields = AgentMetadataField.delegationFields([
            "agent_type": "explorer", "agent_role": "worker", "description": "Requested scope", "model": "requested-model",
            "reasoning_effort": "medium", "task_name": "reader", "fork_context": false,
            "fork_turns": "all", "message": "Full private mission text", "base_instructions": "Not an attribute"
        ], source: source, eventID: "parent-call")
        XCTAssertEqual(value(.role, fields), "explorer")
        XCTAssertEqual(value(.forkContext, fields), "false")
        XCTAssertTrue(fields.allSatisfy { $0.origin == .delegationRequest && $0.source == source && $0.eventID == "parent-call" })
        XCTAssertFalse(AgentMetadataField.searchText(fields).contains("Full private mission text"))
        let rawTurns = AgentMetadataField.delegationFields(["fork_turns": "3"], source: source, eventID: "call")
        XCTAssertEqual(value(.forkContext, rawTurns), "3")
        XCTAssertTrue(AgentMetadataField.delegationFields(["fork_context": "true", "fork_turns": 3], source: source, eventID: "call").isEmpty)
    }

    func testLegacySummaryAndAgentCodableWithoutMetadataRemainReadable() throws {
        let summary = SessionSummary(id: "legacy", cwd: "/invented/worktree", cliVersion: "0.158.0")
        let agent = AgentRecord(id: "legacy", name: "Legacy", mission: "Recorded mission")
        var oldSummary = try object(JSONEncoder().encode(summary)); oldSummary.removeValue(forKey: "agentMetadata")
        var oldAgent = try object(JSONEncoder().encode(agent)); oldAgent.removeValue(forKey: "metadata")
        XCTAssertEqual(try JSONDecoder().decode(SessionSummary.self, from: json(oldSummary)), summary)
        XCTAssertEqual(try JSONDecoder().decode(AgentRecord.self, from: json(oldAgent)), agent)
        let field = AgentMetadataField(kind: .role, value: "worker", origin: .sessionMetadata, sourcePath: "/invented/history")
        let newer = AgentRecord(id: "new", metadata: [field])
        XCTAssertEqual(try JSONDecoder().decode(AgentRecord.self, from: JSONEncoder().encode(newer)), newer)
        XCTAssertNil(summary.agentMetadata); XCTAssertNil(agent.metadata)
    }

    func testKnownVersionHeadersKeepRoleAndModelAcrossWarmAndPersistentCatalogs() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let cases = [("0.158.0", "default"), ("0.159.2", "explorer"), ("0.160.0", "worker")]
        var originals: [URL: Data] = [:]
        for (index, entry) in cases.enumerated() {
            let path = try f.rollout(id: "version-\(index)", extras: ["cli_version": entry.0, "source": ["subagent": ["thread_spawn": ["agent_role": entry.1]]], "model": "model-\(index)", "reasoning_effort": "high"])
            originals[path] = try Data(contentsOf: path)
        }
        let engine = f.engine(), cold = try await engine.catalog(), coldReads = await engine.catalogHeaderReads
        let warm = try await engine.catalog(), warmReads = await engine.catalogHeaderReads
        XCTAssertEqual(warm, cold); XCTAssertEqual(warmReads, coldReads)
        let reopenedEngine = f.engine(), reopened = try await reopenedEngine.catalog(), reopenedReads = await reopenedEngine.catalogHeaderReads
        XCTAssertEqual(reopened, cold); XCTAssertEqual(reopenedReads, 0)
        for (index, entry) in cases.enumerated() {
            let summary = try XCTUnwrap(reopened.first { $0.id == "version-\(index)" })
            XCTAssertEqual(summary.cliVersion, entry.0)
            XCTAssertEqual(value(.role, summary.agentMetadata ?? []), entry.1)
            XCTAssertEqual(value(.model, summary.agentMetadata ?? []), "model-\(index)")
        }
        for (path, bytes) in originals { XCTAssertEqual(try Data(contentsOf: path), bytes) }
    }

    func testMetadataEditAndSourceDeletionDoNotLeaveWarmAttributesBehind() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let path = try f.rollout(id: "edit", extras: ["agent_role": "worker", "model": "model-a"])
        let engine = f.engine(), first = try await engine.catalog()
        XCTAssertEqual(value(.model, first.first?.agentMetadata ?? []), "model-a")
        try f.rollout(id: "edit", extras: ["agent_role": "explorer", "model": "model-b"])
        let changed = try await engine.catalog()
        XCTAssertEqual(value(.role, changed.first?.agentMetadata ?? []), "explorer")
        XCTAssertEqual(value(.model, changed.first?.agentMetadata ?? []), "model-b")
        try FileManager.default.removeItem(at: path)
        let removed = try await engine.catalog()
        XCTAssertTrue(removed.isEmpty)
        let newEngine = f.engine(), restarted = try await newEngine.catalog()
        XCTAssertTrue(restarted.isEmpty)
    }

    func testSQLiteSchemaFallbackAndFreshColumnsRetainDistinctRecordedSources() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let path = try f.rollout(id: "sql-child", extras: ["agent_role": "worker", "model": "header-model"])
        let db = try AgentMetadataDatabase(url: f.home.appendingPathComponent("state_5.sqlite"))
        try db.execute("CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,cwd TEXT,title TEXT,updated_at INTEGER);")
        try db.execute("INSERT INTO threads VALUES('sql-child',\(AgentMetadataDatabase.quote(path.path)),\(AgentMetadataDatabase.quote(f.first.path)),'Child',1);")
        let engine = f.engine(), legacy = try await engine.catalog()
        XCTAssertEqual(value(.role, legacy.first?.agentMetadata ?? []), "worker")
        try db.execute("ALTER TABLE threads ADD COLUMN agent_role TEXT; ALTER TABLE threads ADD COLUMN model TEXT; ALTER TABLE threads ADD COLUMN reasoning_effort TEXT; ALTER TABLE threads ADD COLUMN model_provider TEXT; ALTER TABLE threads ADD COLUMN cli_version TEXT; ALTER TABLE threads ADD COLUMN source TEXT;")
        let nested = String(decoding: try json(["subagent": ["thread_spawn": ["agent_role": "explorer"]]]), as: UTF8.self)
        try db.execute("UPDATE threads SET source=\(AgentMetadataDatabase.quote(nested)),model='database-model',reasoning_effort='low',model_provider='recorded-provider',cli_version='0.160.0';")
        let mergedCatalog = try await engine.catalog()
        let merged = try XCTUnwrap(mergedCatalog.first), fields = merged.agentMetadata ?? []
        XCTAssertEqual(fields.filter { $0.kind == .role }.count, 2)
        XCTAssertEqual(value(.role, fields, origin: .threadMetadata), "explorer")
        XCTAssertEqual(value(.role, fields, origin: .sessionMetadata), "worker")
        XCTAssertEqual(AgentMetadataField.preferredRole(in: fields)?.value, "worker")
        XCTAssertEqual(value(.model, fields, origin: .threadMetadata), "database-model")
        XCTAssertEqual(value(.model, fields, origin: .sessionMetadata), "header-model")
        let reads = await engine.catalogHeaderReads
        try db.execute("UPDATE threads SET source=NULL,model=NULL,reasoning_effort=NULL,model_provider=NULL,cli_version=NULL;")
        let cleared = try await engine.catalog(), finalReads = await engine.catalogHeaderReads
        XCTAssertEqual(finalReads, reads, "Fresh database fields should merge with unchanged immutable header cache entries")
        XCTAssertFalse((cleared.first?.agentMetadata ?? []).contains { $0.origin == .threadMetadata })
    }

    func testWALOnlyAgentAttributeUpdatePublishesRefreshWithoutJournalAppend() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        // Missing header version permits the database version fallback. No prompt or event is appended.
        let path = try f.rollout(id: AgentMetadataFixture.root, extras: ["cli_version": NSNull()])
        let originalJournal = try Data(contentsOf: path), databasePath = f.home.appendingPathComponent("state_5.sqlite")
        let db = try AgentMetadataDatabase(url: databasePath)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,cwd TEXT,title TEXT,updated_at INTEGER,agent_nickname TEXT,agent_role TEXT,agent_description TEXT,model TEXT,reasoning_effort TEXT,model_provider TEXT,cli_version TEXT);")
        try db.execute("INSERT INTO threads VALUES(\(AgentMetadataDatabase.quote(AgentMetadataFixture.root)),\(AgentMetadataDatabase.quote(path.path)),\(AgentMetadataDatabase.quote(f.first.path)),'Unchanged title',1,'Before','explorer','Before description','model-before','low','provider-before','0.158.0'); PRAGMA wal_checkpoint(TRUNCATE);")
        let originalDatabase = try Data(contentsOf: databasePath), engine = f.engine()
        let initial = try await engine.open(id: AgentMetadataFixture.root), initialReads = await engine.catalogHeaderReads
        XCTAssertEqual(initial.root.agentName, "Before")
        XCTAssertEqual(value(.role, initial.agents.first?.metadata ?? [], origin: .threadMetadata), "explorer")
        try db.execute("UPDATE threads SET agent_nickname='After',agent_role='worker',agent_description='After description',model='model-after',reasoning_effort='high',model_provider='provider-after',cli_version='0.160.1';")
        XCTAssertEqual(try Data(contentsOf: databasePath), originalDatabase, "This regression changes the live WAL, not the main database or journal")
        let update = try await engine.refresh(), refreshed = try XCTUnwrap(update)
        XCTAssertEqual(refreshed.root.id, initial.root.id); XCTAssertEqual(refreshed.root.title, initial.root.title)
        XCTAssertEqual(refreshed.root.agentName, "After"); XCTAssertEqual(refreshed.root.cliVersion, "0.160.1")
        let agent = try XCTUnwrap(refreshed.agents.first { $0.id == AgentMetadataFixture.root }), fields = agent.metadata ?? []
        XCTAssertEqual(agent.name, "After")
        XCTAssertEqual(value(.role, fields, origin: .threadMetadata), "worker")
        XCTAssertEqual(value(.description, fields, origin: .threadMetadata), "After description")
        XCTAssertEqual(value(.model, fields, origin: .threadMetadata), "model-after")
        XCTAssertEqual(value(.reasoningEffort, fields, origin: .threadMetadata), "high")
        XCTAssertEqual(value(.modelProvider, fields, origin: .threadMetadata), "provider-after")
        XCTAssertEqual(value(.cliVersion, fields, origin: .threadMetadata), "0.160.1")
        let finalReads = await engine.catalogHeaderReads
        XCTAssertEqual(finalReads, initialReads, "Metadata-only changes must continue using the unchanged validated header")
        XCTAssertEqual(try Data(contentsOf: path), originalJournal)
        let repeated = try await engine.refresh()
        XCTAssertNil(repeated, "The same metadata revision must not be published repeatedly")
        XCTAssertEqual(try Data(contentsOf: databasePath), originalDatabase)
    }

    func testExplicitChildResultLinksOnlyTheMatchingRequestedMissionAndKeepsConflict() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let parentPath = try f.rollout(id: AgentMetadataFixture.root, records: [
            f.call("other-call", ["task_name": "same-name", "message": "Other mission", "agent_type": "default", "model": "wrong-request"]),
            f.result("other-call", child: AgentMetadataFixture.other),
            f.call("right-call", ["task_name": "same-name", "message": "Inspect Beta", "agent_type": "explorer", "model": "requested-model", "reasoning_effort": "low", "fork_context": true]),
            f.result("right-call", child: AgentMetadataFixture.child)
        ])
        let childPath = try f.rollout(id: AgentMetadataFixture.child, cwd: f.second, parent: AgentMetadataFixture.root, extras: ["agent_nickname": "same-name", "agent_role": "worker", "model": "recorded-model", "reasoning_effort": "high"])
        try f.rollout(id: AgentMetadataFixture.other, cwd: f.first, parent: AgentMetadataFixture.root)
        let before = [parentPath: try Data(contentsOf: parentPath), childPath: try Data(contentsOf: childPath)]
        let snapshot = try await f.engine().open(id: AgentMetadataFixture.root)
        let child = try XCTUnwrap(snapshot.agents.first { $0.id == AgentMetadataFixture.child }), fields = child.metadata ?? []
        XCTAssertEqual(child.mission, "Inspect Beta")
        let call = try XCTUnwrap(snapshot.events.first { $0.callID == "right-call" && $0.toolName == "spawn_agent" })
        XCTAssertEqual(child.missionEventID, call.id)
        XCTAssertEqual(value(.role, fields, origin: .sessionMetadata), "worker")
        XCTAssertEqual(value(.role, fields, origin: .delegationRequest), "explorer")
        XCTAssertEqual(value(.model, fields, origin: .sessionMetadata), "recorded-model")
        XCTAssertEqual(value(.model, fields, origin: .delegationRequest), "requested-model")
        XCTAssertEqual(value(.reasoningEffort, fields, origin: .sessionMetadata), "high")
        XCTAssertEqual(value(.reasoningEffort, fields, origin: .delegationRequest), "low")
        XCTAssertFalse(fields.contains { $0.value == "wrong-request" })
        XCTAssertTrue(fields.filter { $0.origin == .delegationRequest }.allSatisfy { $0.eventID == call.id && $0.source == call.source && $0.sourcePath == parentPath.path })
        XCTAssertTrue(fields.filter { $0.origin == .sessionMetadata }.allSatisfy { $0.sourcePath == childPath.path })
        for (path, bytes) in before { XCTAssertEqual(try Data(contentsOf: path), bytes) }
    }

    func testNicknameAndTimeProximityWithoutExplicitChildResultDoNotAttachRequestedSettings() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        try f.rollout(id: AgentMetadataFixture.root, records: [f.call("ambiguous", ["task_name": "reader", "message": "Do not infer this mission", "agent_type": "explorer", "model": "not-linked"])])
        try f.rollout(id: AgentMetadataFixture.child, parent: AgentMetadataFixture.root, extras: ["agent_nickname": "reader", "agent_role": "worker"])
        let snapshot = try await f.engine().open(id: AgentMetadataFixture.root)
        let child = try XCTUnwrap(snapshot.agents.first { $0.id == AgentMetadataFixture.child })
        XCTAssertFalse((child.metadata ?? []).contains { $0.origin == .delegationRequest })
        XCTAssertFalse(child.mission.contains("Do not infer this mission")); XCTAssertNil(child.missionEventID)
        XCTAssertEqual(value(.role, child.metadata ?? []), "worker")
    }

    func testExplicitChildResultLinksRecordedRequestSettingsWithoutInventingMissingMission() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let parentPath = try f.rollout(id: AgentMetadataFixture.root, records: [
            f.call("missing-mission", ["task_name": "reader", "agent_type": "explorer", "model": "requested-but-no-mission"]),
            f.result("missing-mission", child: AgentMetadataFixture.child)
        ])
        let childPath = try f.rollout(id: AgentMetadataFixture.child, parent: AgentMetadataFixture.root, extras: ["agent_role": "worker"])
        let snapshot = try await f.engine().open(id: AgentMetadataFixture.root)
        let child = try XCTUnwrap(snapshot.agents.first { $0.id == AgentMetadataFixture.child }), fields = child.metadata ?? []
        let request = try XCTUnwrap(snapshot.events.first { $0.agentID == AgentMetadataFixture.root && $0.callID == "missing-mission" && $0.toolName == "spawn_agent" })
        let requested = fields.filter { $0.origin == .delegationRequest }
        XCTAssertEqual(Set(requested.map(\.kind)), [.role, .model, .taskName])
        XCTAssertEqual(value(.role, requested), "explorer")
        XCTAssertEqual(value(.model, requested), "requested-but-no-mission")
        XCTAssertTrue(requested.allSatisfy { $0.source == request.source && $0.sourcePath == parentPath.path && $0.eventID == request.id })
        XCTAssertEqual(request.source.line, 2)
        let recordedRole = try XCTUnwrap(fields.first { $0.kind == .role && $0.origin == .sessionMetadata })
        XCTAssertEqual(recordedRole.value, "worker"); XCTAssertEqual(recordedRole.sourcePath, childPath.path)
        XCTAssertEqual(AgentMetadataField.preferredRole(in: fields), recordedRole)
        XCTAssertNil(child.missionEventID)
        XCTAssertNil(value(.description, fields))
        XCTAssertNil(value(.model, fields, origin: .sessionMetadata))
        XCTAssertFalse(child.mission.contains("requested-but-no-mission"))
    }

    func testOpaqueMissionDoesNotBecomeDescriptionAndInstructionsRemainOpenableAtTheirSource() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        var wire = Data(repeating: 0, count: 89); wire[0] = 0x80
        let opaque = wire.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        try f.rollout(id: AgentMetadataFixture.root, records: [f.call("opaque", ["task_name": "reader", "message": opaque, "agent_type": "explorer"]), f.result("opaque", child: AgentMetadataFixture.child)])
        let marker = "Invented child instruction open only from the original source"
        let childPath = try f.rollout(id: AgentMetadataFixture.child, parent: AgentMetadataFixture.root, extras: ["base_instructions": ["text": marker]])
        let engine = f.engine(), snapshot = try await engine.open(id: AgentMetadataFixture.root)
        let child = try XCTUnwrap(snapshot.agents.first { $0.id == AgentMetadataFixture.child })
        XCTAssertTrue(child.mission.lowercased().contains("opaque"))
        XCTAssertFalse(child.mission.contains(opaque))
        XCTAssertNil(value(.description, child.metadata ?? []))
        XCTAssertFalse(AgentMetadataField.searchText(child.metadata ?? []).contains(marker))
        let instruction = try XCTUnwrap(snapshot.events.first { $0.agentID == AgentMetadataFixture.child && $0.kind == .instruction && $0.preview.contains(marker) })
        XCTAssertEqual(instruction.source.path, childPath.path); XCTAssertEqual(instruction.source.line, 1)
        let detail = try await engine.sourceDetail(for: instruction)
        XCTAssertTrue(detail.content.contains(marker))
    }

    func testCurrentConfigAndCustomAgentFileCannotFillMissingHistoricalRoleOrDescription() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let config = f.home.appendingPathComponent("config.toml"), agents = f.home.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let custom = agents.appendingPathComponent("reader.toml")
        try Data("model = \"CURRENT_CONFIG_MODEL_NOT_HISTORY\"\n[agents.reader]\ndescription = \"CURRENT_DESCRIPTION_NOT_HISTORY\"\nconfig_file = \"agents/reader.toml\"\n".utf8).write(to: config)
        try Data("model = \"CURRENT_CUSTOM_MODEL_NOT_HISTORY\"\ndeveloper_instructions = \"CURRENT_AGENT_INSTRUCTIONS_NOT_HISTORY\"\n".utf8).write(to: custom)
        let originalConfig = try Data(contentsOf: config), originalCustom = try Data(contentsOf: custom)
        try f.rollout(id: AgentMetadataFixture.root, extras: ["agent_nickname": "reader"])
        let snapshot = try await f.engine().open(id: AgentMetadataFixture.root)
        let agent = try XCTUnwrap(snapshot.agents.first { $0.id == AgentMetadataFixture.root })
        XCTAssertNil(value(.role, agent.metadata ?? [])); XCTAssertNil(value(.description, agent.metadata ?? [])); XCTAssertNil(value(.model, agent.metadata ?? []))
        XCTAssertFalse(AgentMetadataField.searchText(agent.metadata ?? []).contains("CURRENT_"))
        XCTAssertEqual(try Data(contentsOf: config), originalConfig); XCTAssertEqual(try Data(contentsOf: custom), originalCustom)
    }

    func testBoundedRedactedAttributesDoNotCopyPromptsIntoCatalogCache() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let instructionMarker = "INVENTED_INSTRUCTIONS_NOT_METADATA", secret = "sk-THISISONLYASYNTHETICKEY123456789"
        let path = try f.rollout(id: AgentMetadataFixture.root, extras: [
            "agent_role": String(repeating: "w", count: 800), "agent_description": "description \(secret) " + String(repeating: "é", count: 4000),
            "model": "model \(secret)", "base_instructions": ["text": String(repeating: instructionMarker, count: 2500)], "developer_instructions": instructionMarker
        ])
        let original = try Data(contentsOf: path), engine = f.engine(), catalog = try await engine.catalog()
        let fields = try XCTUnwrap(catalog.first?.agentMetadata)
        XCTAssertEqual(value(.role, fields)?.utf8.count, 512)
        XCTAssertLessThanOrEqual(try XCTUnwrap(value(.description, fields)).utf8.count, 4096)
        XCTAssertEqual(fields.first { $0.kind == .role }?.isTruncated, true)
        XCTAssertEqual(fields.first { $0.kind == .description }?.isTruncated, true)
        XCTAssertEqual(fields.first { $0.kind == .model }?.isTruncated, false)
        XCTAssertTrue(fields.allSatisfy { $0.value.utf8.count <= ($0.kind == .description ? 4096 : 512) })
        XCTAssertFalse(AgentMetadataField.searchText(fields).contains(secret))
        let cached = try Data(contentsOf: XCTUnwrap(f.catalogFiles().first))
        XCTAssertNil(cached.range(of: Data(instructionMarker.utf8))); XCTAssertNil(cached.range(of: Data(secret.utf8)))
        XCTAssertLessThan(cached.count, 20 * 1024)
        let bytes = await engine.catalogHeaderCacheBytes
        XCTAssertLessThan(bytes, 20 * 1024)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testOldHeaderCacheWithoutMetadataIsRejectedAndRebuilt() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        try f.rollout(id: "header-version", extras: ["agent_role": "worker", "model": "source-model"])
        _ = try await f.engine().catalog()
        let file = try XCTUnwrap(f.catalogFiles().first)
        var container = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) as? [String: Any])
        var envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: XCTUnwrap(container["payload"] as? Data), options: [], format: nil) as? [String: Any])
        envelope["version"] = 1
        var entries = try XCTUnwrap(envelope["entries"] as? [String: Any])
        for (key, raw) in entries {
            var entry = try XCTUnwrap(raw as? [String: Any]), header = try XCTUnwrap(entry["header"] as? [String: Any])
            header.removeValue(forKey: "agentMetadata"); entry["header"] = header; entries[key] = entry
        }
        envelope["entries"] = entries
        let payload = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        container["payload"] = payload; container["checksum"] = Data(SHA256.hash(data: payload))
        try PropertyListSerialization.data(fromPropertyList: container, format: .binary, options: 0).write(to: file)
        let newEngine = f.engine(), rebuilt = try await newEngine.catalog(), reads = await newEngine.catalogHeaderReads
        XCTAssertEqual(value(.role, rebuilt.first?.agentMetadata ?? []), "worker")
        XCTAssertEqual(value(.model, rebuilt.first?.agentMetadata ?? []), "source-model")
        XCTAssertEqual(reads, 1, "A valid-checksum old schema cannot silently omit new historical attributes")
    }

    func testOldEventCacheCannotOmitRequestedMetadataOnRestartAndWarmRestartPreservesIt() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        try f.rollout(id: AgentMetadataFixture.root, records: [f.call("versioned", ["message": "Inspect source", "agent_type": "explorer", "model": "requested"]), f.result("versioned", child: AgentMetadataFixture.child)])
        try f.rollout(id: AgentMetadataFixture.child, parent: AgentMetadataFixture.root, extras: ["agent_role": "worker"])
        let first = try await f.engine().open(id: AgentMetadataFixture.root)
        let expected = try XCTUnwrap(first.agents.first { $0.id == AgentMetadataFixture.child }).metadata
        let file = try XCTUnwrap(f.eventFiles().first), objectValue = try object(Data(contentsOf: file))
        var legacy = try XCTUnwrap(removingDelegationMetadata(objectValue) as? [String: Any]); legacy["version"] = 7
        try json(legacy).write(to: file)
        let restarted = try await f.engine().open(id: AgentMetadataFixture.root)
        XCTAssertEqual(try XCTUnwrap(restarted.agents.first { $0.id == AgentMetadataFixture.child }).metadata, expected)
        XCTAssertEqual(try object(Data(contentsOf: file))["version"] as? Int, 8)
        let warm = try await f.engine().open(id: AgentMetadataFixture.root)
        XCTAssertEqual(try XCTUnwrap(warm.agents.first { $0.id == AgentMetadataFixture.child }).metadata, expected)
    }

    func testSameThreadIDsInDifferentHomesKeepMetadataAndWorktreeSourceDistinct() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        let secondHome = f.base.appendingPathComponent("second-home"); try f.createSource(secondHome)
        let alpha = try f.rollout(id: AgentMetadataFixture.root, extras: ["agent_role": "worker", "model": "alpha-model"])
        let beta = try f.rollout(id: AgentMetadataFixture.root, home: secondHome, cwd: f.second, extras: ["agent_role": "explorer", "model": "beta-model"])
        let first = try await f.engine().catalog(), second = try await f.engine(home: secondHome).catalog()
        XCTAssertEqual(value(.model, first.first?.agentMetadata ?? []), "alpha-model")
        XCTAssertEqual(value(.model, second.first?.agentMetadata ?? []), "beta-model")
        XCTAssertEqual(first.first?.cwd, f.first.path); XCTAssertEqual(second.first?.cwd, f.second.path)
        XCTAssertTrue((first.first?.agentMetadata ?? []).allSatisfy { $0.sourcePath == alpha.path })
        XCTAssertTrue((second.first?.agentMetadata ?? []).allSatisfy { $0.sourcePath == beta.path })
        let warmFirst = try await f.engine().catalog()
        XCTAssertEqual(value(.role, warmFirst.first?.agentMetadata ?? []), "worker")
    }

    func testAgentSearchIncludesMetadataWithoutInventingInstructions() async throws {
        let f = try AgentMetadataFixture(); defer { f.remove() }
        try f.rollout(id: AgentMetadataFixture.root, extras: ["agent_role": "worker", "agent_description": "Unique metadata description", "model": "unique-recorded-model"])
        let snapshot = try await f.engine().open(id: AgentMetadataFixture.root), builder = SessionPresentationBuilder()
        let description = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "metadata description"))
        XCTAssertEqual(description.agentRows.map { $0.0.id }, [AgentMetadataFixture.root])
        let model = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "unique-recorded-model"))
        XCTAssertEqual(model.agentRows.map { $0.0.id }, [AgentMetadataFixture.root])
        let absent = try await builder.prepare(snapshot: snapshot, revision: 1, filters: EventFilters(), agentFilters: AgentFilters(query: "unrecorded custom instructions"))
        XCTAssertTrue(absent.agentRows.isEmpty)
    }

    private func value(_ kind: AgentMetadataField.Kind, _ fields: [AgentMetadataField], origin: AgentMetadataField.Origin? = nil) -> String? {
        fields.first { $0.kind == kind && (origin == nil || $0.origin == origin) }?.value
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func removingDelegationMetadata(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.filter { $0.key != "delegatedMetadata" }.mapValues(removingDelegationMetadata) }
        if let array = value as? [Any] { return array.map(removingDelegationMetadata) }
        return value
    }
}

private struct AgentMetadataFixture {
    static let root = "11111111-1111-4111-8111-111111111111", child = "22222222-2222-4222-8222-222222222222", other = "33333333-3333-4333-8333-333333333333"
    let base: URL, home: URL, cache: URL, registry: URL, first: URL, second: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("LensAgentMetadataTests-" + UUID().uuidString)
        home = base.appendingPathComponent("home"); cache = base.appendingPathComponent("cache"); registry = base.appendingPathComponent("ownership")
        first = base.appendingPathComponent("worktrees/alpha"); second = base.appendingPathComponent("worktrees/beta")
        try createSource(home)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    }
    func createSource(_ home: URL) throws {
        for name in ["sessions", "archived_sessions"] { try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true) }
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func engine(home override: URL? = nil) -> SessionEngine { SessionEngine(home: override ?? home, cacheDirectory: cache, investigationRegistryDirectory: registry) }
    func event(_ type: String, _ payload: [String: Any]) -> [String: Any] { ["timestamp": "2026-10-01T14:00:00.000Z", "type": type, "payload": payload] }
    func call(_ id: String, _ arguments: [String: Any]) -> [String: Any] {
        event("response_item", ["type": "function_call", "name": "spawn_agent", "namespace": "agents", "call_id": id, "arguments": arguments])
    }
    func result(_ id: String, child: String) -> [String: Any] {
        event("response_item", ["type": "function_call_output", "call_id": id, "output": "{\"agent_id\":\"\(child)\"}"])
    }
    @discardableResult func rollout(id: String, home override: URL? = nil, cwd: URL? = nil, parent: String? = nil, extras: [String: Any] = [:], records: [[String: Any]] = []) throws -> URL {
        let sourceHome = override ?? home, path = sourceHome.appendingPathComponent("sessions/rollout-" + id + ".jsonl")
        var payload: [String: Any] = ["id": id, "cwd": (cwd ?? first).path, "cli_version": "0.159.2", "source": "cli", "history_mode": "legacy"]
        if let parent { payload["parent_thread_id"] = parent }
        payload.merge(extras) { _, new in new }
        var data = Data()
        for record in [event("session_meta", payload)] + records { data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10) }
        try data.write(to: path); return path
    }
    func catalogFiles() throws -> [URL] {
        let directory = cache.appendingPathComponent("Catalog-v1")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "plist" }
    }
    func eventFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
}

private final class AgentMetadataDatabase {
    private var connection: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "AgentMetadataFixture", code: 1)
        }
    }
    deinit { if let connection { sqlite3_close(connection) } }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "AgentMetadataFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
}
