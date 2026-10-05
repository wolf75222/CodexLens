import Foundation
import Darwin

/// Ownership is established only by a persisted local chat followed by an explicit
/// binding to the newly created investigation thread. Archive inference IDs are not consulted.
public struct CodexInvestigationChat: Codable, Sendable, Equatable, Identifiable {
    public var id: String { chatID }
    public let chatID: String
    public let rootObservedID: String
    public let threadID: String?
}

public actor CodexInvestigationRegistry {
    public static let shared = CodexInvestigationRegistry()
    public nonisolated let directory: URL
    public nonisolated let maximumBytes: Int
    public nonisolated let maximumChats: Int
    public nonisolated var fileURL: URL { directory.appendingPathComponent("ownership.json") }

    public init(directory: URL? = nil, maximumBytes: Int = 256 * 1024, maximumChats: Int = 1000) {
        self.directory = Self.selectedDirectory(directory)
        self.maximumBytes = min(256 * 1024, max(1024, maximumBytes))
        self.maximumChats = min(1000, max(1, maximumChats))
    }

    /// A supplied UUID reconnects the same local chat; an unknown UUID starts an
    /// unbound chat and never imports ownership of an existing Codex thread.
    public func chat(root: String, chatID: String? = nil) throws -> CodexInvestigationChat {
        let root = try Self.validID(root)
        let id = try Self.validChatID(chatID ?? UUID().uuidString)
        return try mutate { state in
            guard !state.chats.contains(where: { $0.threadID == root }) else { throw LensError.unsupported("Un thread d'investigation ne peut pas devenir une source observée.") }
            if let existing = state.chats.first(where: { $0.chatID == id }) {
                guard existing.rootObservedID == root else { throw Self.rootMismatch() }
                return existing
            }
            guard state.chats.count < maximumChats else { throw Self.quota() }
            let new = CodexInvestigationChat(chatID: id, rootObservedID: root, threadID: nil)
            state.chats.append(new)
            return new
        }
    }

    /// Persist this result before sending the first turn. Existing bindings cannot
    /// be replaced and an observed source can never be bound as an investigation.
    @discardableResult public func bind(chatID: String, root: String, threadID: String) throws -> CodexInvestigationChat {
        let id = try Self.validChatID(chatID), root = try Self.validID(root), thread = try Self.validID(threadID)
        guard root != thread else { throw LensError.unsupported("Le thread observé ne peut pas appartenir à l'investigation.") }
        return try mutate { state in
            guard let index = state.chats.firstIndex(where: { $0.chatID == id }) else { throw LensError.unavailable("Chat local non enregistré ; propriété du thread refusée.") }
            let existing = state.chats[index]
            guard existing.rootObservedID == root else { throw Self.rootMismatch() }
            guard existing.threadID == nil || existing.threadID == thread else { throw LensError.unsupported("Ce chat possède déjà un autre thread d'investigation.") }
            guard !state.chats.contains(where: { $0.chatID != id && $0.threadID == thread }),
                  !state.chats.contains(where: { $0.rootObservedID == thread }) else {
                throw LensError.unsupported("Thread déjà associé à une autre identité locale ou observée.")
            }
            let bound = CodexInvestigationChat(chatID: id, rootObservedID: root, threadID: thread)
            state.chats[index] = bound
            return bound
        }
    }

    public func lookup(chatID: String, root: String) throws -> CodexInvestigationChat? {
        let id = try Self.validChatID(chatID), root = try Self.validID(root)
        guard let chat = try readState().chats.first(where: { $0.chatID == id }) else { return nil }
        guard chat.rootObservedID == root else { throw Self.rootMismatch() }
        return chat
    }

    /// UI metadata only. Retain the server identity across a section rename.
    /// Legacy registries omit this optional key; ownership bindings stay intact.
    public func sidebarSectionID() throws -> String? { try readState().sidebarSectionID }
    public func rememberSidebarSection(_ id: String) throws {
        let id = try Self.validID(id)
        try mutate { state in state.sidebarSectionID = id }
    }

    /// This private cwd also excludes a newly created blank thread before its ID
    /// can be returned by app-server and bound to the registry.
    public func workspaceDirectory(chatID: String) throws -> URL {
        let id = try Self.validChatID(chatID)
        guard try readState().chats.contains(where: { $0.chatID == id }) else { throw LensError.unavailable("Chat local non enregistré ; espace privé indisponible.") }
        let workspace = Self.workspaceRoot(directory: directory).appendingPathComponent(id, isDirectory: true)
        try RegistryFile.ensureDirectory(workspace)
        return workspace
    }
    /// Account probing must not pre-create the ownership root with public
    /// Foundation defaults before the first chat is registered.
    public func connectionProbeDirectory() throws -> URL {
        try RegistryFile.ensureDirectory(directory)
        let probe = directory.appendingPathComponent("ConnectionProbe", isDirectory: true)
        try RegistryFile.ensureDirectory(probe)
        return probe
    }

    /// Read-only collector helper. Missing storage means no ownership; malformed,
    /// oversized or unsafe storage throws so callers cannot silently collect its threads.
    public nonisolated static func ownedThreadIDs(directory: URL? = nil) throws -> Set<String> {
        let selected = selectedDirectory(directory)
        return Set(try readState(directory: selected, maximumBytes: 256 * 1024, maximumChats: 1000).chats.compactMap(\.threadID))
    }

    public nonisolated static func workspaceRoot(directory: URL? = nil) -> URL {
        selectedDirectory(directory).appendingPathComponent("Workspaces", isDirectory: true)
    }

    private struct State: Codable { var schemaVersion = 1; var chats: [CodexInvestigationChat] = []; var sidebarSectionID: String? }

    private func mutate<T>(_ body: (inout State) throws -> T) throws -> T {
        return try RegistryFile.withLock(directory: directory) { descriptor in
            var state = try Self.readState(descriptor: descriptor, maximumBytes: maximumBytes, maximumChats: maximumChats)
            let result = try body(&state)
            state.chats.sort { $0.chatID < $1.chatID }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            guard data.count <= maximumBytes else { throw Self.quota() }
            try RegistryFile.write(data, descriptor: descriptor)
            return result
        }
    }

    private func readState() throws -> State { try Self.readState(directory: directory, maximumBytes: maximumBytes, maximumChats: maximumChats) }

    private nonisolated static func readState(directory: URL, maximumBytes: Int, maximumChats: Int) throws -> State {
        guard let descriptor = try RegistryFile.openDirectory(directory, create: false) else { return State() }
        defer { _ = close(descriptor) }
        return try readState(descriptor: descriptor, maximumBytes: maximumBytes, maximumChats: maximumChats)
    }

    private nonisolated static func readState(descriptor: Int32, maximumBytes: Int, maximumChats: Int) throws -> State {
        guard let data = try RegistryFile.read(descriptor: descriptor, maximumBytes: maximumBytes) else { return State() }
        let state: State
        do { state = try JSONDecoder().decode(State.self, from: data) }
        catch { throw LensError.corrupt("Registre de propriété d'investigation illisible ; aucune identité n'est récupérée.") }
        guard state.schemaVersion == 1, state.chats.count <= maximumChats else { throw LensError.corrupt("Version ou nombre de chats du registre invalide ; aucune identité n'est récupérée.") }
        if let id = state.sidebarSectionID { _ = try validID(id) }
        var chatIDs = Set<String>(), threads = Set<String>()
        let observed = Set(state.chats.map(\.rootObservedID))
        for chat in state.chats {
            guard try validChatID(chat.chatID) == chat.chatID, try validID(chat.rootObservedID) == chat.rootObservedID,
                  chatIDs.insert(chat.chatID).inserted else { throw LensError.corrupt("Identité locale du registre invalide ou dupliquée.") }
            if let thread = chat.threadID {
                guard try validID(thread) == thread, !observed.contains(thread), threads.insert(thread).inserted else {
                    throw LensError.corrupt("Propriété de thread du registre invalide ou ambiguë.")
                }
            }
        }
        return state
    }

    private nonisolated static func selectedDirectory(_ directory: URL?) -> URL {
        let selected = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexLens/InvestigationThreads", isDirectory: true)
        guard selected.isFileURL else { return selected }
        // Foundation standardization can abbreviate an existing /private/tmp to
        // the symlink /tmp. Normalize lexical components only, preserving every
        // ancestor spelling for the descriptor-relative symlink checks below.
        var components: [String] = []
        for component in selected.pathComponents.dropFirst() {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }
    private nonisolated static func validChatID(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw LensError.unsupported("UUID de chat Lens invalide.") }
        return uuid.uuidString
    }
    private nonisolated static func validID(_ id: String) throws -> String {
        guard !id.isEmpty, id.utf8.count <= 256, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.contains("/"), !id.contains("\\"), !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LensError.unsupported("Identifiant de thread invalide.")
        }
        return id
    }
    private nonisolated static func rootMismatch() -> LensError { .unsupported("Le chat local appartient à une autre session observée.") }
    private nonisolated static func quota() -> LensError { .unsupported("Quota du registre de propriété atteint ; aucune identité n'a été supprimée ni remplacée.") }
}

