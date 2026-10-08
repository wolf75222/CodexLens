import Foundation
import CryptoKit

public struct FileSearchOptions: Codable, Hashable, Sendable {
    public var maxFiles: Int
    public var maxTotalBytes: Int
    public var maxFileBytes: Int
    public var maxMatches: Int
    public var maxDirectories: Int
    public var maxDepth: Int
    public var pageBytes: Int
    public var caseSensitive: Bool
    public var excludedDirectoryNames: [String]
    /// UTF-16 units, with at most two extra units to avoid breaking surrogate pairs.
    public var maxSnippetCharacters: Int
    public var maxCoverageIssues: Int
    public init(maxFiles: Int = 5000, maxTotalBytes: Int = 64 * 1024 * 1024, maxFileBytes: Int = 4 * 1024 * 1024, maxMatches: Int = 1000, maxDirectories: Int = 1000, maxDepth: Int = 64, pageBytes: Int = 65536, caseSensitive: Bool = false, excludedDirectoryNames: [String] = [".git"], maxSnippetCharacters: Int = 240, maxCoverageIssues: Int = 1000) {
        self.maxFiles = maxFiles; self.maxTotalBytes = maxTotalBytes; self.maxFileBytes = maxFileBytes
        self.maxMatches = maxMatches; self.maxDirectories = maxDirectories; self.maxDepth = maxDepth
        self.pageBytes = pageBytes; self.caseSensitive = caseSensitive; self.excludedDirectoryNames = excludedDirectoryNames
        self.maxSnippetCharacters = maxSnippetCharacters; self.maxCoverageIssues = maxCoverageIssues
    }
}

public struct FileSearchHit: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var environmentID: String
    public var path: String
    public var relativePath: String
    public var version: String
    public var line: Int
    /// One-based UTF-16 column and UTF-16 match length for native text selection.
    public var column: Int
    public var length: Int
    public var snippet: String
    public var snippetTruncated: Bool
    public var observedAt: Date
    public init(id: String, environmentID: String, path: String, relativePath: String, version: String, line: Int, column: Int, length: Int, snippet: String, snippetTruncated: Bool, observedAt: Date) {
        self.id = id; self.environmentID = environmentID; self.path = path; self.relativePath = relativePath
        self.version = version; self.line = line; self.column = column; self.length = length
        self.snippet = snippet; self.snippetTruncated = snippetTruncated; self.observedAt = observedAt
    }
}

public struct FileSearchResult: Codable, Sendable {
    public var environmentID: String
    public var query: String
    public var hits: [FileSearchHit]
    public var coverage: [CoverageIssue]
    public var searchedFiles: Int
    public var visitedFiles: Int
    public var visitedDirectories: Int
    /// Successful UTF-8 page bytes returned by FileService, not physical disk I/O including overlap.
    public var decodedBytes: Int
    public var cancelled: Bool
    public var coverageOmittedCount: Int
    public var finishedAt: Date
    public var complete: Bool { !cancelled && coverage.isEmpty && coverageOmittedCount == 0 }
    public init(environmentID: String, query: String, hits: [FileSearchHit] = [], coverage: [CoverageIssue] = [], searchedFiles: Int = 0, visitedFiles: Int = 0, visitedDirectories: Int = 0, decodedBytes: Int = 0, cancelled: Bool = false, coverageOmittedCount: Int = 0, finishedAt: Date = Date()) {
        self.environmentID = environmentID; self.query = query; self.hits = hits; self.coverage = coverage
        self.searchedFiles = searchedFiles; self.visitedFiles = visitedFiles; self.visitedDirectories = visitedDirectories
        self.decodedBytes = decodedBytes; self.cancelled = cancelled; self.coverageOmittedCount = coverageOmittedCount; self.finishedAt = finishedAt
    }
}

/// Live accounting for the discovered search queue, not a percentage of the
/// filesystem or of a byte budget. New subdirectories can extend the queue.
public struct FileSearchProgress: Sendable, Equatable {
    public let searchedFiles: Int
    public let visitedDirectories: Int
    public let decodedBytes: Int
    public let pendingDirectories: Int
    public let currentPath: String?
    public let finished: Bool
}
public typealias FileSearchProgressHandler = @Sendable (FileSearchProgress) -> Void

