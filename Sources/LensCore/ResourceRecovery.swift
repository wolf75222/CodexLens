import Foundation
import CryptoKit
import Darwin

/// Evidence for the bytes of the attachment itself, never the digest of its log event.
public struct ResourceRecoveryRecordedDigest: Codable, Hashable, Sendable {
    public let sha256: String
    public let evidence: String
    public init(sha256: String, evidence: String) { self.sha256 = sha256.lowercased(); self.evidence = evidence }
    public var isValid: Bool { sha256.count == 64 && sha256.allSatisfy { "0123456789abcdef".contains($0) } && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct ResourceRecoveryRoot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public enum ResourceRecoveryConfidence: String, Codable, Sendable {
    case recordedDigest, filename, filenameVariant, explicitlyChosen
    public var label: String {
        switch self {
        case .recordedDigest: return "Empreinte enregistrée identique"
        case .filename: return "Même nom et type · version historique non prouvée"
        case .filenameVariant: return "Nom approchant et type · version historique non prouvée"
        case .explicitlyChosen: return "Fichier choisi · version historique non prouvée"
        }
    }
}

/// A present-day observation, independent from the original ResourceRecord and event IDs.
public struct ResourceRecoveryCandidate: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path + "#" + version }
    public let resourceID: String
    public let originalLocation: String
    public let path: String
    public let rootPath: String
    public let byteCount: UInt64
    public let modifiedAt: Date
    public let observedAt: Date
    public let version: String
    public let sha256: String
    public let confidence: ResourceRecoveryConfidence
    public let recordedDigest: ResourceRecoveryRecordedDigest?
    /// The existing FileService version contract, for its expectedVersion guard.
    public var filePreviewVersion: String? {
        let fields = version.split(separator: ":").map(String.init)
        guard fields.count == 7, let modified = Double(fields[3]), let modifiedNanos = Double(fields[4]), let changed = Double(fields[5]), let changedNanos = Double(fields[6]) else { return nil }
        let modifiedDate = Date(timeIntervalSince1970: modified + modifiedNanos / 1e9)
        let changedDate = Date(timeIntervalSince1970: changed + changedNanos / 1e9)
        return fields.prefix(3).joined(separator: ":") + ":\(modifiedDate.timeIntervalSince1970):\(changedDate.timeIntervalSince1970)"
    }
}

public struct ResourceRecoveryLimits: Sendable {
    public var maximumRoots = 32
    public var maximumEntries = 12_000
    public var maximumDirectories = 800
    public var maximumDepth = 12
    public var maximumCandidates = 80
    public var maximumFileBytes: UInt64 = 32 * 1024 * 1024
    public var maximumTotalReadBytes: UInt64 = 96 * 1024 * 1024
    public var maximumSeconds: TimeInterval = 4
    public init() {}
}

public struct ResourceRecoveryIssue: Identifiable, Codable, Hashable, Sendable {
    public var id: String { category + ":" + path }
    public let category: String
    public let path: String
    public let message: String
}

public struct ResourceRecoveryReport: Sendable {
    public let candidates: [ResourceRecoveryCandidate]
    public let issues: [ResourceRecoveryIssue]
    public let inspectedEntries: Int
    public let bytesRead: UInt64
    public let elapsedSeconds: TimeInterval
    public let wasLimited: Bool
}

