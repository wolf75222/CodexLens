import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

struct LensUpdateDriverSnapshot {
    let canCheck: Bool
    let sessionInProgress: Bool
    let automaticChecks: Bool
    let lastChecked: Date?
}

/// The same native updater serves every button and window.
@MainActor protocol LensUpdateDriving: AnyObject {
    var snapshot: LensUpdateDriverSnapshot { get }
    func start() throws
    func check()
    func setAutomaticChecks(_ enabled: Bool)
    func observeChanges(_ receive: @escaping @MainActor () -> Void)
}

#if canImport(Sparkle)
@MainActor final class LensSparkleUpdateDriver: LensUpdateDriving {
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    init(delegate: SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    }
    var snapshot: LensUpdateDriverSnapshot {
        let updater = controller.updater
        return LensUpdateDriverSnapshot(canCheck: updater.canCheckForUpdates, sessionInProgress: updater.sessionInProgress,
            automaticChecks: updater.automaticallyChecksForUpdates, lastChecked: updater.lastUpdateCheckDate)
    }
    func start() throws { try controller.updater.start() }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func observeChanges(_ receive: @escaping @MainActor () -> Void) {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, _ in Task { @MainActor in receive() } },
            updater.observe(\.sessionInProgress, options: [.new]) { _, _ in Task { @MainActor in receive() } },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { _, _ in Task { @MainActor in receive() } }
        ]
    }
}
#endif
