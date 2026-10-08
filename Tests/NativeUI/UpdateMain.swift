import AppKit
import CryptoKit
import Sparkle

/// An isolated app used by verify-updates.sh. Replies exercise Sparkle's public
/// user-driver API; they do not qualify physical input or the standard dialogs.
@MainActor private final class UpdateFixture: NSObject, NSApplicationDelegate, SPUUserDriver {
    private var updater: SPUUpdater?
    private var output: URL!
    private var scenario = ""

    private func event(_ name: String, _ extra: [String: Any] = [:]) {
        var value = extra
        value["event"] = name
        value["time"] = ISO8601DateFormatter().string(from: Date())
        value["pid"] = ProcessInfo.processInfo.processIdentifier
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let stream = try? FileHandle(forWritingTo: output.appendingPathComponent("events.jsonl")) else { return }
        _ = try? stream.seekToEnd()
        try? stream.write(contentsOf: bytes + Data([10]))
        try? stream.close()
    }

    private func finish(_ result: String) {
        event("finished", ["result": result])
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main
        guard let identifier = bundle.bundleIdentifier,
              identifier.hasPrefix("fr.codexlens.update-test."),
              identifier != "fr.codexlens.inspector",
              let receipt = bundle.object(forInfoDictionaryKey: "LensUpdateReceiptDirectory") as? String,
              let expectedPath = bundle.object(forInfoDictionaryKey: "LensUpdateApplicationPath") as? String,
              URL(fileURLWithPath: expectedPath).standardizedFileURL == bundle.bundleURL.standardizedFileURL else { exit(70) }
        output = URL(fileURLWithPath: receipt)
        scenario = bundle.object(forInfoDictionaryKey: "LensUpdateScenario") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        event("launched", ["bundle": bundle.bundleURL.path, "build": build, "identifier": identifier])

        if scenario == "install", build == "2" {
            let marker: [String: Any] = ["bundle": bundle.bundleURL.path, "build": build,
                                       "identifier": identifier, "pid": ProcessInfo.processInfo.processIdentifier]
            try? JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted])
                .write(to: output.appendingPathComponent("relaunched.json"))
            finish("relaunched-version-2")
            return
        }
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: nil)
        do {
            try updater!.start()
            event("updater-started")
            updater!.checkForUpdates()
        } catch {
            event("start-error", ["description": error.localizedDescription])
            finish("error")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.finish("timeout") }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        event("permission")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { event("checking") }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        event("update-found", ["version": appcastItem.versionString, "stage": state.stage.rawValue])
        if scenario == "cancel" {
            reply(.dismiss)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finish("cancelled") }
        } else {
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { event("release-notes-unexpected") }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { event("release-notes-error") }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        event("no-update", ["description": error.localizedDescription])
        acknowledgement()
        finish("no-update")
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let value = error as NSError
        event("update-error", ["domain": value.domain, "code": value.code,
                               "description": value.localizedDescription,
                               "underlying": String(describing: value.userInfo[NSUnderlyingErrorKey])])
        acknowledgement()
        finish("error")
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { event("download-started") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        event("download-length", ["bytes": expectedContentLength])
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { event("download-data", ["bytes": length]) }
    func showDownloadDidStartExtractingUpdate() { event("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) { event("extraction-progress", ["progress": progress]) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        event("ready-to-install")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        event("installing", ["applicationTerminated": applicationTerminated])
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        event("installed", ["relaunched": relaunched])
        acknowledgement()
    }
    func dismissUpdateInstallation() { event("dismissed") }
}

@main private struct UpdateMain {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--generate-fixture-key" {
            let key = Curve25519.Signing.PrivateKey()
            let folder = URL(fileURLWithPath: CommandLine.arguments[2])
            try key.rawRepresentation.base64EncodedData().write(to: folder.appendingPathComponent("private-key.txt"))
            try key.publicKey.rawRepresentation.base64EncodedData().write(to: folder.appendingPathComponent("public-key.txt"))
            return
        }
        let application = NSApplication.shared
        let delegate = UpdateFixture()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
