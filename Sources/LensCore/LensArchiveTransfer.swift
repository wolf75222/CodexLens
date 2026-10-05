import Foundation
import CryptoKit
import Darwin

/// A frozen, portable value. Paths remain provenance references; importing never opens them.
/// SHA-256 checks content integrity, not the identity or trustworthiness of the exporter.
public struct LensArchiveEnvelope: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let formatIdentifier = "fr.codexlens.investigation"
    public let format: String
    public let schemaVersion: Int
    public let capturedAt: Date
    public let record: InvestigationRecord
    public let sourceRecordID: String?
    /// False for a capture built from UI values: record dates describe this capture,
    /// not an invented historical creation date for an investigation.
    public let recordDatesAreHistorical: Bool
    public let recordSHA256: String
    public let envelopeSHA256: String
    fileprivate init(capturedAt: Date, record: InvestigationRecord, sourceRecordID: String?, recordDatesAreHistorical: Bool, recordSHA256: String, envelopeSHA256: String) {
        self.format = Self.formatIdentifier; self.schemaVersion = Self.currentVersion
        self.capturedAt = capturedAt; self.record = record; self.sourceRecordID = sourceRecordID
        self.recordDatesAreHistorical = recordDatesAreHistorical
        self.recordSHA256 = recordSHA256; self.envelopeSHA256 = envelopeSHA256
    }
}

public struct LensArchiveExportReceipt: Codable, Sendable {
    public let destination: URL
    public let byteCount: Int
    public let capsuleID: String
    public let sourceRecordID: String?
    public let envelopeSHA256: String
}

public struct LensArchiveImportReceipt: Codable, Sendable {
    public let record: InvestigationRecord
    public let sourceRecordID: String?
    public let byteCount: Int
    public let bytesUsed: Int
    public let quotaBytes: Int
    public let envelopeSHA256: String
    /// Imports do not evict existing investigations to make room.
    public let removedIDs: [String]
}

