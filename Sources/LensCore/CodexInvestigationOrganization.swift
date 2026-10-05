import Foundation

/// Persisted section metadata in the installed v0.159.2 protocol. No archive,
/// resume, interrupt or observed-session write occurs in this adapter.
enum CodexInvestigationOrganization {
    static let sectionName = "Codex Lens — Enquêtes"
    private static let resolver = CodexSectionResolver()

    static func prepare(server: CodexAppServerTransport, registry: CodexInvestigationRegistry,
                        chatID: String, rootID: String, threadID: String, isNew: Bool,
                        groupInSidebar: Bool) async throws {
        guard let owned = try await registry.lookup(chatID: chatID, root: rootID),
              owned.threadID == threadID, threadID != rootID else {
            throw LensError.unsupported("Classement refusé : ce thread n’appartient pas au chat Lens.")
        }
        let read = try await request(server, "thread/read", ["threadId": threadID, "includeTurns": false])
        guard let thread = read["thread"] as? [String: Any], thread["id"] as? String == threadID else {
            throw LensError.corrupt("Identité du thread à classer non vérifiée ; aucun tour lancé.")
        }
        if isNew || thread["name"] == nil || thread["name"] is NSNull {
            // A compact, non-sensitive title replaces the fallback capsule
            // preview. A person's explicit title on an existing thread is kept.
            _ = try await request(server, "thread/name/set", ["threadId": threadID,
                "name": "Codex Lens · Enquête " + String(chatID.prefix(8))])
        }
        guard groupInSidebar else { return }
        if let current = thread["section"] as? [String: Any], let id = current["id"] as? String, !id.isEmpty {
            // Keep a section selected by the person, including after a rename.
            if current["name"] as? String == sectionName { try await registry.rememberSidebarSection(id) }
            return
        }
        guard thread["section"] == nil || thread["section"] is NSNull else { throw malformedSections() }
        let id = try await resolver.resolve(server: server, registry: registry)
        _ = try await request(server, "thread/section/move", ["threadId": threadID, "sectionId": id])
        let confirmation = try await request(server, "thread/read", ["threadId": threadID, "includeTurns": false])
        guard let verified = confirmation["thread"] as? [String: Any], verified["id"] as? String == threadID,
              (verified["section"] as? [String: Any])?["id"] as? String == id else {
            throw LensError.corrupt("Classement du chat non confirmé ; le brouillon est conservé et aucun tour lancé.")
        }
    }

    fileprivate static func resolveSection(server: CodexAppServerTransport, registry: CodexInvestigationRegistry) async throws -> String {
        let remembered = try await registry.sidebarSectionID()
        var rememberedMatch: [String: Any]?, namedMatch: [String: Any]?, cursor: String?, seen = Set<String>()
        for page in 0..<20 {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(server, "threadSection/list", params)
            guard let data = result["data"] as? [[String: Any]], data.count <= 100,
                  data.allSatisfy({ ($0["id"] as? String)?.isEmpty == false && $0["name"] is String }) else { throw malformedSections() }
            if rememberedMatch == nil, let remembered { rememberedMatch = data.first { $0["id"] as? String == remembered } }
            if namedMatch == nil { namedMatch = data.first { $0["name"] as? String == sectionName } }
            // A remembered identity is authoritative, even after a rename.
            if rememberedMatch != nil || result["nextCursor"] == nil || result["nextCursor"] is NSNull { break }
            guard let next = result["nextCursor"] as? String, !next.isEmpty, seen.insert(next).inserted, page < 19 else {
                throw malformedSections()
            }
            cursor = next
        }
        let existing = rememberedMatch ?? namedMatch
        let section: [String: Any]
        if let existing { section = existing }
        else {
            let result = try await request(server, "threadSection/create", ["name": sectionName])
            guard let created = result["section"] as? [String: Any] else { throw malformedSections() }
            section = created
        }
        guard let id = section["id"] as? String, !id.isEmpty else { throw malformedSections() }
        // Persist before move. An ambiguous EOF does not create another group
        // automatically on the next explicit Send.
        try await registry.rememberSidebarSection(id)
        return id
    }

    private static func request(_ server: CodexAppServerTransport, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        do {
            try Task.checkCancellation()
            let data = try await server.request(method: method, params: JSONSerialization.data(withJSONObject: params))
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw malformedSections() }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { throw LensError.unavailable("Le classement du chat dans Codex a échoué ; le brouillon est conservé. Aucun tour lancé. Vous pouvez réessayer ou désactiver le classement dans Réglages > IA.") }
    }
    private static func malformedSections() -> LensError { .corrupt("Sections Codex illisibles ou pagination incomplète ; aucun tour lancé.") }
}

/// Coalesce section discovery/creation for concurrent Lens windows. Moving each
/// owned thread is separate. Finished flights are evicted immediately.
private actor CodexSectionResolver {
    private var flights: [String: (UUID, Task<String, Error>)] = [:]
    func resolve(server: CodexAppServerTransport, registry: CodexInvestigationRegistry) async throws -> String {
        let key = registry.directory.path
        if let flight = flights[key] { return try await flight.1.value }
        let generation = UUID()
        let task = Task { try await CodexInvestigationOrganization.resolveSection(server: server, registry: registry) }
        flights[key] = (generation, task)
        defer { if flights[key]?.0 == generation { flights[key] = nil } }
        return try await task.value
    }
}
