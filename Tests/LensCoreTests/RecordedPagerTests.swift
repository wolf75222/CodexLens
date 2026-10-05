import XCTest
import CryptoKit
@testable import LensCore

final class RecordedPagerTests: XCTestCase {
    func testFullPersistedReasoningSummaryIsPagedWithoutOpaqueContent() async throws {
        let text = String(repeating: "Texte original ", count: 20000) + "SUMMARY-END"
        let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "Reasoning", "summary_text": [text], "raw_content": [], "encrypted_content": "OPAQUE-MARKER"]]])
        let pager = RecordedPager(), item = try event(data)
        let first = try await pager.begin(event: item, part: "content", limit: 4096)
        XCTAssertNotNil(first.token)
        let content = try await all(pager, first: first, limit: 4096)
        XCTAssertTrue(content.contains("SUMMARY-END")); XCTAssertFalse(content.contains("OPAQUE-MARKER"))
    }
    func testNotificationParamsExposeMessageWithoutEncryptedParts() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["method": "item/completed", "params": ["threadId": "root", "item": ["type": "agentMessage", "text": "MESSAGE-NATIVE-FULL", "encrypted_content": "OPAQUE-MARKER"]]])
        let pager = RecordedPager(), item = try event(data)
        let first = try await pager.begin(event: item, part: "content", limit: 4096)
        let content = try await all(pager, first: first)
        XCTAssertTrue(content.contains("MESSAGE-NATIVE-FULL")); XCTAssertFalse(content.contains("OPAQUE-MARKER"))
    }
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lens-pager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func event(_ data: Data, name: String = "record.jsonl") throws -> LensEvent {
        let file = directory.appendingPathComponent(name)
        try data.write(to: file)
        return LensEvent(id: UUID().uuidString, agentID: "root", source: SourceRef(path: file.path, length: data.count, line: 1))
    }
    private func record(output: Any, type: String = "function_call_output") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": type, "call_id": "call-1", "output": output]], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func all(_ pager: RecordedPager, first: RecordedPage, limit: Int = 65536) async throws -> String {
        var page = first, text = page.text
        while let token = page.token { page = try await pager.next(token: token, limit: limit); text += page.text }
        return text
    }

    func testTwoMegabyteOutputIsPulledAndTailIsPresent() async throws {
        let payload = String(repeating: "abcdef", count: 370000) + "TRAILING-MARKER"
        let data = try record(output: payload)
        let item = try event(data)
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 65536)
        XCTAssertNotNil(first.token)
        XCTAssertLessThan(first.bytesRead, 80000, "First page must not eagerly read the two megabyte record")
        XCTAssertEqual(first.totalSourceBytes, UInt64(data.count))
        let text = try await all(pager, first: first)
        XCTAssertTrue(text.hasSuffix("TRAILING-MARKER"))
        XCTAssertTrue(text.contains(payload))
    }

    func testUTF8UnicodeEscapesAndFilePageBoundaries() async throws {
        let value = String(repeating: "é👩🏽‍💻\n\"\\", count: 1300) + "END"
        let prefix = "{\"payload\":{\"type\":\"function_call_output\",\"output\":\""
        let padding = String(repeating: "x", count: 4095 - prefix.utf8.count)
        let data = Data((prefix + padding + "\\uD83D\\uDE80\\n\\t" + "\"}}\n").utf8)
        let pager = RecordedPager()
        let escaped = try event(data)
        let first = try await pager.begin(event: escaped, limit: 31)
        let text = try await all(pager, first: first, limit: 31)
        XCTAssertTrue(text.hasSuffix("🚀\n\t"))
        let native = try event(record(output: value), name: "unicode.jsonl")
        let nativeFirst = try await pager.begin(event: native, limit: 33)
        let nativeText = try await all(pager, first: nativeFirst, limit: 33)
        XCTAssertTrue(nativeText.hasSuffix(value))
        XCTAssertFalse(nativeText.contains("�"))
    }

    func testNativeOutputAndStructuredValuesRemainAvailable() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "item_completed", "item": ["formatted_output": ["status": "ok", "lines": ["a", "b"]]]]], options: .sortedKeys)
        let pager = RecordedPager()
        let item = try event(data)
        let first = try await pager.begin(event: item, limit: 16)
        let text = try await all(pager, first: first, limit: 16)
        XCTAssertTrue(text.contains("\"status\":\"ok\""))
        XCTAssertTrue(text.contains("\"lines\":[\"a\",\"b\"]"))
    }

    func testRawMasksKeysAndTextTokensAcrossBoundaries() async throws {
        let secret = "sk-" + String(repeating: "s", count: 12000)
        let data = try JSONSerialization.data(withJSONObject: ["authorization": "sensitive-auth", "payload": ["output": String(repeating: "x", count: 4080) + " Bearer abcDEF123.-_token " + secret + " TAIL", "api_key": ["nested": "hidden-secret"]]], options: [.sortedKeys, .withoutEscapingSlashes])
        let pager = RecordedPager()
        let item = try event(data)
        let first = try await pager.begin(event: item, part: "raw", limit: 13)
        let text = try await all(pager, first: first, limit: 13)
        XCTAssertFalse(text.contains("sensitive-auth"))
        XCTAssertFalse(text.contains("hidden-secret"))
        XCTAssertFalse(text.contains("abcDEF123"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("TAIL"))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }

    func testSourceChangeAndDisappearanceFailExplicitly() async throws {
        let data = try record(output: String(repeating: "a", count: 100000))
        let item = try event(data)
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 128)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: item.source.path)
        do { _ = try await pager.next(token: try XCTUnwrap(first.token)); XCTFail("Changed source accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("modifiée")) }
        let second = try await pager.begin(event: item, limit: 128)
        try FileManager.default.removeItem(atPath: item.source.path)
        do { _ = try await pager.next(token: try XCTUnwrap(second.token)); XCTFail("Missing source accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disparue")) }
    }

    func testActiveAppendPreservesExistingRecordPaging() async throws {
        let value = String(repeating: "a", count: 100000) + "OLD-RECORD-END"
        let item = try event(record(output: value))
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 128)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: item.source.path))
        try writer.seekToEnd(); try writer.write(contentsOf: Data("\n{\"payload\":{\"output\":\"new event\"}}\n".utf8)); try writer.close()
        let text = try await all(pager, first: first, limit: 4096)
        XCTAssertTrue(text.hasSuffix(value))
        XCTAssertFalse(text.contains("new event"))
    }

    func testRecordedSHA256VerifiesWholeEventIntegrityAtEOF() async throws {
        let data = try record(output: String(repeating: "v", count: 100000) + "VERIFIED-END")
        var item = try event(data)
        item.source.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 4096)
        let text = try await all(pager, first: first, limit: 4096)
        XCTAssertTrue(text.hasSuffix("VERIFIED-END"))
    }

    func testInteriorRewritePlusAppendFailsFinalRecordedSHA256() async throws {
        let data = try record(output: String(repeating: "v", count: 100000))
        var item = try event(data)
        item.source.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 4096)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: item.source.path))
        try writer.seek(toOffset: 80000); try writer.write(contentsOf: Data("w".utf8))
        try writer.seekToEnd(); try writer.write(contentsOf: Data("\n{}\n".utf8)); try writer.close()
        do { _ = try await all(pager, first: first, limit: 4096); XCTFail("Interior rewrite and append must fail the recorded integrity check") }
        catch {
            guard let lensError = error as? LensError, case .corrupt = lensError else {
                return XCTFail("A changed source must be rejected as corrupt at the recorded digest check")
            }
        }
    }

    func testLargeUnselectedFieldAlsoHasBoundedFirstRead() async throws {
        let data = Data(("{\"payload\":{\"arguments\":\"" + String(repeating: "q", count: 2200000) + "\",\"output\":\"LATE-MARKER\"}}").utf8)
        let item = try event(data)
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 65536)
        XCTAssertLessThan(first.bytesRead, 80000)
        XCTAssertNotNil(first.token)
        let text = try await all(pager, first: first)
        XCTAssertTrue(text.hasSuffix("LATE-MARKER"))
    }

    func testContentMessageAndFileChangePayloads() async throws {
        let content = Data("{\"payload\":{\"content\":[{\"type\":\"input_text\",\"text\":\"mission reçue\"},{\"type\":\"output_text\",\"text\":\"résultat\"}]}}".utf8)
        let pager = RecordedPager()
        let message = try event(content)
        let messageFirst = try await pager.begin(event: message, part: "content", limit: 16)
        let text = try await all(pager, first: messageFirst, limit: 16)
        XCTAssertTrue(text.contains("mission reçue\nrésultat"))
        let patch = Data("{\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"FileChange\",\"changes\":{\"a.swift\":{\"diff\":\"+new line\"}}}}}".utf8)
        let change = try event(patch, name: "patch.jsonl")
        let patchFirst = try await pager.begin(event: change, part: "output", limit: 16)
        let patchText = try await all(pager, first: patchFirst, limit: 16)
        XCTAssertTrue(patchText.contains("\"a.swift\":{\"diff\":\"+new line\"}"))
    }

    func testMalformedSourceDoesNotBecomeSuccessfulEOF() async throws {
        let data = Data(("{\"payload\":{\"output\":\"" + String(repeating: "q", count: 10000)).utf8)
        let item = try event(data)
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 64)
        do { _ = try await all(pager, first: first, limit: 64); XCTFail("Partial JSON accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("incomplète")) }
    }

    func testInputIsReadOnlyAndSupplementarySourcesHaveLabels() async throws {
        let sentinel = directory.appendingPathComponent("MUST-NOT-EXIST")
        let command = "touch '" + sentinel.path + "'"
        let data = try JSONSerialization.data(withJSONObject: ["payload": ["type": "function_call", "arguments": command]], options: .sortedKeys)
        var item = try event(data)
        let related = try event(record(output: "recorded result"), name: "mirror.jsonl")
        item.supplementarySources = [item.source]
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, relatedEvent: related, part: "arguments", limit: 32)
        let text = try await all(pager, first: first, limit: 32)
        XCTAssertTrue(text.contains(command))
        XCTAssertTrue(text.contains("[Source 1"))
        XCTAssertTrue(text.contains("[Source 2"))
        XCTAssertFalse(text.contains("[Source 3"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.source.path)), data)
    }

    func testUndecoratedSingleTracePreservesCompleteDecodedInput() async throws {
        let sentinel = directory.appendingPathComponent("MUST-NOT-EXECUTE")
        let input = "touch '" + sentinel.path + "'\n" + String(repeating: "é\\\"\t", count: 400000) + "TRAILING-PATCH-END\n"
        let data = try JSONSerialization.data(withJSONObject: ["payload": ["type": "custom_tool_call", "input": input]], options: [.sortedKeys, .withoutEscapingSlashes])
        var item = try event(data)
        item.source.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, part: "input", limit: 31, decorateSources: false)
        XCTAssertNotNil(first.token)
        XCTAssertLessThan(first.bytesRead, 80000)
        let copied = try await all(pager, first: first)
        XCTAssertEqual(copied.utf8.count, input.utf8.count)
        XCTAssertTrue(copied.utf8.elementsEqual(input.utf8), "Complete copied UTF-8 must equal the recorded input; large payload omitted from diagnostics")
        XCTAssertFalse(copied.contains("[Source"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: item.source.path)) == data, "Recorded source bytes must remain unchanged; large payload omitted from diagnostics")
    }

    func testUndecoratedFirstFieldHasNoSyntheticPrefixButDistinctFieldsStaySeparated() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["payload": ["type": "item_completed",
            "item": ["arguments": "FIRST-FIELD", "command": "SECOND-FIELD"]]], options: .sortedKeys)
        let item = try event(data)
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, part: "input", limit: 7, decorateSources: false)
        let copied = try await all(pager, first: first, limit: 7)
        XCTAssertEqual(copied, "FIRST-FIELD\nSECOND-FIELD")
    }

    func testUndecoratedSourceSelectionDoesNotMixCallResultOrWorktree() async throws {
        let dataA = try JSONSerialization.data(withJSONObject: ["payload": ["type": "function_call", "arguments": "{\"command\":\"cat src/main.swift\",\"cwd\":\"/fixture/worktree-a\"}"]], options: .sortedKeys)
        let dataB = try JSONSerialization.data(withJSONObject: ["payload": ["type": "function_call", "arguments": "{\"command\":\"cat src/main.swift\",\"cwd\":\"/fixture/worktree-b\"}"]], options: .sortedKeys)
        var selected = try event(dataA, name: "worktree-a.jsonl")
        let mirror = try event(dataB, name: "worktree-b.jsonl")
        selected.source = mirror.source
        selected.supplementarySources = []
        let pager = RecordedPager()
        let first = try await pager.begin(event: selected, relatedEvent: nil, part: "arguments", limit: 9, decorateSources: false)
        let copied = try await all(pager, first: first, limit: 9)
        XCTAssertEqual(copied, "{\"command\":\"cat src/main.swift\",\"cwd\":\"/fixture/worktree-b\"}")
        XCTAssertFalse(copied.contains("worktree-a"))
        XCTAssertFalse(copied.contains("[Source"))
    }

    func testUndecoratedMissingFieldIsEmptyWithoutInventedCoverageText() async throws {
        let item = try event(record(output: "recorded result"))
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, part: "input", limit: 7, decorateSources: false)
        let copied = try await all(pager, first: first, limit: 7)
        XCTAssertEqual(copied, "")
        let decorated = try await pager.begin(event: item, part: "input")
        let displayed = try await all(pager, first: decorated)
        XCTAssertTrue(displayed.contains("[Source 1"))
        XCTAssertTrue(displayed.contains("[Couverture"))
    }

    func testUndecoratedStillMasksSecretsAndRejectsIncompleteSource() async throws {
        let raw = Data("{\"payload\":{\"output\":\"Bearer abcDEF123 sk-keyexample\",\"api_key\":\"private-value\"}}".utf8)
        let item = try event(raw)
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, part: "raw", limit: 5, decorateSources: false)
        let copied = try await all(pager, first: first, limit: 5)
        XCTAssertTrue(copied.contains("[REDACTED]"))
        XCTAssertFalse(copied.contains("abcDEF123"))
        XCTAssertFalse(copied.contains("sk-keyexample"))
        XCTAssertFalse(copied.contains("private-value"))
        XCTAssertFalse(copied.contains("[Source"))
        let partial = try event(Data(("{\"payload\":{\"input\":\"" + String(repeating: "q", count: 10000)).utf8), name: "partial.jsonl")
        let partialFirst = try await pager.begin(event: partial, part: "input", limit: 64, decorateSources: false)
        do { _ = try await all(pager, first: partialFirst, limit: 64); XCTFail("Partial source accepted for a complete copy") }
        catch { XCTAssertTrue(error.localizedDescription.contains("incomplète")) }
    }

    func testInactiveCursorCapExpiresOldest() async throws {
        let item = try event(record(output: String(repeating: "q", count: 10000)))
        let pager = RecordedPager()
        let first = try await pager.begin(event: item, limit: 32)
        for _ in 0..<8 { _ = try await pager.begin(event: item, limit: 32) }
        do { _ = try await pager.next(token: try XCTUnwrap(first.token)); XCTFail("Old cursor was not evicted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("expirée")) }
    }
}
