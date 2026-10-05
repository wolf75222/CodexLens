import AppKit
import LensCore
import SwiftUI

/// A projection of a parsed, immutable answer. Parsing and citation validation
/// are performed by the presentation actor; displaying this view performs no IO.
struct LensChatMarkdownView: View {
    let document: ChatMarkdownDocument
    let fontSize: Double
    let onCopyCode: (String) -> Void
    let onOpenURL: (URL) -> Void
    var unformattedSuffix: String = ""
    var speaker: String? = nil
    var onCopyMessage: ((String) -> Void)? = nil
    var sources: [ChatContextSource] = []
    @State private var showsSource = false
    @AppStorage("lens.language") private var language = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if speaker != nil || document.fallbackReason != nil { HStack {
                if let speaker { Text(speaker).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                if let reason = document.fallbackReason {
                    Label(LensL10n.display(reason), systemImage: LensSymbols.name("info.circle"))
                        .font(LensUI.metadata).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .id("chat-message-controls-\(language):\(LensL10n.resolvedLanguage.rawValue)") }
            if showsSource {
                Text(document.source + unformattedSuffix)
                    .font(LensUI.readingFont(fontSize)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(document.blocks) { block in
                    decoratedBlock(block)
                        .accessibilityIdentifier("lens-chat-markdown-block-" + String(block.id))
                }
                if !unformattedSuffix.isEmpty {
                    // The last verified prefix remains in place while the next
                    // snapshot is parsed. Every received byte is still visible.
                    Text(unformattedSuffix).font(LensUI.readingFont(fontSize))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                LensChatMessageMenu(document: document, showsSource: showsSource, sources: sources,
                    onCopyMessage: onCopyMessage.map { copy in { copy(document.source + unformattedSuffix) } },
                    onCopyCode: onCopyCode, onToggleSource: { showsSource.toggle() }, onOpenURL: onOpenURL)
            }
            .environment(\.openURL, OpenURLAction { url in onOpenURL(url); return .handled })
            .accessibilityIdentifier("lens-chat-markdown")
    }


    private func decoratedBlock(_ block: ChatMarkdownBlock) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if block.quoteDepth > 0 {
                RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: .separatorColor)).frame(width: 3)
                    .accessibilityHidden(true)
            }
            if let marker = block.listMarker {
                Text(marker).font(LensUI.readingFont(fontSize)).foregroundStyle(.secondary)
                    .frame(width: fontSize * 1.5, alignment: .trailing)
            }
            blockBody(block)
        }.padding(.leading, CGFloat(min(8, max(0, block.listDepth - 1))) * 14)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func blockBody(_ block: ChatMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(.system(size: fontSize * (level == 1 ? 1.5 : level == 2 ? 1.3 : 1.12), weight: .semibold))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader).padding(.top, 4)
        case .code(let language):
            codeBlock(block, language: language)
        case .table:
            if let table = block.table { tableBody(table) }
        case .rule:
            Divider().padding(.vertical, 4)
        case .paragraph:
            Text(block.text).font(LensUI.readingFont(fontSize)).lineSpacing(3)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(_ block: ChatMarkdownBlock, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.nonempty ?? LensL10n.text("Code"))
                    .font(LensUI.metadata).foregroundStyle(.secondary).lineLimit(1).help(language ?? "")
                Spacer(minLength: 4)
                Button { onCopyCode(block.plainText) } label: {
                    Label(LensL10n.text("Copier le code"), systemImage: LensSymbols.name("doc.on.doc"))
                }.font(LensUI.metadata).buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help(LensL10n.text("Copier le contenu du bloc, sans les délimiteurs Markdown"))
                    .accessibilityIdentifier("lens-chat-code-copy-" + String(block.id))
            }.padding(8)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(block.codeLineNumbers).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).textSelection(.disabled)
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("lens-chat-code-lines-" + String(block.id))
                        Text(block.plainText).textSelection(.enabled)
                            .accessibilityIdentifier("lens-chat-code-text-" + String(block.id))
                    }.font(.system(size: max(10, fontSize - 1), design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true).padding(10)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }.frame(height: min(330, max(44, CGFloat(block.lineCount) * (fontSize + 4) + 20)))
                .accessibilityLabel(LensL10n.text("Bloc de code défilable, en lecture seule"))
                .help(LensL10n.text("Numéros des lignes de cet extrait ; pas des lignes du fichier d’origine"))
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableBody(_ table: ChatMarkdownTable) -> some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(table.rows.indices, id: \.self) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            Text(table.rows[row][column]).font(LensUI.readingFont(fontSize))
                                .fontWeight(table.headerRow && row == 0 ? .semibold : .regular)
                                .textSelection(.enabled)
                                .frame(width: 150, alignment: alignment(table, column))
                                .fixedSize(horizontal: false, vertical: true).padding(7)
                        }
                    }
                    Divider()
                }
            }.frame(width: CGFloat(table.alignments.count) * 164)
        }.background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .accessibilityLabel(LensL10n.text("Tableau Markdown, défilement horizontal"))
    }

    private func alignment(_ table: ChatMarkdownTable, _ index: Int) -> Alignment {
        guard table.alignments.indices.contains(index) else { return .leading }
        switch table.alignments[index] { case .left: return .leading; case .center: return .center; case .right: return .trailing }
    }
}

/// A question is visually distinct from the answer without using a second
/// accent color. Native selectable text preserves exact copy and wrapping.
struct LensChatQuestionBubble: View {
    @AppStorage("lens.language") private var language = "system"
    let text: String
    let fontSize: Double

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(LensL10n.text("Vous")).font(LensUI.metadata).foregroundStyle(.secondary)
                    .id("chat-question-label-\(language):\(LensL10n.resolvedLanguage.rawValue)")
                Text(text).font(LensUI.readingFont(fontSize)).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(LensBrand.controlHover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("lens-chat-question-bubble")
    }
}

/// Anonymous component variants within the existing development gallery.
private enum LensChatMarkdownFixture {
    static let source = """
    ## Analyse du diff
    Le patch contient `label`.

    > La version courante n’est pas la version historique.

    - Ouvrir la source
      - Conserver le worktree
    - Signaler les données absentes

    | Version | Disponibilité |
    | :-- | :-- |
    | Capturée | Fragment enregistré |
    | Courante | Fichier local distinct |

    ```swift
    let label = "fixture café"
    ```
    """
}
struct LensChatMarkdownGalleryPreview: View {
    let fontSize: Double
    @State private var document: ChatMarkdownDocument?
    @State private var notice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let document {
                LensChatMarkdownView(document: document, fontSize: fontSize, onCopyCode: { text in
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    notice = LensL10n.text("Texte copié")
                }, onOpenURL: { _ in notice = LensL10n.text("Lien de démonstration ; aucune navigation externe") })
            } else { LensProgressIndicator(LensL10n.text("Préparation du Markdown…")) }
            if let notice { Text(notice).font(LensUI.metadata).foregroundStyle(.secondary) }
        }.task {
            let task = Task.detached { try ChatMarkdownParser.parse(LensChatMarkdownFixture.source) }
            do {
                let parsed = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                guard !Task.isCancelled else { return }; document = parsed
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
