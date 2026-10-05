import AppKit
import SwiftUI
import LensCore
import CryptoKit
import QuartzCore

/// Own native component qualification, replacing production @main. The launcher
/// denies networking; all journals below are copies of an anonymous corpus.
@main struct MotionMain {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let run = MotionRun()
        Task { @MainActor in
            do { try await run.run() } catch { run.recordFatal(error) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}

private enum MotionScope: String, CaseIterable { case control, preference, stable }

@MainActor private final class MotionTransactionState: ObservableObject {
    @Published var generation = 0
}

@MainActor private final class MotionTransactionLog {
    var entries: [[String: Any]] = []
    func record(_ generation: Int, transaction: Transaction, environment: EnvironmentValues) {
        entries.append(["generation": generation, "hasAnimation": transaction.animation != nil,
                        "disablesAnimations": transaction.disablesAnimations,
                        "animationDescription": transaction.animation.map { String(describing: $0) } ?? "nil",
                        "systemReduceMotion": environment.accessibilityReduceMotion,
                        "hasFixtureOverride": environment.lensReduceMotionOverride != nil])
    }
}

private struct MotionTransactionRecorder: NSViewRepresentable {
    let generation: Int
    let log: MotionTransactionLog
    func makeNSView(context: Context) -> NSView {
        log.record(generation, transaction: context.transaction, environment: context.environment)
        return NSView(frame: .zero)
    }
    func updateNSView(_ view: NSView, context: Context) {
        log.record(generation, transaction: context.transaction, environment: context.environment)
    }
}

@MainActor private struct MotionTransactionFixture: View {
    @ObservedObject var state: MotionTransactionState
    let log: MotionTransactionLog
    let scope: MotionScope
    let reduceMotion: Bool?
    let descendantImplicitAnimation: Bool
    private var recorder: some View {
        MotionTransactionRecorder(generation: state.generation, log: log)
            .frame(width: 40 + CGFloat(state.generation), height: 20)
    }
    @ViewBuilder private var recorded: some View {
        if descendantImplicitAnimation {
            recorder.animation(.easeInOut(duration: 0.5), value: state.generation)
        } else {
            recorder
        }
    }
    var body: some View {
        Group {
            switch scope {
            case .control: recorded
            case .preference: recorded.lensMotionAware()
            case .stable: recorded.lensStableContent()
            }
        }.environment(\.lensReduceMotionOverride, reduceMotion)
    }
}

@MainActor private struct MotionProgressFixture: View {
    let reduceMotion: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Chargement et réception").font(.headline)
            Text("Fixture anonyme · préférence Réduire les animations : \(reduceMotion ? "activée" : "désactivée")")
                .font(.caption).foregroundStyle(.secondary)
            LensProgressIndicator("Chargement de la session…")
            HStack(spacing: 8) {
                LensProgressIndicator(accessibilityLabel: "Réponse en cours de réception")
                Text("Réponse en cours de réception")
                Spacer()
                Button("Arrêter la réception") { /* fixture only; no request */ }
            }
            Text("Le statut et la commande restent visibles dans les deux modes.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .lensMotionAware().environment(\.lensReduceMotionOverride, reduceMotion)
    }
}

private enum MotionReader: String, CaseIterable { case prose, code }

@MainActor private final class MotionReaderState: ObservableObject {
    @Published var text: String
    @Published var reduceMotion = false
    @Published var dark = false
    init(_ text: String) { self.text = text }
}

@MainActor private struct MotionReaderFixture: View {
    @ObservedObject var state: MotionReaderState
    let reader: MotionReader
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(reader == .prose ? "Réponse enregistrée" : "Fichier enregistré").font(.headline)
                Spacer()
                LensProgressIndicator(accessibilityLabel: "Réception en cours")
                Text("Réception en cours").font(.caption)
            }
            Text("Worktree alpha · fragment enregistré v1 · fixture anonyme")
                .font(.caption).foregroundStyle(.secondary)
            if reader == .prose {
                NativeTextView(text: state.text, monospaced: false, fontSize: 13)
            } else {
                CodeDocumentView(text: state.text, path: "/anonymous/worktrees/alpha/src/Motion.swift",
                                 versionLabel: "Fragment enregistré v1 · fixture", fontSize: 13)
            }
        }.padding(12).background(Color(nsColor: .windowBackgroundColor))
            // Same data boundary as MainView.center / InspectorView: includes
            // the header whose standard/static status indicator changes layout.
            .lensStableContent().lensMotionAware().environment(\.lensReduceMotionOverride, state.reduceMotion)
            .environment(\.colorScheme, state.dark ? .dark : .light)
    }
}

