import AppKit
import Foundation
import LensCore
import SwiftUI

/// Native chat variants on frozen anonymous evidence. No visible window, Dock
/// item, Codex process, credential query, network request or observed source.
@main struct SideChatV34Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Side chat v34 qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else {
            throw LensError.unavailable("Missing --output")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var checks: [[String: Any]] = [], renders: [[String: Any]] = []
        for symbol in ["square.and.pencil", "arrow.down"] {
            checks.append(["name": "chat-symbol-" + symbol, "passed": LensSymbols.name(symbol) == symbol
                && NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil])
        }
        let cut = Date(timeIntervalSince1970: 1_759_320_000)
        let pieces = (1...12).map { ordinal in
            EvidencePiece(id: String(format: "E%03d", ordinal), kind: "recordedDiff",
                title: "Sources/AnonymousVeryLongInvestigationFile\(ordinal).swift",
                text: "Recorded fixture patch; not an actual current file.\n-old\n+new",
                environmentID: "/anonymous/worktrees/alpha", knownVersion: "fixture-captured-version-\(ordinal)", capturedAt: cut)
        }
        let capsule = try EvidenceCapsule.build(rootThreadID: "anonymous-sidechat-root", collectionCut: cut,
            pieces: pieces, omissions: [EvidenceOmission(reason: "Anonymous missing historical bytes; current state not substituted.")], createdAt: cut)
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-home"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")),
            cacheDirectory: output.appendingPathComponent("own-cache"))
        store.investigation.capsule = capsule
        store.investigation.connectionMode = .api // RAM fixture only; never selected by the production UI.
        store.investigation.apiKey = "fixture-only-never-sent"
        store.investigation.model = String(repeating: "anonymous-very-long-model-name-", count: 4)
        store.investigation.question = "Explique le diff capturé et distingue les faits des données absentes."
        store.investigation.response = "Réponse locale synthétique pour éprouver la lecture. [E001] Aucune inférence n’a été exécutée."
        let originalQuestion = store.investigation.question
        let originalDigest = capsule.digestSHA256
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                for size in [NSSize(width: 320, height: 520), NSSize(width: 460, height: 760)] {
                    for expanded in [false, true] {
                        let name = "sidechat-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))-\(expanded ? "expanded" : "compact")"
                        let view = InvestigationView(investigator: store.investigation,
                            initiallyExpandedEvidence: expanded)
                            .environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
                        let result = try await render(AnyView(view), size: size, name: name, dark: dark, output: output)
                        renders.append(result)
                        checks.append(["name": name + "-editor-contained", "passed": result["editorContained"] as? Bool == true])
                        checks.append(["name": name + "-no-send-or-context-change", "passed": !store.investigation.sending
                            && store.investigation.codexChatID == nil && store.investigation.question == originalQuestion
                            && store.investigation.capsule?.digestSHA256 == originalDigest])
                    }
                }
            }
        }
        store.stopObserving(); await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual source-matched detached NSHostingView chat bitmaps and native editable text-view frames, with synthetic local response, twelve frozen evidence pieces, long model label, and expanded disclosures. Activation prohibited; no visible window or Dock item; no inference or credentials.",
            "unqualified": ["Production compositor capture", "Physical pointer and keyboard", "VoiceOver", "Send/cancellation or authenticated inference"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    @MainActor private static func render(_ view: AnyView, size: NSSize, name: String, dark: Bool, output: URL) async throws -> [String: Any] {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .textBackgroundColor)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<25 {
            await Task.yield(); try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        var queue = [host as NSView], index = 0, editorFrames: [CGRect] = []
        while index < queue.count {
            let view = queue[index]; index += 1
            if let editor = view as? NSTextView, editor.isEditable {
                // Document height can grow while editing. The enclosing clip
                // view is the actual readable/interactive editor viewport.
                let viewport: NSView
                if let clip = editor.enclosingScrollView?.contentView { viewport = clip }
                else { viewport = editor }
                editorFrames.append(host.convert(viewport.bounds, from: viewport))
            }
            queue.append(contentsOf: view.subviews)
        }
        let contained = !editorFrames.isEmpty && editorFrames.allSatisfy {
            $0.width > 0 && $0.height >= 20 && host.bounds.insetBy(dx: -1, dy: -1).contains($0)
        }
        return ["file": name + ".png", "width": size.width, "height": size.height,
            "editorContained": contained,
            "nativeEditorViewportFrames": editorFrames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
            "method": "Own offscreen NSHostingView bitmap and native NSTextView viewport; not a production screenshot"]
    }
}
