import Foundation
import CryptoKit
import Network
import Security
import LocalAuthentication

public struct CodexInvestigationAccount: Sendable, Equatable {
    public let subject: String
    public let email: String?
    public let clientID: String
    public let canUseChatGPTPlan: Bool
}

/// OAuth credentials belong only to Lens. The actor serializes refreshes and
/// never reads Codex's auth.json, keychain entries, configuration or tokens.
public actor CodexInvestigationConnection {
    public static let shared = CodexInvestigationConnection()
    private var credential: CodexInvestigationCredential?
    private let vault: CodexInvestigationVault
    private let hostID: String
    private let session: URLSession
    private var connecting = false
    private var disconnecting = false
    private var generation: UInt64 = 0
    private var callback: CodexInvestigationLoopback?
    private var connectingTask: Task<CodexInvestigationAccount, Error>?
    private var refreshTask: Task<CodexInvestigationCredential, Error>?

    public init() {
        vault = CodexInvestigationVault()
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "lensChatGPTAgentHostID"), saved.hasPrefix("urn:uuid:"), saved.count <= 80 { hostID = saved }
        else { let value = "urn:uuid:" + UUID().uuidString.lowercased(); defaults.set(value, forKey: "lensChatGPTAgentHostID"); hostID = value }
        session = Self.makeSession()
    }

    init(hostID: String, vault: CodexInvestigationVault, session: URLSession) {
        self.hostID = hostID; self.vault = vault; self.session = session
    }

    public func status() throws -> CodexInvestigationAccount? {
        if credential == nil { credential = try vault.load() }
        return credential?.account
    }

    /// Start the listener before the parent opens the system browser. The
    /// closure is UI-owned; this core has no WebView or automatic browser launch.
    public func connect(openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexInvestigationAccount {
        guard !connecting, !disconnecting else { throw LensError.unsupported("Une connexion ou déconnexion ChatGPT est déjà en cours.") }
        connecting = true; generation &+= 1; let revision = generation
        defer { connecting = false; connectingTask = nil; callback?.stop(); callback = nil }
        let pending = Task { try await self.performConnect(revision: revision, openAuthorizationURL: openAuthorizationURL) }
        connectingTask = pending
        return try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
    }
    private func performConnect(revision: UInt64, openAuthorizationURL: @Sendable (URL) async throws -> Void) async throws -> CodexInvestigationAccount {
        try Task.checkCancellation()
        let previous = try status(), verifier = try CodexInvestigationOAuth.random(), state = try CodexInvestigationOAuth.random(), nonce = try CodexInvestigationOAuth.random()
        let server = CodexInvestigationLoopback(expectedState: state); callback = server
        let redirect = try await server.start()
        let attempt = CodexInvestigationOAuthAttempt(state: state, nonce: nonce, verifier: verifier, redirect: redirect, hostID: hostID, clientID: previous?.clientID)
        try await openAuthorizationURL(attempt.authorizationURL())
        let callbackURL = try await server.receive(timeoutSeconds: 180)
        let grant = try attempt.callbackGrant(callbackURL)
        let data = try await CodexInvestigationOAuth.post(form: ["grant_type": "authorization_code", "client_id": grant.clientID,
            "code": grant.code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString,
            "resource": "https://api.openai.com/v1"], session: session)
        let jwks = try await CodexInvestigationOAuth.get(url: CodexInvestigationOAuth.jwks, session: session)
        let connected = try CodexInvestigationOAuth.validateCredential(data: data, jwks: jwks, clientID: grant.clientID,
            nonce: nonce, expectedSubject: previous?.subject, hostID: hostID)
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        try vault.save(connected); credential = connected
        return connected.account
    }

    public func cancelConnection() { generation &+= 1; connectingTask?.cancel(); callback?.stop() }

    /// Revoke only Lens' renewable session; never call Codex logout. A failed
    /// remote revocation retains credentials so the user can retry explicitly.
    public func disconnect() async throws {
        guard !disconnecting else { throw LensError.unsupported("Une déconnexion ChatGPT est déjà en cours.") }
        disconnecting = true
        defer { disconnecting = false }
        cancelConnection()
        if let pending = connectingTask { _ = try? await pending.value }
        // Let a rotating refresh finish before revoking the current renewable
        // session. Cancelling halfway could strand a newer refresh credential.
        if let pending = refreshTask {
            if let refreshed = try? await pending.value { try vault.save(refreshed); credential = refreshed }
            refreshTask = nil
        }
        guard let current = try loadCredential() else { return }
        let revision = generation
        let discovery = try await CodexInvestigationOAuth.get(url: CodexInvestigationOAuth.discovery, session: session)
        let revocation = try CodexInvestigationOAuth.revocationEndpoint(discovery)
        let request = CodexInvestigationOAuth.formRequest(url: revocation, form:
            ["token": current.refreshToken, "token_type_hint": "refresh_token", "client_id": current.clientID])
        _ = try await CodexInvestigationOAuth.perform(request, session: session, limit: 16 * 1024)
        guard generation == revision else { throw CancellationError() }
        try vault.remove(); credential = nil
    }

    public func models() async throws -> [CodexInvestigationModel] {
        let revision = generation
        let token = try await accessToken()
        let request = try CodexInvestigationClient.authenticatedRequest(url: CodexInvestigationClient.modelsEndpoint, token: token)
        let data = try await CodexInvestigationOAuth.perform(request, session: session, limit: 256 * 1024)
        guard generation == revision else { throw CancellationError() }
        return try CodexInvestigationClient.parseModels(data)
    }

    public func answer(body: Data, capsule: EvidenceCapsule) async throws -> InvestigationAnswer {
        try CodexInvestigationClient.validate(body: body, capsule: capsule)
        let revision = generation, token = try await accessToken()
        let answer = try await CodexInvestigationClient.answer(body: body, capsule: capsule, accessToken: token, session: session)
        guard generation == revision else { throw CancellationError() }
        return answer
    }

    private func loadCredential() throws -> CodexInvestigationCredential? {
        if credential == nil { credential = try vault.load() }; return credential
    }
    private func accessToken() async throws -> String {
        guard !connecting, !disconnecting else { throw LensError.unsupported("Attendez la fin de la connexion ChatGPT avant d’envoyer.") }
        guard let current = try loadCredential(), current.account.canUseChatGPTPlan else {
            throw LensError.unsupported("Connectez ChatGPT à Lens et autorisez l’utilisation du forfait.")
        }
        if current.expiresAt.timeIntervalSinceNow > 90 { return current.accessToken }
        let revision = generation
        if refreshTask == nil {
            let session = self.session
            refreshTask = Task {
                let data = try await CodexInvestigationOAuth.post(form: ["grant_type": "refresh_token", "client_id": current.clientID,
                    "refresh_token": current.refreshToken, "resource": "https://api.openai.com/v1"], session: session)
                return try CodexInvestigationOAuth.refreshed(data, previous: current)
            }
        }
        guard let pending = refreshTask else { throw CancellationError() }
        do {
            let refreshed = try await pending.value
            guard generation == revision else { throw CancellationError() }
            // One actor owns this vault and rotates the full record atomically.
            if credential?.accessToken == current.accessToken { try vault.save(refreshed); credential = refreshed }
            refreshTask = nil
            try Task.checkCancellation()
            guard refreshed.account.canUseChatGPTPlan else { throw LensError.unsupported("La permission d’utiliser le forfait ChatGPT a été retirée ; reconnectez Lens.") }
            return refreshed.accessToken
        } catch { if generation == revision { refreshTask = nil }; throw error }
    }
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: CodexInvestigationRedirectPolicy(), delegateQueue: nil)
    }
}