public enum ResourceRecoveryError: LocalizedError, Sendable, Equatable {
    case invalidPath, broadRoot, unavailable, symbolicLink, placeholder, restricted, tooLarge, changed, timedOut, invalidDigest, scopeLimit
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "Choisissez un chemin local absolu."
        case .broadRoot: return "Choisissez un dossier précis, plutôt que la racine du disque ou tout le dossier personnel."
        case .unavailable: return "Ce fichier ou dossier n’est plus accessible sur ce Mac."
        case .symbolicLink: return "Les liens symboliques ne sont pas parcourus. Choisissez directement leur dossier ou fichier de destination."
        case .placeholder: return "Ces octets ne sont pas téléchargés. Téléchargez le fichier dans le Finder, puis réessayez."
        case .restricted: return "Fichier exclu : il peut contenir des identifiants d’authentification."
        case .tooLarge: return "Le fichier dépasse le budget de lecture de cette recherche."
        case .changed: return "Le fichier a changé depuis la recherche. Recherchez-le à nouveau avant de l’ouvrir."
        case .timedOut: return "Le budget de temps de la recherche a été atteint."
        case .invalidDigest: return "Empreinte SHA-256 de la pièce jointe invalide."
        case .scopeLimit: return "Recherche partielle : un budget de dossiers, de profondeur, d’entrées, de temps, de lecture ou de candidats a été atteint."
        }
    }
}

public enum ResourceRecoveryRoots {
    /// These are suggestions only. The sheet exposes and allows removal of every scope before scanning.
    public static func suggested(resource: ResourceRecord, snapshot: SessionSnapshot?, attachmentDirectories: [String] = []) -> [ResourceRecoveryRoot] {
        var roots: [ResourceRecoveryRoot] = []
        if let url = localURL(resource.location) { roots.append(.init(path: url.deletingLastPathComponent().path, reason: "Dossier de la référence enregistrée")) }
        for path in attachmentDirectories { roots.append(.init(path: path, reason: "Dossier de pièces jointes connu")) }
        if let snapshot {
            for path in snapshot.root.paths { if let url = localURL(path) { roots.append(.init(path: url.deletingLastPathComponent().path, reason: "Dossier des traces de la session")) } }
            if !snapshot.root.cwd.isEmpty { roots.append(.init(path: snapshot.root.cwd, reason: "Répertoire initial de la session")) }
            for environment in snapshot.environments { roots.append(.init(path: environment.path, reason: "Environnement enregistré · " + environment.path)) }
        }
        var seen = Set<String>()
        return roots.filter { root in guard let path = try? normalized(root.path), !isBroad(path) else { return false }; return seen.insert(path).inserted }
    }

    fileprivate static func localURL(_ location: String) -> URL? {
        if location.hasPrefix("/") { return URL(fileURLWithPath: location).standardizedFileURL }
        if let url = URL(string: location), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { return url.standardizedFileURL }
        return nil
    }
    fileprivate static func normalized(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ResourceRecoveryError.invalidPath }
        var path = URL(fileURLWithPath: path).standardizedFileURL.path
        // macOS's system aliases are not user-controlled traversal links.
        if path.hasPrefix("/tmp/") { path = "/private" + path }
        if path.hasPrefix("/var/") { path = "/private" + path }
        return path
    }
    fileprivate static func isBroad(_ path: String) -> Bool {
        ["/", "/Users", "/Volumes", "/private", "/tmp", "/private/tmp", "/var", "/private/var", "/System", "/Library", FileManager.default.homeDirectoryForCurrentUser.path].contains(path)
    }
}

