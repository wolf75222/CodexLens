import Foundation

/// A presentation of an AI answer. `source` always preserves the complete original
/// answer, including Markdown that the system parser treats as structure.
public struct ChatMarkdownDocument: Sendable {
    public let blocks: [ChatMarkdownBlock]
    public let source: String
    public let fallbackReason: String?
    /// A conservative cache charge, not a measurement of the process's allocation.
    public let estimatedRetainedBytes: Int
}

public struct ChatMarkdownBlock: Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case code(String?)
        case table
        case rule
    }

    /// Ordinal identity stays stable for the existing prefix when a reply appends.
    public let id: Int
    public let kind: Kind
    public let text: AttributedString
    public let plainText: String
    public let lineCount: Int
    /// Ordinals within this response snippet, never historical file coordinates.
    public let codeLineNumbers: String
    public let quoteDepth: Int
    public let listDepth: Int
    public let listMarker: String?
    public let table: ChatMarkdownTable?
}

public struct ChatMarkdownTable: Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public let alignments: [Alignment]
    public let rows: [[AttributedString]]
    public let headerRow: Bool
}

/// Foundation's full Markdown parser is available on the macOS 14 deployment
/// target. This model performs no I/O, media fetching, HTML evaluation or UI work.
/// Call it from an indexing/presentation actor, not from a SwiftUI body.
public enum ChatMarkdownParser {
    public static let maximumFormattedSourceBytes = 512 * 1024
    public static let maximumFormattedBlocks = 10_000
    public static let maximumFormattedRuns = 50_000

