import SwiftUI
import LensCore

enum LensSettingsPage: String { case general, ai, help }

@MainActor final class LensGuideCoordinator: ObservableObject {
    static let shared = LensGuideCoordinator()
    let onboarding = LensOnboardingState()
    @Published var settingsPage = LensSettingsPage.general
    @Published var topic = LensGuideTopic.openSession
    @Published var replayPresented = false

    func showHelp(replay: Bool = false) {
        settingsPage = .help
        if replay { replayPresented = true }
    }
}

/// The first-run introduction stays separate from the five help articles.
enum LensOnboardingStep: Int, CaseIterable, Identifiable {
    case openSession
    case activity
    case investigation

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }
    var previous: Self? { Self(rawValue: rawValue - 1) }
    var next: Self? { Self(rawValue: rawValue + 1) }

    var title: String {
        switch self {
        case .openSession: "Votre session"
        case .activity: "La chronologie"
        case .investigation: "Le chat"
        }
    }

    var symbol: String {
        switch self {
        case .openSession: "rectangle.stack"
        case .activity: "waveform.path"
        case .investigation: "text.bubble"
        }
    }

    var introduction: String {
        switch self {
        case .openSession: "Choisissez une session Codex dans la liste ou collez son ID."
        case .activity: "Sélectionnez un événement pour retrouver son appel, ses fichiers et son contexte."
        case .investigation: "Posez vos questions dans le chat latéral, avec ou sans sélection."
        }
    }

    var detail: String {
        switch self {
        case .openSession: "Vous pouvez consulter son historique pendant qu’elle est active."
        case .activity: "Suspendez le suivi pour lire le passé ; la collecte continue."
        case .investigation: "Les réponses restent liées aux versions jointes."
        }
    }
}

struct LensGuideArticle {
    let title: String
    let symbol: String
    let introduction: String
    let steps: [String]
    let note: String
    let screenshot: String?
    let caption: String?

    static func article(for topic: LensGuideTopic) -> Self {
        switch topic {
        case .openSession:
            return Self(title: "Ouvrir une session", symbol: "rectangle.stack", introduction: "Consultez une session Codex, ses agents et ses environnements sans la reprendre.", steps: [
                "Choisissez Ouvrir une session… (⌘O), puis collez son ID ou sélectionnez-la dans la liste.",
                "Lens charge l’historique disponible et suit les nouveaux événements, y compris pour une session active.",
                "Le menu de la session → Sources et limites indique les données manquantes et les sous-agents inaccessibles."
            ], note: "Ouvrir une session ne lance aucun agent et ne modifie pas ses fichiers. Certains contenus peuvent être indisponibles.", screenshot: "opening", caption: "Sélection d’une session par son ID.")
        case .activity:
            return Self(title: "Suivre l’activité", symbol: "waveform.path", introduction: "La timeline, la liste et l’inspecteur suivent la même sélection.", steps: [
                "Un clic sélectionne ; double-cliquez ou appuyez sur Retour pour lire le contenu complet. Ouvrir la sélection fait la même chose.",
                "Vue et filtres regroupe les modes, types et compactages. Le menu de la chronologie permet de cadrer la sélection ou de choisir une période.",
                "Suspendez le suivi pour lire le passé. La collecte continue ; Revenir au présent affiche les nouveaux événements."
            ], note: "La barre latérale donne accès à l’activité, aux agents, aux appels et aux fichiers. Deux sessions dans le même dépôt restent distinctes.", screenshot: "activity", caption: "Un événement sélectionné dans la timeline et la liste.")
        case .proofs:
            return Self(title: "Consulter les sources", symbol: "point.3.connected.trianglepath.dotted", introduction: "Depuis un diff, retrouvez l’appel, l’agent et les instructions associés.", steps: [
                "Ouvrez un appel pour lire ses arguments, son résultat et l’événement brut. Il n’est pas réexécuté.",
                "Dans Modifications, vérifiez le worktree et les versions comparées. Le patch demandé, le résultat enregistré et le diff Git actuel sont présentés séparément.",
                "Dépliez Détails dans l’inspecteur pour retrouver l’origine et les instructions. Ressources, dans la barre latérale, distingue les fichiers fournis, référencés, lus, modifiés ou produits."
            ], note: "Une version passée s’ouvre si son contenu est enregistré ou peut être reconstruit. Si elle manque, le fichier actuel n’est pas affiché à sa place.", screenshot: "proofs", caption: "Diff, worktree et versions comparées.")
        case .investigation:
            return Self(title: "Poser une question", symbol: "text.bubble", introduction: "Le chat d’enquête utilise une conversation distincte de la session consultée.", steps: [
                "Ouvrez le chat avec ⌥⌘C. Demander à l’IA… ou Ajouter à la question y prépare la sélection sans l’envoyer.",
                "Codex installé est détecté et sa connexion est vérifiée à l’ouverture du chat. Réglages → IA indique le binaire utilisé et permet de le choisir.",
                "Écrivez un message. Retour envoie ; Majuscule-Retour ajoute une ligne. Répondez ensuite dans la même saisie pour continuer le chat.",
                "Le trombone permet de joindre la sélection et de préparer une question. Contexte envoyé et Sources citées ouvrent les versions conservées ; + les joint à une relance sans envoyer."
            ], note: "Envoyer transmet la question, le contexte sélectionné et les échanges à OpenAI. La connexion, l’accès au modèle et le résultat de la requête sont indiqués séparément.", screenshot: "investigation", caption: "Le contexte sélectionné reste visible avant l’envoi et conserve ses versions.")
        case .shortcuts:
            return Self(title: "Adapter votre espace", symbol: "keyboard", introduction: "Ajustez les fenêtres, les panneaux et la taille du texte.", steps: [
                "Faites glisser les séparateurs pour ajuster les panneaux. Présentation permet de masquer la navigation ou l’inspecteur et de passer en plein écran.",
                "⌥⌘1, ⌥⌘2, ⌥⌘3 et ⌥⌘4 placent le focus dans la navigation, le contenu, l’inspecteur et le chat. ⌥⌘C affiche ou masque le chat. ⌥⌘← et ⌥⌘→ ajustent le panneau actif. ⌘[ et ⌘] parcourent l’historique.",
                "⌘F recherche dans le texte actif ; ⇧⌘F recherche dans la session. ⌘+, ⌘− et ⌘0 ajustent la lecture ou la timeline. Réglages → Général permet de choisir la langue, la police, les pas du zoom et le pincement."
            ], note: "Retrouvez ce guide dans Aide. Revoir les premiers pas conserve votre session, vos filtres et votre brouillon.", screenshot: nil, caption: nil)
        }
    }
}
