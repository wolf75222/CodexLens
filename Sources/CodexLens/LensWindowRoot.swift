import SwiftUI

struct LensWindowRoot: View {
    @StateObject private var context: LensWindowContext
    @StateObject private var store: LensStore
    @SceneStorage("lensWindowIdentity") private var windowIdentity = UUID().uuidString
    @Environment(\.openWindow) private var openWindow
    init(requestID: UUID? = nil) {
        let seed = LensApplicationCoordinator.shared.pendingWindowSeed(for: requestID)
        let store = LensStore(sourceHome: seed?.sourceHome,
                              investigationArchive: seed?.investigationArchive,
                              cacheDirectory: seed?.cacheDirectory, readerPool: seed?.readerPool ?? .shared)
        _store = StateObject(wrappedValue: store)
        _context = StateObject(wrappedValue: LensWindowContext(store: store, sceneRequestID: requestID))
    }
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
