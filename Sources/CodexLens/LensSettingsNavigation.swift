import AppKit
import SwiftUI

/// A native settings toolbar with owned borderless buttons. The system TabView
/// toolbar ignores app tint when macOS uses a fixed accent; contentTintColor is
/// supported for these buttons without modifying system preferences.
struct LensSettingsNavigation: NSViewControllerRepresentable {
    @Binding var selection: LensSettingsPage
    let accent: LensControlAccent
    let language: LensL10n.Language
    let content: AnyView
    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        updateNSViewController(controller, context: context)
        return controller
    }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(selection: selection, accent: accent, language: language,
                          content: content, environment: context.environment, onSelect: { selection = $0 })
    }
    @MainActor final class Controller: NSViewController, NSToolbarDelegate {
        private let toolbar = NSToolbar(identifier: NSToolbar.Identifier("LensSettings-" + UUID().uuidString))
        private var host: NSHostingView<Root>?
        private var buttons: [LensSettingsPage: NSButton] = [:]
        private var selected = LensSettingsPage.general
        private var accent = LensControlAccent.lens
        private var language = LensL10n.Language.en
        private var onSelect: ((LensSettingsPage) -> Void)?
        private weak var ownedWindow: NSWindow?
        private var previousToolbar: NSToolbar?
        private let pages: [LensSettingsPage] = [.general, .ai, .help]
        override func loadView() { view = NSView() }
        func update(selection: LensSettingsPage, accent: LensControlAccent, language: LensL10n.Language,
                    content: AnyView, environment: EnvironmentValues, onSelect: @escaping (LensSettingsPage) -> Void) {
            loadViewIfNeeded()
            selected = selection; self.accent = accent; self.language = language; self.onSelect = onSelect
            let root = Root(content: content, environment: environment)
            if let host { host.rootView = root }
            else {
                let host = NSHostingView(rootView: root); host.sizingOptions = []; host.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(host)
                NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    host.topAnchor.constraint(equalTo: view.topAnchor), host.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
                self.host = host
                toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
                toolbar.autosavesConfiguration = false
            }
            refreshButtons()
        }
        override func viewDidAppear() { super.viewDidAppear(); installToolbar() }
        private func installToolbar() {
            guard let window = view.window else { return }
            if ownedWindow !== window { previousToolbar = window.toolbar; ownedWindow = window }
            if window.toolbar !== toolbar { window.toolbar = toolbar }
            refreshButtons()
        }
        override func viewWillDisappear() {
            if let window = ownedWindow, window.toolbar === toolbar { window.toolbar = previousToolbar }
            super.viewWillDisappear()
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.flexibleSpace] + pages.map { .init($0.rawValue) } + [.flexibleSpace]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { pages.map { .init($0.rawValue) } }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard let page = LensSettingsPage(rawValue: identifier.rawValue) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            let button = NSButton(title: title(page), target: self, action: #selector(selectPage(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(page.rawValue)
            button.setButtonType(.momentaryPushIn); button.isBordered = false
            button.imagePosition = .imageAbove; button.font = .systemFont(ofSize: 12)
            button.image = NSImage(systemSymbolName: symbol(page), accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
            button.frame = NSRect(x: 0, y: 0, width: 76, height: 55)
            item.view = button; buttons[page] = button
            item.label = title(page); item.paletteLabel = title(page); item.toolTip = title(page)
            configure(button, page: page); return item
        }
        @objc private func selectPage(_ button: NSButton) {
            guard let id = button.identifier, let page = LensSettingsPage(rawValue: id.rawValue) else { return }
            selected = page; refreshButtons(); onSelect?(page)
        }
        private func title(_ page: LensSettingsPage) -> String {
            LensL10n.text(page == .general ? "Général" : page == .ai ? "IA" : "Aide", in: language)
        }
        private func symbol(_ page: LensSettingsPage) -> String { page == .general ? "gearshape" : page == .ai ? "text.bubble" : "questionmark.circle" }
        private func configure(_ button: NSButton, page: LensSettingsPage) {
            button.title = title(page); button.contentTintColor = page == selected ? accent.nsColor : .secondaryLabelColor
            button.setAccessibilityLabel(title(page)); button.setAccessibilityTitle(title(page)); button.setAccessibilityHelp(title(page))
            button.state = page == selected ? .on : .off
            button.setAccessibilityIdentifier("lens-settings-" + page.rawValue)
        }
        private func refreshButtons() {
            for (page, button) in buttons { configure(button, page: page) }
            for item in toolbar.items {
                if let page = LensSettingsPage(rawValue: item.itemIdentifier.rawValue) { item.label = title(page); item.paletteLabel = title(page); item.toolTip = title(page) }
            }
            toolbar.selectedItemIdentifier = .init(selected.rawValue)
            ownedWindow?.title = title(selected)
        }
    }
    struct Root: View {
        let content: AnyView
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment) }
    }
}
