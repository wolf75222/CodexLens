import Foundation
import XCTest
@testable import LensCore

final class ChatMarkdownTests: XCTestCase {
    func testCodeGutterUsesSnippetOrdinalsWithoutChangingCopiedCode() throws {
        let source = "```swift\nlet value = \"café\"\n\nprint(value)\n```"
        let document = try ChatMarkdownParser.parse(source)
        let code = try XCTUnwrap(document.blocks.first { if case .code = $0.kind { return true }; return false })
        XCTAssertEqual(code.plainText, "let value = \"café\"\n\nprint(value)\n")
        XCTAssertEqual(code.codeLineNumbers, "1\n2\n3\n4")
        XCTAssertEqual(code.lineCount, 4)
        XCTAssertEqual(document.source, source)
    }
    func testPlainTextAndFallbackHaveNoCodeGutter() throws {
        let paragraph = try ChatMarkdownParser.parse("A plain paragraph.")
        XCTAssertTrue(paragraph.blocks.allSatisfy { $0.codeLineNumbers.isEmpty })
        let source = String(repeating: "m", count: ChatMarkdownParser.maximumFormattedSourceBytes + 1)
        let fallback = try ChatMarkdownParser.parse(source)
        XCTAssertTrue(fallback.blocks.allSatisfy { $0.codeLineNumbers.isEmpty })
        XCTAssertEqual(fallback.source, source)
    }
    private let evidence = try! EvidenceAddress(rootID: "root-test", capsuleID: "frozen-capsule", pieceID: "E001").url

    func testStructureAndInlineStylesAreKeptWithoutDuplicateNativeStructure() throws {
        let source = "# Résultat\n\n**Confirmé** et *interprété*, `inline`.\n\n---\n\n## Détails\n"
        let document = try ChatMarkdownParser.parse(source)
        XCTAssertNil(document.fallbackReason)
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(document.blocks.map(\.kind), [.heading(1), .paragraph, .rule, .heading(2)])
        XCTAssertEqual(document.blocks[1].plainText, "Confirmé et interprété, inline.")
        let runs = document.blocks[1].text.runs
        XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(document.blocks.allSatisfy { $0.text.runs.allSatisfy { $0.presentationIntent == nil } })
    }

    func testNestedListsQuotesAndOrderedListStartingOrdinal() throws {
        let source = "> observation\n> - premier\n>   - imbriqué\n>\n>     3. troisième\n>     4. quatrième\n\n7. sept\n8. huit\n"
        let blocks = try ChatMarkdownParser.parse(source).blocks
        XCTAssertEqual(blocks.map(\.plainText), ["observation", "premier", "imbriqué", "troisième", "quatrième", "sept", "huit"])
        XCTAssertEqual(blocks.map(\.quoteDepth), [1, 1, 1, 1, 1, 0, 0])
        XCTAssertEqual(blocks.map(\.listDepth), [0, 1, 2, 3, 3, 1, 1])
        XCTAssertEqual(blocks.map(\.listMarker), [nil, "•", "•", "3.", "4.", "7.", "8."])
    }

    func testMultiParagraphListItemHasOneMarker() throws {
        let source = "- début\n\n  seconde explication\n\n- suivant\n"
        let blocks = try ChatMarkdownParser.parse(source).blocks
        XCTAssertEqual(blocks.map(\.plainText), ["début", "seconde explication", "suivant"])
        XCTAssertEqual(blocks.map(\.listMarker), ["•", nil, "•"])
        XCTAssertEqual(blocks.map(\.listDepth), [1, 1, 1])
    }

