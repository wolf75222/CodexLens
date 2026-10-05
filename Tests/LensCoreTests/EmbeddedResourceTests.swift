import Foundation
import AppKit
import XCTest
@testable import LensCore

final class EmbeddedResourceTests: XCTestCase {
    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func resource(index: Int = 1) -> ResourceRecord {
        ResourceRecord(location: "trace:test-event:attachment:\(index)", roles: [.supplied], eventIDs: ["test-event"])
    }

    private func detail(parts: [[String: Any]], wrapped: Bool = false, supplementary: [[String: Any]] = []) throws -> EventDetail {
        let message: [String: Any] = ["type": "message", "role": "user", "content": parts]
        let payload: [String: Any] = wrapped ? ["type": "item_completed", "item": ["type": "UserMessage", "content": parts]] : message
        let records = [["type": "response_item", "payload": payload]] + supplementary
        let raw = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n\n")
        return EventDetail(raw: raw)
    }

    func testRecordedPNGReturnsExactInlineBytesAtCompleteContentIndex() throws {
        let png = try pngData()
        let uri = "data:image/png;base64," + png.base64EncodedString()
        let record = try detail(parts: [["type": "input_text", "text": "Inspect this supplied image"], ["type": "input_image", "image_url": uri]], supplementary: [["type": "event_msg", "payload": ["type": "task_complete"]]])
        let decoded = try EmbeddedResource.decodeImage(resource: resource(), detail: record)
        XCTAssertEqual(decoded, png)
        XCTAssertNotNil(NSImage(data: decoded))
        do { _ = try EmbeddedResource.decodeImage(resource: resource(index: 0), detail: record); XCTFail("A text part cannot substitute its adjacent image") }
        catch EmbeddedResource.DecodeError.unavailable { }
    }

    func testItemCompletedAndDictionaryURLKeepSameAttachmentIndex() throws {
        let png = try pngData()
        let uri = "data:image/png;base64," + png.base64EncodedString()
        let record = try detail(parts: [["type": "input_text", "text": "Context"], ["type": "input_image", "image_url": ["url": uri]]], wrapped: true)
        XCTAssertEqual(try EmbeddedResource.decodeImage(resource: resource(), detail: record), png)
    }

    func testMissingBytesAndRemoteURLsAreExplicitWithoutFetching() throws {
        let absent = try detail(parts: [["type": "input_text", "text": "Context"], ["type": "input_image"]])
        do { _ = try EmbeddedResource.decodeImage(resource: resource(), detail: absent); XCTFail("Missing URL") }
        catch EmbeddedResource.DecodeError.unavailable { }
        let remote = try detail(parts: [["type": "input_text", "text": "Context"], ["type": "input_image", "image_url": "https://example.invalid/never-fetch.png"]])
        do { _ = try EmbeddedResource.decodeImage(resource: resource(), detail: remote); XCTFail("Remote URL cannot be fetched") }
        catch EmbeddedResource.DecodeError.unsupportedFormat { }
        let generic = ResourceRecord(location: "trace:test-event:images", roles: [.supplied], eventIDs: ["test-event"])
        do { _ = try EmbeddedResource.decodeImage(resource: generic, detail: remote); XCTFail("No arbitrary-image fallback") }
        catch EmbeddedResource.DecodeError.invalidReference { }
    }

    func testTextInstructionsAndUnsupportedMIMEAreNotImages() throws {
        let textBytes = Data("Draw a red circle. This is an instruction, not recorded image bytes.".utf8)
        for (uri, expectedFormatError) in [("data:image/png;base64," + textBytes.base64EncodedString(), false), ("data:image/svg+xml;base64," + textBytes.base64EncodedString(), true)] {
            let record = try detail(parts: [["type": "input_image", "image_url": uri]])
            do { _ = try EmbeddedResource.decodeImage(resource: resource(index: 0), detail: record); XCTFail("Text instruction is not an image") }
            catch EmbeddedResource.DecodeError.invalidImage { XCTAssertFalse(expectedFormatError) }
            catch EmbeddedResource.DecodeError.unsupportedFormat { XCTAssertTrue(expectedFormatError) }
        }
        let invalidBase64 = try detail(parts: [["type": "input_image", "image_url": "data:image/png;base64,%%%%"]])
        do { _ = try EmbeddedResource.decodeImage(resource: resource(index: 0), detail: invalidBase64); XCTFail("Invalid base64") }
        catch EmbeddedResource.DecodeError.invalidBase64 { }
    }

    func testAmbiguousSourcesAndMismatchedOriginDoNotChooseAnotherImage() throws {
        let uri = "data:image/png;base64," + (try pngData()).base64EncodedString()
        let other: [String: Any] = ["payload": ["type": "message", "content": [["type": "input_image", "image_url": uri.replacingOccurrences(of: "image/png", with: "IMAGE/PNG")]]]]
        let record = try detail(parts: [["type": "input_image", "image_url": uri]], supplementary: [other])
        do { _ = try EmbeddedResource.decodeImage(resource: resource(index: 0), detail: record); XCTFail("Ambiguous source") }
        catch EmbeddedResource.DecodeError.ambiguousRecords { }
        let wrongOrigin = ResourceRecord(location: "trace:other-event:attachment:0", roles: [.supplied], eventIDs: ["test-event"])
        do { _ = try EmbeddedResource.decodeImage(resource: wrongOrigin, detail: record); XCTFail("Wrong event association") }
        catch EmbeddedResource.DecodeError.invalidReference { }
        do { _ = try EmbeddedResource.decodeImage(resource: resource(index: 0), detail: EventDetail(raw: "{\"payload\":")); XCTFail("Incomplete JSON") }
        catch EmbeddedResource.DecodeError.malformedRecord { }
    }

    func testDecodedByteLimitIsCheckedBeforeAllocatingImageData() throws {
        let limit = 32 * 1024 * 1024
        let oversized = String(repeating: "A", count: ((limit + 2) / 3) * 4 + 4)
        let raw = "{\"payload\":{\"type\":\"message\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,\(oversized)\"}]}}"
        do { _ = try EmbeddedResource.decodeImage(resource: resource(index: 0), detail: EventDetail(raw: raw)); XCTFail("More than 32 MiB decoded") }
        catch EmbeddedResource.DecodeError.tooLarge { }
    }
}