struct CodexInvestigationCredential: Codable {
    let subject: String, email: String?, clientID: String, hostID: String
    let accessToken: String, refreshToken: String, idToken: String
    let scopes: [String]
    let expiresAt: Date
    var account: CodexInvestigationAccount { .init(subject: subject, email: email, clientID: clientID, canUseChatGPTPlan: scopes.contains("chatgpt.tokens.use.direct")) }
}

struct CodexInvestigationOAuthAttempt {
    let state: String, nonce: String, verifier: String
    let redirect: URL
    let hostID: String
    let clientID: String?
    func authorizationURL() throws -> URL {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil,
              redirect.path == "/auth/callback", redirect.query == nil, redirect.fragment == nil
        else { throw LensError.unsupported("Adresse de retour OAuth invalide.") }
        var url = URLComponents(url: CodexInvestigationOAuth.authorization, resolvingAgainstBaseURL: false)!
        var values = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID, "response_type": "code",
            "redirect_uri": redirect.absoluteString, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce, "code_challenge_method": "S256",
            "code_challenge": CodexInvestigationOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if clientID == nil { values["agent_name_hint"] = "Codex Lens" }
        url.queryItems = values.sorted(by: { $0.key < $1.key }).map { .init(name: $0.key, value: $0.value) }
        guard let result = url.url else { throw LensError.unsupported("Adresse d’autorisation indisponible.") }; return result
    }
    func callbackGrant(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port,
              url.path == redirect.path, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems,
              items.count <= 12, Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state
        else { throw LensError.unsupported("Retour OAuth inattendu ; connexion refusée.") }
        if items.contains(where: { $0.name == "error" }) { throw LensError.unsupported("L’autorisation ChatGPT n’a pas été accordée.") }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= 8192
        else { throw LensError.unsupported("Code d’autorisation manquant.") }
        let returnedID = items.first(where: { $0.name == "client_id" })?.value
        guard clientID == nil || returnedID == nil || returnedID == clientID,
              let issued = clientID ?? returnedID, issued != "dynamic_agent_client",
              issued.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil
        else { throw LensError.unsupported("Enregistrement ChatGPT incomplet ou compte différent.") }
        return (code, issued)
    }
}

