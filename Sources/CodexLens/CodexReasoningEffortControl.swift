import SwiftUI
import LensCore

/// Capabilities come from the installed Codex, rather than a fixed list of levels.
struct CodexReasoningEffortControl: View {
    @ObservedObject var investigator: InvestigationStore
    var compact = true

    var body: some View {
        Group {
            if compact {
                Menu {
                    picker
                    if !investigator.reasoningEffortSelectionValid { Divider(); clearSavedChoice }
                } label: {
                    Text(currentLabel).font(LensUI.metadata).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 90, alignment: .leading)
                }.menuStyle(.borderlessButton)
                    .frame(maxWidth: 110, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true).clipped()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    picker.pickerStyle(.menu)
                    if !investigator.reasoningEffortSelectionValid { clearSavedChoice }
                }
            }
        }
        .disabled(investigator.sending || investigator.connecting || investigator.availableReasoningEfforts.isEmpty && investigator.reasoningEffortSelectionValid)
        .help(currentLabel + "\n" + helpText)
        .accessibilityLabel(LensL10n.text("Effort de raisonnement"))
        .accessibilityValue(currentLabel)
        .accessibilityIdentifier(compact ? "lens-chat-effort-selector" : "lens-settings-effort-selector")
    }

    private var selection: Binding<String> {
        Binding(get: { investigator.reasoningEffort ?? "" }, set: { investigator.chooseReasoningEffort($0.isEmpty ? nil : $0) })
    }
    private var clearSavedChoice: some View {
        Button(LensL10n.text("Effacer l’effort enregistré")) { investigator.clearUnavailableReasoningEffort() }
            .help(LensL10n.text("Retirer le choix de Lens. Sans valeur par défaut annoncée, Codex conserve son réglage courant."))
    }

    private var picker: some View {
        Picker(LensL10n.text("Effort de raisonnement"), selection: selection) {
            Text(defaultLabel).tag("").disabled(investigator.selectedCodexModel?.defaultReasoningEffort == nil)
            if let selected = investigator.reasoningEffort, !investigator.reasoningEffortSelectionValid {
                Text(LensL10n.text("{0} · indisponible", Self.label(selected))).tag(selected).disabled(true)
            }
            ForEach(investigator.availableReasoningEfforts) { effort in
                Text(Self.label(effort.id)).tag(effort.id)
            }
        }
    }

    private var defaultLabel: String {
        if let value = investigator.selectedCodexModel?.defaultReasoningEffort {
            return LensL10n.text("Par défaut · {0}", Self.label(value))
        }
        return LensL10n.text("Par défaut dans Codex")
    }
    private var currentLabel: String {
        if let value = investigator.effectiveReasoningEffort { return Self.label(value) }
        return LensL10n.text(investigator.availableReasoningEfforts.isEmpty ? "Indisponible" : "Par défaut dans Codex")
    }
    private var helpText: String {
        if !investigator.reasoningEffortSelectionValid {
            return investigator.reasoningEffortUnavailableMessage
        }
        if investigator.availableReasoningEfforts.isEmpty {
            return LensL10n.text("Cette version de Codex ne fournit pas les niveaux d’effort de ce modèle.")
        }
        return LensL10n.text("Choisir l’effort de raisonnement. Un effort plus élevé peut prendre plus de temps.")
    }

    static func label(_ value: String) -> String {
        switch value {
        case "none": return LensL10n.text("Aucun")
        case "minimal": return LensL10n.text("Minimal")
        case "low": return LensL10n.text("Faible")
        case "medium": return LensL10n.text("Moyen")
        case "high": return LensL10n.text("Élevé")
        case "xhigh": return LensL10n.text("Très élevé")
        default: return value
        }
    }
}
