import SwiftUI
import AppKit
import LensCore
import CryptoKit
import Combine

enum InvestigationConnectionMode: String, CaseIterable { case codex, chatgpt, api
    func setupInstruction(in language: LensL10n.Language) -> String {
        switch self {
        case .codex: return LensL10n.text("Utilisez votre connexion Codex et choisissez un modèle.", in: language)
        case .chatgpt: return LensL10n.text("Connectez ChatGPT dans Configurer l’envoi, puis choisissez un modèle.", in: language)
        case .api: return LensL10n.text("Renseignez la clé API dédiée et le modèle dans Configurer l’envoi.", in: language)
        }
    }
}

@MainActor private final class CodexLocalConnectionPresentation {
    static let shared = CodexLocalConnectionPresentation()
    @Published var status: CodexLocalConnectionStatus?
    @Published var completedModel: String?
    @Published var model = UserDefaults.standard.string(forKey: "LensCodexModel") ?? ""
    private var verification: (id: UUID, path: String?, task: Task<CodexLocalConnectionStatus, Error>)?
    func checkedStatus(preferred: URL?) async throws -> CodexLocalConnectionStatus {
        if let running = verification {
            if running.path == preferred?.path { return try await running.task.value }
            _ = try? await running.task.value
        }
        let id = UUID()
        let task = Task<CodexLocalConnectionStatus, Error> {
            let engine = CodexInvestigationEngine()
            do {
                try await engine.useExecutable(preferred)
                let result = try await engine.status()
                await engine.shutdown() // Metadata checks must not retain idle children.
                return result
            } catch { await engine.shutdown(); throw error }
        }
        verification = (id, preferred?.path, task)
        defer { if verification?.id == id { verification = nil } }
        return try await task.value
    }
}

@MainActor final class InvestigationStore: ObservableObject {
    let archive: InvestigationArchive
    init(archive: InvestigationArchive = InvestigationArchive(), statusProvider: (@Sendable (URL?) async throws -> CodexLocalConnectionStatus)? = nil) {
        self.archive = archive
        self.statusProvider = statusProvider
        codexConnectionObservation = CodexLocalConnectionPresentation.shared.$status.sink { [weak self] in self?.codexStatus = $0 }
        codexCompletionObservation = CodexLocalConnectionPresentation.shared.$completedModel.sink { [weak self] in self?.completedModel = $0 }
        codexModelObservation = CodexLocalConnectionPresentation.shared.$model.sink { [weak self] value in
            guard let self, self.connectionMode == .codex, !self.sending, self.model != value else { return }
            self.model = value
        }
    }
    private var codexConnectionObservation: AnyCancellable?
    private let statusProvider: (@Sendable (URL?) async throws -> CodexLocalConnectionStatus)?
    private var codexModelObservation: AnyCancellable?
    private var codexCompletionObservation: AnyCancellable?
    @Published var capsule: EvidenceCapsule? {
        didSet {
            evidenceContextGeneration = UUID()
            if evidenceRemoval?.resultID != capsule?.id || evidenceRemoval?.resultDigest != capsule?.digestSHA256 { evidenceRemoval = nil }
        }
    }
    private(set) var evidenceContextGeneration = UUID()
    @Published var question = ""
    @Published var response: String?
    @Published var recordID: String?
    @Published var records: [InvestigationSummary] = []
    @Published var preparing = false
    @Published var sending = false
    @Published var issue: String?
    @Published var notice: String?
    @Published var apiKey = "" // RAM only; never UserDefaults, archive, or log.
    @Published var model = UserDefaults.standard.string(forKey: "LensCodexModel") ?? "" { didSet { if connectionMode == .codex {
        UserDefaults.standard.set(model, forKey: "LensCodexModel")
        if CodexLocalConnectionPresentation.shared.model != model { CodexLocalConnectionPresentation.shared.model = model }
    } } }
    @Published var connectionMode: InvestigationConnectionMode = .codex
    @Published private(set) var chatGPTAccount: CodexInvestigationAccount?
    @Published private(set) var chatGPTModels: [CodexInvestigationModel] = []
    @Published private(set) var connecting = false
    private var connectionTask: Task<Void, Never>?
    private let codexEngine = CodexInvestigationEngine()
    @Published private(set) var codexStatus: CodexLocalConnectionStatus?
    @Published private(set) var codexChatID: String?
    @Published private(set) var responseComplete = false
    @Published private(set) var completedModel: String?
    private var automaticallyCheckedCodex = false
    var automaticCodexCheckEnabled = true // Anonymous native fixtures explicitly disable metadata requests.
    private var connectionGeneration = UUID()
    var preferredCodexExecutable: URL? {
        UserDefaults.standard.string(forKey: "LensCodexExecutablePath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
    func chooseCodexExecutable(_ url: URL?) {
        guard !connecting, !sending else { return }
        if let url { UserDefaults.standard.set(url.path, forKey: "LensCodexExecutablePath") }
        else { UserDefaults.standard.removeObject(forKey: "LensCodexExecutablePath") }
        CodexLocalConnectionPresentation.shared.status = nil
        useLocalCodex()
    }
    func useLocalCodex() {
        guard !connecting, !sending else { return }
        connectionMode = .codex; connecting = true; issue = nil; automaticallyCheckedCodex = true
        let generation = UUID(); connectionGeneration = generation
        let preferred = preferredCodexExecutable
        connectionTask = Task { [weak self] in
            defer { if self?.connectionGeneration == generation { self?.connecting = false } }
            guard let self else { return }
            do {
                let status: CodexLocalConnectionStatus
                if let statusProvider { status = try await statusProvider(preferred) }
                else { status = try await CodexLocalConnectionPresentation.shared.checkedStatus(preferred: preferred) }
                try Task.checkCancellation()
                guard connectionGeneration == generation, connectionMode == .codex, preferredCodexExecutable == preferred else { return }
                CodexLocalConnectionPresentation.shared.status = status
                guard status.isChatGPT else {
                    issue = LensL10n.text(status.authentication == "signedOut"
                        ? "Connectez-vous à ChatGPT dans Codex, puis actualisez ici. Lens réutilise cette connexion sans gérer votre mot de passe."
                        : "Codex n’utilise pas une connexion ChatGPT. Connectez-vous avec codex login ; aucune clé API ne sera utilisée par Lens.")
                    return // Keep the verified account state; a different auth mode is not a transport failure.
                }
                if let catalogueIssue = status.catalogueIssue { issue = LensL10n.text(catalogueIssue) }
                else if model.isEmpty { model = status.models.first(where: { $0.isDefault })?.id ?? status.models.first?.id ?? "" }
                else if !status.models.contains(where: { $0.id == self.model }) { issue = LensL10n.text("Le modèle enregistré est absent du catalogue Codex. Choisissez un modèle ; aucun remplacement automatique.") }
            } catch { if !Task.isCancelled, connectionGeneration == generation, preferredCodexExecutable == preferred { issue = error.localizedDescription; CodexLocalConnectionPresentation.shared.status = nil } }
        }
    }
    func continueChat() {
        guard !sending, responseComplete, codexChatID != nil else { return }
        response = nil; responseComplete = false; question = ""; recordID = nil; savedDraft = nil; issue = nil
        scheduleDraftSave()
    }
    func prepareChatPrompt(_ prompt: LensChatPrompt) {
        guard !sending, !preparing, capsule?.pieces.isEmpty == false, !responseComplete || codexChatID != nil else { return }
        let draft = responseComplete ? "" : question
        editChatQuestion(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prompt.question : draft + "\n\n" + prompt.question)
    }

    /// A conversation may start without selecting an event or reading a file.
    /// The empty frozen context carries only its observed-session identity.
    func ensureChatContext(rootID: String, cut: Date = Date()) {
        guard capsule == nil, !sending, !preparing,
              activeRootID == nil || activeRootID == rootID else { return }
        do {
            capsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: cut, pieces: [])
            activeRootID = rootID
        } catch { issue = error.localizedDescription }
    }

    func beginNewChat() async {
        let rootID = capsule?.rootThreadID ?? activeRootID
        await beginNewQuestion()
        if let rootID { ensureChatContext(rootID: rootID) }
    }

    var canSendChatMessage: Bool {
        !sending && !preparing && !connecting && !responseComplete && connectionReady && !model.isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && capsule.map { connectionMode == .codex || !$0.pieces.isEmpty } == true
    }
    var connectionReady: Bool { switch connectionMode { case .codex: return codexStatus?.isChatGPT == true && codexStatus?.models.contains(where: { $0.id == model }) == true; case .api: return !apiKey.isEmpty; case .chatgpt: return chatGPTAccount?.canUseChatGPTPlan == true } }
    func refreshConnection() async {
        if connectionMode == .codex {
            guard automaticCodexCheckEnabled, !automaticallyCheckedCodex, codexStatus == nil, !connecting, !sending else { return }
            useLocalCodex()
            await connectionTask?.value
            return
        }
        do { chatGPTAccount = try await CodexInvestigationConnection.shared.status() }
        catch { issue = error.localizedDescription }
    }
    func connectChatGPT() {
        guard !connecting, !sending else { return }
        connecting = true; issue = nil
        connectionTask = Task { [weak self] in
            defer { self?.connecting = false }
            do {
                let account = try await CodexInvestigationConnection.shared.connect { url in
                    let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                    if !opened { throw LensError.unavailable(LensL10n.text("Le navigateur système n’a pas pu ouvrir la connexion ChatGPT.")) }
                }
                try Task.checkCancellation()
                self?.chatGPTAccount = account
                let models = try await CodexInvestigationConnection.shared.models()
                guard !Task.isCancelled else { return }
                self?.chatGPTModels = models
                if self?.model.isEmpty == true, let first = models.first { self?.model = first.id }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self?.issue = error.localizedDescription } }
        }
    }
    func cancelConnection() {
        connectionGeneration = UUID(); connectionTask?.cancel(); connectionTask = nil; connecting = false
        Task { await codexEngine.shutdown(); await CodexInvestigationConnection.shared.cancelConnection() }
    }
    func disconnectChatGPT() {
        guard !sending, !connecting else { return }
        connecting = true
        connectionTask = Task { [weak self] in
            defer { self?.connecting = false }
            do {
                try await CodexInvestigationConnection.shared.disconnect()
                guard !Task.isCancelled else { return }
                self?.chatGPTAccount = nil; self?.chatGPTModels = []
            } catch { if !Task.isCancelled { self?.issue = error.localizedDescription } }
        }
    }
    func refreshModels() {
        guard !connecting, !sending else { return }
        connecting = true
        connectionTask = Task { [weak self] in
            defer { self?.connecting = false }
            do { let models = try await CodexInvestigationConnection.shared.models(); if !Task.isCancelled { self?.chatGPTModels = models } }
            catch { if !Task.isCancelled { self?.issue = error.localizedDescription } }
        }
    }
    @Published var inspectedPiece: String?
    @Published var reviewed = false
    private var sendTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var draftGeneration = UUID()
    enum DraftSaveState { case idle, pending, saving, failed }
    @Published private(set) var draftSaveState: DraftSaveState = .idle
    private struct SavedDraft {
        let recordID: String
        let capsuleID: String
        let digest: String
        let question: String
        let redacted: Bool
    }
    @Published private var savedDraft: SavedDraft?
    var isCurrentDraftSaved: Bool {
        guard let savedDraft, let capsule else { return false }
        return savedDraft.recordID == recordID && savedDraft.capsuleID == capsule.id
            && savedDraft.digest == capsule.digestSHA256 && savedDraft.question == question
    }
    var draftSaveLabel: String {
        if isCurrentDraftSaved {
            return savedDraft?.redacted == true ? LensL10n.text("Question masquée et contexte enregistrés localement") : LensL10n.text("Question et contexte enregistrés localement")
        }
        switch draftSaveState {
        case .failed: return LensL10n.text("Brouillon non sauvegardé · consultez l’erreur")
        case .saving: return LensL10n.text("Enregistrement local en cours")
        case .idle, .pending: return LensL10n.text("Modifications en attente de sauvegarde locale")
        }
    }
    private func cancelDraftSave() {
        draftGeneration = UUID(); draftTask?.cancel(); draftTask = nil
        draftSaveState = .idle
    }
    /// Only a successful archive write (or a verified archive load) calls this.
    /// The archive may redact the submitted question before persisting it.
    private func markSaved(_ record: InvestigationRecord, originalQuestion: String) {
        guard capsule?.id == record.capsule.id, capsule?.digestSHA256 == record.capsule.digestSHA256,
              question == originalQuestion else { return }
        savedDraft = SavedDraft(recordID: record.id, capsuleID: record.capsule.id,
                                digest: record.capsule.digestSHA256, question: originalQuestion,
                                redacted: record.question != originalQuestion)
        draftSaveState = .idle
    }
    private var activeRootID: String?
    private var contextRevision: UInt64 = 0
    private var archiveSelectionRevision: UInt64 = 0
    /// One reversible edit, scoped to the exact capsule produced by that edit.
    /// No current file is read to restore its captured bytes.
    private struct EvidenceRemoval {
        let capsule: EvidenceCapsule
        let resultID: String
        let resultDigest: String
        let question: String
        let response: String?
        let recordID: String?
        let savedDraft: SavedDraft?
        let inspectedPiece: String?
        let reviewed: Bool
        let responseComplete: Bool
        let questionAfterRemoval: String
        let removedID: String
    }
    @Published private var evidenceRemoval: EvidenceRemoval?
    var canUndoEvidenceRemoval: Bool {
        !sending && !preparing && evidenceRemoval?.resultID == capsule?.id && evidenceRemoval?.resultDigest == capsule?.digestSHA256 && evidenceRemoval != nil
    }
    var evidenceRemovalNotice: String? { evidenceRemoval.map { LensL10n.text("Élément {0} retiré de la question.", String(describing: $0.removedID)) } }

