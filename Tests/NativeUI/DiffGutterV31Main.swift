import AppKit
import SwiftUI
import LensCore
import CryptoKit

/// Render-only fixture of the product diff. No visible window, Dock icon,
/// real session, account or model request. This is not a compositor capture.
@main struct DiffGutterV31Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await render() }
            catch { fputs("Diff render failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor static func render() async throws {
        guard let argument = CommandLine.arguments.firstIndex(of: "--output"),
              argument + 1 < CommandLine.arguments.count else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-codex-home"),
                              investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")),
                              cacheDirectory: output.appendingPathComponent("own-cache"))
        let patch = """
        diff --git a/Example.swift b/Example.swift
        --- a/Example.swift
        +++ b/Example.swift
        @@ -222,2 +222,3 @@
         let previous = true
        +let inserted = true
         let following = true
        """
        let document = try RecordedDiff.parse(patch, provenance: DiffProvenance(
            environmentID: "/anonymous/worktrees/alpha", eventIDs: [], sources: [],
            beforeReference: "fixture-before", afterReference: "fixture-after"))
        var renders: [[String: Any]] = []
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                let size = NSSize(width: 940, height: 650)
                let root = RecordedDiffView(document: document).environmentObject(store)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: root); host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size); window.contentView = host
                for _ in 0..<10 {
                    await Task.yield(); try await Task.sleep(nanoseconds: 20_000_000)
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw LensError.unavailable("No native bitmap")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw LensError.unavailable("No PNG")
                }
                let filename = "diff-columns-\(language.rawValue)-\(dark ? "dark" : "light").png"
                try png.write(to: output.appendingPathComponent(filename))
                renders.append(["file": filename, "bytes": png.count,
                                "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                                "method": "Own product NSHostingView bitmap; not production screenshot"])
                window.contentView = nil; window.close()
            }
        }
        store.stopObserving()
        await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["renderOnly": true, "checks": [], "allExecutedChecksPassed": true,
                                      "renders": renders, "networkDeniedByLauncher": true,
                                      "unqualified": ["Production GUI and physical input: Mac locked", "Side-by-side interaction and VoiceOver", "Performance and live sessions"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
}
