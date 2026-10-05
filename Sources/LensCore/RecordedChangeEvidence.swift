import Foundation

/// Source and contextual counterpart remain separate: a result never substitutes its call's input.
public struct RecordedChangeTraceSelection: Sendable {
    public let source: LensEvent
    public let call: LensEvent?
    public let result: LensEvent?
    public let missingLinkedContext: Bool
}

public enum RecordedChangeEvidence {
    /// Freeze the selected recorded diff, never a current worktree comparison.
    /// Run parsing/encoding off the UI actor. Oversized documents are rejected
    /// explicitly rather than sending a silently truncated diff.
    public static func frozenPieces(change: ChangeRecord, selection: RecordedChangeTraceSelection, detail: EventDetail, capturedAt: Date, maximumBytes: Int = 256 * 1024) throws -> [EvidencePiece] {
        let documents = try documents(change: change, selection: selection, detail: detail)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var retained = 0
        return try documents.enumerated().map { index, document in
            try Task.checkCancellation()
            let data = try encoder.encode(document)
            retained += data.count
            guard retained <= maximumBytes else { throw LensError.unavailable("Le diff dépasse la limite de contexte de 256 Kio. Sélectionnez un fragment ; le diff complet n’est pas joint.") }
            return EvidencePiece(id: String(format: "E%03d", index + 1), kind: "recordedDiffDocument", title: "Diff enregistré · \(change.path)",
                text: "FRAGMENTS ENREGISTRÉS\nCe document contient le diff et ses références. Les fichiers complets et l’auteur ne sont pas établis par ce fragment. Le contenu actuel n’est pas lu.\n\n" + String(decoding: data, as: UTF8.self),
                eventID: change.eventID, agentID: selection.source.agentID, environmentID: change.environmentID,
                sourceRefs: document.provenance.sources, capturedAt: capturedAt)
        }
    }

    public static func select(change: ChangeRecord, event: LensEvent, related: LensEvent? = nil) throws -> RecordedChangeTraceSelection {
        guard change.eventID == event.id else { throw LensError.unavailable("La source ne correspond pas à l'événement enregistré de cette modification.") }
        let counterpart = related.flatMap { event.relatedEventID == $0.id ? $0 : nil }
        let call: LensEvent?, result: LensEvent?
        if change.kind == .recordedResult {
            result = event
            call = counterpart?.kind == .toolCall ? counterpart : nil
        } else {
            call = event.kind == .toolCall ? event : counterpart?.kind == .toolCall ? counterpart : nil
            result = event.kind == .toolResult ? event : counterpart?.kind == .toolResult ? counterpart : nil
        }
        return RecordedChangeTraceSelection(source: event, call: call, result: result, missingLinkedContext: event.relatedEventID != nil && counterpart == nil)
    }

    /// Pure parsing of only the selected source. No disk access, execution, or current Git comparison.
    public static func documents(change: ChangeRecord, selection: RecordedChangeTraceSelection, detail: EventDetail) throws -> [RecordedDiffDocument] {
        guard change.eventID == selection.source.id else { throw LensError.unavailable("La source du diff enregistré a changé.") }
        let event = selection.source
        let requested = change.kind == .requestedPatch
        let provenance = DiffProvenance(environmentID: change.environmentID, eventIDs: [event.id], sources: [event.source] + event.supplementarySources, agentID: event.agentID,
            authorEvidence: requested ? "Agent de l'appel demandant ce patch ; l'application effective est distincte." : nil)
        let kind: RecordedDiffKind = requested ? .requestedPatch : .recordedDiff
        // Native completed FileChange details may exist only in raw; call arguments are excluded for results.
        let values = (requested ? [detail.arguments] : [detail.output]) + selectedRawValues(detail.raw, requested: requested)
        var patches: [String] = [], seen = Set<String>()
        for value in values where !value.isEmpty {
            for patch in try RecordedDiff.extractRecordedDiffs(from: value) where seen.insert(patch).inserted { patches.append(patch) }
        }
        let target = URL(fileURLWithPath: change.path).standardizedFileURL.path
        return try patches.map { patch in
            var document = try RecordedDiff.parse(patch, provenance: provenance, kind: kind)
            document.files = document.files.filter { file in
                [file.oldPath, file.newPath].compactMap { $0 }.contains { recorded in
                    let path = recorded.hasPrefix("/") ? recorded : (change.environmentID as NSString).appendingPathComponent(recorded)
                    return URL(fileURLWithPath: path).standardizedFileURL.path == target
                }
            }
            return document
        }.filter { !$0.files.isEmpty && (requested || $0.kind != .requestedPatch) }
    }

    /// An item ID may coalesce call and completed records. Keep their physical
    /// payload roles separate; scanning all raw strings would relabel an input as a result.
    private static func selectedRawValues(_ raw: String, requested: Bool) -> [String] {
        var values: [String] = [], foundRecord = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            foundRecord = true
            let payload = root["payload"] as? [String: Any] ?? root["params"] as? [String: Any] ?? root
            let type = payload["type"] as? String ?? ""
            if requested, ["function_call", "custom_tool_call"].contains(type) {
                values.append(String(line))
            } else if !requested, ["function_call_output", "custom_tool_call_output"].contains(type) {
                values.append(String(line))
            } else if !requested, let item = payload["item"] as? [String: Any],
                      ["FileChange", "fileChange"].contains(item["type"] as? String ?? ""),
                      type == "item_completed" || root["method"] as? String == "item/completed" {
                values.append(String(line))
            }
        }
        return foundRecord ? values : raw.isEmpty ? [] : [raw]
    }
}
