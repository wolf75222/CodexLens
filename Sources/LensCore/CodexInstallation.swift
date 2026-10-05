import Foundation

/// Discovers executable paths only. No shell, credential file, login or inference.
public enum CodexInstallation {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                  applications: [URL]? = nil) -> [URL] {
        let roots = applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let appPaths = ["Codex.app/Contents/Resources/codex-cli/bin/codex",
                        "Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                        "Codex.app/Contents/Resources/codex",
                        "ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                        "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        var paths = roots.flatMap { root in appPaths.map { root.appendingPathComponent($0) } }
        paths += [home.appendingPathComponent(".npm-global/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
        // Ignore relative PATH entries: a session's current directory must not
        // cause an arbitrary local file to be mistaken for the installed CLI.
        paths += path.split(separator: ":").filter { $0.hasPrefix("/") }.prefix(64).map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        var seen = Set<String>()
        return paths.filter { url in
            FileManager.default.isExecutableFile(atPath: url.path) && seen.insert(url.resolvingSymlinksInPath().path).inserted
        }
    }

    public static func qualifiedExecutable(preferred: URL? = nil, candidates: [URL]? = nil) async throws -> URL {
        let paths = preferred.map { [$0] } ?? candidates ?? Self.candidates()
        guard !paths.isEmpty else { throw LensError.unavailable("Codex est introuvable. Choisissez le binaire installé dans Réglages > IA.") }
        var observed: [String] = []
        for url in paths {
            try Task.checkCancellation()
            guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path) else {
                if preferred != nil { throw LensError.unavailable("Le binaire Codex choisi n’est plus accessible. Choisissez-le à nouveau dans Réglages > IA.") }
                continue
            }
            do {
                let version = try await CodexInvestigationLocalStatus.inspectVersion(executable: url)
                if version == CodexInvestigationPolicy.supportedVersion { return url }
                observed.append(version ?? "inconnue")
            } catch is CancellationError { throw CancellationError() }
            catch { if preferred != nil { throw error } }
        }
        throw LensError.unsupported("Version Codex incompatible avec cet adaptateur. Version prise en charge : \(CodexInvestigationPolicy.supportedVersion). Version trouvée : \(observed.joined(separator: ", ").nonEmptyVersion). Le brouillon est conservé.")
    }
}

private extension String { var nonEmptyVersion: String { isEmpty ? "inconnue" : self } }
