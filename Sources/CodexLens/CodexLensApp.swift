import SwiftUI

@main struct CodexLensApp: App {
    @AppStorage("lens.language") private var language = "system"
    @NSApplicationDelegateAdaptor(LensApplicationDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Codex Lens", id: "session", for: UUID.self) { request in
            LensWindowRoot(requestID: request.wrappedValue).id(request.wrappedValue).environment(\.locale, Locale(identifier: language == "system" ? (Locale.preferredLanguages.first ?? "en") : language)).frame(minWidth: 900, minHeight: 600)
        } defaultValue: { UUID() }
        .defaultSize(width: 1480, height: 900).windowResizability(.contentMinSize).commands { LensCommands() }
        Window(LensL10n.text("Composants Lens — fixtures anonymisées"), id: "components") {
            ComponentGalleryView().frame(minWidth: 800, minHeight: 600)
        }.defaultSize(width: 1080, height: 820)
        Settings { LensSettingsView() }
            .defaultSize(width: 850, height: 720)
            .windowResizability(.contentMinSize)
    }
}

struct LensWindowRoot: View {
    @StateObject private var context: LensWindowContext
    @StateObject private var store: LensStore
    @SceneStorage("lensWindowIdentity") private var windowIdentity = UUID().uuidString
    @Environment(\.openWindow) private var openWindow
    init(requestID: UUID? = nil) { let store = LensStore(); _store = StateObject(wrappedValue: store); _context = StateObject(wrappedValue: LensWindowContext(store: store, sceneRequestID: requestID)) }
    var body: some View {
        MainView().environmentObject(store)
            .environment(\.lensWindowContext, context)
            .focusedSceneValue(\.lensWindowStore, store)
            .focusedSceneValue(\.lensWindowContext, context)
            .focusedSceneObject(store)
            .focusedSceneObject(context)
            .background(LensWindowProbe(context: context))
            .task {
                store.setNavigationScope(windowIdentity)
                if let window = context.window { context.attach(window) }
                let openWindowAction = openWindow
                LensApplicationCoordinator.shared.newWindowHandler = { requestID in openWindowAction(id: "session", value: requestID) }
                await store.start()
                LensApplicationCoordinator.shared.acceptPendingSession(in: context)
            }
            .onChange(of: store.snapshot?.root.id) { _, id in if id != nil, let root = store.snapshot?.root { LensApplicationCoordinator.shared.remember(root) } }
            .onOpenURL { url in Task { await store.handleURL(url) } }
    }
}
