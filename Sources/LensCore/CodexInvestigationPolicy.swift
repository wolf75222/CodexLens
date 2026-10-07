import Foundation
import Darwin

/// The native Codex process owns credentials. Lens only examines the public RPC
/// configuration in memory; it never reads auth.json or changes a config file.
/// Exact-version qualification uses each binary's experimental JSON schemas,
/// tagged tool-registry source and isolated configuration/permissions probes.
enum CodexInvestigationPolicy {
    static let profileName = "codex_lens_context_only_v19"
    static let supportedVersions = ["0.159.2", "0.160.1"]
    private static let backend = "https://chatgpt.com/backend-api/codex"
    private static let disabledFeatures = [
        "hooks", "plugins", "apps", "shell_tool", "unified_exec", "shell_snapshot",
        "skill_mcp_dependency_install", "memories", "multi_agent", "goals", "tool_suggest",
        "browser_use", "browser_use_external", "browser_use_full_cdp_access", "computer_use",
        "image_generation", "view_image", "code_mode", "request_permissions_tool"
    ]
    private static let instructions = "Use only the conversation context supplied by Codex Lens. Do not access local files, commands, apps, connectors, plugins, skills or other conversations."

    static func version(executable: URL) async throws -> String {
        guard let version = try await CodexInvestigationLocalStatus.inspectVersion(executable: executable),
              CodexInstallation.isSupportedVersion(version) else {
            throw failure("Version Codex non qualifiée ; connexion refusée sans modifier la session CLI.")
        }
        return version
    }

