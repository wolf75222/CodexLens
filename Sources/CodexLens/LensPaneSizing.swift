import AppKit
import SwiftUI

/// Give native split views sensible initial proportions, then let AppKit own
/// dragging. Widths and heights survive remounting in this window's context.
struct LensPaneSizing: NSViewRepresentable {
    let key: String
    let preferredWidth: CGFloat
    let context: LensWindowContext?
    var isVertical = true
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.key = key; view.preferredWidth = preferredWidth; view.context = self.context; view.isVertical = isVertical
        view.scheduleInstallation()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.dispose() }

    @MainActor final class Probe: NSView {
        var key = "", preferredWidth: CGFloat = 228
        var isVertical = true
        weak var context: LensWindowContext?
        private weak var split: NSSplitView?
        private weak var pane: NSView?
        private var observer: NSObjectProtocol?
        private var pending: Task<Void, Never>?
        private var installing = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleInstallation() }
        func scheduleInstallation() {
            guard split == nil, pending == nil, window != nil else { return }
            pending = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.pending = nil
                var child: NSView = self
                while let parent = child.superview {
                    if let split = parent as? NSSplitView, split.isVertical == self.isVertical,
                       let index = split.arrangedSubviews.firstIndex(where: { $0 === child }),
                       (self.isVertical ? split.bounds.width : split.bounds.height) > 0, split.arrangedSubviews.count > 1 {
                        self.split = split; self.pane = child
                        self.installing = true
                        let remembered = self.isVertical ? self.context?.paneWidths[self.key] : self.context?.paneHeights[self.key]
                        let wanted = remembered ?? self.preferredWidth
                        let extent = self.isVertical ? split.bounds.width : split.bounds.height
                        if index == 0 { split.setPosition(wanted, ofDividerAt: 0) }
                        else if index == split.arrangedSubviews.count - 1 {
                            split.setPosition(extent - wanted - split.dividerThickness, ofDividerAt: index - 1)
                        }
                        self.installing = false; self.rememberWidth()
                        self.observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.rememberWidth() }
                        }
                        return
                    }
                    child = parent
                }
            }
        }
        private func rememberWidth() {
            guard !installing, let pane else { return }
            let extent = isVertical ? pane.bounds.width : pane.bounds.height
            guard extent.isFinite, extent > 0 else { return }
            if isVertical { context?.paneWidths[key] = extent }
            else { context?.paneHeights[key] = extent }
        }
        func dispose() {
            pending?.cancel(); pending = nil; rememberWidth()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; split = nil; pane = nil
        }
    }
}
