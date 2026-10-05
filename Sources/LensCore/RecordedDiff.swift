import Foundation
import CryptoKit

public enum RecordedDiffKind: String, Codable, Sendable { case requestedPatch, recordedDiff, observedTextComparison, currentGit }
public enum DiffCoverage: String, Codable, Sendable { case fragmentOnly, completeTextsAvailable }
public enum DiffLineKind: String, Codable, Sendable { case context, removed, added, metadata }
public enum DiffFileOperation: String, Codable, Sendable { case added, deleted, modified, renamed, binary, unknown }
public enum DiffMappingDirection: String, Codable, Sendable { case beforeToAfter, afterToBefore }
public enum DiffMappingStatus: String, Codable, Sendable { case mapped, deleted, partial, ambiguous, unavailable }
public enum DiffExecutionStatus: String, Codable, Sendable { case unknown, succeeded, failed }

public struct DiffProvenance: Codable, Hashable, Sendable {
    public var environmentID: String
    public var eventIDs: [String]
    public var sources: [SourceRef]
    /// Agent that produced this trace. It is not necessarily the author of its observed changes.
    public var agentID: String?
    /// Authorship requires explicit recorded evidence; no time-based attribution is performed.
    public var authorEvidence: String?
    public var beforeReference: String?
    public var afterReference: String?
    public init(environmentID: String, eventIDs: [String] = [], sources: [SourceRef] = [], agentID: String? = nil, authorEvidence: String? = nil, beforeReference: String? = nil, afterReference: String? = nil) {
        self.environmentID = environmentID; self.eventIDs = eventIDs; self.sources = sources; self.agentID = agentID
        self.authorEvidence = authorEvidence; self.beforeReference = beforeReference; self.afterReference = afterReference
    }
}

/// A recorded execution result stays separate from the proposed patch. Success does not capture file bytes.
public struct RecordedDiffResult: Codable, Hashable, Sendable {
    public var status: DiffExecutionStatus
    public var message: String
    public var eventIDs: [String]
    public var sources: [SourceRef]
    public init(status: DiffExecutionStatus, message: String = "", eventIDs: [String] = [], sources: [SourceRef] = []) {
        self.status = status; self.message = message; self.eventIDs = eventIDs; self.sources = sources
    }
}

public struct RecordedDiffIssue: Codable, Hashable, Sendable {
    public var category: String
    public var message: String
    public var patchLine: Int?
    public init(_ category: String, _ message: String, patchLine: Int? = nil) { self.category = category; self.message = message; self.patchLine = patchLine }
}

public struct RecordedDiffLine: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: DiffLineKind
    public var text: String
    public var beforeLine: Int?
    public var afterLine: Int?
    /// One-based coordinates within this hunk; they do not claim an absolute file line.
    public var beforeOffset: Int?
    public var afterOffset: Int?
    public var alignmentAmbiguous: Bool
    public init(id: String, kind: DiffLineKind, text: String, beforeLine: Int? = nil, afterLine: Int? = nil, beforeOffset: Int? = nil, afterOffset: Int? = nil, alignmentAmbiguous: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.beforeLine = beforeLine; self.afterLine = afterLine
        self.beforeOffset = beforeOffset; self.afterOffset = afterOffset; self.alignmentAmbiguous = alignmentAmbiguous
    }
}

public struct RecordedDiffHunk: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var header: String
    public var beforeStart: Int?
    public var afterStart: Int?
    public var beforeCount: Int
    public var afterCount: Int
    public var lines: [RecordedDiffLine]
    public var isComplete: Bool
    public var patchLine: Int
    public init(id: String, header: String, beforeStart: Int? = nil, afterStart: Int? = nil, beforeCount: Int = 0, afterCount: Int = 0, lines: [RecordedDiffLine] = [], isComplete: Bool = true, patchLine: Int = 0) {
        self.id = id; self.header = header; self.beforeStart = beforeStart; self.afterStart = afterStart
        self.beforeCount = beforeCount; self.afterCount = afterCount; self.lines = lines; self.isComplete = isComplete; self.patchLine = patchLine
    }
}

