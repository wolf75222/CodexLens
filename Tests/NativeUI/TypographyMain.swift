import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Source-matched native reader qualification. All text is generated below.
/// This replaces production @main; it never injects OS input or makes a request.
@main struct TypographyMain {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let run = TypographyRun()
        Task { @MainActor in
            do { try await run.run() } catch { run.recordFatal(error) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}

@MainActor private final class TypographyState: ObservableObject {
    @Published var text: String
    @Published var fontSize: Double = 13
    @Published var dark = false
    init(text: String) { self.text = text }
}

private enum TypographyReader: String { case prose, code }

@MainActor private struct TypographyReaderFixture: View {
    @ObservedObject var state: TypographyState
    let reader: TypographyReader
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reader == .prose ? "Message enregistré" : "Fichier enregistré")
                .font(.headline)
            Text("Fixture anonyme · contenu en lecture seule · \(Int(state.fontSize)) points demandés")
                .font(.caption).foregroundStyle(.secondary)
            if reader == .prose {
                NativeTextView(text: state.text, monospaced: false, fontSize: state.fontSize)
            } else {
                CodeDocumentView(text: state.text, path: "/anonymous/worktrees/alpha/src/Typography.swift",
                                 versionLabel: "Fragment enregistré · fixture", fontSize: state.fontSize)
            }
        }.padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, state.dark ? .dark : .light)
    }
}

