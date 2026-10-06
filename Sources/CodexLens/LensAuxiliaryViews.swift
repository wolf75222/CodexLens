import SwiftUI
import AppKit

struct LensSettingsView: View {
    @StateObject private var investigationSettings = InvestigationStore()
    @ObservedObject private var reading = LensReadingPreferences.shared
    @ObservedObject private var guide = LensGuideCoordinator.shared
    @AppStorage("lensControlAccent") private var controlAccent = "lens"
    @AppStorage("lensAppearance") private var appearance = "dark"
    @AppStorage("lensAppIconAppearance") private var iconAppearance = LensAppIconController.defaultAppearance
    @AppStorage("lensTabMaterial") private var tabMaterial = "system"
    @AppStorage("lens.language") private var language = "en"
    @State private var uninstallPresented = false
    @State private var maintenancePrepared = false
    @State private var uninstallPreservedStorage: [URL] = []
    var body: some View {
        TabView(selection: $guide.settingsPage) {
            generalSettings.tabItem { Label(LensL10n.text("Général"), systemImage: "gearshape") }.tag(LensSettingsPage.general)
            Form {
                Section(LensL10n.text("IA")) {
                    CodexLocalConnectionView(investigator: investigationSettings)
                    if let issue = investigationSettings.issue { Text(LensL10n.display(issue)).font(.caption).foregroundStyle(LensAppearance.warningText).textSelection(.enabled) }
                }
                Section(LensL10n.text("Confidentialité")) {
                    Text(LensL10n.text("Envoyer transmet à OpenAI votre question, le contexte joint et les échanges précédents de ce chat. Les règles de conservation d’OpenAI s’appliquent."))
                    Text(LensL10n.text("Le chat est distinct des sessions observées. Le moteur n’a accès ni à leurs dépôts, ni aux outils, hooks ou connecteurs. Le passage à l’API dédiée reste manuel."))
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).padding(12)
                .task { await investigationSettings.refreshConnection() }
                .tabItem { Label(LensL10n.text("IA"), systemImage: "text.bubble") }.tag(LensSettingsPage.ai)
            LensGuideView().tabItem { Label(LensL10n.text("Aide"), systemImage: "questionmark.circle") }.tag(LensSettingsPage.help)
        }
        .frame(minWidth: 640, idealWidth: 850, maxWidth: .infinity, minHeight: 520, idealHeight: 720, maxHeight: .infinity)
        .lensControlAccent(LensControlAccent(rawValue: controlAccent) ?? .lens)
        .onChange(of: language) { _, value in LensL10n.language = LensL10n.Language(rawValue: value) ?? .system }
        .environment(\.locale, Locale(identifier: LensL10n.resolvedLanguage == .fr ? "fr" : "en"))
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .sheet(isPresented: $guide.replayPresented, onDismiss: { guide.onboarding.dismiss() }) {
            LensOnboardingView { guide.replayPresented = false }
        }
        .sheet(isPresented: $uninstallPresented) {
            LensUninstallView(prepareForUninstall: {
                guard !LensUpdateController.shared.sessionInProgress else {
                    throw NSError(domain: "LensUninstall", code: 2, userInfo: [NSLocalizedDescriptionKey: LensL10n.text("Fermez la fenêtre de mise à jour avant de désinstaller Lens.")])
                }
                maintenancePrepared = true
                await LensApplicationCoordinator.shared.beginMaintenance()
                await investigationSettings.flushAndStop()
                try await LensApplicationCoordinator.shared.prepareForUninstall()
                if investigationSettings.draftSaveState == .failed {
                    throw NSError(domain: "LensUninstall", code: 1, userInfo: [NSLocalizedDescriptionKey: investigationSettings.issue ?? LensL10n.text("Brouillon non sauvegardé")])
                }
            }, preservedStorageURLs: uninstallPreservedStorage, resumeAfterFailure: {
                maintenancePrepared = false
                await LensApplicationCoordinator.shared.resumeAfterFailedUninstall()
            })
        }
        .onDisappear { if !maintenancePrepared { Task { await investigationSettings.flushAndStop() } } }
    }
    private var generalSettings: some View {
        Form {
            Section(LensL10n.text("Mises à jour")) { LensUpdateSettingsView().id(language) }
            Section(LensL10n.text("Langue")) {
                Picker(LensL10n.text("Langue de l’interface"), selection: $language) {
                    Text(LensL10n.text("Système")).tag("system"); Text(LensL10n.text("Français")).tag("fr"); Text(LensL10n.text("English")).tag("en")
                }
                Text(LensL10n.text("La langue change immédiatement. Les conversations, le code et vos questions conservent leur langue d’origine.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(LensL10n.text("Lecture")) {
                Picker(LensL10n.text("Apparence"), selection: $appearance) { Text(LensL10n.text("Système")).tag("system"); Text(LensL10n.text("Clair")).tag("light"); Text(LensL10n.text("Sombre")).tag("dark") }
                Text(LensL10n.text("Système suit macOS. Clair et Sombre s’appliquent uniquement à Lens.")).font(LensUI.metadata).foregroundStyle(.secondary)
                Picker(LensL10n.text("Icône du Dock"), selection: $iconAppearance) {
                    Text(LensL10n.text("Suivre l’apparence de Lens")).tag("appearance")
                    Text(LensL10n.text("Claire")).tag("light")
                    Text(LensL10n.text("Sombre")).tag("dark")
                }
                Text(LensL10n.text("Le choix s’applique pendant que Lens est ouverte. L’icône du Finder reste sombre.")).font(LensUI.metadata).foregroundStyle(.secondary)
                Picker(LensL10n.text("Couleur des contrôles"), selection: $controlAccent) {
                    ForEach(LensControlAccent.allCases) { accent in Text(accent.title(in: LensL10n.Language(rawValue: language) ?? .system)).tag(accent.rawValue) }
                }.id("control-accent-" + language)
                Text(LensL10n.text("Les couleurs des événements et des diffs restent inchangées.")).font(LensUI.metadata).foregroundStyle(.secondary)
                Picker(LensL10n.text("Police du code et des sorties"), selection: Binding(get: { reading.configuration.codeFont }, set: { reading.setCodeFont($0) })) {
                    ForEach(LensCodeFont.allCases) { font in Text(font.title(in: LensL10n.Language(rawValue: language) ?? .system)).tag(font) }
                }.id("code-font-" + language)
                Text("let session = CodexLens()").font(reading.configuration.codeFont.font(size: reading.configuration.defaultSize)).textSelection(.enabled)
                Picker(LensL10n.text("Matériau des contrôles"), selection: $tabMaterial) {
                    Text(LensL10n.text("Automatique")).tag("system")
                    Text(LensL10n.text("Opaque")).tag("opaque")
                }
                Text(LensL10n.text("Liquid Glass sur macOS 26, selon vos réglages d’accessibilité. La barre d’outils suit macOS.")).font(LensUI.metadata).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { reading.configuration.defaultSize }, set: { reading.setDefaultSize($0) }), in: 10...24, step: 0.5) {
                    Text(LensL10n.text("Taille de lecture par défaut : {0} pt", reading.configuration.defaultSize.formatted()))
                }
                Text(LensL10n.text("Cette taille s’applique aux fenêtres ouvertes. Les ajustements au clavier sont mémorisés par fenêtre.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(LensL10n.text("Zoom et raccourcis")) {
                Picker(LensL10n.text("⌘+ et ⌘− ajustent"), selection: Binding(get: { reading.configuration.timelineShortcuts }, set: { reading.setTimelineShortcuts($0) })) {
                    Text(LensL10n.text("Le contenu actif")).tag(true)
                    Text(LensL10n.text("Toujours le texte")).tag(false)
                }
                Stepper(value: Binding(get: { reading.configuration.textStep }, set: { reading.setTextStep($0) }), in: 0.5...4, step: 0.5) {
                    Text(LensL10n.text("Pas de la taille du texte : {0} pt", reading.configuration.textStep.formatted()))
                }
                Stepper(value: Binding(get: { reading.configuration.timelineStep }, set: { reading.setTimelineStep($0) }), in: 0.05...1, step: 0.05) {
                    Text(LensL10n.text("Pas du zoom temporel : {0} %", (reading.configuration.timelineStep * 100).rounded().formatted()))
                }
                Toggle(LensL10n.text("Activer le pincement pour zoomer"), isOn: Binding(get: { reading.configuration.pinchEnabled }, set: { reading.setPinchEnabled($0) }))
                Text(LensL10n.text("Dans la timeline, les raccourcis ajustent la période ; ailleurs, la taille du texte. ⌘= agrandit aussi. ⌘0 réinitialise le zoom.")).font(.caption).foregroundStyle(.secondary)
                Button(LensL10n.text("Réinitialiser les réglages de lecture")) { reading.reset() }
            }
            Section(LensL10n.text("Données locales")) {
                Text(LensL10n.text("Les journaux Codex et les dépôts sont consultés en lecture seule. Les enquêtes sont enregistrées dans Application Support/CodexLens/Investigations. Au-delà de 32 Mio, les plus anciennes sauvegardes sont supprimées."))
                Text(LensL10n.text("Aucune synchronisation ni télémétrie.")).foregroundStyle(.secondary)
                Text(LensL10n.text("Codex gère la connexion et ses identifiants. Lens enregistre le contexte sélectionné, les échanges et l’ID du thread d’enquête. Les exports peuvent contenir des conversations et du code ; vous choisissez leur destination.")).foregroundStyle(.secondary)
            }
            Section(LensL10n.text("Maintenance")) {
                Button(LensL10n.text("Désinstaller Codex Lens…")) {
                    Task {
                        uninstallPreservedStorage = await LensApplicationCoordinator.shared.storageURLsForUninstall()
                        uninstallPresented = true
                    }
                }
                    .disabled(LensUpdateController.shared.sessionInProgress)
                    .accessibilityIdentifier("lens-uninstall-review")
            }
        }.formStyle(.grouped).padding(12)
    }
}

struct LensShortcutReferenceView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                Text(LensL10n.text("Codex Lens")).font(.title)
                Text(LensL10n.text("Version {0} · build {1}", String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? LensL10n.text("développement")), String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? LensL10n.text("développement")))).foregroundStyle(.secondary)
                Text(LensL10n.text("Raccourcis")).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    row(LensL10n.text("⌘N / ⌘O"), LensL10n.text("Ouvrir une fenêtre / ouvrir une session"))
                    row(LensL10n.text("⌘1…6 / ⌘7"), LensL10n.text("Vues d’inspection / ouvrir le chat latéral"))
                    row(LensL10n.text("⌥⌘C / ⌥⌘4"), LensL10n.text("Afficher ou masquer le chat / placer le focus dans le chat"))
                    row(LensL10n.text("⌥⌘1 / ⌥⌘2 / ⌥⌘3"), LensL10n.text("Placer le focus dans la navigation / le contenu / l’inspecteur"))
                    row(LensL10n.text("⌥⌘← / ⌥⌘→"), LensL10n.text("Réduire / élargir le panneau actif"))
                    row(LensL10n.text("⌘M / ⌘H"), LensL10n.text("Réduire la fenêtre / masquer Lens"))
                    row(LensL10n.text("⌘W"), LensL10n.text("Fermer l’onglet actif, puis la fenêtre si aucun onglet"))
                    row(LensL10n.text("⇧⌘W / ⌥⌘W"), LensL10n.text("Fermer la fenêtre et ses onglets / toutes les fenêtres"))
                    row(LensL10n.text("⌃Tab / ⇧⌃Tab"), LensL10n.text("Onglet suivant / précédent dans cette fenêtre"))
                    row(LensL10n.text("⌘, / ⌘Q"), LensL10n.text("Ouvrir les réglages / quitter Lens"))
                    row(LensL10n.text("⌘F / ⌘G / ⇧⌘G"), LensL10n.text("Rechercher dans le texte actif / suivant / précédent"))
                    row(LensL10n.text("⇧⌘F"), LensL10n.text("Rechercher dans la session"))
                    row(LensL10n.text("⌘[ / ⌘]"), LensL10n.text("Historique précédent / suivant"))
                    row(LensL10n.text("⌃⌘S / ⌥⌘I"), LensL10n.text("Afficher ou masquer la navigation / l’inspecteur"))
                    row(LensL10n.text("⇧⌘L"), LensL10n.text("Suspendre le suivi visuel / revenir au présent"))
                    row(LensL10n.text("⇧⌘R"), LensL10n.text("Réinitialiser les filtres d’activité / effacer la recherche des agents"))
                    row(LensL10n.text("⇧⌘E / ⇧⌘D"), LensL10n.text("Préparer une question / ajouter ou retirer un signet"))
                    row(LensL10n.text("⇧⌘C"), LensL10n.text("Copier le lien interne"))
                    row(LensL10n.text("⌘+ / ⌘= / ⌘−"), LensL10n.text("Zoomer / dézoomer le contenu actif"))
                    row(LensL10n.text("⌘0"), LensL10n.text("Réinitialiser le zoom ou la taille de lecture"))
                    row(LensL10n.text("⌃⌘F"), LensL10n.text("Plein écran"))
                }
                Text(LensL10n.text("Fichiers et archives")).font(.headline)
                Text(LensL10n.text("Fichier → Exporter l’enquête… enregistre le contexte, la question et la réponse affichés au lancement de la commande. Importer une archive d’enquête… ouvre une archive Lens version 1 (.codexlens ou JSON) après vérification de son intégrité. L’import crée une enquête distincte sans reprendre la session. Les chemins référencés peuvent être indisponibles."))
                Text(LensL10n.text("Afficher l’emplacement actuel dans le Finder ouvre l’environnement sélectionné tel qu’il est aujourd’hui. Si le chemin manque, Lens le signale sans ouvrir un autre worktree."))
                Text(LensL10n.text("Fermer la dernière fenêtre arrête la collecte ; Lens reste accessible dans le Dock. Quitter ferme l’application. À la réouverture, Lens charge les événements enregistrés par Codex pendant son absence.")).foregroundStyle(.secondary)
        }.textSelection(.enabled).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ key: String, _ title: String) -> some View { GridRow { Text(key).font(.system(.body, design: .monospaced)); Text(title) } }
}