/// All directory enumeration, hashing and revalidation execute on this actor, never on MainActor.
/// No downloads, Spotlight query, shell commands, source writes or implicit historical associations.
public actor ResourceRecoveryService {
    private struct Stamp: Equatable {
        let device: UInt64, inode: UInt64, size: UInt64
        let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
        init(_ value: stat) {
            device = UInt64(value.st_dev); inode = UInt64(value.st_ino); size = UInt64(max(0, value.st_size))
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        var version: String { "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanos):\(changedSeconds):\(changedNanos)" }
        var modifiedAt: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1e9) }
    }
    public init() {}

    public func search(resource: ResourceRecord, roots: [ResourceRecoveryRoot], recordedDigest: ResourceRecoveryRecordedDigest? = nil, limits: ResourceRecoveryLimits = .init()) async throws -> ResourceRecoveryReport {
        if let recordedDigest, !recordedDigest.isValid { throw ResourceRecoveryError.invalidDigest }
        let start = ProcessInfo.processInfo.systemUptime
        let target = ResourceRecoveryRoots.localURL(resource.location)?.lastPathComponent ?? resource.name
        var queue: [(String, String, Int)] = [], seenRoots = Set<String>(), seenDirectories = Set<String>(), seenFiles = Set<String>()
        var candidates: [ResourceRecoveryCandidate] = [], issues: [ResourceRecoveryIssue] = []
        var entries = 0, directories = 0, bytes: UInt64 = 0, limited = false, omittedIssues = 0
        var issueIDs = Set<String>()
        func addIssue(_ category: String, _ path: String, _ error: Error) {
            guard issueIDs.insert(category + ":" + path).inserted else { return }
            if issues.count < 100 { issues.append(.init(category: category, path: path, message: error.localizedDescription)) }
            else { omittedIssues += 1 }
        }
        if roots.count > max(0, limits.maximumRoots) { limited = true; addIssue("rootLimit", "", ResourceRecoveryError.scopeLimit) }
        for root in roots.prefix(max(0, limits.maximumRoots)) {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - start >= max(0, limits.maximumSeconds) { limited = true; break }
            do {
                let path = try ResourceRecoveryRoots.normalized(root.path)
                guard !ResourceRecoveryRoots.isBroad(path) else { throw ResourceRecoveryError.broadRoot }
                guard seenRoots.insert(path).inserted else { continue }
                let metadata = try metadata(path, checkAncestors: true)
                guard metadata.st_mode & S_IFMT == S_IFDIR else { throw ResourceRecoveryError.unavailable }
                queue.append((path, path, 0))
            } catch { addIssue("rootUnavailable", root.path, error) }
        }
        var queueIndex = 0
        scan: while queueIndex < queue.count {
            try Task.checkCancellation()
            if entries >= max(0, limits.maximumEntries) || directories >= max(0, limits.maximumDirectories) || candidates.count >= max(0, limits.maximumCandidates) || ProcessInfo.processInfo.systemUptime - start >= max(0, limits.maximumSeconds) { limited = true; break }
            let (directory, root, depth) = queue[queueIndex]; queueIndex += 1
            guard seenDirectories.insert(directory).inserted else { continue }
            do {
                let before = try metadata(directory, checkAncestors: true)
                let fd = try secureOpen(directory, directory: true)
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino, opened.st_mode & S_IFMT == S_IFDIR, opened.st_flags & UInt32(SF_DATALESS) == 0 else { close(fd); throw ResourceRecoveryError.changed }
                guard let handle = fdopendir(fd) else { close(fd); throw ResourceRecoveryError.unavailable }
                defer { closedir(handle) }
                directories += 1
                while let item = readdir(handle) {
                    try Task.checkCancellation()
                    if entries >= max(0, limits.maximumEntries) || candidates.count >= max(0, limits.maximumCandidates) || ProcessInfo.processInfo.systemUptime - start >= max(0, limits.maximumSeconds) { limited = true; break scan }
                    let name = withUnsafePointer(to: &item.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                    guard name != ".", name != ".." else { continue }
                    entries += 1
                    let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                    // Skip machine/build metadata; retain ordinary dotfiles but never credentials.
                    if [".git", ".build", "node_modules", ".Trash"].contains(name) { continue }
                    do {
                        let itemMetadata = try metadata(path, checkAncestors: false)
                        if itemMetadata.st_mode & S_IFMT == S_IFDIR {
                            if depth < max(0, limits.maximumDepth) { queue.append((path, root, depth + 1)) }
                            else { limited = true; addIssue("depthLimit", path, ResourceRecoveryError.scopeLimit) }
                            continue
                        }
                        guard itemMetadata.st_mode & S_IFMT == S_IFREG, seenFiles.insert(path).inserted else { continue }
                        let nameMatch = Self.match(filename: name, target: target)
                        // Hash-only discovery is restricted to the recorded attachment's file type.
                        let sameType = URL(fileURLWithPath: name).pathExtension.lowercased() == URL(fileURLWithPath: target).pathExtension.lowercased()
                        guard nameMatch != nil || (recordedDigest != nil && sameType) else { continue }
                        let remaining = limits.maximumTotalReadBytes > bytes ? limits.maximumTotalReadBytes - bytes : 0
                        guard remaining > 0 else { limited = true; break scan }
                        let observation = try observe(resource: resource, path: path, rootPath: root, fallback: nameMatch ?? .filenameVariant, recordedDigest: recordedDigest, maximumBytes: min(limits.maximumFileBytes, remaining), deadline: start + max(0, limits.maximumSeconds), consumedBytes: &bytes)
                        if nameMatch != nil || observation.confidence == .recordedDigest { candidates.append(observation) }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if error as? ResourceRecoveryError == .timedOut { limited = true; break scan }
                        if error as? ResourceRecoveryError == .tooLarge { limited = true }
                        addIssue("skipped", path, error)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { addIssue("directoryUnavailable", directory, error) }
        }
        if limited { addIssue("limit", "", ResourceRecoveryError.scopeLimit) }
        if omittedIssues > 0 { issues.append(.init(category: "issueLimit", path: "", message: "\(omittedIssues) exclusions supplémentaires ne sont pas détaillées. La recherche reste partielle.")); limited = true }
        candidates.sort {
            let rank: (ResourceRecoveryConfidence) -> Int = { $0 == .recordedDigest ? 0 : $0 == .filename ? 1 : 2 }
            if rank($0.confidence) != rank($1.confidence) { return rank($0.confidence) < rank($1.confidence) }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return .init(candidates: candidates, issues: issues, inspectedEntries: entries, bytesRead: bytes, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start, wasLimited: limited)
    }

    public func inspectChosenFile(resource: ResourceRecord, path: String, recordedDigest: ResourceRecoveryRecordedDigest? = nil, limits: ResourceRecoveryLimits = .init()) async throws -> ResourceRecoveryCandidate {
        if let recordedDigest, !recordedDigest.isValid { throw ResourceRecoveryError.invalidDigest }
        let path = try ResourceRecoveryRoots.normalized(path)
        var bytes: UInt64 = 0
        return try observe(resource: resource, path: path, rootPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, fallback: .explicitlyChosen, recordedDigest: recordedDigest, maximumBytes: min(limits.maximumFileBytes, limits.maximumTotalReadBytes), deadline: ProcessInfo.processInfo.systemUptime + max(0, limits.maximumSeconds), consumedBytes: &bytes)
    }

    /// Re-hash before opening; do not silently display a later local version under this candidate.
    public func validate(_ candidate: ResourceRecoveryCandidate, limits: ResourceRecoveryLimits = .init()) async throws -> ResourceRecoveryCandidate {
        let path = try ResourceRecoveryRoots.normalized(candidate.path)
        guard path == candidate.path else { throw ResourceRecoveryError.changed }
        let metadata = try metadata(path, checkAncestors: true)
        guard Stamp(metadata).version == candidate.version else { throw ResourceRecoveryError.changed }
        let resource = ResourceRecord(id: candidate.resourceID, location: candidate.originalLocation)
        var bytes: UInt64 = 0
        let current = try observe(resource: resource, path: candidate.path, rootPath: candidate.rootPath, fallback: candidate.confidence, recordedDigest: candidate.recordedDigest, maximumBytes: min(limits.maximumFileBytes, limits.maximumTotalReadBytes), deadline: ProcessInfo.processInfo.systemUptime + max(0, limits.maximumSeconds), consumedBytes: &bytes)
        guard current.version == candidate.version, current.sha256 == candidate.sha256 else { throw ResourceRecoveryError.changed }
        return current
    }

    /// Immutable bytes for text, image and PDF readers. No preview reopens the path.
    /// Capture succeeds only while the candidate's exact stamp and digest still match.
    public func captureValidated(_ candidate: ResourceRecoveryCandidate, limits: ResourceRecoveryLimits = .init()) async throws -> Data {
        let path = try ResourceRecoveryRoots.normalized(candidate.path)
        guard path == candidate.path else { throw ResourceRecoveryError.changed }
        let metadata = try metadata(path, checkAncestors: true)
        let stamp = Stamp(metadata)
        guard stamp.version == candidate.version else { throw ResourceRecoveryError.changed }
        let budget = min(limits.maximumFileBytes, limits.maximumTotalReadBytes)
        guard stamp.size <= budget else { throw ResourceRecoveryError.tooLarge }
        var data = Data(), bytes: UInt64 = 0
        data.reserveCapacity(Int(stamp.size))
        let resource = ResourceRecord(id: candidate.resourceID, location: candidate.originalLocation)
        let observed = try observe(resource: resource, path: path, rootPath: candidate.rootPath, fallback: candidate.confidence, recordedDigest: candidate.recordedDigest, maximumBytes: budget, deadline: ProcessInfo.processInfo.systemUptime + max(0, limits.maximumSeconds), consumedBytes: &bytes, capture: { data.append($0) })
        guard observed.version == candidate.version, observed.sha256 == candidate.sha256, UInt64(data.count) == candidate.byteCount else { throw ResourceRecoveryError.changed }
        try Task.checkCancellation()
        return data
    }

    private static func match(filename: String, target: String) -> ResourceRecoveryConfidence? {
        if filename == target { return .filename }
        let file = URL(fileURLWithPath: filename), reference = URL(fileURLWithPath: target)
        guard file.pathExtension.lowercased() == reference.pathExtension.lowercased() else { return nil }
        let stem = reference.deletingPathExtension().lastPathComponent.lowercased()
        let candidate = file.deletingPathExtension().lastPathComponent.lowercased()
        guard !stem.isEmpty else { return nil }
        if candidate == stem { return .filename }
        // Boundary prevents report.pdf matching reporter.pdf; several candidates remain separate.
        if candidate.hasPrefix(stem), let next = candidate.dropFirst(stem.count).first, " -_.(".contains(next) { return .filenameVariant }
        return nil
    }

    private func metadata(_ path: String, checkAncestors: Bool) throws -> stat {
        if checkAncestors {
            let components = URL(fileURLWithPath: path).pathComponents
            var parent = ""
            for component in components.dropLast() {
                parent = component == "/" ? "/" : URL(fileURLWithPath: parent).appendingPathComponent(component).path
                var value = stat()
                guard parent.withCString({ lstat($0, &value) }) == 0 else { throw ResourceRecoveryError.unavailable }
                if value.st_mode & S_IFMT == S_IFLNK { throw ResourceRecoveryError.symbolicLink }
                if value.st_flags & UInt32(SF_DATALESS) != 0 { throw ResourceRecoveryError.placeholder }
            }
        }
        if Self.restricted(path) { throw ResourceRecoveryError.restricted }
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { throw ResourceRecoveryError.unavailable }
        if value.st_mode & S_IFMT == S_IFLNK { throw ResourceRecoveryError.symbolicLink }
        if value.st_flags & UInt32(SF_DATALESS) != 0 { throw ResourceRecoveryError.placeholder }
        return value
    }

    private func observe(resource: ResourceRecord, path: String, rootPath: String, fallback: ResourceRecoveryConfidence, recordedDigest: ResourceRecoveryRecordedDigest?, maximumBytes: UInt64, deadline: TimeInterval, consumedBytes: inout UInt64, capture: ((Data) -> Void)? = nil) throws -> ResourceRecoveryCandidate {
        try Task.checkCancellation()
        let before = try metadata(path, checkAncestors: true)
        guard before.st_mode & S_IFMT == S_IFREG else { throw ResourceRecoveryError.unavailable }
        let stamp = Stamp(before)
        guard stamp.size <= maximumBytes else { throw ResourceRecoveryError.tooLarge }
        let fd = try secureOpen(path, directory: false)
        defer { close(fd) }
        var descriptorMetadata = stat()
        guard fstat(fd, &descriptorMetadata) == 0, Stamp(descriptorMetadata) == stamp else { throw ResourceRecoveryError.changed }
        if descriptorMetadata.st_flags & UInt32(SF_DATALESS) != 0 { throw ResourceRecoveryError.placeholder }
        var digest = SHA256(), bytes: UInt64 = 0, overlap = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while bytes < stamp.size {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ResourceRecoveryError.timedOut }
            let requested = min(buffer.count, Int(min(stamp.size - bytes, UInt64(Int.max))))
            let count = Darwin.read(fd, &buffer, requested)
            guard count >= 0 else { throw ResourceRecoveryError.unavailable }
            if count == 0 { break }
            bytes += UInt64(count)
            consumedBytes += UInt64(count)
            guard bytes <= maximumBytes else { throw ResourceRecoveryError.tooLarge }
            let chunk = Data(buffer.prefix(count))
            var guarded = overlap; guarded.append(chunk)
            if Self.secretContent(guarded) { throw ResourceRecoveryError.restricted }
            overlap = Data(guarded.suffix(512))
            digest.update(data: chunk)
            capture?(chunk)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Stamp(after) == stamp, Stamp(try metadata(path, checkAncestors: true)) == stamp, bytes == stamp.size else { throw ResourceRecoveryError.changed }
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let confidence: ResourceRecoveryConfidence = recordedDigest?.sha256 == sha ? .recordedDigest : fallback == .recordedDigest ? .explicitlyChosen : fallback
        return .init(resourceID: resource.id, originalLocation: resource.location, path: path, rootPath: rootPath, byteCount: bytes, modifiedAt: stamp.modifiedAt, observedAt: Date(), version: stamp.version, sha256: sha, confidence: confidence, recordedDigest: recordedDigest)
    }

    private static func restricted(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path), components = url.pathComponents.map { $0.lowercased() }, name = url.lastPathComponent.lowercased()
        let names: Set<String> = ["auth.json", "credentials", "credentials.json", "token.json", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "application_default_credentials.json", "credentials.db", "accesstokens.json"]
        return names.contains(name) || name == ".env" || name.hasPrefix(".env.") || ["pem", "key", "p12", "pfx", "jks", "keystore"].contains(url.pathExtension.lowercased()) || components.contains(".ssh") || components.contains(".aws") || components.contains(".gnupg")
    }
    /// Open each path component without following a symlink, including ancestors.
    /// Descriptors also make a concurrent replacement of the directory path detectable.
    private func secureOpen(_ path: String, directory: Bool) throws -> Int32 {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ResourceRecoveryError.unavailable }
        defer { if fd >= 0 { close(fd) } }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let isDirectory = index < components.count - 1 || directory
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (isDirectory ? O_DIRECTORY : 0)
            let child = component.withCString { openat(fd, $0, flags) }
            let failure = errno
            close(fd); fd = -1
            guard child >= 0 else { throw failure == ELOOP ? ResourceRecoveryError.symbolicLink : ResourceRecoveryError.unavailable }
            fd = child
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw ResourceRecoveryError.unavailable }
            if value.st_flags & UInt32(SF_DATALESS) != 0 { throw ResourceRecoveryError.placeholder }
        }
        let result = fd; fd = -1; return result
    }
    private static let secretPatterns: [NSRegularExpression] = ["-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----", "\\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\\b"].compactMap { try? NSRegularExpression(pattern: $0) }
    private static func secretContent(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return secretPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
