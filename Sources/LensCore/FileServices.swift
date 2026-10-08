import Foundation
import Darwin
import CryptoKit

/// Paths remain lexical absolute paths: `src/main.swift` in two worktrees has two identities.
public struct FileEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var isSymbolicLink: Bool
    public var isRestricted: Bool
    public init(id: String, name: String, isDirectory: Bool, size: UInt64 = 0, isSymbolicLink: Bool = false, isRestricted: Bool = false) {
        self.id = id; self.name = name; self.isDirectory = isDirectory; self.size = size
        self.isSymbolicLink = isSymbolicLink; self.isRestricted = isRestricted
    }
}

/// A page of the CURRENT local file, never a historical reconstruction.
public struct TextPage: Codable, Sendable {
    public var text: String
    public var nextOffset: UInt64?
    public var totalBytes: UInt64
    public var observedAt: Date
    public var version: String
    public init(text: String, nextOffset: UInt64?, totalBytes: UInt64, observedAt: Date = Date(), version: String = "") {
        self.text = text; self.nextOffset = nextOffset; self.totalBytes = totalBytes
        self.observedAt = observedAt; self.version = version
    }
}

/// Live metadata is intentionally separate from EnvironmentRecord's recorded branch/ref.
public struct EnvironmentInspection: Codable, Sendable {
    public var path: String
    public var repositoryPath: String?
    public var worktreePath: String?
    public var branch: String?
    public var head: String?
    public var exists: Bool
    public var observedAt: Date
    public init(path: String, repositoryPath: String? = nil, worktreePath: String? = nil, branch: String? = nil, head: String? = nil, exists: Bool, observedAt: Date = Date()) {
        self.path = path; self.repositoryPath = repositoryPath; self.worktreePath = worktreePath
        self.branch = branch; self.head = head; self.exists = exists; self.observedAt = observedAt
    }
}

/// This is an observation of the worktree/index, without attribution to any session or agent.
public struct CurrentDiff: Codable, Sendable {
    public var text: String
    public var reference: String
    public var observedAt: Date
    public var excludedPaths: [String]
    public init(text: String, reference: String, observedAt: Date = Date(), excludedPaths: [String] = []) {
        self.text = text; self.reference = reference; self.observedAt = observedAt; self.excludedPaths = excludedPaths
    }
}

/// Verified bytes from a regular Git blob at the session's recorded commit.
/// This proves committed content only, not the dirty worktree content at an event's time.
public struct HistoricalText: Codable, Sendable {
    public var text: String
    public var reference: String
    public var blobID: String
    /// Repository-relative path, scoped by the associated EnvironmentRecord.
    public var path: String
    public init(text: String, reference: String, blobID: String, path: String) {
        self.text = text; self.reference = reference; self.blobID = blobID; self.path = path
    }
}

public enum FileServiceError: LocalizedError, Sendable {
    case invalidPath(String), unavailable(String), restricted(String), binary(String), staleFile(String)
    case invalidOffset(String), outputTooLarge, notRepository(String), gitFailure(String), timedOut
    case invalidReference(String), historicalUnavailable(String), objectUnavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Le chemin doit être absolu : \(path)"
        case .unavailable(let path): return "Contenu local indisponible : \(path)"
        case .restricted(let path): return "Lecture exclue : ce fichier peut contenir des identifiants d’authentification (\(path))."
        case .binary(let path): return "Ce fichier n’est pas du texte UTF-8 : \(path)"
        case .staleFile(let path): return "Le fichier a changé pendant la lecture. Rechargez son état actuel : \(path)"
        case .invalidOffset(let path): return "Position de lecture invalide ou située au milieu d’un caractère UTF-8 : \(path)"
        case .outputTooLarge: return "La lecture dépasse la limite de 8 Mio. Pour un diff, sélectionnez un fichier pour réduire le périmètre."
        case .notRepository(let path): return "Aucun worktree Git accessible à cet emplacement : \(path)"
        case .gitFailure(let message): return "Lecture Git impossible : \(message)"
        case .timedOut: return "La lecture Git a dépassé 15 secondes."
        case .objectUnavailable(let id): return "Objet Git enregistré indisponible dans le dépôt associé : \(id)"
        case .invalidReference(let reference): return "La version historique exige le SHA complet du commit enregistré pour cet environnement : \(reference)"
        case .historicalUnavailable(let message): return "Version Git historique indisponible : \(message)"
        }
    }
}

