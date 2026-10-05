import SwiftUI
import PDFKit
import LensCore

/// Captured bytes of a candidate, never a substitution for the original resource.
struct RecoveredResourcePreview: View {
    @EnvironmentObject var store: LensStore
    let candidate: ResourceRecoveryCandidate
    let original: ResourceRecord
    @State private var text: String?
    @State private var image: EvidenceImagePreview?
    @State private var pdf: PDFDocument?
    @State private var issue: String?
    @State private var loading = true
    private let recovery = ResourceRecoveryService()
    private var environment: EnvironmentRecord? {
        store.snapshot?.environments.filter { candidate.path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
    var body: some View {
        VSplitView {
            ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Label(LensL10n.text("Version locale retrouvée · distincte de la pièce jointe historique"), systemImage: "doc.viewfinder").font(.headline)
                Text(candidate.path).font(.caption.monospaced()).textSelection(.enabled)
                Text(LensL10n.text("Observée : {0} · modifiée : {1}", String(describing: candidate.observedAt.lensFormatted(date: .abbreviated, time: .standard)), String(describing: candidate.modifiedAt.lensFormatted(date: .abbreviated, time: .standard)))).font(.caption).foregroundStyle(.secondary)
                Text(LensL10n.display(candidate.confidence.label)).font(.caption).foregroundStyle(.secondary)
                if let environment {
                    EnvironmentIdentityView(environment: environment, availability: .accessible)
                } else { Text(LensL10n.text("Dépôt et worktree : non établis pour ce fichier retrouvé")).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup(LensL10n.text("Empreinte et référence d’origine")) {
                    Text(LensL10n.text("SHA-256 : {0}\nRessource d’origine : {1}\nRéférence enregistrée : {2}", String(describing: candidate.sha256), String(describing: original.id), String(describing: original.location))).font(.caption.monospaced()).textSelection(.enabled)
                }.font(.caption)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 90, idealHeight: 160, maxHeight: 260)
            Group {
            if loading { LensLoadingState(title: LensL10n.text("Vérification et capture du candidat…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let issue { Text(LensL10n.display(issue)).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            else if let text {
                CodeDocumentView(text: text, path: candidate.path, versionLabel: "SHA-256 " + candidate.sha256, fontSize: store.fontSize, codeFont: store.codeFont,
                    onInvestigateSelection: { range, selection in
                        guard !selection.isEmpty else { return }
                        store.addCodeEvidence(text: selection, path: candidate.path, environmentID: environment?.id,
                            version: candidate.sha256, line: NativeFileLocation.lineNumber(in: text, atUTF16Offset: range.location) ?? 1, historical: false)
                    })
            } else if let image { EvidenceImageView(preview: image, label: LensL10n.text("Version locale retrouvée de ") + original.name) }
            else if let pdf { PDFPreview(document: pdf) }
            }.frame(minHeight: 150, maxHeight: .infinity)
        }.task(id: candidate.id) {
            loading = true; issue = nil; text = nil; image = nil; pdf = nil
            do {
                let bytes = try await recovery.captureValidated(candidate)
                try Task.checkCancellation()
                switch URL(fileURLWithPath: candidate.path).pathExtension.lowercased() {
                case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif":
                    let value = try await EvidenceImagePreview.load(data: bytes)
                    try Task.checkCancellation(); image = value
                case "pdf":
                    let value = await Task.detached(priority: .userInitiated) { PDFDocument(data: bytes) }.value
                    try Task.checkCancellation()
                    guard let value else { throw LensError.unavailable("PDF illisible") }; pdf = value
                default:
                    let value = await Task.detached(priority: .userInitiated) { bytes.contains(0) ? nil : String(data: bytes, encoding: .utf8) }.value
                    try Task.checkCancellation()
                    guard let value else { throw LensError.unsupported(LensL10n.text("Ce format binaire n’a pas de prévisualisation locale dans Lens.")) }; text = value
                }
            } catch { if !Task.isCancelled { issue = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}
