import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation
import LensCore

/// Lexical paths preserve worktree/symlink identity. Availability and external opens
/// are validated separately against the actual local target; no path adds a version.
struct NativeFileLocation: Hashable {
    let path: String
    var worktreeRoot: String? = nil
    var line: Int? = nil
    var absolutePath: String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    var relativePath: String? {
        guard let absolutePath, let worktreeRoot, worktreeRoot.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.path
        if absolutePath == root { return "." }
        let prefix = root == "/" ? "/" : root + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        return String(absolutePath.dropFirst(prefix.count))
    }
    var fileLine: String? {
        guard let absolutePath, let line, line >= 1 else { return nil }
        return absolutePath + ":" + String(line)
    }
    static func localPath(_ recordedLocation: String) -> String? {
        if recordedLocation.hasPrefix("/") { return NativeFileLocation(path: recordedLocation).absolutePath }
        guard let url = URL(string: recordedLocation), url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost", url.query == nil, url.fragment == nil else { return nil }
        return NativeFileLocation(path: url.path).absolutePath
    }
    static func lineNumber(in text: String, atUTF16Offset offset: Int) -> Int? {
        guard offset >= 0, offset <= (text as NSString).length else { return nil }
        var iterator = text.utf16.makeIterator()
        var line = 1, previousCR = false
        var previousUnit: UInt16?
        for _ in 0..<offset {
            guard let unit = iterator.next() else { return nil }
            if unit == 13 || unit == 0x2028 || unit == 0x2029 { line += 1 }
            else if unit == 10, !previousCR { line += 1 }
            previousCR = unit == 13; previousUnit = unit
        }
        // AppKit offsets are UTF-16; reject a coordinate splitting a surrogate pair.
        if let previousUnit, (0xD800...0xDBFF).contains(previousUnit), let next = iterator.next(), (0xDC00...0xDFFF).contains(next) { return nil }
        return line
    }
}

struct NativeDocumentApplication: Identifiable {
    let url: URL
    let name: String
    var id: String { url.path }
}

/// A current file target is resolved in the recorded environment, never from the
/// app's working directory or from another worktree with a matching filename.
enum NativeDiffFileTarget {
    static func path(file: RecordedFileDiff, environment: EnvironmentRecord?) -> String? {
        guard let environment, file.provenance.environmentID == environment.id,
              let root = NativeFileLocation(path: environment.path).absolutePath,
              !file.path.isEmpty, !file.path.contains("\0"), !file.path.contains("://"), file.path != "/dev/null" else { return nil }
        let candidate = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : URL(fileURLWithPath: root).appendingPathComponent(file.path)
        let path = candidate.standardizedFileURL.path
        // macOS records both spellings of its temporary directory. Comparison
        // is lexical: do not resolve symlinks or perform I/O while rendering.
        func comparable(_ value: String) -> String {
            if value == "/tmp" { return "/private/tmp" }
            return value.hasPrefix("/tmp/") ? "/private" + value : value
        }
        let base = comparable(root), target = comparable(path)
        guard target != base, target.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
        return path
    }
}

/// Readers/editors only. Registered shell/interpreter handlers are never used to
/// open a file, even when Launch Services advertises them as compatible.
enum NativeDocumentApplicationPolicy {
    static func permits(bundleID: String?, name: String, documentTypes: [[String: Any]], fileType: UTType?, extension fileExtension: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let identity = (bundleID + " " + name).lowercased()
        let runners = ["terminal", "iterm", "pythonlauncher", "python launcher", "script editor", "scripteditor", "automator", "powershell", "warp-terminal", "kitty", "alacritty", "wezterm"]
        guard !runners.contains(where: identity.contains), bundleID.lowercased() != "com.apple.finder" else { return false }
        return documentTypes.contains { document in
            guard let role = document["CFBundleTypeRole"] as? String, ["editor", "viewer"].contains(role.lowercased()) else { return false }
            let identifiers = document["LSItemContentTypes"] as? [String] ?? []
            let extensions = document["CFBundleTypeExtensions"] as? [String] ?? []
            if let fileType, identifiers.contains(where: { UTType($0).map { fileType.conforms(to: $0) } ?? false }) { return true }
            return extensions.contains { $0 == "*" || $0.caseInsensitiveCompare(fileExtension) == .orderedSame }
        }
    }
    static func permitsFile(type: UTType?, isExecutable: Bool, extension fileExtension: String) -> Bool {
        guard !isExecutable, !["app", "command", "tool", "workflow", "scptd"].contains(fileExtension.lowercased()) else { return false }
        return type.map { !$0.conforms(to: .executable) && !$0.conforms(to: .applicationBundle) } ?? true
    }
}

