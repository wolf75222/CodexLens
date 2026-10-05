import Foundation
import XCTest
@testable import LensCore

final class CodexSourceLocationTests: XCTestCase {
    func testPersonalSourceHonorsCodexHomeAndTestSourceRequiresExplicitOverride() {
        let home = URL(fileURLWithPath: "/anonymous/user")
        let environment = ["CODEX_HOME": "/anonymous/personal", "LENS_CODEX_HOME": "/anonymous/test"]
        XCTAssertEqual(CodexSourceLocation.personalHome(environment: environment, userHome: home).path, "/anonymous/personal")
        XCTAssertEqual(CodexSourceLocation.observationHome(environment: environment, userHome: home).path, "/anonymous/test")
        XCTAssertEqual(CodexSourceLocation.observationHome(environment: ["CODEX_HOME": "/anonymous/personal"], userHome: home).path, "/anonymous/personal")
    }
    func testInvalidOverridesDoNotBecomeRelativeOrEmptySources() {
        let home = URL(fileURLWithPath: "/anonymous/user")
        for value in ["", "relative", "file:///anonymous/other", "/anonymous/\0secret"] {
            XCTAssertEqual(CodexSourceLocation.observationHome(environment: ["LENS_CODEX_HOME": value, "CODEX_HOME": value], userHome: home).path, "/anonymous/user/.codex")
        }
        XCTAssertEqual(CodexSourceLocation.personalHome(environment: [:], userHome: home).path, "/anonymous/user/.codex")
    }
}
