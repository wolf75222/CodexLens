import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// Exercises the actual owned native controls, without showing a window,
/// changing macOS preferences, reading a session, or contacting a model.
@main struct ControlColorsMain {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let succeeded: Bool
            do { succeeded = try await qualify() }
            catch { fputs("Control color qualification: \(error)\n", stderr); exit(1) }
            if !succeeded { exit(1) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else {
            throw CocoaError(.fileNoSuchFile)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        LensL10n.language = .en
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func stage(_ name: String) {
            try? JSONSerialization.data(withJSONObject: ["stage": name, "completedChecks": checks.count], options: [.sortedKeys])
                .write(to: output.appendingPathComponent("phase.json"))
        }

        stage("mounting-native-fixture")
        let model = ControlColorsModel(), observed = ControlColorsObservation()
        let host = NSHostingView(rootView: ControlColorsFixture(model: model, observed: observed))
        host.sizingOptions = []
        let window = makeWindow(size: NSSize(width: 950, height: 790))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 950, height: 790))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        stage("settling-native-fixture")
        await settle(host)
        stage("finding-native-editors")
        guard let chat = descendants(host).compactMap({ $0 as? LensChatInputTextView }).first,
              let codeHost = descendants(host).compactMap({ $0 as? CodeDocumentHost }).first,
              let code = descendants(codeHost).compactMap({ $0 as? NSTextView }).first,
              let recorded = descendants(host).compactMap({ $0 as? NSTextView }).first(where: { $0 !== chat && $0 !== code && !$0.isFieldEditor }),
              let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Open test action" }) else {
            throw NSError(domain: "ControlColors", code: 1, userInfo: [NSLocalizedDescriptionKey: "Owned native fixture controls were not mounted"])
        }
        let editors: [(String, NSTextView)] = [("chat", chat), ("code", code), ("recorded", recorded)]
        let readingRange = NSRange(location: 18, length: 19)
        for (_, editor) in editors {
            editor.setSelectedRange(readingRange)
            if let scroll = editor.enclosingScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 72))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let origins = editors.map { $0.1.enclosingScrollView?.contentView.bounds.origin ?? .zero }
        let undoWitness = ControlColorsUndoWitness()
        stage("registering-undo-witness")
        guard let undo = chat.undoManager else {
            throw NSError(domain: "ControlColors", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native chat undo manager was unavailable"])
        }
        undo.beginUndoGrouping(); undo.registerUndo(withTarget: undoWitness) { $0.calls += 1 }; undo.endUndoGrouping()

        for dark in [false, true] {
            for accent in LensControlAccent.allCases {
                let label = "\(accent.rawValue)-\(dark ? "dark" : "light")"
                stage("matrix-" + label)
                model.dark = dark; model.accent = accent
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                await settle(host)
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let expectedInk = expectedColor(accent, dark: dark)
                check(label + "-split-environment", observed.regions["navigation"] == accent && observed.regions["content"] == accent)
                for (position, item) in editors.enumerated() {
                    let name = label + "-" + item.0, editor = item.1
                    let expectedBackground = accent == .system ? NSColor.selectedTextBackgroundColor : expectedInk.withAlphaComponent(0.24)
                    let expectedText = accent == .system ? NSColor.selectedTextColor : .textColor
                    check(name + "-caret-and-selection", same(editor.insertionPointColor, expectedInk, appearance: appearance) &&
                        same(editor.selectedTextAttributes[.backgroundColor] as? NSColor, expectedBackground, appearance: appearance) &&
                        same(editor.selectedTextAttributes[.foregroundColor] as? NSColor, expectedText, appearance: appearance))
                    check(name + "-reading-state", editor.string == model.text && editor.selectedRange() == readingRange &&
                        editor.enclosingScrollView?.contentView.bounds.origin == origins[position])
                }
                check(label + "-undo-retained", chat.undoManager === undo && undo.canUndo && undoWitness.calls == 0)
                check(label + "-primary-native-bezel", accent == .system ? button.bezelColor == nil : same(button.bezelColor, expectedFilledColor(accent), appearance: appearance))
                check(label + "-default-button-label-and-key", button.keyEquivalent == "\r" && button.isEnabled && button.accessibilityLabel() == "Open test action")
                check(label + "-primary-keeps-intrinsic-size", abs(button.frame.width - button.intrinsicContentSize.width) <= 1 && abs(button.frame.height - button.intrinsicContentSize.height) <= 1)
                let actionCount = model.actionCount
                button.performClick(nil)
                check(label + "-default-action", model.actionCount == actionCount + 1)
            }
        }
        model.buttonEnabled = false
        stage("primary-disabled-and-undo")
        await settle(host)
        let actionCount = model.actionCount
        button.performClick(nil)
        check("disabled-primary-does-not-send-action", !button.isEnabled && !button.accessibilityPerformPress() && model.actionCount == actionCount)
        model.buttonEnabled = true; model.isDefault = false
        await settle(host)
        check("primary-key-equivalent-cleared", button.isEnabled && button.keyEquivalent.isEmpty)
        let accessibleActionCount = model.actionCount
        check("primary-accessible-press", button.accessibilityPerformPress() && model.actionCount == accessibleActionCount + 1)
        undo.undo()
        check("retained-undo-action-executes-once", undoWitness.calls == 1)

        stage("native-shared-search-editor")
        try qualifySearch(check: check)
        stage("native-settings-toolbar")
        try qualifySettings(check: check)
        stage("hosted-general-language")
        try await qualifySettingsLanguage(output: output, check: check)
        stage("writing-receipt")
        let succeeded = checks.allSatisfy { $0["passed"] as? Bool == true }
        let receipt: [String: Any] = [
            "checks": checks, "allExecutedChecksPassed": succeeded,
            "scope": "Actual owned native editors, shared search field editor, primary button, native workspace hosting and settings toolbar; anonymous in-memory fixture in hidden windows.",
            "appearanceChoices": ["light", "dark"], "accentChoices": LensControlAccent.allCases.map(\.rawValue),
            "modelRequests": 0, "observedSessionsRead": 0, "macOSPreferencesChanged": false,
            "unqualified": ["Physical keyboard/mouse and VoiceOver", "Actual application compositor and native bezel pixels", "Other macOS versions"]
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        return succeeded
    }

    @MainActor private static func qualifySearch(check: (String, Bool) -> Void) throws {
        for dark in [false, true] {
            let window = makeWindow(size: NSSize(width: 600, height: 160))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { window.close() }
            let first = LensAccentSearchField(frame: NSRect(x: 20, y: 80, width: 550, height: 30))
            let second = NSSearchField(frame: NSRect(x: 20, y: 25, width: 550, height: 30))
            first.stringValue = "Recorded search query"; second.stringValue = "Other native field"
            window.contentView?.addSubview(first); window.contentView?.addSubview(second)
            first.selectText(nil)
            guard let editor = first.currentEditor() as? NSTextView else {
                throw NSError(domain: "ControlColors", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native search field editor was unavailable"])
            }
            let originalCaret = editor.insertionPointColor!
            let originalAttributes = editor.selectedTextAttributes
            editor.setSelectedRange(NSRange(location: 2, length: 5))
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            for accent in LensControlAccent.allCases {
                let name = "search-\(accent.rawValue)-\(dark ? "dark" : "light")"
                first.accent = accent; first.applyEditorAccent()
                let expectedInk = expectedColor(accent, dark: dark)
                let expectedBackground = accent == .system ? NSColor.selectedTextBackgroundColor : expectedInk.withAlphaComponent(0.24)
                check(name + "-editor-uses-accent", same(editor.insertionPointColor, expectedInk, appearance: appearance) &&
                    same(editor.selectedTextAttributes[.backgroundColor] as? NSColor, expectedBackground, appearance: appearance))
                check(name + "-query-and-selection-retained", editor.string == first.stringValue && editor.selectedRange() == NSRange(location: 2, length: 5))
                check(name + "-owned-focus-policy", first.focusRingType == (accent == .system ? .default : .none))
                check(name + "-owned-focus-border", accent == .system ? first.layer?.borderWidth == 0 :
                    ((first.layer?.borderWidth ?? 0) > 0 && same(first.layer?.borderColor.flatMap { NSColor(cgColor: $0) }, expectedInk, appearance: appearance)))
            }
            first.restoreEditorAccent()
            check("search-\(dark)-restore-original-editor", same(editor.insertionPointColor, originalCaret, appearance: appearance) && sameAttributes(editor.selectedTextAttributes, originalAttributes, appearance: appearance))
            check("search-\(dark)-restore-removes-owned-ring", first.layer?.borderWidth == 0)
            second.selectText(nil)
            guard let reused = second.currentEditor() as? NSTextView else {
                throw NSError(domain: "ControlColors", code: 4, userInfo: [NSLocalizedDescriptionKey: "Second native field editor was unavailable"])
            }
            check("search-\(dark)-no-shared-editor-leak", reused === editor && same(reused.insertionPointColor, originalCaret, appearance: appearance) && sameAttributes(reused.selectedTextAttributes, originalAttributes, appearance: appearance))
            first.selectText(nil); first.accent = .sage; first.applyEditorAccent()
            let coordinator = LensNativeSearchField.Coordinator(LensNativeSearchField(placeholder: "Test search", text: .constant(first.stringValue)))
            LensNativeSearchField.dismantleNSView(first, coordinator: coordinator)
            check("search-\(dark)-dismantle-restores-editor", same(editor.insertionPointColor, originalCaret, appearance: appearance) && sameAttributes(editor.selectedTextAttributes, originalAttributes, appearance: appearance))
            window.makeFirstResponder(nil)
        }
    }

    @MainActor private static func qualifySettings(check: (String, Bool) -> Void) throws {
        let controller = LensSettingsNavigation.Controller()
        var selected = LensSettingsPage.general
        var environment = EnvironmentValues()
        let content = AnyView(Text("Settings qualification"))
        controller.update(selection: selected, accent: .lens, language: .en, content: content, environment: environment, onSelect: { selected = $0 })
        let toolbar = NSToolbar(identifier: "ControlColors-owned-test-toolbar")
        let pages: [LensSettingsPage] = [.general, .ai, .help]
        var buttons: [LensSettingsPage: NSButton] = [:]
        for page in pages {
            guard let item = controller.toolbar(toolbar, itemForItemIdentifier: .init(page.rawValue), willBeInsertedIntoToolbar: true), let button = item.view as? NSButton else {
                throw NSError(domain: "ControlColors", code: 5, userInfo: [NSLocalizedDescriptionKey: "Owned settings toolbar item was unavailable"])
            }
            buttons[page] = button
            check("settings-" + page.rawValue + "-named-toolbar-item", !item.label.isEmpty && item.label == button.title && button.accessibilityLabel() == button.title)
            check("settings-" + page.rawValue + "-tintable-symbol", button.image?.isTemplate == true)
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            for accent in LensControlAccent.allCases {
                environment.lensAccent = accent
                controller.update(selection: selected, accent: accent, language: .en, content: content, environment: environment, onSelect: { selected = $0 })
                let name = "settings-\(accent.rawValue)-\(dark ? "dark" : "light")"
                for page in pages {
                    let button = buttons[page]!
                    check(name + "-" + page.rawValue + "-native-tint", !button.isBordered && same(button.contentTintColor, page == selected ? expectedColor(accent, dark: dark) : .secondaryLabelColor, appearance: appearance) &&
                        button.state == (page == selected ? .on : .off))
                }
                let next: LensSettingsPage = selected == .help ? .general : .help
                buttons[next]!.performClick(nil)
                check(name + "-page-action", selected == next && buttons[next]!.state == .on)
            }
        }
        let window = makeWindow(size: NSSize(width: 600, height: 340))
        defer { window.contentViewController = nil; window.close() }
        let previousToolbar = NSToolbar(identifier: "ControlColors-previous-toolbar")
        window.toolbar = previousToolbar; window.contentViewController = controller
        controller.viewDidAppear()
        check("settings-installs-owned-toolbar", window.toolbar !== previousToolbar)
        check("settings-avoids-duplicate-native-caption", window.toolbar?.displayMode == .iconOnly)
        controller.viewWillDisappear()
        check("settings-restores-previous-toolbar", window.toolbar === previousToolbar)
    }

    @MainActor private static func expectedColor(_ accent: LensControlAccent, dark: Bool) -> NSColor {
        switch accent {
        case .lens: return rgb(dark ? (0.73, 0.68, 0.90) : (0.36, 0.32, 0.54))
        case .slate: return rgb(dark ? (0.63, 0.74, 0.88) : (0.29, 0.39, 0.54))
        case .sage: return rgb(dark ? (0.62, 0.79, 0.68) : (0.27, 0.43, 0.34))
        case .system: return .controlAccentColor
        }
    }

    @MainActor private static func qualifySettingsLanguage(output: URL, check: (String, Bool) -> Void) async throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("fr.codexlens.designprobe.") == true else {
            throw NSError(domain: "ControlColors", code: 6, userInfo: [NSLocalizedDescriptionKey: "Language regression requires the private probe preferences domain"])
        }
        let preferences = UserDefaults.standard
        let keys = ["lens.language", "lensAppearance", "lensControlAccent"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, preferences.object(forKey: $0)) })
        let previousLanguage = LensL10n.language
        let previousPage = LensGuideCoordinator.shared.settingsPage
        let archive = output.appendingPathComponent("settings-language-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        setenv("LENS_ARCHIVE_DIRECTORY", archive.path, 1)
        preferences.set("en", forKey: "lens.language")
        preferences.set("dark", forKey: "lensAppearance")
        preferences.set("sage", forKey: "lensControlAccent")
        LensL10n.language = .en
        LensGuideCoordinator.shared.settingsPage = .general

        let controller = NSHostingController(rootView: LensSettingsView())
        let window = makeWindow(size: NSSize(width: 900, height: 1380))
        window.setAccessibilityIdentifier("ControlColors-general-language-" + UUID().uuidString)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 1380))
        // Public self-process AX needs a registered window. Ordering this
        // prohibited-activation app's window behind other windows at (-6000,
        // -6000) never activates the app, raises it, or creates a Dock icon.
        window.orderBack(nil)
        var snapshots: [[String: Any]] = []
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            for key in keys {
                if let value = previous[key] ?? nil { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
            LensL10n.language = previousLanguage
            LensGuideCoordinator.shared.settingsPage = previousPage
        }
        await settle(controller.view)
        for (step, language) in [LensL10n.Language.en, .fr, .en].enumerated() {
            // Exercise the real AppStorage/onChange path. Updating LensL10n
            // here would conceal the hosted-content ordering regression.
            preferences.set(language.rawValue, forKey: "lens.language")
            await settle(controller.view)
            let sample = ownWindowStrings(window, root: controller.view)
            let strings = Set(sample.strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            let headings = language == .fr ? ["Mises à jour", "Langue", "Lecture"] : ["Updates", "Language", "Reading"]
            let labels = language == .fr ? ["Langue de l’interface", "Apparence"] : ["Interface language", "Appearance"]
            let stale = language == .fr ? ["Interface language", "Appearance"] : ["Langue de l’interface", "Apparence"]
            let name = "general-language-\(step)-\(language.rawValue)"
            check(name + "-current-body-headings", headings.allSatisfy(strings.contains))
            check(name + "-current-picker-labels", labels.allSatisfy(strings.contains) && !stale.contains(where: strings.contains))
            check(name + "-global-language-synchronized", LensL10n.language == language)
            check(name + "-preferences-and-page-preserved", preferences.string(forKey: "lensAppearance") == "dark" &&
                preferences.string(forKey: "lensControlAccent") == "sage" && LensGuideCoordinator.shared.settingsPage == .general)
            let sourceTheme = controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            check(name + "-theme-preserved", sourceTheme == "dark")
            let filename = "general-language-\(step)-\(language.rawValue)-\(sourceTheme).png"
            guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent(filename))
            snapshots.append(["step": step, "sourceLanguage": preferences.string(forKey: "lens.language") ?? "unavailable",
                "resolvedLanguage": LensL10n.resolvedLanguage.rawValue, "sourceTheme": sourceTheme,
                "bodyHeadingsExpected": headings, "pickerLabelsExpected": labels, "strings": strings.sorted(),
                "accessibilityDiagnostics": sample.diagnostics,
                "capture": filename, "captureMethod": "Source-matched NSHostingController bitmap cache; not the application compositor",
                "generalPageOnly": LensGuideCoordinator.shared.settingsPage == .general])
        }
        try JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("settings-language-observations.json"))
    }

    @MainActor private static func ownWindowStrings(_ window: NSWindow, root: NSView) -> (strings: [String], diagnostics: [String]) {
        var strings: Set<String> = [], diagnostics: [String] = []
        var nativeSeen: Set<ObjectIdentifier> = []
        func native(_ object: Any, depth: Int) {
            guard depth < 40, nativeSeen.count < 10_000, let element = object as? NSAccessibilityProtocol,
                  nativeSeen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            for text in [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityValue() as? String].compactMap({ $0 }) where !text.isEmpty { strings.insert(text) }
            for child in element.accessibilityChildren() ?? [] { native(child, depth: depth + 1) }
        }
        for view in descendants(root) where !view.isHiddenOrHasHiddenAncestor {
            native(view, depth: 0)
            if let field = view as? NSTextField, !field.stringValue.isEmpty { strings.insert(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { strings.insert(button.title) }
        }
        func value(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &result)
            return (error, result)
        }
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 0.5)
        let windows = value(application, kAXWindowsAttribute)
        let identifier = window.accessibilityIdentifier()
        guard windows.0 == .success, let peers = windows.1 as? [AXUIElement], !identifier.isEmpty else {
            diagnostics.append("Own-process AXWindows unavailable: \(windows.0.rawValue)"); return (strings.sorted(), diagnostics)
        }
        let matches = peers.filter { value($0, kAXIdentifierAttribute).1 as? String == identifier }
        guard matches.count == 1, let match = matches.first else {
            diagnostics.append("Expected one identified own window; found \(matches.count)"); return (strings.sorted(), diagnostics)
        }
        var seen: [CFHashCode: [AXUIElement]] = [:], count = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 40, count < 10_000 else { return }
            let hash = CFHash(element)
            guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return }
            seen[hash, default: []].append(element); count += 1
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text = value(element, key).1 as? String, !text.isEmpty { strings.insert(text) }
            }
            for child in value(element, kAXChildrenAttribute).1 as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(match, depth: 0)
        diagnostics.append("Own-process public AX nodes visited: \(count)")
        return (strings.sorted(), diagnostics)
    }
    private static func rgb(_ components: (CGFloat, CGFloat, CGFloat)) -> NSColor { NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1) }
    @MainActor private static func expectedFilledColor(_ accent: LensControlAccent) -> NSColor { expectedColor(accent, dark: false) }
    private static func same(_ lhs: NSColor?, _ rhs: NSColor, appearance: NSAppearance) -> Bool {
        var first: NSColor?, second: NSColor?
        appearance.performAsCurrentDrawingAppearance { first = lhs?.usingColorSpace(.sRGB); second = rhs.usingColorSpace(.sRGB) }
        guard let first, let second else { return false }
        return abs(first.redComponent - second.redComponent) < 0.0001 && abs(first.greenComponent - second.greenComponent) < 0.0001 &&
            abs(first.blueComponent - second.blueComponent) < 0.0001 && abs(first.alphaComponent - second.alphaComponent) < 0.0001
    }
    private static func sameAttributes(_ first: [NSAttributedString.Key: Any], _ second: [NSAttributedString.Key: Any], appearance: NSAppearance) -> Bool {
        guard Set(first.keys) == Set(second.keys) else { return false }
        return second.allSatisfy { key, value in
            if let color = value as? NSColor { return same(first[key] as? NSColor, color, appearance: appearance) }
            return (first[key] as? NSObject)?.isEqual(value) == true
        }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private static func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0..<25 {
            await Task.yield(); try? await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
    }
}

