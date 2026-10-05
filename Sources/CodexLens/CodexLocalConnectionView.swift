import SwiftUI
import AppKit
import LensCore

/// The settings window and investigation sheet use the same controls and wording.
struct CodexLocalConnectionView: View {
    @ObservedObject var investigator: InvestigationStore
    @Environment(\.locale) private var locale
    @AppStorage("LensGroupCodexInvestigations") private var groupInSidebar = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LensL10n.text("Codex App Server · processus local"), systemImage: "terminal").font(.subheadline.weight(.medium))
            Text(LensL10n.text("Codex gère votre connexion ChatGPT. Lens ne lit ni ne copie ses identifiants et ne déconnecte pas la CLI.")).font(.caption).foregroundStyle(.secondary)
            Toggle(LensL10n.text("Regrouper les enquêtes dans Codex"), isOn: $groupInSidebar)
                .disabled(investigator.sending)
                .help(LensL10n.text("Classer les nouveaux chats dans « Codex Lens — Enquêtes » avant l’envoi."))
            Text(LensL10n.text("La section conserve les conversations et leurs relances. Vous pouvez la renommer ou déplacer un chat dans Codex ; Lens conserve ce choix.")).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack {
                    verifyButton
                    executableMenu
                }
                VStack(alignment: .leading, spacing: 6) { verifyButton; executableMenu }
            }
            if let selected = investigator.preferredCodexExecutable {
                Text(selected.path).font(LensUI.metadata).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if investigator.connecting {
                HStack {
                    LensProgressIndicator(LensL10n.text("Vérification de Codex…"))
                    Button(LensL10n.text("Annuler")) { investigator.cancelConnection() }
                }
            }
            if let status = investigator.codexStatus {
                LabeledContent(LensL10n.text("Version"), value: status.version)
                LabeledContent(LensL10n.text("Binaire utilisé")) {
                    Text(status.executable).font(LensUI.metadata).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(status.isChatGPT ? LensL10n.text("Connexion ChatGPT vérifiée") : LensL10n.text("Connexion ChatGPT indisponible"), systemImage: status.isChatGPT ? "checkmark.circle" : "exclamationmark.triangle")
                if let issue = status.catalogueIssue {
                    Text(LensL10n.text(issue)).font(LensUI.metadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let email = status.email { Text(email).textSelection(.enabled) }
                if let plan = status.plan { LabeledContent(LensL10n.text("Forfait"), value: plan) }
                if !status.isChatGPT {
                    Text(LensL10n.text("Connectez-vous à ChatGPT dans Codex, puis actualisez ici. Lens réutilise cette connexion sans gérer votre mot de passe."))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                    if let url = Self.applicationURL(executable: status.executable) {
                        Button(LensL10n.text("Ouvrir Codex")) { NSWorkspace.shared.open(url) }
                    } else {
                        Button(LensL10n.text("Copier la commande codex login")) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("codex login", forType: .string)
                        }.help(LensL10n.text("Copier uniquement ; aucune commande exécutée"))
                    }
                }
                if !status.models.isEmpty {
                    Picker(LensL10n.text("Modèle"), selection: $investigator.model) {
                        if !status.models.contains(where: { $0.id == investigator.model }) { Text(LensL10n.text("Choisir un modèle")).tag(investigator.model) }
                        ForEach(status.models) { model in Text(model.displayName).tag(model.id) }
                    }.disabled(investigator.sending)
                }
                Text(LensL10n.text("Le catalogue ne garantit pas l’accès au modèle. Seule une requête terminée confirme cet accès.")).font(.caption).foregroundStyle(.secondary)
                if let completedModel = investigator.completedModel { Label(LensL10n.text("Requête terminée avec {0}", completedModel), systemImage: "checkmark.circle") }
                if let limits = status.limits { LabeledContent(LensL10n.text("Limites · pourcentage restant")) { Text(limits).font(.caption).textSelection(.enabled) } }
                else { Text(LensL10n.text("Informations de limites indisponibles")).font(.caption).foregroundStyle(.secondary) }
            }
        }.id(locale.identifier)
    }
    private var verifyButton: some View {
        Button { investigator.useLocalCodex() } label: {
            Label(LensL10n.text(investigator.connecting ? "Vérification de Codex…" : investigator.codexStatus == nil ? "Vérifier Codex" : "Actualiser la connexion"), systemImage: "arrow.clockwise")
        }.disabled(investigator.connecting || investigator.sending)
    }
    private var executableMenu: some View {
        Menu(LensL10n.text("Binaire Codex")) {
            Button(LensL10n.text("Détecter automatiquement")) { investigator.chooseCodexExecutable(nil) }
            Button(LensL10n.text("Choisir le binaire installé…")) {
                let panel = NSOpenPanel()
                panel.title = LensL10n.text("Choisir le binaire Codex")
                panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true; panel.treatsFilePackagesAsDirectories = true
                panel.begin { result in
                    if result == .OK, let url = panel.url { investigator.chooseCodexExecutable(url) }
                }
            }
        }.disabled(investigator.connecting || investigator.sending)
    }
    static func applicationURL(executable: String) -> URL? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(executable[..<range.lowerBound]) + ".app")
    }
}
