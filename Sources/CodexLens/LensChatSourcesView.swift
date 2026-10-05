import SwiftUI
import LensCore

/// Narrow metadata inputs keep source navigation independent of streamed text.
struct LensChatSourcesView: View {
    let sources: [ChatContextSource]
    let title: String
    let canReuse: Bool
    let onOpen: (EvidenceAddress) -> Void
    let onReuse: (EvidenceAddress) -> Void
    @State private var expanded = false
    /// The seed is for the native fixture gallery; later disclosure belongs to this list.
    init(sources: [ChatContextSource], title: String, canReuse: Bool, initiallyExpanded: Bool = false,
         onOpen: @escaping (EvidenceAddress) -> Void, onReuse: @escaping (EvidenceAddress) -> Void) {
        self.sources = sources; self.title = title; self.canReuse = canReuse; self.onOpen = onOpen; self.onReuse = onReuse
        _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    LensChatSourceRow(source: source, onOpen: { onOpen(source.address) }) {
                        Button { onReuse(source.address) } label: {
                            Image(systemName: "plus").frame(width: 24, height: 24)
                        }.buttonStyle(.borderless).disabled(!canReuse)
                            .help(LensL10n.text("Joindre cette version à la prochaine question"))
                            .accessibilityLabel(LensL10n.text("Joindre {0} à la prochaine question", source.title))
                            .accessibilityIdentifier("lens-chat-reuse-" + source.address.pieceID)
                    }
                }
            }.padding(.top, 6)
        } label: { Text(title).lineLimit(1) }
            .font(LensUI.metadata).accessibilityIdentifier("lens-chat-message-sources")
    }
}

struct LensChatSourceRow<Accessory: View>: View {
    let source: ChatContextSource
    let onOpen: () -> Void
    @ViewBuilder let accessory: Accessory
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            openButton
            accessory
        }
    }
    private var openButton: some View {
        Button { onOpen() } label: {
            LensChatSourceLabel(source: source, symbol: symbol, versionLabel: versionLabel)
        }.buttonStyle(.plain).help(tooltip)
            .accessibilityLabel(LensL10n.text("Ouvrir {0}, {1}", source.title, versionLabel))
            .accessibilityIdentifier("lens-chat-source-\(source.address.pieceID)")
    }
    private var tooltip: String { [source.title, versionLabel, source.environment ?? ""].joined(separator: "\n") }
    private var versionLabel: String {
        let kind: String
        switch source.location?.versionKind {
        case .capturedCurrent: kind = LensL10n.text("Fichier actuel capturé")
        case .verifiedGitBlob: kind = LensL10n.text("Version Git")
        case .verifiedReconstruction: kind = LensL10n.text("Version reconstruite")
        case .recordedFragment: kind = LensL10n.text("Fragment enregistré")
        case nil: kind = InvestigationEvidenceLabels.label(source.kind)
        }
        return source.version.map { kind + " · " + $0 } ?? kind
    }
    private var symbol: String {
        switch source.kind {
        case "recordedDiff", "recordedPatch", "currentGitDiff", "observedDiff": return "plus.forwardslash.minus"
        case "instruction", "user", "userMessage", "assistant", "content": return "text.bubble"
        case "toolCall", "toolResult", "input", "output", "arguments", "result": return "wrench.and.screwdriver"
        case "environmentMetadata": return "folder"
        case "resourceMetadata": return "paperclip"
        default: return "doc.text"
        }
    }
}

private struct LensChatSourceLabel: View {
    let source: ChatContextSource
    let symbol: String
    let versionLabel: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).frame(width: 16).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("[\(source.address.pieceID)] \(source.title)").lineLimit(2).truncationMode(.middle)
                Text(versionLabel).font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(2)
                if let environment = source.environment {
                    Text(LensL10n.text("Worktree : {0}", environment))
                        .font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                if source.coverageCount > 0 {
                    Label(LensL10n.text("{0} limites dans les sources", String(source.coverageCount)), systemImage: "exclamationmark.triangle")
                        .font(LensUI.metadata).foregroundStyle(LensAppearance.warningText)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
    }
}

enum LensChatPrompt: String, CaseIterable {
    case explain, compare, instructions, missing
    var title: String {
        switch self {
        case .explain: return LensL10n.text("Expliquer la sélection")
        case .compare: return LensL10n.text("Comparer les versions jointes")
        case .instructions: return LensL10n.text("Retrouver les consignes")
        case .missing: return LensL10n.text("Identifier ce qui manque")
        }
    }
    var question: String {
        switch self {
        case .explain: return LensL10n.text("Explique le contexte joint et cite les sources correspondantes.")
        case .compare: return LensL10n.text("Compare les versions jointes. Indique les différences, les worktrees et les limites des extraits disponibles, avec les sources correspondantes.")
        case .instructions: return LensL10n.text("Quelles consignes sont associées aux actions jointes ? Distingue les liens enregistrés des simples rapprochements et cite les sources.")
        case .missing: return LensL10n.text("Que peut-on établir à partir du contexte joint, et quels éléments manquent pour répondre ? Cite les sources disponibles.")
        }
    }
}
