import Foundation
import SwiftUI
import Observation
import AppKit
import CryptoKit
import QuartzCore
import LensCore

/// Source-matched navigation qualification against anonymous recorded journals.
/// The production stores and views are used; recorded tools are never executed.
@main struct ActionsV44Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await qualify() }
            catch { fputs("Actions qualification: \(error)\n", stderr) }
            NSApp.terminate(nil)
        }
        NSApp.run()
    }

    @MainActor private static func qualify() async throws {
        let output = try argument("--output"), corpus = try argument("--corpus")
        let fixture = try ActionsFixture(corpus: corpus)
        let buildManifestURL = output.appendingPathComponent("native-design-v07-source-manifest.json")
        let buildManifestBytes = try Data(contentsOf: buildManifestURL)
        let buildManifest = try require(try JSONSerialization.jsonObject(with: buildManifestBytes) as? [String: Any], "source manifest")
        LensL10n.language = .fr
        LensGuideCoordinator.shared.onboarding.dismiss()
        let scope = UUID().uuidString
        let store = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive")),
            cacheDirectory: output.appendingPathComponent("cache"), readerPool: SessionReaderPool())
        store.setNavigationScope(scope)
        await store.start(); await store.open(fixture.rootID); await store.waitForPresentation()
        defer { store.stopObserving() }
        store.showSessionPicker = false; store.chatVisible = false; store.inspectorVisible = false
        var checks: [[String: Any]] = [], observations: [[String: Any]] = [], renders: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        check("entrypoint-matches-frozen-source-manifest", buildManifest["entrypoint"] as? String == "ActionsV44Main.swift" && buildManifest["productionEntryPointReplaced"] as? Bool == true && buildManifest["copiedAppSourcesModified"] as? Bool == false)
        let unnamedAttachment = ResourceRecord(location: "trace:anonymous:attachment:3", roles: [.supplied])
        check("calm-unnamed-attachment-keeps-identity-with-readable-title", LensUI.resourceTitle(unnamedAttachment) == LensL10n.text("Pièce jointe embarquée") && unnamedAttachment.location == "trace:anonymous:attachment:3")
        let namedAttachment = ResourceRecord(location: "trace:anonymous:attachment:4", name: "Diagram.svg", roles: [.supplied])
        check("calm-named-attachment-preserves-recorded-filename", LensUI.resourceTitle(namedAttachment) == "Diagram.svg")
        let snapshot = try require(store.snapshot, "loaded anonymous history")
        let a = try require(snapshot.events.first { $0.callID == fixture.patchCallID && $0.kind == .toolCall }, "recorded patch call")
        let b = try require(a.relatedEventID.flatMap { store.event($0) }, "recorded call result")
        let c = try require(snapshot.events.first { $0.kind == .toolCall && $0.id != a.id && $0.id != b.id }, "third recorded event")
        let agent = try require(snapshot.agents.first { $0.id == a.agentID }, "recorded producer agent")
        let aDestination = Destination.event(a.id), bDestination = Destination.event(b.id)
        // Observation must notify only the displayed field. A rejected source
        // never reaches the clipboard and is deterministic on the anonymous corpus.
        let copier = RecordedCopyController()
        let issueChanged = LensObservationFlag(), busyChanged = LensObservationFlag()
        withObservationTracking { _ = copier.issue } onChange: { issueChanged.mark() }
        withObservationTracking { _ = copier.busy } onChange: { busyChanged.mark() }
        copier.copy(event: a, related: nil, part: "input",
            source: SourceRef(path: "/anonymous/not-selected", length: 1, line: 1), store: store)
        check("observable-copy-error-publishes-without-clipboard-write", issueChanged.value && copier.issue != nil && !copier.busy)
        check("observable-copy-error-does-not-invalidate-busy-only-observer", !busyChanged.value)
        check("localized-duration-follows-french-interface", LensUI.duration(0.125, fractionDigits: 3) == "0,125 s")
        LensL10n.language = .en
        check("localized-duration-follows-english-interface", LensUI.duration(0.125, fractionDigits: 3) == "0.125 s")
        LensL10n.language = .fr
        for accent in [LensControlAccent.lens, .slate, .sage] {
            let color = accent.filledNSColor.usingColorSpace(.sRGB)!
            let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { value -> Double in
                let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
            check("filled-control-" + accent.rawValue + "-white-label-reference-contrast", 1.05 / (luminance + 0.05) >= 4.5)
        }

        // A table selection creates/reuses the reading tab without replacing the list.
        store.navigate(aDestination)
        check("ordinary-event-selection-keeps-list", store.selection == aDestination && !store.tabContentVisible && store.tabContentDestination == nil)
        closeAllTabs(store)
        store.navigate(aDestination, newTab: true)
        let aTab = try require(store.tabs.first { $0.destination == aDestination }, "event A tab")
        check("explicit-event-tab-opens-content", store.tabs.count == 1 && store.activeTab == aTab.id && store.tabContentVisible && store.tabContentDestination == aDestination)
        store.navigate(bDestination, newTab: true)
        let bTab = try require(store.tabs.first { $0.destination == bDestination }, "event B tab")
        let originalDestinations = destinations(store)
        check("second-event-tab-keeps-first-destination", store.tabs.count == 2 && store.activeTab == bTab.id && store.tabContentDestination == bDestination && originalDestinations[aTab.id] == aDestination)
        store.navigate(aDestination, newTab: true)
        check("opening-existing-tab-deduplicates-and-selects", store.tabs.count == 2 && store.activeTab == aTab.id && store.tabContentDestination == aDestination && destinations(store) == originalDestinations)
        store.selectTab(bTab)
        check("select-tab-opens-exact-destination", store.activeTab == bTab.id && store.selection == bDestination && store.tabContentDestination == bDestination)
        store.goBack()
        check("back-after-tab-switch-restores-A-without-overwriting-B", store.activeTab == aTab.id && store.selection == aDestination && store.tabContentDestination == aDestination && destinations(store) == originalDestinations)
        store.goForward()
        check("forward-after-tab-switch-restores-B-without-duplicates", store.activeTab == bTab.id && store.selection == bDestination && store.tabContentDestination == bDestination && destinations(store) == originalDestinations && Set(store.tabs.map(\.destination)).count == store.tabs.count)

        store.navigate(aDestination)
        check("ordinary-link-to-existing-tab-preserves-other-tabs", store.activeTab == aTab.id && store.selection == aDestination && destinations(store) == originalDestinations)
        store.goBack()
        check("back-after-ordinary-link-restores-other-tab", store.activeTab == bTab.id && store.selection == bDestination && destinations(store) == originalDestinations)
        store.showInTimeline(a.id)
        check("timeline-reveal-preserves-other-open-tab", store.activeTab == aTab.id && store.selection == aDestination && !store.tabContentVisible && destinations(store) == originalDestinations)
        store.goBack()
        check("back-after-timeline-reveal-restores-other-tab-content", store.activeTab == bTab.id && store.tabContentDestination == bDestination && destinations(store) == originalDestinations)

        store.browseSection(store.section)
        check("browse-current-section-exits-tab-content", !store.tabContentVisible && store.tabContentDestination == nil && store.selection == bDestination && destinations(store) == originalDestinations)
        store.goBack()
        check("back-restores-explicit-tab-presentation", store.activeTab == bTab.id && store.tabContentDestination == bDestination && destinations(store) == originalDestinations)
        store.goForward()
        check("forward-restores-list-presentation", !store.tabContentVisible && store.tabContentDestination == nil && destinations(store) == originalDestinations)

        store.pinTab(aTab.id); store.selectTab(try require(store.tabs.first { $0.id == aTab.id }, "pinned A"))
        store.browseSection(.activity); store.navigate(.event(c.id))
        check("ordinary-navigation-preserves-pinned-tab-and-list", store.tabs.first { $0.id == aTab.id }.map { $0.pinned && $0.destination == aDestination } == true && store.selection == .event(c.id) && !store.tabContentVisible && store.tabs.count == 3)
        store.selectTab(try require(store.tabs.first { $0.id == aTab.id }, "pinned A after ordinary navigation"))
        check("selecting-pinned-tab-does-not-duplicate-it", store.activeTab == aTab.id && store.tabContentDestination == aDestination && store.tabs.count == 3)
        store.pinTab(aTab.id)
        check("unpin-retains-tab-identity-and-destination", store.tabs.first { $0.id == aTab.id }.map { !$0.pinned && $0.destination == aDestination } == true)
        store.closeTab(aTab.id)
        let replacement = store.tabs.first { $0.id == store.activeTab }
        check("close-active-tab-selects-retained-tab", store.tabs.count == 2 && !store.tabs.contains { $0.id == aTab.id } && replacement != nil && replacement?.destination == store.selection && store.tabContentVisible)
        closeAllTabs(store)
        check("close-last-tab-clears-content", store.tabs.isEmpty && store.activeTab == nil && store.selection == nil && !store.tabContentVisible && store.tabContentDestination == nil)

        store.browseSection(.calls); store.timelineVisible = false; store.activityMode = .communications
        store.navigate(aDestination, newTab: true)
        store.showInTimeline(a.id)
        check("show-in-timeline-from-calls-opens-visible-chronology", store.section == .activity && store.activityMode == .chronology && store.timelineVisible && store.selection == aDestination && !store.tabContentVisible && store.tabContentDestination == nil && store.timelineFocus?.eventID == a.id)
        check("timeline-reveal-persists-list-presentation", persistedContentMode(store) == false)
        store.navigate(bDestination)
        check("ordinary-selection-after-timeline-reveal-retains-list", store.selection == bDestination && !store.tabContentVisible && store.tabContentDestination == nil)

        let instructionID = try require(store.presentation?.originInspection.associatedEventIDsByInstruction.keys.sorted().first { store.event($0) != nil }, "instruction activity relation")
        store.showInstructionActivity(instructionID)
        check("instruction-filter-alone-enables-clear-filters", store.originInstructionFilter == instructionID && store.query.isEmpty && store.agentFilter == nil && store.environmentFilter == nil && store.resourceFilter == nil && store.kindFilter == nil && store.period == nil && store.canPerform(.clearFilters))
        store.perform(.clearFilters)
        check("clear-filters-removes-instruction-scope", store.originInstructionFilter == nil && !store.canPerform(.clearFilters))
        store.showChat(); store.perform(.inspector)
        check("inspector-action-switches-away-from-chat", store.inspectorVisible && !store.chatVisible)
        store.perform(.inspector)
        check("inspector-action-hides-inspector", !store.inspectorVisible && !store.chatVisible)

        // Build context from actual recorded events, without a connection or send.
        let recordedContextPrepared = await store.prepareInvestigation(for: aDestination)
        let frozen = try require(store.investigation.capsule, "recorded context")
        let currentPiece = try require(frozen.pieces.last, "recorded context element")
        let currentEvidence = Destination.evidence(capsule: frozen.id, piece: currentPiece.id)
        check("recorded-event-prepares-frozen-context", recordedContextPrepared && frozen.rootThreadID == fixture.rootID && !frozen.pieces.isEmpty)
        store.investigation.question = "Question locale de test, sans envoi."
        // A clearly marked fixture state checks that selection cannot erase an answer.
        store.investigation.response = "État synthétique de test pour vérifier la conservation ; aucun modèle appelé."
        let draftBefore = store.investigation.question, responseBefore = store.investigation.response
        check("current-evidence-is-a-known-action-target", store.canPerform(.investigate, target: currentEvidence) && !store.canPerform(.investigate, target: .evidence(capsule: frozen.id, piece: "absent-piece")))
        let currentPrepared = await store.prepareInvestigation(for: currentEvidence)
        check("current-evidence-selects-piece-without-replacing-draft-or-answer", currentPrepared && store.investigation.capsule?.id == frozen.id && store.investigation.capsule?.digestSHA256 == frozen.digestSHA256 && store.investigation.capsule?.pieces.count == frozen.pieces.count && store.investigation.inspectedPiece == currentPiece.id && store.investigation.question == draftBefore && store.investigation.response == responseBefore && store.chatVisible)
        let savedFrozen = try await store.investigation.archive.save(capsule: frozen, question: draftBefore)
        let archivedBefore = try require(try await store.investigation.archive.load(id: savedFrozen.record.id), "saved context archive")
        let archivedBytesBefore = try archivedBefore.capsule.transmissionJSON()
        store.investigation.clear()
        let environmentID = try require(a.environmentID, "recorded patch environment")
        let environmentPrepared = await store.prepareInvestigation(for: .environment(environmentID))
        let environmentContext = try require(store.investigation.capsule, "new environment context")
        check("separate-draft-uses-recorded-environment-metadata", environmentPrepared && environmentContext.id != frozen.id && environmentContext.pieces.contains { $0.kind == "environmentMetadata" && $0.environmentID == environmentID } && environmentContext.pieces.allSatisfy { ["environmentMetadata", "collectionManifest"].contains($0.kind) })
        store.investigation.question = "Brouillon local courant, sans envoi."
        let archivedAddress = try EvidenceAddress(rootID: fixture.rootID, capsuleID: frozen.id, pieceID: currentPiece.id)
        await store.openEvidence(archivedAddress)
        check("archived-evidence-is-a-known-action-target", store.selection == currentEvidence && store.displayedEvidenceCapsule?.id == frozen.id && store.canPerform(.investigate, target: currentEvidence) && store.canPerform(.copyLink, target: currentEvidence))
        let archivedPrepared = await store.prepareInvestigation(for: currentEvidence)
        let added = store.investigation.capsule?.pieces.first { $0.id == store.investigation.inspectedPiece }
        check("archived-evidence-appends-exact-frozen-element", archivedPrepared && store.investigation.capsule?.pieces.count == environmentContext.pieces.count + 1 && added?.text == currentPiece.text && added?.kind == currentPiece.kind && added?.knownVersion == currentPiece.knownVersion && added?.environmentID == currentPiece.environmentID && added?.sourceRefs == currentPiece.sourceRefs && store.investigation.question == "Brouillon local courant, sans envoi.")
        let retainedArchive = try await store.investigation.archive.load(id: savedFrozen.record.id)
        let archivedBytesAfter = try retainedArchive?.capsule.transmissionJSON()
        check("reuse-keeps-original-archived-capsule-immutable", retainedArchive?.capsule.representsSameFrozenContent(as: frozen) == true && archivedBytesAfter == archivedBytesBefore)
        store.chatVisible = false; store.inspectorVisible = false

        closeAllTabs(store)
        store.enableLiveTimeline(at: Date())
        store.previewLiveEvent(a.id)
        check("direct-preview-selects-event-without-promoting-tab", store.liveTimelineVisible && store.livePreview == aDestination && store.selection == aDestination && store.tabs.isEmpty && !store.tabContentVisible)
        check("calm-direct-preview-identifies-central-reader", store.centrallyPresentedEventID == a.id)
        store.openLivePreviewInTab()
        let directTab = try require(store.tabs.first, "promoted Direct event tab")
        check("direct-preview-promotes-to-content-tab-with-axis-retained", store.liveTimelineVisible && store.livePreview == nil && store.tabContentDestination == aDestination && store.tabs.count == 1 && directTab.destination == aDestination)
        store.previewLiveEvent(a.id); store.openLivePreviewInTab()
        check("direct-preview-promotion-deduplicates", store.tabs.count == 1 && store.activeTab == directTab.id && store.tabContentDestination == aDestination)
        store.previewLiveEvent(b.id); store.showLiveEventList()
        check("direct-list-route-clears-preview-and-content-but-keeps-tab", store.liveTimelineVisible && store.livePreview == nil && store.selection == nil && !store.tabContentVisible && store.tabContentDestination == nil && store.tabs.count == 1)
        check("calm-direct-list-does-not-hide-inspector-reader", store.centrallyPresentedEventID == nil)
        check("direct-list-route-persists-list-presentation", persistedContentMode(store) == false)
        store.selectTab(directTab)
        check("direct-tab-selection-reopens-event-content", store.liveTimelineVisible && store.livePreview == nil && store.tabContentDestination == aDestination && store.activeTab == directTab.id)
        store.disableLiveTimeline()
        check("hide-direct-retains-explicit-event-tab", !store.liveTimelineVisible && store.tabContentDestination == aDestination && store.activeTab == directTab.id)

        // Navigation from objects must checkpoint before changing the activity
        // scope. Use recorded identities and deliberately conflicting filters.
        let environment = try require(snapshot.environments.first { $0.id == a.environmentID }, "recorded call environment")
        let resource = try require(snapshot.resources.first, "recorded session resource")
        let oldAgentID = try require(snapshot.agents.first { $0.id != agent.id }?.id, "second recorded agent")
        let oldEnvironmentID = try require(snapshot.environments.first { $0.id != environment.id }?.id, "second recorded environment")
        let oldResourceID = try require(snapshot.resources.first { $0.id != resource.id }?.id, "second recorded resource")
        let outsidePeriod = a.timestamp.addingTimeInterval(-7200)...a.timestamp.addingTimeInterval(-3600)
        let unmatchedQuery = "navigation-regression-no-matching-text"
        let activityTargets: [(String, Destination)] = [
            ("agent", .agent(agent.id)),
            ("environment", .environment(environment.id)),
            ("resource", .resource(resource.id))
        ]
        func setPreviousFilters() {
            store.query = unmatchedQuery
            store.agentFilter = oldAgentID
            store.environmentFilter = oldEnvironmentID
            store.resourceFilter = oldResourceID
            store.kindFilter = .assistant
            store.period = outsidePeriod
            store.originInstructionFilter = instructionID
        }
        func previousFiltersAreRestored() -> Bool {
            store.query == unmatchedQuery && store.agentFilter == oldAgentID &&
                store.environmentFilter == oldEnvironmentID && store.resourceFilter == oldResourceID &&
                store.kindFilter == .assistant && store.period == outsidePeriod &&
                store.originInstructionFilter == instructionID
        }
        func activityFiltersMatch(_ target: Destination) -> Bool {
            var agentID = oldAgentID, environmentID = oldEnvironmentID, resourceID = oldResourceID
            switch target {
            case .agent(let id): agentID = id
            case .environment(let id): environmentID = id
            case .resource(let id): resourceID = id
            default: return false
            }
            return store.query == unmatchedQuery && store.agentFilter == agentID &&
                store.environmentFilter == environmentID && store.resourceFilter == resourceID &&
                store.kindFilter == .assistant && store.period == outsidePeriod &&
                store.originInstructionFilter == instructionID
        }
        for (name, target) in activityTargets {
            closeAllTabs(store); store.resetFilters()
            store.navigate(target, newTab: true)
            setPreviousFilters()
            let previousSection = store.section, previousTabs = destinations(store), previousTab = store.activeTab
            store.showActivity(for: target)
            check("navigation-activity-" + name + "-opens-scoped-collection",
                  store.section == .activity && store.activityMode == .chronology &&
                  store.selection == target && !store.tabContentVisible && store.livePreview == nil &&
                  activityFiltersMatch(target) && destinations(store) == previousTabs)
            store.goBack()
            check("navigation-activity-" + name + "-back-restores-object-and-prior-filters",
                  store.section == previousSection && store.selection == target && store.tabContentVisible &&
                  store.activeTab == previousTab && previousFiltersAreRestored() && destinations(store) == previousTabs)
            store.goForward()
            check("navigation-activity-" + name + "-forward-restores-scoped-collection",
                  store.section == .activity && store.selection == target && !store.tabContentVisible &&
                  store.livePreview == nil && activityFiltersMatch(target) && destinations(store) == previousTabs)
        }

        // A live preview is another navigation state, not a tab to overwrite.
        closeAllTabs(store); store.resetFilters(); store.browseSection(.activity)
        store.enableLiveTimeline(at: a.timestamp); store.previewLiveEvent(a.id)
        setPreviousFilters()
        store.showActivity(for: .resource(resource.id))
        check("navigation-activity-from-live-preview-clears-preview-without-creating-tab",
              store.liveTimelineVisible && store.livePreview == nil && !store.tabContentVisible &&
              store.section == .activity && store.selection == aDestination &&
              activityFiltersMatch(.resource(resource.id)) && store.tabs.isEmpty)
        store.goBack()
        check("navigation-activity-back-restores-live-preview-and-prior-filters",
              store.liveTimelineVisible && store.livePreview == aDestination && store.selection == aDestination &&
              !store.tabContentVisible && previousFiltersAreRestored() && store.tabs.isEmpty)
        store.goForward()
        check("navigation-activity-forward-restores-resource-scope-with-live-axis-retained",
              store.liveTimelineVisible && store.livePreview == nil && store.section == .activity &&
              !store.tabContentVisible && activityFiltersMatch(.resource(resource.id)) && store.tabs.isEmpty)
        store.disableLiveTimeline()

        // Explicit links open their exact content even when the surrounding
        // collection excludes it. Back/Forward must retain the user's scopes.
        closeAllTabs(store); store.resetFilters(); store.browseSection(.calls)
        store.navigate(.event(c.id)); setPreviousFilters(); await store.waitForPresentation()
        let previousLinkTabs = destinations(store)
        let eventExcluded = !store.events.contains { $0.id == a.id }
        store.navigate(aDestination, newTab: true)
        check("navigation-explicit-event-link-opens-excluded-event-without-resetting-filters",
              eventExcluded && store.selection == aDestination && store.tabContentDestination == aDestination &&
              previousFiltersAreRestored() && store.tabs.contains { $0.destination == aDestination })
        store.goBack()
        check("navigation-explicit-event-link-back-restores-filtered-call-collection",
              store.section == .calls && store.selection == .event(c.id) && !store.tabContentVisible &&
              previousFiltersAreRestored() && previousLinkTabs.allSatisfy { destinations(store)[$0.key] == $0.value })
        store.goForward()
        check("navigation-explicit-event-link-forward-reopens-same-recorded-content",
              store.selection == aDestination && store.tabContentDestination == aDestination && previousFiltersAreRestored())

        let selectedChange = try require(snapshot.changes.first { $0.eventID == a.id }, "recorded patch change")
        store.navigate(.change(selectedChange.id), newTab: true)
        await store.waitForPresentation()
        check("navigation-explicit-change-link-retains-excluded-source-and-filters",
              store.section == .changes && store.selection == .change(selectedChange.id) &&
              store.change(selectedChange.id)?.eventID == a.id && previousFiltersAreRestored() &&
              !store.matches(selectedChange.path + selectedChange.evidence, eventIDs: [selectedChange.eventID]))
        observations.append(["scenario": "filtered-change-link", "changeID": selectedChange.id,
            "recordedEventID": selectedChange.eventID,
            "limit": "This check establishes the exact selected source and retained filters; ChangesView detail materialization is qualified separately in the interactive production app."])
        store.goBack()
        check("navigation-explicit-change-link-back-restores-event-content-and-filters",
              store.selection == aDestination && store.tabContentDestination == aDestination && previousFiltersAreRestored())
        closeAllTabs(store); store.resetFilters(); store.browseSection(.activity)
        store.navigate(aDestination, newTab: true)

        // One native window hosts MainView, including the production split panes.
        await store.waitForPresentation()
        let context = LensWindowContext(store: store)
        let host = NSHostingView(rootView: MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, .light))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 1380, height: 920)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1380, height: 920), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Codex Lens — actions (données de test)"
        defer { window.contentViewController = nil; window.contentView = nil; window.close() }
        store.resetFilters(); await store.waitForPresentation()
        await runContextMenuChecksV44(store: store, window: window) { name, passed, detail in
            checks.append(["name": name, "passed": passed, "detail": detail])
        }
        window.setContentSize(NSSize(width: 1380, height: 920))
        window.contentView = host; context.attach(window); window.orderBack(nil)
        // The reader keeps provenance outside the text body. Match the recorded
        // first page, not the legacy clipboard format with source wrappers.
        let expectationPager = RecordedDocumentPager()
        let inputPage = try await expectationPager.begin(event: a, relatedEvent: b, part: "input")
        let inputText = inputPage.slices.map(\.text).joined()
        let inputRendered = try await waitForLayout(host) { !inputText.isEmpty && contentTextViews(context).contains { $0.string == inputText } }
        let eventRendered = inputRendered && context.paneKeyboard.view(for: .content).map { !descendants($0).contains { $0 is NSTableView } } == true
        check("native-main-view-renders-event-tab-content", eventRendered && store.tabContentDestination == aDestination)
        check("native-event-call-opens-recorded-input-by-default", inputRendered && store.tabContentDestination == aDestination)
        store.inspectorVisible = true
        let inspectorContext = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .inspector).map { descendants($0).compactMap { $0 as? NSTextView }.allSatisfy { $0.isFieldEditor || $0.isHiddenOrHasHiddenAncestor } } ?? false
        }
        check("calm-open-call-has-one-reader-and-contextual-inspector", inspectorContext && store.centrallyPresentedEventID == a.id && contentTextViews(context).contains { $0.string == inputText })
        window.makeFirstResponder(nil); context.find(.showFindInterface)
        let findShown = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .content).map { descendants($0).contains { ($0 as? NSScrollView)?.isFindBarVisible == true } } ?? false
        }
        check("find-command-opens-search-in-visible-event-text", findShown && store.tabContentDestination == aDestination && store.query.isEmpty)
        observations.append(["scenario": "event-tab", "identifiers": accessibilityIdentifiers(host), "selection": String(describing: store.selection)])
        if eventRendered { renders.append(try capture(host, path: output.appendingPathComponent("event-tab-content.png"))) }
        store.navigate(bDestination, newTab: true)
        let outputPage = try await expectationPager.begin(event: b, relatedEvent: a, part: "output")
        let outputText = outputPage.slices.map(\.text).joined()
        let outputRendered = try await waitForLayout(host) { !outputText.isEmpty && contentTextViews(context).contains { $0.string == outputText } }
        check("native-event-result-opens-recorded-output-by-default", outputRendered && store.tabContentDestination == bDestination)
        let inspectorResultContext = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .inspector).map { descendants($0).compactMap { $0 as? NSTextView }.allSatisfy { $0.isFieldEditor || $0.isHiddenOrHasHiddenAncestor } } ?? false
        }
        check("calm-result-switch-keeps-output-in-central-reader-only", inspectorResultContext && store.centrallyPresentedEventID == b.id && outputRendered)
        store.browseSection(.activity)
        let inspectorOutput = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .inspector).map { descendants($0).compactMap { $0 as? NSTextView }.contains { $0.string == outputText } } ?? false
        }
        check("calm-list-selection-keeps-full-recorded-output-in-inspector", inspectorOutput && store.centrallyPresentedEventID == nil)
        store.navigate(aDestination)
        let inspectorInput = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .inspector).map { descendants($0).compactMap { $0 as? NSTextView }.contains { $0.string == inputText } } ?? false
        }
        check("calm-list-call-selection-keeps-full-recorded-input-in-inspector", inspectorInput && store.centrallyPresentedEventID == nil)
        store.navigate(aDestination, newTab: true)
        let inspectorCollapsed = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .inspector).map { descendants($0).compactMap { $0 as? NSTextView }.allSatisfy { $0.isFieldEditor || $0.isHiddenOrHasHiddenAncestor } } ?? false
        }
        check("calm-reopening-call-unmounts-duplicate-reader", inspectorCollapsed && store.centrallyPresentedEventID == a.id)
        store.inspectorVisible = false
        if outputRendered { renders.append(try capture(host, path: output.appendingPathComponent("result-tab-content.png"))) }
        store.browseSection(.activity)
        let listRendered = try await waitForLayout(host) { context.paneKeyboard.view(for: .content).map { descendants($0).contains { $0 is NSTableView } } == true }
        check("native-main-view-restores-table-after-browsing", listRendered && !store.tabContentVisible)
        store.navigate(.agent(agent.id), newTab: true)
        let agentRendered = try await waitForLayout(host) {
            context.paneKeyboard.view(for: .content).map { pane in
                let views = descendants(pane)
                return views.contains { $0 is NSScrollView } && !views.contains { $0 is NSTableView } &&
                    !contentTextViews(context).contains { $0.string == inputText || $0.string == outputText }
            } == true
        }
        check("native-agent-tab-replaces-collection-with-object-reader", agentRendered && store.tabContentDestination == .agent(agent.id))
        observations.append(["scenario": "agent-tab", "identifiers": accessibilityIdentifiers(host), "selection": String(describing: store.selection)])
        if agentRendered { renders.append(try capture(host, path: output.appendingPathComponent("agent-tab-content.png"))) }

        // Reopening the same root exercises actual WindowTabs encoding/decoding.
        store.navigate(aDestination, newTab: true)
        let persistedTab = store.activeTab, persistedDestinations = destinations(store)
        await store.open(fixture.rootID); await store.waitForPresentation()
        check("reopen-restores-explicit-content-and-tab-identities", store.tabContentDestination == aDestination && store.activeTab == persistedTab && destinations(store) == persistedDestinations)
        store.browseSection(.activity)
        await store.open(fixture.rootID); await store.waitForPresentation()
        check("reopen-restores-list-mode-with-tab-identities", !store.tabContentVisible && store.tabContentDestination == nil && store.activeTab == persistedTab && destinations(store) == persistedDestinations)
        // Legacy data intentionally has no mode key: preserve its old list presentation.
        let legacyScope = UUID().uuidString
        let legacyTab = LensTab(destination: aDestination, pinned: true)
        var saved = UserDefaults.standard.dictionary(forKey: "lensTabsByRoot") as? [String: Data] ?? [:]
        saved[legacyScope + "|" + fixture.rootID] = try JSONEncoder().encode(LegacyWindowTabs(tabs: [legacyTab], activeTab: legacyTab.id))
        UserDefaults.standard.set(saved, forKey: "lensTabsByRoot")
        let legacyStore = LensStore(sourceHome: fixture.home,
            investigationArchive: InvestigationArchive(directory: output.appendingPathComponent("archive-legacy")),
            cacheDirectory: output.appendingPathComponent("cache-legacy"), readerPool: SessionReaderPool())
        legacyStore.setNavigationScope(legacyScope)
        await legacyStore.start(); await legacyStore.open(fixture.rootID); await legacyStore.waitForPresentation()
        check("legacy-tab-data-decodes-with-old-list-mode", legacyStore.snapshot?.root.id == fixture.rootID && legacyStore.tabs.count == 1 && legacyStore.activeTab == legacyTab.id && legacyStore.selection == aDestination && legacyStore.tabs.first?.pinned == true && !legacyStore.tabContentVisible && legacyStore.tabContentDestination == nil)
        legacyStore.stopObserving(); await legacyStore.investigation.flushAndStop()

        // Qualify the actual native row with a localized 12-hour timestamp.
        let formerLanguage = UserDefaults.standard.string(forKey: "lensLanguage")
        UserDefaults.standard.set("en", forKey: "lensLanguage")
        // Use the bounded table owner, so a restored scroll position and other
        // session filters cannot hide the event being measured.
        let clockHost = NSHostingView(rootView: EventListView(events: [a, c], title: "Localized recorded calls").environmentObject(store))
        clockHost.sizingOptions = []; clockHost.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = clockHost; window.setContentSize(clockHost.frame.size)
        let localizedColumnsFit = try await waitForLayout(clockHost) {
            let expected = [a.timestamp.lensFormatted(date: .omitted, time: .standard),
                            a.timestamp.lensFormatted(date: .abbreviated, time: .omitted)]
            guard let table = descendants(clockHost).compactMap({ $0 as? NSTableView }).first,
                  table.numberOfRows == 2, let row = table.view(atColumn: 0, row: 0, makeIfNecessary: true) else { return false }
            row.layoutSubtreeIfNeeded()
            let fields = descendants(row).compactMap { $0 as? NSTextField }
            return expected.allSatisfy { value in
                fields.contains { field in
                    field.stringValue == value && field.frame.width + 0.5 >= field.intrinsicContentSize.width
                }
            }
        }
        check("localized-event-time-and-date-fit-without-truncation", localizedColumnsFit)
        if let formerLanguage { UserDefaults.standard.set(formerLanguage, forKey: "lensLanguage") }
        else { UserDefaults.standard.removeObject(forKey: "lensLanguage") }
        window.contentView = host; window.setContentSize(NSSize(width: 1380, height: 920))

        // A hidden tab remains addressable; the native header exposes only two.
        closeAllTabs(store)
        for destination in [aDestination, bDestination, Destination.event(c.id)] { store.navigate(destination, newTab: true) }
        let overflowDestinations = destinations(store)
        let hiddenTab = try require(store.tabs.first { $0.destination == bDestination }, "overflow hidden tab")
        _ = try await waitForLayout(host) { !contentTextViews(context).isEmpty }
        check("redesign-three-tabs-retain-each-original-destination", store.tabs.count == 3 && Set(overflowDestinations.values) == Set([aDestination, bDestination, Destination.event(c.id)]) && overflowDestinations[hiddenTab.id] == bDestination)
        renders.append(try capture(host, path: output.appendingPathComponent("redesign-tab-overflow.png")))
        observations.append(["scenario": "tab-overflow", "identifiers": accessibilityIdentifiers(host),
            "limit": "The accessory hosting window does not expose SwiftUI tab IDs to the in-process accessibility API; visible-tab count is not asserted from that API."])
        store.selectTab(hiddenTab)
        let hiddenTabContent = try await waitForLayout(host) { !outputText.isEmpty && contentTextViews(context).contains { $0.string == outputText } }
        check("redesign-overflow-tab-selection-renders-the-same-recorded-output", hiddenTabContent && store.activeTab == hiddenTab.id && store.tabContentDestination == bDestination && destinations(store) == overflowDestinations)

        // Inspect the same product views at two window sizes and appearances.
        // These are native bitmap renders, not compositor screenshots or proof
        // of mouse hover. No new store, data adapter or model transport is used.
        closeAllTabs(store); store.inspectorVisible = false; store.chatVisible = false
        store.selection = nil; store.timelineVisible = true; store.resetTimelineExtent()
        for section in [LensSection.activity, .agents, .environments, .resources, .changes] {
            store.browseSection(section); store.selection = nil
            await store.waitForPresentation()
            _ = try await waitForLayout(host) { context.paneKeyboard.view(for: .content) != nil }
            renders.append(try capture(host, path: output.appendingPathComponent("polish-" + section.symbol.replacingOccurrences(of: ".", with: "-") + "-light.png")))
        }
        store.navigate(aDestination, newTab: true)
        let polishSelection = store.selection, polishTabs = destinations(store)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 980, height: 680))
        host.rootView = MainView().environmentObject(store).environment(\.lensWindowContext, context).environment(\.colorScheme, .dark)
        let narrowReader = try await waitForLayout(host) { !inputText.isEmpty && contentTextViews(context).contains { $0.string == inputText } }
        check("polish-resize-and-theme-retain-selection-tabs-and-recorded-input", narrowReader && store.selection == polishSelection && destinations(store) == polishTabs)
        renders.append(try capture(host, path: output.appendingPathComponent("polish-reader-dark-narrow.png")))
        store.showChat()
        window.setContentSize(NSSize(width: 1380, height: 920))
        _ = try await waitForLayout(host) { accessibilityIdentifiers(host).contains("lens-side-chat") }
        renders.append(try capture(host, path: output.appendingPathComponent("polish-chat-dark.png")))
        try await runGlassChromeChecksV54(output: output, check: check, renders: &renders)
        store.stopObserving(); await store.investigation.flushAndStop()
        for name in ["ellipsis", "line.3.horizontal.decrease", "book", "bubble.left.and.bubble.right"] {
            check("redesign-symbol-" + name + "-does-not-fall-back-to-question-mark",
                  LensSymbols.catalogue.contains(name) &&
                  (NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil || LensSymbols.name(name) == name))
        }
        check("anonymous-journals-and-worktree-files-remain-unchanged", fixture.sourcesUnchanged())
        check("source-manifest-remains-unchanged", (try? Data(contentsOf: buildManifestURL)) == buildManifestBytes)
        let receipt: [String: Any] = ["checks": checks, "renders": renders, "observations": observations,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Actual LensStore navigation and MainView in one accessory NSWindow; anonymous recorded journals; production entrypoint replaced by the source-matched verification script.",
            "sourceManifest": ["path": buildManifestURL.path, "sha256": digest(buildManifestBytes)],
            "fixture": ["corpus": corpus.path, "sourceHome": fixture.home.path, "rootID": fixture.rootID, "recordedCallID": fixture.patchCallID, "anonymous": true, "sourcesModified": false],
            "modelRequests": 0, "recordedToolsExecuted": 0,
            "unqualified": ["Production compositor, physical mouse/trackpad clicks and VoiceOver require interactive verification. Native PNG files are NSHostingView bitmap renders.", "The tab actions are dispatched through the production store; this probe does not synthesize a right-click menu gesture."]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
    }

    @MainActor private static func runGlassChromeChecksV54(output: URL, check: (String, Bool) -> Void, renders: inout [[String: Any]]) async throws {
        for preference in ["system", "opaque"] {
            for transparent in [false, true] {
                for contrast in [false, true] {
                    check("glass-policy-" + preference + "-" + String(transparent) + "-" + String(contrast),
                        LensNavigationMaterialPolicy.usesGlass(available: true, preference: preference, reduceTransparency: transparent, increasedContrast: contrast) == (preference != "opaque" && !transparent && !contrast))
                }
            }
        }
        check("glass-policy-keeps-macOS14-fallback", !LensNavigationMaterialPolicy.usesGlass(available: false, preference: "system", reduceTransparency: false, increasedContrast: false))
        let oldMaterial = UserDefaults.standard.object(forKey: "lensTabMaterial")
        defer {
            if let oldMaterial { UserDefaults.standard.set(oldMaterial, forKey: "lensTabMaterial") }
            else { UserDefaults.standard.removeObject(forKey: "lensTabMaterial") }
        }
        UserDefaults.standard.set("system", forKey: "lensTabMaterial")
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 720, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        for scheme in [ColorScheme.light, .dark] {
            for variant in ["glass", "opaque"] {
                let name = "glass-v54-" + (scheme == .light ? "light" : "dark") + "-" + variant
                // The SDK exposes accessibility preferences as read-only
                // environment values. Render the same opaque branch via the
                // existing user setting; policy checks above cover the system
                // inputs separately, without pretending to change macOS.
                UserDefaults.standard.set(variant == "opaque" ? "opaque" : "system", forKey: "lensTabMaterial")
                let root = AnyView(GlassChromeFixtureV54().environment(\.colorScheme, scheme))
                let controller = NSHostingController(rootView: root)
                let host = controller.view
                host.frame = NSRect(x: 0, y: 0, width: 720, height: 170)
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                window.contentViewController = controller; window.orderBack(nil)
                controller.rootView = root
                let identifiers = ["glass-fixture-primary", "glass-fixture-secondary", "glass-fixture-disabled", "glass-fixture-menu", "glass-fixture-tab-selected", "glass-fixture-tab-passive"]
                let controlsPresent = try await waitForLayout(host) { Set(identifiers).isSubset(of: Set(accessibilityIdentifiers(host))) }
                check(name + "-retains-native-accessible-controls", controlsPresent)
                renders.append(try capture(host, path: output.appendingPathComponent(name + ".png")))
            }
        }
    }

    private struct LegacyWindowTabs: Codable { let tabs: [LensTab]; let activeTab: UUID? }
    private static func argument(_ name: String) throws -> URL {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { throw LensError.unavailable("Missing " + name) }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw LensError.unavailable("Missing " + name) }; return value
    }
    @MainActor private static func destinations(_ store: LensStore) -> [UUID: Destination] {
        Dictionary(store.tabs.map { ($0.id, $0.destination) }, uniquingKeysWith: { first, _ in first })
    }
    @MainActor private static func closeAllTabs(_ store: LensStore) {
        for id in store.tabs.map(\.id) { store.closeTab(id) }
    }
    @MainActor private static func persistedContentMode(_ store: LensStore) -> Bool? {
        guard let rootID = store.snapshot?.root.id,
              let saved = UserDefaults.standard.dictionary(forKey: "lensTabsByRoot") as? [String: Data],
              let data = saved[store.windowIdentity + "|" + rootID],
              let tabs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return tabs["tabContentVisible"] as? Bool
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private static func contentTextViews(_ context: LensWindowContext) -> [NSTextView] {
        guard let pane = context.paneKeyboard.view(for: .content) else { return [] }
        return descendants(pane).compactMap { $0 as? NSTextView }.filter { !$0.isFieldEditor && !$0.isHiddenOrHasHiddenAncestor && $0.isSelectable }
    }
    @MainActor private static func accessibilityIdentifiers(_ host: NSView) -> [String] {
        var identifiers: Set<String> = [], seen: Set<ObjectIdentifier> = []
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, seen.count < 20_000, let element = object as? NSAccessibilityProtocol else { return }
            guard seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            if let id = element.accessibilityIdentifier(), !id.isEmpty { identifiers.insert(id) }
            for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        for view in descendants(host) {
            if let id = view.identifier?.rawValue, !id.isEmpty { identifiers.insert(id) }
            walk(view, depth: 0)
        }
        return identifiers.sorted()
    }
    @MainActor private static func waitForLayout(_ view: NSView, until ready: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            await Task.yield(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.window?.displayIfNeeded(); CATransaction.flush()
            if ready() { return true }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        return ready()
    }
    @MainActor private static func capture(_ view: NSView, path: URL) throws -> [String: Any] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: path)
        return ["filename": path.lastPathComponent, "bytes": png.count, "sha256": digest(png), "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
            "method": "Actual product MainView in NSHostingView bitmap cache; not a production compositor screenshot"]
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class ActionsFixture {
    let home: URL, rootID: String, patchCallID: String
    private var hashes: [URL: String] = [:]
    init(corpus: URL) throws {
        let fm = FileManager.default, root = corpus.resolvingSymlinksInPath().path
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().path + "/"
        guard root.hasPrefix(temporaryRoot), fm.fileExists(atPath: corpus.appendingPathComponent("ANONYMOUS_FIXTURE").path),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("corpus-manifest.json"))) as? [String: Any],
              manifest["anonymous"] as? Bool == true, let rootID = manifest["rootID"] as? String, let home = manifest["home"] as? String,
              let cases = manifest["originCases"] as? [String: Any], let patch = cases["mainPatchCallID"] as? String,
              let rollouts = manifest["rollouts"] as? [String: [String: Any]], let worktrees = manifest["worktrees"] as? [String: String] else { throw LensError.unavailable("Anonymous origin corpus manifest is unavailable.") }
        self.rootID = rootID; self.patchCallID = patch; self.home = URL(fileURLWithPath: home)
        guard self.home.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
        for entry in rollouts.values {
            guard let path = entry["path"] as? String else { throw CocoaError(.fileReadUnknown) }
            let url = URL(fileURLWithPath: path)
            guard url.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            hashes[url] = Self.digest(try Data(contentsOf: url))
        }
        for tree in worktrees.values {
            let directory = URL(fileURLWithPath: tree)
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
            for relative in ["src/Same.swift", "src/Origin.swift"] {
                let url = directory.appendingPathComponent(relative)
                if fm.fileExists(atPath: url.path) { hashes[url] = Self.digest(try Data(contentsOf: url)) }
            }
        }
    }
    func sourcesUnchanged() -> Bool {
        hashes.allSatisfy { url, expected in (try? Data(contentsOf: url)).map { Self.digest($0) == expected } ?? false }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Exercises native selectors and accessibility actions without opening a popup
/// or touching the observed files, clipboard, or investigation connection.
@MainActor func runContextMenuChecksV44(store: LensStore, window: NSWindow, check: (String, Bool, String) -> Void) async {
    let epoch = Date(timeIntervalSince1970: 1_790_784_000)
    let events = [
        LensEvent(id: "v44-menu-selected", timestamp: epoch.addingTimeInterval(10), agentID: "v44-menu-agent", kind: .toolCall,
                  title: "Selected recorded call", source: SourceRef(path: "anonymous-v44.jsonl", offset: 0, line: 1)),
        LensEvent(id: "v44-menu-clicked", timestamp: epoch.addingTimeInterval(40), agentID: "v44-menu-agent", kind: .assistant,
                  title: "Clicked recorded message", source: SourceRef(path: "anonymous-v44.jsonl", offset: 100, line: 2))
    ]
    let agents = [AgentRecord(id: "v44-menu-agent", name: "Anonymous menu agent")]
    do {
        let projection = try await Task.detached { try TimelineProjection.prepare(events: events, agents: agents) }.value
        let geometry = try TimelineGeometry(window: TimelineWindow(start: epoch, end: epoch.addingTimeInterval(60)), contentWidth: 900, minimumTimeSpan: 0.001)
        let canvas = TimelineCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 220))
        canvas.projection = projection; canvas.geometry = geometry; canvas.selectedID = events[0].id
        canvas.eventLookup = { id in events.first { $0.id == id } }
        window.contentView = canvas; window.setContentSize(canvas.frame.size)
        defer { window.contentView = nil }
        canvas.layoutSubtreeIfNeeded()
        var openedID: String?, investigatedID: String?, selectedID: String?
        var investigationAllowed = true
        canvas.onOpenTab = { openedID = $0 }
        canvas.onInvestigate = { investigatedID = $0 }
        canvas.canInvestigate = { investigationAllowed && $0 == events[1].id }
        canvas.onSelect = { selectedID = $0 }
        func dispatch(_ item: NSMenuItem?) -> Bool {
            guard let item, let action = item.action, let target = item.target else { return false }
            return NSApp.sendAction(action, to: target, from: item)
        }
        func rightMenu() -> NSMenu? {
            guard let item = projection.item(id: events[1].id) else { return nil }
            let rect = geometry.rect(for: item)
            let point = canvas.convert(NSPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return nil }
            let menu = canvas.menu(for: event)
            menu?.update()
            return menu
        }
        let menu = rightMenu()
        let tab = menu?.items.first { $0.title == LensL10n.text("Ouvrir dans un onglet") }
        check("context-menu-native-tab-target", tab?.target === canvas && (tab?.representedObject as? String) == events[1].id,
              "The native item carries the clicked event while another event remains selected.")
        let opened = dispatch(tab)
        check("context-menu-tab-dispatches-clicked-event", opened && openedID == events[1].id && canvas.selectedID == events[0].id,
              "NSApp.sendAction invokes the actual selector; the target does not come from the selection.")
        let investigate = menu?.items.first { $0.title == LensL10n.text("Préparer une question contextualisée") }
        let prepared = dispatch(investigate)
        check("context-menu-investigation-dispatches-clicked-event", investigate?.isEnabled == true && prepared && investigatedID == events[1].id,
              "The enabled native action invokes its callback for the clicked event.")
        investigatedID = nil; investigationAllowed = false
        let staleDispatched = dispatch(investigate)
        check("context-menu-stale-investigation-is-guarded", staleDispatched && investigatedID == nil,
              "An item opened before the state changed cannot bypass the selector's availability guard.")
        let blocked = rightMenu()?.items.first { $0.title == LensL10n.text("Préparer une question contextualisée") }
        check("context-menu-blocked-investigation-stays-disabled-after-update", blocked != nil && blocked?.isEnabled == false,
              "AppKit menu.update does not re-enable an unavailable investigation action.")

        let details = canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        check("context-menu-detail-ax-buttons-enabled", details.count == 2 && details.allSatisfy { $0.accessibilityRole() == .button && $0.isAccessibilityEnabled() },
              "Both visible event buttons expose enabled native accessibility state.")
        let clickedAX = details.first { $0.accessibilityLabel()?.contains(events[1].title) == true }
        let pressed = clickedAX?.accessibilityPerformPress() == true
        check("context-menu-detail-ax-press-selects-target", pressed && selectedID == events[1].id,
              "The enabled accessibility button selects its own recorded event.")

        var zoomPermitted = false
        var zoomCommands: [LensZoomAction] = []
        canvas.canZoomCommand = { _ in zoomPermitted }
        canvas.onZoomCommand = { zoomCommands.append($0) }
        func invokeZoom(_ name: String) -> Bool {
            canvas.accessibilityCustomActions()?.first { $0.name == LensL10n.text(name) }?.handler?() ?? false
        }
        let upperResult = invokeZoom("Agrandir la chronologie")
        let lowerResult = invokeZoom("Réduire la chronologie")
        check("context-menu-ax-zoom-bounds-report-no-action", !upperResult && !lowerResult && zoomCommands.isEmpty,
              "Accessibility reports failure when the zoom guard refuses both directions.")
        zoomPermitted = true
        let increase = invokeZoom("Agrandir la chronologie")
        let decrease = invokeZoom("Réduire la chronologie")
        check("context-menu-ax-zoom-success-dispatches-once", increase && decrease && zoomCommands.count == 2,
              "Each permitted accessibility zoom action invokes its native callback once.")

        let denseEvents = (0..<24).map { index in
            LensEvent(id: "v44-menu-density-\(index)", timestamp: epoch.addingTimeInterval(30 + Double(index) / 1000), agentID: "v44-menu-agent", kind: .toolCall,
                      title: "Anonymous grouped call \(index)", source: SourceRef(path: "anonymous-v44-dense.jsonl", offset: UInt64(index), line: index + 1))
        }
        canvas.projection = try await Task.detached { try TimelineProjection.prepare(events: denseEvents, agents: agents) }.value
        canvas.selectedID = nil
        canvas.eventLookup = { id in denseEvents.first { $0.id == id } }
        var focusedRange: ClosedRange<Date>?
        canvas.onFocusRange = { focusedRange = $0 }
        let groups = canvas.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        let groupPressed = groups.first?.accessibilityPerformPress() == true
        check("context-menu-group-ax-buttons-enabled-and-functional", !groups.isEmpty && groups.count < denseEvents.count && groups.allSatisfy { $0.isAccessibilityEnabled() } && groupPressed && focusedRange != nil,
              "A bounded dense group is exposed as an enabled button and its press requests a focus range.")
    } catch {
        check("context-menu-native-fixture-created", false, error.localizedDescription)
    }

    // The event table's implementation is private; reach it through its actual
    // SwiftUI owner and inspect the native menu without changing store navigation.
    if !store.events.isEmpty {
        let tableEvents = store.events
        let host = NSHostingView(rootView: EventListView(events: tableEvents, title: "Anonymous recorded activity").environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        host.sizingOptions = []
        window.contentView = host; window.setContentSize(host.frame.size)
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            await Task.yield(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            if descendants(host).contains(where: { ($0 as? NSTableView).map { $0.numberOfRows > 0 } == true }) { break }
            try? await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        if let table = descendants(host).compactMap({ $0 as? NSTableView }).first, table.numberOfRows > 0 {
            let row = table.selectedRow == 0 && table.numberOfRows > 1 ? 1 : 0
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)
            let menu = event.flatMap { table.menu(for: $0) }
            menu?.update()
            let tab = menu?.items.first { $0.title == LensL10n.text("Ouvrir dans un onglet") }
            let payload = tab?.representedObject as? [String: String]
            let responds = tab.flatMap { item in item.action.map { (item.target as? NSObject)?.responds(to: $0) == true } } ?? false
            check("context-menu-table-clicked-row-has-dispatchable-tab-action", tableEvents.indices.contains(row) && payload?["id"] == tableEvents[row].id && payload?["command"] == "tab" && tab?.isEnabled == true && responds,
                  "The actual NSTableView menu carries the clicked row's ID and a live selector target, without retargeting to the selected row.")

            // Return must use the currently selected row, not NSTableView's
            // mouse-only clickedRow. Dispatch through the actual native owner.
            let previousDestination = store.selection
            if table.numberOfRows >= 2,
               let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
                   windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let firstClickedRow = table.clickedRow
                table.keyDown(with: returnKey)
                check("navigation-native-return-opens-selected-event-without-mouse-click",
                      firstClickedRow != 0 && store.selection == .event(tableEvents[0].id) &&
                      store.tabContentDestination == .event(tableEvents[0].id),
                      "Return reaches EventNativeTableView and its mounted production coordinator; clickedRow differs from the selected row.")

                table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                let secondClickedRow = table.clickedRow
                table.keyDown(with: returnKey)
                check("navigation-native-return-retargets-to-new-selection",
                      secondClickedRow != 1 && store.selection == .event(tableEvents[1].id) &&
                      store.tabContentDestination == .event(tableEvents[1].id),
                      "A second keyboard selection opens its own recorded event, rather than retaining the previous event or mouse target.")

                table.deselectAll(nil)
                let destinationWithoutSelection = store.selection, tabsWithoutSelection = store.tabs.map { $0.destination }
                table.keyDown(with: returnKey)
                check("navigation-native-return-with-no-row-does-not-open-or-replace-content",
                      store.selection == destinationWithoutSelection && store.tabs.map { $0.destination } == tabsWithoutSelection,
                      "Return without a selected native row leaves the current destination and reading tabs intact.")
            } else {
                check("navigation-native-return-fixture-has-two-rows-and-key-event", false,
                      "The anonymous native owner needs two recorded rows and a Return NSEvent for keyboard routing qualification.")
            }
            if let previousDestination { store.navigate(previousDestination, newTab: true, record: false) }
        } else {
            check("context-menu-table-materialized", false, "The bounded EventListView host did not create a native event table.")
        }
    } else {
        check("context-menu-table-fixture-has-events", false, "The supplied anonymous store has no filtered event.")
    }

    // The coordinator reads live availability, rather than capturing the state
    // when the view was mounted. No selector below prepares or sends a question.
    let linkedScroll = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 220))
    let linkedCanvas = TimelineCanvas(frame: linkedScroll.bounds)
    linkedScroll.documentView = linkedCanvas
    let coordinator = TimelineView.Coordinator()
    coordinator.attach(linkedScroll, store: store)
    defer { coordinator.detach() }
    let previousSending = store.investigation.sending, previousPreparing = store.investigation.preparing
    defer { store.investigation.sending = previousSending; store.investigation.preparing = previousPreparing }
    store.investigation.sending = false; store.investigation.preparing = false
    coordinator.configure(store: store)
    guard let eventID = store.snapshot?.events.first?.id else {
        check("context-menu-coordinator-fixture-has-event", false, "The supplied anonymous store has no recorded event.")
        return
    }
    check("context-menu-coordinator-checks-object-identity", linkedCanvas.canInvestigate?(eventID) == true && linkedCanvas.canInvestigate?("v44-absent-event") == false,
          "The mounted coordinator allows its recorded event and refuses a missing event.")
    store.investigation.sending = true
    check("context-menu-coordinator-observes-sending", linkedCanvas.canInvestigate?(eventID) == false,
          "Availability changes while sending without remounting the timeline.")
    store.investigation.sending = false; store.investigation.preparing = true
    check("context-menu-coordinator-observes-preparation", linkedCanvas.canInvestigate?(eventID) == false,
          "Availability changes while preparing without remounting the timeline.")
}

