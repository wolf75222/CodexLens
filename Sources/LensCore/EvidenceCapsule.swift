import Foundation
import CryptoKit

/// A frozen, user-selected piece of published evidence. Text never triggers a file read.
public struct EvidencePiece: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let title: String
    public let text: String
    public let eventID: String?
    public let agentID: String?
    public let environmentID: String?
    public let sourceRefs: [SourceRef]
    public let knownVersion: String?
    public let capturedAt: Date
    public let coverage: [CoverageIssue]
    public let location: EvidenceLocation?

    public init(id: String, kind: String, title: String, text: String, eventID: String? = nil, agentID: String? = nil, environmentID: String? = nil, sourceRefs: [SourceRef] = [], knownVersion: String? = nil, capturedAt: Date = Date(), coverage: [CoverageIssue] = [], location: EvidenceLocation? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.eventID = eventID; self.agentID = agentID; self.environmentID = environmentID; self.sourceRefs = sourceRefs; self.knownVersion = knownVersion; self.capturedAt = capturedAt; self.coverage = coverage
        self.location = location
    }
    fileprivate func cleaned(text replacement: String? = nil) -> EvidencePiece {
        EvidencePiece(id: id, kind: EvidenceRedaction.redact(kind), title: EvidenceRedaction.redact(title), text: replacement ?? EvidenceRedaction.redact(text), eventID: eventID, agentID: agentID, environmentID: environmentID.map(EvidenceRedaction.redact), sourceRefs: sourceRefs.map { SourceRef(path: EvidenceRedaction.redact($0.path), offset: $0.offset, length: $0.length, line: $0.line, sha256: $0.sha256) }, knownVersion: knownVersion.map(EvidenceRedaction.redact), capturedAt: capturedAt, coverage: coverage.map { CoverageIssue(EvidenceRedaction.redact($0.category), EvidenceRedaction.redact($0.message), source: EvidenceRedaction.redact($0.source)) }, location: location?.redacted())
    }
}

public struct EvidenceOmission: Codable, Sendable, Equatable {
    public let pieceID: String?
    public let reason: String
    public let originalUTF8Bytes: Int?
    public let retainedUTF8Bytes: Int?
    public let omittedCount: Int
    public init(pieceID: String? = nil, reason: String, originalUTF8Bytes: Int? = nil, retainedUTF8Bytes: Int? = nil, omittedCount: Int = 1) { self.pieceID = pieceID; self.reason = reason; self.originalUTF8Bytes = originalUTF8Bytes; self.retainedUTF8Bytes = retainedUTF8Bytes; self.omittedCount = omittedCount }
}

public struct CitationValidation: Codable, Sendable, Equatable {
    public let validIDs: [String]
    public let invalidIDs: [String]
    public let uncitedSourceIDs: [String]
    public var isValid: Bool { invalidIDs.isEmpty }
}