@MainActor private final class MotionConnectedState: ObservableObject {
    @Published var reduceMotion = false
    @Published var dark = false
}

@MainActor private struct MotionConnectedFixture: View {
    @ObservedObject var state: MotionConnectedState
    @ObservedObject var store: LensStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session, activité et enquête séparée · corpus anonyme")
                .font(.headline).padding(12)
            HSplitView {
                ActivityView().frame(minWidth: 580)
                InvestigationView(investigator: store.investigation).frame(minWidth: 530)
            }
        }.environmentObject(store).background(Color(nsColor: .windowBackgroundColor))
            .lensStableContent().lensMotionAware().environment(\.lensReduceMotionOverride, state.reduceMotion)
            .environment(\.colorScheme, state.dark ? .dark : .light)
    }
}

@MainActor private final class MotionRun {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var receipt: [String: Any] = [:]
    private var checks: [[String: Any]] = []
    private var renders: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    private var windows: [NSWindow] = []
    private var store: LensStore?
    private var unavailable: [String] = []

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let data = try Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["anonymous"] as? Bool == true else { throw failure("Corpus must be explicitly anonymous.") }
        receipt["startedAt"] = Date().ISO8601Format()
        receipt["scope"] = "Source-matched product modifiers, native readers, timeline and investigation in an own NSApplication. Production @main is replaced."
        receipt["entrypoint"] = "MotionMain.swift"
        receipt["corpusManifestSHA256"] = digest(data)
        receipt["networkDeniedByLauncher"] = true
        receipt["realCodexHomeRead"] = false
        receipt["credentialAccess"] = false
        receipt["modelRequests"] = 0
        receipt["interactionMethod"] = "Own NSHostingView, NSViewRepresentable.Context.transaction, NSTextView, NSScrollView and LensStore APIs; no OS input or system preference changes."
        try await qualifyTransactions()
        try await qualifyProgress()
        for reader in MotionReader.allCases { try await qualifyReader(reader) }
        try await qualifyConnected(manifest)
        receipt["unqualified"] = unavailable + [
            "Own NSHostingView PNG renders are not compositor screenshots or production startup qualification.",
            "Physical keyboard, expanded menus, VoiceOver announcements, display hitches and animation timing are not exercised.",
            "Reduce Motion cases use the product's explicit lensReduceMotionOverride fixture input; default nil uses the read-only OS preference. The macOS preference switch and macOS 14 runtime are not changed or inferred.",
            "Native responder identity is tested programmatically; OS activation and physical focus routing are not inferred.",
            "The sending flag and answer are fixtures, with no model request. Presence of the stop control does not qualify cancellation of a real network stream.",
            "UTF-16 selections and pixel viewport origins are preserved on append; semantic line anchoring after unrelated reflow is outside this test."
        ]
        receipt["readerBoundaryQualification"] = "Actual NativeTextView/CodeDocumentView in a containing VStack protected by product lensStableContent(), matching MainView.center and InspectorView. The separate transaction control/preference matrix tests normal inherited animation passthrough outside the stable data boundary."
        receipt["finishedAt"] = Date().ISO8601Format()
        await cleanUp()
        try saveReceipt()
    }

    private func qualifyTransactions() async throws {
        let observedSystemPreference = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        receipt["systemReduceMotionObserved"] = observedSystemPreference
        for scope in MotionScope.allCases {
            for reduced in [false, true, nil] as [Bool?] {
                for implicit in [false, true] {
                    let state = MotionTransactionState(), log = MotionTransactionLog()
                    let host = NSHostingView(rootView: MotionTransactionFixture(state: state, log: log, scope: scope,
                                                                               reduceMotion: reduced, descendantImplicitAnimation: implicit))
                    let window = install(host, size: NSSize(width: 180, height: 80))
                    try await settle(host)
                    log.entries.removeAll()
                    withAnimation(.linear(duration: 0.8)) { state.generation = 1 }
                    try await settle(host)
                    let matching = log.entries.filter { $0["generation"] as? Int == 1 }
                    let id = "transaction-\(scope.rawValue)-reduced-\(reduced.map(String.init) ?? "system")-implicit-\(implicit)"
                    check(id + "-real-update-observed", !matching.isEmpty)
                    let mustSuppress = scope == .stable || (scope == .preference && (reduced ?? observedSystemPreference))
                    check(id + "-animation-policy", !matching.isEmpty && matching.allSatisfy {
                        $0["hasAnimation"] as? Bool == !mustSuppress
                    })
                    check(id + "-implicit-reinjection-policy", !matching.isEmpty && matching.allSatisfy {
                        $0["disablesAnimations"] as? Bool == mustSuppress
                    })
                    check(id + "-system-preference-and-override-source", !matching.isEmpty && matching.allSatisfy {
                        $0["systemReduceMotion"] as? Bool == observedSystemPreference &&
                            $0["hasFixtureOverride"] as? Bool == (reduced != nil)
                    })
                    observations.append(["id": id, "contextTransactions": matching, "expectedSuppression": mustSuppress])
                    window.close()
                }
            }
        }
    }

    private func qualifyProgress() async throws {
        for reduced in [false, true] {
            let host = NSHostingView(rootView: MotionProgressFixture(reduceMotion: reduced))
            let window = install(host, size: NSSize(width: 690, height: 240))
            try await settle(host)
            let indicators = descendants(host).compactMap { $0 as? NSProgressIndicator }
            let id = "progress-reduced-\(reduced)"
            check(id + "-native-spinner-policy", reduced ? indicators.isEmpty : indicators.count == 2)
            check(id + "-host-size-finite", host.bounds.width.isFinite && host.bounds.height.isFinite && host.bounds.width > 0)
            let labels = accessibilityStrings(host)
            observations.append(["id": id, "nativeProgressIndicatorCount": indicators.count, "accessibilityStrings": labels,
                                 "hostConformsToAccessibilityProtocol": host is NSAccessibilityProtocol,
                                 "hostAccessibilityChildrenCount": host.accessibilityChildren()?.count ?? 0,
                                 "hostAccessibilityRole": host.accessibilityRole()?.rawValue ?? "nil"])
            let labelled = LensProgressIndicator("Chargement de la session…")
            let explicit = LensProgressIndicator(accessibilityLabel: "Réponse en cours de réception")
            check(id + "-actual-title-and-default-accessibility-label", labelled.title == "Chargement de la session…" && labelled.accessibilityLabel == labelled.title)
            check(id + "-actual-explicit-accessibility-label", explicit.title == nil && explicit.accessibilityLabel == "Réponse en cours de réception")
            if labels.isEmpty {
                unavailable.append(id + ": the own NSHostingView's public accessibility getters returned no SwiftUI children/strings; status value, stop control and accessibility mode identifier are not qualified by an AX tree. Native NSProgressIndicator presence and rendered product states are qualified separately.")
            } else {
                check(id + "-status-text-preserved", labels.contains { $0.contains("Chargement de la session") })
                check(id + "-stop-control-preserved", labels.contains { $0.contains("Arrêter la réception") })
                check(id + "-unlabelled-indicator-has-context", labels.contains { $0.contains("Réponse en cours de réception") })
                check(id + "-accessible-in-progress-value", labels.contains("En cours"))
                check(id + "-accessible-product-mode-identifier", labels.contains("identifier:" + (reduced ? "lens-progress-stationary" : "lens-progress-standard")))
            }
            for theme in ["light", "dark"] {
                window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                try await capture(host, filename: "motion-progress-\(reduced ? "reduced" : "normal")-\(theme).png",
                                  theme: theme, reduceMotion: reduced, scene: "Product progress indicator composite")
            }
            window.close()
        }
    }

    private func qualifyReader(_ reader: MotionReader) async throws {
        let marker = "repère 🧭 café e\u{301}"
        let lines = (0..<700).map { index in
            reader == .prose ? "\(index) — Réponse enregistrée, instruction et contexte : \(marker)\r\n" :
                "let valeur\(index) = \(index) // Preuve enregistrée : \(marker)\r\n"
        }
        let original = lines.joined()
        let state = MotionReaderState(original)
        let host = NSHostingView(rootView: MotionReaderFixture(state: state, reader: reader))
        let window = install(host, size: NSSize(width: 910, height: 590))
        try await settle(host)
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let editor = scroll.documentView as? NSTextView else { throw failure("Actual \(reader.rawValue) reader not found.") }
        check(reader.rawValue + "-actual-reader-read-only-selectable", !editor.isEditable && editor.isSelectable)
        let prefixLength = (lines.prefix(50).joined() as NSString).length
        let selected = (original as NSString).range(of: marker, options: .literal,
                                                  range: NSRange(location: prefixLength, length: (original as NSString).length - prefixLength))
        guard selected.location != NSNotFound else { throw failure("Unicode marker absent.") }
        editor.setSelectedRange(selected)
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 720))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = readingOrigin(scroll)
        let focusEstablished = window.makeFirstResponder(editor)
        check(reader.rawValue + "-utf16-selection-with-surrogate-established", selected.length == (marker as NSString).length && selected.length > marker.count)
        check(reader.rawValue + "-scrolled-viewport-established", origin.y > 100)
        check(reader.rawValue + "-native-responder-established", focusEstablished && window.firstResponder === editor)
        observeReader(reader.rawValue + "-before", editor: editor, scroll: scroll)
        for theme in ["light", "dark"] {
            state.dark = theme == "dark"; window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
            try await capture(host, filename: "motion-\(reader.rawValue)-before-\(theme).png", theme: theme,
                              reduceMotion: false, scene: "Native reader before append, selection and nonzero viewport")
        }
        var expected = original
        for (index, reduced) in [false, true, false, true].enumerated() {
            let appendix = "\r\nSortie ajoutée \(index) 🧪 — octets exacts et contexte inchangé.\r\n"
            expected += appendix
            withAnimation(.easeInOut(duration: 0.9)) {
                state.reduceMotion = reduced
                state.text = expected
            }
            try await settle(host)
            let id = reader.rawValue + "-animated-append-\(index)-reduced-\(reduced)"
            observeReader(id, editor: editor, scroll: scroll)
            check(id + "-exact-bytes", Data(editor.string.utf8) == Data(expected.utf8))
            check(id + "-native-reader-identity", scroll.documentView === editor)
            check(id + "-utf16-selection", editor.selectedRange() == selected && selectedString(editor) == marker)
            check(id + "-viewport", near(readingOrigin(scroll), origin))
            check(id + "-responder-identity", window.firstResponder === editor)
            observations.append(["id": id, "textSHA256": digest(Data(editor.string.utf8)),
                                 "selectionLocationUTF16": editor.selectedRange().location,
                                 "selectionLengthUTF16": editor.selectedRange().length,
                                 "originX": readingOrigin(scroll).x, "originY": readingOrigin(scroll).y,
                                 "nativeResponderIsReader": window.firstResponder === editor])
        }
        for theme in ["light", "dark"] {
            state.dark = theme == "dark"; window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
            try await capture(host, filename: "motion-\(reader.rawValue)-after-\(theme).png", theme: theme,
                              reduceMotion: true, scene: "Native reader after four animated appends and preference switches")
        }
        if let code = descendants(host).compactMap({ $0 as? CodeDocumentHost }).first { code.cancelAnalysis() }
        window.close()
    }

    private func qualifyConnected(_ manifest: [String: Any]) async throws {
        guard let root = manifest["rootID"] as? String, let child = manifest["childID"] as? String,
              let originalHome = manifest["home"] as? String,
              let expected = manifest["expected"] as? [String: Any],
              let calls = expected["toolCallIDs"] as? [String: String], let betaRead = calls["betaRead"] else {
            throw failure("Anonymous connected corpus is incomplete.")
        }
        let runtime = output.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let home = runtime.appendingPathComponent("source")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: originalHome), to: home)
        let current = LensStore(sourceHome: home, investigationArchive: InvestigationArchive(directory: runtime.appendingPathComponent("archive")),
                                cacheDirectory: runtime.appendingPathComponent("cache"))
        store = current
        current.setNavigationScope(UUID().uuidString)
        await current.start(); await current.open(root); await current.waitForPresentation()
        current.showSessionPicker = false
        guard let snapshot = current.snapshot, let event = snapshot.events.first(where: { $0.callID == betaRead && $0.kind == .toolCall }) else {
            throw failure("Connected recorded call did not open.")
        }
        receipt["connectedInitialEventCount"] = snapshot.events.count
        receipt["connectedCorpusFamilyRawRecordCount"] = expected["familyRawRecordCount"]
        check("connected-separate-subagent", snapshot.agents.contains { $0.id == child && $0.parentID == root && $0.relation == .subagent })
        current.navigate(.event(event.id)); current.follow = false
        await current.prepareInvestigation(for: .event(event.id))
        guard let capsule = current.investigation.capsule else { throw failure("Connected capsule did not prepare.") }
        let frozen = try capsule.transmissionJSON()
        current.navigate(.event(event.id))
        let selection = current.selection
        let state = MotionConnectedState()
        let host = NSHostingView(rootView: MotionConnectedFixture(state: state, store: current))
        let window = install(host, size: NSSize(width: 1480, height: 920))
        try await settle(host)
        guard let timelineScroll = descendants(host).compactMap({ $0 as? TimelineScrollView }).first,
              let canvas = timelineScroll.documentView as? TimelineCanvas,
              let projection = current.timelineProjection, let item = projection.item(id: event.id),
              let geometry = canvas.geometry else { throw failure("Actual timeline projection and native canvas are absent.") }
        let originalRect = geometry.rect(for: item)
        let originalWindow = current.timelineWindow
        let originalTimelineOrigin = current.timelineOrigin
        let originalScrollOrigin = timelineScroll.contentView.bounds.origin
        check("connected-timeline-selection-anchored", canvas.selectedID == event.id)
        current.investigation.question = "Pourquoi cette lecture appartient-elle au worktree beta ?"
        current.investigation.response = "Réponse fixture sans requête : lecture enregistrée dans le worktree beta."
        current.investigation.sending = true
        let rootRollout = try ownRollout(home: home, id: root)
        let added = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-01T15:00:00.000Z", "type": "response_item",
              "payload": ["type": "message", "id": "qa-motion-live-append", "role": "assistant", "content": [["type": "output_text",
              "text": "Événement direct anonyme, aucune commande exécutée."]]]], options: [.sortedKeys]) + Data([10])
        let writer = try FileHandle(forWritingTo: rootRollout); try writer.seekToEnd(); try writer.write(contentsOf: added); try writer.close()
        let deadline = Date().addingTimeInterval(8)
        while current.waitingEvents == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try await settle(host)
        check("connected-paused-collection-continues", current.waitingEvents > 0 && current.snapshot?.events.count == snapshot.events.count)
        check("connected-paused-selection-preserved", current.selection == selection && canvas.selectedID == event.id)
        check("connected-paused-window-and-origin-preserved", current.timelineWindow == originalWindow && current.timelineOrigin == originalTimelineOrigin && near(timelineScroll.contentView.bounds.origin, originalScrollOrigin))
        check("connected-paused-frozen-json-and-sha-preserved", try current.investigation.capsule?.transmissionJSON() == frozen && current.investigation.capsule?.digestSHA256 == capsule.digestSHA256)
        for reduced in [false, true] {
            state.reduceMotion = reduced
            try await settle(host)
            let labels = accessibilityStrings(host)
            if labels.isEmpty {
                unavailable.append("connected-reduced-\(reduced): no SwiftUI accessibility tree materialized through own public getters. The stop-control presence is visually reviewable in the actual InvestigationView bitmap; its AX announcement/action is unqualified.")
            } else {
                check("connected-stop-control-reduced-\(reduced)", labels.contains { $0.contains("Arrêter la réception") })
            }
            observations.append(["id": "connected-reduced-\(reduced)", "accessibilityStrings": labels,
                                 "waitingEvents": current.waitingEvents, "selectionEventID": event.id,
                                 "frozenCapsuleSHA256": capsule.digestSHA256])
            for theme in ["light", "dark"] {
                state.dark = theme == "dark"; window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
                try await capture(host, filename: "motion-connected-\(reduced ? "reduced" : "normal")-\(theme).png",
                                  theme: theme, reduceMotion: reduced, scene: "Actual ActivityView and InvestigationView, paused live collection, fixture receiving state")
            }
        }
        withAnimation(.easeInOut(duration: 0.9)) { current.toggleFollow() }
        await current.waitForPresentation(); try await settle(host)
        check("connected-explicit-return-publishes-all-collected-events", current.snapshot?.events.count == snapshot.events.count + 1 && current.waitingEvents == 0)
        check("connected-explicit-return-selection-preserved", current.selection == selection && canvas.selectedID == event.id)
        check("connected-explicit-return-deliberately-resets-extent", current.timelineWindow == current.timelineProjection?.bounds.map { $0.start...$0.end } && current.timelineZoom == 1)
        check("connected-explicit-return-frozen-json-and-sha-preserved", try current.investigation.capsule?.transmissionJSON() == frozen && current.investigation.capsule?.digestSHA256 == capsule.digestSHA256)
        guard let followedItem = current.timelineProjection?.item(id: event.id), let followedGeometry = canvas.geometry else { throw failure("Timeline disappeared after explicit return.") }
        let followedRect = followedGeometry.rect(for: followedItem)
        let followedWindow = current.timelineWindow, followedOrigin = current.timelineOrigin
        let followedScrollOrigin = timelineScroll.contentView.bounds.origin
        observations.append(["id": "connected-explicit-return", "geometryBefore": rectRecord(originalRect), "geometryAfter": rectRecord(followedRect),
                             "reason": "LensStore.toggleFollow intentionally schedules resetTimelineExtent; movement from explicit return is not a streaming stability regression."])
        let second = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-01T15:02:00.000Z", "type": "response_item",
              "payload": ["type": "message", "id": "qa-motion-followed-append", "role": "assistant", "content": [["type": "output_text",
              "text": "Deuxième événement direct anonyme, suivi visuel actif."]]]], options: [.sortedKeys]) + Data([10])
        let nextWriter = try FileHandle(forWritingTo: rootRollout); try nextWriter.seekToEnd(); try nextWriter.write(contentsOf: second); try nextWriter.close()
        let nextDeadline = Date().addingTimeInterval(8)
        while current.snapshot?.events.count == snapshot.events.count + 1 && Date() < nextDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        await current.waitForPresentation(); try await settle(host)
        check("connected-followed-append-publishes-all-events", current.snapshot?.events.count == snapshot.events.count + 2 && current.waitingEvents == 0)
        check("connected-followed-append-selection-preserved", current.selection == selection && canvas.selectedID == event.id)
        check("connected-followed-append-window-and-origin-preserved", current.timelineWindow == followedWindow && current.timelineOrigin == followedOrigin && near(timelineScroll.contentView.bounds.origin, followedScrollOrigin))
        if let nextItem = current.timelineProjection?.item(id: event.id), let nextGeometry = canvas.geometry {
            check("connected-followed-append-existing-event-exact-geometry", nextItem == followedItem && nextGeometry.rect(for: nextItem) == followedRect)
        } else { check("connected-followed-append-existing-event-exact-geometry", false) }
        check("connected-followed-append-frozen-json-and-sha-preserved", try current.investigation.capsule?.transmissionJSON() == frozen && current.investigation.capsule?.digestSHA256 == capsule.digestSHA256)
        current.investigation.sending = false
        window.close()
    }

    private func install<V: View>(_ host: NSHostingView<V>, size: NSSize) -> NSWindow {
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Codex Lens — anonymous Motion qualification"
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        window.appearance = NSAppearance(named: .aqua)
        windows.append(window); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func settle<V: View>(_ host: NSHostingView<V>) async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
    }
    private func capture<V: View>(_ host: NSHostingView<V>, filename: String, theme: String, reduceMotion: Bool, scene: String) async throws {
        try await settle(host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No native bitmap.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("No native PNG.") }
        try png.write(to: output.appendingPathComponent(filename))
        check("render-nonempty-" + filename, png.count > 4096 && bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        renders.append(["filename": filename, "scene": scene, "theme": theme, "reduceMotion": reduceMotion,
                        "logicalWidth": host.bounds.width, "logicalHeight": host.bounds.height,
                        "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                        "bytes": png.count, "sha256": digest(png), "anonymous": true,
                        "method": "Own NSHostingView bitmap cache; not compositor or production screenshot"])
    }
    private func accessibilityStrings(_ host: NSView) -> [String] {
        var result: [String] = [], seen: Set<ObjectIdentifier> = []
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, let element = object as? NSAccessibilityProtocol else { return }
            let identifier = ObjectIdentifier(element as AnyObject)
            guard seen.insert(identifier).inserted else { return }
            if let label = element.accessibilityLabel(), !label.isEmpty { result.append(label) }
            if let value = element.accessibilityValue() as? String, !value.isEmpty { result.append(value) }
            if let identifier = element.accessibilityIdentifier(), !identifier.isEmpty { result.append("identifier:" + identifier) }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return Array(Set(result)).sorted()
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func readingOrigin(_ scroll: NSScrollView) -> NSPoint {
        let origin = scroll.contentView.bounds.origin
        return NSPoint(x: origin.x + (scroll.verticalRulerView?.ruleThickness ?? 0), y: origin.y)
    }
    private func observeReader(_ stage: String, editor: NSTextView, scroll: NSScrollView) {
        observations.append(["stage": stage, "kind": "native-reader-layout",
                             "scrollFrame": NSStringFromRect(scroll.frame), "scrollBounds": NSStringFromRect(scroll.bounds),
                             "clipFrame": NSStringFromRect(scroll.contentView.frame), "clipBounds": NSStringFromRect(scroll.contentView.bounds),
                             "editorFrame": NSStringFromRect(editor.frame), "editorBounds": NSStringFromRect(editor.bounds),
                             "documentHeight": scroll.documentView?.bounds.height ?? 0,
                             "clipHeight": scroll.contentView.bounds.height,
                             "constrainedClipBounds": NSStringFromRect(scroll.contentView.constrainBoundsRect(scroll.contentView.bounds)),
                             "originX": readingOrigin(scroll).x, "originY": readingOrigin(scroll).y])
    }
    private func rectRecord(_ rect: TimelineRect) -> [String: Double] { ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height] }
    private func selectedString(_ editor: NSTextView) -> String? {
        let text = editor.string as NSString, range = editor.selectedRange()
        guard range.location != NSNotFound, range.location <= text.length, range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }
    private func near(_ a: NSPoint, _ b: NSPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
    private func ownRollout(home: URL, id: String) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil),
              let path = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.hasSuffix(id + ".jsonl") }) else {
            throw failure("Own rollout absent.")
        }
        return path
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
        store?.stopObserving(); await store?.investigation.flushAndStop()
        for window in windows { window.close() }
    }
    func recordFatal(_ error: Error) {
        check("fatal", false); observations.append(["fatal": error.localizedDescription])
        store?.stopObserving(); for window in windows { window.close() }
        receipt["finishedAt"] = Date().ISO8601Format(); try? saveReceipt()
    }
    private func argument(_ name: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw failure("Missing " + name) }
        return CommandLine.arguments[index + 1]
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ text: String) -> NSError { NSError(domain: "CodexLensMotionProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
