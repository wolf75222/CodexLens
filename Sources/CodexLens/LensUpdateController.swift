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
    private(set) var availableVersion: String?
    private(set) var unavailableReason: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var driver: (any LensUpdateDriving)?

    init(driver: (any LensUpdateDriving)? = nil) { self.driver = driver; super.init() }
    var actionTitle: String { sessionInProgress ? "Afficher la mise à jour…" : "Mettre à jour l’app…" }

    func start() {
        guard !started else { return }
        started = true
        if driver == nil {
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
        driver = LensSparkleUpdateDriver(delegate: self)
        #else
        unavailableReason = "Les mises à jour sont disponibles dans l’application distribuée."
        return
        #endif
        }
        guard let driver else { return }
        do { try driver.start() }
        catch { unavailableReason = error.localizedDescription; return }
        refreshProperties()
        driver.observeChanges { [weak self] in self?.refreshProperties() }
    }

    func check() {
        start()
        guard unavailableReason == nil else { return }
        // KVO publication can lag behind a second click. Read Sparkle's actual
        // state before deciding whether to start or bring its window forward.
        refreshProperties()
        guard canCheck, !LensApplicationCoordinator.shared.maintenanceInProgress else { return }
        if !sessionInProgress {
            status = "Recherche de mises à jour…"
            availableVersion = nil
        }
        driver?.check()
        refreshProperties()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        driver?.setAutomaticChecks(enabled)
        refreshProperties()
    }

    private func refreshProperties() {
        guard let value = driver?.snapshot else { return }
        canCheck = value.canCheck
        sessionInProgress = value.sessionInProgress
        automaticChecks = value.automaticChecks
        lastChecked = value.lastChecked
    }

    func recordAvailableVersion(_ version: String) {
        availableVersion = version; status = ""; refreshProperties()
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
        recordAvailableVersion(item.displayVersionString)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        refreshProperties()
        if let error = error as NSError? {
            availableVersion = nil
            if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { status = "Lens est à jour." }
            else if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.installationCanceledError.rawValue) { status = "Installation annulée." }
            else { status = error.localizedDescription }
        } else if status == "Recherche de mises à jour…" { status = "Vérification terminée." }
    }
}
#endif

struct LensUpdateButton: View {
    @State private var updater: LensUpdateController
    @ObservedObject private var application = LensApplicationCoordinator.shared
    var iconOnly = false
    var identifier = "lens-update-app"
    init(updater: LensUpdateController = .shared, iconOnly: Bool = false, identifier: String = "lens-update-app") {
        _updater = State(initialValue: updater); self.iconOnly = iconOnly; self.identifier = identifier
    }
    var body: some View {
        Button { updater.check() } label: {
            if iconOnly {
                Label(LensL10n.text(updater.actionTitle), systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(LensL10n.text(updater.actionTitle), systemImage: symbol).labelStyle(.titleAndIcon)
            }
        }
        .disabled(!updater.canCheck || application.maintenanceInProgress)
        .help(updater.unavailableReason.map { LensL10n.display($0) } ?? LensL10n.text("Vérifier la dernière release GitHub et ouvrir la mise à jour native."))
        .accessibilityLabel(LensL10n.text(updater.actionTitle))
        .accessibilityIdentifier(identifier)
        .task { updater.start() }
    }
    private var symbol: String { updater.availableVersion == nil ? "arrow.down.circle" : "arrow.down.circle.fill" }
}

struct LensUpdateSettingsView: View {
    @State private var updater: LensUpdateController
    @AppStorage("lens.language") private var language = "en"
    init(updater: LensUpdateController = .shared) { _updater = State(initialValue: updater) }
    private func label(_ french: String, _ values: String...) -> String {
        var result = LensL10n.text(french, in: LensL10n.Language(rawValue: language) ?? .system)
        for (index, value) in values.enumerated() { result = result.replacingOccurrences(of: "{\(index)}", with: value) }
        return result
    }
    var body: some View {
        LabeledContent(label("Version installée")) {
            Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                .monospacedDigit().textSelection(.enabled)
        }
        Toggle(label("Rechercher automatiquement les mises à jour"), isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
            .disabled(updater.unavailableReason != nil)
        HStack {
            LensUpdateButton(updater: updater, identifier: "lens-check-updates").buttonStyle(.borderedProminent)
            if let version = updater.availableVersion { Text(label("Version {0} disponible", version)).foregroundStyle(.secondary) }
            else if !updater.status.isEmpty { Text(label(updater.status)).foregroundStyle(.secondary) }
        }
        if let reason = updater.unavailableReason { Text(label(reason)).font(.caption).foregroundStyle(.secondary) }
        else if let date = updater.lastChecked {
            Text(label("Dernière vérification : {0}", date.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
        }
        Text(label("Les mises à jour signées proviennent des releases GitHub de Codex Lens. Vous confirmez l’installation ; votre application est remplacée au même emplacement et vos données sont conservées."))
            .font(.caption).foregroundStyle(.secondary)
        .task { updater.start() }
    }
}