@MainActor private final class TypographyRun {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    private var receipt: [String: Any] = [:]
    private var windows: [NSWindow] = []
    private var stores: [LensStore] = []

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let corpusData = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: corpusData) as? [String: Any],
              manifest["anonymous"] as? Bool == true else { throw failure("Corpus must be explicitly anonymous.") }
        receipt["startedAt"] = Date().ISO8601Format()
        receipt["scope"] = "Unmodified production reader and action implementations in an own NSApplication; production @main is replaced. Native component/model qualification, not the production executable."
        receipt["entrypoint"] = "TypographyMain.swift"
        receipt["corpusManifestSHA256"] = digest(corpusData)
        receipt["fixtureSource"] = "Deterministic generated Unicode/CRLF prose and code; corpus manifest read only, no session traces loaded."
        receipt["networkDeniedByLauncher"] = true
        receipt["realCodexHomeRead"] = false
        receipt["modelRequests"] = 0
        receipt["credentialAccess"] = false
        receipt["interactionMethod"] = "Own NSHostingView, NSTextView, NSScrollView and LensStore APIs. No OS keyboard, accessibility clicks, clipboard or system preferences."
        try await qualifyReader(.prose)
        try await qualifyReader(.code)
        try await qualifyWindowActions()
        receipt["unqualified"] = [
            "Physical ⌘+/⌘− key delivery, focused-scene menu routing, VoiceOver, IME and clipboard are not exercised.",
            "NSHostingView bitmap caching captures own native components; it is not a compositor screenshot or production startup qualification.",
            "The viewport contract preserves vertical pixel origin and horizontal offset relative to the native ruler; preserving the same semantic line after font reflow is not asserted.",
            "Typography of other screens, genuine streaming sessions, performance, historical provenance and actual model responses are outside this bounded probe."
        ]
        receipt["finishedAt"] = Date().ISO8601Format()
        await cleanUp()
        try saveReceipt()
    }

    private func qualifyReader(_ reader: TypographyReader) async throws {
        let marker = "repère 🧭 café e\u{301}"
        let lines = (0..<700).map { index -> String in
            if reader == .prose {
                return "\(index) — Message enregistré : contexte, instruction et résultat. \(marker)\r\n"
            }
            return "let valeur\(index) = \(index) // Contexte enregistré : \(marker)\r\n"
        }
        let original = lines.joined()
        let state = TypographyState(text: original)
        let host = NSHostingView(rootView: TypographyReaderFixture(state: state, reader: reader))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Codex Lens — typography qualification (anonymous)"
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.appearance = NSAppearance(named: .aqua)
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await settle(host)
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let editor = scroll.documentView as? NSTextView else { throw failure("Actual native \(reader.rawValue) reader not found.") }
        check(reader.rawValue + "-read-only-selectable", !editor.isEditable && editor.isSelectable)
        check(reader.rawValue + "-initial-bytes-exact", Data(editor.string.utf8) == Data(original.utf8))
        check(reader.rawValue + "-initial-font-13", fontsMatch(editor, requested: 13))
        let fontTraits = editor.font?.fontDescriptor.symbolicTraits ?? []
        check(reader.rawValue + "-appropriate-system-font", reader == .code ? fontTraits.contains(.monoSpace) : !fontTraits.contains(.monoSpace))
        observe(reader.rawValue + "-initial-before-scroll", editor: editor, scroll: scroll)

        let document = original as NSString
        let prefixLength = (lines.prefix(50).joined() as NSString).length
        let search = NSRange(location: prefixLength, length: document.length - prefixLength)
        let selected = document.range(of: marker, options: .literal, range: search)
        guard selected.location != NSNotFound else { throw failure("Unicode selection fixture absent.") }
        editor.setSelectedRange(selected)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        // NSScrollView uses a negative native X origin to reserve its ruler.
        // Forcing X=0 would hide the first glyphs beneath that ruler.
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 650))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = readingOrigin(scroll)
        observe(reader.rawValue + "-initial-after-scroll", editor: editor, scroll: scroll)
        check(reader.rawValue + "-nonzero-viewport-established", origin.y > 100)
        check(reader.rawValue + "-selection-is-utf16-with-surrogate", selected.length == (marker as NSString).length && selected.length > marker.count)
        if reader == .code { check("code-font-13-first-glyph-beyond-ruler", leadingGlyphClearance(editor, scroll: scroll) >= 0) }
        try await capturePair(reader: reader, size: 13, state: state, host: host, window: window)

        for size in [18.0, 24.0] {
            state.fontSize = size
            try await settle(host)
            check(reader.rawValue + "-font-\(Int(size))-applied-everywhere", fontsMatch(editor, requested: size))
            check(reader.rawValue + "-font-\(Int(size))-bytes-preserved", Data(editor.string.utf8) == Data(original.utf8))
            check(reader.rawValue + "-font-\(Int(size))-utf16-selection-preserved", editor.selectedRange() == selected && selectedString(editor) == marker)
            check(reader.rawValue + "-font-\(Int(size))-viewport-preserved", near(readingOrigin(scroll), origin))
            check(reader.rawValue + "-font-\(Int(size))-native-reader-not-replaced", scroll.documentView === editor)
            if reader == .code { check("code-font-\(Int(size))-first-glyph-beyond-ruler", leadingGlyphClearance(editor, scroll: scroll) >= 0) }
            observe(reader.rawValue + "-font-\(Int(size))", editor: editor, scroll: scroll)
            observations.append(["reader": reader.rawValue, "fontSize": size, "originX": scroll.contentView.bounds.origin.x,
                                 "originY": scroll.contentView.bounds.origin.y, "selectionLocationUTF16": editor.selectedRange().location,
                                 "selectionLengthUTF16": editor.selectedRange().length, "textSHA256": digest(Data(editor.string.utf8))])
            try await capturePair(reader: reader, size: size, state: state, host: host, window: window)
        }

        // Both publications happen in the same main-actor transaction. SwiftUI
        // must deliver one coherent reader update rather than reset selection.
        let appendix = "\r\nNouvelle sortie enregistrée 🧪 — caractères exacts, sans normalisation.\r\n"
        state.fontSize = 18
        state.text = original + appendix
        try await settle(host)
        observe(reader.rawValue + "-font-and-append", editor: editor, scroll: scroll)
        check(reader.rawValue + "-font-and-append-exact-bytes", Data(editor.string.utf8) == Data((original + appendix).utf8))
        check(reader.rawValue + "-font-and-append-font-uniform", fontsMatch(editor, requested: 18))
        check(reader.rawValue + "-font-and-append-selection-preserved", editor.selectedRange() == selected && selectedString(editor) == marker)
        check(reader.rawValue + "-font-and-append-viewport-preserved", near(readingOrigin(scroll), origin))
        check(reader.rawValue + "-font-and-append-native-reader-not-replaced", scroll.documentView === editor)
        if reader == .code { check("code-font-and-append-first-glyph-beyond-ruler", leadingGlyphClearance(editor, scroll: scroll) >= 0) }

        for (requested, expected) in [(4.0, 10.0), (40.0, 24.0)] {
            state.fontSize = requested
            try await settle(host)
            observe(reader.rawValue + "-clamp-\(Int(expected))", editor: editor, scroll: scroll)
            check(reader.rawValue + "-clamp-request-\(Int(requested))-to-\(Int(expected))", fontsMatch(editor, requested: expected))
            check(reader.rawValue + "-clamp-\(Int(expected))-preserves-bytes-and-selection", Data(editor.string.utf8) == Data(state.text.utf8) && editor.selectedRange() == selected && selectedString(editor) == marker)
            check(reader.rawValue + "-clamp-\(Int(expected))-preserves-viewport", near(readingOrigin(scroll), origin))
        }
        // A shorter replacement cannot retain an out-of-document selection or
        // viewport. Its UTF-16 range must clamp to the end of the actual bytes.
        let shortened = "Version plus courte 🧭\r\n"
        state.fontSize = 13
        state.text = shortened
        try await settle(host)
        observe(reader.rawValue + "-shorten", editor: editor, scroll: scroll)
        let shortenedLength = (shortened as NSString).length
        check(reader.rawValue + "-shorten-and-font-exact-bytes", Data(editor.string.utf8) == Data(shortened.utf8))
        check(reader.rawValue + "-shorten-and-font-applied", fontsMatch(editor, requested: 13))
        check(reader.rawValue + "-shorten-clamps-utf16-selection", editor.selectedRange() == NSRange(location: shortenedLength, length: 0))
        let shortenedOrigin = scroll.contentView.bounds.origin
        let maximumY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        check(reader.rawValue + "-shorten-viewport-valid", shortenedOrigin.y.isFinite && shortenedOrigin.y >= 0 && shortenedOrigin.y <= maximumY + 1)
        check(reader.rawValue + "-shorten-native-reader-not-replaced", scroll.documentView === editor)
        receipt[reader.rawValue + "Fixture"] = ["originalBytes": Data(original.utf8).count, "originalSHA256": digest(Data(original.utf8)),
                                                "appendedBytes": Data(appendix.utf8).count, "lineCount": lines.count,
                                                "selectedUTF16Location": selected.location, "selectedUTF16Length": selected.length,
                                                "initialRulerRelativeOriginX": origin.x, "initialOriginY": origin.y]
        if let codeHost = descendants(host).compactMap({ $0 as? CodeDocumentHost }).first { codeHost.cancelAnalysis() }
        window.close()
    }

    private func qualifyWindowActions() async throws {
        let runtime = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        func makeStore(_ name: String) -> LensStore {
            LensStore(sourceHome: runtime.appendingPathComponent(name + "-empty-source"),
                      investigationArchive: InvestigationArchive(directory: runtime.appendingPathComponent(name + "-archive")),
                      cacheDirectory: runtime.appendingPathComponent(name + "-cache"))
        }
        let first = makeStore("first"), second = makeStore("second")
        stores = [first, second]
        first.setNavigationScope(UUID().uuidString); second.setNavigationScope(UUID().uuidString)
        check("default-reading-size-13-in-two-independent-windows", first.fontSize == 13 && second.fontSize == 13 && first.windowIdentity != second.windowIdentity)
        first.perform(.largerText)
        check("larger-action-increases-one-point-and-is-window-local", first.fontSize == 14 && second.fontSize == 13)
        first.perform(.smallerText)
        check("smaller-action-decreases-one-point-and-is-window-local", first.fontSize == 13 && second.fontSize == 13)
        for _ in 0..<30 { first.perform(.largerText) }
        check("larger-action-upper-bound-disabled-and-no-overshoot", first.fontSize == 24 && !first.canPerform(.largerText) && first.canPerform(.smallerText) && second.fontSize == 13)
        first.perform(.largerText)
        check("disabled-larger-action-is-idempotent", first.fontSize == 24 && second.fontSize == 13)
        for _ in 0..<30 { first.perform(.smallerText) }
        check("smaller-action-lower-bound-disabled-and-no-overshoot", first.fontSize == 10 && !first.canPerform(.smallerText) && first.canPerform(.largerText) && second.fontSize == 13)
        first.perform(.smallerText)
        check("disabled-smaller-action-is-idempotent", first.fontSize == 10 && second.fontSize == 13)
        second.perform(.largerText)
        check("second-window-action-does-not-change-first", second.fontSize == 14 && first.fontSize == 10)
        receipt["commandQualification"] = "Actual LensStore.canPerform/perform implementations shared by largerText (⌘+) and smallerText (⌘−), with two independent per-window stores; physical key and menu routing are not inferred."
    }

    private func settle<V: View>(_ host: NSHostingView<V>) async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
    }

    private func capturePair(reader: TypographyReader, size: Double, state: TypographyState,
                             host: NSHostingView<TypographyReaderFixture>, window: NSWindow) async throws {
        for theme in ["light", "dark"] {
            state.dark = theme == "dark"
            window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
            try await settle(host)
            window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No own native bitmap.") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("No native PNG data.") }
            let filename = "typography-\(reader.rawValue)-\(Int(size))-\(theme).png"
            try png.write(to: output.appendingPathComponent(filename))
            renders.append(["filename": filename, "reader": reader.rawValue, "fontSize": size, "theme": theme,
                            "logicalWidth": host.bounds.width, "logicalHeight": host.bounds.height,
                            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                            "bytes": png.count, "sha256": digest(png), "anonymous": true,
                            "method": "Own NSHostingView bitmap cache, not compositor screenshot"])
        }
    }

    private func fontsMatch(_ editor: NSTextView, requested: Double) -> Bool {
        guard abs((editor.font?.pointSize ?? 0) - requested) < 0.01,
              let storage = editor.textStorage, storage.length > 0 else { return false }
        var uniform = true
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let font = value as? NSFont, abs(font.pointSize - requested) < 0.01 else { uniform = false; return }
        }
        return uniform
    }
    private func selectedString(_ editor: NSTextView) -> String? {
        let text = editor.string as NSString, range = editor.selectedRange()
        guard range.location != NSNotFound, range.location <= text.length, range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func near(_ actual: NSPoint, _ expected: NSPoint) -> Bool { abs(actual.x - expected.x) <= 1 && abs(actual.y - expected.y) <= 1 }
    private func readingOrigin(_ scroll: NSScrollView) -> NSPoint {
        // Exact native geometry observed in this NSScrollView: X=-rulerWidth
        // represents the start of a read-only document, not horizontal scrolling.
        let origin = scroll.contentView.bounds.origin
        return NSPoint(x: origin.x + (scroll.verticalRulerView?.ruleThickness ?? 0), y: origin.y)
    }
    private func observe(_ stage: String, editor: NSTextView, scroll: NSScrollView) {
        let constrained = scroll.contentView.constrainBoundsRect(scroll.contentView.bounds)
        let rulerFrame = scroll.verticalRulerView.map { $0.convert($0.bounds, to: scroll) } ?? .zero
        let clipFrame = scroll.contentView.convert(scroll.contentView.bounds, to: scroll)
        let editorFrame = editor.convert(editor.bounds, to: scroll)
        observations.append(["stage": stage, "fontSize": editor.font?.pointSize ?? 0,
                             "originX": scroll.contentView.bounds.origin.x, "originY": scroll.contentView.bounds.origin.y,
                             "rulerRelativeOriginX": readingOrigin(scroll).x,
                             "clipHeight": scroll.contentView.bounds.height, "documentHeight": scroll.documentView?.bounds.height ?? 0,
                             "constrainedOriginX": constrained.origin.x, "constrainedOriginY": constrained.origin.y,
                             "contentInsetLeft": scroll.contentInsets.left, "contentInsetTop": scroll.contentInsets.top,
                             "editorFrameInScrollX": editorFrame.minX, "editorFrameInScrollY": editorFrame.minY,
                             "clipFrameInScrollX": clipFrame.minX, "clipFrameInScrollY": clipFrame.minY,
                             "rulerFrameInScrollX": rulerFrame.minX, "rulerFrameInScrollRight": rulerFrame.maxX,
                             "rulerThickness": scroll.verticalRulerView?.ruleThickness ?? 0,
                             "leadingGlyphClearanceFromRuler": leadingGlyphClearance(editor, scroll: scroll),
                             "selectionLocationUTF16": editor.selectedRange().location, "selectionLengthUTF16": editor.selectedRange().length,
                             "textSHA256": digest(Data(editor.string.utf8))])
    }
    private func leadingGlyphClearance(_ editor: NSTextView, scroll: NSScrollView) -> CGFloat {
        guard let ruler = scroll.verticalRulerView, let layout = editor.layoutManager, let container = editor.textContainer,
              layout.numberOfGlyphs > 0 else { return 0 }
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        let glyphInScroll = editor.convert(glyph, to: scroll)
        let rulerInScroll = ruler.convert(ruler.bounds, to: scroll)
        return glyphInScroll.minX - rulerInScroll.maxX
    }
    private func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
    private func saveReceipt() throws {
        receipt["checks"] = checks; receipt["renders"] = renders; receipt["observations"] = observations
        receipt["allExecutedChecksPassed"] = checks.allSatisfy { $0["passed"] as? Bool == true }
        receipt["failedCheckIDs"] = checks.filter { $0["passed"] as? Bool == false }.compactMap { $0["id"] as? String }
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"), options: .atomic)
    }
    private func cleanUp() async {
        for store in stores { store.stopObserving(); await store.investigation.flushAndStop() }
        for window in windows { window.close() }
    }
    func recordFatal(_ error: Error) {
        checks.append(["id": "fatal", "passed": false, "message": error.localizedDescription])
        for store in stores { store.stopObserving() }
        for window in windows { window.close() }
        receipt["finishedAt"] = Date().ISO8601Format()
        try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw failure("Missing " + name) }
        return CommandLine.arguments[index + 1]
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensTypographyProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
