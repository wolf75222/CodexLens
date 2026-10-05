import AppKit
import SwiftUI
import QuartzCore
import LensCore

/// Native layout regression and a visible fixture using the product views.
/// No Codex process, model request, real journal or global preference is used.
@main struct LoadingV42Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await qualify()
                if !CommandLine.arguments.contains("--linger") { NSApp.terminate(nil) }
            } catch {
                fputs("Loading qualification: \(error)\n", stderr)
                NSApp.terminate(nil)
            }
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.count > index + 1 else {
            throw LensError.unavailable("Missing private output directory")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        LensL10n.language = .fr
        let store = LensStore(sourceHome: output.appendingPathComponent("empty-source"),
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: SessionReaderPool())
        store.catalog = [SessionSummary(id: "11111111-1111-4111-8111-111111111111", title: "Session Alpha", cwd: "/anonymous/worktrees/alpha", modifiedAt: Date())]
        let originalCatalog = store.catalog
        var checks: [[String: Any]] = [], observations: [[String: Any]] = []
        func check(_ id: String, _ passed: Bool) { checks.append(["id": id, "passed": passed]) }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 740, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Codex Lens — chargement (données de test)"
        for dark in [false, true] {
            for width in [620.0, 1040.0] {
                store.busy = true
                let host = NSHostingView(rootView: SessionPickerView().environmentObject(store))
                host.sizingOptions = []
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: width, height: 540))
                window.makeKeyAndOrderFront(nil)
                await settle(host)
                let indicators = descendants(host).compactMap { $0 as? NSProgressIndicator }
                let id = "picker-\(dark ? "dark" : "light")-\(Int(width))"
                check(id + "-single-native-spinner", indicators.count == 1)
                if let spinner = indicators.first {
                    let rect = spinner.convert(spinner.bounds, to: host)
                    let offset = abs(rect.midX - host.bounds.midX)
                    check(id + "-spinner-centred", offset <= 2 && rect.width > 0 && rect.height > 0)
                    observations.append(["id": id, "spinnerFrame": NSStringFromRect(rect), "contentBounds": NSStringFromRect(host.bounds), "horizontalOffsetPoints": offset])
                } else { check(id + "-spinner-centred", false) }
            }
        }
        store.cancelSessionOpening()
        check("cancel-preserves-catalog", !store.busy && store.catalog == originalCatalog)
        for width in [260.0, 620.0] {
            let host = NSHostingView(rootView: LensLoadingState(title: "Recherche de la version dans le dépôt associé…").frame(maxHeight: .infinity))
            host.sizingOptions = []
            window.contentView = host; window.setContentSize(NSSize(width: width, height: 260))
            await settle(host)
            let spinner = descendants(host).compactMap { $0 as? NSProgressIndicator }.first
            let rect = spinner.map { $0.convert($0.bounds, to: host) }
            check("long-title-\(Int(width))-spinner-centred", rect.map { abs($0.midX - host.bounds.midX) <= 2 } ?? false)
        }
        let reduced = NSHostingView(rootView: LensLoadingState(title: "Lecture des traces…").frame(maxHeight: .infinity).environment(\.lensReduceMotionOverride, true))
        reduced.sizingOptions = []; window.contentView = reduced
        await settle(reduced)
        check("reduced-motion-no-animated-spinner", descendants(reduced).allSatisfy { !($0 is NSProgressIndicator) })
        let receipt: [String: Any] = ["checks": checks, "observations": observations,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual product SessionPickerView and loading component in a native fixture; production @main replaced.",
            "realCodexHomeRead": false, "modelRequests": 0, "unqualified": ["VoiceOver and physical trackpad input"]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        if CommandLine.arguments.contains("--linger") {
            store.busy = true
            let host = NSHostingView(rootView: LoadingReviewFixture(store: store, window: window))
            host.sizingOptions = []; window.contentView = host
            window.setContentSize(NSSize(width: 740, height: 590))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { window.close(); store.stopObserving() }
    }

    @MainActor private static func settle(_ view: NSView) async {
        for _ in 0..<10 { await Task.yield(); try? await Task.sleep(nanoseconds: 20_000_000) }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}

@MainActor private struct LoadingReviewFixture: View {
    @ObservedObject var store: LensStore
    let window: NSWindow
    @State private var dark = true
    @State private var reduced = false
    @State private var english = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Données de test").font(.caption).foregroundStyle(.secondary)
                Button("Chargement") { store.busy = true }
                Menu("Affichage") {
                    Toggle("Sombre", isOn: $dark)
                    Toggle("Mouvement réduit", isOn: $reduced)
                    Toggle("English", isOn: $english)
                    Button("Étroit") { window.setContentSize(NSSize(width: 620, height: 590)) }
                    Button("Large") { window.setContentSize(NSSize(width: 1040, height: 680)) }
                }
                Spacer()
                Button("Terminer") { store.stopObserving(); NSApp.terminate(nil) }
            }.controlSize(.small).padding(8)
            Divider()
            SessionPickerView().environmentObject(store)
        }
        .environment(\.lensReduceMotionOverride, reduced)
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { window.appearance = NSAppearance(named: .darkAqua) }
        .onChange(of: dark) { _, value in window.appearance = NSAppearance(named: value ? .darkAqua : .aqua) }
        .onChange(of: english) { _, value in LensL10n.language = value ? .en : .fr }
    }
}