/// Only this immutable package is transmitted to an investigator. Its collection cut
/// is explicit; an AI answer is never added to the package as source evidence.
public struct EvidenceCapsule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let rootThreadID: String
    public let createdAt: Date
    public let collectionCut: Date
    public let pieces: [EvidencePiece]
    public let omissions: [EvidenceOmission]
    public let digestSHA256: String
    public let maxEncodedBytes: Int
    public let excludedFromAutocollection: Bool

    private init(id: String, rootThreadID: String, createdAt: Date, collectionCut: Date, pieces: [EvidencePiece], omissions: [EvidenceOmission], digestSHA256: String, maxEncodedBytes: Int) {
        self.id = id; self.rootThreadID = rootThreadID; self.createdAt = createdAt; self.collectionCut = collectionCut; self.pieces = pieces; self.omissions = omissions; self.digestSHA256 = digestSHA256; self.maxEncodedBytes = maxEncodedBytes; self.excludedFromAutocollection = true
    }

    public static func build(rootThreadID: String, collectionCut: Date, pieces proposed: [EvidencePiece], omissions initialOmissions: [EvidenceOmission] = [], maxBytes: Int = 256 * 1024, pieceMaxBytes: Int = 64 * 1024, id: String = UUID().uuidString, createdAt: Date = Date()) throws -> EvidenceCapsule {
        guard maxBytes >= 1024, maxBytes <= 32 * 1024 * 1024, pieceMaxBytes >= 256, pieceMaxBytes <= maxBytes else { throw LensError.unsupported("Limite de taille invalide (contexte : minimum 1 Kio ; élément : minimum 256 octets).") }
        var ids = Set<String>()
        for piece in proposed {
            guard piece.id.range(of: #"^E[0-9]{3,6}$"#, options: .regularExpression) != nil, ids.insert(piece.id).inserted else { throw LensError.unsupported("Identifiant d’élément invalide ou répété : \(piece.id). Utilisez E001, E002, …") }
        }
        let cleanRoot = EvidenceRedaction.redact(rootThreadID)
        var accepted: [EvidencePiece] = []
        var omitted = initialOmissions.map { EvidenceOmission(pieceID: $0.pieceID, reason: EvidenceRedaction.utf8Prefix(EvidenceRedaction.redact($0.reason), limit: 1024), originalUTF8Bytes: $0.originalUTF8Bytes, retainedUTF8Bytes: $0.retainedUTF8Bytes, omittedCount: $0.omittedCount) }
        let placeholder = String(repeating: "0", count: 64)
        func candidate(_ pieces: [EvidencePiece], _ omissions: [EvidenceOmission]) -> EvidenceCapsule { EvidenceCapsule(id: id, rootThreadID: cleanRoot, createdAt: createdAt, collectionCut: collectionCut, pieces: pieces, omissions: omissions, digestSHA256: placeholder, maxEncodedBytes: maxBytes) }
        for proposedPiece in proposed {
            let piece = proposedPiece.cleaned()
            let originalBytes = piece.text.utf8.count
            let entry: EvidencePiece
            // Origin contains a reversible reference graph. Cutting its JSON can
            // leave citations with unresolved source/object references. Account
            // separately for JSON string escaping and metadata; keep it atomic.
            let isStructuredOrigin = piece.kind == "originEvidence"
            let entryLimit = isStructuredOrigin ? min(maxBytes, max(pieceMaxBytes, 128 * 1024)) : pieceMaxBytes
            if try CapsuleJSON.encode(piece).count <= entryLimit { entry = piece }
            else if isStructuredOrigin {
                omitted.append(EvidenceOmission(pieceID: piece.id, reason: "Origine structurée supérieure au budget de \(entryLimit) octets JSON ; pièce entière omise, aucune référence partielle transmise.", originalUTF8Bytes: originalBytes, retainedUTF8Bytes: 0))
                continue
            }
            else {
                let marker = "\n[Extrait limité ; texte supplémentaire omis.]"
                guard try CapsuleJSON.encode(piece.cleaned(text: marker)).count <= pieceMaxBytes else { omitted.append(EvidenceOmission(pieceID: piece.id, reason: "Métadonnées de l'entrée supérieures à la limite de \(pieceMaxBytes) octets ; entrée omise.", originalUTF8Bytes: originalBytes, retainedUTF8Bytes: 0)); continue }
                var lower = 0, upper = min(originalBytes, pieceMaxBytes), retained = ""
                while lower <= upper {
                    let middle = lower + (upper - lower) / 2
                    let prefix = EvidenceRedaction.utf8Prefix(piece.text, limit: middle)
                    if try CapsuleJSON.encode(piece.cleaned(text: prefix + marker)).count <= pieceMaxBytes { retained = prefix; lower = middle + 1 } else { upper = middle - 1 }
                }
                entry = piece.cleaned(text: retained + marker)
                omitted.append(EvidenceOmission(pieceID: piece.id, reason: "Texte d'entrée borné à \(pieceMaxBytes) octets JSON ; aucun scalaire UTF-8 coupé.", originalUTF8Bytes: originalBytes, retainedUTF8Bytes: retained.utf8.count))
            }
            if try CapsuleJSON.encode(candidate(accepted + [entry], omitted)).count <= maxBytes { accepted.append(entry) }
            else { omitted.append(EvidenceOmission(pieceID: piece.id, reason: "Budget total de \(maxBytes) octets atteint ; entrée omise.", originalUTF8Bytes: originalBytes, retainedUTF8Bytes: 0)) }
        }
        while try CapsuleJSON.encode(candidate(accepted, omitted)).count > maxBytes {
            if let removed = accepted.popLast() { omitted.append(EvidenceOmission(pieceID: removed.id, reason: "Entrée retirée pour préserver le budget total et la liste des omissions.", originalUTF8Bytes: removed.text.utf8.count, retainedUTF8Bytes: 0)) }
            else {
                let count = omitted.reduce(0) { $0 + max(1, $1.omittedCount) }
                omitted = [EvidenceOmission(reason: "La liste détaillée des omissions dépasse le budget. \(count) omissions sont regroupées ; aucun détail de ces omissions n'est transmis.", omittedCount: count)]
                guard try CapsuleJSON.encode(candidate([], omitted)).count <= maxBytes else { throw LensError.unsupported("La limite de taille ne permet pas de conserver les métadonnées du contexte.") }
            }
        }
        let unsigned = candidate(accepted, omitted)
        let digest = try unsigned.computedDigest()
        let capsule = EvidenceCapsule(id: id, rootThreadID: cleanRoot, createdAt: createdAt, collectionCut: collectionCut, pieces: accepted, omissions: omitted, digestSHA256: digest, maxEncodedBytes: maxBytes)
        _ = try capsule.transmissionJSON()
        return capsule
    }

    public func transmissionJSON() throws -> Data {
        let data = try CapsuleJSON.encode(self)
        guard data.count <= maxEncodedBytes else { throw LensError.unsupported("Le contexte dépasse la limite de taille ; envoi refusé.") }
        return data
    }
    public func verifyDigest() throws -> Bool { guard excludedFromAutocollection else { return false }; return try computedDigest() == digestSHA256 }
    private func computedDigest() throws -> String {
        let unsigned = EvidenceCapsule(id: id, rootThreadID: rootThreadID, createdAt: createdAt, collectionCut: collectionCut, pieces: pieces, omissions: omissions, digestSHA256: "", maxEncodedBytes: maxEncodedBytes)
        return SHA256.hash(data: try CapsuleJSON.encode(unsigned)).map { String(format: "%02x", $0) }.joined()
    }
    public func validateCitations(in analysis: String) -> CitationValidation {
        let expression = try! NSRegularExpression(pattern: #"\[(E[A-Za-z0-9_-]{1,32})\]"#)
        let present = Set(pieces.map(\.id))
        var valid: [String] = [], invalid: [String] = [], seen = Set<String>()
        for match in expression.matches(in: analysis, range: NSRange(analysis.startIndex..., in: analysis)) {
            guard let range = Range(match.range(at: 1), in: analysis) else { continue }
            let id = String(analysis[range]); guard seen.insert(id).inserted else { continue }
            if present.contains(id) { valid.append(id) } else { invalid.append(id) }
        }
        return CitationValidation(validIDs: valid, invalidIDs: invalid, uncitedSourceIDs: pieces.map(\.id).filter { !Set(valid).contains($0) })
    }
    /// For capsules already validated at creation/import/load. The recorded JSON
    /// rounds dates to milliseconds, so Swift's raw Date equality after a round
    /// trip can differ even when the captured bytes and their digest are identical.
    /// This comparison does not validate an untrusted capsule; verifyDigest does.
    public func representsSameFrozenContent(as other: EvidenceCapsule) -> Bool {
        id == other.id && rootThreadID == other.rootThreadID && digestSHA256 == other.digestSHA256 &&
        maxEncodedBytes == other.maxEncodedBytes && excludedFromAutocollection == other.excludedFromAutocollection
    }
}

enum CapsuleJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .custom { date, encoder in
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        guard millis.isFinite, abs(millis) <= 9_000_000_000_000_000 else { throw EncodingError.invalidValue(date, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Date non finie ou hors du domaine pris en charge.")) }
        var container = encoder.singleValueContainer(); try container.encode(Int64(millis))
    }; return try encoder.encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { decoder in let millis = try decoder.singleValueContainer().decode(Int64.self); return Date(timeIntervalSince1970: Double(millis) / 1000) }; return try decoder.decode(type, from: data) }
}

enum EvidenceRedaction {
    static func redact(_ text: String) -> String {
        var value = text
        let patterns: [(String, String)] = [
            (#"(?is)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#, "[clé privée masquée]"),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/-]{8,}"#, "$1[secret masqué]"),
            (#"(?i)([\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|passwd|client[_-]?secret|secret[_-]?key)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&}]+)"#, "$1[secret masqué]"),
            (#"\bsk-[A-Za-z0-9_-]{12,}\b"#, "[secret masqué]"),
            (#"(?i)(https?://)[^\s/:@]+:[^\s/@]+@"#, "$1[identifiants masqués]@"),
            (#"(?i)([?&](?:token|key|api_key|access_token|password)=)[^&\s]+"#, "$1[secret masqué]")
        ]
        for (pattern, replacement) in patterns { if let expression = try? NSRegularExpression(pattern: pattern) { value = expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement) } }
        return value
    }
    static func utf8Prefix(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let bytes = Data(text.utf8); guard bytes.count > limit else { return text }
        var end = limit
        while end > 0 { if let prefix = String(data: bytes.prefix(end), encoding: .utf8) { return prefix }; end -= 1 }
        return ""
    }
}
