import SwiftUI
import LensCore

enum LensQuestionIntent {
    case explainChange, explainError, traceOrigin, compareInstruction, verifyJustification
    var title: String {
        switch self {
        case .explainChange: return LensL10n.text("Expliquer ce changement")
        case .explainError: return LensL10n.text("Expliquer cette erreur")
        case .traceOrigin: return LensL10n.text("Retrouver l’origine de cette modification")
        case .compareInstruction: return LensL10n.text("Comparer la consigne et l’exécution")
        case .verifyJustification: return LensL10n.text("Vérifier cette justification")
        }
    }
    var prompt: String {
        switch self {
        case .explainChange: return LensL10n.text("Explique cette modification : demande initiale, résultat de l’appel, agent, instructions, worktree et versions comparées. Cite les éléments utilisés et indique ce qui manque.")
        case .explainError: return LensL10n.text("Explique l’erreur à partir de l’appel et des messages associés. Cite tes sources, sépare les observations des hypothèses et indique ce qui manque.")
        case .traceOrigin: return LensL10n.text("Retrouve l’origine de cette modification parmi les traces sélectionnées. Distingue attribution confirmée, corrélation et changements manuels inconnus. Cite l’agent, ses instructions et les versions quand ils sont enregistrés.")
        case .compareInstruction: return LensL10n.text("Compare la consigne aux actions sélectionnées. Sépare les correspondances textuelles de ton interprétation. Si un texte manque, ne conclus pas qu’il était absent du contexte hérité. Cite les passages et indique les liens manquants.")
        case .verifyJustification: return LensL10n.text("Que dit l’historique sur la raison de ce changement ? Retrouve la demande, les instructions et les explications de l’agent. Cite les messages, précise les liens manquants et sépare tes interprétations. Des dates proches ou un tour commun ne suffisent pas à établir une cause.")
        }
    }
}

extension LensStore {
    func prepareQuestion(for target: Destination?, intent: LensQuestionIntent? = nil) {
        guard let target, canPerform(.investigate, target: target), let root = snapshot?.root.id else { return }
        let previous = investigationPreparationTask
        previous?.cancel()
        investigationPreparationTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.isObserving, self.snapshot?.root.id == root else { return }
            let prepared = await self.prepareInvestigation(for: target)
            guard prepared, !Task.isCancelled, self.isObserving, self.snapshot?.root.id == root,
                  self.investigation.capsule?.rootThreadID == root, self.investigation.issue == nil else { return }
            if let intent {
                let existing = self.investigation.question.trimmingCharacters(in: .whitespacesAndNewlines)
                if !existing.contains(intent.prompt) { self.investigation.editQuestion(existing.isEmpty ? intent.prompt : existing + "\n\n" + intent.prompt) }
            }
            if case .evidence = target { self.showLocalNotice(LensL10n.text("Élément sélectionné dans le contexte du chat")) }
            else { self.showLocalNotice(LensL10n.text("Contexte ajouté à la question · aucun envoi")) }
        }
    }
}

/// Secondary actions share the same captured object as the visible preparation button.
struct LensQuestionMenu: View {
    @ObservedObject var store: LensStore
    let target: Destination
    var body: some View {
        Menu(LensL10n.text("Préparer une question")) {
            Button(LensL10n.text("Ajouter à la question")) { store.prepareQuestion(for: target) }
            if case .change = target {
                Button(LensQuestionIntent.explainChange.title) { store.prepareQuestion(for: target, intent: .explainChange) }
                Button(LensQuestionIntent.traceOrigin.title) { store.prepareQuestion(for: target, intent: .traceOrigin) }
            }
            if case .event(let id) = target, store.event(id)?.isError == true {
                Button(LensQuestionIntent.explainError.title) { store.prepareQuestion(for: target, intent: .explainError) }
            }
        }.menuStyle(.borderlessButton)
            .disabled(!store.canPerform(.investigate, target: target))
            .help(LensL10n.text("Ajoute cet élément à une question modifiable, sans l’envoyer."))
    }
}