    func loadArchive(rootID: String) async {
        guard !Task.isCancelled else { return }
        cancelDraftSave()
        if activeRootID != rootID { activeRootID = rootID; contextRevision &+= 1; archiveSelectionRevision &+= 1; sendTask?.cancel(); sending = false; preparing = false; records = []; issue = nil; notice = nil }
        let revision = contextRevision
        if capsule?.rootThreadID != rootID { capsule = nil; response = nil; codexChatID = nil; responseComplete = false; recordID = nil; question = ""; reviewed = false; savedDraft = nil }
        do { let loaded = try await archive.list().filter { $0.rootThreadID == rootID }; if !Task.isCancelled, activeRootID == rootID, contextRevision == revision { records = loaded } }
        catch { if !Task.isCancelled, activeRootID == rootID, contextRevision == revision { issue = error.localizedDescription } }
        if !Task.isCancelled, activeRootID == rootID, contextRevision == revision { ensureChatContext(rootID: rootID) }
    }
    func openRecord(_ id: String) async {
        guard !Task.isCancelled else { return }
        guard !sending else { issue = LensL10n.text("Arrêtez la réception en cours avant d’ouvrir une autre enquête."); return }
        cancelDraftSave(); evidenceContextGeneration = UUID(); evidenceRemoval = nil
        archiveSelectionRevision &+= 1
        let revision = contextRevision, selectionRevision = archiveSelectionRevision
        do {
            let resolvedID = records.first(where: { $0.capsuleID == id })?.id ?? id
            guard let record = try await archive.load(id: resolvedID) else { throw LensError.unavailable(LensL10n.text("Enquête indisponible. Choisissez une autre entrée dans Archives locales.")) }
            guard !Task.isCancelled, revision == contextRevision, selectionRevision == archiveSelectionRevision else { return }
            guard activeRootID == nil || activeRootID == record.capsule.rootThreadID else { throw LensError.unavailable(LensL10n.text("Cette enquête appartient à une autre session.")) }
            capsule = record.capsule; question = record.question; response = record.response; responseComplete = record.response != nil; codexChatID = record.codexChatID; recordID = record.id; reviewed = false; issue = nil; notice = nil; inspectedPiece = record.capsule.pieces.first?.id
            markSaved(record, originalQuestion: record.question)
        } catch { if !Task.isCancelled, revision == contextRevision, selectionRevision == archiveSelectionRevision { issue = error.localizedDescription } }
    }
    func append(_ additions: [EvidencePiece], rootID: String, cut: Date, omissions: [EvidenceOmission] = []) throws {
        guard !sending else { throw LensError.unsupported(LensL10n.text("Une réponse est en cours. Attendez la fin ou arrêtez la réception avant d’ajouter un élément.")) }
        guard activeRootID == nil || activeRootID == rootID else { throw LensError.unavailable(LensL10n.text("La session a changé. Sélectionnez un élément dans la session ouverte, puis choisissez Demander à l’IA….")) }
        if activeRootID == nil { activeRootID = rootID }
        let existing = capsule?.rootThreadID == rootID ? capsule?.pieces ?? [] : []
        var pieces = existing
        var requestedIndex: Int?
        for piece in additions {
            if let index = pieces.firstIndex(where: { $0.kind == piece.kind && $0.eventID == piece.eventID && $0.agentID == piece.agentID && $0.title == piece.title && $0.text == piece.text && $0.environmentID == piece.environmentID && $0.knownVersion == piece.knownVersion && $0.location == piece.location && $0.sourceRefs == piece.sourceRefs && $0.coverage == piece.coverage }) {
                requestedIndex = index
            } else { pieces.append(piece); requestedIndex = pieces.count - 1 }
        }
        let numbered = pieces.enumerated().map { i, p in EvidencePiece(id: String(format: "E%03d", i + 1), kind: p.kind, title: p.title, text: p.text, eventID: p.eventID, agentID: p.agentID, environmentID: p.environmentID, sourceRefs: p.sourceRefs, knownVersion: p.knownVersion, capturedAt: p.capturedAt, coverage: p.coverage, location: p.location) }
        capsule = try EvidenceCapsule.build(rootThreadID: rootID, collectionCut: cut, pieces: numbered, omissions: (capsule?.rootThreadID == rootID ? capsule?.omissions ?? [] : []) + omissions)
        archiveSelectionRevision &+= 1
        if responseComplete { question = "" }
        response = nil; responseComplete = false; recordID = nil; reviewed = false; issue = nil; notice = nil
        if let requestedIndex {
            let requestedID = String(format: "E%03d", requestedIndex + 1)
            inspectedPiece = capsule?.pieces.contains(where: { $0.id == requestedID }) == true ? requestedID : nil
            if inspectedPiece == nil { notice = LensL10n.text("Cet élément dépasse la limite du contexte et n’a pas été ajouté. Consultez les éléments omis ; aucun autre n’est sélectionné à sa place.") }
        } else if capsule?.pieces.contains(where: { $0.id == inspectedPiece }) != true { inspectedPiece = capsule?.pieces.first?.id }
        scheduleDraftSave()
    }
    func removePiece(_ id: String) {
        guard !sending, !preparing, let capsule, capsule.pieces.contains(where: { $0.id == id }) else { return }
        do {
            let edited = try EvidenceCapsule.build(rootThreadID: capsule.rootThreadID, collectionCut: capsule.collectionCut, pieces: capsule.pieces.filter { $0.id != id }, omissions: capsule.omissions + [EvidenceOmission(pieceID: id, reason: "Élément retiré par l’utilisateur avant envoi.")], maxBytes: capsule.maxEncodedBytes, pieceMaxBytes: capsule.maxEncodedBytes)
            let nextQuestion = responseComplete ? "" : question
            let recovery = EvidenceRemoval(capsule: capsule, resultID: edited.id, resultDigest: edited.digestSHA256, question: question, response: response, recordID: recordID, savedDraft: savedDraft, inspectedPiece: inspectedPiece, reviewed: reviewed, responseComplete: responseComplete, questionAfterRemoval: nextQuestion, removedID: id)
            archiveSelectionRevision &+= 1
            self.capsule = edited; evidenceRemoval = recovery
            if inspectedPiece == id { inspectedPiece = edited.pieces.first?.id }
            question = nextQuestion; reviewed = false; response = nil; responseComplete = false; recordID = nil; issue = nil; notice = nil; scheduleDraftSave()
        }
        catch { issue = error.localizedDescription }
    }
    func undoEvidenceRemoval() {
        guard canUndoEvidenceRemoval, let recovery = evidenceRemoval else { return }
        cancelDraftSave(); archiveSelectionRevision &+= 1
        capsule = recovery.capsule
        inspectedPiece = recovery.inspectedPiece
        // A later question edit remains the person's draft. An old answer is
        // restored only when both its question and frozen evidence match.
        if question == recovery.questionAfterRemoval {
            question = recovery.question; response = recovery.response; responseComplete = recovery.responseComplete
            recordID = recovery.recordID; savedDraft = recovery.savedDraft; reviewed = recovery.reviewed
        } else { response = nil; responseComplete = false; recordID = nil; savedDraft = nil; reviewed = false }
        issue = nil; notice = LensL10n.text("Retrait annulé ; l’élément est restauré avec sa version enregistrée.")
        if response == nil { scheduleDraftSave() }
    }
    func clear() { guard !sending else { return }; cancelDraftSave(); archiveSelectionRevision &+= 1; capsule = nil; response = nil; responseComplete = false; codexChatID = nil; question = ""; recordID = nil; savedDraft = nil; reviewed = false; issue = nil; notice = nil }
    /// The explicit New Question action flushes the debounce before leaving a
    /// draft. A write failure leaves both the question and its evidence visible.
    func beginNewQuestion() async {
        guard !sending, !preparing else { return }
        guard let frozen = capsule, response == nil else { clear(); return }
        let frozenQuestion = question, previousID = recordID, revision = contextRevision, evidenceContext = evidenceContextGeneration
        cancelDraftSave(); savedDraft = nil; draftSaveState = .saving; preparing = true
        defer { if contextRevision == revision { preparing = false } }
        do {
            let saved: ArchiveWriteResult
            if let previousID, let previous = try await archive.load(id: previousID), previous.capsule.representsSameFrozenContent(as: frozen), previous.response == nil {
                saved = try await archive.updateQuestion(id: previousID, question: frozenQuestion)
            } else { saved = try await archive.save(capsule: frozen, question: frozenQuestion, codexChatID: codexChatID) }
            guard !Task.isCancelled, contextRevision == revision, evidenceContextGeneration == evidenceContext, question == frozenQuestion else { return }
            recordID = saved.record.id; markSaved(saved.record, originalQuestion: frozenQuestion)
            let loaded = try await archive.list().filter { $0.rootThreadID == frozen.rootThreadID }
            guard !Task.isCancelled, contextRevision == revision, evidenceContextGeneration == evidenceContext, question == frozenQuestion else { return }
            records = loaded
            clear()
            notice = saved.rotated ? LensL10n.text("Brouillon sauvegardé dans Archives locales ; quota : {0} anciennes enquêtes retirées.", String(describing: saved.removedIDs.count)) : LensL10n.text("Brouillon précédent sauvegardé dans Archives locales.")
        } catch {
            if !Task.isCancelled, contextRevision == revision, evidenceContextGeneration == evidenceContext {
                if !isCurrentDraftSaved { draftSaveState = .failed }
                issue = "Nouvelle question impossible : le brouillon reste ouvert. " + error.localizedDescription
            }
        }
    }
    func editQuestion(_ value: String) {
        guard !sending else { return }
        archiveSelectionRevision &+= 1
        question = value; reviewed = false
        if response != nil { response = nil; recordID = nil }
        scheduleDraftSave()
    }
    /// Typing a follow-up starts a draft in the explicitly linked Codex chat.
    /// The completed exchange remains in the archive with its frozen context.
    /// Merely focusing the editor never changes a record or sends a request.
    func editChatQuestion(_ value: String) {
        guard !sending else { return }
        if let rootID = activeRootID { ensureChatContext(rootID: rootID) }
        if responseComplete {
            guard codexChatID != nil, !value.isEmpty else { return }
            continueChat()
        }
        editQuestion(value)
    }
    private func scheduleDraftSave() {
        cancelDraftSave(); savedDraft = nil
        guard let frozen = capsule else { return }
        draftSaveState = .pending
        let frozenQuestion = question, previousID = recordID, revision = contextRevision, generation = draftGeneration
        draftTask = Task {
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
                try Task.checkCancellation()
                guard generation == draftGeneration else { return }
                draftSaveState = .saving
                let saved: ArchiveWriteResult
                let previous: InvestigationRecord?
                if let previousID { previous = try await archive.load(id: previousID) }
                else { previous = nil }
                try Task.checkCancellation()
                if let previousID, let previous, previous.capsule.representsSameFrozenContent(as: frozen), previous.response == nil { saved = try await archive.updateQuestion(id: previousID, question: frozenQuestion) }
                else { saved = try await archive.save(capsule: frozen, question: frozenQuestion, codexChatID: codexChatID) }
                guard !Task.isCancelled, generation == draftGeneration, contextRevision == revision, capsule?.id == frozen.id, question == frozenQuestion else { return }
                recordID = saved.record.id
                markSaved(saved.record, originalQuestion: frozenQuestion)
                if saved.rotated { notice = LensL10n.text("Quota local : {0} anciennes enquêtes retirées.", String(describing: saved.removedIDs.count)) }
                let loaded = try await archive.list().filter { $0.rootThreadID == frozen.rootThreadID }
                if !Task.isCancelled, generation == draftGeneration, contextRevision == revision, capsule?.id == frozen.id, question == frozenQuestion { records = loaded }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, generation == draftGeneration, contextRevision == revision, capsule?.id == frozen.id, question == frozenQuestion {
                    if !isCurrentDraftSaved { draftSaveState = .failed }
                    issue = error.localizedDescription
                }
            }
        }
    }
    func send() {
        guard !sending, !preparing, let frozen = capsule else { return }
        let frozenQuestion = question, frozenKey = apiKey, frozenModel = model, revision = contextRevision
        let previousChatID = codexChatID
        let frozenMode = connectionMode, language: CodexInvestigationLanguage = LensL10n.resolvedLanguage == .en ? .english : .french
        let frozenGroupInSidebar = UserDefaults.standard.object(forKey: "LensGroupCodexInvestigations") as? Bool ?? true
        let frozenExecutable = preferredCodexExecutable
        do {
            let body = try frozenMode == .codex ? CodexInvestigationEngine.evidenceInput(capsule: frozen, question: frozenQuestion, model: frozenModel) : frozenMode == .chatgpt ? CodexInvestigationClient.requestBody(capsule: frozen, question: frozenQuestion, model: frozenModel, language: language) : InvestigationClient.requestBody(capsule: frozen, question: frozenQuestion, model: frozenModel)
            cancelDraftSave(); savedDraft = nil; draftSaveState = .saving; evidenceRemoval = nil
            sending = true; issue = nil; response = nil; responseComplete = false
            sendTask = Task {
                defer { if contextRevision == revision, capsule?.id == frozen.id { sending = false } }
                var savedID: String?
                do {
                    let frozenChatID: String?
                    if frozenMode == .codex {
                        try await codexEngine.useExecutable(frozenExecutable)
                        let chat = try await codexEngine.chat(rootID: frozen.rootThreadID, chatID: previousChatID)
                        try Task.checkCancellation()
                        guard contextRevision == revision, capsule?.id == frozen.id else { return }
                        frozenChatID = chat.chatID; codexChatID = chat.chatID
                    } else { frozenChatID = nil }
                    let saved: ArchiveWriteResult
                    if let draftID = recordID, let previous = try await archive.load(id: draftID), previous.capsule.representsSameFrozenContent(as: frozen), previous.response == nil, frozenMode == .codex || previous.codexChatID == nil { saved = try await archive.updateQuestion(id: draftID, question: frozenQuestion, codexChatID: frozenChatID) }
                    else { saved = try await archive.save(capsule: frozen, question: frozenQuestion, codexChatID: frozenChatID) }
                    savedID = saved.record.id
                    try Task.checkCancellation()
                    guard contextRevision == revision, capsule?.id == frozen.id else { return }
                    recordID = saved.record.id
                    markSaved(saved.record, originalQuestion: frozenQuestion)
                    if saved.rotated { notice = LensL10n.text("Quota local : {0} anciennes enquêtes retirées.", String(describing: saved.removedIDs.count)) }
                    let answer: InvestigationAnswer
                    if frozenMode == .codex {
                        guard let chatID = frozenChatID else { throw LensError.corrupt("Chat d’enquête absent.") }
                        answer = try await codexEngine.answer(chatID: chatID, rootID: frozen.rootThreadID, capsule: frozen, question: frozenQuestion, model: frozenModel, language: language, groupInSidebar: frozenGroupInSidebar, metadata: { [weak self] status in
                            await self?.receiveCodexMetadata(status, revision: revision, capsuleID: frozen.id)
                        }) { [weak self] text in
                            await self?.receiveCodexProgress(text, revision: revision, capsuleID: frozen.id)
                        }
                    } else if frozenMode == .chatgpt { answer = try await CodexInvestigationConnection.shared.answer(body: body, capsule: frozen) }
                    else { answer = try await InvestigationClient().answer(body: body, capsule: frozen, apiKey: frozenKey) }
                    let updated = try await archive.updateResponse(id: saved.record.id, response: answer.text, inferenceIDs: [answer.responseID])
                    guard contextRevision == revision, capsule?.id == frozen.id else { return }
                    response = updated.record.response; responseComplete = true
                    if frozenMode == .codex { CodexLocalConnectionPresentation.shared.completedModel = answer.model }
                    if updated.rotated { notice = LensL10n.text("Quota local : {0} anciennes enquêtes retirées.", String(describing: updated.removedIDs.count)) }
                } catch {
                    guard contextRevision == revision, capsule?.id == frozen.id else { return }
                    issue = error is CancellationError ? LensL10n.text("Réception arrêtée ; aucune réponse complète enregistrée. La question et le contexte restent disponibles.") : error.localizedDescription
                    if !isCurrentDraftSaved { draftSaveState = .failed }
                    if let savedID { recordID = savedID }
                }
                do { let loaded = try await archive.list().filter { $0.rootThreadID == frozen.rootThreadID }; if contextRevision == revision, capsule?.id == frozen.id { records = loaded } }
                catch { if contextRevision == revision, capsule?.id == frozen.id { issue = error.localizedDescription } }
            }
        } catch { issue = error.localizedDescription }
    }
    func cancel() { sendTask?.cancel() }
    private func receiveCodexProgress(_ text: String, revision: UInt64, capsuleID: String) {
        guard contextRevision == revision, capsule?.id == capsuleID, sending else { return }
        response = text.isEmpty ? nil : text
    }
    private func receiveCodexMetadata(_ status: CodexLocalConnectionStatus?, revision: UInt64, capsuleID: String) {
        guard contextRevision == revision, capsule?.id == capsuleID, sending else { return }
        if status == nil || status?.email != codexStatus?.email { CodexLocalConnectionPresentation.shared.completedModel = nil }
        CodexLocalConnectionPresentation.shared.status = status
    }
    /// Capture the latest draft before stopping; only Lens' private archive is written.
    func flushAndStop() async {
        cancelDraftSave(); sendTask?.cancel(); connectionTask?.cancel(); apiKey = ""; evidenceRemoval = nil
        let frozen = capsule, frozenQuestion = question, previousID = recordID
        let frozenResponse = responseComplete ? response : nil
        contextRevision &+= 1; sending = false; preparing = false
        await codexEngine.shutdown()
        guard let frozen, frozenResponse == nil else { return }
        let revision = contextRevision
        savedDraft = nil; draftSaveState = .saving
        do {
            let saved: ArchiveWriteResult
            if let previousID, let previous = try await archive.load(id: previousID), previous.capsule.representsSameFrozenContent(as: frozen), previous.response == nil {
                saved = try await archive.updateQuestion(id: previousID, question: frozenQuestion)
            } else { saved = try await archive.save(capsule: frozen, question: frozenQuestion, codexChatID: codexChatID) }
            if contextRevision == revision, capsule?.id == frozen.id, question == frozenQuestion {
                recordID = saved.record.id; markSaved(saved.record, originalQuestion: frozenQuestion)
            }
        } catch {
            if contextRevision == revision, capsule?.id == frozen.id, question == frozenQuestion {
                draftSaveState = .failed; issue = LensL10n.text("Brouillon non sauvegardé : ") + error.localizedDescription
            }
        }
    }
}

