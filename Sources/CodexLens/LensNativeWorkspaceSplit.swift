import AppKit
import SwiftUI

struct LensNativeWorkspacePane {
    let id: String
    let minimum: CGFloat
    let maximum: CGFloat?
    let content: AnyView
}

/// Native split items have explicit thickness bounds. In particular, they do
/// not ask SwiftUI's private NavigationPane hosting roots for changing minima
/// during an inspector/chat transition.
struct LensNativeWorkspaceSplit: NSViewControllerRepresentable {
    let panes: [LensNativeWorkspacePane]
    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.update(panes, environment: context.environment)
        return controller
    }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(panes, environment: context.environment)
    }
    @MainActor final class Controller: NSSplitViewController {
        private var paneIDs: [String] = []
        private var hosts: [String: NSHostingView<PaneRoot>] = [:]
        private var items: [String: NSSplitViewItem] = [:]
        override func loadView() {
            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            splitView = split
            view = split
        }
        func update(_ panes: [LensNativeWorkspacePane], environment: EnvironmentValues) {
            loadViewIfNeeded()
            let ids = panes.map(\.id)
            for pane in panes {
                let root = PaneRoot(content: pane.content, environment: environment)
                if let host = hosts[pane.id] { host.rootView = root }
                else {
                    let host = NSHostingView(rootView: root)
                    host.sizingOptions = []
                    let child = NSViewController()
                    child.view = host
                    let item = NSSplitViewItem(viewController: child)
                    item.minimumThickness = pane.minimum
                    if let maximum = pane.maximum { item.maximumThickness = maximum }
                    // Keep side panes stable when the window grows, while
                    // allowing the native divider's drag constraint (490) to
                    // resize them. A .defaultHigh (750) holding constraint
                    // would win over both mouse dragging and setPosition.
                    item.holdingPriority = NSLayoutConstraint.Priority(
                        rawValue: pane.id == "content" ? 250 : (pane.id == "navigation" ? 252 : 251))
                    hosts[pane.id] = host; items[pane.id] = item
                }
                // Bounds change when the auxiliary pane opens or closes.
                // Existing hosts retain their state while adopting that layout.
                if let item = items[pane.id] {
                    if item.minimumThickness != pane.minimum { item.minimumThickness = pane.minimum }
                    if let maximum = pane.maximum, item.maximumThickness != maximum {
                        item.maximumThickness = maximum
                    }
                }
            }
            if paneIDs != ids {
                let desired = ids.compactMap { items[$0] }
                // Adding or closing an auxiliary pane must not detach the
                // centre: its version choice, scroll and tasks stay mounted.
                for item in splitViewItems where !desired.contains(where: { $0 === item }) {
                    removeSplitViewItem(item)
                }
                for (index, item) in desired.enumerated() {
                    if let current = splitViewItems.firstIndex(where: { $0 === item }) {
                        if current != index { removeSplitViewItem(item); insertSplitViewItem(item, at: index) }
                    } else { insertSplitViewItem(item, at: index) }
                }
                paneIDs = ids
                // This workspace has three fixed identities. Retain their
                // detached hosts for this window so reopening navigation/chat
                // preserves view state; there is no per-event view cache.
            }
        }
    }
    struct PaneRoot: View {
        let content: AnyView
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment) }
    }
}
