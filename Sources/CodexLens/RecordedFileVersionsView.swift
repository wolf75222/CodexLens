import SwiftUI
import LensCore

// Internal selection stays in the change's pane; no second window or duplicate navigator.
enum FileVersionPresentation: String, CaseIterable { case patch, before, after, comparison, gitReference }

@MainActor final class FileVersionInspection: ObservableObject {
    @Published private(set) var version: VerifiedFileVersion?
    @Published private(set) var comparison: RecordedDiffPresentation?
    @Published private(set) var issue: String?
    @Published private(set) var loading = false
    private var generation: UInt64 = 0
    func cancel() { generation &+= 1; loading = false }
    func load(file: RecordedFileDiff, environment: EnvironmentRecord, mode: FileVersionPresentation, files: FileService) async {
        generation &+= 1; let request = generation
        version = nil; comparison = nil; issue = nil; loading = true
        let span = LensSignposts.begin("FileVersionInspection"); defer { span.end(); if request == generation { loading = false } }
        do {
            try Task.checkCancellation()
            let resolver = RecordedFileVersionResolver(files: files)
            if mode == .comparison {
                async let before = resolver.resolve(file: file, environment: environment, side: .before)
                async let after = resolver.resolve(file: file, environment: environment, side: .after)
                let (a, b) = try await (before, after)
                var provenance = file.provenance
                provenance.beforeReference = a.objectID ?? "absent"; provenance.afterReference = b.objectID ?? "absent"
                provenance.authorEvidence = "Comparaison des versions citées par la trace ; application et auteur non déduits."
                let work = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    var document = try RecordedDiff.compare(before: a.text ?? "", after: b.text ?? "", path: file.path, provenance: provenance)
                    document.files[0].oldPath = a.isAbsent ? nil : file.oldPath
                    document.files[0].newPath = b.isAbsent ? nil : file.newPath
                    document.files[0].operation = file.operation
                    if a.isAbsent || b.isAbsent { document.issues.append(RecordedDiffIssue("absence", "Un côté est absent dans la trace ; il n’est pas un fichier vide.")) }
                    return try RecordedDiffPresentation(document: document)
                }
                let rendered = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, request == generation else { return }; comparison = rendered
            } else {
                let loaded: VerifiedFileVersion
                if mode == .gitReference {
                    guard let ref = environment.recordedRef else { throw FileServiceError.historicalUnavailable("Aucune référence Git enregistrée pour cet environnement.") }
                    // Deliberately separate baseline from before/after action: no time mapping exists.
                    let path = file.path.hasPrefix(environment.path + "/") ? String(file.path.dropFirst(environment.path.count + 1)) : file.path
                    let git = try await files.historicalText(environment: environment, relativePath: path, reference: ref)
                    loaded = VerifiedFileVersion(text: git.text, objectID: git.blobID, baseObjectID: git.reference)
                } else { loaded = try await resolver.resolve(file: file, environment: environment, side: mode == .before ? .before : .after) }
                guard !Task.isCancelled, request == generation else { return }; version = loaded
            }
        } catch is CancellationError { }
        catch { guard !Task.isCancelled, request == generation else { return }; issue = error.localizedDescription }
    }
}