extension LensStore {
    @discardableResult func prepareInvestigation(for target: Destination? = nil, selectedPeriodEventIDs: [String]? = nil) async -> Bool {
        guard !Task.isCancelled, isObserving, let snap = snapshot, let target = target ?? selection else { return false }
        let investigator = investigation
        let frozenPresentation = presentation
        let frozenCodeReferences = originCodeReferences
        guard !investigator.preparing, !investigator.sending else { return false }
        let evidenceContext = investigator.evidenceContextGeneration
        investigator.preparing = true
        defer { if snapshot?.root.id == snap.root.id { investigator.preparing = false } }
        let span = LensSignposts.begin("PrepareEvidence"); defer { span.end() }
        do {
            var ids: [String] = [], pieces: [EvidencePiece] = [], omissions: [EvidenceOmission] = []
            if let selectedPeriodEventIDs {
                ids = Array(selectedPeriodEventIDs.prefix(16))
                omissions.append(EvidenceOmission(reason: "Période sélectionnée : seize événements au plus, dans leur ordre affiché. Les autres événements ne sont pas transmis.", omittedCount: max(0, selectedPeriodEventIDs.count - ids.count)))
                let bounds = period.map { "\($0.lowerBound.ISO8601Format())…\($0.upperBound.ISO8601Format())" } ?? "inconnues"
                pieces.append(EvidencePiece(id: "period", kind: "selectedPeriod", title: "Période sélectionnée", text: "Bornes sélectionnées : \(bounds)\nCoupe de collecte : \(snap.collectedAt.ISO8601Format())\nCette sélection ne prouve pas la continuité de la collecte entre les événements.", capturedAt: snap.collectedAt))
            } else { switch target {
            case .event(let id): ids.append(id)
            case .change(let id):
                if let change = snap.changes.first(where: { $0.id == id }) {
                    ids.append(change.eventID)
                    do {
                        guard let event = frozenPresentation?.eventsByID[change.eventID] ?? snap.events.first(where: { $0.id == change.eventID }) else { throw LensError.unavailable("Événement d’origine du diff inaccessible.") }
                        let related = event.relatedEventID.flatMap { frozenPresentation?.eventsByID[$0] }
                        let selected = try RecordedChangeEvidence.select(change: change, event: event, related: related)
                        guard ([event.source] + event.supplementarySources).reduce(0, { $0 + max(0, $1.length) }) <= RecordedDiff.maximumInputBytes else { throw LensError.unavailable("Trace du diff supérieure à 8 Mio ; consultez la source progressive ou sélectionnez un fragment.") }
                        let detail = try await engine.sourceDetail(for: event)
                        let captured = try await Task.detached(priority: .userInitiated) {
                            try RecordedChangeEvidence.frozenPieces(change: change, selection: selected, detail: detail, capturedAt: snap.collectedAt)
                        }.value
                        if captured.isEmpty { omissions.append(EvidenceOmission(reason: "Aucun diff enregistré interprétable pour la modification sélectionnée ; aucun fichier courant substitué.")) }
                        pieces += captured
                    } catch { omissions.append(EvidenceOmission(reason: "Diff sélectionné : \(error.localizedDescription)")) }
                }
            case .agent(let id):
                if let agent = snap.agents.first(where: { $0.id == id }) {
                    if let mission = agent.missionEventID { ids.append(mission) }
                    let recent = snap.events.filter { $0.agentID == id }.suffix(6); ids += recent.map(\.id)
                    omissions.append(EvidenceOmission(reason: "Agent sélectionné : mission et six derniers événements au plus ; les autres événements ne sont pas transmis.", omittedCount: max(0, snap.events.count(where: { $0.agentID == id }) - recent.count)))
                }
            case .resource(let id):
                if let resource = snap.resources.first(where: { $0.id == id }) {
                    ids += resource.eventIDs.prefix(4)
                    pieces.append(EvidencePiece(id: "E001", kind: "resourceMetadata", title: resource.name, text: "Localisation : \(resource.location)\nRôles : \(resource.roles.map(\.rawValue).joined(separator: ", "))\nDisponibilité : \(resource.availability.rawValue)\nCette entrée décrit la ressource ; ses octets ne sont pas implicitement joints.", capturedAt: snap.collectedAt))
                }
            case .environment(let id), .file(let id, _, _, _):
                if let env = snap.environments.first(where: { $0.id == id }) { pieces.append(EvidencePiece(id: "E001", kind: "environmentMetadata", title: env.path, text: "Environnement enregistré : \(env.path)\nDépôt (résolution actuelle) : \(env.repositoryPath ?? "inconnu")\nBranche enregistrée : \(env.recordedBranch ?? "inconnue")\nRéférence enregistrée : \(env.recordedRef ?? "inconnue")\nMétadonnées enregistrées ; aucun fichier courant inclus.", environmentID: env.id, capturedAt: snap.collectedAt)) }
            case .evidence(let capsuleID, let pieceID):
                guard let source = [inspectedEvidenceCapsule, investigator.capsule].compactMap({ $0 }).first(where: { $0.id == capsuleID && $0.rootThreadID == snap.root.id }),
                      let piece = source.pieces.first(where: { $0.id == pieceID }) else { return false }
                if investigator.capsule?.id == capsuleID {
                    investigator.inspectedPiece = pieceID
                } else {
                    // Reuse the frozen element, never reread a current file as its old version.
                    try investigator.append([piece], rootID: snap.root.id, cut: source.collectionCut)
                }
                showChat(); return true
            case .investigation: showChat(); return false
            } }
            if let objectID = originObjectID(for: target), let origin = frozenPresentation?.originInspection.selection(objectID: objectID) {
                ids += origin.evidenceEventIDs
                do { pieces.append(try await Task.detached(priority: .userInitiated) { try OriginEvidence.piece(selection: origin, collectionCut: snap.collectedAt) }.value) }
                catch { omissions.append(EvidenceOmission(reason: error.localizedDescription)) }
                if let sourceID = frozenPresentation?.changesByID[origin.object.sourceID]?.eventID ?? (origin.object.kind == .agent ? nil : origin.object.sourceID),
                   let code = frozenCodeReferences[sourceID], code.environmentID == origin.object.environmentID,
                   frozenPresentation?.changesByID[origin.object.sourceID].map({ code.belongs(to: $0) }) ?? true {
                    do { pieces.append(try code.evidence(capturedAt: snap.collectedAt)) }
                    catch { omissions.append(EvidenceOmission(reason: error.localizedDescription)) }
                }
            }
            // Only explicit trace relations contribute context, never proximity.
            for id in ids {
                if let event = snap.events.first(where: { $0.id == id }) {
                    if let related = event.relatedEventID { ids.append(related) }
                    if let mission = snap.agents.first(where: { $0.id == event.agentID })?.missionEventID { ids.append(mission) }
                    if let exchange = frozenPresentation?.communicationInspection.communicationByEventID[id] { ids += exchange.originEventIDs + exchange.missionEventIDs + exchange.recipientContextEventIDs }
                }
            }
            var seen = Set<String>()
            let uniqueEventIDs = ids.filter { seen.insert($0).inserted }
            if uniqueEventIDs.count > 16 {
                omissions.append(EvidenceOmission(reason: "Événements liés : seize au plus sont transmis. Les liens supplémentaires restent consultables dans Lens.", omittedCount: uniqueEventIDs.count - 16))
            }
            for id in uniqueEventIDs.prefix(16) {
                try Task.checkCancellation()
                guard let event = snap.events.first(where: { $0.id == id }) else { omissions.append(EvidenceOmission(reason: "Événement lié inaccessible : \(id).")); continue }
                do {
                    if let frozenPresentation { pieces += try InspectionEvidence.pieces(event: event, presentation: frozenPresentation, collectionCut: snap.collectedAt) }
                    let capsulePager = RecordedPager()
                    var parts: [String] = []
                    for part in ["content", "input", "output"] {
                        try Task.checkCancellation()
                        if event.trace?.communication?.isOpaque == true, part != "output" {
                            parts.append(part.uppercased() + "\n[Message opaque : contenu non transmis ; source brute consultable dans Lens.]")
                            omissions.append(EvidenceOmission(reason: "\(event.id) / \(part) : message opaque, aucune instruction lisible reconstruite ou transmise."))
                            continue
                        }
                        let page = try await capsulePager.begin(event: event, part: part, limit: 16 * 1024)
                        guard !Task.isCancelled, isObserving, snapshot?.root.id == snap.root.id else { return false }
                        guard investigator.evidenceContextGeneration == evidenceContext else { showLocalNotice(LensL10n.text("Préparation annulée : le contexte a changé.")); return false }
                        parts.append(part.uppercased() + "\n" + page.text)
                        if page.token != nil { omissions.append(EvidenceOmission(reason: "\(event.id) / \(part) : première page de 16 Kio seulement. Sortie supplémentaire non transmise ; empreinte de la ligne entière non revalidée avant EOF.")) }
                    }
                    let text = "Événement : \(event.id)\nAgent : \(event.agentID)\nTour : \(event.turnID ?? "inconnu")\nDate : \(event.timestamp.ISO8601Format())\nFin : \(event.endTime?.ISO8601Format() ?? "inconnue")\nOutil : \(event.toolName ?? "sans objet")\nEnvironnement : \(event.environmentID ?? "inconnu")\n\n" + parts.joined(separator: "\n\n")
                    pieces.append(EvidencePiece(id: "E001", kind: event.kind.rawValue, title: event.title, text: text, eventID: event.id, agentID: event.agentID, environmentID: event.environmentID, sourceRefs: [event.source] + event.supplementarySources, capturedAt: snap.collectedAt, coverage: snap.coverage.filter { $0.source == event.source.path }))
                } catch { omissions.append(EvidenceOmission(reason: "\(event.title) : \(error.localizedDescription)")) }
            }
            // A per-journal byte cut anchors the view frozen at preparation time.
            var cuts: [String: SourceRef] = [:]
            for event in snap.events { for source in [event.source] + event.supplementarySources { if source.offset + UInt64(source.length) > (cuts[source.path].map { $0.offset + UInt64($0.length) } ?? 0) { cuts[source.path] = source } } }
            let manifest = cuts.keys.sorted().map { path in let s = cuts[path]!; return "\(path) : dernière ligne observée \(s.line), fin octet \(s.offset + UInt64(s.length)), SHA-256 de cette ligne \(s.sha256 ?? "inconnu")" }.joined(separator: "\n")
            let coverage = snap.coverage.prefix(40).map { "\($0.category) : \($0.message)" }.joined(separator: "\n")
            pieces.insert(EvidencePiece(id: "E001", kind: "collectionManifest", title: LensL10n.text("Session"), text: "Session racine : \(snap.root.id)\nTitre : \(snap.root.title)\nCollecte : \(snap.collectedAt.ISO8601Format())\n\(snap.agents.count) agents, \(snap.events.count) événements observés. L'ensemble de cet historique n'est pas joint.\n\nCOUPES PAR JOURNAL\n\(manifest)\n\nLIMITES CONNUES\n\(coverage)", capturedAt: snap.collectedAt, coverage: Array(snap.coverage.prefix(40))), at: 0)
            guard !Task.isCancelled, isObserving, snapshot?.root.id == snap.root.id else { return false }
            guard investigator.evidenceContextGeneration == evidenceContext else { showLocalNotice("Préparation annulée : le contexte a changé."); return false }
            try investigator.append(pieces, rootID: snap.root.id, cut: snap.collectedAt, omissions: omissions)
            navigate(.investigation(investigator.capsule!.id), newTab: true)
            return true
        } catch { if !Task.isCancelled, snapshot?.root.id == snap.root.id { investigator.issue = error.localizedDescription }; return false }
    }
    func addCodeEvidence(text: String, path: String, environmentID: String?, version: String, line: Int, historical: Bool) {
        guard let snap = snapshot else { return }
        do {
            let piece = EvidencePiece(id: "E001", kind: historical ? "verifiedHistoricalCode" : "capturedCurrentCode", title: "\(path):\(line)", text: "Chemin : \(path)\nLigne de début : \(line)\nNature : \(historical ? "version Git vérifiée" : "extrait du contenu courant capturé ; pas une version passée")\n\n\(text)", environmentID: environmentID, knownVersion: version,
                location: environmentID.map { EvidenceLocation(environmentID: $0, path: path, versionKind: historical ? .verifiedGitBlob : .capturedCurrent, version: version, side: .after, firstLine: line, lastLine: line + max(0, text.split(separator: "\n", omittingEmptySubsequences: false).count - 1)) })
            try investigation.append([piece], rootID: snap.root.id, cut: snap.collectedAt)
            navigate(.investigation(investigation.capsule!.id), newTab: true)
        } catch { investigation.issue = error.localizedDescription }
    }
}

