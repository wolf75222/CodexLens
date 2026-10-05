import AppKit
import Foundation
import LensCore
import SwiftUI

/// Source-matched connection-state checks; synthetic metadata, no credentials,
/// network, thread/turn creation or model request. Real metadata is tested separately.
@main struct LocalCodexV72Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Local Codex qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--output")! + 1])
        var checks: [[String: Any]] = [], renders: [String] = []
        let counter = MetadataCounter()
        let connected = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("connected-archive")), statusProvider: { _ in
            await counter.increment()
            return Self.metadata("chatgpt")
        })
        connected.model = ""
        connected.ensureChatContext(rootID: "anonymous-connection-source")
        connected.editChatQuestion("Explain this session.")
        await connected.refreshConnection()
        await connected.refreshConnection()
        let requests = await counter.value
        checks.append(["name": "automatic-existing-chatgpt-is-ready-with-default-model", "passed":
            requests == 1 && connected.connectionReady && connected.model == "anonymous-model"
            && connected.canSendChatMessage && connected.question == "Explain this session."
            && !connected.sending && connected.codexChatID == nil])
        await connected.flushAndStop()

        for auth in ["chatgpt", "signedOut", "apiKey", "processFailure"] {
            let store = LensStore(sourceHome: output.appendingPathComponent("empty-" + auth),
                investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive-" + auth)),
                cacheDirectory: output.appendingPathComponent("cache-" + auth))
            store.investigation.automaticCodexCheckEnabled = false
            let investigator = InvestigationStore(archive: store.investigation.archive, statusProvider: { _ in
                if auth == "processFailure" { throw CodexAppServerTransportError.transportClosed }
                return Self.metadata(auth)
            })
            investigator.automaticCodexCheckEnabled = false
            investigator.model = ""
            investigator.ensureChatContext(rootID: "anonymous-connection-source")
            investigator.editChatQuestion("Keep my draft.")
            investigator.useLocalCodex()
            for _ in 0..<100 where investigator.connecting { try await Task.sleep(for: .milliseconds(5)) }
            checks.append(["name": auth + "-retains-account-state-and-draft-without-send", "passed":
                !investigator.connecting && investigator.connectionMode == .codex
                && investigator.codexStatus?.authentication == (auth == "processFailure" ? nil : auth)
                && investigator.connectionReady == (auth == "chatgpt")
                && investigator.question == "Keep my draft." && !investigator.sending && investigator.codexChatID == nil])
            for language in [LensL10n.Language.fr, .en] {
                LensL10n.language = language
                let dark = language == .en
                let name = "local-codex-\(auth)-\(language.rawValue)"
                let host = NSHostingView(rootView: InvestigationView(investigator: investigator)
                    .environmentObject(store).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: 460, height: 650)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No native bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
                try png.write(to: output.appendingPathComponent(name + ".png"))
                renders.append(name + ".png")
                checks.append(["name": name + "-render-does-not-send-or-lose-draft", "passed":
                    investigator.question == "Keep my draft." && !investigator.sending && investigator.codexChatID == nil])
                window.contentView = nil
            }
            await investigator.flushAndStop()
            store.stopObserving(); await store.investigation.flushAndStop()
        }
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "modelRequests": 0, "anonymousMetadataOnly": true,
            "unqualified": ["Authenticated inference", "Physical input", "VoiceOver"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    private static func metadata(_ auth: String) -> CodexLocalConnectionStatus {
        CodexLocalConnectionStatus(version: "0.159.2", executable: "/anonymous/Codex.app/Contents/Resources/codex",
            authentication: auth, email: nil, plan: nil,
            models: auth == "chatgpt" ? [CodexLocalModel(id: "anonymous-model", displayName: "Anonymous model", isDefault: true)] : [], limits: nil)
    }
}

private actor MetadataCounter {
    var value = 0
    func increment() { value += 1 }
}