public enum FileSearchError: LocalizedError, Sendable {
    case invalidQuery, invalidOptions
    public var errorDescription: String? {
        switch self {
        case .invalidQuery: return "La recherche attend un texte littéral non vide, sur une seule ligne, limité à 1024 octets."
        case .invalidOptions: return "Bornes invalides : 1–100000 fichiers, 4 octets–512 Mio au total, 1 octet–32 Mio par fichier, 1–10000 résultats/répertoires, profondeur 0–128, pages 256 octets–1 Mio et extraits 16–2048 unités UTF-16."
        }
    }
}

// Internal injection supports deterministic race/cancellation tests; the public API uses guarded FileService.
struct FileSearchDirectoryListing: Sendable {
    let entries: [FileEntry]
    let hasMore: Bool
}
protocol FileSearchReader: Sendable {
    func children(path: String) async throws -> [FileEntry]
    func searchChildren(path: String, maxEntries: Int) async throws -> FileSearchDirectoryListing
    func readText(path: String, offset: UInt64, limit: Int, expectedVersion: String?) async throws -> TextPage
}
extension FileSearchReader {
    /// Older injected readers remain compatible. Production FileService supplies
    /// a bounded native enumerator instead of materializing this legacy array.
    func searchChildren(path: String, maxEntries: Int) async throws -> FileSearchDirectoryListing {
        guard maxEntries > 0 else { throw FileSearchError.invalidOptions }
        let entries = try await children(path: path)
        return FileSearchDirectoryListing(entries: Array(entries.prefix(maxEntries)), hasMore: entries.count > maxEntries)
    }
}
extension FileService: FileSearchReader {}

