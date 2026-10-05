import AppKit
import UniformTypeIdentifiers

/// Called by the native verification harness. Pure fixture paths/policies and an
/// unattached read-only text view; no NSWorkspace open and no real clipboard write.
@MainActor
func nativeFileActionLogicChecks() -> [(String, Bool)] {
    let first = NativeFileLocation(path: "/private/tmp/LensWorktreeA/src/Same.swift", worktreeRoot: "/private/tmp/LensWorktreeA", line: 7)
    let second = NativeFileLocation(path: "/private/tmp/LensWorktreeB/src/Same.swift", worktreeRoot: "/private/tmp/LensWorktreeB", line: 7)
    let unicode = NativeFileLocation(path: "/private/tmp/LensWorktreeA/src/../Sources/Texte collé 2026.swift", worktreeRoot: "/private/tmp/LensWorktreeA", line: 17)
    let text = "é😀\r\nligne CR\rligne LF\nfin"
    let finalOffset = (text as NSString).range(of: "fin").location
    let surrogateOffset = (text as NSString).range(of: "😀").location + 1
    let documents: [[String: Any]] = [["CFBundleTypeRole": "Editor", "LSItemContentTypes": [UTType.plainText.identifier]]]
    let shellDocuments: [[String: Any]] = [["CFBundleTypeRole": "Shell", "CFBundleTypeExtensions": ["*"]]]
    var checks: [(String, Bool)] = [
        ("file-path-two-worktrees-distinct", first != second && first.absolutePath != second.absolutePath),
        ("file-path-two-worktrees-relative-same", first.relativePath == "src/Same.swift" && second.relativePath == first.relativePath),
        ("file-path-spaces-unicode-normalized", unicode.absolutePath == "/private/tmp/LensWorktreeA/Sources/Texte collé 2026.swift" && unicode.relativePath == "Sources/Texte collé 2026.swift"),
        ("file-path-line-no-gutter-or-extra-numbers", unicode.fileLine == "/private/tmp/LensWorktreeA/Sources/Texte collé 2026.swift:17"),
        ("file-path-zero-line-rejected", NativeFileLocation(path: "/private/tmp/a.swift", line: 0).fileLine == nil),
        ("file-path-outside-root-no-relative", NativeFileLocation(path: "/private/tmp/LensWorktreeA-copy/a.swift", worktreeRoot: "/private/tmp/LensWorktreeA").relativePath == nil),
        ("file-path-traversal-no-relative", NativeFileLocation(path: "/private/tmp/LensWorktreeA/../other/a.swift", worktreeRoot: "/private/tmp/LensWorktreeA").relativePath == nil),
        ("file-path-relative-not-absolute-invented", NativeFileLocation(path: "src/Same.swift").absolutePath == nil),
        ("file-local-uri-decodes-spaces", NativeFileLocation.localPath("file:///private/tmp/Texte%20coll%C3%A9.txt") == "/private/tmp/Texte collé.txt"),
        ("file-remote-uri-refused", NativeFileLocation.localPath("file://server/private/tmp/file.txt") == nil && NativeFileLocation.localPath("https://example.invalid/file.txt") == nil),
        ("file-line-crlf-cr-lf-unicode-utf16", NativeFileLocation.lineNumber(in: text, atUTF16Offset: finalOffset) == 4),
        ("file-line-crlf-counted-once", NativeFileLocation.lineNumber(in: "é😀\r\nfin", atUTF16Offset: ("é😀\r\n" as NSString).length) == 2),
        ("file-line-surrogate-split-refused", NativeFileLocation.lineNumber(in: text, atUTF16Offset: surrogateOffset) == nil),
        ("file-line-out-of-range-refused", NativeFileLocation.lineNumber(in: text, atUTF16Offset: -1) == nil && NativeFileLocation.lineNumber(in: text, atUTF16Offset: (text as NSString).length + 1) == nil),
        ("file-app-recognized-reader-editor", NativeDocumentApplicationPolicy.permits(bundleID: "fr.codexlens.fixture.editor", name: "Fixture Editor", documentTypes: documents, fileType: .plainText, extension: "txt")),
        ("file-app-shell-role-refused", !NativeDocumentApplicationPolicy.permits(bundleID: "fr.codexlens.fixture.runner", name: "Fixture", documentTypes: shellDocuments, fileType: .plainText, extension: "txt")),
        ("file-app-terminal-and-interpreter-refused", !NativeDocumentApplicationPolicy.permits(bundleID: "com.apple.Terminal", name: "Terminal", documentTypes: documents, fileType: .plainText, extension: "txt") && !NativeDocumentApplicationPolicy.permits(bundleID: "org.python.PythonLauncher", name: "Python Launcher", documentTypes: documents, fileType: .plainText, extension: "txt")),
        ("file-app-unknown-identity-refused", !NativeDocumentApplicationPolicy.permits(bundleID: nil, name: "Unknown", documentTypes: documents, fileType: .plainText, extension: "txt")),
        ("file-app-incompatible-document-type-refused", !NativeDocumentApplicationPolicy.permits(bundleID: "fr.codexlens.fixture.editor", name: "Fixture", documentTypes: documents, fileType: .pdf, extension: "pdf")),
        ("file-app-executable-and-bundle-refused", !NativeDocumentApplicationPolicy.permitsFile(type: .executable, isExecutable: false, extension: "bin") && !NativeDocumentApplicationPolicy.permitsFile(type: .plainText, isExecutable: true, extension: "swift") && !NativeDocumentApplicationPolicy.permitsFile(type: .applicationBundle, isExecutable: false, extension: "app")),
        ("file-app-ordinary-text-permitted", NativeDocumentApplicationPolicy.permitsFile(type: .plainText, isExecutable: false, extension: "txt"))
    ]
    let document = CodeReadOnlyTextView(frame: .zero)
    document.isEditable = false; document.isSelectable = true
    let code = "let numéro2026 = \"é😀\"\r\n// deuxième ligne\n"
    document.string = code
    var copies: [(String, CodeTextCopyScope)] = []
    document.onCopyText = { copies.append(($0, $1)) }
    let selectedRange = (code as NSString).range(of: "é😀")
    document.setSelectedRange(selectedRange)
    document.copy(nil)
    document.perform(NSSelectorFromString("copyLoadedText:"), with: nil)
    checks.append(("file-code-copy-selection-exact-no-gutter", copies.count >= 1 && copies[0].0 == "é😀" && copies[0].1 == .selection))
    checks.append(("file-code-copy-loaded-exact-no-gutter", copies.count == 2 && copies[1].0 == code && copies[1].1 == .loadedText))
    checks.append(("file-code-copy-remains-read-only", document.string == code && !document.isEditable))
    return checks
}
