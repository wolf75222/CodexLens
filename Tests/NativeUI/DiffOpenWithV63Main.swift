import AppKit
import Foundation
import LensCore

/// Pure target and existing file-action policies, with an unattached read-only
/// code view. Launch Services opens and the application picker are tested in GUI.
@main struct DiffOpenWithV63Main {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--output"), args.indices.contains(index + 1) else { exit(2) }
        let output = URL(fileURLWithPath: args[index + 1])
        let alpha = EnvironmentRecord(path: "/private/tmp/LensAlpha"), beta = EnvironmentRecord(path: "/private/tmp/LensBeta")
        func file(_ path: String?, old: String? = nil, environment: EnvironmentRecord = alpha, operation: DiffFileOperation = .modified) -> RecordedFileDiff {
            RecordedFileDiff(id: "test", oldPath: old ?? path, newPath: path, operation: operation, provenance: DiffProvenance(environmentID: environment.id))
        }
        func target(_ file: RecordedFileDiff, _ environment: EnvironmentRecord? = alpha) -> String? { NativeDiffFileTarget.path(file: file, environment: environment) }
        var checks = nativeFileActionLogicChecks()
        checks += [
            ("diff-relative-path-resolves-in-alpha", target(file("src/Same.swift")) == "/private/tmp/LensAlpha/src/Same.swift"),
            ("diff-relative-path-resolves-in-beta", target(file("src/Same.swift", environment: beta), beta) == "/private/tmp/LensBeta/src/Same.swift"),
            ("diff-cannot-use-another-worktree-environment", target(file("src/Same.swift"), beta) == nil),
            ("diff-missing-environment-no-current-directory-fallback", target(file("src/Same.swift"), nil) == nil),
            ("diff-absolute-path-preserved", target(file("/private/tmp/LensAlpha/src/Same.swift")) == "/private/tmp/LensAlpha/src/Same.swift"),
            ("diff-macos-temporary-alias-preserved", target(file("/tmp/LensAlpha/src/Same.swift")) == "/tmp/LensAlpha/src/Same.swift"),
            ("diff-external-absolute-path-refused", target(file("/private/tmp/LensBeta/src/Same.swift")) == nil),
            ("diff-prefix-sibling-refused", target(file("/private/tmp/LensAlpha-copy/src/Same.swift")) == nil),
            ("diff-traversal-refused", target(file("../LensBeta/src/Same.swift")) == nil),
            ("diff-dot-segments-and-unicode-preserved", target(file("src/../Notes/Texte collé.swift")) == "/private/tmp/LensAlpha/Notes/Texte collé.swift"),
            ("diff-rename-opens-current-new-path", target(file("src/New.swift", old: "src/Old.swift", operation: .renamed)) == "/private/tmp/LensAlpha/src/New.swift"),
            ("diff-deletion-keeps-old-path-without-fabricating-version", target(file(nil, old: "src/Deleted.swift", operation: .deleted)) == "/private/tmp/LensAlpha/src/Deleted.swift"),
            ("diff-unknown-path-refused", target(file(nil)) == nil),
            ("diff-null-byte-refused", target(file("src/a\0.swift")) == nil),
            ("diff-dev-null-refused", target(file("/dev/null")) == nil),
            ("diff-network-reference-refused", target(file("https://example.invalid/file.swift")) == nil)
        ]
        let passed = checks.allSatisfy(\.1)
        let result: [String: Any] = ["allExecutedChecksPassed": passed, "checks": checks.map { ["name": $0.0, "passed": $0.1] },
            "unqualified": [], "externalOpens": 0, "clipboardWrites": 0, "productionEntryPoint": false]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("native-v06-receipt.json"))
        } catch { fputs("Qualification receipt: \(error)\n", stderr); exit(2) }
        exit(passed ? 0 : 1)
    }
}
