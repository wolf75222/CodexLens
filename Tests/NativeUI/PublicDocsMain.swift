import AppKit
import SwiftUI
import LensCore

/// Offline native component renders from an anonymous on-disk history.
/// No Codex process, account request, inference, or observed user session.
@main struct PublicDocsMain {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await capture() }
            catch { fputs("Native documentation capture failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func capture() async throws {
        let args = CommandLine.arguments
        func argument(_ name: String) throws -> URL {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { throw LensError.unavailable("Missing " + name) }
            return URL(fileURLWithPath: args[i + 1])
        }
        let output = try argument("--output"), corpus = try argument("--corpus")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any]
        guard manifest?["anonymous"] as? Bool == true, let home = manifest?["home"] as? String,
              let rootID = manifest?["rootID"] as? String else { throw LensError.unavailable("Anonymous corpus required") }
        LensL10n.language = .en
        UserDefaults.standard.set("en", forKey: "lens.language")
        UserDefaults.standard.set("dark", forKey: "lensAppearance")
        UserDefaults.standard.set("lens", forKey: "lensControlAccent")
        UserDefaults.standard.set(true, forKey: LensOnboardingState.preferenceKey)
        let store = LensStore(sourceHome: URL(fileURLWithPath: home),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"))
        store.investigation.automaticCodexCheckEnabled = false
        store.setNavigationScope(UUID().uuidString)
        await store.start(); await store.open(rootID); await store.waitForPresentation()
        guard let snapshot = store.snapshot, snapshot.root.id == rootID, store.error == nil,
              let call = snapshot.events.first(where: { $0.kind == .toolCall }),
              let change = snapshot.changes.first(where: { $0.path.hasSuffix("/Same.swift") && $0.kind == .requestedPatch })
        else { throw LensError.unavailable("Incomplete anonymous fixture") }
        let context = LensWindowContext(store: store)
        var renders: [String] = []
        // One host/window preserves toolbar ownership while the model changes.
        // Creating detached MainViews with a shared toolbar ID in several bare
        // AppKit windows causes a duplicate native sidebar item assertion.
        let host = NSHostingView(rootView: MainView().environmentObject(store)
            .environment(\.lensWindowContext, context).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
        defer { window.contentView = nil; window.close() }
        func render(_ name: String) async throws {
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No native bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
            try png.write(to: output.appendingPathComponent(name + ".png")); renders.append(name + ".png")
        }
        store.showSessionPicker = false; store.chatVisible = false; store.inspectorVisible = false
        store.browseSection(.activity); store.showInTimeline(call.id); await store.waitForPresentation()
        try await render("activity")
        store.navigate(.change(change.id)); await store.waitForPresentation()
        try await render("diff")
        guard await store.prepareInvestigation(for: .change(change.id)) else { throw LensError.unavailable("Cannot prepare fixture context") }
        store.navigate(.change(change.id)); store.chatVisible = true
        store.investigation.editChatQuestion("Explain this change and show the relevant instructions.")
        try await render("chat")
        store.stopObserving(); await store.investigation.flushAndStop()
        let checks: [[String: Any]] = [
            ["name": "anonymous-history-loaded", "passed": snapshot.root.id == rootID],
            ["name": "diff-retains-environment", "passed": !change.environmentID.isEmpty],
            ["name": "context-prepared-without-send", "passed": !store.investigation.sending && store.investigation.codexChatID == nil],
            ["name": "native-three-view-renders", "passed": renders.count == 3]
        ]
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "method": "Native NSHostingView renders, current source, synthetic on-disk sessions",
            "modelRequests": 0, "accountRequests": 0,
            "unqualified": ["OS compositor screenshot", "Physical input", "VoiceOver"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
}
