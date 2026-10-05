import Foundation
import XCTest
@testable import LensCore

final class PastedAttachmentTests: XCTestCase {
    func testPastedTitlePreservesSpacesAndProvidedProvenance() async throws {
        let snapshot = try await snapshot(availableFiles: ["Texte collé avec espaces.txt"]) { base in
            "# Files pasted by the user:\n\n## Document fourni: \(base.appendingPathComponent("Texte collé avec espaces.txt").path)\n\nContenu fourni.\n\n# My request:\nLire ce document."
        }
        let resource = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/Texte collé avec espaces.txt") })
        XCTAssertTrue(resource.roles.contains(.supplied))
        XCTAssertTrue(resource.roles.contains(.referenced))
        XCTAssertFalse(resource.roles.contains(.recordedRead))
        XCTAssertEqual(resource.availability, .accessible)
        XCTAssertEqual(resource.eventIDs.count, 1)
    }

    func testMentionedSectionIsReferencedOnly() async throws {
        let snapshot = try await snapshot { base in
            "# Files mentioned by the user:\n\n## Document mentionné: \(base.appendingPathComponent("document mentionné avec espaces.pdf").path)\n\n# My request:\nExpliquer cette référence."
        }
        let resource = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/document mentionné avec espaces.pdf") })
        XCTAssertEqual(Set(resource.roles), [.referenced])
        XCTAssertEqual(resource.availability, .missing)
        XCTAssertFalse(snapshot.resources.contains { $0.roles.contains(.supplied) })
    }

    func testPathInLaterRequestDoesNotBecomeProvided() async throws {
        let snapshot = try await snapshot { base in
            "# Files pasted by the user:\n\n## Pièce jointe: \(base.appendingPathComponent("document fourni.txt").path)\n\nTexte.\n\n# My request:\nConsulte aussi\n\(base.appendingPathComponent("autre fichier demandé.swift").path)"
        }
        let attachment = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/document fourni.txt") })
        let requested = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/autre fichier demandé.swift") })
        XCTAssertTrue(attachment.roles.contains(.supplied))
        XCTAssertEqual(Set(requested.roles), [.referenced])
    }

    func testUnavailablePastedAttachmentKeepsProvidedReference() async throws {
        let snapshot = try await snapshot { base in
            "# Files pasted by the user:\n\n## Ancienne pièce jointe: \(base.appendingPathComponent("fichier disparu avec espaces.txt").path)\n\nExtrait enregistré.\n\n# My request:\nAnalyser."
        }
        let resource = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/fichier disparu avec espaces.txt") })
        XCTAssertTrue(resource.roles.contains(.supplied))
        XCTAssertTrue(resource.roles.contains(.referenced))
        XCTAssertFalse(resource.roles.contains(.recordedRead))
        XCTAssertEqual(resource.availability, .missing)
        XCTAssertFalse(resource.eventIDs.isEmpty)
        XCTAssertTrue(snapshot.coverage.contains { $0.category == "pièce jointe indisponible" })
    }

    func testSixPastedTitlesDoNotPromotePathsInsideDocumentContents() async throws {
        let snapshot = try await snapshot { base in
            let attachments = (1...6).map { index in
                "## Document \(index): \(base.appendingPathComponent("Document fourni \(index).txt").path)\nTexte anonymisé."
            }.joined(separator: "\n\n")
            return "# Files pasted by the user:\n\n\(attachments)\n\nChemin mentionné dans le contenu:\n\(base.appendingPathComponent("mention dans le contenu.txt").path)\n\n# My request:\nComparer les six documents."
        }
        XCTAssertEqual(snapshot.resources.filter { $0.roles.contains(.supplied) }.count, 6)
        let mention = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/mention dans le contenu.txt") })
        XCTAssertEqual(Set(mention.roles), [.referenced])
    }

    func testLegacySuppliedSectionStopsAtPlainRequestBoundary() async throws {
        let snapshot = try await snapshot { base in
            "Files supplied by the user:\n\(base.appendingPathComponent("ancien fourni.txt").path)\nMy request:\n\(base.appendingPathComponent("référence de la demande.txt").path)"
        }
        let supplied = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/ancien fourni.txt") })
        let reference = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/référence de la demande.txt") })
        XCTAssertTrue(supplied.roles.contains(.supplied))
        XCTAssertEqual(Set(reference.roles), [.referenced])
    }

    func testAnotherTopLevelSectionStopsProvidedProvenance() async throws {
        let snapshot = try await snapshot { base in
            "# Files pasted by the user:\n## Fourni: \(base.appendingPathComponent("fourni.txt").path)\nTexte.\n# Files mentioned by the user:\n## Mentionné: \(base.appendingPathComponent("simple mention.txt").path)\n# My request:\nComparer."
        }
        let mention = try XCTUnwrap(snapshot.resources.first { $0.location.hasSuffix("/simple mention.txt") })
        XCTAssertEqual(Set(mention.roles), [.referenced])
        XCTAssertEqual(snapshot.resources.filter { $0.roles.contains(.supplied) }.count, 1)
    }

    private func snapshot(availableFiles: [String] = [], text: (URL) -> String) async throws -> SessionSnapshot {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LensPasted-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("codex-home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for name in availableFiles { try Data("Contenu anonymisé.\n".utf8).write(to: base.appendingPathComponent(name)) }
        let id = UUID().uuidString.lowercased()
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": base.path, "cli_version": "0.159.2"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text(base)]]]]
        ]
        var bytes = Data()
        for var record in records {
            record["timestamp"] = "2026-10-02T12:00:00.000Z"
            bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10)
        }
        try bytes.write(to: sessions.appendingPathComponent("rollout-" + id + ".jsonl"))
        let engine = SessionEngine(home: home, cacheDirectory: base.appendingPathComponent("cache"))
        return try await engine.open(id: id)
    }
}
