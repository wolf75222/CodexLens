import Foundation

/// Recorded coordinates only. Nil versions/lines never fall back to today's file.
public struct OriginCodeReference: Codable, Hashable, Sendable {
    public let eventID: String
    public let environmentID: String
    public let path: String
    public let beforeVersion: String?
    public let afterVersion: String?
    public let beforeLine: Int?
    public let afterLine: Int?
    public let beforeFragmentOffset: Int?
    public let afterFragmentOffset: Int?
    public let hunkID: String
    public let hunkHeader: String
    public let sourceRefs: [SourceRef]
    public let selectedSide: EvidenceLocation.Side
    public init?(document: RecordedDiffDocument, file: RecordedFileDiff, hunk: RecordedDiffHunk, line: RecordedDiffLine, eventID selectedEventID: String? = nil, side: EvidenceLocation.Side? = nil) {
        let resolved = selectedEventID ?? (document.provenance.eventIDs.count == 1 ? document.provenance.eventIDs.first : nil)
        guard document.kind != .currentGit, let eventID = resolved, document.provenance.eventIDs.contains(eventID),
              document.files.contains(where: { $0.id == file.id }), file.hunks.contains(where: { $0.id == hunk.id }), hunk.lines.contains(where: { $0.id == line.id }) else { return nil }
        self.eventID = eventID; environmentID = document.provenance.environmentID; path = file.path
        beforeVersion = document.provenance.beforeReference ?? file.beforeBlobID
        afterVersion = document.provenance.afterReference ?? file.afterBlobID
        beforeLine = line.beforeLine; afterLine = line.afterLine
        beforeFragmentOffset = line.beforeOffset; afterFragmentOffset = line.afterOffset
        hunkID = hunk.id; hunkHeader = hunk.header; sourceRefs = document.provenance.sources
        selectedSide = side ?? (line.kind == .removed ? .before : line.kind == .added ? .after : .unified)
    }
    public func evidence(capturedAt: Date) throws -> EvidencePiece {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = "RÉFÉRENCE DE CODE ENREGISTRÉE\nLes positions de fragment sont locales ; elles ne remplacent pas les lignes absolues absentes. Les versions nulles sont inconnues ; aucun état courant n’est substitué.\n\n" + String(decoding: try encoder.encode(self), as: UTF8.self)
        let useAfter = selectedSide == .after
        let selectedLine = selectedSide == .unified ? nil : useAfter ? afterLine : beforeLine
        let fragmentOffset = selectedSide == .unified ? nil : useAfter ? afterFragmentOffset : beforeFragmentOffset
        return EvidencePiece(id: "codeReference", kind: "originCodeReference", title: "Localisation enregistrée · " + path, text: text, eventID: eventID, environmentID: environmentID,
            sourceRefs: sourceRefs, capturedAt: capturedAt, location: EvidenceLocation(environmentID: environmentID, path: path, versionKind: .recordedFragment,
                version: selectedSide == .unified ? nil : useAfter ? afterVersion : beforeVersion, side: selectedSide,
                coordinates: selectedLine != nil ? .absolute : .fragment,
                firstLine: selectedLine ?? fragmentOffset, hunkID: hunkID))
    }
    public func belongs(to change: ChangeRecord) -> Bool {
        let absolute = path.hasPrefix("/") ? path : (environmentID as NSString).appendingPathComponent(path)
        return change.eventID == eventID && change.environmentID == environmentID && URL(fileURLWithPath: absolute).standardizedFileURL.path == URL(fileURLWithPath: change.path).standardizedFileURL.path
    }
}
