import Foundation
import XCTest
@testable import LensCore

final class CodexInvestigationPolicyTests: XCTestCase {
    func testUnqualifiedVersionFailsBeforeCreatingAWorkspace() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await CodexInvestigationPolicy.launch(executable: URL(fileURLWithPath: "/usr/bin/false"), version: "0.143.0", workspace: workspace)
            XCTFail("An unqualified binary must not start.")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testLaunchArgumentsKeepNativeAuthAndCloseCapabilities() {
        let workspace = URL(fileURLWithPath: "/private/tmp/lens-policy-unit")
        let arguments = CodexInvestigationPolicy.arguments(workspace: workspace)
        XCTAssertEqual(Array(arguments.prefix(4)), ["app-server", "--strict-config", "--listen", "stdio://"])
        XCTAssertFalse(arguments.contains(where: { $0.contains("forced_login_method") || $0.contains("cli_auth_credentials_store") }))
        XCTAssertFalse(arguments.contains(where: { $0.contains("dangerously") || $0.contains("externalSandbox") || $0.contains("danger-full-access") }))
        XCTAssertTrue(arguments.contains("notify=[]"))
        XCTAssertTrue(arguments.contains("features.hooks=false"))
        XCTAssertTrue(arguments.contains("features.plugins=false"))
        XCTAssertTrue(arguments.contains("features.shell_tool=false"))
        XCTAssertTrue(arguments.contains("skills.include_instructions=false"))
        XCTAssertTrue(arguments.contains("skills.bundled.enabled=false"))
        XCTAssertTrue(arguments.contains("default_permissions=\"\(CodexInvestigationPolicy.profileName)\""))
    }

    func testHostInstructionGuardRejectsSymlinksWithoutReadingTheirTarget() throws {
        let home = URL(fileURLWithPath: "/private/tmp/LensInstructions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("synthetic-target.txt")
        try Data("synthetic untrusted instructions".utf8).write(to: target)
        let agents = home.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(at: agents, withDestinationURL: target)
        XCTAssertThrowsError(try CodexInvestigationPolicy.hostSandboxArguments(stateHome: home))
        try FileManager.default.removeItem(at: agents)
        try Data("synthetic global instructions".utf8).write(to: agents)
        let arguments = try CodexInvestigationPolicy.hostSandboxArguments(stateHome: home)
        XCTAssertEqual(arguments.first, "-p")
        XCTAssertTrue(arguments[1].contains("deny file-read*"))
        XCTAssertTrue(arguments[1].contains(agents.path))
    }

    /// Uses the exact installed native binary, an explicit isolated state root,
    /// ephemeral auth, and synthetic files. No thread, turn, login or logout RPC.
    func testNativeIsolatedLaunchDisablesMCPAndEnforcesNamedReadDenials() async throws {
        let executable: URL
        let preferred = ProcessInfo.processInfo.environment["LENS_POLICY_TEST_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
        do { executable = try await CodexInstallation.qualifiedExecutable(preferred: preferred) }
        catch {
            if preferred != nil { throw error }
            throw XCTSkip("Qualified installed Codex binary unavailable.")
        }
        let version = try await CodexInvestigationPolicy.version(executable: executable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LensPolicy-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = root.appendingPathComponent("State"), workspace = root.appendingPathComponent("Context")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mcpMarker = root.appendingPathComponent("mcp-must-not-run")
        let config = """
        cli_auth_credentials_store = "ephemeral"
        [mcp_servers."lens.test"]
        command = "/usr/bin/touch"
        args = [\(quoted(mcpMarker.path))]
        enabled = true
        """
        try Data(config.utf8).write(to: home.appendingPathComponent("config.toml"))
        let server = try await CodexInvestigationPolicy.launch(executable: executable, version: version, workspace: workspace, stateHome: home)
        do {
            _ = try await rpc(server, "initialize", ["clientInfo": ["name": "codex_lens_permissions_test", "title": "Codex Lens Permissions Test", "version": "0.0.1"], "capabilities": ["experimentalApi": true]])
            try await server.notify(method: "initialized")
            try await CodexInvestigationPolicy.verify(server: server, workspace: workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: mcpMarker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
            await server.close()

            // macOS cannot apply a second Seatbelt profile inside sandbox-exec.
            // Independently qualify the native named profile with the same
            // pinned config and isolated synthetic home. Production has no
            // tools/environments and never sends command/exec.
            let native = CodexAppServerTransport(executableURL: executable,
                arguments: CodexInvestigationPolicy.arguments(workspace: workspace) + ["-c", "mcp_servers={\"lens.test\"={enabled=false}}"],
                currentDirectoryURL: workspace,
                environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "CODEX_HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            try await native.start()
            do {
            _ = try await rpc(native, "initialize", ["clientInfo": ["name": "codex_lens_permissions_test", "version": "0.0.1"], "capabilities": ["experimentalApi": true]])
            try await native.notify(method: "initialized")
            try await CodexInvestigationPolicy.verify(server: native, workspace: workspace)

            let allowed = workspace.appendingPathComponent("synthetic-allowed.txt")
            let denied = root.appendingPathComponent("synthetic-denied.txt")
            try Data("ALLOWED_SYNTHETIC_MARKER".utf8).write(to: allowed)
            try Data("DENIED_SYNTHETIC_MARKER".utf8).write(to: denied)
            let readAllowed = try await rpc(native, "command/exec", ["command": ["/bin/cat", allowed.path], "cwd": workspace.path, "permissionProfile": CodexInvestigationPolicy.profileName, "timeoutMs": 3_000, "outputBytesCap": 1_024])
            XCTAssertEqual(readAllowed["exitCode"] as? Int, 0)
            XCTAssertEqual(readAllowed["stdout"] as? String, "ALLOWED_SYNTHETIC_MARKER")
            let readDenied = try await rpc(native, "command/exec", ["command": ["/bin/cat", denied.path], "cwd": workspace.path, "permissionProfile": CodexInvestigationPolicy.profileName, "timeoutMs": 3_000, "outputBytesCap": 1_024])
            XCTAssertNotEqual(readDenied["exitCode"] as? Int, 0)
            XCTAssertFalse((readDenied["stdout"] as? String ?? "").contains("DENIED_SYNTHETIC_MARKER"))
            let writeDenied = try await rpc(native, "command/exec", ["command": ["/usr/bin/touch", workspace.appendingPathComponent("must-not-write").path], "cwd": workspace.path, "permissionProfile": CodexInvestigationPolicy.profileName, "timeoutMs": 3_000, "outputBytesCap": 1_024])
            XCTAssertNotEqual(writeDenied["exitCode"] as? Int, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("must-not-write").path))
            await native.close()
            } catch { await native.close(); throw error }
        } catch {
            await server.close()
            throw error
        }
    }

    private func rpc(_ server: CodexAppServerTransport, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let bytes = try await server.request(method: method, params: JSONSerialization.data(withJSONObject: params), timeoutSeconds: 15)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func quoted(_ value: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
