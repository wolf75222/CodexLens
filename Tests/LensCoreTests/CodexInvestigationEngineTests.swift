import XCTest
@testable import LensCore

final class CodexInvestigationEngineTests: XCTestCase {
    private func event(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func testCompletionRequiresMatchingSuccessfulTurnAndNonemptyText() throws {
        var state = CodexInvestigationTurnAccumulator(threadID: "owned", turnID: "turn")
        try state.consume(method: "item/agentMessage/delta", params: event(["threadId": "external", "turnId": "turn", "delta": "wrong"]))
        XCTAssertTrue(state.text.isEmpty)
        try state.consume(method: "item/agentMessage/delta", params: event(["threadId": "owned", "turnId": "old", "delta": "stale"]))
        XCTAssertTrue(state.text.isEmpty)
        try state.consume(method: "item/agentMessage/delta", params: event(["threadId": "owned", "turnId": "turn", "delta": "Analysis [E001]"]))
        XCTAssertFalse(state.completed) // EOF or RPC success cannot turn this into a saved answer.
        try state.consume(method: "item/completed", params: event(["threadId": "owned", "turnId": "turn", "item": ["id": "reply", "type": "agentMessage", "text": "Analysis [E001]", "phase": "final_answer"]]))
        try state.consume(method: "turn/completed", params: event(["threadId": "owned", "turn": ["id": "turn", "status": "completed", "error": NSNull()]]))
        XCTAssertTrue(state.completed)
        var empty = CodexInvestigationTurnAccumulator(threadID: "owned", turnID: "turn")
        XCTAssertThrowsError(try empty.consume(method: "turn/completed", params: event(["threadId": "owned", "turn": ["id": "turn", "status": "completed", "error": NSNull()]])))
    }
    func testExpiredQuotaAndCancellationCannotBecomeSuccessfulAnswers() throws {
        for message in ["Authentication expired", "Usage limit exceeded"] {
            var state = CodexInvestigationTurnAccumulator(threadID: "owned", turnID: "turn")
            try state.consume(method: "item/agentMessage/delta", params: event(["threadId": "owned", "turnId": "turn", "delta": "partial"]))
            XCTAssertThrowsError(try state.consume(method: "turn/completed", params: event(["threadId": "owned", "turn": ["id": "turn", "status": "failed", "error": ["message": message]]])))
            XCTAssertFalse(state.completed); XCTAssertEqual(state.text, "partial")
        }
        var state = CodexInvestigationTurnAccumulator(threadID: "owned", turnID: "turn")
        XCTAssertThrowsError(try state.consume(method: "turn/completed", params: event(["threadId": "owned", "turn": ["id": "turn", "status": "interrupted", "error": NSNull()]]))) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(CodexInvestigationFailure.terminalMessage(["codexErrorInfo": "usageLimitExceeded"]).contains("Limite Codex"))
        XCTAssertTrue(CodexInvestigationFailure.terminalMessage(["codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 401]]]).contains("expiré"))
    }
    func testFailedStatusDoesNotReuseAClosedSubprocessOnExplicitRefresh() async throws {
        let fixture = EngineConnectionFixture()
        let engine = CodexInvestigationEngine(testingConnectionFactory: { _ in try await fixture.next() })
        do { _ = try await engine.status(); XCTFail("First metadata request must fail") } catch { }
        let refreshed = try await engine.status()
        XCTAssertEqual(refreshed.authentication, "signedOut")
        let launches = await fixture.launches
        XCTAssertEqual(launches, 2)
        await engine.shutdown()
    }
    func testShutdownDuringConnectionLaunchCannotInstallALateChild() async throws {
        let fixture = EngineDelayedConnectionFixture()
        let engine = CodexInvestigationEngine(testingConnectionFactory: { _ in try await fixture.start() })
        let pending = Task { try await engine.status() }
        try await fixture.waitUntilLaunching()
        await engine.shutdown()
        await fixture.releaseLaunch()
        do { _ = try await pending.value; XCTFail("An abandoned launch must not publish an account state") }
        catch { XCTAssertTrue(error is CancellationError) }
        let capturedServer = await fixture.server
        let server = try XCTUnwrap(capturedServer)
        do { _ = try await server.request(method: "account/read"); XCTFail("The late child must be closed") }
        catch { XCTAssertEqual(error as? CodexAppServerTransportError, .transportClosed) }
        await engine.shutdown()
    }
    func testConcurrentMetadataChecksShareOneConnectionLaunch() async throws {
        let fixture = EngineDelayedConnectionFixture()
        let engine = CodexInvestigationEngine(testingConnectionFactory: { _ in try await fixture.start() })
        let first = Task { try await engine.status() }
        try await fixture.waitUntilLaunching()
        let second = Task { try await engine.status() }
        // Give the peer a chance to enter the actor while launch is suspended.
        try await Task.sleep(nanoseconds: 20_000_000)
        await fixture.releaseLaunch()
        let states = try await (first.value, second.value)
        XCTAssertEqual(states.0.authentication, "signedOut")
        XCTAssertEqual(states.1.authentication, "signedOut")
        let launches = await fixture.launches
        XCTAssertEqual(launches, 1)
        await engine.shutdown()
    }
    func testCancelledMetadataWaiterStillAllowsShutdownToCloseItsCompletedChild() async throws {
        let fixture = EngineDelayedConnectionFixture()
        let engine = CodexInvestigationEngine(testingConnectionFactory: { _ in try await fixture.start() })
        let pending = Task { try await engine.status() }
        try await fixture.waitUntilLaunching()
        pending.cancel()
        await fixture.releaseLaunch()
        do { _ = try await pending.value; XCTFail("A cancelled waiter must not publish account metadata") }
        catch { XCTAssertTrue(error is CancellationError) }
        let capturedServer = await fixture.server
        let server = try XCTUnwrap(capturedServer)
        await engine.shutdown()
        do { _ = try await server.request(method: "account/read"); XCTFail("Shutdown must close a child completed for a cancelled waiter") }
        catch { XCTAssertEqual(error as? CodexAppServerTransportError, .transportClosed) }
        await server.close()
    }
    func testCancellingOneMetadataWaiterPreservesItsNoncancelledPeer() async throws {
        let fixture = EngineDelayedConnectionFixture()
        let engine = CodexInvestigationEngine(testingConnectionFactory: { _ in try await fixture.start() })
        let first = Task { try await engine.status() }
        try await fixture.waitUntilLaunching()
        let second = Task { try await engine.status() }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        await fixture.releaseLaunch()
        do { _ = try await first.value; XCTFail("The cancelled waiter must stay cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let status = try await second.value
        XCTAssertEqual(status.authentication, "signedOut")
        let launches = await fixture.launches
        XCTAssertEqual(launches, 1)
        let fresh = try await engine.status()
        XCTAssertEqual(fresh.authentication, "signedOut")
        await engine.shutdown()
    }
    func testUnexpectedToolIsRejectedAndLongOutputIsExplicitlyRejected() throws {
        var state = CodexInvestigationTurnAccumulator(threadID: "owned", turnID: "turn")
        XCTAssertThrowsError(try state.consume(method: "item/started", params: event(["threadId": "owned", "turnId": "turn", "item": ["type": "commandExecution"]])))
        XCTAssertThrowsError(try state.consume(method: "item/agentMessage/delta", params: event(["threadId": "owned", "turnId": "turn", "delta": String(repeating: "a", count: 128 * 1024 + 1)])))
        XCTAssertThrowsError(try state.consume(method: "account/updated", params: event(["authMode": "apikey"])))
    }
    func testUnavailableCatalogueKeepsVerifiedAccountAndDoesNotSelectAModel() async throws {
        for failCatalogue in [true, false] {
            let fixture = EngineCatalogueFixture(failCatalogue: failCatalogue)
            let engine = CodexInvestigationEngine(testingConnectionFactory: { _ in try await fixture.start() })
            let status = try await engine.status()
            XCTAssertTrue(status.isChatGPT)
            XCTAssertEqual(status.email, "anonymous@example.invalid")
            XCTAssertTrue(status.models.isEmpty)
            XCTAssertNotNil(status.catalogueIssue)
            await engine.shutdown()
        }
    }
    func testServerModelReroutingDoesNotSilentlyChangeTheSelectedModel() throws {
        var state = CodexInvestigationTurnAccumulator(threadID: "owned", turnID: "turn", expectedModel: "selected")
        try state.consume(method: "model/rerouted", params: event(["threadId": "external", "turnId": "turn", "toModel": "other"]))
        XCTAssertThrowsError(try state.consume(method: "model/rerouted", params: event(["threadId": "owned", "turnId": "turn", "toModel": "other"])))
        XCTAssertFalse(state.completed)
    }
    func testPreviewIsFrozenEvidenceOnlyAndHasNoToolsOrPathsToOpen() throws {
        let capsule = try fixture()
        let data = try CodexInvestigationEngine.evidenceInput(capsule: capsule, question: "What changed?", model: "fixture-model")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "input"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1); XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertTrue((input[0]["text"] as? String)?.contains("CAPSULE JSON") == true)
        XCTAssertTrue((input[0]["text"] as? String)?.contains("oldValue") == true)
    }
    func testMissingLimitsAreUnknownNotZero() {
        XCTAssertNil(CodexInvestigationEngine.limitDescription([:]))
        XCTAssertNil(CodexInvestigationEngine.limitDescription(["rateLimits": ["primary": NSNull()]]))
        XCTAssertTrue(CodexInvestigationEngine.limitDescription(["rateLimits": ["primary": ["usedPercent": 75.0, "windowDurationMins": 300]]])?.contains("25.0%") == true)
    }
    func testCodexConversationAcceptsMessageWithoutAttachmentsButAPIRemainsExplicit() throws {
        let empty = try EvidenceCapsule.build(rootThreadID: "anonymous-conversation", collectionCut: .distantPast, pieces: [])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexInvestigationEngine.evidenceInput(
            capsule: empty, question: "  Bonjour, discutons de cette session.  ", model: "fixture-model")) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let text = try XCTUnwrap(input.first?["text"] as? String)
        XCTAssertTrue(text.hasPrefix("QUESTION\nBonjour, discutons de cette session."))
        XCTAssertTrue(text.contains("\"pieces\":[]"))
        XCTAssertEqual(Set(body.keys), ["model", "input"])
        XCTAssertThrowsError(try InvestigationClient.requestBody(capsule: empty, question: "Bonjour", model: "fixture-model"))
    }

    func testAttachmentFreeMessageRetainsRedactionAndInputBounds() throws {
        let empty = try EvidenceCapsule.build(rootThreadID: "anonymous-conversation", collectionCut: .distantPast, pieces: [])
        let bytes = try CodexInvestigationEngine.evidenceInput(capsule: empty,
            question: "api_key=sk-anonymousprivatevalue12345\nBonjour", model: "fixture-model")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("sk-anonymousprivatevalue12345"))
        for message in ["", " \n ", String(repeating: "a", count: 16_385)] {
            XCTAssertThrowsError(try CodexInvestigationEngine.evidenceInput(capsule: empty, question: message, model: "fixture-model"))
        }
        XCTAssertThrowsError(try CodexInvestigationEngine.evidenceInput(capsule: empty, question: "Bonjour", model: "invalid model"))
    }

    /// Explicit opt-in sends only fabricated messages and a fabricated patch.
    /// Reopening our exact chat after a process restart must retain conversation.
    func testLiveContinuousConversationWithoutAttachmentsThenDiff() async throws {
        guard ProcessInfo.processInfo.environment["LENS_VERIFY_LIVE_CONVERSATION"] == "1" else { throw XCTSkip("Continuous chat inference requires explicit opt-in.") }
        let registry = CodexInvestigationRegistry(), engine = CodexInvestigationEngine(registry: CodexInvestigationRegistry())
        let status = try await engine.status()
        XCTAssertTrue(status.isChatGPT)
        let model = try XCTUnwrap(status.models.first(where: { $0.isDefault })?.id ?? status.models.first?.id)
        let root = "anonymous-continuous-chat-" + UUID().uuidString
        let empty = try EvidenceCapsule.build(rootThreadID: root, collectionCut: Date(), pieces: [])
        let chat = try await registry.chat(root: root)
        let first = try await engine.answer(chatID: chat.chatID, rootID: root, capsule: empty,
            question: "Notre mot de repère pour cette conversation est tulipe-482. Réponds simplement Bonjour et ce mot.", model: model, language: .french) { _ in }
        XCTAssertTrue(first.text.contains("tulipe-482"))
        let storedBinding = try await registry.lookup(chatID: chat.chatID, root: root)
        let binding = try XCTUnwrap(storedBinding)
        let threadID = try XCTUnwrap(binding.threadID)
        await engine.shutdown()
        let restarted = CodexInvestigationEngine()
        let followup = try await restarted.answer(chatID: chat.chatID, rootID: root, capsule: empty,
            question: "Quel mot de repère t’ai-je donné dans mon message précédent ? Une seule phrase.", model: model, language: .french) { _ in }
        XCTAssertTrue(followup.text.contains("tulipe-482"))
        let attached = try EvidenceCapsule.build(rootThreadID: root, collectionCut: Date(), pieces: [
            EvidencePiece(id: "E001", kind: "recordedPatch", title: "Anonymous patch", text: "-let value = oldValue\n+let value = newValue\nPatch demandé ; résultat d’application absent.")])
        let diff = try await restarted.answer(chatID: chat.chatID, rootID: root, capsule: attached,
            question: "Merci. Maintenant explique ce diff en une phrase, cite [E001], puis rappelle notre mot de repère.", model: model, language: .french) { _ in }
        XCTAssertTrue(diff.text.contains("tulipe-482"))
        XCTAssertTrue(diff.citations.validIDs.contains("E001"))
        let after = try await registry.lookup(chatID: chat.chatID, root: root)
        XCTAssertEqual(after?.threadID, threadID)
        await restarted.shutdown()
        if let path = ProcessInfo.processInfo.environment["LENS_LIVE_RECEIPT"] {
            let receipt: [String: Any] = ["version": status.version, "model": model, "root": root,
                "chatID": chat.chatID, "threadID": threadID, "sameThreadAfterRestart": true,
                "turnIDs": [first.responseID, followup.responseID, diff.responseID],
                "answers": [first.text, followup.text, diff.text], "anonymousInputOnly": true, "attachmentsOptional": true]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
    func testThreadScopeDefaultsDoNotAdmitUnexpectedRootsOrInstructions() throws {
        let workspace = URL(fileURLWithPath: "/private/tmp/lens-owned-context")
        var scope: [String: Any] = ["activePermissionProfile": ["id": CodexInvestigationPolicy.profileName],
            "model": "fixture", "modelProvider": "openai", "cwd": workspace.path,
            "approvalPolicy": "never", "approvalsReviewer": "user", "instructionSources": [String]()]
        // runtimeWorkspaceRoots has an optional, empty default in the exact schema.
        try CodexInvestigationEngine.validateThread(scope, model: "fixture", workspace: workspace)
        scope["runtimeWorkspaceRoots"] = [String]()
        try CodexInvestigationEngine.validateThread(scope, model: "fixture", workspace: workspace)
        scope["runtimeWorkspaceRoots"] = [workspace.path]
        try CodexInvestigationEngine.validateThread(scope, model: "fixture", workspace: workspace)
        scope["runtimeWorkspaceRoots"] = ["/external/repository"]
        XCTAssertThrowsError(try CodexInvestigationEngine.validateThread(scope, model: "fixture", workspace: workspace))
        scope["runtimeWorkspaceRoots"] = [String]()
        scope["instructionSources"] = ["/external/AGENTS.md"]
        XCTAssertThrowsError(try CodexInvestigationEngine.validateThread(scope, model: "fixture", workspace: workspace))
    }
    private func fixture() throws -> EvidenceCapsule {
        let date = Date(timeIntervalSince1970: 1_790_899_200)
        return try EvidenceCapsule.build(rootThreadID: "anonymous-observed-fixture", collectionCut: date,
            pieces: [.init(id: "E001", kind: "recordedPatch", title: "Anonymous requested diff", text: "--- a/Value.swift\n+++ b/Value.swift\n@@ -1 +1 @@\n-let value = oldValue\n+let value = newValue\nPatch requested; no recorded success or full historical version.", capturedAt: date)], createdAt: date)
    }

    /// Opt-in only: this sends anonymous fixture evidence through the user's Codex plan.
    func testLivePersonalCodexDiffFollowupRestartAndCancellation() async throws {
        guard ProcessInfo.processInfo.environment["LENS_VERIFY_LIVE_CODEX"] == "1" else { throw XCTSkip("Real Codex plan requests require an explicit opt-in test invocation.") }
        // Use the production ownership registry so these test investigations
        // are excluded from ordinary session/agent collection as well.
        let registry = CodexInvestigationRegistry()
        let sentinel = URL(fileURLWithPath: "/private/tmp/CodexLens-observed-\(UUID().uuidString).swift")
        let observedBytes = Data("let value = oldValue // observed file must remain unchanged\n".utf8)
        try observedBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let engine = CodexInvestigationEngine(registry: registry)
        let status = try await engine.status()
        FileHandle.standardError.write(Data("LENS_LIVE: connection metadata read; no inference yet\n".utf8))
        XCTAssertTrue(status.isChatGPT)
        let model = try XCTUnwrap(status.models.first(where: { $0.isDefault })?.id ?? status.models.first?.id)
        let capsule = try fixture(), chat = try await registry.chat(root: capsule.rootThreadID)
        let firstStart = Date()
        let first = try await engine.answer(chatID: chat.chatID, rootID: capsule.rootThreadID, capsule: capsule, question: "Explique ce diff en deux phrases. Cite [E001] et distingue patch demandé et modification observée.", model: model, language: .french) { _ in }
        let firstDuration = Date().timeIntervalSince(firstStart)
        FileHandle.standardError.write(Data("LENS_LIVE: first diff answer completed\n".utf8))
        XCTAssertFalse(first.text.isEmpty); XCTAssertTrue(first.citations.validIDs.contains("E001"))
        let binding = try await registry.lookup(chatID: chat.chatID, root: capsule.rootThreadID)
        let thread = try XCTUnwrap(binding?.threadID)
        await engine.shutdown()
        FileHandle.standardError.write(Data("LENS_LIVE: own subprocess stopped; resuming owned investigation\n".utf8))
        let restarted = CodexInvestigationEngine(registry: CodexInvestigationRegistry())
        let followupStart = Date()
        let followup = try await restarted.answer(chatID: chat.chatID, rootID: capsule.rootThreadID, capsule: capsule, question: "Dans notre précédente réponse, quelle limite de provenance reste inconnue ? Une phrase et une citation.", model: model, language: .french) { _ in }
        XCTAssertFalse(followup.text.isEmpty)
        let followupDuration = Date().timeIntervalSince(followupStart)
        FileHandle.standardError.write(Data("LENS_LIVE: same-thread followup completed after restart\n".utf8))
        let after = try await registry.lookup(chatID: chat.chatID, root: capsule.rootThreadID)
        XCTAssertEqual(after?.threadID, thread)
        let task = Task { try await restarted.answer(chatID: chat.chatID, rootID: capsule.rootThreadID, capsule: capsule, question: "Explique très longuement chacune des implications de ce diff.", model: model, language: .french) { _ in } }
        let cancellationDeadline = Date().addingTimeInterval(40)
        while !(await restarted.hasActiveTurn), Date() < cancellationDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let acceptedTurn = await restarted.hasActiveTurn
        XCTAssertTrue(acceptedTurn, "Cancellation qualification requires an accepted turn")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation unexpectedly succeeded") } catch { }
        await restarted.shutdown()
        XCTAssertEqual(try Data(contentsOf: sentinel), observedBytes)
        let receipt: [String: Any] = ["version": status.version, "model": model, "chatID": chat.chatID, "threadID": thread, "firstTurn": first.responseID, "followupTurn": followup.responseID, "restartSameThread": true, "cancellationAfterAcceptedTurn": acceptedTurn, "observedFileUnchanged": true, "firstSeconds": firstDuration, "followupSeconds": followupDuration, "firstAnswer": first.text, "followupAnswer": followup.text]
        if let path = ProcessInfo.processInfo.environment["LENS_LIVE_RECEIPT"] { try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
    }

    /// Explicit recovery qualification targets a named locally owned chat only.
    /// It never replays a completed question after a subprocess cleanup failure.
    func testLiveResumeNamedOwnedChatAndCancelAcceptedTurn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LENS_VERIFY_LIVE_RESUME"] == "1", let chatID = environment["LENS_LIVE_CHAT_ID"] else { throw XCTSkip("Named owned-chat resume requires explicit opt-in.") }
        let registry = CodexInvestigationRegistry(), capsule = try fixture()
        let lookup = try await registry.lookup(chatID: chatID, root: capsule.rootThreadID)
        let binding = try XCTUnwrap(lookup)
        let threadID = try XCTUnwrap(binding.threadID)
        let engine = CodexInvestigationEngine(registry: registry)
        let status = try await engine.status()
        XCTAssertTrue(status.isChatGPT)
        let model = try XCTUnwrap(environment["LENS_LIVE_MODEL"])
        XCTAssertTrue(status.models.contains(where: { $0.id == model }))
        FileHandle.standardError.write(Data("LENS_LIVE: explicit owned chat ready for followup\n".utf8))
        let start = Date()
        let followup = try await engine.answer(chatID: chatID, rootID: capsule.rootThreadID, capsule: capsule, question: "Dans notre précédente réponse sur ce diff, quelle limite de provenance reste inconnue ? Une phrase et la citation [E001].", model: model, language: .french) { _ in }
        XCTAssertTrue(followup.citations.validIDs.contains("E001"))
        let duration = Date().timeIntervalSince(start)
        FileHandle.standardError.write(Data("LENS_LIVE: same-thread followup completed\n".utf8))
        let after = try await registry.lookup(chatID: chatID, root: capsule.rootThreadID)
        XCTAssertEqual(after?.threadID, threadID)
        let task = Task { try await engine.answer(chatID: chatID, rootID: capsule.rootThreadID, capsule: capsule, question: "Explique très longuement les implications de ce diff, avec de nombreux exemples.", model: model, language: .french) { _ in } }
        let deadline = Date().addingTimeInterval(40)
        while !(await engine.hasActiveTurn), Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let accepted = await engine.hasActiveTurn
        XCTAssertTrue(accepted)
        let cancelStart = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled turn unexpectedly completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        await engine.shutdown()
        let receipt: [String: Any] = ["version": status.version, "model": model, "chatID": chatID, "threadID": threadID, "followupTurn": followup.responseID, "followupAnswer": followup.text, "followupSeconds": duration, "restartSameOwnedThread": true, "firstQuestionReplayed": false, "cancellationAfterAcceptedTurn": accepted, "cancellationSeconds": Date().timeIntervalSince(cancelStart)]
        if let path = environment["LENS_LIVE_RECEIPT"] { try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
    }
}

private actor EngineConnectionFixture {
    private(set) var launches = 0
    func next() async throws -> CodexAppServerTransport {
        launches += 1
        let response = launches == 1 ? "{'error':{'code':-1,'message':'synthetic metadata failure'}}" : "{'result':{'account':None}}"
        let script = "import json,sys\nr=json.loads(sys.stdin.readline())\nv=\(response)\nv['id']=r['id']\nprint(json.dumps(v),flush=True)\nsys.stdin.read()\n"
        let transport = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script])
        try await transport.start()
        return transport
    }
}

private actor EngineDelayedConnectionFixture {
    private(set) var launches = 0
    private(set) var server: CodexAppServerTransport?
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func start() async throws -> CodexAppServerTransport {
        launches += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        let script = """
        import json,sys
        for line in sys.stdin:
            r=json.loads(line)
            print(json.dumps({'id':r['id'],'result':{'account':None}}),flush=True)
        """
        let transport = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script])
        try await transport.start()
        server = transport
        return transport
    }
    func waitUntilLaunching() async throws {
        for _ in 0..<100 {
            if launches > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LensError.unavailable("Synthetic connection never started")
    }
    func releaseLaunch() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor EngineCatalogueFixture {
    let failCatalogue: Bool
    init(failCatalogue: Bool) { self.failCatalogue = failCatalogue }
    func start() async throws -> CodexAppServerTransport {
        let catalogue = failCatalogue ? "{'error':{'code':-1,'message':'synthetic catalogue failure'}}" : "{'result':{'data':[]}}"
        let script = """
        import json,sys
        for line in sys.stdin:
            r=json.loads(line)
            if r['method']=='account/read': v={'result':{'account':{'type':'chatgpt','email':'anonymous@example.invalid'}}}
            elif r['method']=='model/list': v=\(catalogue)
            elif r['method']=='account/rateLimits/read': v={'result':{}}
            else: v={'error':{'code':-1,'message':'unexpected request'}}
            v['id']=r['id']
            print(json.dumps(v),flush=True)
        """
        let transport = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script])
        try await transport.start()
        return transport
    }
}
