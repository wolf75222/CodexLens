import SwiftUI
import LensCore

struct EnvironmentSearchView: View {
    let environment: EnvironmentRecord
    var fontSize: Double = LensUI.defaultReadingSize
    var codeFont: LensCodeFont = .system
    let onOpenHit: (FileSearchHit) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var result: FileSearchResult?
    @State private var issue: String?
    @State private var searching = false
    @State private var searchProgress: FileSearchProgress?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    private let searcher = FileSearch()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(LensL10n.text("Rechercher dans les fichiers")).font(.title2); Spacer(); Button(LensL10n.text("Fermer"), action: onClose).keyboardShortcut(.cancelAction) }
            Text(LensL10n.text("Contenu actuel · {0}", String(describing: environment.path))).font(.caption.monospaced()).textSelection(.enabled)
            HStack {
                LensNativeSearchField(placeholder: LensL10n.text("Texte littéral, une ligne…"), text: $query, accessibilityLabel: LensL10n.text("Texte à rechercher dans l’environnement actuel"), onSubmit: { start() }).frame(height: 28).disabled(searching)
                if searching { Button(LensL10n.text("Interrompre")) { task?.cancel() } }
                else { Button(LensL10n.text("Rechercher")) { start() }.disabled(query.isEmpty).keyboardShortcut(.defaultAction) }
            }
            if searching {
                LensOperationProgressLine(progress: .init(stage: .searchingFiles))
                if let progress = searchProgress {
                    Text(LensL10n.text("{0} fichiers lus · {1} dossiers en attente", progress.searchedFiles.formatted(), progress.pendingDirectories.formatted()))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .help(LensL10n.text("Dossiers déjà découverts ; cette file peut grandir pendant la recherche."))
                    if let path = progress.currentPath {
                        Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle).help(path)
                    }
                }
            }
            if let issue { Text(LensL10n.display(issue)).foregroundStyle(LensAppearance.warningText).font(.caption).textSelection(.enabled) }
            if let result {
                Text(LensL10n.text("Recherche : « {0} »", String(describing: result.query))).font(LensUI.metadata).textSelection(.enabled)
                Text(LensL10n.text("{0} résultats · {1} fichiers lus · {2} octets · {3}", String(describing: result.hits.count), String(describing: result.searchedFiles), String(describing: result.decodedBytes), String(describing: result.complete ? LensL10n.text("recherche terminée") : LensL10n.text("couverture partielle")))).font(.caption).foregroundStyle(.secondary)
                List(result.hits) { hit in
                    Button { onOpenHit(hit) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(LensL10n.text("{0}:{1}:{2}", String(describing: hit.relativePath), String(describing: hit.line), String(describing: hit.column))).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(hit.snippet + (hit.snippetTruncated ? LensL10n.text(" […]") : "")).font(codeFont.font(size: fontSize)).foregroundStyle(.secondary).lineLimit(3)
                            Text(LensL10n.text("Version constatée {0}", String(describing: hit.observedAt.formatted()))).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
                if !result.coverage.isEmpty {
                    DisclosureGroup(LensL10n.text("{0} limites de recherche", String(describing: result.coverage.count))) { ScrollView { VStack(alignment: .leading, spacing: 5) { ForEach(result.coverage) { item in Text(LensL10n.display(item.message) + LensL10n.text(" · ") + item.source).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 120) }.font(.caption)
                }
            } else { Text(LensL10n.text("La recherche lit les fichiers accessibles hors du thread d'interface. Les résultats ouvrent leur worktree et leur ligne, avec vérification de la version lue.")).foregroundStyle(.secondary).font(.caption); Spacer() }
        }.padding(18).frame(minWidth: 760, minHeight: 500)
            .onDisappear { requestID = UUID(); task?.cancel(); task = nil; searching = false }
            .onChange(of: environment.id) { _, _ in requestID = UUID(); task?.cancel(); task = nil; searching = false; result = nil; issue = nil }
    }
    private func start() {
        guard !query.isEmpty, !searching else { return }
        searching = true; issue = nil; result = nil; searchProgress = nil
        let needle = query
        let request = UUID(); requestID = request
        task = Task {
            let (updates, continuation) = AsyncStream<FileSearchProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let progressTask = Task { @MainActor in
                for await progress in updates {
                    guard !Task.isCancelled, request == requestID, searching else { break }
                    searchProgress = progress
                }
            }
            defer { continuation.finish(); progressTask.cancel() }
            do {
                let next = try await searcher.search(environment: environment, query: needle, progress: { continuation.yield($0) })
                guard request == requestID else { return }
                // Explicit interruption returns its partial coverage; closing invalidates the request.
                result = next
            }
            catch { guard request == requestID else { return }; issue = error.localizedDescription }
            guard request == requestID else { return }
            searching = false
            task = nil
        }
    }
}
