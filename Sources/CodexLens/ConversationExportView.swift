import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LensCore

/// A review of one frozen collection cut. Streaming never changes its export target.
struct ConversationExportView: View {
    @EnvironmentObject private var store: LensStore
    @StateObject private var controller: ConversationExportController
    @State private var filter: ConversationReviewFilter = .all
    @State private var query = ""
    @State private var searchFocused = false
    @State private var questionTask: Task<Void, Never>?
    @State private var isAddingToQuestion = false
    let onClose: () -> Void

    init(snapshot: SessionSnapshot, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: ConversationExportController(snapshot: snapshot))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let review = controller.review {
                HSplitView {
                    messageList(review)
                        .frame(minWidth: 250, idealWidth: 310, maxWidth: 440)
                    messageDetail
                        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                preparation
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 1020, minHeight: 540, idealHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ConversationExportWindowReader(controller: controller).frame(width: 0, height: 0))
        .task { controller.prepare() }
        .onDisappear { questionTask?.cancel(); controller.close() }
        .onChange(of: controller.selectedID) { _, id in controller.loadMessage(id) }
        .onChange(of: filter) { _, _ in updateFilter() }
        .onChange(of: query) { _, _ in updateFilter() }
        .focusedSceneValue(\.lensSearchAction, { searchFocused = true })
        .accessibilityIdentifier("lens-conversation-export")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(LensL10n.text("Conversation de la session"), systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                Button(LensL10n.text("Fermer")) { close() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(controller.title).font(.subheadline).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Text(LensL10n.text("Session {0}", controller.rootThreadID))
                Text(LensL10n.text("Capture : {0}", controller.collectedAt.lensFormatted(date: .abbreviated, time: .standard)))
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(LensL10n.text("Messages utilisateur et modèle du thread principal. Les outils et les conversations des sous-agents ne sont pas inclus. La collecte continue."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func messageList(_ review: ConversationReview) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                LensNativeSearchField(placeholder: LensL10n.text("Rechercher dans les aperçus…"), text: $query,
                                      accessibilityLabel: LensL10n.text("Rechercher dans les aperçus de conversation"), focused: $searchFocused)
                    .frame(height: 25)
                Picker(LensL10n.text("Afficher les messages"), selection: $filter) {
                    ForEach(ConversationReviewFilter.allCases, id: \.self) { item in Text(item.title).tag(item) }
                }.pickerStyle(.menu)
                Text(LensL10n.text("Recherche limitée aux aperçus de 400 caractères. L’export contient tous les textes disponibles."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            if controller.isFiltering { ProgressView().controlSize(.small).padding(6) }
            if controller.visibleMessages.isEmpty && !controller.isFiltering {
                Text(LensL10n.text(review.messages.isEmpty ? "Aucun message principal indexé. Consultez la couverture et les traces anciennes signalées." : "Aucun résultat dans les aperçus avec ces filtres."))
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            List(controller.visibleMessages, selection: $controller.selectedID) { message in
                ConversationMessageRow(message: message)
                    .tag(message.id)
                    .contextMenu {
                        Button(LensL10n.text("Retrouver le message")) { reveal(message.id) }
                            .disabled(!matchesObservedRoot)
                    }
            }.listStyle(.inset)
                .accessibilityLabel(LensL10n.text("Messages de la conversation"))
                .overlay {
                    if controller.visibleMessages.isEmpty && !controller.isFiltering {
                        Text(LensL10n.text(review.messages.isEmpty ? "Aucun message utilisateur ou modèle retrouvé dans cette collecte." : "Aucun message ne correspond aux filtres."))
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(18)
                    }
                }
            HStack {
                Text(LensL10n.text("{0} messages affichés sur {1}", String(controller.visibleMessages.count), String(review.messages.count)))
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    @ViewBuilder private var messageDetail: some View {
        if controller.isLoadingMessage {
            LensLoadingState(title: LensL10n.text("Chargement du message enregistré…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = controller.selectedMessage {
            VStack(spacing: 0) {
                detailHeader(message)
                Divider()
                if let text = message.text {
                    CodeDocumentView(text: text, path: "Conversation.txt",
                                     versionLabel: LensL10n.text("Message · {0}", message.id),
                                     fontSize: store.fontSize, codeFont: store.codeFont)
                        .id(message.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(message.status.title, systemImage: "doc.badge.ellipsis")
                            .font(.headline)
                        Text(LensL10n.text("Le texte complet n’est pas disponible dans cette collecte. L’aperçu de la timeline ne le remplace pas."))
                        ForEach(Array(message.limitations.enumerated()), id: \.offset) { _, limit in Text(LensL10n.text(limit)) }
                    }.font(.subheadline).padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } else {
            VStack(spacing: 9) {
                Image(systemName: "text.bubble").font(.title2).foregroundStyle(.secondary)
                Text(LensL10n.text("Sélectionnez un message pour lire son texte et sa provenance."))
                if let issue = controller.messageIssue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
                if controller.selectedID != nil {
                    Button(LensL10n.text("Réessayer")) { controller.loadMessage(controller.selectedID, force: true) }
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(message.role.title, systemImage: message.role.symbol).font(.headline)
                if let timestamp = message.timestamp {
                    Text(timestamp.lensFormatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button(LensL10n.text("Retrouver le message")) { reveal(message.id) }
                    .disabled(!matchesObservedRoot)
                Button(LensL10n.text("Ajouter à la question")) {
                    guard matchesObservedRoot, message.text != nil, !isAddingToQuestion else { return }
                    isAddingToQuestion = true
                    questionTask = Task { @MainActor in
                        let added = await store.addConversationEvidence(message: message, rootID: controller.rootThreadID, cut: controller.collectedAt)
                        guard !Task.isCancelled else { return }
                        isAddingToQuestion = false
                        if added { close() }
                        else { controller.issue = store.investigation.issue ?? LensL10n.text("Le message n’a pas été ajouté. Vérifiez la session et la limite de taille du contexte.") }
                    }
                }.disabled(!matchesObservedRoot || message.text == nil || isAddingToQuestion)
                    .help(LensL10n.text("Ajoute ce message au chat, sans l’envoyer. Un extrait sera ajouté si le texte dépasse la limite du contexte."))
                if isAddingToQuestion { ProgressView().controlSize(.small) }
                Spacer()
            }.controlSize(.small)
            Text(LensL10n.text("Agent : {0} · Tour : {1}", message.agentID, message.turnID ?? LensL10n.text("Non enregistré")))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(message.environmentID.map { LensL10n.text("Environnement / worktree enregistré : {0}", $0) } ?? LensL10n.text("Environnement non enregistré"))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup(LensL10n.text("Provenance et ressources")) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        sourceLabel(message.source)
                        ForEach(Array(message.supplementarySources.enumerated()), id: \.offset) { _, source in sourceLabel(source) }
                        ForEach(message.resources) { resource in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(resource.name, systemImage: "paperclip")
                                Text(resource.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(resource.roles.map(\.label).joined(separator: " · ") + " · " + resource.availability.conversationTitle)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(LensL10n.text("Référence liée au message ; les octets de la pièce jointe ne sont pas inclus dans l’export."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(message.limitations.enumerated()), id: \.offset) { _, limit in Text(LensL10n.text(limit)).font(.caption) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 145)
            }.font(.caption)
            if !message.signals.isEmpty {
                DisclosureGroup(LensL10n.text("Indices d’orientation · {0}", String(message.signals.count))) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            Text(LensL10n.text("Repérage lexical local, avec faux positifs possibles. Un indice ne prouve ni l’importance ni l’application de la consigne."))
                                .foregroundStyle(.secondary)
                            ForEach(Array(message.signals.enumerated()), id: \.offset) { _, signal in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.kind.title + " · « " + signal.cue + " »").bold()
                                    Text(signal.excerpt).textSelection(.enabled)
                                }
                            }
                        }.font(.caption).padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }.font(.caption)
            }
            if !matchesObservedRoot {
                Label(LensL10n.text("La session ouverte a changé. L’export conserve son contenu ; les actions vers cette session sont désactivées."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10)
    }

    private func sourceLabel(_ source: SourceRef) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.path).textSelection(.enabled)
            Text(LensL10n.text("Ligne {0} · Décalage {1} · Longueur {2} octets", String(source.line), String(source.offset), String(source.length)))
                .foregroundStyle(.secondary)
            if let hash = source.sha256 { Text("SHA-256 " + hash).foregroundStyle(.secondary).textSelection(.enabled) }
        }.font(.caption)
    }

    private var preparation: some View {
        VStack(spacing: 12) {
            if controller.isPreparing {
                LensLoadingState(title: LensL10n.text("Préparation de la conversation…"),
                    cancelTitle: LensL10n.text("Annuler le chargement"), onCancel: { controller.cancelPreparation() })
            } else {
                Image(systemName: "text.bubble").font(.title2).foregroundStyle(.secondary)
                Text(controller.issue ?? LensL10n.text("La préparation est suspendue. Aucun fichier exporté."))
                    .textSelection(.enabled)
                Button(LensL10n.text("Réessayer")) { controller.prepare() }
            }
        }.padding(24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let review = controller.review {
                HStack {
                    Text(LensL10n.text("Utilisateur : {0} · Modèle : {1}", String(review.userCount), String(review.assistantCount)))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(review.totalTextBytes), countStyle: .file))
                }.font(.caption).foregroundStyle(.secondary)
                if !review.excludedReferences.isEmpty {
                    Label(LensL10n.text("{0} traces anciennes signalées séparément", String(review.excludedReferences.count)), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !review.coverage.isEmpty || !review.limits.isEmpty {
                    DisclosureGroup(LensL10n.text("Couverture et limites")) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(review.limits.enumerated()), id: \.offset) { _, limit in Text(LensL10n.text(limit)) }
                                Text(LensL10n.text(review.redactionPolicy))
                                ForEach(review.coverage) { coverage in
                                    Text(coverage.message + (coverage.source.isEmpty ? "" : " · " + coverage.source))
                                }
                                ForEach(review.excludedReferences) { reference in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(reference.title).bold()
                                        Text(LensL10n.text(reference.reason))
                                        sourceLabel(reference.source)
                                        Button(LensL10n.text("Retrouver l’origine")) { reveal(reference.id) }
                                            .disabled(!matchesObservedRoot)
                                    }.padding(.vertical, 4)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }.font(.caption)
                }
            }
            if let issue = controller.issue, controller.review != nil {
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled)
            }
            if let receipt = controller.receipt {
                Text(LensL10n.text("Export terminé : {0} · {1} messages", receipt.destination.path, String(receipt.messageCount)))
                    .font(.caption).textSelection(.enabled)
                Text("SHA-256 " + receipt.sha256).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LensAdaptiveRow {
                Text(LensL10n.text("Export local. Peut contenir des conversations et chemins sensibles."))
                    .font(.caption).foregroundStyle(.secondary)
            } trailing: {
                HStack(spacing: 9) {
                if controller.isExporting || controller.isChoosingDestination {
                    ProgressView().controlSize(.small)
                    Button(LensL10n.text("Annuler l’export")) { controller.cancelExport() }
                } else {
                    Button(LensL10n.text("Exporter JSON…")) { controller.chooseDestination(format: .json) }
                    Button(LensL10n.text("Exporter Markdown…")) { controller.chooseDestination(format: .markdown) }
                }
                }
            }.disabled(controller.review == nil)
        }.padding(12)
    }

    private var matchesObservedRoot: Bool { store.snapshot?.root.id == controller.rootThreadID }
    private func updateFilter() { controller.apply(filter: filter, query: query) }
    private func close() { questionTask?.cancel(); controller.close(); onClose() }
    private func reveal(_ id: String) {
        guard matchesObservedRoot else { return }
        close()
        store.navigate(.event(id), newTab: true)
    }
}

enum ConversationReviewFilter: CaseIterable, Hashable, Sendable {
    case all, user, orientation
    var title: String {
        switch self {
        case .all: return LensL10n.text("Tous les messages")
        case .user: return LensL10n.text("Utilisateur")
        case .orientation: return LensL10n.text("Indices d’orientation")
        }
    }
}

private struct ConversationMessageRow: View {
    let message: ConversationMessageSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(message.role.title, systemImage: message.role.symbol).font(.subheadline).bold()
                Spacer()
                if !message.signals.isEmpty {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .accessibilityLabel(LensL10n.text("Indice d’orientation"))
                        .help(LensL10n.text("Indice lexical d’orientation ; à vérifier dans le texte."))
                }
            }
            if message.status == .available {
                Text(message.preview).font(.caption).lineLimit(3)
            } else {
                Label(message.status.title, systemImage: "doc.badge.ellipsis").font(.caption)
            }
            if let timestamp = message.timestamp {
                Text(timestamp.lensFormatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

@MainActor final class ConversationExportController: ObservableObject {
    let rootThreadID: String
    let title: String
    let collectedAt: Date
    private let exporterTask: Task<(ConversationExporter, Bool), Error>
    private(set) var planPreparedOffMainThread: Bool?
    @Published var review: ConversationReview?
    @Published var visibleMessages: [ConversationMessageSummary] = []
    @Published var selectedID: String?
    @Published var selectedMessage: ConversationMessage?
    @Published var issue: String?
    @Published var messageIssue: String?
    @Published var receipt: ConversationExportReceipt?
    @Published var isPreparing = false
    @Published var isLoadingMessage = false
    @Published var isFiltering = false
    @Published var isChoosingDestination = false
    @Published var isExporting = false
    weak var window: NSWindow?
    private var panel: NSSavePanel?
    private var prepareTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generation = 0
    private var filterGeneration = 0
    private var loadingMessageID: String?
    private var closed = false
    private var activeFilter: ConversationReviewFilter = .all
    private var activeQuery = ""

    init(snapshot: SessionSnapshot) {
        rootThreadID = snapshot.root.id
        title = snapshot.root.title
        collectedAt = snapshot.collectedAt
        // The Sendable snapshot is captured once; even index construction stays off the UI executor.
        exporterTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let span = LensSignposts.begin("ConversationIndex"); defer { span.end() }
            let plan = ConversationExportPlan(snapshot: snapshot)
            try Task.checkCancellation()
            return (ConversationExporter(plan: plan), Self.isBackgroundThread())
        }
    }

    // Synchronous probe avoids Thread's noasync API in the detached async closure.
    nonisolated private static func isBackgroundThread() -> Bool { !Thread.isMainThread }

    func prepare() {
        guard !closed, !isPreparing, review == nil else { return }
        generation += 1
        let ticket = generation
        let previous = prepareTask
        isPreparing = true; issue = nil
        prepareTask = Task { [weak self, exporterTask] in
            do {
                await previous?.value
                try Task.checkCancellation()
                let (exporter, offMain) = try await exporterTask.value
                try Task.checkCancellation()
                let review = try await exporter.prepare()
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == ticket else { return }
                self.planPreparedOffMainThread = offMain
                self.review = review; self.isPreparing = false
                self.apply(filter: self.activeFilter, query: self.activeQuery)
                self.selectedID = review.messages.first?.id
                self.loadMessage(self.selectedID)
            } catch is CancellationError {
            } catch {
                guard let self, !self.closed, self.generation == ticket else { return }
                self.isPreparing = false; self.issue = error.localizedDescription
            }
        }
    }

    func cancelPreparation() {
        // Retain the cancelled task so Retry waits for its spool cleanup before a new prepare.
        generation += 1; prepareTask?.cancel(); isPreparing = false
    }

    func apply(filter: ConversationReviewFilter, query: String) {
        activeFilter = filter; activeQuery = query
        filterTask?.cancel(); filterGeneration += 1
        guard let messages = review?.messages, !closed else { return }
        let ticket = filterGeneration
        isFiltering = true
        filterTask = Task { [weak self] in
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(160)) }
                let worker = Task.detached(priority: .userInitiated) {
                    let span = LensSignposts.begin("ConversationSearch"); defer { span.end() }
                    var result: [ConversationMessageSummary] = []
                    result.reserveCapacity(messages.count)
                    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    for (index, message) in messages.enumerated() {
                        if index % 128 == 0 { try Task.checkCancellation() }
                        let included = filter == .all || (filter == .user && message.role == .user) || (filter == .orientation && !message.signals.isEmpty)
                        if included && (needle.isEmpty || message.preview.localizedStandardContains(needle)) { result.append(message) }
                    }
                    return result
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, !self.closed, self.filterGeneration == ticket else { return }
                self.visibleMessages = result; self.isFiltering = false
            } catch is CancellationError {
            } catch {
                guard let self, !self.closed, self.filterGeneration == ticket else { return }
                self.isFiltering = false; self.issue = error.localizedDescription
            }
        }
    }

    func loadMessage(_ id: String?, force: Bool = false) {
        guard !closed else { return }
        if !force, let id, selectedMessage?.id == id || loadingMessageID == id { return }
        messageTask?.cancel()
        selectedMessage = nil; messageIssue = nil; loadingMessageID = id; isLoadingMessage = id != nil
        guard let id else { return }
        messageTask = Task { [weak self, exporterTask] in
            do {
                let (exporter, _) = try await exporterTask.value
                let message = try await exporter.message(eventID: id)
                try Task.checkCancellation()
                guard let self, !self.closed, self.selectedID == id else { return }
                self.selectedMessage = message; self.loadingMessageID = nil; self.isLoadingMessage = false
            } catch is CancellationError {
            } catch {
                guard let self, !self.closed, self.selectedID == id else { return }
                self.messageIssue = error.localizedDescription; self.loadingMessageID = nil; self.isLoadingMessage = false
            }
        }
    }

    func chooseDestination(format: ConversationExportFormat) {
        guard !closed, review != nil, !isExporting, !isChoosingDestination else { return }
        guard let window else { issue = LensL10n.text("La fenêtre d’export n’est pas disponible. Réessayez depuis cette fenêtre."); return }
        let panel = NSSavePanel()
        self.panel = panel; isChoosingDestination = true; issue = nil; receipt = nil
        let suffix = format == .json ? "json" : "md"
        panel.allowedContentTypes = [format == .json ? .json : (UTType(filenameExtension: "md") ?? .plainText)]
        panel.nameFieldStringValue = "CodexLens-conversation-" + String(rootThreadID.prefix(8)) + "." + suffix
        panel.title = LensL10n.text("Exporter la conversation")
        panel.message = LensL10n.text("L’export reste local et peut contenir des données sensibles. Les pièces jointes sont référencées ; leurs octets ne sont pas copiés.")
        panel.canCreateDirectories = true
        exportTask = Task { [weak self, exporterTask] in
            let result = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard let self, !self.closed else { return }
            self.panel = nil; self.isChoosingDestination = false
            guard !Task.isCancelled, result == .OK, let destination = panel.url else { return }
            self.isExporting = true
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do {
                let (exporter, _) = try await exporterTask.value
                let receipt = try await exporter.export(to: destination, format: format, replaceExisting: true)
                // A completed receipt means the atomic export committed, even if Cancel was pressed just after commit.
                guard !self.closed else { return }
                self.receipt = receipt; self.isExporting = false
            } catch is CancellationError {
                if !self.closed { self.isExporting = false; self.issue = LensL10n.text("Export annulé. Aucun nouvel envoi ni réessai automatique.") }
            } catch {
                if !self.closed { self.isExporting = false; self.issue = error.localizedDescription }
            }
        }
    }

    func cancelExport() { panel?.cancel(nil); exportTask?.cancel() }
    func close() {
        guard !closed else { return }
        closed = true; generation += 1; filterGeneration += 1
        panel?.cancel(nil); panel = nil
        prepareTask?.cancel(); messageTask?.cancel(); filterTask?.cancel(); exportTask?.cancel()
        exporterTask.cancel()
        let exporterTask = exporterTask
        Task { if let (exporter, _) = try? await exporterTask.value { await exporter.dispose() } }
    }
    deinit {
        prepareTask?.cancel(); messageTask?.cancel(); filterTask?.cancel(); exportTask?.cancel()
        exporterTask.cancel()
        let exporterTask = exporterTask
        Task { if let (exporter, _) = try? await exporterTask.value { await exporter.dispose() } }
    }
}

/// The Save panel attaches to this sheet's own window, never to another Lens window.
private struct ConversationExportWindowReader: NSViewRepresentable {
    let controller: ConversationExportController
    func makeNSView(context: Context) -> Reader { Reader(controller: controller) }
    func updateNSView(_ view: Reader, context: Context) { view.controller = controller; controller.window = view.window }
    final class Reader: NSView {
        weak var controller: ConversationExportController?
        init(controller: ConversationExportController) { self.controller = controller; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller?.window = window }
    }
}

private extension ConversationRole {
    var title: String { LensL10n.text(self == .user ? "Utilisateur" : "Modèle") }
    var symbol: String { self == .user ? "person" : "bubble.left" }
}

private extension ConversationTextStatus {
    var title: String {
        switch self {
        case .available: return LensL10n.text("Texte enregistré")
        case .noRecordedText: return LensL10n.text("Aucun texte enregistré")
        case .unavailable: return LensL10n.text("Source indisponible")
        case .integrityFailed: return LensL10n.text("Source modifiée depuis la collecte")
        case .messageLimitExceeded: return LensL10n.text("Message au-delà du budget de lecture")
        case .storageLimitExceeded: return LensL10n.text("Budget de collecte atteint")
        }
    }
}

private extension ConversationSignalKind {
    var title: String {
        switch self {
        case .correction: return LensL10n.text("Correction possible")
        case .preference: return LensL10n.text("Préférence possible")
        case .constraint: return LensL10n.text("Contrainte possible")
        case .continuation: return LensL10n.text("Relance possible")
        }
    }
}

private extension Availability {
    var conversationTitle: String {
        switch self {
        case .accessible: return LensL10n.text("Accessible localement")
        case .missing: return LensL10n.text("Emplacement introuvable ou inaccessible")
        case .external: return LensL10n.text("Ressource externe ; aucune lecture automatique")
        case .unknown: return LensL10n.text("Disponibilité du contenu inconnue")
        }
    }
}
