import AppKit
import SwiftUI
import LensCore

/// Passive native renders. Separate preferences, no production session or model.
@main struct AccentV38Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Accent qualification: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--output"), i + 1 < args.count else { throw CocoaError(.fileNoSuchFile) }
        let output = URL(fileURLWithPath: args[i + 1])
        LensL10n.language = .fr
        var checks: [[String: Any]] = [], renders: [String] = []
        func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "passed": pass]) }
        for dark in [false, true] {
            for accent in LensControlAccent.allCases {
                let box = AccentV38Observation()
                let model = AccentV38Model()
                let view = AccentV38Fixture(model: model, box: box, accent: accent, legacy: false)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let name = "accent-\(accent.rawValue)-\(dark ? "dark" : "light")"
                try await render(AnyView(view), name: name, dark: dark, output: output)
                renders.append(name + ".png")
                check(name + "-accent-and-tint-share-color", box.matches)
                check(name + "-split-roots-share-color", box.regionMatches["navigation"] == true && box.regionMatches["content"] == true)
                check(name + "-selection-retained", model.section == "activity" && model.mode == "timeline")
            }
        }
        // The previous composition is rendered with the same native controls.
        let baseline = AccentV38Observation()
        try await render(AnyView(AccentV38Fixture(model: AccentV38Model(), box: baseline, accent: .lens, legacy: true)),
                         name: "before-tint-only-light", dark: false, output: output)
        renders.append("before-tint-only-light.png")
        check("previous-composition-reproduces-color-mismatch", !baseline.matches)

        // Change the preference without replacing the host or model.
        let model = AccentV38Model(), box = AccentV38Observation()
        UserDefaults.standard.set("lens", forKey: "lensControlAccent")
        let host = NSHostingView(rootView: AccentV38LiveFixture(model: model, box: box))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 430)
        host.sizingOptions = []
        for accent in [LensControlAccent.lens, .slate, .sage, .system, .lens] {
            UserDefaults.standard.set(accent.rawValue, forKey: "lensControlAccent")
            await settle(host)
            check("live-\(accent.rawValue)-same-color", box.matches && box.observedChoice == accent)
            check("live-\(accent.rawValue)-selection-retained", model.section == "activity" && model.mode == "timeline")
        }
        let sections = try await renderSectionsV38(output: output)
        renders += sections.compactMap { $0["name"] as? String }
        let receipt: [String: Any] = ["checks": checks, "renders": renders,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched accent modifier, native List/Picker and native workspace split in detached NSHostingViews; separate preferences. No OS input, model request or observed session.",
            "unqualified": ["Production compositor and physical keyboard/mouse inspection unavailable while Mac is locked."]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    @MainActor private static func renderSectionsV38(output: URL) async throws -> [[String: Any]] {
        guard let i = CommandLine.arguments.firstIndex(of: "--corpus"), i + 1 < CommandLine.arguments.count else { throw LensError.unavailable("Missing corpus") }
        let corpus = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let data = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any], fixture["anonymous"] as? Bool == true,
              let home = fixture["home"] as? String, let rootID = fixture["rootID"] as? String else { throw LensError.unavailable("Anonymous corpus required") }
        let current = LensStore(sourceHome: URL(fileURLWithPath: home), investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("copy-archive")), cacheDirectory: output.appendingPathComponent("copy-cache"))
        current.setNavigationScope(UUID().uuidString)
        UserDefaults.standard.set(true, forKey: LensOnboardingState.preferenceKey)
        await current.start(); await current.open(rootID); await current.waitForPresentation()
        guard let snapshot = current.snapshot, snapshot.root.id == rootID, current.error == nil,
              let call = snapshot.events.first(where: { $0.kind == .toolCall }),
              let change = snapshot.changes.first(where: { $0.path.hasSuffix("/Same.swift") && $0.kind == .requestedPatch }) else { throw LensError.unavailable("Anonymous session is incomplete") }
        let context = LensWindowContext(store: current)
        let size = NSSize(width: 1440, height: 900)
        var results: [[String: Any]] = []
        for language in [LensL10n.Language.fr, .en] {
            LensL10n.language = language; UserDefaults.standard.set(language.rawValue, forKey: "lens.language")
            let dark = language == .en
            let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
            UserDefaults.standard.set(dark ? "dark" : "light", forKey: "lensAppearance")
            func mainView() -> AnyView { AnyView(MainView().environmentObject(current).environment(\.lensWindowContext, context).environment(\.colorScheme, dark ? .dark : .light)) }
            current.showSessionPicker = false; current.inspectorVisible = false; current.chatVisible = false; current.resetFilters()
            results.append(try await renderSection(AnyView(SessionPickerView().environmentObject(current).environment(\.colorScheme, dark ? .dark : .light)), size: NSSize(width: 820, height: 600), name: "help-opening-" + language.rawValue, appearance: appearance, output: output))
            current.browseSection(.activity); current.navigate(.event(call.id)); current.inspectorVisible = true
            await current.waitForPresentation()
            results.append(try await renderSection(mainView(), size: size, name: "help-activity-" + language.rawValue, appearance: appearance, output: output))
            current.navigate(.change(change.id)); current.inspectorVisible = false
            await current.waitForPresentation()
            results.append(try await renderSection(mainView(), size: size, name: "help-proof-" + language.rawValue, appearance: appearance, output: output))
            guard await current.prepareInvestigation(for: .change(change.id)) else { throw LensError.unavailable("Context preparation failed") }
            current.navigate(.change(change.id)); current.chatVisible = true
            current.investigation.question = language == .fr ? "Quelles instructions expliquent ce changement ? Compare les versions dans le worktree Alpha." : "Which instructions explain this change? Compare the versions in worktree Alpha."
            results.append(try await renderSection(mainView(), size: size, name: "help-investigation-" + language.rawValue, appearance: appearance, output: output))
            current.chatVisible = false; current.inspectorVisible = false
            for section in [LensSection.agents, .calls, .environments, .resources] {
                current.browseSection(section); await current.waitForPresentation()
                results.append(try await renderSection(mainView(), size: size, name: "copy-section-" + section.id + "-" + language.rawValue, appearance: appearance, output: output))
            }
        }
        current.stopObserving(); await current.investigation.flushAndStop()
        return results
    }

    @MainActor private static func renderSection(_ view: AnyView, size: NSSize, name: String, appearance: NSAppearance.Name, output: URL) async throws -> [String: Any] {
        try await render(view, size: size, name: name, dark: appearance == .darkAqua, output: output)
        return ["name": name + ".png", "method": "Detached native NSHostingView"]
    }

    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0..<20 {
            await Task.yield(); try? await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
    }

    @MainActor private static func render(_ view: AnyView, size: NSSize = NSSize(width: 800, height: 430), name: String, dark: Bool, output: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .textBackgroundColor)))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); window.contentView = host
        defer { window.contentView = nil; window.close() }
        await settle(host)
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
}

