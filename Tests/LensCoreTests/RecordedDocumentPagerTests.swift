import XCTest
@testable import LensCore

final class RecordedDocumentPagerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lens-document-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func event(_ payload: [String: Any], name: String) throws -> LensEvent {
        let data = try JSONSerialization.data(withJSONObject: ["payload": payload], options: [.sortedKeys, .withoutEscapingSlashes])
        let path = directory.appendingPathComponent(name); try data.write(to: path)
        return LensEvent(id: name, agentID: "root", source: SourceRef(path: path.path, length: data.count, line: 1))
    }
    func testMissingCallOutputDoesNotPolluteResultOrHideItsSource() async throws {
        let call = try event(["arguments": "cat Instructions.md"], name: "call.jsonl")
        let content = "# Instructions QA\nInspecter les deux worktrees.\n[Source 1 : texte appartenant au résultat]\n"
        let result = try event(["output": content], name: "result.jsonl")
        let page = try await RecordedDocumentPager().begin(event: call, relatedEvent: result, part: "output")
        XCTAssertNil(page.token)
        XCTAssertEqual(page.slices.count, 2)
        XCTAssertEqual(page.slices[0].source, call.source)
        XCTAssertTrue(page.slices[0].complete); XCTAssertFalse(page.slices[0].fieldFound)
        XCTAssertEqual(page.slices[0].text, "")
        XCTAssertEqual(page.slices[1].text, content)
        XCTAssertTrue(page.slices[1].fieldFound)
        XCTAssertEqual(page.slices[1].source, result.source)
    }
    func testLargeUnicodeResultKeepsTailAndDoesNotRepeatSourceHeaders() async throws {
        let body = String(repeating: "é\\\"\t\n", count: 100000) + "END-OF-RECORDED-OUTPUT"
        let item = try event(["output": body], name: "large.jsonl")
        let reader = RecordedDocumentPager()
        var page = try await reader.begin(event: item, part: "output", limit: 4096)
        XCTAssertNotNil(page.token); XCTAssertLessThan(page.bytesRead, 80000)
        var text = ""
        while true {
            for slice in page.slices { XCTAssertEqual(slice.source, item.source); text += slice.text }
            guard let token = page.token else { break }
            page = try await reader.next(token: token, limit: 4096)
        }
        XCTAssertTrue(text.utf8.elementsEqual(body.utf8))
    }
    func testEmptyRecordedFieldIsDistinctFromMissingField() async throws {
        let item = try event(["output": ""], name: "empty.jsonl")
        let page = try await RecordedDocumentPager().begin(event: item, part: "output")
        XCTAssertEqual(page.slices[0].text, ""); XCTAssertTrue(page.slices[0].fieldFound)
        XCTAssertTrue(page.slices[0].complete); XCTAssertNil(page.token)
    }
    func testDeduplicationKeepsTwoWorktreeSourcesDistinct() async throws {
        var first = try event(["output": "ALPHA"], name: "alpha.jsonl")
        let second = try event(["output": "BETA"], name: "beta.jsonl")
        first.supplementarySources = [first.source, second.source]
        let reader = RecordedDocumentPager()
        let a = try await reader.begin(event: first, relatedEvent: second, part: "output")
        let b = try await reader.next(token: XCTUnwrap(a.token))
        XCTAssertEqual(a.slices.map(\.text), ["ALPHA"])
        XCTAssertEqual(b.slices.map(\.text), ["BETA"]); XCTAssertNil(b.token)
        XCTAssertNotEqual(a.slices[0].source, b.slices[0].source)
    }
    func testMaskingAndCorruptEOFRemainEnforced() async throws {
        let item = try event(["output": "Bearer ABCdef123 sk-sensitive\nEND"], name: "secret.jsonl")
        let page = try await RecordedDocumentPager().begin(event: item, part: "output", limit: 4096)
        XCTAssertTrue(page.slices[0].text.contains("[REDACTED]"))
        XCTAssertFalse(page.slices[0].text.contains("ABCdef123")); XCTAssertFalse(page.slices[0].text.contains("sk-sensitive"))
        let path = directory.appendingPathComponent("partial.jsonl")
        let data = Data("{\"payload\":{\"output\":\"unfinished".utf8); try data.write(to: path)
        let broken = LensEvent(id: "partial", agentID: "root", source: SourceRef(path: path.path, length: data.count, line: 1))
        do { _ = try await RecordedDocumentPager().begin(event: broken, part: "output"); XCTFail("Corrupt EOF accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("incomplète")) }
    }
}
