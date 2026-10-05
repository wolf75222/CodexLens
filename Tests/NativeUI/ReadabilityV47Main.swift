import AppKit
import SwiftUI
import LensCore

@main struct ReadabilityV47Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run() }
            catch { fputs("READABILITY_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        func argument(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
        let output = URL(fileURLWithPath: argument("--output"))
        let corpus = URL(fileURLWithPath: argument("--corpus"))
        var checks: [String] = []
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "Readability", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        func allTextViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(allTextViews) }
        let source = "# Instructions QA\n\nInspecter les deux worktrees **sans modifier** leurs fichiers.\n\n- Garder le contexte\n- Consulter les sources\n\n```swift\nlet version = 1\n```\n"
        let markdown = try await Task.detached { try ChatMarkdownParser.parse(source) }.value
        let attributes = RecordedMarkdownTypography.render(markdown, fontSize: 14, codeFont: .system)
        try check(attributes.string.contains("Instructions QA") && !attributes.string.hasPrefix("#"), "Native Markdown heading omits syntax")
        try check(attributes.string.contains("sans modifier") && attributes.string.contains("let version = 1"), "Narrative and code content retained")
        try check(markdown.source == source, "Original Markdown is retained unchanged")
        let headingFont = attributes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check((headingFont?.pointSize ?? 0) > 14, "Heading has an explicit typographic hierarchy")
        let proseRange = (attributes.string as NSString).range(of: "Inspecter")
        let proseFont = attributes.attribute(.font, at: proseRange.location, effectiveRange: nil) as? NSFont
        try check(proseFont?.isFixedPitch == false, "Prose uses a proportional font")
        let codeRange = (attributes.string as NSString).range(of: "let version")
        let codeFont = attributes.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        try check(codeFont?.isFixedPitch == true, "Code remains monospaced")
        let host = NSHostingView(rootView: NativeTextView(text: source, fontSize: 14, markdown: markdown))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 860, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        let native = try XCTLikeUnwrap(allTextViews(host).first, "Native NSTextView missing")
        try check(native.isSelectable && !native.isEditable && native.usesFindBar, "Read-only native selection, copy and Find are available")
        try check(native.string == attributes.string, "NSTextView receives the formatted document")
        native.setSelectedRange(proseRange)
        let selected = native.selectedRange()
        let prefix = source + "\nAutre paragraphe."
        let next = try await Task.detached { try ChatMarkdownParser.parse(prefix) }.value
        host.rootView = NativeTextView(text: prefix, fontSize: 14, markdown: next)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(native.selectedRange() == selected, "Loading another page preserves selection in the existing prefix")
        window.close()

        let store = LensStore(sourceHome: corpus.appendingPathComponent("codex-home"),
                              investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
                              cacheDirectory: output.appendingPathComponent("cache"))
        await store.open("11111111-1111-4111-8111-111111111111")
        let snapshot = try XCTLikeUnwrap(store.snapshot, "Anonymous session did not open")
        let call = try XCTLikeUnwrap(snapshot.events.first { $0.kind == .toolCall && $0.preview.contains("Instructions.md") }, "Instructions call not found")
        for _ in 0..<100 where store.event(call.id) == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        try check(store.event(call.id) != nil, "Session presentation index resolves the selected call")
        for appearance in ["light", "dark"] {
            let preview = NSHostingView(rootView: LensLivePreviewView(destination: .event(call.id), temporary: false).environmentObject(store))
            let frame = NSRect(x: 50, y: 50, width: 1000, height: 680)
            let viewWindow = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            viewWindow.isReleasedWhenClosed = false; viewWindow.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            viewWindow.contentView = preview; viewWindow.orderFront(nil)
            try await Task.sleep(nanoseconds: 350_000_000); preview.layoutSubtreeIfNeeded()
            let initialViews = allTextViews(preview)
            try check(!initialViews.isEmpty, "Real call preview hosts the native reader: " + appearance)
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                try bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: output.appendingPathComponent("call-input-" + appearance + ".png"))
            }
            viewWindow.close()
            let outputHost = NSHostingView(rootView: RecordedEventText(event: call, part: "output").environmentObject(store))
            let outputWindow = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            outputWindow.isReleasedWhenClosed = false; outputWindow.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            outputWindow.contentView = outputHost; outputWindow.orderFront(nil)
            try await Task.sleep(nanoseconds: 350_000_000); outputHost.layoutSubtreeIfNeeded()
            let outputText = try XCTLikeUnwrap(allTextViews(outputHost).first, "Output NSTextView missing")
            try check(outputText.string.contains("Instructions QA"), "Output presents recorded instructions: " + appearance)
            try check(!outputText.string.contains("[Couverture") && !outputText.string.contains("rollout-2026"), "Generated journal metadata is outside the body: " + appearance)
            try check(!outputText.string.hasPrefix("#"), "Recorded Markdown uses a formatted heading: " + appearance)
            if let bitmap = outputHost.bitmapImageRepForCachingDisplay(in: outputHost.bounds) {
                outputHost.cacheDisplay(in: outputHost.bounds, to: bitmap)
                try bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?.write(to: output.appendingPathComponent("call-output-" + appearance + ".png"))
            }
            outputWindow.close()
        }
        store.stopObserving()
        let receipt: [String: Any] = ["allExecutedChecksPassed": true, "checks": checks,
            "unqualified": ["Component captures are native NSHostingView renders, not Dock screenshots", "Physical keyboard/trackpad not driven by this probe", "No macOS 14 or Intel runtime"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }
    static func XCTLikeUnwrap<T>(_ value: T?, _ error: String) throws -> T {
        guard let value else { throw NSError(domain: "Readability", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }; return value
    }
}
