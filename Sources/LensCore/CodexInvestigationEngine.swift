import Foundation

/// Capability metadata returned by the installed Codex model catalogue.
/// Effort IDs are extensible protocol strings, rather than a fixed client enum.
public struct CodexLocalReasoningEffort: Sendable, Equatable, Identifiable {
    public let id: String
    public let description: String
    public init(id: String, description: String) { self.id = id; self.description = description }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
    }
}

public struct CodexLocalModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let supportedReasoningEfforts: [CodexLocalReasoningEffort]
    /// Only retained when the catalogue also advertises this effort as supported.
    public let defaultReasoningEffort: String?
    public init(id: String, displayName: String, isDefault: Bool,
                supportedReasoningEfforts: [CodexLocalReasoningEffort] = [], defaultReasoningEffort: String? = nil) {
        self.id = id; self.displayName = displayName; self.isDefault = isDefault
        var seen = Set<String>()
        let efforts = supportedReasoningEfforts.prefix(64).filter {
            CodexLocalReasoningEffort.isValidID($0.id) && seen.insert($0.id).inserted
        }
        self.supportedReasoningEfforts = efforts
        self.defaultReasoningEffort = defaultReasoningEffort.flatMap { value in
            efforts.contains(where: { $0.id == value }) ? value : nil
        }
    }
}

public struct CodexLocalConnectionStatus: Sendable, Equatable {
    public let version: String
    public let executable: String
    public let authentication: String
    public let email: String?
    public let plan: String?
    public let models: [CodexLocalModel]
    /// Public limit metadata only. This contains neither tokens nor credential data.
    public let limits: String?
    /// A catalogue failure does not erase the independently verified account state.
    public let catalogueIssue: String?
    public init(version: String, executable: String, authentication: String, email: String?, plan: String?, models: [CodexLocalModel], limits: String?, catalogueIssue: String? = nil) {
        self.version = version; self.executable = executable; self.authentication = authentication; self.email = email
        self.plan = plan; self.models = models; self.limits = limits
        self.catalogueIssue = catalogueIssue
    }
    public var isChatGPT: Bool { authentication == "chatgpt" }
}

/// A turn is successful only after its matching completed terminal notification.
/// Delta text remains provisional; neither EOF nor a successful RPC acknowledges inference.
public struct CodexInvestigationTurnAccumulator: Sendable {
    public let threadID: String
    public let expectedModel: String?
    public var turnID: String?
    public private(set) var text = ""
    public private(set) var completed = false
    private var finalMessages: [String: String] = [:]
    private var messageOrder: [String] = []
    private let maximumTextBytes = 128 * 1024
    public init(threadID: String, turnID: String? = nil, expectedModel: String? = nil) { self.threadID = threadID; self.turnID = turnID; self.expectedModel = expectedModel }
    public mutating func consume(method: String, params: Data?) throws {
        guard let params, let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else { return }
        if method == "account/updated", object["authMode"] as? String != "chatgpt" {
            throw LensError.unavailable("La connexion Codex a changé ; enquête arrêtée sans basculement vers une clé API.")
        }
        guard object["threadId"] as? String == threadID else { return }
        let receivedTurn = object["turnId"] as? String ?? (object["turn"] as? [String: Any])?["id"] as? String
        if let receivedTurn, let turnID, receivedTurn != turnID { return }
        if turnID == nil, let receivedTurn { turnID = receivedTurn }
        if method == "model/rerouted", let expectedModel, object["toModel"] as? String != expectedModel {
            throw LensError.unavailable("Le service Codex a changé de modèle ; réception arrêtée sans accepter une réponse de remplacement. Le brouillon est conservé.")
        }
        if method == "item/agentMessage/delta", let delta = object["delta"] as? String {
            guard text.utf8.count + delta.utf8.count <= maximumTextBytes else { throw LensError.unsupported("Réponse supérieure à 128 Kio ; réception arrêtée sans troncature silencieuse.") }
            text += delta
        } else if method == "item/started" || method == "item/completed", let item = object["item"] as? [String: Any], let type = item["type"] as? String {
            guard ["userMessage", "agentMessage", "reasoning", "plan", "contextCompaction"].contains(type) else { throw LensError.unsupported("Un outil inattendu a été annoncé ; enquête arrêtée : \(type).") }
            if method == "item/completed", type == "agentMessage", let value = item["text"] as? String, let id = item["id"] as? String {
                try recordFinal(id: id, value: value, phase: item["phase"] as? String)
            }
        } else if method == "turn/completed", let turn = object["turn"] as? [String: Any] {
            guard let id = turn["id"] as? String, id == turnID else { return }
            guard turn["status"] as? String == "completed", turn["error"] == nil || turn["error"] is NSNull else {
                if turn["status"] as? String == "interrupted" { throw CancellationError() }
                let error = turn["error"] as? [String: Any]
                throw LensError.unavailable(CodexInvestigationFailure.terminalMessage(error ?? [:]))
            }
            for item in turn["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "agentMessage" {
                if let value = item["text"] as? String, let id = item["id"] as? String { try recordFinal(id: id, value: value, phase: item["phase"] as? String) }
            }
            guard !finalMessages.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LensError.unavailable("Tour terminé sans message final enregistré ; aucun résultat d’analyse sauvegardé.") }
            completed = true
        }
    }
    private mutating func recordFinal(id: String, value: String, phase: String?) throws {
        guard phase == nil || phase == "final_answer" else { return }
        if finalMessages[id] == nil { messageOrder.append(id) }; finalMessages[id] = value
        let full = messageOrder.compactMap { finalMessages[$0] }.joined(separator: "\n\n")
        guard full.utf8.count <= maximumTextBytes else { throw LensError.unsupported("Réponse supérieure à 128 Kio.") }
        text = full
    }
}

