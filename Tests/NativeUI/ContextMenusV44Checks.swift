import AppKit
import SwiftUI
import LensCore

/// Exercises native selectors and accessibility actions without opening a popup
/// or touching the observed files, clipboard, or investigation connection.
@MainActor func runContextMenuChecksV44(store: LensStore, check: (String, Bool, String) -> Void) async {
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
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
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
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
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
