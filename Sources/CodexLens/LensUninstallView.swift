import AppKit
import SwiftUI
import LensCore

/// The caller closes/flushes its settings chat and every application store.
/// No deletion is performed by opening or reviewing this sheet.
@MainActor struct LensUninstallView: View {
    let prepareForUninstall: @MainActor () async throws -> Void
    var preservedStorageURLs: [URL] = []
    var resumeAfterFailure: @MainActor () async -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var removeLocalData = false
    @State private var plan: LensUninstallPlan?
    @State private var issue: String?
    @State private var loading = true
    @State private var working = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LensL10n.text("Désinstaller Codex Lens")).font(.title2.weight(.semibold))
            Text(LensL10n.text("L’application sera déplacée dans la Corbeille. Vos données locales sont conservées par défaut."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(Bundle.main.bundleURL.path).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)

            if loading {
                LensProgressIndicator(LensL10n.text("Vérification des emplacements…"))
                    .frame(maxWidth: .infinity, minHeight: 70)
            }
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(LensL10n.text("Retirer aussi les données locales de Lens"), isOn: $removeLocalData)
                .disabled(loading || working)
            if let plan {
                DisclosureGroup(LensL10n.text("Emplacements des données locales")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LensL10n.text("Enquêtes, index de lecture et réglages de Lens. Les emplacements absents sont ignorés."))
                            .foregroundStyle(.secondary)
                        ForEach(plan.localDataURLs, id: \.path) { url in
                            Text(url.path).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if !plan.preservedLocalDataURLs.isEmpty {
                            Text(LensL10n.text("Ces emplacements contiennent des données personnalisées et seront conservés :"))
                                .foregroundStyle(.secondary)
                            ForEach(plan.preservedLocalDataURLs, id: \.path) { url in
                                Text(url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
            Text(LensL10n.text("Codex, sa connexion, les sessions, les dépôts, les exports et les emplacements personnalisés sont conservés."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 12) {
                if plan == nil && !loading {
                    Button(LensL10n.text("Afficher dans le Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
                if working { LensProgressIndicator(accessibilityLabel: LensL10n.text("Désinstallation en cours…")).controlSize(.small) }
                Spacer()
                Button(LensL10n.text("Annuler")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(LensL10n.text("Déplacer dans la Corbeille…"), role: .destructive) { confirming = true }
                    .disabled(plan == nil || loading || working)
            }
        }
        .padding(24).frame(width: 570)
        .interactiveDismissDisabled(working)
        .onExitCommand { if !working { dismiss() } }
        .task(id: removeLocalData) { await review() }
        .confirmationDialog(LensL10n.text("Désinstaller Codex Lens ?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(LensL10n.text("Déplacer dans la Corbeille"), role: .destructive) { Task { await uninstall() } }
            Button(LensL10n.text("Annuler"), role: .cancel) {}
        } message: {
            Text(LensL10n.text(removeLocalData
                ? "L’application et les données locales de Lens seront déplacées dans la Corbeille. Lens quittera ensuite."
                : "L’application sera déplacée dans la Corbeille. Les données locales seront conservées. Lens quittera ensuite."))
        }
    }

    private func review() async {
        loading = true; plan = nil; issue = nil
        guard !otherCopyIsRunning else {
            issue = LensL10n.text("Fermez les autres copies de Codex Lens avant de la désinstaller.")
            loading = false; return
        }
        let app = Bundle.main.bundleURL
        let executable = Bundle.main.executableURL
        let cleanup = removeLocalData
        let protected = protectedStorage
        let result = await Task.detached(priority: .utility) { () -> Result<LensUninstallPlan, LensUninstallPolicyError> in
            guard let executable else { return .failure(.unsupportedApplication) }
            do { return .success(try LensUninstallPolicy(preservedStorageURLs: protected).review(applicationURL: app, runningExecutableURL: executable, removeLocalData: cleanup)) }
            catch let error as LensUninstallPolicyError { return .failure(error) }
            catch { return .failure(.unsafePath(app.path)) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(reviewed): plan = reviewed
        case let .failure(error): issue = description(error)
        }
        loading = false
    }

    private func uninstall() async {
        guard let reviewed = plan, !working else { return }
        guard !otherCopyIsRunning else { issue = LensL10n.text("Fermez les autres copies de Codex Lens avant de la désinstaller."); return }
        working = true; issue = nil
        do { try await prepareForUninstall() }
        catch { await failAfterPreparation(LensL10n.text("Désinstallation interrompue : ") + error.localizedDescription); return }
        guard !otherCopyIsRunning else {
            await failAfterPreparation(LensL10n.text("Fermez les autres copies de Codex Lens avant de la désinstaller.")); return
        }
        let protected = protectedStorage
        let result = await Task.detached(priority: .utility) { () -> Result<LensUninstallPlan, LensUninstallPolicyError> in
            do { return .success(try LensUninstallPolicy(preservedStorageURLs: protected).validateForExecution(reviewed)) }
            catch let error as LensUninstallPolicyError { return .failure(error) }
            catch { return .failure(.unsafePath(reviewed.applicationURL.path)) }
        }.value
        let validated: LensUninstallPlan
        switch result {
        case let .success(current): validated = current
        case let .failure(error): await failAfterPreparation(description(error)); return
        }
        guard !otherCopyIsRunning else {
            await failAfterPreparation(LensL10n.text("Fermez les autres copies de Codex Lens avant de la désinstaller.")); return
        }
        // Permission failure on the app must never cause data to be removed.
        // Recycle only the running bundle first; data follows its success.
        let appResult = await recycle([validated.applicationURL])
        guard appResult.paths.contains(validated.applicationURL.path) else {
            await failAfterPreparation(failureDescription(appResult, expected: [validated.applicationURL])); return
        }
        let dataURLs = validated.urlsToRecycle.filter { $0.path != validated.applicationURL.path }
        let dataResult: Recycled
        if otherCopyIsRunning {
            // Another installed copy may share default data. Keep its storage
            // intact even if it was launched during the application move.
            dataResult = Recycled(paths: [], error: LensL10n.text("Fermez les autres copies de Codex Lens avant de la désinstaller."))
        } else if dataURLs.isEmpty { dataResult = Recycled(paths: [], error: nil) }
        else { dataResult = await recycle(dataURLs) }
        let errors = [appResult.error, dataResult.error].compactMap { $0 }
        let recycled = Recycled(paths: appResult.paths.union(dataResult.paths), error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
        let allRecycled = recycled.error == nil && validated.urlsToRecycle.allSatisfy { recycled.paths.contains($0.path) }
        if allRecycled && validated.resetPreferences && !otherCopyIsRunning {
            // Only this application's persistent domain; never Codex's auth or
            // any suite. The existing preferences file was recycled above.
            UserDefaults.standard.removePersistentDomain(forName: LensUninstallPolicy.bundleIdentifier)
        }
        let alert = NSAlert()
        alert.messageText = LensL10n.text("Codex Lens est dans la Corbeille.")
        alert.informativeText = allRecycled
            ? LensL10n.text(removeLocalData ? "Les données locales sélectionnées ont aussi été retirées. Vous pouvez restaurer les éléments depuis la Corbeille." : "Vos données locales sont conservées. Vous pouvez restaurer l’application depuis la Corbeille.")
            : failureDescription(recycled, expected: validated.urlsToRecycle)
        alert.alertStyle = allRecycled ? .informational : .warning
        alert.addButton(withTitle: LensL10n.text("Quitter"))
        alert.runModal()
        // The running app was successfully recycled; do not continue opening
        // windows or loading resources from a bundle that has moved.
        LensApplicationCoordinator.shared.finishUninstall()
        NSApp.terminate(nil)
    }

    private struct Recycled: Sendable { let paths: Set<String>; let error: String? }
    private func failAfterPreparation(_ message: String) async {
        issue = message
        await resumeAfterFailure()
        working = false
    }
    private var otherCopyIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: LensUninstallPolicy.bundleIdentifier)
            .contains { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
    private var protectedStorage: [URL] {
        preservedStorageURLs + ["LENS_ARCHIVE_DIRECTORY", "LENS_CACHE_DIRECTORY"].compactMap {
            ProcessInfo.processInfo.environment[$0].map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }
    private func recycle(_ urls: [URL]) async -> Recycled {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { mapping, error in
                continuation.resume(returning: Recycled(paths: Set(mapping.keys.map(\.path)), error: error?.localizedDescription))
            }
        }
    }
    private func description(_ error: LensUninstallPolicyError) -> String {
        LensL10n.text(error.messageKey) + (error.path.map { "\n" + $0 } ?? "")
    }
    private func failureDescription(_ result: Recycled, expected: [URL]) -> String {
        let retained = expected.filter { !result.paths.contains($0.path) }.map(\.path).joined(separator: "\n")
        return LensL10n.text("Certains éléments n’ont pas pu être déplacés. Les éléments déjà retirés restent récupérables dans la Corbeille.")
            + (retained.isEmpty ? "" : "\n" + retained)
            + (result.error.map { "\n" + $0 } ?? "")
    }
}