/// Personal local authentication stays inside Codex. Lens only consumes account metadata.
/// All target IDs come from its private ownership registry, never from observed sessions.
public actor CodexInvestigationEngine {
    private struct Connection: Sendable {
        let server: CodexAppServerTransport
        let workspace: URL?
        let executable: URL
        let version: String
    }
    private struct ConnectionFlight {
        let id: UUID
        let requestedWorkspace: URL?
        let task: Task<Connection, Error>
    }
    private let registry: CodexInvestigationRegistry
    private let testingConnectionFactory: (@Sendable (URL?) async throws -> CodexAppServerTransport)?
    private var transport: CodexAppServerTransport?
    private var workspace: URL?
    private var loadedThread: String?
    private var activeThread: String?
    private var activeTurn: String?
    private var busy = false
    private var activeOperation: UUID?
    private var version = ""
    private var executable = URL(fileURLWithPath: "/nonexistent")
    private var preferredExecutable: URL?
    private var connectionFlight: ConnectionFlight?
    public func useExecutable(_ url: URL?) async throws {
        guard !busy else { throw LensError.unavailable("Une requête est en cours ; attendez sa fin pour changer de binaire Codex.") }
        if preferredExecutable != url { preferredExecutable = url; await shutdown() }
    }
    // Used by the opt-in cancellation qualification to wait for an accepted
    // turn instead of cancelling arbitrarily during authentication/preflight.
    var hasActiveTurn: Bool { activeTurn != nil }
    public init(registry: CodexInvestigationRegistry = CodexInvestigationRegistry()) { self.registry = registry; testingConnectionFactory = nil }
    init(registry: CodexInvestigationRegistry = CodexInvestigationRegistry(), testingConnectionFactory: @escaping @Sendable (URL?) async throws -> CodexAppServerTransport) {
        self.registry = registry; self.testingConnectionFactory = testingConnectionFactory
    }
    public func chat(rootID: String, chatID: String? = nil) async throws -> CodexInvestigationChat { try await registry.chat(root: rootID, chatID: chatID) }

    public static func evidenceInput(capsule: EvidenceCapsule, question: String, model: String, reasoningEffort: String? = nil) throws -> Data {
        let text = try InvestigationClient.selectedInputText(capsule: capsule, question: question, model: model, allowEmptyContext: true)
        var body: [String: Any] = ["model": model, "input": [["type": "text", "text": text]]]
        if let reasoningEffort {
            guard CodexLocalReasoningEffort.isValidID(reasoningEffort) else { throw LensError.unsupported("Effort de raisonnement Codex invalide ; aucun envoi effectué.") }
            body["effort"] = reasoningEffort
        }
        // Omission preserves the legacy Codex configuration. It does not reset
        // an earlier override: callers must send an advertised default explicitly.
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 384 * 1024 else { throw LensError.unsupported("Requête supérieure à 384 Kio ; envoi refusé.") }
        return data
    }

    public func status() async throws -> CodexLocalConnectionStatus {
        let span = LensSignposts.begin("CodexConnection"); defer { span.end() }
        guard !busy else { throw LensError.unavailable("Une requête est en cours ; attendez sa fin pour actualiser la connexion.") }
        var requestedServer: CodexAppServerTransport?
        do {
            let server = try await connected(workspace: nil)
            requestedServer = server
            return try await readStatus(server, refresh: false)
        } catch {
            // An old metadata request must never close a replacement child.
            if let requestedServer {
                if transport === requestedServer { await shutdown() }
                else { await requestedServer.close() }
            }
            throw error
        }
    }

    public func answer(chatID: String, rootID: String, capsule: EvidenceCapsule, question: String, model: String, reasoningEffort: String? = nil, language: CodexInvestigationLanguage, groupInSidebar: Bool = true, metadata: @escaping @Sendable (CodexLocalConnectionStatus?) async -> Void = { _ in }, progress: @escaping @Sendable (String) async -> Void) async throws -> InvestigationAnswer {
        let span = LensSignposts.begin("CodexInvestigationTurn"); defer { span.end() }
        guard !busy else { throw LensError.unavailable("Une requête est déjà en cours. Aucun envoi supplémentaire n’a été effectué.") }
        busy = true
        let operation = UUID(); activeOperation = operation
        defer { busy = false; if activeOperation == operation { activeOperation = nil; activeThread = nil; activeTurn = nil } }
        do {
            return try await performAnswer(chatID: chatID, rootID: rootID, capsule: capsule, question: question, model: model, reasoningEffort: reasoningEffort, language: language, groupInSidebar: groupInSidebar, operation: operation, metadata: metadata, progress: progress)
        } catch {
            // Includes auth/config/thread preflight and idle EOF failures. Never
            // cache a dead child or retry an ambiguously accepted inference.
            await stopActive(operation: operation)
            await metadata(nil)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func performAnswer(chatID: String, rootID: String, capsule: EvidenceCapsule, question: String, model: String, reasoningEffort: String?, language: CodexInvestigationLanguage, groupInSidebar: Bool, operation: UUID, metadata: @escaping @Sendable (CodexLocalConnectionStatus?) async -> Void, progress: @escaping @Sendable (String) async -> Void) async throws -> InvestigationAnswer {
        let input = try Self.evidenceInput(capsule: capsule, question: question, model: model, reasoningEffort: reasoningEffort)
        guard capsule.rootThreadID == rootID, let chat = try await registry.lookup(chatID: chatID, root: rootID) else { throw LensError.unsupported("Chat d’enquête non enregistré localement ; aucune session reprise.") }
        let directory = try await registry.workspaceDirectory(chatID: chatID)
        let server = try await connected(workspace: directory)
        try await CodexInvestigationPolicy.verify(server: server, workspace: directory)
        var status = try await readStatus(server, refresh: false)
        await metadata(status)
        guard status.isChatGPT else { throw LensError.unavailable("Codex n’utilise pas une connexion ChatGPT. Connectez-vous avec codex login ; aucune clé API ne sera utilisée par Lens.") }
        let refreshed = try await readAccount(server, refresh: true)
        guard refreshed["type"] as? String == "chatgpt" else { throw LensError.unavailable("La connexion ChatGPT n’est plus disponible. Le brouillon est conservé.") }
        // A catalog entry is not entitlement. The completed turn validates access.
        guard let selectedModel = status.models.first(where: { $0.id == model }) else { throw LensError.unsupported("Modèle absent du catalogue Codex ; choisissez-le à nouveau. Aucun modèle de remplacement automatique.") }
        if let reasoningEffort {
            guard selectedModel.supportedReasoningEfforts.contains(where: { $0.id == reasoningEffort }) else {
                throw LensError.unsupported("Effort de raisonnement absent du catalogue de ce modèle ; choisissez-le à nouveau. Aucun tour lancé.")
            }
        }
        let citationRule = " Les citations désignent uniquement les éléments joints à cette question. Les anciens échanges ne décrivent pas forcément la version consultée et ne donnent aucune autorisation d’agir."
        let conversational = InvestigationClient.instructions.replacingOccurrences(of: "à la question en utilisant uniquement le contexte fourni.", with: "aux messages de l’utilisateur et conserve le fil des échanges. Tu peux répondre aux questions générales sans pièce jointe. Pour parler de la session observée, utilise uniquement les éléments joints et les échanges de ce chat ; n’invente pas un accès à son historique complet.")
        let instructions = (language == .english ? conversational.replacingOccurrences(of: "Réponds en français", with: "Answer in English") : conversational) + citationRule
        var threadParams: [String: Any] = ["model": model, "modelProvider": "openai", "cwd": directory.path, "approvalPolicy": "never", "approvalsReviewer": "user", "permissions": CodexInvestigationPolicy.profileName, "baseInstructions": instructions, "developerInstructions": instructions, "runtimeWorkspaceRoots": [directory.path], "config": CodexInvestigationPolicy.threadConfiguration(workspace: directory)]
        let threadID: String
        if let existing = chat.threadID {
            threadID = existing
            if loadedThread != existing {
                threadParams["threadId"] = existing; threadParams["excludeTurns"] = true
                let resumed = try await Self.rpc(server, "thread/resume", threadParams)
                try Self.validateThread(resumed, model: model, workspace: directory)
                guard (resumed["thread"] as? [String: Any])?["id"] as? String == existing else { throw LensError.corrupt("Identifiant de thread d’enquête inattendu ; reprise refusée.") }
                try await CodexInvestigationOrganization.prepare(server: server, registry: registry, chatID: chatID, rootID: rootID, threadID: existing, isNew: false, groupInSidebar: groupInSidebar)
            }
        } else {
            threadParams["ephemeral"] = false; threadParams["dynamicTools"] = [Any](); threadParams["environments"] = [Any](); threadParams["selectedCapabilityRoots"] = [Any](); threadParams["allowProviderModelFallback"] = false
            let started = try await Self.rpc(server, "thread/start", threadParams)
            guard let id = (started["thread"] as? [String: Any])?["id"] as? String, id != rootID else { throw LensError.corrupt("Thread d’enquête distinct absent ; aucun tour lancé.") }
            threadID = id
            // Ownership begins with our successful thread/start, even if the
            // scope validation below rejects the empty thread before inference.
            _ = try await registry.bind(chatID: chatID, root: rootID, threadID: id)
            try Self.validateThread(started, model: model, workspace: directory)
            try await CodexInvestigationOrganization.prepare(server: server, registry: registry, chatID: chatID, rootID: rootID, threadID: id, isNew: true, groupInSidebar: groupInSidebar)
        }
        loadedThread = threadID; activeThread = threadID
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000); await self?.stopActive(operation: operation) } catch { }
        }
        defer { deadline.cancel() }
        var turnParams = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        turnParams["threadId"] = threadID; turnParams["cwd"] = directory.path; turnParams["permissions"] = CodexInvestigationPolicy.profileName; turnParams["approvalPolicy"] = "never"; turnParams["approvalsReviewer"] = "user"; turnParams["runtimeWorkspaceRoots"] = [directory.path]; turnParams["environments"] = [Any]()
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                let started = try await Self.rpc(server, "turn/start", turnParams)
                guard let id = (started["turn"] as? [String: Any])?["id"] as? String else { throw LensError.corrupt("Tour d’enquête sans identifiant.") }
                activeTurn = id
                var accumulator = CodexInvestigationTurnAccumulator(threadID: threadID, turnID: id, expectedModel: model)
                var lastPublish = Date.distantPast
                for try await event in server.notifications {
                    try Task.checkCancellation()
                    if event.method == "account/rateLimits/updated", let data = event.params,
                       let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        status = CodexLocalConnectionStatus(version: status.version, executable: status.executable, authentication: status.authentication, email: status.email, plan: status.plan, models: status.models, limits: Self.limitDescription(object))
                        await metadata(status)
                    }
                    try accumulator.consume(method: event.method, params: event.params)
                    if Date().timeIntervalSince(lastPublish) >= 0.1 || accumulator.completed { await progress(accumulator.text); lastPublish = Date() }
                    if accumulator.completed {
                        return InvestigationAnswer(text: accumulator.text, responseID: id, model: model, citations: capsule.validateCitations(in: accumulator.text))
                    }
                }
                throw LensError.unavailable("Le flux Codex s’est fermé avant la fin du tour ; le texte partiel n’est pas une réponse réussie.")
            } catch {
                await stopActive(operation: operation)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }, onCancel: { Task { await self.stopActive(operation: operation) } })
    }

    public func shutdown() async { await stopActive() }
    private func stopActive(operation: UUID? = nil) async {
        if let operation, activeOperation != operation { return }
        let server = transport, thread = activeThread, turn = activeTurn
        connectionFlight?.task.cancel()
        connectionFlight = nil
        // Detach before the RPC suspension. Repeated callbacks for an old turn
        // can only close this captured child, never a newly connected one.
        transport = nil; loadedThread = nil; workspace = nil; activeThread = nil; activeTurn = nil
        if let server, let thread, let turn {
            _ = try? await server.request(method: "turn/interrupt", params: JSONSerialization.data(withJSONObject: ["threadId": thread, "turnId": turn]), timeoutSeconds: 3)
        }
        // Closing our own child also resolves cancellation while turn/start is pending.
        if let server { await server.close() }
    }
    private func connected(workspace requested: URL?) async throws -> CodexAppServerTransport {
        try Task.checkCancellation()
        if let transport, requested == nil || workspace == requested { return transport }
        if let flight = connectionFlight, requested == nil || flight.requestedWorkspace == requested {
            return try await finishConnection(flight)
        }
        await shutdown()
        try Task.checkCancellation()
        // Closing a previous child suspends this actor. A peer may have opened
        // the requested connection in the meantime; share it rather than launch again.
        if transport != nil || connectionFlight != nil { return try await connected(workspace: requested) }
        let registry = registry, preferred = preferredExecutable, factory = testingConnectionFactory
        let flight = ConnectionFlight(id: UUID(), requestedWorkspace: requested, task: Task {
            try await Self.createConnection(workspace: requested, registry: registry, preferred: preferred, testingFactory: factory)
        })
        connectionFlight = flight
        return try await finishConnection(flight)
    }
    private func finishConnection(_ flight: ConnectionFlight) async throws -> CodexAppServerTransport {
        let connection: Connection
        do { connection = try await flight.task.value }
        catch {
            if connectionFlight?.id == flight.id { connectionFlight = nil }
            throw error
        }
        if connectionFlight?.id == flight.id {
            connectionFlight = nil
            transport = connection.server; workspace = connection.workspace
            executable = connection.executable; version = connection.version
        } else if transport !== connection.server {
            // Shutdown or a different workspace superseded this launch while it
            // awaited I/O. Never install its result after that ownership was revoked.
            await connection.server.close()
            throw CancellationError()
        }
        // Own a completed child before honoring this waiter's cancellation:
        // shutdown can then close it, and a noncancelled peer can still use it.
        try Task.checkCancellation()
        return connection.server
    }
    private static func createConnection(workspace requested: URL?, registry: CodexInvestigationRegistry, preferred: URL?, testingFactory: (@Sendable (URL?) async throws -> CodexAppServerTransport)?) async throws -> Connection {
        try Task.checkCancellation()
        if let testingFactory {
            let server = try await testingFactory(requested)
            do { try Task.checkCancellation() }
            catch { await server.close(); throw error }
            return Connection(server: server, workspace: requested, executable: URL(fileURLWithPath: "/nonexistent"), version: "")
        }
        let executable = try await CodexInstallation.qualifiedExecutable(preferred: preferred)
        let version = try await CodexInvestigationPolicy.version(executable: executable)
        let directory: URL
        if let requested { directory = requested } else { directory = try await registry.connectionProbeDirectory() }
        try Task.checkCancellation()
        let server = try await CodexInvestigationPolicy.launch(executable: executable, version: version, workspace: directory)
        do {
            try Task.checkCancellation()
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            _ = try await rpc(server, "initialize", ["clientInfo": ["name": "codex_lens", "title": "Codex Lens", "version": appVersion], "capabilities": ["experimentalApi": true]])
            try await server.notify(method: "initialized")
            try await CodexInvestigationPolicy.verify(server: server, workspace: directory)
            try Task.checkCancellation()
        } catch { await server.close(); throw error }
        return Connection(server: server, workspace: directory, executable: executable, version: version)
    }
    private func readAccount(_ server: CodexAppServerTransport, refresh: Bool) async throws -> [String: Any] {
        let result = try await Self.rpc(server, "account/read", ["refreshToken": refresh])
        return result["account"] as? [String: Any] ?? ["type": "signedOut"]
    }
    private func readStatus(_ server: CodexAppServerTransport, refresh: Bool) async throws -> CodexLocalConnectionStatus {
        let account = try await readAccount(server, refresh: refresh)
        var models: [CodexLocalModel] = []
        var limits: String?
        var catalogueIssue: String?
        if account["type"] as? String == "chatgpt" {
            do {
                let catalogue = try await Self.rpc(server, "model/list", ["includeHidden": false, "limit": 100])
                models = Self.localModels(from: catalogue)
                if models.isEmpty { catalogueIssue = "Connexion ChatGPT vérifiée ; aucun modèle disponible dans le catalogue. Actualisez la connexion avant l’envoi." }
            } catch {
                try Task.checkCancellation()
                catalogueIssue = "Connexion ChatGPT vérifiée ; le catalogue des modèles est indisponible. Actualisez la connexion avant l’envoi."
            }
            if let result = try? await Self.rpc(server, "account/rateLimits/read", nil) { limits = Self.limitDescription(result) }
        }
        try Task.checkCancellation()
        return CodexLocalConnectionStatus(version: version, executable: executable.path, authentication: account["type"] as? String ?? "unknown", email: account["email"] as? String, plan: account["planType"] as? String, models: models, limits: limits, catalogueIssue: catalogueIssue)
    }
    static func localModels(from catalogue: [String: Any]) -> [CodexLocalModel] {
        (catalogue["data"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["model"] as? String ?? row["id"] as? String, !id.isEmpty else { return nil }
            let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).prefix(64).compactMap { option -> CodexLocalReasoningEffort? in
                guard let value = option["reasoningEffort"] as? String, CodexLocalReasoningEffort.isValidID(value) else { return nil }
                return CodexLocalReasoningEffort(id: value, description: String((option["description"] as? String ?? "").prefix(2048)))
            }
            return CodexLocalModel(id: id, displayName: row["displayName"] as? String ?? id, isDefault: row["isDefault"] as? Bool == true,
                                   supportedReasoningEfforts: efforts, defaultReasoningEffort: row["defaultReasoningEffort"] as? String)
        }
    }
    public static func limitDescription(_ result: [String: Any]) -> String? {
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let rows = buckets?.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) } ?? ((result["rateLimits"] as? [String: Any]).map { [("Codex", $0)] } ?? [])
        var lines: [String] = []
        for (name, row) in rows {
            for key in ["primary", "secondary"] {
                guard let window = row[key] as? [String: Any], let used = window["usedPercent"] as? Double else { continue }
                var text = "\(name) · \(max(0, min(100, 100-used)).rounded())%"
                if let minutes = window["windowDurationMins"] as? Int { text += " · \(minutes) min" }
                if let reset = window["resetsAt"] as? Double { text += " · ↻ " + Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened) }
                lines.append(text)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    private static func rpc(_ server: CodexAppServerTransport, _ method: String, _ object: [String: Any]?) async throws -> [String: Any] {
        let data: Data
        do { data = try await server.request(method: method, params: object.map { try JSONSerialization.data(withJSONObject: $0) }) }
        catch let CodexAppServerTransportError.rpc(code, message) { throw LensError.unavailable(CodexInvestigationFailure.message(message, code: String(code))) }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LensError.corrupt("Réponse App Server invalide : \(method).") }
        return result
    }
    static func validateThread(_ result: [String: Any], model: String, workspace: URL) throws {
        let profile = result["activePermissionProfile"] as? [String: Any]
        let sources = result["instructionSources"] as? [String]
        let checks = [
            "activePermissionProfile.id": profile?["id"] as? String == CodexInvestigationPolicy.profileName,
            "activePermissionProfile.extends": profile?["extends"] == nil || profile?["extends"] is NSNull,
            "model": result["model"] as? String == model,
            "modelProvider": result["modelProvider"] as? String == "openai",
            "cwd": result["cwd"] as? String == workspace.path,
            "approvalPolicy": result["approvalPolicy"] as? String == "never",
            "approvalsReviewer": result["approvalsReviewer"] as? String == "user",
            // Creation with environments=[] may serialize [] (or omit the
            // default); resume also restores our explicitly requested private
            // root. Neither case grants a production repository or extends the
            // named profile. Any other root or value type is rejected.
            "runtimeWorkspaceRoots": result["runtimeWorkspaceRoots"] == nil || result["runtimeWorkspaceRoots"] as? [String] == [] || result["runtimeWorkspaceRoots"] as? [String] == [workspace.path],
            "instructionSources": sources?.allSatisfy({ $0 == workspace.appendingPathComponent("lens-context-instructions.txt").path }) == true
        ]
        let failed = checks.filter { !$0.value }.map(\.key).sorted()
        guard failed.isEmpty else { throw LensError.unsupported("Périmètre du thread Codex non vérifié : \(failed.joined(separator: ", ")). Aucun tour lancé.") }
    }
}

