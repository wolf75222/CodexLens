import AppKit
import Foundation
import LensCore
import SwiftUI
import Combine

/// Runtime regression for navigation and a detached native hosting window.
/// No visible window, Dock item, inference, account or observed-source write.
@main struct SideChatV30Main {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let run = SideChatV30Run()
            do { try await run.run() } catch { run.fail(error) }
            await run.finish()
            application.terminate(nil)
        }
        application.run()
    }
}

@MainActor private final class SideChatV30Run {
    private var output = URL(fileURLWithPath: "/private/tmp")
    private var checks: [[String: Any]] = []
    private var stores: [LensStore] = []

    private struct TabState: Equatable {
        let id: UUID
        let destination: Destination
        let pinned: Bool
    }
    private struct CenterState: Equatable {
        let selection: Destination?
        let section: LensSection
        let activityMode: ActivityInspectionMode
        let tabs: [TabState]
        let activeTab: UUID?
        let query: String
        let agentQuery: String
        let agentFilter: String?
        let environmentFilter: String?
        let resourceFilter: String?
        let kindFilter: EventKind?
        let instructionFilter: String?
        let period: ClosedRange<Date>?
        let timelineWindow: ClosedRange<Date>?
        let timelineZoom: Double
        let timelineOrigin: CGPoint
        let follow: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        @MainActor init(_ store: LensStore) {
            selection = store.selection; section = store.section; activityMode = store.activityMode
            tabs = store.tabs.map { TabState(id: $0.id, destination: $0.destination, pinned: $0.pinned) }
            activeTab = store.activeTab; query = store.query; agentQuery = store.agentQuery
            agentFilter = store.agentFilter; environmentFilter = store.environmentFilter
            resourceFilter = store.resourceFilter; kindFilter = store.kindFilter
            instructionFilter = store.originInstructionFilter; period = store.period
            timelineWindow = store.timelineWindow; timelineZoom = store.timelineZoom
            timelineOrigin = store.timelineOrigin; follow = store.follow
            canGoBack = store.canGoBack; canGoForward = store.canGoForward
        }
    }
    private struct LegacyWindowTabs: Encodable {
        let tabs: [LensTab]
        let activeTab: UUID?
    }
    private func argument(_ key: String) throws -> String {
        guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { throw LensError.unavailable("Missing " + key) }
        return CommandLine.arguments[index + 1]
    }
    private func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + name) }; return value
    }
    private func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
    private func settle(_ store: LensStore) async {
        await store.waitForPresentation()
        for _ in 0..<12 { await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    private func makeStore(home: URL, archive: InvestigationArchive, cacheName: String, scope: String = UUID().uuidString) -> LensStore {
        let store = LensStore(sourceHome: home, investigationArchive: archive, cacheDirectory: output.appendingPathComponent(cacheName))
        store.setNavigationScope(scope); stores.append(store); return store
    }

    func run() async throws {
        output = URL(fileURLWithPath: try argument("--output"))
        let corpus = URL(fileURLWithPath: try argument("--corpus"))
        let manifest = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any], "corpus manifest")
        let root = try require(manifest["rootID"] as? String, "root ID")
        let home = URL(fileURLWithPath: try require(manifest["home"] as? String, "anonymous Codex home"))
        let cases = try require(manifest["originCases"] as? [String: Any], "origin fixture cases")
        let callID = try require(cases["mainPatchCallID"] as? String, "recorded patch call")
        let archive = InvestigationArchive(directory: output.appendingPathComponent("archive-primary"))
        let store = makeStore(home: home, archive: archive, cacheName: "index-primary")
        let peer = makeStore(home: home, archive: InvestigationArchive(directory: output.appendingPathComponent("archive-peer")), cacheName: "index-peer")
        await store.start(); await store.open(root); await settle(store)
        await peer.start(); await peer.open(root); await settle(peer)
        let snapshot = try require(store.snapshot, "loaded history")
        let presentation = try require(store.presentation, "loaded presentation")
        let call = try require(snapshot.events.first { $0.callID == callID && $0.kind == .toolCall }, "fixture patch event")
        let change = try require(snapshot.changes.first { $0.kind == .recordedResult && presentation.eventsByID[$0.eventID]?.callID == callID && $0.evidence.hasPrefix("FileChange") }, "recorded diff result")

        peer.navigate(.event(call.id), newTab: true); peer.agentFilter = call.agentID; peer.follow = false
        await settle(peer)
        let peerBefore = CenterState(peer)
        store.navigate(.event(call.id), newTab: true); store.pinTab(try require(store.activeTab, "pinned event tab"))
        store.navigate(.change(change.id), newTab: true)
        store.agentFilter = call.agentID; store.environmentFilter = change.environmentID
        store.kindFilter = .toolCall; store.query = "origin"; store.agentQuery = "writer"
        store.period = call.timestamp.addingTimeInterval(-1)...call.timestamp.addingTimeInterval(1)
        store.follow = false; await settle(store)
        store.timelineZoom = 2; store.timelineOrigin = CGPoint(x: 83, y: 7)
        let centerBefore = CenterState(store)
        let prepared = await store.prepareInvestigation(for: .change(change.id))
        await settle(store)
        check("prepare-opens-lateral-chat-without-central-navigation", prepared && store.chatVisible && CenterState(store) == centerBefore)
        check("prepare-never-starts-inference", !store.investigation.sending && store.investigation.codexChatID == nil)
        let oldCapsule = try require(store.investigation.capsule, "prepared frozen capsule")
        let oldPiece = try require(oldCapsule.pieces.first { $0.kind == "originEvidence" }, "frozen origin proof")
        let oldRecord = try await archive.save(capsule: oldCapsule, question: "Anonymous archived origin question")

        store.navigate(.investigation(oldCapsule.id), newTab: true)
        check("investigation-destination-leaves-central-tabs-and-history-intact", store.chatVisible && CenterState(store) == centerBefore)
        store.toggleChat()
        check("hiding-chat-keeps-reading-context", !store.chatVisible && CenterState(store) == centerBefore)
        store.showChat()
        store.inspectorVisible = true
        check("inspector-command-hides-chat-without-navigation", !store.chatVisible && store.inspectorVisible && CenterState(store) == centerBefore)
        store.showChat()
        check("reopening-chat-keeps-reading-context", store.chatVisible && CenterState(store) == centerBefore)
        check("peer-window-is-not-retargeted", CenterState(peer) == peerBefore && !peer.chatVisible && peer.investigation.capsule == nil)

        await store.investigation.beginNewQuestion()
        store.addCodeEvidence(text: "Anonymous independently captured draft excerpt", path: change.path,
                              environmentID: change.environmentID, version: "v30-fixture-capture", line: 1, historical: false)
        store.investigation.editQuestion("Keep this current draft while reading an older citation.")
        store.investigation.response = "Synthetic local response fixture; no inference occurred."
        let currentCapsule = try require(store.investigation.capsule, "new draft capsule")
        let currentQuestion = store.investigation.question, currentResponse = store.investigation.response
        check("code-evidence-opens-chat-without-central-navigation", store.chatVisible && CenterState(store) == centerBefore)
        check("new-draft-has-distinct-frozen-identity", currentCapsule.id != oldCapsule.id)
        store.toggleChat(); store.showChat()
        check("hide-show-keeps-current-draft-and-response", store.chatVisible && CenterState(store) == centerBefore
              && store.investigation.capsule?.representsSameFrozenContent(as: currentCapsule) == true
              && store.investigation.question == currentQuestion && store.investigation.response == currentResponse)
        let address = try EvidenceAddress(rootID: root, capsuleID: oldCapsule.id, pieceID: oldPiece.id)
        await store.handleURL(address.url); await settle(store)
        check("old-citation-opens-exact-frozen-central-proof", store.selection == .evidence(capsule: oldCapsule.id, piece: oldPiece.id)
              && store.displayedEvidenceCapsule?.representsSameFrozenContent(as: oldCapsule) == true
              && store.displayedEvidencePieceID == oldPiece.id
              && store.displayedEvidenceCapsule?.pieces.first(where: { $0.id == oldPiece.id })?.text == oldPiece.text)
        check("old-citation-does-not-replace-current-chat-draft", store.investigation.capsule?.representsSameFrozenContent(as: currentCapsule) == true
              && store.investigation.question == currentQuestion && store.investigation.response == currentResponse)
        check("old-citation-keeps-chat-open-without-send", store.chatVisible && !store.investigation.sending && store.investigation.codexChatID == nil)
        check("old-proof-keeps-stable-internal-link", store.deepLink() == address.url)
        let displayed = try require(store.displayedEvidenceCapsule, "displayed old capsule")
        let input = InvestigationPresentationInput(rootID: displayed.rootThreadID, capsuleID: displayed.id, capsuleDigest: displayed.digestSHA256,
            response: "[" + oldPiece.id + "]", question: "", model: "", includePayload: false, connectionMode: "codexLocal", language: "fr")
        let rendered = try await InvestigationPresentationCache.shared.prepare(capsule: displayed, input: input)
        check("old-proof-presentation-validates-its-own-capsule", rendered.input.capsuleID == oldCapsule.id && rendered.citations.validIDs.contains(oldPiece.id))
        store.goBack(); await settle(store)
        check("back-from-old-proof-restores-central-selection-and-filters", store.selection == centerBefore.selection
              && store.section == centerBefore.section && store.query == centerBefore.query
              && store.agentFilter == centerBefore.agentFilter && store.environmentFilter == centerBefore.environmentFilter
              && store.period == centerBefore.period && store.timelineOrigin == centerBefore.timelineOrigin)
        check("peer-still-independent-after-citation", CenterState(peer) == peerBefore && peer.investigation.capsule == nil)

        try await checkLegacyRestoration(home: home, archive: archive, root: root, change: change, recordID: oldRecord.record.id, capsule: oldCapsule)
        try await checkArchiveOnlyRestoration(archive: archive, root: root, recordID: oldRecord.record.id, capsule: oldCapsule)
        try await checkPaneTransitions(store: store)
        check("all-inspections-left-inference-idle", stores.allSatisfy { !$0.investigation.sending && $0.investigation.codexChatID == nil })
    }

    private func checkPaneTransitions(store: LensStore) async throws {
        LensGuideCoordinator.shared.onboarding.dismiss()
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: MainView().environmentObject(store).environment(\.lensWindowContext, context))
        // Keep NSHostingView's automatic constraints, as in the production
        // scene. Disabling sizingOptions would conceal the observed failure.
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1480, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var environmentInvalidations = 0
        let subscription = context.objectWillChange.sink { environmentInvalidations += 1 }
        window.contentView = host; context.attach(window)
        defer { subscription.cancel(); window.contentView = nil; window.close() }
        let selection = store.selection, question = store.investigation.question, capsuleID = store.investigation.capsule?.id
        func layout() async throws {
            for _ in 0..<10 {
                await Task.yield(); try await Task.sleep(nanoseconds: 20_000_000)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        func auxiliary() -> LensAuxiliaryPane.Container? {
            var queue = [host as NSView], index = 0
            while index < queue.count {
                let view = queue[index]; index += 1
                if let container = view as? LensAuxiliaryPane.Container, container.window === window { return container }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
        for size in [NSSize(width: 1480, height: 820), NSSize(width: 1080, height: 680), NSSize(width: 1640, height: 920)] {
            window.setContentSize(size)
            var surfacesCorrect = true
            for _ in 0..<4 {
                store.showChat(); try await layout()
                surfacesCorrect = surfacesCorrect && auxiliary()?.visibleSurfaceIsChat == true
                store.inspectorVisible = true; try await layout()
                surfacesCorrect = surfacesCorrect && auxiliary()?.visibleSurfaceIsInspector == true
            }
            check("native-distinct-visible-surface-\(Int(size.width))", surfacesCorrect)
            store.showChat(); try await layout()
            check("native-pane-transition-layout-\(Int(size.width))", window.contentView?.bounds.width == size.width
                  && store.selection == selection && store.investigation.question == question
                  && store.investigation.capsule?.id == capsuleID && !store.investigation.sending)
        }
        check("native-pane-registration-does-not-reinvalidate-scene", environmentInvalidations == 0)
        let centralPane = context.paneKeyboard.view(for: .content)
        let chatContainer = auxiliary()
        store.chatVisible = false; store.inspectorVisible = false; try await layout()
        store.showChat(); try await layout()
        check("hide-reopen-keeps-central-native-pane-mounted", centralPane != nil && context.paneKeyboard.view(for: .content) === centralPane)
        check("hide-reopen-retains-chat-surface-and-draft", auxiliary() === chatContainer && auxiliary()?.visibleSurfaceIsChat == true
              && store.investigation.question == question && store.investigation.capsule?.id == capsuleID)
        let beforeFocus = environmentInvalidations
        context.focusPane(.chat)
        check("native-chat-focus-reaches-editable-composer", context.paneKeyboard.activeRegion(in: window) == .chat
              && (window.firstResponder as? NSTextView)?.isEditable == true)
        check("native-focus-does-not-reinvalidate-window-context", environmentInvalidations == beforeFocus)
        let widthBefore = context.paneKeyboard.view(for: .chat)?.bounds.width ?? 0
        context.resizeActivePane(by: 48); try await layout()
        let widthAfter = context.paneKeyboard.view(for: .chat)?.bounds.width ?? 0
        checks.append(["name": "native-keyboard-resize-widens-chat", "passed": widthAfter > widthBefore + 40, "beforeWidth": widthBefore, "afterWidth": widthAfter])
        context.resizeActivePane(by: -48); try await layout()
        let restoredWidth = context.paneKeyboard.view(for: .chat)?.bounds.width ?? 0
        checks.append(["name": "native-keyboard-resize-restores-width", "passed": abs(restoredWidth - widthBefore) < 2, "restoredWidth": restoredWidth])
        let previousLanguage = LensL10n.language
        LensL10n.language = .en
        check("english-auxiliary-labels-are-translated", LensL10n.text("Inspecteur") == "Inspector" && LensL10n.text("Connexion…") == "Connection…")
        LensL10n.language = previousLanguage
    }

    private func seedLegacyTabs(scope: String, root: String, tabs: [LensTab], activeTab: UUID?) throws {
        var roots = UserDefaults.standard.dictionary(forKey: "lensRootByWindow") as? [String: String] ?? [:]
        roots[scope] = root; UserDefaults.standard.set(roots, forKey: "lensRootByWindow")
        var saved = UserDefaults.standard.dictionary(forKey: "lensTabsByRoot") as? [String: Data] ?? [:]
        saved[scope + "|" + root] = try JSONEncoder().encode(LegacyWindowTabs(tabs: tabs, activeTab: activeTab))
        UserDefaults.standard.set(saved, forKey: "lensTabsByRoot")
    }
    private func checkLegacyRestoration(home: URL, archive: InvestigationArchive, root: String, change: ChangeRecord, recordID: String, capsule: EvidenceCapsule) async throws {
        let scope = UUID().uuidString
        let ordinary = LensTab(destination: .change(change.id), pinned: true)
        let legacyChat = LensTab(destination: .investigation(recordID))
        try seedLegacyTabs(scope: scope, root: root, tabs: [ordinary, legacyChat], activeTab: legacyChat.id)
        let restored = makeStore(home: home, archive: archive, cacheName: "index-legacy", scope: scope)
        await restored.start(); await settle(restored)
        check("legacy-chat-tab-restores-laterally", restored.chatVisible && restored.investigation.capsule?.representsSameFrozenContent(as: capsule) == true)
        check("legacy-ordinary-tab-keeps-identity-and-pin", restored.tabs.count == 1 && restored.tabs.first?.id == ordinary.id
              && restored.tabs.first?.pinned == true && restored.activeTab == ordinary.id && restored.selection == ordinary.destination)
        restored.stopObserving(); await restored.investigation.flushAndStop()
    }
    private func checkArchiveOnlyRestoration(archive: InvestigationArchive, root: String, recordID: String, capsule: EvidenceCapsule) async throws {
        let scope = UUID().uuidString
        let legacyChat = LensTab(destination: .investigation(recordID))
        try seedLegacyTabs(scope: scope, root: root, tabs: [legacyChat], activeTab: legacyChat.id)
        let restored = makeStore(home: output.appendingPathComponent("no-observed-journals"), archive: archive, cacheName: "index-archive-only", scope: scope)
        await restored.start(); await settle(restored)
        check("archive-only-chat-is-still-accessible", restored.snapshot?.root.id == root && restored.chatVisible
              && restored.investigation.capsule?.representsSameFrozenContent(as: capsule) == true)
        check("archive-only-restoration-invents-no-observed-history", restored.snapshot?.events.isEmpty == true
              && restored.snapshot?.agents.isEmpty == true && restored.snapshot?.environments.isEmpty == true
              && restored.snapshot?.resources.isEmpty == true && restored.snapshot?.changes.isEmpty == true
              && restored.snapshot?.root.modifiedAt == .distantPast
              && restored.snapshot?.coverage.contains(where: { $0.category == "archive-only" }) == true)
        restored.stopObserving(); await restored.investigation.flushAndStop()
    }
    func fail(_ error: Error) { checks.append(["name": "fatal", "passed": false, "error": error.localizedDescription]) }
    func finish() async {
        for store in stores { store.stopObserving(); await store.investigation.flushAndStop() }
        let receipt: [String: Any] = ["checks": checks,
            "allExecutedChecksPassed": !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched navigation/store regression and detached NSHostingView/NSWindow constraint transitions on anonymous origin JSONL. Production @main replaced. Activation prohibited; no visible window or Dock item. No inference, account inspection or observed-source write.",
            "unqualified": ["Production app startup and compositor rendering", "Physical keyboard, pointer resizing and VoiceOver", "Live inference and authentication"]]
        if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        }
    }
}
