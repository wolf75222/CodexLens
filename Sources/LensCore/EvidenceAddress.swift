import Foundation

/// Coordinates belong to the captured evidence, never a substitute current file.
public struct EvidenceLocation: Codable, Hashable, Sendable {
    public enum VersionKind: String, Codable, Sendable { case capturedCurrent, verifiedGitBlob, verifiedReconstruction, recordedFragment }
    public enum Side: String, Codable, Sendable { case before, after, unified }
    public enum Coordinates: String, Codable, Sendable { case absolute, fragment }
    public let environmentID: String
    public let path: String
    public let versionKind: VersionKind
    public let version: String?
    public let side: Side
    public let coordinates: Coordinates
    public let firstLine: Int?
    public let lastLine: Int?
    public let hunkID: String?
    public init(environmentID: String, path: String, versionKind: VersionKind, version: String? = nil, side: Side = .unified, coordinates: Coordinates = .absolute, firstLine: Int? = nil, lastLine: Int? = nil, hunkID: String? = nil) {
        self.environmentID = environmentID; self.path = path; self.versionKind = versionKind; self.version = version
        self.side = side; self.coordinates = coordinates; self.firstLine = firstLine; self.lastLine = lastLine; self.hunkID = hunkID
    }
    func redacted() -> EvidenceLocation {
        EvidenceLocation(environmentID: EvidenceRedaction.redact(environmentID), path: EvidenceRedaction.redact(path), versionKind: versionKind, version: version.map(EvidenceRedaction.redact), side: side, coordinates: coordinates, firstLine: firstLine, lastLine: lastLine, hunkID: hunkID)
    }
}

/// Stable citation against an immutable capsule. Resolving has no I/O.
public struct EvidenceAddress: Codable, Hashable, Sendable {
    public let rootID: String
    public let capsuleID: String
    public let pieceID: String
    public init(rootID: String, capsuleID: String, pieceID: String) throws {
        let pattern = #"^[A-Za-z0-9_-]{1,160}$"#
        guard rootID.range(of: pattern, options: .regularExpression) != nil,
              capsuleID.range(of: pattern, options: .regularExpression) != nil,
              pieceID.range(of: #"^E[0-9]{3,6}$"#, options: .regularExpression) != nil else { throw LensError.unsupported("Adresse de citation invalide.") }
        self.rootID = rootID; self.capsuleID = capsuleID; self.pieceID = pieceID
    }
    public init(url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "codexlens", c.host == "session", c.fragment == nil else { throw LensError.unsupported("Lien de citation non reconnu.") }
        let items = c.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count, items.count == 3,
              items.first(where: { $0.name == "type" })?.value == "evidence",
              let capsule = items.first(where: { $0.name == "capsule" })?.value,
              let piece = items.first(where: { $0.name == "id" })?.value else { throw LensError.unsupported("Paramètres du lien de citation invalides ou ambigus.") }
        try self.init(rootID: String(c.path.dropFirst()), capsuleID: capsule, pieceID: piece)
    }
    public var url: URL {
        var c = URLComponents(); c.scheme = "codexlens"; c.host = "session"; c.path = "/" + rootID
        c.queryItems = [URLQueryItem(name: "type", value: "evidence"), URLQueryItem(name: "capsule", value: capsuleID), URLQueryItem(name: "id", value: pieceID)]
        return c.url!
    }
    public func resolve(in capsule: EvidenceCapsule) throws -> EvidencePiece {
        guard capsule.rootThreadID == rootID, capsule.id == capsuleID, try capsule.verifyDigest(), let piece = capsule.pieces.first(where: { $0.id == pieceID }) else { throw LensError.unavailable("Contenu indisponible dans ce contexte. Aucun fichier actuel n’est substitué.") }
        return piece
    }
}