/// Backend diagnostics are classified without copying raw authentication payloads
/// or provider messages into Lens' archive, UI, or system logs.
enum CodexInvestigationFailure {
    static func terminalMessage(_ error: [String: Any]) -> String {
        let info = error["codexErrorInfo"]
        var code = info as? String
        if let variant = info as? [String: Any], let name = variant.keys.sorted().first {
            code = name
            if let value = variant[name] as? [String: Any], let status = value["httpStatusCode"] as? Int { code = String(status) }
        }
        return message(error["message"] as? String ?? "", code: code)
    }
    static func message(_ raw: String, code: String? = nil) -> String {
        let value = (EvidenceRedaction.utf8Prefix(raw, limit: 8_192) + " " + (code ?? "")).lowercased()
        if value.contains("rate") && value.contains("limit") || value.contains("quota") || value.contains("usage limit") || value.contains("usagelimitexceeded") || code == "429" {
            return "Limite Codex atteinte. Le brouillon est conservé ; aucun nouvel envoi automatique. Consultez les limites du compte."
        }
        if value.contains("auth") || value.contains("expired") || value.contains("unauthorized") || value.contains("login") || code == "401" {
            return "La connexion Codex a expiré ou est refusée. Reconnectez Codex avec ChatGPT ; le brouillon est conservé et aucun envoi n’est relancé."
        }
        return "La requête Codex a échoué. Le brouillon est conservé ; aucun nouvel envoi automatique."
    }
}

extension CodexAppServerTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .rpc(code, message): return CodexInvestigationFailure.message(message, code: String(code))
        case .timeout: return "Codex n’a pas répondu dans le délai prévu. Le brouillon est conservé ; aucun nouvel envoi automatique."
        case .backpressure, .lineTooLarge: return "Le flux Codex dépasse le budget de réception ; collecte arrêtée sans troncature silencieuse."
        case .invalidMessage: return "Le protocole Codex a envoyé un événement invalide ; aucune réponse complète sauvegardée."
        default: return "La connexion au processus Codex est fermée ou indisponible ; aucune réponse complète sauvegardée."
        }
    }
}
