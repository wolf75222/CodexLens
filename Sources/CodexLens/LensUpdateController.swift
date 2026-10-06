import AppKit
import SwiftUI
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// One updater for the running app, shared by its menu and Settings.
/// Sparkle owns scheduling, signature verification, replacement and relaunch.
@MainActor @Observable final class LensUpdateController: NSObject {
    static let shared = LensUpdateController()
    private(set) var canCheck = false
    private(set) var sessionInProgress = false
    private(set) var automaticChecks = false
    private(set) var lastChecked: Date?
    private(set) var status = ""
    private(set) var unavailableReason: String?
    @ObservationIgnored private var started = false
    #if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    #endif

    func start() {
        guard !started else { return }
        started = true
        #if canImport(Sparkle)
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "fr.codexlens.inspector", bundle.bundleURL.pathExtension == "app",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? Int == 0,
              bundle.object(forInfoDictionaryKey: "SUShowReleaseNotes") as? Bool == false else {
            unavailableReason = "Les mises à jour sont disponibles dans l’application distribuée."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do { try controller.updater.start() }
        catch { unavailableReason = error.localizedDescription; return }
        refreshProperties()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshProperties() }
        }
        #else
        unavailableReason = "Les mises à jour sont disponibles dans l’application distribuée."
        #endif
    }

    func check() {
        start()
        guard canCheck, !LensApplicationCoordinator.shared.maintenanceInProgress else { return }
        status = "Recherche de mises à jour…"
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if canImport(Sparkle)
        controller?.updater.automaticallyChecksForUpdates = enabled
        refreshProperties()
        #endif
    }

    private func refreshProperties() {
        #if canImport(Sparkle)
        guard let updater = controller?.updater else { return }
        canCheck = updater.canCheckForUpdates
        sessionInProgress = updater.sessionInProgress
        automaticChecks = updater.automaticallyChecksForUpdates
        lastChecked = updater.lastUpdateCheckDate
        #endif
    }
}

#if canImport(Sparkle)
extension LensUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !LensApplicationCoordinator.shared.maintenanceInProgress else { throw CocoaError(.userCancelled) }
    }
    // Do not accept an old feed override from defaults or a log/selected source.
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://github.com/wolf75222/CodexLens/releases/latest/download/appcast.xml"
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = LensL10n.text("Version {0} disponible", item.displayVersionString)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        refreshProperties()
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { status = "Lens est à jour." }
            else if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.installationCanceledError.rawValue) { status = "Installation annulée." }
            else { status = error.localizedDescription }
        } else if status == "Recherche de mises à jour…" { status = "Vérification terminée." }
    }
}
#endif

struct LensUpdateSettingsView: View {
    @State private var updater = LensUpdateController.shared
    var body: some View {
        LabeledContent(LensL10n.text("Version installée")) {
            Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                .monospacedDigit().textSelection(.enabled)
        }
        Toggle(LensL10n.text("Rechercher automatiquement les mises à jour"), isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
            .disabled(updater.unavailableReason != nil)
        HStack {
            Button(LensL10n.text("Rechercher des mises à jour…")) { updater.check() }.disabled(!updater.canCheck)
                .accessibilityIdentifier("lens-check-updates")
            if !updater.status.isEmpty { Text(LensL10n.display(updater.status)).foregroundStyle(.secondary) }
        }
        if let reason = updater.unavailableReason { Text(LensL10n.display(reason)).font(.caption).foregroundStyle(.secondary) }
        else if let date = updater.lastChecked {
            Text(LensL10n.text("Dernière vérification : {0}", date.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
        }
        Text(LensL10n.text("Les mises à jour signées proviennent des releases GitHub de Codex Lens. Vous confirmez l’installation ; votre application est remplacée au même emplacement et vos données sont conservées."))
            .font(.caption).foregroundStyle(.secondary)
        .task { updater.start() }
    }
}
