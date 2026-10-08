import AppKit
import SwiftUI
import Observation
import LensCore

/// Owned by the window. Nothing in the tree is persisted in global defaults.
@MainActor @Observable final class ChangesFileTreeViewState {
    private(set) var expandedIDs: Set<String>
    private(set) var scrollOffset: CGPoint
    fileprivate var revealRevision: UInt64 = 0
    @ObservationIgnored fileprivate var knownRootIDs: Set<String> = []
    @ObservationIgnored fileprivate var lastSelectedFileID: String?
    @ObservationIgnored fileprivate var selectedItemID: String?
    @ObservationIgnored fileprivate var viewport: ChangesTreeViewport?
    @ObservationIgnored fileprivate var lastRevealRevision: UInt64 = 0
    @ObservationIgnored fileprivate var pendingReveal = false

    init(expandedIDs: Set<String> = [], scrollOffset: CGPoint = .zero) {
        self.expandedIDs = expandedIDs
        self.scrollOffset = scrollOffset
    }

    /// An explicit reveal, including when the selected file has not changed.
    func revealSelectedFile() { revealRevision &+= 1 }

    /// Navigation history freezes only navigation state, never the tree or its
    /// source records. Copy again on restore so a later gesture cannot edit it.
    func navigationCopy() -> ChangesFileTreeViewState {
        let copy = ChangesFileTreeViewState(expandedIDs: expandedIDs, scrollOffset: scrollOffset)
        copy.revealRevision = revealRevision; copy.knownRootIDs = knownRootIDs
        copy.lastSelectedFileID = lastSelectedFileID; copy.selectedItemID = selectedItemID
        copy.viewport = viewport; copy.lastRevealRevision = lastRevealRevision; copy.pendingReveal = pendingReveal
        return copy
    }

    fileprivate func save(_ snapshot: ChangesTreeSnapshot) {
        if expandedIDs != snapshot.expandedIDs { expandedIDs = snapshot.expandedIDs }
        if scrollOffset != snapshot.viewport.origin { scrollOffset = snapshot.viewport.origin }
        viewport = snapshot.viewport
        selectedItemID = snapshot.selectedItemID
        lastSelectedFileID = snapshot.selectedFileID
        lastRevealRevision = snapshot.revealRevision
        pendingReveal = snapshot.pendingReveal
        knownRootIDs = snapshot.knownRootIDs
    }
}

struct ChangesFileTreeView: View {
    @Environment(\.lensAccent) private var accent
    let tree: ChangesFileTree
    let selectedFileID: String?
    let state: ChangesFileTreeViewState
    let onSelectFile: @MainActor (String) -> Void
    let onOpenCurrentFile: @MainActor (String) -> Void

    var body: some View {
        NativeChangesFileTree(tree: tree, selectedFileID: selectedFileID, state: state,
                              revealRevision: state.revealRevision, accent: accent,
                              onSelectFile: onSelectFile, onOpenCurrentFile: onOpenCurrentFile)
            .accessibilityIdentifier("lens-changes-file-tree")
    }
}

private struct ChangesTreeViewport {
    var origin: CGPoint
    var itemID: String?
    var rowOffset: CGFloat = 0
}

private struct ChangesTreeSnapshot {
    var expandedIDs: Set<String>
    var viewport: ChangesTreeViewport
    var selectedItemID: String?
    var selectedFileID: String?
    var revealRevision: UInt64
    var pendingReveal: Bool
    var knownRootIDs: Set<String>
}