/// Descriptor-relative, bounded storage. The lock serializes separate registry
/// instances/processes; rename makes a read-only collector see an entire generation.
private enum RegistryFile {
    static func ensureDirectory(_ url: URL) throws { _ = try openDirectory(url, create: true).map { close($0) } }

    static func openDirectory(_ url: URL, create: Bool) throws -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", !url.path.contains("\0") else { throw LensError.unsupported("Répertoire privé local invalide.") }
        // Walk with descriptor-relative O_NOFOLLOW on every component, so a
        // symlinked parent cannot redirect storage between inspection and open.
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("Ouverture du répertoire racine") }
        var returned = false
        defer { if !returned { _ = close(descriptor) } }
        let components = Array(url.pathComponents.dropFirst())
        var createdFinalDirectory = false
        for (index, component) in components.enumerated() {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                guard errno == ENOENT else { throw failure("Répertoire privé non régulier ; lien symbolique refusé") }
                guard create else { return nil }
                let created = mkdirat(descriptor, component, mode_t(0o700)) == 0
                guard created || errno == EEXIST else { throw failure("Création du répertoire privé") }
                if index == components.count - 1 { createdFinalDirectory = created }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure("Répertoire privé modifié ; lien symbolique refusé") }
            }
            _ = close(descriptor); descriptor = next
        }
        if createdFinalDirectory, fchmod(descriptor, mode_t(0o700)) != 0 { throw failure("Permissions du répertoire privé") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("Validation du répertoire privé") }
        guard info.st_mode & 0o077 == 0 else { throw LensError.unavailable("Répertoire du registre non privé ; permissions existantes conservées, accès refusé.") }
        returned = true
        return descriptor
    }

    static func withLock<T>(directory: URL, body: (Int32) throws -> T) throws -> T {
        guard let descriptor = try openDirectory(directory, create: true) else { throw failure("Ouverture du registre") }
        defer { _ = close(descriptor) }
        let lock = try openLock(descriptor: descriptor)
        defer { _ = close(lock) }
        let info = try regular(lock)
        guard info.st_mode & 0o077 == 0 else { throw LensError.unavailable("Verrou du registre non privé ; permissions existantes conservées, accès refusé.") }
        guard flock(lock, LOCK_EX) == 0 else { throw failure("Verrouillage du registre") }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(descriptor)
    }

    private static func openLock(descriptor: Int32) throws -> Int32 {
        var expected = stat()
        guard fstat(descriptor, &expected) == 0 else { throw failure("Validation du répertoire du verrou") }
        // On macOS, concurrent O_CREAT for the same new file can transiently
        // return ENOENT even with a valid directory descriptor (also reproduced
        // with a minimal C/GCD probe). Retry this one creation race for <=9 ms.
        for attempt in 0..<4 {
            let file = openat(descriptor, ".ownership.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
            if file >= 0 { return file }
            guard errno == ENOENT, attempt < 3 else { throw failure("Ouverture du verrou privé") }
            var current = stat()
            guard fstat(descriptor, &current) == 0, current.st_dev == expected.st_dev,
                  current.st_ino == expected.st_ino, current.st_nlink > 0,
                  current.st_mode & S_IFMT == S_IFDIR, current.st_mode & 0o077 == 0 else {
                throw LensError.unavailable("Répertoire du verrou modifié ou non privé ; création refusée.")
            }
            usleep(3000)
        }
        throw failure("Ouverture du verrou privé")
    }

    static func read(descriptor: Int32, maximumBytes: Int) throws -> Data? {
        let file = openat(descriptor, "ownership.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 { if errno == ENOENT { return nil }; throw failure("Lecture du registre ; lien symbolique refusé") }
        defer { _ = close(file) }
        let before = try regular(file)
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else { throw LensError.unsupported("Registre supérieur au quota local ; contenu non lu.") }
        guard before.st_mode & 0o077 == 0 else { throw LensError.unavailable("Permissions du registre non privées ; lecture refusée.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if amount < 0 { if errno == EINTR { continue }; throw failure("Lecture bornée du registre") }
            if amount == 0 { break }
            guard data.count <= maximumBytes - amount else { throw LensError.unsupported("Registre agrandi au-delà du quota ; contenu rejeté.") }
            data.append(contentsOf: buffer.prefix(amount))
        }
        let after = try regular(file)
        guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, data.count == Int(before.st_size) else {
            throw LensError.unavailable("Registre modifié pendant sa lecture ; aucune identité partielle récupérée.")
        }
        return data
    }

    static func write(_ data: Data, descriptor: Int32) throws {
        // Validate an existing destination without following a symlink before replacement.
        var destination = stat()
        if fstatat(descriptor, "ownership.json", &destination, AT_SYMLINK_NOFOLLOW) == 0 {
            guard destination.st_mode & S_IFMT == S_IFREG, destination.st_nlink == 1 else { throw LensError.unavailable("Destination du registre non régulière ; lien refusé.") }
        } else if errno != ENOENT { throw failure("Validation du registre") }
        let name = ".ownership-" + UUID().uuidString + ".partial"
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw failure("Création du registre privé") }
        var committed = false
        defer { _ = close(file); if !committed { _ = unlinkat(descriptor, name, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 { if errno == EINTR { continue }; throw failure("Écriture du registre") }
                guard amount > 0 else { throw failure("Écriture du registre interrompue") }
                offset += amount
            }
        }
        guard fchmod(file, mode_t(0o600)) == 0, fsync(file) == 0,
              renameat(descriptor, name, descriptor, "ownership.json") == 0 else { throw failure("Persistance atomique du registre") }
        committed = true
        guard fsync(descriptor) == 0 else { throw failure("Synchronisation du registre privé") }
    }

    @discardableResult private static func regular(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("Validation du fichier privé") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw LensError.unavailable("Registre non régulier ; liens symboliques ou physiques refusés.") }
        return info
    }
    private static func failure(_ operation: String) -> LensError { .unavailable("\(operation) : \(String(cString: strerror(errno))).") }
}
