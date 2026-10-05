import Foundation
import CryptoKit

public enum FileVersionSide: String, Codable, CaseIterable, Sendable { case before, after }
public enum RecordedFileVersionPlan: Hashable, Sendable {
    case blob(id: String, path: String)
    case absent
    case unavailable(String)
}
public enum VerifiedFileVersionKind: String, Sendable { case gitBlob, reconstructed }
public struct VerifiedFileVersion: Sendable {
    public let text: String?
    public let objectID: String?
    public let baseObjectID: String?
    public let kind: VerifiedFileVersionKind
    public var isAbsent: Bool { text == nil }
    public init(text: String?, objectID: String?, baseObjectID: String? = nil, kind: VerifiedFileVersionKind = .gitBlob) {
        self.text = text; self.objectID = objectID; self.baseObjectID = baseObjectID; self.kind = kind
    }
}

/// A blob name in a diff proves the cited bytes, not the application of the action,
/// its author, or the dirty worktree at that time. No current file enters this resolver.
public enum RecordedFileVersion {
    public static func isFullObjectID(_ id: String) -> Bool {
        (id.count == 40 || id.count == 64) && id.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    public static func objectID(text: String, length: Int = 40) -> String {
        let bytes = Data(text.utf8)
        var object = Data("blob \(bytes.count)\0".utf8); object.append(bytes)
        return length == 64 ? SHA256.hash(data: object).map { String(format: "%02x", $0) }.joined()
            : Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }
    public static func plan(file: RecordedFileDiff, side: FileVersionSide) -> RecordedFileVersionPlan {
        let id = side == .before ? file.beforeBlobID : file.afterBlobID
        let path = side == .before ? file.oldPath : file.newPath
        let mode = side == .before ? file.beforeMode : file.afterMode
        guard let id, isFullObjectID(id) else {
            return .unavailable("Le patch ne contient pas d’identifiant complet de blob pour ce côté. Les fragments restent accessibles ; aucune version actuelle ne les remplace.")
        }
        if id.allSatisfy({ $0 == "0" }) {
            guard path == nil, (side == .before && file.operation == .added) || (side == .after && file.operation == .deleted) else {
                return .unavailable("Le marqueur d’absence et le chemin enregistré ne concordent pas.")
            }
            return .absent
        }
        guard let path, !path.isEmpty, mode == "100644" || mode == "100755" else {
            return .unavailable("Le chemin ou le mode Git du fichier régulier n’est pas établi. Les liens et sous-modules ne sont pas ouverts comme du code historique.")
        }
        return .blob(id: id.lowercased(), path: path)
    }

    /// Applies absolute, complete unified hunks in memory, then verifies the complete
    /// target blob digest. Applicability alone is never enough. This is a reconstruction
    /// of the diff's target object, not proof that an action succeeded or a repository state.
    public static func reconstruct(file: RecordedFileDiff, base: String, side: FileVersionSide) throws -> VerifiedFileVersion {
        let span = LensSignposts.begin("VerifiedVersionReconstruction"); defer { span.end() }
        guard case .blob(let targetID, _) = plan(file: file, side: side), !file.hunks.isEmpty,
              file.issues.isEmpty, file.hunks.allSatisfy({ $0.isComplete && $0.beforeStart != nil && $0.afterStart != nil }) else {
            throw FileServiceError.historicalUnavailable("Patch complet et empreinte cible nécessaires à la reconstruction.")
        }
        let baseSide: FileVersionSide = side == .after ? .before : .after
        let baseID: String
        switch plan(file: file, side: baseSide) {
        case .blob(let id, _):
            guard objectID(text: base, length: id.count) == id else { throw FileServiceError.historicalUnavailable("La base ne correspond pas au blob enregistré.") }
            baseID = id
        case .absent:
            guard base.isEmpty else { throw FileServiceError.historicalUnavailable("La base enregistrée est absente, pas un fichier contenant du texte.") }
            baseID = "absent"
        case .unavailable: throw FileServiceError.historicalUnavailable("Base complète non vérifiable.")
        }
        guard base.utf8.count <= RecordedDiff.maximumInputBytes else { throw FileServiceError.outputTooLarge }
        var lines = base.components(separatedBy: "\n")
        if base.hasSuffix("\n") { lines.removeLast() }
        if base.isEmpty { lines = [] }
        guard lines.count <= RecordedDiff.maximumLines else { throw RecordedDiffError.limit("base supérieure à 100000 lignes") }
        var output: [String] = [], cursor = 0
        for hunk in file.hunks {
            try Task.checkCancellation()
            let start = side == .after ? hunk.beforeStart! : hunk.afterStart!
            let count = side == .after ? hunk.beforeCount : hunk.afterCount
            let targetStart = side == .after ? hunk.afterStart! : hunk.beforeStart!
            let targetCount = side == .after ? hunk.afterCount : hunk.beforeCount
            let offset = count == 0 ? start : start - 1
            guard offset >= cursor, offset <= lines.count, count <= lines.count - offset else { throw FileServiceError.historicalUnavailable("Positions du patch incompatibles avec la base.") }
            output += lines[cursor..<offset]; cursor = offset
            let targetOffset = targetCount == 0 ? targetStart : targetStart - 1
            guard targetOffset == output.count else { throw FileServiceError.historicalUnavailable("Positions de la version cible incompatibles avec le patch.") }
            var consumed = 0, produced = 0
            for (rowIndex, row) in hunk.lines.enumerated() {
                if rowIndex % 512 == 0 { try Task.checkCancellation() }
                switch row.kind {
                case .context:
                    guard cursor < lines.count, lines[cursor].utf8.elementsEqual(row.text.utf8) else { throw FileServiceError.historicalUnavailable("Contexte du patch différent de la base vérifiée.") }
                    output.append(lines[cursor]); cursor += 1; consumed += 1; produced += 1
                case .removed, .added:
                    let removes = side == .after ? row.kind == .removed : row.kind == .added
                    if removes {
                        guard cursor < lines.count, lines[cursor].utf8.elementsEqual(row.text.utf8) else { throw FileServiceError.historicalUnavailable("Ligne retirée différente de la base vérifiée.") }
                        cursor += 1; consumed += 1
                    } else { output.append(row.text); produced += 1 }
                case .metadata:
                    guard row.text == "\\ No newline at end of file" else { throw FileServiceError.historicalUnavailable("Métadonnée de patch non prise en charge.") }
                }
            }
            guard consumed == count, produced == targetCount else { throw FileServiceError.historicalUnavailable("Nombre de lignes du patch incomplet.") }
        }
        output += lines[cursor...]
        guard output.count <= RecordedDiff.maximumLines else { throw RecordedDiffError.limit("version reconstruite supérieure à 100000 lignes") }
        let joined = output.joined(separator: "\n")
        guard joined.utf8.count <= RecordedDiff.maximumInputBytes else { throw FileServiceError.outputTooLarge }
        for candidate in [joined, joined + "\n"] where candidate.utf8.count <= RecordedDiff.maximumInputBytes {
            try Task.checkCancellation()
            if objectID(text: candidate, length: targetID.count) == targetID {
                return VerifiedFileVersion(text: candidate, objectID: targetID, baseObjectID: baseID, kind: .reconstructed)
            }
        }
        throw FileServiceError.historicalUnavailable("La reconstruction ne correspond pas à l’empreinte cible. Aucun texte approché n’est présenté comme une version complète.")
    }
}

public actor RecordedFileVersionResolver {
    private let files: FileService
    public init(files: FileService) { self.files = files }
    public func resolve(file: RecordedFileDiff, environment: EnvironmentRecord, side: FileVersionSide) async throws -> VerifiedFileVersion {
        guard environment.id == file.provenance.environmentID else { throw FileServiceError.historicalUnavailable("Environnement de la trace différent de l’environnement demandé.") }
        try Task.checkCancellation()
        switch RecordedFileVersion.plan(file: file, side: side) {
        case .absent: return VerifiedFileVersion(text: nil, objectID: nil)
        case .unavailable(let reason): throw FileServiceError.historicalUnavailable(reason)
        case .blob(let id, let path):
            do { return try await files.recordedBlob(environment: environment, recordedPath: path, objectID: id) }
            catch FileServiceError.objectUnavailable {
                let opposite: FileVersionSide = side == .before ? .after : .before
                let base: String
                switch RecordedFileVersion.plan(file: file, side: opposite) {
                case .blob(let baseID, let basePath):
                    base = try await files.recordedBlob(environment: environment, recordedPath: basePath, objectID: baseID).text!
                case .absent: base = ""
                case .unavailable: throw FileServiceError.historicalUnavailable("Blob cible absent et aucune base vérifiable pour le reconstruire.")
                }
                return try RecordedFileVersion.reconstruct(file: file, base: base, side: side)
            }
        }
    }
}