@MainActor
private enum NativeFileAccess {
    static func document(_ path: String, files: FileService) async throws -> URL {
        let url = try await files.previewURL(path: path)
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .isExecutableKey])
        guard let isExecutable = values.isExecutable else { throw LensError.unavailable(LensL10n.text("Droits d’exécution du fichier actuel inconnus ; ouverture externe refusée.")) }
        guard NativeDocumentApplicationPolicy.permitsFile(type: values.contentType, isExecutable: isExecutable, extension: url.pathExtension) else {
            throw LensError.unsupported(LensL10n.text("Ouverture externe refusée pour une application, un exécutable ou un fichier de lancement. Le code reste consultable dans Lens."))
        }
        return url
    }
    static func applications(for url: URL) throws -> [NativeDocumentApplication] {
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { application in
            guard seen.insert(application.path).inserted, let bundle = Bundle(url: application) else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? application.deletingPathExtension().lastPathComponent
            let documents = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
            guard NativeDocumentApplicationPolicy.permits(bundleID: bundle.bundleIdentifier, name: name, documentTypes: documents, fileType: type, extension: url.pathExtension) else { return nil }
            return NativeDocumentApplication(url: application, name: name)
        }
    }
    static func open(path: String, application: URL, files: FileService, isCurrent: @MainActor () -> Bool) async throws {
        let url = try await document(path, files: files)
        guard try applications(for: url).contains(where: { $0.url.standardizedFileURL.path == application.standardizedFileURL.path }) else { throw LensError.unavailable(LensL10n.text("Cette application ne se présente plus comme lecteur/éditeur compatible avec le fichier actuel.")) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled, isCurrent() else { continuation.resume(throwing: CancellationError()); return }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: LensError.unavailable(LensL10n.text("L'application n'a pas confirmé l'ouverture du fichier actuel."))) }
            }
        }
    }
    static func reveal(path: String, directory: Bool, files: FileService, isCurrent: @MainActor () -> Bool) async throws {
        if directory {
            let inspection = try await files.inspect(environment: EnvironmentRecord(path: path))
            guard inspection.exists else { throw LensError.unavailable(LensL10n.text("Le répertoire actuel n'est plus accessible.")) }
        } else { _ = try await files.previewURL(path: path) }
        guard let absolute = NativeFileLocation(path: path).absolutePath else { throw LensError.unsupported("Chemin local absolu indisponible.") }
        // Reveal the inspected lexical item, including a symlink, in its worktree.
        // Opening a document above uses the resolved and validated current target.
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
    }
}

/// Explicit local actions retain the opening that authorized their target. A later
/// session/root or a closed window cannot turn a completed read into an external open.
@MainActor
private struct NativeFileActionOrigin {
    let openingIdentity: UUID
    let rootID: String?
    init(store: LensStore) { openingIdentity = store.openingIdentity; rootID = store.snapshot?.root.id }
    func isCurrent(in store: LensStore) -> Bool {
        !Task.isCancelled && store.isObserving && openingIdentity == store.openingIdentity && rootID == store.snapshot?.root.id
    }
}

/// The action belongs to the diff pane, not to a transient context-menu item.
/// It performs metadata checks only after the explicit action and revalidates
/// both the file and the selected reader/editor before Launch Services opens it.
@MainActor @Observable final class NativeCurrentFileActions {
    private(set) var busy = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var panel: NSOpenPanel?
    @ObservationIgnored private var generation = UUID()

    func cancel() {
        generation = UUID(); task?.cancel(); panel?.cancel(nil)
        task = nil; panel = nil; busy = false
    }

