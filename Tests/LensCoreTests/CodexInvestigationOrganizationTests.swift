import Foundation
import XCTest
@testable import LensCore

/// Exercises the real stdio transport against a metadata-only subprocess.
/// The fixture has no Codex credentials, provider, tools, or inference path.
final class CodexInvestigationOrganizationTests: XCTestCase {
    private let rootID = "fixture-observed-thread"
    private let firstID = "fixture-investigation-one"
    private let secondID = "fixture-investigation-two"
    private let createdSectionID = "fixture-section-created"

    func testUnknownAndObservedThreadsAreRejectedBeforeAnyRPC() async throws {
        try await withFixture { fixture in
            let owned = try await self.ownedChat(fixture, threadID: self.firstID)
            for (chatID, threadID) in [(UUID().uuidString, self.firstID), (owned.chatID, self.rootID), (owned.chatID, "unknown-thread")] {
                do {
                    try await self.prepare(fixture, chatID: chatID, threadID: threadID)
                    XCTFail("An unowned or observed thread must not be classified")
                } catch { }
            }
            XCTAssertTrue(try fixture.requests().isEmpty, "Ownership must be established before contacting Codex")
        }
    }

    func testNewOwnedChatCreatesOneSectionAndConfirmsPlacement() async throws {
        try await withFixture { fixture in
            let chat = try await self.ownedChat(fixture, threadID: self.firstID)
            try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID, isNew: true)
            let requests = try fixture.requests()
            XCTAssertEqual(requests.map(\.method), ["thread/read", "thread/name/set", "threadSection/list", "threadSection/create", "thread/section/move", "thread/read"])
            XCTAssertEqual(requests.first(where: { $0.method == "thread/section/move" })?.params["threadId"] as? String, self.firstID)
            XCTAssertEqual(requests.first(where: { $0.method == "thread/section/move" })?.params["sectionId"] as? String, self.createdSectionID)
            let remembered = try await fixture.registry.sidebarSectionID()
            XCTAssertEqual(remembered, self.createdSectionID)
            self.assertNoInferenceOrArchive(requests)
        }
    }

    func testExistingNamedSectionIsReusedAndExplicitChatTitlePreserved() async throws {
        let id = "fixture-existing-section"
        try await withFixture(options: ["sections": [["id": id, "name": CodexInvestigationOrganization.sectionName]]]) { fixture in
            let chat = try await self.ownedChat(fixture, threadID: self.firstID)
            try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID)
            let requests = try fixture.requests()
            XCTAssertFalse(requests.contains { $0.method == "threadSection/create" })
            XCTAssertFalse(requests.contains { $0.method == "thread/name/set" }, "A person's title must survive regrouping")
            XCTAssertEqual(requests.first(where: { $0.method == "thread/section/move" })?.params["sectionId"] as? String, id)
            let remembered = try await fixture.registry.sidebarSectionID()
            XCTAssertEqual(remembered, id)
            self.assertNoInferenceOrArchive(requests)
        }
    }

    func testRememberedIdentitySurvivesSectionRename() async throws {
        let rememberedID = "fixture-renamed-section"
        let otherID = "fixture-other-named-section"
        try await withFixture(options: ["sections": [["id": rememberedID, "name": "Mes enquêtes"], ["id": otherID, "name": CodexInvestigationOrganization.sectionName]]]) { fixture in
            let chat = try await self.ownedChat(fixture, threadID: self.firstID)
            try await fixture.registry.rememberSidebarSection(rememberedID)
            try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID)
            let requests = try fixture.requests()
            XCTAssertFalse(requests.contains { $0.method == "threadSection/create" })
            XCTAssertEqual(requests.first(where: { $0.method == "thread/section/move" })?.params["sectionId"] as? String, rememberedID)
            let persisted = try await CodexInvestigationRegistry(directory: fixture.registry.directory).sidebarSectionID()
            XCTAssertEqual(persisted, rememberedID)
            self.assertNoInferenceOrArchive(requests)
        }
    }

    func testPersonsCustomSectionIsKeptWithoutMovingOrCreatingAnything() async throws {
        let custom: [String: Any] = ["id": "fixture-personal-section", "name": "Mes recherches"]
        try await withFixture(options: ["currentSection": custom]) { fixture in
            let chat = try await self.ownedChat(fixture, threadID: self.firstID)
            try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID)
            let requests = try fixture.requests()
            XCTAssertEqual(requests.map(\.method), ["thread/read"])
            let remembered = try await fixture.registry.sidebarSectionID()
            XCTAssertNil(remembered, "An unrelated person's section is not the Lens default")
            self.assertNoInferenceOrArchive(requests)
        }
    }

    func testGroupingOptOutStillNamesNewChatWithoutSectionWrites() async throws {
        try await withFixture { fixture in
            let chat = try await self.ownedChat(fixture, threadID: self.firstID)
            try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID, isNew: true, group: false)
            let requests = try fixture.requests()
            XCTAssertEqual(requests.map(\.method), ["thread/read", "thread/name/set"])
            let remembered = try await fixture.registry.sidebarSectionID()
            XCTAssertNil(remembered)
            self.assertNoInferenceOrArchive(requests)
        }
    }

    func testMoveErrorOrMissingConfirmationFailsWithoutInferenceOrArchive() async throws {
        for option in ["moveError", "ignoreMove"] {
            try await withFixture(options: [option: true]) { fixture in
                let chat = try await self.ownedChat(fixture, threadID: self.firstID)
                do {
                    try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID)
                    XCTFail("A failed or unconfirmed move must not be treated as success")
                } catch { }
                let requests = try fixture.requests()
                XCTAssertEqual(requests.filter { $0.method == "thread/section/move" }.count, 1)
                let remembered = try await fixture.registry.sidebarSectionID()
                XCTAssertEqual(remembered, self.createdSectionID, "Retry must retain the created section identity")
                let stillOwned = try await fixture.registry.lookup(chatID: chat.chatID, root: self.rootID)
                XCTAssertEqual(stillOwned?.threadID, self.firstID)
                self.assertNoInferenceOrArchive(requests)
            }
        }
    }

    func testIncompletePaginationNeverCreatesASection() async throws {
        try await withFixture(options: ["paginationLoop": true]) { fixture in
            let chat = try await self.ownedChat(fixture, threadID: self.firstID)
            do {
                try await self.prepare(fixture, chatID: chat.chatID, threadID: self.firstID)
                XCTFail("Repeated cursors must fail rather than claiming all sections were searched")
            } catch { }
            let requests = try fixture.requests()
            XCTAssertEqual(requests.filter { $0.method == "threadSection/list" }.count, 2)
            XCTAssertFalse(requests.contains { $0.method == "threadSection/create" || $0.method == "thread/section/move" })
            let remembered = try await fixture.registry.sidebarSectionID()
            XCTAssertNil(remembered)
            self.assertNoInferenceOrArchive(requests)
        }
    }

    func testConcurrentChatsCoalesceSectionDiscoveryAndCreation() async throws {
        try await withFixture(options: ["listDelay": 0.08, "barrierReads": 2]) { fixture in
            let first = try await self.ownedChat(fixture, threadID: self.firstID)
            let second = try await self.ownedChat(fixture, threadID: self.secondID)
            async let firstPreparation = self.preparationResult(fixture, chatID: first.chatID, threadID: self.firstID)
            async let secondPreparation = self.preparationResult(fixture, chatID: second.chatID, threadID: self.secondID)
            // Await both, including a failed sibling, before stopping its shared subprocess.
            let results = await [firstPreparation, secondPreparation]
            for result in results { try result.get() }
            let requests = try fixture.requests()
            XCTAssertEqual(requests.filter { $0.method == "threadSection/list" }.count, 1)
            XCTAssertEqual(requests.filter { $0.method == "threadSection/create" }.count, 1)
            let moves = requests.filter { $0.method == "thread/section/move" }
            XCTAssertEqual(Set(moves.compactMap { $0.params["threadId"] as? String }), Set([self.firstID, self.secondID]))
            XCTAssertTrue(moves.allSatisfy { $0.params["sectionId"] as? String == self.createdSectionID })
            self.assertNoInferenceOrArchive(requests)
        }
    }

    private func ownedChat(_ fixture: Fixture, threadID: String) async throws -> CodexInvestigationChat {
        let chat = try await fixture.registry.chat(root: rootID)
        return try await fixture.registry.bind(chatID: chat.chatID, root: rootID, threadID: threadID)
    }

    private func prepare(_ fixture: Fixture, chatID: String, threadID: String,
                         isNew: Bool = false, group: Bool = true) async throws {
        try await CodexInvestigationOrganization.prepare(server: fixture.server, registry: fixture.registry,
            chatID: chatID, rootID: rootID, threadID: threadID, isNew: isNew, groupInSidebar: group)
    }

    private func preparationResult(_ fixture: Fixture, chatID: String, threadID: String) async -> Result<Void, Error> {
        do {
            try await prepare(fixture, chatID: chatID, threadID: threadID)
            return .success(())
        } catch { return .failure(error) }
    }

    private func assertNoInferenceOrArchive(_ requests: [Request], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(requests.contains { $0.method.hasPrefix("turn/") || ["thread/archive", "thread/unarchive", "thread/resume", "thread/interrupt"].contains($0.method) },
            "Organization must not run, resume, interrupt, or archive a session", file: file, line: line)
        XCTAssertFalse(requests.contains { $0.params["threadId"] as? String == rootID },
            "Observed sessions are never a metadata target", file: file, line: line)
    }

    private func withFixture(options: [String: Any] = [:], _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(options: options, threadIDs: [firstID, secondID], createdID: createdSectionID)
        do {
            try await fixture.server.start()
            try await body(fixture)
            await fixture.server.close()
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await fixture.server.close()
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    private struct Request {
        let method: String
        let params: [String: Any]
    }

    private final class Fixture {
        let directory: URL
        let server: CodexAppServerTransport
        let registry: CodexInvestigationRegistry
        private let log: URL

        init(options: [String: Any], threadIDs: [String], createdID: String) throws {
            directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("LensOrganizationTests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            log = directory.appendingPathComponent("requests.jsonl")
            try Data().write(to: log)
            let configURL = directory.appendingPathComponent("fixture.json")
            var config = options
            config["threadIDs"] = threadIDs
            config["createdID"] = createdID
            config["logPath"] = log.path
            try JSONSerialization.data(withJSONObject: config).write(to: configURL)
            registry = CodexInvestigationRegistry(directory: directory.appendingPathComponent("registry", isDirectory: true))
            server = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", Self.python, configURL.path], currentDirectoryURL: directory,
                environment: ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"], requestTimeoutSeconds: 3)
        }

        func requests() throws -> [Request] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { line in
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                return Request(method: try XCTUnwrap(row["method"] as? String), params: row["params"] as? [String: Any] ?? [:])
            }
        }

        private static let python = #"""
import json, sys, time
with open(sys.argv[1], encoding='utf-8') as f:
    config = json.load(f)
sections = config.get('sections', [])
threads = {identity: {'id': identity, 'name': 'Personal title', 'section': config.get('currentSection')} for identity in config['threadIDs']}
initial_reads = []
for line in sys.stdin:
    request = json.loads(line)
    method, params = request['method'], request.get('params', {})
    with open(config['logPath'], 'a', encoding='utf-8') as log:
        log.write(json.dumps({'method': method, 'params': params})+'\n')
        log.flush()
    result = {}
    error = None
    if method == 'thread/read':
        if len(initial_reads) < config.get('barrierReads', 0):
            initial_reads.append(request)
            if len(initial_reads) < config['barrierReads']:
                continue
            for previous in initial_reads[:-1]:
                print(json.dumps({'id': previous['id'], 'result': {'thread': threads[previous['params']['threadId']]}}), flush=True)
        result = {'thread': threads[params['threadId']]}
    elif method == 'thread/name/set':
        threads[params['threadId']]['name'] = params['name']
    elif method == 'threadSection/list':
        time.sleep(config.get('listDelay', 0))
        result = {'data': sections, 'nextCursor': 'repeated-cursor' if config.get('paginationLoop') else None}
    elif method == 'threadSection/create':
        section = {'id': config['createdID'], 'name': params['name'], 'appearance': None}
        sections.append(section)
        result = {'section': section}
    elif method == 'thread/section/move':
        if config.get('moveError'):
            error = {'code': -32000, 'message': 'Anonymous fixture move failure'}
        elif not config.get('ignoreMove'):
            threads[params['threadId']]['section'] = next(section for section in sections if section['id']==params['sectionId'])
    else:
        error = {'code': -32601, 'message': 'This metadata fixture has no inference or archive operation'}
    response = {'id': request['id'], 'error': error} if error else {'id': request['id'], 'result': result}
    print(json.dumps(response), flush=True)
"""#
    }
}
