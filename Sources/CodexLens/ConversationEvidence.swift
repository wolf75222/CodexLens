import Foundation
import CryptoKit
import LensCore

extension LensStore {
    /// Copies the selected, already frozen message. No journal or attachment is reread.
    @MainActor
    func addConversationEvidence(message: ConversationMessage, rootID: String, cut: Date) async -> Bool {
        guard !Task.isCancelled, snapshot?.root.id == rootID, message.threadID == rootID,
              message.status == .available, let text = message.text,
              !investigation.preparing, !investigation.sending else { return false }
        let generation = investigation.evidenceContextGeneration
        let prepared = await Task.detached(priority: .userInitiated) {
            let span = LensSignposts.begin("ConversationEvidence"); defer { span.end() }
            let bytes = Data(text.utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var prefix = bytes.prefix(48 * 1024)
            while String(data: prefix, encoding: .utf8) == nil, !prefix.isEmpty { prefix = prefix.dropLast() }
            let retained = String(data: prefix, encoding: .utf8) ?? ""
            let shortened = retained.utf8.count < text.utf8.count
            let header = "Thread : \(rootID)\nMessage : \(message.id)\nRôle : \(message.role.rawValue)\nAgent : \(message.agentID)\nTour : \(message.turnID ?? "inconnu")\nDate enregistrée : \(message.timestamp?.ISO8601Format() ?? "inconnue")\nDate de capture : \(cut.ISO8601Format())\nTexte enregistré et masqué. Les indices lexicaux ne suffisent pas à déterminer l’intention ni l’effet.\n\n"
            let coverage = message.limitations.map { CoverageIssue("conversation", $0, source: message.source.path) }
            let piece = EvidencePiece(id: "E001", kind: "frozenConversationMessage", title: "\(message.role.rawValue) · \(message.id)",
                text: header + retained + (shortened ? "\n[Extrait limité à 48 Kio ; l’export de conversation conserve le texte disponible.]" : ""),
                eventID: message.id, agentID: message.agentID, environmentID: message.environmentID,
                sourceRefs: [message.source] + message.supplementarySources, knownVersion: "SHA-256 du texte : " + digest,
                capturedAt: cut, coverage: coverage)
            let omissions = shortened ? [EvidenceOmission(reason: "Message limité à 48 Kio pour la question. L’export local conserve tout le texte disponible.", originalUTF8Bytes: text.utf8.count, retainedUTF8Bytes: retained.utf8.count)] : []
            return (piece, omissions)
        }.value
        guard !Task.isCancelled, snapshot?.root.id == rootID,
              investigation.evidenceContextGeneration == generation,
              !investigation.preparing, !investigation.sending else { return false }
        do {
            try investigation.append([prepared.0], rootID: rootID, cut: cut, omissions: prepared.1)
            if let capsule = investigation.capsule { navigate(.investigation(capsule.id), newTab: true) }
            return true
        } catch { investigation.issue = error.localizedDescription; return false }
    }
}
