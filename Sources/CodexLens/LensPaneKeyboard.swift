import AppKit
import SwiftUI

enum LensPaneRegion: String, CaseIterable {
    case navigation, content, inspector, chat
    var title: String {
        switch self {
        case .navigation: return LensL10n.text("Navigation latérale")
        case .content: return LensL10n.text("Contenu principal")
        case .inspector: return LensL10n.text("Inspecteur")
        case .chat: return LensL10n.text("Chat d’enquête")
        }
    }
}

/// Window-local handles to existing native panes. No new focusable wrapper,
/// key-event interception or reconstruction of the session/content is needed.
@MainActor final class LensPaneKeyboardController {
    private final class Handle {
        weak var view: NSView?
        weak var split: NSSplitView?
        weak var responder: NSResponder?
        init(view: NSView, split: NSSplitView) { self.view = view; self.split = split }
    }
    private var handles: [LensPaneRegion: Handle] = [:]

    func register(_ region: LensPaneRegion, view: NSView, split: NSSplitView) {
        guard handles[region]?.view !== view else { return }
        handles[region] = Handle(view: view, split: split)
    }
    func unregister(_ region: LensPaneRegion, view: NSView?) {
        guard handles[region]?.view === view else { return }
        handles.removeValue(forKey: region)
    }
    func view(for region: LensPaneRegion) -> NSView? { handles[region]?.view }
    private func responderView(_ responder: NSResponder?) -> NSView? {
        if let text = responder as? NSTextView, text.isFieldEditor,
           let control = text.delegate as? NSView { return control }
        return responder as? NSView
    }
    func activeRegion(in window: NSWindow) -> LensPaneRegion? {
        guard let view = responderView(window.firstResponder) else { return nil }
        return LensPaneRegion.allCases.first { region in
            guard let pane = handles[region]?.view else { return false }
            return view === pane || view.isDescendant(of: pane)
        }
    }
    func isAvailable(_ region: LensPaneRegion, in window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil, let pane = handles[region]?.view else { return false }
        return pane.window === window && !pane.isHiddenOrHasHiddenAncestor
    }
    @discardableResult func focus(_ region: LensPaneRegion, in window: NSWindow?) -> Bool {
        guard isAvailable(region, in: window), let window, let handle = handles[region], let pane = handle.view else { return false }
        if let current = activeRegion(in: window) { handles[current]?.responder = window.firstResponder }
        if let remembered = handle.responder, let view = responderView(remembered),
           view.window === window, !view.isHiddenOrHasHiddenAncestor,
           (view === pane || view.isDescendant(of: pane)), window.makeFirstResponder(remembered) { return true }
        // Prefer the native table/editor over a filter or incidental button.
        // The native control owns arrows, selection, text editing and Tab.
        var candidates: [NSView] = [], queue = [pane], index = 0
        while index < queue.count {
            let view = queue[index]; index += 1
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            if view.acceptsFirstResponder { candidates.append(view) }
            queue.append(contentsOf: view.subviews)
        }
        func priority(_ view: NSView) -> Int {
            if view is NSTableView { return 0 }
            if let text = view as? NSTextView, !text.isFieldEditor { return 1 }
            if view is NSControl { return 2 }
            return 3
        }
        for view in candidates.enumerated().sorted(by: {
            let a = priority($0.element), b = priority($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }).map(\.element) where window.makeFirstResponder(view) {
            handle.responder = view; return true
        }
        return false
    }
    @discardableResult func resizeActive(by delta: CGFloat, in window: NSWindow?) -> Bool {
        guard delta.isFinite, delta != 0, let window, window.attachedSheet == nil,
              let region = activeRegion(in: window), let handle = handles[region],
              let (pane, split) = resizingLocation(for: handle),
              let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }) else { return false }
        let trailing = index < split.arrangedSubviews.count - 1
        let divider = trailing ? index : index - 1
        let left = split.arrangedSubviews[divider]
        let position = left.frame.maxX + (trailing ? delta : -delta)
        split.setPosition(min(split.maxPossiblePositionOfDivider(at: divider),
                              max(split.minPossiblePositionOfDivider(at: divider), position)), ofDividerAt: divider)
        split.layoutSubtreeIfNeeded()
        return true
    }
    private func resizingLocation(for handle: Handle) -> (NSView, NSSplitView)? {
        guard let pane = handle.view, let split = handle.split else { return nil }
        if split.arrangedSubviews.count > 1 { return (pane, split) }
        // Without chat/inspector the inner workspace has one pane. Resize the
        // surrounding native navigation split instead of consuming a no-op.
        var child: NSView = split
        while let parent = child.superview {
            if let outer = parent as? NSSplitView, outer.isVertical,
               outer.arrangedSubviews.count > 1,
               outer.arrangedSubviews.contains(where: { $0 === child }) { return (child, outer) }
            child = parent
        }
        return nil
    }
}

/// Locate the main HSplitView's native arranged pane after layout. The probe
/// does not participate in hit testing or the responder/key-view loop.
struct LensPaneKeyboardAccess: NSViewRepresentable {
    let region: LensPaneRegion
    let context: LensWindowContext?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        if view.region != region { view.dispose() }
        view.region = region; view.owner = self.context; view.install()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.dispose() }
    @MainActor final class Probe: NSView {
        var region = LensPaneRegion.content
        weak var owner: LensWindowContext?
        private weak var pane: NSView?
        private var pending: Task<Void, Never>?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        private func location() -> (NSView, NSSplitView)? {
            var child: NSView = self
            while let parent = child.superview {
                if let split = parent as? NSSplitView, split.isVertical,
                   split.arrangedSubviews.contains(where: { $0 === child }) { return (child, split) }
                child = parent
            }
            return nil
        }
        func install() {
            guard window != nil, pending == nil else { return }
            if let (current, _) = location(), pane === current,
               owner?.paneKeyboard.view(for: region) === current { return }
            pending = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.pending = nil
                if let (child, split) = self.location() {
                    self.pane = child
                    self.owner?.paneKeyboard.register(self.region, view: child, split: split)
                    // Registration is an AppKit handle update, not SwiftUI state.
                    // Publishing here can invalidate the scene environment while
                    // its hosting view is being measured after a pane transition.
                }
            }
        }
        func dispose() {
            pending?.cancel(); pending = nil
            owner?.paneKeyboard.unregister(region, view: pane); pane = nil
        }
    }
}