    /// The returned server is started but deliberately NOT initialized. The
    /// caller owns its final initialize/initialized handshake and authentication.
    static func launch(executable: URL, version: String, workspace: URL, stateHome: URL? = nil) async throws -> CodexAppServerTransport {
        guard CodexInstallation.isSupportedVersion(version) else { throw failure("Version Codex non qualifiée.") }
        let hostArguments = try hostSandboxArguments(stateHome: stateHome)
        try prepare(workspace)
        let common = arguments(workspace: workspace)
        let bootstrap = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: hostArguments + [executable.path] + common,
                                               currentDirectoryURL: workspace, environment: environment(stateHome: stateHome, executable: executable))
        let names: [String]
        do {
            try await bootstrap.start()
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            _ = try await rpc(bootstrap, "initialize", ["clientInfo": ["name": "codex_lens", "title": "Codex Lens", "version": appVersion], "capabilities": ["experimentalApi": true]])
            try await bootstrap.notify(method: "initialized")
            let response = try await rpc(bootstrap, "config/read", ["includeLayers": true])
            guard let config = response["config"] as? [String: Any] else { throw failure("Configuration Codex illisible ; connexion refusée.") }
            try validate(config: config, workspace: workspace, requireDisabledMCP: false)
            try validateControlLayer(response)
            try validateRequirements(try await rpc(bootstrap, "configRequirements/read", [:]))
            names = try mcpNames(config)
            await bootstrap.close()
        } catch {
            await bootstrap.close()
            throw error
        }
        // Empty TOML maps merge with earlier layers and cannot remove servers.
        // Pin each effective server off; final verification rejects new names.
        var final = common
        let disabledServers = Dictionary(uniqueKeysWithValues: names.map { ($0, ["enabled": false] as Any) })
        final += ["-c", "mcp_servers=\(toml(disabledServers))"]
        let server = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: hostArguments + [executable.path] + final,
                                            currentDirectoryURL: workspace, environment: environment(stateHome: stateHome, executable: executable))
        try await server.start()
        return server
    }

    static func verify(server: CodexAppServerTransport, workspace: URL) async throws {
        _ = try hostSandboxArguments(stateHome: nil)
        let response = try await rpc(server, "config/read", ["includeLayers": true])
        guard let config = response["config"] as? [String: Any] else { throw failure("Configuration Codex illisible.") }
        try validate(config: config, workspace: workspace, requireDisabledMCP: true)
        try validateControlLayer(response)
        try validateRequirements(try await rpc(server, "configRequirements/read", [:]))
        let profiles = try await rpc(server, "permissionProfile/list", [:])
        guard (profiles["data"] as? [[String: Any]])?.contains(where: {
            $0["id"] as? String == profileName && $0["allowed"] as? Bool == true
        }) == true else { throw failure("Le profil de permissions fermé est indisponible ; aucun tour lancé.") }
    }

    /// Supplemental macOS restriction for the native process, not a replacement
    /// for Codex's named permission profile. The qualified versions expose no
    /// RPC to disable their CODEX_HOME instruction provider. Credentials remain
    /// owned by Codex.
    /// Reject instruction symlinks: SBPL checks resolved paths and a denylist
    /// cannot safely prevent a symlink from being retargeted after launch.
    static func hostSandboxArguments(stateHome: URL? = nil) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw failure("Isolation macOS de Codex indisponible ; aucun tour lancé.")
        }
        let home = stateHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        var denied: Set<String> = []
        for name in ["AGENTS.override.md", "AGENTS.md"] {
            let file = home.appendingPathComponent(name)
            var metadata = stat()
            if lstat(file.path, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                    throw failure("Les instructions globales Codex utilisent un lien ou un fichier spécial. Connexion d’enquête refusée ; aucune configuration globale modifiée.")
                }
            } else if errno != ENOENT {
                throw failure("Les instructions globales Codex ne peuvent pas être vérifiées ; aucun tour lancé.")
            }
            denied.insert(file.path)
            denied.insert(file.resolvingSymlinksInPath().path)
        }
        func quote(_ path: String) throws -> String {
            guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure("Chemin d’état Codex non sûr.") }
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let literals = try denied.sorted().map { "(literal \(try quote($0)))" }.joined(separator: " ")
        return ["-p", "(version 1) (allow default) (deny file-read* \(literals) (regex #\".*/AGENTS([.]override)?[.]md$\"))"]
    }

    /// Both thread/start and turn/start must also send environments: [] and the
    /// named permissions profile. In the qualified versions an empty environment
    /// list removes shell, apply_patch and view_image from the model's tool registry.
    static func threadConfiguration(workspace: URL) -> [String: Any] {
        var values = settings(workspace: workspace)
        values["instructions"] = ""
        values["developer_instructions"] = ""
        return values
    }

    private static func prepare(_ workspace: URL) throws {
        guard workspace.isFileURL, workspace.path.hasPrefix("/"),
              workspace.standardizedFileURL.path == workspace.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw failure("Répertoire d’enquête non sûr ; connexion refusée.")
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("lens-context-instructions.txt")
        if FileManager.default.fileExists(atPath: file.path),
           try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw failure("Source d’instructions d’enquête non sûre.")
        }
        try Data(instructions.utf8).write(to: file, options: .atomic)
    }

    private static func settings(workspace: URL) -> [String: Any] {
        var values: [String: Any] = [
            "model_provider": "openai", "openai_base_url": backend,
            "chatgpt_base_url": "https://chatgpt.com/backend-api/",
            "approval_policy": "never", "approvals_reviewer": "user", "web_search": "disabled",
            "default_permissions": profileName, "notify": [String](), "instructions": "",
            "developer_instructions": "", "compact_prompt": "", "project_doc_max_bytes": 0,
            "model_instructions_file": workspace.appendingPathComponent("lens-context-instructions.txt").path,
            "experimental_compact_prompt_file": workspace.appendingPathComponent("lens-context-instructions.txt").path,
            "skills.include_instructions": false, "skills.bundled.enabled": false,
            "cloud.skills.enabled": false, "orchestrator.mcp.enabled": false,
            "analytics.enabled": false, "otel.exporter": "none", "otel.trace_exporter": "none",
            "otel.log_user_prompt": false, "tools.experimental_request_user_input.enabled": false,
            "tools.update_plan.enabled": false,
            "permissions.\(profileName).filesystem": filesystem(workspace),
            "permissions.\(profileName).network.enabled": false
        ]
        for feature in disabledFeatures { values["features.\(feature)"] = false }
        return values
    }

    private static func filesystem(_ workspace: URL) -> [String: String] {
        var entries = [":root": "deny", ":minimal": "read", ":slash_tmp": "deny", ":tmpdir": "deny",
                       FileManager.default.homeDirectoryForCurrentUser.path: "deny"]
        entries[workspace.path] = "read"
        return entries
    }

    static func arguments(workspace: URL) -> [String] {
        var result = ["app-server", "--strict-config", "--listen", "stdio://"]
        for (key, value) in settings(workspace: workspace).sorted(by: { $0.key < $1.key }) {
            result += ["-c", "\(key)=\(toml(value))"]
        }
        return result
    }

    private static func environment(stateHome: URL? = nil, executable: URL? = nil) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var paths = executable.map { [$0.deletingLastPathComponent().path] } ?? []
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        paths += (inherited["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.prefix(64).map(String.init)
        var seen = Set<String>()
        var result: [String: String] = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                      "PATH": paths.filter { seen.insert($0).inserted }.joined(separator: ":")]
        // The original state root is required to let Codex reuse its own login.
        // Provider keys/tokens, endpoint variables and proxy settings are omitted.
        for key in ["CODEX_HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = inherited[key], !value.isEmpty { result[key] = value }
        }
        if let stateHome { result["CODEX_HOME"] = stateHome.path }
        return result
    }

    private static func validate(config: [String: Any], workspace: URL, requireDisabledMCP: Bool) throws {
        guard config["model_provider"] as? String == "openai",
              config["openai_base_url"] as? String == backend,
              config["chatgpt_base_url"] as? String == "https://chatgpt.com/backend-api/",
              config["approval_policy"] as? String == "never", config["approvals_reviewer"] as? String == "user",
              config["web_search"] as? String == "disabled", config["default_permissions"] as? String == profileName,
              (config["notify"] as? [Any])?.isEmpty == true, (config["project_doc_max_bytes"] as? Int) == 0,
              (config["instructions"] as? String ?? "").isEmpty, (config["developer_instructions"] as? String ?? "").isEmpty else {
            throw failure("Les paramètres Codex imposés ne sont pas effectifs ; aucun tour lancé.")
        }
        let features = config["features"] as? [String: Any] ?? [:]
        guard disabledFeatures.allSatisfy({ features[$0] as? Bool == false }),
              (config["skills"] as? [String: Any])?["include_instructions"] as? Bool == false,
              ((config["skills"] as? [String: Any])?["bundled"] as? [String: Any])?["enabled"] as? Bool == false,
              ((config["cloud"] as? [String: Any])?["skills"] as? [String: Any])?["enabled"] as? Bool == false,
              ((config["orchestrator"] as? [String: Any])?["mcp"] as? [String: Any])?["enabled"] as? Bool == false,
              ((config["analytics"] as? [String: Any])?["enabled"] as? Bool) == false else {
            throw failure("Une capacité locale Codex reste activée ; connexion refusée.")
        }
        let otel = config["otel"] as? [String: Any] ?? [:]
        let checks = [
            "otel.exporter": otel["exporter"] as? String == "none",
            "otel.trace_exporter": otel["trace_exporter"] as? String == "none",
            "otel.log_user_prompt": otel["log_user_prompt"] as? Bool == false,
            "model_instructions_file": config["model_instructions_file"] as? String == workspace.appendingPathComponent("lens-context-instructions.txt").path,
            "experimental_compact_prompt_file": config["experimental_compact_prompt_file"] as? String == workspace.appendingPathComponent("lens-context-instructions.txt").path
        ]
        let failed = checks.filter { !$0.value }.map(\.key).sorted()
        guard failed.isEmpty else { throw failure("Paramètres Codex imposés non vérifiés : \(failed.joined(separator: ", ")). Connexion refusée.") }
        guard let profile = (config["permissions"] as? [String: Any])?[profileName] as? [String: Any],
              let rules = profile["filesystem"] as? [String: Any],
              rules["glob_scan_max_depth"] == nil || rules["glob_scan_max_depth"] is NSNull,
              rules.filter({ $0.key != "glob_scan_max_depth" }) as? [String: String] == filesystem(workspace),
              profile["extends"] == nil || profile["extends"] is NSNull,
              ((profile["workspace_roots"] as? [String: Any]) ?? [:]).isEmpty,
              (profile["network"] as? [String: Any])?["enabled"] as? Bool == false else {
            throw failure("Le profil de permissions contient une règle inattendue ; connexion refusée.")
        }
        let names = try mcpNames(config)
        if requireDisabledMCP {
            let servers = config["mcp_servers"] as? [String: Any] ?? [:]
            guard names.allSatisfy({ (servers[$0] as? [String: Any])?["enabled"] as? Bool == false }) else {
                throw failure("Un serveur MCP est actif ou a changé ; aucun tour lancé.")
            }
        }
    }

    /// The qualified typed ToolsV2 responses omit these two fields. Read the
    /// highest-precedence raw layer through the documented config interface.
    private static func validateControlLayer(_ response: [String: Any]) throws {
        let active = (response["layers"] as? [[String: Any]] ?? []).filter { $0["disabledReason"] == nil || $0["disabledReason"] is NSNull }
        // Qualified native versions return layers from highest to lowest precedence.
        guard let layer = active.first, (layer["name"] as? [String: Any])?["type"] as? String == "sessionFlags",
              let config = layer["config"] as? [String: Any], let tools = config["tools"] as? [String: Any],
              (tools["experimental_request_user_input"] as? [String: Any])?["enabled"] as? Bool == false,
              (tools["update_plan"] as? [String: Any])?["enabled"] as? Bool == false else {
            throw failure("La couche de contrôle des outils Codex n’est pas vérifiée ; connexion refusée.")
        }
    }

    private static func mcpNames(_ config: [String: Any]) throws -> [String] {
        guard config["mcp_servers"] == nil || config["mcp_servers"] is [String: Any] else {
            throw failure("Configuration MCP non reconnue.")
        }
        let names = Array((config["mcp_servers"] as? [String: Any] ?? [:]).keys).sorted()
        guard names.count <= 128, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw failure("Configuration MCP trop grande ou non reconnue.")
        }
        return names
    }

    private static func validateRequirements(_ response: [String: Any]) throws {
        guard let requirements = response["requirements"] as? [String: Any] else { return }
        let features = requirements["featureRequirements"] as? [String: Any] ?? [:]
        guard !disabledFeatures.contains(where: { features[$0] as? Bool == true }) else {
            throw failure("Une politique gérée impose une capacité incompatible avec l’enquête sans outils.")
        }
        if let hooks = requirements["hooks"] as? [String: Any], hooks.values.contains(where: { ($0 as? [Any])?.isEmpty == false }) {
            throw failure("Des hooks gérés imposés empêchent cette connexion d’enquête.")
        }
    }

    private static func rpc(_ server: CodexAppServerTransport, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let bytes = try await server.request(method: method, params: JSONSerialization.data(withJSONObject: params), timeoutSeconds: 15)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw failure("Réponse Codex non reconnue.") }
        return object
    }

    private static func toml(_ value: Any) -> String {
        if let value = value as? String {
            let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: bytes, as: UTF8.self)
        }
        if let values = value as? [String: Any] {
            return "{" + values.sorted(by: { $0.key < $1.key }).map { "\(toml($0.key))=\(toml($0.value))" }.joined(separator: ",") + "}"
        }
        if let values = value as? [String: String] { return toml(values.mapValues { $0 as Any }) }
        if let values = value as? [Any] { return "[" + values.map(toml).joined(separator: ",") + "]" }
        if let value = value as? Bool { return value ? "true" : "false" }
        return String(describing: value)
    }

    private static func failure(_ message: String) -> LensError { .unsupported(message) }
}
