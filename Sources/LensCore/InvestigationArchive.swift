import Foundation

public struct InvestigationRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let capsule: EvidenceCapsule
    public let question: String
    public let response: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let inferenceIDs: [String]
    /// An exact local Lens chat UUID. It conveys no ownership of a Codex thread;
    /// only CodexInvestigationRegistry may establish that ownership.
    public let codexChatID: String?
    public let excludedFromAutocollection: Bool
    public let analysisIsSourceEvidence: Bool
    fileprivate init(id: String, capsule: EvidenceCapsule, question: String, response: String? = nil, createdAt: Date, updatedAt: Date, inferenceIDs: [String] = [], codexChatID: String? = nil) {
        self.id = id; self.capsule = capsule; self.question = question; self.response = response; self.createdAt = createdAt; self.updatedAt = updatedAt; self.inferenceIDs = inferenceIDs; self.codexChatID = codexChatID; self.excludedFromAutocollection = true; self.analysisIsSourceEvidence = false
    }
}
public struct InvestigationSummary: Codable, Sendable, Identifiable {
    public let id: String
    public let rootThreadID: String
    public let capsuleID: String
    public let questionPreview: String
    public let createdAt: Date
    public let updatedAt: Date
    public let responseAvailable: Bool
    public let byteCount: Int
    public let codexChatID: String?
}
public struct InvestigationExclusions: Codable, Sendable {
    public let directories: [String]
    public let investigationIDs: [String]
    public let inferenceIDs: [String]
}
public struct ArchiveWriteResult: Codable, Sendable {
    public let record: InvestigationRecord
    public let removedIDs: [String]
    public let bytesUsed: Int
    public let quotaBytes: Int
    public var rotated: Bool { !removedIDs.isEmpty }
}
public struct InvestigationArchiveStatus: Codable, Sendable {
    public let bytesUsed: Int
    public let quotaBytes: Int
    public let recordCount: Int
    public let exclusions: InvestigationExclusions
    public let coverage: [String]
}