    func reveal(path: String, store: LensStore) {
        guard !busy, store.isObserving else { return }
        let origin = NativeFileActionOrigin(store: store)
        let selection = store.selection, request = UUID()
        generation = request; busy = true
        task = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { if self.generation == request { self.task = nil; self.busy = false } }
            @MainActor func accepts() -> Bool { self.generation == request && origin.isCurrent(in: store) && store.selection == selection }
            do {
                try await NativeFileAccess.reveal(path: path, directory: false, files: store.files, isCurrent: accepts)
            } catch is CancellationError { }
            catch {
                if accepts() { store.showLocalNotice(LensL10n.text("Action sur le fichier actuel indisponible : ") + error.localizedDescription) }
            }
        }
    }

    func choose(path: String, environmentID: String, store: LensStore, window: NSWindow?) {
        guard !busy, store.isObserving else { return }
        guard let window else {
            store.showLocalNotice(LensL10n.text("La fenêtre du diff n’est plus disponible.")); return
        }
        let origin = NativeFileActionOrigin(store: store)
        let selection = store.selection, request = UUID()
        generation = request; busy = true
        task = Task { [weak self, weak store, weak window] in
            guard let self, let store, let window else { return }
            defer { if self.generation == request { self.task = nil; self.panel = nil; self.busy = false } }
            @MainActor func accepts() -> Bool { self.generation == request && origin.isCurrent(in: store) && store.selection == selection }
            do {
                _ = try await NativeFileAccess.document(path, files: store.files)
                guard accepts() else { return }
                let picker = NSOpenPanel()
                picker.title = LensL10n.text("Ouvrir le fichier actuel avec…")
                picker.prompt = LensL10n.text("Ouvrir")
                picker.message = LensL10n.text("Fichier actuel : {0}\nEnvironnement : {1}", path, environmentID)
                picker.allowedContentTypes = [.applicationBundle]
                picker.canChooseFiles = true; picker.canChooseDirectories = false
                picker.allowsMultipleSelection = false; picker.treatsFilePackagesAsDirectories = false
                picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                self.panel = picker
                let result = await withCheckedContinuation { continuation in
                    picker.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
                guard result == .OK, let application = picker.url, accepts() else { return }
                try await NativeFileAccess.open(path: path, application: application, files: store.files, isCurrent: accepts)
            } catch is CancellationError { }
            catch {
                if accepts() { store.showLocalNotice(LensL10n.text("Action sur le fichier actuel indisponible : ") + error.localizedDescription) }
            }
        }
    }
}

