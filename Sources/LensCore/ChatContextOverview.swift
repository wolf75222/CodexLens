import Foundation

/// Small immutable navigation metadata, not another retained copy of file/log text.
public struct ChatContextSource: Sendable, Equatable, Identifiable {
    public var id: String { address.url.absoluteString }
    public let address: EvidenceAddress
    public let title: String
    public let kind: String
    public let environment: String?
    public let version: String?
    public let location: EvidenceLocation?
    public let eventID: String?
    public let capturedAt: Date
    public let textBytes: Int
    public let coverageCount: Int
    public var estimatedRetainedBytes: Int {
        1024 + 2 * (title.utf8.count + kind.utf8.count + (environment?.utf8.count ?? 0)
            + (version?.utf8.count ?? 0) + (eventID?.utf8.count ?? 0) + address.url.absoluteString.utf8.count
            + (location?.path.utf8.count ?? 0) + (location?.version?.utf8.count ?? 0))
    }
}

public struct ChatContextOverview: Sendable, Equatable {
    public let rootID: String
    public let capsuleID: String
    public let capturedAt: Date
    public let sources: [ChatContextSource]
    public let environments: [String]
    public let textBytes: Int
    public let omissionCount: Int
    public var estimatedRetainedBytes: Int { sources.reduce(1024 + rootID.utf8.count + capsuleID.utf8.count) { $0 + $1.estimatedRetainedBytes } }
    public init(capsule: EvidenceCapsule) throws {
        guard try capsule.verifyDigest() else { throw LensError.corrupt("Le contexte archivé a changé ; aucun lien disponible.") }
        rootID = capsule.rootThreadID; capsuleID = capsule.id; capturedAt = capsule.collectionCut
        sources = try capsule.pieces.map { piece in
            ChatContextSource(address: try EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: piece.id),
                title: piece.title, kind: piece.kind, environment: piece.environmentID, version: piece.knownVersion,
                location: piece.location, eventID: piece.eventID, capturedAt: piece.capturedAt,
                textBytes: piece.text.utf8.count, coverageCount: piece.coverage.count)
        }
        environments = Set(sources.compactMap(\.environment)).sorted()
        textBytes = sources.reduce(0) { $0 + $1.textBytes }
        omissionCount = capsule.omissions.reduce(0) { $0 + max(1, $1.omittedCount) }
    }
}
