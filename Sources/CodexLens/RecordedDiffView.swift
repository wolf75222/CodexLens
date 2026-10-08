import SwiftUI
import LensCore
import CryptoKit

struct RecordedChangeView: View {
    @EnvironmentObject var store: LensStore
    @Environment(\.lensWindowContext) private var windowContext
    let change: ChangeRecord
    @State private var documents: [RecordedDiffPresentation] = []
    @State private var issue: String?
    @State private var resultEvent: LensEvent?
    @State private var callEvent: LensEvent?
    @State private var loading = false
    @State private var loadGeneration: UInt64 = 0
    @State private var reloadTask: Task<Void, Never>?
    @State private var loadedSources: [SourceRef] = []
    @State private var documentIndex = 0
    @State private var contextExpanded = false
    @State private var versionPresentation: FileVersionPresentation = .patch
    @State private var versionReadingKey: String?
    init(change: ChangeRecord, initialContextExpanded: Bool = false) {
        self.change = change
        _contextExpanded = State(initialValue: initialContextExpanded)
    }
    private var sourceEvent: LensEvent? { store.event(change.eventID) ?? store.snapshot?.events.first { $0.id == change.eventID } }
    private var availableSources: [SourceRef] { sourceEvent.map { [$0.source] + $0.supplementarySources } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            changeHeader.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
            if loading { LensProgressIndicator(LensL10n.text("Lecture du diff enregistré…")).controlSize(.small).frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true) }
            if !loadedSources.isEmpty, loadedSources != availableSources { Button(LensL10n.text("Lire les nouvelles traces enregistrées")) { startLoad() }.controlSize(.small).padding(.horizontal, 10).padding(.bottom, 5).disabled(loading).fixedSize(horizontal: false, vertical: true) }
            VSplitView {
            Group {
            if documents.indices.contains(documentIndex) {
                let presentation = documents[documentIndex]
                if versionPresentation != .patch, let file = presentation.document.files.first {
                    RecordedFileVersionsView(file: file, identity: presentation.identity, mode: versionPresentation)
                        .id(presentation.identity).frame(maxHeight: .infinity).layoutPriority(1)
                } else {
                    RecordedDiffView(document: presentation.document).id(presentation.identity).frame(maxHeight: .infinity).layoutPriority(1)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(changeLabel(change.kind)).font(LensUI.header)
                        Text(change.path).font(LensUI.metadata.monospaced()).textSelection(.enabled)
                        Text(LensL10n.text("Environnement enregistré : {0}", String(describing: change.environmentID))).font(LensUI.metadata.monospaced()).textSelection(.enabled)
                        Text(LensL10n.text("Versions complètes : non établies par ce résultat.")).font(LensUI.metadata).foregroundStyle(.secondary)
                        if let issue { Label(LensL10n.display(issue), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled) }
                        if !loading { Text(LensL10n.text("Le résultat d'un outil ne garantit pas une capture des versions complètes. L'inspecteur donne accès à la trace intégrale.")).font(LensUI.metadata).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(maxHeight: .infinity).layoutPriority(1)
            }
            }.frame(minHeight: 180, maxHeight: .infinity)
                .background(LensPaneSizing(key: "recorded-change-content", preferredWidth: 500, context: windowContext, isVertical: false))
            DisclosureGroup(isExpanded: $contextExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let issue, !documents.isEmpty { Label(LensL10n.display(issue), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled) }
                        Text(change.evidence).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                        if let event = sourceEvent { Text(LensL10n.text("Action {0} · agent {1}", String(describing: event.timestamp.lensFormatted(date: .abbreviated, time: .standard)), String(describing: event.agentID))).font(LensUI.metadata.monospaced()).textSelection(.enabled) }
                        if change.kind == .recordedResult, let callEvent {
                            Text(LensL10n.text("Le patch demandé et le résultat de l'appel sont deux sources distinctes.")).font(LensUI.metadata).foregroundStyle(.secondary)
                            Button(LensL10n.text("Ouvrir la demande liée")) { store.navigate(.event(callEvent.id), newTab: true) }
                        }
                        if let resultEvent {
                            Text(resultEvent.isError ? LensL10n.text("Erreur enregistrée par l'appel") : LensL10n.text("Résultat enregistré · voir la sortie pour son statut")).font(LensUI.metadata).foregroundStyle(resultEvent.isError ? LensAppearance.warningText : .secondary)
                            Button(LensL10n.text("Lire le résultat intégral")) { store.navigate(.event(resultEvent.id), newTab: true) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.frame(minHeight: 40, idealHeight: 120, maxHeight: .infinity)
            } label: {
                HStack {
                    Label(LensL10n.text("Appel, résultat et contexte"), systemImage: LensSymbols.name("link")).font(LensUI.metadata)
                    Spacer()
                    if resultEvent?.isError == true { Label(LensL10n.text("Erreur enregistrée"), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText) }
                    else if issue != nil, !documents.isEmpty { Label(LensL10n.text("Limite de lecture"), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText) }
                }
            }.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 6)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                let key = (store.snapshot?.root.id ?? "unknown") + "/" + change.id
                versionReadingKey = key
                if let mode = windowContext?.recordedVersionPresentations[key] { versionPresentation = mode }
            }
            .onChange(of: versionPresentation) { _, mode in
                if let key = versionReadingKey { windowContext?.recordedVersionPresentations[key] = mode }
            }
            .task(id: change.id) { loadGeneration &+= 1; await load(generation: loadGeneration) }
            .onChange(of: documents.count) { _, count in documentIndex = count == 0 ? 0 : min(documentIndex, count - 1) }
            .onChange(of: sourceEvent?.relatedEventID) { _, _ in updateContext() }
            .onDisappear {
                if let key = versionReadingKey { windowContext?.recordedVersionPresentations[key] = versionPresentation }
                reloadTask?.cancel(); loadGeneration &+= 1; loading = false
            }
    }
    private var changeHeader: some View {
        LensAdaptiveRow {
            changeSelectors
        } trailing: {
            HStack(spacing: 8) {
                openActionButton.fixedSize()
                changeMoreMenu.fixedSize()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var changeSelectors: some View {
        HStack(spacing: 8) {
            if documents.count > 1 {
                Picker(LensL10n.text("Trace du diff"), selection: $documentIndex) {
                    ForEach(documents.indices, id: \.self) { index in Text(LensL10n.text("Trace {0} / {1}", String(describing: index + 1), String(describing: documents.count))).tag(index) }
                }.labelsHidden().frame(width: 160)
            }
            Picker(LensL10n.text("Contenu de la modification"), selection: $versionPresentation) {
                Text(LensL10n.text("Patch")).tag(FileVersionPresentation.patch)
                Text(LensL10n.text("Avant")).tag(FileVersionPresentation.before)
                Text(LensL10n.text("Après")).tag(FileVersionPresentation.after)
                Text(LensL10n.text("Comparer")).tag(FileVersionPresentation.comparison)
                Text(LensL10n.text("Référence Git")).tag(FileVersionPresentation.gitReference)
            }.labelsHidden().frame(width: 170).disabled(!documents.indices.contains(documentIndex))
        }
    }
    private var openActionButton: some View {
        Button(LensL10n.text("Ouvrir l’action")) { store.navigate(.event(change.eventID), newTab: true) }
            .buttonStyle(LensQuietButtonStyle())
            .font(LensUI.metadata.weight(.semibold))
            .help(LensL10n.text("Ouvrir l’action et son contexte"))
            .accessibilityIdentifier("lens-change-open-action")
    }
    private var changeMoreMenu: some View {
        Menu {
            Button(LensL10n.text("Ouvrir le fichier actuel")) { store.navigate(.file(environment: change.environmentID, path: change.path), newTab: true) }
            LensActionButton(store: store, action: .investigate, target: .change(change.id))
            LensActionButton(store: store, action: .provenance, target: .change(change.id))
            Divider()
            Group {
                Button(LensQuestionIntent.explainChange.title) { store.prepareQuestion(for: .change(change.id), intent: .explainChange) }
                Button(LensQuestionIntent.traceOrigin.title) { store.prepareQuestion(for: .change(change.id), intent: .traceOrigin) }
            }.disabled(!store.canPerform(.investigate, target: .change(change.id)))
        } label: { LensIconMenuLabel() }
            .lensIconMenu("Actions de la modification", help: "Fichier, contexte et question sur cette modification")
            .accessibilityIdentifier("lens-change-more")
    }
    private func startLoad() {
        guard !loading else { return }; reloadTask?.cancel(); loadGeneration &+= 1
        let generation = loadGeneration
        reloadTask = Task { await load(generation: generation) }
    }
    private func updateContext() {
        guard let event = sourceEvent else { return }
        let related = event.relatedEventID.flatMap { id in store.event(id) ?? store.snapshot?.events.first(where: { $0.id == id }) }
        guard let selected = try? RecordedChangeEvidence.select(change: change, event: event, related: related) else { return }
        callEvent = selected.call; resultEvent = selected.result
    }
    private func load(generation: UInt64) async {
        let span = LensSignposts.begin("RecordedDiffLoad"); defer { span.end(); if generation == loadGeneration { loading = false } }
        issue = nil; loading = true
        guard let snap = store.snapshot, let event = sourceEvent else { issue = LensL10n.text("Événement d'origine inaccessible."); return }
        let rootID = snap.root.id
        let related = event.relatedEventID.flatMap { id in store.event(id) ?? snap.events.first { $0.id == id } }
        guard let selected = try? RecordedChangeEvidence.select(change: change, event: event, related: related) else { issue = LensL10n.text("La source de la modification ne correspond pas à l'événement enregistré."); return }
        callEvent = selected.call; resultEvent = selected.result
        let sources = [event.source] + event.supplementarySources
        let sourceBytes = sources.reduce(0) { $0 + max(0, $1.length) }
        guard sourceBytes <= RecordedDiff.maximumInputBytes else { issue = LensL10n.text("La trace dépasse 8 Mio : interprétation du diff bornée. Consultez l'événement avec la lecture progressive ; aucun extrait tronqué n'est présenté comme un diff complet."); return }
        do {
            let detail = try await store.engine.sourceDetail(for: event)
            guard !Task.isCancelled, generation == loadGeneration, store.snapshot?.root.id == rootID else { return }
            let parsed = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try RecordedChangeEvidence.documents(change: change, selection: selected, detail: detail).map { try RecordedDiffPresentation(document: $0) }
            }.value
            guard !Task.isCancelled, generation == loadGeneration, store.snapshot?.root.id == rootID else { return }
            documents = parsed; loadedSources = sources
            if parsed.isEmpty { issue = change.kind == .recordedResult ? LensL10n.text("Ce résultat ne contient aucun diff enregistré pour ce fichier. Consultez l’événement brut et, si disponible, l’appel associé. Ce résultat seul ne prouve pas un changement du contenu.") : LensL10n.text("Aucun patch ou diff interprétable pour ce fichier dans cette trace. La sortie et l'événement brut restent consultables.") }
        } catch { if !Task.isCancelled, generation == loadGeneration, store.snapshot?.root.id == rootID { issue = error.localizedDescription } }
    }
}

/// A load-time identity covers both references, environment, exact lines/positions and
/// source provenance. Parser-generated line IDs alone do not identify a version.
/// Production callers construct this in their detached parse task, never in body.
struct RecordedDiffPresentation: Sendable {
    let document: RecordedDiffDocument
    let identity: String
    init(document: RecordedDiffDocument) throws {
        let span = LensSignposts.begin("RecordedDiffIdentity"); defer { span.end() }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let recordedBytes = try encoder.encode(document)
        try Task.checkCancellation()
        identity = SHA256.hash(data: recordedBytes).map { String(format: "%02x", $0) }.joined()
        self.document = document
    }
}

struct RecordedDiffView: View {
    @Environment(\.lensAccent) private var accent
    @Environment(\.lensWindowContext) private var windowContext
    @Environment(\.lensReadingMagnify) private var onMagnify
    @State private var previousMagnification: CGFloat = 1
    @EnvironmentObject var store: LensStore
    let document: RecordedDiffDocument
    @State private var sideBySide = false
    @State private var selectedLine: RecordedDiffLine?
    @State private var selectedHunk: RecordedDiffHunk?
    @State private var selectedSide: EvidenceLocation.Side = .unified
    @State private var hunkIndex = 0
    @State private var provenanceExpanded = false
    @State private var lineContextExpanded = false
    @State private var copier = RecordedCopyController()
    @State private var fileOpening = NativeCurrentFileActions()
    init(document: RecordedDiffDocument, initialProvenanceExpanded: Bool = false,
         initialSelectedHunk: RecordedDiffHunk? = nil, initialSelectedLine: RecordedDiffLine? = nil,
         initialLineContextExpanded: Bool = false) {
        self.document = document
        _provenanceExpanded = State(initialValue: initialProvenanceExpanded)
        _selectedHunk = State(initialValue: initialSelectedHunk)
        _selectedLine = State(initialValue: initialSelectedLine)
        _lineContextExpanded = State(initialValue: initialLineContextExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    diffTitle
                    Spacer(minLength: 8)
                    secondaryActions
                }.fixedSize(horizontal: false, vertical: true)
                metadataRow(LensL10n.text("Worktree"), environment?.path ?? document.provenance.environmentID)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        versionMetadataRow(LensL10n.text("Avant"), displayedProvenance.beforeReference)
                        versionMetadataRow(LensL10n.text("Après"), displayedProvenance.afterReference)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        versionMetadataRow(LensL10n.text("Avant"), displayedProvenance.beforeReference)
                        versionMetadataRow(LensL10n.text("Après"), displayedProvenance.afterReference)
                    }
                }
                Label(document.coverage == .fragmentOnly ? LensL10n.text("Fragments du diff · versions complètes à vérifier") : LensL10n.text("Deux textes complets explicitement fournis"), systemImage: LensSymbols.name(document.coverage == .fragmentOnly ? "text.alignleft" : "doc.on.doc"))
                    .font(LensUI.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).help(coverageExplanation)
            }.padding(.horizontal, 10).padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
            if copier.busy {
                HStack {
                    LensProgressIndicator().controlSize(.mini)
                    Text(LensL10n.text("Copie complète · {0} octets préparés", String(describing: copier.byteCount))).font(LensUI.metadata).monospacedDigit()
                    Spacer(minLength: 0)
                    Button(LensL10n.text("Annuler")) { copier.cancel() }.controlSize(.small)
                }.padding(.horizontal, 10).padding(.vertical, 4)
            }
            if let issue = copier.issue { Label(LensL10n.display(issue), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(.horizontal, 10).padding(.vertical, 4) }
            Divider()
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack {
                        Text(LensUI.count(allHunks.count, singular: "fragment", plural: "fragments")).font(LensUI.metadata)
                        Spacer()
                        if selectedLine != nil {
                            Button(LensL10n.text("Voir la provenance de la ligne")) { lineContextExpanded = true; proxy.scrollTo("recorded-diff-line-context", anchor: .top) }.help(LensL10n.text("Atteindre le contexte de la ligne sélectionnée"))
                        }
                        Button { jump(-1, proxy: proxy) } label: { Image(systemName: LensSymbols.name("chevron.up")) }.disabled(allHunks.isEmpty).accessibilityLabel(LensL10n.text("Fragment précédent")).help(LensL10n.text("Aller au fragment précédent"))
                        Button { jump(1, proxy: proxy) } label: { Image(systemName: LensSymbols.name("chevron.down")) }.disabled(allHunks.isEmpty).accessibilityLabel(LensL10n.text("Fragment suivant")).help(LensL10n.text("Aller au fragment suivant"))
                    }.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 3).fixedSize(horizontal: false, vertical: true)
                    GeometryReader { viewport in
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                documentProvenance.frame(width: viewport.size.width, alignment: .leading)
                                ForEach(document.files) { file in
                                    Text(LensL10n.text("{0} → {1} · {2}", String(describing: file.oldPath ?? LensL10n.text("∅")), String(describing: file.newPath ?? LensL10n.text("∅")), String(describing: operationLabel(file.operation))))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true).padding(8)
                                        .frame(width: viewport.size.width, alignment: .leading)
                                    ForEach(file.hunks) { hunk in
                                        Text(hunk.header.nonempty ?? LensL10n.text("Fragment sans position absolue")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08)).id(hunk.id)
                                        lineColumnHeader
                                        if !hunk.isComplete { Label(LensL10n.text("Fragment incomplet : correspondances non garanties."), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).padding(6) }
                                        ForEach(hunk.lines) { line in
                                            lineRow(line, hunk: hunk).onTapGesture { selectedLine = line; selectedHunk = hunk; selectedSide = line.kind == .removed ? .before : line.kind == .added ? .after : .unified }
                                                .contextMenu {
                                                    openWithAction(file)
                                                    revealFileAction(file)
                                                    Divider()
                                                    Button(LensL10n.text("Copier le texte de cette ligne")) { copyLine(line) }
                                                    Button(LensL10n.text("Copier le chemin dans cet environnement")) { store.copyLocalText(file.path, notice: LensL10n.text("Chemin du diff copié · {0}.", String(describing: document.provenance.environmentID))) }
                                                    Button { askDiff(file: file, hunk: hunk, line: line) } label: { Label(LensL10n.text("Demander à l’IA sur ce fragment…"), systemImage: LensSymbols.name("text.bubble")) }.disabled(store.investigation.preparing || store.investigation.sending).help(LensL10n.text("Préparer le fragment visé et sa provenance ; aucun envoi."))
                                                    if let eventID = document.provenance.eventIDs.first { LensQuestionMenu(store: store, target: .event(eventID)) }
                                                    Button(LensL10n.text("Voir la provenance de cette ligne")) { selectedLine = line; selectedHunk = hunk; selectedSide = line.kind == .removed ? .before : line.kind == .added ? .after : .unified; lineContextExpanded = true; proxy.scrollTo("recorded-diff-line-context", anchor: .bottom) }
                                                    Button(LensL10n.text("Origine et justification")) { selectedLine = line; selectedHunk = hunk; selectedSide = line.kind == .removed ? .before : line.kind == .added ? .after : .unified; revealOrigin(file: file, hunk: hunk, line: line) }.disabled(codeReference(file: file, hunk: hunk, line: line) == nil)
                                                    ForEach(document.provenance.eventIDs, id: \.self) { id in Button(LensL10n.text("Ouvrir l'action {0}", String(describing: String(id.prefix(12))))) { store.navigate(.event(id), newTab: true) } }
                                                }
                                        }
                                    }
                                }
                                if let line = selectedLine, let hunk = selectedHunk {
                                    Divider().frame(width: viewport.size.width)
                                    lineProvenance(line: line, hunk: hunk)
                                        .frame(width: viewport.size.width, alignment: .leading)
                                        .id("recorded-diff-line-context")
                                }
                            }
                            .padding(.bottom, 8)
                            .frame(minWidth: max(520, viewport.size.width), minHeight: max(0, viewport.size.height), alignment: .topLeading)
                        }
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                        .onChange(of: selectedLine?.id) { _, _ in if lineContextExpanded { proxy.scrollTo("recorded-diff-line-context", anchor: .bottom) } }
                    }.frame(maxHeight: .infinity)
                }
            }.frame(maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .simultaneousGesture(MagnificationGesture().onChanged { value in
            guard previousMagnification > 0 else { return }
            onMagnify?(value / previousMagnification - 1); previousMagnification = value
        }.onEnded { _ in previousMagnification = 1 })
            .onChange(of: store.selection) { _, _ in copier.cancel(); fileOpening.cancel() }
            .onChange(of: store.snapshot?.root.id) { _, _ in copier.cancel(); fileOpening.cancel() }
            .onDisappear { copier.cancel(showIssue: false); fileOpening.cancel() }
    }
    private var documentProvenance: some View {
        DisclosureGroup(isExpanded: $provenanceExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(LensL10n.text("Environnement"), document.provenance.environmentID)
                metadataRow(LensL10n.text("Dépôt actuel"), repositoryPath ?? LensL10n.text("non disponible"))
                if let agent = document.provenance.agentID { metadataRow(LensL10n.text("Agent observateur"), agent) }
                Text(document.provenance.authorEvidence ?? LensL10n.text("Cette trace ne permet pas d’identifier l’auteur de ces changements.")).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                Text(coverageExplanation).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(Array(document.issues.enumerated()), id: \.offset) { _, issue in Label(issue.message, systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } label: {
            HStack { Text(LensL10n.text("Provenance et limites")).font(LensUI.metadata); if !document.issues.isEmpty { Label(LensUI.count(document.issues.count, singular: "limite", plural: "limites"), systemImage: LensSymbols.name("exclamationmark.triangle")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText) } }
        }.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 5)
    }
    private func lineProvenance(line: RecordedDiffLine, hunk: RecordedDiffHunk) -> some View {
        DisclosureGroup(LensL10n.text("Provenance de la ligne sélectionnée · {0}", String(describing: lineKindLabel(line.kind))), isExpanded: $lineContextExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(document.provenance.authorEvidence ?? LensL10n.text("Auteur de la ligne non établi par cette observation.")).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                if let file = document.files.first(where: { $0.hunks.contains { $0.id == hunk.id } }) {
                    Button(LensL10n.text("Origine et justification")) { revealOrigin(file: file, hunk: hunk, line: line) }.buttonStyle(.borderless).disabled(codeReference(file: file, hunk: hunk, line: line) == nil)
                }
                if let offset = line.beforeLine, let file = document.files.first(where: { $0.hunks.contains { $0.id == hunk.id } }) {
                    let mapping = RecordedDiff.map(range: DiffLineRange(start: offset), file: file)
                    Text(LensL10n.text("Correspondance : {0} · {1}", String(describing: mappingLabel(mapping.status)), String(describing: mapping.reason))).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let file = document.files.first(where: { $0.hunks.contains { $0.id == hunk.id } }) { Button { askDiff(file: file, hunk: hunk, line: line) } label: { Label(LensL10n.text("Demander à l’IA sur ce fragment…"), systemImage: LensSymbols.name("text.bubble")) }.disabled(store.investigation.preparing || store.investigation.sending).help(LensL10n.text("Préparer ce fragment et sa provenance ; aucun envoi.")) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
        }.font(LensUI.metadata).controlSize(.small).padding(.horizontal, 10).padding(.vertical, 5)
    }
    private var diffTitle: some View {
        Label(compactKindLabel, systemImage: LensSymbols.name("arrow.left.arrow.right"))
            .font(LensUI.header).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
    }
    private var presentationPicker: some View {
        Picker(LensL10n.text("Présentation du diff"), selection: $sideBySide) {
            Text(LensL10n.text("Unifié")).tag(false); Text(LensL10n.text("Côte à côte")).tag(true)
        }.pickerStyle(.inline)
    }
    private var secondaryActions: some View {
        Menu {
            presentationPicker
            Divider()
            if document.files.count == 1, let file = document.files.first {
                openWithAction(file)
                revealFileAction(file)
            } else if !document.files.isEmpty {
                Menu(LensL10n.text("Ouvrir le fichier actuel avec…")) {
                    ForEach(document.files) { file in openWithAction(file, title: file.path) }
                }
                Menu(LensL10n.text("Afficher le fichier actuel dans le Finder")) {
                    ForEach(document.files) { file in revealFileAction(file, title: file.path) }
                }
            }
            Divider()
            Menu(LensL10n.text("Copier")) { copyActions }
            Menu(LensL10n.text("Action, agent et instructions")) { provenanceActions }
        } label: { LensIconMenuLabel() }
            .lensIconMenu("Actions du diff", help: "Fichier, copie et contexte du diff")
            .accessibilityIdentifier("lens-diff-more")
    }
    private func openWithAction(_ file: RecordedFileDiff, title: String? = nil) -> some View {
        let environment = store.snapshot?.environments.first { $0.id == file.provenance.environmentID }
        let path = NativeDiffFileTarget.path(file: file, environment: environment)
        return Button {
            guard let path else { return }
            fileOpening.choose(path: path, environmentID: file.provenance.environmentID, store: store, window: windowContext?.window)
        } label: {
            Label(title ?? LensL10n.text("Ouvrir le fichier actuel avec…"), systemImage: LensSymbols.name("arrow.up.right"))
        }
        .disabled(path == nil || fileOpening.busy)
        .help(LensL10n.text("Choisir une application pour ouvrir le fichier actuel de cet environnement. Le diff affiché reste inchangé."))
        .accessibilityIdentifier("lens-diff-open-with")
    }
    private func revealFileAction(_ file: RecordedFileDiff, title: String? = nil) -> some View {
        let environment = store.snapshot?.environments.first { $0.id == file.provenance.environmentID }
        let path = NativeDiffFileTarget.path(file: file, environment: environment)
        return Button {
            guard let path else { return }
            fileOpening.reveal(path: path, store: store)
        } label: {
            Label(title ?? LensL10n.text("Afficher le fichier actuel dans le Finder"), systemImage: LensSymbols.name("folder"))
        }
        .disabled(path == nil || fileOpening.busy)
        .help(LensL10n.text("Sélectionner le fichier actuel dans le Finder, dans cet environnement. Le diff affiché reste inchangé."))
        .accessibilityIdentifier("lens-diff-reveal-in-finder")
    }
    @ViewBuilder private var copyActions: some View {
        if let line = selectedLine { Button(LensL10n.text("Copier le texte de la ligne sélectionnée")) { copyLine(line) } }
        if let before = document.provenance.beforeReference { Button(LensL10n.text("Copier la référence avant")) { store.copyLocalText(before, notice: LensL10n.text("Référence avant copiée.")) } }
        if let after = document.provenance.afterReference { Button(LensL10n.text("Copier la référence après")) { store.copyLocalText(after, notice: LensL10n.text("Référence après copiée.")) } }
        if !document.provenance.sources.isEmpty {
            Divider()
            ForEach(Array(document.provenance.sources.enumerated()), id: \.offset) { index, source in
                Menu(LensL10n.text("Trace enregistrée {0} · ligne {1}", String(describing: index + 1), String(describing: source.line))) {
                    Text(source.path)
                    Button(LensL10n.text("Copier l’entrée complète · patch si enregistré")) { copySource(source, part: "input") }
                    Button(LensL10n.text("Copier la sortie enregistrée complète")) { copySource(source, part: "output") }
                    Button(LensL10n.text("Copier l’événement brut complet")) { copySource(source, part: "raw") }
                }.disabled(copier.busy || sourceOwner(source) == nil)
            }
            Text(LensL10n.text("Secrets reconnaissables masqués · limite de copie 32 Mio"))
        } else {
            Text(LensL10n.text("Aucune source enregistrée pour ce diff courant"))
        }
    }
    @ViewBuilder private var provenanceActions: some View {
        if let eventID = document.provenance.eventIDs.first { LensQuestionMenu(store: store, target: .event(eventID)) }
        ForEach(document.provenance.eventIDs, id: \.self) { id in
            Button(LensL10n.text("Ouvrir l’action {0}", String(describing: String(id.prefix(12))))) { store.navigate(.event(id), newTab: true) }
        }
        if let agent = document.provenance.agentID {
            Button(LensL10n.text("Ouvrir l’agent et sa mission")) { store.navigate(.agent(agent), newTab: true) }
            if let instruction = store.presentation?.agentsByID[agent]?.missionEventID {
                Button("Ouvrir l’instruction enregistrée") { store.navigate(.event(instruction), newTab: true) }
            }
        }
        Button(LensL10n.text("Ouvrir l’environnement / worktree")) { store.navigate(.environment(document.provenance.environmentID), newTab: true) }
    }
    private func copyLine(_ line: RecordedDiffLine) {
        store.copyLocalText(line.text, notice: LensL10n.text("Texte de la ligne copié · environnement {0}.", String(describing: document.provenance.environmentID)))
    }
    private func sourceOwner(_ source: SourceRef) -> LensEvent? {
        document.provenance.eventIDs.compactMap { store.event($0) }.first { ([$0.source] + $0.supplementarySources).contains(source) }
    }
    private func copySource(_ source: SourceRef, part: String) {
        guard let event = sourceOwner(source) else { return }
        copier.copy(event: event, related: event.relatedEventID.flatMap { store.event($0) }, part: part, source: source, store: store)
    }
    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title + LensL10n.text(" :")).foregroundStyle(.secondary).fixedSize()
            Text(value).monospaced().textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).help(value)
        }.font(LensUI.metadata).fixedSize(horizontal: false, vertical: true)
    }
    private func versionMetadataRow(_ title: String, _ reference: String?) -> some View {
        metadataRow(title, reference ?? LensL10n.text("non enregistrée"))
    }
    private var compactKindLabel: String {
        switch document.kind {
        case .requestedPatch: return LensL10n.text("Patch demandé")
        case .recordedDiff: return LensL10n.text("Diff enregistré")
        case .observedTextComparison: return LensL10n.text("Comparaison de textes observés")
        case .currentGit: return LensL10n.text("Diff Git actuel")
        }
    }
    private var environment: EnvironmentRecord? { store.snapshot?.environments.first { $0.id == document.provenance.environmentID } }
    private var repositoryPath: String? { environment?.repositoryPath }
    private var displayedProvenance: DiffProvenance {
        var provenance = document.provenance
        if document.files.count == 1 {
            provenance.beforeReference = provenance.beforeReference ?? document.files[0].beforeBlobID
            provenance.afterReference = provenance.afterReference ?? document.files[0].afterBlobID
        }
        return provenance
    }
    private var coverageExplanation: String { document.coverage == .fragmentOnly ? LensL10n.text("Le diff contient des fragments. Vérifiez les versions complètes dans Avant / Après lorsque les empreintes sont enregistrées. Le symbole · indique une position dans le fragment, pas un numéro de ligne du fichier complet.") : LensL10n.text("Comparaison de deux textes complets explicitement fournis.") }
    // Presentation labels only. Codable raw values and evidence exports remain unchanged.
    private func operationLabel(_ value: DiffFileOperation) -> String {
        switch value { case .added: return LensL10n.text("Ajout"); case .deleted: return LensL10n.text("Suppression"); case .modified: return LensL10n.text("Modification"); case .renamed: return LensL10n.text("Renommage"); case .binary: return LensL10n.text("Fichier binaire"); case .unknown: return LensL10n.text("Opération inconnue") }
    }
    private func lineKindLabel(_ value: DiffLineKind) -> String {
        switch value { case .context: return LensL10n.text("Contexte"); case .removed: return LensL10n.text("Suppression"); case .added: return LensL10n.text("Ajout"); case .metadata: return LensL10n.text("Métadonnées") }
    }
    private func mappingLabel(_ value: DiffMappingStatus) -> String {
        switch value { case .mapped: return LensL10n.text("Établie"); case .deleted: return LensL10n.text("Ligne supprimée"); case .partial: return LensL10n.text("Partielle"); case .ambiguous: return LensL10n.text("Ambiguë"); case .unavailable: return LensL10n.text("Indisponible") }
    }
    private var allHunks: [RecordedDiffHunk] { document.files.flatMap(\.hunks) }
    private func askDiff(file: RecordedFileDiff, hunk: RecordedDiffHunk, line: RecordedDiffLine) {
        guard let snap = store.snapshot else { return }
        do {
            let fragment = hunk.lines.map { "\($0.kind == .added ? "+" : $0.kind == .removed ? "-" : " ")\($0.text)" }.joined(separator: "\n")
            let text = "Nature : \(kindLabel)\nFichier : \(file.path)\nEnvironnement enregistré : \(document.provenance.environmentID)\nCouverture : \(document.coverage.rawValue)\nRéférence avant : \((document.provenance.beforeReference ?? file.beforeBlobID) ?? "inconnue")\nRéférence après : \((document.provenance.afterReference ?? file.afterBlobID) ?? "inconnue")\nAuteur : \(document.provenance.authorEvidence ?? "non établi")\nLigne sélectionnée : avant \(number(line.beforeLine, line.beforeOffset)), après \(number(line.afterLine, line.afterOffset)) (· = position locale dans le fragment)\n\n\(hunk.header)\n\(fragment)"
            let piece = EvidencePiece(id: "E001", kind: "recordedDiffFragment", title: file.path, text: text, eventID: document.provenance.eventIDs.first, agentID: document.provenance.agentID, environmentID: document.provenance.environmentID, sourceRefs: document.provenance.sources, knownVersion: document.provenance.beforeReference ?? file.beforeBlobID,
                location: EvidenceLocation(environmentID: document.provenance.environmentID, path: file.path, versionKind: .recordedFragment,
                    version: line.kind == .removed ? (document.provenance.beforeReference ?? file.beforeBlobID) : line.kind == .added ? (document.provenance.afterReference ?? file.afterBlobID) : nil,
                    side: line.kind == .removed ? .before : line.kind == .added ? .after : .unified,
                    coordinates: (line.beforeLine != nil || line.afterLine != nil) ? .absolute : .fragment,
                    firstLine: line.kind == .removed ? (line.beforeLine ?? line.beforeOffset) : (line.afterLine ?? line.afterOffset), hunkID: hunk.id))
            var pieces = [piece]
            if let reference = codeReference(file: file, hunk: hunk, line: line) {
                pieces.append(try reference.evidence(capturedAt: snap.collectedAt))
                if let origin = store.presentation?.originInspection.selection(objectID: OriginInspectionIndex.eventID(reference.eventID)) { pieces.append(try OriginEvidence.piece(selection: origin, collectionCut: snap.collectedAt)) }
            }
            try store.investigation.append(pieces, rootID: snap.root.id, cut: snap.collectedAt)
            store.navigate(.investigation(store.investigation.capsule!.id), newTab: true)
        } catch { store.investigation.issue = error.localizedDescription }
    }
    private func codeReference(file: RecordedFileDiff, hunk: RecordedDiffHunk, line: RecordedDiffLine) -> OriginCodeReference? {
        let selectedEvent: String?
        switch store.selection {
        case .change(let id): selectedEvent = store.change(id)?.eventID
        case .event(let id): selectedEvent = id
        default: selectedEvent = nil
        }
        let source = selectedEvent.flatMap { document.provenance.eventIDs.contains($0) ? $0 : nil }
        return OriginCodeReference(document: document, file: file, hunk: hunk, line: line, eventID: source,
                                   side: line.kind == .context && selectedLine?.id == line.id ? selectedSide : nil)
    }
    private func revealOrigin(file: RecordedFileDiff, hunk: RecordedDiffHunk, line: RecordedDiffLine) {
        guard let reference = codeReference(file: file, hunk: hunk, line: line) else { return }
        store.showOriginCode(reference)
    }
    private var kindLabel: String { switch document.kind { case .requestedPatch: return LensL10n.text("Patch demandé · application non déduite"); case .recordedDiff: return LensL10n.text("Diff présent dans une trace"); case .observedTextComparison: return LensL10n.text("Comparaison de textes observés"); case .currentGit: return LensL10n.text("Diff Git actuel · auteur inconnu") } }
    private func jump(_ delta: Int, proxy: ScrollViewProxy) { guard !allHunks.isEmpty else { return }; hunkIndex = (hunkIndex + delta + allHunks.count) % allHunks.count; proxy.scrollTo(allHunks[hunkIndex].id, anchor: .top) }
    private func number(_ absolute: Int?, _ local: Int?) -> String { absolute.map(String.init) ?? local.map { "·\($0)" } ?? "" }
    private var lineColumnHeader: some View {
        HStack(spacing: 0) {
            if sideBySide {
                HStack(spacing: 0) { columnTitle("Avant"); Spacer(minLength: 0) }
                    .padding(.horizontal, 5).frame(minWidth: 310, maxWidth: .infinity)
                Divider()
                HStack(spacing: 0) { columnTitle("Après"); Spacer(minLength: 0) }
                    .padding(.horizontal, 5).frame(minWidth: 310, maxWidth: .infinity)
            } else {
                columnTitle("Avant")
                columnTitle("Après")
                Spacer(minLength: 0)
            }
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .accessibilityIdentifier("lens-diff-line-columns")
    }
    private func columnTitle(_ side: String) -> some View {
        Text(LensL10n.text(side)).frame(width: 44, alignment: .trailing)
    }
    private func lineNumber(_ absolute: Int?, _ local: Int?, side: String) -> some View {
        let label = number(absolute, local)
        return Text(label).foregroundStyle(.primary).frame(width: 44, alignment: .trailing)
            .help(LensL10n.text(side))
            .accessibilityLabel(LensL10n.text(side) + " : " + label)
            .accessibilityHidden(label.isEmpty)
    }
    private func tint(_ kind: DiffLineKind) -> Color { kind == .added ? LensBrand.addition : kind == .removed ? LensBrand.removal : .clear }
    private func lineRow(_ line: RecordedDiffLine, hunk: RecordedDiffHunk) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if sideBySide {
                HStack(spacing: 6) { lineNumber(line.beforeLine, line.beforeOffset, side: "Avant"); Text(line.kind == .removed ? LensL10n.text("−") : " ").foregroundStyle(.primary).frame(width: 14); Text(line.kind == .added ? "" : line.text).textSelection(.enabled).frame(minWidth: 230, maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 5).background(line.kind == .removed ? tint(.removed) : .clear).contentShape(Rectangle()).onTapGesture { selectedLine = line; selectedHunk = hunk; selectedSide = .before }
                Divider()
                HStack(spacing: 6) { lineNumber(line.afterLine, line.afterOffset, side: "Après"); Text(line.kind == .added ? LensL10n.text("+") : " ").foregroundStyle(.primary).frame(width: 14); Text(line.kind == .removed ? "" : line.text).textSelection(.enabled).frame(minWidth: 230, maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 5).background(line.kind == .added ? tint(.added) : .clear).contentShape(Rectangle()).onTapGesture { selectedLine = line; selectedHunk = hunk; selectedSide = .after }
            } else {
                lineNumber(line.beforeLine, line.beforeOffset, side: "Avant")
                lineNumber(line.afterLine, line.afterOffset, side: "Après")
                Text(line.kind == .added ? LensL10n.text("+") : line.kind == .removed ? LensL10n.text("−") : " ").foregroundStyle(.primary).frame(width: 22)
                Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(store.codeFont.font(size: store.fontSize)).padding(.vertical, 2).background(sideBySide ? .clear : tint(line.kind)).contentShape(Rectangle())
            .overlay(alignment: .leading) { if selectedLine?.id == line.id { Rectangle().fill(accent.color).frame(width: 2) } }
    }
}
