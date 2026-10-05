import SwiftUI
import AppKit
import LensCore

/// Native, explicit recovery sheet. Opening returns a new present-day observation,
/// without replacing the historical resource or inventing its missing bytes.
struct ResourceRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    let resource: ResourceRecord
    let onOpen: (ResourceRecoveryCandidate) -> Void
    @StateObject private var model: ResourceRecoveryViewModel

    init(resource: ResourceRecord, roots: [ResourceRecoveryRoot], recordedDigest: ResourceRecoveryRecordedDigest? = nil, onOpen: @escaping (ResourceRecoveryCandidate) -> Void) {
        self.resource = resource; self.onOpen = onOpen
        _model = StateObject(wrappedValue: ResourceRecoveryViewModel(resource: resource, roots: roots, recordedDigest: recordedDigest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(LensL10n.text("Retrouver une pièce jointe"), systemImage: "doc.viewfinder").font(.title2.bold())
                Text(resource.name).font(.headline).textSelection(.enabled)
                Text(resource.location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text(LensL10n.text("Un fichier retrouvé reste une version locale observée maintenant. Son nom ne prouve pas qu’il s’agit des octets fournis à l’époque."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18)
            Divider()
            VSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(LensL10n.text("Dossiers de recherche")).font(.headline)
                        Spacer()
                        Button(LensL10n.text("Ajouter un dossier…"), systemImage: "folder.badge.plus", action: model.chooseFolder).disabled(model.busy)
                    }
                    if model.roots.isEmpty { Text(LensL10n.text("Ajoutez un dossier précis ou choisissez directement un fichier.")).foregroundStyle(.secondary) }
                    List(model.roots) { root in
                        Toggle(isOn: Binding(get: { model.enabledRootIDs.contains(root.id) }, set: { enabled in model.setRoot(root.id, enabled: enabled) })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(root.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(root.path)
                            Text(LensL10n.display(root.reason)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled(model.busy)
                    }.listStyle(.plain)
                    HStack {
                        Button(LensL10n.text("Rechercher dans ces dossiers"), systemImage: "magnifyingglass", action: model.search).disabled(model.busy || model.enabledRootIDs.isEmpty)
                        Button(LensL10n.text("Choisir un fichier…"), systemImage: "doc", action: model.chooseFile).disabled(model.busy)
                        Spacer()
                        if model.busy { LensProgressIndicator(accessibilityLabel: LensL10n.text("Recherche de fichiers dans les dossiers choisis")).controlSize(.small); Button(LensL10n.text("Annuler"), action: model.cancelSearch) }
                    }
                    Text(LensL10n.text("Recherche limitée : 12 000 entrées, 4 secondes, 96 Mio lus. Les liens, fichiers d’authentification et octets non téléchargés sont exclus."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(minHeight: 145, idealHeight: 180)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(LensL10n.text("Fichiers candidats")).font(.headline)
                        Spacer()
                        Text(model.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.candidates.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: model.didSearch ? "doc.questionmark" : "doc.viewfinder").font(.title2).foregroundStyle(.secondary)
                            Text(model.busy ? LensL10n.text("Recherche de fichiers en cours…") : model.didSearch ? LensL10n.text("Aucun candidat trouvé dans les dossiers consultés.") : LensL10n.text("Lancez une recherche ou choisissez un fichier.")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $model.selectedID) {
                            ForEach(model.candidates) { candidate in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Image(systemName: candidate.confidence == .recordedDigest ? "checkmark.seal" : "doc").accessibilityHidden(true)
                                        Text(URL(fileURLWithPath: candidate.path).lastPathComponent).font(.headline).lineLimit(1)
                                        Spacer()
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(candidate.byteCount), countStyle: .file)).font(.caption)
                                    }
                                    Text(LensL10n.display(candidate.confidence.label)).font(.caption).foregroundStyle(.secondary)
                                    Text(candidate.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(candidate.path)
                                    Text(LensL10n.text("Modifié : {0} · Observé : {1}", String(describing: candidate.modifiedAt.lensFormatted(date: .abbreviated, time: .shortened)), String(describing: candidate.observedAt.lensFormatted(date: .abbreviated, time: .standard))))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 5).tag(candidate.id)
                                    .contextMenu {
                                        Button(LensL10n.text("Copier le chemin")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(candidate.path, forType: .string) }
                                        Button(LensL10n.text("Copier l’empreinte SHA-256")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(candidate.sha256, forType: .string) }
                                    }
                            }
                        }.listStyle(.plain)
                    }
                    if let selected = model.selected {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LensL10n.text("SHA-256 observé : {0}", String(describing: selected.sha256))).font(.caption.monospaced()).textSelection(.enabled)
                            if let recorded = selected.recordedDigest { Text(LensL10n.text("Empreinte SHA-256 : {0}", String(describing: recorded.evidence))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                    if !model.issues.isEmpty {
                        DisclosureGroup(LensL10n.text("Couverture de la recherche · {0} limites", String(describing: model.issues.count))) {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(model.issues) { issue in Text(LensL10n.display(issue.message) + (issue.path.isEmpty ? "" : "\n" + issue.path)).font(.caption).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 90)
                        }.font(.caption)
                    }
                    if let issue = model.issue { Label(LensL10n.display(issue), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(14).frame(minHeight: 190)
            }
            Divider()
            HStack {
                Button(LensL10n.text("Fermer")) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(LensL10n.text("Ouvrir cette version locale")) {
                    model.openSelected { candidate in onOpen(candidate); dismiss() }
                }.disabled(model.selected == nil || model.busy).keyboardShortcut(.defaultAction)
            }.padding(14)
        }.frame(minWidth: 620, idealWidth: 740, minHeight: 530, idealHeight: 650)
            .onDisappear { model.stop() }
    }
}

@MainActor
private final class ResourceRecoveryViewModel: ObservableObject {
    @Published var roots: [ResourceRecoveryRoot]
    @Published var enabledRootIDs: Set<String>
    @Published var candidates: [ResourceRecoveryCandidate] = []
    @Published var selectedID: String?
    @Published var issues: [ResourceRecoveryIssue] = []
    @Published var busy = false
    @Published var issue: String?
    @Published var didSearch = false
    @Published var summary = ""
    private let resource: ResourceRecord
    private let recordedDigest: ResourceRecoveryRecordedDigest?
    private let service = ResourceRecoveryService()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var panel: NSOpenPanel?
    var selected: ResourceRecoveryCandidate? { candidates.first { $0.id == selectedID } }

    init(resource: ResourceRecord, roots: [ResourceRecoveryRoot], recordedDigest: ResourceRecoveryRecordedDigest?) {
        self.resource = resource; self.roots = roots; self.recordedDigest = recordedDigest
        enabledRootIDs = Set(roots.map(\.id))
    }
    func setRoot(_ id: String, enabled: Bool) { if enabled { enabledRootIDs.insert(id) } else { enabledRootIDs.remove(id) } }
    func cancel() { generation &+= 1; task?.cancel(); task = nil; busy = false }
    func cancelSearch() { cancel(); summary = candidates.isEmpty ? LensL10n.text("Recherche annulée") : LensL10n.text("Recherche annulée · candidats précédents conservés") }
    func stop() { cancel(); panel?.cancel(nil); panel = nil }
    func search() {
        cancel(); busy = true; issue = nil
        let identity = generation, scopes = roots.filter { enabledRootIDs.contains($0.id) }
        task = Task {
            do {
                let report = try await service.search(resource: resource, roots: scopes, recordedDigest: recordedDigest)
                guard !Task.isCancelled, generation == identity else { return }
                candidates = report.candidates
                if !candidates.contains(where: { $0.id == selectedID }) { selectedID = nil }
                issues = report.issues; didSearch = true
                summary = LensL10n.text("{0} candidats · {1} entrées consultées", String(describing: report.candidates.count), String(describing: report.inspectedEntries)) + (report.wasLimited ? LensL10n.text(" · recherche partielle") : "")
            } catch { if !Task.isCancelled, generation == identity { issue = error.localizedDescription } }
            guard generation == identity else { return }; busy = false; task = nil
        }
    }
    func chooseFolder() {
        let dialog = NSOpenPanel(); panel = dialog
        dialog.title = LensL10n.text("Choisir un dossier de recherche"); dialog.canChooseDirectories = true; dialog.canChooseFiles = false; dialog.allowsMultipleSelection = false
        dialog.begin { [weak self] response in
            guard let self else { return }; self.panel = nil
            guard response == .OK, let url = dialog.url else { return }
            let root = ResourceRecoveryRoot(path: url.path, reason: LensL10n.text("Dossier choisi explicitement"))
            if !self.roots.contains(where: { $0.id == root.id }) { self.roots.append(root) }
            self.enabledRootIDs.insert(root.id)
        }
    }
    func chooseFile() {
        let dialog = NSOpenPanel(); panel = dialog
        dialog.title = LensL10n.text("Choisir une version locale"); dialog.canChooseDirectories = false; dialog.canChooseFiles = true; dialog.allowsMultipleSelection = false; dialog.resolvesAliases = false
        dialog.begin { [weak self] response in
            guard let self else { return }; self.panel = nil
            guard response == .OK, let url = dialog.url else { return }
            self.inspectFile(url.path)
        }
    }
    private func inspectFile(_ path: String) {
        cancel(); busy = true; issue = nil
        let identity = generation
        task = Task {
            do {
                let candidate = try await service.inspectChosenFile(resource: resource, path: path, recordedDigest: recordedDigest)
                guard !Task.isCancelled, generation == identity else { return }
                if !candidates.contains(where: { $0.id == candidate.id }) { candidates.append(candidate) }
                selectedID = candidate.id; didSearch = true; summary = LensL10n.text("Version choisie explicitement")
            } catch { if !Task.isCancelled, generation == identity { issue = error.localizedDescription } }
            guard generation == identity else { return }; busy = false; task = nil
        }
    }
    func openSelected(_ completion: @escaping (ResourceRecoveryCandidate) -> Void) {
        guard let selected else { return }
        cancel(); busy = true; issue = nil
        let identity = generation
        task = Task {
            do {
                let verified = try await service.validate(selected)
                guard !Task.isCancelled, generation == identity else { return }
                busy = false; task = nil; completion(verified)
            } catch {
                guard !Task.isCancelled, generation == identity else { return }
                issue = error.localizedDescription; busy = false; task = nil
            }
        }
    }
}
