import AppKit
import SwiftUI
import CryptoKit
import LensCore

/// Actual native component bounds on anonymous sources, without a visible app or account.
@main struct TextBoundsV33Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Text bounds qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var checks: [[String: Any]] = [], renders: [[String: Any]] = []
        func check(_ name: String, _ result: Bool) throws {
            checks.append(["name": name, "passed": result])
            guard result else { throw LensError.corrupt(name) }
        }
        func source(_ name: String, _ payload: [String: Any]) throws -> SourceRef {
            let data = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload], options: [.sortedKeys])
            let file = output.appendingPathComponent(name + ".jsonl"); try data.write(to: file)
            return SourceRef(path: file.path, length: data.count, line: 1, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let rootID = "11111111-1111-4111-8111-111111111111"
        let messageSource = try source("anonymous-message", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Corrige la présentation tout en conservant les preuves."]]])
        let outputSource = try source("anonymous-output", ["type": "function_call_output", "call_id": "read-1", "output": String(repeating: "Texte enregistré et conservé ; aucune donnée réelle.\n", count: 9000)])
        let patch = "*** Begin Patch\n*** Update File: src/VeryLongRecordedFileName.swift\n@@\n-old\n+new\n*** End Patch"
        let patchSource = try source("anonymous-patch", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "patch-1", "input": patch])
        let patchSource2 = try source("anonymous-patch-2", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "patch-1", "input": patch.replacingOccurrences(of: "+new", with: "+other")])
        let message = LensEvent(id: "message", agentID: rootID, kind: .user, source: messageSource)
        let reading = LensEvent(id: "result", agentID: rootID, kind: .toolResult, title: "Résultat enregistré", callID: "read-1", source: outputSource)
        let patchEvent = LensEvent(id: "patch", agentID: rootID, kind: .toolCall, title: "apply_patch", toolName: "apply_patch", callID: "patch-1", environmentID: "/anonymous/worktrees/alpha", source: patchSource, supplementarySources: [patchSource2])
        let change = ChangeRecord(id: "change", path: "/anonymous/worktrees/alpha/src/VeryLongRecordedFileName.swift", environmentID: "/anonymous/worktrees/alpha", agentID: rootID, eventID: patchEvent.id, kind: .requestedPatch)
        let snapshot = SessionSnapshot(root: SessionSummary(id: rootID, title: String(repeating: "Titre long — café 🧭 / ", count: 12)),
            agents: [], events: [message, reading, patchEvent], environments: [], resources: [], changes: [change], coverage: [], collectedAt: Date())
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-home"), investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("own-archive")), cacheDirectory: output.appendingPathComponent("own-cache"))
        store.snapshot = snapshot
        let selection = try RecordedChangeEvidence.select(change: change, event: patchEvent, related: nil)
        let detail = try await store.engine.sourceDetail(for: patchEvent)
        let parsedDocumentCount = try RecordedChangeEvidence.documents(change: change, selection: selection, detail: detail).count
        try check("Fixture includes multiple parsed recorded patch traces (\(parsedDocumentCount))", parsedDocumentCount > 1)
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language
            for dark in [false, true] {
                for width in [140.0, 180.0, 240.0, 300.0] {
                    let title = "Session 11111111 · " + String(repeating: "long / ", count: 10)
                    let canvas = ZStack {
                        dark ? Color.black : Color.white
                        LensSessionToolbarTitle(title: title).frame(width: width, height: 44).position(x: 250, y: 50)
                    }
                    let name = "title-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width))"
                    let rendered = try await render(AnyView(canvas), size: NSSize(width: 500, height: 100), name: name, dark: dark, output: output)
                    let outside = inkOutside(rendered.bitmap, width: width, dark: dark)
                    try check(name + "-ink-contained", outside == 0)
                    if !rendered.labels.isEmpty {
                        try check(name + "-full-accessible-title", rendered.labels.contains(where: { $0.contains(title) && $0.contains(LensL10n.text("Inspection locale · sources en lecture seule")) }))
                    }
                    renders.append(rendered.record.merging(["inkOutsideProposedBounds": outside]) { _, new in new })
                }
                for width in [430.0, 1080.0] {
                    let name = "diff-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width))"
                    let rendered = try await render(AnyView(RecordedChangeView(change: change).environmentObject(store)), size: NSSize(width: width, height: 600), name: name, dark: dark, output: output)
                    for label in ["Ouvrir l’action et son contexte", "Ouvrir le fichier actuel", "Demander à l’IA…"] {
                        if !rendered.labels.isEmpty { try check(name + "-" + label, rendered.containedLabels.contains(LensL10n.text(label))) }
                    }
                    renders.append(rendered.record)
                }
                let inspectorName = "inspector-\(language.rawValue)-\(dark ? "dark" : "light")-320"
                let inspector = try await render(AnyView(RecordedEventText(event: reading, part: "output").environmentObject(store)), size: NSSize(width: 320, height: 540), name: inspectorName, dark: dark, output: output)
                if !inspector.labels.isEmpty {
                    try check(inspectorName + "-copy-contained", inspector.containedLabels.contains(LensL10n.text("Copier")))
                    try check(inspectorName + "-next-page-contained", inspector.containedLabels.contains(LensL10n.text("Charger la suite")))
                }
                renders.append(inspector.record)
                let conversationName = "conversation-\(language.rawValue)-\(dark ? "dark" : "light")-760"
                let conversation = try await render(AnyView(ConversationExportView(snapshot: snapshot, onClose: {}).environmentObject(store)), size: NSSize(width: 760, height: 690), name: conversationName, dark: dark, output: output)
                for label in ["Exporter JSON…", "Exporter Markdown…", "Fermer"] {
                    if !conversation.labels.isEmpty { try check(conversationName + "-" + label, conversation.containedLabels.contains(LensL10n.text(label))) }
                }
                renders.append(conversation.record)
            }
        }
        store.stopObserving(); await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "allExecutedChecksPassed": true, "renders": renders, "parsedFixtureDocumentCount": parsedDocumentCount,
            "scope": "Source-matched native component bitmaps and accessible action frames on anonymous sources; no production compositor capture or input injection.",
            "unqualified": ["Production toolbar capsule and physical resize/keyboard/VoiceOver: CUA reports Mac locked", "Performance improvement", "Copy operation and clipboard, actual save dialog, model request"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    @MainActor private static func render(_ view: AnyView, size: NSSize, name: String, dark: Bool, output: URL) async throws -> (bitmap: NSBitmapImageRep, labels: [String], containedLabels: Set<String>, record: [String: Any]) {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .textBackgroundColor)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        for _ in 0..<35 { await Task.yield(); try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        var labels: [String] = [], contained: Set<String> = [], seen: Set<ObjectIdentifier> = []
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, let element = object as? NSAccessibilityProtocol, seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            let strings = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap { $0 }.filter { !$0.isEmpty }
            labels += strings
            let frame = element.accessibilityFrame()
            if frame.width > 0 && frame.height > 0 && viewport.contains(frame) { contained.formUnion(strings) }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        window.contentView = nil; window.close()
        return (bitmap, labels, contained, ["file": name + ".png", "width": size.width, "height": size.height,
            "accessibleLabelsQueryAvailable": !labels.isEmpty,
            "accessibleLabels": labels, "containedAccessibleLabels": Array(contained).sorted(),
            "method": "Own offscreen NSHostingView bitmap; not a production screenshot"])
    }

    private static func inkOutside(_ bitmap: NSBitmapImageRep, width: Double, dark: Bool) -> Int {
        let scaleX = Double(bitmap.pixelsWide) / 500, scaleY = Double(bitmap.pixelsHigh) / 100
        let safe = CGRect(x: 250 - width / 2 - 1, y: 27, width: width + 2, height: 46)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where !safe.contains(CGPoint(x: Double(x) / scaleX, y: Double(y) / scaleY)) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let v = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if dark ? v > 0.5 : v < 0.65 { count += 1 }
            }
        }
        return count
    }
}