enum CodexInvestigationOAuth {
    static let authorization = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let jwks = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    static let discovery = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static func revocationEndpoint(_ discovery: Data) throws -> URL {
        guard let object = try JSONSerialization.jsonObject(with: discovery) as? [String: Any],
              object["issuer"] as? String == "https://auth.openai.com",
              let value = object["revocation_endpoint"] as? String, let url = URL(string: value),
              url.scheme == "https", url.host == "auth.openai.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/api/accounts/oauth/")
        else { throw LensError.unsupported("Révocation distante non confirmée ; connexion Lens conservée pour réessayer.") }
        return url
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw LensError.unsupported("Aléa de connexion indisponible.") }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decodeURL(_ text: String) -> Data? {
        guard !text.isEmpty, text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4); return Data(base64Encoded: text)
    }
    static func formRequest(url: URL, form: [String: String]) -> URLRequest {
        var components = URLComponents(); components.queryItems = form.sorted(by: { $0.key < $1.key }).map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"; request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); return request
    }
    static func post(form: [String: String], session: URLSession) async throws -> Data { try await perform(formRequest(url: token, form: form), session: session, limit: 128 * 1024) }
    static func get(url: URL, session: URLSession) async throws -> Data { try await perform(URLRequest(url: url, timeoutInterval: 45), session: session, limit: 128 * 1024) }
    static func perform(_ request: URLRequest, session: URLSession, limit: Int) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await receive(request, session: session, limit: limit) }
            group.addTask { try await Task.sleep(nanoseconds: 45 * 1_000_000_000); throw LensError.unsupported("Requête de connexion ChatGPT expirée.") }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }; return data
        }
    }
    private static func receive(_ request: URLRequest, session: URLSession, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw LensError.unsupported("Connexion ChatGPT refusée ou indisponible ; réessayez la connexion.") }
        var data = Data(); data.reserveCapacity(min(limit, 8192))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw LensError.unsupported("Réponse de connexion trop volumineuse.") }; data.append(byte)
        }
        return data
    }
    static func tokenFields(_ data: Data) throws -> (access: String, refresh: String, id: String?, scope: [String]?, expiry: Date) {
        guard data.count <= 128 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["token_type"] as? String == "Bearer",
              let access = object["access_token"] as? String, validToken(access),
              let refresh = object["refresh_token"] as? String, validToken(refresh),
              let seconds = object["expires_in"] as? Double, seconds > 0, seconds <= 7 * 24 * 3600
        else { throw LensError.unsupported("Identifiants ChatGPT non reconnus ; connexion refusée.") }
        let scope = object["scope"] as? String
        guard scope == nil || scope!.utf8.count <= 4096 else { throw LensError.unsupported("Permissions ChatGPT non reconnues.") }
        return (access, refresh, object["id_token"] as? String, scope?.split(separator: " ").map(String.init), Date().addingTimeInterval(seconds))
    }
    static func validToken(_ token: String) -> Bool { !token.isEmpty && token.utf8.count <= 16 * 1024 && token.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 } }
    static func validateCredential(data: Data, jwks: Data, clientID: String, nonce: String, expectedSubject: String?, hostID: String) throws -> CodexInvestigationCredential {
        let fields = try tokenFields(data)
        guard let id = fields.id, let scopes = fields.scope else { throw LensError.unsupported("Identité ou permissions ChatGPT manquantes.") }
        let identity = try verifyIdentity(id, jwks: jwks, clientID: clientID, nonce: nonce)
        guard expectedSubject == nil || expectedSubject == identity.subject else { throw LensError.unsupported("Le compte retourné diffère du compte sélectionné.") }
        return .init(subject: identity.subject, email: identity.email, clientID: clientID, hostID: hostID, accessToken: fields.access, refreshToken: fields.refresh, idToken: id, scopes: scopes, expiresAt: fields.expiry)
    }
    static func refreshed(_ data: Data, previous: CodexInvestigationCredential) throws -> CodexInvestigationCredential {
        let fields = try tokenFields(data)
        // An ID token from a refresh is not used to change verified identity.
        return .init(subject: previous.subject, email: previous.email, clientID: previous.clientID, hostID: previous.hostID,
            accessToken: fields.access, refreshToken: fields.refresh, idToken: previous.idToken,
            scopes: fields.scope ?? previous.scopes, expiresAt: fields.expiry)
    }
    static func verifyIdentity(_ jwt: String, jwks: Data, clientID: String, nonce: String, now: Date = Date()) throws -> (subject: String, email: String?) {
        guard jwt.utf8.count <= 32 * 1024, jwks.count <= 128 * 1024 else { throw LensError.unsupported("Identité ChatGPT trop volumineuse.") }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decodeURL(parts[0]), let claimsData = decodeURL(parts[1]), let signature = decodeURL(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              header["crit"] == nil, let kid = header["kid"] as? String, !kid.isEmpty,
              let document = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = document["keys"] as? [[String: Any]], keys.count <= 64
        else { throw LensError.unsupported("Signature d’identité ChatGPT non reconnue.") }
        let matches = keys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }
        guard matches.count == 1, let key = matches.first, key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256", let modulus = key["n"] as? String,
              let exponent = key["e"] as? String, let n = decodeURL(modulus), n.count >= 256, n.count <= 1024,
              let e = decodeURL(exponent), e.count <= 8
        else { throw LensError.unsupported("Clé de signature d’identité indisponible.") }
        let der = derValue(tag: 0x30, payload: derInteger(n) + derInteger(e))
        var error: Unmanaged<CFError>?
        defer { if let error { _ = error.takeRetainedValue() } }
        guard let publicKey = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, &error)
        else { throw LensError.unsupported("Signature d’identité ChatGPT invalide.") }
        guard let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com", claims["nonce"] as? String == nonce,
              let expires = claims["exp"] as? Double, expires > now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty, subject.utf8.count <= 256,
              !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw LensError.unsupported("Identité ChatGPT expirée ou incohérente.") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID,
              (claims["nbf"] as? Double).map({ $0 <= now.timeIntervalSince1970 + 30 }) ?? true,
              (claims["iat"] as? Double).map({ $0 <= now.timeIntervalSince1970 + 30 }) ?? true
        else { throw LensError.unsupported("Destinataire d’identité ChatGPT invalide.") }
        var email: String?
        if let value = claims["email"] as? String, value.utf8.count <= 320,
           !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { email = value }
        return (subject, email)
    }
    static func derInteger(_ bytes: Data) -> Data {
        var payload = Data(bytes.drop(while: { $0 == 0 })); if payload.isEmpty { payload.append(0) }
        if payload.first! & 0x80 != 0 { payload.insert(0, at: 0) }; return derValue(tag: 0x02, payload: payload)
    }
    static func derValue(tag: UInt8, payload: Data) -> Data {
        var result = Data([tag]); let count = payload.count
        if count < 128 { result.append(UInt8(count)) }
        else { var size = count, bytes = [UInt8](); while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }; result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes) }
        result.append(payload); return result
    }
}

