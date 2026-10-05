import AppKit
import SwiftUI

/// A bounded native host for the two auxiliary surfaces. Its parent split view
/// owns the frame; nested editors/splits must not feed automatic minimum sizes
/// back into the WindowGroup during a change of surface.
struct LensAuxiliaryPane: NSViewRepresentable {
    let store: LensStore
    let windowContext: LensWindowContext?
    let isChat: Bool

    func makeNSView(context: Context) -> Container {
        Container(store: store, windowContext: windowContext)
    }
    func updateNSView(_ view: Container, context: Context) {
        view.showChat(isChat)
    }

    @MainActor final class Container: NSView {
        private let inspector: NSHostingView<LensAuxiliaryContent>
        private let chat: NSHostingView<LensAuxiliaryContent>
        private var chatShown: Bool?
        var visibleSurfaceIsChat: Bool { !chat.isHidden && inspector.isHidden }
        var visibleSurfaceIsInspector: Bool { chat.isHidden && !inspector.isHidden }

        init(store: LensStore, windowContext: LensWindowContext?) {
            inspector = NSHostingView(rootView: LensAuxiliaryContent(store: store, windowContext: windowContext, isChat: false))
            chat = NSHostingView(rootView: LensAuxiliaryContent(store: store, windowContext: windowContext, isChat: true))
            super.init(frame: .zero)
            for host in [inspector, chat] {
                // These are our own hosting views, not SwiftUI's private scene
                // hosts. All four edges are controlled by the native container.
                host.sizingOptions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: trailingAnchor),
                    host.topAnchor.constraint(equalTo: topAnchor),
                    host.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }
            showChat(store.chatVisible)
        }
        required init?(coder: NSCoder) { nil }

        func showChat(_ visible: Bool) {
            guard chatShown != visible else { return }
            let outgoing = visible ? inspector : chat
            if let responder = window?.firstResponder as? NSView,
               responder === outgoing || responder.isDescendant(of: outgoing) {
                window?.makeFirstResponder(nil)
            }
            inspector.isHidden = visible
            chat.isHidden = !visible
            chatShown = visible
        }
    }
}

/// Explicitly carry the app environment across the native hosting boundary.
/// The roots stay mounted while switching modes, retaining reading and draft
/// state. Store changes remain observed without reassigning rootView.
struct LensAuxiliaryContent: View {
    @ObservedObject var store: LensStore
    let windowContext: LensWindowContext?
    let isChat: Bool
    @AppStorage("lensAppearance") private var appearance = "system"
    @AppStorage("lensControlAccent") private var accent = "lens"
    @AppStorage("lens.language") private var language = "system"

    @ViewBuilder private var surface: some View {
        if isChat { InvestigationView(investigator: store.investigation) }
        else { InspectorView() }
    }
    var body: some View {
        surface
            .environmentObject(store)
            .environment(\.lensWindowContext, windowContext)
            .environment(\.lensReadingMagnify, store.readingMagnifier)
            .environment(\.locale, Locale(identifier: language == "system" ? (Locale.preferredLanguages.first ?? "en") : language))
            .lensControlAccent(LensControlAccent(rawValue: accent) ?? .lens)
            .font(LensUI.body)
            .symbolRenderingMode(.monochrome)
            .lensStableContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }
}