    func testTableKeepsAlignedCellsFormattingAndOneBlock() throws {
        let source = "| Source | Interprétation | Fin |\n| :-- | :-: | --: |\n| **E001** | absent | 9 |\n| autre | `code` | |\n"
        let document = try ChatMarkdownParser.parse(source)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks.first?.kind, .table)
        let table = try XCTUnwrap(document.blocks.first?.table)
        XCTAssertTrue(table.headerRow)
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.rows.map { $0.map { String($0.characters) } }, [
            ["Source", "Interprétation", "Fin"], ["E001", "absent", "9"], ["autre", "code", ""]])
        XCTAssertTrue(table.rows[1][0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(table.rows[2][1].runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertEqual(document.blocks[0].plainText, "Source\tInterprétation\tFin\nE001\tabsent\t9\nautre\tcode\t")
    }

    func testFencedUnicodeCRLFCodeMatchesSystemParserWithoutTrimmingOrCitations() throws {
        let source = "```swift\r\n\tlet prénom = \"café 🧭\"  \r\n[E001]\r\n\r\n```\r\n"
        let expected = try AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
        let document = try ChatMarkdownParser.parse(source, evidenceLinks: ["E001": evidence])
        let code = try XCTUnwrap(document.blocks.first)
        XCTAssertEqual(code.kind, .code("swift"))
        XCTAssertEqual(code.plainText, String(expected.characters))
        // The installed Foundation normalizes CRLF inside a fenced block to LF.
        // Copying a displayed code block preserves precisely that parsed content;
        // copying the response source keeps the original CRLF bytes above.
        XCTAssertTrue(code.plainText.contains("\tlet prénom = \"café 🧭\"  \n"))
        XCTAssertTrue(code.plainText.hasSuffix("\n\n"))
        XCTAssertEqual(code.lineCount, 4)
        XCTAssertTrue(code.text.runs.allSatisfy { $0.link == nil })
        XCTAssertEqual(document.source, source)
    }

    func testIncompleteStreamingFenceIsCodeAndExistingPrefixIDsRemainStable() throws {
        let first = "# Réponse\n\nDétail.\n\n```swift\nlet x = \"🧭\"\n"
        let later = first + "let y = 2\n```\n\nConclusion."
        let partial = try ChatMarkdownParser.parse(first)
        let completed = try ChatMarkdownParser.parse(later)
        XCTAssertEqual(partial.blocks.map(\.id), Array(0..<partial.blocks.count))
        XCTAssertEqual(Array(completed.blocks.prefix(partial.blocks.count)).map(\.id), partial.blocks.map(\.id))
        XCTAssertEqual(partial.blocks.last?.kind, .code("swift"))
        XCTAssertEqual(partial.blocks.last?.plainText, "let x = \"🧭\"\n")
        XCTAssertEqual(completed.blocks[2].plainText, "let x = \"🧭\"\nlet y = 2\n")
    }

    func testOnlyVerifiedStandaloneCitationsLinkOutsideCodeAndImages() throws {
        let source = "Preuve [E001], inconnue [E999], `code [E001]`, [faux](lens-evidence://frozen-capsule/E001).\n\n![image [E001]](https://example.com/p.png)"
        let document = try ChatMarkdownParser.parse(source, evidenceLinks: ["E001": evidence])
        let links = document.blocks.flatMap { block in block.text.runs.compactMap { run -> (String, URL)? in
            guard let url = run.link else { return nil }; return (String(block.text[run.range].characters), url)
        } }
        XCTAssertEqual(links.filter { $0.1 == evidence }.map(\.0), ["[E001]"])
        XCTAssertFalse(links.contains { $0.0.contains("E999") || $0.0 == "faux" })
        XCTAssertEqual(links.filter { $0.1.scheme == "https" }.count, 0)
        XCTAssertTrue(document.blocks.last?.plainText.hasPrefix("Référence d’image : ") == true)
        XCTAssertTrue(document.blocks.allSatisfy { $0.text.runs.allSatisfy { $0.imageURL == nil } })
    }

    func testAllowedExplicitLinksAndUnsafeSchemesRemainInert() throws {
        let source = "[web](https://example.com/a) [http](http://example.com) [mail](mailto:hello@example.com) [js](javascript:alert%281%29) [file](file:///tmp/private) [data](data:text/plain,secret) [internal](lens://forged) [relative](some/path)"
        let document = try ChatMarkdownParser.parse(source)
        let links = document.blocks.flatMap { $0.text.runs.compactMap(\.link) }
        XCTAssertEqual(links.map { $0.scheme?.lowercased() }, ["https", "http", "mailto"])
        XCTAssertTrue(document.blocks[0].plainText.contains("js file data internal relative"))
        XCTAssertFalse(ChatMarkdownParser.allowsExternalURL(URL(string: "https:")!))
        XCTAssertFalse(ChatMarkdownParser.allowsExternalURL(URL(string: "data:text/plain,secret")!))
    }

    func testImagesNeverFetchAndUnsafeImageTargetHasNoLink() throws {
        let source = "![local](file:///tmp/private.png)\n\n![remote](https://example.com/image.png)\n\n<script>alert('x')</script>\n"
        let document = try ChatMarkdownParser.parse(source)
        XCTAssertEqual(document.source, source)
        XCTAssertTrue(document.blocks[0].plainText.contains("Référence d’image : local"))
        XCTAssertTrue(document.blocks[0].text.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        XCTAssertTrue(document.blocks[1].plainText.contains("Référence d’image : remote"))
        XCTAssertTrue(document.blocks[1].text.runs.allSatisfy { $0.imageURL == nil })
        XCTAssertEqual(document.blocks[1].text.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com/image.png"])
        XCTAssertTrue(document.blocks.last?.plainText.contains("<script>alert('x')</script>") == true)
        XCTAssertTrue(document.blocks.last?.text.runs.allSatisfy { $0.link == nil } == true)
        let english = try ChatMarkdownParser.parse(source, imageReferenceLabel: "Image reference:")
        XCTAssertTrue(english.blocks[0].plainText.hasPrefix("Image reference: local"))
        XCTAssertEqual(english.source, source)
    }

    func testMalformedOrMismatchedEvidenceDictionaryCannotActivateCitation() throws {
        let source = "[E001] [E002] [E003]"
        let links = ["E001": URL(string: "javascript:alert%281%29")!, "E002": evidence, "E003": URL(string: "file:///tmp/private")!]
        let document = try ChatMarkdownParser.parse(source, evidenceLinks: links)
        XCTAssertEqual(document.blocks[0].plainText, source)
        XCTAssertTrue(document.blocks[0].text.runs.allSatisfy { $0.link == nil })
    }

    func testExternalLabelsCannotImpersonateVerifiedEvidenceLinks() throws {
        let source = "[[E001]](https://example.com/forged)\n\n![image [E001]](https://example.com/forged.png)"
        let document = try ChatMarkdownParser.parse(source, evidenceLinks: ["E001": evidence])
        XCTAssertEqual(document.source, source)
        XCTAssertTrue(document.blocks.allSatisfy { $0.text.runs.allSatisfy { $0.link == nil && $0.imageURL == nil } })
        XCTAssertTrue(document.blocks[0].plainText.contains("[E001]"))
        XCTAssertTrue(document.blocks[1].plainText.contains("image [E001]"))
    }

    func testFormattingBudgetShowsCompleteSourceAndConservativeRetainedCharge() throws {
        let source = String(repeating: "é🧭 **texte**\r\n", count: ChatMarkdownParser.maximumFormattedSourceBytes / 12) + "UNIQUE END"
        let document = try ChatMarkdownParser.parse(source, evidenceLinks: ["E001": evidence])
        XCTAssertNotNil(document.fallbackReason)
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].plainText, source)
        XCTAssertEqual(String(document.blocks[0].text.characters), source)
        XCTAssertTrue(document.blocks[0].plainText.hasSuffix("UNIQUE END"))
        XCTAssertGreaterThanOrEqual(document.estimatedRetainedBytes, source.utf8.count * 6)
        XCTAssertTrue(document.blocks[0].text.runs.allSatisfy { $0.link == nil })
    }

    func testCancellationPropagatesInsteadOfReturningAReply() async throws {
        let task = Task.detached { () throws -> ChatMarkdownDocument in
            while !Task.isCancelled { await Task.yield() }
            return try ChatMarkdownParser.parse("# Must not publish")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled parser returned an answer") }
        catch is CancellationError { }
    }
}