/// One visible menu in the file preview. No default executable handler is invoked,
/// no application preference is changed, and opening an editor does not write here.
struct NativeFileActionsMenu: View {
    @EnvironmentObject var store: LensStore
    let path: String
    let environmentID: String
    var line: Int? = nil
    @State private var worktreeRoot: String?
    @State private var applications: [NativeDocumentApplication] = []
    @State private var availability: String?
    @State private var actionIssue: String?
    @State private var checking = true
    @State private var acting = false
    @State private var actionTask: Task<Void, Never>?
    private var identity: String { (store.snapshot?.root.id ?? "") + "\u{0}" + environmentID + "\u{0}" + path }
    private var location: NativeFileLocation { NativeFileLocation(path: path, worktreeRoot: worktreeRoot, line: line) }
    var body: some View {
        Menu {
            if let value = location.absolutePath { Button(LensL10n.text("Copier le chemin absolu")) { store.copyLocalText(value, notice: LensL10n.text("Chemin absolu copié")) } }
            if let value = location.relativePath { Button(LensL10n.text("Copier le chemin relatif au worktree")) { store.copyLocalText(value, notice: LensL10n.text("Chemin relatif au worktree copié")) } }
            if let value = location.fileLine { Button(LensL10n.text("Copier fichier actuel : ligne")) { store.copyLocalText(value, notice: LensL10n.text("Chemin et ligne de la lecture actuelle copiés")) } }
            Divider()
            Button(LensL10n.text("Afficher le fichier actuel dans le Finder")) { perform { origin in try await NativeFileAccess.reveal(path: path, directory: false, files: store.files, isCurrent: { origin.isCurrent(in: store) }) } }.disabled(acting)
            Menu(LensL10n.text("Ouvrir le fichier actuel avec")) {
                if checking { Text(LensL10n.text("Vérification du fichier actuel…")) }
                else if applications.isEmpty { Text(availability ?? LensL10n.text("Aucun lecteur ou éditeur compatible enregistré")) }
                ForEach(applications) { application in
                    Button(application.name) { perform { origin in try await NativeFileAccess.open(path: path, application: application.url, files: store.files, isCurrent: { origin.isCurrent(in: store) }) } }
                }
            }.disabled(checking || applications.isEmpty || acting)
            if let availability { Divider(); Text(LensL10n.text("Ouverture externe : ") + availability) }
            if let actionIssue { Divider(); Text(actionIssue) }
        } label: { Label(LensL10n.text("Fichier actuel"), systemImage: LensSymbols.name("ellipsis.circle")) }
            .help(actionIssue ?? availability ?? LensL10n.text("Actions locales sur le fichier actuel ; l'instantané affiché reste inchangé"))
            .accessibilityLabel(LensL10n.text("Actions du fichier actuel"))
            .controlSize(.small)
            .task(id: identity) { await prepare() }
            .onDisappear { actionTask?.cancel(); actionTask = nil }
    }
    private func prepare() async {
        let expectedIdentity = identity
        applications = []; availability = nil; actionIssue = nil; checking = true; acting = false; worktreeRoot = nil
        if let environment = store.snapshot?.environments.first(where: { $0.id == environmentID }) {
            if let inspection = try? await store.files.inspect(environment: environment), !Task.isCancelled, expectedIdentity == identity {
                worktreeRoot = inspection.worktreePath ?? environment.path
            }
        }
        do {
            let url = try await NativeFileAccess.document(path, files: store.files)
            guard !Task.isCancelled, expectedIdentity == identity else { return }
            applications = try NativeFileAccess.applications(for: url)
            if applications.isEmpty { availability = LensL10n.text("Aucun lecteur ou éditeur compatible enregistré") }
        } catch { if !Task.isCancelled, expectedIdentity == identity { availability = error.localizedDescription } }
        if !Task.isCancelled, expectedIdentity == identity { checking = false }
    }
    private func perform(_ action: @escaping @MainActor (NativeFileActionOrigin) async throws -> Void) {
        guard !acting, store.isObserving else { return }
        let origin = NativeFileActionOrigin(store: store), expectedIdentity = identity
        actionIssue = nil; acting = true
        actionTask = Task {
            do { try await action(origin) }
            catch is CancellationError { }
            catch {
                if origin.isCurrent(in: store), identity == expectedIdentity {
                    actionIssue = error.localizedDescription
                    store.showLocalNotice(LensL10n.text("Action sur le fichier actuel indisponible : ") + error.localizedDescription)
                }
            }
            if origin.isCurrent(in: store), identity == expectedIdentity { acting = false; actionTask = nil }
        }
    }
}

/// Lightweight context actions for tree rows. No applications/contents are loaded
/// while browsing the tree. Directory metadata is checked only on explicit reveal.
struct NativeFilePathActions: View {
    @EnvironmentObject var store: LensStore
    let path: String
    var worktreeRoot: String? = nil
    var isDirectory = false
    var restricted = false
    var onIssue: ((String) -> Void)? = nil
    @State private var actionIssue: String?
    @State private var actionTask: Task<Void, Never>?
    var body: some View {
        let location = NativeFileLocation(path: path, worktreeRoot: worktreeRoot)
        if let value = location.absolutePath { Button(LensL10n.text("Copier le chemin absolu")) { store.copyLocalText(value, notice: LensL10n.text("Chemin absolu copié")) } }
        if let value = location.relativePath { Button(LensL10n.text("Copier le chemin relatif au worktree")) { store.copyLocalText(value, notice: LensL10n.text("Chemin relatif au worktree copié")) } }
        Button(isDirectory ? LensL10n.text("Afficher le répertoire actuel dans le Finder") : LensL10n.text("Afficher le fichier actuel dans le Finder")) {
            guard store.isObserving else { return }
            let origin = NativeFileActionOrigin(store: store)
            actionTask?.cancel(); actionIssue = nil
            actionTask = Task {
                do { try await NativeFileAccess.reveal(path: path, directory: isDirectory, files: store.files, isCurrent: { origin.isCurrent(in: store) }) }
                catch is CancellationError { }
                catch {
                    if origin.isCurrent(in: store) {
                        actionIssue = error.localizedDescription; onIssue?(error.localizedDescription)
                        store.showLocalNotice(LensL10n.text("Finder indisponible pour cette cible : ") + error.localizedDescription)
                    }
                }
                if origin.isCurrent(in: store) { actionTask = nil }
            }
        }.disabled(restricted)
        if let actionIssue { Text(actionIssue) }
    }
}