/// Local, separate storage for investigations. No captured path is ever opened.
/// Its root and inference IDs are explicitly excluded from session auto-collection.
public actor InvestigationArchive {
    public let directory: URL
    public let quotaBytes: Int
    private let directoryAliases: [String]
    public init(directory: URL? = nil, quotaBytes: Int = 32 * 1024 * 1024) {
        let selected = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexLens/Investigations")
        self.directory = selected.standardizedFileURL.resolvingSymlinksInPath()
        self.directoryAliases = Array(Set([selected.path, selected.standardizedFileURL.path, selected.standardizedFileURL.resolvingSymlinksInPath().path])).sorted()
        self.quotaBytes = max(1024, quotaBytes)
    }

    public func save(capsule: EvidenceCapsule, question: String, inferenceIDs: [String] = [], codexChatID: String? = nil) throws -> ArchiveWriteResult {
        guard try capsule.verifyDigest(), capsule.excludedFromAutocollection else { throw LensError.corrupt("Contexte altéré ou hors du périmètre d’enquête.") }
        _ = try capsule.transmissionJSON()
        if let codexChatID, UUID(uuidString: codexChatID) == nil { throw LensError.unsupported("UUID de chat Lens invalide.") }
        let now = Date()
        let record = InvestigationRecord(id: UUID().uuidString, capsule: capsule, question: EvidenceRedaction.redact(question), createdAt: now, updatedAt: now, inferenceIDs: Self.cleanIDs(inferenceIDs), codexChatID: codexChatID.map { UUID(uuidString: $0)!.uuidString })
        return try write(record)
    }

    public func updateResponse(id: String, response: String, inferenceIDs: [String] = []) throws -> ArchiveWriteResult {
        guard let original = try load(id: id) else { throw LensError.unavailable("Enquête \(id) absente de l'archive.") }
        let record = InvestigationRecord(id: original.id, capsule: original.capsule, question: original.question, response: EvidenceRedaction.redact(response), createdAt: original.createdAt, updatedAt: Date(), inferenceIDs: Self.cleanIDs(original.inferenceIDs + inferenceIDs), codexChatID: original.codexChatID)
        return try write(record)
    }

    /// Draft editing preserves its frozen capsule. Once answered, the question is
    /// immutable so the archived response retains the question it actually answered.
    public func updateQuestion(id: String, question: String, codexChatID: String? = nil) throws -> ArchiveWriteResult {
        guard let original = try load(id: id) else { throw LensError.unavailable("Enquête \(id) absente de l'archive.") }
        guard original.response == nil else { throw LensError.unsupported("Cette enquête possède déjà une réponse ; sa question ne peut plus être modifiée pour préserver l'audit.") }
        if let codexChatID, UUID(uuidString: codexChatID) == nil { throw LensError.unsupported("UUID de chat Lens invalide.") }
        let linkedChatID = codexChatID.map { UUID(uuidString: $0)!.uuidString }
        guard original.codexChatID == nil || linkedChatID == nil || original.codexChatID == linkedChatID else { throw LensError.unsupported("Cette enquête appartient déjà à un autre chat Lens.") }
        let record = InvestigationRecord(id: original.id, capsule: original.capsule, question: EvidenceRedaction.redact(question), createdAt: original.createdAt, updatedAt: Date(), inferenceIDs: original.inferenceIDs, codexChatID: linkedChatID ?? original.codexChatID)
        return try write(record)
    }

    public func load(id: String) throws -> InvestigationRecord? {
        let file = try location(id: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LensError.unavailable("Fichier d'enquête non régulier ; lien symbolique refusé.") }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= quotaBytes else { throw LensError.unsupported("Enquête supérieure au quota local ; lecture refusée.") }
        let record = try CapsuleJSON.decode(InvestigationRecord.self, from: Data(contentsOf: file))
        guard record.id == id, record.excludedFromAutocollection, !record.analysisIsSourceEvidence, try record.capsule.verifyDigest() else { throw LensError.corrupt("Archive altérée ou métadonnées de périmètre invalides : \(id).") }
        guard record.codexChatID == nil || UUID(uuidString: record.codexChatID!) != nil else { throw LensError.corrupt("UUID de chat Lens archivé invalide.") }
        _ = try record.capsule.transmissionJSON()
        return record
    }

    public func list() throws -> [InvestigationSummary] {
        var summaries: [InvestigationSummary] = []
        for file in try storedFiles() {
            guard let record = try? load(id: file.id) else { continue }
            summaries.append(InvestigationSummary(id: record.id, rootThreadID: record.capsule.rootThreadID, capsuleID: record.capsule.id, questionPreview: EvidenceRedaction.utf8Prefix(record.question, limit: 240), createdAt: record.createdAt, updatedAt: record.updatedAt, responseAvailable: record.response != nil, byteCount: file.bytes, codexChatID: record.codexChatID))
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func collectionExclusions() throws -> InvestigationExclusions {
        let files = try storedFiles()
        var inferenceIDs = Set<String>()
        for file in files { if let record = try? load(id: file.id) { inferenceIDs.formUnion(record.inferenceIDs) } }
        return InvestigationExclusions(directories: directoryAliases, investigationIDs: files.map(\.id).sorted(), inferenceIDs: inferenceIDs.sorted())
    }

    public func status() throws -> InvestigationArchiveStatus {
        let files = try storedFiles()
        let invalid = files.filter { (try? load(id: $0.id)) == nil }
        return InvestigationArchiveStatus(bytesUsed: files.reduce(0) { $0 + $1.bytes }, quotaBytes: quotaBytes, recordCount: files.count, exclusions: try collectionExclusions(), coverage: invalid.map { "Archive \($0.id) invalide ou inaccessible ; son contenu n’est pas utilisé." })
    }

    private func write(_ record: InvestigationRecord) throws -> ArchiveWriteResult {
        let data = try CapsuleJSON.encode(record)
        guard data.count <= quotaBytes else { throw LensError.unsupported("Cette enquête demande \(data.count) octets, au-delà du quota \(quotaBytes) ; aucun contenu n'a été tronqué ni écrit.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = try location(id: record.id)
        if FileManager.default.fileExists(atPath: file.path), (try FileManager.default.attributesOfItem(atPath: file.path))[.type] as? FileAttributeType != .typeRegular { throw LensError.unavailable("Emplacement d'enquête non régulier ; écriture refusée.") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var files = try storedFiles()
        var total = files.reduce(0) { $0 + $1.bytes }, removed: [String] = []
        files.sort { $0.modifiedAt < $1.modifiedAt }
        for old in files where total > quotaBytes && old.id != record.id {
            do { try FileManager.default.removeItem(at: old.url); total -= old.bytes; removed.append(old.id) }
            catch { throw LensError.unavailable("Rotation de l'archive interrompue : \(error.localizedDescription). Enquêtes déjà retirées : \(removed.joined(separator: ", ")).") }
        }
        guard total <= quotaBytes else { throw LensError.unavailable("Quota non rétabli après écriture ; consultez le statut de l'archive.") }
        return ArchiveWriteResult(record: record, removedIDs: removed, bytesUsed: total, quotaBytes: quotaBytes)
    }
    private func location(id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/"), !id.contains("\\") else { throw LensError.unsupported("Identifiant d'enquête invalide.") }
        return directory.appendingPathComponent(id + ".json")
    }
    private struct StoredFile { let id: String; let url: URL; let bytes: Int; let modifiedAt: Date }
    private func storedFiles() throws -> [StoredFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]).compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", UUID(uuidString: id) != nil else { return nil }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return StoredFile(id: id, url: file, bytes: values.fileSize ?? 0, modifiedAt: values.contentModificationDate ?? .distantPast)
        }
    }
    private static func cleanIDs(_ ids: [String]) -> [String] { Array(Set(ids.map(EvidenceRedaction.redact).filter { !$0.isEmpty })).sorted() }
}