/// The investigation is a persistent side conversation. Its store owns the draft,
/// connection and in-flight request; hiding this view never stops that work.
struct InvestigationView: View {
    @Environment(\.lensAccent) private var accent
    @AppStorage("lens.language") private var language = "en"
    @Environment(\.lensWindowContext) private var windowContext
    @EnvironmentObject var store: LensStore
    @ObservedObject var investigator: InvestigationStore
    @State private var showConnectionSettings = false
    @FocusState private var apiKeyFocused: Bool
    @FocusState private var questionFocused: Bool
    @State private var evidenceExpanded = false
    @State private var omissionsExpanded = false
    @State private var presentation: InvestigationPresentation?
    @State private var presentationIssue: String?
    @State private var previousExchanges: [InvestigationTranscriptExchange] = []
    @State private var transcriptUnavailable: [InvestigationTranscriptUnavailable] = []
    @State private var transcriptOffset = 0
    @State private var transcriptHasMore = false
    @State private var transcriptLoading = false
    @State private var transcriptSelection: InvestigationTranscriptSelection?
    @State private var transcriptInput: InvestigationTranscriptSelection?

    // These seeds also let the native development gallery exercise expanded
    // details. They are used once; later disclosure state belongs to this pane.
    init(investigator: InvestigationStore, initiallyExpandedEvidence: Bool = false) {
        self.investigator = investigator
        _evidenceExpanded = State(initialValue: initiallyExpandedEvidence)
    }

    private func updateTranscriptInput(records: [InvestigationSummary]? = nil) {
        guard let rootID = investigator.capsule?.rootThreadID, let chatID = investigator.codexChatID else { transcriptInput = nil; return }
        let records = records ?? investigator.records
        let next = InvestigationTranscriptSelection(rootID: rootID, chatID: chatID, currentRecordID: investigator.recordID,
            currentCreatedAt: records.first { $0.id == investigator.recordID }?.createdAt,
            recordIDs: Self.transcriptRecordIDs(records, chatID: chatID), language: LensL10n.resolvedLanguage.rawValue)
        if transcriptInput != next { transcriptInput = next }
    }

    /// Page completed exchanges in this exact chat, not unrelated investigations
    /// whose timestamps or observed-session identities happen to match.
    static func transcriptRecordIDs(_ records: [InvestigationSummary], chatID: String) -> [String] {
        records.filter { $0.codexChatID == chatID && $0.responseAvailable }
            .sorted { $0.createdAt > $1.createdAt }.map(\.id)
    }