/// Searches CURRENT accessible files off the UI actor. It never executes a shell or reads authentication
/// files directly. Matches are committed only after every page of that file passes the version/secret guards.
public actor FileSearch {
    private let reader: any FileSearchReader
    public init(fileService: FileService = FileService()) { reader = fileService }
    init(reader: any FileSearchReader) { self.reader = reader }

    public func search(environment: EnvironmentRecord, query: String, options: FileSearchOptions = FileSearchOptions(), progress: FileSearchProgressHandler? = nil) async throws -> FileSearchResult {
        let interval = LensSignposts.begin("EnvironmentSearch")
        defer { interval.end() }
        guard !query.isEmpty, query.utf8.count <= 1024, !query.contains("\n"), !query.contains("\r") else { throw FileSearchError.invalidQuery }
        guard (1...100000).contains(options.maxFiles), (4...536870912).contains(options.maxTotalBytes), (1...33554432).contains(options.maxFileBytes), (1...10000).contains(options.maxMatches), (1...10000).contains(options.maxDirectories), (0...128).contains(options.maxDepth), (256...1048576).contains(options.pageBytes), (16...2048).contains(options.maxSnippetCharacters), (1...10000).contains(options.maxCoverageIssues) else { throw FileSearchError.invalidOptions }
        var result = FileSearchResult(environmentID: environment.id, query: query)
        let expanded = (environment.path as NSString).expandingTildeInPath
        // Use the same lexical URL normalization as FileService; keep environmentID from the trace.
        let root = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL.path : expanded
        var queue: [(String, Int)] = [(root, 0)]
        var seen = Set<String>(), stop = false, inspectedEntries = 0
        var publishedAt: ContinuousClock.Instant?
        func report(_ path: String?, finished: Bool = false) {
            guard let progress else { return }
            let now = ContinuousClock.now
            guard finished || publishedAt == nil || now - publishedAt! >= .milliseconds(100) else { return }
            publishedAt = now
            progress(.init(searchedFiles: result.searchedFiles, visitedDirectories: result.visitedDirectories,
                decodedBytes: result.decodedBytes, pendingDirectories: queue.count, currentPath: path, finished: finished))
        }
        report(root)
        func issue(_ category: String, _ message: String, _ path: String) {
            if result.coverage.count < options.maxCoverageIssues { result.coverage.append(CoverageIssue(category, message, source: path)) }
            else { result.coverageOmittedCount += 1 }
        }
        func cancellation(_ path: String) {
            result.cancelled = true; stop = true
            issue("cancelled", "Recherche annulée ; aucun fichier supplémentaire n’est consulté et les résultats restent partiels.", path)
        }
        func relative(_ path: String) -> String {
            let prefix = root == "/" ? "/" : root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        while let directory = queue.popLast(), !stop {
            if Task.isCancelled { cancellation(directory.0); break }
            guard seen.insert(directory.0).inserted else { issue("directoryCycle", "Répertoire déjà parcouru ; aucune nouvelle lecture.", directory.0); continue }
            guard result.visitedDirectories < options.maxDirectories else { issue("limit.directories", "Limite des répertoires atteinte ; arborescence restante non parcourue.", directory.0); break }
            let entryBudget = options.maxFiles + options.maxDirectories - inspectedEntries
            guard entryBudget > 0 else { issue("limit.entries", "Limite des entrées examinées atteinte ; arborescence restante non parcourue.", directory.0); break }
            result.visitedDirectories += 1
            report(directory.0)
            let listing: FileSearchDirectoryListing
            do { listing = try await reader.searchChildren(path: directory.0, maxEntries: entryBudget) }
            catch is CancellationError { cancellation(directory.0); break }
            catch { issue("unavailable", error.localizedDescription, directory.0); continue }
            if listing.hasMore { issue("limit.entries", "Limite d’énumération atteinte ; ce répertoire n’a pas été listé entièrement.", directory.0) }
            for entry in listing.entries {
                if Task.isCancelled { cancellation(entry.id); break }
                guard inspectedEntries < options.maxFiles + options.maxDirectories else { issue("limit.entries", "Limite des entrées examinées atteinte ; arborescence restante non parcourue.", entry.id); stop = true; break }
                inspectedEntries += 1
                if !entry.isDirectory {
                    if result.visitedFiles >= options.maxFiles { issue("limit.files", "Limite des fichiers atteinte ; les fichiers restants ne sont pas recherchés.", entry.id); stop = true; break }
                    result.visitedFiles += 1
                }
                if entry.isRestricted { issue("restricted", "Fichier ou répertoire d’authentification exclu par les gardes de lecture.", entry.id); continue }
                if entry.isDirectory {
                    if entry.isSymbolicLink { issue("symlinkDirectory", "Lien vers un répertoire non parcouru pour éviter les cycles et sorties de périmètre.", entry.id) }
                    else if options.excludedDirectoryNames.contains(entry.name) { issue("excludedDirectory", "Répertoire explicitement exclu des options de recherche.", entry.id) }
                    else if directory.1 >= options.maxDepth { issue("limit.depth", "Profondeur maximale atteinte ; sous-arborescence non parcourue.", entry.id) }
                    else if queue.count + result.visitedDirectories >= options.maxDirectories { issue("limit.directories", "Répertoire non planifié : limite de parcours atteinte.", entry.id) }
                    else { queue.append((entry.id, directory.1 + 1)) }
                    continue
                }
                if entry.size > UInt64(options.maxFileBytes) { issue("oversize", "Taille observée supérieure à la limite par fichier ; aucun contenu consulté.", entry.id); continue }
                let budget = options.maxTotalBytes - result.decodedBytes
                if budget < 4 { issue("limit.bytes", "Budget de texte épuisé ; fichiers restants non consultés.", entry.id); stop = true; break }
                if !entry.isSymbolicLink && entry.size > UInt64(budget) { issue("limit.bytes", "Fichier non consulté : taille observée supérieure au budget de texte restant.", entry.id); continue }
                var pending: [FileSearchHit] = [], offset: UInt64 = 0, version: String?, carry = "", line = 1
                var completed = false, matchLimit = false
                do {
                    while !completed {
                        if Task.isCancelled { cancellation(entry.id); break }
                        let remaining = options.maxTotalBytes - result.decodedBytes
                        // The first page can extend a limit of 1–3 bytes to finish a UTF-8 character.
                        guard remaining > 0, version != nil || remaining >= 4 else { issue("limit.bytes", "Budget épuisé avant validation complète du fichier ; correspondances provisoires écartées.", entry.id); break }
                        let request = version == nil ? min(options.pageBytes, remaining - 3) : min(options.pageBytes, remaining)
                        let page = try await reader.readText(path: entry.id, offset: offset, limit: max(1, request), expectedVersion: version)
                        let pageBytes = page.text.utf8.count
                        guard pageBytes <= remaining else { issue("limit.bytes", "Page supérieure au budget restant ; aucun résultat de ce fichier conservé.", entry.id); break }
                        result.decodedBytes += pageBytes
                        report(entry.id)
                        guard page.totalBytes <= UInt64(options.maxFileBytes) else { issue("oversize", "La taille actuelle ou la cible du lien dépasse la limite par fichier.", entry.id); break }
                        guard page.totalBytes <= UInt64(budget) else { issue("limit.bytes", "La taille actuelle dépasse le budget initial de ce fichier ; correspondances écartées.", entry.id); break }
                        if let version, version != page.version { throw FileServiceError.staleFile(entry.id) }
                        version = page.version
                        try autoreleasepool {
                            let parts = (carry + page.text).components(separatedBy: "\n")
                            carry = parts.last ?? ""
                            for part in parts.dropLast() {
                                if !matchLimit { appendMatches(in: part, line: line, path: entry.id, relativePath: relative(entry.id), environmentID: environment.id, query: query, version: page.version, observedAt: page.observedAt, options: options, remainingMatches: options.maxMatches - result.hits.count, into: &pending) }
                                if pending.count + result.hits.count >= options.maxMatches { matchLimit = true }
                                line += 1
                            }
                            if let next = page.nextOffset {
                                guard next > offset else { throw FileServiceError.invalidOffset(entry.id) }
                                offset = next
                            } else {
                                if !carry.isEmpty && !matchLimit { appendMatches(in: carry, line: line, path: entry.id, relativePath: relative(entry.id), environmentID: environment.id, query: query, version: page.version, observedAt: page.observedAt, options: options, remainingMatches: options.maxMatches - result.hits.count, into: &pending) }
                                completed = true
                            }
                        }
                    }
                } catch is CancellationError { cancellation(entry.id) }
                catch FileServiceError.staleFile { issue("changed", "Fichier changé entre les pages ; toutes ses correspondances provisoires sont écartées.", entry.id) }
                catch FileServiceError.restricted { issue("restricted", "Lecture exclue par les gardes d’authentification ; aucune correspondance conservée.", entry.id) }
                catch FileServiceError.binary { issue("binary", "Contenu non UTF-8 ou binaire ; aucune correspondance conservée.", entry.id) }
                catch { issue("unavailable", error.localizedDescription, entry.id) }
                if completed && !result.cancelled { result.searchedFiles += 1; result.hits += pending }
                report(entry.id)
                if result.hits.count >= options.maxMatches { issue("limit.matches", "Limite des correspondances atteinte ; recherche restante non effectuée.", entry.id); stop = true }
                if stop { break }
            }
            if listing.hasMore { stop = true }
        }
        result.finishedAt = Date()
        report(nil, finished: true)
        return result
    }

    private func appendMatches(in rawLine: String, line: Int, path: String, relativePath: String, environmentID: String, query: String, version: String, observedAt: Date, options: FileSearchOptions, remainingMatches: Int, into hits: inout [FileSearchHit]) {
        let text = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        var cursor = text.startIndex
        while cursor < text.endIndex && hits.count < remainingMatches,
              let range = text.range(of: query, options: options.caseSensitive ? [] : [.caseInsensitive], range: cursor..<text.endIndex) {
            let match = NSRange(range, in: text)
            let snippet = excerpt(text, match: match, maximum: options.maxSnippetCharacters)
            let fields = [environmentID, path, version, String(line), String(match.location), String(match.length)]
            var framed = Data()
            for field in fields { let bytes = Data(field.utf8); framed.append(Data("\(bytes.count):".utf8)); framed.append(bytes) }
            let id = SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
            hits.append(FileSearchHit(id: "search:" + id, environmentID: environmentID, path: path, relativePath: relativePath, version: version, line: line, column: match.location + 1, length: match.length, snippet: snippet.text, snippetTruncated: snippet.truncated, observedAt: observedAt))
            cursor = range.upperBound
        }
    }

    private func excerpt(_ text: String, match: NSRange, maximum: Int) -> (text: String, truncated: Bool) {
        let native = text as NSString
        var start = max(0, match.location - min(40, maximum / 4)), end = min(native.length, max(0, match.location - min(40, maximum / 4)) + maximum)
        if start > 0 && start < native.length && (0xdc00...0xdfff).contains(native.character(at: start)) { start -= 1 }
        if end < native.length && end > 0 && (0xdc00...0xdfff).contains(native.character(at: end)) { end += 1 }
        return (native.substring(with: NSRange(location: start, length: end - start)), start > 0 || end < native.length)
    }
}
