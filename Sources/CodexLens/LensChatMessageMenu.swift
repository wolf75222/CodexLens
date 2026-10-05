import AppKit
import LensCore
import SwiftUI

/// Selectable SwiftUI text supplies its own native context menu. This transparent
/// surface owns secondary clicks only; selection, links, scroll and left clicks
/// still reach the text below. No event monitor, private API or file access.
struct LensChatMessageMenu: NSViewRepresentable {
    let document: ChatMarkdownDocument
    let showsSource: Bool
    let sources: [ChatContextSource]
    let onCopyMessage: (() -> Void)?
    let onCopyCode: (String) -> Void
    let onToggleSource: () -> Void
    let onOpenURL: (URL) -> Void

    func makeNSView(context: Context) -> LensChatMessageMenuHost { LensChatMessageMenuHost() }
    func updateNSView(_ view: LensChatMessageMenuHost, context: Context) {
        view.document = document; view.showsSource = showsSource; view.sources = sources
        view.onCopyMessage = onCopyMessage; view.onCopyCode = onCopyCode
        view.onToggleSource = onToggleSource; view.onOpenURL = onOpenURL
    }
}

final class LensChatMessageMenuHost: NSView {
    var document: ChatMarkdownDocument?
    var showsSource = false
    var sources: [ChatContextSource] = []
    var onCopyMessage: (() -> Void)?
    var onCopyCode: (String) -> Void = { _ in }
    var onToggleSource: () -> Void = {}
    var onOpenURL: (URL) -> Void = { _ in }

    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.isSecondaryClick(event), super.hitTest(point) != nil else { return nil }
        return self
    }
    static func isSecondaryClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
    override func rightMouseDown(with event: NSEvent) { NSMenu.popUpContextMenu(makeMenu(), with: event, for: self) }
    override func mouseDown(with event: NSEvent) {
        if Self.isSecondaryClick(event) { NSMenu.popUpContextMenu(makeMenu(), with: event, for: self) }
        else { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        if let copy = onCopyMessage { menu.addItem(command("Copier la réponse", id: "lens-chat-copy-message", action: copy)) }
        menu.addItem(command(showsSource ? "Afficher le Markdown" : "Afficher le texte brut",
            id: "lens-chat-markdown-source-toggle", action: onToggleSource))
        let codes = document?.blocks.filter { if case .code = $0.kind { return true }; return false } ?? []
        let copyCode = onCopyCode
        if codes.count == 1, let code = codes.first {
            menu.addItem(command("Copier le code", id: "lens-chat-copy-code", action: { copyCode(code.plainText) }))
        } else if !codes.isEmpty {
            let group = NSMenuItem(title: LensL10n.text("Copier un bloc de code"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(); submenu.autoenablesItems = false
            for (index, code) in codes.enumerated() {
                submenu.addItem(command(LensL10n.text("Bloc {0}", String(index + 1)), id: "lens-chat-copy-code-\(code.id)", action: { copyCode(code.plainText) }))
            }
            group.submenu = submenu; menu.addItem(group)
        }
        if !sources.isEmpty {
            let group = NSMenuItem(title: LensL10n.text("Ouvrir une source du message"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(); submenu.autoenablesItems = false
            let open = onOpenURL
            for source in sources {
                let item = command("[\(source.address.pieceID)] \(source.title)", id: "lens-chat-open-\(source.address.pieceID)", action: { open(source.address.url) })
                item.toolTip = [source.environment, source.version].compactMap { $0 }.joined(separator: "\n")
                submenu.addItem(item)
            }
            group.submenu = submenu; menu.addItem(group)
        }
        return menu
    }
    private func command(_ title: String, id: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: LensL10n.text(title), action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = self; item.identifier = NSUserInterfaceItemIdentifier(id)
        item.representedObject = LensChatMenuCommand(action: action)
        return item
    }
    @objc func invoke(_ item: NSMenuItem) { (item.representedObject as? LensChatMenuCommand)?.action() }
}

private final class LensChatMenuCommand: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
}