    private var presentationInput: InvestigationPresentationInput? {
        guard let capsule = investigator.capsule else { return nil }
        return InvestigationPresentationInput(rootID: capsule.rootThreadID, capsuleID: capsule.id, capsuleDigest: capsule.digestSHA256,
            response: investigator.response, question: "", model: "", includePayload: false,
            connectionMode: investigator.connectionMode.rawValue, language: LensL10n.resolvedLanguage.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chatHeader
            Divider()
            VSplitView {
                conversation.frame(minHeight: 150, idealHeight: 420, maxHeight: .infinity)
                composer.frame(minHeight: 170, idealHeight: 200, maxHeight: evidenceExpanded ? 380 : 260)
                    .background(LensPaneSizing(key: "chat-composer-v66", preferredWidth: 200, context: windowContext, isVertical: false))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: presentationInput) { await preparePresentation() }
        .task(id: transcriptInput) { await prepareTranscript() }
        .task { await investigator.refreshConnection() }
        .onAppear {
            if let snapshot = store.snapshot { investigator.ensureChatContext(rootID: snapshot.root.id, cut: snapshot.collectedAt) }
            updateTranscriptInput()
        }
        .onReceive(investigator.$records) { updateTranscriptInput(records: $0) }
        .onChange(of: investigator.codexChatID) { _, _ in updateTranscriptInput() }
        .onChange(of: investigator.recordID) { _, _ in updateTranscriptInput() }
        .onChange(of: investigator.capsule?.rootThreadID) { _, _ in updateTranscriptInput() }
        .sheet(isPresented: $showConnectionSettings) { connectionSettings }
        .accessibilityIdentifier("lens-side-chat")
    }

    private var chatHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            LensNavigationEffectGroup(spacing: 6) {
            HStack(spacing: 6) {
                Text(LensL10n.text("Chat d’enquête")).font(LensUI.paneTitle).lineLimit(1)
                    .help(LensL10n.text("Chat d’enquête"))
                Spacer(minLength: 4)
                Button { Task { await investigator.beginNewChat(); questionFocused = true } } label: {
                    Image(systemName: LensSymbols.name("square.and.pencil"))
                        .frame(width: 24, height: 24)
                }.buttonStyle(.borderless)
                    .disabled(investigator.sending || investigator.preparing)
                    .help(LensL10n.text("Nouveau chat ; conserver la conversation précédente"))
                    .accessibilityLabel(LensL10n.text("Nouveau chat"))
                    .accessibilityIdentifier("lens-side-chat-new-question")
                Menu {
                    Menu(LensL10n.text("Archives locales")) {
                        ForEach(investigator.records) { record in
                            Button(record.questionPreview.nonempty ?? LensL10n.text("Question sans réponse")) {
                                let rootID = store.snapshot?.root.id, opening = store.openingIdentity
                                Task {
                                    await investigator.openRecord(record.id)
                                    guard store.isObserving, store.openingIdentity == opening, store.snapshot?.root.id == rootID,
                                          investigator.recordID == record.id, investigator.capsule?.rootThreadID == rootID else { return }
                                    store.navigate(.investigation(record.id))
                                }
                            }
                        }
                    }.disabled(investigator.sending || investigator.records.isEmpty)
                    Button(LensL10n.text("Configurer l’envoi…")) { showConnectionSettings = true }
                        .disabled(investigator.sending)
                    Divider()
                    LensActionButton(store: store, action: .inspector)
                } label: { LensIconMenuLabel() }
                    .lensIconMenu("Actions du chat d’enquête").lensChromeMenu()
                    .accessibilityIdentifier("lens-side-chat-more")
                Button {
                    windowContext?.focusPane(.content, afterLayout: true)
                    store.chatVisible = false; store.inspectorVisible = false
                } label: { Image(systemName: LensSymbols.name("xmark")).frame(width: 24, height: 24) }
                    .buttonStyle(.borderless)
                    .help(LensL10n.text("Masquer le chat ; le brouillon et la réception sont conservés"))
                    .accessibilityLabel(LensL10n.text("Masquer le chat d’enquête"))
                    .accessibilityIdentifier("lens-side-chat-close")
            }
            }
            if let chatID = investigator.codexChatID {
                Text(LensL10n.text("Chat séparé {0}", String(chatID.prefix(8)))).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(LensL10n.text("Distinct de la session observée")).font(LensUI.metadata).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(LensBrand.chrome)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        transcriptHistory
                        if investigator.response != nil || investigator.sending {
                            LensChatQuestionBubble(text: investigator.question, fontSize: store.fontSize)
                                .id("lens-chat-question")
                            if let capsule = investigator.capsule, let prepared = currentPresentation(capsule), !prepared.context.sources.isEmpty {
                                messageContext(prepared.context, sent: investigator.responseComplete)
                            }
                            if let capsule = investigator.capsule { generatedResponse(capsule) }
                        } else if previousExchanges.isEmpty {
                            emptyConversation
                        }
                        if let issue = investigator.issue {
                            Label(LensL10n.display(issue), systemImage: LensSymbols.name("exclamationmark.triangle"))
                                .font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let notice = investigator.notice {
                            Text(LensL10n.display(notice)).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let presentationIssue {
                            Label(presentationIssue, systemImage: LensSymbols.name("exclamationmark.triangle"))
                                .font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("lens-chat-latest")
                    }.padding(.horizontal, 16).padding(.vertical, 20)
                }.accessibilityIdentifier("lens-chat-conversation")
                if investigator.response != nil || investigator.sending {
                    HStack {
                        if investigator.codexChatID == nil, investigator.responseComplete {
                            Button(LensL10n.text("Nouveau chat")) { Task { await investigator.beginNewChat(); questionFocused = true } }
                                .buttonStyle(.borderless)
                        }
                        Spacer(minLength: 4)
                        Button { proxy.scrollTo("lens-chat-latest", anchor: .bottom) } label: {
                            Label(LensL10n.text("Dernier message"), systemImage: LensSymbols.name("arrow.down"))
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help(LensL10n.text("Aller au dernier message sans modifier la sélection"))
                    }.padding(.horizontal, 16).padding(.vertical, 5)
                }
            }
            .onChange(of: investigator.sending) { _, sending in
                // Scroll once on explicit Send, never on every streamed token.
                if sending { proxy.scrollTo("lens-chat-latest", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var transcriptHistory: some View {
        if transcriptInput != nil {
            if transcriptLoading {
                LensProgressIndicator(LensL10n.text("Lecture des échanges sauvegardés…")).controlSize(.small).frame(maxWidth: .infinity)
            }
            if transcriptHasMore {
                Button(LensL10n.text("Charger les échanges plus anciens")) { Task { await loadTranscriptPage() } }
                    .disabled(transcriptLoading)
            }
            ForEach(transcriptUnavailable) { item in
                HStack(alignment: .top) {
                    Text(LensL10n.text("Échange archivé non chargé : {0}", String(item.id.prefix(8))) + " · " + LensL10n.display(item.reason))
                        .font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(LensL10n.text("Ouvrir l’archive")) { openArchivedExchange(item.id) }.disabled(investigator.sending)
                }
            }
            ForEach(previousExchanges) { exchange in
                VStack(alignment: .leading, spacing: 8) {
                    LensChatQuestionBubble(text: exchange.question, fontSize: store.fontSize)
                    if exchange.hasAttachedContext { messageContext(exchange.context) }
                    LensChatMarkdownView(document: exchange.markdownResponse, fontSize: store.fontSize,
                        onCopyCode: { store.copyLocalText($0, notice: LensL10n.text("Texte copié")) }, onOpenURL: openChatURL,
                        speaker: "Codex", onCopyMessage: { store.copyLocalText($0, notice: LensL10n.text("Réponse complète copiée")) }, sources: exchange.citedSources)
                    if !exchange.citedSources.isEmpty { sourceList(exchange.citedSources) }
                    if !exchange.invalidCitationIDs.isEmpty {
                        Text(LensL10n.text("Citations inconnues : {0}. Aucun lien disponible.", exchange.invalidCitationIDs.joined(separator: ", ")))
                            .font(LensUI.metadata).foregroundStyle(LensAppearance.warningText)
                    }
                    if exchange.hasAttachedContext, exchange.validCitationIDs.isEmpty {
                        Text(LensL10n.text("Aucune citation vérifiable dans cette réponse.")).font(LensUI.metadata).foregroundStyle(LensAppearance.warningText)
                    }
                    Text(exchange.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }.id("lens-chat-archive-" + exchange.id)
            }
        }
    }
    private func prepareTranscript() async {
        if transcriptSelection?.rootID != transcriptInput?.rootID || transcriptSelection?.chatID != transcriptInput?.chatID {
            previousExchanges = []; transcriptUnavailable = []
        }
        transcriptOffset = 0; transcriptHasMore = false; transcriptLoading = false
        transcriptSelection = transcriptInput
        guard transcriptSelection != nil else { transcriptLoading = false; return }
        await loadTranscriptPage()
    }
    private func loadTranscriptPage() async {
        guard !transcriptLoading, let selection = transcriptSelection, selection == transcriptInput else { return }
        transcriptLoading = true
        defer { if transcriptSelection == selection { transcriptLoading = false } }
        do {
            let replacing = transcriptOffset == 0
            let retainedBytes = replacing ? 0 : previousExchanges.reduce(0) { $0 + $1.retainedBytes }
            let result = try await InvestigationTranscriptReader.shared.read(archive: investigator.archive, selection: selection,
                offset: transcriptOffset, retainedBytes: retainedBytes)
            guard !Task.isCancelled, selection == transcriptInput, selection == transcriptSelection else { return }
            if replacing { previousExchanges = []; transcriptUnavailable = [] }
            let existingIDs = Set(previousExchanges.map(\.id))
            previousExchanges.append(contentsOf: result.exchanges.filter { !existingIDs.contains($0.id) })
            previousExchanges.sort { $0.createdAt < $1.createdAt }
            transcriptUnavailable.append(contentsOf: result.unavailable)
            transcriptOffset = result.nextOffset; transcriptHasMore = result.hasMore
        } catch {
            if !Task.isCancelled, selection == transcriptInput { presentationIssue = error.localizedDescription }
        }
    }
    private func openArchivedExchange(_ id: String) {
        let rootID = store.snapshot?.root.id, opening = store.openingIdentity
        Task {
            await investigator.openRecord(id)
            guard store.isObserving, store.openingIdentity == opening, store.snapshot?.root.id == rootID,
                  investigator.recordID == id, investigator.capsule?.rootThreadID == rootID else { return }
            store.navigate(.investigation(id))
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LensL10n.text("Comprendre cette session")).font(LensUI.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(LensL10n.text("Posez une question, puis continuez la conversation. Vous pouvez joindre un appel, un diff ou un extrait avec le trombone."))
                .font(LensUI.readingFont(store.fontSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 10)
    }

    private var composer: some View {
        GeometryReader { available in
            VStack(alignment: .leading, spacing: 8) {
                // Expanded evidence, omissions and privacy stay scrollable in
                // this bounded region. They must not push the editor or Send
                // outside a narrow/short resizable chat column.
                ScrollView {
                    composerDetails.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(evidenceExpanded ? 180 : investigator.capsule == nil ? 24 : 50, max(24, available.size.height - 130)))
                    .accessibilityIdentifier("lens-chat-composer-details")
                VStack(alignment: .leading, spacing: 6) {
                    questionEditor
                    composerControls

                }.padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(questionFocused ? accent.color : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                    }
            }.padding(12)
        }.background(Color(nsColor: .textBackgroundColor))
    }

    // This row has no draft or reading state. Its identity refreshes cached
    // native control labels on a language change, leaving the editor mounted.
    private var composerControls: some View {
                HStack(spacing: 8) {
                    Menu {
                        Button(LensL10n.text("Ajouter la sélection affichée")) {
                            Task { if await store.prepareInvestigation() { evidenceExpanded = true; questionFocused = true } }
                        }.disabled(store.snapshot == nil || investigator.preparing || investigator.sending)
                        Menu(LensL10n.text("Préparer une question")) {
                            ForEach(LensChatPrompt.allCases, id: \.rawValue) { prompt in
                                Button(prompt.title) { investigator.prepareChatPrompt(prompt); questionFocused = true }
                            }
                        }.disabled(investigator.capsule?.pieces.isEmpty != false || investigator.sending || investigator.preparing
                            || investigator.responseComplete && investigator.codexChatID == nil)
                        if let capsule = investigator.capsule, !capsule.pieces.isEmpty {
                            Divider()
                            Button(LensL10n.text("Voir le contexte envoyé")) { openPayload(capsule) }
                        }
                    } label: {
                        Image(systemName: LensSymbols.name("paperclip")).frame(width: 24, height: 24)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(store.snapshot == nil || investigator.preparing || investigator.sending)
                        .help(LensL10n.text("Ajouter la sélection à la question, sans l’envoyer"))
                        .accessibilityLabel(LensL10n.text("Ajouter la sélection"))
                        .accessibilityIdentifier("lens-chat-add-selection")
                    modelControl
                    Image(systemName: LensSymbols.name(investigator.isCurrentDraftSaved ? "checkmark.circle" : "circle.dotted"))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                        .help(investigator.draftSaveLabel).accessibilityLabel(investigator.draftSaveLabel)
                    sendControl.fixedSize(horizontal: true, vertical: true)
                }
            .id("chat-controls-\(language):\(LensL10n.resolvedLanguage.rawValue)")
    }

    private var composerDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let capsule = investigator.capsule, !capsule.pieces.isEmpty {
                evidenceTray(capsule)
            } else {
                Text(LensL10n.text("Contexte : échanges de ce chat uniquement"))
                    .font(LensUI.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let removalNotice = investigator.evidenceRemovalNotice {
                HStack(alignment: .top, spacing: 6) {
                    Text(removalNotice).font(LensUI.metadata).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(LensL10n.text("Annuler le retrait")) { investigator.undoEvidenceRemoval() }
                        .disabled(!investigator.canUndoEvidenceRemoval)
                        .help(LensL10n.text("Restaurer l’élément et sa version enregistrée, sans relire le fichier actuel"))
                }
            }
            if let capsule = investigator.capsule, let requirement = sendRequirement(capsule) {
                Text(LensL10n.display(requirement)).font(LensUI.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.trailing, 2)
    }

    @ViewBuilder private var modelControl: some View {
        if investigator.connectionMode == .codex, let status = investigator.codexStatus, status.isChatGPT, !status.models.isEmpty {
            Menu {
                Picker(LensL10n.text("Modèle"), selection: $investigator.model) {
                    ForEach(status.models) { model in Text(model.displayName).tag(model.id) }
                }
                Divider()
                Button(LensL10n.text("Connexion et limites…")) { showConnectionSettings = true }
            } label: {
                Text(investigator.model.nonempty ?? LensL10n.text("Choisir un modèle"))
                    .font(LensUI.metadata).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton).disabled(investigator.sending || investigator.connecting)
                .help(LensL10n.text("Choisir le modèle Codex"))
                .accessibilityLabel(LensL10n.text("Modèle Codex : {0}", investigator.model))
                .accessibilityIdentifier("lens-chat-model-selector")
        } else {
            Text(connectionLabel).font(LensUI.metadata).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).help(connectionLabel)
        }
    }

    private var questionEditor: some View {
        ZStack(alignment: .topLeading) {
            LensChatInput(text: Binding(get: { investigator.responseComplete ? "" : investigator.question }, set: { investigator.editChatQuestion($0) }),
                fontSize: store.fontSize, enabled: !investigator.sending && !(investigator.responseComplete && investigator.codexChatID == nil),
                canSend: investigator.canSendChatMessage,
                label: LensL10n.text("Message ; Retour envoie, Majuscule-Retour ajoute une ligne"),
                focused: Binding(get: { questionFocused }, set: { questionFocused = $0 }), onSend: sendQuestion)
            if investigator.question.isEmpty || investigator.responseComplete {
                Text(investigator.responseComplete ? LensL10n.text(investigator.codexChatID == nil ? "Commencez une nouvelle question pour continuer." : "Posez une question de suivi…") : LensL10n.text("Posez votre question…"))
                    .font(LensUI.readingFont(store.fontSize)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.top, 7).allowsHitTesting(false).accessibilityHidden(true)
            }
        }.frame(minHeight: 43, maxHeight: .infinity)
    }

    private var connectionLabel: String {
        if investigator.connecting { return LensL10n.text("Vérification de Codex…") }
        if investigator.connectionReady { return investigator.model.nonempty ?? LensL10n.text("Connexion prête") }
        if investigator.connectionMode == .codex {
            return LensL10n.text(investigator.codexStatus?.authentication == "signedOut" ? "Connexion ChatGPT requise dans Codex" : "Codex local")
        }
        return LensL10n.text("Connexion requise")
    }

    private func evidenceTray(_ capsule: EvidenceCapsule) -> some View {
        DisclosureGroup(isExpanded: $evidenceExpanded) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let prepared = currentPresentation(capsule) {
                        Text(LensL10n.text("Texte joint : {0} · {1} worktrees", prepared.context.textBytes.formatted(.byteCount(style: .file)), String(prepared.context.environments.count)))
                            .font(LensUI.metadata).foregroundStyle(.secondary)
                        ForEach(prepared.context.sources) { source in draftSourceRow(source, capsule: capsule) }
                    } else { LensProgressIndicator(LensL10n.text("Préparation du contexte…")).controlSize(.small) }
                    HStack {
                        Text(LensL10n.text("Capture : {0}", capsule.collectionCut.formatted())).font(LensUI.metadata).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button(LensL10n.text("Voir le JSON")) { openPayload(capsule) }.buttonStyle(.borderless)
                            .disabled(capsule.pieces.isEmpty)
                            .help(LensL10n.text("Lire le JSON préparé ; aucun envoi"))
                    }
                    if !capsule.omissions.isEmpty {
                        DisclosureGroup(LensL10n.text("Éléments non inclus · {0}", String(capsule.omissions.count)), isExpanded: $omissionsExpanded) {
                            Text(capsule.omissions.map(\.reason).joined(separator: "\n"))
                                .font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled)
                        }.font(LensUI.metadata)
                    }
                }.padding(.top, 6).padding(.trailing, 4)
        } label: {
            HStack(spacing: 6) {
                Label(LensL10n.text("Contexte · {0}", String(capsule.pieces.count)), systemImage: LensSymbols.name("paperclip"))
                Spacer(minLength: 4)
                if evidenceExpanded, let prepared = currentPresentation(capsule) {
                    Text(LensL10n.text("{0} octets", String(prepared.encodedBytes))).foregroundStyle(.secondary)
                }
                if !capsule.omissions.isEmpty {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(LensAppearance.warningText)
                        .help(LensL10n.text("Certains éléments ne sont pas inclus ; dépliez le contexte pour les consulter."))
                        .accessibilityLabel(LensL10n.text("Contexte incomplet"))
                }
            }.font(LensUI.metadata)
        }.accessibilityIdentifier("lens-chat-evidence-tray")
    }

    private func draftSourceRow(_ source: ChatContextSource, capsule: EvidenceCapsule) -> some View {
        LensChatSourceRow(source: source, onOpen: { openSource(source.address) }) {
            Button { investigator.removePiece(source.address.pieceID) } label: { Image(systemName: "minus.circle").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).disabled(investigator.sending || investigator.preparing)
                .help(LensL10n.text("Retirer cet élément de la question ; vous pouvez annuler le retrait"))
                .accessibilityLabel(LensL10n.text("Retirer l’élément {0}", source.address.pieceID))
        }.contextMenu {
            Button(LensL10n.text("Lire cet élément")) { openSource(source.address) }
            Button(LensL10n.text("Copier le texte complet")) {
                if let piece = capsule.pieces.first(where: { $0.id == source.address.pieceID }) { store.copyLocalText(piece.text, notice: LensL10n.text("Texte copié")) }
            }
            Button(LensL10n.text("Copier le lien")) {
                store.copyLocalText(source.address.url.absoluteString, notice: LensL10n.text("Lien copié"))
            }
            if let eventID = source.eventID {
                Button(LensL10n.text("Ouvrir le contexte d’origine")) { store.navigate(.event(eventID), newTab: true) }
            }
        }
    }

    private func messageContext(_ context: ChatContextOverview, sent: Bool = true) -> some View {
        LensChatSourcesView(sources: context.sources, title: LensL10n.text(sent ? "Contexte envoyé · {0}" : "Contexte joint · {0}", String(context.sources.count)),
            canReuse: !investigator.sending && !investigator.preparing, onOpen: openSource, onReuse: reuseSource)
    }
    private func sourceList(_ sources: [ChatContextSource]) -> some View {
        LensChatSourcesView(sources: sources, title: LensL10n.text("Sources citées · {0}", String(sources.count)),
            canReuse: !investigator.sending && !investigator.preparing, onOpen: openSource, onReuse: reuseSource)
    }
    private func openSource(_ address: EvidenceAddress) { Task { await store.openEvidence(address) } }
    private func reuseSource(_ address: EvidenceAddress) {
        Task { await store.reuseChatSource(address); evidenceExpanded = true; questionFocused = true }
    }

    @ViewBuilder private var sendControl: some View {
        if investigator.sending {
            Button { investigator.cancel() } label: {
                Image(systemName: LensSymbols.name("stop.fill")).frame(width: 24, height: 24)
            }.buttonBorderShape(.circle)
                .lensChromeButton()
                .help(LensL10n.text("Arrêter la réception ; conserver la question et le contexte"))
                .accessibilityLabel(LensL10n.text("Arrêter"))
                .accessibilityIdentifier("lens-chat-stop")
        } else if !investigator.connectionReady {
            Button(LensL10n.text(investigator.connecting ? "Vérification…"
                : investigator.codexStatus?.isChatGPT == true ? "Choisir un modèle"
                : investigator.connectionMode == .codex && investigator.issue != nil ? "Réessayer"
                : investigator.connectionMode == .codex ? "Vérifier Codex" : "Configurer l’envoi…")) {
                if investigator.connectionMode == .codex, investigator.codexStatus?.isChatGPT != true { investigator.useLocalCodex() }
                else { showConnectionSettings = true }
            }
                .lensChromeButton(prominent: true).lensFilledControlAccent()
                .disabled(investigator.connecting)
                .help(LensL10n.text("Vérifier le Codex installé et sa connexion ChatGPT ; aucun message envoyé"))
        } else {
            Button { sendQuestion() } label: {
                Image(systemName: LensSymbols.name("arrow.up")).font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }.buttonBorderShape(.circle)
                .lensChromeButton(prominent: true).lensFilledControlAccent().keyboardShortcut(.return, modifiers: [.command])
                .disabled(sendDisabled).help(LensL10n.text("Envoyer · Retour ou ⌘Retour ; Majuscule-Retour ajoute une ligne"))
                .accessibilityLabel(LensL10n.text("Envoyer"))
                .accessibilityIdentifier("lens-chat-send")
        }
    }
    private var sendDisabled: Bool {
        !investigator.canSendChatMessage
    }
    private func sendQuestion() {
        guard !sendDisabled, !investigator.sending else { return }
        if windowContext?.hasMarkedText == true { investigator.issue = LensL10n.text("Terminez la saisie en cours avant d’envoyer la question.") }
        else { investigator.send() }
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LensL10n.text("Configurer l’envoi de cette enquête")).font(.headline)
            Picker(LensL10n.text("Connexion"), selection: $investigator.connectionMode) {
                Text(LensL10n.text("Connexion Codex locale")).tag(InvestigationConnectionMode.codex)
                Text(LensL10n.text("ChatGPT · forfait autorisé pour Lens")).tag(InvestigationConnectionMode.chatgpt)
                Text(LensL10n.text("API dédiée")).tag(InvestigationConnectionMode.api)
            }.pickerStyle(.menu).disabled(investigator.sending || investigator.connecting)
            if investigator.connectionMode == .codex {
                CodexLocalConnectionView(investigator: investigator)
            } else if investigator.connectionMode == .chatgpt {
                if let account = investigator.chatGPTAccount {
                    Label(account.email ?? LensL10n.text("Compte ChatGPT connecté"), systemImage: "person.crop.circle.badge.checkmark")
                    Text(account.canUseChatGPTPlan ? LensL10n.text("Forfait autorisé pour Lens") : LensL10n.text("Le compte n’a pas autorisé l’usage du forfait pour Lens")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(LensL10n.text("Déconnecter Lens")) { investigator.disconnectChatGPT() }.disabled(investigator.sending || investigator.connecting)
                        Button(LensL10n.text("Actualiser les modèles")) { investigator.refreshModels() }.disabled(investigator.connecting || investigator.sending)
                    }
                } else {
                    Text(LensL10n.text("Connectez le même compte que dans Codex. L’autorisation de Lens est indépendante : elle ne reprend aucune session et ne lit pas les secrets de Codex.")).font(.caption).foregroundStyle(.secondary)
                    Button(LensL10n.text("Continuer avec ChatGPT…")) { investigator.connectChatGPT() }.disabled(investigator.connecting)
                }
                if investigator.connecting { HStack { LensProgressIndicator(LensL10n.text("Connexion en cours…")); Button(LensL10n.text("Annuler")) { investigator.cancelConnection() } } }
                if !investigator.chatGPTModels.isEmpty {
                    Picker(LensL10n.text("Modèle disponible"), selection: $investigator.model) {
                        if !investigator.chatGPTModels.contains(where: { $0.id == investigator.model }) { Text(investigator.model.isEmpty ? LensL10n.text("Choisir un modèle") : investigator.model).tag(investigator.model) }
                        ForEach(investigator.chatGPTModels) { model in Text(model.displayName).tag(model.id) }
                    }
                } else {
                    Text(LensL10n.text("Actualisez le catalogue pour choisir un modèle autorisé par votre compte.")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(LensL10n.text("Clé API OpenAI dédiée")).font(.caption.weight(.medium))
                SecureField(LensL10n.text("Saisissez une clé API"), text: $investigator.apiKey).textFieldStyle(.roundedBorder).disabled(investigator.sending).focused($apiKeyFocused)
                    .accessibilityLabel(LensL10n.text("Clé API OpenAI dédiée")).help(LensL10n.text("Conservée en mémoire jusqu’à la fermeture de la fenêtre ; jamais sauvegardée"))
                ViewThatFits(in: .horizontal) { HStack { modelField; clearKeyButton }; VStack(alignment: .leading, spacing: 6) { modelField; clearKeyButton } }
                Text(LensL10n.text("La clé reste en mémoire. L’API peut être facturée séparément. Aucun envoi n’est déclenché par ces réglages.")).font(.caption).foregroundStyle(.secondary)
            }
            if let issue = investigator.issue { Text(LensL10n.display(issue)).foregroundStyle(LensAppearance.warningText).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button(LensL10n.text("Terminé")) { showConnectionSettings = false }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 480)
            .task { await investigator.refreshConnection(); apiKeyFocused = investigator.connectionMode == .api && investigator.apiKey.isEmpty }
    }
    private var modelField: some View {
        TextField(LensL10n.text("Saisissez un identifiant de modèle"), text: $investigator.model).textFieldStyle(.roundedBorder).disabled(investigator.sending)
            .accessibilityLabel(LensL10n.text("Identifiant du modèle API")).help(LensL10n.text("Identifiant d’un modèle disponible pour cette clé API"))
    }
    private var clearKeyButton: some View {
        Button(LensL10n.text("Effacer la clé")) { investigator.apiKey = "" }.disabled(investigator.sending || investigator.apiKey.isEmpty)
    }

    @ViewBuilder private func generatedResponse(_ capsule: EvidenceCapsule) -> some View {
        if let response = investigator.response {
            VStack(alignment: .leading, spacing: 8) {
                if let markdown = currentPresentation(capsule)?.markdownResponse, response.hasPrefix(markdown.source) {
                    LensChatMarkdownView(document: markdown, fontSize: store.fontSize,
                        onCopyCode: { store.copyLocalText($0, notice: LensL10n.text("Texte copié")) }, onOpenURL: openChatURL,
                        unformattedSuffix: String(response.dropFirst(markdown.source.count)),
                        speaker: investigator.connectionMode == .codex ? "Codex" : LensL10n.text("Assistant"),
                        onCopyMessage: { store.copyLocalText($0, notice: investigator.responseComplete ? LensL10n.text("Réponse complète copiée") : LensL10n.text("Réponse reçue jusqu’ici copiée")) }, sources: currentPresentation(capsule)?.citedSources ?? [])
                } else {
                HStack(alignment: .top) {
                    Text(investigator.connectionMode == .codex ? "Codex" : LensL10n.text("Assistant"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                    Text(response).font(LensUI.readingFont(store.fontSize)).lineSpacing(3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button(LensL10n.text("Copier la réponse")) { store.copyLocalText(response, notice: LensL10n.text("Texte copié")) }
                        }
                }
                if !investigator.responseComplete {
                    Label(LensL10n.text(investigator.sending ? "Réponse en cours…" : "Réponse partielle"),
                          systemImage: LensSymbols.name(investigator.sending ? "ellipsis" : "pause.circle"))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                }
                if capsule.pieces.isEmpty { EmptyView() }
                else if let prepared = currentPresentation(capsule), prepared.input.response == response {
                    citationLinks(capsule, validation: prepared.citations)
                } else {
                    Text(LensL10n.text("Vérification des citations…")).font(LensUI.metadata).foregroundStyle(.secondary)
                }
            }.id("lens-chat-response")
        } else if investigator.sending {
            LensProgressIndicator(LensL10n.text("Réponse en cours…")).id("lens-chat-response")
        }
    }
    private func sendRequirement(_ capsule: EvidenceCapsule) -> String? {
        if investigator.preparing { return LensL10n.text("Préparation du contexte… Attendez la fin pour envoyer.") }
        if investigator.sending { return LensL10n.text("Réponse en cours. La question et son contexte restent inchangés.") }
        if investigator.responseComplete { return nil }
        if investigator.connecting { return LensL10n.text("Connexion en cours ; vous pouvez l’annuler dans Configurer l’envoi.") }
        if !investigator.connectionReady { return nil }
        if investigator.model.isEmpty { return LensL10n.text("Choisissez un modèle dans Configurer l’envoi.") }
        if capsule.pieces.isEmpty, investigator.connectionMode != .codex { return LensL10n.text("Ajoutez un élément avant d’envoyer.") }
        return nil
    }
    private func currentPresentation(_ capsule: EvidenceCapsule) -> InvestigationPresentation? {
        guard let presentation, presentation.input.capsuleID == capsule.id, presentation.input.capsuleDigest == capsule.digestSHA256, presentation.input.rootID == capsule.rootThreadID else { return nil }
        return presentation
    }
    private func preparePresentation() async {
        guard let capsule = investigator.capsule, let input = presentationInput else { presentation = nil; presentationIssue = nil; return }
        do {
            let preparation = Task.detached(priority: .userInitiated) { try await InvestigationPresentationCache.shared.prepare(capsule: capsule, input: input) }
            let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
            guard !Task.isCancelled, input == presentationInput else { return }
            presentation = prepared; presentationIssue = nil
        } catch { if !Task.isCancelled, input == presentationInput { presentationIssue = error.localizedDescription } }
    }
    private func openEvidence(_ id: String, capsule: EvidenceCapsule) {
        guard let address = try? EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: id) else { return }
        Task { await store.openEvidence(address) }
    }
    private func openPayload(_ capsule: EvidenceCapsule) {
        store.showEvidenceJSON()
    }
    private func openChatURL(_ url: URL) {
        if url.scheme == "codexlens" { Task { await store.handleURL(url) } }
        else if ChatMarkdownParser.allowsExternalURL(url) {
            // An explicit link click is the only route to the external browser.
            NSWorkspace.shared.open(url)
        }
    }
    private func citationLinks(_ capsule: EvidenceCapsule, validation: CitationValidation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !validation.validIDs.isEmpty {
                if let prepared = currentPresentation(capsule) {
                    sourceList(prepared.citedSources).accessibilityIdentifier("lens-chat-response-sources")
                }
            }
            if investigator.responseComplete, !validation.invalidIDs.isEmpty {
                Text(LensL10n.text("Citations inconnues : {0}. Aucun lien disponible.", validation.invalidIDs.joined(separator: ", "))).foregroundStyle(LensAppearance.warningText)
            }
            if investigator.responseComplete, validation.validIDs.isEmpty { Text(LensL10n.text("Aucune citation vérifiable dans cette réponse.")).foregroundStyle(LensAppearance.warningText) }
        }.font(LensUI.metadata)
    }
}

/// The central destination shows the immutable captured evidence only. The
/// question and response remain in the side chat, preserving the reading space.
struct InvestigationEvidenceView: View {
    @EnvironmentObject var store: LensStore
    @ObservedObject var investigator: InvestigationStore
    @State private var technicalExpanded = false
    @State private var presentation: InvestigationPresentation?
    @State private var presentationIssue: String?
    private var wantsPayload: Bool { store.evidenceJSONVisible }
    private var presentationInput: InvestigationPresentationInput? {
        guard let capsule = store.displayedEvidenceCapsule else { return nil }
        return InvestigationPresentationInput(rootID: capsule.rootThreadID, capsuleID: capsule.id, capsuleDigest: capsule.digestSHA256,
            response: nil, question: wantsPayload && capsule.id == investigator.capsule?.id ? investigator.question : "", model: wantsPayload && capsule.id == investigator.capsule?.id ? investigator.model : "", includePayload: wantsPayload,
            connectionMode: investigator.connectionMode.rawValue, language: LensL10n.resolvedLanguage.rawValue)
    }
    private var selectedPiece: EvidencePiece? {
        guard let capsule = store.displayedEvidenceCapsule else { return nil }
        if case .evidence(let capsuleID, let pieceID) = store.selection, capsule.id == capsuleID {
            return capsule.pieces.first { $0.id == pieceID }
        }
        return capsule.pieces.first { $0.id == store.displayedEvidencePieceID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let capsule = store.displayedEvidenceCapsule {
                evidenceHeader(capsule)
                Divider()
                if let presentationIssue {
                    Label(presentationIssue, systemImage: LensSymbols.name("exclamationmark.triangle"))
                        .font(LensUI.metadata).foregroundStyle(LensAppearance.warningText).textSelection(.enabled).padding(10)
                }
                if wantsPayload {
                    payload(capsule)
                } else if let piece = selectedPiece {
                    EvidenceLinkView(reference: LensEvidenceReference(piece: piece, address: try? EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: piece.id)),
                        state: currentPresentation(capsule) == nil ? .unknown : .validated,
                        explanation: LensL10n.text("Contenu enregistré ; le fichier actuel n’est pas relu."), onOpen: { _ in openEvidence(piece.id, capsule: capsule) })
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    CodeDocumentView(text: piece.text, path: "captured-evidence-\(piece.id).txt",
                        versionLabel: LensL10n.text("Extrait enregistré · lignes de l’extrait · ") + (piece.knownVersion ?? LensL10n.text("Trace capturée {0}", piece.capturedAt.formatted())),
                        fontSize: store.fontSize, codeFont: store.codeFont)
                } else {
                    Text(LensL10n.text("Sélectionnez un élément pour lire son contenu.")).foregroundStyle(.secondary).padding(20)
                    Spacer()
                }
            } else {
                ContentUnavailableView(LensL10n.text("Contenu indisponible"), systemImage: LensSymbols.name("doc.text"),
                    description: Text(LensL10n.text("Le contexte n’est pas accessible. Ouvrez une enquête dans Archives locales.")))
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .task(id: presentationInput) { await preparePresentation() }
            .accessibilityIdentifier("lens-investigation-evidence")
    }
    private func evidenceHeader(_ capsule: EvidenceCapsule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(LensL10n.text("Contexte"), systemImage: LensSymbols.name("doc.text")).font(.headline)
                Spacer(minLength: 8)
                Menu(LensL10n.text("Contexte · {0}", String(capsule.pieces.count))) {
                    ForEach(capsule.pieces) { piece in
                        Button(LensL10n.text("[{0}] {1}", piece.id, piece.title)) { openEvidence(piece.id, capsule: capsule) }
                    }
                }.disabled(capsule.pieces.isEmpty)
                Button(wantsPayload ? LensL10n.text("Lire le contenu") : LensL10n.text("Voir le JSON")) {
                    if wantsPayload, let first = capsule.pieces.first { openEvidence(first.id, capsule: capsule) }
                    else { store.evidenceJSONVisible = true }
                }.help(LensL10n.text("Lire le JSON préparé ; aucun envoi"))
            }
            DisclosureGroup(LensL10n.text("Capture : {0}", capsule.collectionCut.formatted()), isExpanded: $technicalExpanded) {
                Text(LensL10n.text("Session : {0}\nContexte : {1}\nSHA-256 : {2}", capsule.rootThreadID, capsule.id, capsule.digestSHA256))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
                Button(LensL10n.text("Copier le SHA-256")) { store.copyLocalText(capsule.digestSHA256, notice: LensL10n.text("SHA-256 copié")) }
                if !capsule.omissions.isEmpty {
                    Text(capsule.omissions.map(\.reason).joined(separator: "\n")).foregroundStyle(LensAppearance.warningText).textSelection(.enabled)
                }
            }.font(LensUI.metadata).foregroundStyle(.secondary)
        }.padding(10)
    }
    @ViewBuilder private func payload(_ capsule: EvidenceCapsule) -> some View {
        if let prepared = currentPresentation(capsule), prepared.input == presentationInput, let payload = prepared.payload {
            if let issue = prepared.payloadIssue {
                Label(LensL10n.display(issue), systemImage: LensSymbols.name("info.circle")).font(LensUI.metadata).foregroundStyle(.secondary).padding(10)
            }
            CodeDocumentView(text: payload, path: prepared.payloadIsRequest ? "request.json" : "capsule.json",
                versionLabel: prepared.payloadIsRequest ? LensL10n.text("Requête préparée · sans clé API") : LensL10n.text("Contexte · requête non préparée"),
                fontSize: store.fontSize, codeFont: store.codeFont)
        } else {
            LensLoadingState(title: LensL10n.text("Préparation du JSON…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func currentPresentation(_ capsule: EvidenceCapsule) -> InvestigationPresentation? {
        guard let presentation, presentation.input.capsuleID == capsule.id, presentation.input.capsuleDigest == capsule.digestSHA256, presentation.input.rootID == capsule.rootThreadID else { return nil }
        return presentation
    }
    private func preparePresentation() async {
        guard let capsule = store.displayedEvidenceCapsule, let input = presentationInput else { presentation = nil; presentationIssue = nil; return }
        do {
            if input.includePayload { try await Task.sleep(nanoseconds: 80_000_000) }
            let preparation = Task.detached(priority: .userInitiated) { try await InvestigationPresentationCache.shared.prepare(capsule: capsule, input: input) }
            let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
            guard !Task.isCancelled, input == presentationInput else { return }
            presentation = prepared; presentationIssue = nil
        } catch { if !Task.isCancelled, input == presentationInput { presentationIssue = error.localizedDescription } }
    }
    private func openEvidence(_ id: String, capsule: EvidenceCapsule) {
        guard let address = try? EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: id) else { return }
        store.evidenceJSONVisible = false
        Task { await store.openEvidence(address) }
    }
}

enum InvestigationEvidenceLabels {
    static func label(_ kind: String) -> String {
        switch kind {
        case "collectionManifest": return LensL10n.text("Session et limites de collecte")
        case "resourceMetadata": return LensL10n.text("Provenance de la ressource")
        case "environmentMetadata": return LensL10n.text("Environnement enregistré")
        case "codeSelection", "capturedCurrentCode": return LensL10n.text("Extrait du fichier actuel capturé")
        case "verifiedHistoricalCode": return LensL10n.text("Version Git vérifiée")
        case "verifiedReconstructedCode": return LensL10n.text("Version reconstruite vérifiée")
        case "toolCall": return LensL10n.text("Appel d’outil enregistré")
        case "toolResult": return LensL10n.text("Résultat d’outil enregistré")
        case "recordedDiff", "recordedPatch": return LensL10n.text("Diff enregistré")
        case "currentGitDiff": return LensL10n.text("Diff Git courant capturé")
        case "originEvidence": return LensL10n.text("Origine et consignes associées")
        case "user", "userMessage": return LensL10n.text("Message utilisateur")
        case "assistant", "assistantMessage": return LensL10n.text("Réponse enregistrée")
        case "instruction": return LensL10n.text("Instruction enregistrée")
        case "delegation": return LensL10n.text("Délégation enregistrée")
        case "wait": return LensL10n.text("Attente enregistrée")
        case "error": return LensL10n.text("Erreur enregistrée")
        case "context": return LensL10n.text("Contexte enregistré")
        case "lifecycle": return LensL10n.text("État de la session")
        case "input", "arguments": return LensL10n.text("Entrée enregistrée")
        case "output", "result": return LensL10n.text("Sortie enregistrée")
        case "content": return LensL10n.text("Message enregistré")
        case "raw": return LensL10n.text("Événement brut")
        default: return LensL10n.text("Trace enregistrée")
        }
    }
}

struct InvestigationTranscriptSelection: Hashable, Sendable {
    let rootID: String
    let chatID: String
    let currentRecordID: String?
    let currentCreatedAt: Date?
    let recordIDs: [String]
    let language: String
}
struct InvestigationTranscriptExchange: Identifiable, Sendable {
    let id: String
    let createdAt: Date
    let question: String
    let linkedResponse: AttributedString
    let markdownResponse: ChatMarkdownDocument
    let validCitationIDs: [String]
    let invalidCitationIDs: [String]
    let hasAttachedContext: Bool
    let context: ChatContextOverview
    let citedSources: [ChatContextSource]
    let retainedBytes: Int
}
struct InvestigationTranscriptUnavailable: Identifiable, Sendable {
    let id: String
    let reason: String
}
struct InvestigationTranscriptPage: Sendable {
    let exchanges: [InvestigationTranscriptExchange]
    let unavailable: [InvestigationTranscriptUnavailable]
    let nextOffset: Int
    let hasMore: Bool
}
/// Read at most twelve archive candidates per page. Only exact local chat IDs
/// join exchanges; shared repositories, timestamps and capsules create no link.
/// Full oversized text remains in its archive, with a visible open action.
actor InvestigationTranscriptReader {
    static let shared = InvestigationTranscriptReader()
    static let retainedTextBudget = 2 * 1024 * 1024
    func read(archive: InvestigationArchive, selection: InvestigationTranscriptSelection, offset: Int, retainedBytes: Int) async throws -> InvestigationTranscriptPage {
        let start = min(max(0, offset), selection.recordIDs.count), end = min(start + 12, selection.recordIDs.count)
        var exchanges: [InvestigationTranscriptExchange] = [], unavailable: [InvestigationTranscriptUnavailable] = []
        var remaining = max(0, Self.retainedTextBudget - retainedBytes)
        for id in selection.recordIDs[start..<end] {
            try Task.checkCancellation()
            guard id != selection.currentRecordID else { continue }
            do {
                guard let record = try await archive.load(id: id), record.codexChatID == selection.chatID,
                      record.capsule.rootThreadID == selection.rootID, let response = record.response else { continue }
                if let boundary = selection.currentCreatedAt, record.createdAt >= boundary { continue }
                // Conservative estimated text/attribute budget; never shorten an exchange to fit.
                let textBytes = record.question.utf8.count + response.utf8.count
                let weighted = textBytes.multipliedReportingOverflow(by: 4)
                guard !weighted.overflow, remaining >= 4096, weighted.partialValue <= remaining - 4096 else {
                    unavailable.append(InvestigationTranscriptUnavailable(id: id, reason: LensL10n.text("Budget d’affichage atteint ; le texte complet reste dans l’archive."))); continue
                }
                let input = InvestigationPresentationInput(rootID: record.capsule.rootThreadID, capsuleID: record.capsule.id,
                    capsuleDigest: record.capsule.digestSHA256, response: response, question: "", model: "", includePayload: false,
                    connectionMode: "codex", language: selection.language)
                let presentation = try await InvestigationPresentationCache.shared.prepare(capsule: record.capsule, input: input)
                try Task.checkCancellation()
                let linked = presentation.linkedResponse ?? AttributedString(response)
                guard let markdown = presentation.markdownResponse else { throw LensError.corrupt("Présentation Markdown indisponible.") }
                let added = (weighted.partialValue + 4096 + presentation.context.estimatedRetainedBytes).addingReportingOverflow(markdown.estimatedRetainedBytes)
                var weight = added.overflow ? Int.max : added.partialValue
                for run in linked.runs {
                    if let url = run.link {
                        let increased = weight.addingReportingOverflow(url.absoluteString.utf8.count + 512)
                        weight = increased.overflow ? Int.max : increased.partialValue
                    }
                }
                guard weight <= remaining else {
                    unavailable.append(InvestigationTranscriptUnavailable(id: id, reason: LensL10n.text("Budget d’affichage atteint ; le texte complet reste dans l’archive."))); continue
                }
                exchanges.append(InvestigationTranscriptExchange(id: record.id, createdAt: record.createdAt, question: record.question,
                    linkedResponse: linked, markdownResponse: markdown, validCitationIDs: presentation.citations.validIDs,
                    invalidCitationIDs: presentation.citations.invalidIDs, hasAttachedContext: !record.capsule.pieces.isEmpty,
                    context: presentation.context, citedSources: presentation.citedSources, retainedBytes: weight))
                remaining -= weight
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable.append(InvestigationTranscriptUnavailable(id: id, reason: error.localizedDescription)) }
        }
        return InvestigationTranscriptPage(exchanges: exchanges, unavailable: unavailable, nextOffset: end, hasMore: end < selection.recordIDs.count)
    }
}

struct InvestigationPresentationInput: Hashable, Sendable {
    let rootID: String
    let capsuleID: String
    let capsuleDigest: String
    let response: String?
    let question: String
    let model: String
    let includePayload: Bool
    var connectionMode: String = "api"
    var language: String = "fr"
}

struct InvestigationPresentation: Sendable {
    let context: ChatContextOverview
    let citedSources: [ChatContextSource]
    let input: InvestigationPresentationInput
    let encodedBytes: Int
    let linkedResponse: AttributedString?
    let markdownResponse: ChatMarkdownDocument?
    let citations: CitationValidation
    let payload: String?
    let payloadIsRequest: Bool
    let payloadIssue: String?
    let preparedOffMainThread: Bool
}

/// At most four prepared representations and 2 MiB of estimated retained text.
/// Validation happens before every cache lookup; declared hashes alone never establish trust.
actor InvestigationPresentationCache {
    static let shared = InvestigationPresentationCache()
    private struct Key: Hashable {
        let rootID: String, capsuleID: String, capsuleDigest: String, responseDigest: String, questionDigest: String, model: String
        let includePayload: Bool
        let connectionMode: String, language: String
    }
    private var values: [Key: (InvestigationPresentation, Int)] = [:]
    private var order: [Key] = []
    private var retainedBytes = 0
    var retainedRepresentationCount: Int { values.count }
    var estimatedRetainedBytes: Int { retainedBytes }

    func prepare(capsule: EvidenceCapsule, input: InvestigationPresentationInput) throws -> InvestigationPresentation {
        let span = LensSignposts.begin("RenderCitation"); defer { span.end() }
        try Task.checkCancellation()
        guard capsule.id == input.capsuleID, capsule.rootThreadID == input.rootID, capsule.digestSHA256 == input.capsuleDigest, try capsule.verifyDigest() else { throw LensError.unavailable(LensL10n.text("L’empreinte du contexte est invalide ; les liens de citation sont désactivés.")) }
        let response = input.response ?? ""
        let key = Key(rootID: input.rootID, capsuleID: input.capsuleID, capsuleDigest: input.capsuleDigest, responseDigest: digest(response), questionDigest: digest(input.question), model: input.model, includePayload: input.includePayload, connectionMode: input.connectionMode, language: input.language)
        if let cached = values[key] { order.removeAll { $0 == key }; order.append(key); return cached.0 }
        let encoded = try capsule.transmissionJSON()
        let citations = capsule.validateCitations(in: response), validIDs = Set(capsule.pieces.map(\.id))
        var linked = AttributedString(response)
        let text = response as NSString
        let expression = try NSRegularExpression(pattern: #"\[(E[A-Za-z0-9_-]{1,32})\]"#)
        var linkedAttributeBytes = 0
        for match in expression.matches(in: response, range: NSRange(location: 0, length: text.length)) {
            try Task.checkCancellation()
            let id = text.substring(with: match.range(at: 1))
            guard validIDs.contains(id), let address = try? EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: id),
                  let range = Range(match.range, in: response), let attributedRange = Range(range, in: linked) else { continue }
            // One verified immutable capsule and its ID index cover all occurrences.
            // Navigation still resolves the address against its archive before opening it.
            linked[attributedRange].link = address.url
            linkedAttributeBytes = boundedSum([linkedAttributeBytes, address.url.absoluteString.utf8.count, 512])
        }
        let evidenceLinks = Dictionary(capsule.pieces.compactMap { piece -> (String, URL)? in
            guard let address = try? EvidenceAddress(rootID: capsule.rootThreadID, capsuleID: capsule.id, pieceID: piece.id) else { return nil }
            return (piece.id, address.url)
        }, uniquingKeysWith: { first, _ in first })
        let markdownSpan = LensSignposts.begin("RenderMarkdown"); defer { markdownSpan.end() }
        let markdown = input.response == nil ? nil : try ChatMarkdownParser.parse(response, evidenceLinks: evidenceLinks,
            imageReferenceLabel: input.language == "en" ? "Image reference:" : "Référence d’image :")
        var payload: String?, payloadIssue: String?, payloadIsRequest = false
        if input.includePayload {
            do {
                let body = try input.connectionMode == "codex" ? CodexInvestigationEngine.evidenceInput(capsule: capsule, question: input.question, model: input.model) : input.connectionMode == "chatgpt" ? CodexInvestigationClient.requestBody(capsule: capsule, question: input.question, model: input.model, language: input.language == "en" ? .english : .french) : InvestigationClient.requestBody(capsule: capsule, question: input.question, model: input.model)
                let object = try JSONSerialization.jsonObject(with: body)
                payload = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
                payloadIsRequest = true
            } catch {
                payload = String(decoding: encoded, as: UTF8.self)
                payloadIssue = "Contexte : " + error.localizedDescription
            }
        }
        let context = try ChatContextOverview(capsule: capsule)
        let citedIDs = Set(citations.validIDs)
        let prepared = InvestigationPresentation(context: context, citedSources: context.sources.filter { citedIDs.contains($0.address.pieceID) }, input: input, encodedBytes: encoded.count, linkedResponse: input.response == nil ? nil : linked, markdownResponse: markdown, citations: citations, payload: payload, payloadIsRequest: payloadIsRequest, payloadIssue: payloadIssue, preparedOffMainThread: !Thread.isMainThread)
        // Conservative logical retention budget, including the input, key and linked attributes.
        // Oversized/overflowing representations remain readable but are never retained here.
        let weight = boundedSum([encoded.count, response.utf8.count, response.utf8.count,
            input.question.utf8.count, input.model.utf8.count, input.rootID.utf8.count, input.rootID.utf8.count,
            input.capsuleID.utf8.count, input.capsuleID.utf8.count, input.capsuleDigest.utf8.count, input.capsuleDigest.utf8.count,
            (payload?.utf8.count ?? 0), linkedAttributeBytes, markdown?.estimatedRetainedBytes ?? 0,
            context.estimatedRetainedBytes * 2, 1024])
        if weight <= 2 * 1024 * 1024 {
            while values.count >= 4 || retainedBytes + weight > 2 * 1024 * 1024, let oldest = order.first {
                order.removeFirst(); if let removed = values.removeValue(forKey: oldest) { retainedBytes -= removed.1 }
            }
            values[key] = (prepared, weight); order.append(key); retainedBytes += weight
        }
        return prepared
    }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func boundedSum(_ values: [Int]) -> Int {
        var total = 0
        for value in values { let next = total.addingReportingOverflow(value); if next.overflow { return .max }; total = next.partialValue }
        return total
    }
}
