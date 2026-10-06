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
        scroll.onLayout = { [weak coordinator] in coordinator?.applySelection() }
        coordinator.table = table; coordinator.scroll = scroll
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.configure(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll as? TrendValuesScrollView)?.onLayout = nil
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
        coordinator.table?.onReturn = nil; coordinator.table?.makeMenu = nil
        coordinator.parent = nil; coordinator.menuActions = []
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: TrendValuesNSTableView?
        weak var scroll: NSScrollView?
        var parent: SessionTrendValuesTable?
        var menuActions: [TrendValuesMenuAction] = []
        private var isUpdating = false
        private var selectedID: String?
        private var pendingSelection = false
        private var pendingReveal = false
        private var dataSignature: [String] = []
        private var metric: SessionTrendMetric?

        func configure(_ parent: SessionTrendValuesTable) {
            self.parent = parent
            guard let table else { return }
            isUpdating = true; defer { isUpdating = false }
            for (id, title) in [("period", "Période"), ("interval", "Par intervalle"), ("cumulative", "Cumul")] {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = LensL10n.text(title)
            }
            let signature = parent.buckets.map { "\($0.id):\($0.count(for: parent.metric)):\($0.cumulativeCount(for: parent.metric))" }
            if dataSignature != signature || metric != parent.metric {
                let origin = scroll?.contentView.bounds.origin
                dataSignature = signature; metric = parent.metric; table.reloadData()
                if let origin, let scroll { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
                pendingSelection = true
            }
            let id = parent.selectedDate.flatMap { date in parent.buckets.first { $0.start <= date && date < $0.end }?.id }
            if selectedID != id { selectedID = id; pendingSelection = true; pendingReveal = true }
            table.setAccessibilityLabel(LensL10n.text("Valeurs de la courbe"))
            applySelection()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent?.buckets.count ?? 0 }
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
            parent.selectedDate = parent.buckets.indices.contains(row) ? parent.buckets[row].start : nil
        }
        func applySelection() {
            guard pendingSelection, let table, let parent, let scroll,
                  scroll.contentSize.width > 1, scroll.contentSize.height > 1,
                  table.numberOfRows == parent.buckets.count else { return }
            let updating = isUpdating; isUpdating = true; defer { isUpdating = updating }
            if let id = selectedID, let row = parent.buckets.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if pendingReveal { table.scrollRowToVisible(row) }
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
