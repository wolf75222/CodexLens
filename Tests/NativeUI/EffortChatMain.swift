import AppKit
import ApplicationServices
import Foundation
import LensCore
import SwiftUI

/// Anonymous capability metadata and native controls. No inference or credentials.
@main struct EffortChatMain {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Chat effort qualification failed: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--output")! + 1])
        var checks: [[String: Any]] = [], renders: [String] = [], accessibilitySamples: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        let preferences = UserDefaults.standard
        let keys = ["LensCodexModel", "LensCodexReasoningEfforts"]
        let old = keys.map { preferences.object(forKey: $0) }
        defer {
            for (index, key) in keys.enumerated() {
                if let value = old[index] { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        for key in keys { preferences.removeObject(forKey: key) }
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-home"),
                              investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
                              cacheDirectory: output.appendingPathComponent("cache"))
        store.investigation.automaticCodexCheckEnabled = false
        let investigator = InvestigationStore(archive: store.investigation.archive, statusProvider: { _ in metadata() })
        investigator.model = ""
        investigator.ensureChatContext(rootID: "anonymous-effort-source")
        investigator.editChatQuestion("Explain the recorded changes.")
        await investigator.refreshConnection()
        check("advertised-default-is-displayed-and-send-ready", investigator.model == "fixture-a"
              && investigator.reasoningEffort == nil && investigator.effectiveReasoningEffort == "medium"
              && investigator.canSendChatMessage)
        investigator.chooseReasoningEffort("high")
        check("selecting-advertised-effort-keeps-draft-and-context", investigator.effectiveReasoningEffort == "high"
              && investigator.question == "Explain the recorded changes." && investigator.capsule?.rootThreadID == "anonymous-effort-source")
        investigator.chooseReasoningEffort("not-advertised")
        check("unadvertised-choice-is-rejected", investigator.reasoningEffort == "high")
        investigator.model = "fixture-b"
        check("model-switch-uses-new-model-default-and-capabilities", investigator.reasoningEffort == nil
              && investigator.effectiveReasoningEffort == "low" && investigator.availableReasoningEfforts.map(\.id) == ["low", "high"])
        investigator.chooseReasoningEffort("high")
        investigator.model = "fixture-a"
        check("model-switch-restores-own-effort-preference", investigator.reasoningEffort == "high")
        investigator.chooseReasoningEffort(nil)
        check("default-restoration-resolves-explicit-advertised-value", investigator.reasoningEffort == nil && investigator.effectiveReasoningEffort == "medium")
        investigator.model = "legacy"
        check("missing-metadata-does-not-invent-effort-options-or-default", investigator.availableReasoningEfforts.isEmpty && investigator.effectiveReasoningEffort == nil)
        preferences.set(["legacy": "high"], forKey: "LensCodexReasoningEfforts")
        investigator.model = "legacy"
        check("legacy-saved-choice-requires-explicit-recovery", !investigator.reasoningEffortSelectionValid && !investigator.canSendChatMessage)
        investigator.clearUnavailableReasoningEffort()
        check("clearing-legacy-saved-choice-recovers-without-claiming-a-default", investigator.reasoningEffort == nil
              && investigator.effectiveReasoningEffort == nil && investigator.canSendChatMessage)
        preferences.set(["fixture-a": "removed-level", "fixture-b": "high"], forKey: "LensCodexReasoningEfforts")
        investigator.model = "fixture-a"
        check("removed-saved-effort-blocks-send", !investigator.reasoningEffortSelectionValid && !investigator.canSendChatMessage)
        investigator.send()
        check("invalid-effort-send-keeps-draft-and-creates-no-owned-thread", investigator.issue != nil
              && !investigator.sending && investigator.codexChatID == nil && investigator.question == "Explain the recorded changes.")
        investigator.chooseReasoningEffort("xhigh")
        check("supported-choice-recovers-from-removed-level", investigator.canSendChatMessage && investigator.effectiveReasoningEffort == "xhigh" && investigator.issue == nil)
        investigator.sending = true
        investigator.chooseReasoningEffort("low")
        check("effort-cannot-change-during-send", investigator.reasoningEffort == "xhigh")
        investigator.sending = false
        investigator.issue = "Effort de raisonnement absent du catalogue de ce modèle ; choisissez-le à nouveau. Aucun tour lancé."
        investigator.chooseReasoningEffort("xhigh")
        check("changing-effort-clears-only-its-stale-server-feedback", investigator.issue == nil)
        let restored = InvestigationStore(archive: InvestigationArchive(directory: output.appendingPathComponent("restored-archive")))
        restored.automaticCodexCheckEnabled = false
        check("new-store-restores-per-model-preference", restored.model == "fixture-a" && restored.reasoningEffort == "xhigh")

        for language in [LensL10n.Language.en, .fr] {
            LensL10n.language = language
            for (width, effortValue) in [(360.0, "xhigh"), (520.0, "xhigh"), (360.0, longEffort)] {
                investigator.chooseReasoningEffort(effortValue)
                let dark = language == .en
                let name = "chat-effort-\(language.rawValue)-\(Int(width))" + (effortValue == longEffort ? "-long" : "")
                let host = NSHostingView(rootView: InvestigationView(investigator: investigator)
                    .environmentObject(store).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
                let window = NSWindow(contentRect: NSRect(x: 0, y: -6000, width: width, height: 650),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.setAccessibilityIdentifier("EffortChat-" + UUID().uuidString)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                window.contentView = host
                window.orderBack(nil)
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                // SwiftUI virtual controls live in the public AX tree, not the
                // raw NSView protocol hierarchy used by the native text editor.
                let controls = try await ownControls(window: window, host: host)
                accessibilitySamples.append(["capture": name, "controls": controls.prefix(120).map {
                    ["identifier": $0.identifier, "role": $0.role, "label": $0.label, "value": $0.value,
                     "frame": $0.frame.map(NSStringFromRect) ?? "unavailable"]
                }])
                let effort = controls.filter { $0.identifier == "lens-chat-effort-selector" }
                check(name + "-exposes-effort-model-and-send-controls", effort.count == 1
                      && controls.contains { $0.identifier == "lens-chat-model-selector" }
                      && controls.contains { $0.identifier == "lens-chat-send" })
                for identifier in ["lens-chat-model-selector", "lens-chat-send"] {
                    let visible = controls.filter { $0.identifier == identifier }.contains {
                        guard let rect = $0.frame else { return false }
                        return rect.width > 0 && rect.minX >= -1 && rect.maxX <= width + 1 && rect.minY >= -1 && rect.maxY <= 651
                    }
                    check(name + "-" + identifier + "-fits-visible-composer", visible)
                }
                if let element = effort.first {
                    check(name + "-effort-label-and-value-are-accessible", element.label == LensL10n.text("Effort de raisonnement")
                          && element.value.contains(CodexReasoningEffortControl.label(effortValue)))
                    let rect = element.frame ?? .zero
                    check(name + "-effort-fits-visible-composer", rect.width > 0 && rect.minX >= -1 && rect.maxX <= width + 1
                          && rect.minY >= -1 && rect.maxY <= 651)
                }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LensError.unavailable("No native bitmap") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw LensError.unavailable("No PNG") }
                try png.write(to: output.appendingPathComponent(name + ".png"))
                renders.append(name + ".png")
                check(name + "-render-keeps-draft-without-inference", investigator.question == "Explain the recorded changes."
                      && !investigator.sending && investigator.codexChatID == nil)
                window.contentView = nil
                window.close()
            }
        }
        await investigator.flushAndStop(); await restored.flushAndStop()
        store.stopObserving(); await store.investigation.flushAndStop()
        let receipt: [String: Any] = ["checks": checks, "renders": renders, "accessibilitySamples": accessibilitySamples,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "captureMethod": "Offscreen AppKit NSHostingView cacheDisplay; production entrypoint replaced.",
            "modelRequests": 0, "anonymousMetadataOnly": true,
            "unqualified": ["Live authenticated inference", "Physical input", "VoiceOver", "Production compositor"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    private struct Control {
        let identifier: String, role: String, label: String, value: String
        let frame: CGRect?
    }
    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &result) == .success else { return nil }
        return result
    }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let p = attribute(node, kAXPositionAttribute), let s = attribute(node, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    @MainActor private static func ownControls(window: NSWindow, host: NSView) async throws -> [Control] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 0.5)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var controls: [Control] = []
        repeat {
            if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
               let own = windows.first(where: { attribute($0, kAXIdentifierAttribute) as? String == window.accessibilityIdentifier() }),
               let base = frame(own), abs(base.width - window.frame.width) <= 2, abs(base.height - window.frame.height) <= 2 {
                var nodes: [AXUIElement] = [], seen: [CFHashCode: [AXUIElement]] = [:]
                func walk(_ node: AXUIElement, depth: Int) {
                    guard depth < 40, nodes.count < 4000 else { return }
                    let hash = CFHash(node)
                    guard !(seen[hash] ?? []).contains(where: { CFEqual($0, node) }) else { return }
                    seen[hash, default: []].append(node); nodes.append(node)
                    for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
                }
                walk(own, depth: 0)
                controls = nodes.map { node in
                    let local = frame(node).map { rect in
                        // AX and AppKit have opposite screen origins. Anchor
                        // to this exact owned window, independent of monitors.
                        let screen = CGRect(x: window.frame.minX + rect.minX - base.minX,
                            y: window.frame.maxY - (rect.minY - base.minY) - rect.height,
                            width: rect.width, height: rect.height)
                        return host.convert(window.convertFromScreen(screen), from: nil)
                    }
                    return Control(identifier: attribute(node, kAXIdentifierAttribute) as? String ?? "",
                        role: attribute(node, kAXRoleAttribute) as? String ?? "",
                        label: attribute(node, kAXDescriptionAttribute) as? String ?? attribute(node, kAXTitleAttribute) as? String ?? "",
                        value: String(describing: attribute(node, kAXValueAttribute) ?? "" as CFString), frame: local)
                }
                let required = ["lens-chat-model-selector", "lens-chat-effort-selector", "lens-chat-send"]
                if required.allSatisfy({ id in controls.contains { $0.identifier == id && ($0.frame?.width ?? 0) > 0 } }) { return controls }
            }
            try await Task.sleep(for: .milliseconds(30))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return controls
    }

    private static func metadata() -> CodexLocalConnectionStatus {
        let a = ["low", "medium", "high", "xhigh", longEffort].map { CodexLocalReasoningEffort(id: $0, description: "Anonymous effort " + $0) }
        let b = ["low", "high"].map { CodexLocalReasoningEffort(id: $0, description: "Anonymous effort " + $0) }
        return CodexLocalConnectionStatus(version: "0.160.1", executable: "/anonymous/codex", authentication: "chatgpt",
            email: nil, plan: nil, models: [
                CodexLocalModel(id: "fixture-a", displayName: "Fixture A", isDefault: true, supportedReasoningEfforts: a, defaultReasoningEffort: "medium"),
                CodexLocalModel(id: "fixture-b", displayName: "Fixture B", isDefault: false, supportedReasoningEfforts: b, defaultReasoningEffort: "low"),
                CodexLocalModel(id: "legacy", displayName: "Legacy metadata", isDefault: false)
            ], limits: nil)
    }
    private static let longEffort = String(repeating: "future-effort-", count: 8)
}