public struct RecordedFileDiff: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var oldPath: String?
    public var newPath: String?
    public var operation: DiffFileOperation
    public var hunks: [RecordedDiffHunk]
    public var provenance: DiffProvenance
    public var kind: RecordedDiffKind
    public var coverage: DiffCoverage
    public var issues: [RecordedDiffIssue]
    /// Full or abbreviated object names as recorded; only complete digests may resolve versions.
    public var beforeBlobID: String?
    public var afterBlobID: String?
    public var beforeMode: String?
    public var afterMode: String?
    public var path: String { newPath ?? oldPath ?? "" }
    public init(id: String, oldPath: String?, newPath: String?, operation: DiffFileOperation = .modified, hunks: [RecordedDiffHunk] = [], provenance: DiffProvenance, kind: RecordedDiffKind = .recordedDiff, coverage: DiffCoverage = .fragmentOnly, issues: [RecordedDiffIssue] = []) {
        self.id = id; self.oldPath = oldPath; self.newPath = newPath; self.operation = operation; self.hunks = hunks
        self.provenance = provenance; self.kind = kind; self.coverage = coverage; self.issues = issues
    }
}

public struct RecordedDiffDocument: Codable, Hashable, Sendable {
    public var format: String
    public var kind: RecordedDiffKind
    public var coverage: DiffCoverage
    public var provenance: DiffProvenance
    public var files: [RecordedFileDiff]
    public var issues: [RecordedDiffIssue]
    public var result: RecordedDiffResult?
    public init(format: String, kind: RecordedDiffKind, coverage: DiffCoverage = .fragmentOnly, provenance: DiffProvenance, files: [RecordedFileDiff], issues: [RecordedDiffIssue] = [], result: RecordedDiffResult? = nil) {
        self.format = format; self.kind = kind; self.coverage = coverage; self.provenance = provenance
        self.files = files; self.issues = issues; self.result = result
    }
}

public struct DiffLineRange: Codable, Hashable, Sendable {
    public var start: Int
    public var count: Int
    public init(start: Int, count: Int = 1) { self.start = start; self.count = count }
}

public struct DiffRangeMapping: Codable, Hashable, Sendable {
    public var source: DiffLineRange
    /// Correspondences explicitly present in the diff, not guessed replacement-line pairings.
    public var destinations: [DiffLineRange]
    public var status: DiffMappingStatus
    public var reason: String
    public var conditionalOnApplication: Bool
    public var provenance: DiffProvenance
}

public enum RecordedDiffError: LocalizedError, Sendable {
    case limit(String), unsupported(String), ambiguousExtraction
    public var errorDescription: String? {
        switch self {
        case .limit(let reason): return "Limite du diff atteinte : \(reason)"
        case .unsupported(let reason): return "Diff enregistré non interprétable : \(reason)"
        case .ambiguousExtraction: return "Plusieurs patches sont enregistrés dans cet appel ; inspectez-les séparément."
        }
    }
}

/// Pure parsing and comparison. No source file is opened, no command is executed and no patch is applied.
public enum RecordedDiff {
    public static let maximumInputBytes = 8 * 1024 * 1024
    public static let maximumLines = 100_000
    public static let maximumComparisonCells = 2_000_000

    public static func parse(_ text: String, provenance: DiffProvenance, kind: RecordedDiffKind = .recordedDiff) throws -> RecordedDiffDocument {
        let interval = LensSignposts.begin("RecordedDiffParse")
        defer { interval.end() }
        let lines = try boundedLines(text)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "*** Begin Patch" {
            return try parseCodex(lines, provenance: provenance)
        }
        return try parseUnified(lines, provenance: provenance, kind: kind)
    }

    /// Handles direct text, JSON tool input, and JSON double-quoted literals in apply_patch(...).
    /// It never evaluates JavaScript, interpolates templates, or guesses concatenated arguments.
    public static func extractRecordedPatch(from text: String) throws -> String? {
        let patches = try extractRecordedDiffs(from: text)
        guard patches.count <= 1 else { throw RecordedDiffError.ambiguousExtraction }
        return patches.first
    }