/// The actor performs disk/process work away from the UI. No API writes or executes source files.
public actor FileService {
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Date
        var changed: Date
        var inode: UInt64
        var device: UInt64
        var version: String { "\(device):\(inode):\(size):\(modified.timeIntervalSince1970):\(changed.timeIntervalSince1970)" }
    }
    private var openVersions: [String: Stamp] = [:]
    private var versionOrder: [String] = []
    private let manager = FileManager.default
    public init() {}

    public func inspect(environment: EnvironmentRecord) async throws -> EnvironmentInspection {
        let url = try absoluteURL(environment.path)
        try ensureAllowed(url)
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            return EnvironmentInspection(path: environment.path, exists: false)
        }
        var inspection = EnvironmentInspection(path: environment.path, exists: true)
        guard let roots = try? await git(.roots, at: url), roots.status == 0 else { return inspection }
        let lines = roots.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2 else { return inspection }
        inspection.worktreePath = lines[0]
        let commonURL = lines[1].hasPrefix("/") ? URL(fileURLWithPath: lines[1]) : url.appendingPathComponent(lines[1]).standardizedFileURL
        inspection.repositoryPath = commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent().path : commonURL.path
        if let result = try? await git(.branch, at: url), result.status == 0 {
            let branch = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            inspection.branch = branch.isEmpty ? nil : branch
        }
        if let result = try? await git(.head, at: url), result.status == 0 {
            inspection.head = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        inspection.observedAt = Date()
        return inspection
    }

    /// One level only; the view lazily requests children when a directory is expanded.
    public func children(path: String) async throws -> [FileEntry] {
        let url = try absoluteURL(path)
        try ensureAllowed(url)
        guard let names = try? manager.contentsOfDirectory(atPath: url.path) else {
            throw FileServiceError.unavailable(url.path)
        }
        var entries: [FileEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            entries.append(autoreleasepool { childEntry(name: name, in: url) })
        }
        return sortedChildren(entries)
    }

    /// Search-only shallow enumeration: retain at most the remaining entry
    /// budget and read one extra name to distinguish truncation from exact EOF.
    /// DIR keeps a bounded native buffer; no complete names array is constructed.
    func searchChildren(path: String, maxEntries: Int) async throws -> FileSearchDirectoryListing {
        guard maxEntries > 0 else { throw FileSearchError.invalidOptions }
        try Task.checkCancellation()
        let url = try absoluteURL(path)
        try ensureAllowed(url)
        guard let directory = opendir(url.path) else { throw FileServiceError.unavailable(url.path) }
        defer { closedir(directory) }
        var entries: [FileEntry] = []
        entries.reserveCapacity(min(maxEntries, 1024))
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let record = readdir(directory) else {
                guard errno == 0 else { throw FileServiceError.unavailable(url.path) }
                return FileSearchDirectoryListing(entries: sortedChildren(entries), hasMore: false)
            }
            let nameCapacity = MemoryLayout.size(ofValue: record.pointee.d_name)
            let name = withUnsafePointer(to: &record.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw FileServiceError.unavailable(url.path) }
            if name == "." || name == ".." { continue }
            if entries.count == maxEntries {
                return FileSearchDirectoryListing(entries: sortedChildren(entries), hasMore: true)
            }
            entries.append(autoreleasepool { childEntry(name: name, in: url) })
        }
    }

    private func childEntry(name: String, in url: URL) -> FileEntry {
        // Preserve lexical IDs for directory aliases, including symlink roots.
        let child = url.appendingPathComponent(name)
        let original = (try? manager.attributesOfItem(atPath: child.path)) ?? [:]
        let isLink = original[.type] as? FileAttributeType == .typeSymbolicLink
        var directory: ObjCBool = false
        _ = manager.fileExists(atPath: child.path, isDirectory: &directory)
        let restricted = isRestricted(child) || isRestricted(child.resolvingSymlinksInPath())
        let size = (original[.size] as? NSNumber)?.uint64Value ?? 0
        return FileEntry(id: child.path, name: child.lastPathComponent, isDirectory: directory.boolValue, size: size,
            isSymbolicLink: isLink, isRestricted: restricted)
    }

    private func sortedChildren(_ entries: [FileEntry]) -> [FileEntry] {
        autoreleasepool {
            entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Reuse only offsets returned by this method. Offset zero starts a new current-file observation.
    /// UTF-8 boundaries are preserved; a page can exceed `limit` by at most three bytes.
    public func readText(path: String, offset: UInt64 = 0, limit: Int = 65536, expectedVersion: String? = nil) async throws -> TextPage {
        let url = try absoluteURL(path)
        try ensureAllowed(url)
        let before = try stamp(url)
        if let expectedVersion {
            guard expectedVersion == before.version else { throw FileServiceError.staleFile(url.path) }
        } else if offset > 0 {
            guard let expected = openVersions[url.path] else { throw FileServiceError.invalidOffset(url.path) }
            guard expected == before else { throw FileServiceError.staleFile(url.path) }
        }
        guard offset <= before.size else { throw FileServiceError.invalidOffset(url.path) }
        let pageLimit = min(max(limit, 1), 1_048_576)
        let handle: FileHandle
        let contentURL = url.resolvingSymlinksInPath()
        try ensureAllowed(contentURL)
        do { handle = try FileHandle(forReadingFrom: contentURL) } catch { throw FileServiceError.unavailable(url.path) }
        defer { try? handle.close() }
        // An overlap recognizes common credential/private-key forms even across page boundaries.
        let scanStart = offset > 512 ? offset - 512 : 0
        try handle.seek(toOffset: scanStart)
        let scan = try handle.read(upToCount: pageLimit + 1027) ?? Data()
        let leading = Int(offset - scanStart)
        guard leading <= scan.count else { throw FileServiceError.staleFile(url.path) }
        try rejectSecretContent(scan, path: url.path)
        let data = scan.subdata(in: leading..<min(scan.count, leading + pageLimit + 3))
        guard !data.contains(0) else { throw FileServiceError.binary(url.path) }
        var byteCount = min(pageLimit, data.count)
        var text: String?
        // Up to three trailing bytes can belong to an incomplete UTF-8 character.
        for end in stride(from: byteCount, through: max(0, byteCount - 3), by: -1) {
            if let decoded = String(data: data.prefix(end), encoding: .utf8), end > 0 || data.isEmpty {
                byteCount = end; text = decoded; break
            }
        }
        if text == nil && byteCount <= 3 {
            for end in (byteCount + 1)...max(byteCount + 1, min(data.count, byteCount + 3)) where end <= data.count {
                if let decoded = String(data: data.prefix(end), encoding: .utf8) { byteCount = end; text = decoded; break }
            }
        }
        guard let text else {
            if offset > 0, let first = data.first, first & 0xc0 == 0x80 { throw FileServiceError.invalidOffset(url.path) }
            throw FileServiceError.binary(url.path)
        }
        // Do not accept a trailing broken UTF-8 sequence at the true end of the file.
        if offset + UInt64(data.count) == before.size, byteCount < data.count,
           String(data: data, encoding: .utf8) == nil { throw FileServiceError.binary(url.path) }
        let after = try stamp(url)
        guard before == after else { throw FileServiceError.staleFile(url.path) }
        remember(after, path: url.path)
        let next = offset + UInt64(byteCount)
        return TextPage(text: text, nextOffset: next < after.size ? next : nil, totalBytes: after.size, version: after.version)
    }

    /// The native image/PDF preview uses the same read-only guards as the text browser.
    /// The returned URL refers to currently accessible bytes, not an event-time snapshot.
    public func previewURL(path: String) async throws -> URL {
        let url = try absoluteURL(path)
        try ensureAllowed(url)
        _ = try stamp(url)
        guard manager.isReadableFile(atPath: url.path) else { throw FileServiceError.unavailable(url.path) }
        return url.resolvingSymlinksInPath()
    }

    /// With a recorded reference, compares that verified commit with the entire
    /// current tracked worktree; `staged` applies only to the default index modes.
    /// A commit baseline cannot reconstruct session-start dirty files or attribute edits.
    public func currentDiff(environment: EnvironmentRecord, relativePath: String? = nil, staged: Bool = false, recordedReference: String? = nil) async throws -> CurrentDiff {
        let interval = LensSignposts.begin("CurrentGitDiff")
        defer { interval.end() }
        if let recordedReference {
            guard recordedReference.range(of: #"\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z"#, options: .regularExpression) != nil,
                  let recordedRef = environment.recordedRef,
                  recordedRef.caseInsensitiveCompare(recordedReference) == .orderedSame else {
                throw FileServiceError.invalidReference(recordedReference)
            }
        }
        let inspection = try await inspect(environment: environment)
        guard inspection.exists, let worktree = inspection.worktreePath else { throw FileServiceError.notRepository(environment.path) }
        let root = URL(fileURLWithPath: worktree, isDirectory: true).standardizedFileURL
        let commit: String?
        if let recordedReference { commit = try await verifiedCommit(recordedReference, at: root) }
        else { commit = nil }
        let indexComparison = recordedReference == nil && staged
        let diffReference = commit ?? (indexComparison ? inspection.head : nil)
        let names = try await git(.names(staged: indexComparison, reference: diffReference), at: root)
        guard names.status == 0 else { throw FileServiceError.gitFailure(names.text) }
        let changedPaths = names.text.split(separator: "\0").map(String.init)
        var selectedPaths = changedPaths
        if let relativePath {
            let fileURL = relativePath.hasPrefix("/") ? URL(fileURLWithPath: relativePath).standardizedFileURL : root.appendingPathComponent(relativePath).standardizedFileURL
            guard fileURL.path.hasPrefix(root.path + "/") else { throw FileServiceError.invalidPath(relativePath) }
            try ensureAllowed(fileURL)
            let relative = String(fileURL.path.dropFirst(root.path.count + 1))
            selectedPaths = changedPaths.filter { $0 == relative }
        }
        let excluded = selectedPaths.filter { isRestricted(root.appendingPathComponent($0)) || isRestricted(root.appendingPathComponent($0).resolvingSymlinksInPath()) }
        let allowed = selectedPaths.filter { !excluded.contains($0) }
        let reference: String
        if let commit { reference = "Commit enregistré \(commit) → worktree actuel" }
        else { reference = staged ? "HEAD \(inspection.head ?? "(branche sans commit)") → index actuel" : "Index actuel → worktree actuel (HEAD observé \(inspection.head ?? "sans commit"))" }
        guard !allowed.isEmpty else { return CurrentDiff(text: "", reference: reference, excludedPaths: excluded) }
        let result = try await git(.diff(staged: indexComparison, paths: allowed, reference: diffReference), at: root)
        guard result.status == 0 else { throw FileServiceError.gitFailure(result.text) }
        try rejectSecretContent(Data(result.text.utf8), path: root.path)
        return CurrentDiff(text: result.text, reference: reference, excludedPaths: excluded)
    }

    /// Resolves only the immutable 40-hex SHA recorded for this environment. It never checks out,
    /// modifies a branch, reads the current file as history, or attempts patch reconstruction.
    public func historicalText(environment: EnvironmentRecord, relativePath: String, reference: String) async throws -> HistoricalText {
        let hexPattern = "^[0-9a-fA-F]{40}$"
        guard reference.range(of: hexPattern, options: .regularExpression) != nil,
              let recordedRef = environment.recordedRef,
              recordedRef.caseInsensitiveCompare(reference) == .orderedSame else {
            throw FileServiceError.invalidReference(reference)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FileServiceError.invalidPath(relativePath)
        }
        let inspection = try await inspect(environment: environment)
        let root: URL
        if let worktree = inspection.worktreePath {
            root = try absoluteURL(worktree)
        } else if let repository = environment.repositoryPath {
            // A surviving repository can retain the objects of a removed historical worktree.
            root = try absoluteURL(repository)
        } else { throw FileServiceError.historicalUnavailable("Dépôt contenant le commit introuvable.") }
        try ensureAllowed(root)
        try ensureAllowed(root.appendingPathComponent(relativePath))
        let commit = try await verifiedCommit(reference, at: root)
        let tree = try await git(.treeEntry(commit: commit, path: relativePath), at: root)
        guard tree.status == 0 else { throw FileServiceError.historicalUnavailable("Arbre du commit inaccessible.") }
        let entries = tree.text.split(separator: "\0", omittingEmptySubsequences: true)
        guard entries.count == 1, let separator = entries[0].firstIndex(of: "\t"),
              String(entries[0][entries[0].index(after: separator)...]) == relativePath else {
            throw FileServiceError.historicalUnavailable("Le fichier \(relativePath) n’existe pas dans le commit enregistré.")
        }
        let fields = entries[0][..<separator].split(separator: " ")
        guard fields.count == 3, fields[1] == "blob", fields[0] == "100644" || fields[0] == "100755" else {
            throw FileServiceError.historicalUnavailable("Cette entrée Git n’est pas un fichier régulier (dossier, lien ou sous-module).")
        }
        let blob = String(fields[2])
        guard blob.range(of: hexPattern, options: .regularExpression) != nil else {
            throw FileServiceError.historicalUnavailable("Identifiant de blob invalide.")
        }
        let blobType = try await git(.objectType(blob), at: root)
        guard blobType.status == 0, blobType.text.trimmingCharacters(in: .whitespacesAndNewlines) == "blob" else {
            throw FileServiceError.historicalUnavailable("Objet blob absent ou invalide.")
        }
        let blobSize = try await git(.objectSize(blob), at: root)
        guard blobSize.status == 0, let size = UInt64(blobSize.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FileServiceError.historicalUnavailable("Taille du blob non vérifiable.")
        }
        guard size <= 8_388_608 else { throw FileServiceError.outputTooLarge }
        let contents = try await git(.blob(blob), at: root)
        guard contents.status == 0, UInt64(contents.text.utf8.count) == size else {
            throw FileServiceError.historicalUnavailable("Le blob n’a pas pu être lu intégralement.")
        }
        var objectBytes = Data("blob \(size)\0".utf8)
        objectBytes.append(contents.text.data(using: .utf8) ?? Data())
        // Git's 40-hex object format uses SHA-1; recomputing it detects corrupted/misnamed bytes.
        let actualBlob = Insecure.SHA1.hash(data: objectBytes).map { String(format: "%02x", $0) }.joined()
        guard actualBlob == blob.lowercased() else {
            throw FileServiceError.historicalUnavailable("Les octets lus ne correspondent pas à l’identifiant du blob.")
        }
        guard !contents.text.contains("\0") else { throw FileServiceError.binary(relativePath) }
        try rejectSecretContent(Data(contents.text.utf8), path: relativePath)
        return HistoricalText(text: contents.text, reference: commit, blobID: blob, path: relativePath)
    }

    private struct BlobKey: Hashable {
        let environment: String, repository: String?, path: String, object: String
    }
    private struct BlobFlight {
        let id: UUID, task: Task<VerifiedFileVersion, Error>
        var readers: Set<UUID>
    }
    private var blobFlights: [BlobKey: BlobFlight] = [:]
    private var blobCache: [BlobKey: VerifiedFileVersion] = [:]
    private var blobOrder: [BlobKey] = []
    private var blobBytes = 0, blobHits = 0, blobLoads = 0
    /// UTF-8 payload budget; native text layout and transient Git buffers are separate.
    public static let blobCacheBudget = 16 * 1024 * 1024
    public func blobCacheStatistics() -> (entries: Int, bytes: Int, hits: Int, loads: Int, inFlight: Int, readers: Int) {
        (blobCache.count, blobBytes, blobHits, blobLoads, blobFlights.count, blobFlights.values.reduce(0) { $0 + $1.readers.count })
    }
    public func clearBlobCache() { blobCache.removeAll(); blobOrder.removeAll(); blobBytes = 0 }

    /// Only immutable full object IDs. Never reads the current file, checks out, writes,
    /// fetches, runs filters or resolves ambiguous prefixes. Associated repository fallback
    /// is available for a removed worktree. Scope checks run even on a cache hit.
    public func recordedBlob(environment: EnvironmentRecord, recordedPath: String, objectID: String) async throws -> VerifiedFileVersion {
        try Task.checkCancellation()
        guard RecordedFileVersion.isFullObjectID(objectID), !objectID.allSatisfy({ $0 == "0" }) else { throw FileServiceError.invalidReference(objectID) }
        let envURL = try absoluteURL(environment.path)
        let path: String
        if recordedPath.hasPrefix("/") {
            let normalized = (recordedPath as NSString).standardizingPath
            guard normalized.hasPrefix(envURL.path + "/") else { throw FileServiceError.invalidPath(recordedPath) }
            path = normalized
        } else {
            let parts = recordedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !recordedPath.contains("\0") else { throw FileServiceError.invalidPath(recordedPath) }
            path = envURL.appendingPathComponent(recordedPath).path
        }
        try ensureAllowed(envURL); try ensureAllowed(try absoluteURL(path))
        let key = BlobKey(environment: environment.id, repository: environment.repositoryPath, path: path, object: objectID.lowercased())
        if let cached = blobCache[key] {
            blobHits += 1; blobOrder.removeAll { $0 == key }; blobOrder.append(key)
            return cached
        }
        let reader = UUID(), flightID: UUID, job: Task<VerifiedFileVersion, Error>
        if var flight = blobFlights[key] {
            flight.readers.insert(reader); blobFlights[key] = flight; flightID = flight.id; job = flight.task
        } else {
            var isDirectory: ObjCBool = false
            let root = manager.fileExists(atPath: envURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? envURL : try absoluteURL(environment.repositoryPath ?? environment.path)
            try ensureAllowed(root)
            flightID = UUID(); blobLoads += 1
            job = Task { try await self.readVerifiedBlob(objectID: key.object, at: root, path: path) }
            blobFlights[key] = BlobFlight(id: flightID, task: job, readers: [reader])
        }
        return try await withTaskCancellationHandler {
            defer { releaseBlobReader(key: key, flightID: flightID, reader: reader) }
            let value = try await job.value
            try Task.checkCancellation()
            if blobCache[key] == nil { rememberBlob(value, key: key) }
            return value
        } onCancel: {
            Task { await self.releaseBlobReader(key: key, flightID: flightID, reader: reader) }
        }
    }
    private func releaseBlobReader(key: BlobKey, flightID: UUID, reader: UUID) {
        guard var flight = blobFlights[key], flight.id == flightID else { return }
        flight.readers.remove(reader)
        if flight.readers.isEmpty { flight.task.cancel(); blobFlights.removeValue(forKey: key) }
        else { blobFlights[key] = flight }
    }
    private func rememberBlob(_ value: VerifiedFileVersion, key: BlobKey) {
        let cost = value.text?.utf8.count ?? 0
        guard cost <= Self.blobCacheBudget else { return }
        while blobBytes + cost > Self.blobCacheBudget || blobCache.count >= 32 {
            guard !blobOrder.isEmpty else { break }
            let old = blobOrder.removeFirst(); blobBytes -= blobCache.removeValue(forKey: old)?.text?.utf8.count ?? 0
        }
        blobCache[key] = value; blobOrder.append(key); blobBytes += cost
    }
    private func readVerifiedBlob(objectID: String, at root: URL, path: String) async throws -> VerifiedFileVersion {
        let span = LensSignposts.begin("RecordedGitBlobLoad"); defer { span.end() }
        let type = try await git(.objectType(objectID), at: root)
        guard type.status == 0 else { throw FileServiceError.objectUnavailable(objectID) }
        guard type.text.trimmingCharacters(in: .whitespacesAndNewlines) == "blob" else { throw FileServiceError.historicalUnavailable("L’objet enregistré n’est pas un blob de fichier.") }
        let size = try await git(.objectSize(objectID), at: root)
        guard size.status == 0, let count = Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 else { throw FileServiceError.historicalUnavailable("Taille du blob non vérifiable.") }
        guard count <= RecordedDiff.maximumInputBytes else { throw FileServiceError.outputTooLarge }
        try Task.checkCancellation()
        let content = try await git(.blob(objectID), at: root)
        guard content.status == 0, content.text.utf8.count == count, RecordedFileVersion.objectID(text: content.text, length: objectID.count) == objectID else { throw FileServiceError.historicalUnavailable("Les octets lus ne correspondent pas à l’empreinte du blob enregistré.") }
        guard !content.text.contains("\0") else { throw FileServiceError.binary(path) }
        try rejectSecretContent(Data(content.text.utf8), path: path)
        try Task.checkCancellation()
        return VerifiedFileVersion(text: content.text, objectID: objectID)
    }

    private func absoluteURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw FileServiceError.invalidPath(path) }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func ensureAllowed(_ url: URL) throws {
        if isRestricted(url) || isRestricted(url.resolvingSymlinksInPath()) { throw FileServiceError.restricted(url.path) }
    }

    private func isRestricted(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let name = components.last ?? ""
        let names: Set<String> = ["auth.json", "credentials", "credentials.json", "token.json", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "application_default_credentials.json", "credentials.db", "accesstokens.json"]
        if names.contains(name) || name == ".env" || name.hasPrefix(".env.") { return true }
        if ["pem", "key", "p12", "pfx", "jks", "keystore"].contains(url.pathExtension.lowercased()) { return true }
        return components.contains(".ssh") || components.contains(".aws") || components.contains(".gnupg")
    }

    private func rejectSecretContent(_ data: Data, path: String) throws {
        let text = String(decoding: data, as: UTF8.self)
        let patterns = ["-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----", "\\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\\b"]
        for pattern in patterns where text.range(of: pattern, options: .regularExpression) != nil { throw FileServiceError.restricted(path) }
    }

    private func stamp(_ url: URL) throws -> Stamp {
        let resolved = url.resolvingSymlinksInPath()
        try ensureAllowed(resolved)
        guard let attrs = try? manager.attributesOfItem(atPath: resolved.path), attrs[.type] as? FileAttributeType == .typeRegular else {
            throw FileServiceError.unavailable(url.path)
        }
        var metadata = stat()
        guard resolved.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else { throw FileServiceError.unavailable(url.path) }
        try LocalContentGuard.requireResident(path: resolved.path, flags: metadata.st_flags)
        return Stamp(size: UInt64(max(0, metadata.st_size)),
                     modified: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000),
                     changed: Date(timeIntervalSince1970: Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1_000_000_000),
                     inode: UInt64(metadata.st_ino), device: UInt64(metadata.st_dev))
    }

    private func remember(_ stamp: Stamp, path: String) {
        openVersions[path] = stamp
        versionOrder.removeAll { $0 == path }; versionOrder.append(path)
        if versionOrder.count > 128 { openVersions.removeValue(forKey: versionOrder.removeFirst()) }
    }

    private func verifiedCommit(_ reference: String, at root: URL) async throws -> String {
        let commitType = try await git(.objectType(reference), at: root)
        guard commitType.status == 0, commitType.text.trimmingCharacters(in: .whitespacesAndNewlines) == "commit" else {
            throw FileServiceError.historicalUnavailable("Le commit enregistré \(reference) n’est pas présent dans ce dépôt.")
        }
        let resolved = try await git(.resolveCommit(reference), at: root)
        let commit = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.status == 0,
              commit.range(of: #"\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z"#, options: .regularExpression) != nil,
              commit.caseInsensitiveCompare(reference) == .orderedSame else {
            throw FileServiceError.historicalUnavailable("Le commit enregistré n’a pas pu être vérifié.")
        }
        return commit
    }

    private enum GitRead {
        case roots, branch, head, names(staged: Bool, reference: String?), diff(staged: Bool, paths: [String], reference: String?)
        case objectType(String), objectSize(String), resolveCommit(String), treeEntry(commit: String, path: String), blob(String)
        var arguments: [String] {
            switch self {
            case .roots: return ["rev-parse", "--show-toplevel", "--git-common-dir"]
            case .branch: return ["branch", "--show-current"]
            case .head: return ["rev-parse", "--verify", "HEAD"]
            case .names(let staged, let reference): return ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z"] + (staged ? ["--cached"] : []) + (reference.map { [$0] } ?? []) + ["--"]
            case .diff(let staged, let paths, let reference): return ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames"] + (staged ? ["--cached"] : []) + (reference.map { [$0] } ?? []) + ["--"] + paths.map { ":(literal)" + $0 }
            case .objectType(let object): return ["cat-file", "-t", object]
            case .objectSize(let object): return ["cat-file", "-s", object]
            case .resolveCommit(let commit): return ["rev-parse", "--verify", commit + "^{commit}"]
            case .treeEntry(let commit, let path): return ["ls-tree", "-z", commit, "--", path]
            case .blob(let object): return ["cat-file", "blob", object]
            }
        }
    }
    private struct GitResult { var text: String; var status: Int32 }

    private func git(_ command: GitRead, at directory: URL) async throws -> GitResult {
        let arguments = ["--no-pager", "--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null"] + command.arguments
        let cancellation = GitProcessCancellation()
        return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "GIT_NO_LAZY_FETCH": "1"]
                let pipe = Pipe()
                process.standardOutput = pipe; process.standardError = pipe
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                let timeout = LockedFlag()
                timer.schedule(deadline: .now() + 15)
                timer.setEventHandler { if process.isRunning { timeout.set(); process.terminate() } }
                timer.resume()
                do {
                    try cancellation.launch(process)
                    var output = Data()
                    var tooLarge = false
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                        if output.count + chunk.count > 8_388_608 {
                            tooLarge = true
                            if process.isRunning { process.terminate() }
                        } else if !tooLarge { output.append(chunk) }
                    }
                    process.waitUntilExit(); timer.cancel()
                    if cancellation.isCancelled { throw CancellationError() }
                    if timeout.value { throw FileServiceError.timedOut }
                    if tooLarge { throw FileServiceError.outputTooLarge }
                    guard let text = String(data: output, encoding: .utf8) else { throw FileServiceError.binary(directory.path) }
                    continuation.resume(returning: GitResult(text: text, status: process.terminationStatus))
                } catch {
                    // A source directory can disappear while a historical environment is being inspected.
                    timer.setEventHandler {}; timer.cancel()
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    continuation.resume(throwing: error)
                }
            }
        }
        } onCancel: { cancellation.cancel() }
    }
}

/// Serializes cancellation against launch, so a cancelled request cannot spawn later.
/// The Process runs only the fixed read-only Git command, with hooks disabled.
private final class GitProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