    public static func parse(_ source: String, evidenceLinks: [String: URL] = [:], imageReferenceLabel: String = "Référence d’image :") throws -> ChatMarkdownDocument {
        try Task.checkCancellation()
        let sourceBytes = source.utf8.count
        guard sourceBytes <= maximumFormattedSourceBytes else {
            return try fallback(source, reason: "Markdown trop volumineux pour la mise en forme ; le texte complet reste affiché.")
        }

        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: .init(
                allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .throwError))
        } catch {
            try Task.checkCancellation()
            return try fallback(source, reason: "Mise en forme Markdown indisponible ; le texte complet reste affiché.")
        }
        try Task.checkCancellation()

        var builders: [BlockBuilder] = []
        var currentKey: BlockKey?
        var shownListItems: Set<Int> = []
        for (runIndex, run) in parsed.runs.enumerated() {
            try Task.checkCancellation()
            guard runIndex < maximumFormattedRuns else {
                return try fallback(source, reason: "Markdown trop complexe pour la mise en forme des styles ; le texte complet reste affiché.")
            }
            let components = run.presentationIntent?.components ?? []
            let tableComponent = components.first { if case .table = $0.kind { return true }; return false }
            let key = tableComponent.map { BlockKey.intent($0.identity) }
                ?? components.first.map { BlockKey.intent($0.identity) } ?? .unstructured

            if key != currentKey {
                guard builders.count < maximumFormattedBlocks else {
                    return try fallback(source, reason: "Markdown trop complexe pour la mise en forme des blocs ; le texte complet reste affiché.")
                }
                builders.append(BlockBuilder(id: builders.count, components: components, shownListItems: &shownListItems))
                currentKey = key
            }
            guard !builders.isEmpty else { continue }
            let isCode = builders[builders.count - 1].isCode
                || run.inlinePresentationIntent?.contains(.code) == true
                || run.inlinePresentationIntent?.contains(.inlineHTML) == true
                || run.inlinePresentationIntent?.contains(.blockHTML) == true
            let text = try sanitized(AttributedString(parsed[run.range]), isCodeOrHTML: isCode, evidenceLinks: evidenceLinks, imageReferenceLabel: imageReferenceLabel)
            builders[builders.count - 1].append(text, components: components)
        }

        // The parser can consume whitespace without producing a run. Keeping it
        // visible as plain text is preferable to an apparently empty answer.
        if builders.isEmpty, !source.isEmpty {
            return try fallback(source, reason: "Aucun bloc Markdown visible ; le texte complet reste affiché.")
        }
        var blocks: [ChatMarkdownBlock] = []
        blocks.reserveCapacity(builders.count)
        var retained = charge(sourceBytes, multiplier: 2)
        for builder in builders {
            try Task.checkCancellation()
            let block = builder.finish()
            blocks.append(block)
            retained = addCharge(retained, estimate(block.text))
            retained = addCharge(retained, charge(block.plainText.utf8.count, multiplier: 2))
            retained = addCharge(retained, charge(block.codeLineNumbers.utf8.count, multiplier: 2))
            retained = addCharge(retained, 256)
            if let table = block.table {
                for row in table.rows {
                    try Task.checkCancellation()
                    retained = addCharge(retained, 64)
                    for cell in row { retained = addCharge(retained, addCharge(estimate(cell), 128)) }
                }
            }
        }
        try Task.checkCancellation()
        return ChatMarkdownDocument(blocks: blocks, source: source, fallbackReason: nil, estimatedRetainedBytes: retained)
    }

    private enum BlockKey: Equatable { case intent(Int), unstructured }

    private struct BlockBuilder {
        let id: Int
        let kind: ChatMarkdownBlock.Kind
        let quoteDepth: Int
        let listDepth: Int
        let listMarker: String?
        var text = AttributedString()
        var alignments: [ChatMarkdownTable.Alignment] = []
        var rows: [[AttributedString]] = []
        var headerRow = false
        var isCode: Bool { if case .code = kind { return true }; return false }

        init(id: Int, components: [PresentationIntent.IntentType], shownListItems: inout Set<Int>) {
            self.id = id
            quoteDepth = components.filter { $0.kind == .blockQuote }.count
            listDepth = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
            var marker: String?
            if let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
               case let .listItem(ordinal) = components[itemIndex].kind,
               shownListItems.insert(components[itemIndex].identity).inserted {
                let container = components.dropFirst(itemIndex + 1).first { $0.kind == .orderedList || $0.kind == .unorderedList }
                marker = container?.kind == .orderedList ? "\(ordinal)." : "•"
            }
            listMarker = marker
            if let table = components.first(where: { if case .table = $0.kind { return true }; return false }),
               case let .table(columns) = table.kind {
                kind = .table
                alignments = columns.map { column in
                    switch column.alignment {
                    case .left: return .left
                    case .center: return .center
                    case .right: return .right
                    @unknown default: return .left
                    }
                }
            } else {
                switch components.first?.kind {
                case let .header(level): kind = .heading(level)
                case let .codeBlock(languageHint): kind = .code(languageHint)
                case .thematicBreak: kind = .rule
                default: kind = .paragraph
                }
            }
        }

        mutating func append(_ value: AttributedString, components: [PresentationIntent.IntentType]) {
            guard kind == .table else { text.append(value); return }
            var rowIndex: Int?
            var columnIndex: Int?
            for component in components {
                switch component.kind {
                case .tableHeaderRow: rowIndex = 0; headerRow = true
                case let .tableRow(index): rowIndex = index
                case let .tableCell(index): columnIndex = index
                default: break
                }
            }
            guard let row = rowIndex, let column = columnIndex, row >= 0, column >= 0 else {
                text.append(value)
                return
            }
            while rows.count <= row { rows.append([]) }
            while rows[row].count <= column { rows[row].append(AttributedString()) }
            rows[row][column].append(value)
        }

        func finish() -> ChatMarkdownBlock {
            var displayText = text
            var table: ChatMarkdownTable?
            if kind == .table {
                let rectangularRows = rows.map { row in row + Array(repeating: AttributedString(), count: max(0, alignments.count - row.count)) }
                table = ChatMarkdownTable(alignments: alignments, rows: rectangularRows, headerRow: headerRow)
                for (rowIndex, row) in rectangularRows.enumerated() {
                    if rowIndex > 0 { displayText.append(AttributedString("\n")) }
                    for (cellIndex, cell) in row.enumerated() {
                        if cellIndex > 0 { displayText.append(AttributedString("\t")) }
                        displayText.append(cell)
                    }
                }
            }
            let plain = String(displayText.characters)
            let lineCount = 1 + plain.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
            return ChatMarkdownBlock(id: id, kind: kind, text: displayText, plainText: plain,
                lineCount: lineCount, codeLineNumbers: isCode ? (1...lineCount).map(String.init).joined(separator: "\n") : "",
                quoteDepth: quoteDepth, listDepth: listDepth, listMarker: listMarker, table: table)
        }
    }

    private static func sanitized(_ value: AttributedString, isCodeOrHTML: Bool, evidenceLinks: [String: URL], imageReferenceLabel: String) throws -> AttributedString {
        var result = value
        let isImage = result.imageURL != nil
        let originalLink = result.link
        let imageLink = result.imageURL
        let plain = String(result.characters)
        let visibleRange = NSRange(plain.startIndex..., in: plain)
        let looksLikeEvidence = citationPattern.firstMatch(in: plain, range: visibleRange) != nil
        result.presentationIntent = nil // The native block renderer owns structure.
        result.imageURL = nil          // Never allow an attributed renderer to fetch media.
        if let link = originalLink, !allowsExternalURL(link) || looksLikeEvidence { result.link = nil }
        if isImage {
            result.link = imageLink.flatMap { allowsExternalURL($0) && !looksLikeEvidence ? $0 : nil }
            var marker = AttributedString(imageReferenceLabel + " ")
            marker.append(result)
            return marker
        }
        guard !isCodeOrHTML, originalLink == nil, !evidenceLinks.isEmpty else { return result }
        let matches = citationPattern.matches(in: plain, range: visibleRange)
        for match in matches {
            try Task.checkCancellation()
            guard let idRange = Range(match.range(at: 1), in: plain),
                  let visibleRange = Range(match.range, in: plain),
                  let target = evidenceLinks[String(plain[idRange])] ?? evidenceLinks[String(plain[visibleRange])],
                  let address = try? EvidenceAddress(url: target), address.pieceID == String(plain[idRange]),
                  let attributedRange = Range(visibleRange, in: result) else { continue }
            result[attributedRange].link = target
        }
        return result
    }

    /// These are explicit actions only; parsing this URL never opens it.
    public static func allowsExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false
        // Markdown's NSURL-backed URL can expose an empty `path` for opaque
        // mailto URLs even when a freshly constructed Swift URL does not.
        case "mailto": return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.isEmpty == false
        default: return false
        }
    }

    private static let citationPattern = try! NSRegularExpression(pattern: #"\[(E[0-9]+)\]"#)

    private static func fallback(_ source: String, reason: String) throws -> ChatMarkdownDocument {
        try Task.checkCancellation()
        let text = AttributedString(source)
        let block = ChatMarkdownBlock(id: 0, kind: .paragraph, text: text, plainText: source,
            lineCount: 1 + source.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }, codeLineNumbers: "", quoteDepth: 0,
            listDepth: 0, listMarker: nil, table: nil)
        try Task.checkCancellation()
        return ChatMarkdownDocument(blocks: [block], source: source, fallbackReason: reason,
            estimatedRetainedBytes: addCharge(charge(source.utf8.count, multiplier: 6), 1280))
    }

    private static func estimate(_ text: AttributedString) -> Int {
        var value = charge(String(text.characters).utf8.count, multiplier: 2)
        for run in text.runs {
            value = addCharge(value, 1024)
            if let link = run.link { value = addCharge(value, charge(link.absoluteString.utf8.count, multiplier: 2)) }
        }
        return value
    }

    private static func charge(_ value: Int, multiplier: Int) -> Int {
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func addCharge(_ left: Int, _ right: Int) -> Int {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int.max : result.partialValue
    }
}
