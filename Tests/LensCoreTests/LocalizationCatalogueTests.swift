import Foundation
import XCTest

final class LocalizationCatalogueTests: XCTestCase {
    private func catalogue() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Assets/Localizations/en.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAllTranslationsBelongToTheLoadedDictionary() throws {
        let value = try catalogue()
        // The app's decoder ignores unknown top-level keys. They must not hide
        // valid-looking translations that users can never see.
        XCTAssertEqual(Set(value.keys), ["schemaVersion", "language", "translations"])
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        XCTAssertEqual(value["language"] as? String, "en")
        let translations = try XCTUnwrap(value["translations"] as? [String: String])
        XCTAssertFalse(translations.isEmpty)
        XCTAssertTrue(translations.allSatisfy { !$0.key.isEmpty && !$0.value.isEmpty })
    }

    func testGettingStartedAndProgressAreAvailableInEnglish() throws {
        let translations = try XCTUnwrap(catalogue()["translations"] as? [String: String])
        XCTAssertEqual(translations["Premiers pas"], "Getting started")
        XCTAssertEqual(translations["Explorer"], "Explore")
        XCTAssertEqual(translations["Fichiers"], "Files")
        XCTAssertEqual(translations["Session {0}"], "Session {0}")
        XCTAssertEqual(translations["Repères"], "Reading guide")
        XCTAssertEqual(translations["Comprendre une session Codex"], "Understand a Codex session")
        XCTAssertEqual(translations["Retrouvez une session Codex et consultez son historique."],
                       "Find a Codex session and browse its history.")
        let progress = try XCTUnwrap(translations["Étape %d sur %d"])
        XCTAssertEqual(progress.components(separatedBy: "%d").count, 3)
        XCTAssertEqual(String(format: progress, 2, 3), "Step 2 of 3")
    }
    func testContinuousChatControlsAreAvailableInEnglish() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Assets/Localizations/en.json"))) as? [String: Any])
        let translations = try XCTUnwrap(catalog["translations"] as? [String: String])
        XCTAssertEqual(translations["Nouveau chat"], "New chat")
        XCTAssertEqual(translations["Connecter Codex"], "Connect Codex")
        XCTAssertEqual(translations["Aucun élément joint"], "No attachments")
        XCTAssertTrue(translations["Message ; Retour envoie, Majuscule-Retour ajoute une ligne"]?.contains("Shift-Return") == true)
    }
}
