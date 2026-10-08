import Foundation

public enum LensUninstallPolicyError: Error, Equatable, Sendable {
    case unsupportedApplication
    case outsideApplications
    case unverifiedBuild
    case unsafePath(String)
    case changedApplication

    public var messageKey: String {
        switch self {
        case .unsupportedApplication: return "Cette copie ne peut pas être désinstallée depuis Lens."
        case .outsideApplications: return "Installez Lens dans Applications pour utiliser cette commande."
        case .unverifiedBuild: return "La désinstallation est indisponible pour une copie de développement ou non vérifiée."
        case .unsafePath: return "Un emplacement est inaccessible, remplacé ou contient un lien symbolique. Rien n’a été déplacé."
        case .changedApplication: return "L’application a changé depuis l’ouverture de cette fenêtre. Fermez-la et réessayez."
        }
    }
    public var path: String? { if case let .unsafePath(path) = self { return path }; return nil }
}

public struct LensUninstallPlan: Sendable {
    public let applicationURL: URL
    /// All allowlisted default locations, including those that do not exist.
    public let localDataURLs: [URL]
    public let preservedLocalDataURLs: [URL]
    /// Only existing objects; no recursive traversal or captured source path.
    public let urlsToRecycle: [URL]
    public let resetPreferences: Bool
    fileprivate let removeLocalDataRequested: Bool
    fileprivate let applicationIdentity: String
    fileprivate let runningExecutableURL: URL
}