/// AppKit only creates views for visible rows; node boxes retain their identity
/// when live publication updates labels, counts, or the surrounding hierarchy.
private struct NativeChangesFileTree: NSViewRepresentable {
    let tree: ChangesFileTree
    let selectedFileID: String?
    let state: ChangesFileTreeViewState
    let revealRevision: UInt64
    let accent: LensControlAccent
    let onSelectFile: @MainActor (String) -> Void
    let onOpenCurrentFile: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChangesTreeScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let outline = ChangesTreeOutlineView()
        outline.headerView = nil
        outline.rowHeight = 26
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Native identity is independent of SwiftUI's inherited AX identifiers.
        outline.identifier = NSUserInterfaceItemIdentifier("lens-changes-file-tree-native")
        outline.setAccessibilityIdentifier("lens-changes-file-tree")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("changed-file"))
        column.minWidth = 100
        column.width = 260
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        scroll.documentView = outline
        let coordinator = context.coordinator
        outline.delegate = coordinator
        outline.dataSource = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.toggleFolder(_:))
        outline.makeMenu = { [weak coordinator] row in coordinator?.menu(for: row) }
        outline.onLayout = { [weak coordinator] in coordinator?.applyPendingPresentation() }
        scroll.onLayout = { [weak coordinator] in coordinator?.applyPendingPresentation() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.didScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        coordinator.outline = outline
        coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.configure(self) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.savePresentation()
        NotificationCenter.default.removeObserver(coordinator)
        (scroll as? ChangesTreeScrollView)?.onLayout = nil
        coordinator.outline?.onLayout = nil
        coordinator.outline?.makeMenu = nil
        coordinator.outline?.delegate = nil
        coordinator.outline?.dataSource = nil
        coordinator.outline?.target = nil
        coordinator.parent = nil
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: ChangesTreeOutlineView?
        weak var scroll: NSScrollView?
        var parent: NativeChangesFileTree?
        private var items: [String: ChangesTreeItem] = [:]
        private var rootIDs: [String] = []
        private var fileNodeIDs: [String: String] = [:]
        private var expandedIDs: Set<String> = []
        private var knownRootIDs: Set<String> = []
        private var selectedItemID: String?
        private var selectedFileID: String?
        private var revealRevision: UInt64 = 0
        private var pendingViewport: ChangesTreeViewport?
        private var pendingReveal = false
        private var pendingSelection = false
        private var suppressCallbacks = false
        private var applyingPresentation = false
        private var configuring = false
        private var persistenceTask: Task<Void, Never>?
        private var layoutTask: Task<Void, Never>?

        func configure(_ parent: NativeChangesFileTree) {
            guard let outline else { return }
            configuring = true
            defer { configuring = false }
            let firstPresentation = self.parent == nil || self.parent?.state !== parent.state
            if firstPresentation {
                expandedIDs = parent.state.expandedIDs
                knownRootIDs = parent.state.knownRootIDs
                selectedItemID = parent.state.selectedItemID
                selectedFileID = parent.state.lastSelectedFileID
                revealRevision = parent.state.lastRevealRevision
                pendingReveal = parent.state.pendingReveal
                pendingViewport = parent.state.viewport ?? ChangesTreeViewport(origin: parent.state.scrollOffset)
            }
            self.parent = parent
            let oldSuppression = suppressCallbacks
            suppressCallbacks = true
            defer { suppressCallbacks = oldSuppression }

            let newRootIDs = parent.tree.roots.map(\.id)
            // A root may arrive after an initially empty loading publication.
            // Expand it once, while preserving an existing root's user choice.
            expandedIDs.formUnion(Set(newRootIDs).subtracting(knownRootIDs))
            knownRootIDs.formUnion(newRootIDs)
            var dataChanged = firstPresentation || rootIDs != newRootIDs || items.count != parent.tree.nodesByID.count
            // Compare shallow presentation fields: recursive Node equality would
            // repeat subtree work for every ancestor on large recorded changes.
            for (id, node) in parent.tree.nodesByID {
                if items[id]?.presentation != ChangesTreeItem.Presentation(node) { dataChanged = true; break }
            }
            if dataChanged {
                if pendingViewport == nil { pendingViewport = captureViewport() }
                var nextItems: [String: ChangesTreeItem] = [:]
                var nextFileNodeIDs: [String: String] = [:]
                for (id, node) in parent.tree.nodesByID {
                    let item = items[id] ?? ChangesTreeItem(node)
                    item.presentation = ChangesTreeItem.Presentation(node)
                    nextItems[id] = item
                    if let fileID = node.fileID, node.kind == .file { nextFileNodeIDs[fileID] = id }
                }
                items = nextItems
                rootIDs = newRootIDs
                fileNodeIDs = nextFileNodeIDs
                outline.reloadData()
                if firstPresentation { outline.collapseItem(nil, collapseChildren: true) }
                restoreExpansion()
                pendingSelection = true
            }
            if selectedFileID != parent.selectedFileID {
                selectedFileID = parent.selectedFileID
                selectedItemID = selectedFileID.flatMap { fileNodeIDs[$0] }
                pendingSelection = true
                pendingReveal = selectedFileID != nil
            }
            if revealRevision != parent.revealRevision {
                revealRevision = parent.revealRevision
                pendingReveal = parent.selectedFileID != nil
                selectedItemID = parent.selectedFileID.flatMap { fileNodeIDs[$0] }
                pendingSelection = true
            }
            // Refresh only instantiated rows, including when the window accent
            // changes; offscreen rows pick up the accent in their delegate.
            let visible = outline.rows(in: outline.visibleRect)
            if visible.location != NSNotFound, visible.length > 0 {
                for row in visible.location..<min(outline.numberOfRows, visible.location + visible.length) {
                    (outline.rowView(atRow: row, makeIfNecessary: false) as? LensTableSelectionRowView)?.accent = parent.accent
                    if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ChangesTreeCellView,
                       let item = outline.item(atRow: row) as? ChangesTreeItem {
                        cell.configure(item.presentation, accent: parent.accent)
                    }
                }
            }
            outline.setAccessibilityIdentifier("lens-changes-file-tree")
            outline.setAccessibilityLabel(LensL10n.text("Arborescence des fichiers modifiés"))
            // Layout can be unavailable during updateNSView. All persistence is
            // deferred; AppKit callbacks fired by restoration stay suppressed.
            layoutTask?.cancel()
            layoutTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.applyPendingPresentation()
            }
        }

        private func restoreExpansion() {
            guard let outline else { return }
            // Walking expanded parents is bounded by the visible hierarchy,
            // without repeatedly expanding descendants or touching file content.
            func restore(_ ids: [String]) {
                for id in ids {
                    guard expandedIDs.contains(id), let item = items[id], !item.presentation.childIDs.isEmpty else { continue }
                    outline.expandItem(item)
                    restore(item.presentation.childIDs)
                }
            }
            restore(rootIDs)
        }

        func applyPendingPresentation() {
            guard !configuring, !applyingPresentation,
                  pendingSelection || pendingViewport != nil || pendingReveal,
                  let outline, let scroll, let parent,
                  scroll.contentSize.width > 1, scroll.contentSize.height > 1 else { return }
            applyingPresentation = true
            let oldSuppression = suppressCallbacks
            suppressCallbacks = true
            defer { suppressCallbacks = oldSuppression; applyingPresentation = false }
            if pendingReveal, let fileID = parent.selectedFileID, let id = fileNodeIDs[fileID], let item = items[id] {
                for ancestorID in parent.tree.ancestorsByFileID[fileID] ?? [] {
                    guard let ancestor = items[ancestorID] else { continue }
                    outline.expandItem(ancestor)
                    expandedIDs.insert(ancestorID)
                }
                selectedItemID = id
                let row = outline.row(forItem: item)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                    pendingReveal = false
                    pendingSelection = false
                    pendingViewport = nil
                }
            }
            if pendingSelection {
                let row = selectedItemID.flatMap { items[$0] }.map { outline.row(forItem: $0) } ?? -1
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                else { outline.deselectAll(nil) }
                pendingSelection = false
            }
            if let viewport = pendingViewport {
                var origin = viewport.origin
                if let id = viewport.itemID, let item = items[id] {
                    let row = outline.row(forItem: item)
                    if row >= 0 { origin.y = outline.rect(ofRow: row).minY + viewport.rowOffset }
                }
                let clip = scroll.contentView
                let proposed = NSRect(origin: origin, size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                scroll.reflectScrolledClipView(clip)
                pendingViewport = nil
            }
            savePresentation()
        }

        private func captureViewport() -> ChangesTreeViewport {
            guard let outline, let scroll else { return ChangesTreeViewport(origin: .zero) }
            let origin = scroll.contentView.bounds.origin
            let row = outline.row(at: NSPoint(x: 1, y: origin.y + 1))
            let item = row >= 0 ? outline.item(atRow: row) as? ChangesTreeItem : nil
            return ChangesTreeViewport(origin: origin, itemID: item?.presentation.id,
                                       rowOffset: row >= 0 ? origin.y - outline.rect(ofRow: row).minY : 0)
        }

        func savePresentation() {
            guard let parent else { return }
            let snapshot = ChangesTreeSnapshot(expandedIDs: expandedIDs,
                                               viewport: pendingViewport ?? captureViewport(),
                                               selectedItemID: selectedItemID, selectedFileID: selectedFileID,
                                               revealRevision: revealRevision, pendingReveal: pendingReveal,
                                               knownRootIDs: knownRootIDs)
            persistenceTask?.cancel()
            let state = parent.state
            persistenceTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                state.save(snapshot)
            }
        }

        @objc func didScroll(_ notification: Notification) {
            guard !suppressCallbacks, !applyingPresentation, !configuring else { return }
            // A deliberate scroll wins over any outstanding layout restoration.
            pendingViewport = nil
            savePresentation()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? ChangesTreeItem)?.presentation.childIDs.count ?? rootIDs.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let ids = (item as? ChangesTreeItem)?.presentation.childIDs ?? rootIDs
            return items[ids[index]]!
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? ChangesTreeItem else { return false }
            return !item.presentation.childIDs.isEmpty
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("lens-changes-tree-row")
            let row = outlineView.makeView(withIdentifier: id, owner: self) as? LensTableSelectionRowView ?? LensTableSelectionRowView()
            row.identifier = id
            row.accent = parent?.accent ?? .lens
            return row
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? ChangesTreeItem else { return nil }
            let id = NSUserInterfaceItemIdentifier("lens-changes-tree-cell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ChangesTreeCellView ?? ChangesTreeCellView()
            cell.identifier = id
            cell.configure(item.presentation, accent: parent?.accent ?? .lens)
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressCallbacks, let outline, let parent else { return }
            let item = outline.item(atRow: outline.selectedRow) as? ChangesTreeItem
            selectedItemID = item?.presentation.id
            if let item, item.presentation.kind == .file, let fileID = item.presentation.fileID {
                selectedFileID = fileID
                savePresentation()
                parent.onSelectFile(fileID)
            } else {
                // Native folder keyboard navigation never clears the diff.
                savePresentation()
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !suppressCallbacks, let item = notification.userInfo?["NSObject"] as? ChangesTreeItem else { return }
            expandedIDs.insert(item.presentation.id)
            savePresentation()
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !suppressCallbacks, let item = notification.userInfo?["NSObject"] as? ChangesTreeItem else { return }
            expandedIDs.remove(item.presentation.id)
            savePresentation()
        }
        @objc func toggleFolder(_ sender: NSOutlineView) {
            guard let item = sender.item(atRow: sender.clickedRow) as? ChangesTreeItem,
                  !item.presentation.childIDs.isEmpty else { return }
            if sender.isItemExpanded(item) { sender.collapseItem(item) }
            else { sender.expandItem(item) }
        }
        func menu(for row: Int) -> NSMenu? {
            guard let outline, row >= 0, let item = outline.item(atRow: row) as? ChangesTreeItem else { return nil }
            let node = item.presentation
            let menu = NSMenu()
            menu.autoenablesItems = false
            let copy = NSMenuItem(title: LensL10n.text("Copier le chemin enregistré"), action: #selector(copyRecordedPath(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = node.path
            copy.isEnabled = !node.path.isEmpty
            menu.addItem(copy)
            if node.kind == .file, let fileID = node.fileID {
                let open = NSMenuItem(title: LensL10n.text("Ouvrir le fichier actuel"), action: #selector(openCurrentFile(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = fileID
                menu.addItem(open)
            }
            return menu
        }
        @objc private func copyRecordedPath(_ item: NSMenuItem) {
            guard let path = item.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        @objc private func openCurrentFile(_ item: NSMenuItem) {
            guard let fileID = item.representedObject as? String else { return }
            parent?.onOpenCurrentFile(fileID)
        }
    }
}

private final class ChangesTreeItem: NSObject {
    struct Presentation: Equatable {
        let id: String
        let label: String
        let environmentID: String
        let fileID: String?
        let path: String
        let kind: ChangesFileTreeNode.Kind
        let fileCount: Int
        let childIDs: [String]
        init(_ node: ChangesFileTreeNode) {
            id = node.id; label = node.label; environmentID = node.environmentID
            fileID = node.fileID; path = node.path; kind = node.kind
            fileCount = node.fileCount; childIDs = node.children.map(\.id)
        }
    }
    var presentation: Presentation
    init(_ node: ChangesFileTreeNode) { presentation = Presentation(node) }
}

private final class ChangesTreeCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private let count = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField = label
        imageView = symbol
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbol.imageScaling = .scaleProportionallyDown
        symbol.setAccessibilityElement(false)
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let views: [NSView] = [symbol, label, count]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
            symbol.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ node: ChangesTreeItem.Presentation, accent: LensControlAccent) {
        label.stringValue = node.label
        label.textColor = .labelColor
        count.stringValue = node.kind == .file ? "" : String(node.fileCount)
        let name: String
        switch node.kind {
        case .worktree: name = "square.stack.3d.up"
        case .directory: name = "folder"
        case .file: name = "doc"
        case .outsidePaths: name = "folder.badge.questionmark"
        }
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbol.contentTintColor = node.kind == .worktree ? accent.nsColor : .secondaryLabelColor
        toolTip = "\(node.path)\n\(node.environmentID)"
        setAccessibilityLabel(node.label)
        setAccessibilityHelp(toolTip)
    }
}

private final class ChangesTreeOutlineView: NSOutlineView {
    var makeMenu: ((Int) -> NSMenu?)?
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return makeMenu?(row) ?? super.menu(for: event)
    }
}

private final class ChangesTreeScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}