/// Local-only, bounded archive transfer. Call freeze before presenting a save panel,
/// then pass that immutable envelope to export. Supply every known source root,
/// including all accessible worktrees and custom Codex homes, to protect them.
public actor LensArchiveTransfer {
    public let maximumBytes: Int
    private let archive: InvestigationArchive
    private let boundary: ArchiveTransferBoundary
    public init(archive: InvestigationArchive, protectedSourceRoots: [URL], codexDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")], maximumBytes: Int = 32 * 1024 * 1024) {
        self.archive = archive
        self.maximumBytes = min(32 * 1024 * 1024, max(1024, maximumBytes))
        self.boundary = ArchiveTransferBoundary(protectedRoots: protectedSourceRoots, codexRoots: codexDirectories, archiveDirectory: archive.directory)
    }

    public func freeze(capsule: EvidenceCapsule, question: String, response: String?, recordID: String?) throws -> LensArchiveEnvelope {
        try Task.checkCancellation()
        let now = Date()
        let record = try CapsuleJSON.decode(InvestigationRecord.self, from: CapsuleJSON.encode(TransferRecord(id: recordID ?? UUID().uuidString, capsule: capsule, question: EvidenceRedaction.redact(question), response: response.map(EvidenceRedaction.redact), createdAt: now, updatedAt: now, inferenceIDs: [])))
        return try makeEnvelope(record: record, sourceRecordID: recordID, capturedAt: now, historicalDates: false)
    }

    public func freeze(record: InvestigationRecord) throws -> LensArchiveEnvelope {
        try Task.checkCancellation()
        return try makeEnvelope(record: record, sourceRecordID: record.id, capturedAt: Date(), historicalDates: true)
    }

    /// Useful for an initial UI check; export repeats the guard against its frozen data
    /// and against the opened destination directory immediately before committing.
    public func validateExportDestination(_ destination: URL, record: InvestigationRecord? = nil) throws {
        try boundary.requireAllowed(destination, capturedPaths: record.map(Self.capturedPaths) ?? [], allowArchive: false)
        guard destination.isFileURL, ["codexlens", "json"].contains(destination.pathExtension.lowercased()), !destination.lastPathComponent.hasPrefix(".") else { throw LensError.unsupported("Choisissez un fichier .codexlens ou JSON visible, hors des sources observées.") }
        try AtomicArchiveFile.validateTarget(destination, replaceExisting: true)
    }

    public func export(envelope: LensArchiveEnvelope, to destination: URL, replaceExisting: Bool = false) async throws -> LensArchiveExportReceipt {
        let bytes = try validate(envelope)
        try validateExportDestination(destination, record: envelope.record)
        try Task.checkCancellation()
        try AtomicArchiveFile.write(bytes, to: destination, replaceExisting: replaceExisting, boundary: boundary, capturedPaths: Self.capturedPaths(envelope.record), allowArchive: false)
        return LensArchiveExportReceipt(destination: destination.standardizedFileURL, byteCount: bytes.count, capsuleID: envelope.record.capsule.id, sourceRecordID: envelope.sourceRecordID, envelopeSHA256: envelope.envelopeSHA256)
    }

    /// Reads the selected file once, with size checked before opening. A changing,
    /// symbolic, nonresident or nonregular file is rejected rather than hydrated.
    public func inspectImport(from source: URL) throws -> LensArchiveEnvelope {
        try Task.checkCancellation()
        try boundary.requireAllowed(source, capturedPaths: [], allowArchive: false, readingImport: true)
        let bytes = try AtomicArchiveFile.read(source, maximumBytes: maximumBytes, boundary: boundary)
        let envelope: LensArchiveEnvelope
        do { envelope = try CapsuleJSON.decode(LensArchiveEnvelope.self, from: bytes) }
        catch { throw LensError.corrupt("Ce fichier n'est pas une enveloppe d'enquête Codex Lens reconnue : \(error.localizedDescription)") }
        _ = try validate(envelope)
        try Task.checkCancellation()
        return envelope
    }

    /// A fresh private archive ID preserves any existing record, even when the
    /// imported source ID already exists. Capsule bytes/versions are not rebuilt.
    public func `import`(envelope: LensArchiveEnvelope) async throws -> LensArchiveImportReceipt {
        let bytes = try validate(envelope)
        try Task.checkCancellation()
        let imported = try CapsuleJSON.decode(InvestigationRecord.self, from: CapsuleJSON.encode(TransferRecord(id: UUID().uuidString, capsule: envelope.record.capsule, question: envelope.record.question, response: envelope.record.response, createdAt: envelope.record.createdAt, updatedAt: envelope.record.updatedAt, inferenceIDs: envelope.record.inferenceIDs)))
        let result = try await archive.installTransferredRecord(imported, boundary: boundary, capturedPaths: Self.capturedPaths(envelope.record), maximumBytes: maximumBytes)
        return LensArchiveImportReceipt(record: result.record, sourceRecordID: envelope.sourceRecordID, byteCount: bytes.count, bytesUsed: result.bytesUsed, quotaBytes: result.quotaBytes, envelopeSHA256: envelope.envelopeSHA256, removedIDs: result.removedIDs)
    }

    private func makeEnvelope(record: InvestigationRecord, sourceRecordID: String?, capturedAt: Date, historicalDates: Bool) throws -> LensArchiveEnvelope {
        // The archive's established JSON format uses integer milliseconds. Normalize
        // once at freeze, so the value previewed by the UI is exactly exportable.
        let record = try CapsuleJSON.decode(InvestigationRecord.self, from: CapsuleJSON.encode(record))
        let capturedAt = Date(timeIntervalSince1970: (capturedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        try Self.validateRecord(record)
        let recordHash = TransferHash.digest(try CapsuleJSON.encode(record))
        let unsigned = LensArchiveEnvelope(capturedAt: capturedAt, record: record, sourceRecordID: sourceRecordID, recordDatesAreHistorical: historicalDates, recordSHA256: recordHash, envelopeSHA256: "")
        let envelope = LensArchiveEnvelope(capturedAt: capturedAt, record: record, sourceRecordID: sourceRecordID, recordDatesAreHistorical: historicalDates, recordSHA256: recordHash, envelopeSHA256: TransferHash.digest(try CapsuleJSON.encode(unsigned)))
        _ = try validate(envelope)
        return envelope
    }
    private func validate(_ envelope: LensArchiveEnvelope) throws -> Data {
        try Task.checkCancellation()
        guard envelope.format == LensArchiveEnvelope.formatIdentifier, envelope.schemaVersion == LensArchiveEnvelope.currentVersion else { throw LensError.unsupported("Format/version d'archive non pris en charge ; aucune migration implicite.") }
        try Self.validateRecord(envelope.record)
        guard envelope.sourceRecordID == nil || UUID(uuidString: envelope.sourceRecordID!) != nil else { throw LensError.corrupt("Identifiant d'enquête source invalide.") }
        guard envelope.recordSHA256 == TransferHash.digest(try CapsuleJSON.encode(envelope.record)) else { throw LensError.corrupt("Intégrité de l'enquête invalide ; question, réponse ou métadonnées altérées.") }
        let unsigned = LensArchiveEnvelope(capturedAt: envelope.capturedAt, record: envelope.record, sourceRecordID: envelope.sourceRecordID, recordDatesAreHistorical: envelope.recordDatesAreHistorical, recordSHA256: envelope.recordSHA256, envelopeSHA256: "")
        guard envelope.envelopeSHA256 == TransferHash.digest(try CapsuleJSON.encode(unsigned)) else { throw LensError.corrupt("Intégrité de l'enveloppe invalide.") }
        let bytes = try CapsuleJSON.encode(envelope)
        guard bytes.count <= maximumBytes else { throw LensError.unsupported("Archive supérieure à la limite de \(maximumBytes) octets ; aucun contenu n'est tronqué.") }
        return bytes
    }
    private static func validateRecord(_ record: InvestigationRecord) throws {
        guard UUID(uuidString: record.id) != nil, record.excludedFromAutocollection, !record.analysisIsSourceEvidence else { throw LensError.corrupt("Périmètre d’enquête invalide : une réponse du chat ne fait pas partie de l’historique de session.") }
        guard record.capsule.maxEncodedBytes >= 1024, record.capsule.maxEncodedBytes <= 32 * 1024 * 1024, try record.capsule.verifyDigest() else { throw LensError.corrupt("Contexte altéré ou limite de taille invalide.") }
        _ = try record.capsule.transmissionJSON()
        let ids = record.capsule.pieces.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ $0.range(of: #"^E[0-9]{3,6}$"#, options: .regularExpression) != nil }) else { throw LensError.corrupt("Identifiants d’éléments invalides ou répétés.") }
    }
    private static func capturedPaths(_ record: InvestigationRecord) -> [URL] {
        let values = record.capsule.pieces.flatMap { piece in piece.sourceRefs.map(\.path) + [piece.location?.path].compactMap { $0 } }
        return values.compactMap { value in
            if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
            if value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL { return url }
            return nil
        }
    }
}

/// Kept in the same actor as ordinary archive writes so quota/install is serialized.
/// The only storage change is a new complete record; no captured file is opened.
extension InvestigationArchive {
    fileprivate func installTransferredRecord(_ record: InvestigationRecord, boundary: ArchiveTransferBoundary, capturedPaths: [URL], maximumBytes: Int) throws -> ArchiveWriteResult {
        try Task.checkCancellation()
        try boundary.requireAllowed(directory, capturedPaths: capturedPaths, allowArchive: true)
        let data = try CapsuleJSON.encode(record)
        guard data.count <= min(maximumBytes, quotaBytes) else { throw LensError.unsupported("L'enquête importée dépasse la limite/quota privé ; aucun enregistrement n'a été écrit.") }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            var metadata = stat()
            guard directory.path.withCString({ lstat($0, &metadata) }) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw LensError.unavailable("Répertoire d'archive privé non régulier ; lien symbolique refusé.") }
            try LocalContentGuard.requireResident(path: directory.path, flags: metadata.st_flags)
        }
        var used = 0
        if fm.fileExists(atPath: directory.path) {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count <= 10_000 else { throw LensError.unsupported("Archive privée trop dense pour une installation bornée (10 000 entrées maximum).") }
            for file in files {
                try Task.checkCancellation()
                var metadata = stat()
                guard file.path.withCString({ lstat($0, &metadata) }) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else { throw LensError.unavailable("L'archive privée contient une entrée non régulière ; installation refusée.") }
                guard metadata.st_size <= Int64(quotaBytes), used <= quotaBytes - Int(metadata.st_size) else { throw LensError.unsupported("Quota privé déjà dépassé ; aucune enquête existante n'a été retirée.") }
                used += Int(metadata.st_size)
            }
        }
        guard used <= quotaBytes - data.count else { throw LensError.unsupported("Espace insuffisant dans l'archive privée ; aucune rotation ni substitution n'a été effectuée.") }
        try Task.checkCancellation()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent(record.id + ".json")
        try AtomicArchiveFile.write(data, to: destination, replaceExisting: false, boundary: boundary, capturedPaths: capturedPaths, allowArchive: true)
        return ArchiveWriteResult(record: record, removedIDs: [], bytesUsed: used + data.count, quotaBytes: quotaBytes)
    }
}

private struct TransferRecord: Encodable {
    let id: String
    let capsule: EvidenceCapsule
    let question: String
    let response: String?
    let createdAt: Date
    let updatedAt: Date
    let inferenceIDs: [String]
    let excludedFromAutocollection = true
    let analysisIsSourceEvidence = false
}
private enum TransferHash {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

fileprivate struct ArchiveTransferBoundary: Sendable {
    private let protectedRoots: [URL]
    private let codexRoots: [URL]
    private let archiveDirectory: URL
    init(protectedRoots: [URL], codexRoots: [URL], archiveDirectory: URL) {
        self.protectedRoots = protectedRoots.filter(\.isFileURL).flatMap(Self.aliases)
        self.codexRoots = codexRoots.filter(\.isFileURL).flatMap(Self.aliases)
        self.archiveDirectory = archiveDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }
    func requireAllowed(_ url: URL, capturedPaths: [URL], allowArchive: Bool, readingImport: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw LensError.unsupported("Un emplacement local absolu est requis ; aucun transfert distant.") }
        let candidates = Self.aliases(url)
        let sourcePaths = capturedPaths.flatMap(Self.aliases).map(\.path)
        // Keep the initial aliases protected and also resolve their current targets.
        // A root symlink repointed after the panel opened cannot create a bypass.
        let currentProtectedRoots = protectedRoots.flatMap(Self.aliases)
        let currentCodexRoots = codexRoots.flatMap(Self.aliases)
        let currentArchiveRoots = Self.aliases(archiveDirectory)
        for candidate in candidates {
            let path = candidate.path
            let parts = candidate.pathComponents.map { $0.lowercased() }
            let name = candidate.lastPathComponent.lowercased()
            guard !parts.contains(".codex"), !parts.contains(".git"), !parts.contains(".ssh"), !parts.contains(".aws"), !parts.contains(".gnupg"), name != "auth.json", !name.hasPrefix(".env"), !name.hasPrefix("id_rsa"), !name.hasPrefix("id_ed25519"), !["jsonl", "pem", "key", "p12", "sqlite", "sqlite3", "db"].contains(candidate.pathExtension.lowercased()) else { throw LensError.unsupported("Source/log ou emplacement d'authentification protégé ; transfert refusé.") }
            guard !currentCodexRoots.contains(where: { Self.contains(root: $0.path, path: path) }) else { throw LensError.unsupported("Répertoire Codex protégé ; aucune lecture/écriture de transfert à cet endroit.") }
            guard (readingImport || !currentProtectedRoots.contains(where: { Self.contains(root: $0.path, path: path) })), !sourcePaths.contains(path) else { throw LensError.unsupported("Emplacement d'une source observée protégé ; aucune écriture d'export à cet endroit.") }
            if !allowArchive, currentArchiveRoots.contains(where: { Self.contains(root: $0.path, path: path) }) { throw LensError.unsupported("L'archive privée interne n'est pas une destination/source de transfert externe.") }
        }
    }
    private static func aliases(_ url: URL) -> [URL] { [url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()] }
    private static func contains(root: String, path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
}

fileprivate enum AtomicArchiveFile {
    static func validateTarget(_ url: URL, replaceExisting: Bool) throws {
        var metadata = stat()
        if url.path.withCString({ lstat($0, &metadata) }) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw LensError.unavailable("Destination non régulière ; liens symboliques et répertoires refusés.") }
            guard replaceExisting else { throw LensError.unsupported("Le fichier existe déjà ; confirmation explicite de remplacement requise.") }
            try LocalContentGuard.requireResident(path: url.path, flags: metadata.st_flags)
            guard metadata.st_nlink == 1 else { throw LensError.unsupported("Destination liée physiquement à un autre fichier ; remplacement refusé.") }
        } else if errno != ENOENT { throw failure("Validation de la destination") }
    }
    static func read(_ url: URL, maximumBytes: Int, boundary: ArchiveTransferBoundary) throws -> Data {
        var before = stat()
        guard url.path.withCString({ lstat($0, &before) }) == 0 else { throw failure("Lecture de l'archive") }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw LensError.unavailable("Archive non régulière ; liens symboliques refusés.") }
        try LocalContentGuard.requireResident(path: url.path, flags: before.st_flags)
        guard before.st_size <= Int64(maximumBytes) else { throw LensError.unsupported("Archive supérieure à la limite de \(maximumBytes) octets ; fichier non lu.") }
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw failure("Ouverture de l'archive") }
        defer { _ = close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameFile(before, opened) else { throw LensError.unavailable("Archive modifiée entre sa sélection et son ouverture ; lecture refusée.") }
        try boundary.requireAllowed(try openedPath(fd), capturedPaths: [], allowArchive: false, readingImport: true)
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw failure("Lecture bornée de l'archive") }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw LensError.unsupported("Archive agrandie pendant la lecture ; limite dépassée, contenu rejeté.") }
            data.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, sameFile(opened, after), data.count == Int(before.st_size) else { throw LensError.unavailable("Archive modifiée pendant la lecture ; aucune version partielle importée.") }
        return data
    }
    static func write(_ data: Data, to destination: URL, replaceExisting: Bool, boundary: ArchiveTransferBoundary, capturedPaths: [URL], allowArchive: Bool) throws {
        try Task.checkCancellation()
        try boundary.requireAllowed(destination, capturedPaths: capturedPaths, allowArchive: allowArchive)
        try validateTarget(destination, replaceExisting: replaceExisting)
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try LocalContentGuard.requireResident(path: parent.path)
        let directoryFD = parent.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw failure("Ouverture du répertoire de destination") }
        defer { _ = close(directoryFD) }
        let actualParent = try openedPath(directoryFD)
        let actualDestination = actualParent.appendingPathComponent(destination.lastPathComponent)
        try boundary.requireAllowed(actualDestination, capturedPaths: capturedPaths, allowArchive: allowArchive)
        try validateTarget(actualDestination, replaceExisting: replaceExisting)
        let temporaryName = ".codexlens-transfer-" + UUID().uuidString + ".partial"
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw failure("Création du fichier de transfert privé") }
        var committed = false
        defer { _ = close(fd); if !committed { _ = unlinkat(directoryFD, temporaryName, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                if count < 0 { if errno == EINTR { continue }; throw failure("Écriture du fichier de transfert") }
                guard count > 0 else { throw LensError.unavailable("Écriture interrompue ; aucun fichier final partiel.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("Synchronisation du fichier complet") }
        try Task.checkCancellation()
        let currentParent = try openedPath(directoryFD)
        let finalURL = currentParent.appendingPathComponent(destination.lastPathComponent)
        try boundary.requireAllowed(finalURL, capturedPaths: capturedPaths, allowArchive: allowArchive)
        try validateTarget(finalURL, replaceExisting: replaceExisting)
        let flags: UInt32 = replaceExisting ? 0 : UInt32(RENAME_EXCL)
        guard renameatx_np(directoryFD, temporaryName, directoryFD, destination.lastPathComponent, flags) == 0 else { throw failure("Installation atomique du fichier complet") }
        committed = true
        // No suspension/cancellation error after commit: a successful rename is the result.
        // File contents are fsynced; crash durability of the directory entry is not promised.
    }
    private static func openedPath(_ fd: Int32) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw failure("Vérification du répertoire ouvert") }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func failure(_ operation: String) -> LensError { LensError.unavailable("\(operation) impossible : \(String(cString: strerror(errno))). Aucun fichier final partiel n'est présenté.") }
}
