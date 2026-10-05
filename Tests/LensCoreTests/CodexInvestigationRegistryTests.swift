import Foundation
import XCTest
@testable import LensCore

final class CodexInvestigationRegistryTests: XCTestCase {
    func testConnectionProbeBeforeFirstChatCreatesPrivateStorageWithoutOwnership() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodexInvestigationRegistry(directory: directory)
        let probe = try await registry.connectionProbeDirectory()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: probe.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory).isEmpty)
        let chat = try await registry.chat(root: "observed")
        XCTAssertNil(chat.threadID)
    }
    private func temporaryDirectory() -> URL { URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("LensOwnershipTests-" + UUID().uuidString) }
    private func reject(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Unsafe ownership operation must fail", file: file, line: line) }
        catch { }
    }
    private func result<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
    private func capsule(root: String = "observed-source") throws -> EvidenceCapsule {
        let date = Date(timeIntervalSince1970: 1_790_784_000)
        return try EvidenceCapsule.build(rootThreadID: root, collectionCut: date, pieces: [EvidencePiece(id: "E001", kind: "event", title: "Recorded output", text: "Existing source evidence", sourceRefs: [], capturedAt: date)], createdAt: date)
    }
    private func rollout(_ id: String, home: URL, cwd: URL, parent: String? = nil) throws {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var payload: [String: Any] = ["id": id, "cwd": cwd.path, "cli_version": "0.159.2"]
        if let parent { payload["parent_thread_id"] = parent }
        var bytes = Data()
        let records: [[String: Any]] = [
            ["timestamp": "2026-10-03T00:00:00Z", "type": "session_meta", "payload": payload],
            ["timestamp": "2026-10-03T00:00:01Z", "type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Source from " + id]]]]
        ]
        for record in records {
            bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10)
        }
        try bytes.write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
    }

    func testPersistedChatAndBindingRestoreExactRootAndThreadWithPrivateModes() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodexInvestigationRegistry(directory: directory)
        let chat = try await registry.chat(root: "observed-source")
        XCTAssertNotNil(UUID(uuidString: chat.chatID)); XCTAssertNil(chat.threadID)
        let persistedDraft = try await CodexInvestigationRegistry(directory: directory).lookup(chatID: chat.chatID, root: "observed-source")
        XCTAssertEqual(persistedDraft, chat, "The local UUID must be durable before thread/start")
        let bound = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "created-investigation-thread")
        let restored = try await CodexInvestigationRegistry(directory: directory).lookup(chatID: chat.chatID, root: "observed-source")
        XCTAssertEqual(restored, bound)
        XCTAssertEqual(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory), ["created-investigation-thread"])
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: registry.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700); XCTAssertEqual(fileMode?.intValue, 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".partial") })
    }

    func testRootMismatchUnknownChatAndReplacementDoNotChangeOwnership() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodexInvestigationRegistry(directory: directory)
        let chat = try await registry.chat(root: "observed-source")
        _ = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "owned-thread")
        let original = try Data(contentsOf: registry.fileURL)
        await reject { _ = try await registry.lookup(chatID: chat.chatID, root: "other-source") }
        await reject { _ = try await registry.chat(root: "other-source", chatID: chat.chatID) }
        await reject { _ = try await registry.bind(chatID: UUID().uuidString, root: "observed-source", threadID: "invented-thread") }
        await reject { _ = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "replacement-thread") }
        await reject { _ = try await registry.chat(root: "owned-thread") }
        XCTAssertEqual(try Data(contentsOf: registry.fileURL), original)
        let unbound = try await registry.chat(root: "other-source")
        await reject { _ = try await registry.bind(chatID: unbound.chatID, root: "other-source", threadID: "owned-thread") }
        await reject { _ = try await registry.bind(chatID: unbound.chatID, root: "other-source", threadID: "observed-source") }
        await reject { _ = try await registry.bind(chatID: unbound.chatID, root: "other-source", threadID: "other-source") }
        XCTAssertEqual(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory), ["owned-thread"])
    }

    func testSeparateRegistryInstancesDoNotLoseConcurrentOwnershipMappings() async throws {
        // Repeat cold creation: the race only exists before the lock file appears.
        for _ in 0..<12 {
            let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            let first = CodexInvestigationRegistry(directory: directory), second = CodexInvestigationRegistry(directory: directory)
            async let firstChat = result { try await first.chat(root: "source-a") }
            async let secondChat = result { try await second.chat(root: "source-b") }
            let (firstResult, secondResult) = await (firstChat, secondChat)
            // Await both operations before propagating errors; fixture cleanup must
            // not delete a directory while the peer still holds its descriptor.
            let a = try firstResult.get(), b = try secondResult.get()
            async let firstBinding = result { try await first.bind(chatID: a.chatID, root: "source-a", threadID: "thread-a") }
            async let secondBinding = result { try await second.bind(chatID: b.chatID, root: "source-b", threadID: "thread-b") }
            let (boundA, boundB) = await (firstBinding, secondBinding)
            _ = try boundA.get(); _ = try boundB.get()
            XCTAssertEqual(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory), ["thread-a", "thread-b"])
            let restarted = CodexInvestigationRegistry(directory: directory)
            let restoredA = try await restarted.lookup(chatID: a.chatID, root: "source-a")
            let restoredB = try await restarted.lookup(chatID: b.chatID, root: "source-b")
            XCTAssertEqual(restoredA?.threadID, "thread-a"); XCTAssertEqual(restoredB?.threadID, "thread-b")
        }
    }

    func testChatAndByteQuotasRejectWithoutRotatingExistingOwnership() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodexInvestigationRegistry(directory: directory, maximumChats: 1)
        let chat = try await registry.chat(root: "observed-source")
        _ = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "owned-thread")
        let before = try Data(contentsOf: registry.fileURL)
        await reject { _ = try await registry.chat(root: "second-source") }
        XCTAssertEqual(try Data(contentsOf: registry.fileURL), before)
        XCTAssertEqual(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory), ["owned-thread"])
        let bytesDirectory = directory.appendingPathComponent("byte-quota")
        let bounded = CodexInvestigationRegistry(directory: bytesDirectory, maximumBytes: 1024)
        for n in 0..<3 { _ = try await bounded.chat(root: "source-\(n)-" + String(repeating: "a", count: 200)) }
        let bytes = try Data(contentsOf: bounded.fileURL)
        await reject { _ = try await bounded.chat(root: String(repeating: "a", count: 256)) }
        XCTAssertEqual(try Data(contentsOf: bounded.fileURL), bytes)
    }

    func testCorruptAndOversizedStorageFailClosedWithoutBeingOverwritten() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodexInvestigationRegistry(directory: directory)
        let chat = try await registry.chat(root: "observed-source")
        for content in [Data("invalid ownership JSON".utf8), Data(repeating: 65, count: 256 * 1024 + 1)] {
            try content.write(to: registry.fileURL)
            XCTAssertThrowsError(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory))
            await reject { _ = try await registry.lookup(chatID: chat.chatID, root: "observed-source") }
            await reject { _ = try await registry.chat(root: "another-source") }
            XCTAssertEqual(try Data(contentsOf: registry.fileURL), content)
        }
    }

    func testSymlinkedFileDirectoryAndWorkspaceAreRejectedWithoutReadingOrWritingTargets() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodexInvestigationRegistry(directory: directory)
        let chat = try await registry.chat(root: "observed-source")
        let target = directory.appendingPathComponent("unrelated-file")
        let content = Data("unchanged unrelated bytes".utf8); try content.write(to: target)
        try FileManager.default.removeItem(at: registry.fileURL)
        try FileManager.default.createSymbolicLink(at: registry.fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try CodexInvestigationRegistry.ownedThreadIDs(directory: directory))
        await reject { _ = try await registry.chat(root: "another-source") }
        XCTAssertEqual(try Data(contentsOf: target), content)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try CodexInvestigationRegistry.ownedThreadIDs(directory: alias))
        await reject { _ = try await CodexInvestigationRegistry(directory: alias).chat(root: "observed-source") }
        try FileManager.default.removeItem(at: registry.fileURL)
        _ = try await registry.chat(root: "observed-source", chatID: chat.chatID)
        let workspaces = CodexInvestigationRegistry.workspaceRoot(directory: directory)
        let unrelated = directory.appendingPathComponent("unrelated-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspaces, withDestinationURL: unrelated)
        await reject { _ = try await registry.workspaceDirectory(chatID: chat.chatID) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: unrelated.path).isEmpty)
    }

    func testExistingUserDirectoryPermissionsArePreservedWhileNewRegistryIsPrivate() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let privateDirectory = directory.appendingPathComponent("new-ownership", isDirectory: true)
        _ = try await CodexInvestigationRegistry(directory: privateDirectory).chat(root: "observed-source")
        let parentMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let privateMode = try FileManager.default.attributesOfItem(atPath: privateDirectory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(parentMode?.intValue, 0o755); XCTAssertEqual(privateMode?.intValue, 0o700)
        let publicRegistry = CodexInvestigationRegistry(directory: directory)
        await reject { _ = try await publicRegistry.chat(root: "another-source") }
        let unchangedMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(unchangedMode?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicRegistry.fileURL.path))
    }

    func testArchiveMappingSurvivesEditsButImportAndInferenceIDsGrantNoOwnership() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let origin = InvestigationArchive(directory: directory.appendingPathComponent("origin"))
        let localChat = UUID().uuidString
        let draft = try await origin.save(capsule: capsule(), question: "Question", inferenceIDs: ["foreign-thread"])
        let linked = try await origin.updateQuestion(id: draft.record.id, question: "Updated question", codexChatID: localChat)
        XCTAssertEqual(linked.record.codexChatID, localChat)
        let saved = try await origin.updateResponse(id: draft.record.id, response: "Answer [E001]", inferenceIDs: ["foreign-response"])
        let reloaded = try await InvestigationArchive(directory: origin.directory).load(id: saved.record.id)
        XCTAssertEqual(reloaded?.codexChatID, localChat)
        let destination = InvestigationArchive(directory: directory.appendingPathComponent("imported"))
        let originTransfer = LensArchiveTransfer(archive: origin, protectedSourceRoots: [], codexDirectories: [])
        let envelope = try await originTransfer.freeze(record: saved.record)
        let imported = try await LensArchiveTransfer(archive: destination, protectedSourceRoots: [], codexDirectories: []).import(envelope: envelope)
        XCTAssertNil(imported.record.codexChatID)
        XCTAssertEqual(imported.record.inferenceIDs, saved.record.inferenceIDs)
        let registryDirectory = directory.appendingPathComponent("ownership")
        XCTAssertTrue(try CodexInvestigationRegistry.ownedThreadIDs(directory: registryDirectory).isEmpty)
        let registry = CodexInvestigationRegistry(directory: registryDirectory)
        let lookup = try await registry.lookup(chatID: localChat, root: "observed-source")
        XCTAssertNil(lookup)
        // Legacy records omit the new optional identity and remain decodable.
        var old = try JSONSerialization.jsonObject(with: CapsuleJSON.encode(saved.record)) as! [String: Any]
        old.removeValue(forKey: "codexChatID")
        XCTAssertNil(try CapsuleJSON.decode(InvestigationRecord.self, from: JSONSerialization.data(withJSONObject: old)).codexChatID)
    }

    func testCollectorExcludesOwnedThreadsDescendantsAndPrivateUnboundCwd() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home"), registryDirectory = directory.appendingPathComponent("ownership")
        let registry = CodexInvestigationRegistry(directory: registryDirectory)
        let chat = try await registry.chat(root: "observed-source")
        _ = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "owned-thread")
        let workspace = try await registry.workspaceDirectory(chatID: chat.chatID)
        try rollout("observed-source", home: home, cwd: directory)
        try rollout("owned-thread", home: home, cwd: directory, parent: "observed-source")
        try rollout("owned-child", home: home, cwd: directory, parent: "owned-thread")
        try rollout("blank-private-thread", home: home, cwd: workspace)
        try rollout("probe-private-thread", home: home, cwd: registryDirectory.appendingPathComponent("ConnectionProbe"))
        let engine = SessionEngine(home: home, cacheDirectory: directory.appendingPathComponent("cache"), investigationRegistryDirectory: registryDirectory)
        let catalog = try await engine.catalog()
        XCTAssertEqual(catalog.map(\.id), ["observed-source"])
        let snapshot = try await engine.open(id: "observed-source")
        XCTAssertEqual(snapshot.agents.map(\.id), ["observed-source"])
        XCTAssertFalse(snapshot.events.contains { $0.agentID != "observed-source" })
        await reject { _ = try await engine.open(id: "owned-thread") }
        await reject { _ = try await engine.open(id: "owned-child") }
        let workspaceMode = try FileManager.default.attributesOfItem(atPath: workspace.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(workspaceMode?.intValue, 0o700)
    }

    func testLiveCollectorReloadsOwnershipWithoutSourceChangesAndRejectsCorruptRegistry() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home"), registryDirectory = directory.appendingPathComponent("ownership")
        try rollout("observed-source", home: home, cwd: directory)
        try rollout("late-investigation", home: home, cwd: directory, parent: "observed-source")
        let engine = SessionEngine(home: home, cacheDirectory: directory.appendingPathComponent("cache"), investigationRegistryDirectory: registryDirectory)
        let initial = try await engine.open(id: "observed-source")
        XCTAssertEqual(Set(initial.agents.map(\.id)), ["observed-source", "late-investigation"])
        let registry = CodexInvestigationRegistry(directory: registryDirectory)
        let chat = try await registry.chat(root: "observed-source")
        _ = try await registry.bind(chatID: chat.chatID, root: "observed-source", threadID: "late-investigation")
        let updated = try await engine.refresh()
        XCTAssertEqual(updated?.agents.map(\.id), ["observed-source"])
        XCTAssertFalse(updated?.events.contains { $0.agentID == "late-investigation" } ?? true)
        try Data("corrupt registry".utf8).write(to: registry.fileURL)
        await reject { _ = try await engine.refresh() }
        await reject { _ = try await engine.catalog() }
        await reject { _ = try await engine.open(id: "observed-source") }
    }
}
