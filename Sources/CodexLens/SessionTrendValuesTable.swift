import AppKit
import SwiftUI
import LensCore

/// Native bounded values table. Model selection is applied after layout and
/// revealed on a new chart selection, without moving an unchanged reading row.
struct SessionTrendValuesTable: NSViewRepresentable {
    let buckets: [SessionTrendBucket]
    let metric: SessionTrendMetric
    @Binding var selectedDate: Date?
    let periodLabel: (SessionTrendBucket) -> String
    let inspect: (SessionTrendBucket) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TrendValuesScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let table = TrendValuesNSTableView()
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 24
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityIdentifier("lens-trends-values")
        for (id, title, width) in [("period", "Période", 380.0), ("interval", "Par intervalle", 120.0), ("cumulative", "Cumul", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = LensL10n.text(title); column.width = width
            column.minWidth = id == "period" ? 160 : 80
            table.addTableColumn(column)
        }
        scroll.documentView = table
        let coordinator = context.coordinator
        table.delegate = coordinator; table.dataSource = coordinator
        table.target = coordinator; table.doubleAction = #selector(Coordinator.openSelection(_:))
        table.onReturn = { [weak coordinator] in coordinator?.openSelection(nil) }
        table.makeMenu = { [weak coordinator] row in coordinator?.menu(for: row) }
        table.onLayout = { [weak coordinator] in coordinator?.applySelection() }
        scroll.onLayout = { [weak coordinator] in coordinator?.applySelection() }
        coordinator.table = table; coordinator.scroll = scroll
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.configure(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll as? TrendValuesScrollView)?.onLayout = nil
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
        coordinator.table?.onReturn = nil; coordinator.table?.makeMenu = nil; coordinator.table?.onLayout = nil
        coordinator.parent = nil; coordinator.menuActions = []
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: TrendValuesNSTableView?
        weak var scroll: NSScrollView?
        var parent: SessionTrendValuesTable?
        var menuActions: [TrendValuesMenuAction] = []
        private var isUpdating = false
        private var applyingSelection = false
        private var selectedID: String?
        private var selectedDateValue: Date?
        private var pendingSelection = false
        private var pendingReveal = false
        private struct ViewportAnchor {
            let bucketID: String
            let date: Date
            let offset: CGFloat
            let horizontal: CGFloat
        }
        private var pendingViewport: ViewportAnchor?
        private var dataSignature: [String] = []
        private var metric: SessionTrendMetric?
        private var rowAccent: LensControlAccent?

        func configure(_ parent: SessionTrendValuesTable) {
            let previous = self.parent
            self.parent = parent
            guard let table else { return }
            isUpdating = true; defer { isUpdating = false }
            for (id, title) in [("period", "Période"), ("interval", "Par intervalle"), ("cumulative", "Cumul")] {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = LensL10n.text(title)
            }
            let signature = parent.buckets.map { "\($0.id):\($0.count(for: parent.metric)):\($0.cumulativeCount(for: parent.metric))" }
            if dataSignature != signature || metric != parent.metric {
                // A filter restoration can move the same bucket from row zero
                // to a later row. Preserve the visible bucket, not its old pixel
                // offset; leave a deliberately scrolled selection alone.
                if pendingViewport == nil, let previous, table.visibleRect.height > 1 {
                    let first = table.rows(in: table.visibleRect).location
                    if previous.buckets.indices.contains(first) {
                        pendingViewport = ViewportAnchor(bucketID: previous.buckets[first].id, date: previous.buckets[first].start,
                            offset: table.visibleRect.minY - table.rect(ofRow: first).minY,
                            horizontal: scroll?.contentView.bounds.minX ?? 0)
                    }
                }
                dataSignature = signature; metric = parent.metric; table.reloadData()
                pendingSelection = true
            }
            let id = parent.selectedDate.flatMap { date in parent.buckets.first { $0.start <= date && date < $0.end }?.id }
            let dateChanged = selectedDateValue != parent.selectedDate
            if selectedID != id || dateChanged { selectedID = id; pendingSelection = true }
            // Re-binning can change an ID while the person's selection is
            // unchanged. Only an explicit date change requests a new reveal.
            if dateChanged { pendingReveal = id != nil }
            selectedDateValue = parent.selectedDate
            let accent = LensControlAccent.current
            if rowAccent != accent {
                rowAccent = accent
                for row in 0..<table.numberOfRows {
                    (table.rowView(atRow: row, makeIfNecessary: false) as? LensTableSelectionRowView)?.accent = accent
                }
            }
            table.setAccessibilityLabel(LensL10n.text("Valeurs de la courbe"))
            applySelection()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent?.buckets.count ?? 0 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("lens-trends-row")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? LensTableSelectionRowView ?? LensTableSelectionRowView()
            view.identifier = id; view.accent = LensControlAccent.current
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, parent.buckets.indices.contains(row), let column = tableColumn else { return nil }
            let bucket = parent.buckets[row], id = column.identifier
            let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = id; field.lineBreakMode = .byTruncatingTail
            field.font = id.rawValue == "period" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = id.rawValue == "period" ? .left : .right
            let locale = Locale(identifier: LensL10n.resolvedLanguage.rawValue)
            switch id.rawValue {
            case "period": field.stringValue = parent.periodLabel(bucket)
            case "interval": field.stringValue = bucket.count(for: parent.metric).formatted(.number.locale(locale))
            default: field.stringValue = bucket.cumulativeCount(for: parent.metric).formatted(.number.locale(locale))
            }
            field.toolTip = field.stringValue
            return field
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table, let parent else { return }
            let row = table.selectedRow
            selectedID = parent.buckets.indices.contains(row) ? parent.buckets[row].id : nil
            selectedDateValue = parent.buckets.indices.contains(row) ? parent.buckets[row].start : nil
            parent.selectedDate = selectedDateValue
        }
        func applySelection() {
            guard !applyingSelection, pendingSelection, let table, let parent, let scroll,
                  scroll.contentSize.width > 1, scroll.contentSize.height > 1,
                  table.numberOfRows == parent.buckets.count else { return }
            if !parent.buckets.isEmpty {
                let last = table.rect(ofRow: parent.buckets.count - 1)
                guard last.height > 0, table.bounds.maxY >= last.maxY else { return }
            }
            applyingSelection = true; defer { applyingSelection = false }
            let updating = isUpdating; isUpdating = true; defer { isUpdating = updating }
            if let anchor = pendingViewport {
                if let row = parent.buckets.firstIndex(where: { $0.id == anchor.bucketID })
                    ?? parent.buckets.firstIndex(where: { $0.start <= anchor.date && anchor.date < $0.end }) {
                    let rowRect = table.rect(ofRow: row)
                    var target = scroll.contentView.bounds
                    target.origin = NSPoint(x: anchor.horizontal, y: max(0, rowRect.minY + anchor.offset))
                    let legal = scroll.contentView.constrainBoundsRect(target).origin
                    scroll.contentView.scroll(to: legal)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    guard abs(scroll.contentView.bounds.minY - legal.y) <= 1 else { return }
                }
                pendingViewport = nil
            }
            if let id = selectedID, let row = parent.buckets.firstIndex(where: { $0.id == id }) {
                // A remounted table can know its row count before its document
                // has its full height. Scrolling at that point clamps to zero.
                // Keep the reveal pending until the row can actually be reached.
                let rowRect = table.rect(ofRow: row)
                guard rowRect.height > 0, table.bounds.maxY >= rowRect.maxY else { return }
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if pendingReveal { table.scrollRowToVisible(row) }
                let visible = table.visibleRect
                if pendingReveal, visible.height >= rowRect.height,
                   visible.minY > rowRect.minY || visible.maxY < rowRect.maxY { return }
            } else { table.deselectAll(nil) }
            pendingSelection = false; pendingReveal = false
        }
        @objc func openSelection(_ sender: Any?) {
            guard let table, let parent, parent.buckets.indices.contains(table.selectedRow) else { return }
            parent.inspect(parent.buckets[table.selectedRow])
        }
        func menu(for row: Int) -> NSMenu? {
            guard let parent, parent.buckets.indices.contains(row) else { return nil }
            let bucket = parent.buckets[row]
            let action = TrendValuesMenuAction { parent.inspect(bucket) }
            menuActions = [action]
            let menu = NSMenu(), item = NSMenuItem(title: LensL10n.text("Voir l’activité"), action: #selector(TrendValuesMenuAction.perform(_:)), keyEquivalent: "")
            item.target = action; menu.addItem(item)
            return menu
        }
    }
}

@MainActor private final class TrendValuesScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}
@MainActor final class TrendValuesNSTableView: NSTableView {
    var onReturn: (() -> Void)?
    var makeMenu: ((Int) -> NSMenu?)?
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return makeMenu?(row) ?? super.menu(for: event)
    }
}
@MainActor final class TrendValuesMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform(_ sender: Any?) { action() }
}