@MainActor @Observable private final class ControlColorsModel {
    var accent = LensControlAccent.lens
    var dark = false
    var text = (0..<180).map { "let recordedLine\($0) = \($0)" }.joined(separator: "\n")
    var query = "Recorded query"
    var buttonEnabled = true
    var isDefault = true
    var actionCount = 0
}
@MainActor private final class ControlColorsObservation { var regions: [String: LensControlAccent] = [:] }
@MainActor private final class ControlColorsUndoWitness: NSObject { var calls = 0 }
private struct ControlColorsEnvironmentProbe: NSViewRepresentable {
    @Environment(\.lensAccent) private var accent
    let observed: ControlColorsObservation
    let region: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { observed.regions[region] = accent }
}
private struct ControlColorsFixture: View {
    @Bindable var model: ControlColorsModel
    let observed: ControlColorsObservation
    var body: some View {
        LensNativeWorkspaceSplit(panes: [
            LensNativeWorkspacePane(id: "navigation", minimum: 250, maximum: 350, content: AnyView(
                VStack(spacing: 12) {
                    LensNativeSearchField(placeholder: "Search fixture", text: $model.query)
                    LensNativePrimaryButton(title: "Open test action", isDefault: model.isDefault) { model.actionCount += 1 }.disabled(!model.buttonEnabled)
                    Spacer()
                }.padding(16).background(ControlColorsEnvironmentProbe(observed: observed, region: "navigation"))
            )),
            LensNativeWorkspacePane(id: "content", minimum: 500, maximum: nil, content: AnyView(
                VStack(spacing: 8) {
                    LensChatInput(text: $model.text, fontSize: 13, enabled: true, canSend: false, label: "Color qualification chat", focused: .constant(false), onSend: {}).frame(height: 215)
                    NativeTextView(text: model.text, monospaced: false).frame(height: 215)
                    CodeDocumentView(text: model.text, path: "/anonymous/Example.swift", versionLabel: "Recorded test version").frame(height: 260)
                }.padding(16).background(ControlColorsEnvironmentProbe(observed: observed, region: "content"))
            ))
        ]).lensControlAccent(model.accent).environment(\.colorScheme, model.dark ? .dark : .light)
    }
}