/// Observation callbacks may run on the mutation executor; test state is locked.
private final class LensObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return marked }
    func mark() { lock.lock(); defer { lock.unlock() }; marked = true }
}


/// Anonymous controls only; no model, file, account or session work in this fixture.
private struct GlassChromeFixtureV54: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LensNavigationEffectGroup {
                HStack(spacing: LensChromeMetrics.spacing) {
                    Button("Connexion et modèle…") {}.lensChromeButton(prominent: true).lensFilledControlAccent().accessibilityIdentifier("glass-fixture-primary")
                    Button("Pause") {}.lensChromeButton().accessibilityIdentifier("glass-fixture-secondary")
                    Button("Envoyer") {}.lensChromeButton(prominent: true).lensFilledControlAccent().disabled(true).accessibilityIdentifier("glass-fixture-disabled")
                    Menu { Button("Archives locales") {} } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).lensChromeMenu().accessibilityLabel("Actions du chat").accessibilityIdentifier("glass-fixture-menu")
                }
            }
            LensNavigationEffectGroup {
                HStack(spacing: LensChromeMetrics.spacing) {
                    Button("exec_command") {}.buttonStyle(.plain).padding(8).lensNavigationItem(selected: true).accessibilityAddTraits(.isSelected).accessibilityIdentifier("glass-fixture-tab-selected")
                    Button("Instructions.md") {}.buttonStyle(.plain).padding(8).lensNavigationItem(selected: false).accessibilityIdentifier("glass-fixture-tab-passive")
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(LensBrand.chrome).lensControlAccent(.lens)
    }
}