struct CodexInvestigationVault: Sendable {
    let service: String
    let account: String
    init(service: String = "fr.codexlens.chatgpt-plan", account: String = "selected-account") { self.service = service; self.account = account }
    private var query: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context]
    }
    func load() throws -> CodexInvestigationCredential? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 128 * 1024,
              let value = try? JSONDecoder().decode(CodexInvestigationCredential.self, from: data)
        else { throw LensError.unsupported("Connexion Lens dans le Trousseau indisponible.") }
        return value
    }
    func save(_ credential: CodexInvestigationCredential) throws {
        let data = try JSONEncoder().encode(credential)
        guard data.count <= 128 * 1024 else { throw LensError.unsupported("Identifiants Lens trop volumineux.") }
        let changes = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            var addition = query; addition[kSecUseAuthenticationContext as String] = nil
            addition[kSecValueData as String] = data; addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw LensError.unsupported("Enregistrement de la connexion Lens dans le Trousseau impossible.") }
        } else if updated != errSecSuccess { throw LensError.unsupported("Mise à jour de la connexion Lens dans le Trousseau impossible.") }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LensError.unsupported("Suppression de la connexion Lens dans le Trousseau impossible.") }
    }
}

private final class CodexInvestigationRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Bound only to 127.0.0.1. Invalid paths/states cannot complete authorization;
/// neither request bytes nor query strings are logged or persisted.
final class CodexInvestigationLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.codexlens.oauth-loopback")
    private let expectedState: String
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var redirect: URL?
    private var stopped = false
    private let stream: AsyncThrowingStream<URL, Error>
    private let continuation: AsyncThrowingStream<URL, Error>.Continuation
    init(expectedState: String) {
        self.expectedState = expectedState
        let pair = AsyncThrowingStream<URL, Error>.makeStream(bufferingPolicy: .bufferingOldest(1)); stream = pair.stream; continuation = pair.continuation
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                queue.async {
                    guard !self.stopped else { ready.resume(throwing: CancellationError()); return }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        var didResume = false
                        listener.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                guard !didResume, let port = listener.port,
                                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else { return }
                                didResume = true; self.redirect = url; ready.resume(returning: url)
                            case .failed, .cancelled:
                                if !didResume { didResume = true; ready.resume(throwing: LensError.unsupported("Port local de connexion ChatGPT indisponible.")) }
                                self.continuation.finish(throwing: CancellationError())
                                listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
                                if self.listener === listener { self.listener = nil }
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { connection in self.accept(connection) }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 5) {
                            if !didResume { didResume = true; ready.resume(throwing: LensError.unsupported("Ouverture du port de connexion expirée.")); listener.cancel() }
                        }
                    } catch { ready.resume(throwing: LensError.unsupported("Écoute locale de connexion ChatGPT impossible.")) }
                }
            }
        } onCancel: { self.stop() }
    }
    func receive(timeoutSeconds: UInt64) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask { for try await value in self.stream { return value }; throw CancellationError() }
                group.addTask { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000); throw LensError.unsupported("Connexion ChatGPT expirée ; réessayez.") }
                defer { group.cancelAll(); self.stop() }
                guard let value = try await group.next() else { throw CancellationError() }; return value
            }
        } onCancel: { self.stop() }
    }
    func stop() {
        queue.async {
            guard !self.stopped else { return }; self.stopped = true
            let listener = self.listener; self.listener = nil
            listener?.newConnectionHandler = nil; listener?.cancel()
            self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
            self.continuation.finish(throwing: CancellationError())
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { if self.connections[id] != nil { connection.cancel(); self.connections[id] = nil } }
        read(connection, id: id, data: Data())
    }
    private func read(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { incoming, _, complete, error in
            var data = data; if let incoming { data.append(incoming) }
            guard data.count <= 16 * 1024, error == nil else { self.respond(connection, id: id, status: "400 Bad Request", accepted: false); return }
            if data.range(of: Data("\r\n\r\n".utf8)) == nil {
                if complete { self.respond(connection, id: id, status: "400 Bad Request", accepted: false) }
                else { self.read(connection, id: id, data: data) }; return
            }
            guard let text = String(data: data, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first,
                  first.hasPrefix("GET "), let target = first.split(separator: " ").dropFirst().first,
                  target.hasPrefix("/auth/callback?"), let redirect = self.redirect,
                  let url = URL(string: "http://127.0.0.1:\(redirect.port!)" + String(target)),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path == "/auth/callback",
                  parts.queryItems?.first(where: { $0.name == "state" })?.value == self.expectedState,
                  let query = parts.queryItems, Set(query.map(\.name)).count == query.count
            else { self.respond(connection, id: id, status: "400 Bad Request", accepted: false); return }
            self.respond(connection, id: id, status: "200 OK", accepted: true, callbackURL: url)
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, status: String, accepted: Bool, callbackURL: URL? = nil) {
        let text = accepted ? "Return to Codex Lens to finish connecting. You may close this page." : "Invalid connection callback. Return to Codex Lens."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(text.utf8.count)\r\n\r\n\(text)"
        connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in
            if let callbackURL { self.continuation.yield(callbackURL); self.continuation.finish() }
            connection.cancel(); self.connections[id] = nil
        })
    }
}