@MainActor private final class AccentV38Model: ObservableObject {
    @Published var section: String? = "activity"
    @Published var mode = "timeline"
}
@MainActor private final class AccentV38Observation {
    var matches = false
    var regionMatches: [String: Bool] = [:]
    var observedChoice: LensControlAccent?
}
private struct AccentV38Observer: NSViewRepresentable {
    let box: AccentV38Observation
    let accent: LensControlAccent
    let region: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let same = Color.accentColor.resolve(in: context.environment) == accent.color.resolve(in: context.environment)
        box.matches = same; box.regionMatches[region] = same; box.observedChoice = accent
    }
}
private struct AccentV38Fixture: View {
    @ObservedObject var model: AccentV38Model
    let box: AccentV38Observation
    let accent: LensControlAccent
    let legacy: Bool
    private var panes: some View {
        LensNativeWorkspaceSplit(panes: [
            LensNativeWorkspacePane(id: "navigation", minimum: 210, maximum: 300, content: AnyView(
                List(selection: $model.section) {
                    Label("Activité", systemImage: "waveform.path").tag("activity")
                    Label("Agents", systemImage: "person.3").tag("agents")
                    Label("Appels d’outils", systemImage: "wrench.and.screwdriver").tag("calls")
                    Label("Ressources", systemImage: "paperclip").tag("resources")
                }.listStyle(.sidebar).scrollContentBackground(.hidden).background(LensBrand.sidebar)
                    .background(AccentV38Observer(box: box, accent: accent, region: "navigation"))
            )),
            LensNativeWorkspacePane(id: "content", minimum: 430, maximum: nil, content: AnyView(
                VStack(alignment: .leading, spacing: 20) {
                    Text("Activité").font(.title2.weight(.semibold))
                    Picker("Vue de l’activité", selection: $model.mode) {
                        Text("Chronologie").tag("timeline"); Text("Échanges").tag("communications")
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("Chronologie par agent").font(.headline)
                    HStack { Image(systemName: "person.crop.circle"); Text("Session principale") }.foregroundStyle(Color.accentColor)
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)).frame(height: 48)
                    Toggle("Suivre les nouveaux événements", isOn: .constant(true)).toggleStyle(.switch)
                    Button("Afficher le contexte") {}.buttonStyle(.borderedProminent)
                    Spacer()
                }.padding(24).background(AccentV38Observer(box: box, accent: accent, region: "content"))
            ))
        ])
    }
    @ViewBuilder var body: some View {
        if legacy { panes.tint(accent.color) }
        else { panes.lensControlAccent(accent) }
    }
}
private struct AccentV38LiveFixture: View {
    @AppStorage("lensControlAccent") private var choice = "lens"
    let model: AccentV38Model
    let box: AccentV38Observation
    var body: some View { AccentV38Fixture(model: model, box: box, accent: LensControlAccent(rawValue: choice) ?? .lens, legacy: false) }
}