    public static func extractRecordedDiffs(from text: String) throws -> [String] {
        guard text.utf8.count <= maximumInputBytes else { throw RecordedDiffError.limit("entrée supérieure à 8 Mio") }
        var values: [String] = []
        try extract(text, depth: 0, into: &values)
        guard values.count <= 1024 else { throw RecordedDiffError.limit("plus de 1024 patches") }
        var seen = Set<Data>()
        return values.filter { seen.insert(Data($0.utf8)).inserted }
    }

    private static func recognized(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("*** Begin Patch") || trimmed.hasPrefix("diff --git ") || (trimmed.hasPrefix("--- ") && trimmed.contains("\n+++ "))
    }

    private static func extract(_ text: String, depth: Int, into values: inout [String]) throws {
        guard depth < 9 else { throw RecordedDiffError.limit("imbrication JSON supérieure à 8 niveaux") }
        if recognized(text) { values.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); return }
        if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            try extractJSON(value, depth: depth + 1, into: &values)
            return
        }
        let expression = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.$])(?:tools\.)?apply_patch\s*\(\s*("(?:\\.|[^"\\])*")\s*\)"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let literalRange = Range(match.range(at: 1), in: text),
                  let data = String(text[literalRange]).data(using: .utf8),
                  let literal = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
                  recognized(literal) else { continue }
            values.append(literal)
        }
        // EventDetail.raw can contain several original JSONL records separated by blank lines.
        if values.isEmpty, text.contains("\n") {
            for line in text.split(separator: "\n") {
                if let data = String(line).data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) {
                    try extractJSON(value, depth: depth + 1, into: &values)
                }
            }
        }
        guard values.count <= 1024 else { throw RecordedDiffError.limit("plus de 1024 patches") }
    }

    private static func extractJSON(_ value: Any, depth: Int, into values: inout [String]) throws {
        guard depth < 9 else { throw RecordedDiffError.limit("imbrication JSON supérieure à 8 niveaux") }
        if let string = value as? String { try extract(string, depth: depth, into: &values); return }
        guard let object = value as? [String: Any] else { return }
        if let changes = object["changes"] as? [[String: Any]] {
            for change in changes { try extractChange(change, path: change["path"] as? String ?? change["file_path"] as? String, depth: depth, into: &values) }
        } else if let changes = object["changes"] as? [String: Any] {
            for path in changes.keys.sorted() {
                if let change = changes[path] as? [String: Any] { try extractChange(change, path: path, depth: depth, into: &values) }
            }
        }
        for key in ["patch", "input", "arguments", "code", "payload", "item"] {
            if let child = object[key] { try extractJSON(child, depth: depth + 1, into: &values) }
        }
    }

    private static func extractChange(_ change: [String: Any], path: String?, depth: Int, into values: inout [String]) throws {
        guard let diff = change["diff"] as? String ?? change["unified_diff"] as? String ?? change["patch"] as? String, !diff.isEmpty else { return }
        if recognized(diff) { try extract(diff, depth: depth, into: &values) }
        else if diff.hasPrefix("@@ -"), let path {
            let kind = change["kind"] as? [String: Any] ?? [:]
            let type = (change["type"] as? String ?? kind["type"] as? String ?? "").lowercased()
            let destination = change["move_path"] as? String ?? kind["move_path"] as? String ?? path
            let old = type == "add" ? "/dev/null" : "a/" + path
            let new = type == "delete" ? "/dev/null" : "b/" + destination
            let oldHeader = String(decoding: try JSONSerialization.data(withJSONObject: old, options: [.fragmentsAllowed]), as: UTF8.self)
            let newHeader = String(decoding: try JSONSerialization.data(withJSONObject: new, options: [.fragmentsAllowed]), as: UTF8.self)
            values.append("--- \(oldHeader)\n+++ \(newHeader)\n" + diff)
        }
    }

    private static func boundedLines(_ text: String, normalizeCR: Bool = true) throws -> [String] {
        guard text.utf8.count <= maximumInputBytes else { throw RecordedDiffError.limit("entrée supérieure à 8 Mio") }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count <= maximumLines else { throw RecordedDiffError.limit("plus de 100000 lignes") }
        return normalizeCR ? lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } : lines
    }

    private static func makeFile(old: String?, new: String?, operation: DiffFileOperation, index: Int, provenance: DiffProvenance, kind: RecordedDiffKind) -> RecordedFileDiff {
        let fields = [provenance.environmentID, old ?? "", new ?? "", String(index), kind.rawValue] + provenance.eventIDs + provenance.sources.flatMap { [$0.path, String($0.offset)] }
        var framed = Data()
        for field in fields { let bytes = Data(field.utf8); framed.append(Data("\(bytes.count):".utf8)); framed.append(bytes) }
        let identity = SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
        return RecordedFileDiff(id: "diff-file:" + identity, oldPath: old, newPath: new, operation: operation, provenance: provenance, kind: kind)
    }

    private static func appendLine(_ raw: String, hunk: inout RecordedDiffHunk, before: inout Int, after: inout Int) -> Bool {
        guard let prefix = raw.first else { return false }
        let kind: DiffLineKind
        switch prefix { case " ": kind = .context; case "-": kind = .removed; case "+": kind = .added; case "\\": kind = .metadata; default: return false }
        let usesBefore = kind == .context || kind == .removed
        let usesAfter = kind == .context || kind == .added
        hunk.lines.append(RecordedDiffLine(id: hunk.id + ":\(hunk.lines.count)", kind: kind, text: kind == .metadata ? raw : String(raw.dropFirst()), beforeLine: usesBefore ? hunk.beforeStart.map { $0 + before } : nil, afterLine: usesAfter ? hunk.afterStart.map { $0 + after } : nil, beforeOffset: usesBefore ? before + 1 : nil, afterOffset: usesAfter ? after + 1 : nil))
        if usesBefore { before += 1 }; if usesAfter { after += 1 }
        return true
    }

    private static func parseCodex(_ lines: [String], provenance: DiffProvenance) throws -> RecordedDiffDocument {
        var files: [RecordedFileDiff] = [], issues: [RecordedDiffIssue] = []
        var index = 1, sawEnd = false
        while index < lines.count {
            let header = lines[index]
            if header == "*** End Patch" { sawEnd = true; break }
            let operation: DiffFileOperation
            let path: String
            if header.hasPrefix("*** Add File: ") { operation = .added; path = String(header.dropFirst(14)) }
            else if header.hasPrefix("*** Delete File: ") { operation = .deleted; path = String(header.dropFirst(17)) }
            else if header.hasPrefix("*** Update File: ") { operation = .modified; path = String(header.dropFirst(17)) }
            else { issues.append(RecordedDiffIssue("unsupported", "Ligne de patch non reconnue.", patchLine: index + 1)); index += 1; continue }
            guard !path.isEmpty else { throw RecordedDiffError.unsupported("chemin de fichier absent") }
            guard files.count < 1024 else { throw RecordedDiffError.limit("plus de 1024 fichiers") }
            var file = makeFile(old: operation == .added ? nil : path, new: operation == .deleted ? nil : path, operation: operation, index: files.count, provenance: provenance, kind: .requestedPatch)
            index += 1
            while index < lines.count && !lines[index].hasPrefix("*** Add File: ") && !lines[index].hasPrefix("*** Update File: ") && !lines[index].hasPrefix("*** Delete File: ") && lines[index] != "*** End Patch" {
                if lines[index].hasPrefix("*** Move to: ") { file.newPath = String(lines[index].dropFirst(13)); file.operation = .renamed; index += 1; continue }
                if lines[index] == "*** End of File" { index += 1; continue }
                if lines[index].hasPrefix("*** ") { file.issues.append(RecordedDiffIssue("unsupported", "Marqueur de patch non reconnu.", patchLine: index + 1)); index += 1; continue }
                let hunkHeader = lines[index].hasPrefix("@@") ? lines[index] : ""
                let patchLine = index + 1
                if !hunkHeader.isEmpty { index += 1 }
                var hunk = RecordedDiffHunk(id: file.id + ":hunk:\(file.hunks.count)", header: hunkHeader, afterStart: operation == .added ? 1 : nil, patchLine: patchLine)
                var before = 0, after = 0
                while index < lines.count && !lines[index].hasPrefix("@@") && !lines[index].hasPrefix("*** ") {
                    if !appendLine(lines[index], hunk: &hunk, before: &before, after: &after) {
                        hunk.isComplete = false; file.issues.append(RecordedDiffIssue("incomplete", "Ligne du fragment non reconnue.", patchLine: index + 1)); break
                    }
                    if operation == .added && lines[index].first != "+" { hunk.isComplete = false; file.issues.append(RecordedDiffIssue("incomplete", "Une création apply_patch attend seulement des lignes ajoutées.", patchLine: index + 1)) }
                    index += 1
                }
                hunk.beforeCount = before; hunk.afterCount = after
                if !hunk.lines.isEmpty { file.hunks.append(hunk) }
                else if index < lines.count && hunkHeader.isEmpty && !lines[index].hasPrefix("*** ") { index += 1 }
                if index < lines.count && lines[index] == "*** End of File" { index += 1 }
            }
            files.append(file)
        }
        if !sawEnd { issues.append(RecordedDiffIssue("incomplete", "Fin du patch absente ; seuls les fragments enregistrés sont disponibles.")) }
        else if index + 1 < lines.count && lines[(index + 1)...].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { issues.append(RecordedDiffIssue("unsupported", "Contenu après la fin du patch ; ces données ne sont pas interprétées comme une seconde modification.")) }
        guard !files.isEmpty else { throw RecordedDiffError.unsupported("aucun fichier de patch disponible") }
        return RecordedDiffDocument(format: "apply_patch", kind: .requestedPatch, provenance: provenance, files: files, issues: issues)
    }

    private static func decodedHeaderValue(_ header: String) -> String? {
        let value = String(header.dropFirst(4)).components(separatedBy: "\t").first ?? ""
        let path: String
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { return nil }
            path = decoded
        } else { path = value }
        return path.isEmpty ? nil : path
    }

    private static func headerPath(_ header: String) -> String? {
        guard let path = decodedHeaderValue(header), path != "/dev/null" else { return nil }
        return path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    private static func hunkNumbers(_ header: String) -> (Int, Int, Int, Int)? {
        let expression = try? NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@"#)
        guard let match = expression?.firstMatch(in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)) else { return nil }
        func number(_ group: Int, fallback: Int? = nil) -> Int? {
            guard let range = Range(match.range(at: group), in: header) else { return fallback }
            return Int(header[range])
        }
        guard let old = number(1), let oldCount = number(2, fallback: 1), let new = number(3), let newCount = number(4, fallback: 1),
              oldCount <= maximumLines, newCount <= maximumLines, (old > 0 || oldCount == 0), (new > 0 || newCount == 0),
              !old.addingReportingOverflow(oldCount).overflow, !new.addingReportingOverflow(newCount).overflow else { return nil }
        return (old, oldCount, new, newCount)
    }

    private static func parseUnified(_ lines: [String], provenance: DiffProvenance, kind: RecordedDiffKind) throws -> RecordedDiffDocument {
        var files: [RecordedFileDiff] = [], issues: [RecordedDiffIssue] = []
        var index = 0
        var beforeBlob: String?, afterBlob: String?, beforeMode: String?, afterMode: String?
        while index < lines.count {
            if lines[index].hasPrefix("diff --git ") {
                beforeBlob = nil; afterBlob = nil; beforeMode = nil; afterMode = nil
            } else if lines[index].hasPrefix("index ") {
                let fields = lines[index].dropFirst(6).split(separator: " ")
                let names = fields.first?.components(separatedBy: "..") ?? []
                if names.count == 2 { beforeBlob = names[0]; afterBlob = names[1] }
                else { beforeBlob = nil; afterBlob = nil }
                if fields.count == 2 { beforeMode = String(fields[1]); afterMode = String(fields[1]) }
            } else if lines[index].hasPrefix("old mode ") { beforeMode = String(lines[index].dropFirst(9)) }
            else if lines[index].hasPrefix("new mode ") { afterMode = String(lines[index].dropFirst(9)) }
            else if lines[index].hasPrefix("new file mode ") { afterMode = String(lines[index].dropFirst(14)) }
            else if lines[index].hasPrefix("deleted file mode ") { beforeMode = String(lines[index].dropFirst(18)) }
            if lines[index].hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") {
                let old = headerPath(lines[index]), new = headerPath(lines[index + 1])
                let oldNull = decodedHeaderValue(lines[index]) == "/dev/null", newNull = decodedHeaderValue(lines[index + 1]) == "/dev/null"
                let pathUnknown = (old == nil && !oldNull) || (new == nil && !newNull) || (oldNull && newNull)
                let operation: DiffFileOperation = pathUnknown ? .unknown : oldNull ? .added : newNull ? .deleted : old != new ? .renamed : .modified
                guard files.count < 1024 else { throw RecordedDiffError.limit("plus de 1024 fichiers") }
                var file = makeFile(old: old, new: new, operation: operation, index: files.count, provenance: provenance, kind: kind)
                file.beforeBlobID = beforeBlob; file.afterBlobID = afterBlob
                file.beforeMode = beforeMode; file.afterMode = afterMode
                beforeBlob = nil; afterBlob = nil; beforeMode = nil; afterMode = nil
                if pathUnknown { file.issues.append(RecordedDiffIssue("unsupported", "Chemin cité Git non décodable ; aucune cible de fichier déduite.")) }
                index += 2
                while index < lines.count && !lines[index].hasPrefix("diff --git ") && !lines[index].hasPrefix("--- ") {
                    guard lines[index].hasPrefix("@@"), let numbers = hunkNumbers(lines[index]) else {
                        if lines[index].hasPrefix("@@") { file.issues.append(RecordedDiffIssue("incomplete", "En-tête de hunk invalide.", patchLine: index + 1)) }
                        index += 1; continue
                    }
                    var hunk = RecordedDiffHunk(id: file.id + ":hunk:\(file.hunks.count)", header: lines[index], beforeStart: numbers.0, afterStart: numbers.2, beforeCount: numbers.1, afterCount: numbers.3, patchLine: index + 1)
                    var before = 0, after = 0
                    index += 1
                    while index < lines.count && !lines[index].hasPrefix("@@") && !lines[index].hasPrefix("diff --git ") {
                        if before == numbers.1 && after == numbers.3 && !lines[index].hasPrefix("\\") { break }
                        if !appendLine(lines[index], hunk: &hunk, before: &before, after: &after) { break }
                        index += 1
                        if before > numbers.1 || after > numbers.3 { break }
                    }
                    hunk.isComplete = before == numbers.1 && after == numbers.3
                    if !hunk.isComplete { file.issues.append(RecordedDiffIssue("incomplete", "Le nombre de lignes enregistré ne correspond pas à l’en-tête ; mapping non garanti.", patchLine: hunk.patchLine)) }
                    file.hunks.append(hunk)
                }
                files.append(file)
            } else if lines[index].hasPrefix("Binary files ") || lines[index] == "GIT binary patch" {
                guard files.count < 1024 else { throw RecordedDiffError.limit("plus de 1024 fichiers") }
                var file = makeFile(old: nil, new: nil, operation: .binary, index: files.count, provenance: provenance, kind: kind)
                file.issues.append(RecordedDiffIssue("unsupported", "Diff binaire enregistré ; aucun texte ou état de fichier reconstruit.", patchLine: index + 1))
                files.append(file); index += 1
            } else { index += 1 }
        }
        guard !files.isEmpty else { throw RecordedDiffError.unsupported("aucun fragment unified diff disponible") }
        if files.contains(where: { $0.hunks.isEmpty && $0.operation != .binary }) { issues.append(RecordedDiffIssue("incomplete", "En-têtes disponibles sans contenu de hunk.")) }
        return RecordedDiffDocument(format: "unified", kind: kind, provenance: provenance, files: files, issues: issues)
    }

    /// Both complete text values must already be available to the caller. This does not load history.
    public static func compare(before: String, after: String, path: String, provenance: DiffProvenance) throws -> RecordedDiffDocument {
        let interval = LensSignposts.begin("ObservedTextComparison")
        defer { interval.end() }
        let old = try boundedLines(before, normalizeCR: false), new = try boundedLines(after, normalizeCR: false)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count) && sameLine(old[prefix], new[prefix]) { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix && sameLine(old[old.count - suffix - 1], new[new.count - suffix - 1]) { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)]), b = Array(new[prefix..<(new.count - suffix)])
        let rows = a.count + 1, columns = b.count + 1
        let cells = rows.multipliedReportingOverflow(by: columns)
        guard !cells.overflow, cells.partialValue <= maximumComparisonCells else { throw RecordedDiffError.limit("comparaison supérieure à 2000000 cellules après préfixe/suffixe communs") }
        var lcs = [Int32](repeating: 0, count: cells.partialValue)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) { try Task.checkCancellation(); for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i * columns + j] = sameLine(a[i], b[j]) ? 1 + lcs[(i + 1) * columns + j + 1] : max(lcs[(i + 1) * columns + j], lcs[i * columns + j + 1])
            } }
        }
        var operations: [(DiffLineKind, String)] = old.prefix(prefix).map { (.context, $0) }
        var i = 0, j = 0, tiedAlignment = false
        while i < a.count || j < b.count {
            if i < a.count && j < b.count && sameLine(a[i], b[j]) { operations.append((.context, a[i])); i += 1; j += 1 }
            else if i < a.count && (j == b.count || lcs[(i + 1) * columns + j] >= lcs[i * columns + j + 1]) {
                if j < b.count && lcs[(i + 1) * columns + j] == lcs[i * columns + j + 1] && lcs[(i + 1) * columns + j] > 0 { tiedAlignment = true }
                operations.append((.removed, a[i])); i += 1
            } else { operations.append((.added, b[j])); j += 1 }
        }
        operations += old.suffix(suffix).map { (.context, $0) }
        var file = makeFile(old: path, new: path, operation: .modified, index: 0, provenance: provenance, kind: .observedTextComparison)
        file.coverage = .completeTextsAvailable
        var hunk = RecordedDiffHunk(id: file.id + ":hunk:0", header: "Deux textes disponibles", beforeStart: old.isEmpty ? 0 : 1, afterStart: new.isEmpty ? 0 : 1, beforeCount: old.count, afterCount: new.count)
        let oldCounts = Dictionary(old.map { ($0, 1) }, uniquingKeysWith: +), newCounts = Dictionary(new.map { ($0, 1) }, uniquingKeysWith: +)
        var oldOffset = 0, newOffset = 0, ambiguous = false
        for operation in operations {
            if oldOffset % 512 == 0 { try Task.checkCancellation() }
            let marker = operation.0 == .context ? " " : operation.0 == .removed ? "-" : "+"
            _ = appendLine(marker + operation.1, hunk: &hunk, before: &oldOffset, after: &newOffset)
            let repeated = (oldCounts[operation.1] ?? 0) > 1 || (newCounts[operation.1] ?? 0) > 1
            let existsOnBothSides = (oldCounts[operation.1] ?? 0) > 0 && (newCounts[operation.1] ?? 0) > 0
            if existsOnBothSides && (!a.isEmpty || !b.isEmpty) && (tiedAlignment || repeated) { hunk.lines[hunk.lines.count - 1].alignmentAmbiguous = true; ambiguous = true }
        }
        if before.hasSuffix("\n") != after.hasSuffix("\n") {
            file.issues.append(RecordedDiffIssue("newline", "Présence du retour à la ligne final différente ; les lignes ne constituent pas une copie complète des octets."))
            hunk.lines.append(RecordedDiffLine(id: hunk.id + ":newline", kind: .metadata, text: before.hasSuffix("\n") ? "\\ Après : pas de retour à la ligne final" : "\\ Avant : pas de retour à la ligne final"))
        }
        if ambiguous { file.issues.append(RecordedDiffIssue("ambiguous", "Alignement déterministe ; unicité non établie pour les lignes répétées ou les chemins LCS équivalents.")) }
        file.hunks = [hunk]
        return RecordedDiffDocument(format: "textComparison", kind: .observedTextComparison, coverage: .completeTextsAvailable, provenance: provenance, files: [file], issues: file.issues)
    }

    private static func sameLine(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    public static func map(range: DiffLineRange, file: RecordedFileDiff, direction: DiffMappingDirection = .beforeToAfter) -> DiffRangeMapping {
        mapLines(range: range, hunks: file.hunks, provenance: file.provenance, requested: file.kind == .requestedPatch, direction: direction, local: false)
    }

    public static func mapFragment(range: DiffLineRange, hunk: RecordedDiffHunk, provenance: DiffProvenance, requested: Bool = true, direction: DiffMappingDirection = .beforeToAfter) -> DiffRangeMapping {
        mapLines(range: range, hunks: [hunk], provenance: provenance, requested: requested, direction: direction, local: true)
    }

    private static func mapLines(range: DiffLineRange, hunks: [RecordedDiffHunk], provenance: DiffProvenance, requested: Bool, direction: DiffMappingDirection, local: Bool) -> DiffRangeMapping {
        func result(_ status: DiffMappingStatus, _ reason: String, destinations: [DiffLineRange] = []) -> DiffRangeMapping {
            DiffRangeMapping(source: range, destinations: destinations, status: status, reason: reason, conditionalOnApplication: requested, provenance: provenance)
        }
        let end = range.start.addingReportingOverflow(range.count)
        guard range.start > 0, range.count > 0, range.count <= maximumLines, !end.overflow else { return result(.unavailable, "Plage invalide ou supérieure à 100000 lignes.") }
        var pairs: [Int: [Int]] = [:], removed = Set<Int>(), replacements = Set<Int>(), ambiguous = Set<Int>()
        for hunk in hunks where hunk.isComplete {
            var block: [RecordedDiffLine] = []
            func flush() {
                let changedSource = block.compactMap { direction == .beforeToAfter ? (local ? $0.beforeOffset : $0.beforeLine) : (local ? $0.afterOffset : $0.afterLine) }
                let changedTarget = block.compactMap { direction == .beforeToAfter ? (local ? $0.afterOffset : $0.afterLine) : (local ? $0.beforeOffset : $0.beforeLine) }
                let uncertainSource = block.filter { $0.alignmentAmbiguous }.compactMap { direction == .beforeToAfter ? (local ? $0.beforeOffset : $0.beforeLine) : (local ? $0.afterOffset : $0.afterLine) }
                ambiguous.formUnion(uncertainSource)
                removed.formUnion(changedSource)
                if !changedTarget.isEmpty { replacements.formUnion(changedSource) }
                block.removeAll(keepingCapacity: true)
            }
            for line in hunk.lines {
                if line.kind == .removed || line.kind == .added { block.append(line); continue }
                if line.kind == .metadata { continue }
                flush()
                let source = direction == .beforeToAfter ? (local ? line.beforeOffset : line.beforeLine) : (local ? line.afterOffset : line.afterLine)
                let target = direction == .beforeToAfter ? (local ? line.afterOffset : line.afterLine) : (local ? line.beforeOffset : line.beforeLine)
                if let source, let target { pairs[source, default: []].append(target); if line.alignmentAmbiguous { ambiguous.insert(source) } }
            }
            flush()
        }
        var targets: [Int] = [], missing = 0, deleted = 0, uncertain = false
        for line in range.start..<end.partialValue {
            if ambiguous.contains(line) { uncertain = true }
            if let values = pairs[line] { if Set(values).count != 1 || ambiguous.contains(line) || removed.contains(line) { uncertain = true }; targets += values }
            else if replacements.contains(line) { uncertain = true; deleted += 1 }
            else if removed.contains(line) { deleted += 1 }
            else { missing += 1 }
        }
        let ordered = Array(Set(targets)).sorted()
        var ranges: [DiffLineRange] = []
        for target in ordered {
            if let last = ranges.last, last.start + last.count == target { ranges[ranges.count - 1].count += 1 }
            else { ranges.append(DiffLineRange(start: target)) }
        }
        if uncertain { return result(.ambiguous, "Remplacement sans correspondance de lignes prouvée, chevauchement contradictoire ou alignement non unique.", destinations: ranges) }
        if missing == range.count { return result(.unavailable, "Plage hors des fragments numérotés, ou hunk incomplet. Aucun contenu absent n’est reconstruit.") }
        if deleted == range.count { return result(.deleted, "Les lignes sont supprimées sans lignes de remplacement associées.") }
        if missing > 0 || deleted > 0 { return result(.partial, "Seule une partie de la plage possède une correspondance enregistrée.", destinations: ranges) }
        return result(.mapped, requested ? "Correspondance proposée par ce patch ; conditionnelle à son application." : "Correspondance de lignes présente dans le diff.", destinations: ranges)
    }
}
