import Foundation

/// Source directories only. This does not inspect credentials or change Codex configuration.
public enum CodexSourceLocation {
    public static func personalHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(environment["CODEX_HOME"]) ?? userHome.appendingPathComponent(".codex", isDirectory: true)
    }
    public static func observationHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(environment["LENS_CODEX_HOME"]) ?? personalHome(environment: environment, userHome: userHome)
    }
    private static func directory(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }
}
