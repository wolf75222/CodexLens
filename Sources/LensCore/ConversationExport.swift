import Foundation
import CryptoKit
import Darwin

public enum ConversationRole: String, Codable, Sendable { case user, assistant }
public enum ConversationExportFormat: String, Codable, CaseIterable, Sendable { case json, markdown }
public enum ConversationTextStatus: String, Codable, Sendable {
    case available, noRecordedText, unavailable, integrityFailed, messageLimitExceeded, storageLimitExceeded
}
public enum ConversationSignalKind: String, Codable, CaseIterable, Sendable { case correction, preference, constraint, continuation }

/// A literal cue in recorded user text, never a conclusion about intention or the model's response.
public struct ConversationSignal: Codable, Hashable, Sendable {
    public let kind: ConversationSignalKind
    public let cue: String
    public let excerpt: String
}

public struct ConversationMessageSummary: Identifiable, Codable, Sendable {
    public let id: String
    public let role: ConversationRole
    public let timestamp: Date?
    public let agentID: String
    public let turnID: String?
    public let preview: String
    public let byteCount: Int
    public let status: ConversationTextStatus
    public let signals: [ConversationSignal]
    public let previousMessageID: String?
    public let limitations: [String]
}

public struct ConversationMessage: Identifiable, Codable, Sendable {
    public let id: String
    public let role: ConversationRole
    public let timestamp: Date?
    public let agentID: String
    public let threadID: String
    public let turnID: String?
    public let environmentID: String?
    public let source: SourceRef
    /// Aliases are provenance only. They are not concatenated into the message text.
    public let supplementarySources: [SourceRef]
    /// References and recorded availability only; no attachment bytes are read or included.
    public let resources: [ResourceRecord]
    public let text: String?
    public let byteCount: Int
    public let status: ConversationTextStatus
    public let signals: [ConversationSignal]
    public let previousMessageID: String?
    public let limitations: [String]
}

/// A legacy message-shaped record indexed as context, whose content is not silently added
/// as a second conversation message. Links are confirmed only by explicit source aliases.
public struct ConversationExcludedReference: Identifiable, Codable, Sendable {
    public let id: String
    public let threadID: String
    public let agentID: String
    public let turnID: String?
    public let timestamp: Date?
    public let title: String
    public let source: SourceRef
    public let supplementarySources: [SourceRef]
    public let associatedMessageIDs: [String]
    public let reason: String
}

public struct ConversationReview: Codable, Sendable {
    public let schemaVersion: Int
    public let rootThreadID: String
    public let sessionID: String
    public let title: String
    public let collectedAt: Date
    public let preparedAt: Date
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let messages: [ConversationMessageSummary]
    public let excludedReferences: [ConversationExcludedReference]
    public let userCount: Int
    public let assistantCount: Int
    public let totalTextBytes: Int
    public let limits: [String]
    public let coverage: [CoverageIssue]
    public let redactionPolicy: String
}

public struct ConversationExportReceipt: Sendable {
    public let destination: URL
    public let format: ConversationExportFormat
    public let messageCount: Int
    public let byteCount: Int
    public let sha256: String
}

/// An index snapshot fixes membership and order before any asynchronous source reads.
/// Neither shared repositories nor source aliases establish membership in this conversation.
public struct ConversationExportPlan: Sendable {
    public let root: SessionSummary
    public let events: [LensEvent]
    public let excludedConversationReferences: [LensEvent]
    public let resources: [ResourceRecord]
    public let collectedAt: Date
    public let coverage: [CoverageIssue]
    fileprivate var protectedPaths: [URL]
    fileprivate var protectedRoots: [URL]
    fileprivate let resourcesByID: [String: ResourceRecord]
    fileprivate let resourcesByEventID: [String: [ResourceRecord]]

