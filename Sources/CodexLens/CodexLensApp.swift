import SwiftUI

@main struct CodexLensApp: App {
    @AppStorage("lens.language") private var language = "en"
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
