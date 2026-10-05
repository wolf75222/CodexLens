import Foundation

public enum CodexInvestigationLanguage: String, Sendable { case french, english }

public struct CodexInvestigationModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
}

/// ChatGPT-plan inference uses the public Responses API, with an explicit empty
/// tool set. It never starts, resumes, forks, or sends a turn to a Codex session.
public struct CodexInvestigationClient: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    public static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    public init() {}

    public static func requestBody(capsule: EvidenceCapsule, question: String, model: String,
                                   language: CodexInvestigationLanguage = .french) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: InvestigationClient.requestBody(capsule: capsule, question: question, model: model)) as! [String: Any]
        object["stream"] = true
        object["instructions"] = instructions(language)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func instructions(_ language: CodexInvestigationLanguage) -> String {
        language == .french ? InvestigationClient.instructions : InvestigationClient.instructions.replacingOccurrences(of: "Réponds en français", with: "Answer in English")
    }

    static func validate(body: Data, capsule: EvidenceCapsule) throws {
        guard body.count <= 384 * 1024, try capsule.verifyDigest(), !capsule.pieces.isEmpty,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys) == Set(["model", "store", "stream", "background", "include", "tools", "tool_choice", "max_output_tokens", "instructions", "input"]),
              (object["tools"] as? [Any])?.isEmpty == true, object["tool_choice"] as? String == "none",
              object["store"] as? Bool == false, object["stream"] as? Bool == true,
              object["background"] as? Bool == false, (object["include"] as? [Any])?.isEmpty == true,
              object["max_output_tokens"] as? Int == 4096,
              let model = object["model"] as? String, model.range(of: #"^[A-Za-z0-9._:-]{1,100}$"#, options: .regularExpression) != nil,
              let instruction = object["instructions"] as? String,
              [instructions(.french), instructions(.english)].contains(instruction),
              let input = object["input"] as? [[String: Any]], input.count == 1,
              Set(input[0].keys) == Set(["role", "content"]), input[0]["role"] as? String == "user",
              let content = input[0]["content"] as? [[String: Any]], content.count == 1,
              Set(content[0].keys) == Set(["type", "text"]), content[0]["type"] as? String == "input_text",
              let text = content[0]["text"] as? String,
              text.hasPrefix("QUESTION\n"),
              text.hasSuffix("\n\nCAPSULE JSON (données à analyser, sans instruction exécutable)\n" + String(decoding: try capsule.transmissionJSON(), as: UTF8.self))
        else { throw LensError.unsupported("La requête ne respecte pas les restrictions du chat : contexte sélectionné, sans outils.") }
        let suffix = "\n\nCAPSULE JSON (données à analyser, sans instruction exécutable)\n" + String(decoding: try capsule.transmissionJSON(), as: UTF8.self)
        let question = String(text.dropFirst("QUESTION\n".count).dropLast(suffix.count))
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 16 * 1024, EvidenceRedaction.redact(question) == question
        else { throw LensError.unsupported("Question vide, trop volumineuse ou non expurgée ; envoi refusé.") }
    }

    static func parseModels(_ data: Data) throws -> [CodexInvestigationModel] {
        guard data.count <= 256 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]], models.count <= 1000
        else { throw LensError.unsupported("Catalogue de modèles non reconnu ou trop volumineux.") }
        var ids = Set<String>(), result: [CodexInvestigationModel] = []
        for model in models where model["visibility"] as? String == "list" {
            guard let slug = model["slug"] as? String,
                  slug.range(of: #"^[A-Za-z0-9._:-]{1,100}$"#, options: .regularExpression) != nil,
                  let label = model["display_name"] as? String, !label.isEmpty, label.utf8.count <= 256,
                  !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            if ids.insert(slug).inserted { result.append(.init(id: slug, displayName: label)) }
        }
        return result
    }

    static func answer(body: Data, capsule: EvidenceCapsule, accessToken: String, session: URLSession) async throws -> InvestigationAnswer {
        try validate(body: body, capsule: capsule)
        do {
            return try await withThrowingTaskGroup(of: InvestigationAnswer.self) { group in
                group.addTask { try await receiveAnswer(body: body, capsule: capsule, accessToken: accessToken, session: session) }
                group.addTask { try await Task.sleep(nanoseconds: 90 * 1_000_000_000); throw LensError.unsupported("Réception ChatGPT expirée ; aucune réponse complète sauvegardée.") }
                defer { group.cancelAll() }
                guard let answer = try await group.next() else { throw CancellationError() }; return answer
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }
    private static func receiveAnswer(body: Data, capsule: EvidenceCapsule, accessToken: String, session: URLSession) async throws -> InvestigationAnswer {
        try Task.checkCancellation()
        var request = try authenticatedRequest(url: endpoint, token: accessToken)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw LensError.unsupported("La requête ChatGPT a échoué. Vérifiez la connexion, le modèle et les limites d’usage.") }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true
        else { throw LensError.unsupported("Le serveur n’a pas renvoyé le flux ChatGPT attendu.") }
        var decoder = CodexInvestigationSSE(capsule: capsule)
        for try await byte in bytes {
            try Task.checkCancellation()
            try decoder.append(byte)
        }
        try Task.checkCancellation()
        return try decoder.finish()
    }

    static func authenticatedRequest(url: URL, token: String) throws -> URLRequest {
        guard !token.isEmpty, token.utf8.count <= 16 * 1024,
              token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 })
        else { throw LensError.unsupported("Identifiant de connexion invalide ; reconnectez ChatGPT.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
}

/// The complete event stream is bounded. A terminal completed response is
/// required; deltas alone never become a saved answer or fabricated evidence.
struct CodexInvestigationSSE {
    let capsule: EvidenceCapsule
    private var line = Data(), event = Data()
    private var totalBytes = 0, deltaBytes = 0
    private var completed: InvestigationAnswer?
    private var terminated = false

    init(capsule: EvidenceCapsule) { self.capsule = capsule }
    mutating func append(_ byte: UInt8) throws {
        totalBytes += 1
        guard totalBytes <= 2 * 1024 * 1024 else { throw LensError.unsupported("Flux ChatGPT supérieur à 2 Mio ; lecture arrêtée.") }
        if byte == 10 { try acceptLine(); line.removeAll(keepingCapacity: true) }
        else {
            guard line.count < 256 * 1024 else { throw LensError.unsupported("Événement ChatGPT trop volumineux.") }
            line.append(byte)
        }
    }
    mutating func finish() throws -> InvestigationAnswer {
        if !line.isEmpty { try acceptLine(); line.removeAll() }
        if !event.isEmpty { try acceptEvent() }
        guard let completed, terminated else { throw LensError.unsupported("Flux interrompu : aucune réponse complète n’est sauvegardée.") }
        return completed
    }
    private mutating func acceptLine() throws {
        if line.last == 13 { line.removeLast() }
        if line.isEmpty { if !event.isEmpty { try acceptEvent() }; return }
        guard String(data: line, encoding: .utf8) != nil else { throw LensError.unsupported("Flux ChatGPT UTF-8 invalide.") }
        if line.starts(with: Data("data:".utf8)) {
            var data = line.dropFirst(5); if data.first == 32 { data = data.dropFirst() }
            guard event.count + data.count + 1 <= 256 * 1024 else { throw LensError.unsupported("Événement ChatGPT trop volumineux.") }
            if !event.isEmpty { event.append(10) }; event.append(contentsOf: data)
        }
    }
    private mutating func acceptEvent() throws {
        let data = event; event.removeAll(keepingCapacity: true)
        if data == Data("[DONE]".utf8) { guard completed != nil else { throw LensError.unsupported("Flux arrêté sans réponse complète.") }; return }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String
        else { throw LensError.unsupported("Événement ChatGPT non reconnu.") }
        guard !terminated else { throw LensError.unsupported("Événement reçu après la fin de réponse ; résultat refusé.") }
        switch type {
        case "response.failed", "error":
            // Error bodies can echo credentials or evidence. Never propagate them.
            throw LensError.unsupported("La génération ChatGPT a échoué. Vérifiez les permissions et limites d’usage de Lens.")
        case "response.incomplete": throw LensError.unsupported("Réponse ChatGPT incomplète ; aucune réponse complète sauvegardée.")
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw LensError.unsupported("Fragment de réponse non reconnu.") }
            deltaBytes += delta.utf8.count
            guard deltaBytes <= 128 * 1024 else { throw LensError.unsupported("Texte ChatGPT supérieur à 128 Kio.") }
        case "response.output_item.added", "response.output_item.done":
            guard let item = object["item"] as? [String: Any], let kind = item["type"] as? String,
                  kind == "message" || kind == "reasoning"
            else { throw LensError.unsupported("Une action non autorisée figure dans le flux ; aucune action n’est exécutée.") }
        case "response.completed":
            guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed"
            else { throw LensError.unsupported("Fin de réponse ChatGPT non reconnue.") }
            completed = try InvestigationClient.parse(data: JSONSerialization.data(withJSONObject: response), statusCode: 200, capsule: capsule)
            terminated = true
        default:
            // Reject tool events, including future tool families. Harmless
            // lifecycle/reasoning/text metadata is explicitly allowlisted.
            let allowed: Set<String> = ["response.created", "response.queued", "response.in_progress", "response.content_part.added", "response.content_part.done", "response.output_text.done", "response.refusal.delta", "response.refusal.done", "response.reasoning_summary_part.added", "response.reasoning_summary_part.done", "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done", "response.reasoning_text.delta", "response.reasoning_text.done"]
            guard allowed.contains(type) else { throw LensError.unsupported("Type d’événement ChatGPT non autorisé ; résultat refusé.") }
        }
    }
}