    public init(snapshot: SessionSnapshot, progress: OperationProgressHandler? = nil) {
        let reporter = progress.map { OperationProgressReporter($0) }
        root = snapshot.root
        reporter?.send(.init(stage: .indexingConversation, total: Int64(snapshot.events.count), unit: .events, step: 1, stepCount: 2))
        var messages: [LensEvent] = [], excluded: [LensEvent] = [], eventPaths: [String] = []
        // These exact labels belong to the installed, versioned SessionEngine adapter.
        // Equal text, a shared turn or temporal proximity cannot establish a mirror.
        for (index, event) in snapshot.events.enumerated() {
            if event.agentID == snapshot.root.id {
                if event.kind == .user || event.kind == .assistant { messages.append(event) }
                else if event.kind == .context && ["user_message · trace de contexte", "agent_message · trace de contexte"].contains(event.title) { excluded.append(event) }
            }
            eventPaths += [event.source.path] + event.supplementarySources.map(\.path)
            reporter?.send(.init(stage: .indexingConversation, completed: Int64(index + 1), total: Int64(snapshot.events.count), unit: .events, step: 1, stepCount: 2))
        }
        events = messages; excludedConversationReferences = excluded
        resources = snapshot.resources
        resourcesByID = Dictionary(snapshot.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var associated: [String: [ResourceRecord]] = [:]
        for resource in snapshot.resources {
            for eventID in Set(resource.eventIDs) { associated[eventID, default: []].append(resource) }
        }
        resourcesByEventID = associated
        collectedAt = snapshot.collectedAt
        coverage = snapshot.coverage
        protectedPaths = (snapshot.root.paths + eventPaths
            + snapshot.resources.map(\.location) + snapshot.changes.map(\.path)).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        protectedRoots = (snapshot.environments.map(\.path) + [snapshot.root.cwd]).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }
}

/// Passive preparation and export. Payloads are stored in a private bounded spool, not retained
/// for the whole conversation in memory. At most one 64 MiB message is materialized to apply
/// the existing cross-page redaction rules or to show the selected message.
public actor ConversationExporter {
    private struct FrozenMessage {
        let metadata: ConversationMessage
        let summary: ConversationMessageSummary
        let file: URL?
    }
    private enum State { case idle, preparing, prepared, disposed }
    private let plan: ConversationExportPlan
    private let maximumBytes: Int
    private let maximumMessageBytes: Int
    private var state: State = .idle
    private var directory: URL?
    private var frozen: [FrozenMessage] = []
    private var review: ConversationReview?
    private var messageIndex: [String: Int] = [:]
    private var exportPlan: ConversationExportPlan?

    public init(plan: ConversationExportPlan, maximumBytes: Int = 256 * 1024 * 1024, maximumMessageBytes: Int = 64 * 1024 * 1024) {
        self.plan = plan
        self.maximumBytes = max(0, min(maximumBytes, 256 * 1024 * 1024))
        self.maximumMessageBytes = max(0, min(maximumMessageBytes, 64 * 1024 * 1024))
    }
    deinit { if let directory { try? FileManager.default.removeItem(at: directory) } }

    public func prepare(progress: OperationProgressHandler? = nil) async throws -> ConversationReview {
        let span = LensSignposts.begin("ConversationPrepare"); defer { span.end() }
        try Task.checkCancellation()
        if let review { return review }
        guard state == .idle else { throw LensError.unavailable("Préparation déjà en cours ou export fermé.") }
        let reporter = progress.map { OperationProgressReporter($0) }
        state = .preparing
        // Resolve source aliases on this actor, before capture. Keep these original targets
        // protected even if a worktree symlink is later repointed; export also resolves again.
        var protectedPlan = plan
        protectedPlan.protectedPaths = Array(Set(plan.protectedPaths.flatMap(Self.aliases)))
        protectedPlan.protectedRoots = Array(Set(plan.protectedRoots.flatMap(Self.aliases)))
        exportPlan = protectedPlan
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("codexlens-conversation-" + UUID().uuidString)
        guard spool.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else { state = .idle; throw ConversationAtomicWriter.failure("Création du dossier privé") }
        directory = spool
        let pager = RecordedPager()
        var prepared: [FrozenMessage] = []
        var total = 0
        do {
            reporter?.send(.init(stage: .readingMessages, total: Int64(plan.events.count), unit: .messages, step: 2, stepCount: 2))
            for (index, original) in plan.events.enumerated() {
                try requirePreparing()
                let role: ConversationRole = original.kind == .user ? .user : .assistant
                let previous = prepared.last?.metadata.id
                var sourceEvent = original
                sourceEvent.supplementarySources = []
                let file = spool.appendingPathComponent(String(index) + ".txt")
                var status: ConversationTextStatus = .available
                var limitations: [String] = []
                var preview = ""
                var signals: [ConversationSignal] = []
                var byteCount = 0
                var retainedFile: URL?
                if total >= maximumBytes {
                    status = .storageLimitExceeded
                    limitations.append("Budget de capture atteint ; texte non chargé, aperçu de l’index non substitué.")
                } else {
                    do {
                        try Self.requireMessageSource(original.source)
                        let fd = file.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
                        guard fd >= 0 else { throw ConversationAtomicWriter.failure("Création du texte privé") }
                        defer { _ = close(fd) }
                        var page = try await pager.begin(event: sourceEvent, part: "content", limit: 65536, decorateSources: false)
                        while true {
                            try requirePreparing()
                            let bytes = Data(page.text.utf8)
                            guard bytes.count <= maximumMessageBytes - byteCount else { throw ConversationCaptureLimit.message }
                            guard bytes.count <= maximumBytes - total - byteCount else { throw ConversationCaptureLimit.storage }
                            try ConversationAtomicWriter.write(bytes, fd: fd)
                            byteCount += bytes.count
                            guard let token = page.token else { break }
                            page = try await pager.next(token: token, limit: 65536)
                        }
                        // EOF is reached only after JSON validation and any recorded digest check.
                        guard fsync(fd) == 0 else { throw ConversationAtomicWriter.failure("Synchronisation du texte privé") }
                        try requirePreparing()
                        if byteCount == 0 {
                            status = .noRecordedText
                            limitations.append("Aucun champ de texte pris en charge dans la source ; aperçu de l’index non substitué.")
                        } else {
                            let data = try Data(contentsOf: file)
                            guard data.count == byteCount, let text = String(data: data, encoding: .utf8) else { throw LensError.corrupt("Texte privé incomplet ou UTF-8 invalide.") }
                            let clean = EvidenceRedaction.redact(text)
                            let cleanBytes = Data(clean.utf8)
                            guard cleanBytes.count <= maximumMessageBytes else { throw ConversationCaptureLimit.message }
                            guard cleanBytes.count <= maximumBytes - total else { throw ConversationCaptureLimit.storage }
                            if clean != text {
                                guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) >= 0 else { throw ConversationAtomicWriter.failure("Masquage du texte privé") }
                                try ConversationAtomicWriter.write(cleanBytes, fd: fd)
                                guard fsync(fd) == 0 else { throw ConversationAtomicWriter.failure("Synchronisation du texte masqué") }
                            }
                            byteCount = cleanBytes.count
                            preview = String(clean.prefix(400))
                            if role == .user { signals = Self.signals(in: clean) }
                            retainedFile = file
                            total += byteCount
                            if original.source.sha256 == nil {
                                limitations.append("Sans empreinte enregistrée, l’intégrité historique complète n’est pas attestée ; la lecture valide les bornes visibles de la source.")
                            }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try requirePreparing()
                        if let limit = error as? ConversationCaptureLimit {
                            status = limit == .message ? .messageLimitExceeded : .storageLimitExceeded
                        } else if let lensError = error as? LensError, case .corrupt = lensError { status = .integrityFailed }
                        else { status = .unavailable }
                        limitations.append(EvidenceRedaction.redact(error.localizedDescription))
                        byteCount = 0; preview = ""; signals = []; retainedFile = nil
                    }
                    if retainedFile == nil { try? FileManager.default.removeItem(at: file) }
                }
                let timestamp = Self.timestamp(original.timestamp)
                let message = ConversationMessage(id: original.id, role: role, timestamp: timestamp, agentID: original.agentID,
                    threadID: plan.root.id, turnID: original.turnID, environmentID: original.environmentID.map(EvidenceRedaction.redact), source: Self.clean(original.source),
                    supplementarySources: original.supplementarySources.map(Self.clean), resources: Self.resources(for: original, in: plan),
                    text: nil, byteCount: byteCount, status: status, signals: signals, previousMessageID: previous, limitations: limitations)
                let summary = ConversationMessageSummary(id: message.id, role: role, timestamp: timestamp, agentID: message.agentID, turnID: message.turnID,
                    preview: preview, byteCount: byteCount, status: status, signals: signals, previousMessageID: previous, limitations: limitations)
                prepared.append(FrozenMessage(metadata: message, summary: summary, file: retainedFile))
                // Count a message only after its captured status and redaction are frozen.
                reporter?.send(.init(stage: .readingMessages, completed: Int64(index + 1), total: Int64(plan.events.count), unit: .messages, step: 2, stepCount: 2))
            }
            try requirePreparing()
            let timestamps = prepared.compactMap(\.metadata.timestamp)
            var messageIDsBySource: [SourceRef: [String]] = [:]
            for event in plan.events {
                for ref in Set([event.source] + event.supplementarySources) { messageIDsBySource[ref, default: []].append(event.id) }
            }
            let excluded = plan.excludedConversationReferences.map { event in
                let linked = Array(Set(([event.source] + event.supplementarySources).flatMap { messageIDsBySource[$0] ?? [] })).sorted()
                return ConversationExcludedReference(id: event.id, threadID: plan.root.id, agentID: event.agentID, turnID: event.turnID,
                    timestamp: Self.timestamp(event.timestamp), title: EvidenceRedaction.redact(event.title), source: Self.clean(event.source),
                    supplementarySources: event.supplementarySources.map(Self.clean), associatedMessageIDs: linked,
                    reason: linked.isEmpty ? "Trace legacy classée comme contexte ; correspondance avec un message de conversation non confirmée. Texte non ajouté automatiquement."
                        : "Référence source explicitement associée à un message indexé ; texte non ajouté une seconde fois.")
            }
            var coverage = plan.coverage.map { CoverageIssue(EvidenceRedaction.redact($0.category), EvidenceRedaction.redact($0.message), source: EvidenceRedaction.redact($0.source)) }
            if !excluded.isEmpty {
                coverage.append(CoverageIssue("conversation legacy", "\(excluded.count) trace(s) user_message/agent_message classée(s) comme contexte par l’adaptateur sont conservées dans excludedReferences, sans texte ajouté automatiquement ; \(excluded.filter { $0.associatedMessageIDs.isEmpty }.count) association(s) à un message non confirmée(s).", source: plan.root.id))
            }
            let result = ConversationReview(schemaVersion: 1, rootThreadID: plan.root.id, sessionID: plan.root.sessionID,
                title: EvidenceRedaction.redact(plan.root.title), collectedAt: plan.collectedAt, preparedAt: Date(), firstTimestamp: timestamps.first,
                lastTimestamp: timestamps.last, messages: prepared.map(\.summary), excludedReferences: excluded, userCount: prepared.filter { $0.metadata.role == .user }.count,
                assistantCount: prepared.filter { $0.metadata.role == .assistant }.count, totalTextBytes: total,
                limits: [
                    "Conversation principale uniquement : messages utilisateur et assistant du thread \(plan.root.id). Outils, instructions et descendants exclus.",
                    "Ordre de l’index au moment de la capture. Une date absente reste inconnue ; la date actuelle n’est pas utilisée à sa place.",
                    "Budget privé : \(maximumBytes) octets, \(maximumMessageBytes) octets par message. Les omissions sont explicites, jamais remplacées par un aperçu.",
                    "Indices lexicaux locaux, non exhaustifs et incertains ; un texte cité peut produire un faux positif. Ils ne prouvent ni intention, ni compréhension, ni effet sur le modèle.",
                    "Les sources supplémentaires sont des références, pas des messages supplémentaires. Pièces jointes : références et disponibilité enregistrée, sans contenu.",
                    "La préparation lit passivement chaque plage disponible ; les fichiers ne forment pas une transaction globale. Après préparation, l’export ne relit plus les journaux."
                ], coverage: coverage,
                redactionPolicy: "RecordedPager masque les champs d’authentification, jetons sk- et Bearer ; les règles EvidenceRedaction masquent aussi les secrets reconnus dans le texte et les références. Masquage heuristique, non garantie de suppression de toute information sensible. Aucun auth.json lu, aucune pièce jointe chargée, aucun envoi réseau.")
            frozen = prepared
            messageIndex = Dictionary(prepared.enumerated().map { ($0.element.metadata.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            review = result; state = .prepared
            return result
        } catch {
            try? FileManager.default.removeItem(at: spool)
            directory = nil
            exportPlan = nil
            if state != .disposed { state = .idle }
            throw error
        }
    }

    public func message(eventID: String) throws -> ConversationMessage {
        try Task.checkCancellation()
        guard state == .prepared, let index = messageIndex[eventID] else { throw LensError.unavailable("Message absent de cette capture ou export fermé.") }
        let item = frozen[index]
        var text: String?
        if let file = item.file {
            let data = try Data(contentsOf: file)
            guard data.count == item.metadata.byteCount, let decoded = String(data: data, encoding: .utf8) else { throw LensError.corrupt("Texte privé incomplet ; capture non substituée.") }
            text = decoded
        }
        let m = item.metadata
        return ConversationMessage(id: m.id, role: m.role, timestamp: m.timestamp, agentID: m.agentID, threadID: m.threadID, turnID: m.turnID, environmentID: m.environmentID,
            source: m.source, supplementarySources: m.supplementarySources, resources: m.resources, text: text, byteCount: m.byteCount,
            status: m.status, signals: m.signals, previousMessageID: m.previousMessageID, limitations: m.limitations)
    }

    public func export(to destination: URL, format: ConversationExportFormat, replaceExisting: Bool = false, progress: OperationProgressHandler? = nil) throws -> ConversationExportReceipt {
        let span = LensSignposts.begin("ConversationExport"); defer { span.end() }
        try Task.checkCancellation()
        guard state == .prepared, let review else { throw LensError.unavailable("Préparez la conversation avant de l’exporter.") }
        let reporter = progress.map { OperationProgressReporter($0) }
        reporter?.send(.init(stage: .writingMessages, total: Int64(frozen.count), unit: .messages, step: 1, stepCount: 2))
        let writer = try ConversationAtomicWriter(destination: destination, replaceExisting: replaceExisting, plan: exportPlan ?? plan, privateDirectory: directory)
        if format == .json {
            try writer.append(Data("{\"schemaVersion\":1,\"dateEncoding\":\"millisecondsSinceUnixEpoch\",\"review\":".utf8))
            try writer.append(CapsuleJSON.encode(review))
            try writer.append(Data(",\"messages\":[".utf8))
            for (index, item) in frozen.enumerated() {
                try Task.checkCancellation()
                if index > 0 { try writer.append(Data(",".utf8)) }
                let metadata = try CapsuleJSON.encode(item.metadata)
                guard metadata.last == 125 else { throw LensError.corrupt("Métadonnées JSON invalides.") }
                try writer.append(metadata.dropLast())
                try writer.append(Data(",\"text\":".utf8))
                if let file = item.file { try writer.append(Data("\"".utf8)); try writer.copy(file, escapingJSON: true); try writer.append(Data("\"".utf8)) }
                else { try writer.append(Data("null".utf8)) }
                try writer.append(Data("}".utf8))
                reporter?.send(.init(stage: .writingMessages, completed: Int64(index + 1), total: Int64(frozen.count), unit: .messages, step: 1, stepCount: 2))
            }
            try writer.append(Data("]}\n".utf8))
        } else {
            try writer.append(Data("# Codex Lens — Conversation\n\nThread : \(review.rootThreadID)\n\nSession : \(review.sessionID)\n\n".utf8))
            try writer.append(Data("## Couverture et limites\n\n".utf8))
            for limitation in review.limits { try writer.append(Data("- \(limitation)\n".utf8)) }
            try writer.append(Data("- \(review.redactionPolicy)\n".utf8))
            for issue in review.coverage { try writer.append(Data("- \(issue.category) : \(issue.message) (\(issue.source))\n".utf8)) }
            if !review.excludedReferences.isEmpty {
                try writer.append(Data("\n## Traces legacy exclues des messages\n\n".utf8))
                for ref in review.excludedReferences {
                    try writer.append(Data("- \(ref.id) · \(ref.title) · \(ref.source.path):\(ref.source.line) · \(ref.reason) Liens source confirmés : \(ref.associatedMessageIDs.joined(separator: ", ")).\n".utf8))
                }
            }
            for (index, item) in frozen.enumerated() {
                try Task.checkCancellation()
                let m = item.metadata
                let date = m.timestamp.map { ISO8601DateFormatter().string(from: $0) } ?? "inconnue"
                try writer.append(Data("\n## \(m.role.rawValue) · \(m.id)\n\nDate : \(date) · Tour : \(m.turnID ?? "inconnu") · Agent : \(m.agentID)\n\nEnvironnement enregistré : \(m.environmentID ?? "inconnu")\n\nSource : \(m.source.path):\(m.source.line), décalage \(m.source.offset), longueur \(m.source.length) octets\n\n".utf8))
                for ref in m.supplementarySources { try writer.append(Data("Source associée (référence seulement) : \(ref.path):\(ref.line)\n\n".utf8)) }
                for resource in m.resources { try writer.append(Data("Ressource (\(resource.availability.rawValue), référence seulement) : \(resource.location)\n\n".utf8)) }
                for signal in m.signals { try writer.append(Data("Indice lexical incertain — \(signal.kind.rawValue), « \(signal.cue) » : \(signal.excerpt)\n\n".utf8)) }
                for limitation in m.limitations { try writer.append(Data("Limite : \(limitation)\n\n".utf8)) }
                // An indented block renders untrusted message text as text, including fence markers.
                if let file = item.file { try writer.copy(file, escapingJSON: false, markdownIndent: true) }
                else { try writer.append(Data("Texte indisponible : \(m.status.rawValue).\n".utf8)) }
                reporter?.send(.init(stage: .writingMessages, completed: Int64(index + 1), total: Int64(frozen.count), unit: .messages, step: 1, stepCount: 2))
            }
        }
        reporter?.send(.init(stage: .savingExport, total: 1, unit: .steps, step: 2, stepCount: 2))
        let result = try writer.commit()
        // The completion belongs to the committed destination, never a partial sibling.
        reporter?.send(.init(stage: .savingExport, completed: 1, total: 1, unit: .steps, step: 2, stepCount: 2))
        return ConversationExportReceipt(destination: destination, format: format, messageCount: frozen.count, byteCount: result.count, sha256: result.sha256)
    }

    /// Removes only this capture's private spool. It never deletes an exported document or source.
    public func dispose() {
        state = .disposed; frozen = []; review = nil; messageIndex = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        exportPlan = nil
    }

    private func requirePreparing() throws {
        try Task.checkCancellation()
        guard state == .preparing else { throw LensError.unavailable("Capture fermée pendant la préparation.") }
    }
    private static func timestamp(_ date: Date) -> Date? {
        date == .distantPast || !date.timeIntervalSince1970.isFinite ? nil : date
    }
    private static func clean(_ ref: SourceRef) -> SourceRef {
        SourceRef(path: EvidenceRedaction.redact(ref.path), offset: ref.offset, length: ref.length, line: ref.line, sha256: ref.sha256)
    }
    private static func aliases(_ url: URL) -> [URL] { [url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()] }
    private static func requireMessageSource(_ source: SourceRef) throws {
        guard source.path.hasPrefix("/"), !source.path.contains("\0") else {
            throw LensError.unsupported("Une plage source locale absolue sans caractère NUL est requise ; aucune résolution depuis le répertoire courant.")
        }
        for url in [URL(fileURLWithPath: source.path).standardizedFileURL, URL(fileURLWithPath: source.path).standardizedFileURL.resolvingSymlinksInPath()] {
            let name = url.lastPathComponent.lowercased()
            guard name != "auth.json", !name.hasPrefix(".env"), !name.hasPrefix("id_rsa"), !name.hasPrefix("id_ed25519"),
                  !["pem", "key", "p12"].contains(url.pathExtension.lowercased()) else { throw LensError.unsupported("Source d’authentification protégée ; contenu non lu.") }
        }
    }
    private static func resources(for event: LensEvent, in plan: ConversationExportPlan) -> [ResourceRecord] {
        var seen = Set<String>()
        let resources = (event.resourceIDs.compactMap { plan.resourcesByID[$0] } + (plan.resourcesByEventID[event.id] ?? [])).filter { seen.insert($0.id).inserted }
        return resources.map { resource in
            let cleanID = EvidenceRedaction.redact(resource.id)
            let exportedID = cleanID == resource.id ? resource.id : "redacted-resource:" + SHA256.hash(data: Data(resource.id.utf8)).map { String(format: "%02x", $0) }.joined()
            return ResourceRecord(id: exportedID, location: EvidenceRedaction.redact(resource.location), name: EvidenceRedaction.redact(resource.name),
                roles: resource.roles, agentIDs: resource.agentIDs, environmentID: resource.environmentID.map(EvidenceRedaction.redact),
                eventIDs: resource.eventIDs, evidence: EvidenceRedaction.redact(resource.evidence), availability: resource.availability)
        }
    }
    private static func signals(in text: String) -> [ConversationSignal] {
        let cues: [(ConversationSignalKind, [String])] = [
            (.correction, ["corrige", "ce n’est pas", "ce n'est pas", "plutôt", "instead", "actually", "correct this"]),
            (.preference, ["je préfère", "j’aime", "j'aime", "i prefer", "i would like"]),
            (.constraint, ["il faut", "ne modifie", "sans modifier", "do not", "don't", "must", "préserve", "preserve"]),
            (.continuation, ["continue", "poursuis", "keep going"])
        ]
        return cues.compactMap { kind, candidates in
            guard let found = candidates.compactMap({ cue in text.range(of: cue, options: [.caseInsensitive]).map { (cue, $0) } }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
            let start = text.index(found.1.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(found.1.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
            return ConversationSignal(kind: kind, cue: found.0, excerpt: String(text[start..<end]))
        }
    }
}

private enum ConversationCaptureLimit: LocalizedError {
    case message, storage
    var errorDescription: String? {
        self == .message ? "Limite par message dépassée ; aucun texte partiel exporté." : "Budget de capture dépassé ; aucun texte partiel exporté."
    }
}

/// A pinned parent directory and exclusive 0600 sibling provide an atomic, cancellation-safe
/// streaming transfer. This does not promise directory-entry durability after power failure.
private final class ConversationAtomicWriter {
    private let destination: URL
    private let replaceExisting: Bool
    private let plan: ConversationExportPlan
    private let privateDirectory: URL?
    private let directoryFD: Int32
    private let fd: Int32
    private let temporaryName = ".codexlens-conversation-" + UUID().uuidString + ".partial"
    private var committed = false
    private var count = 0
    private var hasher = SHA256()

    init(destination: URL, replaceExisting: Bool, plan: ConversationExportPlan, privateDirectory: URL?) throws {
        self.destination = destination; self.replaceExisting = replaceExisting; self.plan = plan; self.privateDirectory = privateDirectory
        try Self.requireAllowed(destination, plan: plan, privateDirectory: privateDirectory)
        try Self.validate(destination, replaceExisting: replaceExisting)
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try LocalContentGuard.requireResident(path: parent.path)
        let dir = parent.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dir >= 0 else { throw Self.failure("Ouverture du dossier d’export") }
        do {
            let actual = try Self.openedPath(dir).appendingPathComponent(destination.lastPathComponent)
            try Self.requireAllowed(actual, plan: plan, privateDirectory: privateDirectory)
            try Self.validate(actual, replaceExisting: replaceExisting)
        } catch { _ = close(dir); throw error }
        directoryFD = dir
        let opened = openat(dir, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard opened >= 0 else { _ = close(dir); throw Self.failure("Création du fichier d’export privé") }
        fd = opened
    }
    deinit { _ = close(fd); if !committed { _ = unlinkat(directoryFD, temporaryName, 0) }; _ = close(directoryFD) }
    func append(_ data: Data) throws {
        try Self.write(data, fd: fd); hasher.update(data: data); count += data.count
    }
    func copy(_ file: URL, escapingJSON: Bool, markdownIndent: Bool = false) throws {
        let source = file.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard source >= 0 else { throw Self.failure("Chargement du message") }
        defer { _ = close(source) }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        if markdownIndent { try append(Data("    ".utf8)) }
        while true {
            try Task.checkCancellation()
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if amount < 0 { if errno == EINTR { continue }; throw Self.failure("Chargement du message") }
            if amount == 0 { break }
            var output = Data()
            output.reserveCapacity(amount * 2)
            for byte in bytes.prefix(amount) {
                if escapingJSON {
                    switch byte {
                    case 34: output.append(contentsOf: [92, 34])
                    case 92: output.append(contentsOf: [92, 92])
                    case 0...31: output.append(Data(String(format: "\\u%04x", byte).utf8))
                    default: output.append(byte)
                    }
                } else {
                    output.append(byte)
                    if markdownIndent && byte == 10 { output.append(Data("    ".utf8)) }
                }
            }
            try append(output)
        }
        if markdownIndent { try append(Data("\n".utf8)) }
    }
    func commit() throws -> (count: Int, sha256: String) {
        guard fsync(fd) == 0 else { throw Self.failure("Synchronisation de l’export complet") }
        try Task.checkCancellation()
        let final = try Self.openedPath(directoryFD).appendingPathComponent(destination.lastPathComponent)
        try Self.requireAllowed(final, plan: plan, privateDirectory: privateDirectory)
        try Self.validate(final, replaceExisting: replaceExisting)
        let flags: UInt32 = replaceExisting ? 0 : UInt32(RENAME_EXCL)
        guard renameatx_np(directoryFD, temporaryName, directoryFD, destination.lastPathComponent, flags) == 0 else { throw Self.failure("Installation atomique de l’export") }
        committed = true
        return (count, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                try Task.checkCancellation()
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: position), min(65536, buffer.count - position))
                if written < 0 { if errno == EINTR { continue }; throw failure("Écriture privée") }
                guard written > 0 else { throw LensError.unavailable("Écriture interrompue ; aucun fichier final partiel.") }
                position += written
            }
        }
    }
    private static func requireAllowed(_ destination: URL, plan: ConversationExportPlan, privateDirectory: URL?) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.contains("\0"), !destination.lastPathComponent.isEmpty else { throw LensError.unsupported("Une destination locale absolue est requise.") }
        let protectedRoots = plan.protectedRoots + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")] + (privateDirectory.map { [$0] } ?? [])
        for candidate in aliases(destination) {
            let parts = candidate.pathComponents.map { $0.lowercased() }, name = candidate.lastPathComponent.lowercased()
            guard !parts.contains(where: { [".codex", ".git", ".ssh", ".aws", ".gnupg"].contains($0) }), name != "auth.json",
                  !name.hasPrefix(".env"), !name.hasPrefix("id_rsa"), !name.hasPrefix("id_ed25519"),
                  !["jsonl", "pem", "key", "p12", "sqlite", "sqlite3", "db"].contains(candidate.pathExtension.lowercased()) else { throw LensError.unsupported("Emplacement de source ou d’authentification protégé ; export refusé.") }
            guard !plan.protectedPaths.flatMap(aliases).contains(where: { $0.path == candidate.path }),
                  !protectedRoots.flatMap(aliases).contains(where: { contains(root: $0.path, path: candidate.path) }) else { throw LensError.unsupported("Source ou environnement observé protégé ; export refusé.") }
        }
    }
    private static func aliases(_ url: URL) -> [URL] { [url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()] }
    private static func contains(root: String, path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    private static func validate(_ url: URL, replaceExisting: Bool) throws {
        var metadata = stat()
        if url.path.withCString({ lstat($0, &metadata) }) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw LensError.unsupported("Destination non régulière ; lien symbolique ou répertoire refusé.") }
            guard replaceExisting else { throw LensError.unsupported("Le fichier existe déjà ; remplacement explicite requis.") }
            try LocalContentGuard.requireResident(path: url.path, flags: metadata.st_flags)
            guard metadata.st_nlink == 1 else { throw LensError.unsupported("Destination liée physiquement ; remplacement refusé.") }
        } else if errno != ENOENT { throw failure("Validation de la destination") }
    }
    private static func openedPath(_ fd: Int32) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw failure("Vérification du dossier ouvert") }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
    }
    static func failure(_ operation: String) -> LensError { LensError.unavailable("\(operation) impossible : \(String(cString: strerror(errno))). Aucun export final partiel.") }
}