struct RecordedFileVersionsView: View {
    @EnvironmentObject var store: LensStore
    let file: RecordedFileDiff
    let identity: String
    let mode: FileVersionPresentation
    @StateObject private var inspection = FileVersionInspection()
    private var environment: EnvironmentRecord { store.snapshot?.environments.first { $0.id == file.provenance.environmentID } ?? EnvironmentRecord(path: file.provenance.environmentID) }
    private var readIdentity: String { (store.snapshot?.root.id ?? "") + ":" + identity + ":" + mode.rawValue }
    private var side: FileVersionSide { mode == .before ? .before : .after }
    private var path: String { mode == .before ? file.oldPath ?? file.path : file.newPath ?? file.path }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .comparison {
                Text(LensL10n.text("Comparaison des versions citées · application de l’action non déduite")).font(LensUI.metadata).foregroundStyle(.secondary).padding(10)
            } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: LensSymbols.name(mode == .comparison ? "arrow.left.arrow.right" : "doc.text")).font(LensUI.header)
                    Spacer()
                    if let version = inspection.version, let text = version.text {
                        Button { store.copyLocalText(text, notice: LensL10n.text("Texte de la version vérifiée copié")) } label: { Image(systemName: LensSymbols.name("doc.on.doc")) }
                            .help(LensL10n.text("Copier la version complète")).accessibilityLabel(LensL10n.text("Copier la version complète"))
                    }
                }
                Text(LensL10n.text("Worktree : {0}", environment.id)).font(LensUI.metadata.monospaced()).lineLimit(2).textSelection(.enabled).help(environment.id)
                if let repository = environment.repositoryPath { Text(LensL10n.text("Dépôt associé : {0}", repository)).font(LensUI.metadata.monospaced()).lineLimit(1).truncationMode(.middle).help(repository) }
                Text(LensL10n.text("{0} → {1}", file.oldPath ?? "∅", file.newPath ?? "∅")).font(LensUI.metadata.monospaced()).textSelection(.enabled)
                Text(explanation).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                if let version = inspection.version {
                    if let id = version.objectID { Text(LensL10n.text("Blob vérifié : {0}", id)).font(LensUI.metadata.monospaced()).textSelection(.enabled) }
                    if let base = version.baseObjectID { Text(LensL10n.text("Base vérifiée : {0}", base)).font(LensUI.metadata.monospaced()).textSelection(.enabled) }
                }
            }.controlSize(.small).padding(10).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if inspection.loading { LensLoadingState(title: LensL10n.text("Recherche de la version dans le dépôt associé…")) }
            if let issue = inspection.issue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(LensL10n.text("Version indisponible"), systemImage: LensSymbols.name("exclamationmark.triangle")).font(.headline)
                        Text(LensL10n.display(issue)).textSelection(.enabled)
                        Text(LensL10n.text("Le patch enregistré reste consultable. Une référence Git ou le fichier actuel ne prouve pas l’état avant ou après cette action.")).font(LensUI.metadata).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else if let compared = inspection.comparison {
                RecordedDiffView(document: compared.document).id(compared.identity).frame(maxHeight: .infinity).layoutPriority(1)
            } else if let version = inspection.version {
                if let text = version.text {
                    CodeDocumentView(text: text, path: path, versionLabel: title + " · " + (version.objectID ?? ""), fontSize: store.fontSize, codeFont: store.codeFont,
                        onInvestigateSelection: { range, selected in ask(range: range, selected: selected, version: version) },
                        onCopyText: { value, _ in store.copyLocalText(value, notice: LensL10n.text("Texte de la version vérifiée copié")) }, loadedTextCopyLabel: LensL10n.text("Copier la version complète"))
                        .id(version.objectID ?? "absent")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(LensL10n.text("Fichier absent dans ce côté de la trace"), systemImage: LensSymbols.name("minus.circle")).font(.headline)
                        Text(LensL10n.text("Le marqueur Git d’absence et le chemin /dev/null concordent. Ce constat décrit la version citée par la trace ; le résultat de l’action reste distinct.")).font(LensUI.metadata).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else { Spacer() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: readIdentity) { await inspection.load(file: file, environment: environment, mode: mode, files: store.files) }
        .onDisappear { inspection.cancel() }
    }
    private var title: String {
        if mode == .comparison { return LensL10n.text("Comparer les versions citées") }
        if mode == .gitReference { return inspection.version == nil ? LensL10n.text("Référence Git · disponibilité à vérifier") : LensL10n.text("Version Git · référence de l’environnement") }
        if inspection.version == nil { return side == .before ? LensL10n.text("Avant · version non établie") : LensL10n.text("Après · version non établie") }
        if inspection.version?.text == nil { return side == .before ? LensL10n.text("Avant · fichier absent") : LensL10n.text("Après · fichier absent") }
        if inspection.version?.kind == .reconstructed { return LensL10n.text("Version reconstruite · empreinte vérifiée") }
        return side == .before ? LensL10n.text("Version Git · côté avant") : LensL10n.text("Version Git · côté après")
    }
    private var explanation: String {
        if inspection.version == nil { return LensL10n.text("Lens recherche une version complète dans les données enregistrées. Aucun contenu courant ne la remplace.") }
        if inspection.version?.text == nil { return LensL10n.text("Les marqueurs enregistrés établissent l’absence du fichier dans ce côté de la trace, sans prouver l’application de l’action.") }
        if mode == .gitReference { return LensL10n.text("Cette référence commitée appartient à l’environnement. Son lien avec le moment de l’action n’est pas établi ; l’état non commité reste inconnu.") }
        if inspection.version?.kind == .reconstructed { return LensL10n.text("Reconstruction en mémoire depuis une base vérifiée et le patch enregistré. L’empreinte complète correspond au blob cible ; cela ne prouve pas l’application de l’action.") }
        return LensL10n.text("Contenu cité par le diff enregistré, vérifié par son empreinte. Une demande ou un échec reste une demande ou un échec ; l’état effectif du worktree à cet instant n’est pas déduit.")
    }
    private func ask(range: NSRange, selected: String, version: VerifiedFileVersion) {
        guard let root = store.snapshot, let text = version.text, !selected.isEmpty,
              let line = NativeFileLocation.lineNumber(in: text, atUTF16Offset: range.location) else { return }
        do {
            let piece = EvidencePiece(id: "E001", kind: version.kind == .reconstructed ? "verifiedReconstructedCode" : "verifiedHistoricalCode", title: "\(path):\(line)",
                text: "\(title)\n\(explanation)\nWorktree : \(environment.id)\nBlob : \(version.objectID ?? "inconnu")\nBase : \(version.baseObjectID ?? "sans reconstruction")\n\n\(selected)",
                eventID: mode == .gitReference ? nil : file.provenance.eventIDs.first, agentID: mode == .gitReference ? nil : file.provenance.agentID, environmentID: environment.id, sourceRefs: mode == .gitReference ? [] : file.provenance.sources, knownVersion: version.objectID,
                location: EvidenceLocation(environmentID: environment.id, path: path, versionKind: version.kind == .reconstructed ? .verifiedReconstruction : .verifiedGitBlob, version: version.objectID,
                    side: mode == .gitReference ? .unified : side == .before ? .before : .after, firstLine: line, lastLine: line + max(0, selected.split(separator: "\n", omittingEmptySubsequences: false).count - 1)))
            try store.investigation.append([piece], rootID: root.root.id, cut: root.collectedAt)
            store.navigate(.investigation(store.investigation.capsule!.id), newTab: true)
        } catch { store.investigation.issue = error.localizedDescription }
    }
}
