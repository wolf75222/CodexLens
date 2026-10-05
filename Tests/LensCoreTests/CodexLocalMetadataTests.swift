import Foundation
import XCTest
@testable import LensCore

final class CodexLocalMetadataTests: XCTestCase {
    /// Explicit metadata-only qualification of the installed user's Codex.
    /// No login/logout, thread/start, thread/resume, turn or model request.
    func testInstalledCodexReusesChatGPTConnectionWithoutInference() async throws {
        guard ProcessInfo.processInfo.environment["LENS_VERIFY_LOCAL_CODEX_METADATA"] == "1" else {
            throw XCTSkip("The local account metadata check requires explicit opt-in.")
        }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LensLocalMetadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CodexInvestigationEngine(registry: CodexInvestigationRegistry(directory: root))
        do {
            let status = try await engine.status()
            XCTAssertTrue(status.isChatGPT)
            XCTAssertEqual(status.version, CodexInvestigationPolicy.supportedVersion)
            XCTAssertFalse(status.models.isEmpty, status.catalogueIssue ?? "Missing model catalogue")
            await engine.shutdown()
            if let path = ProcessInfo.processInfo.environment["LENS_METADATA_RECEIPT"] {
                let receipt: [String: Any] = ["version": status.version, "executable": status.executable,
                    "chatGPTVerified": status.isChatGPT, "modelCount": status.models.count,
                    "limitsAvailable": status.limits != nil, "inferenceRequests": 0,
                    "threadOrTurnRequests": 0, "credentialsReadByLens": false]
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
            }
        } catch { await engine.shutdown(); throw error }
    }
}