/// Read-only review of the *running* installed app and its own default storage.
/// No captured repository/session/export path or configurable storage location
/// is accepted. Execution is left to AppKit's recoverable Trash operation.
public struct LensUninstallPolicy: Sendable {
    public static let bundleIdentifier = "fr.codexlens.inspector"
    private let home: URL
    private let systemApplications: URL
    private let preservedStorage: [URL]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemApplicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                preservedStorageURLs: [URL] = []) {
        home = Self.lexicalFileURL(homeDirectory)
        systemApplications = Self.lexicalFileURL(systemApplicationsDirectory)
        preservedStorage = preservedStorageURLs.filter(\.isFileURL).flatMap(Self.storageAliases)
    }

    public func review(applicationURL: URL, runningExecutableURL: URL, removeLocalData: Bool = false) throws -> LensUninstallPlan {
        guard applicationURL.isFileURL, runningExecutableURL.isFileURL else { throw LensUninstallPolicyError.unsupportedApplication }
        let app = Self.lexicalFileURL(applicationURL)
        let executable = Self.lexicalFileURL(runningExecutableURL)
        guard app.isFileURL, executable.isFileURL, app.pathExtension == "app" else { throw LensUninstallPolicyError.unsupportedApplication }
        let installationRoots = [systemApplications, home.appendingPathComponent("Applications", isDirectory: true)]
        guard installationRoots.contains(where: { $0.path == app.deletingLastPathComponent().path }) else { throw LensUninstallPolicyError.outsideApplications }
        guard try inspect(app, type: .typeDirectory) else { throw LensUninstallPolicyError.unsafePath(app.path) }
        let expectedExecutable = app.appendingPathComponent("Contents/MacOS/CodexLens")
        guard executable.path == expectedExecutable.path, try inspect(expectedExecutable, type: .typeRegular) else { throw LensUninstallPolicyError.unsupportedApplication }

        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard try inspect(infoURL, type: .typeRegular),
              let info = try? PropertyListSerialization.propertyList(from: metadata(at: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              info["CFBundleExecutable"] as? String == "CodexLens" else { throw LensUninstallPolicyError.unsupportedApplication }

        // Repository and QA builds have distinct identities or a dirty receipt.
        // A missing receipt is never interpreted as a release installation.
        let buildURL = app.appendingPathComponent("Contents/Resources/BuildInfo.json")
        guard try inspect(buildURL, type: .typeRegular),
              let build = try? JSONDecoder().decode(BuildReceipt.self, from: metadata(at: buildURL)),
              build.schemaVersion == 1, !build.dirty,
              build.sourceCommit.count == 40,
              build.sourceCommit.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { throw LensUninstallPolicyError.unverifiedBuild }

        let library = home.appendingPathComponent("Library", isDirectory: true)
        let directories = [
            library.appendingPathComponent("Application Support/CodexLens", isDirectory: true),
            library.appendingPathComponent("Caches/CodexLens", isDirectory: true),
            library.appendingPathComponent("Caches/" + Self.bundleIdentifier, isDirectory: true)
        ]
        let preferences = library.appendingPathComponent("Preferences/" + Self.bundleIdentifier + ".plist")
        let defaults = directories + [preferences]
        let preserved = defaults.filter { candidate in
            !preservedStorage.isEmpty && Self.storageAliases(candidate).contains { alias in
                preservedStorage.contains { Self.overlaps(alias, $0) }
            }
        }
        let allowed = defaults.filter { candidate in !preserved.contains(where: { $0.path == candidate.path }) }
        var selected = [app]
        if removeLocalData {
            for directory in directories where allowed.contains(where: { $0.path == directory.path }) {
                if try inspect(directory, type: .typeDirectory) { selected.append(directory) }
            }
            if allowed.contains(where: { $0.path == preferences.path }), try inspect(preferences, type: .typeRegular) { selected.append(preferences) }
        }
        return LensUninstallPlan(applicationURL: app, localDataURLs: allowed, preservedLocalDataURLs: preserved, urlsToRecycle: selected,
                                 resetPreferences: removeLocalData && allowed.contains(where: { $0.path == preferences.path }), removeLocalDataRequested: removeLocalData,
                                 applicationIdentity: try identity(of: app), runningExecutableURL: executable)
    }

    /// Recheck after stores have flushed: reject replaced bundles and newly
    /// introduced unsafe ancestors before handing any URL to NSWorkspace.
    public func validateForExecution(_ plan: LensUninstallPlan) throws -> LensUninstallPlan {
        let current = try review(applicationURL: plan.applicationURL, runningExecutableURL: plan.runningExecutableURL, removeLocalData: plan.removeLocalDataRequested)
        guard current.applicationIdentity == plan.applicationIdentity else { throw LensUninstallPolicyError.changedApplication }
        return current
    }

    private func identity(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw LensUninstallPolicyError.unverifiedBuild }
        return volume.stringValue + ":" + inode.stringValue
    }

    private func metadata(at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let length = attributes[.size] as? NSNumber, length.intValue <= 64 * 1024 else { throw LensUninstallPolicyError.unverifiedBuild }
        return try Data(contentsOf: url)
    }

    private struct BuildReceipt: Decodable { let schemaVersion: Int; let dirty: Bool; let sourceCommit: String }
    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        a.path == b.path || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/")
    }

    /// Preservation only: follow metadata aliases of configured storage, never
    /// read its contents or add its path to the uninstall targets. Resolve the
    /// existing ancestor even when a custom archive/cache has not been created.
    private static func storageAliases(_ url: URL) -> [URL] {
        let lexical = lexicalFileURL(url)
        var ancestor = lexical
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            missing.append(ancestor.lastPathComponent); ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return [lexical, lexicalFileURL(resolved)]
    }

    // Foundation's standardizedFileURL rewrites an existing /private/tmp or
    // /private/var path into its symlink alias. Normalize dot components only,
    // preserving the exact ancestors that the safety check must examine.
    private static func lexicalFileURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents where component != "/" && component != "." {
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }

    /// Examine each ancestor rather than resolving symlinks into another home,
    /// source checkout or disk. Missing default data is a harmless no-op.
    private func inspect(_ url: URL, type expectedType: FileAttributeType) throws -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw LensUninstallPolicyError.unsafePath(url.path) }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = url.pathComponents.dropFirst()
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: current.path) }
            catch {
                if (error as NSError).domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) { return false }
                throw LensUninstallPolicyError.unsafePath(current.path)
            }
            let type = attributes[.type] as? FileAttributeType
            let required = index == components.count - 1 ? expectedType : .typeDirectory
            guard type == required else { throw LensUninstallPolicyError.unsafePath(current.path) }
        }
        return true
    }
}
